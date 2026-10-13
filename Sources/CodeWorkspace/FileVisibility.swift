import Foundation

/// Which files a project hides from its navigator and Quick Open: version
/// control folders and `.DS_Store`, files that match `.gitignore` (unless
/// turned off), and anything the user hid. The user can also show any hidden
/// item, which overrides the other rules.
public struct FileVisibility: Codable, Equatable, Sendable {
  /// Names hidden wherever they appear.
  public static let defaultHiddenNames: Set<String> = [".git", ".svn", ".hg", ".DS_Store"]

  /// Whether `.gitignore` hides files; nil follows the app's setting.
  public var hidesIgnoredFiles: Bool?
  /// Project-relative paths the user hid.
  public var hiddenPaths: Set<String> = []
  /// Project-relative paths the user shows although a rule hides them.
  public var shownPaths: Set<String> = []
  /// The navigator lists hidden items too (⇧⌘.).
  public var showsHiddenFiles = false

  public init() {}

  /// True when the project follows the defaults (the navigator's ⇧⌘.
  /// toggle aside), so Restore Defaults has nothing to do.
  public var isDefault: Bool {
    hidesIgnoredFiles == nil && hiddenPaths.isEmpty && shownPaths.isEmpty
  }
}

/// Why an item is hidden.
public enum HiddenReason: Equatable, Sendable {
  /// A name hidden everywhere (`FileVisibility.defaultHiddenNames`).
  case name
  /// The user hid it in this project.
  case user
  /// A `.gitignore` line matches it.
  case gitIgnore(String)

  public var description: String {
    switch self {
    case .name: return "Hidden by default"
    case .user: return "Hidden in this project"
    case .gitIgnore(let line): return "Matches .gitignore: \(line)"
    }
  }
}

/// The rules in effect for one project, for deciding item by item.
struct VisibilityRules: Sendable {
  var visibility: FileVisibility
  var hidesIgnoredFiles: Bool

  /// Why the item at `path` is hidden on its own (not counting a hidden
  /// folder above it), or nil.
  func reason(for path: String, isDirectory: Bool, gitIgnore: GitIgnore) -> HiddenReason? {
    if visibility.shownPaths.contains(path) { return nil }
    return ruleReason(for: path, isDirectory: isDirectory, gitIgnore: gitIgnore)
  }

  /// The reason from the rules alone, without the user's "show" overrides.
  func ruleReason(for path: String, isDirectory: Bool, gitIgnore: GitIgnore) -> HiddenReason? {
    if visibility.hiddenPaths.contains(path) { return .user }
    let name = path.split(separator: "/").last.map(String.init) ?? path
    if FileVisibility.defaultHiddenNames.contains(name) { return .name }
    if hidesIgnoredFiles, let rule = gitIgnore.rule(ignoring: path, isDirectory: isDirectory) {
      return .gitIgnore(rule.line)
    }
    return nil
  }
}
