#if canImport(AppKit)
  import AppKit
  import CodeHighlighting

  /// The line-number gutter, laid out like Xcode's: numbers right-aligned
  /// against the text, on the text's baseline, in a slightly smaller
  /// monospaced-digit font; the current line's number is brighter and the
  /// current-line highlight starts here. Draws only the visible lines and
  /// widens when the line count gains a digit (two digits at least).
  @MainActor final class LineNumberRuler: NSRulerView {
    /// Space left of the numbers, and between the numbers and the ruler's
    /// right edge (the text starts after the text view's inset).
    static let leadingSpace: CGFloat = 17
    static let trailingSpace: CGFloat = 3
    /// Where the current-line highlight starts.
    static let highlightInset: CGFloat = 14

    private weak var textView: CodeTextView?
    private var digits = 0
    private var fontSize: CGFloat = 0

    init(textView: CodeTextView) {
      self.textView = textView
      super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
      clientView = textView
      clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var font: NSFont {
      let size = max(9, (textView?.configuration.fontSize ?? 13) - 1)
      return .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    /// Widens the ruler to fit the line count; `force` after a font change.
    func updateThickness(force: Bool = false) {
      guard let textView else { return }
      let count = max(2, String(textView.lineIndex.count).count)
      let size = font.pointSize
      guard force || count != digits || size != fontSize else { return }
      digits = count
      fontSize = size
      let digitWidth = ("8" as NSString).size(withAttributes: [.font: font]).width
      ruleThickness = ceil(Self.leadingSpace + digitWidth * CGFloat(count) + Self.trailingSpace)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
      guard let textView else { return }
      NSColor(hex: textView.theme.background).setFill()
      dirtyRect.fill()
      drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
      guard let textView, let layoutManager = textView.layoutManager,
        let container = textView.textContainer, let text = textView.textStorage?.mutableString
      else { return }
      updateThickness()
      let lines = textView.lineIndex
      let theme = textView.theme
      let font = font
      let normal: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor(hex: theme.gutterText),
      ]
      let current: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor(hex: theme.gutterCurrentText),
      ]
      let origin = textView.textContainerOrigin

      // The current-line highlight's left end (the text view draws the rest).
      if textView.configuration.highlightCurrentLine, let lineRect = textView.currentLineRect() {
        let y = convert(NSPoint(x: 0, y: lineRect.minY), from: textView).y
        let radius = CodeTextView.lineHighlightRadius
        let bar = NSRect(
          x: Self.highlightInset, y: y, width: ruleThickness - Self.highlightInset + radius * 2,
          height: lineRect.height)
        NSColor(hex: theme.currentLine).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
      }

      let selection = textView.selectedRange()
      let caretLines =
        lines.line(containing: selection.location)...lines.line(
          containing: max(selection.location, NSMaxRange(selection) - (selection.length > 0 ? 1 : 0)))
      let visible = textView.visibleRect
      let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
      let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      let firstLine = lines.line(containing: chars.location)
      let lastLine = lines.line(containing: NSMaxRange(chars))
      let right = ruleThickness - Self.trailingSpace

      func label(_ line: Int, at fragment: NSRect) {
        let top = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
        guard top + fragment.height >= rect.minY, top <= rect.maxY else { return }
        let number = String(line + 1) as NSString
        let attributes = caretLines.contains(line) ? current : normal
        let width = number.size(withAttributes: attributes).width
        // On the text's baseline.
        number.draw(
          at: NSPoint(x: right - width, y: top + textView.baseline - font.ascender),
          withAttributes: attributes)
      }

      for line in firstLine...lastLine {
        let range = lines.range(ofLine: line)
        if range.length == 0 {
          // The empty last line: drawn in the extra line fragment.
          let extra = layoutManager.extraLineFragmentRect
          if !extra.isEmpty || text.length == 0 {
            label(
              line,
              at: extra.isEmpty
                ? NSRect(x: 0, y: 0, width: 0, height: textView.lineHeight) : extra)
          }
          continue
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        label(line, at: fragment)
      }
    }
  }
#endif
