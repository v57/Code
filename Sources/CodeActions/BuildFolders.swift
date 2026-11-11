import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Where builds go once the user opts in (`standard`, `optIn`): an instance `<kind>/<project>/<n>` of a builds folder
/// (`~/Developer/Builds`), the layout the build-lease tool hands coding agents (`~/.claude/hooks/build-lease.py`), so
/// every worktree of a repo, the agents and Code share dependencies and build products and only the project's own
/// sources rebuild. `project` is the repo's main checkout relative to `~/Developer` ("v57/Shell"), plus the package's
/// folder inside the repo for SwiftPM and Cargo. By default, and when the folder doesn't exist, each tool builds where
/// it always does (Xcode's DerivedData, `.build`, `target`): a folder that happens to exist isn't consent (C-010).
public struct BuildFolders: Sendable {
  public enum Kind: String, Sendable {
    case xcode, swiftpm, cargo
  }

  /// `~/Developer`, which project names are relative to.
  public var developer: URL
  /// `~/Developer/Builds`.
  public var root: URL
  /// The agents' leases (`<instance path with / as __>.json`): an instance one holds isn't picked.
  public var leases: URL
  /// Whether builds go here at all; off, `instance` is always nil and schemes stay as they are.
  public var isEnabled: Bool

  public init(developer: URL, root: URL? = nil, leases: URL, isEnabled: Bool = true) {
    self.developer = developer
    self.root = root ?? developer.appendingPathComponent("Builds")
    self.leases = leases
    self.isEnabled = isEnabled
  }

  /// The environment variable and user default that opt in (`optIn`).
  public static let environmentKey = "V57_BUILD_FOLDERS"
  public static let defaultsKey = "V57BuildFolders"

  /// The builds folder the user or an agent chose, nil when nobody did: `V57_BUILD_FOLDERS` in the environment (the
  /// agents' shells), else the `V57BuildFolders` user default (the app's own, or every app's with `defaults write -g`).
  /// `1`/`yes`/`true` means `~/Developer/Builds`, a path means that folder, `0`/`no`/`false` or nothing means off.
  public static func optIn(
    environment: [String: String] = ProcessInfo.processInfo.environment, defaults: UserDefaults = .standard,
    home: URL = URL(fileURLWithPath: NSHomeDirectory())
  ) -> URL? {
    guard
      let value = (environment[environmentKey] ?? defaults.string(forKey: defaultsKey))?
        .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    switch value.lowercased() {
    case "0", "no", "false", "off": return nil
    case "1", "yes", "true", "on": return home.appendingPathComponent("Developer/Builds")
    default:
      let path = value.hasPrefix("~/") ? home.path + value.dropFirst(1) : value
      return URL(fileURLWithPath: path, isDirectory: true)
    }
  }

  /// The builds folder `optIn` names, off unless someone opted in: by default Xcode, SwiftPM and Cargo build where
  /// they always do.
  public static var standard: BuildFolders {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let root = optIn(home: home)
    return BuildFolders(
      developer: home.appendingPathComponent("Developer"), root: root,
      leases: home.appendingPathComponent(".claude/build-leases"), isEnabled: root != nil)
  }

  /// The record each instance keeps of its last build, which the build-lease tool reads and writes too.
  static let meta = ".build-lease.json"

  /// The instance to build `directory` into as `kind`, nil when off or `root` doesn't exist. Picks a free one (no live
  /// lease) last built from this folder, else the free one used most recently, else makes the next; records the build
  /// in it.
  public func instance(_ kind: Kind, for directory: URL, now: Date = Date()) -> URL? {
    var isDirectory: ObjCBool = false
    guard isEnabled, FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue
    else { return nil }
    let source = directory.resolvingSymlinksInPath()
    let project = root.appendingPathComponent(kind.rawValue).appendingPathComponent(projectName(source, kind))
    let existing =
      ((try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? [])
      .compactMap(Int.init).sorted()
    let free =
      existing
      .map { (n: $0, url: project.appendingPathComponent(String($0))) }
      .filter { !isLeased($0.url, now: now) }
      .map { (n: $0.n, url: $0.url, meta: Self.readMeta($0.url)) }
      .sorted {
        let (same0, same1) = ($0.meta["last_dir"] as? String == source.path, $1.meta["last_dir"] as? String == source.path)
        if same0 != same1 { return same0 }
        return ($0.meta["last_used"] as? Double ?? 0) > ($1.meta["last_used"] as? Double ?? 0)
      }
    let pick = free.first?.url ?? project.appendingPathComponent(String((existing.last ?? 0) + 1))
    try? FileManager.default.createDirectory(at: pick, withIntermediateDirectories: true)
    var meta = Self.readMeta(pick)
    meta["last_used"] = now.timeIntervalSince1970
    meta["last_dir"] = source.path
    if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: pick.appendingPathComponent(Self.meta))
    }
    return pick
  }

  /// "v57/Shell" for any worktree of ~/Developer/v57/Shell, "other/<name>" for a repo outside `developer`; SwiftPM
  /// and Cargo add the folder inside the repo ("v57/Hub/Scripts/Tests").
  func projectName(_ directory: URL, _ kind: Kind) -> String {
    let (top, main) = Self.checkoutRoots(directory)
    let developer = developer.resolvingSymlinksInPath().pathComponents
    let mainComponents = main.pathComponents
    var name =
      mainComponents.starts(with: developer) && mainComponents.count > developer.count
      ? mainComponents.dropFirst(developer.count).joined(separator: "/") : "other/" + main.lastPathComponent
    let inside = directory.pathComponents
    if kind != .xcode, inside.starts(with: top.pathComponents), inside.count > top.pathComponents.count {
      name += "/" + inside.dropFirst(top.pathComponents.count).joined(separator: "/")
    }
    return name
  }

  /// The checkout `directory` is in and the repo's main checkout (the same but in a linked worktree), found from the
  /// `.git` folder or file above it; `directory` for both outside Git.
  static func checkoutRoots(_ directory: URL) -> (top: URL, main: URL) {
    var components = directory.pathComponents
    while !components.isEmpty {
      let folder = URL(fileURLWithPath: NSString.path(withComponents: components), isDirectory: true)
      let git = folder.appendingPathComponent(".git")
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
        guard !isDirectory.boolValue else { return (folder, folder) }
        // A worktree's `gitdir: <main>/.git/worktrees/<name>`, whose commondir is the main .git; a submodule's has
        // none and is its own main checkout.
        guard let text = try? String(contentsOf: git, encoding: .utf8),
          let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:")
        else { return (folder, folder) }
        let gitdir = URL(
          fileURLWithPath: line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces), isDirectory: true,
          relativeTo: folder
        ).standardizedFileURL
        guard let common = try? String(contentsOf: gitdir.appendingPathComponent("commondir"), encoding: .utf8)
        else { return (folder, folder) }
        let commonURL = URL(
          fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true,
          relativeTo: gitdir
        ).standardizedFileURL
        return (folder, commonURL.lastPathComponent == ".git" ? commonURL.deletingLastPathComponent() : folder)
      }
      components.removeLast()
    }
    return (directory, directory)
  }

  /// Whether an agent's live lease holds `instance`: its process runs and it built there within the lease's
  /// lifetime (`BUILD_LEASE_TTL_MIN`, 60 minutes by default).
  func isLeased(_ instance: URL, now: Date) -> Bool {
    let relative = instance.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "__")
    guard let data = try? Data(contentsOf: leases.appendingPathComponent(relative + ".json")),
      let lease = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let pid = lease["pid"] as? Int
    else { return false }
    let minutes = ProcessInfo.processInfo.environment["BUILD_LEASE_TTL_MIN"].flatMap(Double.init) ?? 60
    let lastUsed = lease["last_used"] as? Double ?? 0
    guard now.timeIntervalSince1970 - lastUsed <= minutes * 60 else { return false }
    #if os(Windows)
      return true
    #else
      return kill(pid_t(pid), 0) == 0 || errno == EPERM
    #endif
  }

  static func readMeta(_ instance: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: instance.appendingPathComponent(meta)),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return [:] }
    return object
  }
}

extension ActionScheme {
  /// The scheme with its builds in `folders` (`BuildFolders`): Xcode's derived data, SwiftPM's scratch path and
  /// Cargo's target folder, and the executable built there. Unchanged when off (nobody opted in), when the folder
  /// doesn't exist or the toolchain has none. Leases nothing but records the build, so call it when an action starts, on the machine it runs on.
  public func inBuildFolders(_ folders: BuildFolders = .standard) -> ActionScheme {
    var scheme = self
    switch toolchain {
    case .xcode:
      guard let path = folders.instance(.xcode, for: directory)?.path else { return self }
      scheme.derivedDataPath = path
      let flag = "xcodebuild -derivedDataPath \(shellQuote(path)) "
      scheme.commands = commands.mapValues {
        $0.replacingOccurrences(of: "xcodebuild -project ", with: flag + "-project ")
          .replacingOccurrences(of: "xcodebuild -workspace ", with: flag + "-workspace ")
      }
    case .swiftPM:
      guard let path = folders.instance(.swiftpm, for: directory)?.path else { return self }
      scheme.commands = commands.mapValues { Self.swiftCommand($0, scratchPath: path) }
      scheme.executable = executable.map { $0.hasPrefix(".build/") ? path + $0.dropFirst(".build".count) : $0 }
    case .cargo:
      guard let path = folders.instance(.cargo, for: directory)?.path else { return self }
      scheme.commands = commands.mapValues { Self.cargoCommand($0, targetDirectory: path) }
      scheme.executable = executable.map { $0.hasPrefix("target/") ? path + $0.dropFirst("target".count) : $0 }
    default:
      return self
    }
    return scheme
  }
}
