import CodeModel
import CodeScan
import Foundation

/// A dependency as a manifest writes it.
struct CargoDependency {
  /// The name the crate uses for it (`-` as `_`).
  var name: String
  /// The package it is (`package = "…"`, else the key).
  var package: String
  var requirement = ""
  var path: String?
  var git: String?
  var rev: String?
  var optional = false
  var defaultFeatures = true
  var features: [String] = []
  var kind = Kind.normal

  enum Kind { case normal, dev, build }
}

/// A package's manifest: its targets, dependencies and features.
final class CargoPackage {
  let name: String
  var version: String
  let directory: String
  var edition = "2015"
  var libName: String
  var libPath: String?
  /// Binaries, tests, examples, benches: kind, name, root file.
  var targets: [(kind: String, name: String, path: String)] = []
  var dependencies: [CargoDependency] = []
  var featureTable: [String: [String]] = [:]
  var isProject = false
  /// What the dependencies resolve to, by the name the crate uses: a crate's display name.
  var resolved: [String: CargoPackage] = [:]
  var enabledDependencies: Set<String> = []

  init(name: String, version: String, directory: String) {
    self.name = name
    self.version = version
    self.directory = directory
    libName = name.replacingOccurrences(of: "-", with: "_")
  }

  /// The library crate's display name: the project's own by name, a dependency's with its version or folder.
  var libDisplay: String { isProject ? libName : libName + "@" + (directory.contains("/registry/src/") ? version : directory) }
}

/// A compilation unit: one target of a package, with its root file.
final class RustCrate {
  /// The core module's display name: `name` for a project library, `name#bin:x` for its other targets,
  /// `name@1.2.3` for a registry dependency, `name@/folder` for another, `std` for the standard library's stub.
  let display: String
  /// The name paths use for it (`crate` inside): a library's name, a binary's own.
  let pathName: String
  let root: String
  let package: CargoPackage?
  let kind: String

  init(display: String, pathName: String, root: String, package: CargoPackage?, kind: String) {
    self.display = display
    self.pathName = pathName
    self.root = root
    self.package = package
    self.kind = kind
  }
}

/// Rust's projects: crates from every `Cargo.toml` under the root (and the workspace above it), their files from the
/// module tree (`mod x;` → `x.rs` or `x/mod.rs`, `#[path]`), dependencies from the lock file in the registry
/// (`~/.cargo/registry/src`) or a git checkout (`~/.cargo/git/checkouts`) read when a path first names them, never
/// fetched, features unified as Cargo does, and the standard library from a stub (`RustStd`, no rust-src here).
final class RustLayout: ProjectLayout {
  static let registryMarker = "registry:"
  let config = RustConfig()
  lazy var rustSyntax = RustSyntax(config: config)
  var syntax: any LanguageSyntax { rustSyntax }
  let implicitModules: [String] = []
  let interfaceExtension = ".rs"
  let root: String
  private(set) var packages: [CargoPackage] = []
  /// Every crate by display name; the project's are made at once, dependencies' as they load.
  private(set) var crates: [String: RustCrate] = [:]
  /// A project file's crate, by absolute path.
  private(set) var crateOfFile: [String: String] = [:]
  private var lock: [(name: String, version: String, source: String, dependencies: [String])] = []
  private var workspaceDependencies: [String: Any] = [:]
  private var registryDirectories: [String] = []
  private var registryVersions: [String: [String]] = [:]
  private var packageCache: [String: CargoPackage] = [:]
  private let fileManager = FileManager.default
  let cargoHome: String

  init(root: String) {
    self.root = root
    let environment = ProcessInfo.processInfo.environment
    cargoHome = environment["CARGO_HOME"] ?? (NSHomeDirectory() + "/.cargo")
    let registry = cargoHome + "/registry/src"
    registryDirectories = ((try? fileManager.contentsOfDirectory(atPath: registry)) ?? []).sorted().map { registry + "/" + $0 }
    findPackages()
    resolveDependencies()
    resolveFeatures()
    makeCrates()
  }

  // MARK: Manifests

  private func findPackages() {
    var manifests: [String] = []
    var stack = [root]
    while let directory = stack.popLast() {
      guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
      for entry in entries {
        if entry.hasPrefix(".") || entry == "target" || entry == "node_modules" { continue }
        let path = directory + "/" + entry
        if entry == "Cargo.toml" {
          manifests.append(directory)
          continue
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { stack.append(path) }
      }
    }
    // The package and workspace above the root, when it's inside one.
    var above = (root as NSString).deletingLastPathComponent
    var workspaceRoot: String?
    var depth = 0
    while above.count > 1, depth < 6 {
      if fileManager.fileExists(atPath: above + "/Cargo.toml") {
        if !manifests.contains(root), manifests.isEmpty || isPackage(above) && !manifests.contains(above) { manifests.append(above) }
        if let toml = Toml.read(above + "/Cargo.toml"), toml["workspace"] != nil { workspaceRoot = above }
      }
      above = (above as NSString).deletingLastPathComponent
      depth += 1
    }
    for directory in manifests.sorted() {
      guard let toml = Toml.read(directory + "/Cargo.toml") else { continue }
      if let workspace = toml["workspace"] as? [String: Any] {
        if workspaceRoot == nil { workspaceRoot = directory }
        if let deps = workspace["dependencies"] as? [String: Any] { workspaceDependencies.merge(deps) { a, _ in a } }
      }
      if let package = makePackage(toml, directory: directory, isProject: true) { packages.append(package) }
    }
    // The lock: the root's, else the workspace's, else the nearest above.
    var lockDirectory: String? = fileManager.fileExists(atPath: root + "/Cargo.lock") ? root : nil
    if lockDirectory == nil, let workspaceRoot, fileManager.fileExists(atPath: workspaceRoot + "/Cargo.lock") { lockDirectory = workspaceRoot }
    if lockDirectory == nil {
      for package in packages where fileManager.fileExists(atPath: package.directory + "/Cargo.lock") {
        lockDirectory = package.directory
        break
      }
    }
    if let lockDirectory, let toml = Toml.read(lockDirectory + "/Cargo.lock"), let list = toml["package"] as? [Any] {
      for entry in list {
        guard let table = entry as? [String: Any], let name = table["name"] as? String, let version = table["version"] as? String else { continue }
        lock.append((name, version, table["source"] as? String ?? "", (table["dependencies"] as? [Any])?.compactMap { $0 as? String } ?? []))
      }
    }
  }

  private func isPackage(_ directory: String) -> Bool { Toml.read(directory + "/Cargo.toml")?["package"] != nil }

  private func makePackage(_ toml: [String: Any], directory: String, isProject: Bool) -> CargoPackage? {
    guard let table = toml["package"] as? [String: Any], let name = table["name"] as? String else { return nil }
    let version = table["version"] as? String ?? "0.0.0"
    let package = CargoPackage(name: name, version: version, directory: directory)
    package.isProject = isProject
    if let edition = table["edition"] as? String { package.edition = edition }
    if let lib = toml["lib"] as? [String: Any] {
      if let libName = lib["name"] as? String { package.libName = libName.replacingOccurrences(of: "-", with: "_") }
      if let path = lib["path"] as? String { package.libPath = directory + "/" + path }
      if (lib["proc-macro"] as? String) == "true" { package.targets.append(("proc-macro", package.libName, "")) }
    }
    if package.libPath == nil, fileManager.fileExists(atPath: directory + "/src/lib.rs") { package.libPath = directory + "/src/lib.rs" }
    if isProject { addTargets(package, toml) }
    func dependencies(_ value: Any?, kind: CargoDependency.Kind) {
      guard let list = value as? [String: Any] else { return }
      for (key, spec) in list {
        var dependency = CargoDependency(name: key.replacingOccurrences(of: "-", with: "_"), package: key)
        dependency.kind = kind
        var details: [String: Any] = [:]
        if let text = spec as? String {
          dependency.requirement = text
        } else if let inline = spec as? [String: Any] {
          details = inline
          if (inline["workspace"] as? String) == "true", let shared = workspaceDependencies[key] {
            if let text = shared as? String { details["version"] = text } else if let more = shared as? [String: Any] { details.merge(more) { own, _ in own } }
            if let features = inline["features"] as? [Any], let sharedFeatures = (shared as? [String: Any])?["features"] as? [Any] {
              details["features"] = features + sharedFeatures
            }
          }
        }
        if let requirement = details["version"] as? String { dependency.requirement = requirement }
        if let path = details["path"] as? String {
          let base = (details["workspace"] as? String) == "true" ? (workspaceRootDirectory(of: directory) ?? directory) : directory
          dependency.path = URL(fileURLWithPath: path.hasPrefix("/") ? path : base + "/" + path).standardizedFileURL.path
        }
        dependency.git = details["git"] as? String
        dependency.rev = (details["rev"] as? String) ?? (details["tag"] as? String) ?? (details["branch"] as? String)
        if let renamed = details["package"] as? String { dependency.package = renamed }
        dependency.optional = (details["optional"] as? String) == "true"
        dependency.defaultFeatures = (details["default-features"] as? String) != "false" && (details["default_features"] as? String) != "false"
        dependency.features = (details["features"] as? [Any])?.compactMap { $0 as? String } ?? []
        package.dependencies.append(dependency)
      }
    }
    dependencies(toml["dependencies"], kind: .normal)
    dependencies(toml["dev-dependencies"], kind: .dev)
    dependencies(toml["build-dependencies"], kind: .build)
    if let targets = toml["target"] as? [String: Any] {
      for (spec, value) in targets where RustLayout.targetHolds(spec) {
        guard let table = value as? [String: Any] else { continue }
        dependencies(table["dependencies"], kind: .normal)
        dependencies(table["dev-dependencies"], kind: .dev)
      }
    }
    if let features = toml["features"] as? [String: Any] {
      for (key, value) in features { package.featureTable[key] = (value as? [Any])?.compactMap { $0 as? String } ?? [] }
    }
    return package
  }

  private func workspaceRootDirectory(of directory: String) -> String? {
    var current = directory
    while current.count > 1 {
      if let toml = Toml.read(current + "/Cargo.toml"), toml["workspace"] != nil { return current }
      current = (current as NSString).deletingLastPathComponent
    }
    return nil
  }

  /// `cfg(unix)`, `cfg(target_os = "macos")` or a target triple: whether this Mac's build uses it.
  static func targetHolds(_ spec: String) -> Bool {
    if spec.hasPrefix("cfg(") {
      var reader = CfgText(text: Array(spec.utf8))
      reader.at = 4
      return reader.predicate()
    }
    #if arch(x86_64)
      let arch = "x86_64"
    #else
      let arch = "aarch64"
    #endif
    #if os(macOS)
      return spec == arch + "-apple-darwin"
    #elseif os(Linux)
      return spec.hasPrefix(arch) && spec.contains("linux")
    #else
      return false
    #endif
  }

  private func addTargets(_ package: CargoPackage, _ toml: [String: Any]) {
    let directory = package.directory
    var named: Set<String> = []
    for kind in ["bin", "test", "example", "bench"] {
      for entry in (toml[kind] as? [Any]) ?? [] {
        guard let table = entry as? [String: Any], let name = table["name"] as? String else { continue }
        var path = table["path"] as? String
        if path == nil {
          let folder = kind == "bin" ? "src/bin" : kind + "s"
          path = fileManager.fileExists(atPath: directory + "/\(folder)/\(name).rs") ? "\(folder)/\(name).rs" : "\(folder)/\(name)/main.rs"
          if kind == "bin", !fileManager.fileExists(atPath: directory + "/" + path!), fileManager.fileExists(atPath: directory + "/src/main.rs") { path = "src/main.rs" }
        }
        package.targets.append((kind, name, directory + "/" + path!))
        named.insert(directory + "/" + path!)
      }
    }
    func discover(_ kind: String, _ folder: String) {
      guard let entries = try? fileManager.contentsOfDirectory(atPath: directory + "/" + folder) else { return }
      for entry in entries.sorted() {
        var path = directory + "/" + folder + "/" + entry
        var name = entry
        if entry.hasSuffix(".rs") {
          name = String(entry.dropLast(3))
        } else if fileManager.fileExists(atPath: path + "/main.rs") {
          path += "/main.rs"
        } else {
          continue
        }
        if !named.contains(path) { package.targets.append((kind, name, path)) }
      }
    }
    if fileManager.fileExists(atPath: directory + "/src/main.rs"), !named.contains(directory + "/src/main.rs") {
      package.targets.append(("bin", package.name, directory + "/src/main.rs"))
    }
    discover("bin", "src/bin")
    discover("test", "tests")
    discover("example", "examples")
    discover("bench", "benches")
    if fileManager.fileExists(atPath: directory + "/build.rs") { package.targets.append(("build", "build_script_build", directory + "/build.rs")) }
    config.addTestFolder(directory + "/tests")
    config.addTestFolder(directory + "/benches")
  }

  // MARK: Dependencies

  private func registryDirectory(_ name: String, _ version: String) -> String? {
    for directory in registryDirectories {
      let path = directory + "/" + name + "-" + version
      if fileManager.fileExists(atPath: path + "/Cargo.toml") { return path }
    }
    return nil
  }

  /// A package outside the project, read once: from the registry, a git checkout or a folder.
  private func externalPackage(at directory: String, version: String?) -> CargoPackage? {
    if let known = packageCache[directory] { return known }
    if let project = packages.first(where: { $0.directory == directory }) { return project }
    guard let toml = Toml.read(directory + "/Cargo.toml"), let package = makePackage(toml, directory: directory, isProject: false) else { return nil }
    if let version { package.version = version }
    packageCache[directory] = package
    return package
  }

  private func versions(of name: String) -> [String] {
    if let known = registryVersions[name] { return known }
    var found: [String] = []
    for directory in registryDirectories {
      for entry in (try? fileManager.contentsOfDirectory(atPath: directory)) ?? [] where entry.hasPrefix(name + "-") {
        let version = String(entry.dropFirst(name.count + 1))
        if let first = version.first, first.isNumber { found.append(version) }
      }
    }
    found.sort { RustLayout.compareVersions($0, $1) > 0 }
    registryVersions[name] = found
    return found
  }

  static func compareVersions(_ a: String, _ b: String) -> Int {
    func parts(_ text: String) -> [Int] { text.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? [] }
    let x = parts(a)
    let y = parts(b)
    for k in 0..<max(x.count, y.count) {
      let p = k < x.count ? x[k] : 0
      let q = k < y.count ? y[k] : 0
      if p != q { return p < q ? -1 : 1 }
    }
    return 0
  }

  /// Whether a version meets a requirement as Cargo reads it (`1.2` is `^1.2`).
  static func satisfies(_ version: String, _ requirement: String) -> Bool {
    let trimmed = requirement.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed == "*" { return true }
    for part in trimmed.split(separator: ",") {
      var text = part.trimmingCharacters(in: .whitespaces)
      var op = "^"
      for candidate in [">=", "<=", "=", ">", "<", "^", "~"] where text.hasPrefix(candidate) {
        op = candidate
        text = String(text.dropFirst(candidate.count)).trimmingCharacters(in: .whitespaces)
        break
      }
      let wanted = text.replacingOccurrences(of: ".*", with: "")
      let order = compareVersions(version, wanted)
      let pieces = wanted.split(separator: ".").map { Int($0) ?? 0 }
      let have = version.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
      switch op {
      case ">=": if order < 0 { return false }
      case "<=": if order > 0 { return false }
      case ">": if order <= 0 { return false }
      case "<": if order >= 0 { return false }
      case "=": if order != 0 && !(pieces.count < 3 && Array(have.prefix(pieces.count)) == pieces) { return false }
      case "~":
        if order < 0 || Array(have.prefix(min(2, pieces.count))) != Array(pieces.prefix(2)) { return false }
      default:
        if order < 0 { return false }
        // The first non-zero part must match.
        var k = 0
        while k < pieces.count - 1, pieces[k] == 0 { k += 1 }
        if Array(have.prefix(k + 1)) != Array(pieces.prefix(k + 1)) { return false }
      }
    }
    return true
  }

  /// A dependency's package: a folder, the lock's version in the registry or a git checkout, else the newest
  /// version in the registry that meets the requirement.
  private func resolve(_ dependency: CargoDependency, of owner: CargoPackage) -> CargoPackage? {
    if let path = dependency.path { return externalPackage(at: path, version: nil) }
    if let member = packages.first(where: { $0.name == dependency.package }), dependency.git == nil { return member }
    // The lock's entry for the owner, then the version it names for this dependency.
    var version: String?
    var source = ""
    let candidates = lock.filter { $0.name == dependency.package }
    if candidates.count == 1 {
      version = candidates[0].version
      source = candidates[0].source
    } else if candidates.count > 1 {
      if let entry = lock.first(where: { $0.name == owner.name && $0.version == owner.version }) {
        for item in entry.dependencies where item == dependency.package || item.hasPrefix(dependency.package + " ") {
          let words = item.split(separator: " ")
          if words.count >= 2 { version = String(words[1]) }
        }
      }
      if version == nil { version = candidates.first(where: { RustLayout.satisfies($0.version, dependency.requirement) })?.version }
      source = candidates.first(where: { $0.version == version })?.source ?? ""
    }
    if source.hasPrefix("git+") || dependency.git != nil {
      return gitPackage(dependency.package, source: source, url: dependency.git, rev: dependency.rev)
    }
    if let version, let directory = registryDirectory(dependency.package, version) { return externalPackage(at: directory, version: version) }
    if let found = versions(of: dependency.package).first(where: { RustLayout.satisfies($0, dependency.requirement) }),
      let directory = registryDirectory(dependency.package, found)
    {
      return externalPackage(at: directory, version: found)
    }
    return nil
  }

  /// `~/.cargo/git/checkouts/<repo>-<hash>/<short rev>/…`: the package of that name in the checkout.
  private func gitPackage(_ name: String, source: String, url: String?, rev: String?) -> CargoPackage? {
    var repository = url ?? ""
    var commit = rev ?? ""
    if source.hasPrefix("git+") {
      let body = source.dropFirst(4)
      repository = String(body.split(separator: "?").first ?? body.split(separator: "#").first ?? "")
      if let hash = body.split(separator: "#").last, body.contains("#") { commit = String(hash) }
    }
    var repoName = repository.split(separator: "/").last.map(String.init) ?? name
    if repoName.hasSuffix(".git") { repoName.removeLast(4) }
    let checkouts = cargoHome + "/git/checkouts"
    for folder in ((try? fileManager.contentsOfDirectory(atPath: checkouts)) ?? []).sorted() where folder.hasPrefix(repoName + "-") {
      let base = checkouts + "/" + folder
      let revisions = ((try? fileManager.contentsOfDirectory(atPath: base)) ?? []).sorted()
      let chosen = revisions.first { !commit.isEmpty && commit.hasPrefix($0) } ?? revisions.first
      guard let chosen else { continue }
      if let found = findPackage(named: name, under: base + "/" + chosen) { return externalPackage(at: found, version: nil) }
    }
    return nil
  }

  private func findPackage(named name: String, under directory: String) -> String? {
    var stack = [directory]
    while let current = stack.popLast() {
      if let toml = Toml.read(current + "/Cargo.toml"), (toml["package"] as? [String: Any])?["name"] as? String == name { return current }
      for entry in (try? fileManager.contentsOfDirectory(atPath: current)) ?? [] where !entry.hasPrefix(".") && entry != "target" {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: current + "/" + entry, isDirectory: &isDirectory), isDirectory.boolValue { stack.append(current + "/" + entry) }
      }
    }
    return nil
  }

  private func resolveDependencies() {
    var queue = packages
    var seen = Set(packages.map(\.directory))
    while let package = queue.popLast() {
      for dependency in package.dependencies {
        if dependency.kind == .dev, !package.isProject { continue }
        guard package.resolved[dependency.name] == nil, let target = resolve(dependency, of: package) else { continue }
        package.resolved[dependency.name] = target
        if seen.insert(target.directory).inserted { queue.append(target) }
      }
    }
  }

  // MARK: Features

  /// Cargo's feature unification: the project's defaults, each dependency's requested features and defaults,
  /// `dep:x` and `x/feature` entries, optional dependencies a feature turns on.
  private func resolveFeatures() {
    var enabled: [String: Set<String>] = [:]
    var work: [(CargoPackage, String)] = []
    var active: Set<String> = []
    var all: [String: CargoPackage] = [:]
    func activate(_ package: CargoPackage) {
      all[package.directory] = package
      guard active.insert(package.directory).inserted else { return }
      for dependency in package.dependencies where !dependency.optional && (dependency.kind != .dev || package.isProject) && dependency.kind != .build {
        enableDependency(package, dependency.name)
      }
    }
    func enableDependency(_ package: CargoPackage, _ name: String) {
      package.enabledDependencies.insert(name)
      guard let target = package.resolved[name] else { return }
      activate(target)
      for dependency in package.dependencies where dependency.name == name {
        if dependency.defaultFeatures { work.append((target, "default")) }
        for feature in dependency.features { work.append((target, feature)) }
      }
    }
    for package in packages {
      activate(package)
      work.append((package, "default"))
    }
    while let (package, feature) = work.popLast() {
      guard enabled[package.directory, default: []].insert(feature).inserted else { continue }
      let entries = package.featureTable[feature]
      if entries == nil, package.dependencies.contains(where: { $0.name == feature.replacingOccurrences(of: "-", with: "_") && $0.optional }) {
        enableDependency(package, feature.replacingOccurrences(of: "-", with: "_"))
      }
      for entry in entries ?? [] {
        if entry.hasPrefix("dep:") {
          enableDependency(package, String(entry.dropFirst(4)).replacingOccurrences(of: "-", with: "_"))
        } else if let slash = entry.firstIndex(of: "/") {
          var depName = String(entry[..<slash])
          let weak = depName.hasSuffix("?")
          if weak { depName.removeLast() }
          let key = depName.replacingOccurrences(of: "-", with: "_")
          if !weak { enableDependency(package, key) }
          if let target = package.resolved[key] { work.append((target, String(entry[entry.index(after: slash)...]))) }
        } else {
          work.append((package, entry))
        }
      }
    }
    for (directory, set) in enabled { config.setFeatures(set, for: directory) }
    for package in all.values where enabled[package.directory] == nil { config.setFeatures([], for: package.directory) }
  }

  // MARK: Crates and files

  private func makeCrates() {
    for package in packages {
      if let lib = package.libPath {
        add(RustCrate(display: package.libName, pathName: package.libName, root: lib, package: package, kind: "lib"))
      }
      for target in package.targets where target.kind != "proc-macro" {
        let pathName = target.name.replacingOccurrences(of: "-", with: "_")
        add(RustCrate(display: package.libName + "#" + target.kind + ":" + target.name, pathName: pathName, root: target.path, package: package, kind: target.kind))
      }
    }
    // Each file joins the first crate whose module tree reaches it.
    for crate in crates.values.sorted(by: { ($0.kind == "lib" ? 0 : 1, $0.display) < ($1.kind == "lib" ? 0 : 1, $1.display) }) {
      var queue = [(crate.root, true)]
      while let (path, isModRoot) = queue.popLast() {
        guard crateOfFile[path] == nil, fileManager.fileExists(atPath: path) else { continue }
        crateOfFile[path] = crate.display
        for child in RustLayout.childModuleFiles(of: path, isModRoot: isModRoot, syntax: rustSyntax) { queue.append(child) }
      }
    }
  }

  private func add(_ crate: RustCrate) { crates[crate.display] = crate }

  /// The files `mod x;` declarations in a file name, from its tokens alone (no cfg): with whether each is a module
  /// root (`mod.rs`, or named by `#[path]`).
  static func childModuleFiles(of path: String, isModRoot: Bool, syntax: RustSyntax) -> [(String, Bool)] {
    guard let data = FileManager.default.contents(atPath: path) else { return [] }
    let source = SourceFile(bytes: data, profile: syntax.profile)
    let tokens = source.tokens.filter { $0.kind != .comment && $0.kind != .docComment }
    func text(_ i: Int) -> String { source.string(tokens[i]) }
    var result: [(String, Bool)] = []
    var inline: [String?] = []
    let directory = (path as NSString).deletingLastPathComponent
    let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    let base = isModRoot ? directory : directory + "/" + stem
    var i = 0
    while i < tokens.count {
      let token = tokens[i]
      if token.kind == .open, source.text[token.start] == 0x7B {
        inline.append(nil)
      } else if token.kind == .close, source.text[token.start] == 0x7D {
        if !inline.isEmpty { inline.removeLast() }
      } else if text(i) == "mod", i + 2 < tokens.count, tokens[i + 1].kind == .identifier || tokens[i + 1].kind == .keyword {
        let name = text(i + 1)
        if tokens[i + 2].kind == .open, source.text[tokens[i + 2].start] == 0x7B {
          inline.append(name)
          i += 3
          continue
        }
        if source.text[tokens[i + 2].start] == 0x3B {
          let inlinePath = inline.compactMap { $0 }
          // `#[path = "…"]` before it.
          var attributePath: String?
          var k = i - 1
          while k >= 0, tokens[k].kind == .keyword || tokens[k].kind == .identifier && text(k) == "pub" || tokens[k].kind == .open || tokens[k].kind == .close { k -= 1 }
          while k >= 0, tokens[k].kind == .attribute {
            let attribute = text(k)
            if let range = attribute.range(of: "path"), let quote = attribute[range.upperBound...].firstIndex(of: "\"") {
              let rest = attribute[attribute.index(after: quote)...]
              if let end = rest.firstIndex(of: "\"") { attributePath = String(rest[..<end]) }
            }
            k -= 1
          }
          if let attributePath {
            let folder = inlinePath.isEmpty ? directory : base + "/" + inlinePath.joined(separator: "/")
            result.append((URL(fileURLWithPath: folder + "/" + attributePath).standardizedFileURL.path, true))
          } else {
            let folder = ([base] + inlinePath).joined(separator: "/")
            if FileManager.default.fileExists(atPath: folder + "/" + name + ".rs") {
              result.append((folder + "/" + name + ".rs", false))
            } else {
              result.append((folder + "/" + name + "/mod.rs", true))
            }
          }
        }
      }
      i += 1
    }
    return result
  }

  func sourceFiles(in directory: String) -> [String] {
    var result: [String] = []
    var stack = [directory]
    while let current = stack.popLast() {
      guard let entries = try? fileManager.contentsOfDirectory(atPath: current) else { continue }
      for entry in entries {
        if entry.hasPrefix(".") || entry == "target" || entry == "node_modules" { continue }
        let path = current + "/" + entry
        if entry.hasSuffix(".rs") {
          result.append(path)
          continue
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { stack.append(path) }
      }
    }
    return result.sorted()
  }

  func moduleName(ofRelative path: String) -> String {
    let full = path.hasPrefix("/") ? path : root + "/" + path
    if let crate = crateOfFile[full] { return crate }
    // A file no crate reaches: its package's library, else its own.
    for package in packages.sorted(by: { $0.directory.count > $1.directory.count }) where full.hasPrefix(package.directory + "/") {
      if package.libPath != nil { return package.libName }
    }
    return "#file:" + path
  }

  /// The project crate a file is in, if any.
  func crate(ofFile path: String) -> RustCrate? {
    guard let display = crateOfFile[path] else { return nil }
    return crates[display]
  }

  /// What a crate's code sees by name (`serde`, `tokio`): its dependencies' library crates; a package's other targets
  /// also see its library. Dev-dependencies count for the project's crates (tests use them).
  func externCrates(of crate: RustCrate) -> [String: String] {
    var result: [String: String] = ["std": "std", "core": "std", "alloc": "std"]
    guard let package = crate.package else { return result }
    for dependency in package.dependencies {
      if dependency.kind == .build, crate.kind != "build" { continue }
      if dependency.kind == .dev, !package.isProject { continue }
      if dependency.optional, !package.enabledDependencies.contains(dependency.name) { continue }
      guard let target = package.resolved[dependency.name], target.libPath != nil || target.targets.contains(where: { $0.kind == "proc-macro" }) else { continue }
      result[dependency.name] = target.libDisplay
      remember(target)
    }
    if crate.kind != "lib", package.libPath != nil { result[package.libName] = package.libDisplay }
    return result
  }

  private func remember(_ package: CargoPackage) {
    let display = package.libDisplay
    if crates[display] == nil, let lib = package.libPath ?? (package.targets.contains { $0.kind == "proc-macro" } ? package.directory + "/src/lib.rs" : nil) {
      crates[display] = RustCrate(display: display, pathName: package.libName, root: lib, package: package, kind: "lib")
    }
  }

  // MARK: Loading

  /// A dependency's library (`name@version`, `name@/folder`) or the standard library's stub (`std`): its files from the
  /// module tree, as the parser keeps them (cfg-aware).
  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    if display == "std" { return loadStd(into: project) }
    guard display.contains("@"), let crate = crates[display] else { return nil }
    var paths: [String] = []
    var queue = [(crate.root, true)]
    var seen: Set<String> = []
    while let (path, isModRoot) = queue.popLast() {
      guard seen.insert(path).inserted, fileManager.fileExists(atPath: path) else { continue }
      paths.append(path)
      for child in RustLayout.childModuleFiles(of: path, isModRoot: isModRoot, syntax: rustSyntax) { queue.append(child) }
    }
    guard !paths.isEmpty else { return nil }
    let units = project.parse(paths, isInterface: false)
    return project.register(display, units, isSDK: true)
  }

  private func loadStd(into project: Project) -> Module? {
    let directory = NSTemporaryDirectory() + "code-rust-std"
    let path = directory + "/std.rs"
    let text = RustStd.source
    if (try? String(contentsOfFile: path, encoding: .utf8)) != text {
      try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
      try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
    let unit = Unit(path: path, source: SourceFile(text, profile: rustSyntax.profile), syntax: rustSyntax)
    let crate = RustCrate(display: "std", pathName: "std", root: path, package: nil, kind: "lib")
    crates["std"] = crate
    return project.register("std", [unit], isSDK: true)
  }

  /// A registry or checkout file's place: `registry:<name>-<version>/<path>`, `git:<repo>/<path>`.
  func externalPlace(_ path: String) -> String? {
    for directory in registryDirectories where path.hasPrefix(directory + "/") { return RustLayout.registryMarker + path.dropFirst(directory.count + 1) }
    let checkouts = cargoHome + "/git/checkouts/"
    if path.hasPrefix(checkouts) {
      let parts = path.dropFirst(checkouts.count).split(separator: "/").map(String.init)
      guard parts.count > 2 else { return nil }
      let repo = parts[0].split(separator: "-").dropLast().joined(separator: "-")
      return "git:" + repo + "/" + parts[2...].joined(separator: "/")
    }
    return nil
  }
}

/// A cfg predicate in a manifest's `[target.'cfg(…)']`.
struct CfgText {
  let text: [UInt8]
  var at = 0

  mutating func skip() { while at < text.count, text[at] == 0x20 || text[at] == 0x2C { at += 1 } }

  mutating func word() -> String {
    skip()
    let start = at
    while at < text.count, text[at] == 0x5F || (text[at] | 0x20 >= 0x61 && text[at] | 0x20 <= 0x7A) || (text[at] >= 0x30 && text[at] <= 0x39) { at += 1 }
    return String(decoding: text[start..<at], as: UTF8.self)
  }

  mutating func predicate() -> Bool {
    let name = word()
    skip()
    if at < text.count, text[at] == 0x28, ["all", "any", "not"].contains(name) {
      at += 1
      var values: [Bool] = []
      while at < text.count {
        skip()
        if text[at] == 0x29 {
          at += 1
          break
        }
        let before = at
        values.append(predicate())
        if at == before { at += 1 }
      }
      switch name {
      case "all": return values.allSatisfy { $0 }
      case "any": return values.contains(true)
      default: return !(values.first ?? false)
      }
    }
    if at < text.count, text[at] == 0x3D {
      at += 1
      skip()
      guard at < text.count, text[at] == 0x22 else { return false }
      at += 1
      let start = at
      while at < text.count, text[at] != 0x22 { at += 1 }
      let value = String(decoding: text[start..<at], as: UTF8.self)
      at += 1
      return RustConfig.holds(name, value, features: [], test: false)
    }
    return RustConfig.holds(name, nil, features: [], test: false)
  }
}
