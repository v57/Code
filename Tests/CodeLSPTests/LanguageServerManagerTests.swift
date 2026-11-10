import Foundation
import Testing

@testable import CodeFolders
@testable import CodeLSP

/// Folder trust (security audit H1): until the person trusts a folder, no language server but Code's own starts in
/// it, so a cloned repository's `buildServer.json` (which sourcekit-lsp runs) runs nothing.
@MainActor
@Suite struct LanguageServerManagerTests {
  func folder() throws -> (root: URL, marker: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Trust-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let marker = root.appendingPathComponent("ran")
    let buildServer = #"{"name":"x","version":"1","bspVersion":"2.0","languages":["swift"],"argv":["/bin/sh","-c","touch \#(marker.path)"]}"#
    try buildServer.write(to: root.appendingPathComponent("buildServer.json"), atomically: true, encoding: .utf8)
    try "let a = 1\n".write(to: root.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
    return (root, marker)
  }

  @Test func untrustedFolderStartsNoExternalServer() async throws {
    let (root, marker) = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = LanguageServerManager(workspace: root)
    manager.isTrusted = false
    let file = root.appendingPathComponent("A.swift")
    // Only the built-in server is offered for Swift.
    #expect(manager.configuration(for: file)?.install == .builtIn)
    manager.didOpen(file, text: "let a = 1\n")
    try await Task.sleep(for: .seconds(2))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(manager.states["sourcekit-lsp"] == nil)

    // Trusted, Swift's own server is the one again.
    manager.isTrusted = true
    #expect(manager.configuration(for: file)?.id == "sourcekit-lsp")
    manager.stopAll()
  }

  @Test func trustCoversTheFolderAndWhatIsInside() throws {
    let trusted: Set<String> = ["/Users/me/Developer/Atlas"]
    #expect(FolderTrust.contains(trusted, URL(fileURLWithPath: "/Users/me/Developer/Atlas")))
    #expect(FolderTrust.contains(trusted, URL(fileURLWithPath: "/Users/me/Developer/Atlas/App/Sources")))
    #expect(!FolderTrust.contains(trusted, URL(fileURLWithPath: "/Users/me/Developer/AtlasOld")))
    #expect(!FolderTrust.contains(trusted, URL(fileURLWithPath: "/Users/me/Developer")))
    // A link into a trusted folder is that folder; a link to elsewhere isn't trusted by its name.
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("TrustLink-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let real = base.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = base.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    #expect(FolderTrust.contains([FolderTrust.path(real)], link))
    #expect(!FolderTrust.contains([link.path], real))
  }
}
