import CodeModel
import CodeScan
import Foundation

/// A `tsconfig.json` (or `jsconfig.json`) as the model needs it, `extends` followed.
struct TSConfig {
  var directory: String
  var libs: [String]?
  var target = "es5"
  var types: [String]?
  var baseUrl: String?
  var paths: [(pattern: String, targets: [String])] = []
  /// `moduleDetection: force` (or a module file kind): every file is a module, none a global script.
  var forcesModules = false

  init(directory: String) { self.directory = directory }

  /// The config in a directory, if there is one.
  static func read(in directory: String) -> TSConfig? {
    for file in ["tsconfig.json", "jsconfig.json"] {
      let path = directory + "/" + file
      if FileManager.default.fileExists(atPath: path) { return read(path: path, depth: 0) }
    }
    return nil
  }

  private static func read(path: String, depth: Int) -> TSConfig? {
    guard depth < 8, let data = FileManager.default.contents(atPath: path), let json = parseJSONC(data) as? [String: Any] else { return nil }
    let directory = (path as NSString).deletingLastPathComponent
    var config = TSConfig(directory: directory)
    if let parent = json["extends"] as? String ?? (json["extends"] as? [String])?.first {
      var parentPath = parent.hasPrefix(".") || parent.hasPrefix("/") ? (parent.hasPrefix("/") ? parent : directory + "/" + parent) : directory + "/node_modules/" + parent
      if !parentPath.hasSuffix(".json") { parentPath += FileManager.default.fileExists(atPath: parentPath + "/tsconfig.json") ? "/tsconfig.json" : ".json" }
      if let base = read(path: URL(fileURLWithPath: parentPath).standardizedFileURL.path, depth: depth + 1) { config = base }
    }
    config.directory = directory
    guard let options = json["compilerOptions"] as? [String: Any] else { return config }
    if let libs = options["lib"] as? [String] { config.libs = libs.map { $0.lowercased() } }
    if let target = options["target"] as? String { config.target = target.lowercased() }
    if let types = options["types"] as? [String] { config.types = types }
    if let baseUrl = options["baseUrl"] as? String { config.baseUrl = URL(fileURLWithPath: directory + "/" + baseUrl).standardizedFileURL.path }
    if let paths = options["paths"] as? [String: [String]] {
      config.paths = paths.map { ($0.key, $0.value) }.sorted { $0.0.count > $1.0.count }
      if config.baseUrl == nil { config.baseUrl = directory }
    }
    if let detection = options["moduleDetection"] as? String { config.forcesModules = detection.lowercased() == "force" }
    return config
  }

  /// JSON with comments and trailing commas, as tsconfig files are written.
  static func parseJSONC(_ data: Data) -> Any? {
    let bytes = [UInt8](data)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    var inString = false
    while i < bytes.count {
      let byte = bytes[i]
      if inString {
        out.append(byte)
        if byte == 0x5C, i + 1 < bytes.count {
          out.append(bytes[i + 1])
          i += 2
          continue
        }
        if byte == 0x22 { inString = false }
        i += 1
        continue
      }
      if byte == 0x22 {
        inString = true
      } else if byte == 0x2F, i + 1 < bytes.count, bytes[i + 1] == 0x2F {
        while i < bytes.count, bytes[i] != 0x0A { i += 1 }
        continue
      } else if byte == 0x2F, i + 1 < bytes.count, bytes[i + 1] == 0x2A {
        i += 2
        while i + 1 < bytes.count, !(bytes[i] == 0x2A && bytes[i + 1] == 0x2F) { i += 1 }
        i += 2
        continue
      } else if byte == 0x2C {
        // A comma before a closing bracket goes.
        var k = i + 1
        while k < bytes.count, bytes[k] == 0x20 || bytes[k] == 0x0A || bytes[k] == 0x0D || bytes[k] == 0x09 { k += 1 }
        if k < bytes.count, bytes[k] == 0x7D || bytes[k] == 0x5D {
          i += 1
          continue
        }
      }
      out.append(byte)
      i += 1
    }
    return try? JSONSerialization.jsonObject(with: Data(out))
  }

  /// The lib files the config names (`lib`, or the target's default), as `lib.<name>.d.ts`.
  var libFiles: [String] {
    if let libs { return libs.map { "lib." + $0 + ".d.ts" } }
    switch target {
    case "es3", "es5": return ["lib.d.ts"]
    case "es6", "es2015": return ["lib.es6.d.ts"]
    case "esnext", "latest": return ["lib.esnext.full.d.ts"]
    default: return ["lib.\(target).full.d.ts"]
    }
  }
}

/// TypeScript's projects: every file is its own module (named by its absolute path), and imports are resolved as
/// TypeScript resolves them (`bundler`/`node` resolution): relative files with their extensions and index files,
/// `paths` and `baseUrl`, packages in `node_modules` (`exports`, `types`, `typings`, `main`, a `.d.ts` beside a `.js`,
/// `@types/*`), the project's own workspace packages by name, and ambient modules (`declare module "fs"`). The global
/// scope (module `<global>`) is TypeScript's `lib.*.d.ts` files, the type roots (`@types/*`) and what their
/// `/// <reference>`s reach, read when a global name is first asked for. Nothing is ever downloaded.
final class TSLayout: ProjectLayout {
  static let globalModule = "<global>"
  let root: String
  let config: TSConfig
  /// TypeScript's `lib` folder: the project's `node_modules/typescript`, else one found on this machine.
  let libDirectory: String?
  private(set) var syntax: any LanguageSyntax = TSSyntax(resolve: { _, _ in "" })
  let implicitModules: [String] = []
  let interfaceExtension = ".d.ts"
  /// The global set's files, found from the libs and type roots: scripts are global, modules their own.
  private(set) var globalFiles: [String] = []
  /// Ambient modules' names (`declare module "fs"`), and patterns with a `*`.
  private(set) var ambientNames: Set<String> = []
  private var ambientPatterns: [(prefix: String, suffix: String)] = []
  /// Package names of the project's own workspace (a monorepo without its links installed).
  private var workspacePackages: [String: String] = [:]
  private let lock = NSLock()
  private var resolved: [String: String] = [:]
  private var packageJSONs: [String: [String: Any]?] = [:]
  private var configs: [String: TSConfig?] = [:]
  private var existing: [String: Bool] = [:]

  init(root: String) {
    self.root = root
    config = TSConfig.read(in: root) ?? TSConfig(directory: root)
    libDirectory = TSLayout.findLibDirectory(from: root)
    syntax = TSSyntax(resolve: { [unowned self] specifier, from in self.resolve(specifier, from: from) })
    findGlobalFiles()
    findWorkspacePackages()
  }

  // MARK: Files

  private static let skipped: Set<String> = ["node_modules", "dist", "build", "out", "coverage", ".build", ".next", "target"]
  static let extensions = [".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"]

  static func isSource(_ name: String) -> Bool {
    extensions.contains { name.hasSuffix($0) } && !name.hasSuffix(".min.js")
  }

  func sourceFiles(in directory: String) -> [String] {
    var result: [String] = []
    let manager = FileManager.default
    var stack = [directory]
    while let current = stack.popLast() {
      guard let entries = try? manager.contentsOfDirectory(atPath: current) else { continue }
      for entry in entries {
        if entry.hasPrefix(".") || TSLayout.skipped.contains(entry) { continue }
        let path = current + "/" + entry
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
        if isDirectory.boolValue {
          stack.append(path)
        } else if TSLayout.isSource(entry) {
          result.append(path)
        }
      }
    }
    return result.sorted()
  }

  /// Each file is its own module.
  func moduleName(ofRelative path: String) -> String { path.hasPrefix("/") ? path : root + "/" + path }

  /// A module the project didn't load: a file an import reached (in `node_modules`, outside the root), or the global set.
  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    if display == TSLayout.globalModule {
      let units = project.parse(globalFiles, isInterface: false)
      var scripts: [Unit] = []
      var modules: [Unit] = []
      for unit in units {
        if let file = unit.scans[TSFile.key] as? TSFile, file.hasModuleSyntax { modules.append(unit) } else { scripts.append(unit) }
      }
      for unit in modules where project.unitByPath[unit.path] == nil { project.register(unit.path, [unit], isSDK: true) }
      return project.register(display, scripts, isSDK: true)
    }
    guard display.hasPrefix("/"), project.unitByPath[display] == nil, FileManager.default.fileExists(atPath: display) else { return nil }
    let units = project.parse([display], isInterface: false)
    guard !units.isEmpty else { return nil }
    return project.register(display, units, isSDK: !display.hasPrefix(root + "/") || display.contains("/node_modules/"))
  }

  // MARK: The global set

  static func findLibDirectory(from root: String) -> String? {
    var directory = root
    let manager = FileManager.default
    while true {
      let candidate = directory + "/node_modules/typescript/lib"
      if manager.fileExists(atPath: candidate + "/lib.es5.d.ts") { return candidate }
      let parent = (directory as NSString).deletingLastPathComponent
      if parent == directory || parent.isEmpty { break }
      directory = parent
    }
    var candidates: [String] = []
    if let asked = ProcessInfo.processInfo.environment["CODE_TYPESCRIPT_LIB"] { candidates.append(asked) }
    let home = NSHomeDirectory()
    candidates += [
      "/opt/homebrew/lib/node_modules/typescript/lib", "/usr/local/lib/node_modules/typescript/lib", "/usr/lib/node_modules/typescript/lib",
      home + "/.bun/install/global/node_modules/typescript/lib", home + "/.npm-global/lib/node_modules/typescript/lib",
      "/Applications/Visual Studio Code.app/Contents/Resources/app/extensions/node_modules/typescript/lib",
    ]
    return candidates.first { manager.fileExists(atPath: $0 + "/lib.es5.d.ts") }
  }

  /// The lib files, the type roots and everything their references reach, in order; the ambient modules among them.
  private func findGlobalFiles() {
    var order: [String] = []
    var seen: Set<String> = []
    var queue: [String] = []
    func add(_ path: String) {
      let standard = URL(fileURLWithPath: path).standardizedFileURL.path
      guard FileManager.default.fileExists(atPath: standard), seen.insert(standard).inserted else { return }
      queue.append(standard)
    }
    func addLib(_ fileName: String) {
      guard let libDirectory else { return }
      add(libDirectory + "/" + fileName.lowercased())
    }
    for lib in config.libFiles { addLib(lib) }
    for directory in typeRoots() { if let entry = packageTypesEntry(directory) { add(entry) } }
    while !queue.isEmpty {
      let path = queue.removeFirst()
      order.append(path)
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
      let directory = (path as NSString).deletingLastPathComponent
      var inBlock = false
      for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(400) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if inBlock {
          if trimmed.contains("*/") { inBlock = false }
          continue
        }
        if trimmed.isEmpty || trimmed.hasPrefix("//") && !trimmed.hasPrefix("///") { continue }
        guard trimmed.hasPrefix("///") else {
          if trimmed.hasPrefix("/*") {
            inBlock = !trimmed.contains("*/")
            continue
          }
          break
        }
        guard let value = TSLayout.attribute(of: trimmed) else { continue }
        switch value.kind {
        case "path": add(directory + "/" + value.value)
        case "types":
          if let package = packageDirectory(value.value, from: directory, types: true), let entry = packageTypesEntry(package) { add(entry) }
        case "lib": addLib("lib." + value.value + ".d.ts")
        default: break
        }
      }
      // `declare module "x"` at the top level of a file: an ambient module.
      var search = text[...]
      while let found = search.range(of: "declare module ") {
        let rest = search[found.upperBound...]
        if let quote = rest.first, quote == "\"" || quote == "'" {
          let moduleName = String(rest.dropFirst().prefix { $0 != quote })
          if let star = moduleName.firstIndex(of: "*") {
            ambientPatterns.append((String(moduleName[..<star]), String(moduleName[moduleName.index(after: star)...])))
          } else {
            ambientNames.insert(moduleName)
          }
        }
        search = rest
      }
    }
    globalFiles = order
  }

  private static func attribute(of line: String) -> (kind: String, value: String)? {
    for kind in ["path", "types", "lib"] {
      guard let at = line.range(of: kind + "=") else { continue }
      let rest = line[at.upperBound...]
      guard let quote = rest.first, quote == "\"" || quote == "'" else { continue }
      return (kind, String(rest.dropFirst().prefix { $0 != quote }))
    }
    return nil
  }

  /// `compilerOptions.types`' packages, else every `node_modules/@types/*` from the root up.
  private func typeRoots() -> [String] {
    if let types = config.types {
      return types.compactMap { packageDirectory($0, from: root, types: true) }
    }
    var result: [String] = []
    var directory = root
    while true {
      let folder = directory + "/node_modules/@types"
      if let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) {
        for entry in entries.sorted() where !entry.hasPrefix(".") { result.append(folder + "/" + entry) }
      }
      let parent = (directory as NSString).deletingLastPathComponent
      if parent == directory || parent.isEmpty { break }
      directory = parent
    }
    return result
  }

  // MARK: Resolving

  /// The key of what a module specifier names from a file: an absolute file path, `ambient:<name>`, or `?<specifier>`
  /// when nothing here has it. Safe from any thread.
  func resolve(_ specifier: String, from path: String) -> String {
    let directory = (path as NSString).deletingLastPathComponent
    let isRelative = specifier.hasPrefix("./") || specifier.hasPrefix("../") || specifier == "." || specifier == ".." || specifier.hasPrefix("/")
    let cacheKey = isRelative ? directory + "\u{0}" + specifier : specifier + "\u{0}" + nearestNodeModules(directory)
    lock.lock()
    if let known = resolved[cacheKey] {
      lock.unlock()
      return known
    }
    lock.unlock()
    let found = resolveUncached(specifier, directory: directory, isRelative: isRelative) ?? "?" + specifier
    lock.lock()
    resolved[cacheKey] = found
    lock.unlock()
    return found
  }

  /// The innermost directory with a `node_modules` above a directory (what a bare name's resolution depends on).
  private func nearestNodeModules(_ directory: String) -> String {
    var current = directory
    while true {
      if exists(current + "/node_modules") { return current }
      let parent = (current as NSString).deletingLastPathComponent
      if parent == current || parent.isEmpty { return "" }
      current = parent
    }
  }

  private func resolveUncached(_ specifier: String, directory: String, isRelative: Bool) -> String? {
    if isRelative {
      let base = specifier.hasPrefix("/") ? specifier : directory + "/" + specifier
      return file(URL(fileURLWithPath: base).standardizedFileURL.path)
    }
    if ambientNames.contains(specifier) { return "ambient:" + specifier }
    if let config = nearestConfig(directory) {
      for (pattern, targets) in config.paths {
        guard let captured = TSLayout.match(pattern, specifier) else { continue }
        for target in targets {
          let replaced = target.replacingOccurrences(of: "*", with: captured)
          let base = replaced.hasPrefix("/") ? replaced : (config.baseUrl ?? config.directory) + "/" + replaced
          if let found = file(URL(fileURLWithPath: base).standardizedFileURL.path) { return found }
        }
      }
      if let baseUrl = config.baseUrl, let found = file(baseUrl + "/" + specifier) { return found }
    }
    let parts = specifier.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    let packageName = specifier.hasPrefix("@") && parts.count >= 2 ? parts[0] + "/" + parts[1] : parts[0]
    let sub = parts.dropFirst(specifier.hasPrefix("@") ? 2 : 1).joined(separator: "/")
    if let package = packageDirectory(packageName, from: directory, types: false), let found = packageFile(package, sub: sub) { return found }
    if let package = workspacePackages[packageName], let found = packageFile(package, sub: sub) { return found }
    for (prefix, suffix) in ambientPatterns where specifier.hasPrefix(prefix) && specifier.hasSuffix(suffix) {
      return "ambient:" + prefix + "*" + suffix
    }
    return nil
  }

  static func match(_ pattern: String, _ specifier: String) -> String? {
    guard let star = pattern.firstIndex(of: "*") else { return pattern == specifier ? "" : nil }
    let prefix = pattern[..<star]
    let suffix = pattern[pattern.index(after: star)...]
    guard specifier.hasPrefix(prefix), specifier.hasSuffix(suffix), specifier.count >= prefix.count + suffix.count else { return nil }
    return String(specifier.dropFirst(prefix.count).dropLast(suffix.count))
  }

  private func nearestConfig(_ directory: String) -> TSConfig? {
    var current = directory
    while current.hasPrefix(root) {
      lock.lock()
      let known = configs[current]
      lock.unlock()
      if let known { return known ?? (current == root ? config : nil) }
      let found = current == root ? config : TSConfig.read(in: current)
      lock.lock()
      configs[current] = .some(found)
      lock.unlock()
      if let found { return found }
      let parent = (current as NSString).deletingLastPathComponent
      if parent == current { break }
      current = parent
    }
    return config
  }

  /// A package's folder from a directory up: `node_modules/<name>`, else `node_modules/@types/<name>` (`@a/b` as
  /// `@types/a__b`); with `types`, the `@types` one first.
  func packageDirectory(_ packageName: String, from directory: String, types: Bool) -> String? {
    let typesName = packageName.hasPrefix("@") ? String(packageName.dropFirst()).replacingOccurrences(of: "/", with: "__") : packageName
    var current = directory
    while true {
      let plain = current + "/node_modules/" + packageName
      let typed = current + "/node_modules/@types/" + typesName
      if types, exists(typed) { return typed }
      if exists(plain) {
        if !types, packageFile(plain, sub: "") == nil, exists(typed) { return typed }
        return plain
      }
      if exists(typed) { return typed }
      let parent = (current as NSString).deletingLastPathComponent
      if parent == current || parent.isEmpty { return nil }
      current = parent
    }
  }

  /// A package's types entry: `types`/`typings`, else `index.d.ts`.
  func packageTypesEntry(_ package: String) -> String? {
    let json = packageJSON(package)
    for key in ["types", "typings"] {
      if let entry = json?[key] as? String, let found = file(package + "/" + entry) { return found }
    }
    return file(package + "/index")
  }

  /// A path without `.` and `..` parts: `a/./b/../c` is `a/c`.
  static func normalized(_ path: String) -> String {
    var parts: [Substring] = []
    for part in path.split(separator: "/", omittingEmptySubsequences: false) {
      if part == "." { continue }
      if part == "..", let last = parts.last, last != "..", !last.isEmpty {
        parts.removeLast()
        continue
      }
      parts.append(part)
    }
    return parts.joined(separator: "/")
  }

  /// A file in a package: through `exports` when it has them, else `types`, `typings`, `main` (a `.d.ts` beside it),
  /// `index`.
  func packageFile(_ package: String, sub: String) -> String? {
    let json = packageJSON(package)
    if let exports = json?["exports"] {
      let key = sub.isEmpty ? "." : "./" + sub
      if let target = TSLayout.exportTarget(exports, key: key), let found = file(package + "/" + target) { return found }
    }
    if !sub.isEmpty { return file(package + "/" + sub) }
    for key in ["types", "typings", "main", "module"] {
      if let entry = json?[key] as? String, let found = file(package + "/" + entry) { return found }
    }
    return file(package + "/index")
  }

  /// `exports`' target for a subpath, with the conditions TypeScript's bundler resolution takes.
  static func exportTarget(_ exports: Any, key: String) -> String? {
    if let string = exports as? String { return key == "." ? string : nil }
    if let list = exports as? [Any] { return list.lazy.compactMap { exportTarget($0, key: key) }.first }
    guard let map = exports as? [String: Any] else { return nil }
    let isSubpaths = map.keys.contains { $0.hasPrefix(".") }
    if !isSubpaths { return condition(map) }
    if let value = map[key] { return condition(value) }
    for (pattern, value) in map where pattern.contains("*") {
      if let captured = match(pattern, key), let target = condition(value) { return target.replacingOccurrences(of: "*", with: captured) }
    }
    return nil
  }

  private static func condition(_ value: Any) -> String? {
    if let string = value as? String { return string }
    if let list = value as? [Any] { return list.lazy.compactMap { condition($0) }.first }
    guard let map = value as? [String: Any] else { return nil }
    for key in ["types", "typescript", "import", "bun", "module", "node", "require", "default"] {
      if let inner = map[key], let found = condition(inner) { return found }
    }
    return nil
  }

  private func packageJSON(_ package: String) -> [String: Any]? {
    lock.lock()
    if let known = packageJSONs[package] {
      lock.unlock()
      return known
    }
    lock.unlock()
    let json = FileManager.default.contents(atPath: package + "/package.json").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    lock.lock()
    packageJSONs[package] = .some(json)
    lock.unlock()
    return json
  }

  /// A path as an import names it: the file itself, with an extension TypeScript adds or for its `.js` the source,
  /// or a folder's `package.json` or `index`.
  func file(_ written: String) -> String? {
    let base = written.contains("/.") ? TSLayout.normalized(written) : written
    var stem = base
    for (written, sources) in [(".js", [".ts", ".tsx", ".d.ts"]), (".jsx", [".tsx", ".d.ts"]), (".mjs", [".mts", ".d.mts"]), (".cjs", [".cts", ".d.cts"])]
    where base.hasSuffix(written) {
      stem = String(base.dropLast(written.count))
      for source in sources where isFile(stem + source) { return stem + source }
    }
    if TSLayout.isSource(base) || base.hasSuffix(".d.ts"), isFile(base) { return base }
    for suffix in [".ts", ".tsx", ".d.ts", ".js", ".jsx", ".mts", ".cts", ".mjs", ".cjs"] where isFile(base + suffix) { return base + suffix }
    if exists(base) {
      if let json = packageJSON(base) {
        for key in ["types", "typings", "main"] {
          if let entry = json[key] as? String, entry != "", let found = file(base + "/" + entry), found != base { return found }
        }
      }
      for suffix in ["/index.ts", "/index.tsx", "/index.d.ts", "/index.js", "/index.jsx"] where isFile(base + suffix) { return base + suffix }
    }
    return nil
  }

  private func isFile(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
  }

  private func exists(_ path: String) -> Bool {
    lock.lock()
    if let known = existing[path] {
      lock.unlock()
      return known
    }
    lock.unlock()
    let found = FileManager.default.fileExists(atPath: path)
    lock.lock()
    existing[path] = found
    lock.unlock()
    return found
  }

  /// `package.json` names under the root (outside `node_modules`): a workspace's packages, by name.
  private func findWorkspacePackages() {
    let manager = FileManager.default
    var stack = [root]
    var depth: [String: Int] = [root: 0]
    while let current = stack.popLast() {
      let level = depth[current] ?? 0
      guard level < 4, let entries = try? manager.contentsOfDirectory(atPath: current) else { continue }
      if current != root, entries.contains("package.json"), let json = packageJSON(current), let packageName = json["name"] as? String {
        workspacePackages[packageName] = current
      }
      for entry in entries where !entry.hasPrefix(".") && !TSLayout.skipped.contains(entry) {
        let path = current + "/" + entry
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
          depth[path] = level + 1
          stack.append(path)
        }
      }
    }
  }
}
