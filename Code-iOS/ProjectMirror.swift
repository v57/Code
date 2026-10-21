import CodeActions
import Foundation
import SSHKit

/// A copy here of what Code's detectors read in a project on another machine: its folders a few levels down (as
/// `ProjectScanner` searches them), their small files (manifests), and the Xcode projects' scheme files and
/// `project.pbxproj`, fetched over SFTP. The schemes found in the copy run there, in the real folder: the executor
/// maps the copy's paths to the folder there.
enum ProjectMirror {
  /// Files up to this size are copied; bigger ones are left empty (detectors only need to see that they exist).
  static let fileLimit = 512 * 1024
  /// The most files copied, so a huge folder can't stall opening the project.
  static let countLimit = 2000

  /// Copies `directory` on the server into a fresh folder for `projectID` in the caches, and returns it.
  static func fetch(_ directory: String, projectID: String, client: SFTPClient) async throws -> URL {
    let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let root = caches.appendingPathComponent("Projects", isDirectory: true)
      .appendingPathComponent(projectID, isDirectory: true)
      .appendingPathComponent((directory as NSString).lastPathComponent, isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var copier = Copier(client: client)
    try await copier.folder(directory, into: root, level: 0)
    return root
  }

  private struct Copier {
    let client: SFTPClient
    var count = 0

    init(client: SFTPClient) { self.client = client }

    /// A folder as the scanner sees it: every entry, its files' contents, and the folders it searches next.
    mutating func folder(_ path: String, into local: URL, level: Int) async throws {
      for entry in try await client.list(path) where !entry.name.hasPrefix(".") {
        let target = local.appendingPathComponent(entry.name)
        if entry.isDirectory {
          try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
          if entry.name.hasSuffix(".xcodeproj") || entry.name.hasSuffix(".xcworkspace") {
            try await xcodeContainer(entry.path, into: target)
          } else if level < 2, Self.searched(entry.name) {
            try await folder(entry.path, into: target, level: level + 1)
          }
        } else {
          try await file(entry.path, size: entry.size, into: target)
        }
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
        for user in try await client.list(path + "/xcuserdata") where user.isDirectory {
          schemeFolders.append("xcuserdata/\(user.name)/xcschemes")
        }
      }
      for folder in schemeFolders {
        guard try await client.stat(path + "/" + folder) != nil else { continue }
        let target = local.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for scheme in try await client.list(path + "/" + folder) where scheme.name.hasSuffix(".xcscheme") {
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
      try await client.read(path).write(to: local)
    }

    /// Whether the scanner looks inside a folder of this name (`ProjectScanner.scan`'s rule).
    static func searched(_ name: String) -> Bool {
      !ProjectScanner.skippedFolders.contains(name) && !name.hasPrefix("build") && !name.hasSuffix(".app")
        && !name.hasSuffix(".xcassets") && !name.hasSuffix(".lproj")
    }
  }
}
