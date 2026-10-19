#if canImport(AppKit)
  import AppKit
  import Testing

  import CodeHighlighting
  @testable import CodeEditor

  @MainActor private func makeEditor(_ text: String, _ language: String = "swift") -> CodeTextView {
    let view = CodeTextView(
      text: text, spec: CodeHighlighter.spec(forLanguage: language), highlightsSyntax: true,
      configuration: EditorConfiguration(themeID: "github-light"))
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
    view.setSelectedRange(NSRange(location: 0, length: 0))
    return view
  }

  /// Renders `view` and returns whether any pixel is close to `hex`.
  @MainActor private func draws(_ view: NSView, color hex: UInt32) -> Bool {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: rep)
    let target = NSColor(hex: hex)
    for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
      for y in stride(from: 0, to: min(rep.pixelsHigh, 60), by: 1) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        if abs(c.redComponent - target.redComponent) < 0.04
          && abs(c.greenComponent - target.greenComponent) < 0.04
          && abs(c.blueComponent - target.blueComponent) < 0.04
        {
          return true
        }
      }
    }
    return false
  }

  @MainActor @Suite struct EditorTests {
    /// A long text's lines get their indents a batch per run-loop turn after opening (all at once stalled it),
    /// down to the last line.
    @Test func longTextGetsEveryLineIndentInBatches() async throws {
      let count = CodeTextView.lineAttributesBatch * 3
      let view = makeEditor((0..<count).map { "    let value\($0) = \($0)" }.joined(separator: "\n"))
      let storage = try #require(view.textStorage)
      func headIndent(ofLine line: Int) -> CGFloat {
        let style = storage.attribute(.paragraphStyle, at: view.lineIndex.starts[line], effectiveRange: nil)
        return (style as? NSParagraphStyle)?.headIndent ?? 0
      }
      // Four spaces of indent, plus four for wrapped rows.
      let expected = headIndent(ofLine: 0)
      #expect(expected > 0)
      for _ in 0..<200 where headIndent(ofLine: count - 1) != expected {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(headIndent(ofLine: count - 1) == expected)
      #expect(headIndent(ofLine: count / 2) == expected)
    }

    @Test func drawsKeywordColorsFromTheHighlighter() {
      let view = makeEditor("return return return return\n")
      #expect(draws(view, color: EditorTheme.githubLight.syntax.keyword))
      let plain = makeEditor("hello hello hello hello\n", "nonexistent")
      #expect(!draws(plain, color: EditorTheme.githubLight.syntax.keyword))
    }

    @Test func newlineKeepsIndentationAndSplitsBrackets() {
      let view = makeEditor("  func f() {}")
      view.setSelectedRange(NSRange(location: 12, length: 0))  // between { and }
      view.insertNewline(nil)
      #expect(view.string == "  func f() {\n      \n  }")
      #expect(view.selectedRange() == NSRange(location: 19, length: 0))
    }

    @Test func tabIndentsAndBacktabOutdentsSelectedLines() {
      let view = makeEditor("a\nb\nc")
      view.setSelectedRange(NSRange(location: 0, length: 3))
      view.insertTab(nil)
      #expect(view.string == "    a\n    b\nc")
      view.insertBacktab(nil)
      #expect(view.string == "a\nb\nc")
      view.undoManager?.undo()
    }

    @Test func toggleCommentRoundTrips() {
      let view = makeEditor("  let a = 1\n    let b = 2\n")
      view.setSelectedRange(NSRange(location: 0, length: 20))
      view.toggleComment(nil)
      #expect(view.string == "  // let a = 1\n  //   let b = 2\n")
      view.toggleComment(nil)
      #expect(view.string == "  let a = 1\n    let b = 2\n")
      let html = makeEditor("<p>hi</p>", "html")
      html.toggleComment(nil)
      #expect(html.string == "<!-- <p>hi</p> -->")
    }

    @Test func lineIndexFollowsEditsAndSelectionReportsLineAndColumn() {
      let view = makeEditor("one\ntwo\n")
      view.setSelectedRange(NSRange(location: 4, length: 0))
      view.insertText("x\n", replacementRange: view.selectedRange())
      #expect(view.lineIndex == LineIndex(view.string))
      #expect(view.currentSelection == EditorSelection(line: 3, column: 1, length: 0, lineCount: 1))
    }

    @Test func crlfFilesGetCrlfNewlines() {
      let view = makeEditor("a\r\nb")
      view.setSelectedRange(NSRange(location: 1, length: 0))
      view.insertNewline(nil)
      #expect(view.string == "a\r\n\r\nb")
    }
  }
#endif
