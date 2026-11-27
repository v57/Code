#if canImport(AppKit)
  import AppKit
  import Testing

  import CodeHighlighting
  @testable import CodeEditor

  @MainActor struct LineBreakTests {
    static let text = """
      struct A {
        @MainActor var separateStatus: Bool {
          switch body {
          case .emoji, .sticker, .post, .circle, .gift, .tradeRequest: true
          case .attachments(let attachments): !attachments.isVoiceMessage
          case .text, .localized, .previewText, .poll, .empty, .unknown, .contact, .social, .call, .giveaway,
            .story:
            false
          }
        }
      }
      """

    /// The rows line 6 (`case .text, …`) wraps into at `width`.
    private func rows(width: CGFloat, theme: String) async throws -> [String] {
      let scrollView = CodeEditorScrollView(
        text: Self.text, language: CodeHighlighter.spec(forLanguage: "swift"),
        configuration: EditorConfiguration(themeID: theme))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.titled], backing: .buffered,
        defer: true)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 400)
      window.contentView?.addSubview(scrollView)
      let view = scrollView.textView
      view.applyWrapping()
      // The wrapped rows' indent is set a turn later.
      try await Task.sleep(for: .milliseconds(30))
      let layoutManager = view.layoutManager!
      let range = view.lineIndex.range(ofLine: 5)
      layoutManager.ensureLayout(forCharacterRange: range)
      let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      var rows: [String] = []
      var glyph = glyphs.location
      while glyph < NSMaxRange(glyphs) {
        var effective = NSRange()
        _ = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
        let characters = layoutManager.characterRange(forGlyphRange: effective, actualGlyphRange: nil)
        rows.append((view.string as NSString).substring(with: characters))
        glyph = NSMaxRange(effective)
      }
      return rows
    }

    /// AppKit never breaks before a period, so this line's only break was after its indentation: an empty first
    /// row, then rows cut inside words.
    @Test(arguments: ["github-light", "xcode-light"])
    func enumCasesWrapBetweenWords(theme: String) async throws {
      for width in stride(from: 800, through: 300, by: -23) {
        let rows = try await rows(width: CGFloat(width), theme: theme)
        #expect(rows.count > 1, "width \(width)")
        #expect(rows.first?.hasPrefix("    case ") == true, "width \(width): \(rows)")
        for row in rows.dropLast() { #expect(row.hasSuffix(", "), "width \(width): \(rows)") }
        #expect(rows.joined() == "    case .text, .localized, .previewText, .poll, .empty, .unknown, .contact, .social, .call, .giveaway,\n")
      }
    }

    private func breakPoint(_ text: String, before location: Int, from start: Int = 0, appKit: Int? = nil) -> Int {
      CodeLineBreaks.lineBreak(
        before: location, within: NSRange(location: start, length: location - start), in: text as NSString,
        appKit: appKit ?? start)
    }

    @Test func breaksAfterWhitespace() {
      //          0123456789012345678
      let line = "    case .a, .b, .c"
      #expect(breakPoint(line, before: 18) == 17)
      #expect(breakPoint(line, before: 16) == 13)
      // Not after the indentation: the row would be empty.
      #expect(breakPoint(line, before: 7) == 0)
      #expect(breakPoint(line, before: 12) == 9)
    }

    @Test func breaksAtPunctuationWithoutSpaces() {
      //          01234567890123456789
      let line = "alpha.beta(gamma,delta)"
      #expect(breakPoint(line, before: 20) == 17)
      #expect(breakPoint(line, before: 15) == 11)
      #expect(breakPoint(line, before: 8) == 5)
      // Nothing to break at: the typesetter cuts at the width.
      #expect(breakPoint(line, before: 4) == 0)
      // A later row starts where the last one broke.
      #expect(breakPoint(line, before: 15, from: 11) == 11)
    }

    @Test func keepsAppKitsBreakInTextWithoutSpaces() {
      #expect(breakPoint("// 日本語のコメントです", before: 10, appKit: 9) == 9)
    }
  }
#endif
