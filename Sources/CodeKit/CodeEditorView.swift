#if canImport(AppKit)
  import AppKit
  import SwiftUI

  /// The editor of one workspace document: CodeEditor's view, fed from a
  /// `TextDocument` and saving through it. Kept in `TextDocument.editorState`
  /// so a tab brought back shows the same undo history, selection and scroll
  /// position.
  @MainActor final class DocumentEditor {
    let scrollView: CodeEditorScrollView
    /// The document revision whose text the editor shows.
    var appliedRevision: Int

    init(document: TextDocument, configuration: EditorConfiguration) {
      scrollView = CodeEditorScrollView(
        text: document.text, language: document.language,
        highlightsSyntax: document.highlightsSyntax, configuration: configuration)
      appliedRevision = document.revision
      attach(to: document)
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
      textView.onEdit = { [weak document] in document?.markEdited() }
      document.willSave = { [weak textView] in textView?.trimTrailingWhitespace() ?? false }
      // The text is copied out only when a save runs.
      document.textProvider = { [weak textView, weak document] in
        textView?.string ?? document?.text ?? ""
      }
    }

    /// Takes the document's text when it was replaced from outside (reloaded
    /// from disk), and its language when that changed.
    func sync(with document: TextDocument) {
      if document.revision != appliedRevision {
        appliedRevision = document.revision
        scrollView.textView.replaceAllText(document.text)
        attach(to: document)
      }
      scrollView.textView.setLanguage(
        document.language, highlightsSyntax: document.highlightsSyntax)
    }
  }

  /// The editor for a workspace document, as a SwiftUI view.
  ///
  /// Pass `document.revision` so SwiftUI updates the editor when the file is
  /// reloaded from disk. Edits flow back through the document's autosave.
  public struct CodeEditorView: NSViewRepresentable {
    public var document: TextDocument
    public var revision: Int
    public var configuration: EditorConfiguration
    public var onSelectionChange: @MainActor (EditorSelection) -> Void

    public init(
      document: TextDocument, revision: Int, configuration: EditorConfiguration = .init(),
      onSelectionChange: @escaping @MainActor (EditorSelection) -> Void = { _ in }
    ) {
      self.document = document
      self.revision = revision
      self.configuration = configuration
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
      host.show(editor.scrollView)
      let selection = textView.currentSelection
      Task { @MainActor in onSelectionChange(selection) }
    }
  }

  extension TextDocument {
    /// Moves the caret of this document's editor to `line` and `column` (from
    /// 1). Does nothing before the editor has been shown.
    public func goTo(line: Int, column: Int = 1) {
      textView?.goTo(line: line, column: column)
    }

    /// This document's text view, once its editor has been shown.
    public var textView: CodeTextView? {
      (editorState as? DocumentEditor)?.scrollView.textView
    }
  }
#endif
