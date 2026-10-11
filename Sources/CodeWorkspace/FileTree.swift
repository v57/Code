import CodeHighlighting
import Foundation
import Observation

/// The file tree of a project folder, as the sidebar shows it.
///
/// Folders list lazily: only expanded folders (and the root) are read, and
/// only those are re-read when the file watcher reports a change. Reloading
/// keeps the nodes of entries that still exist, so expansion and selection
/// survive.
@MainActor @Observable public final class FileTree {
  /// Names hidden from the tree and from Quick Open.
  public static let defaultExcludedNames: Set<String> = [
    ".git", ".svn", ".hg", ".DS_Store", ".build", ".swiftpm", "DerivedData", "node_modules",
    "xcuserdata",
  ]

  public let root: FileNode
  /// Expanded folders. The sidebar binds disclosure state to this.
  public var expanded: Set<URL> = []
  public var excludedNames: Set<String> {
    didSet {
      guard excludedNames != oldValue else { return }
      reloadAll()
    }
  }

  public init(root url: URL, excludedNames: Set<String> = FileTree.defaultExcludedNames) {
    self.excludedNames = excludedNames
    root = FileNode(url: url.standardizedFileURL, isDirectory: true, parent: nil)
    loadChildren(of: root)
  }

  // MARK: - Reading

  /// Lists `node`'s children if it is a folder that has not been read yet.
  public func loadChildren(of node: FileNode) {
    guard node.isDirectory, node.children == nil else { return }
    node.children = list(node)
  }

  /// Expands or collapses a folder, reading it first when it expands.
  public func setExpanded(_ node: FileNode, _ isExpanded: Bool) {
    if isExpanded {
      loadChildren(of: node)
      expanded.insert(node.url)
    } else {
      expanded.remove(node.url)
    }
  }

  /// Re-reads the folder at `url` if it has been read, keeping existing nodes.
  public func reload(directory url: URL) {
    guard let node = node(for: url), node.isDirectory, node.children != nil else { return }
    reload(node)
  }

  /// Re-reads every folder that has been read.
  public func reloadAll() {
    func walk(_ node: FileNode) {
      guard node.children != nil else { return }
      reload(node)
      for child in node.children ?? [] where child.isDirectory { walk(child) }
    }
    walk(root)
  }

  private func reload(_ node: FileNode) {
    let existing = Dictionary(
      (node.children ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let fresh = list(node).map { listed -> FileNode in
      if let old = existing[listed.name], old.isDirectory == listed.isDirectory { return old }
      return listed
    }
    if fresh.map(\.id) != (node.children ?? []).map(\.id) { node.children = fresh }
  }

  /// The loaded node for `url`, or nil when it is outside the tree or inside
  /// a folder that has not been read.
  public func node(for url: URL) -> FileNode? {
    let target = url.standardizedFileURL.pathComponents
    let base = root.url.pathComponents
    guard target.count >= base.count, Array(target.prefix(base.count)) == base else { return nil }
    var node = root
    for name in target.dropFirst(base.count) {
      guard let next = node.children?.first(where: { $0.name == name }) else { return nil }
      node = next
    }
    return node
  }

  /// Reads and expands every folder between the root and `url`, so the
  /// sidebar can show it. Returns its node.
  @discardableResult
  public func reveal(_ url: URL) -> FileNode? {
    walk(to: url, expandingTarget: false)
  }

  /// Reads and expands the folder at `url` and every folder above it.
  public func expand(_ url: URL) {
    walk(to: url, expandingTarget: true)
  }

  @discardableResult
  private func walk(to url: URL, expandingTarget: Bool) -> FileNode? {
    let target = url.standardizedFileURL.pathComponents
    let base = root.url.pathComponents
    guard target.count > base.count, Array(target.prefix(base.count)) == base else { return nil }
    var node = root
    for name in target.dropFirst(base.count) {
      loadChildren(of: node)
      if node !== root { expanded.insert(node.url) }
      guard let next = node.children?.first(where: { $0.name == name }) else { return nil }
      node = next
    }
    if expandingTarget, node.isDirectory {
      loadChildren(of: node)
      expanded.insert(node.url)
    }
    return node
  }

  /// The path of `url` relative to the root ("Sources/App/main.swift").
  public func relativePath(of url: URL) -> String {
    Self.relativePath(of: url, in: root.url)
  }

  public nonisolated static func relativePath(of url: URL, in root: URL) -> String {
    let path = url.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return path }
    return String(path.dropFirst(rootPath.count + 1))
  }

  /// `url`'s path with symlinks resolved, as FSEvents and directory
  /// enumerators report it ("/private/var/…" for "/var/…"; Foundation's
  /// `resolvingSymlinksInPath()` keeps "/var").
  public nonisolated static func realPath(of url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private func list(_ node: FileNode) -> [FileNode] {
    Self.listDirectory(node.url, excluding: excludedNames).map {
      FileNode(url: $0.url, isDirectory: $0.isDirectory, parent: node)
    }
  }

  /// The entries of `directory`: hidden files included (projects live on
  /// dotfiles), `excluded` names left out, folders first, then Finder order.
  /// A symlink to a folder counts as a folder.
  public nonisolated static func listDirectory(_ directory: URL, excluding excluded: Set<String>)
    -> [(url: URL, isDirectory: Bool)]
  {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: keys)
    else { return [] }
    let entries = urls.compactMap { url -> (url: URL, isDirectory: Bool)? in
      let name = url.lastPathComponent
      guard !excluded.contains(name) else { return nil }
      let values = try? url.resourceValues(forKeys: Set(keys))
      var isDirectory = values?.isDirectory ?? false
      if values?.isSymbolicLink == true {
        isDirectory =
          (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?
          .isDirectory ?? false
      }
      return (url.standardizedFileURL, isDirectory)
    }
    return entries.sorted { a, b in
      if a.isDirectory != b.isDirectory { return a.isDirectory }
      return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent)
        == .orderedAscending
    }
  }

  // MARK: - File operations

  public enum OperationError: LocalizedError {
    case alreadyExists(String)
    case invalidName(String)

    public var errorDescription: String? {
      switch self {
      case .alreadyExists(let name): return "“\(name)” already exists."
      case .invalidName(let name): return "“\(name)” isn’t a valid name."
      }
    }
  }

  /// Creates an empty file named `name` in `directory` and returns its URL.
  public func createFile(named name: String, in directory: URL) throws -> URL {
    let url = try destination(named: name, in: directory)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    reloadAfterChange(at: url)
    return url
  }

  /// Creates a folder named `name` in `directory` and returns its URL.
  public func createFolder(named name: String, in directory: URL) throws -> URL {
    let url = try destination(named: name, in: directory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    reloadAfterChange(at: url)
    return url
  }

  /// Renames the item at `url` and returns its new URL.
  public func rename(_ url: URL, to name: String) throws -> URL {
    let newURL = try destination(named: name, in: url.deletingLastPathComponent())
    try FileManager.default.moveItem(at: url, to: newURL)
    if expanded.remove(url) != nil { expanded.insert(newURL) }
    node(for: url)?.relocate(to: newURL)
    reload(directory: url.deletingLastPathComponent())
    return newURL
  }

  /// Moves the item at `url` to the Trash.
  public func trash(_ url: URL) throws {
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    expanded.remove(url)
    reload(directory: url.deletingLastPathComponent())
  }

  /// "name" in `directory`; names may contain "/" to create inside subfolders
  /// ("Sources/App.swift"), as in VS Code.
  private func destination(named name: String, in directory: URL) throws -> URL {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: "/").map(String.init)
    guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else {
      throw OperationError.invalidName(trimmed)
    }
    let url = parts.reduce(directory) { $0.appendingPathComponent($1) }.standardizedFileURL
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw OperationError.alreadyExists(parts.last!)
    }
    return url
  }

  /// Re-reads the folders from the root down to `url`'s parent: a name with
  /// "/" may have created several.
  private func reloadAfterChange(at url: URL) {
    var directory = url.deletingLastPathComponent().standardizedFileURL
    var folders: [URL] = []
    while directory.path.count >= root.url.path.count {
      folders.append(directory)
      if directory.path == root.url.path { break }
      directory = directory.deletingLastPathComponent()
    }
    for folder in folders.reversed() { reload(directory: folder) }
  }
}
