import CodeModel
import CodeScan
import Foundation

/// Where a Composer project's classes and functions are: its PSR-4, PSR-0 and classmap autoloading and its `files`,
/// for one `composer.json` and its vendor folder.
struct PHPAutoload {
  var psr4: [(prefix: String, directories: [String])] = []
  var psr0: [(prefix: String, directories: [String])] = []
  /// Lowercased class names to files.
  var classmap: [String: String] = [:]
  /// Folders a classmap names, scanned for classes when a name isn't found otherwise.
  var classmapDirectories: [String] = []
  var files: [String] = []
}

/// PHP's projects: every `.php` and `.phtml` file under the root is read, each its own module named by its path
/// (`vendor`, `node_modules` and hidden folders left out). Names are found by their fully qualified name across them
/// (the model's table), and a class that isn't there through Composer's autoloading as `composer install` wrote it
/// (`vendor/composer/autoload_psr4.php`, `autoload_namespaces.php`, `autoload_classmap.php`, `autoload_files.php`), else
/// as `composer.json` and `vendor/composer/installed.json` declare it: the vendor files are read in place when a name
/// reaches them, never installed. PHP's own functions and classes come from `PHPStd`, a hand-written stub (module
/// `php`), written to `$TMPDIR/code-php-std/` when it's opened.
final class PHPLayout: ProjectLayout {
  let syntax: any LanguageSyntax = PHPSyntax()
  let implicitModules: [String] = []
  let interfaceExtension = ".php"
  let root: String
  private(set) var autoloads: [PHPAutoload] = []
  /// Classmap folders scanned: lowercased class names to files.
  private var scanned: [String: String]?
  static let skipped: Set<String> = ["vendor", "node_modules"]
  static let extensions: Set<String> = ["php", "phtml"]
  static let stdModule = "php"
  static let stdDirectory = NSTemporaryDirectory() + "code-php-std"

  init(root: String) {
    self.root = root
    readComposer()
  }

  // MARK: Files

  func sourceFiles(in directory: String) -> [String] {
    var result: [String] = []
    walk(directory) { path in
      if let dot = path.lastIndex(of: "."), Self.extensions.contains(path[path.index(after: dot)...].lowercased()) { result.append(path) }
    }
    return result.sorted()
  }

  private func walk(_ directory: String, depth: Int = 0, _ visit: (String) -> Void) {
    guard depth < 40, let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
    for entry in entries.sorted() {
      let path = directory + "/" + entry
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
      if isDirectory.boolValue {
        if entry.hasPrefix(".") || Self.skipped.contains(entry) { continue }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeSymbolicLink { continue }
        walk(path, depth: depth + 1, visit)
      } else {
        visit(path)
      }
    }
  }

  func moduleName(ofRelative path: String) -> String { path }

  /// A file outside the project (a vendor's, one an `include` names) by its path, or the stub.
  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    if display == Self.stdModule {
      let path = Self.stdDirectory + "/php.php"
      if (try? String(contentsOfFile: path, encoding: .utf8)) != PHPStd.source {
        try? FileManager.default.createDirectory(atPath: Self.stdDirectory, withIntermediateDirectories: true)
        try? PHPStd.source.write(toFile: path, atomically: true, encoding: .utf8)
      }
      let unit = Unit(path: path, source: SourceFile(PHPStd.source, profile: syntax.profile), syntax: syntax, isInterface: true)
      return project.register(display, [unit], isSDK: true)
    }
    guard display.hasPrefix("/"), FileManager.default.fileExists(atPath: display) else { return nil }
    let units = project.parse([display], isInterface: false)
    guard !units.isEmpty else { return nil }
    return project.register(display, units, isSDK: false)
  }

  // MARK: Composer

  /// Every `composer.json` under the root (or the nearest above it), each with its vendor folder.
  private func readComposer() {
    var manifests: [String] = []
    walk(root) { path in if path.hasSuffix("/composer.json") { manifests.append(path) } }
    if manifests.isEmpty {
      var current = (root as NSString).deletingLastPathComponent
      for _ in 0..<4 where current.count > 1 {
        if FileManager.default.fileExists(atPath: current + "/composer.json") {
          manifests.append(current + "/composer.json")
          break
        }
        current = (current as NSString).deletingLastPathComponent
      }
    }
    for manifest in manifests.sorted() { autoloads.append(Self.autoload(manifest)) }
  }

  static func json(_ path: String) -> Any? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }

  /// One project's autoloading: the generated files when Composer has run, else the manifests.
  static func autoload(_ manifest: String) -> PHPAutoload {
    let base = (manifest as NSString).deletingLastPathComponent
    let config = json(manifest) as? [String: Any] ?? [:]
    var vendor = base + "/vendor"
    if let dir = (config["config"] as? [String: Any])?["vendor-dir"] as? String { vendor = dir.hasPrefix("/") ? dir : base + "/" + dir }
    var result = PHPAutoload()
    let generated = vendor + "/composer"
    if FileManager.default.fileExists(atPath: generated + "/autoload_psr4.php") {
      for (key, paths) in entries(generated + "/autoload_psr4.php", vendor: vendor, base: base) { result.psr4.append((key, paths)) }
      for (key, paths) in entries(generated + "/autoload_namespaces.php", vendor: vendor, base: base) { result.psr0.append((key, paths)) }
      for (key, paths) in entries(generated + "/autoload_classmap.php", vendor: vendor, base: base) {
        if let path = paths.first { result.classmap[key.lowercased()] = path }
      }
      for (_, paths) in entries(generated + "/autoload_files.php", vendor: vendor, base: base) { result.files += paths }
    } else {
      add(config["autoload"], at: base, into: &result)
      add(config["autoload-dev"], at: base, into: &result)
      let installed = json(generated + "/installed.json")
      let packages = (installed as? [String: Any])?["packages"] as? [[String: Any]] ?? installed as? [[String: Any]] ?? []
      for package in packages {
        var directory = vendor + "/" + (package["name"] as? String ?? "")
        if let install = package["install-path"] as? String { directory = standardize(generated + "/" + install) }
        add(package["autoload"], at: directory, into: &result)
      }
    }
    result.psr4.sort { $0.prefix.count > $1.prefix.count }
    result.psr0.sort { $0.prefix.count > $1.prefix.count }
    return result
  }

  /// A manifest's `autoload` section, its paths relative to `directory`.
  private static func add(_ section: Any?, at directory: String, into result: inout PHPAutoload) {
    guard let section = section as? [String: Any] else { return }
    func paths(_ value: Any) -> [String] {
      let list = value as? [String] ?? (value as? String).map { [$0] } ?? []
      return list.map { standardize(directory + "/" + $0) }
    }
    for (prefix, value) in section["psr-4"] as? [String: Any] ?? [:] { result.psr4.append((prefix, paths(value))) }
    for (prefix, value) in section["psr-0"] as? [String: Any] ?? [:] { result.psr0.append((prefix, paths(value))) }
    if let list = section["classmap"] { result.classmapDirectories += paths(list) }
    if let list = section["files"] { result.files += paths(list) }
  }

  /// A generated autoload file's entries: `'Key\\' => array($vendorDir . '/a', $baseDir . '/b'),`.
  static func entries(_ path: String, vendor: String, base: String) -> [(String, [String])] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var result: [(String, [String])] = []
    for line in text.split(separator: "\n") {
      guard let arrow = line.range(of: "=>"), let open = line.firstIndex(of: "'") else { continue }
      guard open < arrow.lowerBound, let close = line[line.index(after: open)...].firstIndex(of: "'") else { continue }
      let key = line[line.index(after: open)..<close].replacingOccurrences(of: "\\\\", with: "\\")
      var paths: [String] = []
      var rest = line[arrow.upperBound...]
      while let variable = rest.range(of: "$") {
        let after = rest[variable.upperBound...]
        let root: String
        if after.hasPrefix("vendorDir") { root = vendor } else if after.hasPrefix("baseDir") { root = base } else {
          rest = after
          continue
        }
        guard let quote = after.firstIndex(of: "'"), let end = after[after.index(after: quote)...].firstIndex(of: "'") else { break }
        paths.append(standardize(root + after[after.index(after: quote)..<end]))
        rest = after[after.index(after: end)...]
      }
      if !paths.isEmpty { result.append((key, paths)) }
    }
    return result
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

  /// The file Composer would load for a class: the classmap, then PSR-4 (longest prefix first), then PSR-0.
  func classFile(_ fqn: String) -> String? {
    let lower = fqn.lowercased()
    for autoload in autoloads {
      if let path = autoload.classmap[lower] { return path }
    }
    for autoload in autoloads {
      for (prefix, directories) in autoload.psr4 where lower.hasPrefix(prefix.lowercased()) {
        let rest = fqn.dropFirst(prefix.count).replacingOccurrences(of: "\\", with: "/")
        for directory in directories {
          let path = directory + "/" + rest + ".php"
          if FileManager.default.fileExists(atPath: path) { return path }
        }
      }
      for (prefix, directories) in autoload.psr0 where lower.hasPrefix(prefix.lowercased()) {
        var relative = fqn
        if let slash = relative.lastIndex(of: "\\") {
          relative = relative[...slash].replacingOccurrences(of: "\\", with: "/") + relative[relative.index(after: slash)...].replacingOccurrences(of: "_", with: "/")
        } else {
          relative = relative.replacingOccurrences(of: "_", with: "/")
        }
        for directory in directories {
          let path = directory + "/" + relative + ".php"
          if FileManager.default.fileExists(atPath: path) { return path }
        }
      }
    }
    return scannedClassmap()[lower]
  }

  /// The `files` every request loads: functions and constants declared there are global.
  var autoloadFiles: [String] { autoloads.flatMap(\.files) }

  /// Classes in the classmap folders, read from their files' `namespace` and declaration lines once.
  private func scannedClassmap() -> [String: String] {
    if let scanned { return scanned }
    var map: [String: String] = [:]
    let profile = syntax.profile
    for directory in autoloads.flatMap(\.classmapDirectories) {
      var files: [String] = []
      if directory.hasSuffix(".php") { files = [directory] } else { walkAll(directory) { if $0.hasSuffix(".php") { files.append($0) } } }
      for file in files {
        guard let data = FileManager.default.contents(atPath: file) else { continue }
        let source = SourceFile(bytes: data, profile: profile)
        var namespace = ""
        let tokens = source.tokens
        for (i, token) in tokens.enumerated() where token.kind == .keyword || token.kind == .declarationKeyword {
          let word = source.string(token)
          if word == "namespace", i + 1 < tokens.count {
            var k = i + 1
            var text = ""
            while k < tokens.count, tokens[k].kind == .identifier || source.string(tokens[k]) == "\\" {
              text += source.string(tokens[k])
              k += 1
            }
            namespace = text
          } else if word == "class" || word == "interface" || word == "trait" || word == "enum", i + 1 < tokens.count, tokens[i + 1].kind == .identifier,
            i == 0 || source.string(tokens[i - 1]) != "::" && source.string(tokens[i - 1]) != "new"
          {
            let short = source.string(tokens[i + 1])
            map[(namespace.isEmpty ? short : namespace + "\\" + short).lowercased()] = file
          }
        }
      }
    }
    scanned = map
    return map
  }

  private func walkAll(_ directory: String, depth: Int = 0, _ visit: (String) -> Void) {
    guard depth < 40, let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
    for entry in entries.sorted() {
      let path = directory + "/" + entry
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
      if isDirectory.boolValue { walkAll(path, depth: depth + 1, visit) } else { visit(path) }
    }
  }
}
