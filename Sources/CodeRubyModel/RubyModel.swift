import CodeModel
import CodeScan
import Foundation

/// Ruby's model: definitions, references, completion and details from source, on CodeModel's core. Constants are
/// global, by their qualified name (`A::B`) over every file read: a name looks in the classes and modules around it
/// (innermost first), then in the innermost one's ancestors, then at the top level; `A::B` in `A` and its ancestors.
/// A class's ancestors are its prepends, itself, its includes (latest first) and its superclass's, as Ruby orders them;
/// its singleton side has its `def self.x` and `class << self` methods, its extends, its superclass's singleton side,
/// then `Class` and `Module`. Locals are a scope's (a block sees its parents', up to a method, class or file), defined
/// where first bound. Instance variables are a class's, defined at their first assignment in it (else in an
/// ancestor), apart for the class itself (class-level ones); class variables are shared down the hierarchy, globals by
/// the whole program. Methods go through a value's type (literals, `Foo.new`, constants, YARD's `@return` and
/// `@param`, Sorbet's `sig`, a method's last expression) along its ancestors; a value whose type can't be told answers
/// by name, as candidates. `method_missing`, `define_method` with a computed name, `send` and blocks evaluated
/// elsewhere (`instance_eval`, DSLs) are unknown rather than guessed.
public final class RubyModel: LanguageModel {
  public let project: Project
  let layout: RubyLayout
  /// Qualified constant names (`A::B`) to their declarations: class and module openings, constants.
  var constants: [String: [DeclRef]] = [:]
  var qualifiedCache: [DeclRef: String] = [:]
  private var indexedUnits = 0
  private var loadedStd = false
  /// Units whose requires were followed.
  private var followed: Set<Int32> = []
  private var followedProject = false
  var ancestorCache: [String: [String]] = [:]
  var building: Set<String> = []
  var instanceTables: [String: [Name: DeclRef]] = [:]
  var staticTables: [String: [Name: DeclRef]] = [:]
  /// Instance, class and global variables' first assignments by owner (`Q`, `#Q` for the class's own, `@@Q`, `$`).
  var variableDefs: [String: [Name: (path: String, token: Int, site: Site)]] = [:]
  /// Every assignment of each, for types.
  var variableAssignments: [String: [Name: [(Int32, Int)]]] = [:]
  private var variablesIndexed = 0
  var valueTypes: [DeclRef: Ty] = [:]
  var resolving: Set<DeclRef> = []
  var variableTypes: [String: Ty] = [:]
  var resolvingVariables: Set<String> = []
  var depth = 0

  init(project: Project) {
    self.project = project
    layout = project.layout as! RubyLayout
    project.onShapeChange = { [weak self] in self?.dropTables() }
  }

  /// A Ruby project under `root`: its files, the files its requires reach, Ruby's core classes.
  public convenience init(root: String) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    self.init(project: Project(root: root, layout: RubyLayout(root: root)))
  }

  private func dropTables() {
    constants.removeAll()
    qualifiedCache.removeAll()
    indexedUnits = 0
    ancestorCache.removeAll()
    instanceTables.removeAll()
    staticTables.removeAll()
    variableDefs.removeAll()
    variableAssignments.removeAll()
    variablesIndexed = 0
    valueTypes.removeAll()
    variableTypes.removeAll()
  }

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }

  static let unknown = Answer(state: .unknown, sites: [])

  func summarize(_ sites: [Site]) -> Answer { sites.isEmpty ? Self.unknown : Answer(summarizing: sites) }

  func isSDK(_ ref: DeclRef) -> Bool { project.isSDK(unit(ref)) }

  func structure(_ unit: Unit) -> RubyStructure { unsafeDowncast(unit.scans[RubyStructure.key]!, to: RubyStructure.self) }

  /// The locals of a file, scanned once asked for.
  func body(_ unitIndex: Int32) -> RubyBody {
    let unit = project.units[Int(unitIndex)]
    if let known = unit.scans[RubyBody.key] { return unsafeDowncast(known, to: RubyBody.self) }
    let scan = RubyBody(unit: unit, structure: structure(unit))
    unit.scans[RubyBody.key] = scan
    return scan
  }

  // MARK: Constants

  /// Whether a declaration is a constant: a class, a module, or `X = …`.
  static func isConstant(_ item: Decl) -> Bool {
    item.kind == .classType || item.kind == .namespace || item.kind == .variable && item.isStatic
  }

  /// A class, module or constant's qualified name: the classes and modules around it and its path as written.
  func qualifiedName(_ ref: DeclRef) -> String {
    if let known = qualifiedCache[ref] { return known }
    let holder = unit(ref)
    let item = decl(ref)
    var path = item.typeStart >= 0 && item.typeEnd > item.typeStart ? holder.text(from: Int(item.typeStart), to: Int(item.typeEnd)).filter { $0 != " " && $0 != "\t" && $0 != "\n" } : holder.string(Int(item.nameToken))
    var result: String
    if path.hasPrefix("::") {
      path.removeFirst(2)
      result = path
    } else {
      var parent = item.parent
      while parent >= 0, holder.decls[Int(parent)].kind != .classType, holder.decls[Int(parent)].kind != .namespace { parent = holder.decls[Int(parent)].parent }
      let outer = parent >= 0 ? qualifiedName(DeclRef(unit: ref.unit, decl: parent)) : ""
      result = outer.isEmpty ? path : outer + "::" + path
    }
    qualifiedCache[ref] = result
    return result
  }

  func indexNewUnits() {
    while indexedUnits < project.units.count {
      let u = Int32(indexedUnits)
      indexedUnits += 1
      let holder = project.units[Int(u)]
      for (index, item) in holder.decls.enumerated() where Self.isConstant(item) {
        if item.kind == .variable {
          // `X = …` inside a method or block isn't read; one in a class body or a file is.
          var parent = item.parent
          var inMethod = false
          while parent >= 0 {
            let kind = holder.decls[Int(parent)].kind
            if kind == .function || kind == .initializer { inMethod = true }
            parent = holder.decls[Int(parent)].parent
          }
          if inMethod { continue }
        }
        let ref = DeclRef(unit: u, decl: Int32(index))
        constants[qualifiedName(ref), default: []].append(ref)
      }
    }
  }

  func loadStd() {
    guard !loadedStd else { return }
    loadedStd = true
    project.ensureModule(name(RubyLayout.stdModule), display: RubyLayout.stdModule)
    indexNewUnits()
  }

  var stdUnit: Int32? {
    loadStd()
    return project.modules[name(RubyLayout.stdModule)]?.units.first
  }

  /// A file outside the project, read once.
  @discardableResult
  func load(_ path: String) -> Int32? {
    if let known = project.unitByPath[path] { return known }
    guard project.ensureModule(name(path), display: path) != nil else { return nil }
    indexNewUnits()
    return project.unitByPath[path]
  }

  /// The file a `require`, `require_relative`, `load` or `autoload` of a unit names.
  func requiredFile(_ item: Import, of holder: Unit) -> String? {
    let directory = (holder.path as NSString).deletingLastPathComponent
    switch item.member {
    case RubyImport.requireRelative:
      let path = RubyLayout.standardize(directory + "/" + item.moduleName)
      if FileManager.default.fileExists(atPath: path), !RubyLayout.isDirectory(path) { return path }
      return FileManager.default.fileExists(atPath: path + ".rb") ? path + ".rb" : nil
    case RubyImport.require, RubyImport.autoload:
      return layout.resolve(feature: item.moduleName)
    case RubyImport.load:
      if item.moduleName.hasPrefix("/") { return item.moduleName }
      return layout.resolve(feature: item.moduleName) ?? (FileManager.default.fileExists(atPath: directory + "/" + item.moduleName) ? RubyLayout.standardize(directory + "/" + item.moduleName) : nil)
    default:
      return nil
    }
  }

  /// The folders a unit adds to `$LOAD_PATH`, before its requires are followed.
  func addLoadPaths(of holder: Unit) {
    let directory = (holder.path as NSString).deletingLastPathComponent
    for item in holder.imports where item.member == RubyImport.loadPath { layout.addLoadPath(directory + "/" + item.moduleName) }
  }

  private var loadPathsRead = false

  /// Every project file's `$LOAD_PATH` additions, once.
  func readLoadPaths() {
    guard !loadPathsRead else { return }
    loadPathsRead = true
    for u in 0..<project.projectUnits { addLoadPaths(of: project.units[u]) }
  }

  /// Reads what a unit requires, and what that requires, to a bound.
  func follow(_ start: [Int32], budget: Int = 1500) {
    readLoadPaths()
    var queue = start.filter { followed.insert($0).inserted }
    var loaded = 0
    while let next = queue.popLast(), loaded < budget {
      let holder = project.units[Int(next)]
      addLoadPaths(of: holder)
      for item in holder.imports where item.member != RubyImport.loadPath {
        guard let path = requiredFile(item, of: holder) else { continue }
        let known = project.unitByPath[path]
        guard let index = known ?? load(path) else { continue }
        if known == nil { loaded += 1 }
        if followed.insert(index).inserted { queue.append(index) }
      }
    }
  }

  /// The constant declarations of a qualified name, the project's first.
  func constantRefs(_ qualified: String) -> [DeclRef]? {
    guard let found = constants[qualified], !found.isEmpty else { return nil }
    return found
  }

  /// The classes and modules a token is lexically inside (their qualified names), innermost first. A class's own name
  /// and superclass are read outside it.
  func lexicalScopes(unitIndex: Int32, token: Int) -> [String] {
    let holder = project.units[Int(unitIndex)]
    var result: [String] = []
    for index in holder.chain(at: Int32(token)) {
      let item = holder.decls[Int(index)]
      guard item.kind == .classType || item.kind == .namespace else { continue }
      // A class `Struct.new` makes: its block doesn't change where constants are looked up.
      if item.initStart >= 0 { continue }
      guard item.bodyOpen >= 0, token >= Int(item.bodyOpen) else { continue }
      result.insert(qualifiedName(DeclRef(unit: unitIndex, decl: index)), at: 0)
    }
    return result
  }

  /// A constant's name looked up from a token: lexically, then the innermost scope's ancestors, then the top level;
  /// the files required (and Ruby's core) read when it isn't found.
  func lookupConstant(_ word: String, unitIndex: Int32, token: Int) -> [DeclRef] {
    indexNewUnits()
    let scopes = lexicalScopes(unitIndex: unitIndex, token: token)
    func find() -> [DeclRef]? {
      for scope in scopes {
        if let found = constantRefs(scope + "::" + word) { return found }
      }
      if let innermost = scopes.first {
        for ancestor in ancestors(innermost).dropFirst() where ancestor != "Object" {
          if let found = constantRefs(ancestor + "::" + word) { return found }
        }
      }
      return constantRefs(word)
    }
    if let found = find() { return found }
    if !followed.contains(unitIndex) {
      follow([unitIndex])
      if let found = find() { return found }
    }
    if !followedProject {
      followedProject = true
      follow((0..<Int32(project.projectUnits)).map { $0 })
      if let found = find() { return found }
    }
    loadStd()
    return find() ?? []
  }

  /// `A::B`: `B` in `A` (and its ancestors).
  func scopedConstant(_ word: String, in owner: String) -> [DeclRef] {
    indexNewUnits()
    if let found = constantRefs(owner + "::" + word) { return found }
    for ancestor in ancestors(owner).dropFirst() where ancestor != "Object" {
      if let found = constantRefs(ancestor + "::" + word) { return found }
    }
    if !followedProject {
      followedProject = true
      follow((0..<Int32(project.projectUnits)).map { $0 })
      if let found = constantRefs(owner + "::" + word) { return found }
    }
    loadStd()
    return constantRefs(owner + "::" + word) ?? []
  }

  /// The constant a path ending at `end` names (`A`, `A::B`, `::A`), from where it's written.
  func resolvePath(unitIndex: Int32, end: Int) -> [DeclRef] {
    let holder = project.units[Int(unitIndex)]
    guard holder.rbIsConstant(end) else { return [] }
    let word = holder.string(end)
    if holder.rbIsColon2(end - 1) {
      if holder.rbIsConstant(end - 2) {
        let owners = resolvePath(unitIndex: unitIndex, end: end - 2)
        guard let owner = owners.first, isNamespaceLike(owner) else { return [] }
        return scopedConstant(word, in: qualifiedName(owner))
      }
      // `::A`: the top level, unless `x::A` (a value's).
      if end - 2 >= 0, holder.touchesPrevious(end - 1), holder.rbIsValueEnd(end - 2) { return [] }
      indexNewUnits()
      if let found = constantRefs(word) { return found }
      loadStd()
      return constantRefs(word) ?? []
    }
    return lookupConstant(word, unitIndex: unitIndex, token: end)
  }

  func isNamespaceLike(_ ref: DeclRef) -> Bool { decl(ref).kind == .classType || decl(ref).kind == .namespace }

  /// The one opening of a class or module to answer: the project's, in the file named after it, else the first.
  func preferred(_ refs: [DeclRef]) -> [DeclRef] {
    guard refs.count > 1 else { return refs }
    // The project's own first, then Ruby's core, its standard library, and gems last: a gem reopening `Object` or
    // `Process`, or mimicking `JSON`, isn't where they're defined.
    let best = refs.map(tier).min()!
    let pool = refs.filter { tier($0) == best }
    guard pool.count > 1 else { return pool }
    if pool.contains(where: { decl($0).kind == .variable }) {
      // A constant assigned again: every assignment.
      return pool
    }
    let file = Self.snakeCase(qualifiedName(pool[0])) + ".rb"
    if let named = pool.first(where: { unit($0).path.hasSuffix("/" + file) }) { return [named] }
    let short = Self.snakeCase(unit(pool[0]).string(Int(decl(pool[0]).nameToken))) + ".rb"
    if let named = pool.first(where: { unit($0).path.hasSuffix("/" + short) }) { return [named] }
    return [pool[0]]
  }

  /// 0 the project's files, 1 the core stub, 2 the standard library, 3 a gem or another file outside the project.
  func tier(_ ref: DeclRef) -> Int {
    guard let module = project.modules[unit(ref).moduleName] else { return 0 }
    if module.displayName == RubyLayout.stdModule { return 1 }
    if module.isSDK { return 2 }
    return module.displayName.hasPrefix("/") ? 3 : 0
  }

  /// `ChannelRb::HTTPServer` → `channel_rb/http_server`.
  static func snakeCase(_ text: String) -> String {
    var result = ""
    let chars = Array(text.replacingOccurrences(of: "::", with: "/"))
    for (i, c) in chars.enumerated() {
      if c.isUppercase, i > 0, chars[i - 1] != "/" {
        let previousLower = chars[i - 1].isLowercase || chars[i - 1].isNumber
        let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
        if previousLower || (chars[i - 1].isUppercase && nextLower) { result.append("_") }
      }
      result.append(contentsOf: c.lowercased())
    }
    return result
  }

  /// The declaration standing for a class or module (its preferred opening), for types.
  func classRef(_ qualified: String) -> DeclRef? {
    indexNewUnits()
    var refs = constantRefs(qualified)
    if refs == nil {
      loadStd()
      refs = constantRefs(qualified)
    }
    guard let refs else { return nil }
    let classes = refs.filter(isNamespaceLike)
    return preferred(classes).first
  }

  // MARK: Ancestors

  /// What a class's or module's ranges after `class X <`, `include`, `extend` and `prepend` are.
  enum Inheritance { case superclass, include, extend, prepend }

  func inheritance(_ ref: DeclRef) -> [(Inheritance, Int32, Int32)] {
    let holder = unit(ref)
    let item = decl(ref)
    var result: [(Inheritance, Int32, Int32)] = []
    for r in 0..<Int(item.inheritCount) {
      let range = holder.ranges[Int(item.inheritStart) + r]
      var k = Int(range.start) - 1
      while k >= 0, holder.isByte(k, 0x2C) || holder.isByte(k, 0x28) || holder.rbIsColon2(k) || holder.rbIsConstant(k) { k -= 1 }
      let how: Inheritance
      if holder.isToken(k, "include") { how = .include } else if holder.isToken(k, "extend") { how = .extend } else if holder.isToken(k, "prepend") { how = .prepend } else { how = .superclass }
      result.append((how, range.start, range.end))
    }
    return result
  }

  /// The class or module a range names (`A::B`, `Struct.new(…)` is `Struct`), from where it's written.
  func rangeTarget(_ ref: DeclRef, _ start: Int32, _ end: Int32) -> String? {
    let holder = unit(ref)
    var last = Int(start)
    if holder.rbIsColon2(last) { last += 1 }
    while holder.rbIsColon2(last + 1), holder.rbIsConstant(last + 2), last + 2 < Int(end) { last += 2 }
    guard holder.rbIsConstant(last) else { return nil }
    // `< Base` followed by more than the path (`< Struct.new(…)`, `< Foo[x]`): only `Struct`/`Data` are read.
    if last + 1 < Int(end), !(holder.isToken(Int(start), "Struct") || holder.isToken(Int(start), "Data")) {
      if !(holder.rbIsDot(last + 1) && (holder.isToken(last + 2, "new") || holder.isToken(last + 2, "define"))) { return nil }
    }
    let found = resolvePath(unitIndex: ref.unit, end: last).filter(isNamespaceLike)
    guard let first = found.first else { return nil }
    let qualified = qualifiedName(first)
    return qualified
  }

  /// A class's or module's ancestors, as Ruby orders them, itself among them (qualified names).
  func ancestors(_ qualified: String) -> [String] {
    if let known = ancestorCache[qualified] { return known }
    guard building.insert(qualified).inserted else { return [qualified] }
    defer { building.remove(qualified) }
    indexNewUnits()
    var openings = (constantRefs(qualified) ?? []).filter(isNamespaceLike)
    if openings.isEmpty, ["Object", "BasicObject", "Kernel", "Module", "Class", "Comparable", "Enumerable"].contains(qualified) {
      loadStd()
      openings = (constantRefs(qualified) ?? []).filter(isNamespaceLike)
    }
    var prepends: [String] = []
    var includes: [String] = []
    var superclass: String?
    var isClass = false
    for opening in openings {
      if decl(opening).kind == .classType { isClass = true }
      for (how, start, end) in inheritance(opening) {
        guard let target = rangeTarget(opening, start, end), target != qualified else { continue }
        switch how {
        case .superclass: if superclass == nil { superclass = target }
        case .include: includes.append(target)
        case .prepend: prepends.append(target)
        case .extend: break
        }
      }
    }
    var result: [String] = []
    func add(_ list: [String]) {
      for item in list where !result.contains(item) { result.append(item) }
    }
    for item in prepends.reversed() { add(ancestors(item)) }
    result.append(qualified)
    for item in includes.reversed() { add(ancestors(item)) }
    if isClass, qualified != "BasicObject" {
      let parent = superclass ?? (qualified == "Object" ? "BasicObject" : "Object")
      if parent != qualified { add(ancestors(parent)) }
    }
    ancestorCache[qualified] = result
    return result
  }

  /// A class's or module's `extend`s.
  func extends(_ qualified: String) -> [String] {
    var result: [String] = []
    for opening in (constantRefs(qualified) ?? []).filter(isNamespaceLike) {
      for (how, start, end) in inheritance(opening) where how == .extend {
        if let target = rangeTarget(opening, start, end) { result.append(target) }
      }
    }
    return result
  }

  /// Where a class's own methods (`Foo.bar`) are looked up: each class's singleton side up its superclasses, with their
  /// extends, then `Class`, `Module`, `Object`'s instance methods. `(name, true)` is a singleton side.
  func singletonChain(_ qualified: String) -> [(String, Bool)] {
    var result: [(String, Bool)] = []
    let isClass = (constantRefs(qualified) ?? []).contains { decl($0).kind == .classType }
    let line = isClass ? ancestors(qualified).filter { q in (constantRefs(q) ?? []).contains { decl($0).kind == .classType } } : [qualified]
    for item in line {
      result.append((item, true))
      for module in extends(item).reversed() {
        for ancestor in ancestors(module) where !result.contains(where: { $0.0 == ancestor && !$0.1 }) { result.append((ancestor, false)) }
      }
    }
    for ancestor in ancestors(isClass ? "Class" : "Module") where !result.contains(where: { $0.0 == ancestor && !$0.1 }) { result.append((ancestor, false)) }
    return result
  }

  // MARK: Members

  /// A class's or module's own instance methods and attributes, over its openings.
  func instanceTable(_ qualified: String) -> [Name: DeclRef] {
    if let known = instanceTables[qualified] { return known }
    var table: [Name: DeclRef] = [:]
    let refs = (constantRefs(qualified) ?? []).filter(isNamespaceLike)
    for opening in refs.sorted(by: { (isSDK($0) ? 1 : 0, $0.unit, $0.decl) < (isSDK($1) ? 1 : 0, $1.unit, $1.decl) }) {
      let holder = unit(opening)
      for child in holder.children(of: opening.decl) {
        let item = holder.decls[Int(child)]
        guard item.kind == .function || item.kind == .initializer || item.kind == .variable && !item.isStatic, !item.isStatic, !item.isLocal else { continue }
        if table[item.name] == nil { table[item.name] = DeclRef(unit: opening.unit, decl: child) }
      }
    }
    if qualified == "Object" {
      // Methods at a file's level are Object's.
      for u in 0..<project.units.count {
        let holder = project.units[u]
        for (index, item) in holder.decls.enumerated() where item.parent < 0 && (item.kind == .function || item.kind == .initializer) && !item.isStatic {
          if table[item.name] == nil { table[item.name] = DeclRef(unit: Int32(u), decl: Int32(index)) }
        }
      }
    }
    instanceTables[qualified] = table
    return table
  }

  /// A class's or module's own singleton methods: `def self.x`, `class << self`, `module_function` and `extend self`.
  func staticTable(_ qualified: String) -> [Name: DeclRef] {
    if let known = staticTables[qualified] { return known }
    var table: [Name: DeclRef] = [:]
    let refs = (constantRefs(qualified) ?? []).filter(isNamespaceLike)
    var selfExtending = false
    for opening in refs {
      let holder = unit(opening)
      if structure(holder).selfExtending.contains(opening.decl) { selfExtending = true }
      for child in holder.children(of: opening.decl) {
        let item = holder.decls[Int(child)]
        if item.kind == .extensionDecl, item.isStatic {
          for inner in holder.children(of: child) {
            let member = holder.decls[Int(inner)]
            guard member.kind == .function || member.kind == .variable && !member.isStatic else { continue }
            if table[member.name] == nil { table[member.name] = DeclRef(unit: opening.unit, decl: inner) }
          }
          continue
        }
        guard item.isStatic, !item.isLocal, item.kind == .function || item.kind == .initializer else { continue }
        if table[item.name] == nil { table[item.name] = DeclRef(unit: opening.unit, decl: child) }
      }
    }
    if selfExtending {
      for (key, ref) in instanceTable(qualified) where table[key] == nil { table[key] = ref }
    }
    staticTables[qualified] = table
    return table
  }

  /// Whether a class's lookups end in its own `method_missing`.
  func hasMethodMissing(_ chain: [String]) -> Bool {
    let key = name("method_missing")
    for item in chain where !isStdClass(item) {
      if instanceTable(item)[key] != nil { return true }
    }
    return false
  }

  func isStdClass(_ qualified: String) -> Bool {
    guard let refs = constantRefs(qualified) else { return false }
    return refs.allSatisfy(isSDK)
  }

  /// A method or attribute of an instance of a class.
  func instanceMember(_ qualified: String, _ key: Name) -> DeclRef? {
    for item in ancestors(qualified) {
      if let found = instanceTable(item)[key] { return found }
    }
    return nil
  }

  /// A method of a class or module itself.
  func staticMember(_ qualified: String, _ key: Name) -> DeclRef? {
    for (item, isSingleton) in singletonChain(qualified) {
      if let found = (isSingleton ? staticTable(item) : instanceTable(item))[key] { return found }
    }
    return nil
  }

  /// A type's member by key: nil when the type can't be told or the member may be made at run time.
  func members(of ty: Ty, key: Name) -> [DeclRef]? {
    switch ty {
    case .nominal(let ref, _):
      let qualified = qualifiedName(ref)
      if let found = instanceMember(qualified, key) { return [found] }
      return nil
    case .meta(.nominal(let ref, _)):
      let qualified = qualifiedName(ref)
      if key == Self.newKey {
        // `Foo.new`: its `initialize`, unless it defines its own `self.new`.
        if let own = staticMember(qualified, key), !isSDK(own) { return [own] }
        if let found = instanceMember(qualified, Self.initializeKey) { return [found] }
      }
      if let found = staticMember(qualified, key) { return [found] }
      return nil
    case .constructed(let kind, let parts) where kind == Ty.union:
      var result: [DeclRef] = []
      for part in parts {
        guard let found = members(of: part, key: key) else { return nil }
        for ref in found where !result.contains(ref) { result.append(ref) }
      }
      return result.isEmpty ? nil : result
    default:
      return nil
    }
  }

  static let newKey = name("new"), initializeKey = name("initialize"), classKey = name("class")

  // MARK: Self

  enum SelfContext: Equatable {
    /// An instance of a class (in its methods), the class itself (in its body, `def self.x`), the program's main
    /// object (a file's top level), or something a block is evaluated on.
    case instance(String), singleton(String), main, unknown
  }

  /// Blocks that may run with another `self`, anywhere.
  static let evaluating: Set<String> = [
    "instance_eval", "instance_exec", "class_eval", "class_exec", "module_eval", "module_exec", "dsl_eval", "dsl_eval_immutable", "dsl_eval_with_block_return",
  ]

  /// Blocks at a class's or file's level that run where they're written (`each`, `loop`); others there are DSLs.
  static let keepingSelf: Set<String> = [
    "each", "each_with_index", "each_with_object", "each_pair", "each_key", "each_value", "each_slice", "each_cons", "each_char", "each_line", "map",
    "flat_map", "collect", "select", "filter", "reject", "filter_map", "times", "upto", "downto", "step", "loop", "tap", "then", "yield_self", "zip", "inject",
    "reduce", "sort_by", "group_by", "find", "detect", "any?", "all?", "none?", "count", "sum", "min_by", "max_by", "partition", "lambda", "proc", "at_exit",
    "catch", "fork", "trap", "synchronize", "open", "each_entry", "find_each", "sort", "uniq", "index", "find_index", "delete_if", "keep_if", "fetch",
    "transform_values", "transform_keys", "to_h", "sum", "chunk_while", "slice_when", "new",
  ]

  /// The call a block belongs to: its name's token and whether it has a receiver.
  func blockCall(_ holder: Unit, _ open: Int) -> (name: Int, hasReceiver: Bool)? {
    if holder.isByte(open, 0x7B) {
      var k = open - 1
      if holder.isByte(k, 0x29), let o = holder.matchingOpen(k) { k = o - 1 }
      guard holder.rbIsWord(k) else { return nil }
      return (k, holder.rbIsDot(k - 1) || holder.rbIsColon2(k - 1))
    }
    if holder.isToken(open, "->") { return nil }
    // `do`: the statement's call, as a command takes it (`describe X do`, `foo.each do`, `x = bar(1) do`).
    if holder.isByte(open - 1, 0x29), let o = holder.matchingOpen(open - 1), o > 0, holder.rbIsWord(o - 1), holder.touchesPrevious(o) {
      // `foo(1) do`: unless a command is around it (`expect(x).to receive(:y) do`).
      let start = holder.rbStatementStart(o - 1)
      if start == chainStart(holder, o - 1) { return (o - 1, holder.rbIsDot(o - 2) || holder.rbIsColon2(o - 2)) }
    }
    var k = holder.rbStatementStart(open)
    if holder.rbIsIdentifier(k), RubyBody.isAssignOperator(holder, k + 1) { k += 2 }
    if holder.isToken(k, "return") { k += 1 }
    let start = k
    while k + 2 < open {
      if holder.tokens[k + 1].kind == .open, holder.touchesPrevious(k + 1) {
        let after = holder.skipBalanced(k + 1)
        if holder.rbIsDot(after) || holder.rbIsColon2(after), holder.rbIsWord(after + 1) {
          k = after + 1
          continue
        }
        break
      }
      if holder.rbIsDot(k + 1) || holder.rbIsColon2(k + 1), holder.rbIsWord(k + 2) {
        k += 2
        continue
      }
      break
    }
    guard holder.rbIsWord(k) else { return nil }
    return (k, k > start)
  }

  /// The first token of a call chain ending at `end` (`a.b(1).c[2]`).
  func chainStart(_ holder: Unit, _ end: Int) -> Int {
    var k = end
    var budget = 400
    while k > 0, budget > 0 {
      budget -= 1
      let kind = holder.tokens[k].kind
      if kind == .close {
        guard let open = holder.matchingOpen(k) else { return k }
        if open > 0, holder.touchesPrevious(open), holder.rbIsValueEnd(open - 1), !holder.isByte(open, 0x7B) || holder.tokens[open - 1].kind != .keyword {
          k = open - 1
          continue
        }
        k = open
      }
      if holder.rbIsDot(k - 1) || holder.rbIsColon2(k - 1) && holder.touchesPrevious(k - 1) && holder.rbIsValueEnd(k - 2) {
        k -= 2
        continue
      }
      return k
    }
    return k
  }

  /// What `self` is at a token.
  func selfContext(unitIndex: Int32, token: Int) -> SelfContext {
    let holder = project.units[Int(unitIndex)]
    let shape = structure(holder)
    var index = shape.scope(at: Int32(token))
    var inMethod = false
    while index >= 0 {
      let scope = shape.scopes[Int(index)]
      switch scope.kind {
      case .file:
        return .main
      case .method:
        guard scope.decl >= 0 else { return .unknown }
        return methodSelf(unitIndex: unitIndex, method: scope.decl)
      case .classBody:
        guard scope.decl >= 0 else { return .unknown }
        let item = holder.decls[Int(scope.decl)]
        if item.kind == .extensionDecl {
          guard item.isStatic, let owner = owningClass(holder, item.parent) else { return .unknown }
          return .singleton(qualifiedName(DeclRef(unit: unitIndex, decl: owner)))
        }
        return .singleton(qualifiedName(DeclRef(unit: unitIndex, decl: scope.decl)))
      case .block, .lambda:
        if scope.decl >= 0 { return .singleton(qualifiedName(DeclRef(unit: unitIndex, decl: scope.decl))) }
        if scope.kind == .block, let call = blockCall(holder, Int(scope.open)) {
          let word = holder.string(call.name)
          if Self.evaluating.contains(word) { return .unknown }
          if word == "new", holder.isToken(call.name - 2, "Class") || holder.isToken(call.name - 2, "Module") || holder.isToken(call.name - 2, "Struct") || holder.isToken(call.name - 2, "Data") {
            return .unknown
          }
          if !inMethod, !isInMethod(shape, index), !Self.keepingSelf.contains(word) { return .unknown }
        }
        inMethod = inMethod || isInMethod(shape, index)
        index = scope.parent
        if index < 0 { return .main }
      }
    }
    return .main
  }

  private func isInMethod(_ shape: RubyStructure, _ index: Int32) -> Bool {
    var k = shape.scopes[Int(index)].parent
    while k >= 0 {
      let scope = shape.scopes[Int(k)]
      if scope.kind == .method { return true }
      if scope.kind == .classBody || scope.kind == .file { return false }
      k = scope.parent
    }
    return false
  }

  /// The class or module a declaration is directly in, past a singleton class.
  func owningClass(_ holder: Unit, _ start: Int32) -> Int32? {
    var parent = start
    while parent >= 0 {
      let kind = holder.decls[Int(parent)].kind
      if kind == .classType || kind == .namespace { return parent }
      if kind == .function || kind == .initializer { return nil }
      parent = holder.decls[Int(parent)].parent
    }
    return nil
  }

  /// `self` in a method: an instance of its class, the class for `def self.x` and in `class << self`; the main object
  /// for a method at a file's level.
  func methodSelf(unitIndex: Int32, method: Int32) -> SelfContext {
    let holder = project.units[Int(unitIndex)]
    let item = holder.decls[Int(method)]
    // `def obj.x`: another object's.
    if item.isLocal { return .unknown }
    if item.parent < 0 { return .main }
    let parent = holder.decls[Int(item.parent)]
    if parent.kind == .extensionDecl {
      guard parent.isStatic, let owner = owningClass(holder, parent.parent) else { return .unknown }
      return .singleton(qualifiedName(DeclRef(unit: unitIndex, decl: owner)))
    }
    guard let owner = owningClass(holder, item.parent) else { return .unknown }
    let qualified = qualifiedName(DeclRef(unit: unitIndex, decl: owner))
    return item.isStatic ? .singleton(qualified) : .instance(qualified)
  }

  func selfType(_ context: SelfContext) -> Ty {
    switch context {
    case .instance(let q): return classRef(q).map { .nominal($0, []) } ?? .unknown
    case .singleton(let q): return classRef(q).map { .meta(.nominal($0, [])) } ?? .unknown
    case .main: return classRef("Object").map { .nominal($0, []) } ?? .unknown
    case .unknown: return .unknown
    }
  }

  // MARK: Asking

  public func answer(path: String, line: Int, character: Int) -> Answer {
    guard let unitIndex = project.unitByPath[path] else { return Self.unknown }
    let unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    guard let token = unit.token(at: offset) else { return Self.unknown }
    return answer(unitIndex: unitIndex, token: token)
  }

  package func answer(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    guard token >= 0, token < unit.tokens.count else { return Self.unknown }
    let kind = unit.tokens[token].kind
    if kind == .string { return stringAnswer(unitIndex: unitIndex, token: token) }
    guard kind == .identifier || kind == .keyword || kind == .declarationKeyword else { return Self.unknown }
    if let site = unit.declaredSite(at: token, unitIndex: unitIndex) { return Answer(state: .exact, sites: [site]) }
    if kind != .identifier {
      if unit.isToken(token, "self") {
        guard case .nominal(let ref, _) = selfType(selfContext(unitIndex: unitIndex, token: token)).metaInner, !isMain(unitIndex, token) else { return Self.unknown }
        return Answer(state: .exact, sites: [.decl(ref)])
      }
      if unit.isToken(token, "super") { return superAnswer(unitIndex: unitIndex, token: token) }
      return Self.unknown
    }
    if unit.rbIsIvar(token) { return variableAnswer(unitIndex: unitIndex, token: token, kind: .instance) }
    if unit.rbIsCvar(token) { return variableAnswer(unitIndex: unitIndex, token: token, kind: .classLevel) }
    if unit.rbIsGlobal(token) { return variableAnswer(unitIndex: unitIndex, token: token, kind: .global) }
    let word = unit.string(token)
    // `foo.bar`, `foo&.bar`, `Foo::bar`.
    if unit.rbIsDot(token - 1) || unit.rbIsColon2(token - 1) && !unit.rbIsConstant(token) && token >= 2 && unit.rbIsValueEnd(token - 2) {
      let receiver = expressionType(unitIndex: unitIndex, end: token - 2)
      return memberAnswer(receiver, key: methodKey(unit, token, word), unitIndex: unitIndex)
    }
    if unit.rbIsConstant(token) {
      // `Integer("1")`: Kernel's method.
      if unit.isByte(token + 1, 0x28), unit.touchesPrevious(token + 1), !unit.rbIsColon2(token - 1) {
        return receiverless(unitIndex: unitIndex, token: token, key: name(word))
      }
      return summarize(preferred(resolvePath(unitIndex: unitIndex, end: token)).map { .decl($0) })
    }
    let locals = body(unitIndex)
    if let definition = locals.definition[Int32(token)] { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: definition)]) }
    // `name: value` in a call: a keyword parameter of what's called.
    if unit.isByte(token + 1, 0x3A), unit.touchesPrevious(token + 1), !unit.rbIsColon2(token + 1) {
      return keywordArgument(unitIndex: unitIndex, token: token)
    }
    // `alias new old`, `alias_method :new, :old`: the old method.
    if unit.isToken(token - 2, "alias"), let found = aliasTarget(unitIndex: unitIndex, token: token) { return found }
    return receiverless(unitIndex: unitIndex, token: token, key: methodKey(unit, token, word))
  }

  /// A file's top level, where `self` is the main object.
  private func isMain(_ unitIndex: Int32, _ token: Int) -> Bool { selfContext(unitIndex: unitIndex, token: token) == .main }

  /// A method's key at a call: `x=` for `recv.x = v` (not `==`, not `x += 1`).
  func methodKey(_ holder: Unit, _ token: Int, _ word: String) -> Name {
    if holder.isToken(token + 1, "="), holder.rbIsDot(token - 1) { return name(word + "=") }
    return name(word)
  }

  /// A call on `self` without a receiver: its class's (or the main object's) method; by name when `self` isn't known.
  func receiverless(unitIndex: Int32, token: Int, key: Name) -> Answer {
    let context = selfContext(unitIndex: unitIndex, token: token)
    let ty = selfType(context)
    if ty != .unknown, let found = members(of: ty, key: key) { return summarize(found.map { .decl($0) }) }
    if context == .main || ty != .unknown, let found = members(of: selfType(.main), key: key), !found.isEmpty {
      // Kernel's methods (`puts`, `require`) and the file-level methods are everyone's.
      return summarize(found.map { .decl($0) })
    }
    return byName(key, unitIndex: unitIndex)
  }

  /// `recv.name`: the receiver's member; by name when the receiver's type is unknown.
  func memberAnswer(_ receiver: Ty, key: Name, unitIndex: Int32) -> Answer {
    if let found = members(of: receiver, key: key) { return summarize(found.map { .decl($0) }) }
    if receiver == .unknown { return byName(key, unitIndex: unitIndex) }
    return Self.unknown
  }

  /// The project's methods of a name, as candidates, when what's called on can't be told.
  func byName(_ key: Name, unitIndex: Int32) -> Answer {
    let found = project.membersNamed(key).filter {
      let item = decl($0)
      return item.kind == .function || item.kind == .initializer || item.kind == .variable && !item.isStatic
    }
    guard !found.isEmpty else { return Self.unknown }
    return Answer(state: .candidates, sites: found.prefix(12).map { .decl($0) }, byNameOnly: true)
  }

  /// `super`: the method of the same name next in the ancestors.
  private func superAnswer(unitIndex: Int32, token: Int) -> Answer {
    let holder = project.units[Int(unitIndex)]
    let shape = structure(holder)
    var index = shape.scope(at: Int32(token))
    while index > 0, shape.scopes[Int(index)].kind != .method { index = shape.scopes[Int(index)].parent }
    guard index > 0, shape.scopes[Int(index)].decl >= 0 else { return Self.unknown }
    let method = shape.scopes[Int(index)].decl
    let key = holder.decls[Int(method)].name
    switch methodSelf(unitIndex: unitIndex, method: method) {
    case .instance(let q):
      guard (constantRefs(q) ?? []).contains(where: { decl($0).kind == .classType }) else { return Self.unknown }
      for item in ancestors(q).dropFirst(ancestors(q).firstIndex(of: q).map { $0 + 1 } ?? 1) {
        if let found = instanceTable(item)[key] { return Answer(state: .exact, sites: [.decl(found)]) }
      }
    case .singleton(let q):
      let chain = singletonChain(q)
      for (item, isSingleton) in chain.dropFirst() {
        if let found = (isSingleton ? staticTable(item) : instanceTable(item))[key] { return Answer(state: .exact, sites: [.decl(found)]) }
      }
    default:
      break
    }
    return Self.unknown
  }

  /// The old name of an alias: a method of the class around.
  private func aliasTarget(unitIndex: Int32, token: Int) -> Answer? {
    let holder = project.units[Int(unitIndex)]
    let word = holder.rbLiteral(token) ?? holder.string(token)
    return receiverlessMember(unitIndex: unitIndex, token: token, key: name(word))
  }

  private func receiverlessMember(unitIndex: Int32, token: Int, key: Name) -> Answer? {
    // An alias in a class body names an instance method.
    switch selfContext(unitIndex: unitIndex, token: token) {
    case .singleton(let q):
      let holder = project.units[Int(unitIndex)]
      let inSingleton = holder.chain(at: Int32(token)).contains { holder.decls[Int($0)].kind == .extensionDecl }
      let found = inSingleton ? staticMember(q, key) : instanceMember(q, key)
      return found.map { Answer(state: .exact, sites: [.decl($0)]) } ?? Self.unknown
    default:
      return nil
    }
  }

  /// A symbol or a string: a method named in `alias_method`, a file `require` names.
  private func stringAnswer(unitIndex: Int32, token: Int) -> Answer {
    let holder = project.units[Int(unitIndex)]
    if let site = holder.declaredSite(at: token, unitIndex: unitIndex) { return Answer(state: .exact, sites: [site]) }
    if holder.rbIsSymbol(token) {
      // `alias_method :new, :old`, `alias :new :old`.
      var k = token - 1
      if holder.isByte(k, 0x2C) { k -= 1 }
      if holder.rbIsSymbol(k), holder.isToken(k - 1, "alias_method") || holder.isByte(k - 1, 0x28) && holder.isToken(k - 2, "alias_method") || holder.isToken(k - 1, "alias") {
        return receiverlessMember(unitIndex: unitIndex, token: token, key: name(holder.rbLiteral(token) ?? "")) ?? Self.unknown
      }
      return Self.unknown
    }
    for item in holder.imports where Int(item.token) == token {
      guard item.member != RubyImport.loadPath, let path = requiredFile(item, of: holder), let target = load(path) else { return Self.unknown }
      return Answer(state: .exact, sites: [.file(target)])
    }
    return Self.unknown
  }

  // MARK: Variables

  enum VariableKind { case instance, classLevel, global }

  /// `@x`: the first assignment in its class (instance or class level), else in an ancestor; `@@x` in the class or an
  /// ancestor; `$x` anywhere, else Ruby's own.
  private func variableAnswer(unitIndex: Int32, token: Int, kind: VariableKind) -> Answer {
    let holder = project.units[Int(unitIndex)]
    let key = holder.hash(token)
    indexVariables()
    for owner in variableOwners(unitIndex: unitIndex, token: token, kind: kind) {
      if let found = variableDefs[owner]?[key] { return Answer(state: .exact, sites: [found.site]) }
    }
    if kind == .global, let site = stdGlobal(holder.string(token)) { return Answer(state: .exact, sites: [site]) }
    return Self.unknown
  }

  /// Where a variable at a token is looked up, nearest first.
  func variableOwners(unitIndex: Int32, token: Int, kind: VariableKind) -> [String] {
    switch kind {
    case .global:
      return ["$"]
    case .instance:
      switch selfContext(unitIndex: unitIndex, token: token) {
      case .instance(let q): return ancestors(q)
      case .singleton(let q): return ["#" + q]
      case .main: return ["main"]
      case .unknown: return []
      }
    case .classLevel:
      let holder = project.units[Int(unitIndex)]
      guard let owner = holder.chain(at: Int32(token)).last(where: { holder.decls[Int($0)].kind == .classType || holder.decls[Int($0)].kind == .namespace }) else { return [] }
      return ancestors(qualifiedName(DeclRef(unit: unitIndex, decl: owner))).map { "@@" + $0 }
    }
  }

  /// The owner of a variable's assignment at a token, as `variableOwners` names it.
  private func assignmentOwner(unitIndex: Int32, token: Int) -> String? {
    let holder = project.units[Int(unitIndex)]
    if holder.rbIsGlobal(token) { return "$" }
    if holder.rbIsCvar(token) {
      guard let owner = holder.chain(at: Int32(token)).last(where: { holder.decls[Int($0)].kind == .classType || holder.decls[Int($0)].kind == .namespace }) else { return nil }
      return "@@" + qualifiedName(DeclRef(unit: unitIndex, decl: owner))
    }
    switch selfContext(unitIndex: unitIndex, token: token) {
    case .instance(let q): return q
    case .singleton(let q): return "#" + q
    case .main: return "main"
    case .unknown: return nil
    }
  }

  /// Every unit's variable assignments into `variableDefs`, the first by file path and position.
  func indexVariables() {
    indexNewUnits()
    while variablesIndexed < project.units.count {
      let u = Int32(variablesIndexed)
      variablesIndexed += 1
      let holder = project.units[Int(u)]
      if holder.isInterface { continue }
      for i in holder.tokens.indices where holder.tokens[i].kind == .identifier {
        let b = holder.rbFirst(i)
        guard b == 0x40 || b == 0x24, isVariableAssignment(holder, i), let owner = assignmentOwner(unitIndex: u, token: i) else { continue }
        let key = holder.hash(i)
        variableAssignments[owner, default: [:]][key, default: []].append((u, i))
        if let known = variableDefs[owner]?[key], (known.path, known.token) <= (holder.path, i) { continue }
        variableDefs[owner, default: [:]][key] = (holder.path, i, .local(unit: u, token: Int32(i)))
      }
    }
  }

  /// `@x = …`, `@x ||= …`, `@a, @b = …`.
  func isVariableAssignment(_ holder: Unit, _ i: Int) -> Bool {
    if RubyBody.isAssignOperator(holder, i + 1) { return true }
    if holder.isByte(i + 1, 0x2C) || holder.isByte(i - 1, 0x2C) || holder.punctuation(i - 1, madeOf: "*") {
      let start = holder.rbStatementStart(i)
      let end = holder.rbStatementEnd(start, limit: holder.tokens.count)
      var j = start
      while j < end {
        if holder.isToken(j, "=") { return j > i }
        if !(holder.rbIsIdentifier(j) || holder.isByte(j, 0x2C) || holder.punctuation(j, madeOf: "*") || holder.isByte(j, 0x28) || holder.isByte(j, 0x29)) { return false }
        j += 1
      }
    }
    if holder.isToken(i - 1, "=>") {
      // `rescue Error => @e`.
      var k = i - 2
      while k >= 0, !holder.startsLine(k + 1) || k == i - 2 {
        if holder.isToken(k, "rescue") { return true }
        k -= 1
      }
    }
    return false
  }

  /// `$stdout`, `$0`: the stub's assignment.
  func stdGlobal(_ word: String) -> Site? {
    guard let u = stdUnit else { return nil }
    let holder = project.units[Int(u)]
    for i in holder.tokens.indices where holder.rbIsGlobal(i) && holder.string(i) == word { return .local(unit: u, token: Int32(i)) }
    return nil
  }

  // MARK: Keyword arguments

  /// `call(name: value)`, `call name: value`: the keyword parameter of what's called.
  private func keywordArgument(unitIndex: Int32, token: Int) -> Answer {
    let holder = project.units[Int(unitIndex)]
    guard let callee = calleeOfArgument(holder, token) else { return Self.unknown }
    let key = holder.hash(token)
    var sites: [Site] = []
    for ref in callees(unitIndex: unitIndex, nameToken: callee) {
      let owner = unit(ref)
      let item = decl(ref)
      for p in 0..<Int(item.paramCount) {
        let param = owner.params[Int(item.paramStart) + p]
        // Keyword parameters only: `name:`.
        guard param.label == key, owner.isByte(Int(param.nameToken) + 1, 0x3A) else { continue }
        sites.append(.local(unit: ref.unit, token: param.nameToken))
      }
    }
    return summarize(sites)
  }

  /// The name of the call an argument at a token is in: `foo(` around it, or a command `foo a, b:` it's part of.
  func calleeOfArgument(_ holder: Unit, _ token: Int) -> Int? {
    var k = token - 1
    var depth = 0
    var budget = 2000
    while k >= 0, budget > 0 {
      budget -= 1
      let kind = holder.tokens[k].kind
      if kind == .close { depth += 1 } else if kind == .open {
        if depth == 0 {
          guard holder.isByte(k, 0x28), k > 0, holder.touchesPrevious(k), holder.rbIsWord(k - 1) else { return nil }
          return k - 1
        }
        depth -= 1
      } else if depth == 0 {
        if holder.isByte(k, 0x3B) || holder.startsLine(k + 1) && !holder.rbContinues(k) && k + 1 <= token && !holder.rbIsDot(k + 1) {
          // The statement's start: a command call `name args`.
          let first = k + 1
          return commandName(holder, first, token)
        }
      }
      k -= 1
    }
    if k < 0 { return commandName(holder, 0, token) }
    return nil
  }

  private func commandName(_ holder: Unit, _ first: Int, _ token: Int) -> Int? {
    var k = first
    if holder.isToken(k, "return") || holder.isToken(k, "super") && k + 1 < token { if holder.isToken(k, "super") { return k }; k += 1 }
    while k + 2 < token, holder.rbIsDot(k + 1) || holder.rbIsColon2(k + 1), holder.rbIsWord(k + 2) { k += 2 }
    guard holder.rbIsWord(k), k + 1 < token, !holder.startsLine(k + 1), !holder.isByte(k + 1, 0x28) || !holder.touchesPrevious(k + 1) else { return nil }
    return k
  }

  /// What a call's name calls: a method of the receiver or `self`, `initialize` for `new`, the next method for `super`.
  func callees(unitIndex: Int32, nameToken: Int) -> [DeclRef] {
    let holder = project.units[Int(unitIndex)]
    if holder.isToken(nameToken, "super") {
      let found = superAnswer(unitIndex: unitIndex, token: nameToken)
      return found.sites.compactMap { if case .decl(let ref) = $0 { return ref } else { return nil } }
    }
    let word = holder.string(nameToken)
    if holder.rbIsDot(nameToken - 1) {
      let receiver = expressionType(unitIndex: unitIndex, end: nameToken - 2)
      return members(of: receiver, key: name(word)) ?? []
    }
    let found = receiverless(unitIndex: unitIndex, token: nameToken, key: name(word))
    guard found.state == .exact else { return [] }
    return found.sites.compactMap { if case .decl(let ref) = $0 { return ref } else { return nil } }
  }

  // MARK: References

  public func references(of answer: Answer) -> [(path: String, line: Int)] {
    guard answer.state != .unknown, !answer.byNameOnly, let first = answer.sites.first else { return [] }
    var targets = Set(answer.sites)
    var names: Set<Name> = []
    var restrict: Int32?
    switch first {
    case .decl:
      for site in answer.sites {
        guard case .decl(let ref) = site else { continue }
        let item = decl(ref)
        var text = unit(ref).rbLiteral(Int(item.nameToken)) ?? unit(ref).string(Int(item.nameToken))
        if text.count > 1, text.hasSuffix("="), text.first.map({ $0.isLetter || $0 == "_" }) == true { text.removeLast() }
        names.insert(name(text))
        // A class's uses answer one of its openings; `initialize` is called as `new`.
        if Self.isConstant(item) {
          for other in constantRefs(qualifiedName(ref)) ?? [] { targets.insert(.decl(other)) }
        }
        if item.kind == .initializer { names.insert(Self.newKey) }
        // `attr_accessor :x`: its reader and writer are one declaration.
        if unit(ref).tokens[Int(item.nameToken)].kind == .string {
          for (index, other) in unit(ref).decls.enumerated() where other.nameToken == item.nameToken { targets.insert(.decl(DeclRef(unit: ref.unit, decl: Int32(index)))) }
        }
      }
    case .local(let unitIndex, let token), .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      // A required file is used by its requires, which aren't names.
      if token < 0 { return [] }
      names.insert(holder.hash(Int(token)))
      // A local is only seen in its file; a keyword parameter is named by callers anywhere, a variable with a sign too.
      if holder.rbIsPlain(Int(token)), !holder.isByte(Int(token) + 1, 0x3A) { restrict = unitIndex }
    case .module:
      return []
    }
    var found = project.references(named: names, in: restrict, landingOn: targets) { self.answer(unitIndex: $0, token: $1) }
    // A method named by a symbol (`attr_reader :x`) is used where it's declared too, which the search for words misses.
    for site in answer.sites {
      guard case .decl(let ref) = site, Int(ref.unit) < project.projectUnits, unit(ref).tokens[Int(decl(ref).nameToken)].kind == .string,
        let at = place(of: site), !found.contains(where: { $0.path == at.path && $0.line == at.line })
      else { continue }
      found.append(at)
    }
    return found
  }

  /// A place as `rbref.rb` names it: a path relative to the root (`../` outside it), `ruby:` for the stub.
  public func place(of site: Site) -> (path: String, line: Int)? {
    if site.fileUnit != nil { return project.place(of: site) }
    let holder: Unit
    let token: Int
    switch site {
    case .decl(let ref):
      holder = unit(ref)
      token = Int(decl(ref).nameToken)
    case .local(let u, let t), .generic(let u, let t):
      holder = project.units[Int(u)]
      token = Int(t)
    case .module:
      return nil
    }
    guard token >= 0, token < holder.tokens.count else { return nil }
    let line = holder.source.lines.line(of: holder.tokens[token].start) + 1
    if holder.isInterface { return ("ruby:core.rb", line) }
    return (project.rootRelative(holder.path), line)
  }
}

extension Ty {
  /// A class's type for its instances and itself alike.
  var metaInner: Ty {
    if case .meta(let inner) = self { return inner }
    return self
  }
}
