import CryptoKit
import Foundation

/// The folders on this computer that an Xcode scheme's build reads: the project folder, the projects and packages
/// its workspace lists (a `-Local` workspace's sibling checkouts, which stand in for the GitHub packages of the same
/// name), the local packages its projects use (`XCLocalSwiftPackageReference`), and the `.package(path:)`
/// dependencies of those packages, followed to the end. Remote packages come from their repository at build time,
/// so they aren't here.
public enum LocalDependencies {
  /// The folders of `scheme`'s build, the project's first; a folder inside another listed one is left out.
  public static func folders(of scheme: ActionScheme) -> [URL] {
    folders(root: scheme.directory, container: scheme.xcodeContainer)
  }

  static func folders(root: URL, container: String?) -> [URL] {
    var found: [URL] = []
    var visited = Set<String>()
    func add(_ url: URL) -> Bool {
      let url = url.standardizedFileURL
      guard visited.insert(url.path).inserted else { return false }
      found.append(url)
      return true
    }
    func addPackage(_ url: URL) {
      guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path), add(url),
        let manifest = try? String(contentsOf: url.appendingPathComponent("Package.swift"), encoding: .utf8)
      else { return }
      for groups in matches(of: #"\.package\s*\([^()]*?\bpath:\s*"([^"\\]+)""#, in: manifest) {
        addPackage(url.appendingPathComponent(groups[0]))
      }
    }
    func addProject(_ url: URL) {
      let folder = url.deletingLastPathComponent()
      _ = add(folder)
      let pbxproj = (try? String(contentsOf: url.appendingPathComponent("project.pbxproj"), encoding: .utf8)) ?? ""
      let packages = matches(
        of: #"isa = XCLocalSwiftPackageReference;[^}]*?relativePath = "?([^";]+)"?;"#, in: pbxproj)
      for groups in packages { addPackage(folder.appendingPathComponent(groups[0])) }
    }
    _ = add(root)
    addPackage(root)
    if let container {
      let url = root.appendingPathComponent(container)
      if container.hasSuffix(".xcodeproj") { addProject(url) }
      if container.hasSuffix(".xcworkspace") {
        let contents =
          (try? String(contentsOf: url.appendingPathComponent("contents.xcworkspacedata"), encoding: .utf8)) ?? ""
        for groups in matches(of: #"location = "(group|container|absolute):([^"]+)""#, in: contents) {
          let referenced =
            groups[0] == "absolute"
            ? URL(fileURLWithPath: groups[1]) : root.appendingPathComponent(groups[1])
          if referenced.pathExtension == "xcodeproj" { addProject(referenced) } else { addPackage(referenced) }
        }
      }
    }
    return outermost(found)
  }

  /// `folders` without the ones inside another of them, in their order.
  static func outermost(_ folders: [URL]) -> [URL] {
    folders.filter { folder in
      !folders.contains { other in other != folder && folder.path.hasPrefix(other.path + "/") }
    }
  }
}

/// What a build's source looks like now: one value that changes when a file of the project or of one of its local
/// dependencies changes, and stays when nothing did (a commit of what was already there, an amend or rebase that
/// keeps the content, a touched file, a rebuild).
///
/// In a Git repository a folder is the Git blob id of each file in its working tree: HEAD's (`git ls-tree`), with
/// the files `git status` reports changed or untracked hashed as Git would hash them, so it depends only on the
/// content, not on what is committed. `git status` runs without taking the index lock other tools wait on. Outside
/// Git a folder is its newest modification date and its file count.
public struct SourceFingerprint: Hashable, Codable, Sendable {
  public var value: String
  /// Some folder has uncommitted changes or isn't in Git, so the commit count alone can't say the app is current.
  public var isDirty: Bool

  public init(value: String, isDirty: Bool) {
    self.value = value
    self.isDirty = isDirty
  }

  /// The fingerprint of `scheme`'s project and its local dependencies (`LocalDependencies`).
  public static func of(_ scheme: ActionScheme) -> SourceFingerprint {
    of(folders: LocalDependencies.folders(of: scheme), salt: scheme.name)
  }

  /// The fingerprint of `folders`, with `salt` (the scheme) in it.
  public static func of(folders: [URL], salt: String = "") -> SourceFingerprint {
    var lines = ["v1", salt]
    var isDirty = false
    for folder in folders {
      let state = folderState(folder)
      lines.append(folder.standardizedFileURL.path + " " + state.value)
      isDirty = isDirty || state.isDirty
    }
    return SourceFingerprint(value: sha256(Data(lines.joined(separator: "\n").utf8)), isDirty: isDirty)
  }

  /// One folder's part: its working tree's blob ids in Git, else its newest modification date.
  static func folderState(_ folder: URL) -> SourceFingerprint {
    guard let location = git(["rev-parse", "--show-toplevel"], in: folder) else { return walkState(folder) }
    let topLevel = URL(fileURLWithPath: location.trimmingCharacters(in: .newlines))
    // Paths from the top level, as `git status` gives them. A repository without commits has no tree yet.
    var blobs: [String: String] = [:]
    let tree = git(["ls-tree", "-r", "-z", "--full-name", "HEAD", "--", "."], in: folder) ?? ""
    for entry in tree.split(separator: "\0") {
      // "<mode> <type> <id>\t<path>"
      guard let tab = entry.firstIndex(of: "\t") else { continue }
      let fields = entry[..<tab].split(separator: " ")
      guard fields.count == 3 else { continue }
      blobs[String(entry[entry.index(after: tab)...])] = String(fields[2])
    }
    let status =
      git(["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "."], in: folder)
      ?? ""
    var isDirty = false
    var entries = status.split(separator: "\0")[...]
    while let entry = entries.popFirst() {
      // "XY path"; a rename or copy lists its old path next.
      guard entry.count > 3 else { continue }
      isDirty = true
      let code = entry.prefix(2)
      if code.contains("R"), let old = entries.popFirst() {
        blobs[String(old)] = nil
      } else if code.contains("C") {
        _ = entries.popFirst()
      }
      let path = String(entry.dropFirst(3))
      blobs[path] = blobID(topLevel.appendingPathComponent(path))
    }
    let listing = blobs.keys.sorted().map { "\($0) \(blobs[$0]!)" }
    return SourceFingerprint(value: sha256(Data(listing.joined(separator: "\n").utf8)), isDirty: isDirty)
  }

  /// Files up to this size are hashed; larger ones are their size and date.
  static let hashLimit = 8 << 20

  /// The id Git gives a file's content (`git hash-object`; a link's is its target's path), nil when it's gone, its
  /// size and date when it's large.
  static func blobID(_ file: URL) -> String? {
    let manager = FileManager.default
    guard let attributes = try? manager.attributesOfItem(atPath: file.path) else { return nil }
    let data: Data
    if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
      data = Data(((try? manager.destinationOfSymbolicLink(atPath: file.path)) ?? "").utf8)
    } else {
      let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
      if size > hashLimit {
        let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "size:\(size):\(date)"
      }
      guard let contents = try? Data(contentsOf: file) else { return nil }
      data = contents
    }
    var hash = Insecure.SHA1()
    hash.update(data: Data("blob \(data.count)\0".utf8))
    hash.update(data: data)
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// A folder outside Git: its newest file date and how many files it has, skipping build output and hidden files.
  static func walkState(_ folder: URL) -> SourceFingerprint {
    let skipped: Set<String> = ["build", "DerivedData", "node_modules", "Pods", "Carthage"]
    var newest: TimeInterval = 0
    var count = 0
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
    let enumerator = FileManager.default.enumerator(
      at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    while let url = enumerator?.nextObject() as? URL {
      let values = try? url.resourceValues(forKeys: Set(keys))
      if values?.isDirectory == true {
        if skipped.contains(url.lastPathComponent) { enumerator?.skipDescendants() }
        continue
      }
      count += 1
      newest = max(newest, values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }
    return SourceFingerprint(value: "files:\(count):\(newest)", isDirty: true)
  }

  /// The number of commits at HEAD of the repository `folder` is in: the build number the v57 apps carry
  /// (`CFBundleVersion`), nil outside Git.
  public static func commitCount(in folder: URL) -> Int? {
    git(["rev-list", "--count", "HEAD"], in: folder).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }

  static func git(_ arguments: [String], in folder: URL) -> String? {
    SubprocessCapture.run("/usr/bin/git", ["-C", folder.path] + arguments, timeout: 30)
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
