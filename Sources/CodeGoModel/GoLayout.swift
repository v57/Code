import CodeModel
import CodeScan
import Foundation

/// The Go toolchain this Mac has: where the standard library and the module cache are, and the build context files
/// are chosen for (`go env`, read once).
struct GoEnvironment {
  var goroot = ""
  var modcache = ""
  var goos = "darwin"
  var goarch = "arm64"
  var cgo = true
  /// The newest `go1.N` the toolchain satisfies.
  var minor = 27
  /// The toolchain's own tags: its experiments on by default (`goexperiment.jsonv2`), `arm64.v8.0`.
  var toolTags: Set<String> = []

  static let shared = GoEnvironment.read()

  private static func read() -> GoEnvironment {
    var found = GoEnvironment()
    #if os(macOS)
      found.goos = "darwin"
    #elseif os(Linux)
      found.goos = "linux"
    #elseif os(Windows)
      found.goos = "windows"
    #endif
    #if arch(x86_64)
      found.goarch = "amd64"
    #endif
    #if os(macOS) || os(Linux) || os(Windows)
      let environment = ProcessInfo.processInfo.environment
      var candidates = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/go" }
      candidates += ["/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/local/bin/go", "/usr/bin/go"]
      guard let go = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return found }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: go)
      process.arguments = ["env", "-json", "GOROOT", "GOMODCACHE", "GOOS", "GOARCH", "CGO_ENABLED", "GOVERSION"]
      // Nothing may be fetched: GOTOOLCHAIN would download another toolchain.
      process.environment = environment.merging(["GOTOOLCHAIN": "local", "GOPROXY": "off"]) { $1 }
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      guard (try? process.run()) != nil else { return found }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return found }
      found.goroot = json["GOROOT"] ?? ""
      found.modcache = json["GOMODCACHE"] ?? ""
      found.goos = json["GOOS"] ?? found.goos
      found.goarch = json["GOARCH"] ?? found.goarch
      found.cgo = json["CGO_ENABLED"] != "0"
      if let version = json["GOVERSION"], version.hasPrefix("go1.") {
        found.minor = Int(version.dropFirst(4).prefix { $0.isNumber }) ?? found.minor
      }
      // `go list` answers this from the toolchain alone, run inside GOROOT so that no module is read.
      let list = Process()
      list.executableURL = URL(fileURLWithPath: go)
      list.arguments = ["list", "-f", "{{context.ToolTags}}", "runtime"]
      list.environment = process.environment
      if !found.goroot.isEmpty { list.currentDirectoryURL = URL(fileURLWithPath: found.goroot + "/src") }
      let listPipe = Pipe()
      list.standardOutput = listPipe
      list.standardError = FileHandle.nullDevice
      if (try? list.run()) != nil {
        let output = String(decoding: listPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        list.waitUntilExit()
        found.toolTags = Set(output.trimmingCharacters(in: CharacterSet(charactersIn: "[] \n")).split(separator: " ").map(String.init))
      }
    #endif
    return found
  }

  static let knownOS: Set<String> = [
    "aix", "android", "darwin", "dragonfly", "freebsd", "hurd", "illumos", "ios", "js", "linux", "nacl", "netbsd", "openbsd",
    "plan9", "solaris", "wasip1", "windows", "zos",
  ]
  static let knownArch: Set<String> = [
    "386", "amd64", "amd64p32", "arm", "armbe", "arm64", "arm64be", "loong64", "mips", "mipsle", "mips64", "mips64le",
    "mips64p32", "mips64p32le", "ppc", "ppc64", "ppc64le", "riscv", "riscv64", "s390", "s390x", "sparc", "sparc64", "wasm",
  ]
  static let unixOS: Set<String> = [
    "aix", "android", "darwin", "dragonfly", "freebsd", "hurd", "illumos", "ios", "linux", "netbsd", "openbsd", "solaris",
  ]

  /// Whether a build tag holds here.
  func satisfies(_ tag: String) -> Bool {
    if tag == goos || tag == goarch || tag == "gc" { return true }
    if tag == "cgo" { return cgo }
    if toolTags.contains(tag) { return true }
    if tag == "unix" { return GoEnvironment.unixOS.contains(goos) }
    if goos == "android", tag == "linux" { return true }
    if goos == "ios", tag == "darwin" { return true }
    if tag.hasPrefix("go1."), let n = Int(tag.dropFirst(4)) { return n <= minor }
    return false
  }

  /// Whether a file is built here: its name's `_GOOS`/`_GOARCH` suffixes and its `//go:build` line.
  func builds(fileName: String, head: Substring) -> Bool {
    var stem = fileName.hasSuffix(".go") ? String(fileName.dropLast(3)) : fileName
    if stem.hasSuffix("_test") { stem.removeLast(5) }
    let parts = stem.split(separator: "_").map(String.init)
    if parts.count >= 2 {
      let last = parts[parts.count - 1]
      if GoEnvironment.knownArch.contains(last) {
        if !satisfies(last) { return false }
        if parts.count >= 3, GoEnvironment.knownOS.contains(parts[parts.count - 2]), !satisfies(parts[parts.count - 2]) { return false }
      } else if GoEnvironment.knownOS.contains(last), !satisfies(last) {
        return false
      }
    }
    for line in head.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("package ") { break }
      if trimmed.hasPrefix("//go:build ") {
        var reader = ConstraintReader(text: Array(trimmed.dropFirst(11).utf8), environment: self)
        return reader.expression()
      }
    }
    return true
  }
}

/// `//go:build linux && (amd64 || arm64) && !cgo`.
private struct ConstraintReader {
  let text: [UInt8]
  let environment: GoEnvironment
  var at = 0

  mutating func skipSpace() { while at < text.count, text[at] == 0x20 || text[at] == 0x09 { at += 1 } }

  mutating func expression() -> Bool {
    var value = conjunction()
    skipSpace()
    while at + 1 < text.count, text[at] == 0x7C, text[at + 1] == 0x7C {
      at += 2
      let next = conjunction()
      value = value || next
      skipSpace()
    }
    return value
  }

  mutating func conjunction() -> Bool {
    var value = unary()
    skipSpace()
    while at + 1 < text.count, text[at] == 0x26, text[at + 1] == 0x26 {
      at += 2
      let next = unary()
      value = value && next
      skipSpace()
    }
    return value
  }

  mutating func unary() -> Bool {
    skipSpace()
    guard at < text.count else { return false }
    if text[at] == 0x21 {
      at += 1
      return !unary()
    }
    if text[at] == 0x28 {
      at += 1
      let value = expression()
      skipSpace()
      if at < text.count, text[at] == 0x29 { at += 1 }
      return value
    }
    let start = at
    while at < text.count, text[at] == 0x5F || text[at] == 0x2E || (text[at] | 0x20 >= 0x61 && text[at] | 0x20 <= 0x7A) || (text[at] >= 0x30 && text[at] <= 0x39) {
      at += 1
    }
    guard at > start else {
      at = text.count
      return false
    }
    return environment.satisfies(String(decoding: text[start..<at], as: UTF8.self))
  }
}

/// A `go.mod`: the module's path, what it requires and what it replaces.
struct GoModule {
  var directory: String
  var path: String
  var requires: [String: String] = [:]
  /// A module path's replacement: a directory (absolute), or another module path and version.
  var replaces: [String: (directory: String?, path: String, version: String)] = [:]

  init?(directory: String) {
    guard let text = try? String(contentsOfFile: directory + "/go.mod", encoding: .utf8) else { return nil }
    self.directory = directory
    path = ""
    var block = ""
    for raw in text.split(separator: "\n") {
      var line = raw.trimmingCharacters(in: .whitespaces)
      if let comment = line.range(of: "//") { line = line[..<comment.lowerBound].trimmingCharacters(in: .whitespaces) }
      if line.isEmpty { continue }
      if line == ")" {
        block = ""
        continue
      }
      var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
      if let first = words.first, ["module", "require", "replace", "exclude", "retract", "go", "toolchain", "tool", "godebug", "ignore"].contains(first) {
        if words.count >= 2, words[1] == "(" {
          block = first
          continue
        }
        block = ""
        words.removeFirst()
        handle(first, words)
      } else if !block.isEmpty {
        handle(block, words)
      }
    }
    guard !path.isEmpty else { return nil }
  }

  private mutating func handle(_ verb: String, _ words: [String]) {
    func unquote(_ word: String) -> String { word.trimmingCharacters(in: CharacterSet(charactersIn: "\"`")) }
    switch verb {
    case "module":
      path = words.first.map(unquote) ?? ""
    case "require":
      if words.count >= 2 { requires[unquote(words[0])] = words[1] }
    case "replace":
      guard let arrow = words.firstIndex(of: "=>"), arrow >= 1, arrow + 1 < words.count else { return }
      let target = unquote(words[arrow + 1])
      if target.hasPrefix(".") || target.hasPrefix("/") {
        let absolute = target.hasPrefix("/") ? target : directory + "/" + target
        replaces[unquote(words[0])] = (URL(fileURLWithPath: absolute).standardizedFileURL.path, "", "")
      } else if arrow + 2 < words.count {
        replaces[unquote(words[0])] = (nil, target, words[arrow + 2])
      }
    default:
      break
    }
  }
}

/// Go's projects: packages are directories, named by their module's path; the standard library is read from
/// `GOROOT/src` and other modules from the module cache (or a `replace` directory, or `vendor/`), each only when an
/// import names it. Files another platform builds are kept apart (`<path>#off`): they see the package, it doesn't see them.
final class GoLayout: ProjectLayout {
  var syntax: any LanguageSyntax { GoSyntax.shared }
  /// Universe scope lookups go to `builtin` by hand; nothing is seen without naming it.
  let implicitModules: [String] = []
  let interfaceExtension = ".go"
  let environment: GoEnvironment
  private(set) var modules: [GoModule] = []
  let root: String

  init(root: String, environment: GoEnvironment = .shared) {
    self.root = root
    self.environment = environment
    findModules()
  }

  /// Every `go.mod` under the root, and the nearest above it, deepest first.
  private func findModules() {
    var found: [GoModule] = []
    var directory = root
    while true {
      if let module = GoModule(directory: directory) {
        found.append(module)
        break
      }
      let parent = (directory as NSString).deletingLastPathComponent
      if parent == directory || parent.isEmpty { break }
      directory = parent
    }
    for path in walk(root, wantsModules: true) { if let module = GoModule(directory: path) { found.append(module) } }
    var seen = Set<String>()
    modules = found.filter { seen.insert($0.directory).inserted }.sorted { $0.directory.count > $1.directory.count }
  }

  /// The directories under one, skipping what Go skips (`.x`, `_x`, `testdata`, `vendor`), or with `wantsModules` those
  /// holding a `go.mod`.
  private func walk(_ start: String, wantsModules: Bool) -> [String] {
    var result: [String] = []
    let manager = FileManager.default
    var stack = FolderStack(start)
    while let directory = stack.pop() {
      guard let entries = try? manager.contentsOfDirectory(atPath: directory) else { continue }
      for entry in entries {
        if entry.hasPrefix(".") || entry.hasPrefix("_") || entry == "testdata" || entry == "vendor" || entry == "node_modules" { continue }
        let path = directory + "/" + entry
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
        if isDirectory.boolValue {
          if stack.push(path), wantsModules, manager.fileExists(atPath: path + "/go.mod") { result.append(path) }
        } else if !wantsModules, entry.hasSuffix(".go") {
          result.append(path)
        }
      }
    }
    return result
  }

  func sourceFiles(in directory: String) -> [String] { walk(directory, wantsModules: false).sorted() }

  /// A directory's import path: its module's path and where it is in it; under GOROOT/src, the path itself.
  func importPath(ofDirectory directory: String) -> String {
    if !environment.goroot.isEmpty, directory.hasPrefix(environment.goroot + "/src/") {
      var path = String(directory.dropFirst(environment.goroot.count + 5))
      if path.hasPrefix("vendor/") { path.removeFirst(7) }
      return path
    }
    for module in modules where directory == module.directory || directory.hasPrefix(module.directory + "/") {
      if module.path == "std" { return String(directory.dropFirst(module.directory.count + 1)) }
      return directory == module.directory ? module.path : module.path + directory.dropFirst(module.directory.count)
    }
    let relative = directory.hasPrefix(root + "/") ? String(directory.dropFirst(root.count + 1)) : directory
    return directory == root ? "." : relative
  }

  /// A file's package: its directory's import path, `_test` for an external test package, `#off` for a file this
  /// platform doesn't build.
  func moduleName(ofRelative path: String) -> String {
    let full = path.hasPrefix("/") ? path : root + "/" + path
    let directory = (full as NSString).deletingLastPathComponent
    var name = importPath(ofDirectory: directory)
    let head = GoLayout.head(of: full)
    if !environment.builds(fileName: (full as NSString).lastPathComponent, head: head[...]) { name += "#off" }
    if full.hasSuffix("_test.go"), let clause = GoLayout.packageClause(head), clause.hasSuffix("_test") { name += "_test" }
    return name
  }

  static func head(of path: String) -> String {
    guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? handle.close() }
    let data = handle.readData(ofLength: 4096)
    return String(decoding: data, as: UTF8.self)
  }

  static func packageClause(_ head: String) -> String? {
    var inBlock = false
    for line in head.split(separator: "\n") {
      var text = line.trimmingCharacters(in: .whitespaces)
      if inBlock {
        guard let end = text.range(of: "*/") else { continue }
        text = text[end.upperBound...].trimmingCharacters(in: .whitespaces)
        inBlock = false
      }
      if text.hasPrefix("/*"), !text.contains("*/") {
        inBlock = true
        continue
      }
      if text.hasPrefix("package ") { return text.dropFirst(8).prefix { $0.isLetter || $0.isNumber || $0 == "_" }.description }
    }
    return nil
  }

  /// The directory of an import path: the project's modules, a replacement, `vendor/`, GOROOT, the module cache.
  func directory(ofImport path: String) -> (directory: String, isSDK: Bool)? {
    let manager = FileManager.default
    func exists(_ directory: String) -> Bool {
      var isDirectory: ObjCBool = false
      return manager.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    func inside(_ modulePath: String) -> String? {
      if path == modulePath { return "" }
      return path.hasPrefix(modulePath + "/") ? String(path.dropFirst(modulePath.count)) : nil
    }
    for module in modules {
      if let sub = inside(module.path), exists(module.directory + sub) { return (module.directory + sub, false) }
    }
    // The longest module path that holds it, among what any go.mod here requires or replaces; the outermost go.mod's
    // version when several require it (the root's build list).
    var best: (module: String, sub: String, owner: GoModule)?
    for module in modules.reversed() {
      for required in Array(module.requires.keys) + Array(module.replaces.keys) {
        guard let sub = inside(required), required.count > (best?.module.count ?? -1) else { continue }
        best = (required, sub, module)
      }
    }
    if let best {
      if let replacement = best.owner.replaces[best.module] {
        if let directory = replacement.directory {
          return exists(directory + best.sub) ? (directory + best.sub, false) : nil
        }
        let cached = modcachePath(replacement.path, replacement.version) + best.sub
        if exists(cached) { return (cached, true) }
      }
      let vendored = best.owner.directory + "/vendor/" + path
      if exists(vendored) { return (vendored, true) }
      if let version = best.owner.requires[best.module] {
        let cached = modcachePath(best.module, version) + best.sub
        if exists(cached) { return (cached, true) }
      }
    }
    if !environment.goroot.isEmpty {
      let first = path.split(separator: "/").first.map(String.init) ?? path
      let std = environment.goroot + "/src/" + path
      if !first.contains("."), exists(std) { return (std, true) }
      let vendored = environment.goroot + "/src/vendor/" + path
      if exists(vendored) { return (vendored, true) }
    }
    return nil
  }

  /// `GOMODCACHE/github.com/!microsoft/go-winio@v0.6.4`: capitals escaped as `!` and the lowercase letter.
  private func modcachePath(_ module: String, _ version: String) -> String {
    var escaped = ""
    for character in module {
      if character.isUppercase {
        escaped += "!" + character.lowercased()
      } else {
        escaped.append(character)
      }
    }
    return environment.modcache + "/" + escaped + "@" + version
  }

  /// A package an import names: its files this platform builds, tests left out.
  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    guard let found = directory(ofImport: display) else { return nil }
    let manager = FileManager.default
    let entries = ((try? manager.contentsOfDirectory(atPath: found.directory)) ?? []).sorted()
    var paths: [String] = []
    for entry in entries where entry.hasSuffix(".go") && !entry.hasSuffix("_test.go") && !entry.hasPrefix(".") && !entry.hasPrefix("_") {
      let path = found.directory + "/" + entry
      if environment.builds(fileName: entry, head: GoLayout.head(of: path)[...]) { paths.append(path) }
    }
    guard !paths.isEmpty else { return nil }
    // `package documentation` files and the like aren't the package's.
    var units = project.parse(paths, isInterface: false)
    let names = units.compactMap { GoSyntax.packageName(of: $0) }
    if let common = Dictionary(grouping: names, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key {
      units = units.filter { GoSyntax.packageName(of: $0) == common }
    }
    return project.register(display, units, isSDK: found.isSDK)
  }
}
