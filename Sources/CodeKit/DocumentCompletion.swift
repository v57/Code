#if os(macOS)
  import AppKit
  import CodeAutocompletion
  import CodeEditor
  import CodeLSP
  import CodeWorkspace

  /// Completions for a workspace document: from its language server when
  /// one is running and completes code, else the file's words and the
  /// language's keywords.
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

    var triggerCharacters: Set<String> {
      guard let (servers, url) = server else { return words.triggerCharacters }
      let characters = servers.completionTriggerCharacters(url)
      return characters.isEmpty ? ["."] : characters
    }

    func completions(for context: CompletionContext) async -> CompletionList? {
      guard let (servers, url) = server, let textView else {
        return await words.completions(for: context)
      }
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
