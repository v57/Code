#if canImport(UIKit) && !canImport(AppKit)
  import CodeHighlighting
  import UIKit

  /// The code editor's text view on iPhone and iPad: TextKit 2, plain text in one font, with incremental syntax
  /// coloring, auto-indent and Tab to the next tab stop.
  ///
  /// As on the Mac, coloring never touches the text storage. The highlighter's tokens become the layout manager's
  /// rendering attributes as each layout fragment is laid out (`renderingAttributesValidator`), so only text that is
  /// shown is ever colored, an edit costs a rescan of the touched lines plus recoloring them where they are in view,
  /// and undo never sees colors. Line numbers and the Mac's other edit assists aren't here yet.
  @MainActor public final class CodeTextView: UITextView, NSTextStorageDelegate, UITextViewDelegate {
    /// Lines rescanned past the edited ones while an edit is made; the rest follows in batches.
    static let rescanBudget = 200
    /// The time a batch of a rescan, or of an opened file's scan, may take per run-loop turn.
    static let rescanBatchTime: CFTimeInterval = 0.002
    /// Lines scanned when a file opens, so the text in view never shows uncolored.
    static let openingScanLines = 150
    /// A longer text finishes its opening scan off the main thread, which would otherwise be busy with it for long
    /// enough to drop frames while scrolling.
    static let synchronousScanLimit = 100_000

    public private(set) var lineIndex: LineIndex
    public private(set) var spec: LanguageSpec?
    public var configuration: EditorConfiguration {
      didSet { if configuration != oldValue { applyConfiguration() } }
    }
    /// Called after every edit made in the editor (typing, paste, undo), not for text set with `replaceAllText(_:)`.
    public var onEdit: (() -> Void)?
    public var onSelectionChange: ((EditorSelection) -> Void)?
    /// The text as the editor shows it.
    public var string: String { textStorage.string }

    /// "\n", or "\r\n" for files that use it; new lines match the file.
    private(set) var lineEnding = "\n"
    private let contentStorage: NSTextContentStorage
    private var highlighter: SyntaxHighlighter?
    private var highlightsSyntax: Bool
    private var scanGeneration = 0
    private var scanTask: Task<Void, Never>?
    private var continueTask: Task<Void, Never>?
    /// Text whose colors changed, recolored once the edit settles.
    private var dirtyRange: NSRange?
    private var isFlushScheduled = false
    private var isApplyingExternalText = false
    /// An edit was made in the editor since `onEdit` was last called.
    private var hasUnreportedEdit = false
    private var colors: [SyntaxKind: UIColor] = [:]
    private var plainColor = UIColor.label
    private var baseFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var lineSpacing: CGFloat = 0
    private var spaceWidth: CGFloat = 8

    public init(text: String, spec: LanguageSpec?, highlightsSyntax: Bool, configuration: EditorConfiguration) {
      self.spec = spec
      self.highlightsSyntax = highlightsSyntax
      self.configuration = configuration
      lineIndex = LineIndex(text)
      contentStorage = NSTextContentStorage()
      let layoutManager = NSTextLayoutManager()
      contentStorage.addTextLayoutManager(layoutManager)
      let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
      container.widthTracksTextView = true
      layoutManager.textContainer = container
      // A container with a text layout manager makes the view TextKit 2 (never touch `layoutManager`, which would
      // switch it to TextKit 1).
      super.init(frame: .zero, textContainer: container)
      configure()
      resolveTheme()
      lineEnding = Self.detectLineEnding(text as NSString)
      textStorage.setAttributedString(NSAttributedString(string: text, attributes: baseAttributes))
      textStorage.delegate = self
      delegate = self
      layoutManager.renderingAttributesValidator = { [weak self] _, fragment in
        guard Thread.isMainThread else { return }
        nonisolated(unsafe) let fragment = fragment
        MainActor.assumeIsolated { self?.color(fragment) }
      }
      registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: CodeTextView, _: UITraitCollection) in
        view.applyConfiguration()
      }
      startFullScan()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
      autocorrectionType = .no
      autocapitalizationType = .none
      spellCheckingType = .no
      smartQuotesType = .no
      smartDashesType = .no
      smartInsertDeleteType = .no
      inlinePredictionType = .no
      if #available(iOS 18.0, *) { writingToolsBehavior = .none }
      dataDetectorTypes = []
      allowsEditingTextAttributes = false
      isFindInteractionEnabled = true
      alwaysBounceVertical = true
      keyboardDismissMode = .interactive
      textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
      textContainer.lineFragmentPadding = 4
      isEditable = configuration.isEditable
    }

    // MARK: - Configuration and theme

    private var paragraphStyle: NSParagraphStyle {
      let style = NSMutableParagraphStyle()
      style.tabStops = []
      style.defaultTabInterval = spaceWidth * CGFloat(max(1, configuration.tabWidth))
      style.lineSpacing = lineSpacing
      return style
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
      [.font: baseFont, .paragraphStyle: paragraphStyle, .foregroundColor: plainColor]
    }

    /// The theme for the current appearance: colors, the font and the line spacing. Every kind uses the plain
    /// text's font (rendering attributes can't change fonts, so a theme's bold keywords stay regular here).
    private func resolveTheme() {
      let theme = configuration.theme(isDark: traitCollection.userInterfaceStyle == .dark)
      let syntax = theme.syntax
      let kinds: [SyntaxKind] = [
        .comment, .prose, .keyword, .string, .number, .link, .preprocessor, .attribute, .typeDeclaration,
        .memberDeclaration, .projectType, .projectMember, .otherType, .otherMember,
      ]
      colors = Dictionary(uniqueKeysWithValues: kinds.map { ($0, UIColor(hex: syntax.color(for: $0))) })
      plainColor = UIColor(hex: syntax.plainText)
      backgroundColor = configuration.drawsBackground ? UIColor(hex: theme.background) : .clear
      tintColor = UIColor(hex: theme.cursor)
      let size = configuration.fontSize
      if let name = configuration.fontName {
        baseFont = UIFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
      } else {
        baseFont = theme.fonts[.plainText].map { Self.font(named: $0, size: size) }
          ?? .monospacedSystemFont(ofSize: size, weight: .regular)
      }
      lineSpacing = ceil(baseFont.lineHeight * CGFloat(theme.lineSpacing)) - baseFont.lineHeight
      spaceWidth = (" " as NSString).size(withAttributes: [.font: baseFont]).width
    }

    /// A theme font name at `size`: SF Mono names map to the system monospaced font (SF Mono isn't installed under its
    /// own name), other names are looked up as given.
    static func font(named name: String, size: CGFloat) -> UIFont {
      if name.hasPrefix("SFMono-") {
        let weights: [String: UIFont.Weight] = [
          "Light": .light, "Regular": .regular, "Medium": .medium, "Semibold": .semibold, "Bold": .bold,
          "Heavy": .heavy,
        ]
        let style = String(name.dropFirst("SFMono-".count))
        let weight = weights.first { style.hasPrefix($0.key) }?.value ?? .regular
        return .monospacedSystemFont(ofSize: size, weight: weight)
      }
      return UIFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Applies the configuration and the theme for the current appearance. The text's attributes are set again only
    /// when they changed.
    private func applyConfiguration() {
      isEditable = configuration.isEditable
      let old = (baseFont, plainColor, lineSpacing, spaceWidth)
      resolveTheme()
      typingAttributes = baseAttributes
      if old != (baseFont, plainColor, lineSpacing, spaceWidth), textStorage.length > 0 {
        textStorage.setAttributes(baseAttributes, range: NSRange(location: 0, length: textStorage.length))
      }
      invalidateAllColors()
    }

    // MARK: - Language and text

    /// Switches highlighting to `spec` (after a rename, or once a "#!" line decided the language).
    public func setLanguage(_ spec: LanguageSpec?, highlightsSyntax: Bool) {
      guard spec?.name != self.spec?.name || highlightsSyntax != self.highlightsSyntax else { return }
      self.spec = spec
      self.highlightsSyntax = highlightsSyntax
      startFullScan()
    }

    /// Replaces the whole text (the file changed on the host) as one undoable change, keeping the caret where it
    /// was as far as possible.
    public func replaceAllText(_ newText: String) {
      guard newText != textStorage.string, let full = textRange(from: beginningOfDocument, to: endOfDocument)
      else { return }
      let selection = selectedRange
      isApplyingExternalText = true
      replace(full, withText: newText)
      isApplyingExternalText = false
      lineEnding = Self.detectLineEnding(textStorage.mutableString)
      selectedRange = NSRange(location: min(selection.location, textStorage.length), length: 0)
    }

    private static func detectLineEnding(_ text: NSString) -> String {
      let newline = text.range(of: "\n")
      guard newline.location != NSNotFound, newline.location > 0 else { return "\n" }
      return text.character(at: newline.location - 1) == 0x0D ? "\r\n" : "\n"
    }

    // MARK: - Highlighting

    public nonisolated func textStorage(
      _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
      range editedRange: NSRange, changeInLength delta: Int
    ) {
      guard editedMask.contains(.editedCharacters) else { return }
      MainActor.assumeIsolated { storageEdited(range: editedRange, delta: delta) }
    }

    /// Brings the line index and highlighter up to date with an edit. Runs inside the storage's edit callback, so it
    /// only reads the text and records what to recolor; that happens once the edit settles.
    private func storageEdited(range editedRange: NSRange, delta: Int) {
      let text = textStorage.mutableString
      let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
      _ = lineIndex.apply(edit: oldRange, replacementLength: editedRange.length, in: text)
      dirtyRange = dirtyRange.map { Self.shifted($0, forEditAt: oldRange, newLength: editedRange.length) }
      if !isApplyingExternalText { hasUnreportedEdit = true }
      if scanTask != nil {
        // The opening scan off the main thread scanned older text: the lines it didn't reach yet are finished here
        // instead, a batch at a time.
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
      }
      if highlighter != nil {
        let lines = highlighter!.edit(
          range: oldRange, replacementLength: editedRange.length, in: text, budget: Self.rescanBudget)
        markDirty(lines: lines)
        if highlighter?.pending.isEmpty == false { scheduleContinue() }
      }
      scheduleFlush()
    }

    private func startFullScan() {
      scanTask?.cancel()
      scanTask = nil
      continueTask?.cancel()
      continueTask = nil
      scanGeneration += 1
      guard highlightsSyntax, let spec else {
        highlighter = nil
        invalidateAllColors()
        return
      }
      let text = textStorage.mutableString
      highlighter = SyntaxHighlighter(text: text, spec: spec, scanningLines: Self.openingScanLines)
      invalidateAllColors()
      guard highlighter?.pending.isEmpty == false else { return }
      if text.length <= Self.synchronousScanLimit {
        scheduleContinue()
        return
      }
      let generation = scanGeneration
      let snapshot = textStorage.string
      scanTask = Task { [weak self] in
        let result = await Task.detached(priority: .userInitiated) {
          SyntaxHighlighter(text: snapshot as NSString, spec: spec)
        }.value
        guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
        self.scanTask = nil
        self.highlighter = result
        self.invalidateAllColors()
      }
    }

    /// Finishes a rescan that stopped at the budget (or an opened file's scan), a batch of `rescanBatchTime` per
    /// run-loop turn so typing and scrolling stay smooth.
    private func scheduleContinue() {
      guard continueTask == nil else { return }
      continueTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(1))
          guard !Task.isCancelled, let self, self.highlighter?.pending.isEmpty == false else { break }
          let text = self.textStorage.mutableString
          let began = CACurrentMediaTime()
          while CACurrentMediaTime() - began < Self.rescanBatchTime,
            let lines = self.highlighter?.continuePending(in: text, budget: 50)
          {
            self.markDirty(lines: lines)
          }
          self.flushDirty()
        }
        self?.continueTask = nil
      }
    }

    private func markDirty(lines: Range<Int>) {
      guard !lines.isEmpty else { return }
      let start = lineIndex.starts[lines.lowerBound]
      let end = NSMaxRange(lineIndex.range(ofLine: lines.upperBound - 1))
      let range = NSRange(location: start, length: end - start)
      dirtyRange = dirtyRange.map { NSUnionRange($0, range) } ?? range
    }

    private static func shifted(_ range: NSRange, forEditAt oldRange: NSRange, newLength: Int) -> NSRange {
      var dirty = range
      let delta = newLength - oldRange.length
      if NSMaxRange(oldRange) <= dirty.location {
        dirty.location += delta
      } else if oldRange.location < NSMaxRange(dirty) {
        let start = min(dirty.location, oldRange.location)
        let end = max(NSMaxRange(dirty) + delta, oldRange.location + newLength)
        dirty = NSRange(location: start, length: max(0, end - start))
      }
      return dirty
    }

    private func scheduleFlush() {
      guard !isFlushScheduled else { return }
      isFlushScheduled = true
      DispatchQueue.main.async { [weak self] in self?.flushDirty() }
    }

    /// Recolors text whose tokens changed and reports edits, once the edit settled (TextKit has processed it).
    private func flushDirty() {
      isFlushScheduled = false
      if let dirty = dirtyRange {
        dirtyRange = nil
        let range = NSIntersectionRange(dirty, NSRange(location: 0, length: textStorage.length))
        if range.length > 0 { recolor(range) }
      }
      if hasUnreportedEdit {
        hasUnreportedEdit = false
        onEdit?()
      }
    }

    /// The document's start and the viewport's range in it, when laid out.
    private var viewport: (start: NSTextLocation, range: NSRange)? {
      guard let layoutManager = textLayoutManager,
        let range = layoutManager.textViewportLayoutController.viewportRange
      else { return nil }
      let documentStart = contentStorage.documentRange.location
      let start = contentStorage.offset(from: documentStart, to: range.location)
      let end = contentStorage.offset(from: documentStart, to: range.endLocation)
      return (range.location, NSRange(location: start, length: max(0, end - start)))
    }

    /// Colors `range` where it is in view now; the rest is colored by the validator when it is laid out.
    private func recolor(_ range: NSRange) {
      guard let layoutManager = textLayoutManager else { return }
      if let outside = textRange(range, from: contentStorage.documentRange.location, at: 0) {
        layoutManager.invalidateRenderingAttributes(for: outside)
      }
      guard let viewport else { return }
      let shown = NSIntersectionRange(range, viewport.range)
      if shown.length > 0 { applyColors(in: shown, anchor: viewport.start, at: viewport.range.location) }
    }

    /// Colors the whole text again (a new scan, the theme changed).
    private func invalidateAllColors() {
      recolor(NSRange(location: 0, length: textStorage.length))
    }

    /// The rendering-attributes validator: colors a fragment as it is laid out.
    private func color(_ fragment: NSTextLayoutFragment) {
      let range = fragment.rangeInElement
      let documentStart = contentStorage.documentRange.location
      let start = contentStorage.offset(from: documentStart, to: range.location)
      let length = contentStorage.offset(from: range.location, to: range.endLocation)
      applyColors(in: NSRange(location: start, length: length), anchor: range.location, at: start)
    }

    /// Sets the tokens' colors on the characters in `range` as rendering attributes. `anchor` is a text location at
    /// character `offset`, near `range`: locations are counted from it rather than from the document's start.
    private func applyColors(in range: NSRange, anchor: NSTextLocation, at offset: Int) {
      guard let layoutManager = textLayoutManager, range.length > 0,
        let whole = textRange(range, from: anchor, at: offset)
      else { return }
      layoutManager.removeRenderingAttribute(.foregroundColor, for: whole)
      guard let highlighter, highlighter.lines.length == textStorage.length, NSMaxRange(range) <= textStorage.length
      else { return }
      let first = highlighter.lines.line(containing: range.location)
      let last = highlighter.lines.line(containing: NSMaxRange(range) - 1)
      for line in first...last {
        // Later tokens win (a link inside a comment): each one's color replaces what is under it.
        for token in highlighter.tokens(ofLine: line) {
          let clipped = NSIntersectionRange(token.range, range)
          guard clipped.length > 0, let color = colors[token.kind],
            let tokenRange = textRange(clipped, from: anchor, at: offset)
          else { continue }
          layoutManager.setRenderingAttributes([.foregroundColor: color], for: tokenRange)
        }
      }
    }

    private func textRange(_ range: NSRange, from anchor: NSTextLocation, at offset: Int) -> NSTextRange? {
      guard let start = contentStorage.location(anchor, offsetBy: range.location - offset),
        let end = contentStorage.location(start, offsetBy: range.length)
      else { return nil }
      return NSTextRange(location: start, end: end)
    }

    // MARK: - Selection

    public nonisolated func textViewDidChangeSelection(_ textView: UITextView) {
      MainActor.assumeIsolated {
        guard let onSelectionChange else { return }
        onSelectionChange(currentSelection)
      }
    }

    /// Where the caret is, lines and columns from 1.
    public var currentSelection: EditorSelection {
      let range = selectedRange
      let line = lineIndex.line(containing: range.location)
      let lastLine = lineIndex.line(containing: max(range.location, NSMaxRange(range) - 1))
      return EditorSelection(
        line: line + 1, column: range.location - lineIndex.starts[line] + 1, length: range.length,
        lineCount: lastLine - line + 1)
    }

    // MARK: - Typing

    /// Return keeps the line's indentation and the file's line ending; Tab inserts spaces up to the next tab stop
    /// when the configuration says so.
    public override func insertText(_ text: String) {
      let storage = textStorage.mutableString
      if text == "\n" {
        let location = min(selectedRange.location, storage.length)
        let lineStart = storage.lineRange(for: NSRange(location: location, length: 0)).location
        var end = lineStart
        while end < location, storage.character(at: end) == 0x20 || storage.character(at: end) == 0x09 { end += 1 }
        let indent = storage.substring(with: NSRange(location: lineStart, length: end - lineStart))
        super.insertText(lineEnding + indent)
        return
      }
      if text == "\t", configuration.insertSpaces {
        let location = min(selectedRange.location, storage.length)
        let lineStart = storage.lineRange(for: NSRange(location: location, length: 0)).location
        var column = 0
        for index in lineStart..<location {
          column += storage.character(at: index) == 0x09 ? configuration.tabWidth - column % configuration.tabWidth : 1
        }
        let width = max(1, configuration.tabWidth)
        super.insertText(String(repeating: " ", count: width - column % width))
        return
      }
      super.insertText(text)
    }
  }

  extension UIColor {
    fileprivate convenience init(hex: UInt32) {
      self.init(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
  }
#endif
