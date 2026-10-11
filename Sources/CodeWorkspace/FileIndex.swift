import Foundation
import Observation

/// Every file in a project (relative paths), for Quick Open. Built off the
/// main thread, and rebuilt when files are created, removed or renamed.
@MainActor @Observable public final class FileIndex {
  /// More files than this stops indexing (a home folder opened by mistake).
  public nonisolated static let limit = 100_000

  public let root: URL
  public private(set) var paths: [String] = []
  public private(set) var isIndexing = false
  /// True when indexing stopped at `limit`.
  public private(set) var isTruncated = false

  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var excludedNames: Set<String>

  public init(root: URL, excludedNames: Set<String>) {
    self.root = root.standardizedFileURL
    self.excludedNames = excludedNames
  }

  /// Re-reads the project, replacing a rebuild already running.
  public func rebuild(excludedNames: Set<String>? = nil) {
    if let excludedNames { self.excludedNames = excludedNames }
    task?.cancel()
    isIndexing = true
    let root = root
    let excluded = self.excludedNames
    task = Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        Self.enumerate(root, excluding: excluded)
      }.value
      guard !Task.isCancelled, let self else { return }
      self.paths = result.paths
      self.isTruncated = result.truncated
      self.isIndexing = false
    }
  }

  /// The best matches for `query`, best first. An empty query lists files in
  /// path order.
  public func search(_ query: String, limit: Int = 50) -> [(path: String, match: FuzzyMatch.Result)] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      return paths.prefix(limit).map { ($0, FuzzyMatch.Result(score: 0, positions: [])) }
    }
    var results: [(path: String, match: FuzzyMatch.Result)] = []
    for path in paths {
      if let match = FuzzyMatch.match(trimmed, in: path) { results.append((path, match)) }
    }
    results.sort { a, b in
      a.match.score != b.match.score ? a.match.score > b.match.score : a.path < b.path
    }
    return Array(results.prefix(limit))
  }

  nonisolated static func enumerate(_ root: URL, excluding excluded: Set<String>) -> (
    paths: [String], truncated: Bool
  ) {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])
    else { return ([], false) }
    var paths: [String] = []
    // The enumerator reports real paths ("/private/var/…" under "/var/…").
    let prefixes = Set([root.path, FileTree.realPath(of: root)]).map { $0 + "/" }
    for case let url as URL in enumerator {
      if Task.isCancelled { break }
      if excluded.contains(url.lastPathComponent) {
        enumerator.skipDescendants()
        continue
      }
      if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
      let path = url.path
      let prefix = prefixes.first { path.hasPrefix($0) }
      paths.append(prefix.map { String(path.dropFirst($0.count)) } ?? path)
      if paths.count >= limit { return (paths.sorted(), true) }
    }
    return (paths.sorted(), false)
  }
}
