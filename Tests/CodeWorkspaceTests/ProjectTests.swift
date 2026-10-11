import Foundation
import Testing

@testable import CodeWorkspace

/// A fresh temporary folder, removed when the test ends.
private final class TempFolder {
  let url: URL
  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodeKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }
  deinit { try? FileManager.default.removeItem(at: url) }

  func file(_ path: String, _ contents: String = "") throws {
    let file = url.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: file, atomically: true, encoding: .utf8)
  }
}

@MainActor @Suite struct ProjectTests {
  @Test func treeSortsFoldersFirstAndHidesExcluded() throws {
    let temp = try TempFolder()
    try temp.file("b.swift")
    try temp.file("A10.txt")
    try temp.file("A9.txt")
    try temp.file("Sources/x.swift")
    try temp.file(".git/HEAD")
    try temp.file(".gitignore")
    let tree = FileTree(root: temp.url)
    #expect(tree.root.children?.map(\.name) == ["Sources", ".gitignore", "A9.txt", "A10.txt", "b.swift"])
    let sources = tree.root.children![0]
    #expect(sources.children == nil)
    tree.setExpanded(sources, true)
    #expect(sources.children?.map(\.name) == ["x.swift"])
    #expect(tree.expanded.contains(sources.url))
  }

  @Test func reloadKeepsNodesAndPicksUpNewFiles() throws {
    let temp = try TempFolder()
    try temp.file("a.swift")
    let tree = FileTree(root: temp.url)
    let a = tree.root.children![0]
    try temp.file("b.swift")
    tree.reload(directory: temp.url)
    #expect(tree.root.children?.map(\.name) == ["a.swift", "b.swift"])
    #expect(tree.root.children![0] === a)
  }

  @Test func fileOperations() throws {
    let temp = try TempFolder()
    let tree = FileTree(root: temp.url)
    let file = try tree.createFile(named: "Sources/App/main.swift", in: temp.url)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(tree.root.children?.map(\.name) == ["Sources"])
    #expect(throws: FileTree.OperationError.self) {
      try tree.createFile(named: "Sources/App/main.swift", in: temp.url)
    }
    #expect(throws: FileTree.OperationError.self) { try tree.createFile(named: "../x", in: temp.url) }
    let renamed = try tree.rename(file, to: "App.swift")
    #expect(renamed.lastPathComponent == "App.swift")
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test func revealExpandsParents() throws {
    let temp = try TempFolder()
    try temp.file("a/b/c.swift")
    let tree = FileTree(root: temp.url)
    let node = tree.reveal(temp.url.appendingPathComponent("a/b/c.swift"))
    #expect(node?.name == "c.swift")
    #expect(tree.expanded.count == 2)
    #expect(tree.relativePath(of: node!.url) == "a/b/c.swift")
  }

  @Test func indexSkipsExcludedFolders() throws {
    let temp = try TempFolder()
    try temp.file("Sources/a.swift")
    try temp.file("node_modules/x/index.js")
    try temp.file(".git/HEAD")
    let result = FileIndex.enumerate(temp.url, excluding: FileTree.defaultExcludedNames)
    #expect(result.paths == ["Sources/a.swift"])
  }

  @Test func fuzzyMatchRanksWordStartsAndFileNames() {
    let paths = [
      "Sources/CodeKit/Workspace/Workspace.swift", "Code/Workspace/WorkspaceWindow.swift",
      "Tests/CodeKitTests/ProjectTests.swift", "Sources/CodeKit/Project/FileWatcher.swift",
    ]
    func best(_ query: String) -> String? {
      paths.compactMap { p in FuzzyMatch.match(query, in: p).map { (p, $0.score) } }
        .max { $0.1 < $1.1 }?.0
    }
    #expect(best("fw") == "Sources/CodeKit/Project/FileWatcher.swift")
    #expect(best("wsw") == "Code/Workspace/WorkspaceWindow.swift")
    #expect(best("projtest") == "Tests/CodeKitTests/ProjectTests.swift")
    #expect(FuzzyMatch.match("zzz", in: paths[0]) == nil)
    #expect(FuzzyMatch.match("ws", in: "Workspace")?.positions == [0, 4])
  }

  @Test func workspaceTabsAndPreview() async throws {
    let temp = try TempFolder()
    try temp.file("a.swift", "let a = 1\n")
    try temp.file("b.swift", "let b = 2\n")
    try temp.file("c.swift", "let c = 3\n")
    let defaults = UserDefaults(suiteName: "CodeKitTests-\(UUID().uuidString)")!
    let workspace = Workspace(root: temp.url, defaults: defaults)
    let a = workspace.open(temp.url.appendingPathComponent("a.swift"), preview: true)
    #expect(workspace.isPreview(a))
    let b = workspace.open(temp.url.appendingPathComponent("b.swift"), preview: true)
    #expect(workspace.tabs.map(\.name) == ["b.swift"])
    workspace.keep(b)
    workspace.open(temp.url.appendingPathComponent("c.swift"))
    #expect(workspace.tabs.map(\.name) == ["b.swift", "c.swift"])
    workspace.close(workspace.selectedDocument!)
    #expect(workspace.selectedDocument?.name == "b.swift")

    // The session restores kept tabs.
    let restored = Workspace(root: temp.url, defaults: defaults)
    #expect(restored.tabs.map(\.name) == ["b.swift"])
    #expect(restored.selectedDocument?.name == "b.swift")
  }
}

@MainActor @Suite struct TextDocumentTests {
  @Test func decodesEncodingsAndDetectsBinary() {
    guard case .text(let utf8, .utf8) = TextDocument.decode(Data("héllo".utf8)) else {
      Issue.record("UTF-8")
      return
    }
    #expect(utf8 == "héllo")
    let latin1 = "café".data(using: .isoLatin1)!
    guard case .text(let text, let encoding) = TextDocument.decode(latin1) else {
      Issue.record("Latin-1")
      return
    }
    #expect(text == "café")
    #expect(encoding != .utf8)
    let utf16 = "hi".data(using: .utf16)!
    guard case .text("hi", .utf16) = TextDocument.decode(utf16) else {
      Issue.record("UTF-16")
      return
    }
    guard case .binary = TextDocument.decode(Data([0x50, 0x4B, 0x00, 0x01])) else {
      Issue.record("binary")
      return
    }
  }

  @Test func autosaveWritesInTheOriginalEncoding() async throws {
    let temp = try TempFolder()
    let url = temp.url.appendingPathComponent("latin.txt")
    try "café".data(using: .isoLatin1)!.write(to: url)
    let document = TextDocument(url: url)
    await document.load()
    #expect(document.content == .text)
    var live = document.text
    document.textProvider = { live }
    live += " noir"
    document.saveDelay = .milliseconds(10)
    document.markEdited()
    #expect(document.saveState == .unsaved)
    try await Task.sleep(for: .milliseconds(200))
    #expect(document.saveState == .saved)
    #expect(String(data: try Data(contentsOf: url), encoding: .isoLatin1) == "café noir")

    // A character Latin-1 can't hold switches the file to UTF-8.
    live += " 😀"
    document.markEdited()
    document.flush()
    #expect(document.encoding == .utf8)
    #expect(try String(contentsOf: url, encoding: .utf8) == "café noir 😀")
  }

  @Test func reloadPicksUpExternalChangesButKeepsPendingEdits() async throws {
    let temp = try TempFolder()
    let url = temp.url.appendingPathComponent("a.txt")
    try "one".write(to: url, atomically: true, encoding: .utf8)
    let document = TextDocument(url: url)
    await document.load()
    let revision = document.revision
    try "two".write(to: url, atomically: true, encoding: .utf8)
    await document.reloadFromDisk()
    #expect(document.text == "two")
    #expect(document.revision == revision + 1)

    document.textProvider = { "mine" }
    document.markEdited()
    try "three".write(to: url, atomically: true, encoding: .utf8)
    await document.reloadFromDisk()
    document.flush()
    #expect(try String(contentsOf: url, encoding: .utf8) == "mine")
  }
}
