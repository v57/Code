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
    private var choices: Choices?
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
      /// The user moved the selection: a later list keeps the rows down to it where they were.
      var moved = false
    }

    /// A list to pick from instead of completions (where a symbol may be defined).
    private struct Choices {
      var anchor: Int
      var selection: NSRange
      var onPick: (Int) -> Void
      var moved = false
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
      choices = nil
      requestTask?.cancel()
      resolveTask?.cancel()
      hideWindow()
    }

    private func hideWindow() {
      guard window.isVisible else { return }
      window.parent?.removeChildWindow(window)
      window.orderOut(nil)
    }

    // MARK: - Choices

    /// Whether a list of choices is on screen.
    public var isShowingChoices: Bool { choices != nil && window.isVisible }
    /// The user moved the selection in the choices shown.
    public var choicesSelectionMoved: Bool { choices?.moved ?? false }
    /// The selected choice.
    public var selectedChoice: Int { window.selectedRow }

    /// Shows a list to pick from in the completion list's window, under the word at `anchor` (the places a symbol may
    /// be defined). Return, Tab or a double click picks a row (`onPick` gets its index); Esc, typing or moving the
    /// caret closes it.
    public func showChoices(
      _ items: [CompletionItem], at anchor: Int, selecting index: Int = 0, onPick: @escaping (Int) -> Void
    ) {
      guard let textView, !items.isEmpty else { return }
      dismiss()
      choices = Choices(anchor: anchor, selection: textView.selectedRange(), onPick: onPick)
      showRows(items, selecting: index)
    }

    /// Replaces the choices shown (a slower answer arrived), keeping them open.
    public func updateChoices(_ items: [CompletionItem], selecting index: Int) {
      guard choices != nil, !items.isEmpty else { return }
      showRows(items, selecting: index)
    }

    private func showRows(_ items: [CompletionItem], selecting index: Int) {
      guard let textView else { return }
      window.nameFont = .monospacedSystemFont(
        ofSize: max(10, min(textView.configuration.fontSize - 1, 16)), weight: .regular)
      window.appearance = textView.effectiveAppearance
      window.show(items.map { CompletionWindow.Row(item: $0, positions: []) }, selecting: index)
      reposition()
      if !window.isVisible, let parent = textView.window {
        parent.addChildWindow(window, ordered: .above)
        window.orderFront(nil)
      }
    }

    // MARK: - Typing

    private func typed(_ typed: String?) {
      if choices != nil { dismiss() }
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
      if let choices {
        if textView?.selectedRange() != choices.selection { dismiss() }
        return
      }
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
      let quickShown = QuickFlag()
      requestTask = Task { [weak self] in
        let list = await provider.completions(for: context) { [weak self] quick in
          guard let self, self.generation == generation else { return }
          quickShown.value = true
          self.apply(quick, requestedAt: context.location)
        }
        guard let self, !Task.isCancelled, self.generation == generation else { return }
        // A slower answer that failed leaves the quick list.
        if list == nil, quickShown.value { return }
        self.apply(list ?? CompletionList(items: []), requestedAt: context.location)
      }
    }

    /// Whether a quick list was shown for a request.
    private final class QuickFlag { var value = false }

    /// Takes a provider's list, the first or a better one that followed.
    private func apply(_ list: CompletionList, requestedAt location: Int) {
      guard var session else { return }
      let keeping = window.isVisible && session.moved ? keptRows() : nil
      session.items = list.items
      session.isIncomplete = list.isIncomplete
      session.hasResults = true
      session.requestLocation = location
      self.session = session
      refilter(keeping: keeping)
      // Typed on while it was asked: an incomplete list may lack what fits the word now.
      if list.isIncomplete, let caret = textView?.selectedRange().location, caret != location {
        requestIfIncomplete()
      }
    }

    /// The rows down to the selection, which a list that arrives later leaves in place.
    private func keptRows() -> (keys: [String], selected: Int) {
      let selected = window.selectedRow
      guard selected >= 0 else { return ([], 0) }
      return (window.rows.prefix(selected + 1).map { Self.key($0.item) }, selected)
    }

    private static func key(_ item: CompletionItem) -> String { item.label + "\u{1}" + item.insertText }

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

    private func refilter(keeping: (keys: [String], selected: Int)? = nil) {
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
      var rows = ranked.prefix(1000).map {
        CompletionWindow.Row(item: session.items[$0.index], positions: $0.match.positions)
      }
      var preselected = typed.isEmpty ? rows.firstIndex { $0.item.isPreselected } ?? 0 : 0
      if let keeping, !keeping.keys.isEmpty {
        // Never move what the user already went past: those rows first, as they were, then the rest.
        var byKey: [String: Int] = [:]
        for (index, row) in rows.enumerated() where byKey[Self.key(row.item)] == nil { byKey[Self.key(row.item)] = index }
        let kept = keeping.keys.compactMap { byKey[$0] }
        let keptSet = Set(kept)
        rows = kept.map { rows[$0] } + rows.indices.filter { !keptSet.contains($0) }.map { rows[$0] }
        let selectedKey = keeping.keys[keeping.selected]
        preselected = rows.firstIndex { Self.key($0.item) == selectedKey } ?? min(keeping.selected, rows.count - 1)
      }
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
      guard let start = session?.start ?? choices?.anchor, let textView, window.isVisible || !window.rows.isEmpty
      else { return }
      let anchor = textView.firstRect(
        forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
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
      let moves: Set<Selector> = [
        #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)), #selector(NSResponder.pageUp(_:)),
        #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageDown(_:)),
        #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.moveToBeginningOfDocument(_:)),
        #selector(NSResponder.scrollToBeginningOfDocument(_:)), #selector(NSResponder.moveToEndOfDocument(_:)),
        #selector(NSResponder.scrollToEndOfDocument(_:)),
      ]
      if moves.contains(selector) {
        session?.moved = true
        choices?.moved = true
      }
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
      if let choices {
        guard window.rows.indices.contains(row) else { return }
        dismiss()
        choices.onPick(row)
        return
      }
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
