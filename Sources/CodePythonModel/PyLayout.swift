import CodeModel
import CodeScan
import Foundation

/// Python's projects: modules from the file tree. A module's key is its file's path without the extension, a
/// package's its folder (`__init__.py` in it, or none for a namespace package); a `.pyi` beside a `.py` is the same
/// module and answers for it. Imports resolve as Python finds them, offline and without running anything:
///
/// 1. The modules built into the interpreter (`sys`, `builtins`, `posix`…), from the generated stubs (`PyStubs`).
/// 2. The project's roots: the folder itself, `src/`, every folder with a `pyproject.toml`, `setup.py` or `setup.cfg`
///    and the package folders those name (hatch's `packages`, setuptools' `where` and `package_dir`, poetry's `from`).
/// 3. The importing file's own folder (a script's `sys.path[0]`).
/// 4. The standard library's sources (`CODE_PYTHON_STDLIB`, Xcode's Python 3, a framework, Homebrew's or `/usr/lib`'s),
///    then its C extension modules from the stubs.
/// 5. A virtual environment's `site-packages` (`.venv`, `venv`, `env` in the project), read, never installed into.
///
/// A namespace package (a folder without `__init__.py`) answers only when no root has a module of the name.
/// Relative imports go up from the importing file's folder.
final class PyLayout: ProjectLayout {
  let root: String
  private(set) var syntax: any LanguageSyntax = PySyntax(resolve: { _, _, _ in "" })
  let implicitModules: [String] = []
  let interfaceExtension = ".pyi"
  /// Where absolute imports are looked for, in order (before the importing file's folder).
  private(set) var roots: [String] = []
  let stdlib: String?
  let sitePackages: String?
  /// The C extension modules of the standard library (its `lib-dynload`), stubbed.
  private let extensionModules: Set<String>
  private let lock = NSLock()
  private var resolved: [String: String] = [:]
  private var existing: [String: Int8] = [:]

  /// Built into the interpreter (Python 3.9's `sys.builtin_module_names`): found before any path.
  static let builtinModules: Set<String> = [
    "_abc", "_ast", "_codecs", "_collections", "_functools", "_imp", "_io", "_locale", "_operator", "_peg_parser", "_signal", "_sre", "_stat",
    "_string", "_symtable", "_thread", "_tracemalloc", "_warnings", "_weakref", "atexit", "builtins", "errno", "faulthandler", "gc", "itertools",
    "marshal", "posix", "pwd", "sys", "time", "xxsubtype",
  ]
  static let skipped: Set<String> = ["node_modules", "__pycache__", "build", "dist", "site-packages", ".tox", ".git"]
  static let stubPrefix = "stub:"

  init(root: String) {
    self.root = root
    stdlib = PyLayout.findStdlib()
    sitePackages = PyLayout.findSitePackages(in: root)
    var extensions = Set<String>()
    if let stdlib, let names = try? FileManager.default.contentsOfDirectory(atPath: stdlib + "/lib-dynload") {
      for file in names { if let base = file.split(separator: ".").first { extensions.insert(String(base)) } }
    } else {
      extensions = Set(PyStubs.modules.keys).subtracting(PyLayout.builtinModules)
    }
    extensionModules = extensions
    syntax = PySyntax(resolve: { [unowned self] dotted, level, from in self.resolve(dotted, level: level, from: from) })
  }

  // MARK: Files

  static func isSource(_ name: String) -> Bool { name.hasSuffix(".py") || name.hasSuffix(".pyi") || name.hasSuffix(".pyw") }

  func sourceFiles(in directory: String) -> [String] {
    var result: [String] = []
    var manifests: [String] = []
    let manager = FileManager.default
    var stack = [directory]
    while let current = stack.popLast() {
      guard let entries = try? manager.contentsOfDirectory(atPath: current) else { continue }
      for entry in entries {
        let path = current + "/" + entry
        if entry == "pyproject.toml" || entry == "setup.py" || entry == "setup.cfg" { manifests.append(current) }
        if entry.hasPrefix(".") || PyLayout.skipped.contains(entry) { continue }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
        if isDirectory.boolValue {
          if manager.fileExists(atPath: path + "/pyvenv.cfg") { continue }
          stack.append(path)
        } else if PyLayout.isSource(entry) {
          result.append(path)
        }
      }
    }
    if directory == root { findRoots(manifests: Set(manifests)) }
    return result.sorted()
  }

  /// The project's import roots, from its manifests.
  private func findRoots(manifests: Set<String>) {
    var found = [root]
    func add(_ path: String) {
      let standard = URL(fileURLWithPath: path).standardizedFileURL.path
      var isDirectory: ObjCBool = false
      if !found.contains(standard), FileManager.default.fileExists(atPath: standard, isDirectory: &isDirectory), isDirectory.boolValue { found.append(standard) }
    }
    add(root + "/src")
    for directory in manifests.sorted() {
      add(directory)
      add(directory + "/src")
      var text = ""
      for file in ["pyproject.toml", "setup.cfg"] {
        if let data = FileManager.default.contents(atPath: directory + "/" + file) { text += String(decoding: data, as: UTF8.self) + "\n" }
      }
      // hatch: `packages = ["src/x"]`: the package's folder is in a root.
      for list in PyLayout.matches(#"packages\s*=\s*\[([^\]]*)\]"#, in: text) {
        for item in PyLayout.matches(#""([^"]+)""#, in: list) { add((directory + "/" + item as NSString).deletingLastPathComponent) }
      }
      for item in PyLayout.matches(#"where\s*=\s*\[\s*"([^"]+)""#, in: text) { add(directory + "/" + item) }
      for item in PyLayout.matches(#"package_dir\s*=\s*\n?\s*=\s*(\S+)"#, in: text) { add(directory + "/" + item) }
      for item in PyLayout.matches(#"from\s*=\s*"([^"]+)""#, in: text) { add(directory + "/" + item) }
    }
    roots = found
  }

  /// The first group of every match of a pattern.
  static func matches(_ pattern: String, in text: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return expression.matches(in: text, range: range).compactMap { match in
      guard match.numberOfRanges > 1, let found = Range(match.range(at: 1), in: text) else { return nil }
      return String(text[found])
    }
  }

  /// A project file's module key: its path without the extension, a package's folder for `__init__`.
  func moduleName(ofRelative path: String) -> String {
    let absolute = path.hasPrefix("/") ? path : root + "/" + path
    return PyLayout.key(ofFile: absolute)
  }

  static func key(ofFile path: String) -> String {
    let directory = (path as NSString).deletingLastPathComponent
    let file = (path as NSString).lastPathComponent
    if file == "__init__.py" || file == "__init__.pyi" { return directory }
    guard let dot = file.lastIndex(of: ".") else { return path }
    return directory + "/" + file[..<dot]
  }

  /// A module an import reached: a stub, a file's module, a package, or a namespace package's folder.
  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    if display.hasPrefix(PyLayout.stubPrefix) {
      let module = String(display.dropFirst(PyLayout.stubPrefix.count))
      guard let text = PyStubs.modules[module] else { return nil }
      let path = PyLayout.stubFile(module, text: text)
      let unit = Unit(path: path, source: SourceFile(text, profile: syntax.profile), syntax: syntax, isInterface: false)
      return project.register(display, [unit], isSDK: true)
    }
    guard display.hasPrefix("/") else { return nil }
    let files = PyLayout.files(ofKey: display)
    let isSDK = !display.hasPrefix(root + "/") || (sitePackages.map { display.hasPrefix($0 + "/") } ?? false)
    if files.isEmpty {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: display, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
      return project.register(display, [], isSDK: isSDK)
    }
    let units = project.parse(files.filter { project.unitByPath[$0] == nil }, isInterface: false)
    return project.register(display, units, isSDK: isSDK)
  }

  /// A module key's files: the stub first.
  static func files(ofKey key: String) -> [String] {
    let manager = FileManager.default
    var result: [String] = []
    for candidate in [key + ".pyi", key + ".py"] where manager.fileExists(atPath: candidate) { result.append(candidate) }
    if result.isEmpty {
      for candidate in [key + "/__init__.pyi", key + "/__init__.py"] where manager.fileExists(atPath: candidate) { result.append(candidate) }
    }
    return result
  }

  /// A stub's text on disk, where an editor can open it: the temporary folder, written once.
  static func stubFile(_ module: String, text: String) -> String {
    let directory = NSTemporaryDirectory() + "code-python-stubs-39"
    let path = directory + "/" + module + ".pyi"
    let manager = FileManager.default
    if (try? manager.attributesOfItem(atPath: path)[.size] as? Int) != text.utf8.count {
      try? manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
      try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
    return path
  }

  // MARK: Resolving

  /// A dotted module name imported from a file, with its relative level, to a module key; `?` and the name when it
  /// isn't found.
  func resolve(_ dotted: String, level: Int, from: String) -> String {
    let directory = (from as NSString).deletingLastPathComponent
    let cacheKey = level > 0 ? "\(level)|\(directory)|\(dotted)" : dotted + "|" + directory
    lock.lock()
    if let known = resolved[cacheKey] {
      lock.unlock()
      return known
    }
    lock.unlock()
    let found = find(dotted, level: level, directory: directory)
    lock.lock()
    resolved[cacheKey] = found
    lock.unlock()
    return found
  }

  private func find(_ dotted: String, level: Int, directory: String) -> String {
    if level > 0 {
      var base = directory
      for _ in 1..<level { base = (base as NSString).deletingLastPathComponent }
      if dotted.isEmpty { return base }
      return lookIn(base, dotted).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } ?? "?" + dotted
    }
    let top = dotted.split(separator: ".").first.map(String.init) ?? dotted
    if !dotted.contains("."), PyLayout.builtinModules.contains(dotted), PyStubs.modules[dotted] != nil { return PyLayout.stubPrefix + dotted }
    var namespace: String?
    for base in roots + [directory] + (stdlib.map { [$0] } ?? []) {
      guard let found = lookIn(base, dotted) else { continue }
      if found.hasSuffix("/") {
        if namespace == nil { namespace = String(found.dropLast()) }
        continue
      }
      return found
    }
    if !dotted.contains("."), extensionModules.contains(top), PyStubs.modules[dotted] != nil { return PyLayout.stubPrefix + dotted }
    if let sitePackages, let found = lookIn(sitePackages, dotted) {
      if !found.hasSuffix("/") { return found }
      if namespace == nil { namespace = String(found.dropLast()) }
    }
    return namespace ?? "?" + dotted
  }

  /// A module in one search folder: its key, or a namespace package's folder ending in `/`.
  private func lookIn(_ base: String, _ dotted: String) -> String? {
    let path = base + "/" + dotted.replacingOccurrences(of: ".", with: "/")
    if exists(path + ".pyi") || exists(path + ".py") { return path }
    if exists(path + "/__init__.pyi") || exists(path + "/__init__.py") { return path }
    if isDirectory(path) { return path + "/" }
    return nil
  }

  private func exists(_ path: String) -> Bool { status(path) == 1 }
  private func isDirectory(_ path: String) -> Bool { status(path) == 2 }

  /// 0 missing, 1 a file, 2 a folder; cached.
  private func status(_ path: String) -> Int8 {
    lock.lock()
    if let known = existing[path] {
      lock.unlock()
      return known
    }
    lock.unlock()
    var isDirectory: ObjCBool = false
    let found: Int8 = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) ? (isDirectory.boolValue ? 2 : 1) : 0
    lock.lock()
    existing[path] = found
    lock.unlock()
    return found
  }

  // MARK: The toolchain

  /// The standard library's sources: `CODE_PYTHON_STDLIB`, else the first Python 3 found on this machine.
  static func findStdlib() -> String? {
    let manager = FileManager.default
    if let path = ProcessInfo.processInfo.environment["CODE_PYTHON_STDLIB"], manager.fileExists(atPath: path + "/os.py") { return path }
    var candidates = ["/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/lib/python3.9"]
    for frameworks in ["/Library/Frameworks/Python.framework/Versions", "/opt/homebrew/Frameworks/Python.framework/Versions", "/usr/local/Frameworks/Python.framework/Versions"] {
      for version in ((try? manager.contentsOfDirectory(atPath: frameworks)) ?? []).sorted().reversed() where version.hasPrefix("3") {
        candidates.append(frameworks + "/" + version + "/lib/python" + version)
      }
    }
    for lib in ["/usr/lib", "/usr/local/lib"] {
      for entry in ((try? manager.contentsOfDirectory(atPath: lib)) ?? []).sorted().reversed() where entry.hasPrefix("python3") { candidates.append(lib + "/" + entry) }
    }
    return candidates.first { manager.fileExists(atPath: $0 + "/os.py") }
  }

  /// A virtual environment in the project: its `site-packages`.
  static func findSitePackages(in root: String) -> String? {
    let manager = FileManager.default
    for venv in [".venv", "venv", "env"] {
      let base = root + "/" + venv
      guard manager.fileExists(atPath: base + "/pyvenv.cfg") else { continue }
      if manager.fileExists(atPath: base + "/Lib/site-packages") { return base + "/Lib/site-packages" }
      let lib = base + "/lib"
      for entry in ((try? manager.contentsOfDirectory(atPath: lib)) ?? []).sorted().reversed() where entry.hasPrefix("python") {
        if manager.fileExists(atPath: lib + "/" + entry + "/site-packages") { return lib + "/" + entry + "/site-packages" }
      }
    }
    return nil
  }
}
