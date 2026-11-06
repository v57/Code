#if canImport(AppKit)
  import AppKit

  /// Xcode's Quick Help (⌥-click): a language server's hover text in a
  /// popover at the symbol, with its code in the editor's font.
  @MainActor enum QuickHelpPopover {
    private static var current: NSPopover?
    /// The ⌘-hover's popover, which stays until the hover ends (`closeHover`), and where it points.
    private static var hover: NSPopover?
    private static var hoverTarget: (view: CodeTextView, range: NSRange)?

    static func show(_ markdown: String, in textView: CodeTextView, at range: NSRange) {
      current?.close()
      closeHover()
      let popover = NSPopover()
      popover.contentViewController = controller(markdown)
      popover.behavior = .transient
      popover.show(relativeTo: rect(of: range, in: textView), of: textView, preferredEdge: .maxY)
      current = popover
    }

    /// What ⌘ held over a symbol shows: under it, closed by the editor when the hover ends, and updated in place when
    /// a later answer (the language server's) adds to it.
    static func showHover(_ markdown: String, in textView: CodeTextView, at range: NSRange) {
      if let hover, hover.isShown, let target = hoverTarget, target.view === textView, target.range == range {
        let controller = controller(markdown)
        hover.contentViewController = controller
        hover.contentSize = controller.view.frame.size
        return
      }
      closeHover()
      let popover = NSPopover()
      popover.contentViewController = controller(markdown)
      // Not transient: the editor closes it (moving off the symbol, letting go of ⌘), and clicks go to the editor.
      popover.behavior = .applicationDefined
      popover.show(relativeTo: rect(of: range, in: textView), of: textView, preferredEdge: .maxY)
      hover = popover
      hoverTarget = (textView, range)
    }

    static func closeHover() {
      hover?.close()
      hover = nil
      hoverTarget = nil
    }

    /// The text in a scroll view 520 wide, up to 420 high.
    private static func controller(_ markdown: String) -> NSViewController {
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
      // Short text keeps a narrow popover.
      let width = min(520, max(160, ceil(used.width) + 24))
      let height = min(420, ceil(used.height) + 20)
      let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
      scroll.hasVerticalScroller = used.height + 20 > 420
      scroll.drawsBackground = false
      view.frame = NSRect(x: 0, y: 0, width: width, height: max(height, ceil(used.height) + 20))
      scroll.documentView = view
      let controller = NSViewController()
      controller.view = scroll
      return controller
    }

    /// The range's first line in the view's coordinates.
    private static func rect(of range: NSRange, in textView: CodeTextView) -> NSRect {
      var rect = textView.firstRect(forCharacterRange: range, actualRange: nil)
      // Screen → view coordinates.
      if let window = textView.window {
        rect = textView.convert(window.convertFromScreen(rect), from: nil)
      }
      return rect
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
