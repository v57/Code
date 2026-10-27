#if os(Windows) || os(Linux)
  import CodeEditor
  import CodeHighlighting
  import CodeWorkspace
  import Foundation
  import Observation
  import SwiftUI

  /// The editor of one workspace document on Windows and Linux: the text in SwiftUI's text editor, saving through the
  /// document and connected to the project's services (language servers, formatting, breakpoints) as the Mac's
  /// `DocumentEditor` is. Kept in `TextDocument.editorState`, so a tab brought back keeps its text and caret.
  @MainActor @Observable final class PortableDocumentEditor: CodeTextEditing {
    var text: String {
      didSet { if !isApplyingExternalText, text != oldValue { textChanged(from: oldValue) } }
    }
    var selection: TextSelection?
    /// Quick Help for the symbol under ⌥-click, until dismissed.
    var quickHelp: String?
    /// The document revision whose text the editor shows.
    @ObservationIgnored var appliedRevision: Int
    @ObservationIgnored private weak var document: TextDocument?
    @ObservationIgnored private weak var services: ProjectServices?
    @ObservationIgnored private var breakpoints: Set<Int> = []
    @ObservationIgnored private var isApplyingExternalText = false
    /// The file ends lines with CRLF: the editor works with "\n" (as the text box reports its lines) and the
    /// file keeps its own line endings when saved.
    @ObservationIgnored private var usesCRLF = false
    #if os(Linux)
      /// The text in the theme's colors, until the text or the theme changes.
      @ObservationIgnored private var highlighted: (text: String, theme: String, value: AttributedString)?
    #endif

    init(document: TextDocument) {
      usesCRLF = document.text.contains("\r\n")
      text = Self.editable(document.text)
      appliedRevision = document.revision
      self.document = document
      attach(to: document)
    }

    /// The editor for `document`, made on first use.
    static func editor(for document: TextDocument) -> PortableDocumentEditor {
      if let editor = document.editorState as? PortableDocumentEditor { return editor }
      let editor = PortableDocumentEditor(document: document)
      document.editorState = editor
      return editor
    }

    private func attach(to document: TextDocument) {
      // The text is copied out only when a save runs.
      document.textProvider = { [weak self, weak document] in
        guard let self else { return document?.text ?? "" }
        return usesCRLF ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
      }
    }

    /// Text as the editor holds it: lines end with "\n".
    private static func editable(_ text: String) -> String {
      text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// Takes the document's text when it was replaced from outside (reloaded from disk).
    func sync(with document: TextDocument) {
      guard document.revision != appliedRevision else { return }
      appliedRevision = document.revision
      isApplyingExternalText = true
      usesCRLF = document.text.contains("\r\n")
      text = Self.editable(document.text)
      isApplyingExternalText = false
      attach(to: document)
    }

    /// Connects the editor to the project's services, once.
    func connect(_ services: ProjectServices, document: TextDocument) {
      guard self.services !== services else { return }
      self.services = services
      document.preSave = { [weak services, weak document, weak self] in
        guard let services, let document, let self else { return }
        await services.formatBeforeSave(document, textView: self)
      }
      document.didSave = { [weak services, weak document] text in
        guard let services, let document else { return }
        services.documentSaved(document, text: text)
      }
      services.documentShown(document, textView: self)
    }

    private func textChanged(from old: String) {
      guard let document else { return }
      document.markEdited()
      // The whole text, as language servers take an edit: the old text's range replaced by the new.
      let lines = old.split(separator: "\n", omittingEmptySubsequences: false)
      let edit = TextEdit(
        startLine: 0, startColumn: 0, endLine: max(lines.count - 1, 0), endColumn: lines.last?.utf16.count ?? 0,
        text: text)
      services?.documentEdited(document, edit: edit, textView: self)
    }

    // MARK: CodeTextEditing

    var string: String { text }

    var lineCount: Int { text.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 } }

    var caretLocation: Int { selectedRange.location }

    var selectionRange: NSRange { selectedRange }

    /// Whether the text box has focus isn't followed here; a selection means it was used.
    var isFocused: Bool { selection != nil }

    /// The selection as UTF-16 offsets.
    private var selectedRange: NSRange {
      guard case .selection(let range)? = selection?.indices,
        range.lowerBound <= text.endIndex, range.upperBound <= text.endIndex
      else { return NSRange(location: 0, length: 0) }
      return NSRange(range, in: text)
    }

    var currentSelection: EditorSelection {
      let range = selectedRange
      let start = position(of: range.location)
      let end = position(of: range.location + max(range.length - 1, 0))
      return EditorSelection(
        line: start.line + 1, column: start.column + 1, length: range.length,
        lineCount: range.length == 0 ? 1 : end.line - start.line + 1)
    }

    func position(of location: Int) -> (line: Int, column: Int) {
      var line = 0
      var lineStart = 0
      var offset = 0
      for unit in text.utf16 {
        guard offset < location else { break }
        offset += 1
        if unit == 0x0A {
          line += 1
          lineStart = offset
        }
      }
      return (line, min(location, offset) - lineStart)
    }

    func identifierRange(at location: Int) -> NSRange? { identifierRange(in: text as NSString, at: location) }

    func applyFormattedText(_ newText: String) {
      guard newText != text else { return }
      let caret = selectedRange.location
      text = newText
      let index = String.Index(utf16Offset: min(caret, newText.utf16.count), in: newText)
      selection = TextSelection(insertionPoint: index)
    }

    func goTo(line: Int, column: Int, length: Int) {
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
      let number = min(max(line, 1), max(lines.count, 1)) - 1
      var location = lines.prefix(number).reduce(0) { $0 + $1.utf16.count + 1 }
      let lineLength = lines.isEmpty ? 0 : lines[number].utf16.count
      location += min(max(column - 1, 0), lineLength)
      let utf16 = text.utf16
      let start = utf16.index(utf16.startIndex, offsetBy: min(location, utf16.count))
      let end = utf16.index(start, offsetBy: min(max(length, 0), utf16.distance(from: start, to: utf16.endIndex)))
      selection = TextSelection(range: start..<end)
    }

    func toggleBreakpoint(atLine line: Int) {
      guard let document, line >= 0 else { return }
      if breakpoints.contains(line) { breakpoints.remove(line) } else { breakpoints.insert(line) }
      services?.setBreakpoints(breakpoints, for: document.url)
    }

    func showQuickHelp(_ text: String, at range: NSRange) { quickHelp = text }

    #if os(Linux)
      /// Files longer than this are shown in the plain text color (each edit colors the whole text again).
      private static let highlightLimit = 400_000

      /// The text with its syntax in `theme`'s colors, for a text editor of an attributed string.
      func highlightedText(theme: EditorTheme) -> AttributedString {
        if let highlighted, highlighted.text == text, highlighted.theme == theme.id { return highlighted.value }
        let value = Self.highlight(text, language: document?.language, scheme: theme.syntax)
        highlighted = (text, theme.id, value)
        return value
      }

      /// The edited text from the text editor (its colors are the next highlight's).
      func setHighlightedText(_ value: AttributedString) {
        let edited = String(value.characters)
        if edited != text { text = edited }
      }

      private static func highlight(_ text: String, language: LanguageSpec?, scheme: CodeColorScheme) -> AttributedString {
        func piece(_ substring: Substring, _ kind: SyntaxKind) -> AttributedString {
          var piece = AttributedString(String(substring))
          piece.foregroundColor = Color(hex: scheme.color(for: kind))
          return piece
        }
        guard let language, text.utf8.count <= highlightLimit else { return piece(text[...], .plainText) }
        var scanner = CodeScanner(code: text, spec: language)
        let tokens = scanner.scan().sorted { $0.range.location < $1.range.location }
        // Walks the text once, by the tokens' UTF-16 offsets.
        let utf16 = text.utf16
        var result = AttributedString()
        var index = utf16.startIndex
        var offset = 0
        func advance(to target: Int) -> String.Index {
          let target = min(target, utf16.count)
          if target > offset {
            index = utf16.index(index, offsetBy: target - offset)
            offset = target
          }
          return index
        }
        for token in tokens where token.range.location >= offset && token.range.length > 0 {
          let gapStart = index
          let start = advance(to: token.range.location)
          if start > gapStart { result += piece(text[gapStart..<start], .plainText) }
          let end = advance(to: token.range.location + token.range.length)
          if end > start { result += piece(text[start..<end], token.kind) }
        }
        if index < text.endIndex { result += piece(text[index...], .plainText) }
        return result
      }
    #endif
  }

  /// The editor for a workspace document (Windows and Linux): the document's text in the theme's colors and the editor
  /// font, saving through the document; the Mac's has the same initializer.
  public struct CodeEditorView: View {
    public let document: TextDocument
    /// The document's revision, so SwiftUI updates the editor when the text was replaced from outside.
    public var revision: Int
    public var configuration: EditorConfiguration
    public weak var services: ProjectServices?
    /// Changes when issues, breakpoints or the debugger's line change.
    public var marks: Int
    public var features: EditorFeatures
    public var unobscuredFrame: CGRect?
    public var onSelectionChange: @MainActor (EditorSelection) -> Void
    @Environment(\.colorScheme) private var colorScheme

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

    public var body: some View {
      let editor = PortableDocumentEditor.editor(for: document)
      let theme = configuration.theme(isDark: colorScheme == .dark)
      EditorTextView(
        editor: editor, theme: theme,
        font: configuration.fontName.map { Font.custom($0, size: configuration.fontSize) }
          ?? .system(size: configuration.fontSize, design: .monospaced),
        onSelectionChange: onSelectionChange
      )
      .onAppear {
        editor.sync(with: document)
        if let services { editor.connect(services, document: document) }
      }
      .onChange(of: revision) { editor.sync(with: document) }
    }
  }

  private struct EditorTextView: View {
    @Bindable var editor: PortableDocumentEditor
    let theme: EditorTheme
    let font: Font
    let onSelectionChange: @MainActor (EditorSelection) -> Void

    var body: some View {
      textEditor
        .textEditorStyle(.plain)
        .font(font)
        .foregroundStyle(Color(hex: theme.syntax.plainText))
        .padding(.leading, 8)
        .background(Color(hex: theme.background))
        .onChange(of: editor.selection) { onSelectionChange(editor.currentSelection) }
        .overlay(alignment: .bottomLeading) {
          if let help = editor.quickHelp {
            QuickHelpCard(text: help) { editor.quickHelp = nil }
              .padding(12)
          }
        }
    }
  }

  extension EditorTextView {
    /// On Linux the text in its syntax colors (GTK's text view has no selection binding); elsewhere plain text
    /// with the selection.
    @ViewBuilder fileprivate var textEditor: some View {
      #if os(Linux)
        TextEditor(
          text: Binding(
            get: { [editor, theme] in editor.highlightedText(theme: theme) },
            set: { [editor] in editor.setHighlightedText($0) }))
      #else
        TextEditor(text: $editor.text, selection: $editor.selection)
      #endif
    }
  }

  /// Quick Help over the editor's corner, until closed.
  private struct QuickHelpCard: View {
    let text: String
    let close: () -> Void

    var body: some View {
      HStack(alignment: .top, spacing: 8) {
        ScrollView {
          Text(text)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 520, maxHeight: 220)
        Button("Close", systemImage: "xmark", action: close)
          .labelStyle(.iconOnly)
          .buttonStyle(.plain)
      }
      .padding(10)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
  }

  extension Color {
    /// A 0xRRGGBB theme color.
    fileprivate init(hex: UInt32) {
      self.init(
        red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
  }

  extension TextDocument {
    /// Moves the caret of this document's editor to `line` and `column` (from 1), selecting `length`
    /// characters. Does nothing before the editor has been shown.
    public func goTo(line: Int, column: Int = 1, length: Int = 0) {
      textView?.goTo(line: line, column: column, length: length)
    }

    /// This document's editor, once it has been shown.
    public var textView: (any CodeTextEditing)? { editorState as? PortableDocumentEditor }
  }
#endif
