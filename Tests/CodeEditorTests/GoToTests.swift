#if canImport(AppKit)
  import AppKit
  import Testing

  import CodeHighlighting
  @testable import CodeEditor

  @MainActor struct GoToTests {
    /// Long lines among short ones, so wrapped rows make the heights of text not laid out yet a poor guess.
    private static let text: String = (1...3000).map { line in
      line % 3 == 0
        ? "let value\(line) = " + String(repeating: "someFunction(argument: \(line)) + ", count: 12) + "0"
        : "// line \(line)"
    }.joined(separator: "\n")

    private func makeEditor() -> (CodeEditorScrollView, NSWindow) {
      let scrollView = CodeEditorScrollView(
        text: Self.text, language: CodeHighlighter.spec(forLanguage: "swift"),
        configuration: EditorConfiguration(themeID: "github-light"))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered,
        defer: true)
      window.isReleasedWhenClosed = false
      scrollView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
      window.contentView?.addSubview(scrollView)
      scrollView.textView.applyWrapping()
      return (scrollView, window)
    }

    /// How far the middle of `line` (from 1) is from the middle of what the scroll view shows.
    private func offCenter(_ line: Int, in view: CodeTextView) -> CGFloat {
      let layoutManager = view.layoutManager!
      let location = view.lineIndex.starts[line - 1]
      let glyphs = layoutManager.glyphRange(
        forCharacterRange: NSRange(location: location, length: 0), actualCharacterRange: nil)
      let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: view.textContainer!)
      return abs(rect.midY + view.textContainerOrigin.y - view.visibleRect.midY)
    }

    private func settle(_ view: CodeTextView) async throws {
      for _ in 0..<2000 {
        if view.layoutManager!.firstUnlaidCharacterIndex() >= view.textStorage!.length { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      try await Task.sleep(for: .milliseconds(50))
    }

    /// A jump into text that isn't laid out yet (a file just opened) ends on its line once the layout is done.
    @Test func aJumpBeforeLayoutEndsOnItsLine() async throws {
      let (scrollView, window) = makeEditor()
      defer { window.close() }
      let view = scrollView.textView
      view.goTo(line: 2500)
      #expect(offCenter(2500, in: view) < 30)
      try await settle(view)
      #expect(view.layoutManager!.firstUnlaidCharacterIndex() >= view.textStorage!.length)
      #expect(offCenter(2500, in: view) < 30)
    }

    /// The same after the width changed, which lays every wrapped line out again.
    @Test func aJumpAfterAWidthChangeEndsOnItsLine() async throws {
      let (scrollView, window) = makeEditor()
      defer { window.close() }
      let view = scrollView.textView
      try await settle(view)
      scrollView.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
      view.applyWrapping()
      view.goTo(line: 2500)
      try await settle(view)
      #expect(offCenter(2500, in: view) < 30)
    }
  }
#endif
