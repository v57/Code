import CodeModel
import CodeScan
import Foundation

/// Haskell's model: definitions, references, completion and details from source, on CodeModel's core. Each file is
/// read whole (`HaskellParser`): a local answers its binding, and a free name is looked up as GHC's renamer does, by
/// name alone — the module's own top level, then what its imports bring in (their lists, `hiding`, `qualified` and
/// `as`, the modules' export lists with `T(..)` and `module X` re-exports), then the implicit Prelude. One declaration
/// is exact, several are candidates, none is unknown. A class's method answers its declaration in the class, from a
/// use or from an instance's equation; a field answers its declaration from record syntax, a `C{..}` wildcard's names
/// and (with OverloadedRecordDot) `x.f`, the last by name. Types aren't inferred: nothing here needs them.
public final class HaskellModel: LanguageModel {
  public let project: Project
  let layout: HaskellLayout
  let syntax: HaskellSyntax

  struct Scope {
    var values: [Name: [DeclRef]] = [:]
    var types: [Name: [DeclRef]] = [:]

    subscript(_ namespace: HsNamespace) -> [Name: [DeclRef]] {
      get { namespace == .value ? values : types }
      set { if namespace == .value { values = newValue } else { types = newValue } }
    }

    mutating func add(_ refs: [DeclRef], _ key: Name, _ namespace: HsNamespace) {
      guard !refs.isEmpty else { return }
      var list = self[namespace][key] ?? []
      for ref in refs where !list.contains(ref) { list.append(ref) }
      self[namespace][key] = list
    }

    mutating func merge(_ other: Scope) {
      for (key, refs) in other.values { add(refs, key, .value) }
      for (key, refs) in other.types { add(refs, key, .type) }
    }
  }

  // Tables, dropped when a file's shape changes.
  private var moduleMap: [String: [Int32]]?
  private var exportCache: [Int32: Scope] = [:]
  private var exporting: Set<Int32> = []
  private var importCache: [Int64: Scope] = [:]
  /// References by the sites they land on, dropped when any file is read again.
  private var referenceCache: [[Site]: [(path: String, line: Int)]] = [:]
  private var cachedReferences = 0
  private var seenParses = -1

  init(project: Project) {
    self.project = project
    layout = project.layout as! HaskellLayout
    syntax = layout.syntax as! HaskellSyntax
    project.onShapeChange = { [weak self] in self?.dropTables() }
  }

  /// A Haskell project under `root`: its files, the stub's modules its imports name.
  public convenience init(root: String) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    self.init(project: Project(root: root, layout: HaskellLayout(root: root)))
  }

  private func dropTables() {
    moduleMap = nil
    exportCache.removeAll()
    importCache.removeAll()
  }

  func refresh() {
    let parsed = syntax.parses.value
    guard parsed != seenParses else { return }
    seenParses = parsed
    referenceCache.removeAll()
    cachedReferences = 0
  }

  static let unknown = Answer(state: .unknown, sites: [])

  func hsFile(_ unitIndex: Int32) -> HaskellFile? {
    guard unitIndex >= 0, Int(unitIndex) < project.units.count, let scan = project.units[Int(unitIndex)].scans[HaskellFile.key] else { return nil }
    return unsafeDowncast(scan, to: HaskellFile.self)
  }

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }

  func info(_ ref: DeclRef) -> HsDeclInfo? {
    guard let file = hsFile(ref.unit), Int(ref.decl) < file.info.count else { return nil }
    return file.info[Int(ref.decl)]
  }

  /// Types, classes and families live in the type namespace; the rest in the value one.
  func namespace(of ref: DeclRef) -> HsNamespace {
    switch info(ref)?.kind {
    case .data, .newtype, .typeSynonym, .typeFamily, .dataFamily, .classDecl, .associatedType: return .type
    default: return .value
    }
  }

  // MARK: Modules

  /// The project's files by the Haskell module each declares.
  private var modulesByName: [String: [Int32]] {
    if let known = moduleMap { return known }
    var map: [String: [Int32]] = [:]
    for u in 0..<project.projectUnits {
      guard let file = hsFile(Int32(u)) else { continue }
      map[file.moduleName, default: []].append(Int32(u))
    }
    moduleMap = map
    return map
  }

  /// The files of the module an import names: the project's (a `.hs` before its `.hs-boot`, the importer's own
  /// package first), else the stub's.
  func moduleUnits(_ moduleName: String, from unitIndex: Int32) -> [Int32] {
    if var picked = modulesByName[moduleName] {
      let full = picked.filter { !project.units[Int($0)].path.hasSuffix(".hs-boot") }
      if !full.isEmpty { picked = full }
      if picked.count > 1 {
        let package = layout.package(of: project.units[Int(unitIndex)].path)
        let same = picked.filter { layout.package(of: project.units[Int($0)].path) == package }
        if !same.isEmpty { picked = same }
      }
      return picked
    }
    guard moduleName != "Main", let module = project.ensureModule(name(moduleName), display: moduleName) else { return [] }
    return module.units
  }

  /// Every module name a file could import: the project's and the stub's.
  func moduleNames() -> [String] {
    Array(Set(modulesByName.keys).union(HaskellStd.modules.keys)).filter { $0 != "Main" }.sorted()
  }

  func ownTop(_ unitIndex: Int32) -> Scope {
    var scope = Scope()
    guard let file = hsFile(unitIndex) else { return scope }
    for (key, decls) in file.topValues { scope.values[key] = decls.map { DeclRef(unit: unitIndex, decl: $0) } }
    for (key, decls) in file.topTypes { scope.types[key] = decls.map { DeclRef(unit: unitIndex, decl: $0) } }
    return scope
  }

  /// A type's or class's constructors, fields, methods and associated types.
  func children(_ ref: DeclRef) -> [DeclRef] {
    unit(ref).children(of: ref.decl).map { DeclRef(unit: ref.unit, decl: $0) }
  }

  /// What a module exports: its export list read in its own scope, else everything it declares.
  func exports(_ unitIndex: Int32) -> Scope {
    if let known = exportCache[unitIndex] { return known }
    guard exporting.insert(unitIndex).inserted, let file = hsFile(unitIndex) else { return Scope() }
    defer { exporting.remove(unitIndex) }
    guard let items = file.exports else {
      let scope = ownTop(unitIndex)
      exportCache[unitIndex] = scope
      return scope
    }
    var scope = Scope()
    for item in items {
      if let moduleName = item.module {
        // `module X`: what's in scope both as `e` and as `X.e`.
        if moduleName == file.moduleName { scope.merge(ownTop(unitIndex)) }
        for (index, entry) in file.imports.enumerated() where !entry.isQualified && (entry.alias ?? entry.module) == moduleName {
          scope.merge(importScope(unitIndex, index))
        }
        continue
      }
      var found: [DeclRef]
      if item.qualifier != 0 {
        found = lookupQualified(unitIndex, file.texts[item.qualifier] ?? "", item.name, item.namespace)
      } else {
        found = lookup(unitIndex, item.name, item.namespace)
      }
      var namespace = item.namespace
      if found.isEmpty, namespace == .type {
        // A pattern synonym's or constructor's name written alone.
        found = lookup(unitIndex, item.name, .value)
        namespace = .value
      }
      scope.add(found, item.name, namespace)
      addSubordinates(item.subs, of: found, into: &scope, from: nil)
    }
    exportCache[unitIndex] = scope
    return scope
  }

  /// `T(..)` and `T(a, b)`: the type's subordinates, those `available` has when given.
  private func addSubordinates(_ subs: HsItem.Subs, of parents: [DeclRef], into scope: inout Scope, from available: Scope?) {
    switch subs {
    case .none:
      return
    case .all:
      for parent in parents {
        for child in children(parent) {
          let key = decl(child).name
          let namespace = namespace(of: child)
          if let available, !(available[namespace][key]?.contains(child) ?? false) { continue }
          scope.add([child], key, namespace)
        }
      }
    case .some(let list):
      let wanted = Set(list.map(\.name))
      for parent in parents {
        for child in children(parent) where wanted.contains(decl(child).name) {
          scope.add([child], decl(child).name, namespace(of: child))
        }
      }
    }
  }

  /// What an import brings in.
  func importScope(_ unitIndex: Int32, _ index: Int) -> Scope {
    let key = Int64(unitIndex) << 32 | Int64(index)
    if let known = importCache[key] { return known }
    guard let file = hsFile(unitIndex), index < file.imports.count else { return Scope() }
    let entry = file.imports[index]
    var all = Scope()
    for target in moduleUnits(entry.module, from: unitIndex) where target != unitIndex { all.merge(exports(target)) }
    guard let items = entry.items else {
      importCache[key] = all
      return all
    }
    var result = Scope()
    if entry.isHiding {
      result = all
      for item in items {
        // Hiding `C` hides a constructor as well as a type or class.
        result.values[item.name] = nil
        if item.namespace == .type { result.types[item.name] = nil }
        if case .some(let list) = item.subs { for sub in list { result.values[sub.name] = nil } }
      }
    } else {
      for item in items {
        var namespace = item.namespace
        var found = all[namespace][item.name] ?? []
        if found.isEmpty, namespace == .type {
          found = all.values[item.name] ?? []
          namespace = .value
        }
        result.add(found, item.name, namespace)
        addSubordinates(item.subs, of: found, into: &result, from: all)
      }
    }
    importCache[key] = result
    return result
  }

  func implicitPrelude(_ file: HaskellFile) -> Bool {
    file.moduleName != "Prelude" && !file.importsPrelude && !file.extensions.contains("NoImplicitPrelude")
  }

  private func dedupe(_ refs: [DeclRef]) -> [DeclRef] {
    var unique: [DeclRef] = []
    for ref in refs where !unique.contains(ref) { unique.append(ref) }
    return unique
  }

  /// An unqualified name: the module's own top level, else its imports'.
  func lookup(_ unitIndex: Int32, _ key: Name, _ namespace: HsNamespace) -> [DeclRef] {
    guard let file = hsFile(unitIndex) else { return [] }
    let own = (namespace == .value ? file.topValues : file.topTypes)[key] ?? []
    if !own.isEmpty { return own.map { DeclRef(unit: unitIndex, decl: $0) } }
    var found: [DeclRef] = []
    for index in file.imports.indices where !file.imports[index].isQualified {
      found += importScope(unitIndex, index)[namespace][key] ?? []
    }
    if implicitPrelude(file) {
      for target in moduleUnits("Prelude", from: unitIndex) where target != unitIndex { found += exports(target)[namespace][key] ?? [] }
    }
    return dedupe(found)
  }

  /// `Q.x`: what the imports named `Q` (by `as`, else by module) bring in.
  func lookupQualified(_ unitIndex: Int32, _ qualifier: String, _ key: Name, _ namespace: HsNamespace) -> [DeclRef] {
    guard let file = hsFile(unitIndex) else { return [] }
    var found: [DeclRef] = []
    if qualifier == file.moduleName { found += ((namespace == .value ? file.topValues : file.topTypes)[key] ?? []).map { DeclRef(unit: unitIndex, decl: $0) } }
    for (index, entry) in file.imports.enumerated() where (entry.alias ?? entry.module) == qualifier {
      found += importScope(unitIndex, index)[namespace][key] ?? []
    }
    if qualifier == "Prelude", implicitPrelude(file) {
      for target in moduleUnits("Prelude", from: unitIndex) where target != unitIndex { found += exports(target)[namespace][key] ?? [] }
    }
    return dedupe(found)
  }

  /// The modules a qualifier names.
  func qualifierUnits(_ unitIndex: Int32, _ qualifier: String) -> [Int32] {
    guard let file = hsFile(unitIndex) else { return [] }
    var found: [Int32] = []
    if qualifier == file.moduleName { found.append(unitIndex) }
    for entry in file.imports where (entry.alias ?? entry.module) == qualifier {
      for target in moduleUnits(entry.module, from: unitIndex) where !found.contains(target) { found.append(target) }
    }
    if found.isEmpty, qualifier == "Prelude" { found = moduleUnits("Prelude", from: unitIndex) }
    return found
  }

  func moduleSite(_ unitIndex: Int32) -> Site {
    let token = hsFile(unitIndex).map { max(0, $0.moduleToken) } ?? 0
    return .local(unit: unitIndex, token: token)
  }

  static func answer(_ refs: [DeclRef]) -> Answer {
    guard !refs.isEmpty else { return unknown }
    return Answer(state: refs.count == 1 ? .exact : .candidates, sites: refs.map { .decl($0) })
  }

  // MARK: Asking

  public func answer(path: String, line: Int, character: Int) -> Answer {
    refresh()
    guard let unitIndex = project.unitByPath[path] else { return Self.unknown }
    let unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    guard let token = unit.token(at: offset) else { return Self.unknown }
    return answer(unitIndex: unitIndex, token: token)
  }

  package func answer(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    guard token >= 0, token < unit.tokens.count, let file = hsFile(unitIndex) else { return Self.unknown }
    if let site = unit.declaredSite(at: token, unitIndex: unitIndex) { return Answer(state: .exact, sites: [site]) }
    guard let use = file.uses[Int32(token)] else { return Self.unknown }
    let key = unit.hash(token)
    if let shadows = file.wildcardShadow[Int32(token)], let field = wildcardField(unitIndex, file, shadows, key) {
      return Answer(state: .exact, sites: [.decl(field)])
    }
    switch use {
    case .local(let def):
      return Answer(state: .exact, sites: [.local(unit: unitIndex, token: def)])
    case .free(let namespace):
      var found = lookup(unitIndex, key, namespace)
      if found.isEmpty, namespace == .type, file.extensions.contains("DataKinds") { found = lookup(unitIndex, key, .value) }
      return Self.answer(found)
    case .qualified(let qualifier, let namespace):
      return Self.answer(lookupQualified(unitIndex, file.texts[qualifier] ?? "", key, namespace))
    case .field:
      return fieldAnswer(lookup(unitIndex, key, .value), key)
    case .recordDot:
      return fieldAnswer(lookup(unitIndex, key, .value), key, byName: true)
    case .qualifier(let qualifier):
      let found = qualifierUnits(unitIndex, file.texts[qualifier] ?? "")
      return found.isEmpty ? Self.unknown : Answer(summarizing: found.map(moduleSite))
    case .module(let moduleName):
      // The module's own header names itself (two `Main`s are two files).
      if file.moduleToken >= 0, token >= Int(file.moduleToken), token < Int(file.moduleToken) + 2 * file.moduleName.split(separator: ".").count {
        return Answer(state: .exact, sites: [moduleSite(unitIndex)])
      }
      let found = moduleUnits(file.texts[moduleName] ?? "", from: unitIndex)
      return found.isEmpty ? Self.unknown : Answer(summarizing: found.map(moduleSite))
    case .method(let instance):
      guard Int(instance) < file.instances.count else { return Self.unknown }
      return Self.answer(methods(of: file.instances[Int(instance)], in: unitIndex, file, named: key))
    case .imported(let index, let namespace):
      guard Int(index) < file.imports.count else { return Self.unknown }
      let entry = file.imports[Int(index)]
      var all = Scope()
      for target in moduleUnits(entry.module, from: unitIndex) where target != unitIndex { all.merge(exports(target)) }
      var found = all[namespace][key] ?? []
      if found.isEmpty, namespace == .type { found = all.values[key] ?? [] }
      return Self.answer(found)
    case .importedSub(let index, let parentToken):
      guard Int(index) < file.imports.count else { return Self.unknown }
      let entry = file.imports[Int(index)]
      var all = Scope()
      for target in moduleUnits(entry.module, from: unitIndex) where target != unitIndex { all.merge(exports(target)) }
      let parents = all.types[unit.hash(Int(parentToken))] ?? []
      return Self.answer(parents.flatMap(children).filter { decl($0).name == key })
    case .exportedSub(let parentToken):
      let parents = lookup(unitIndex, unit.hash(Int(parentToken)), .type)
      return Self.answer(parents.flatMap(children).filter { decl($0).name == key })
    }
  }

  /// A record field's name: the fields among what the name finds; with OverloadedRecordDot (no type to tell the
  /// record by), every field of the name in scope, else the project's, as a guess.
  private func fieldAnswer(_ found: [DeclRef], _ key: Name, byName: Bool = false) -> Answer {
    let fields = found.filter { info($0)?.kind == .field }
    if byName {
      if fields.count == 1 { return Answer(state: .exact, sites: [.decl(fields[0])]) }
      var all = fields
      if all.isEmpty {
        for u in 0..<project.projectUnits {
          guard let file = hsFile(Int32(u)) else { continue }
          for index in file.topValues[key] ?? [] where file.info[Int(index)].kind == .field { all.append(DeclRef(unit: Int32(u), decl: index)) }
        }
      }
      guard !all.isEmpty else { return Self.unknown }
      return Answer(state: .candidates, sites: all.prefix(12).map { .decl($0) }, byNameOnly: all.count > 1)
    }
    return Self.answer(fields.isEmpty ? found : fields)
  }

  /// A name a `C{..}` binds: the constructor's field.
  private func wildcardField(_ unitIndex: Int32, _ file: HaskellFile, _ shadows: [Int32], _ key: Name) -> DeclRef? {
    let unit = project.units[Int(unitIndex)]
    for index in shadows where Int(index) < file.wildcards.count {
      let wildcard = file.wildcards[Int(index)]
      let constructorName = unit.hash(Int(wildcard.token))
      let constructors =
        wildcard.qualifier != 0
        ? lookupQualified(unitIndex, file.texts[wildcard.qualifier] ?? "", constructorName, .value) : lookup(unitIndex, constructorName, .value)
      for constructor in constructors {
        guard let holder = hsFile(constructor.unit) else { continue }
        for field in holder.constructorFields[constructor.decl] ?? [] where project.units[Int(constructor.unit)].decls[Int(field)].name == key {
          return DeclRef(unit: constructor.unit, decl: field)
        }
      }
    }
    return nil
  }

  /// An instance's method: the class's declaration of it.
  func methods(of instance: HsInstance, in unitIndex: Int32, _ file: HaskellFile, named key: Name) -> [DeclRef] {
    let unit = project.units[Int(unitIndex)]
    let className = unit.hash(Int(instance.classToken))
    let classes =
      instance.qualifier != 0 ? lookupQualified(unitIndex, file.texts[instance.qualifier] ?? "", className, .type) : lookup(unitIndex, className, .type)
    return classes.filter { info($0)?.kind == .classDecl }.flatMap(children).filter { decl($0).name == key && info($0)?.kind == .method }
  }

  // MARK: References

  public func references(of answer: Answer) -> [(path: String, line: Int)] {
    refresh()
    guard answer.state != .unknown, !answer.byNameOnly, let first = answer.sites.first else { return [] }
    if let known = referenceCache[answer.sites] { return known }
    let targets = Set(answer.sites)
    var names: Set<Name> = []
    var restrict: Int32?
    switch first {
    case .decl:
      for site in answer.sites {
        if case .decl(let ref) = site { names.insert(decl(ref).name) }
      }
    case .local(let unitIndex, let token):
      names.insert(project.units[Int(unitIndex)].hash(Int(token)))
      if hsFile(unitIndex)?.locals[token] != nil {
        // A local is its file's.
        restrict = unitIndex
      } else if let moduleName = hsFile(unitIndex)?.moduleName {
        // A module is named by any word of its name, and by the aliases its imports give it.
        for word in moduleName.split(separator: ".") { names.insert(name(String(word))) }
        for u in 0..<project.projectUnits {
          for entry in hsFile(Int32(u))?.imports ?? [] where entry.module == moduleName {
            for word in (entry.alias ?? "").split(separator: ".") { names.insert(name(String(word))) }
          }
        }
      }
    case .generic, .module:
      return []
    }
    let found = project.references(named: names, in: restrict, landingOn: targets, operators: true) { self.answer(unitIndex: $0, token: $1) }
    cachedReferences += found.count
    if cachedReferences > 100_000 {
      referenceCache.removeAll()
      cachedReferences = found.count
    }
    referenceCache[answer.sites] = found
    return found
  }

  /// A place as `hsref.py` names it: a path relative to the root; the stub's as `std:<Module>` with its line there.
  public func place(of site: Site) -> (path: String, line: Int)? {
    let holder: Unit
    let token: Int
    let unitIndex: Int32
    switch site {
    case .decl(let ref):
      unitIndex = ref.unit
      holder = unit(ref)
      token = Int(decl(ref).nameToken)
    case .local(let index, let at):
      unitIndex = index
      holder = project.units[Int(index)]
      token = Int(at)
    case .generic, .module:
      return nil
    }
    guard token >= 0, token < holder.tokens.count else { return nil }
    let line = holder.source.lines.line(of: holder.tokens[token].start) + 1
    if holder.isInterface { return ("std:" + (hsFile(unitIndex)?.moduleName ?? "?"), line) }
    return (project.rootRelative(holder.path), line)
  }
}
