#if canImport(AppKit)
  import AppKit
  import CodeHighlighting

  /// A stretch of non-blank text on a line, for the minimap: where it starts
  /// (in columns, tabs expanded), how long it is, and its syntax kind.
  public struct MinimapRun: Equatable, Sendable {
    public var column: Int
    public var length: Int
    public var kind: SyntaxKind

    public init(column: Int, length: Int, kind: SyntaxKind) {
      self.column = column
      self.length = length
      self.kind = kind
    }
  }

  /// Something marked on a line: an issue, a breakpoint, the debugger's
  /// line, a search result.
  public struct MinimapMark: Equatable, Sendable {
    public enum Kind: Int, Sendable {
      case error, warning, note, breakpoint, execution, highlight
    }

    public var line: Int
    public var kind: Kind

    public init(line: Int, kind: Kind) {
      self.line = line
      self.kind = kind
    }
  }

  /// A titled section start, as `// MARK: - Name` makes in Xcode; drawn as
  /// its title in the minimap.
  public struct MinimapSection: Equatable, Sendable {
    public var line: Int
    public var title: String
    /// `MARK: -`: a separator line above the title.
    public var hasSeparator: Bool

    public init(line: Int, title: String, hasSeparator: Bool) {
      self.line = line
      self.title = title
      self.hasSeparator = hasSeparator
    }
  }

  /// What the minimap shows and scrolls: an editor.
  @MainActor public protocol MinimapDataSource: AnyObject {
    var minimapLineCount: Int { get }
    func minimapRuns(ofLine line: Int) -> [MinimapRun]
    /// The lines the editor shows now (fractional at the edges).
    var minimapVisibleLines: ClosedRange<Double> { get }
    /// Scrolls the editor so `line` is at its top.
    func minimapScroll(toTopLine line: Double)
  }

  /// Xcode's minimap: the file in miniature, each run of text drawn as a
  /// rounded bar in its syntax color rather than as tiny text, with the
  /// visible part framed, section titles from MARK comments, and marks for
  /// issues and breakpoints. Click or drag to scroll.
  @MainActor public final class MinimapView: NSView {
    public weak var dataSource: MinimapDataSource? {
      didSet { needsDisplay = true }
    }
    public var theme: EditorTheme = .xcodeLight {
      didSet { if theme != oldValue { needsDisplay = true } }
    }
    public var marks: [MinimapMark] = [] {
      didSet { if marks != oldValue { needsDisplay = true } }
    }
    public var sections: [MinimapSection] = [] {
      didSet { if sections != oldValue { needsDisplay = true } }
    }

    /// Height of a line, of its bar, and width of a column.
    public var rowHeight: CGFloat = 3
    public var barHeight: CGFloat = 2
    public var columnWidth: CGFloat = 1.25
    public static let defaultWidth: CGFloat = 120
    static let leadingInset: CGFloat = 8

    /// Offset into the drawn lines when they are taller than the view.
    private var dragOffset: CGFloat?

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Redraws after the editor scrolled or changed.
    public func refresh() { needsDisplay = true }

    // MARK: - Geometry

    private var contentHeight: CGFloat {
      CGFloat(dataSource?.minimapLineCount ?? 0) * rowHeight
    }

    /// How far the drawing is scrolled: like Xcode's, the minimap scrolls
    /// along with the editor when the file is taller than the view.
    private var scrollOffset: CGFloat {
      guard let dataSource else { return 0 }
      let overflow = contentHeight - bounds.height
      guard overflow > 0 else { return 0 }
      let visible = dataSource.minimapVisibleLines
      let count = Double(dataSource.minimapLineCount)
      let scrollable = max(1, count - (visible.upperBound - visible.lowerBound))
      let fraction = min(1, max(0, visible.lowerBound / scrollable))
      return overflow * CGFloat(fraction)
    }

    private func y(ofLine line: Double, offset: CGFloat) -> CGFloat {
      CGFloat(line) * rowHeight - offset
    }

    private func line(atY y: CGFloat, offset: CGFloat) -> Double {
      Double((y + offset) / rowHeight)
    }

    // MARK: - Drawing

    public override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      // Since macOS 14 views don't clip: the background fill would cover
      // the views around the minimap.
      clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func draw(_ rect: NSRect) {
      let dirtyRect = rect.intersection(bounds)
      NSColor(hex: theme.background).setFill()
      dirtyRect.fill()
      // A hairline between the editor and the minimap.
      NSColor.separatorColor.withAlphaComponent(0.4).setFill()
      NSRect(x: 0, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
      guard let dataSource else { return }
      let count = dataSource.minimapLineCount
      guard count > 0 else { return }
      let offset = scrollOffset
      let first = max(0, Int(line(atY: dirtyRect.minY, offset: offset)))
      let last = min(count - 1, Int(line(atY: dirtyRect.maxY, offset: offset)) + 1)
      guard first <= last else { return }

      drawMarks(lines: first...last, offset: offset, behind: true)

      // Bars, one path per color.
      var paths: [UInt32: NSBezierPath] = [:]
      let maxX = bounds.maxX - 4
      for lineNumber in first...last {
        let top = y(ofLine: Double(lineNumber), offset: offset) + (rowHeight - barHeight) / 2
        for run in dataSource.minimapRuns(ofLine: lineNumber) {
          let x = Self.leadingInset + CGFloat(run.column) * columnWidth
          guard x < maxX else { break }
          let width = min(CGFloat(run.length) * columnWidth, maxX - x)
          let color = theme.syntax.color(for: run.kind)
          let path = paths[color] ?? NSBezierPath()
          path.appendRoundedRect(
            NSRect(x: x, y: top, width: max(width, 1), height: barHeight), xRadius: 0.8, yRadius: 0.8)
          paths[color] = path
        }
      }
      let alpha: CGFloat = theme.isDark ? 0.75 : 0.6
      for (color, path) in paths {
        NSColor(hex: color).withAlphaComponent(alpha).setFill()
        path.fill()
      }

      drawMarks(lines: first...last, offset: offset, behind: false)
      drawSections(offset: offset, in: dirtyRect)
      drawViewport(offset: offset)
    }

    private func drawMarks(lines: ClosedRange<Int>, offset: CGFloat, behind: Bool) {
      for mark in marks where lines.contains(mark.line) {
        let top = y(ofLine: Double(mark.line), offset: offset)
        let height = max(rowHeight, 2)
        switch mark.kind {
        case .error, .warning, .note, .highlight:
          guard behind else { continue }
          let color: NSColor =
            mark.kind == .error
            ? .systemRed : mark.kind == .warning ? .systemYellow : mark.kind == .note ? .systemGray : .systemYellow
          color.withAlphaComponent(mark.kind == .highlight ? 0.45 : 0.5).setFill()
          NSRect(x: 1, y: top - 0.5, width: bounds.width - 1, height: height + 1).fill()
          // A solid tick at the edge, visible however short the line is.
          color.setFill()
          NSRect(x: bounds.maxX - 4, y: top - 0.5, width: 3, height: height + 1).fill()
        case .breakpoint, .execution:
          guard !behind else { continue }
          let color =
            mark.kind == .breakpoint
            ? NSColor(srgbRed: 0.27, green: 0.53, blue: 0.97, alpha: 1)
            : NSColor(srgbRed: 0.30, green: 0.72, blue: 0.36, alpha: 1)
          color.setFill()
          NSBezierPath(
            roundedRect: NSRect(x: 2, y: top - 1, width: 4, height: height + 2), xRadius: 1, yRadius: 1
          ).fill()
        }
      }
    }

    /// Section titles, bold over a cleared background, as Xcode shows MARKs.
    private func drawSections(offset: CGFloat, in dirtyRect: NSRect) {
      guard !sections.isEmpty else { return }
      let font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
      let color = NSColor(hex: theme.syntax.plainText).withAlphaComponent(0.85)
      let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
      let background = NSColor(hex: theme.background)
      let height = ceil(font.ascender - font.descender) + 2
      var lastBottom = -CGFloat.infinity
      for section in sections {
        let top = y(ofLine: Double(section.line), offset: offset) - 1
        guard top + height >= dirtyRect.minY, top <= dirtyRect.maxY, top >= lastBottom else {
          continue
        }
        let title = section.title as NSString
        let width = min(bounds.width - Self.leadingInset - 4, title.size(withAttributes: attributes).width)
        let box = NSRect(x: Self.leadingInset - 2, y: top, width: width + 4, height: height)
        background.withAlphaComponent(0.9).setFill()
        box.fill()
        if section.hasSeparator {
          NSColor.separatorColor.setFill()
          NSRect(x: Self.leadingInset - 2, y: top - 1, width: bounds.width - Self.leadingInset - 2, height: 1).fill()
        }
        title.draw(
          with: NSRect(x: Self.leadingInset, y: top + 1, width: width, height: height),
          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        lastBottom = top + height
      }
    }

    private func drawViewport(offset: CGFloat) {
      guard let visible = dataSource?.minimapVisibleLines else { return }
      let top = y(ofLine: visible.lowerBound, offset: offset)
      let bottom = y(ofLine: visible.upperBound, offset: offset)
      let rect = NSRect(x: 1, y: top, width: bounds.width - 1, height: max(bottom - top, 4))
      let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
      NSColor.labelColor.withAlphaComponent(theme.isDark ? 0.10 : 0.06).setFill()
      path.fill()
      NSColor.labelColor.withAlphaComponent(0.12).setStroke()
      path.lineWidth = 1
      path.stroke()
    }

    // MARK: - Scrolling

    public override func mouseDown(with event: NSEvent) {
      guard let dataSource else { return }
      let point = convert(event.locationInWindow, from: nil)
      let offset = scrollOffset
      let visible = dataSource.minimapVisibleLines
      let clicked = line(atY: point.y, offset: offset)
      if visible.contains(clicked) {
        // Dragging the frame keeps the grabbed point under the mouse.
        dragOffset = CGFloat(clicked - visible.lowerBound)
      } else {
        let half = (visible.upperBound - visible.lowerBound) / 2
        dragOffset = CGFloat(half)
        dataSource.minimapScroll(toTopLine: max(0, clicked - half))
        needsDisplay = true
      }
    }

    public override func mouseDragged(with event: NSEvent) {
      guard let dataSource, let dragOffset else { return }
      let point = convert(event.locationInWindow, from: nil)
      // While dragging, follow the mouse in the unscrolled drawing so the
      // minimap's own scrolling doesn't fight the drag.
      let visible = dataSource.minimapVisibleLines
      let visibleCount = visible.upperBound - visible.lowerBound
      let count = Double(dataSource.minimapLineCount)
      let overflow = contentHeight - bounds.height
      let line: Double
      if overflow > 0 {
        // Map the mouse over the view's height onto the scrollable range.
        let fraction = Double(max(0, min(1, (point.y - dragOffset * rowHeight) / max(1, bounds.height - CGFloat(visibleCount) * rowHeight))))
        line = fraction * max(0, count - visibleCount)
      } else {
        line = Double(point.y / rowHeight) - Double(dragOffset)
      }
      dataSource.minimapScroll(toTopLine: max(0, line))
      needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
      dragOffset = nil
    }

    public override func scrollWheel(with event: NSEvent) {
      // Scrolling over the minimap scrolls the editor.
      if let scrollView = (dataSource as? NSView)?.enclosingScrollView {
        scrollView.scrollWheel(with: event)
      } else {
        super.scrollWheel(with: event)
      }
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

  /// Finds MARK comments: `// MARK: - Title`, `# MARK: Title`,
  /// `#pragma mark - Title`, `// region Title`.
  public enum MinimapSections {
    static let pattern = try! NSRegularExpression(
      pattern: #"^[ \t]*(?://+|#+|--|;+|/\*+)[ \t]*(?:MARK:|pragma mark|region\b)[ \t]*(-)?[ \t]*(.*?)[ \t]*(?:\*/)?[ \t]*$"#,
      options: [.anchorsMatchLines, .caseInsensitive])

    public static func find(in text: NSString, lines: LineIndex) -> [MinimapSection] {
      guard text.range(of: "MARK").location != NSNotFound || text.range(of: "pragma mark").location != NSNotFound
        || text.range(of: "region").location != NSNotFound
      else { return [] }
      var sections: [MinimapSection] = []
      let range = NSRange(location: 0, length: text.length)
      for match in pattern.matches(in: text as String, range: range) {
        let separator = match.range(at: 1).location != NSNotFound
        let title = text.substring(with: match.range(at: 2))
        guard !title.isEmpty || separator else { continue }
        sections.append(
          MinimapSection(
            line: lines.line(containing: match.range.location), title: title, hasSeparator: separator))
      }
      return sections
    }
  }
#endif
