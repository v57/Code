#if canImport(AppKit)
  import AppKit
  import CodeHighlighting
  import Testing

  @testable import CodeEditor

  @MainActor private func editor(_ text: String, caret: Int? = nil, _ language: String = "swift")
    -> CodeTextView
  {
    let view = CodeTextView(
      text: text, spec: CodeHighlighter.spec(forLanguage: language), highlightsSyntax: true,
      configuration: EditorConfiguration(tabWidth: 4))
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
    view.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
    return view
  }

  /// Types one character the way a key press does (through the assists).
  @MainActor private func type(_ c: Character, in view: CodeTextView) {
    let unit = String(c).utf16.first!
    if !view.assistTyping(unit, selection: view.selectedRange()) {
      view.insertText(String(c), replacementRange: view.selectedRange())
    }
  }

  @MainActor @Suite struct EditAssistTests {
    @Test func bracketsAutoCloseAndTypeOver() {
      let view = editor("let x = ")
      type("(", in: view)
      #expect(view.string == "let x = ()")
      #expect(view.selectedRange().location == 9)
      type("1", in: view)
      type(")", in: view)
      #expect(view.string == "let x = (1)")
      #expect(view.selectedRange().location == 11)
    }

    @Test func backspaceDeletesAnAutoClosedPair() {
      let view = editor("f")
      type("[", in: view)
      #expect(view.string == "f[]")
      view.deleteBackward(nil)
      #expect(view.string == "f")
    }

    @Test func noAutoCloseBeforeWordsAfterLettersOrInStrings() {
      let beforeWord = editor("value", caret: 0)
      type("(", in: beforeWord)
      #expect(beforeWord.string == "(value")
      let afterLetter = editor("abc")
      type("\"", in: afterLetter)
      #expect(afterLetter.string == "abc\"")
      let inString = editor("let s = \"ab\"", caret: 11)
      type("(", in: inString)
      #expect(inString.string == "let s = \"ab(\"")
      let swiftApostrophe = editor("x = ")
      type("'", in: swiftApostrophe)  // Swift has no '…' literals
      #expect(swiftApostrophe.string == "x = '")
    }

    @Test func typingADelimiterWrapsTheSelection() {
      let view = editor("call abc")
      view.setSelectedRange(NSRange(location: 5, length: 3))
      type("(", in: view)
      #expect(view.string == "call (abc)")
      #expect(view.selectedRange() == NSRange(location: 6, length: 3))
      type("\"", in: view)
      #expect(view.string == "call (\"abc\")")
    }

    @Test func closerOnABlankLineTakesItsOpenersIndentation() {
      let view = editor("  func f() {\n        ")
      type("}", in: view)
      #expect(view.string == "  func f() {\n  }")
    }

    @Test func returnAfterAnUnclosedBraceAddsTheCloser() {
      let view = editor("func f() {")
      view.insertNewline(nil)
      #expect(view.string == "func f() {\n    \n}")
      #expect(view.selectedRange().location == 15)
      // Balanced already: no second closer.
      let balanced = editor("func f() {\n}", caret: 10)
      balanced.insertNewline(nil)
      #expect(balanced.string == "func f() {\n    \n}")
    }

    @Test func returnContinuesDocComments() {
      let view = editor("  /// Summary.")
      view.insertNewline(nil)
      #expect(view.string == "  /// Summary.\n  /// ")
    }

    @Test func backspaceInIndentationDeletesToTheTabStop() {
      let view = editor("        x", caret: 8)
      view.deleteBackward(nil)
      #expect(view.string == "    x")
      let uneven = editor("      x", caret: 6)
      uneven.deleteBackward(nil)
      #expect(uneven.string == "    x")
    }

    @Test func commandLeftGoesToTheIndentationFirst() {
      let view = editor("    let a = 1", caret: 9)
      #expect(view.moveToLineIndentation(extending: false))
      #expect(view.selectedRange().location == 4)
      #expect(view.moveToLineIndentation(extending: false))
      #expect(view.selectedRange().location == 0)
    }

    @Test func doubleClickOnABracketSelectsTheBlock() {
      let view = editor("f(a, \")\", [b])")
      #expect(view.delimitedBlock(at: NSRange(location: 1, length: 0)) == NSRange(location: 1, length: 13))
      #expect(view.delimitedBlock(at: NSRange(location: 13, length: 1)) == NSRange(location: 1, length: 13))
    }

    @Test func doubleClickSelectsOneIdentifierAcrossDots() {
      let view = editor("workspace.flushAll($0)")
      let word = { (at: Int) in
        view.selectionRange(forProposedRange: NSRange(location: at, length: 0), granularity: .selectByWord)
      }
      #expect(word(3) == NSRange(location: 0, length: 9))
      #expect(word(12) == NSRange(location: 10, length: 8))
      #expect(word(9) == NSRange(location: 9, length: 1))
      #expect(word(20) == NSRange(location: 19, length: 2))
      // Dragging by words from one name to the next.
      let drag = view.selectionRange(
        forProposedRange: NSRange(location: 3, length: 9), granularity: .selectByWord)
      #expect(drag == NSRange(location: 0, length: 18))
    }

    @Test func tabOnAnEmptyLineIndentsToItsBlock() {
      let text = "struct S {\n    var body: some View {\n\n    }\n}"
      let empty = (text as NSString).range(of: "\n\n").location + 1
      let view = editor(text, caret: empty)
      view.insertTab(nil)
      #expect(view.string == "struct S {\n    var body: some View {\n        \n    }\n}")
      #expect(view.selectedRange().location == empty + 8)
      // Indented that far already: one more level, as before.
      view.insertTab(nil)
      #expect(view.selectedRange().location == empty + 12)
      // Short of a closing brace's level, the opener's.
      let closer = editor("f {\n  x\n}", caret: 8)
      closer.insertTab(nil)
      #expect(closer.string == "f {\n  x\n    }")
      let under = editor("a {\n}", caret: 4)
      under.insertTab(nil)
      #expect(under.string == "a {\n    }")
    }

    @Test func optionArrowsMoveByNames() {
      let view = editor("x = Some.value + 1", caret: 4)
      view.moveWordRight(nil)
      #expect(view.selectedRange().location == 8)
      view.moveWordRight(nil)
      #expect(view.selectedRange().location == 14)
      view.moveWordLeft(nil)
      #expect(view.selectedRange().location == 8)  // ".value", the dot with its name
      view.moveWordLeft(nil)
      #expect(view.selectedRange().location == 4)
    }

    @Test func optionArrowsTakeAStringLiteralAsOneWord() {
      let view = editor("print(\"Hello World\")", caret: 6)
      view.moveWordRight(nil)
      #expect(view.selectedRange().location == 19)
      view.moveWordLeft(nil)
      #expect(view.selectedRange().location == 6)
      view.moveWordLeft(nil)
      #expect(view.selectedRange().location == 5)  // the bracket
      view.moveWordLeft(nil)
      #expect(view.selectedRange().location == 0)
      // Inside the string, word by word.
      view.setSelectedRange(NSRange(location: 7, length: 0))
      view.moveWordRight(nil)
      #expect(view.selectedRange().location == 12)
      // From before "print": the name first, the bracket, then the string.
      view.setSelectedRange(NSRange(location: 0, length: 0))
      view.moveWordRight(nil)
      #expect(view.selectedRange().location == 5)
      view.moveWordRight(nil)
      #expect(view.selectedRange().location == 6)
      view.moveWordRight(nil)
      #expect(view.selectedRange().location == 19)
      // Interpolations and raw strings stay in the one word; an unclosed string doesn't count.
      let interpolated = editor("f(\"a \\(b + 1) c\", #\"r\"#)", caret: 2)
      interpolated.moveWordRight(nil)
      #expect(interpolated.selectedRange().location == 16)
      interpolated.moveWordRight(nil)
      #expect(interpolated.selectedRange().location == 17)
      interpolated.moveWordRight(nil)
      #expect(interpolated.selectedRange().location == 23)
      let unclosed = editor("f(\"ab cd", caret: 2)
      unclosed.moveWordRight(nil)
      #expect(unclosed.selectedRange().location == 5)
    }

    @Test func shiftOptionArrowsExtendFromTheSameEnd() {
      let view = editor("a.bc.d", caret: 4)
      view.moveWordLeftAndModifySelection(nil)
      #expect(view.selectedRange() == NSRange(location: 1, length: 3))
      view.moveWordLeftAndModifySelection(nil)
      #expect(view.selectedRange() == NSRange(location: 0, length: 4))
      view.moveWordRightAndModifySelection(nil)
      #expect(view.selectedRange() == NSRange(location: 1, length: 3))
      view.moveWordRightAndModifySelection(nil)
      view.moveWordRightAndModifySelection(nil)
      #expect(view.selectedRange() == NSRange(location: 4, length: 2))
    }

    @Test func optionDeleteDeletesOneName() {
      let view = editor("Some.value")
      view.deleteWordBackward(nil)
      #expect(view.string == "Some")
      view.deleteWordBackward(nil)
      #expect(view.string == "")
      view.undoManager?.undo()
      let string = editor("x(\"a b\")", caret: 2)
      string.deleteWordForward(nil)
      #expect(string.string == "x()")
    }

    @Test func doubleClickOnAQuoteSelectsTheString() {
      let view = editor("print(\"Hello \\\"World\")")
      let word = { (at: Int) in
        view.selectionRange(forProposedRange: NSRange(location: at, length: 0), granularity: .selectByWord)
      }
      #expect(word(6) == NSRange(location: 6, length: 15))
      #expect(word(20) == NSRange(location: 6, length: 15))
      #expect(word(14) == NSRange(location: 14, length: 1))  // an escaped quote is itself
      #expect(word(8) == NSRange(location: 7, length: 5))  // a word inside, as before
    }

    /// The stops of ⌥→ (or ⌃→ with `subwords`) from the start, marked with "|".
    private func stops(_ text: String, _ language: String = "swift", subwords: Bool = false) -> String {
      let view = editor(text, caret: 0, language)
      let ns = text as NSString
      var marks: [Int] = []
      var i = 0
      while i < ns.length {
        i = subwords ? view.subwordBoundary(from: i, forward: true) : view.wordBoundary(from: i, forward: true)
        marks.append(i)
      }
      let out = NSMutableString(string: text)
      for mark in marks.reversed() { out.insert("|", at: mark) }
      return out as String
    }

    @Test func optionArrowsTakeNumbersPrefixedStringsAndContractionsWhole() {
      #expect(stops("x = 3.14 + 0x1F + 1e-5") == "x| =| 3.14| +| 0x1F| +| 1e-5|")
      #expect(stops("// don't use it") == "// don't| use| it|")
      #expect(stops("s = \"it's ok\"") == "s| =| \"it's ok\"|")
      #expect(stops("f(r\"x y\", b'z')", "python") == "f|(|r\"x y\"|,| b'z'|)|")
      #expect(stops("s = @\"Hello World\";", "objective-c") == "s| =| @\"Hello World\"|;|")
      // A multi-line string's opening quotes are a stop, then the caret goes into it.
      #expect(stops("s = \"\"\"\n  hi\n  \"\"\"") == "s| =| \"\"\"|\n  hi|\n  \"\"\"|")
    }

    @Test func optionArrowsStopAtPunctuationAndLineEnds() {
      #expect(
        stops("    Text(\"Hello World\").font(.system(size: 24))\n  }\n}\n\nstruct S {")
          == "    Text|(|\"Hello World\"|)|.font|(|.system|(|size|:| 24|))|\n  }|\n}|\n\nstruct| S| {|")
      #expect(stops("a -> [Int]? // e.g. this") == "a| ->| [|Int|]?| // e|.g|. this|")
      #expect(stops("// a, b.\n\nx") == "// a|, b|.|\n\nx|")
    }

    @Test func doubleClickSelectsWholeNumbersContractionsAndMultilineStrings() {
      let word = { (text: String, language: String, at: Int) -> String in
        let view = editor(text, caret: 0, language)
        let range = view.selectionRange(
          forProposedRange: NSRange(location: at, length: 0), granularity: .selectByWord)
        return (text as NSString).substring(with: range)
      }
      #expect(word("x = 3.14", "swift", 6) == "3.14")
      #expect(word("// don't", "swift", 4) == "don't")
      #expect(word("f'x'", "python", 0) == "f")
      #expect(word("f(r\"x y\")", "python", 3) == "r\"x y\"")
      let multiline = "s = \"\"\"\n  hi\n  \"\"\""
      #expect(word(multiline, "swift", 5) == "\"\"\"\n  hi\n  \"\"\"")
      #expect(word(multiline, "swift", 17) == "\"\"\"\n  hi\n  \"\"\"")
      #expect(word("x = '''\nab\n\ncd'''", "python", 15) == "'''\nab\n\ncd'''")
      let raw = "s = #\"\"\"\n  hi\n  \"\"\"#"
      #expect(word(raw, "swift", 6) == "#\"\"\"\n  hi\n  \"\"\"#")
      #expect(word(raw, "swift", 18) == "#\"\"\"\n  hi\n  \"\"\"#")
      #expect(word("x = `a\n\nb`", "javascript", 4) == "`a\n\nb`")
    }

    @Test func controlArrowsMoveBySubwords() {
      #expect(
        stops("camelCase URLSession snake_case utf8", subwords: true)
          == "camel|Case| URL|Session| snake|_case| utf|8|")
      let view = editor("URLSession")
      view.moveSubwordBackward(nil)
      #expect(view.selectedRange().location == 3)
      view.moveSubwordBackwardAndModifySelection(nil)
      #expect(view.selectedRange() == NSRange(location: 0, length: 3))
      let key = { (flags: NSEvent.ModifierFlags, arrow: Int) -> NSEvent in
        let character = String(UnicodeScalar(UInt16(arrow))!)
        return NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: flags.union(.function), timestamp: 0, windowNumber: 0,
          context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false,
          keyCode: 0)!
      }
      #expect(
        CodeTextView.subwordCommand(for: key(.control, NSRightArrowFunctionKey))
          == #selector(CodeTextView.moveSubwordForward(_:)))
      #expect(
        CodeTextView.subwordCommand(for: key([.control, .option, .shift], NSLeftArrowFunctionKey))
          == #selector(CodeTextView.moveSubwordBackwardAndModifySelection(_:)))
      #expect(CodeTextView.subwordCommand(for: key(.option, NSLeftArrowFunctionKey)) == nil)
      #expect(CodeTextView.subwordCommand(for: key([.control, .command], NSLeftArrowFunctionKey)) == nil)
    }

    @Test func saveTrimsTrailingWhitespaceOfEditedLinesOnly() {
      let view = editor("a\nb  \nc", caret: 1)
      view.insertText("  ", replacementRange: view.selectedRange())  // edits line 1
      view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
      #expect(view.trimTrailingWhitespace())
      // Line 2 had trailing spaces but wasn't edited: kept.
      #expect(view.string == "a\nb  \nc")
    }

    @Test func wrappedLinesIndentPastTheirIndentation() {
      let view = editor("    let a = 1\nb")
      let style = view.textStorage!.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
        as! NSParagraphStyle
      let space = (" " as NSString).size(withAttributes: [.font: view.baseFont]).width
      #expect(abs(style.headIndent - space * 8) < 0.01)
    }

    @Test func lastLineCanScrollToTheMiddle() {
      let text = String(repeating: "line\n", count: 100)
      let scrollView = CodeEditorScrollView(text: text, language: nil)
      scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
      scrollView.tile()
      let textView = scrollView.textView
      textView.layoutManager!.ensureLayout(for: textView.textContainer!)
      textView.sizeToFit()
      let content = textView.layoutManager!.usedRect(for: textView.textContainer!).height
      #expect(abs(textView.overscroll + textView.textContainerInset.height - 150) <= 1)
      #expect(textView.frame.height >= content + textView.overscroll)
    }
  }
#endif
