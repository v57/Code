#if canImport(AppKit)
  import AppKit
  import CodeHighlighting
  import SwiftUI

  /// The code editor as a SwiftUI view over a string, for apps that only
  /// need an editor. (CodeKit's `CodeEditorView` edits a workspace's
  /// documents instead, with autosave.) On iPhone and iPad it is the UIKit
  /// `CodeTextView`, with the same API.
  public struct CodeTextEditor: NSViewRepresentable {
    @Binding public var text: String
    public var language: LanguageSpec?
    public var configuration: EditorConfiguration
    public var onSelectionChange: @MainActor (EditorSelection) -> Void

    public init(
      text: Binding<String>, language: LanguageSpec?,
      configuration: EditorConfiguration = EditorConfiguration(),
      onSelectionChange: @escaping @MainActor (EditorSelection) -> Void = { _ in }
    ) {
      _text = text
      self.language = language
      self.configuration = configuration
      self.onSelectionChange = onSelectionChange
    }

    public final class Coordinator {
      /// The text last pushed into or read from the editor: the binding is
      /// pushed only when the host changed it.
      var appliedText = ""
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> CodeEditorScrollView {
      let editor = CodeEditorScrollView(text: text, language: language, configuration: configuration)
      context.coordinator.appliedText = text
      return editor
    }

    public func updateNSView(_ editor: CodeEditorScrollView, context: Context) {
      let textView = editor.textView
      let coordinator = context.coordinator
      textView.configuration = configuration
      textView.setLanguage(language, highlightsSyntax: true)
      textView.onEdit = { [binding = $text] in
        coordinator.appliedText = textView.string
        binding.wrappedValue = coordinator.appliedText
      }
      textView.onSelectionChange = { selection in
        Task { @MainActor in onSelectionChange(selection) }
      }
      if text != coordinator.appliedText {
        coordinator.appliedText = text
        textView.replaceAllText(text)
      }
    }
  }
#elseif canImport(UIKit)
  import CodeHighlighting
  import SwiftUI
  import UIKit

  /// The code editor as a SwiftUI view over a string, for apps that only
  /// need an editor: the UIKit `CodeTextView` on iPhone and iPad, with the
  /// Mac's API.
  public struct CodeTextEditor: UIViewRepresentable {
    @Binding public var text: String
    public var language: LanguageSpec?
    public var configuration: EditorConfiguration
    public var onSelectionChange: @MainActor (EditorSelection) -> Void

    public init(
      text: Binding<String>, language: LanguageSpec?,
      configuration: EditorConfiguration = EditorConfiguration(),
      onSelectionChange: @escaping @MainActor (EditorSelection) -> Void = { _ in }
    ) {
      _text = text
      self.language = language
      self.configuration = configuration
      self.onSelectionChange = onSelectionChange
    }

    public final class Coordinator {
      /// The text last pushed into or read from the editor: the binding is
      /// pushed only when the host changed it.
      var appliedText = ""
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> CodeTextView {
      let textView = CodeTextView(text: text, spec: language, highlightsSyntax: true, configuration: configuration)
      context.coordinator.appliedText = text
      return textView
    }

    public func updateUIView(_ textView: CodeTextView, context: Context) {
      let coordinator = context.coordinator
      textView.configuration = configuration
      textView.setLanguage(language, highlightsSyntax: true)
      textView.onEdit = { [binding = $text, weak textView] in
        guard let textView else { return }
        coordinator.appliedText = textView.string
        binding.wrappedValue = coordinator.appliedText
      }
      textView.onSelectionChange = { selection in
        Task { @MainActor in onSelectionChange(selection) }
      }
      if text != coordinator.appliedText {
        coordinator.appliedText = text
        textView.replaceAllText(text)
      }
    }
  }
#endif
