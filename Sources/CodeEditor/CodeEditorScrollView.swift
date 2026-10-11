#if canImport(AppKit)
  import AppKit
  import CodeHighlighting

  /// The editor as an AppKit view: a scroll view holding a `CodeTextView`
  /// and its line numbers. Hosts keep one per open file, so a file brought
  /// back keeps its undo history, selection and scroll position.
  @MainActor public final class CodeEditorScrollView: NSScrollView {
    public let textView: CodeTextView
    private let ruler: LineNumberRuler

    public init(
      text: String, language: LanguageSpec?, highlightsSyntax: Bool = true,
      configuration: EditorConfiguration = EditorConfiguration()
    ) {
      textView = CodeTextView(
        text: text, spec: language, highlightsSyntax: highlightsSyntax, configuration: configuration)
      ruler = LineNumberRuler(textView: textView)
      super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
      hasVerticalScroller = true
      hasHorizontalScroller = !configuration.wrapLines
      autohidesScrollers = true
      borderType = .noBorder
      drawsBackground = true
      documentView = textView
      verticalRulerView = ruler
      ruler.clientView = textView
      hasVerticalRuler = true
      rulersVisible = configuration.showLineNumbers
      textView.applyWrapping()
      ruler.updateThickness()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func tile() {
      super.tile()
      // A wrapped container must follow width changes (window resize,
      // sidebar toggle, ruler width change); the overscroll follows height.
      if textView.configuration.wrapLines,
        let container = textView.textContainer,
        abs(container.size.width - contentSize.width) > 0.5
      {
        textView.applyWrapping()
      }
      textView.updateOverscroll()
    }
  }

  /// Shows one editor at a time and swaps editors (tab changes), moving
  /// focus along when the previous editor had it.
  @MainActor public final class CodeEditorHostView: NSView {
    public private(set) weak var current: CodeEditorScrollView?

    public func show(_ editor: CodeEditorScrollView) {
      guard editor !== current else { return }
      let hadFocus = window?.firstResponder is CodeTextView
      current?.removeFromSuperview()
      editor.frame = bounds
      editor.autoresizingMask = [.width, .height]
      addSubview(editor)
      current = editor
      if hadFocus { window?.makeFirstResponder(editor.textView) }
    }

    public override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // A new window (or tab) opens with the caret in the editor.
      if let editor = current, window?.firstResponder === window {
        window?.makeFirstResponder(editor.textView)
      }
    }
  }
#endif
