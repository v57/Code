#if canImport(AppKit)
  import AppKit
  import CodeEditor
  import CodeHighlighting

  /// Code completion for one editor, as in Xcode: the list opens while
  /// typing an identifier or after a trigger character ("."), and with Esc
  /// or ⌃Space; it narrows as you type, ↑ ↓ choose, Return or Tab insert
  /// (arguments become placeholders), Esc closes it.
  ///
  /// Typing never waits for the provider: answers arrive in the background
  /// and are filtered with what was typed since. A provider whose list is
  /// incomplete is asked again as the word grows.
  @MainActor public final class CompletionController {
    public private(set) weak var textView: CodeTextView?
    public var provider: any CompletionProvider
    /// Off: the list opens only for Esc and ⌃Space (Xcode's "Suggest
    /// completions while typing").
    public var suggestsWhileTyping = true
    /// Called when an item is inserted.
    public var onAccept: ((CompletionItem) -> Void)?

    /// Whether the list is on screen.
    public var isShowing: Bool { window.isVisible }
    /// The rows shown, best first.
    public var shownItems: [CompletionItem] { window.isVisible ? window.rows.map(\.item) : [] }

    private let window = CompletionWindow()
    private var session: Session?
    private var generation = 0
    private var requestTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private struct Session {
      /// Where the word being completed starts.
      var start: Int
      var trigger: CompletionContext.Trigger
      var items: [CompletionItem] = []
      var isIncomplete = false
      var hasResults = false
      /// The caret when the items were asked for: their ranges are in the
      /// text as it was then.
      var requestLocation: Int
    }

    public init(textView: CodeTextView, provider: any CompletionProvider) {
      self.textView = textView
      self.provider = provider
      window.onAccept = { [weak self] row in self?.accept(row: row) }
      window.onSelect = { [weak self] row in self?.resolveSelection(row) }
      textView.commandHandler = { [weak self] selector in self?.handle(selector) ?? false }
      textView.onTyping = { [weak self] typed in self?.typed(typed) }
      textView.onCompletionRequest = { [weak self] in self?.toggle() }
      textView.onFocusLoss = { [weak self] in self?.dismiss() }
      let center = NotificationCenter.default
      observers.append(
        center.addObserver(
          forName: NSTextView.didChangeSelectionNotification, object: textView, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.selectionChanged() } })
      observers.append(
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) {
          [weak self] note in
          let window = ObjectIdentifier(note.object as AnyObject)
          MainActor.assumeIsolated {
            guard let self, let own = self.textView?.window, ObjectIdentifier(own) == window else {
              return
            }
            self.dismiss()
          }
        })
      if let clip = textView.enclosingScrollView?.contentView {
        observers.append(
          center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
          ) { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } })
      }
    }

    isolated deinit {
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
      window.orderOut(nil)
    }

    // MARK: - Opening and closing

    /// Shows completions for the word at the caret (Esc, ⌃Space), or closes
    /// the list when it is open.
    public func toggle() {
      if isShowing { return dismiss() }
      show(trigger: .invoked)
    }

    /// Asks for completions at the caret and shows them when there are any.
    public func show(trigger: CompletionContext.Trigger = .invoked) {
      guard let textView, let text = textView.textStorage?.mutableString else { return }
      let caret = textView.selectedRange()
      guard caret.length == 0 else { return }
      dismiss()
      let start: Int
      if case .character = trigger {
        start = caret.location
      } else {
        start = Identifier.range(endingAt: caret.location, in: text).location
      }
      session = Session(start: start, trigger: trigger, requestLocation: caret.location)
      request(trigger)
    }

    public func dismiss() {
      generation += 1
      session = nil
      requestTask?.cancel()
      resolveTask?.cancel()
      hideWindow()
    }

    private func hideWindow() {
      guard window.isVisible else { return }
      window.parent?.removeChildWindow(window)
      window.orderOut(nil)
    }

    // MARK: - Typing

    private func typed(_ typed: String?) {
      guard let textView, let text = textView.textStorage?.mutableString else { return }
      let caret = textView.selectedRange()
      guard caret.length == 0 else { return dismiss() }
      guard let typed else {
        // Backspace: narrow less, or close once the word is gone.
        guard let session else { return }
        if caret.location < session.start
          || (caret.location == session.start && session.trigger == .typing)
        {
          dismiss()
        } else {
          refilter()
          requestIfIncomplete()
        }
        return
      }
      let units = typed as NSString
      if units.length == 1, Identifier.contains(units.character(at: 0)) {
        if session != nil {
          refilter()
          requestIfIncomplete()
          return
        }
        guard suggestsWhileTyping, !isInCommentOrString(caret.location - 1) else { return }
        let word = Identifier.range(endingAt: caret.location, in: text)
        guard word.length > 0, !Identifier.isDigit(text.character(at: word.location)) else {
          return
        }
        show(trigger: .typing)
      } else if suggestsWhileTyping, provider.triggerCharacters.contains(typed) {
        show(trigger: .character(typed))
      } else {
        dismiss()
      }
    }

    /// The caret left the word (a click, an arrow, a non-identifier typed).
    private func selectionChanged() {
      guard let session, let textView, let text = textView.textStorage?.mutableString else {
        return
      }
      let selection = textView.selectedRange()
      guard selection.length == 0, selection.location >= session.start,
        selection.location <= text.length
      else { return dismiss() }
      for i in session.start..<selection.location where !Identifier.contains(text.character(at: i))
      { return dismiss() }
    }

    private func isInCommentOrString(_ location: Int) -> Bool {
      guard let textView, location >= 0 else { return false }
      let line = textView.position(of: location).line
      return textView.tokens(ofLine: line).contains { token in
        [.comment, .prose, .string].contains(token.kind) && NSLocationInRange(location, token.range)
      }
    }

    // MARK: - Asking the provider

    private func request(_ trigger: CompletionContext.Trigger) {
      guard let textView, let text = textView.textStorage?.mutableString, let session else {
        return
      }
      requestTask?.cancel()
      let caret = textView.selectedRange().location
      let context = CompletionContext(
        text: text, location: caret,
        wordRange: NSRange(location: session.start, length: max(0, caret - session.start)),
        trigger: trigger, language: textView.spec)
      let generation = generation
      let provider = provider
      requestTask = Task { [weak self] in
        let list = await provider.completions(for: context)
        guard let self, !Task.isCancelled, self.generation == generation, var session = self.session
        else { return }
        session.items = list?.items ?? []
        session.isIncomplete = list?.isIncomplete ?? false
        session.hasResults = true
        session.requestLocation = context.location
        self.session = session
        self.refilter()
      }
    }

    /// Asks again for an incomplete list, once typing pauses briefly.
    private func requestIfIncomplete() {
      guard let session, session.hasResults, session.isIncomplete else { return }
      requestTask?.cancel()
      let generation = generation
      requestTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(60))
        guard let self, !Task.isCancelled, self.generation == generation else { return }
        self.request(.incomplete)
      }
    }

    // MARK: - The list

    private func refilter() {
      guard let session, let textView, let text = textView.textStorage?.mutableString else {
        return
      }
      let caret = textView.selectedRange().location
      guard caret >= session.start, caret <= text.length else { return dismiss() }
      guard session.hasResults else { return }
      var queries: [Int: String] = [:]
      let ranked = CompletionMatcher.rank(session.items) { item in
        let start = min(item.range?.location ?? session.start, caret)
        if let query = queries[start] { return query }
        let query = text.substring(with: NSRange(location: start, length: caret - start))
        queries[start] = query
        return query
      }
      let typed = text.substring(
        with: NSRange(location: session.start, length: caret - session.start))
      // Nothing to offer, or only what is already typed.
      if ranked.isEmpty || (ranked.count == 1 && session.items[ranked[0].index].insertText == typed)
      {
        return hideWindow()
      }
      let rows = ranked.prefix(1000).map {
        CompletionWindow.Row(item: session.items[$0.index], positions: $0.match.positions)
      }
      let preselected = typed.isEmpty ? rows.firstIndex { $0.item.isPreselected } ?? 0 : 0
      window.nameFont = .monospacedSystemFont(
        ofSize: max(10, min(textView.configuration.fontSize - 1, 16)), weight: .regular)
      window.appearance = textView.effectiveAppearance
      window.show(rows, selecting: preselected)
      reposition()
      if !window.isVisible, let parent = textView.window {
        parent.addChildWindow(window, ordered: .above)
        window.orderFront(nil)
      }
    }

    private func reposition() {
      guard let session, let textView, window.isVisible || !window.rows.isEmpty else { return }
      let anchor = textView.firstRect(
        forCharacterRange: NSRange(location: session.start, length: 0), actualRange: nil)
      // Scrolled out of view: close.
      if let window = textView.window, window.isVisible {
        let local = textView.convert(window.convertFromScreen(anchor), from: nil)
        if !textView.visibleRect.insetBy(dx: -1, dy: -1).intersects(local.insetBy(dx: 0, dy: 1)) {
          return dismiss()
        }
      }
      window.layout(under: anchor, on: textView.window?.screen)
    }

    private func handle(_ selector: Selector) -> Bool {
      guard window.isVisible else { return false }
      switch selector {
      case #selector(NSResponder.moveUp(_:)): window.moveSelection(by: -1)
      case #selector(NSResponder.moveDown(_:)): window.moveSelection(by: 1)
      case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)):
        window.moveSelection(by: -(CompletionWindow.visibleRows - 1))
      case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)):
        window.moveSelection(by: CompletionWindow.visibleRows - 1)
      case #selector(NSResponder.moveToBeginningOfDocument(_:)),
        #selector(NSResponder.scrollToBeginningOfDocument(_:)):
        window.select(0)
      case #selector(NSResponder.moveToEndOfDocument(_:)),
        #selector(NSResponder.scrollToEndOfDocument(_:)):
        window.select(window.rows.count - 1)
      case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)),
        #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
        accept(row: window.selectedRow)
      case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)): dismiss()
      default:
        // Moving the caret any other way closes the list and moves it.
        if NSStringFromSelector(selector).hasPrefix("move") { dismiss() }
        return false
      }
      return true
    }

    // MARK: - Inserting

    /// Inserts the item in `row` of the list.
    func accept(row: Int) {
      guard let session, let textView, window.rows.indices.contains(row) else { return }
      let item = window.rows[row].item
      let caret = textView.selectedRange().location
      // The item's range is in the text as it was when it was asked for;
      // what was typed since lies between then and the caret.
      var start = session.start
      var end = caret
      if let range = item.range {
        start = range.location
        let delta = caret - session.requestLocation
        end =
          NSMaxRange(range) >= session.requestLocation
          ? NSMaxRange(range) + delta : NSMaxRange(range)
        end = max(end, caret)
      }
      start = min(start, caret)
      end = min(end, textView.textStorage?.length ?? end)
      let expansion = item.expansion
      dismiss()
      textView.insertCompletion(
        expansion.text, replacing: NSRange(location: start, length: end - start),
        caret: expansion.caret, additionalEdits: item.additionalEdits.map { ($0.range, $0.text) })
      onAccept?(item)
    }

    /// Fills in the selected item's documentation and edits, once the
    /// selection rests on it.
    private func resolveSelection(_ row: Int) {
      resolveTask?.cancel()
      guard window.rows.indices.contains(row), window.rows[row].item.needsResolve else { return }
      let item = window.rows[row].item
      let generation = generation
      let provider = provider
      resolveTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled, var resolved = await provider.resolve(item) else { return }
        guard let self, !Task.isCancelled, self.generation == generation,
          self.window.rows.indices.contains(row), self.window.rows[row].item.label == item.label
        else { return }
        resolved.needsResolve = false
        self.window.update(resolved, at: row)
      }
    }
  }
#endif
