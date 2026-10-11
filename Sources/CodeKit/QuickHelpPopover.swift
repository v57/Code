#if canImport(AppKit)
  import AppKit

  /// Xcode's Quick Help (⌥-click): a language server's hover text in a
  /// popover at the symbol, with its code in the editor's font.
  @MainActor enum QuickHelpPopover {
    private static var current: NSPopover?

    static func show(_ markdown: String, in textView: CodeTextView, at range: NSRange) {
      current?.close()
      let text = attributedText(markdown, codeFont: .monospacedSystemFont(ofSize: 12, weight: .regular))
      let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 10))
      view.isEditable = false
      view.isSelectable = true
      view.drawsBackground = false
      view.textContainerInset = NSSize(width: 10, height: 10)
      view.textStorage?.setAttributedString(text)
      view.textContainer?.widthTracksTextView = true
      view.layoutManager?.ensureLayout(for: view.textContainer!)
      let used = view.layoutManager?.usedRect(for: view.textContainer!).size ?? .zero
      let height = min(420, ceil(used.height) + 20)
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: height))
      scroll.hasVerticalScroller = used.height + 20 > 420
      scroll.drawsBackground = false
      view.frame = NSRect(x: 0, y: 0, width: 520, height: max(height, ceil(used.height) + 20))
      scroll.documentView = view
      let controller = NSViewController()
      controller.view = scroll
      let popover = NSPopover()
      popover.contentViewController = controller
      popover.behavior = .transient
      var rect = textView.firstRect(forCharacterRange: range, actualRange: nil)
      // Screen → view coordinates.
      if let window = textView.window {
        rect = textView.convert(window.convertFromScreen(rect), from: nil)
      }
      popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
      current = popover
    }

    /// Markdown as attributed text: fenced code in `codeFont`, the rest with
    /// inline Markdown (bold, code spans, links).
    static func attributedText(_ markdown: String, codeFont: NSFont) -> NSAttributedString {
      let result = NSMutableAttributedString()
      let body: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
      ]
      let code: [NSAttributedString.Key: Any] = [.font: codeFont, .foregroundColor: NSColor.labelColor]
      var inCode = false
      var paragraph: [String] = []
      func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        let text = paragraph.joined(separator: "\n")
        paragraph = []
        if let parsed = try? AttributedString(
          markdown: text,
          options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        {
          let string = NSMutableAttributedString(parsed)
          string.addAttributes(body, range: NSRange(location: 0, length: string.length))
          result.append(string)
        } else {
          result.append(NSAttributedString(string: text, attributes: body))
        }
        result.append(NSAttributedString(string: "\n", attributes: body))
      }
      for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("```") {
          flushParagraph()
          inCode.toggle()
          continue
        }
        if inCode {
          result.append(NSAttributedString(string: line + "\n", attributes: code))
        } else if line.trimmingCharacters(in: .whitespaces) == "---" {
          flushParagraph()
          result.append(NSAttributedString(string: "\n", attributes: body))
        } else {
          paragraph.append(String(line))
        }
      }
      flushParagraph()
      while result.string.hasSuffix("\n") {
        result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
      }
      return result
    }
  }
#endif
