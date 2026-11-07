#if os(macOS)
  import AppKit
  import CodeEditor
  import CodeLSP
  import CodeWorkspace
  import Observation

  /// The symbol menu while it's up: what it shows (rebuilt as the tiers answer), the highlighted row, and what its rows
  /// and keys do. The app draws it (`ProjectServices.symbolMenuPresenter`); the editor gives it the keys.
  @MainActor @Observable public final class SymbolMenu {
    public private(set) var content: SymbolMenuContent
    /// The highlighted row's id: the first row until the pointer or a key picks another.
    public var highlighted: String? {
      didSet {
        guard highlighted != oldValue, content.hasSeveralPlaces else { return }
        // Inside follows the highlighted definition.
        if let definition = content.rows.first(where: { $0.id == highlighted })?.definition, definition != focus {
          focus = definition
          rebuild()
        }
      }
    }
    /// The file's language, to color the declaration as the editor does.
    public let language: String
    public let theme: EditorTheme
    /// The declaration's font size: the editor's.
    public let fontSize: CGFloat
    /// Opened by a ⌘-click that found several places (else by ⌘ held over the symbol).
    public let isFromClick: Bool

    @ObservationIgnored var answers: [DefinitionTier: SymbolAnswer] = [:]
    @ObservationIgnored var pendingServer: String?
    @ObservationIgnored var references: Int?
    @ObservationIgnored private var focus: Int?
    @ObservationIgnored let file: URL
    @ObservationIgnored let root: URL
    /// Opens a place: in a new tab, or (false) as a jump does.
    @ObservationIgnored var openPlace: (DefinitionPlace, Bool) -> Void = { _, _ in }
    @ObservationIgnored var findReferences: (String) -> Void = { _ in }
    @ObservationIgnored var closeMenu: () -> Void = {}

    init(content: SymbolMenuContent, language: String, theme: EditorTheme, fontSize: CGFloat, isFromClick: Bool, file: URL, root: URL) {
      self.content = content
      self.language = language
      self.theme = theme
      self.fontSize = fontSize
      self.isFromClick = isFromClick
      self.file = file
      self.root = root
    }

    /// Builds the content again from the answers so far; false when there's nothing to show.
    @discardableResult
    func rebuild() -> Bool {
      guard
        let made = SymbolMenuContent.make(
          Array(answers.values), pendingServer: pendingServer, references: references, file: file, root: root,
          highlighted: focus)
      else { return false }
      if made != content { content = made }
      if highlighted.map({ id in !made.rows.contains { $0.id == id } }) ?? true {
        highlighted = made.rows.first(where: \.isEnabled)?.id
      }
      return true
    }

    // MARK: Keys and picks

    /// ↑ ↓: the next enabled row, wrapping.
    public func move(by step: Int) {
      let rows = content.rows.filter(\.isEnabled)
      guard !rows.isEmpty else { return }
      if let highlighted, let index = rows.firstIndex(where: { $0.id == highlighted }) {
        self.highlighted = rows[(index + step + rows.count) % rows.count].id
      } else {
        highlighted = (step > 0 ? rows.first : rows.last)?.id
      }
    }

    /// ↩ (⌥↩: in a new tab): the highlighted row, else the first.
    public func activate(newTab: Bool = false) {
      let row = content.rows.first { $0.id == highlighted } ?? content.rows.first(where: \.isEnabled)
      if let row { pick(row, newTab: newTab) }
    }

    public func pick(_ row: SymbolMenuContent.Row, newTab: Bool = false) {
      switch row.action {
      case .none: return
      case .open(let place): openPlace(place, newTab)
      case .findReferences(let name): findReferences(name)
      case .copy(let text):
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
      }
      close()
    }

    /// ⌘↑: the nearest parent.
    public func jumpToParent() {
      guard let parent = content.parents.first(where: { $0.place != nil }) else { return NSSound.beep() }
      open(parent)
    }

    /// A part of the path on top.
    public func open(_ part: SymbolInfo, newTab: Bool = false) {
      guard let place = part.place else { return }
      openPlace(place, newTab)
      close()
    }

    public func close() { closeMenu() }

    /// The editor's key commands while the menu is up; true when the menu took it.
    func handle(_ selector: Selector) -> Bool {
      switch selector {
      case #selector(NSResponder.moveUp(_:)): move(by: -1)
      case #selector(NSResponder.moveDown(_:)): move(by: 1)
      case #selector(NSResponder.insertNewline(_:)): activate()
      case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): activate(newTab: true)
      case #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.scrollToBeginningOfDocument(_:)):
        jumpToParent()
      case #selector(NSResponder.cancelOperation(_:)): close()
      default: return false
      }
      return true
    }

    /// The menu as text, for Debug automation's dump.
    public var summary: String {
      var lines = ["path: " + content.path.map { "\($0.kind.rawValue):\($0.name)" }.joined(separator: " > ")]
      lines.append("declaration: \(content.declaration ?? "-")")
      if let summary = content.summary { lines.append("summary: \(summary)") }
      for row in content.rows {
        var line = (row.id == highlighted ? "> " : "  ") + row.title
        if let detail = row.detail { line += " (\(detail))" }
        if let trail = row.trail { line += " [\(trail)]" }
        if row.isGuess { line += " GUESS" }
        lines.append(line)
      }
      if let row = content.rows.first(where: { $0.id == highlighted }) { lines.append("preview: \(row.preview)") }
      if let footer = content.footer { lines.append("footer: \(footer)") }
      return lines.joined(separator: "\n")
    }
  }

  extension ProjectServices {
    /// ⌘ held over a symbol (or a ⌘-click that found several places): the symbol menu under it, from Code's scanner
    /// and the Swift model at once, then the language server's answer replacing theirs in place.
    public func showSymbolMenu(in document: TextDocument, at location: Int, range: NSRange, fromClick: Bool = false) {
      guard let textView = document.textView, symbolMenuPresenter != nil else { return }
      symbolMenuLookup?.cancel()
      let url = document.url
      let position = textView.position(of: location)
      let text = textView.string
      let tiers = tiers
      let servers = languageServers
      let useModel = settings.usesSwiftModel && CodeTiers.isSwift(url)
      let useScanner = settings.usesScanner
      let serverOpen = languageServers.isOpen(url)
      let serverMode = serverOpen ? settings.serverDefinitions : .off
      let serverName = languageServers.configuration(for: url)?.id ?? "The language server"
      let lspPosition = LSPPosition(line: position.line, character: position.column)
      let line = position.line
      let column = position.column
      let menu = SymbolMenu(
        content: SymbolMenuContent(path: [], rows: [], hasSeveralPlaces: false, parents: []),
        language: document.language?.name ?? url.pathExtension, theme: textView.theme,
        fontSize: textView.font?.pointSize ?? 12, isFromClick: fromClick, file: url, root: workspace.root)
      menu.openPlace = { [weak self] place, newTab in
        self?.open(place.url, line: place.line + 1, column: place.column + 1, preview: !newTab)
      }
      menu.findReferences = { [weak self] name in self?.findReferences?(name) }
      menu.closeMenu = { [weak self, weak textView] in
        self?.hideSymbolMenu()
        textView?.closeCommandHover()
      }
      var shown = false
      symbolMenuLookup = Task { [weak self, weak textView] in
        enum Event: Sendable {
          case answer(DefinitionTier, SymbolAnswer?)
          case references(Int?)
          case finished
          case typeFound(SymbolInfo)
          /// Long enough waiting for the Swift model: show what there is.
          case deadline
        }
        let (events, continuation) = AsyncStream<Event>.makeStream()
        var running = 0
        @MainActor func run(_ work: @escaping @Sendable () async -> Event?) {
          running += 1
          Task.detached(priority: .userInitiated) {
            if let event = await work() { continuation.yield(event) }
            continuation.yield(.finished)
          }
        }
        // Each job ends with `finished`; the server's answer is tracked by `serverPending`.
        var serverPending = false
        @MainActor func askServer() {
          guard !serverPending, serverMode != .off else { return }
          serverPending = true
          menu.pendingServer = serverName
          run {
            let locations = await servers.locations(url: url, position: lspPosition)
            var symbols: [SymbolDescription] = []
            for location in locations.prefix(30) {
              let place = DefinitionPlace(
                url: location.url, line: location.range.start.line, column: location.range.start.character, name: "",
                preview: ProjectServices.preview(of: location.url, line: location.range.start.line))
              if var described = await tiers.describe(place, useModel: useModel, useScanner: useScanner) {
                described.symbol.place = described.symbol.place ?? place
                symbols.append(described)
              } else {
                symbols.append(
                  SymbolDescription(
                    symbol: SymbolInfo(kind: .other, name: place.preview ?? "", place: place),
                    declaration: place.preview))
              }
            }
            return .answer(.server, locations.isEmpty ? nil : SymbolAnswer(tier: .server, isSure: true, symbols: symbols))
          }
        }
        if useScanner {
          run { .answer(.scanner, await tiers.scannerSymbols(url: url, text: text, line: line, column: column)) }
        }
        if useModel {
          run { .answer(.model, await tiers.modelSymbols(url: url, text: text, line: line, column: column, countReferences: false).answer) }
          // Counting reads every file with the name: after the answer, in the model's queue.
          run { .references(await tiers.modelSymbols(url: url, text: text, line: line, column: column, countReferences: true).references) }
        }
        if serverMode == .always || (serverMode == .whenUnsure && !useModel) { askServer() }
        if !useModel, serverOpen {
          run { .references(await servers.locations("textDocument/references", url: url, position: lspPosition).count) }
        }
        if running == 0 { continuation.finish() }
        // The scanner answers first, the model a few milliseconds later: the menu waits a moment for the model, so
        // it doesn't open with the scanner's guesses only to change.
        var modelAnswered = !useModel
        let deadline = Task {
          try? await Task.sleep(for: .milliseconds(150))
          continuation.yield(.deadline)
        }
        defer {
          deadline.cancel()
          continuation.finish()
        }
        var deadlinePassed = false
        var askedType = false
        for await event in events {
          guard let self, !Task.isCancelled else { return }
          switch event {
          case .answer(let tier, let answer):
            if let answer, !answer.symbols.isEmpty { menu.answers[tier] = answer }
            if tier == .server {
              serverPending = false
              menu.pendingServer = nil
            }
            if tier == .model { modelAnswered = true }
            // The model wasn't sure: now the server, when it's asked only then.
            if tier == .model, serverMode == .whenUnsure, answer?.isSure != true { askServer() }
          case .references(let count):
            if let count, count > 0 { menu.references = count }
          case .typeFound(let type):
            for tier in Array(menu.answers.keys) {
              guard var answer = menu.answers[tier], answer.symbols.count == 1, answer.symbols[0].type == nil else { continue }
              answer.symbols[0].type = type
              menu.answers[tier] = answer
            }
          case .finished:
            running -= 1
          case .deadline:
            deadlinePassed = true
          }
          // A value with no type from the tiers: the server's type definition, once.
          if !askedType, serverMode != .off, !serverPending, running <= 1,
            let lead = SymbolMenuContent.merged(Array(menu.answers.values)).first?.description, lead.type == nil,
            lead.symbol.isValue || lead.symbol.kind == .property || lead.symbol.kind == .variable
          {
            askedType = true
            run {
              let locations = await servers.locations("textDocument/typeDefinition", url: url, position: lspPosition)
              guard let location = locations.first else { return nil }
              let place = DefinitionPlace(url: location.url, line: location.range.start.line, column: location.range.start.character, name: "")
              guard let described = await tiers.describe(place, useModel: useModel, useScanner: useScanner) else { return nil }
              return .typeFound(described.symbol)
            }
          }
          guard menu.rebuild() else {
            if running == 0 {
              if fromClick { NSSound.beep(); self.showStatus("No definition found") }
              return
            }
            continue
          }
          if !shown, modelAnswered || deadlinePassed || running == 0, let textView {
            shown = true
            self.symbolMenu = menu
            textView.pinCommandHover(range: range) { [weak menu] selector in menu?.handle(selector) ?? false }
            self.symbolMenuPresenter?(menu, textView, Self.screenRect(of: range, in: textView))
          }
          if running == 0 { return }
        }
      }
    }

    /// Takes the symbol menu away (the hover ended, a row was picked).
    public func hideSymbolMenu() {
      symbolMenuLookup?.cancel()
      symbolMenuLookup = nil
      guard symbolMenu != nil else { return }
      symbolMenu = nil
      symbolMenuPresenter?(nil, nil, .zero)
    }

    /// The range's first line on screen.
    static func screenRect(of range: NSRange, in textView: CodeTextView) -> NSRect {
      textView.firstRect(forCharacterRange: range, actualRange: nil)
    }
  }
#endif
