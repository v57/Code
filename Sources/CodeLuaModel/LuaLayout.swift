import CodeModel
import CodeScan
import Foundation

/// Lua's projects: every `.lua` file under the root, each its own module named by its path (hidden folders,
/// `node_modules` and LuaRocks' `lua_modules` left out). Globals are the whole program's, so names are found across
/// every file read (the model's table). `require("a.b")` is found as `package.path` would find it from the project's
/// root: `.luarc.json`'s `runtime.path` patterns, then `?.lua`, `?/init.lua` and the same under `lua/` and `src/`, a
/// rockspec's `build.modules`, `workspace.library` folders and `lua_modules`; then from the requiring file's folder up to
/// the root, as Factorio (a mod's root) and scripts run from their own folder see it; `__mod__/x` names a Factorio mod's
/// folder. Files outside the project are read when a require reaches them. Lua's standard library comes from `LuaStd`,
/// a hand-written stub (module `lua`), written to `$TMPDIR/code-lua-std/` when opened.
final class LuaLayout: ProjectLayout {
  let syntax: any LanguageSyntax = LuaSyntax()
  let implicitModules: [String] = []
  let interfaceExtension = ".lua"
  let root: String
  /// `?`-patterns relative to the root, in the order they're tried.
  private(set) var patterns: [String] = []
  /// Folders searched with `?.lua` and `?/init.lua` after the project (`workspace.library`, `lua_modules`).
  private(set) var libraries: [String] = []
  /// A rockspec's `build.modules`: module name to file.
  private(set) var rockModules: [String: String] = [:]
  /// `.luarc.json`'s `diagnostics.globals` and `.luacheckrc`'s globals: names the host defines.
  private(set) var hostGlobals: Set<String> = []
  private var resolved: [String: String?] = [:]
  static let skipped: Set<String> = ["node_modules", "lua_modules", ".luarocks"]
  static let stdModule = "lua"
  static let stdDirectory = NSTemporaryDirectory() + "code-lua-std"

  init(root: String) {
    self.root = root
    readConfiguration()
    for pattern in ["?.lua", "?/init.lua", "lua/?.lua", "lua/?/init.lua", "src/?.lua", "src/?/init.lua"] where !patterns.contains(pattern) {
      patterns.append(pattern)
    }
    readRockspecs()
    for tree in [root + "/lua_modules/share/lua", root + "/.luarocks/share/lua"] {
      for version in ((try? FileManager.default.contentsOfDirectory(atPath: tree)) ?? []).sorted(by: >) { libraries.append(tree + "/" + version) }
    }
  }

  static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  static func isFile(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
  }

  // MARK: Files

  func sourceFiles(in directory: String) -> [String] {
    var result: [String] = []
    walk(directory) { if $0.hasSuffix(".lua") { result.append($0) } }
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

  /// A file outside the project by its absolute path, or the stub.
  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    if display == Self.stdModule {
      let path = Self.stdDirectory + "/std.lua"
      if (try? String(contentsOfFile: path, encoding: .utf8)) != LuaStd.source {
        try? FileManager.default.createDirectory(atPath: Self.stdDirectory, withIntermediateDirectories: true)
        try? LuaStd.source.write(toFile: path, atomically: true, encoding: .utf8)
      }
      let unit = Unit(path: path, source: SourceFile(LuaStd.source, profile: syntax.profile), syntax: syntax, isInterface: true)
      return project.register(display, [unit], isSDK: true)
    }
    guard display.hasPrefix("/"), Self.isFile(display) else { return nil }
    let units = project.parse([display], isInterface: false)
    guard !units.isEmpty else { return nil }
    return project.register(display, units, isSDK: false)
  }

  // MARK: Configuration

  /// `.luarc.json` (or `.luarc.jsonc`): `runtime.path`, `workspace.library` and `diagnostics.globals`, flat
  /// (`"runtime.path"`) or nested (`"runtime": {"path"}`). `.luacheckrc`'s `globals` and `read_globals`.
  private func readConfiguration() {
    for file in [".luarc.json", ".luarc.jsonc"] {
      guard let text = try? String(contentsOfFile: root + "/" + file, encoding: .utf8),
        let data = Self.stripComments(text).data(using: .utf8),
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else { continue }
      func value(_ path: String) -> Any? {
        if let flat = json[path] { return flat }
        let parts = path.split(separator: ".").map(String.init)
        var current: Any? = json
        for part in parts { current = (current as? [String: Any])?[part] }
        return current
      }
      for pattern in value("runtime.path") as? [String] ?? [] {
        let cleaned = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
        if !cleaned.isEmpty, !patterns.contains(cleaned) { patterns.append(cleaned) }
      }
      for library in value("workspace.library") as? [String] ?? [] {
        var path = library.replacingOccurrences(of: "${3rd}", with: "")
        if path.hasPrefix("~") { path = NSHomeDirectory() + path.dropFirst() }
        if !path.hasPrefix("/") { path = root + "/" + path }
        if Self.isDirectory(path) { libraries.append(Self.standardize(path)) }
      }
      for global in value("diagnostics.globals") as? [String] ?? [] { hostGlobals.insert(global) }
      break
    }
    if let text = try? String(contentsOfFile: root + "/.luacheckrc", encoding: .utf8) {
      // `globals = { "a", "b" }`, `read_globals = {…}`: the quoted words in those tables.
      for key in ["globals", "read_globals", "new_globals", "new_read_globals"] {
        guard let range = text.range(of: key + " = {") ?? text.range(of: key + "={") else { continue }
        var depth = 1
        var index = range.upperBound
        var word = ""
        var quote: Character?
        while index < text.endIndex, depth > 0 {
          let c = text[index]
          if let open = quote {
            if c == open {
              hostGlobals.insert(word)
              word = ""
              quote = nil
            } else {
              word.append(c)
            }
          } else if c == "\"" || c == "'" {
            quote = c
          } else if c == "{" {
            depth += 1
          } else if c == "}" {
            depth -= 1
          }
          index = text.index(after: index)
        }
      }
    }
  }

  /// JSON with `//` and `/* */` comments (`.luarc.jsonc`) as plain JSON; strings are kept as they are.
  static func stripComments(_ text: String) -> String {
    var out = ""
    var inString = false
    var chars = Array(text)
    var i = 0
    chars.append("\n")
    while i < chars.count - 1 {
      let c = chars[i]
      if inString {
        out.append(c)
        if c == "\\" {
          out.append(chars[i + 1])
          i += 2
          continue
        }
        if c == "\"" { inString = false }
      } else if c == "\"" {
        inString = true
        out.append(c)
      } else if c == "/", chars[i + 1] == "/" {
        while i < chars.count, chars[i] != "\n" { i += 1 }
        continue
      } else if c == "/", chars[i + 1] == "*" {
        i += 2
        while i < chars.count - 1, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
        i += 2
        continue
      } else {
        out.append(c)
      }
      i += 1
    }
    return out
  }

  /// A rockspec's `build = { modules = { ["a.b"] = "src/a/b.lua" } }` pairs.
  private func readRockspecs() {
    for entry in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] where entry.hasSuffix(".rockspec") {
      guard let text = try? String(contentsOfFile: root + "/" + entry, encoding: .utf8) else { continue }
      var rest = Substring(text)
      while let open = rest.range(of: "[\"") {
        rest = rest[open.upperBound...]
        guard let close = rest.range(of: "\"]") else { break }
        let module = String(rest[..<close.lowerBound])
        rest = rest[close.upperBound...]
        let after = rest.drop { $0 == " " || $0 == "\t" }
        guard after.first == "=" else { continue }
        let value = after.dropFirst().drop { $0 == " " || $0 == "\t" }
        guard let quote = value.first, quote == "\"" || quote == "'" else { continue }
        let body = value.dropFirst()
        guard let end = body.firstIndex(of: quote) else { continue }
        let file = String(body[..<end])
        if file.hasSuffix(".lua"), rockModules[module] == nil { rockModules[module] = Self.standardize(root + "/" + file) }
      }
    }
  }

  // MARK: Require

  /// The file `require(name)` loads from a file at `from`, or nil when none is on disk.
  func resolve(require name: String, from: String) -> String? {
    let folder = (from as NSString).deletingLastPathComponent
    let key = folder + "\u{1}" + name
    if let known = resolved[key] { return known }
    let found = find(name, folder: folder)
    resolved[key] = found
    return found
  }

  private func find(_ requested: String, folder: String) -> String? {
    var name = requested
    if name.hasSuffix(".lua") { name.removeLast(4) }
    if let file = rockModules[name], Self.isFile(file) { return file }
    // Factorio's `__mod__/path` and `__mod__.path`: a mod's folder under the root (or the root itself).
    if name.hasPrefix("__"), let end = name.dropFirst(2).range(of: "__") {
      let mod = String(name[name.index(name.startIndex, offsetBy: 2)..<end.lowerBound])
      let rest = String(name[end.upperBound...]).drop { $0 == "/" || $0 == "." }
      let path = rest.contains("/") ? String(rest) : rest.replacingOccurrences(of: ".", with: "/")
      for base in [root + "/" + mod, root] where Self.isDirectory(base) {
        if base == root, (root as NSString).lastPathComponent != mod { continue }
        for candidate in [base + "/" + path + ".lua", base + "/" + path + "/init.lua"] where Self.isFile(candidate) { return candidate }
      }
      return nil
    }
    let path = name.contains("/") ? name : name.replacingOccurrences(of: ".", with: "/")
    guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
    for pattern in patterns {
      let candidate = Self.standardize(root + "/" + pattern.replacingOccurrences(of: "?", with: path))
      if Self.isFile(candidate) { return candidate }
    }
    for library in libraries {
      for pattern in ["?.lua", "?/init.lua", "lua/?.lua", "lua/?/init.lua"] {
        let candidate = library + "/" + pattern.replacingOccurrences(of: "?", with: path)
        if Self.isFile(candidate) { return candidate }
      }
    }
    // From the requiring file's folder up to the root: a Factorio mod's or scenario's root, a script's own folder.
    var directory = folder
    while directory.hasPrefix(root) {
      for candidate in [directory + "/" + path + ".lua", directory + "/" + path + "/init.lua"] where Self.isFile(candidate) { return candidate }
      if directory == root { break }
      directory = (directory as NSString).deletingLastPathComponent
    }
    return nil
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
}
