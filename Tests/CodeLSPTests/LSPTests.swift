import Foundation
import Testing

@testable import CodeLSP

@Suite struct CatalogTests {
  @Test func rootsAndLanguages() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LSP-\(UUID().uuidString)")
    let crate = root.appendingPathComponent("rs/crates/a/src")
    try FileManager.default.createDirectory(at: crate, withIntermediateDirectories: true)
    try "".write(to: root.appendingPathComponent("rs/Cargo.toml"), atomically: true, encoding: .utf8)
    try "".write(to: root.appendingPathComponent("rs/crates/a/Cargo.toml"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = crate.appendingPathComponent("lib.rs")
    let rust = try #require(LanguageServerCatalog.configuration(for: file))
    #expect(rust.id == "rust-analyzer")
    #expect(
      LanguageServerCatalog.root(for: file, configuration: rust, workspace: root).path
        == root.appendingPathComponent("rs").standardizedFileURL.path)
    let swift = try #require(LanguageServerCatalog.configuration(for: URL(fileURLWithPath: "/a/b.swift")))
    #expect(swift.id == "sourcekit-lsp")
    #expect(
      LanguageServerCatalog.root(for: file, configuration: swift, workspace: root).path
        == root.standardizedFileURL.path)
  }

  @Test func jsonRoundTrip() throws {
    let value: JSONValue = ["a": [1, true, "x", nil], "b": ["c": .number(2.5)]]
    #expect(try JSONValue.decode(value.encoded()) == value)
  }
}

#if os(macOS)
  /// Talks to a real gopls when it is installed.
  @MainActor @Suite struct GoplsTests {
    @Test func definitionAndDiagnostics() async throws {
      var environment = ProcessInfo.processInfo.environment
      environment["PATH"] = "/opt/homebrew/bin:" + (environment["PATH"] ?? "")
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("Gopls-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let manager = LanguageServerManager(workspace: root, environment: environment)
      guard let configuration = LanguageServerCatalog.all.first(where: { $0.id == "gopls" }),
        manager.executable(for: configuration) != nil
      else { return }
      try "module example.com/x\n\ngo 1.21\n".write(
        to: root.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
      let text = "package main\n\nfunc helper() int { return 1 }\n\nfunc main() {\n\t_ = helper()\n\tundefinedThing()\n}\n"
      let file = root.appendingPathComponent("main.go")
      try text.write(to: file, atomically: true, encoding: .utf8)
      manager.didOpen(file, text: text)

      var locations: [LSPLocation] = []
      for _ in 0..<60 where locations.isEmpty {
        try await Task.sleep(for: .milliseconds(250))
        locations = await manager.locations(url: file, position: LSPPosition(line: 5, character: 7))
      }
      #expect(locations.first?.range.start.line == 2)
      #expect(locations.first?.url.lastPathComponent == "main.go")
      for _ in 0..<60 where manager.diagnostics[file.standardizedFileURL] == nil {
        try await Task.sleep(for: .milliseconds(250))
      }
      let diagnostics = manager.diagnostics[file.standardizedFileURL] ?? []
      #expect(diagnostics.contains { $0.range.start.line == 6 && $0.severity == .error })
      manager.stopAll()
    }

    @Test func completion() async throws {
      var environment = ProcessInfo.processInfo.environment
      environment["PATH"] = "/opt/homebrew/bin:" + (environment["PATH"] ?? "")
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("Gopls-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let manager = LanguageServerManager(workspace: root, environment: environment)
      guard let configuration = LanguageServerCatalog.all.first(where: { $0.id == "gopls" }),
        manager.executable(for: configuration) != nil
      else { return }
      try "module example.com/x\n\ngo 1.21\n".write(
        to: root.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
      let text = "package main\n\nfunc helperValue(count int) int { return count }\n\nfunc main() {\n\t_ = help\n}\n"
      let file = root.appendingPathComponent("main.go")
      try text.write(to: file, atomically: true, encoding: .utf8)
      manager.didOpen(file, text: text)
      for _ in 0..<60 where !manager.supportsCompletion(file) {
        try await Task.sleep(for: .milliseconds(250))
      }
      #expect(manager.completionTriggerCharacters(file).contains("."))
      let list = await manager.completions(
        url: file, position: LSPPosition(line: 5, character: 9), trigger: .invoked)
      let item = try #require(list?.items.first { $0.label == "helperValue" })
      #expect(item.isSnippet)
      #expect(item.insertText.hasPrefix("helperValue("))
      #expect(item.range?.start == LSPPosition(line: 5, character: 5))
      manager.stopAll()
    }
  }
#endif
