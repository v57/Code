#if canImport(AppKit)
  import AppKit
  import CodeAutocompletion
  import CodeMinimap
  import SwiftUI

  /// What an editor shows besides the text, from the app's settings.
  public struct EditorFeatures: Equatable, Sendable {
    public var showsMinimap = true
    public var showsIssueMessages = true
    public var breakpointsEnabled = true
    /// The completion list opens while typing (else only with Esc and
    /// ⌃Space).
    public var suggestsCompletions = true

    public init(
      showsMinimap: Bool = true, showsIssueMessages: Bool = true, breakpointsEnabled: Bool = true,
      suggestsCompletions: Bool = true
    ) {
      self.showsMinimap = showsMinimap
      self.showsIssueMessages = showsIssueMessages
      self.breakpointsEnabled = breakpointsEnabled
      self.suggestsCompletions = suggestsCompletions
    }
  }

  /// The editor of one workspace document: CodeEditor's view, fed from a
  /// `TextDocument` and saving through it, with the minimap beside it. Kept
  /// in `TextDocument.editorState` so a tab brought back shows the same undo
  /// history, selection and scroll position.
  @MainActor final class DocumentEditor {
    let scrollView: CodeEditorScrollView
    let container: EditorContainerView
    let completion: CompletionController
    private let completionProvider: DocumentCompletionProvider
    /// The document revision whose text the editor shows.
    var appliedRevision: Int
    private weak var services: ProjectServices?
    private var appliedAnnotations: [LineAnnotation]?
    private var sectionsTask: Task<Void, Never>?
    private var minimapSource: MinimapAdapter?

    init(document: TextDocument, configuration: EditorConfiguration) {
      scrollView = CodeEditorScrollView(
        text: document.text, language: document.language,
        highlightsSyntax: document.highlightsSyntax, configuration: configuration)
      container = EditorContainerView(scrollView: scrollView)
      completionProvider = DocumentCompletionProvider(textView: scrollView.textView)
      completionProvider.document = document
      completion = CompletionController(textView: scrollView.textView, provider: completionProvider)
      appliedRevision = document.revision
      attach(to: document)
      let source = MinimapAdapter(textView: scrollView.textView)
      minimapSource = source
      container.minimap.dataSource = source
      let textView = scrollView.textView
      textView.onLayoutChange = { [weak self] in self?.layoutChanged() }
      scrollView.contentView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.container.minimap.refresh() }
      }
      updateSections()
    }

    /// The editor for `document`, made on first use.
    static func editor(for document: TextDocument, configuration: EditorConfiguration)
      -> DocumentEditor
    {
      if let editor = document.editorState as? DocumentEditor { return editor }
      let editor = DocumentEditor(document: document, configuration: configuration)
      document.editorState = editor
      return editor
    }

    private func attach(to document: TextDocument) {
      let textView = scrollView.textView
      textView.onEdit = { [weak document, weak self] in
        document?.markEdited()
        self?.container.minimap.invalidateContent()
        self?.scheduleSections()
      }
      document.willSave = { [weak textView] in textView?.trimTrailingWhitespace() ?? false }
      // The text is copied out only when a save runs.
      document.textProvider = { [weak textView, weak document] in
        textView?.string ?? document?.text ?? ""
      }
    }

    /// Connects the editor to the project's services: language servers,
    /// formatting, breakpoints. Done once, on first show.
    func connect(_ services: ProjectServices, document: TextDocument) {
      guard self.services !== services else { return }
      self.services = services
      completionProvider.services = services
      let textView = scrollView.textView
      textView.onTextChange = { [weak services, weak document, weak textView] edit in
        guard let services, let document, let textView else { return }
        services.documentEdited(document, edit: edit, textView: textView)
      }
      textView.onCommandClick = { [weak services, weak document] location in
        guard let services, let document else { return false }
        services.jumpToDefinition(in: document, at: location)
        return true
      }
      textView.onOptionClick = { [weak services, weak document] location in
        guard let services, let document else { return false }
        services.showQuickHelp(in: document, at: location)
        return true
      }
      textView.onBreakpointsChange = { [weak services, weak document] lines in
        guard let services, let document else { return }
        services.setBreakpoints(lines, for: document.url)
      }
      document.preSave = { [weak services, weak document, weak textView] in
        guard let services, let document, let textView else { return }
        await services.formatBeforeSave(document, textView: textView)
      }
      document.didSave = { [weak services, weak document] text in
        guard let services, let document else { return }
        services.documentSaved(document, text: text)
      }
      services.documentShown(document, textView: textView)
    }

    /// Takes the document's text when it was replaced from outside (reloaded
    /// from disk), and its language when that changed.
    func sync(with document: TextDocument) {
      if document.revision != appliedRevision {
        appliedRevision = document.revision
        scrollView.textView.replaceAllText(document.text)
        attach(to: document)
        updateSections()
      }
      scrollView.textView.setLanguage(
        document.language, highlightsSyntax: document.highlightsSyntax)
    }

    /// Shows issues, breakpoints and the debugger's line from the services.
    func apply(_ services: ProjectServices?, document: TextDocument, features: EditorFeatures) {
      let textView = scrollView.textView
      container.showsMinimap = features.showsMinimap
      textView.showsAnnotationMessages = features.showsIssueMessages
      textView.allowsBreakpoints = features.breakpointsEnabled
      completion.suggestsWhileTyping = features.suggestsCompletions
      container.minimap.theme = textView.theme
      guard let services else { return }
      let annotations = services.annotations(for: document.url)
      if annotations != appliedAnnotations {
        appliedAnnotations = annotations
        textView.annotations = annotations
      }
      let breakpoints = features.breakpointsEnabled ? services.breakpoints(for: document.url) : []
      if textView.breakpoints != breakpoints { textView.breakpoints = breakpoints }
      textView.breakpointsActive = services.breakpointsActive
      let execution = services.executionLocation
      textView.executionLine =
        execution?.url == document.url.standardizedFileURL ? execution?.line : nil
      updateMarks()
    }

    /// Moves the caret where a jump asked for, once the text is shown.
    func applyPendingSelection(of document: TextDocument) {
      guard let (line, column, length) = document.pendingSelection else { return }
      document.pendingSelection = nil
      // After layout, so the jump scrolls to the right place.
      DispatchQueue.main.async { [weak textView = scrollView.textView] in
        textView?.goTo(line: line, column: column, length: length)
      }
    }

    // MARK: - Minimap

    private func layoutChanged() {
      updateMarks()
      container.minimap.invalidateContent()
    }

    private func updateMarks() {
      let textView = scrollView.textView
      var marks: [MinimapMark] = textView.annotations.map { annotation in
        let kind: MinimapMark.Kind =
          annotation.severity == .error ? .error : annotation.severity == .warning ? .warning : .note
        return MinimapMark(line: annotation.line, kind: kind)
      }
      marks += textView.breakpoints.map { MinimapMark(line: $0, kind: .breakpoint) }
      if let line = textView.executionLine { marks.append(MinimapMark(line: line, kind: .execution)) }
      container.minimap.marks = marks
    }

    private func scheduleSections() {
      sectionsTask?.cancel()
      sectionsTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        self?.updateSections()
      }
    }

    private func updateSections() {
      let textView = scrollView.textView
      guard let text = textView.textStorage?.mutableString else { return }
      container.minimap.sections = MinimapSections.find(in: text, lines: textView.lineIndex)
    }
  }

  /// The editor's scroll view with the minimap at its right, as in Xcode.
  @MainActor final class EditorContainerView: NSView {
    let scrollView: CodeEditorScrollView
    let minimap = MinimapView()

    /// Room at the top and bottom where the host's bars float over the editor: the text and the minimap run on under
    /// them, and start and end clear of them.
    var contentInsets = NSEdgeInsets() {
      didSet {
        guard contentInsets.top != oldValue.top || contentInsets.bottom != oldValue.bottom else { return }
        applyInsets(from: oldValue)
      }
    }

    var showsMinimap = true {
      didSet {
        guard showsMinimap != oldValue else { return }
        minimap.isHidden = !showsMinimap
        needsLayout = true
      }
    }

    init(scrollView: CodeEditorScrollView) {
      self.scrollView = scrollView
      super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
      addSubview(scrollView)
      addSubview(minimap)
      scrollView.automaticallyAdjustsContentInsets = false
    }

    /// Sets the scroll view's insets, keeping the text where it was on screen: an editor at its top stays at its top,
    /// clear of the bars.
    private func applyInsets(from old: NSEdgeInsets) {
      let clipView = scrollView.contentView
      var origin = clipView.bounds.origin
      origin.y -= contentInsets.top - old.top
      var insets = scrollView.contentInsets
      insets.top = contentInsets.top
      insets.bottom = contentInsets.bottom
      scrollView.contentInsets = insets
      minimap.contentInsets = NSEdgeInsets(top: contentInsets.top, left: 0, bottom: contentInsets.bottom, right: 0)
      clipView.scroll(to: clipView.constrainBoundsRect(NSRect(origin: origin, size: clipView.bounds.size)).origin)
      scrollView.reflectScrolledClipView(clipView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
      super.layout()
      // No minimap in a narrow editor.
      let width = showsMinimap && bounds.width > 500 ? MinimapView.defaultWidth : 0
      minimap.isHidden = width == 0
      // The minimap shows where the editor is; the scroller would repeat it.
      scrollView.hasVerticalScroller = width == 0
      scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width - width, height: bounds.height)
      minimap.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    }
  }

  /// Feeds the minimap from a text view: runs of text by syntax kind, the
  /// visible lines, and scrolling.
  @MainActor final class MinimapAdapter: MinimapDataSource {
    weak var textView: CodeTextView?

    init(textView: CodeTextView) {
      self.textView = textView
    }

    var minimapLineCount: Int { textView?.lineIndex.count ?? 0 }

    func minimapRuns(ofLine line: Int) -> [MinimapRun] {
      guard let textView, let text = textView.textStorage?.mutableString else { return [] }
      let lines = textView.lineIndex
      guard line < lines.count else { return [] }
      let content = lines.contentRange(ofLine: line, in: text)
      let tokens = textView.tokens(ofLine: line)
      let tabWidth = max(1, textView.configuration.tabWidth)
      var runs: [MinimapRun] = []
      var column = 0
      var tokenIndex = 0
      var current: MinimapRun?
      let limit = min(content.length, 300)
      for offset in 0..<limit {
        let location = content.location + offset
        let character = text.character(at: location)
        if character == 0x20 || character == 0x09 {
          if let run = current { runs.append(run) }
          current = nil
          column += character == 0x09 ? tabWidth - column % tabWidth : 1
          continue
        }
        while tokenIndex < tokens.count, NSMaxRange(tokens[tokenIndex].range) <= location { tokenIndex += 1 }
        let kind =
          tokenIndex < tokens.count && tokens[tokenIndex].range.location <= location
          ? tokens[tokenIndex].kind : .plainText
        if var run = current, run.kind == kind {
          run.length += 1
          current = run
        } else {
          if let run = current { runs.append(run) }
          current = MinimapRun(column: column, length: 1, kind: kind)
        }
        column += 1
      }
      if let run = current { runs.append(run) }
      return runs
    }

    var minimapVisibleLines: ClosedRange<Double> {
      guard let textView, let layoutManager = textView.layoutManager,
        let container = textView.textContainer, textView.lineIndex.count > 0
      else { return 0...0 }
      // What shows between the bars floating over the editor.
      let shown = unobscuredRect(of: textView)
      var visible = shown
      visible.origin.y -= textView.textContainerOrigin.y
      let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
      let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
      let lines = textView.lineIndex
      let first = lines.line(containing: characters.location)
      let last = lines.line(containing: max(characters.location, NSMaxRange(characters) - 1))
      // The fraction of the first line scrolled away, and of the last one shown: whole lines at the bottom made the
      // count jump by a line as the editor scrolled, which the minimap's drag multiplied into jumps near the end.
      var start = Double(first)
      if let rect = textView.rect(ofLine: first), rect.height > 0 {
        let hidden = (shown.minY - rect.minY) / rect.height
        start += Double(min(max(hidden, 0), 1))
      }
      var end = Double(last + 1)
      if let rect = textView.rect(ofLine: last), rect.height > 0 {
        let fraction = (shown.maxY - rect.minY) / rect.height
        end = Double(last) + Double(min(max(fraction, 0), 1))
      }
      return start...max(start, end)
    }

    func minimapScroll(toTopLine line: Double) {
      guard let textView, let scrollView = textView.enclosingScrollView else { return }
      let index = min(max(Int(line), 0), max(textView.lineIndex.count - 1, 0))
      guard let rect = textView.rect(ofLine: index) else { return }
      let clipView = scrollView.contentView
      let insets = scrollView.contentInsets
      // The line's top at the top of what shows under the bars.
      let y = rect.minY + rect.height * CGFloat(line - Double(index)) - insets.top
      let maxY = textView.frame.height - clipView.bounds.height + insets.bottom
      clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: min(max(-insets.top, y), max(-insets.top, maxY))))
      scrollView.reflectScrolledClipView(clipView)
    }

    /// The text view's visible rect less what the scroll view's top and bottom insets cover.
    private func unobscuredRect(of textView: CodeTextView) -> NSRect {
      var rect = textView.visibleRect
      guard let insets = textView.enclosingScrollView?.contentInsets else { return rect }
      rect.origin.y += insets.top
      rect.size.height = max(0, rect.height - insets.top - insets.bottom)
      return rect
    }
  }

  /// The editor for a workspace document, as a SwiftUI view.
  ///
  /// Pass `document.revision` so SwiftUI updates the editor when the file is
  /// reloaded from disk. Edits flow back through the document's autosave.
  /// With `services`, the editor talks to language servers, formats on save
  /// and shows issues and breakpoints.
  public struct CodeEditorView: NSViewRepresentable {
    public var document: TextDocument
    public var revision: Int
    public var configuration: EditorConfiguration
    public var services: ProjectServices?
    /// A value that changes when the document's issues, breakpoints or the
    /// debugger's line change, so SwiftUI updates the editor.
    public var marks: Int
    public var features: EditorFeatures
    /// For an editor that runs on under bars floating over it (it ignores the safe area): the part of the window,
    /// in SwiftUI's global space, that the bars leave clear (the safe area's frame). Its text starts and ends there
    /// and scrolls on under the bars.
    public var unobscuredFrame: CGRect?
    public var onSelectionChange: @MainActor (EditorSelection) -> Void

    public init(
      document: TextDocument, revision: Int, configuration: EditorConfiguration = .init(),
      services: ProjectServices? = nil, marks: Int = 0, features: EditorFeatures = .init(),
      unobscuredFrame: CGRect? = nil,
      onSelectionChange: @escaping @MainActor (EditorSelection) -> Void = { _ in }
    ) {
      self.document = document
      self.revision = revision
      self.configuration = configuration
      self.services = services
      self.marks = marks
      self.features = features
      self.unobscuredFrame = unobscuredFrame
      self.onSelectionChange = onSelectionChange
    }

    public func makeNSView(context: Context) -> CodeEditorHostView { CodeEditorHostView() }

    public func updateNSView(_ host: CodeEditorHostView, context: Context) {
      let editor = DocumentEditor.editor(for: document, configuration: configuration)
      let textView = editor.scrollView.textView
      textView.configuration = configuration
      // Reported on the next turn: selection changes during a view update
      // must not update SwiftUI state.
      textView.onSelectionChange = { selection in
        Task { @MainActor in onSelectionChange(selection) }
      }
      editor.sync(with: document)
      if let services { editor.connect(services, document: document) }
      editor.apply(services, document: document, features: features)
      host.show(editor.container, focusing: textView)
      let container = editor.container
      host.onContentInsetsChange = { [weak container] insets in container?.contentInsets = insets }
      host.unobscuredFrame = unobscuredFrame
      container.contentInsets = host.contentInsets
      editor.applyPendingSelection(of: document)
      let selection = textView.currentSelection
      Task { @MainActor in onSelectionChange(selection) }
    }
  }

  extension TextDocument {
    /// Moves the caret of this document's editor to `line` and `column` (from
    /// 1), selecting `length` characters. Does nothing before the editor has
    /// been shown.
    public func goTo(line: Int, column: Int = 1, length: Int = 0) {
      textView?.goTo(line: line, column: column, length: length)
    }

    /// The completion list of this document's editor, once it has been
    /// shown.
    public var completion: CompletionController? {
      (editorState as? DocumentEditor)?.completion
    }

    /// This document's text view, once its editor has been shown.
    public var textView: CodeTextView? {
      (editorState as? DocumentEditor)?.scrollView.textView
    }
  }
#endif
