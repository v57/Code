#if canImport(AppKit)
  import AppKit
  import CodeHighlighting

  /// The editing behaviors Xcode's source editor calls edit assists, matched
  /// here by name:
  ///
  /// - AutoCloseDelimiter: typing ( [ or a quote inserts its closer, dimmed
  ///   until typed over (TypeOver); Backspace between the pair deletes both.
  ///   "{" closes on Return instead (see `insertNewline`).
  /// - AutoEncloseDelimiter: typing a delimiter with text selected wraps it.
  /// - AdjustClosingDelimiter: a closer typed on a blank line takes its
  ///   opener's indentation.
  /// - AutoDeleteIndent: Backspace in leading spaces deletes back to the
  ///   previous tab stop.
  /// - DelimiterHighlight: moving or typing past a closer flashes its opener;
  ///   a double-click on a bracket selects the block.
  /// - MoveToBeginningOfLine: ⌘← goes to the indentation first, then column 0.
  /// - TrimTrailingWhitespace: ⌘S trims trailing whitespace from edited lines
  ///   (not whitespace-only lines, not the caret's line).
  extension CodeTextView {
    // MARK: - Typing

    /// Handles a typed character; false lets the text view insert it as is.
    func assistTyping(_ c: unichar, selection: NSRange) -> Bool {
      guard configuration.autoCloseDelimiters, spec != nil,
        let text = textStorage?.mutableString
      else { return false }
      let location = selection.location

      // Type-over: the closer is already there.
      if selection.length == 0, typeOverMarkers.contains(location), location < text.length,
        text.character(at: location) == c
      {
        typeOverMarkers.removeAll { $0 == location }
        setSelectedRange(NSRange(location: location + 1, length: 0))
        return true
      }

      // Auto-enclose: wrap the selection.
      if selection.length > 0, let close = closer(for: c) {
        let selected = text.substring(with: selection)
        insertAssisted(
          String(utf16CodeUnits: [c], count: 1) + selected + String(utf16CodeUnits: [close], count: 1),
          replacing: selection,
          select: NSRange(location: location + 1, length: selection.length))
        return true
      }

      // Auto-close.
      if selection.length == 0, let close = closer(for: c), shouldAutoClose(c, at: location, in: text) {
        insertAssisted(
          String(utf16CodeUnits: [c, close], count: 2), replacing: selection, caret: location + 1)
        typeOverMarkers.append(location + 1)
        return true
      }

      // A closer on a blank line lines up with its opener.
      if selection.length == 0, Delimiters.openers[c] != nil {
        let line = lineIndex.line(containing: location)
        let lineStart = lineIndex.starts[line]
        let before = text.substring(with: NSRange(location: lineStart, length: location - lineStart))
        if !before.isEmpty, before.allSatisfy({ $0 == " " || $0 == "\t" }),
          let opener = Delimiters.opener(
            for: c, before: location, in: text, lines: lineIndex, highlighter: highlighter)
        {
          let indent = indentation(ofLine: lineIndex.line(containing: opener), in: text)
          if indent != before {
            let replaced = NSRange(location: lineStart, length: location - lineStart)
            insertAssisted(
              indent + String(utf16CodeUnits: [c], count: 1), replacing: replaced,
              caret: lineStart + (indent as NSString).length + 1)
            return true
          }
        }
      }
      return false
    }

    /// The closer typing `c` opens: brackets always, quotes only where the
    /// language has strings (or character literals) delimited by them.
    private func closer(for c: unichar) -> unichar? {
      if c == 0x7B { return nil }  // "{" closes on Return
      if let close = Delimiters.pairs[c] { return close }
      guard let spec, [0x22, 0x27, 0x60].contains(c) else { return nil }
      let quote = String(utf16CodeUnits: [c], count: 1)
      let hasStrings = spec.strings.contains { $0.open == quote && $0.close == quote }
      let hasChars = c == 0x27 && spec.charLiteral == "'"
      return hasStrings || hasChars ? c : nil
    }

    /// Auto-close only where the pair is likely wanted: before whitespace,
    /// the line end or a closer, outside strings and comments, and for quotes
    /// not after a letter ("it's").
    private func shouldAutoClose(_ c: unichar, at location: Int, in text: NSString) -> Bool {
      if location < text.length {
        let next = text.character(at: location)
        let nextAllowed =
          next == 0x20 || next == 0x09 || next == 0x0A || next == 0x0D
          || Delimiters.openers[next] != nil || [0x2C, 0x3B, 0x3A, 0x2E].contains(next)
        if !nextAllowed { return false }
      }
      if Delimiters.pairs[c] == nil, location > 0 {
        let previous = text.character(at: location - 1)
        if isIdentifierCharacter(previous) || previous == c { return false }
      }
      return !isInsideLiteral(at: location, in: text)
    }

    /// Whether the caret at `location` is inside a string or comment (an
    /// unterminated one counts up to its end; a closed string doesn't at its
    /// closing quote).
    private func isInsideLiteral(at location: Int, in text: NSString) -> Bool {
      guard let highlighter, highlighter.lines.length == text.length else { return false }
      let line = lineIndex.line(containing: location)
      for token in highlighter.tokens(ofLine: line)
      where [.string, .comment, .prose].contains(token.kind) {
        let start = token.range.location
        let end = NSMaxRange(token.range)
        if start < location && location < end { return true }
        if location == end && start < location {
          let isClosedString =
            token.kind == .string && token.range.length >= 2
            && text.character(at: end - 1) == text.character(at: start)
          let isClosedComment =
            token.kind != .string && text.substring(with: token.range).hasSuffix("*/")
          if !isClosedString && !isClosedComment { return true }
        }
      }
      return false
    }

    private func isIdentifierCharacter(_ c: unichar) -> Bool {
      (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
    }

    // MARK: - Deleting

    func assistDeleteBackward() -> Bool {
      guard let text = textStorage?.mutableString else { return false }
      let selection = selectedRange()
      let location = selection.location
      guard selection.length == 0, location > 0 else { return false }

      // Backspace between an auto-closed pair deletes both.
      if typeOverMarkers.contains(location), location < text.length {
        let open = text.character(at: location - 1)
        let close = text.character(at: location)
        if Delimiters.pairs[open] == close || (open == close && [0x22, 0x27, 0x60].contains(open)) {
          typeOverMarkers.removeAll { $0 == location }
          insertAssisted("", replacing: NSRange(location: location - 1, length: 2), caret: location - 1)
          return true
        }
      }

      // Backspace in leading spaces deletes to the previous tab stop.
      guard configuration.insertSpaces else { return false }
      let lineStart = lineIndex.starts[lineIndex.line(containing: location)]
      let column = location - lineStart
      guard column > 0,
        text.substring(with: NSRange(location: lineStart, length: column)).allSatisfy({ $0 == " " })
      else { return false }
      let width = max(1, configuration.tabWidth)
      let count = column % width == 0 ? width : column % width
      guard count > 1 else { return false }
      insertAssisted("", replacing: NSRange(location: location - count, length: count), caret: location - count)
      return true
    }

    // MARK: - Selection

    /// After the caret moved: drops type-over closers it left, and flashes
    /// the opener of a closer the caret just passed with the keyboard.
    func selectionDidChange() {
      let selection = selectedRange()
      dropStaleTypeOverMarkers()
      guard selection.length == 0, selection.location > 0, NSApp.currentEvent?.type == .keyDown,
        let text = textStorage?.mutableString, selection.location <= text.length,
        Delimiters.openers[text.character(at: selection.location - 1)] != nil,
        let opener = Delimiters.match(
          at: selection.location - 1, in: text, lines: lineIndex, highlighter: highlighter)
      else { return }
      flashCharacter(at: opener)
    }

    /// Keeps only the type-over closers ahead of the caret on its line.
    func dropStaleTypeOverMarkers() {
      guard !typeOverMarkers.isEmpty else { return }
      let selection = selectedRange()
      let caretLine = lineIndex.line(containing: selection.location)
      typeOverMarkers.removeAll { marker in
        selection.length > 0 || marker < selection.location
          || lineIndex.line(containing: marker) != caretLine
      }
    }

    /// Xcode's delimiter highlight: a brief flash on the matching delimiter,
    /// only when it is on screen (the flash would scroll to it otherwise).
    private func flashCharacter(at location: Int) {
      guard let layoutManager, let textContainer else { return }
      let range = NSRange(location: location, length: 1)
      let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
      rect.origin.y += textContainerOrigin.y
      guard visibleRect.contains(rect) else { return }
      showFindIndicator(for: range)
    }

    /// The bracketed block for a double-click on a bracket, brackets included.
    func delimitedBlock(at proposed: NSRange) -> NSRange? {
      guard proposed.length <= 1, let text = textStorage?.mutableString,
        proposed.location < text.length
      else { return nil }
      let c = text.character(at: proposed.location)
      guard Delimiters.pairs[c] != nil || Delimiters.openers[c] != nil,
        let match = Delimiters.match(
          at: proposed.location, in: text, lines: lineIndex, highlighter: highlighter)
      else { return nil }
      let start = min(proposed.location, match)
      return NSRange(location: start, length: max(proposed.location, match) - start + 1)
    }

    /// ⌘←: to the first non-blank character, or to column 0 when already
    /// there (or on a wrapped continuation row, where AppKit's behavior is
    /// kept). Returns false to let AppKit handle it.
    func moveToLineIndentation(extending: Bool) -> Bool {
      guard let text = textStorage?.mutableString, let layoutManager else { return false }
      let selection = selectedRange()
      let caret = selection.location
      let line = lineIndex.line(containing: caret)
      let lineStart = lineIndex.starts[line]
      if caret > lineStart, caret <= text.length {
        let glyph = layoutManager.glyphIndexForCharacter(at: max(0, caret - 1))
        var fragment = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragment)
        let fragmentStart = layoutManager.characterIndexForGlyph(at: fragment.location)
        if fragmentStart > lineStart && fragmentStart < caret { return false }
      }
      let indentEnd = lineStart + (indentation(ofLine: line, in: text) as NSString).length
      let target = caret == indentEnd ? lineStart : indentEnd
      if extending {
        let anchor = NSMaxRange(selection)
        setSelectedRange(NSRange(location: min(target, anchor), length: abs(anchor - target)))
      } else {
        setSelectedRange(NSRange(location: target, length: 0))
      }
      scrollRangeToVisible(NSRange(location: target, length: 0))
      return true
    }

    // MARK: - Trailing whitespace

    /// Removes trailing spaces and tabs from the lines edited since the text
    /// was loaded, except whitespace-only lines and the caret's line (Xcode's
    /// defaults). One undoable change; returns whether anything changed.
    @discardableResult
    public func trimTrailingWhitespace() -> Bool {
      guard configuration.trimTrailingWhitespace, let storage = textStorage else { return false }
      let text = storage.mutableString
      let caretLine = lineIndex.line(containing: selectedRange().location)
      var ranges: [NSRange] = []
      for line in editedLines where line < lineIndex.count && line != caretLine {
        let content = lineIndex.contentRange(ofLine: line, in: text)
        var end = NSMaxRange(content)
        while end > content.location,
          text.character(at: end - 1) == 0x20 || text.character(at: end - 1) == 0x09
        { end -= 1 }
        if end > content.location && end < NSMaxRange(content) {
          ranges.append(NSRange(location: end, length: NSMaxRange(content) - end))
        }
      }
      guard !ranges.isEmpty,
        shouldChangeText(inRanges: ranges.map { NSValue(range: $0) },
          replacementStrings: Array(repeating: "", count: ranges.count))
      else { return false }
      let selection = selectedRange()
      let removedBefore = ranges.filter { NSMaxRange($0) <= selection.location }.reduce(0) {
        $0 + $1.length
      }
      isAssisting = true
      isApplyingExternalText = true
      storage.beginEditing()
      for range in ranges.reversed() { storage.replaceCharacters(in: range, with: "") }
      storage.endEditing()
      didChangeText()
      isApplyingExternalText = false
      isAssisting = false
      undoManager?.setActionName("Trim Trailing Whitespace")
      setSelectedRange(NSRange(location: selection.location - removedBefore, length: selection.length))
      return true
    }

    // MARK: - Helpers

    /// Replaces `range` with `string` as one undoable change and puts the
    /// caret at `caret` (default: after the inserted text) or selects
    /// `select`.
    func insertAssisted(
      _ string: String, replacing range: NSRange, caret: Int? = nil, select: NSRange? = nil
    ) {
      guard let storage = textStorage, shouldChangeText(in: range, replacementString: string) else {
        return
      }
      isAssisting = true
      storage.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: typingAttributes))
      didChangeText()
      isAssisting = false
      let caretLocation = caret ?? range.location + (string as NSString).length
      setSelectedRange(select ?? NSRange(location: caretLocation, length: 0))
      scrollRangeToVisible(selectedRange())
    }

    func indentation(ofLine line: Int, in text: NSString) -> String {
      let range = lineIndex.range(ofLine: line)
      var end = range.location
      while end < NSMaxRange(range), text.character(at: end) == 0x20 || text.character(at: end) == 0x09
      { end += 1 }
      return text.substring(with: NSRange(location: range.location, length: end - range.location))
    }
  }
#endif
