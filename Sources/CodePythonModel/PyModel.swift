import CodeModel
import CodeScan
import Foundation

/// Python's model: definitions, references, completion and details from source, on CodeModel's core. Names resolve by
/// Python's scope rules (a function's names, enclosing functions' but not classes', the module's, `from m import *`,
/// builtins), a name bound several times answering every binding as one symbol; imports are followed to what they
/// bind; attributes through the receiver's type: declared (annotations, `.pyi` stubs) or inferred (constructors,
/// annotated and plain `return`s, `self` and `cls`, `self.x = …` in methods), members found along the class's MRO.
/// Where a receiver's type can't be told, an attribute is answered by name, as candidates.
public final class PyModel: LanguageModel {
  public let project: Project
  let layout: PyLayout
  var exportCache: [Name: [Name: [Site]]] = [:]
  var exporting: Set<UInt64> = []
  var mroCache: [DeclRef: [DeclRef?]] = [:]
  var typeParamCache: [DeclRef: [Name]] = [:]
  var submoduleCache: [Name: [Name: String]] = [:]
  var resolvingValues: Set<DeclRef> = []
  var depth = 0

  public init(project: Project) {
    self.project = project
    layout = project.layout as! PyLayout
    project.onShapeChange = { [weak self] in
      guard let self else { return }
      self.exportCache.removeAll()
      self.mroCache.removeAll()
      self.typeParamCache.removeAll()
    }
  }

  /// A Python project under `root`: its modules from the file tree, its virtual environment's packages.
  public convenience init(root: String) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    self.init(project: Project(root: root, layout: PyLayout(root: root)))
  }

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }
  func file(_ unit: Unit) -> PyFile { unsafeDowncast(unit.scans[PyFile.key]!, to: PyFile.self) }
  func file(_ unitIndex: Int32) -> PyFile { file(project.units[Int(unitIndex)]) }

  static let none = Answer(state: .unknown, sites: [])

  // MARK: Modules

  static let builtinsKey = PyLayout.stubPrefix + "builtins"

  var builtins: Module? { project.ensureModule(name(Self.builtinsKey), display: Self.builtinsKey) }

  /// A module by its key, loaded when first asked.
  func module(_ key: String) -> Module? {
    guard !key.hasPrefix("?"), !key.isEmpty else { return nil }
    return project.ensureModule(name(key), display: key)
  }

  /// The unit that answers for a module: its stub when it has one.
  func primaryUnit(_ module: Module) -> Int32? {
    var found: Int32?
    for index in module.units {
      if file(index).isStub { return index }
      if found == nil { found = index }
    }
    return found
  }

  /// Whether a module is a package: a folder (its `__init__`, or a namespace package).
  func isPackage(_ module: Module) -> Bool {
    guard let first = module.units.first else { return module.displayName.hasPrefix("/") }
    let file = (project.units[Int(first)].path as NSString).lastPathComponent
    return file.hasPrefix("__init__.")
  }

  /// What a module has of a name: its top-level bindings (imports followed), a submodule, what `from m import *` brings.
  func moduleMember(_ moduleName: Name, _ word: Name) -> [Site] {
    if let known = exportCache[moduleName]?[word] { return known }
    let key = moduleName &* 31 &+ word
    guard exporting.insert(key).inserted, depth < 40 else { return [] }
    depth += 1
    defer {
      exporting.remove(key)
      depth -= 1
    }
    guard let module = project.modules[moduleName] else { return [] }
    var result: [Site] = []
    if let unitIndex = primaryUnit(module) {
      let facts = file(unitIndex)
      if let list = facts.byName[ScopeName(scope: 0, name: word)] { result = sites(of: list, in: unitIndex) }
    }
    if result.isEmpty, isPackage(module), let text = submodules(of: module)[word], let sub = self.module(module.displayName + "/" + text) {
      result = [.module(sub.name)]
    }
    if result.isEmpty, let unitIndex = primaryUnit(module) {
      result = starMember(unitIndex, scope: 0, word: word)
    }
    exportCache[moduleName, default: [:]][word] = result
    return result
  }

  /// A package's modules and subpackages by name, from its folder.
  func submodules(of module: Module) -> [Name: String] {
    if let known = submoduleCache[module.name] { return known }
    var table: [Name: String] = [:]
    let manager = FileManager.default
    for entry in (try? manager.contentsOfDirectory(atPath: module.displayName)) ?? [] where !entry.hasPrefix(".") && !entry.hasPrefix("__init__.") {
      var isDirectory: ObjCBool = false
      guard manager.fileExists(atPath: module.displayName + "/" + entry, isDirectory: &isDirectory) else { continue }
      if isDirectory.boolValue {
        if entry != "__pycache__", !entry.contains(".") { table[name(entry)] = entry }
      } else if PyLayout.isSource(entry), let dot = entry.firstIndex(of: ".") {
        table[name(String(entry[..<dot]))] = String(entry[..<dot])
      }
    }
    submoduleCache[module.name] = table
    return table
  }

  /// What `from m import *` in a scope brings of a name: m's `__all__`, or its public names.
  func starMember(_ unitIndex: Int32, scope: Int32, word: Name) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    for importIndex in file(unit).stars[scope] ?? [] {
      let item = unit.imports[Int(importIndex)]
      guard let target = self.module(item.moduleName), let targetUnit = primaryUnit(target) else {
        continue
      }
      let targetFile = file(targetUnit)
      if let all = targetFile.dunderAll {
        guard all.contains(where: { name($0) == word }) else { continue }
      } else if let list = targetFile.byName[ScopeName(scope: 0, name: word)], let first = list.first,
        project.units[Int(targetUnit)].string(Int(targetFile.bindings[Int(first)].token)).hasPrefix("_")
      {
        continue
      }
      let found = moduleMember(target.name, word)
      if !found.isEmpty { return found }
    }
    return []
  }

  // MARK: Names

  /// A binding's sites: its declaration, what its import binds, or the local.
  func sites(of bindings: [Int32], in unitIndex: Int32) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    let facts = file(unit)
    var result: [Site] = []
    for index in bindings {
      let binding = facts.bindings[Int(index)]
      if binding.importIndex >= 0 {
        for site in follow(unitIndex, Int(binding.importIndex)) where !result.contains(site) { result.append(site) }
      } else if binding.decl >= 0 {
        let site = Site.decl(DeclRef(unit: unitIndex, decl: binding.decl))
        if !result.contains(site) { result.append(site) }
      } else {
        result.append(.local(unit: unitIndex, token: binding.token))
      }
    }
    return result
  }

  /// What an import binds: the module (`import a.b` binds `a`), or what the module has of the member; the import itself
  /// when the module or the member isn't found.
  func follow(_ unitIndex: Int32, _ importIndex: Int) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    let item = unit.imports[importIndex]
    let own: [Site] = item.aliasToken >= 0 ? [.local(unit: unitIndex, token: item.aliasToken)] : []
    guard let target = module(item.moduleName) else { return own }
    if item.member == 0 { return [.module(target.name)] }
    let found = moduleMember(target.name, item.member)
    return found.isEmpty ? own : found
  }

  /// A name read in a scope, by Python's rules: the scope's own bindings (`global` and `nonlocal` sending it out),
  /// enclosing functions' (not classes'), the module's, `from m import *`'s, then builtins.
  func lookup(_ word: Name, unitIndex: Int32, scope: Int32) -> [Site] {
    let facts = file(unitIndex)
    var current = scope
    var first = true
    while current > 0 {
      let item = facts.scopes[Int(current)]
      if first || item.kind != .classBody {
        if item.globals.contains(word) { break }
        if !item.nonlocals.contains(word), let list = facts.byName[ScopeName(scope: current, name: word)] { return sites(of: list, in: unitIndex) }
      }
      first = false
      current = item.parent
    }
    return moduleLookup(word, unitIndex: unitIndex)
  }

  func moduleLookup(_ word: Name, unitIndex: Int32) -> [Site] {
    let facts = file(unitIndex)
    if let list = facts.byName[ScopeName(scope: 0, name: word)] { return sites(of: list, in: unitIndex) }
    let starred = starMember(unitIndex, scope: 0, word: word)
    if !starred.isEmpty { return starred }
    return builtin(word)
  }

  /// A builtin: `builtins`' own declaration of the name.
  func builtin(_ word: Name) -> [Site] {
    guard let module = builtins, let unitIndex = module.units.first else { return [] }
    let facts = file(unitIndex)
    guard let list = facts.byName[ScopeName(scope: 0, name: word)] else { return [] }
    return sites(of: list, in: unitIndex)
  }

  /// A builtin class, as a type.
  func builtinClass(_ word: Name, _ args: [Ty] = []) -> Ty {
    for case .decl(let ref) in builtin(word) where decl(ref).kind == .classType { return .nominal(ref, args) }
    return .unknown
  }

  // MARK: Asking

  public func answer(path: String, line: Int, character: Int) -> Answer {
    guard let unitIndex = project.unitByPath[path] else { return Self.none }
    let unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    guard let token = unit.token(at: offset) else { return Self.none }
    return answer(unitIndex: unitIndex, token: token)
  }

  func answer(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    guard unit.tokens[token].kind == .identifier || unit.tokens[token].kind == .keyword && unit.isByte(token - 1, 0x2E) else { return Self.none }
    let facts = file(unit)
    let word = unit.hash(token)
    // A string's prefix (`b"…"`, `rf"…"`) is part of the string.
    if token + 1 < unit.tokens.count, unit.tokens[token + 1].kind == .string, unit.tokens[token + 1].start == unit.tokens[token].end { return Self.none }
    // A module's name in an import.
    if let path = facts.modulePaths[Int32(token)] {
      let key = layout.resolve(path.dotted, level: Int(path.level), from: unit.path)
      guard let found = module(key) else { return Self.none }
      return Answer(state: .exact, sites: [.module(found.name)])
    }
    for (index, item) in unit.imports.enumerated() where item.memberToken == Int32(token) || item.aliasToken == Int32(token) {
      return settled(follow(unitIndex, index))
    }
    // `f"{x!r}"`: a conversion, no name.
    if token >= 1, unit.isByte(token - 1, 0x21), unit.tokens[token - 1].length == 1, token + 1 < unit.tokens.count,
      unit.tokens[token + 1].kind == .interpolationClose || unit.isByte(token + 1, 0x3A)
    {
      return Self.none
    }
    if unit.isByte(token - 1, 0x2E), token >= 2, !unit.isAllDots(token - 2) || unit.tokens[token - 2].kind != .punctuation, !unit.isNumberDot(token - 1) {
      return member(unitIndex: unitIndex, dot: token - 1, word: word)
    }
    if let bindingIndex = facts.byToken[Int32(token)] {
      let binding = facts.bindings[Int(bindingIndex)]
      if binding.kind == .parameter { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))]) }
    }
    if let found = keywordArgument(unitIndex: unitIndex, token: token) { return found }
    let found = lookup(word, unitIndex: unitIndex, scope: facts.scope(at: token))
    return found.isEmpty ? Self.none : settled(found)
  }

  /// Sites without repeats: one symbol (a name's bindings, a member's declarations in one class) is exact however
  /// many sites it has.
  func settled(_ sites: [Site], byName: Bool = false) -> Answer {
    var unique: [Site] = []
    for site in sites where !unique.contains(site) { unique.append(site) }
    if unique.isEmpty { return Self.none }
    if byName { return Answer(state: .candidates, sites: unique, byNameOnly: true) }
    return Answer(state: .exact, sites: unique)
  }

  /// `f(name=value)`: f's parameter.
  func keywordArgument(unitIndex: Int32, token: Int) -> Answer? {
    let unit = project.units[Int(unitIndex)]
    guard unit.isByte(token + 1, 0x3D) || unit.startsWithAssign(token + 1), unit.isByte(token - 1, 0x28) || unit.isByte(token - 1, 0x2C),
      let open = unit.matchingOpenBefore(token), unit.isByte(open, 0x28), open > 0,
      unit.tokens[open - 1].kind == .identifier || unit.tokens[open - 1].kind == .close
    else { return nil }
    let callee = callee(unitIndex, open: open)
    let word = unit.hash(token)
    var found: [Site] = []
    for ref in callee {
      let item = decl(ref)
      let holder = self.unit(ref)
      for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].local == word {
        found.append(.local(unit: ref.unit, token: holder.params[Int(item.paramStart) + p].nameToken))
      }
      // A dataclass's field.
      if item.kind == .classType {
        for child in holder.children(of: ref.decl) where holder.decls[Int(child)].name == word && holder.decls[Int(child)].kind == .variable {
          found.append(.decl(DeclRef(unit: ref.unit, decl: child)))
          break
        }
      }
    }
    return found.isEmpty ? Self.none : settled(found)
  }

  /// What a call at `open` calls: functions, or a class (its `__init__` when it has one).
  func callee(_ unitIndex: Int32, open: Int) -> [DeclRef] {
    let ty = operandType(unitIndex, end: open)
    var result: [DeclRef] = []
    func add(_ ty: Ty) {
      switch ty {
      case .nominal(let ref, _) where decl(ref).kind == .function: result.append(ref)
      case .meta(.nominal(let ref, _)):
        let inits = members(of: .nominal(ref, []), named: PyWord.initName, from: unitIndex)
        let own = inits.compactMap { site -> DeclRef? in
          if case .decl(let found) = site, decl(found).paramCount > 1 || self.unit(found).path == unit(ref).path { return found }
          return nil
        }
        if own.isEmpty || own.allSatisfy({ isBuiltinsUnit(self.unit($0)) }) { result.append(ref) } else { result += own }
      case .constructed(let kind, let parts) where kind == Ty.union: parts.forEach(add)
      default: break
      }
    }
    add(ty)
    return result
  }

  func isBuiltinsUnit(_ unit: Unit) -> Bool { project.modules[unit.moduleName]?.displayName == Self.builtinsKey }

  /// `x.name`: what x's type has of that name; by name when x's type can't be told.
  func member(unitIndex: Int32, dot: Int, word: Name) -> Answer {
    let operand = operandType(unitIndex, end: dot)
    let found = members(of: operand, named: word, from: unitIndex)
    if !found.isEmpty { return settled(found) }
    guard isUnknown(operand) else { return Self.none }
    let candidates = project.membersNamed(word)
    guard !candidates.isEmpty else { return Self.none }
    return settled(candidates.prefix(12).map { .decl($0) }, byName: true)
  }

  // MARK: References

  public func references(of answer: Answer) -> [(path: String, line: Int)] {
    guard answer.state != .unknown, !answer.byNameOnly, let first = answer.sites.first else { return [] }
    let targets = Set(answer.sites)
    var names: Set<Name> = []
    var restrict: Int32?
    switch first {
    case .decl(let ref):
      names.insert(decl(ref).name)
    case .local(let unitIndex, let token), .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      names.insert(holder.hash(Int(token)))
      // An import that wasn't found is the definition other files' imports of it land on too.
      if !holder.imports.contains(where: { $0.aliasToken == token }) { restrict = unitIndex }
    case .module:
      break
    }
    var modules: Set<Name> = []
    for target in targets {
      switch target {
      case .decl(let ref): names.insert(decl(ref).name)
      case .module(let moduleName):
        guard let module = project.modules[moduleName] else { continue }
        modules.insert(moduleName)
        names.insert(name(Self.moduleWord(module.displayName)))
      default: break
      }
    }
    // Names it's imported as: `from m import a as b` in the project, `import m as b` in any file read (`os.path` is
    // `posixpath`).
    let wanted = names
    for u in project.units.indices {
      for item in project.units[u].imports where item.alias != 0 {
        if item.member == 0 ? modules.contains(item.module) : u < project.projectUnits && wanted.contains(item.member) { names.insert(item.alias) }
      }
    }
    return project.references(named: names, in: restrict, landingOn: targets) { self.answer(unitIndex: $0, token: $1) }
  }

  /// The word a module key is written as: `stub:os.path` and `/…/os/path` are `path`.
  static func moduleWord(_ key: String) -> String {
    if key.hasPrefix(PyLayout.stubPrefix) { return String(key.dropFirst(PyLayout.stubPrefix.count).split(separator: ".").last ?? "") }
    return (key as NSString).lastPathComponent
  }

  // MARK: Places

  /// As the reference names a place: relative to the root, `stdlib:<path>`, `site:<path>` in the virtual
  /// environment, `stub:<module>.pyi` for the generated stubs, `../…` elsewhere; a module at line 1 (a namespace
  /// package as its folder with a `/`).
  public func place(of site: Site) -> (path: String, line: Int)? {
    var path: String
    var line: Int
    if case .module(let moduleName) = site {
      guard let module = project.modules[moduleName] else { return nil }
      if let first = primaryUnit(module) {
        path = project.units[Int(first)].path
      } else {
        path = module.displayName + "/"
      }
      line = 1
    } else {
      guard let at = location(of: site) else { return nil }
      path = at.path
      line = at.line + 1
    }
    return (placeName(path), line)
  }

  /// Where the generated stubs are written, for an editor to open.
  static let stubDirectory = NSTemporaryDirectory() + "code-python-stubs-39/"

  func placeName(_ path: String) -> String {
    let stubs = Self.stubDirectory
    if path.hasPrefix(stubs) { return "stub:" + path.dropFirst(stubs.count) }
    if let site = layout.sitePackages, path.hasPrefix(site + "/") { return "site:" + path.dropFirst(site.count + 1) }
    if path.hasPrefix(project.root + "/") { return String(path.dropFirst(project.root.count + 1)) }
    if let stdlib = layout.stdlib, path.hasPrefix(stdlib + "/") { return "stdlib:" + path.dropFirst(stdlib.count + 1) }
    let root = project.root.split(separator: "/")
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    var common = 0
    while common < root.count, common < parts.count, root[common] == parts[common] { common += 1 }
    return (Array(repeating: "..", count: root.count - common) + parts[common...].map(String.init)).joined(separator: "/") + (path.hasSuffix("/") ? "/" : "")
  }
}
