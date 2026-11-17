import CodeModel
import CodeScan
import Foundation

/// What a project's compile commands say for every file: its include folders, macros and language standard. One set
/// for the whole project (the union of its files'), as a header is read once for all of them.
struct CompileFlags {
  var includes: [String] = []
  var quoteIncludes: [String] = []
  var systemIncludes: [String] = []
  var frameworkDirs: [String] = []
  var defines: [(String, String)] = []
  var undefines: [String] = []
  var cStandard: String?
  var cppStandard: String?
  var found = false

  /// `compile_commands.json` at the root or in a build folder, else nothing.
  static func read(root: String) -> CompileFlags {
    var flags = CompileFlags()
    let candidates = ["compile_commands.json", "build/compile_commands.json", ".build/compile_commands.json", "out/compile_commands.json", "cmake-build-debug/compile_commands.json"]
    guard let file = candidates.lazy.map({ root + "/" + $0 }).first(where: { FileManager.default.fileExists(atPath: $0) }),
      let data = FileManager.default.contents(atPath: file),
      let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    else { return flags }
    flags.found = true
    var seen = Set<String>()
    var seenDefines = Set<String>()
    for entry in entries {
      let directory = entry["directory"] as? String ?? root
      var arguments = entry["arguments"] as? [String] ?? []
      if arguments.isEmpty, let command = entry["command"] as? String { arguments = CompileFlags.words(command) }
      let path = entry["file"] as? String ?? ""
      let isCpp = CDialect.of(path: path)?.contains(.cpp) == true
      func absolute(_ value: String) -> String {
        let joined = value.hasPrefix("/") ? value : directory + "/" + value
        return URL(fileURLWithPath: joined).standardizedFileURL.path
      }
      var i = 0
      func value(_ flag: String) -> String? {
        let argument = arguments[i]
        if argument == flag, i + 1 < arguments.count {
          i += 1
          return arguments[i]
        }
        if argument.hasPrefix(flag), argument.count > flag.count { return String(argument.dropFirst(flag.count)) }
        return nil
      }
      while i < arguments.count {
        defer { i += 1 }
        if let include = value("-I") {
          if seen.insert("I" + absolute(include)).inserted { flags.includes.append(absolute(include)) }
        } else if let include = value("-iquote") {
          if seen.insert("Q" + absolute(include)).inserted { flags.quoteIncludes.append(absolute(include)) }
        } else if let include = value("-isystem") {
          if seen.insert("S" + absolute(include)).inserted { flags.systemIncludes.append(absolute(include)) }
        } else if let framework = value("-F") {
          if seen.insert("F" + absolute(framework)).inserted { flags.frameworkDirs.append(absolute(framework)) }
        } else if let define = value("-D") {
          guard seenDefines.insert(define).inserted else { continue }
          if let equals = define.firstIndex(of: "=") {
            flags.defines.append((String(define[..<equals]), String(define[define.index(after: equals)...])))
          } else {
            flags.defines.append((define, "1"))
          }
        } else if let undefine = value("-U") {
          flags.undefines.append(undefine)
        } else if arguments[i].hasPrefix("-std=") {
          let standard = String(arguments[i].dropFirst(5))
          if isCpp { flags.cppStandard = standard } else { flags.cStandard = standard }
        }
      }
    }
    return flags
  }

  /// A shell command's words, quotes removed.
  static func words(_ command: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false
    var any = false
    for c in command {
      if escaped {
        current.append(c)
        escaped = false
        continue
      }
      if c == "\\", quote != "'" {
        escaped = true
        continue
      }
      if let open = quote {
        if c == open { quote = nil } else { current.append(c) }
        continue
      }
      if c == "\"" || c == "'" {
        quote = c
        any = true
        continue
      }
      if c == " " || c == "\t" || c == "\n" {
        if !current.isEmpty || any { result.append(current) }
        current = ""
        any = false
        continue
      }
      current.append(c)
    }
    if !current.isEmpty || any { result.append(current) }
    return result
  }
}

/// A C-family project's files and where its includes are found: the compile commands' folders, then the system's
/// (libc++ for C++, clang's own headers, the SDK's `usr/include`, its frameworks), as clang searches them. Every file
/// is its own module, named by its path, and an `#include` imports the module of the header it finds.
final class CLayout: ProjectLayout {
  let root: String
  let csyntax: CSyntax
  var syntax: any LanguageSyntax { csyntax }
  let implicitModules: [String] = []
  let interfaceExtension = ""
  let sdk: String
  /// clang's own headers (`stddef.h`, `stdarg.h`): `…/lib/clang/<version>/include`.
  let resourceInclude: String
  /// Folders outside the project and the SDK, by their real paths.
  private var realFolders: [String: String] = [:]
  let libcxxInclude: String
  let flags: CompileFlags
  private(set) var files: [String] = []
  /// Project files by name, for an include no folder finds.
  private var byName: [String: [String]] = [:]
  /// Folders named `include` in the project, searched when there are no compile commands.
  private var guessedIncludes: [String] = []
  private let lock = NSLock()
  private var resolved: [String: String?] = [:]
  private var tables: [CDialect: CMacroTable] = [:]
  private var projectDefines: [(name: Name, macro: CMacro, path: String)] = []
  private var moduleMapValue: ClangModuleMap?

  init(root: String) {
    self.root = root
    csyntax = CSyntax()
    sdk = CLayout.sharedSDK
    resourceInclude = CLayout.sharedResourceInclude
    libcxxInclude = sdk.isEmpty ? "" : sdk + "/usr/include/c++/v1"
    flags = CompileFlags.read(root: root)
    files = walk(root)
    for file in files { byName[(file as NSString).lastPathComponent, default: []].append(file) }
    if !flags.found {
      guessedIncludes = Set(files.compactMap { file -> String? in
        let directory = (file as NSString).deletingLastPathComponent
        let parts = directory.dropFirst(root.count).split(separator: "/")
        guard let index = parts.firstIndex(of: "include") else { return nil }
        return root + "/" + parts[...index].joined(separator: "/")
      }).sorted()
    }
    csyntax.headerDialect = projectDialect()
    scanProjectDefines()
    csyntax.resolve = { [unowned self] spelling, angled, includer, includeNext in
      self.resolve(spelling, angled: angled, includer: includer, includeNext: includeNext)
    }
    csyntax.macros = { [unowned self] dialect in self.table(dialect) }
    csyntax.included = { [unowned self] path, dialect in self.exports(of: path, dialect: dialect) }
  }

  static let sharedSDK: String = {
    let path = ClangModuleMap.sdkPath()
    return path.isEmpty ? "" : URL(fileURLWithPath: path).resolvingSymlinksInPath().path
  }()

  static let sharedResourceInclude: String = {
    #if os(macOS)
      let clang = ClangModuleMap.run("/usr/bin/xcrun", ["--find", "clang"]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !clang.isEmpty else { return "" }
      let base = URL(fileURLWithPath: clang).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/clang").resolvingSymlinksInPath().path
      let versions = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).sorted()
      for version in versions.reversed() where FileManager.default.fileExists(atPath: base + "/" + version + "/include/stddef.h") {
        return URL(fileURLWithPath: base + "/" + version + "/include").resolvingSymlinksInPath().path
      }
    #endif
    return ""
  }()

  static let sourceExtensions: Set<String> = ["c", "h", "cc", "cpp", "cxx", "c++", "hpp", "hh", "hxx", "m", "mm"]
  static let skipped: Set<String> = ["node_modules", "build", ".build", "DerivedData", "Pods", "target", "out", "cmake-build-debug", "cmake-build-release"]

  private func walk(_ start: String) -> [String] {
    var result: [String] = []
    let manager = FileManager.default
    var stack = [start]
    while let directory = stack.popLast() {
      guard let entries = try? manager.contentsOfDirectory(atPath: directory) else { continue }
      for entry in entries where !entry.hasPrefix(".") {
        let path = directory + "/" + entry
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
        if isDirectory.boolValue {
          if !CLayout.skipped.contains(entry), !entry.hasSuffix(".xcodeproj"), !entry.hasSuffix(".xcassets"), !entry.hasSuffix(".app") { stack.append(path) }
          continue
        }
        guard let dot = entry.lastIndex(of: "."), CLayout.sourceExtensions.contains(entry[entry.index(after: dot)...].lowercased()) else { continue }
        result.append(path)
      }
    }
    return result.sorted()
  }

  func sourceFiles(in directory: String) -> [String] { directory == root ? files : walk(directory) }

  func moduleName(ofRelative path: String) -> String { root + "/" + path }

  /// A header's dialect where its extension doesn't say: Objective-C++ when the project has `.mm` files, Objective-C
  /// with `.m`, C++ when most of its sources are, else C.
  private func projectDialect() -> CDialect {
    var counts: [CDialect: Int] = [:]
    for file in files { if let dialect = CDialect.of(path: file) { counts[dialect, default: 0] += 1 } }
    var dialect: CDialect = .c
    if (counts[.cpp] ?? 0) > (counts[.c] ?? 0) { dialect.insert(.cpp) }
    if (counts[.objc] ?? 0) + (counts[[.cpp, .objc]] ?? 0) > 0 { dialect.insert(.objc) }
    if (counts[[.cpp, .objc]] ?? 0) > 0 { dialect.insert(.cpp) }
    return dialect
  }

  // MARK: Macros

  /// What the project's headers `#define`, read from their lines (without their `#if`s), for other files' `#if`.
  private func scanProjectDefines() {
    for file in files where CDialect.of(path: file) == nil || file.hasSuffix(".hpp") || file.hasSuffix(".hh") {
      guard let data = FileManager.default.contents(atPath: file) else { continue }
      let text = String(decoding: data, as: UTF8.self)
      var guardName: Substring?
      var lineIndex = 0
      for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        lineIndex += 1
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("#") else { continue }
        let directive = trimmed.dropFirst().drop { $0 == " " || $0 == "\t" }
        if guardName == nil, directive.hasPrefix("ifndef") {
          guardName = directive.dropFirst(6).drop { $0 == " " || $0 == "\t" }.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        guard directive.hasPrefix("define"), let (key, macro) = CMacroTable.parseDefine(directive.dropFirst(6)) else { continue }
        projectDefines.append((key, macro, file))
      }
    }
  }

  func table(_ dialect: CDialect) -> CMacroTable {
    lock.lock()
    defer { lock.unlock() }
    if let known = tables[dialect] { return known }
    let made = CMacroTable()
    made.macros = CMacroTable.predefined(dialect, sdk: sdk, std: dialect.contains(.cpp) ? flags.cppStandard : flags.cStandard)
    for (key, macro, path) in projectDefines where made.macros[key] == nil || made.definedIn[key] != nil {
      if made.definedIn[key] != nil { continue }
      made.macros[key] = macro
      made.definedIn[key] = path
    }
    for (key, value) in flags.defines {
      made.macros[name(key)] = CMacro(value: value, isFunction: false)
      made.definedIn[name(key)] = nil
    }
    for key in flags.undefines { made.macros[name(key)] = nil }
    tables[dialect] = made
    return made
  }

  // MARK: What headers define

  private let exportLock = NSRecursiveLock()
  private var exportCache: [String: [Name: CMacro?]] = [:]
  private var exporting: Set<String> = []

  /// The macros a header leaves defined (or undefined, nil) for a file that includes it, its own includes' too: its
  /// directive lines read with its `#if`s taken as the project's table says. Read once per dialect.
  func exports(of path: String, dialect: CDialect) -> [Name: CMacro?] {
    let key = dialect.clangName + "|" + path
    exportLock.lock()
    defer { exportLock.unlock() }
    if let known = exportCache[key] { return known }
    // An include cycle: what's read so far.
    guard exporting.insert(key).inserted, let data = FileManager.default.contents(atPath: path) else { return [:] }
    defer { exporting.remove(key) }
    let table = self.table(dialect)
    var env: [Name: CMacro?] = [:]
    var stack: [(active: Bool, taken: Bool)] = []
    var sawGuard = false
    func lookup(_ name: Name) -> CMacro? {
      if let local = env[name] { return local }
      guard let macro = table.macros[name], table.definedIn[name] != path else { return nil }
      return macro
    }
    func evaluate(_ text: Substring) -> Bool {
      CCondition(lookup: lookup, hasInclude: { [unowned self] spelling, angled in self.resolve(spelling, angled: angled, includer: path, includeNext: false) != nil }, dialect: dialect)
        .evaluate(String(text))
    }
    for line in CLayout.directiveLines(data) {
      let word = line.prefix { $0.isLetter || $0 == "_" }
      let rest = line.dropFirst(word.count).drop { $0 == " " || $0 == "\t" }
      let taking = stack.allSatisfy(\.active)
      switch word {
      case "if", "ifdef", "ifndef":
        guard taking else {
          stack.append((false, true))
          continue
        }
        var value: Bool
        if word == "if" {
          value = evaluate(rest)
        } else {
          let macro = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
          value = lookup(CodeModel.name(String(macro))) != nil || CCondition.checkNames.contains(CodeModel.name(String(macro)))
          if word == "ifndef" {
            value = !value
            // The include guard.
            if !sawGuard, stack.isEmpty { value = true }
          }
        }
        sawGuard = true
        stack.append((value, value))
      case "elif", "elifdef", "elifndef":
        guard let top = stack.popLast() else { continue }
        if top.taken || !stack.allSatisfy(\.active) {
          stack.append((false, true))
        } else {
          var value: Bool
          if word == "elif" {
            value = evaluate(rest)
          } else {
            let macro = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            value = (lookup(CodeModel.name(String(macro))) != nil || CCondition.checkNames.contains(CodeModel.name(String(macro)))) == (word == "elifdef")
          }
          stack.append((value, value))
        }
      case "else":
        guard let top = stack.popLast() else { continue }
        stack.append((!top.taken, true))
      case "endif":
        _ = stack.popLast()
      case "define":
        sawGuard = true
        if taking, let (macro, value) = CMacroTable.parseDefine(rest) { env[macro] = .some(value) }
      case "undef":
        sawGuard = true
        let macro = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        if taking { env[CodeModel.name(String(macro))] = .some(nil) }
      case "include", "import", "include_next":
        sawGuard = true
        guard taking, let open = rest.first, open == "<" || open == "\"" else { continue }
        let close: Character = open == "<" ? ">" : "\""
        let spelled = rest.dropFirst().prefix { $0 != close }
        guard let found = resolve(String(spelled), angled: open == "<", includer: path, includeNext: word == "include_next") else { continue }
        for (macro, value) in exports(of: found, dialect: dialect) { env[macro] = value }
      default:
        if !word.isEmpty { sawGuard = true }
      }
    }
    exportCache[key] = env
    return env
  }

  /// A file's directive lines without their `#`, continuation lines joined, comments left out.
  static func directiveLines(_ data: Data) -> [Substring] {
    let text = String(decoding: data, as: UTF8.self)
    var lines: [Substring] = []
    var inComment = false
    var current = ""
    var continuing = false
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
      var line = Substring(raw)
      if line.hasSuffix("\r") { line = line.dropLast() }
      // What's outside comments.
      var kept = ""
      var i = line.startIndex
      while i < line.endIndex {
        if inComment {
          if let end = line[i...].range(of: "*/") {
            inComment = false
            i = end.upperBound
            kept += " "
            continue
          }
          i = line.endIndex
          break
        }
        let c = line[i]
        if c == "/", line.index(after: i) < line.endIndex {
          let next = line[line.index(after: i)]
          if next == "/" { break }
          if next == "*" {
            inComment = true
            i = line.index(i, offsetBy: 2)
            continue
          }
        }
        if c == "\"" || c == "'" {
          // A string's text stays.
          var j = line.index(after: i)
          while j < line.endIndex, line[j] != c { j = line[j] == "\\" && line.index(after: j) < line.endIndex ? line.index(j, offsetBy: 2) : line.index(after: j) }
          let end = j < line.endIndex ? line.index(after: j) : j
          kept += line[i..<end]
          i = end
          continue
        }
        kept.append(c)
        i = line.index(after: i)
      }
      if continuing {
        current += " " + kept
      } else {
        let trimmed = kept.drop { $0 == " " || $0 == "\t" }
        guard trimmed.first == "#" else { continue }
        current = String(trimmed.dropFirst().drop { $0 == " " || $0 == "\t" })
      }
      if current.hasSuffix("\\") {
        current.removeLast()
        continuing = true
        continue
      }
      continuing = false
      lines.append(Substring(current))
    }
    return lines
  }

  // MARK: Includes

  var moduleMap: ClangModuleMap? {
    lock.lock()
    defer { lock.unlock() }
    if moduleMapValue == nil, !sdk.isEmpty { moduleMapValue = CLayout.sharedMap(sdk: sdk) }
    return moduleMapValue
  }

  nonisolated(unsafe) private static var maps: [String: ClangModuleMap] = [:]
  private static let mapLock = NSLock()

  static func sharedMap(sdk: String) -> ClangModuleMap {
    mapLock.lock()
    defer { mapLock.unlock() }
    if let known = maps[sdk] { return known }
    let made = ClangModuleMap(sdk: sdk, frameworks: ClangModuleMap.frameworks(sdk: sdk))
    maps[sdk] = made
    return made
  }

  /// The folders an include searches, in clang's order: `-iquote` (for `"…"` only), `-I`, `-isystem`, libc++ (C++),
  /// clang's headers, the SDK's `usr/include`.
  private func searchPath(quoted: Bool, cpp: Bool) -> [String] {
    var path: [String] = []
    if quoted { path += flags.quoteIncludes }
    path += flags.includes
    path += guessedIncludes
    path += flags.systemIncludes
    if cpp, !libcxxInclude.isEmpty { path.append(libcxxInclude) }
    if !resourceInclude.isEmpty { path.append(resourceInclude) }
    if !sdk.isEmpty { path.append(sdk + "/usr/include") }
    return path
  }

  func resolve(_ spelling: String, angled: Bool, includer: String, includeNext: Bool) -> String? {
    let directory = (includer as NSString).deletingLastPathComponent
    let cpp = csyntax.dialect(of: includer).contains(.cpp)
    let key = "\(angled ? "<" : "\"")\(cpp ? "+" : "")\(includeNext ? includer : directory)|\(spelling)"
    lock.lock()
    if let known = resolved[key] {
      lock.unlock()
      return known
    }
    lock.unlock()
    let found = find(spelling, angled: angled, includer: includer, directory: directory, cpp: cpp, includeNext: includeNext)
    lock.lock()
    resolved[key] = found
    lock.unlock()
    return found
  }

  private func exists(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
  }

  private func find(_ spelling: String, angled: Bool, includer: String, directory: String, cpp: Bool, includeNext: Bool) -> String? {
    if spelling.hasPrefix("@") {
      // `@import Name;`: the module's umbrella header.
      return moduleMap?.umbrellaHeader(of: String(spelling.dropFirst()))
    }
    if spelling.hasPrefix("/") { return exists(spelling) ? spelling : nil }
    var path = searchPath(quoted: !angled, cpp: cpp)
    if includeNext {
      // After the folder the includer was found in.
      if let index = path.firstIndex(where: { includer.hasPrefix($0 + "/") }) { path = Array(path[(index + 1)...]) }
    } else if !angled {
      let local = URL(fileURLWithPath: directory + "/" + spelling).standardizedFileURL.path
      if exists(local) { return local }
    }
    for folder in path {
      let candidate = folder + "/" + spelling
      if exists(candidate) { return URL(fileURLWithPath: candidate).standardizedFileURL.path }
    }
    if let map = moduleMap, let header = map.frameworkHeader(spelling) { return header }
    for folder in flags.frameworkDirs {
      if let slash = spelling.firstIndex(of: "/") {
        let candidate = folder + "/" + spelling[..<slash] + ".framework/Headers/" + spelling[spelling.index(after: slash)...]
        if exists(candidate) { return candidate }
      }
    }
    guard !includeNext else { return nil }
    // A project header no folder finds: the one whose path ends the same, nearest the includer.
    let fileName = (spelling as NSString).lastPathComponent
    let matches = (byName[fileName] ?? []).filter { $0.hasSuffix("/" + spelling) }
    guard !matches.isEmpty else { return nil }
    return matches.max { CLayout.shared($0, includer) < CLayout.shared($1, includer) }
  }

  private static func shared(_ a: String, _ b: String) -> Int {
    var count = 0
    for (x, y) in zip(a.utf8, b.utf8) {
      guard x == y else { break }
      count += 1
    }
    return count
  }

  // MARK: Modules

  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    guard display.hasPrefix("/") else { return nil }
    let units = project.parse([display], isInterface: false)
    guard !units.isEmpty else { return nil }
    return project.register(display, units, isSDK: !display.hasPrefix(root + "/"))
  }

  /// A place outside the project as the reference writes it: `sdk:` and the path in the SDK, `clang:` and the path in
  /// clang's own headers, else the whole path.
  func outsidePlace(_ path: String) -> String {
    // A framework's `Headers` is a link to `Versions/<v>/Headers`, which clang names; a linked file keeps its name.
    var path = path
    if path.contains(".framework/") {
      let folder = (path as NSString).deletingLastPathComponent
      path = (folder as NSString).resolvingSymlinksInPath + "/" + (path as NSString).lastPathComponent
    }
    if !sdk.isEmpty, path.hasPrefix(sdk + "/") { return "sdk:" + path.dropFirst(sdk.count + 1) }
    if !resourceInclude.isEmpty, path.hasPrefix(resourceInclude + "/") { return "clang:" + path.dropFirst(resourceInclude.count + 1) }
    // Elsewhere clang names a header by its folder's real path too (`/opt/homebrew/opt/openssl` is a link into Cellar).
    let folder = (path as NSString).deletingLastPathComponent
    if let known = realFolders[folder] { return known + "/" + (path as NSString).lastPathComponent }
    let real = (folder as NSString).resolvingSymlinksInPath
    realFolders[folder] = real
    return real + "/" + (path as NSString).lastPathComponent
  }
}
