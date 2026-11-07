#if canImport(AppKit)
  import AppKit
  import CodeHighlighting

  /// ⌥← and ⌥→ (and ⌥⌫, ⌥⌦, with ⇧ to select) move by the same words a double-click selects: names, so
  /// `Some.value` is two words where AppKit joins them across the dot (as in "e.g."). A string literal on one line
  /// counts as one word when the caret meets it from outside, so ⌥→ after `print(` lands after `"Hello World"`;
  /// inside it the caret moves word by word. A placeholder is one word too.
  extension CodeTextView {
    public override func moveWordRight(_ sender: Any?) { moveWord(forward: true, extending: false) }
    public override func moveWordLeft(_ sender: Any?) { moveWord(forward: false, extending: false) }
    public override func moveWordForward(_ sender: Any?) { moveWord(forward: true, extending: false) }
    public override func moveWordBackward(_ sender: Any?) { moveWord(forward: false, extending: false) }

    public override func moveWordRightAndModifySelection(_ sender: Any?) {
      moveWord(forward: true, extending: true)
    }
    public override func moveWordLeftAndModifySelection(_ sender: Any?) {
      moveWord(forward: false, extending: true)
    }
    public override func moveWordForwardAndModifySelection(_ sender: Any?) {
      moveWord(forward: true, extending: true)
    }
    public override func moveWordBackwardAndModifySelection(_ sender: Any?) {
      moveWord(forward: false, extending: true)
    }

    public override func deleteWordBackward(_ sender: Any?) { deleteWord(forward: false, sender) }
    public override func deleteWordForward(_ sender: Any?) { deleteWord(forward: true, sender) }

    private func moveWord(forward: Bool, extending: Bool) {
      let selection = selectedRange()
      guard extending else {
        let target = wordBoundary(from: forward ? NSMaxRange(selection) : selection.location, forward: forward)
        setSelectedRange(NSRange(location: target, length: 0))
        scrollRangeToVisible(NSRange(location: target, length: 0))
        return
      }
      // The end that moves: the one the last ⇧⌥ arrow moved, else the end in the direction of travel.
      let head: Int
      let anchor: Int
      if let last = wordSelection, last.range == selection {
        head = last.head
        anchor = last.head == selection.location ? NSMaxRange(selection) : selection.location
      } else {
        head = forward ? NSMaxRange(selection) : selection.location
        anchor = forward ? selection.location : NSMaxRange(selection)
      }
      let target = wordBoundary(from: head, forward: forward)
      let range = NSRange(location: min(anchor, target), length: abs(target - anchor))
      // Upstream affinity when the moving end is the start, so AppKit's own ⇧ arrows keep moving that end.
      setSelectedRange(range, affinity: target < anchor ? .upstream : .downstream, stillSelecting: false)
      wordSelection = (range, target)
      scrollRangeToVisible(NSRange(location: target, length: 0))
    }

    private func deleteWord(forward: Bool, _ sender: Any?) {
      let selection = selectedRange()
      guard selection.length == 0 else {
        return forward ? deleteForward(sender) : deleteBackward(sender)
      }
      let target = wordBoundary(from: selection.location, forward: forward)
      guard target != selection.location else { return }
      let range = NSRange(
        location: min(target, selection.location), length: abs(target - selection.location))
      guard shouldChangeText(in: range, replacementString: "") else { return }
      textStorage?.replaceCharacters(in: range, with: "")
      didChangeText()
      setSelectedRange(NSRange(location: range.location, length: 0))
      undoManager?.setActionName("Delete Word")
    }

    /// Where a word motion from `location` ends: past the non-word characters, then to the far end of the next name
    /// (or of a string literal or placeholder met from outside).
    func wordBoundary(from location: Int, forward: Bool) -> Int {
      guard let text = textStorage?.mutableString else { return location }
      var atoms: [Int: [NSRange]] = [:]
      func atom(at i: Int) -> NSRange? {
        let line = lineIndex.line(containing: max(0, min(i, text.length)))
        if atoms[line] == nil { atoms[line] = wordAtoms(onLine: line, in: text) }
        return atoms[line]!.first { forward ? $0.location == i : NSMaxRange($0) == i }
      }
      var i = max(0, min(location, text.length))
      if forward {
        while i < text.length {
          if let atom = atom(at: i) { return NSMaxRange(atom) }
          if Self.isIdentifier(at: i, in: text) {
            while Self.isIdentifier(at: i, in: text) { i += 1 }
            return i
          }
          i += 1
        }
      } else {
        while i > 0 {
          if let atom = atom(at: i) { return atom.location }
          if Self.isIdentifier(at: i - 1, in: text) {
            while Self.isIdentifier(at: i - 1, in: text) { i -= 1 }
            return i
          }
          i -= 1
        }
      }
      return i
    }

    /// The string literals and placeholders on `line` that word motions treat as one word.
    private func wordAtoms(onLine line: Int, in text: NSString) -> [NSRange] {
      var atoms = placeholders(onLinesOf: lineIndex.range(ofLine: line))
      atoms += stringLiterals(onLine: line, in: text)
      return atoms
    }

    /// The string tokens on `line` that are whole literals: from an opening quote to its closer (a raw string's `#`
    /// included), not a piece of a multi-line string or one still being typed.
    func stringLiterals(onLine line: Int, in text: NSString) -> [NSRange] {
      guard let highlighter, highlighter.lines.length == text.length, line < highlighter.lines.count
      else { return [] }
      return highlighter.tokens(ofLine: line).filter { token in
        guard token.kind == .string, token.range.length >= 2 else { return false }
        let first = text.character(at: token.range.location)
        let last = text.character(at: NSMaxRange(token.range) - 1)
        return (Self.isQuote(first) || first == 0x23) && (Self.isQuote(last) || last == 0x23)
          && Self.firstQuote(in: token.range, of: text) != nil
      }.map(\.range)
    }

    /// The whole string literal for a double-click on its opening or closing quote.
    func stringLiteral(atQuote proposed: NSRange) -> NSRange? {
      guard proposed.length <= 1, let text = textStorage?.mutableString, proposed.location < text.length,
        Self.isQuote(text.character(at: proposed.location))
      else { return nil }
      let line = lineIndex.line(containing: proposed.location)
      return stringLiterals(onLine: line, in: text).first { literal in
        NSLocationInRange(proposed.location, literal)
          && (proposed.location == Self.firstQuote(in: literal, of: text)
            || proposed.location == Self.lastQuote(in: literal, of: text))
      }
    }

    static func isQuote(_ unit: unichar) -> Bool { unit == 0x22 || unit == 0x27 || unit == 0x60 }  // " ' `

    private static func firstQuote(in range: NSRange, of text: NSString) -> Int? {
      (range.location..<NSMaxRange(range)).first { isQuote(text.character(at: $0)) }
    }

    private static func lastQuote(in range: NSRange, of text: NSString) -> Int? {
      (range.location..<NSMaxRange(range)).reversed().first { isQuote(text.character(at: $0)) }
    }
  }
#endif
