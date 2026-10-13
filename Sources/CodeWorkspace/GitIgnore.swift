import Foundation

/// The `.gitignore` rules of a project: the project's own `.gitignore` files
/// (loaded folder by folder, as the tree and the index reach them), those of
/// the folders above it up to the repository root, and `.git/info/exclude`.
///
/// Matching follows git: the last matching pattern wins, a deeper
/// `.gitignore` beats a shallower one, `!` re-includes, a trailing `/`
/// matches only folders, and a pattern with a `/` before its end is anchored
/// to its file's folder. Callers skip the inside of an ignored folder, as git
/// does, so nothing inside it is re-included.
public struct GitIgnore: Sendable {
  public struct Rule: Sendable, Equatable {
    /// The line as written in the file ("build/", "!keep.log").
    public let line: String
    let pattern: [UInt8]
    let isNegated: Bool
    let isDirectoryOnly: Bool
    let isAnchored: Bool

    init?(line raw: String) {
      var text = Substring(raw)
      if text.hasSuffix("\r") { text = text.dropLast() }
      // Trailing spaces are dropped unless escaped.
      while text.hasSuffix(" "), !text.hasSuffix("\\ ") { text = text.dropLast() }
      guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
      line = String(text)
      isNegated = text.hasPrefix("!")
      if isNegated { text = text.dropFirst() }
      if text.hasPrefix("\\!") || text.hasPrefix("\\#") { text = text.dropFirst() }
      isDirectoryOnly = text.hasSuffix("/")
      if isDirectoryOnly { text = text.dropLast() }
      isAnchored = text.contains("/")
      if text.hasPrefix("/") { text = text.dropFirst() }
      guard !text.isEmpty else { return nil }
      pattern = Array(text.utf8)
    }

    /// Whether the rule matches `path`, relative to the rule's folder.
    func matches(_ path: Substring, isDirectory: Bool) -> Bool {
      if isDirectoryOnly && !isDirectory { return false }
      let subject = isAnchored ? path : path.split(separator: "/").last ?? path
      return GitIgnore.wildmatch(pattern, Array(subject.utf8))
    }
  }

  /// Rules from one file. `prefix` turns a project-relative path into one
  /// relative to the file's folder: "Code/" for a `.gitignore` one folder
  /// above a project named Code.
  struct RuleSet: Sendable {
    var prefix: String
    var rules: [Rule]
  }

  public let root: URL
  /// Rules from outside the project (lowest precedence first): the
  /// repository's `info/exclude`, then `.gitignore` files above the project.
  private var outer: [RuleSet] = []
  /// Rules from the project's own `.gitignore` files, by folder ("" for the
  /// root, "Sources/App").
  private var folders: [String: [Rule]] = [:]

  /// Reads the rules from above the project and the root's `.gitignore`.
  public init(root: URL) {
    self.root = root.standardizedFileURL
    loadOuterRules()
    load(folder: "")
  }

  /// Reads (or re-reads) the `.gitignore` in the project folder `folder`.
  public mutating func load(folder: String) {
    let url = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
    let rules = Self.rules(at: url.appendingPathComponent(".gitignore"))
    folders[folder] = rules.isEmpty ? nil : rules
  }

  /// Re-reads every `.gitignore` read so far.
  public mutating func reload() {
    let loaded = Array(folders.keys)
    outer = []
    loadOuterRules()
    folders = [:]
    load(folder: "")
    for folder in loaded where !folder.isEmpty { load(folder: folder) }
  }

  /// The rule that ignores `path` (project-relative), or nil when no rule
  /// does or the last match re-includes it.
  public func rule(ignoring path: String, isDirectory: Bool) -> Rule? {
    // Deepest .gitignore first; within a file, the last line first.
    var folder = Substring(path)
    while true {
      guard let slash = folder.lastIndex(of: "/") else {
        folder = ""
        if let rule = decide(folders[""], path[...], isDirectory) { return rule.isNegated ? nil : rule }
        break
      }
      folder = folder[..<slash]
      if let rules = folders[String(folder)] {
        let local = path[path.index(after: slash)...]
        if let rule = decide(rules, local, isDirectory) { return rule.isNegated ? nil : rule }
      }
    }
    for set in outer.reversed() {
      if let rule = decide(set.rules, Substring(set.prefix + path), isDirectory) {
        return rule.isNegated ? nil : rule
      }
    }
    return nil
  }

  private func decide(_ rules: [Rule]?, _ path: Substring, _ isDirectory: Bool) -> Rule? {
    rules?.last { $0.matches(path, isDirectory: isDirectory) }
  }

  /// Finds the repository root above the project and reads its
  /// `info/exclude` and every `.gitignore` between it and the project.
  private mutating func loadOuterRules() {
    // Walks path components, not URLs: `deletingLastPathComponent()` of "/"
    // is "/..", so a URL walk never reaches a fixed point above the root.
    var components = root.pathComponents.filter { $0 != "/" }
    var prefix = ""
    var sets: [RuleSet] = []
    let fm = FileManager.default
    while true {
      let folder = "/" + components.joined(separator: "/")
      if components.count < root.pathComponents.count - 1 {
        let rules = Self.rules(at: URL(fileURLWithPath: folder).appendingPathComponent(".gitignore"))
        if !rules.isEmpty { sets.append(RuleSet(prefix: prefix, rules: rules)) }
      }
      let git = URL(fileURLWithPath: folder).appendingPathComponent(".git")
      if fm.fileExists(atPath: git.path) {
        let exclude = Self.rules(at: git.appendingPathComponent("info/exclude"))
        if !exclude.isEmpty { sets.append(RuleSet(prefix: prefix, rules: exclude)) }
        break
      }
      // Not in a repository: only the project's own .gitignore files count.
      guard let name = components.popLast() else { return }
      prefix = name + "/" + prefix
    }
    outer = sets.reversed()
  }

  static func rules(at url: URL) -> [Rule] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
      Rule(line: String($0))
    }
  }

  // MARK: - Wildcards

  /// git's wildmatch: `*` and `?` stop at "/", `**` between slashes (or at
  /// either end) crosses folders, `[a-z]` and `[!a-z]` are classes, `\`
  /// escapes.
  static func wildmatch(_ pattern: [UInt8], _ text: [UInt8]) -> Bool {
    match(pattern, 0, text, 0)
  }

  private static let star = UInt8(ascii: "*")
  private static let slash = UInt8(ascii: "/")

  private static func match(_ p: [UInt8], _ start: Int, _ t: [UInt8], _ textStart: Int) -> Bool {
    var pi = start
    var ti = textStart
    while pi < p.count {
      switch p[pi] {
      case star:
        let isDouble = pi + 1 < p.count && p[pi + 1] == star
        if isDouble && (pi == 0 || p[pi - 1] == slash) {
          let after = pi + 2
          // "x/**": everything inside x.
          if after == p.count { return true }
          if p[after] == slash {
            // "**/": zero or more folders.
            var candidate = ti
            while true {
              if match(p, after + 1, t, candidate) { return true }
              guard let next = t[candidate...].firstIndex(of: slash) else { return false }
              candidate = next + 1
            }
          }
        }
        var rest = pi
        while rest < p.count && p[rest] == star { rest += 1 }
        if rest == p.count { return !t[ti...].contains(slash) }
        var candidate = ti
        while true {
          if match(p, rest, t, candidate) { return true }
          if candidate == t.count || t[candidate] == slash { return false }
          candidate += 1
        }
      case UInt8(ascii: "?"):
        guard ti < t.count, t[ti] != slash else { return false }
        pi += 1
        ti += 1
      case UInt8(ascii: "["):
        guard ti < t.count, t[ti] != slash else { return false }
        if let (matched, next) = matchClass(p, pi, t[ti]) {
          guard matched else { return false }
          pi = next
          ti += 1
        } else {
          guard t[ti] == p[pi] else { return false }
          pi += 1
          ti += 1
        }
      case UInt8(ascii: "\\") where pi + 1 < p.count:
        guard ti < t.count, t[ti] == p[pi + 1] else { return false }
        pi += 2
        ti += 1
      default:
        guard ti < t.count, t[ti] == p[pi] else { return false }
        pi += 1
        ti += 1
      }
    }
    return ti == t.count
  }

  /// Matches `c` against the class starting at `p[start]` ("["). Returns
  /// whether it matched and the index after "]", or nil when the class is
  /// not closed (the "[" is then literal).
  private static func matchClass(_ p: [UInt8], _ start: Int, _ c: UInt8) -> (Bool, Int)? {
    var i = start + 1
    var negated = false
    if i < p.count, p[i] == UInt8(ascii: "!") || p[i] == UInt8(ascii: "^") {
      negated = true
      i += 1
    }
    var matched = false
    var first = true
    while i < p.count {
      var low = p[i]
      if low == UInt8(ascii: "]") && !first { return (matched != negated, i + 1) }
      first = false
      if low == UInt8(ascii: "\\"), i + 1 < p.count {
        i += 1
        low = p[i]
      }
      if i + 2 < p.count, p[i + 1] == UInt8(ascii: "-"), p[i + 2] != UInt8(ascii: "]") {
        if low <= c && c <= p[i + 2] { matched = true }
        i += 3
      } else {
        if low == c { matched = true }
        i += 1
      }
    }
    return nil
  }
}
