import Foundation
import SSHKit

/// A copy here of what Code's detectors read in a project on another machine: its folders a few levels down (as
/// `ProjectScanner` searches them), their small files (manifests), and the Xcode projects' scheme files and
/// `project.pbxproj`, fetched over SFTP. The schemes found in the copy run there, in the real folder: the executor
/// maps the copy's paths to the folder there.
public enum ProjectMirror {
  /// Files up to this size are copied; bigger ones are left empty (detectors only need to see that they exist).
  static let fileLimit = 512 * 1024
  /// The most files copied, so a huge folder can't stall opening the project.
  static let countLimit = 2000

  /// A copy: its folder here, and what in it the server wouldn't let this user read (paths there), copied empty.
  public struct Copy: Sendable {
    public var root: URL
    public var unreadable: [String]
  }

  /// Copies `directory` on the server into a fresh folder for `projectID` in the caches.
  public static func fetch(_ directory: String, projectID: String, client: SFTPClient) async throws -> Copy {
    let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let root = caches.appendingPathComponent("Projects", isDirectory: true)
      .appendingPathComponent(projectID, isDirectory: true)
      .appendingPathComponent((directory as NSString).lastPathComponent, isDirectory: true)
    let unreadable = try await fetch(directory, into: root, client: client)
    return Copy(root: root, unreadable: unreadable)
  }

  /// Copies `directory` on the server into `root`, replacing what's there only once the copy has succeeded, so losing
  /// the connection halfway keeps the last one. A folder or file inside that this user can't read is skipped (an empty
  /// folder or file in the copy) and returned, so one locked folder doesn't keep the project from opening; the
  /// project's own folder must be readable.
  @discardableResult
  public static func fetch(_ directory: String, into root: URL, client: SFTPClient) async throws -> [String] {
    let parent = root.deletingLastPathComponent()
    let fresh = parent.appendingPathComponent(".\(root.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fresh) }
    var copier = Copier(client: client)
    try await copier.folder(directory, into: fresh, level: 0)
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.moveItem(at: fresh, to: root)
    return copier.unreadable
  }

  private struct Copier {
    let client: SFTPClient
    var count = 0
    /// What the server refused to list or read, below the project's folder.
    var unreadable: [String] = []

    init(client: SFTPClient) { self.client = client }

    /// A folder as the scanner sees it: every entry, its files' contents, and the folders it searches next.
    mutating func folder(_ path: String, into local: URL, level: Int) async throws {
      guard let entries = try await list(path, isRoot: level == 0) else { return }
      for entry in entries where !entry.name.hasPrefix(".") {
        let target = local.appendingPathComponent(entry.name)
        if entry.isDirectory {
          try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
          if entry.name.hasSuffix(".xcodeproj") || entry.name.hasSuffix(".xcworkspace") {
            do {
              try await xcodeContainer(entry.path, into: target)
            } catch let error as SFTPError where Self.isUnreadable(error) {
              unreadable.append(entry.path)
            }
          } else if level < 2, Self.searched(entry.name) {
            try await folder(entry.path, into: target, level: level + 1)
          } else if entry.name == "src" {
            // Cargo's detector looks for src/main.rs; the scanner goes no further.
            for file in try await list(entry.path) ?? [] where !file.isDirectory {
              try await self.file(file.path, size: file.size, into: target.appendingPathComponent(file.name))
            }
          }
        } else {
          try await file(entry.path, size: entry.size, into: target)
        }
      }
    }

    /// A folder's entries, or nil when the server won't list it for this user (or it went away meanwhile); the
    /// project's own folder throws instead. A broken connection throws too, so a copy is never half made.
    mutating func list(_ path: String, isRoot: Bool = false) async throws -> [SFTPFileInfo]? {
      do {
        return try await client.list(path)
      } catch let error as SFTPError where !isRoot && Self.isUnreadable(error) {
        unreadable.append(path)
        return nil
      }
    }

    static func isUnreadable(_ error: SFTPError) -> Bool {
      switch error {
      case .permissionDenied, .noSuchFile: true
      default: false
      }
    }

    /// What `XcodeDetector` reads in a project or workspace: `project.pbxproj`, `contents.xcworkspacedata`, and
    /// the shared and user scheme files.
    mutating func xcodeContainer(_ path: String, into local: URL) async throws {
      for name in ["project.pbxproj", "contents.xcworkspacedata"] {
        if let info = try await client.stat(path + "/" + name) {
          try await file(info.path, size: info.size, into: local.appendingPathComponent(name), limit: 16 << 20)
        }
      }
      var schemeFolders = ["xcshareddata/xcschemes"]
      if try await client.stat(path + "/xcuserdata") != nil {
        for user in try await list(path + "/xcuserdata") ?? [] where user.isDirectory {
          schemeFolders.append("xcuserdata/\(user.name)/xcschemes")
        }
      }
      for folder in schemeFolders {
        guard try await client.stat(path + "/" + folder) != nil else { continue }
        let target = local.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for scheme in try await list(path + "/" + folder) ?? [] where scheme.name.hasSuffix(".xcscheme") {
          try await file(scheme.path, size: scheme.size, into: target.appendingPathComponent(scheme.name))
        }
      }
    }

    mutating func file(_ path: String, size: UInt64, into local: URL, limit: Int = ProjectMirror.fileLimit) async throws {
      count += 1
      guard count <= ProjectMirror.countLimit, size <= UInt64(limit) else {
        FileManager.default.createFile(atPath: local.path, contents: nil)
        return
      }
      do {
        try await client.read(path).write(to: local)
      } catch let error as SFTPError where Self.isUnreadable(error) {
        unreadable.append(path)
        FileManager.default.createFile(atPath: local.path, contents: nil)
      }
    }

    /// Whether the scanner looks inside a folder of this name (`ProjectScanner.scan`'s rule).
    static func searched(_ name: String) -> Bool {
      !ProjectScanner.skippedFolders.contains(name) && !name.hasPrefix("build") && !name.hasSuffix(".app")
        && !name.hasSuffix(".xcassets") && !name.hasSuffix(".lproj")
    }
  }
}
