import Foundation

/// Folders whose own code may run (security audit H1, H2, L10), as VS Code's workspace trust: a cloned repository
/// can ship a `buildServer.json` that sourcekit-lsp runs, a `node_modules/.bin/prettier`, a `Package.swift` that
/// `dump-package` evaluates and package URLs `xcodebuild` resolves. Until the person trusts the folder, the libraries
/// run none of it: `code-lsp` is its only language server, formatters come from PATH and skip configs that are code,
/// and nothing reads the project through `xcodebuild` or SwiftPM.
///
/// A host that keeps no trust (Shell, Dev: their folders are the person's own) never calls `use(_:)`, and every folder
/// is trusted there. Code installs its store at launch: the folders it trusts, in its keychain item, not defaults,
/// where the repository's own scripts could add themselves. A folder inside a trusted one is trusted.
public enum FolderTrust {
  /// Where the trusted folders are kept.
  public struct Store: Sendable {
    public var load: @Sendable () -> Set<String>
    public var save: @Sendable (Set<String>) -> Void

    public init(load: @escaping @Sendable () -> Set<String>, save: @escaping @Sendable (Set<String>) -> Void) {
      self.load = load
      self.save = save
    }

    /// Kept for this process only (tests).
    public static func memory() -> Store {
      let box = Box()
      return Store(load: { box.withLock { $0 } }, save: { paths in box.withLock { $0 = paths } })
    }
  }

  private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []
    func withLock<T>(_ body: (inout Set<String>) -> T) -> T { lock.withLock { body(&paths) } }
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var store: Store?
  nonisolated(unsafe) private static var trusted: Set<String>?

  /// Makes trust apply: from now on a folder is trusted only once `trust(_:)` named it or a folder above it.
  public static func use(_ store: Store) {
    lock.withLock {
      self.store = store
      trusted = nil
    }
  }

  /// Whether trust applies in this process (Code), so folders can be untrusted at all.
  public static var isInUse: Bool { lock.withLock { store != nil } }

  /// Whether the folder's own code may run: it or a folder above it was trusted, or this host keeps no trust.
  public static func isTrusted(_ url: URL) -> Bool {
    lock.withLock {
      guard let store else { return true }
      let paths = trusted ?? store.load()
      trusted = paths
      return contains(paths, url)
    }
  }

  /// Trusts a folder and everything in it.
  public static func trust(_ url: URL) {
    lock.withLock {
      guard let store else { return }
      var paths = trusted ?? store.load()
      paths.insert(path(url))
      trusted = paths
      store.save(paths)
    }
  }

  /// Takes the trust of a folder back (and of the folders inside it that were trusted on their own).
  public static func distrust(_ url: URL) {
    lock.withLock {
      guard let store else { return }
      let removed = path(url)
      var paths = trusted ?? store.load()
      paths = paths.filter { $0 != removed && !$0.hasPrefix(removed == "/" ? "/" : removed + "/") }
      trusted = paths
      store.save(paths)
    }
  }

  /// The trusted folders, for settings.
  public static var trustedFolders: [String] {
    lock.withLock {
      guard let store else { return [] }
      let paths = trusted ?? store.load()
      trusted = paths
      return paths.sorted()
    }
  }

  static func contains(_ paths: Set<String>, _ url: URL) -> Bool {
    var candidate = path(url)
    while true {
      if paths.contains(candidate) { return true }
      let parent = (candidate as NSString).deletingLastPathComponent
      if parent == candidate || parent.isEmpty { return false }
      candidate = parent
    }
  }

  /// The folder's path with links resolved, so a link to a folder isn't a way around it.
  static func path(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path
  }
}
