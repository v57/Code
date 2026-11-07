#if canImport(AppKit)
  import AppKit
  import CodeHighlighting

  /// ⌥← and ⌥→ (and ⌥⌫, ⌥⌦, with ⇧ to select) move by the same words a double-click selects: names, so
  /// `Some.value` is two words where AppKit joins them across the dot (as in "e.g."), and `don't` in a comment or a
  /// string is one. A string literal on one line (its prefix included: `r"…"`, `@"…"`), a number (`3.14`) and a
  /// placeholder count as one word when the caret meets them from outside, so ⌥→ after `print(` lands after
  /// `"Hello World"`; inside a string the caret moves word by word.
  ///
  /// ⌃← and ⌃→ (Xcode's) or ⌃⌥← and ⌃⌥→ (when Mission Control has ⌃←), with ⇧ to select, move by subwords:
  /// `URLSession` is `URL` and `Session`, `snake_case` is `snake` and `case`.
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

    @objc public func moveSubwordForward(_ sender: Any?) { moveSubword(forward: true, extending: false) }
    @objc public func moveSubwordBackward(_ sender: Any?) { moveSubword(forward: false, extending: false) }
    @objc public func moveSubwordForwardAndModifySelection(_ sender: Any?) {
      moveSubword(forward: true, extending: true)
    }
    @objc public func moveSubwordBackwardAndModifySelection(_ sender: Any?) {
      moveSubword(forward: false, extending: true)
    }

    /// The subword command for ⌃←/⌃→ or ⌃⌥←/⌃⌥→ (⇧ to select), which AppKit binds to line moves or nothing.
    static func subwordCommand(for event: NSEvent) -> Selector? {
      let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
      guard flags.contains(.control), !flags.contains(.command),
        let key = event.charactersIgnoringModifiers?.utf16.first,
        key == UInt16(NSLeftArrowFunctionKey) || key == UInt16(NSRightArrowFunctionKey)
      else { return nil }
      let forward = key == UInt16(NSRightArrowFunctionKey)
      switch (forward, flags.contains(.shift)) {
      case (true, false): return #selector(moveSubwordForward(_:))
      case (false, false): return #selector(moveSubwordBackward(_:))
      case (true, true): return #selector(moveSubwordForwardAndModifySelection(_:))
      case (false, true): return #selector(moveSubwordBackwardAndModifySelection(_:))
      }
    }

    private func moveWord(forward: Bool, extending: Bool) {
      move(forward: forward, extending: extending) { wordBoundary(from: $0, forward: forward) }
    }

    private func moveSubword(forward: Bool, extending: Bool) {
      move(forward: forward, extending: extending) { subwordBoundary(from: $0, forward: forward) }
    }

    private func move(forward: Bool, extending: Bool, to boundary: (Int) -> Int) {
      let selection = selectedRange()
      guard extending else {
        let target = boundary(forward ? NSMaxRange(selection) : selection.location)
        setSelectedRange(NSRange(location: target, length: 0))
        scrollRangeToVisible(NSRange(location: target, length: 0))
        return
      }
      // The end that moves: the one the last ⇧ word move moved, else the end in the direction of travel.
      let head: Int
      let anchor: Int
      if let last = wordSelection, last.range == selection {
        head = last.head
        anchor = last.head == selection.location ? NSMaxRange(selection) : selection.location
      } else {
        head = forward ? NSMaxRange(selection) : selection.location
        anchor = forward ? selection.location : NSMaxRange(selection)
      }
      let target = boundary(head)
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

    // MARK: - Boundaries

    /// Where a word motion from `location` ends: past the non-word characters, then to the far end of the next name
    /// (or of a string literal, number or placeholder met from outside).
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
          if isWordCharacter(at: i, in: text) {
            while isWordCharacter(at: i, in: text) { i += 1 }
            return i
          }
          i += 1
        }
      } else {
        while i > 0 {
          if let atom = atom(at: i) { return atom.location }
          if isWordCharacter(at: i - 1, in: text) {
            while isWordCharacter(at: i - 1, in: text) { i -= 1 }
            return i
          }
          i -= 1
        }
      }
      return i
    }

    /// Where a subword motion from `location` ends: past what isn't a letter or digit (`_` included), then to the
    /// far end of the next run of lowercase letters (with its capital), capitals (`URL` in `URLSession`) or digits.
    func subwordBoundary(from location: Int, forward: Bool) -> Int {
      guard let text = textStorage?.mutableString else { return location }
      enum Kind { case lower, upper, digit }
      func kind(_ i: Int) -> Kind? {
        guard Self.isIdentifier(at: i, in: text), let scalar = Unicode.Scalar(text.character(at: i)) else {
          return nil
        }
        if scalar.properties.numericType != nil { return .digit }
        if scalar.properties.isUppercase { return .upper }
        if scalar.properties.isAlphabetic { return .lower }
        return nil  // _ $
      }
      var i = max(0, min(location, text.length))
      if forward {
        while i < text.length, kind(i) == nil { i += 1 }
        guard i < text.length, let first = kind(i) else { return i }
        switch first {
        case .digit, .lower:
          while i < text.length, kind(i) == first { i += 1 }
        case .upper:
          var end = i
          while end < text.length, kind(end) == .upper { end += 1 }
          if end - i == 1 {
            while end < text.length, kind(end) == .lower { end += 1 }
          } else if end < text.length, kind(end) == .lower {
            end -= 1  // URLSession: the S starts the next subword
          }
          i = end
        }
        return i
      }
      while i > 0, kind(i - 1) == nil { i -= 1 }
      guard i > 0, let last = kind(i - 1) else { return i }
      switch last {
      case .digit, .upper:
        while i > 0, kind(i - 1) == last { i -= 1 }
      case .lower:
        while i > 0, kind(i - 1) == .lower { i -= 1 }
        if i > 0, kind(i - 1) == .upper { i -= 1 }
      }
      return i
    }

    /// Whether the character at `i` belongs to a word: a name's character, or an apostrophe between letters in a
    /// comment, a string or plain text (`don't`), but not a string's own quote (Python's `f'x'`).
    func isWordCharacter(at i: Int, in text: NSString) -> Bool {
      if Self.isIdentifier(at: i, in: text) { return true }
      guard i > 0, i + 1 < text.length else { return false }
      let unit = text.character(at: i)
      guard unit == 0x27 || unit == 0x2019 else { return false }  // ' ’
      func isLetter(_ j: Int) -> Bool {
        Unicode.Scalar(text.character(at: j))?.properties.isAlphabetic == true
      }
      guard isLetter(i - 1), isLetter(i + 1) else { return false }
      guard let highlighter, highlighter.lines.length == text.length else { return spec == nil }
      let line = highlighter.lines.line(containing: i)
      guard let token = highlighter.tokens(ofLine: line).last(where: { NSLocationInRange(i, $0.range) })
      else { return false }
      switch token.kind {
      case .comment, .prose: return true
      case .string:
        if continuesString(token, onLine: line, in: highlighter) { return true }
        guard let shape = Self.literalShape(of: token.range, in: text) else { return true }
        return !NSLocationInRange(i, shape.open) && !(shape.close.map { NSLocationInRange(i, $0) } ?? false)
      default: return false
      }
    }

    // MARK: - Literals

    /// The string literals, numbers and placeholders on `line` that word motions treat as one word.
    private func wordAtoms(onLine line: Int, in text: NSString) -> [NSRange] {
      var atoms = placeholders(onLinesOf: lineIndex.range(ofLine: line))
      atoms += stringLiterals(onLine: line, in: text)
      if let highlighter, highlighter.lines.length == text.length, line < highlighter.lines.count {
        atoms += highlighter.tokens(ofLine: line).filter { $0.kind == .number && $0.range.length > 1 }.map(\.range)
      }
      return atoms
    }

    /// The whole string literals on `line`, each from its prefix (`r`, `@`, `#`) to its closing quote, not a piece
    /// of a multi-line string or one still being typed.
    func stringLiterals(onLine line: Int, in text: NSString) -> [NSRange] {
      guard let highlighter, highlighter.lines.length == text.length, line < highlighter.lines.count
      else { return [] }
      return highlighter.tokens(ofLine: line).compactMap { token in
        guard token.kind == .string, !continuesString(token, onLine: line, in: highlighter),
          !opensString(token, onLine: line, in: highlighter),
          Self.literalShape(of: token.range, in: text)?.close != nil
        else { return nil }
        let start = gluedPrefixStart(of: token.range.location, in: text)
        return NSRange(location: start, length: NSMaxRange(token.range) - start)
      }
    }

    /// The whole string literal for a double-click on its opening or closing quotes, across lines for a multi-line
    /// string (`"""`, `'''`, a template literal).
    func stringLiteral(atQuote proposed: NSRange) -> NSRange? {
      guard proposed.length <= 1, let text = textStorage?.mutableString, proposed.location < text.length,
        Self.isQuote(text.character(at: proposed.location)),
        let highlighter, highlighter.lines.length == text.length
      else { return nil }
      let location = proposed.location
      let line = highlighter.lines.line(containing: location)
      guard
        let token = highlighter.tokens(ofLine: line).last(where: {
          $0.kind == .string && NSLocationInRange(location, $0.range)
        })
      else { return nil }
      if continuesString(token, onLine: line, in: highlighter) {
        // The closer of a multi-line string: the literal starts at the opener on the line it began.
        guard !inMultilineString(at: line + 1, in: highlighter),
          let close = Self.closingRun(endingIn: token.range, in: text), NSLocationInRange(location, close)
        else { return nil }
        var opener = line - 1
        while opener > 0, line - opener < 10_000, inMultilineString(at: opener, in: highlighter) { opener -= 1 }
        guard opener >= 0, let first = highlighter.tokens(ofLine: opener).last(where: { $0.kind == .string })
        else { return nil }
        let start = gluedPrefixStart(of: first.range.location, in: text)
        return NSRange(location: start, length: NSMaxRange(token.range) - start)
      }
      guard let shape = Self.literalShape(of: token.range, in: text) else { return nil }
      let start = gluedPrefixStart(of: token.range.location, in: text)
      if opensString(token, onLine: line, in: highlighter) {
        // The opener of a multi-line string: the literal ends with the token on the last line inside it.
        guard NSLocationInRange(location, shape.open) else { return nil }
        var closer = line + 1
        while closer + 1 < highlighter.lines.count, closer - line < 10_000,
          inMultilineString(at: closer + 1, in: highlighter)
        { closer += 1 }
        guard let last = highlighter.tokens(ofLine: closer).first(where: { $0.kind == .string }),
          Self.closingRun(endingIn: last.range, in: text) != nil
        else { return nil }
        return NSRange(location: start, length: NSMaxRange(last.range) - start)
      }
      guard let close = shape.close,
        NSLocationInRange(location, shape.open) || NSLocationInRange(location, close)
      else { return nil }
      return NSRange(location: start, length: NSMaxRange(token.range) - start)
    }

    /// The number a double-click lands on (`3.14`, `0x1F`, `1e-5`), whole.
    func numberLiteral(at proposed: NSRange) -> NSRange? {
      guard proposed.length == 0, let text = textStorage?.mutableString, proposed.location < text.length,
        let highlighter, highlighter.lines.length == text.length
      else { return nil }
      let line = highlighter.lines.line(containing: proposed.location)
      return highlighter.tokens(ofLine: line).first {
        $0.kind == .number && $0.range.length > 1 && NSLocationInRange(proposed.location, $0.range)
      }?.range
    }

    /// Whether `line` starts inside a multi-line string.
    private func inMultilineString(at line: Int, in highlighter: SyntaxHighlighter) -> Bool {
      guard line >= 0, line < highlighter.lines.count else { return false }
      if case .multilineString = highlighter.startState(ofLine: line) { return true }
      return false
    }

    /// Whether `token` is the rest of a multi-line string begun on an earlier line.
    private func continuesString(_ token: CodeToken, onLine line: Int, in highlighter: SyntaxHighlighter) -> Bool {
      inMultilineString(at: line, in: highlighter) && highlighter.tokens(ofLine: line).first == token
    }

    /// Whether `token` opens a multi-line string that goes on past its line.
    private func opensString(_ token: CodeToken, onLine line: Int, in highlighter: SyntaxHighlighter) -> Bool {
      inMultilineString(at: line + 1, in: highlighter)
        && highlighter.tokens(ofLine: line).last(where: { $0.kind == .string }) == token
    }

    /// The start of a string's prefix outside its token (Python's `r` and `f`, C#'s `$`): up to three letters,
    /// digits, `@` or `$` right before it that don't end a longer name.
    private func gluedPrefixStart(of location: Int, in text: NSString) -> Int {
      var start = location
      while start > 0, location - start < 3, Self.isPrefixCharacter(text.character(at: start - 1)) { start -= 1 }
      if start > 0, Self.isIdentifier(at: start - 1, in: text) { return location }
      return start
    }

    /// A string token's opening quotes (after a prefix such as `r`, `@` or `#`) and its closing quotes (followed
    /// only by `#`), nil when the token doesn't start with quotes. A triple quote opens with three.
    static func literalShape(of range: NSRange, in text: NSString) -> (open: NSRange, close: NSRange?)? {
      guard range.length > 0 else { return nil }
      var first = range.location
      while first < NSMaxRange(range), first - range.location < 3, !isQuote(text.character(at: first)),
        isPrefixCharacter(text.character(at: first)) || text.character(at: first) == 0x23
      { first += 1 }
      guard first < NSMaxRange(range), isQuote(text.character(at: first)) else { return nil }
      let quote = text.character(at: first)
      var runEnd = first
      while runEnd < NSMaxRange(range), text.character(at: runEnd) == quote { runEnd += 1 }
      let open = NSRange(location: first, length: runEnd - first >= 3 ? 3 : 1)
      guard let close = closingRun(endingIn: range, in: text), text.character(at: close.location) == quote,
        close.length == open.length, close.location >= NSMaxRange(open)
      else { return (open, nil) }
      return (open, close)
    }

    /// The closing quotes at the end of a string token (before any `#`), as long as the opening ones would be:
    /// three for a triple quote, else one. Nil when the token ends otherwise or the quote is escaped.
    static func closingRun(endingIn range: NSRange, in text: NSString) -> NSRange? {
      var last = NSMaxRange(range) - 1
      while last > range.location, text.character(at: last) == 0x23 { last -= 1 }
      guard last >= range.location, isQuote(text.character(at: last)) else { return nil }
      let quote = text.character(at: last)
      var runStart = last
      while runStart > range.location, text.character(at: runStart - 1) == quote { runStart -= 1 }
      let length = last - runStart + 1 >= 3 ? 3 : 1
      let start = last - length + 1
      guard !isEscaped(start, in: text) else { return nil }
      return NSRange(location: start, length: length)
    }

    /// Whether an odd number of backslashes comes right before `location`.
    private static func isEscaped(_ location: Int, in text: NSString) -> Bool {
      var count = 0
      var i = location - 1
      while i >= 0, text.character(at: i) == 0x5C {
        count += 1
        i -= 1
      }
      return count % 2 == 1
    }

    static func isQuote(_ unit: unichar) -> Bool { unit == 0x22 || unit == 0x27 || unit == 0x60 }  // " ' `

    private static func isPrefixCharacter(_ unit: unichar) -> Bool {
      (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x30 && unit <= 0x39)
        || unit == 0x40 || unit == 0x24  // @ $
    }
  }
#endif
