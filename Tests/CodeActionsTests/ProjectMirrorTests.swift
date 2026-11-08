import Foundation
import SSHKit
import Testing

@testable import CodeActions

/// Copies of a project on another machine over SSHKit's SFTP, when a server is given: `CODE_SSH_TEST_HOST`,
/// `CODE_SSH_TEST_PORT`, `CODE_SSH_TEST_USER` and `CODE_SSH_TEST_KEY` (a private key file it accepts), the server
/// running as a user who isn't root (so `chmod 000` locks a folder).
struct ProjectMirrorTests {
  /// One folder the user can't read in the first two levels used to fail the whole project ("The server doesn’t allow
  /// access to “…/Locked”", Code C-003): it is skipped and named, and the rest is copied.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CODE_SSH_TEST_KEY"] != nil))
  func skipsUnreadableFolders() async throws {
    let environment = ProcessInfo.processInfo.environment
    let key = try SSHKey(importing: String(contentsOfFile: environment["CODE_SSH_TEST_KEY"]!, encoding: .utf8))
    let manager = FileManager.default
    let remote = manager.temporaryDirectory.appendingPathComponent("mirror-\(UUID().uuidString)")
    let locked = remote.appendingPathComponent("Locked")
    let lockedFile = remote.appendingPathComponent("Config/Secret.json")
    try manager.createDirectory(at: locked, withIntermediateDirectories: true)
    try manager.createDirectory(at: lockedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("// swift-tools-version:5.9\n".utf8).write(to: remote.appendingPathComponent("Package.swift"))
    try Data("x".utf8).write(to: lockedFile)
    try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: lockedFile.path)
    let copy = manager.temporaryDirectory.appendingPathComponent("mirror-copy-\(UUID().uuidString)")
    defer {
      try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
      try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedFile.path)
      try? manager.removeItem(at: remote)
      try? manager.removeItem(at: copy)
    }
    let client = try await SFTPClient.connect(
      server: SSHServer(
        host: environment["CODE_SSH_TEST_HOST"] ?? "127.0.0.1", port: Int(environment["CODE_SSH_TEST_PORT"] ?? "22") ?? 22,
        user: environment["CODE_SSH_TEST_USER"] ?? NSUserName(), key: key, trust: .ask { _ in true }),
      timeout: 15)
    defer { client.close() }
    let path = remote.resolvingSymlinksInPath().path
    let unreadable = try await ProjectMirror.fetch(path, into: copy, client: client)
    #expect(unreadable.contains { $0.hasSuffix("/Locked") }, "\(unreadable)")
    #expect(unreadable.contains { $0.hasSuffix("/Config/Secret.json") })
    #expect(manager.fileExists(atPath: copy.appendingPathComponent("Package.swift").path))
    #expect(manager.fileExists(atPath: copy.appendingPathComponent("Locked").path))

    // The project's own folder still has to be readable.
    try manager.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    await #expect(throws: SFTPError.self) {
      try await ProjectMirror.fetch(locked.resolvingSymlinksInPath().path, into: copy, client: client)
    }
  }
}
