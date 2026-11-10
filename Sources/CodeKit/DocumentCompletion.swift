#if os(macOS)
  import AppKit
  import CodeAutocompletion
  import CodeEditor
  import CodeLSP
  import CodeScan
  import CodeSwiftModel
  import CodeWorkspace

  /// Completions for a workspace document, in steps: the Swift model's list (Swift) or Code's scanner's (other
  /// languages) right away, then the language server's with the fast list's extra names, when the server takes longer
  /// than a moment. Without a server, the fast list alone, else the file's words and the language's keywords.
  @MainActor final class DocumentCompletionProvider: CompletionProvider {
    weak var services: ProjectServices?
    weak var document: TextDocument?
    weak var textView: CodeTextView?
    private let words = WordCompletionProvider()

    init(textView: CodeTextView) { self.textView = textView }

    /// The file's server, when it completes code.
    private var server: (LanguageServerManager, URL)? {
      guard let services, let url = document?.url, services.languageServers.supportsCompletion(url)
      else { return nil }
      return (services.languageServers, url)
    }

    /// How long the server's list is waited for before the fast list shows.
    static let serverWait: Duration = .milliseconds(50)

    var triggerCharacters: Set<String> {
      // A call's "(" lists what it could mean (the Swift model's overloads).
      let calls: Set<String> = listsOverloads ? ["("] : []
      guard let (servers, url) = server else {
        // Without a server (Restricted Mode, none installed), "." still asks the model or the scanner.
        let members: Set<String> = hasFastList ? ["."] : []
        return words.triggerCharacters.union(calls).union(members)
      }
      let characters = servers.completionTriggerCharacters(url)
      return (characters.isEmpty ? ["."] : characters).union(calls)
    }

    /// Whether the Swift model (a Swift file) or Code's scanner (another) answers.
    private var hasFastList: Bool {
      guard let services, let url = document?.url else { return false }
      return CodeTiers.isSwift(url) ? services.settings.usesSwiftModel : services.settings.usesScanner
    }

    /// Whether "(" lists a call's overloads: the Swift model's, in a Swift file.
    private var listsOverloads: Bool {
      guard let services, let url = document?.url else { return false }
      return services.settings.usesSwiftModel && CodeTiers.isSwift(url)
    }

    func completions(for context: CompletionContext) async -> CompletionList? {
      await completions(for: context) { _ in }
    }

    func completions(
      for context: CompletionContext, update: @escaping @MainActor (CompletionList) -> Void
    ) async -> CompletionList? {
      // The text as it is now: typing goes on while the tiers answer.
      let text = context.text as String
      if case .character("(") = context.trigger {
        // Only the call's overloads, or nothing: "(" opens no list elsewhere.
        guard let list = await fastCompletions(for: context, text: text) else { return nil }
        let overloads = list.items.filter { $0.payload is Overload }
        return overloads.isEmpty ? nil : CompletionList(items: overloads, isIncomplete: false)
      }
      let fast = Task { await self.fastCompletions(for: context, text: text) }
      guard server != nil else {
        if let list = await fast.value, !list.items.isEmpty { return list }
        return await words.completions(for: context)
      }
      let slow = Task { await self.serverCompletions(for: context) }
      let quick = await fast.value
      // The server's list when it's quick enough, else the fast one in the meantime.
      let early = await Self.value(of: slow, within: Self.serverWait)
      if early == nil, let quick, !quick.items.isEmpty { update(quick) }
      var list = early
      if list == nil { list = await slow.value }
      guard let list else { return quick }
      return Self.merge(list, quick)
    }

    /// A task's value if it finishes within `limit`.
    private static func value<T: Sendable>(of task: Task<T?, Never>, within limit: Duration) async -> T? {
      await withTaskGroup(of: T?.self) { group in
        group.addTask { await task.value }
        group.addTask {
          try? await Task.sleep(for: limit)
          return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
      }
    }

    /// The server's items, then the fast list's names it doesn't have.
    static func merge(_ list: CompletionList, _ fast: CompletionList?) -> CompletionList {
      guard let fast, !fast.items.isEmpty else { return list }
      func name(_ item: CompletionItem) -> Substring {
        let text = item.filterText ?? item.label
        return text.prefix { $0 != "(" && $0 != " " && $0 != ":" }
      }
      let names = Set(list.items.map(name))
      return CompletionList(
        items: list.items + fast.items.filter { !names.contains(name($0)) }, isIncomplete: list.isIncomplete)
    }

    /// The Swift model's list for a Swift file, Code's scanner's for another; nil when they're off.
    private func fastCompletions(for context: CompletionContext, text: String) async -> CompletionList? {
      guard let services, let url = document?.url, let textView else { return nil }
      let position = textView.position(of: context.location)
      let tiers = services.tiers
      if services.settings.usesSwiftModel, CodeTiers.isSwift(url) {
        guard
          let list = await tiers.modelCompletions(
            url: url, text: text, line: position.line, column: position.column), list.context != .none
        else { return nil }
        return CompletionList(
          items: list.items.map { Self.item($0, context: context) }, isIncomplete: list.isIncomplete)
      }
      guard services.settings.usesScanner else { return nil }
      let found = await tiers.scannerCompletions(url: url, text: text, line: position.line, column: position.column)
      return CompletionList(
        items: found.map {
          CompletionItem(
            label: $0.label, detail: $0.detail, kind: Self.kind($0.kind),
            sortText: String(format: "%05d", 99999 - min($0.score, 99999)))
        }, isIncomplete: found.count >= 150)
    }

    /// A Swift model's item. On an optional receiver it also writes the `?` before the dot.
    static func item(_ entry: SwiftCompletionEntry, context: CompletionContext) -> CompletionItem {
      var edits: [CompletionEdit] = []
      let dot = context.wordRange.location - 1
      if entry.needsUnwrap, dot >= 0, dot < context.text.length, context.text.character(at: dot) == 0x2E {
        edits.append(CompletionEdit(range: NSRange(location: dot, length: 0), text: "?"))
      }
      let signature = entry.label.hasPrefix(entry.name) ? String(entry.label.dropFirst(entry.name.count)) : nil
      return CompletionItem(
        label: entry.name, labelDetail: signature.flatMap { $0.isEmpty ? nil : $0 },
        detail: entry.detail.isEmpty ? (entry.module.isEmpty ? nil : entry.module) : entry.detail,
        documentation: entry.module.isEmpty ? nil : entry.module,
        kind: CompletionKind(rawValue: entry.kind.rawValue) ?? .text, filterText: entry.name,
        insertText: entry.insertText, isSnippet: entry.isSnippet, additionalEdits: edits,
        isDeprecated: entry.isDeprecated, payload: entry.isArguments ? Overload() : nil)
    }

    /// Marks an overload of the call after its "(": its insert text is the arguments alone.
    struct Overload: Sendable {}

    static func kind(_ kind: SymbolKind?) -> CompletionKind {
      guard let kind else { return .keyword }
      switch kind {
      case .class, .typeAlias: return .class
      case .struct: return .struct
      case .enum: return .enum
      case .enumMember: return .enumMember
      case .interface: return .interface
      case .method: return .method
      case .function: return .function
      case .constructor: return .constructor
      case .field: return .field
      case .property: return .property
      case .constant: return .constant
      case .module, .namespace, .extension: return .module
      case .variable, .key: return .variable
      }
    }

    /// The language server's list; nil when it has none or failed.
    private func serverCompletions(for context: CompletionContext) async -> CompletionList? {
      guard let (servers, url) = server, let textView else { return nil }
      let position = textView.position(of: context.location)
      let trigger: LSPCompletionTrigger
      switch context.trigger {
      case .character(let character): trigger = .character(character)
      case .incomplete: trigger = .incomplete
      case .invoked, .typing: trigger = .invoked
      }
      guard
        let list = await servers.completions(
          url: url, position: LSPPosition(line: position.line, character: position.column),
          trigger: trigger), let current = self.textView
      else { return nil }
      return CompletionList(
        items: list.items.map { Self.item($0, in: current) }, isIncomplete: list.isIncomplete)
    }

    func resolve(_ item: CompletionItem) async -> CompletionItem? {
      guard let original = item.payload as? LSPCompletionItem, let (servers, url) = server,
        let resolved = await servers.resolve(original, url: url), let textView
      else { return nil }
      var result = Self.item(resolved, in: textView)
      // The range is in the text as it was when the list was asked for.
      result.range = item.range
      return result
    }

    /// A server's item with its ranges as text locations.
    static func item(_ item: LSPCompletionItem, in textView: CodeTextView) -> CompletionItem {
      func range(_ range: LSPRange) -> NSRange {
        let start = textView.location(line: range.start.line, column: range.start.character)
        let end = textView.location(line: range.end.line, column: range.end.character)
        return NSRange(location: start, length: max(0, end - start))
      }
      return CompletionItem(
        label: item.label, labelDetail: item.labelDetail,
        detail: item.labelDescription ?? item.detail, documentation: item.documentation,
        kind: item.kind.flatMap(CompletionKind.init) ?? .text, filterText: item.filterText,
        sortText: item.sortText, insertText: item.insertText, isSnippet: item.isSnippet,
        range: item.range.map(range),
        additionalEdits: item.additionalTextEdits.compactMap { edit in
          edit.range.map { CompletionEdit(range: range($0), text: edit.text) }
        }, isDeprecated: item.isDeprecated, isPreselected: item.isPreselected, needsResolve: true,
        payload: item)
    }
  }
#endif
