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
