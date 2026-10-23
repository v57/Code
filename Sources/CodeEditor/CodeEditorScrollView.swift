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
      // Attaching lays the text out before the clip view takes on the text
      // view's flippedness, and the layout manager moves the view to keep
      // its top edge in place in unflipped coordinates.
      textView.setFrameOrigin(.zero)
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
      if textView.configuration.wrapLines, abs(textView.frame.width - textView.visibleWidth) > 0.5 {
        textView.applyWrapping()
      }
      textView.updateOverscroll()
      clearFindBarBackground()
    }

    /// The find bar (⌘F) floats over the text as the window's other bars do: AppKit's band, the line it draws along
    /// its bottom and the scroll edge's blur go, and the editor's ground fades in behind its field and buttons, as
    /// ComponentKit's bars fade theirs.
    private func clearFindBarBackground() {
      for view in subviews {
        let name = String(describing: type(of: view))
        if name.contains("ScrollPocket") || name.contains("BackdropView") { view.isHidden = isFindBarVisible }
      }
      guard isFindBarVisible, let bar = findBarView, let banner = bar.subviews.first else { return }
      for view in banner.subviews {
        let name = String(describing: type(of: view))
        if name.contains("PocketView") || name.contains("DecorationView") { view.isHidden = true }
      }
      // On a layer of its own the bar stays above the text's layers, which run on under it; the banner draws the
      // line itself, so a mask leaves out the bar's bottom point.
      bar.wantsLayer = true
      if let layer = bar.layer {
        let mask = layer.mask ?? CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.frame = CGRect(x: 0, y: bar.isFlipped ? 0 : 1, width: bar.bounds.width, height: bar.bounds.height - 1)
        layer.mask = mask
      }
      let fade = banner.subviews.lazy.compactMap { $0 as? GroundFade }.first ?? {
        let fade = GroundFade()
        fade.autoresizingMask = [.width, .height]
        banner.addSubview(fade, positioned: .below, relativeTo: nil)
        return fade
      }()
      fade.frame = banner.bounds
      fade.show(backgroundColor)
    }
  }

  /// The ground behind the find bar's controls, fading out along its bottom edge instead of ending in a line (AppKit's
  /// controls are see-through, so the text under them must fade too).
  @MainActor private final class GroundFade: NSView {
    private let gradient = CAGradientLayer()

    init() {
      super.init(frame: .zero)
      layer = gradient
      wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ ground: NSColor) {
      effectiveAppearance.performAsCurrentDrawingAppearance {
        gradient.colors = [ground.withAlphaComponent(0.9), ground.withAlphaComponent(0.9), ground.withAlphaComponent(0)]
          .map(\.cgColor)
      }
      gradient.locations = [0, 0.7, 1]
      // Unflipped: y = 1 is the top.
      gradient.startPoint = CGPoint(x: 0.5, y: 1)
      gradient.endPoint = CGPoint(x: 0.5, y: 0)
    }
  }

  /// Shows one editor at a time and swaps editors (tab changes), moving
  /// focus along when the previous editor had it.
  @MainActor public final class CodeEditorHostView: NSView {
    public private(set) weak var current: NSView?
    private weak var currentTextView: NSView?

    public func show(_ editor: CodeEditorScrollView) {
      show(editor, focusing: editor.textView)
    }

    /// Shows `editor` (an editor with views around it, like a minimap),
    /// moving focus to `textView` when the previous editor had it.
    public func show(_ editor: NSView, focusing textView: NSView) {
      guard editor !== current else { return }
      let hadFocus = window?.firstResponder is CodeTextView
      // The editor may have moved to another host since (a document opened
      // in its own window); leave it there.
      if current?.superview === self { current?.removeFromSuperview() }
      editor.frame = bounds
      editor.autoresizingMask = [.width, .height]
      addSubview(editor)
      current = editor
      currentTextView = textView
      if hadFocus { window?.makeFirstResponder(textView) }
    }

    /// The part of the window, from its top-left corner (SwiftUI's global space), that bars floating over the
    /// editor leave clear: the host turns it into insets for the editor, whose text runs on under the bars.
    public var unobscuredFrame: CGRect? {
      didSet { if unobscuredFrame != oldValue { needsLayout = true } }
    }
    /// How far the bars reach in from the host's top and bottom (from `unobscuredFrame`).
    public private(set) var contentInsets = NSEdgeInsets()
    /// Called when `contentInsets` change.
    public var onContentInsetsChange: ((NSEdgeInsets) -> Void)?

    public override func layout() {
      super.layout()
      updateContentInsets()
    }

    private func updateContentInsets() {
      var insets = NSEdgeInsets()
      if let clear = unobscuredFrame, let height = window?.contentView?.bounds.height {
        let frame = convert(bounds, to: nil)
        let top = height - frame.maxY
        let bottom = height - frame.minY
        insets.top = max(0, clear.minY - top)
        insets.bottom = max(0, bottom - clear.maxY)
      }
      guard insets.top != contentInsets.top || insets.bottom != contentInsets.bottom else { return }
      contentInsets = insets
      onContentInsetsChange?(insets)
    }

    public override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // A new window (or tab) opens with the caret in the editor.
      if let textView = currentTextView, window?.firstResponder === window {
        window?.makeFirstResponder(textView)
      }
    }
  }
#endif
