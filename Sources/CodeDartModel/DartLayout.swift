import CodeModel
import CodeScan
import Foundation

/// A package under the root: a folder with a `pubspec.yaml`, and the packages its files name by `package:`.
struct DartPackage {
  var name: String
  var directory: String
  /// Package names to their `lib` folders, as this package resolves them.
  var packages: [String: String] = [:]
}

/// Dart's projects: every `.dart` file under the root (build output, `.dart_tool`, hidden folders and platform build
/// folders left out) is a library, or a part of the library that names it (`part`/`part of`), which is one module with
/// it, named by the library's path. A file's `package:` URIs resolve through its package (the deepest folder with a
/// `pubspec.yaml` above it): `.dart_tool/package_config.json` (paths written for another machine's pub cache are read
/// from this one's), else `pubspec.lock` with the pub cache (`PUB_CACHE`, `~/.pub-cache`), then the packages under the
/// root by name. Nothing is fetched: a package not on disk stays unknown. `dart:` libraries come from a Dart SDK on disk
/// (`CODE_DART_SDK`, `DART_SDK`, a Flutter SDK's, Homebrew's, `/usr/lib/dart`), else from `DartStd`, a hand-written stub,
/// one module per library (`dart:core`).
final class DartLayout: ProjectLayout {
  let syntax: any LanguageSyntax
  let implicitModules: [String] = []
  let interfaceExtension = ".dart"
  let root: String
  private(set) var packages: [DartPackage] = []
  /// Each project file's library (its own path, or its owner's for a part).
  private var owners: [String: String] = [:]
  private var files: [String] = []
  /// `lib` folders of every package known, longest first, for places (`package:a/b.dart`).
  private(set) var packageLibraries: [(name: String, lib: String)] = []
  /// The Dart SDK's `lib` folder, when one is on disk; nil: the stub.
  let sdkLibrary: String?
  let flutterRoot: String?
  static let skipped: Set<String> = ["build", "node_modules", "Pods", "ephemeral", "DerivedData", ".dart_tool"]
  /// Where the stub's files are written when one is opened.
  static let stdDirectory = NSTemporaryDirectory() + "code-dart-std"

  init(root: String) {
    self.root = root
    let environment = ProcessInfo.processInfo.environment
    let home = NSHomeDirectory()
    let flutter = DartLayout.findFlutter(environment: environment, home: home, root: root)
    flutterRoot = flutter
    sdkLibrary = DartLayout.findSDK(environment: environment, flutter: flutter)
    let table = Table()
    let sdk = sdkLibrary
    let flutterUI = flutter.map { $0 + "/bin/cache/pkg/sky_engine/lib/ui/ui.dart" }
    syntax = DartSyntax(resolve: { from, uri in table.resolve(from: from, uri: uri, sdk: sdk, flutterUI: flutterUI) })
    readPackages(environment: environment, home: home, table: table)
    readFiles()
  }

  /// What the resolver reads, filled before any file is parsed and only read after.
  final class Table: @unchecked Sendable {
    var packages: [DartPackage] = []
    var all: [String: String] = [:]

    func resolve(from: String, uri: String, sdk: String?, flutterUI: String?) -> String? {
      if uri.hasPrefix("dart:") {
        let library = String(uri.dropFirst(5))
        return library.isEmpty ? nil : uri
      }
      if uri.hasPrefix("package:") {
        let rest = uri.dropFirst(8)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let package = String(rest[..<slash])
        let path = String(rest[rest.index(after: slash)...])
        let owner = packages.last { from.hasPrefix($0.directory + "/") }
        guard let lib = owner?.packages[package] ?? all[package] else { return nil }
        return DartLayout.standardize(lib + "/" + path)
      }
      if uri.contains(":") { return nil }
      let directory = (from as NSString).deletingLastPathComponent
      return DartLayout.standardize(directory + "/" + uri)
    }
  }

  static func standardize(_ path: String) -> String {
    var parts: [Substring] = []
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
      if part == "." { continue }
      if part == "..", !parts.isEmpty, parts.last != ".." {
        parts.removeLast()
        continue
      }
      parts.append(part)
    }
    return "/" + parts.joined(separator: "/")
  }

  // MARK: SDKs

  static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  /// A Flutter SDK: `FLUTTER_ROOT`, the project's `.fvm/flutter_sdk`, FVM's default, the usual install folders.
  static func findFlutter(environment: [String: String], home: String, root: String) -> String? {
    var candidates: [String] = []
    if let value = environment["FLUTTER_ROOT"] { candidates.append(value) }
    candidates.append(root + "/.fvm/flutter_sdk")
    candidates += [home + "/fvm/default", home + "/flutter", home + "/development/flutter", home + "/sdk/flutter", "/opt/flutter", home + "/snap/flutter/common/flutter"]
    for cask in ["/opt/homebrew/Caskroom/flutter", "/usr/local/Caskroom/flutter"] {
      let versions = Toolchains.newestFirst((try? FileManager.default.contentsOfDirectory(atPath: cask)) ?? [])
      for version in versions { candidates.append(cask + "/" + version + "/flutter") }
    }
    let fvm = Toolchains.newestFirst((try? FileManager.default.contentsOfDirectory(atPath: home + "/fvm/versions")) ?? [])
    for version in fvm { candidates.append(home + "/fvm/versions/" + version) }
    return candidates.first { isDirectory($0 + "/packages/flutter/lib") }
  }

  /// A Dart SDK's `lib` folder: `CODE_DART_SDK`, `DART_SDK`, the Flutter SDK's, Homebrew's, Linux's, Windows'.
  static func findSDK(environment: [String: String], flutter: String?) -> String? {
    var candidates: [String] = []
    for key in ["CODE_DART_SDK", "DART_SDK"] { if let value = environment[key] { candidates.append(value) } }
    if let flutter { candidates.append(flutter + "/bin/cache/dart-sdk") }
    candidates += [
      "/opt/homebrew/opt/dart/libexec", "/opt/homebrew/opt/dart-sdk/libexec", "/usr/local/opt/dart/libexec", "/usr/lib/dart", "/usr/local/lib/dart",
      "C:/tools/dart-sdk", "C:/Program Files/Dart/dart-sdk",
    ]
    return candidates.map { $0 + "/lib" }.first { FileManager.default.fileExists(atPath: $0 + "/core/core.dart") }
  }

  // MARK: Packages

  private func readPackages(environment: [String: String], home: String, table: Table) {
    var pubspecs: [String] = []
    walk(root) { path in if path.hasSuffix("/pubspec.yaml") { pubspecs.append(path) } }
    let pubCache = environment["PUB_CACHE"] ?? (environment["LOCALAPPDATA"].map { $0 + "/Pub/Cache" }.flatMap { DartLayout.isDirectory($0) ? $0 : nil } ?? home + "/.pub-cache")
    var local: [String: String] = [:]
    for pubspec in pubspecs.sorted() {
      let directory = (pubspec as NSString).deletingLastPathComponent
      guard let name = Self.yamlName(pubspec) else { continue }
      packages.append(DartPackage(name: name, directory: directory))
      if local[name] == nil { local[name] = directory + "/lib" }
    }
    // The root's own package can be above it (a folder inside a package opened alone).
    if packages.isEmpty || !packages.contains(where: { $0.directory == root }) {
      var current = (root as NSString).deletingLastPathComponent
      var steps = 0
      while current.count > 1, steps < 4 {
        if let name = Self.yamlName(current + "/pubspec.yaml") {
          packages.insert(DartPackage(name: name, directory: current), at: 0)
          if local[name] == nil { local[name] = current + "/lib" }
          break
        }
        current = (current as NSString).deletingLastPathComponent
        steps += 1
      }
    }
    for index in packages.indices {
      var map: [String: String] = [:]
      for (name, lib) in Self.lockPackages(packages[index].directory, pubCache: pubCache, flutter: flutterRoot) where map[name] == nil { map[name] = lib }
      for (name, lib) in Self.configPackages(packages[index].directory, pubCache: pubCache) { map[name] = lib }
      for (name, lib) in local where map[name] == nil { map[name] = lib }
      map[packages[index].name] = packages[index].directory + "/lib"
      packages[index].packages = map
    }
    packages.sort { $0.directory.count < $1.directory.count }
    table.packages = packages
    table.all = local
    var libraries: [String: String] = [:]
    for package in packages {
      for (name, lib) in package.packages where libraries[lib] == nil { libraries[lib] = name }
    }
    packageLibraries = libraries.map { (name: $0.value, lib: $0.key) }.sorted { $0.lib.count > $1.lib.count }
  }

  /// A pubspec's `name:`.
  static func yamlName(_ path: String) -> String? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") where line.hasPrefix("name:") {
      let value = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'\r"))
      if let hash = value.firstIndex(of: "#") { return String(value[..<hash]).trimmingCharacters(in: .whitespaces) }
      return value.isEmpty ? nil : value
    }
    return nil
  }

  /// `.dart_tool/package_config.json` in a package's folder or a workspace's above it: names to `lib` folders that
  /// exist here (a path in another machine's pub cache is looked for in this one's).
  static func configPackages(_ directory: String, pubCache: String) -> [String: String] {
    var current = directory
    var config: String?
    for _ in 0..<4 {
      let candidate = current + "/.dart_tool/package_config.json"
      if FileManager.default.fileExists(atPath: candidate) {
        config = candidate
        break
      }
      let parent = (current as NSString).deletingLastPathComponent
      if parent == current { break }
      current = parent
    }
    guard let config, let data = FileManager.default.contents(atPath: config),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let list = json["packages"] as? [[String: Any]]
    else { return [:] }
    let base = (config as NSString).deletingLastPathComponent
    var result: [String: String] = [:]
    for entry in list {
      guard let name = entry["name"] as? String, let rootUri = entry["rootUri"] as? String else { continue }
      var packageRoot: String
      if rootUri.hasPrefix("file://") {
        packageRoot = URL(string: rootUri)?.path ?? String(rootUri.dropFirst(7))
      } else {
        packageRoot = standardize(base + "/" + (rootUri.removingPercentEncoding ?? rootUri))
      }
      let packageUri = (entry["packageUri"] as? String) ?? "lib/"
      var lib = standardize(packageRoot + "/" + packageUri)
      if !isDirectory(lib), let range = lib.range(of: "/.pub-cache/") {
        lib = pubCache + "/" + lib[range.upperBound...]
      }
      if isDirectory(lib) { result[name] = lib }
    }
    return result
  }

  /// `pubspec.lock`'s packages where they are on disk: hosted ones in the pub cache at their version, path ones next
  /// to the package, git ones in the cache's checkouts, the Flutter SDK's.
  static func lockPackages(_ directory: String, pubCache: String, flutter: String?) -> [String: String] {
    guard let text = try? String(contentsOfFile: directory + "/pubspec.lock", encoding: .utf8) else { return [:] }
    var result: [String: String] = [:]
    var current: String?
    var fields: [String: String] = [:]
    func finish() {
      guard let package = current else { return }
      defer { fields = [:] }
      let source = fields["source"] ?? ""
      var lib: String?
      switch source {
      case "hosted":
        var host = "pub.dev"
        if let url = fields["url"], let parsed = URL(string: url), let name = parsed.host, name != "pub.dartlang.org" { host = name }
        if let version = fields["version"] { lib = pubCache + "/hosted/" + host + "/" + package + "-" + version + "/lib" }
      case "path":
        if let path = fields["path"] { lib = standardize((path.hasPrefix("/") ? path : directory + "/" + path) + "/lib") }
      case "git":
        if let url = fields["url"], let ref = fields["resolved-ref"] {
          var repository = (url as NSString).lastPathComponent
          if repository.hasSuffix(".git") { repository.removeLast(4) }
          let sub = fields["path"].map { $0 == "." ? "" : "/" + $0 } ?? ""
          lib = pubCache + "/git/" + repository + "-" + ref + sub + "/lib"
        }
      case "sdk":
        if let flutter {
          lib = package == "sky_engine" ? flutter + "/bin/cache/pkg/sky_engine/lib" : flutter + "/packages/" + package + "/lib"
        }
      default:
        break
      }
      if let lib, isDirectory(lib) { result[package] = lib }
    }
    for raw in text.split(separator: "\n") {
      let line = raw.replacingOccurrences(of: "\r", with: "")
      let indent = line.prefix { $0 == " " }.count
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
      if indent == 0 {
        finish()
        current = nil
        continue
      }
      if indent == 2, trimmed.hasSuffix(":") {
        finish()
        current = String(trimmed.dropLast())
        continue
      }
      guard current != nil, let colon = trimmed.firstIndex(of: ":") else { continue }
      let key = String(trimmed[..<colon])
      let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
      // `description: name/url/path/ref`, one level deeper, or a plain value (`description: flutter`).
      if indent >= 4, !value.isEmpty, fields[key] == nil || indent > 4 { fields[key] = value }
    }
    finish()
    return result
  }

  // MARK: Files

  private func walk(_ directory: String, _ visit: (String) -> Void) {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
    for entry in entries.sorted() {
      let path = directory + "/" + entry
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
      if isDirectory.boolValue {
        if entry.hasPrefix(".") || Self.skipped.contains(entry) { continue }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeSymbolicLink { continue }
        walk(path, visit)
      } else {
        visit(path)
      }
    }
  }

  private func readFiles() {
    var sources: [String] = []
    walk(root) { path in if path.hasSuffix(".dart") { sources.append(path) } }
    sources.sort()
    // Parts: a library's `part 'x.dart'`, else a part's `part of 'lib.dart'` or `part of a.b;` (a library's name).
    let profile = (syntax as! DartSyntax).profile
    var partOf: [String: String] = [:]
    var partOfName: [String: String] = [:]
    var libraryNames: [String: String] = [:]
    var owned: [String: String] = [:]
    let resolver = (syntax as! DartSyntax).resolve
    for path in sources {
      guard let data = FileManager.default.contents(atPath: path) else { continue }
      let directives = Self.directives(SourceFile(bytes: data, profile: profile))
      if let name = directives.libraryName { libraryNames[name] = path }
      for uri in directives.parts {
        if let part = resolver(path, uri), owned[part] == nil { owned[part] = path }
      }
      if let owner = directives.partOfURI { partOf[path] = resolver(path, owner) }
      if let owner = directives.partOfName { partOfName[path] = owner }
    }
    for path in sources {
      if let owner = owned[path] {
        owners[path] = owner
      } else if let owner = partOf[path] ?? partOfName[path].flatMap({ libraryNames[$0] }) {
        owners[path] = owner
      } else {
        owners[path] = path
      }
    }
    files = sources
  }

  /// A file's `library`, `part` and `part of` directives, read from its first tokens.
  static func directives(_ source: SourceFile) -> (libraryName: String?, parts: [String], partOfURI: String?, partOfName: String?) {
    var parts: [String] = []
    var libraryName: String?
    var partOfURI: String?
    var partOfName: String?
    let tokens = source.tokens.filter { $0.kind != .comment && $0.kind != .docComment }
    func text(_ i: Int) -> String { source.string(tokens[i]) }
    func unquote(_ value: String) -> String { String(value.dropFirst().dropLast()) }
    var i = 0
    while i < tokens.count {
      let word = text(i)
      if word == "@" {
        i += 2
        continue
      }
      if word == "library" {
        var k = i + 1
        var words: [String] = []
        while k < tokens.count, text(k) != ";" {
          if tokens[k].kind == .identifier || tokens[k].kind == .keyword { words.append(text(k)) }
          k += 1
        }
        if !words.isEmpty { libraryName = words.joined(separator: ".") }
        i = k + 1
        continue
      }
      if word == "part" {
        if i + 1 < tokens.count, text(i + 1) == "of" {
          if i + 2 < tokens.count, tokens[i + 2].kind == .string {
            partOfURI = unquote(text(i + 2))
          } else {
            var k = i + 2
            var words: [String] = []
            while k < tokens.count, text(k) != ";" {
              if tokens[k].kind == .identifier || tokens[k].kind == .keyword { words.append(text(k)) }
              k += 1
            }
            partOfName = words.joined(separator: ".")
          }
        } else if i + 1 < tokens.count, tokens[i + 1].kind == .string {
          parts.append(unquote(text(i + 1)))
        }
      } else if word == "import" || word == "export" || word == ";" || tokens[i].kind == .string || word == "as" || word == "show" || word == "hide"
        || tokens[i].kind == .identifier || word == "," || word == "." || word == "if" || word == "deferred" || tokens[i].kind == .open
        || tokens[i].kind == .close || word == "=="
      {
        // Still in the directives.
      } else {
        break
      }
      i += 1
    }
    return (libraryName, parts, partOfURI, partOfName)
  }

  // MARK: ProjectLayout

  func sourceFiles(in directory: String) -> [String] { files }

  func moduleName(ofRelative path: String) -> String {
    let full = path.hasPrefix("/") ? path : root + "/" + path
    return owners[full] ?? full
  }

  /// A library outside the project (a package's, the SDK's or the stub's) with its parts.
  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    let dart = syntax as! DartSyntax
    if display.hasPrefix("dart:") {
      let library = String(display.dropFirst(5))
      var path: String?
      if library == "ui", let flutterRoot { path = flutterRoot + "/bin/cache/pkg/sky_engine/lib/ui/ui.dart" }
      if path == nil, let sdkLibrary {
        let candidate = sdkLibrary + "/" + library + "/" + library + ".dart"
        if FileManager.default.fileExists(atPath: candidate) { path = candidate }
      }
      if let path, let units = libraryUnits(path, project: project) { return project.register(display, units, isSDK: true) }
      guard let text = DartStd.files[library + ".dart"] else { return nil }
      let unit = Unit(path: Self.stdDirectory + "/" + library + ".dart", source: SourceFile(text, profile: dart.profile), syntax: dart)
      return project.register(display, [unit], isSDK: true)
    }
    // A project file that's another library's part: only through its library.
    if let owner = owners[display], owner != display { return nil }
    guard display.hasPrefix("/"), let units = libraryUnits(display, project: project) else { return nil }
    return project.register(display, units, isSDK: false)
  }

  /// A library file and its parts, parsed.
  private func libraryUnits(_ path: String, project: Project) -> [Unit]? {
    guard let library = project.parse([path], isInterface: false).first else { return nil }
    let dart = syntax as! DartSyntax
    let parts = Self.directives(library.source).parts.compactMap { dart.resolve(path, $0) }
    return [library] + project.parse(parts, isInterface: false)
  }

  /// Writes a stub file where its unit says it is, if it isn't there yet.
  func materialize(_ path: String) {
    guard path.hasPrefix(Self.stdDirectory + "/"), !FileManager.default.fileExists(atPath: path) else { return }
    let file = String(path.dropFirst(Self.stdDirectory.count + 1))
    guard let text = DartStd.files[file] else { return }
    try? FileManager.default.createDirectory(atPath: Self.stdDirectory, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
  }

  /// A file outside the root as a `package:` URI, when it's in a package's `lib`.
  func packageURI(_ path: String) -> String? {
    for entry in packageLibraries where path.hasPrefix(entry.lib + "/") {
      return "package:" + entry.name + "/" + path.dropFirst(entry.lib.count + 1)
    }
    return nil
  }
}
