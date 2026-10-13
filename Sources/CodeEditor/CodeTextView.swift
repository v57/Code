#if canImport(AppKit)
  import AppKit
  import CodeHighlighting

  /// The code editor's text view: TextKit 1, plain text in one monospaced font,
  /// with incremental syntax coloring, a current-line highlight, auto-indent,
  /// block indent/outdent and comment toggling.
  ///
  /// Coloring never touches the text storage. The highlighter's tokens are
  /// handed to the layout manager at draw time (`layoutManager(_:
  /// shouldUseTemporaryAttributes:…)`), so only visible text is ever colored, an
  /// edit costs a rescan of the touched lines plus a display invalidation, and
  /// undo never sees color changes. Storage edits during an edit callback are
  /// what corrupts TextKit 1 layout (see Md's EditorTextView), and this design
  /// makes none.
  @MainActor public final class CodeTextView: NSTextView, NSTextStorageDelegate,
    NSLayoutManagerDelegate
  {
    /// Lines rescanned per run-loop turn after an edit changes the state of
    /// following lines (typing "/*" near the top of a long file).
    static let rescanBudget = 2000
    /// Smaller files are scanned synchronously when opened, so they never
    /// show uncolored; larger ones are scanned off the main thread.
    static let synchronousScanLimit = 200_000
    /// Longer texts are laid out as they come into view, with estimated
    /// heights for the rest (UTF-16 units).
    static let contiguousLayoutLimit = 500_000

    public private(set) var lineIndex: LineIndex
    public private(set) var spec: LanguageSpec?
    public private(set) var theme: EditorTheme = .githubLight
    public var configuration: EditorConfiguration {
      didSet { if configuration != oldValue { applyConfiguration(previous: oldValue) } }
    }
    /// Called after every edit made in the editor (typing, paste, undo), not
    /// for text set with `replaceAllText(_:)`.
    public var onEdit: (() -> Void)?
    public var onSelectionChange: ((EditorSelection) -> Void)?
    /// "\n", or "\r\n" for files that use it; new lines match the file.
    private(set) var lineEnding = "\n"

    var highlighter: SyntaxHighlighter?
    private var highlightsSyntax: Bool
    private var scanGeneration = 0
    private var scanTask: Task<Void, Never>?
    private var continueTask: Task<Void, Never>?
    /// Text whose colors changed and must be redrawn once the edit settles.
    private var dirtyRange: NSRange?
    private var isFlushScheduled = false
    var isApplyingExternalText = false
    /// An edit assist is changing the text itself (no assists on its edits).
    var isAssisting = false
    /// Between `shouldChangeText` and `didChangeText`: AppKit may move the
    /// selection before the storage reports the edit, so selection-driven
    /// cleanup waits for the edit to finish.
    private var isInEdit = false
    /// Closers inserted by auto-close, not typed yet: typing one steps over it
    /// (Xcode's type-over). Dropped when the caret leaves its line.
    var typeOverMarkers: [Int] = [] {
      didSet { syncTypeOverCharacters() }
    }
    /// The closer at each marker, to recognize it after an edit.
    private var typeOverCharacters: [Int: unichar] = [:]

    private func syncTypeOverCharacters() {
      guard let text = textStorage?.mutableString else { return }
      var characters: [Int: unichar] = [:]
      for marker in typeOverMarkers where marker < text.length {
        characters[marker] = typeOverCharacters[marker] ?? text.character(at: marker)
      }
      typeOverCharacters = characters
    }
    /// Lines changed since the text was loaded; ⌘S trims their trailing
    /// whitespace.
    var editedLines = IndexSet()
    /// Extra height below the last line, so it can scroll up to the top.
    private(set) var overscroll: CGFloat = 0

    // MARK: Line marks (see CodeTextView+Annotations.swift)

    /// Issues shown on their lines, as in Xcode: a tinted line and a banner
    /// with the message at its right end. Lines move with edits.
    public var annotations: [LineAnnotation] = [] {
      didSet { if annotations != oldValue { annotationsChanged() } }
    }
    /// Lines (from 0) with a breakpoint, drawn in the gutter; a click on a
    /// line number toggles one.
    public var breakpoints: Set<Int> = [] {
      didSet { if breakpoints != oldValue { rulerNeedsDisplay() } }
    }
    /// Breakpoints are drawn dimmed when deactivated.
    public var breakpointsActive = true {
      didSet { if breakpointsActive != oldValue { rulerNeedsDisplay() } }
    }
    /// Whether clicking the gutter toggles breakpoints.
    public var allowsBreakpoints = true
    /// Called when the user adds or removes a breakpoint, or edits move them.
    public var onBreakpointsChange: ((Set<Int>) -> Void)?
    /// The line the debugger stopped at (from 0), highlighted in green.
    public var executionLine: Int? {
      didSet {
        guard executionLine != oldValue else { return }
        needsDisplay = true
        rulerNeedsDisplay()
      }
    }
    /// Whether annotations show a message banner (else only the line tint).
    public var showsAnnotationMessages = true {
      didSet { if showsAnnotationMessages != oldValue { needsDisplay = true } }
    }
    /// ⌘-click at a character location (jump to definition); return true
    /// when handled.
    public var onCommandClick: ((Int) -> Bool)?
    /// Called with each edit, positioned in the text before it, for
    /// language servers.
    public var onTextChange: ((TextEdit) -> Void)?
    /// ⌥-click at a character location (Quick Help); return true when
    /// handled.
    public var onOptionClick: ((Int) -> Bool)?
    /// Called when line marks move or the text is laid out again (the
    /// minimap redraws).
    public var onLayoutChange: (() -> Void)?
    var annotationPopover: NSPopover?

    // MARK: Completion (see CodeAutocompletion)

    /// Takes key commands (`moveUp:`, `insertNewline:`, `cancelOperation:`,
    /// …) before the editor; returns true when it handled one. A completion
    /// list uses it while shown.
    public var commandHandler: ((Selector) -> Bool)?
    /// Called after an edit typed at the keyboard: the typed text, or nil
    /// for Backspace.
    public var onTyping: ((String?) -> Void)?
    /// Esc, ⌃Space or F5 (`complete:`) ask for completions; without a
    /// handler AppKit's own completion runs.
    public var onCompletionRequest: (() -> Void)?
    /// Called when the editor stops being first responder or leaves its
    /// window (a completion list closes).
    public var onFocusLoss: (() -> Void)?
    private var colors: [SyntaxKind: NSColor] = [:]
    private var plainColor = NSColor.textColor

    public init(text: String, spec: LanguageSpec?, highlightsSyntax: Bool, configuration: EditorConfiguration)
    {
      self.spec = spec
      self.highlightsSyntax = highlightsSyntax
      self.configuration = configuration
      lineIndex = LineIndex(text)
      let storage = NSTextStorage(string: text)
      let layoutManager = NSLayoutManager()
      // Non-contiguous layout estimates the height of text it hasn't laid
      // out (badly, for wrapped lines), and the text in view can shift when
      // the real height arrives. Laying out everything is exact but takes a
      // while in long files, so only those get estimates.
      layoutManager.allowsNonContiguousLayout = storage.length > Self.contiguousLayoutLimit
      storage.addLayoutManager(layoutManager)
      let container = NSTextContainer(
        size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
      layoutManager.addTextContainer(container)
      super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
      storage.delegate = self
      layoutManager.delegate = self
      lineEnding = Self.detectLineEnding(text as NSString)
      configure()
      applyConfiguration(previous: nil)
      startFullScan()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Required by NSTextView's designated-initializer chain on some SDKs.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
      spec = nil
      highlightsSyntax = false
      configuration = EditorConfiguration()
      lineIndex = LineIndex("")
      super.init(frame: frameRect, textContainer: container)
    }

    private func configure() {
      isRichText = false
      importsGraphics = false
      allowsUndo = true
      usesFindBar = true
      isIncrementalSearchingEnabled = true
      usesFontPanel = false
      allowsDocumentBackgroundColorChange = false
      isAutomaticQuoteSubstitutionEnabled = false
      isAutomaticDashSubstitutionEnabled = false
      isAutomaticTextReplacementEnabled = false
      isAutomaticSpellingCorrectionEnabled = false
      isContinuousSpellCheckingEnabled = false
      isGrammarCheckingEnabled = false
      isAutomaticLinkDetectionEnabled = false
      isAutomaticDataDetectionEnabled = false
      smartInsertDeleteEnabled = false
      if #available(macOS 15.0, *) { writingToolsBehavior = .none }
      isVerticallyResizable = true
      textContainerInset = NSSize(width: 4, height: 6)
      textContainer?.lineFragmentPadding = 4
      // Since macOS 14 views don't clip by default; the text would draw over
      // the line-number ruler when scrolled horizontally.
      clipsToBounds = true
    }

    // MARK: - Configuration and theme

    /// The font of plain text: the configured font, or the theme's.
    private(set) var baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    /// Fonts of the kinds whose font differs from `baseFont` (Xcode themes:
    /// bold keywords, proportional doc comments). Empty for single-font themes.
    private var kindFonts: [SyntaxKind: NSFont] = [:]
    /// Every line fragment's height, and the baseline within it: the text is
    /// centered vertically in the line, as in Xcode.
    private(set) var lineHeight: CGFloat = 16
    private(set) var baseline: CGFloat = 12

    /// A theme font name at `size`. SF Mono names map to the system
    /// monospaced font (SF Mono isn't installed under its own name outside
    /// Xcode), ".AppleSystemUIFont" to the system font; other names are looked
    /// up as given.
    static func font(named name: String, size: CGFloat) -> NSFont {
      if name.hasPrefix("SFMono-") {
        let weights: [String: NSFont.Weight] = [
          "Light": .light, "Regular": .regular, "Medium": .medium, "Semibold": .semibold,
          "Bold": .bold, "Heavy": .heavy,
        ]
        let style = String(name.dropFirst("SFMono-".count))
        let weight = weights.first { style.hasPrefix($0.key) }?.value ?? .regular
        return .monospacedSystemFont(ofSize: size, weight: weight)
      }
      if name.hasPrefix(".AppleSystemUIFont") {
        // Xcode 27 draws doc-comment prose a weight up from the theme's.
        return .systemFont(ofSize: size, weight: name.contains("Bold") ? .bold : .medium)
      }
      return NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private var paragraphStyle: NSParagraphStyle {
      let style = NSMutableParagraphStyle()
      style.tabStops = []
      let space = (" " as NSString).size(withAttributes: [.font: baseFont]).width
      style.defaultTabInterval = space * CGFloat(max(1, configuration.tabWidth))
      style.minimumLineHeight = lineHeight
      style.maximumLineHeight = lineHeight
      return style
    }

    private var baseAttributes: [NSAttributedString.Key: Any] {
      [.font: baseFont, .paragraphStyle: paragraphStyle, .foregroundColor: plainColor]
    }

    private func applyConfiguration(previous: EditorConfiguration?) {
      if previous?.wrapLines != configuration.wrapLines { applyWrapping() }
      if previous?.showLineNumbers != configuration.showLineNumbers {
        enclosingScrollView?.rulersVisible = configuration.showLineNumbers
      }
      applyTheme(force: previous == nil || previous?.tabWidth != configuration.tabWidth)
    }

    /// Resolves the theme for the current appearance and applies its colors,
    /// fonts and line height. Text attributes are rewritten only when the
    /// fonts or line height changed.
    private func applyTheme(force: Bool = false) {
      let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      theme = configuration.theme(isDark: isDark)
      let syntax = theme.syntax
      let kinds: [SyntaxKind] = [
        .plainText, .comment, .prose, .keyword, .string, .number, .link, .preprocessor,
        .attribute, .typeDeclaration, .memberDeclaration, .projectType, .projectMember, .otherType,
        .otherMember,
      ]
      colors = Dictionary(uniqueKeysWithValues: kinds.map { ($0, NSColor(hex: syntax.color(for: $0))) })
      plainColor = NSColor(hex: syntax.plainText)
      backgroundColor = NSColor(hex: theme.background)
      insertionPointColor = NSColor(hex: theme.cursor)
      selectedTextAttributes = [.backgroundColor: NSColor(hex: theme.selection)]

      let size = configuration.fontSize
      let newBase: NSFont
      var newKindFonts: [SyntaxKind: NSFont] = [:]
      if let name = configuration.fontName {
        newBase = NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
      } else {
        newBase = theme.fonts[.plainText].map { Self.font(named: $0, size: size) }
          ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        for (kind, name) in theme.fonts where name != theme.fonts[.plainText] {
          newKindFonts[kind] = Self.font(named: name, size: size)
        }
      }
      let natural = newBase.ascender - newBase.descender + newBase.leading
      let newLineHeight = ceil(natural * CGFloat(theme.lineSpacing))
      let fontsChanged =
        force || newBase != baseFont || newKindFonts != kindFonts || newLineHeight != lineHeight
      baseFont = newBase
      kindFonts = newKindFonts
      lineHeight = newLineHeight
      baseline = round((lineHeight - (newBase.ascender - newBase.descender)) / 2 + newBase.ascender)

      if let storage = textStorage {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        if fontsChanged {
          storage.setAttributes(baseAttributes, range: full)
        } else {
          storage.addAttribute(.foregroundColor, value: plainColor, range: full)
        }
        storage.endEditing()
        if fontsChanged {
          defaultParagraphStyle = paragraphStyle
          paragraphStyles = [:]
          applyLineAttributes(in: full)
        }
      }
      typingAttributes = baseAttributes
      enclosingScrollView?.backgroundColor = backgroundColor
      (enclosingScrollView?.verticalRulerView as? LineNumberRuler)?.updateThickness(force: true)
      invalidateAllColors()
      rulerNeedsDisplay()
    }

    /// Sets per-line attributes on the lines touching `range`: the theme's
    /// per-kind fonts (Xcode themes: bold keywords, proportional doc comments)
    /// and a paragraph style that indents wrapped continuation rows to the
    /// line's indentation plus four spaces, as Xcode does. Fonts and indents
    /// change layout, so unlike colors they live in the text storage; this
    /// runs only once an edit has settled (never inside the storage's edit
    /// callback).
    private func applyLineAttributes(in range: NSRange) {
      guard let storage = textStorage, range.length > 0 || storage.length == 0 else { return }
      let text = storage.mutableString
      let first = lineIndex.line(containing: range.location)
      let last = lineIndex.line(containing: max(range.location, NSMaxRange(range) - 1))
      let fonts = !kindFonts.isEmpty && highlighter.map { $0.lines.length == storage.length } == true
      storage.beginEditing()
      for line in first...last {
        let lineRange = lineIndex.range(ofLine: line)
        guard lineRange.length > 0 else { continue }
        storage.addAttribute(
          .paragraphStyle, value: paragraphStyle(indent: indentWidth(ofLine: line, in: text)),
          range: lineRange)
        guard fonts, let highlighter else { continue }
        storage.addAttribute(.font, value: baseFont, range: lineRange)
        for token in highlighter.tokens(ofLine: line) {
          // Later tokens win (a link inside a comment), so every token sets
          // its font, the base font included.
          var range = token.range
          // Doc prose starts after a monospaced space ("/// Text"), as in Xcode.
          if token.kind == .prose, range.length > 1, text.character(at: range.location) == 0x20 {
            range.location += 1
            range.length -= 1
          }
          storage.addAttribute(.font, value: kindFonts[token.kind] ?? baseFont, range: range)
        }
      }
      storage.endEditing()
    }

    /// Width of a line's leading whitespace, in points.
    private func indentWidth(ofLine line: Int, in text: NSString) -> CGFloat {
      let range = lineIndex.range(ofLine: line)
      var width: CGFloat = 0
      let tab = spaceWidth * CGFloat(max(1, configuration.tabWidth))
      for i in range.location..<NSMaxRange(range) {
        switch text.character(at: i) {
        case 0x20: width += spaceWidth
        case 0x09: width = (floor(width / tab) + 1) * tab
        default: return width
        }
      }
      return width
    }

    private var spaceWidth: CGFloat {
      (" " as NSString).size(withAttributes: [.font: baseFont]).width
    }

    /// Paragraph styles by indent, shared across lines.
    private var paragraphStyles: [CGFloat: NSParagraphStyle] = [:]

    private func paragraphStyle(indent: CGFloat) -> NSParagraphStyle {
      if let style = paragraphStyles[indent] { return style }
      let style = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
      style.headIndent = indent + spaceWidth * 4
      paragraphStyles[indent] = style
      return style
    }

    public override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      applyTheme()
    }

    public override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      applyWrapping()
    }

    /// Wrapped: the container follows the view's width. Unwrapped: lines run
    /// as long as they are and the view scrolls sideways.
    func applyWrapping() {
      guard let container = textContainer else { return }
      let contentSize = enclosingScrollView?.contentSize ?? bounds.size
      maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      minSize = NSSize(width: 0, height: contentSize.height)
      autoresizingMask = [.width]
      if configuration.wrapLines {
        // Exactly as wide as the visible area: wider, and lines would wrap
        // out of sight and the text could slide sideways.
        let width = visibleWidth
        isHorizontallyResizable = false
        container.widthTracksTextView = true
        setFrameSize(NSSize(width: width, height: frame.height))
        container.size = NSSize(
          width: width - textContainerInset.width * 2, height: CGFloat.greatestFiniteMagnitude)
        enclosingScrollView?.hasHorizontalScroller = false
        enclosingScrollView?.horizontalScrollElasticity = .none
      } else {
        container.widthTracksTextView = false
        container.size = NSSize(
          width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isHorizontallyResizable = true
        enclosingScrollView?.hasHorizontalScroller = true
        enclosingScrollView?.horizontalScrollElasticity = .automatic
        sizeToFit()
      }
    }

    /// The width the scroll view shows of the text. The clip view runs under
    /// the line numbers, which inset it, so its own width is too wide.
    var visibleWidth: CGFloat {
      guard let clip = enclosingScrollView?.contentView else { return bounds.width }
      return max(0, clip.bounds.width - clip.contentInsets.left - clip.contentInsets.right)
    }

    // MARK: - Language and text

    /// Switches highlighting to `spec` (after a rename, or once a "#!" line
    /// decided the language).
    public func setLanguage(_ spec: LanguageSpec?, highlightsSyntax: Bool) {
      guard spec?.name != self.spec?.name || highlightsSyntax != self.highlightsSyntax else { return }
      self.spec = spec
      self.highlightsSyntax = highlightsSyntax
      startFullScan()
    }

    /// Replaces the whole text (the file changed on disk) as one undoable
    /// change, keeping the selection where it was as far as possible.
    public func replaceAllText(_ newText: String) {
      guard let storage = textStorage, newText != storage.string else { return }
      let selection = selectedRange()
      let full = NSRange(location: 0, length: storage.length)
      isApplyingExternalText = true
      defer { isApplyingExternalText = false }
      if shouldChangeText(in: full, replacementString: newText) {
        storage.replaceCharacters(
          in: full, with: NSAttributedString(string: newText, attributes: baseAttributes))
        didChangeText()
      }
      lineEnding = Self.detectLineEnding(storage.mutableString)
      editedLines = []
      typeOverMarkers = []
      let location = min(selection.location, storage.length)
      setSelectedRange(NSRange(location: location, length: 0))
    }

    private static func detectLineEnding(_ text: NSString) -> String {
      let newline = text.range(of: "\n")
      guard newline.location != NSNotFound, newline.location > 0 else { return "\n" }
      return text.character(at: newline.location - 1) == 0x0D ? "\r\n" : "\n"
    }

    // MARK: - Highlighting

    public nonisolated func textStorage(
      _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
      range editedRange: NSRange, changeInLength delta: Int
    ) {
      guard editedMask.contains(.editedCharacters) else { return }
      MainActor.assumeIsolated { storageEdited(range: editedRange, delta: delta) }
    }

    /// Brings the line index and highlighter up to date with an edit. Runs
    /// inside the storage's edit callback, so it only reads the text and
    /// records what to redraw; the redraw happens once the edit settles.
    private func storageEdited(range editedRange: NSRange, delta: Int) {
      guard let text = textStorage?.mutableString else { return }
      let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
      if let onTextChange {
        // Positions in the old text, before the line index moves on.
        let startLine = lineIndex.line(containing: oldRange.location)
        let endLine = lineIndex.line(containing: NSMaxRange(oldRange))
        onTextChange(
          TextEdit(
            startLine: startLine, startColumn: oldRange.location - lineIndex.starts[startLine],
            endLine: endLine, endColumn: NSMaxRange(oldRange) - lineIndex.starts[endLine],
            text: text.substring(with: editedRange)))
      }
      let oldLineCount = lineIndex.count
      let changed = lineIndex.apply(edit: oldRange, replacementLength: editedRange.length, in: text)
      let lineDelta = lineIndex.count - oldLineCount
      shiftDirtyRange(forEditAt: oldRange, newLength: editedRange.length)
      if lineDelta != 0 { shiftLineMarks(changed: changed, lineDelta: lineDelta) }
      // Changed lines get their indent and fonts again, highlighted or not.
      markDirty(lines: changed)
      // Lines after the edit move with it; the edited lines are the ones the
      // new text covers (the storage may report a terminator it rewrote as
      // edited, which shouldn't flag the next line).
      editedLines.shift(startingAt: changed.upperBound - lineDelta, by: lineDelta)
      if !isApplyingExternalText {
        let first = lineIndex.line(containing: editedRange.location)
        let last = lineIndex.line(
          containing: max(editedRange.location, NSMaxRange(editedRange) - 1))
        editedLines.insert(integersIn: first...last)
      }
      // Type-over closers move with the text. The storage may report a
      // closer next to an insertion as replaced ({9,1} → "1)"): it survives
      // when the same character sits at its shifted place.
      typeOverMarkers = typeOverMarkers.compactMap { marker in
        if NSMaxRange(oldRange) <= marker { return marker + delta }
        if oldRange.location > marker { return marker }
        let shifted = marker + delta
        guard let closer = typeOverCharacters[marker], shifted >= editedRange.location,
          shifted < text.length, text.character(at: shifted) == closer
        else { return nil }
        return shifted
      }
      if highlighter != nil {
        let lines = highlighter!.edit(
          range: oldRange, replacementLength: editedRange.length, in: text,
          budget: Self.rescanBudget)
        markDirty(lines: lines)
        if !(highlighter?.pending.isEmpty ?? true) { scheduleContinue() }
      } else if highlightsSyntax, spec != nil {
        // A full scan is running for older text; start over once typing pauses.
        scheduleFullScan(after: .milliseconds(300))
      }
      scheduleFlush()
    }

    private func startFullScan() {
      scanTask?.cancel()
      continueTask?.cancel()
      continueTask = nil
      scanGeneration += 1
      guard highlightsSyntax, let spec, let storage = textStorage else {
        highlighter = nil
        invalidateAllColors()
        return
      }
      if storage.length <= Self.synchronousScanLimit {
        highlighter = SyntaxHighlighter(text: storage.mutableString, spec: spec)
        invalidateAllColors()
        return
      }
      highlighter = nil
      let generation = scanGeneration
      let text = storage.string
      scanTask = Task { [weak self] in
        let result = await Task.detached(priority: .userInitiated) {
          SyntaxHighlighter(text: text as NSString, spec: spec)
        }.value
        guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
        self.highlighter = result
        self.invalidateAllColors()
      }
    }

    private func scheduleFullScan(after delay: Duration) {
      scanGeneration += 1
      scanTask?.cancel()
      scanTask = Task { [weak self] in
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
        self?.startFullScan()
      }
    }

    /// Finishes a rescan that stopped at the budget, a batch per turn so
    /// typing stays responsive.
    private func scheduleContinue() {
      guard continueTask == nil else { return }
      continueTask = Task { [weak self] in
        while !Task.isCancelled {
          await Task.yield()
          guard let self, let text = self.textStorage?.mutableString,
            let lines = self.highlighter?.continuePending(in: text, budget: Self.rescanBudget)
          else { break }
          self.markDirty(lines: lines)
          self.flushDirty()
        }
        self?.continueTask = nil
      }
    }

    private func markDirty(lines: Range<Int>) {
      guard !lines.isEmpty else { return }
      let start = lineIndex.starts[lines.lowerBound]
      let endRange = lineIndex.range(ofLine: lines.upperBound - 1)
      let range = NSRange(location: start, length: NSMaxRange(endRange) - start)
      dirtyRange = dirtyRange.map { NSUnionRange($0, range) } ?? range
    }

    /// Keeps a not-yet-redrawn range pointing at the same text across an edit.
    private func shiftDirtyRange(forEditAt oldRange: NSRange, newLength: Int) {
      guard var dirty = dirtyRange else { return }
      let delta = newLength - oldRange.length
      if NSMaxRange(oldRange) <= dirty.location {
        dirty.location += delta
      } else if oldRange.location < NSMaxRange(dirty) {
        let start = min(dirty.location, oldRange.location)
        let end = max(NSMaxRange(dirty) + delta, oldRange.location + newLength)
        dirty = NSRange(location: start, length: max(0, end - start))
      }
      dirtyRange = dirty
    }

    private func scheduleFlush() {
      guard !isFlushScheduled else { return }
      isFlushScheduled = true
      DispatchQueue.main.async { [weak self] in self?.flushDirty() }
    }

    /// Redraws text whose colors changed. Runs after the edit settled (the
    /// layout manager has processed it), from `didChangeText` or the next turn.
    private func flushDirty() {
      isFlushScheduled = false
      guard let dirty = dirtyRange, let storage = textStorage else { return }
      dirtyRange = nil
      let range = NSIntersectionRange(dirty, NSRange(location: 0, length: storage.length))
      guard range.length > 0 else { return }
      applyLineAttributes(in: range)
      invalidatePlaceholderGlyphs(in: range)
      layoutManager?.invalidateDisplay(forCharacterRange: range)
      onLayoutChange?()
    }

    /// Redraws everything after a full scan or theme change, setting fonts
    /// for the whole text first.
    private func invalidateAllColors() {
      guard let storage = textStorage, storage.length > 0 else { return }
      let full = NSRange(location: 0, length: storage.length)
      if !kindFonts.isEmpty && highlighter == nil {
        storage.addAttribute(.font, value: baseFont, range: full)
      }
      applyLineAttributes(in: full)
      layoutManager?.invalidateDisplay(forCharacterRange: full)
      onLayoutChange?()
    }

    public nonisolated func layoutManager(
      _ layoutManager: NSLayoutManager,
      shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any] = [:],
      forDrawingToScreen toScreen: Bool, atCharacterIndex charIndex: Int,
      effectiveRange effectiveCharRange: NSRangePointer?
    ) -> [NSAttributedString.Key: Any]? {
      // Drawing happens on the main thread.
      nonisolated(unsafe) var result = attrs
      nonisolated(unsafe) let effectiveCharRange = effectiveCharRange
      MainActor.assumeIsolated {
        guard let run = colorRun(at: charIndex) else { return }
        effectiveCharRange?.pointee = run.range
        result[.foregroundColor] = run.color
      }
      return result
    }

    /// Placeholders' "<#" and "#>" get no glyphs.
    public nonisolated func layoutManager(
      _ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
      properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
      characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange
    ) -> Int {
      nonisolated(unsafe) let glyphs = glyphs
      nonisolated(unsafe) let props = props
      nonisolated(unsafe) let charIndexes = charIndexes
      nonisolated(unsafe) let layoutManager = layoutManager
      nonisolated(unsafe) let font = aFont
      return MainActor.assumeIsolated {
        generatePlaceholderGlyphs(
          layoutManager, glyphs: glyphs, properties: props, characterIndexes: charIndexes, font: font,
          glyphRange: glyphRange)
      }
    }

    /// Every line gets the same height with the text centered in it, whatever
    /// fonts it mixes (Xcode's line spacing).
    public nonisolated func layoutManager(
      _ layoutManager: NSLayoutManager,
      shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
      lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
      baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer,
      forGlyphRange glyphRange: NSRange
    ) -> Bool {
      nonisolated(unsafe) let rect = lineFragmentRect
      nonisolated(unsafe) let used = lineFragmentUsedRect
      nonisolated(unsafe) let offset = baselineOffset
      MainActor.assumeIsolated {
        rect.pointee.size.height = lineHeight
        used.pointee.size.height = lineHeight
        offset.pointee = baseline
      }
      return true
    }

    /// The color at `location` and how far it extends: up to the next token
    /// boundary on its line.
    private func colorRun(at location: Int) -> (color: NSColor, range: NSRange)? {
      guard let highlighter, highlighter.lines.length == textStorage?.length,
        location < highlighter.lines.length
      else { return nil }
      let line = highlighter.lines.line(containing: location)
      let lineRange = highlighter.lines.range(ofLine: line)
      var kind = SyntaxKind.plainText
      var end = NSMaxRange(lineRange)
      for token in highlighter.tokens(ofLine: line) {
        let tokenEnd = NSMaxRange(token.range)
        if token.range.location > location {
          end = min(end, token.range.location)
        } else if tokenEnd > location {
          // Later tokens win (a link inside a comment).
          kind = token.kind
          end = min(end, tokenEnd)
        }
      }
      // A closer waiting to be typed over is dimmed, as in Xcode.
      if typeOverMarkers.contains(location) {
        return ((colors[kind] ?? plainColor).withAlphaComponent(0.4), NSRange(location: location, length: 1))
      }
      if let next = typeOverMarkers.filter({ $0 > location }).min() { end = min(end, next) }
      return (colors[kind] ?? plainColor, NSRange(location: location, length: max(1, end - location)))
    }

    /// The syntax tokens of `line` (document offsets); empty while the
    /// text isn't highlighted.
    public func tokens(ofLine line: Int) -> [CodeToken] {
      guard let highlighter, highlighter.lines.length == textStorage?.length,
        line >= 0, line < highlighter.lines.count
      else { return [] }
      return highlighter.tokens(ofLine: line)
    }

    // MARK: - Edits and selection

    public override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?)
      -> Bool
    {
      let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
      if allowed { isInEdit = true }
      return allowed
    }

    public override func shouldChangeText(
      inRanges affectedRanges: [NSValue], replacementStrings: [String]?
    ) -> Bool {
      let allowed = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
      if allowed { isInEdit = true }
      return allowed
    }

    public override func didChangeText() {
      isInEdit = false
      super.didChangeText()
      dropStaleTypeOverMarkers()
      flushDirty()
      // Typing after a bold keyword must not continue in bold.
      typingAttributes = baseAttributes
      rulerNeedsDisplay()
      if !isApplyingExternalText { onEdit?() }
    }

    public override func setSelectedRanges(
      _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
      let oldLineRect = currentLineRect()
      // A caret placed inside a placeholder selects all of it.
      var ranges = ranges
      if !stillSelecting, !isInEdit, ranges.count == 1, let placeholder = placeholder(around: ranges[0].rangeValue) {
        ranges = [NSValue(range: placeholder)]
      }
      super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
      if configuration.highlightCurrentLine {
        if let oldLineRect { setNeedsDisplay(oldLineRect) }
        if let newLineRect = currentLineRect() { setNeedsDisplay(newLineRect) }
      }
      rulerNeedsDisplay()
      if !stillSelecting && !isInEdit { selectionDidChange() }
      onSelectionChange?(currentSelection)
    }

    public var currentSelection: EditorSelection {
      let range = selectedRange()
      let line = lineIndex.line(containing: range.location)
      let lastLine = lineIndex.line(containing: max(range.location, NSMaxRange(range) - 1))
      return EditorSelection(
        line: line + 1, column: range.location - lineIndex.starts[line] + 1, length: range.length,
        lineCount: range.length == 0 ? 1 : lastLine - line + 1)
    }

    /// The caret's line (all its wrapped fragments), in view coordinates; nil
    /// while text is selected.
    func currentLineRect() -> NSRect? {
      guard let layoutManager, let textContainer, selectedRange().length == 0 else { return nil }
      let caret = selectedRange().location
      let line = lineIndex.line(containing: caret)
      let range = lineIndex.range(ofLine: line)
      var rect: NSRect
      if range.length == 0 {
        // The empty last line exists only as the extra line fragment.
        rect = layoutManager.extraLineFragmentRect
        if rect.isEmpty { return nil }
      } else {
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
      }
      return NSRect(x: 0, y: rect.minY + textContainerOrigin.y, width: bounds.width, height: rect.height)
    }

    /// Corner radius of the current-line highlight, which runs from the
    /// gutter (drawn by the ruler) to just short of the right edge, as in Xcode.
    static let lineHighlightRadius: CGFloat = 5
    static let lineHighlightRightInset: CGFloat = 8

    public override func drawBackground(in rect: NSRect) {
      super.drawBackground(in: rect)
      // Placeholders, issue and debugger tints go over the current-line bar.
      defer {
        drawPlaceholderTokens(in: rect)
        drawLineTints(in: rect)
      }
      guard configuration.highlightCurrentLine, let lineRect = currentLineRect(),
        lineRect.intersects(rect)
      else { return }
      // The left end continues in the ruler, so it starts past the view's edge.
      let radius = Self.lineHighlightRadius
      let right = visibleRect.maxX - Self.lineHighlightRightInset
      let bar = NSRect(
        x: -radius * 2, y: lineRect.minY, width: right + radius * 2, height: lineRect.height)
      NSColor(hex: theme.currentLine).setFill()
      NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
    }

    func rulerNeedsDisplay() {
      enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      drawAnnotationBanners(in: dirtyRect)
    }

    public override func mouseDown(with event: NSEvent) {
      if handleCommandClick(event) { return }
      if event.clickCount == 1, handleBannerClick(at: convert(event.locationInWindow, from: nil)) {
        return
      }
      super.mouseDown(with: event)
    }

    // MARK: - Edit assists (see CodeTextView+EditAssists.swift)

    public override func insertText(_ string: Any, replacementRange: NSRange) {
      // Assists act on single characters typed at the keyboard; pastes,
      // dictation and their own edits go straight through.
      guard !isAssisting, NSApp.currentEvent?.type == .keyDown,
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
      else { return super.insertText(string, replacementRange: replacementRange) }
      let selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
      if (typed as NSString).length != 1
        || !assistTyping((typed as NSString).character(at: 0), selection: selection)
      {
        super.insertText(string, replacementRange: replacementRange)
      }
      onTyping?(typed)
    }

    public override func deleteBackward(_ sender: Any?) {
      if !deletePlaceholder(forward: false), !assistDeleteBackward() { super.deleteBackward(sender) }
      if NSApp.currentEvent?.type == .keyDown { onTyping?(nil) }
    }

    public override func deleteForward(_ sender: Any?) {
      if !deletePlaceholder(forward: true) { super.deleteForward(sender) }
    }

    public override func doCommand(by selector: Selector) {
      if commandHandler?(selector) == true { return }
      super.doCommand(by: selector)
    }

    /// Esc asks for completions, as in Xcode.
    public override func cancelOperation(_ sender: Any?) {
      if onCompletionRequest != nil { complete(sender) } else { super.cancelOperation(sender) }
    }

    public override func complete(_ sender: Any?) {
      guard let onCompletionRequest else { return super.complete(sender) }
      onCompletionRequest()
    }

    public override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned { onFocusLoss?() }
      return resigned
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
      super.viewWillMove(toWindow: newWindow)
      if newWindow == nil { onFocusLoss?() }
    }

    public override func keyDown(with event: NSEvent) {
      // ⌃Space shows completions (when the system doesn't take it for
      // switching input sources).
      if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control,
        event.charactersIgnoringModifiers == " ", onCompletionRequest != nil
      {
        complete(nil)
        return
      }
      super.keyDown(with: event)
    }

    public override func moveToBeginningOfLine(_ sender: Any?) {
      if !moveToLineIndentation(extending: false) { super.moveToBeginningOfLine(sender) }
    }

    public override func moveToLeftEndOfLine(_ sender: Any?) {
      if !moveToLineIndentation(extending: false) { super.moveToLeftEndOfLine(sender) }
    }

    public override func moveToBeginningOfLineAndModifySelection(_ sender: Any?) {
      if !moveToLineIndentation(extending: true) {
        super.moveToBeginningOfLineAndModifySelection(sender)
      }
    }

    public override func moveToLeftEndOfLineAndModifySelection(_ sender: Any?) {
      if !moveToLineIndentation(extending: true) {
        super.moveToLeftEndOfLineAndModifySelection(sender)
      }
    }

    public override func selectionRange(
      forProposedRange proposedCharRange: NSRange, granularity: NSSelectionGranularity
    ) -> NSRange {
      if granularity == .selectByWord, let placeholder = placeholder(around: proposedCharRange) {
        return placeholder
      }
      // A double-click on a bracket selects the bracketed block, as in Xcode.
      if granularity == .selectByWord, let block = delimitedBlock(at: proposedCharRange) {
        return block
      }
      return super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
    }

    // MARK: - Overscroll

    /// Lets the last line scroll up to the top of the view, as in Xcode.
    func updateOverscroll() {
      guard let scrollView = enclosingScrollView else { return }
      let visible = scrollView.contentSize.height
      let amount = max(0, visible - lineHeight - textContainerInset.height * 2)
      minSize = NSSize(width: 0, height: visible)
      guard abs(amount - overscroll) > 0.5 else { return }
      overscroll = amount
      sizeToFit()
    }

    public override func setFrameSize(_ newSize: NSSize) {
      var size = newSize
      if overscroll > 0, let layoutManager, let textContainer {
        let content = layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2
        size.height = max(newSize.height, content + overscroll)
      }
      super.setFrameSize(size)
    }

    // MARK: - Indentation

    var indentUnit: String {
      configuration.insertSpaces ? String(repeating: " ", count: max(1, configuration.tabWidth)) : "\t"
    }

    public override func insertNewline(_ sender: Any?) {
      guard let text = textStorage?.mutableString else { return super.insertNewline(sender) }
      let selection = selectedRange()
      let line = lineIndex.line(containing: selection.location)
      let lineStart = lineIndex.starts[line]
      let content = lineIndex.contentRange(ofLine: line, in: text)
      // Indentation of the current line, up to the caret.
      var i = lineStart
      while i < min(selection.location, NSMaxRange(content)),
        text.character(at: i) == 0x20 || text.character(at: i) == 0x09
      { i += 1 }
      let indent = text.substring(with: NSRange(location: lineStart, length: i - lineStart))
      // A "///" doc comment continues on the next line (Xcode's doc comment
      // assist).
      if selection.location >= i + 3, i + 3 <= NSMaxRange(content),
        text.substring(with: NSRange(location: i, length: 3)) == "///"
      {
        insertAssisted(lineEnding + indent + "/// ", replacing: selection)
        return
      }
      // One more level after an opening bracket (or a ":" in Python and YAML).
      var j = selection.location - 1
      while j >= lineStart, text.character(at: j) == 0x20 || text.character(at: j) == 0x09 { j -= 1 }
      let before: unichar? = j >= lineStart ? text.character(at: j) : nil
      let colonIndents = ["Python", "YAML"].contains(spec?.name ?? "")
      let indents =
        before.map { Delimiters.pairs[$0] != nil || (colonIndents && $0 == 0x3A) } ?? false
      var insertion = lineEnding + indent + (indents ? indentUnit : "")
      let caretOffset = (insertion as NSString).length
      let afterLocation = NSMaxRange(selection)
      let restOfLine = text.substring(
        with: NSRange(location: afterLocation, length: max(0, NSMaxRange(content) - afterLocation)))
      if indents, let before, let after = restOfLine.utf16.first, Delimiters.pairs[before] == after {
        // Between a bracket pair, the closer moves to its own line.
        insertion += lineEnding + indent
      } else if before == 0x7B, restOfLine.allSatisfy(\.isWhitespace),
        Delimiters.balance(of: 0x7B, in: text, lines: lineIndex, highlighter: highlighter) > 0
      {
        // Return after an unclosed "{" adds its "}" (Xcode's closing brace
        // assist).
        insertion += lineEnding + indent + "}"
      }
      insertAssisted(insertion, replacing: selection, caret: selection.location + caretOffset)
    }

    public override func insertTab(_ sender: Any?) {
      if selectPlaceholder(forward: true, onlyNearby: true) { return }
      let selection = selectedRange()
      if selection.length > 0, selectedLines.count > 1 {
        shiftRight(sender)
        return
      }
      guard configuration.insertSpaces else { return super.insertTab(sender) }
      let line = lineIndex.line(containing: selection.location)
      let column = selection.location - lineIndex.starts[line]
      let width = max(1, configuration.tabWidth)
      insertText(String(repeating: " ", count: width - column % width), replacementRange: selection)
    }

    public override func insertBacktab(_ sender: Any?) {
      if !selectPlaceholder(forward: false, onlyNearby: true) { shiftLeft(sender) }
    }

    /// Indents the selected lines by one level (⌘]).
    @objc public func shiftRight(_ sender: Any?) {
      let unit = indentUnit
      replaceSelectedLines(actionName: "Indent") { line in line.isEmpty ? line : unit + line }
    }

    /// Outdents the selected lines by one level (⌘[).
    @objc public func shiftLeft(_ sender: Any?) {
      let width = max(1, configuration.tabWidth)
      replaceSelectedLines(actionName: "Outdent") { line in
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        let spaces = line.prefix(while: { $0 == " " }).count
        return String(line.dropFirst(min(spaces, width)))
      }
    }

    /// Comments the selected lines out, or back in when all of them are
    /// commented (⌘/). Uses the language's line comment, or wraps each line in
    /// its block comment (HTML, CSS, Markdown).
    @objc public func toggleComment(_ sender: Any?) {
      guard let spec else { return NSSound.beep() }
      let preferBlock = spec.lineComments.isEmpty || spec.name == "CSS"
      let open: String
      let close: String
      if preferBlock, let block = spec.blockComments.first {
        (open, close) = (block.open, block.close)
      } else if let marker = spec.lineComments.first {
        (open, close) = (marker, "")
      } else {
        return NSSound.beep()
      }
      guard let text = textStorage?.mutableString else { return }
      let lines = selectedLines.map { text.substring(with: lineIndex.contentRange(ofLine: $0, in: text)) }
      let nonBlank = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      guard !nonBlank.isEmpty else { return }
      let isCommented = { (line: String) -> Bool in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(open) && (close.isEmpty || trimmed.hasSuffix(close))
      }
      if nonBlank.allSatisfy(isCommented) {
        replaceSelectedLines(actionName: "Uncomment") { line in
          guard isCommented(line) else { return line }
          let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
          var body = String(line.dropFirst(indent.count).dropFirst(open.count))
          if body.hasPrefix(" ") { body.removeFirst() }
          if !close.isEmpty {
            body = String(body.dropLast(close.count))
            if body.hasSuffix(" ") { body.removeLast() }
          }
          return indent + body
        }
      } else {
        let column = nonBlank.map { $0.prefix(while: { $0 == " " || $0 == "\t" }).count }.min() ?? 0
        replaceSelectedLines(actionName: "Comment") { line in
          guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
          let indent = line.prefix(column)
          return indent + open + " " + line.dropFirst(column) + (close.isEmpty ? "" : " " + close)
        }
      }
    }

    /// The lines the selection touches. A selection ending at a line start
    /// doesn't include that line.
    private var selectedLines: ClosedRange<Int> {
      let selection = selectedRange()
      let first = lineIndex.line(containing: selection.location)
      let end = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
      return first...max(first, lineIndex.line(containing: end))
    }

    /// Rewrites each selected line's content as one undoable change and
    /// selects the result (a caret stays on its line, shifted with it).
    private func replaceSelectedLines(actionName: String, _ transform: (String) -> String) {
      guard let storage = textStorage else { return }
      let text = storage.mutableString
      let lines = selectedLines
      let selection = selectedRange()
      let blockStart = lineIndex.starts[lines.lowerBound]
      let lastContent = lineIndex.contentRange(ofLine: lines.upperBound, in: text)
      let block = NSRange(location: blockStart, length: NSMaxRange(lastContent) - blockStart)
      var replacement = ""
      var caretDelta = 0
      for line in lines {
        let content = lineIndex.contentRange(ofLine: line, in: text)
        let old = text.substring(with: content)
        let new = transform(old)
        if line == lines.lowerBound { caretDelta = (new as NSString).length - (old as NSString).length }
        replacement += new
        if line < lines.upperBound {
          let full = lineIndex.range(ofLine: line)
          replacement += text.substring(
            with: NSRange(location: NSMaxRange(content), length: NSMaxRange(full) - NSMaxRange(content)))
        }
      }
      guard replacement != text.substring(with: block),
        shouldChangeText(in: block, replacementString: replacement)
      else { return }
      storage.replaceCharacters(in: block, with: replacement)
      didChangeText()
      undoManager?.setActionName(actionName)
      if selection.length == 0 && lines.count == 1 {
        setSelectedRange(NSRange(location: max(blockStart, selection.location + caretDelta), length: 0))
      } else {
        setSelectedRange(NSRange(location: blockStart, length: (replacement as NSString).length))
      }
    }

    // MARK: - Navigation

    /// Moves the caret to `line` and `column` (from 1), scrolls it to the
    /// middle of the view and flashes the line.
    public func goTo(line: Int, column: Int = 1) {
      guard let text = textStorage?.mutableString else { return }
      let lineNumber = min(max(line, 1), lineIndex.count) - 1
      let content = lineIndex.contentRange(ofLine: lineNumber, in: text)
      let location = content.location + min(max(column - 1, 0), content.length)
      setSelectedRange(NSRange(location: location, length: 0))
      window?.makeFirstResponder(self)
      if let layoutManager, let textContainer {
        let glyphs = layoutManager.glyphRange(
          forCharacterRange: NSRange(location: location, length: 0), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.y += textContainerOrigin.y
        let visible = visibleRect
        if let scrollView = enclosingScrollView {
          // Keep the clip view's x: with the line numbers' inset it is
          // negative, and the visible rect's x (0) would slide the text
          // under them.
          let clip = scrollView.contentView
          let maxY = max(0, frame.height - clip.bounds.height)
          clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(maxY, max(0, rect.midY - visible.height / 2))))
          scrollView.reflectScrolledClipView(clip)
        } else {
          scroll(NSPoint(x: visible.minX, y: max(0, rect.midY - visible.height / 2)))
        }
      }
      if content.length > 0 { showFindIndicator(for: content) }
    }
  }

  extension NSColor {
    /// An sRGB color from a 0xRRGGBB value.
    convenience init(hex: UInt32) {
      self.init(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
  }
#endif
