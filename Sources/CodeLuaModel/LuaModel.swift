import CodeModel
import CodeScan
import Foundation

/// Lua's model: definitions, references, completion and details from source, on CodeModel's core. Each file is read
/// whole (`LuaParser`), resolving names as Lua scopes them: a local answers its declaration, a free name is a global
/// and answers every place the program assigns it (else the standard library's stub). A field answers every place it's
/// assigned on the same table: tables are known by where they're made (a constructor), through locals and globals,
/// `require` (the module's returned value), functions' returns, `setmetatable` and `__index` (classes), `self` in a
/// method, and LuaLS's `---@class`, `---@type`, `---@param` and `---@return`. A table no one makes (a host's `game`,
/// `vim`, `love`) is known by its path, so what the program assigns on it is found and the rest is unknown; a value
/// whose table can't be told answers fields by name, as candidates.
public final class LuaModel: LanguageModel {
  public let project: Project
  let layout: LuaLayout
  let syntax: LuaSyntax
  // Types, dropped when any file is read again.
  var exprTypes: [Int64: LuaType] = [:]
  var resolving: Set<Int64> = []
  var depth = 0
  var localTypes: [Int64: LuaType] = [:]
  var resolvingLocals: Set<Int64> = []
  var globalTypes: [Name: LuaType] = [:]
  var resolvingGlobals: Set<Name> = []
  var owners: [DeclRef: LuaType] = [:]
  var classOwners: [LuaType: [String]]?
  var buildingClassOwners = false
  var fieldsByOwner: [LuaType: [DeclRef]]?
  /// References by the sites they land on: every use of a name asks the same.
  var referenceCache: [[Site]: [(path: String, line: Int)]] = [:]
  var cachedReferences = 0
  // Tables of the files read, each file's part taken out and put back when its text changes.
  var annotationCache: [Int32: [Int32: LuaAnnotations]] = [:]
  /// The first `---@class` of each name, by file order.
  var classes: [String: LuaClass] = [:]
  /// Every `---@class` of each name, by file order.
  var classDefinitions: [String: [LuaClass]] = [:]
  var classesIndexed = 0
  /// Fields assigned on a value (`a.b = …`, `function a:b()`), by name.
  var fieldWrites: [Name: [DeclRef]] = [:]
  /// Constructor keys by their table and name.
  var keys: [TableKey: [DeclRef]] = [:]
  /// Every constructor's keys, for completion.
  var keysOfTable: [TableKey: [DeclRef]] = [:]
  /// Global assignments by name.
  var globalWrites: [Name: [DeclRef]] = [:]
  var fieldsIndexed = 0
  /// What each file put in the tables above, to take it out again.
  private var indexedNames: [Int32: (fields: [Name], globals: [Name], tables: [TableKey])] = [:]
  var indexedClasses: [Int32: [String]] = [:]
  private var seenParses = 0
  /// The files the tables were built from.
  private var seenUnits: [Unit] = []
  private var loadedStd = false
  static let indexName = name("__index")
  static let stringName = name("string")

  struct TableKey: Hashable {
    var unit: Int32
    var brace: Int32
    var name: Name
  }

  init(project: Project) {
    self.project = project
    layout = project.layout as! LuaLayout
    syntax = layout.syntax as! LuaSyntax
    // A declaration's shape changing is a re-parse too: `refresh()` puts that file's part back.
  }

  /// A Lua project under `root`: its files, the files its requires reach, the standard library's stub.
  public convenience init(root: String) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    self.init(project: Project(root: root, layout: LuaLayout(root: root)))
  }

  private func dropTypes() {
    exprTypes.removeAll()
    localTypes.removeAll()
    globalTypes.removeAll()
    owners.removeAll()
    classOwners = nil
    fieldsByOwner = nil
    referenceCache.removeAll()
    cachedReferences = 0
  }

  /// Answers cached for a file's tokens go stale when the file is read again, even when no other file's view of it
  /// changed (the core's shape): any parse drops the types, and a file read again has its part of the tables
  /// taken out and put back, in file order, as a full rebuild would have them.
  func refresh() {
    let parsed = syntax.parses.value
    guard parsed != seenParses || project.units.count != seenUnits.count else { return }
    seenParses = parsed
    dropTypes()
    for index in seenUnits.indices where project.units[index] !== seenUnits[index] {
      let unitIndex = Int32(index)
      annotationCache[unitIndex] = nil
      if index < fieldsIndexed {
        unindexFields(unitIndex)
        indexFields(of: unitIndex)
      }
      if index < classesIndexed {
        unindexClasses(unitIndex)
        indexClasses(of: unitIndex)
      }
      seenUnits[index] = project.units[index]
    }
    seenUnits.append(contentsOf: project.units[seenUnits.count...])
  }

  static let unknown = Answer(state: .unknown, sites: [])

  func luaFile(_ unitIndex: Int32) -> LuaFile? {
    guard unitIndex >= 0, Int(unitIndex) < project.units.count, let scan = project.units[Int(unitIndex)].scans[LuaFile.key] else { return nil }
    return unsafeDowncast(scan, to: LuaFile.self)
  }

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }

  func field(_ ref: DeclRef) -> LuaField? {
    guard let file = luaFile(ref.unit), Int(ref.decl) < file.fields.count else { return nil }
    return file.fields[Int(ref.decl)]
  }

  func isGlobalWrite(_ ref: DeclRef) -> Bool {
    guard let item = field(ref) else { return false }
    return item.owner < 0 && item.table < 0
  }

  // MARK: Files

  func loadStd() {
    guard !loadedStd else { return }
    loadedStd = true
    project.ensureModule(name(LuaLayout.stdModule), display: LuaLayout.stdModule)
  }

  var stdUnit: Int32? {
    loadStd()
    return project.modules[name(LuaLayout.stdModule)]?.units.first
  }

  func isStd(_ unitIndex: Int32) -> Bool { project.units[Int(unitIndex)].isInterface }

  /// The file a `require` string names, read when it's outside the project.
  func requiredUnit(_ unitIndex: Int32, _ stringToken: Int32) -> Int32? {
    guard let file = luaFile(unitIndex), let text = file.requireStrings[stringToken] else { return nil }
    let holder = project.units[Int(unitIndex)]
    guard let path = layout.resolve(require: text, from: holder.path) else { return nil }
    if let known = project.unitByPath[path] { return known }
    guard project.ensureModule(name(path), display: path) != nil else { return nil }
    return project.unitByPath[path]
  }

  /// The declarations of every file read so far, by what they assign.
  func indexFields() {
    loadStd()
    while fieldsIndexed < project.units.count {
      let unitIndex = Int32(fieldsIndexed)
      fieldsIndexed += 1
      indexFields(of: unitIndex)
    }
  }

  private func indexFields(of unitIndex: Int32) {
    guard let file = luaFile(unitIndex) else { return }
    let holder = project.units[Int(unitIndex)]
    var fields: [Name: [DeclRef]] = [:]
    var globals: [Name: [DeclRef]] = [:]
    var tables: [TableKey] = []
    for (index, item) in file.fields.enumerated() {
      let ref = DeclRef(unit: unitIndex, decl: Int32(index))
      let key = holder.decls[index].name
      if item.table >= 0 {
        let table = TableKey(unit: unitIndex, brace: item.table, name: key)
        let all = TableKey(unit: unitIndex, brace: item.table, name: 0)
        if keys[table] == nil { tables.append(table) }
        if keysOfTable[all] == nil { tables.append(all) }
        keys[table, default: []].append(ref)
        keysOfTable[all, default: []].append(ref)
      } else if item.owner >= 0 {
        fields[key, default: []].append(ref)
      } else {
        globals[key, default: []].append(ref)
      }
    }
    for (key, refs) in fields { Self.insert(refs, into: &fieldWrites[key, default: []]) }
    for (key, refs) in globals { Self.insert(refs, into: &globalWrites[key, default: []]) }
    indexedNames[unitIndex] = (Array(fields.keys), Array(globals.keys), tables)
  }

  private func unindexFields(_ unitIndex: Int32) {
    guard let names = indexedNames.removeValue(forKey: unitIndex) else { return }
    for key in names.fields {
      fieldWrites[key]?.removeAll { $0.unit == unitIndex }
      if fieldWrites[key]?.isEmpty == true { fieldWrites[key] = nil }
    }
    for key in names.globals {
      globalWrites[key]?.removeAll { $0.unit == unitIndex }
      if globalWrites[key]?.isEmpty == true { globalWrites[key] = nil }
    }
    for table in names.tables {
      keys[table] = nil
      keysOfTable[table] = nil
    }
  }

  /// One file's declarations put where a rebuild in file order would have them: after the earlier files'.
  private static func insert(_ refs: [DeclRef], into list: inout [DeclRef]) {
    let unitIndex = refs[0].unit
    var at = list.count
    while at > 0, list[at - 1].unit > unitIndex { at -= 1 }
    list.insert(contentsOf: refs, at: at)
  }

  /// A global's assignments: the program's, else the standard library's.
  func globalSites(_ word: Name) -> [DeclRef] {
    indexFields()
    let all = globalWrites[word] ?? []
    let own = all.filter { !isStd($0.unit) }
    return own.isEmpty ? all : own
  }

  /// The declarations assigning a field on one table (`owner`), from every file read.
  func writes(on owner: LuaType, _ key: Name) -> [DeclRef] {
    guard owner.isKnown else { return [] }
    indexFields()
    var found: [DeclRef] = []
    if case .table(let unitIndex, let brace) = owner { found = keys[TableKey(unit: unitIndex, brace: brace, name: key)] ?? [] }
    for ref in fieldWrites[key] ?? [] where ownerOf(ref) == owner { found.append(ref) }
    return found
  }

  /// The table a field's declaration assigns on.
  func ownerOf(_ ref: DeclRef) -> LuaType {
    if let known = owners[ref] { return known }
    guard let item = field(ref) else { return .unknown }
    var result = LuaType.unknown
    if item.table >= 0 {
      result = .table(ref.unit, item.table)
    } else if item.owner >= 0 {
      result = type(item.owner, ref.unit).owner ?? .unknown
    }
    owners[ref] = result
    return result
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
    guard token >= 0, token < unit.tokens.count, let file = luaFile(unitIndex) else { return Self.unknown }
    switch unit.tokens[token].kind {
    case .identifier: break
    case .string:
      // `require "a.b"`: the file; `t["name"] = …`: the field.
      if file.requireStrings[Int32(token)] != nil {
        guard let target = requiredUnit(unitIndex, Int32(token)) else { return Self.unknown }
        return Answer(state: .exact, sites: [.file(target)])
      }
      if let site = unit.declaredSite(at: token, unitIndex: unitIndex), case .decl(let ref) = site { return declAnswer(ref) }
      return Self.unknown
    default:
      return Self.unknown
    }
    guard let use = file.uses[Int32(token)] else { return Self.unknown }
    switch use {
    case .local(let def):
      return Answer(state: .exact, sites: [.local(unit: unitIndex, token: def)])
    case .label(let label):
      return Answer(state: .exact, sites: [.local(unit: unitIndex, token: label)])
    case .selfParameter(let function):
      // `self` in `function T:m()`: what `T` names.
      let owner = file.functions[Int(function)].owner
      guard owner >= 0 else { return Self.unknown }
      switch file.expr(owner) {
      case .name(let name), .field(_, let name): return answer(unitIndex: unitIndex, token: Int(name))
      default: return Self.unknown
      }
    case .global:
      let sites = globalSites(unit.hash(token))
      return sites.isEmpty ? Self.unknown : Answer(state: .exact, sites: sites.map { .decl($0) })
    case .field(let expr):
      guard case .field(let base, _) = file.expr(expr) else { return Self.unknown }
      return fieldAnswer(type(base, unitIndex), unit.hash(token))
    case .key(let brace):
      return fieldAnswer(.table(unitIndex, brace), unit.hash(token))
    }
  }

  /// A declaration's own name: every assignment of what it assigns.
  func declAnswer(_ ref: DeclRef) -> Answer {
    guard let item = field(ref) else { return Self.unknown }
    if item.table >= 0 { return fieldAnswer(.table(ref.unit, item.table), decl(ref).name) }
    if item.owner >= 0 { return fieldAnswer(type(item.owner, ref.unit), decl(ref).name) }
    return Answer(state: .exact, sites: globalSites(decl(ref).name).map { .decl($0) })
  }

  /// `value.key`: where the key is assigned on the value's tables; by name when the value can't be told.
  func fieldAnswer(_ base: LuaType, _ key: Name) -> Answer {
    guard base.isKnown else { return byName(key) }
    let sites = fieldSites(base, key)
    guard !sites.isEmpty else { return Self.unknown }
    let tables = Set(sites.map(ownerOf))
    var unique: [Site] = []
    for site in sites.map({ Site.decl($0) }) where !unique.contains(site) { unique.append(site) }
    // One table's field is one thing however often it's assigned; several tables' are a guess between them.
    return Answer(state: tables.count == 1 ? .exact : .candidates, sites: unique)
  }

  /// The project's fields of a name, as candidates.
  func byName(_ key: Name) -> Answer {
    indexFields()
    var found: [DeclRef] = []
    for ref in fieldWrites[key] ?? [] where Int(ref.unit) < project.projectUnits {
      found.append(ref)
      if found.count == 12 { break }
    }
    guard !found.isEmpty else { return Self.unknown }
    return Answer(state: .candidates, sites: found.map { .decl($0) }, byNameOnly: true)
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
      // A required file is used by its requires, which aren't names.
      guard token > 0 || token == 0 && luaFile(unitIndex)?.locals[0] != nil else { return [] }
      names.insert(project.units[Int(unitIndex)].hash(Int(token)))
      restrict = unitIndex
    case .generic, .module:
      return []
    }
    let found = project.references(named: names, in: restrict, landingOn: targets) { self.answer(unitIndex: $0, token: $1) }
    // Bounded: a run over every position of a big project asks for thousands, some of them long.
    cachedReferences += found.count
    if cachedReferences > 100_000 {
      referenceCache.removeAll()
      cachedReferences = found.count
    }
    referenceCache[answer.sites] = found
    return found
  }

  /// A place as `luaref.py` names it: a path relative to the root (`../` outside it); the stub's as
  /// `std:<name>` or `std:<library>.<name>`, line 0.
  public func place(of site: Site) -> (path: String, line: Int)? {
    switch site {
    case .decl(let ref):
      let holder = unit(ref)
      if holder.isInterface { return ("std:" + stdName(ref), 0) }
      let token = Int(decl(ref).nameToken)
      guard token >= 0, token < holder.tokens.count else { return nil }
      return (project.rootRelative(holder.path), holder.source.lines.line(of: holder.tokens[token].start) + 1)
    case .local(let unitIndex, let token):
      if token < 0 { return project.place(of: site) }
      let holder = project.units[Int(unitIndex)]
      guard Int(token) < holder.tokens.count else { return nil }
      return (project.rootRelative(holder.path), holder.source.lines.line(of: holder.tokens[Int(token)].start) + 1)
    case .generic, .module:
      return nil
    }
  }

  /// A stub declaration's name: `print`, `string.format`, `file.read`.
  func stdName(_ ref: DeclRef) -> String {
    let holder = unit(ref)
    let own = holder.string(Int(decl(ref).nameToken))
    guard let item = field(ref), item.owner >= 0, let file = luaFile(ref.unit), case .name(let owner) = file.expr(item.owner) else { return own }
    return holder.string(Int(owner)) + "." + own
  }
}

/// How many files Lua's syntax has read, across threads (`Project.parse` reads in parallel).
final class LuaCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}
