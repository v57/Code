#if canImport(AppKit)
  import AppKit
  import Testing

  @testable import CodeKit

  @MainActor @Suite struct DocumentEditorTests {
    @Test func editsInTheEditorAutosaveAndExternalChangesReload() async throws {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeKitEditor-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let url = folder.appendingPathComponent("main.swift")
      try "let a = 1\n".write(to: url, atomically: true, encoding: .utf8)

      let document = TextDocument(url: url)
      await document.load()
      document.saveDelay = .milliseconds(10)
      let editor = DocumentEditor.editor(for: document, configuration: EditorConfiguration())
      #expect(DocumentEditor.editor(for: document, configuration: EditorConfiguration()) === editor)
      let textView = editor.scrollView.textView
      textView.setSelectedRange(NSRange(location: 9, length: 0))
      textView.insertText("0", replacementRange: textView.selectedRange())
      #expect(document.saveState == .unsaved)
      try await Task.sleep(for: .milliseconds(200))
      #expect(document.saveState == .saved)
      #expect(try String(contentsOf: url, encoding: .utf8) == "let a = 10\n")

      // Another app rewrites the file: the editor takes the new text.
      try "let b = 2\n".write(to: url, atomically: true, encoding: .utf8)
      await document.reloadFromDisk()
      editor.sync(with: document)
      #expect(textView.string == "let b = 2\n")
      #expect(document.saveState == .saved)
    }

  }
#endif
