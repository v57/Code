#if canImport(AppKit)
  import AppKit
  import CodeHighlighting

  /// An issue shown on a line: an error, warning or note from a build or a
  /// language server.
  public struct LineAnnotation: Equatable, Sendable {
    public enum Severity: Int, Comparable, Sendable {
      case error, warning, note

      public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// From 0.
    public var line: Int
    /// UTF-16 column from 0, when known.
    public var column: Int?
    public var severity: Severity
    public var message: String

    public init(line: Int, column: Int? = nil, severity: Severity, message: String) {
      self.line = line
      self.column = column
      self.severity = severity
      self.message = message
    }
  }

  extension CodeTextView {
    // MARK: - Moving with edits

    /// Moves annotations, breakpoints and the execution line with an edit
    /// that added or removed lines. `changed` is the edit's lines in the new
    /// text; marks on removed lines move to the edit's last line.
    func shiftLineMarks(changed: Range<Int>, lineDelta: Int) {
      let firstAfter = changed.upperBound - lineDelta  // in the old numbering
      func shift(_ line: Int) -> Int {
        if line >= firstAfter { return line + lineDelta }
        if line >= changed.upperBound { return max(changed.lowerBound, changed.upperBound - 1) }
        return line
      }
      if !annotations.isEmpty {
        annotations = annotations.map {
          var annotation = $0
          annotation.line = shift($0.line)
          return annotation
        }
      }
      if !breakpoints.isEmpty {
        let moved = Set(breakpoints.map(shift))
        if moved != breakpoints {
          breakpoints = moved
          onBreakpointsChange?(moved)
        }
      }
      if let line = executionLine { executionLine = shift(line) }
      onLayoutChange?()
    }

    func annotationsChanged() {
      annotationPopover?.close()
      needsDisplay = true
      onLayoutChange?()
    }

    /// Adds or removes a breakpoint on `line` (a click in the gutter).
    public func toggleBreakpoint(atLine line: Int) {
      guard allowsBreakpoints, line >= 0, line < lineIndex.count else { return }
      if breakpoints.contains(line) {
        breakpoints.remove(line)
      } else {
        breakpoints.insert(line)
      }
      onBreakpointsChange?(breakpoints)
      onLayoutChange?()
    }

    // MARK: - Geometry

    /// A line's rectangle (all its wrapped fragments), in view coordinates.
    public func rect(ofLine line: Int) -> NSRect? {
      guard let layoutManager, let textContainer, line >= 0, line < lineIndex.count else { return nil }
      let range = lineIndex.range(ofLine: line)
      var rect: NSRect
      if range.length == 0 {
        rect = layoutManager.extraLineFragmentRect
        if rect.isEmpty { return nil }
      } else {
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
      }
      return NSRect(x: 0, y: rect.minY + textContainerOrigin.y, width: bounds.width, height: rect.height)
    }

    /// The right end of a line's text on its last fragment, and that
    /// fragment's rectangle, in view coordinates.
    func lastFragment(ofLine line: Int) -> (textEnd: CGFloat, fragment: NSRect)? {
      guard let layoutManager, let text = textStorage?.mutableString, line >= 0,
        line < lineIndex.count
      else { return nil }
      let content = lineIndex.contentRange(ofLine: line, in: text)
      let origin = textContainerOrigin
      if content.length == 0 {
        guard let rect = rect(ofLine: line) else { return nil }
        return (origin.x, NSRect(x: 0, y: rect.minY, width: bounds.width, height: lineHeight))
      }
      let lastGlyph = layoutManager.glyphIndexForCharacter(at: NSMaxRange(content) - 1)
      var fragmentRange = NSRange()
      let fragment = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: &fragmentRange)
      let used = layoutManager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
      return (
        used.maxX + origin.x,
        NSRect(x: 0, y: fragment.minY + origin.y, width: bounds.width, height: fragment.height)
      )
    }

    // MARK: - Drawing

    static func tint(for severity: LineAnnotation.Severity, isDark: Bool) -> NSColor {
      switch severity {
      case .error: return NSColor.systemRed.withAlphaComponent(isDark ? 0.22 : 0.13)
      case .warning: return NSColor.systemYellow.withAlphaComponent(isDark ? 0.2 : 0.2)
      case .note: return NSColor.systemGray.withAlphaComponent(isDark ? 0.18 : 0.12)
      }
    }

    static func bannerColor(for severity: LineAnnotation.Severity, isDark: Bool) -> NSColor {
      switch severity {
      case .error:
        return isDark
          ? NSColor(srgbRed: 0.42, green: 0.15, blue: 0.15, alpha: 1)
          : NSColor(srgbRed: 0.99, green: 0.86, blue: 0.86, alpha: 1)
      case .warning:
        return isDark
          ? NSColor(srgbRed: 0.40, green: 0.33, blue: 0.10, alpha: 1)
          : NSColor(srgbRed: 1.0, green: 0.95, blue: 0.80, alpha: 1)
      case .note:
        return isDark
          ? NSColor(srgbRed: 0.25, green: 0.25, blue: 0.27, alpha: 1)
          : NSColor(srgbRed: 0.92, green: 0.92, blue: 0.93, alpha: 1)
      }
    }

    static func iconColor(for severity: LineAnnotation.Severity) -> NSColor {
      switch severity {
      case .error: return .systemRed
      case .warning: return .systemYellow
      case .note: return .systemGray
      }
    }

    /// The annotations of each line, most severe first.
    var annotationsByLine: [Int: [LineAnnotation]] {
      Dictionary(grouping: annotations, by: \.line).mapValues {
        $0.sorted { $0.severity < $1.severity }
      }
    }

    /// Tints behind the text: issue lines and the execution line.
    func drawLineTints(in rect: NSRect) {
      let isDark = theme.isDark
      for (line, items) in annotationsByLine {
        guard let lineRect = self.rect(ofLine: line), lineRect.intersects(rect),
          let severity = items.first?.severity
        else { continue }
        Self.tint(for: severity, isDark: isDark).setFill()
        lineRect.fill(using: .sourceOver)
      }
      if let line = executionLine, let lineRect = self.rect(ofLine: line), lineRect.intersects(rect) {
        NSColor.systemGreen.withAlphaComponent(isDark ? 0.28 : 0.22).setFill()
        lineRect.fill(using: .sourceOver)
      }
    }

    /// The banner rectangles of the visible annotated lines.
    func annotationBanners() -> [(line: Int, rect: NSRect, items: [LineAnnotation])] {
      guard showsAnnotationMessages, !annotations.isEmpty else { return [] }
      let visible = visibleRect
      let right = visible.maxX - 6
      let font = NSFont.systemFont(ofSize: max(9, (configuration.fontSize) - 1))
      var banners: [(Int, NSRect, [LineAnnotation])] = []
      for (line, items) in annotationsByLine {
        guard let (textEnd, fragment) = lastFragment(ofLine: line), fragment.intersects(visible),
          let first = items.first
        else { continue }
        let label = bannerLabel(first, count: items.count)
        let textWidth = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        let iconWidth = fragment.height
        let wanted = iconWidth + 8 + textWidth + 10
        var left = max(textEnd + 20, right - wanted)
        // A long line: the banner covers its end, at least half the view wide.
        if right - left < min(wanted, 160) { left = max(visible.minX + visible.width * 0.45, right - wanted) }
        banners.append(
          (line, NSRect(x: left, y: fragment.minY + 1, width: right - left, height: fragment.height - 2), items))
      }
      return banners
    }

    func bannerLabel(_ annotation: LineAnnotation, count: Int) -> String {
      let message = annotation.message.split(separator: "\n").first.map(String.init) ?? ""
      return count > 1 ? "\(message)  (+\(count - 1))" : message
    }

    /// Message banners at the right end of issue lines, over the text.
    func drawAnnotationBanners(in rect: NSRect) {
      let isDark = theme.isDark
      let font = NSFont.systemFont(ofSize: max(9, configuration.fontSize - 1))
      let textColor = isDark ? NSColor.white.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.85)
      for (_, bannerRect, items) in annotationBanners() where bannerRect.intersects(rect) {
        guard let first = items.first else { continue }
        let path = NSBezierPath(roundedRect: bannerRect, xRadius: 4, yRadius: 4)
        Self.bannerColor(for: first.severity, isDark: isDark).setFill()
        path.fill()
        // The icon: a filled circle (error, note) or triangle (warning).
        let size = min(bannerRect.height - 4, 13)
        let iconRect = NSRect(
          x: bannerRect.minX + 6, y: bannerRect.midY - size / 2, width: size, height: size)
        drawIcon(first.severity, in: iconRect)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let label = bannerLabel(first, count: items.count) as NSString
        let textRect = NSRect(
          x: iconRect.maxX + 6, y: bannerRect.minY, width: bannerRect.maxX - iconRect.maxX - 12,
          height: bannerRect.height)
        let attributes: [NSAttributedString.Key: Any] = [
          .font: font, .foregroundColor: textColor, .paragraphStyle: style,
        ]
        let height = label.size(withAttributes: attributes).height
        label.draw(
          with: NSRect(x: textRect.minX, y: textRect.midY - height / 2, width: textRect.width, height: height),
          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
      }
    }

    func drawIcon(_ severity: LineAnnotation.Severity, in rect: NSRect) {
      Self.iconColor(for: severity).setFill()
      switch severity {
      case .warning:
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.midX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.close()
        path.fill()
        drawGlyph("!", in: rect.offsetBy(dx: 0, dy: 1.5), color: .black)
      case .error:
        NSBezierPath(ovalIn: rect).fill()
        drawGlyph("✕", in: rect, color: .white)
      case .note:
        NSBezierPath(ovalIn: rect).fill()
        drawGlyph("i", in: rect, color: .white)
      }
    }

    private func drawGlyph(_ glyph: String, in rect: NSRect, color: NSColor) {
      let font = NSFont.systemFont(ofSize: rect.height * 0.62, weight: .bold)
      let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
      let size = (glyph as NSString).size(withAttributes: attributes)
      (glyph as NSString).draw(
        at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
        withAttributes: attributes)
    }

    // MARK: - Clicks

    /// Shows all of a line's messages when its banner is clicked.
    func handleBannerClick(at point: NSPoint) -> Bool {
      guard let banner = annotationBanners().first(where: { $0.rect.contains(point) }) else {
        return false
      }
      annotationPopover?.close()
      let text = banner.items.map { item -> String in
        let kind =
          item.severity == .error ? "Error" : item.severity == .warning ? "Warning" : "Note"
        return "\(kind): \(item.message)"
      }.joined(separator: "\n\n")
      let field = NSTextField(wrappingLabelWithString: text)
      field.isSelectable = true
      field.font = .systemFont(ofSize: NSFont.systemFontSize)
      field.preferredMaxLayoutWidth = 480
      let size = field.fittingSize
      let controller = NSViewController()
      let container = NSView(
        frame: NSRect(x: 0, y: 0, width: min(500, size.width + 24), height: size.height + 20))
      field.frame = NSRect(x: 12, y: 10, width: container.frame.width - 24, height: size.height)
      container.addSubview(field)
      controller.view = container
      let popover = NSPopover()
      popover.contentViewController = controller
      popover.behavior = .transient
      popover.show(relativeTo: banner.rect, of: self, preferredEdge: .maxY)
      annotationPopover = popover
      return true
    }

    /// A ⌘-click: asks `onCommandClick` (jump to definition).
    func handleCommandClick(_ event: NSEvent) -> Bool {
      guard event.modifierFlags.contains(.command), let onCommandClick else { return false }
      let point = convert(event.locationInWindow, from: nil)
      let location = characterIndexForInsertion(at: point)
      guard location != NSNotFound else { return false }
      return onCommandClick(location)
    }

    /// The identifier around `location` (letters, digits, "_", "$").
    public func identifierRange(at location: Int) -> NSRange? {
      guard let text = textStorage?.mutableString, text.length > 0 else { return nil }
      func isIdentifier(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || c == 0x5F || c == 0x24
      }
      var start = min(location, text.length)
      var end = start
      while start > 0, isIdentifier(text.character(at: start - 1)) { start -= 1 }
      while end < text.length, isIdentifier(text.character(at: end)) { end += 1 }
      return end > start ? NSRange(location: start, length: end - start) : nil
    }

    /// The line and UTF-16 column (from 0) of a character location.
    public func position(of location: Int) -> (line: Int, column: Int) {
      let line = lineIndex.line(containing: min(location, lineIndex.length))
      return (line, location - lineIndex.starts[line])
    }

    /// The character location of a line and UTF-16 column (from 0), clamped
    /// to the text.
    public func location(line: Int, column: Int) -> Int {
      guard let text = textStorage?.mutableString else { return 0 }
      let line = min(max(line, 0), lineIndex.count - 1)
      let content = lineIndex.contentRange(ofLine: line, in: text)
      return content.location + min(max(column, 0), content.length)
    }
  }
#endif
