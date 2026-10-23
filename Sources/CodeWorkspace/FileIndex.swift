import Foundation
import Observation

/// Every file in a project (relative paths), for Quick Open. Built off the
/// main thread, and rebuilt when files are created, removed or renamed.
///
/// Hidden files (see `FileVisibility`) are left out unless
/// `includesHiddenFiles` is set: then they are listed in `hiddenPaths`, except
/// the inside of folders hidden by name (`.git`).
@MainActor @Observable public final class FileIndex {
  /// More files than this stops indexing (a home folder opened by mistake).
  public nonisolated static let limit = 100_000

  public let root: URL
  public private(set) var paths: [String] = []
  /// Hidden files, when `includesHiddenFiles` is set.
  public private(set) var hiddenPaths: [String] = []
  public private(set) var isIndexing = false
  /// Counts finished rebuilds, so a search kept elsewhere knows to run again.
  public private(set) var revision = 0
  /// True when indexing stopped at `limit`.
  public private(set) var isTruncated = false
  /// Also index hidden files (Quick Open's Hidden Files toggle). Setting it
  /// rebuilds the index the first time.
  public var includesHiddenFiles = false {
    didSet { if includesHiddenFiles != oldValue { rebuild() } }
  }

  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored var rules: VisibilityRules

  init(root: URL, rules: VisibilityRules) {
    self.root = root.standardizedFileURL
    self.rules = rules
  }

  /// Re-reads the project, replacing a rebuild already running.
  public func rebuild() {
    task?.cancel()
    isIndexing = true
    let root = root
    let rules = rules
    let includesHidden = includesHiddenFiles
    task = Task { [weak self] in
      let result = await Task.detached(priority: .utility) {
        Self.enumerate(root, rules: rules, includingHidden: includesHidden)
      }.value
      guard !Task.isCancelled, let self else { return }
      self.paths = result.paths
      self.hiddenPaths = result.hiddenPaths
      self.isTruncated = result.truncated
      self.isIndexing = false
      self.revision += 1
    }
  }

  /// The best matches for `query`, best first, with whether each is hidden.
  /// An empty query lists files in path order.
  public func search(_ query: String, includingHidden: Bool = false, limit: Int = 50) -> [(
    path: String, match: FuzzyMatch.Result, isHidden: Bool
  )] {
    Self.search(query, in: paths, hidden: includingHidden ? hiddenPaths : [], limit: limit)
  }

  /// Matches of `query` found off the main thread: a large project takes a moment per keystroke.
  public struct Matches: Sendable {
    public var results: [(path: String, match: FuzzyMatch.Result, isHidden: Bool)] = []
    /// How many hidden files match while they are left out of `results`.
    public var hiddenMatchCount = 0

    public init() {}
  }

  /// `search` and `hiddenMatchCount` on a background thread. Cancelling the calling task stops the search.
  public func matches(_ query: String, includingHidden: Bool = false, limit: Int = 50) async -> Matches {
    let paths = paths
    let hiddenPaths = hiddenPaths
    let task = Task.detached(priority: .userInitiated) {
      var matches = Matches()
      matches.results = Self.search(query, in: paths, hidden: includingHidden ? hiddenPaths : [], limit: limit)
      if !includingHidden { matches.hiddenMatchCount = Self.matchCount(query, in: hiddenPaths) }
      return matches
    }
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
  }

  nonisolated static func search(_ query: String, in paths: [String], hidden: [String], limit: Int)
    -> [(path: String, match: FuzzyMatch.Result, isHidden: Bool)]
  {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      let visible = paths.prefix(limit).map { ($0, FuzzyMatch.Result(score: 0, positions: []), false) }
      let rest = hidden.prefix(max(0, limit - visible.count)).map {
        ($0, FuzzyMatch.Result(score: 0, positions: []), true)
      }
      return visible + rest
    }
    var results: [(path: String, match: FuzzyMatch.Result, isHidden: Bool)] = []
    for (index, path) in paths.enumerated() {
      if index % 1024 == 0, Task.isCancelled { return [] }
      if let match = FuzzyMatch.match(trimmed, in: path) { results.append((path, match, false)) }
    }
    for path in hidden {
      if let match = FuzzyMatch.match(trimmed, in: path) { results.append((path, match, true)) }
    }
    // Hidden files rank a little lower, so a build product doesn't beat the
    // source file it was built from.
    func rank(_ r: (path: String, match: FuzzyMatch.Result, isHidden: Bool)) -> Int {
      r.match.score - (r.isHidden ? hiddenPenalty : 0)
    }
    results.sort { a, b in
      if rank(a) != rank(b) { return rank(a) > rank(b) }
      if a.isHidden != b.isHidden { return !a.isHidden }
      return a.path < b.path
    }
    return Array(results.prefix(limit))
  }

  /// How much lower hidden files score: about one word-start match.
  nonisolated static let hiddenPenalty = 10

  /// How many hidden files match `query`, when hidden files are indexed.
  public func hiddenMatchCount(_ query: String) -> Int {
    Self.matchCount(query, in: hiddenPaths)
  }

  nonisolated static func matchCount(_ query: String, in paths: [String]) -> Int {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return 0 }
    var count = 0
    for (index, path) in paths.enumerated() {
      if index % 1024 == 0, Task.isCancelled { return count }
      if FuzzyMatch.match(trimmed, in: path) != nil { count += 1 }
    }
    return count
  }

  /// Walks the project depth first, reading each folder's `.gitignore`
  /// before its entries. Symlinked folders are not followed.
  nonisolated static func enumerate(_ root: URL, rules: VisibilityRules, includingHidden: Bool)
    -> (paths: [String], hiddenPaths: [String], truncated: Bool)
  {
    var gitIgnore = GitIgnore(root: root)
    var paths: [String] = []
    var hiddenPaths: [String] = []
    var truncated = false
    let fm = FileManager.default

    func walk(_ folder: URL, _ folderPath: String, hidden folderHidden: Bool) {
      guard !truncated, !Task.isCancelled,
        let urls = try? fm.contentsOfDirectory(
          at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      else { return }
      if !folderHidden, !folderPath.isEmpty { gitIgnore.load(folder: folderPath) }
      for url in urls {
        let name = url.lastPathComponent
        let path = folderPath.isEmpty ? name : folderPath + "/" + name
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
        let reason =
          folderHidden ? nil : rules.reason(for: path, isDirectory: isDirectory, gitIgnore: gitIgnore)
        let isHidden = folderHidden || reason != nil
        if isDirectory {
          guard !isHidden || (includingHidden && reason != .name) else { continue }
          walk(url, path, hidden: isHidden)
        } else if !isHidden {
          paths.append(path)
        } else if includingHidden {
          hiddenPaths.append(path)
        }
        if paths.count + hiddenPaths.count >= limit {
          truncated = true
          return
        }
      }
    }
    walk(root, "", hidden: false)
    return (paths.sorted(), hiddenPaths.sorted(), truncated)
  }
}
