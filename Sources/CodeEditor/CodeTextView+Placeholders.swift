#if canImport(AppKit)
  import AppKit
  import CodeHighlighting

  /// Xcode's placeholders ("<#name#>" in the text): drawn as a rounded token
  /// with the markers hidden, selected whole when clicked or reached with the
  /// arrow keys, deleted whole by Backspace after one, and visited with Tab
  /// and ⇧Tab. Completions insert them for arguments.
  extension CodeTextView {
    // MARK: - Finding

    /// The placeholders on the lines touching `range`.
    func placeholders(onLinesOf range: NSRange) -> [NSRange] {
      guard let text = textStorage?.mutableString, text.length > 0 else { return [] }
      let clamped = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
      let lines = text.lineRange(
        for: NSRange(location: min(range.location, text.length), length: clamped.length))
      guard text.range(of: EditorPlaceholder.open, range: lines).location != NSNotFound else {
        return []
      }
      return EditorPlaceholder.ranges(in: text, range: lines)
    }

    /// The placeholder `range` lies inside of (a caret after its first
    /// character, or part of it selected), to select instead.
    func placeholder(around range: NSRange) -> NSRange? {
      for placeholder in placeholders(onLinesOf: range) where placeholder != range {
        let inside =
          range.length == 0
          ? range.location > placeholder.location && range.location < NSMaxRange(placeholder)
          : range.location >= placeholder.location && NSMaxRange(range) <= NSMaxRange(placeholder)
        if inside { return placeholder }
      }
      return nil
    }

    // MARK: - Moving between placeholders

    /// Selects the next (or previous) placeholder. `onlyNearby` (Tab) looks
    /// only on the caret's line unless a placeholder is selected; then it
    /// wraps around the file. Returns whether it selected one.
    @discardableResult func selectPlaceholder(forward: Bool, onlyNearby: Bool) -> Bool {
      guard let text = textStorage?.mutableString, text.length > 0 else { return false }
      let selection = selectedRange()
      let isOnPlaceholder = placeholders(onLinesOf: selection).contains(selection)
      // A quick check before scanning: Tab in a file without placeholders.
      guard text.range(of: EditorPlaceholder.open).location != NSNotFound else { return false }
      let all = NSRange(location: 0, length: text.length)
      let lines = text.lineRange(for: selection)
      let scope = onlyNearby && !isOnPlaceholder ? lines : all
      let found: NSRange?
      if forward {
        let start = NSMaxRange(selection)
        let after = EditorPlaceholder.ranges(
          in: text, range: NSRange(location: start, length: NSMaxRange(scope) - start))
        found =
          after.first
          ?? (isOnPlaceholder || !onlyNearby
            ? EditorPlaceholder.ranges(in: text, range: all).first : nil)
      } else {
        let before = EditorPlaceholder.ranges(
          in: text,
          range: NSRange(location: scope.location, length: selection.location - scope.location)
        ).filter { NSMaxRange($0) <= selection.location }
        found =
          before.last
          ?? (isOnPlaceholder || !onlyNearby
            ? EditorPlaceholder.ranges(in: text, range: all).last : nil)
      }
      guard let found else { return false }
      setSelectedRange(found)
      scrollRangeToVisible(found)
      return true
    }

    /// Jumps to the next placeholder in the file (Xcode's ⌃/).
    @objc public func selectNextPlaceholder(_ sender: Any?) {
      if !selectPlaceholder(forward: true, onlyNearby: false) { NSSound.beep() }
    }

    @objc public func selectPreviousPlaceholder(_ sender: Any?) {
      if !selectPlaceholder(forward: false, onlyNearby: false) { NSSound.beep() }
    }

    /// Backspace right after a placeholder (or Delete right before one)
    /// deletes all of it.
    func deletePlaceholder(forward: Bool) -> Bool {
      let selection = selectedRange()
      guard selection.length == 0,
        let placeholder = placeholders(onLinesOf: selection).first(where: {
          forward ? $0.location == selection.location : NSMaxRange($0) == selection.location
        })
      else { return false }
      insertAssisted("", replacing: placeholder, caret: placeholder.location)
      return true
    }

    // MARK: - Inserting completions

    /// Inserts a completion as one undoable change: `text` replaces `range`,
    /// its later lines indented like the caret's line, and `additionalEdits`
    /// (imports) are applied with it. Selects the first placeholder in the
    /// inserted text, or puts the caret at `caret` (a UTF-16 offset in
    /// `text`), or after it.
    public func insertCompletion(
      _ text: String, replacing range: NSRange, caret: Int? = nil,
      additionalEdits: [(range: NSRange, text: String)] = []
    ) {
      guard let storage = textStorage else { return }
      let length = storage.length
      guard NSMaxRange(range) <= length else { return }
      var insertion = text
      var caret = caret
      if text.contains("\n") {
        let indent = indentation(
          ofLine: lineIndex.line(containing: range.location), in: storage.mutableString)
        if let offset = caret {
          // The caret's offset moves with the indentation added before it.
          let before = (text as NSString).substring(to: min(offset, (text as NSString).length))
          caret =
            (Self.reindented(before, indent: indent, unit: indentUnit, lineEnding: lineEnding)
            as NSString).length
        }
        insertion = Self.reindented(text, indent: indent, unit: indentUnit, lineEnding: lineEnding)
      }
      var edits = additionalEdits.filter {
        NSMaxRange($0.range) <= range.location || $0.range.location >= NSMaxRange(range)
      }.filter { NSMaxRange($0.range) <= length }
      edits.append((range, insertion))
      edits.sort { $0.range.location > $1.range.location }
      let shiftBefore = additionalEdits.filter { NSMaxRange($0.range) <= range.location }.reduce(0)
      { $0 + ($1.text as NSString).length - $1.range.length }

      breakUndoCoalescing()
      undoManager?.beginUndoGrouping()
      isAssisting = true
      for edit in edits {
        guard shouldChangeText(in: edit.range, replacementString: edit.text) else { continue }
        storage.replaceCharacters(
          in: edit.range, with: NSAttributedString(string: edit.text, attributes: typingAttributes))
        didChangeText()
      }
      isAssisting = false
      undoManager?.endUndoGrouping()
      undoManager?.setActionName("Completion")

      let start = range.location + shiftBefore
      let inserted = NSRange(location: start, length: (insertion as NSString).length)
      if let first = EditorPlaceholder.ranges(in: storage.mutableString, range: inserted).first {
        setSelectedRange(first)
      } else {
        setSelectedRange(
          NSRange(location: start + min(caret ?? inserted.length, inserted.length), length: 0))
      }
      scrollRangeToVisible(selectedRange())
    }

    /// Later lines indented by `indent`, their leading tabs (how snippets
    /// indent) as the editor's indentation.
    private static func reindented(_ text: String, indent: String, unit: String, lineEnding: String)
      -> String
    {
      let lines = text.components(separatedBy: "\n")
      let rest = lines.dropFirst().map { line -> String in
        let tabs = line.prefix(while: { $0 == "\t" }).count
        return indent + String(repeating: unit, count: tabs) + line.dropFirst(tabs)
      }
      return ([lines[0]] + rest).joined(separator: lineEnding)
    }

    // MARK: - Drawing

    /// Hides each placeholder's "<#" and "#>" (null glyphs take no space).
    func generatePlaceholderGlyphs(
      _ layoutManager: NSLayoutManager, glyphs: UnsafePointer<CGGlyph>,
      properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
      characterIndexes: UnsafePointer<Int>, font: NSFont, glyphRange: NSRange
    ) -> Int {
      let count = glyphRange.length
      guard count > 0 else { return 0 }
      let first = characterIndexes[0]
      let last = characterIndexes[count - 1]
      let placeholders = placeholders(onLinesOf: NSRange(location: first, length: last - first + 1))
      guard !placeholders.isEmpty else { return 0 }
      var hidden = IndexSet()
      for placeholder in placeholders {
        hidden.insert(integersIn: placeholder.location..<(placeholder.location + 2))
        hidden.insert(integersIn: (NSMaxRange(placeholder) - 2)..<NSMaxRange(placeholder))
      }
      var newProperties = Array(UnsafeBufferPointer(start: properties, count: count))
      var changed = false
      for i in 0..<count where hidden.contains(characterIndexes[i]) {
        newProperties[i].insert(.null)
        changed = true
      }
      guard changed else { return 0 }
      newProperties.withUnsafeBufferPointer { buffer in
        layoutManager.setGlyphs(
          glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes, font: font,
          forGlyphRange: glyphRange)
      }
      return count
    }

    /// Glyphs are made again for edited lines that have placeholder markers
    /// (a "#>" typed completes one; deleting one shows its "<#" again).
    func invalidatePlaceholderGlyphs(in range: NSRange) {
      guard let layoutManager, let text = textStorage?.mutableString, text.length > 0 else {
        return
      }
      let lines = text.lineRange(
        for: NSIntersectionRange(range, NSRange(location: 0, length: text.length)))
      guard
        text.range(of: "<#", range: lines).location != NSNotFound
          || text.range(of: "#>", range: lines).location != NSNotFound
      else { return }
      layoutManager.invalidateGlyphs(
        forCharacterRange: lines, changeInLength: 0, actualCharacterRange: nil)
      layoutManager.invalidateLayout(forCharacterRange: lines, actualCharacterRange: nil)
    }

    /// The tokens behind visible placeholders.
    func drawPlaceholderTokens(in rect: NSRect) {
      guard let layoutManager, let textContainer, let text = textStorage?.mutableString,
        text.length > 0
      else { return }
      var visible = rect
      visible.origin.y -= textContainerOrigin.y
      let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
      let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      let placeholders = placeholders(onLinesOf: characters)
      guard !placeholders.isEmpty else { return }
      let color =
        theme.isDark
        ? NSColor(srgbRed: 0.30, green: 0.36, blue: 0.47, alpha: 1)
        : NSColor(srgbRed: 0.80, green: 0.86, blue: 0.96, alpha: 1)
      color.setFill()
      for placeholder in placeholders {
        let content = NSRange(location: placeholder.location + 2, length: placeholder.length - 4)
        let glyphRange = layoutManager.glyphRange(
          forCharacterRange: content, actualCharacterRange: nil)
        layoutManager.enumerateEnclosingRects(
          forGlyphRange: glyphRange,
          withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer
        ) { box, _ in
          var token = box.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
          token = token.insetBy(dx: -2, dy: 1)
          NSBezierPath(roundedRect: token, xRadius: 4, yRadius: 4).fill()
        }
      }
    }
  }
#endif
