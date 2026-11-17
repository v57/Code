import CodeModel
import CodeScan
import Foundation

/// TypeScript's and JavaScript's model: definitions, references, completion and details from source, on CodeModel's
/// core. Each file is a module; names resolve as the checker resolves them (a body's locals, the namespaces around,
/// the file's declarations, its imports followed to what the other module exports, then the global scope: the lib
/// files, the type roots and the project's scripts), members through the receiver's type (classes and interfaces with
/// their bases and every declaration merged into them, object types and literals, unions), and an object literal's keys
/// through the type it's written for. Where a type can't be told, a member is answered by name as candidates.
public final class TSModel: LanguageModel {
  public let project: Project
  let layout: TSLayout
  var valueTypes: [DeclRef: Ty] = [:]
  var returnTypes: [DeclRef: Ty] = [:]
  var resolving: Set<DeclRef> = []
  var exportTables: [Name: [Name: [Site]]] = [:]
  var exporting: Set<Name> = []
  var globalTable: [Name: [DeclRef]]?
  var ambientTable: [String: [DeclRef]] = [:]
  var globalUnits: Set<Int32> = []
  /// Module augmentations (`declare module "m" { … }` in a module) by the module they add to.
  var augmentationTable: [Name: [DeclRef]]?
  var depth = 0

  public init(project: Project) {
    self.project = project
    layout = project.layout as! TSLayout
    project.onShapeChange = { [weak self] in
      guard let self else { return }
      self.valueTypes.removeAll()
      self.returnTypes.removeAll()
      self.exportTables.removeAll()
      self.globalTable = nil
      self.augmentationTable = nil
    }
  }

  /// A TypeScript or JavaScript project under `root`: its `tsconfig.json` (or `jsconfig.json`), its `node_modules`.
  public convenience init(root: String) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    self.init(project: Project(root: root, layout: TSLayout(root: root)))
  }

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }
  func file(_ unit: Unit) -> TSFile { unsafeDowncast(unit.scans[TSFile.key]!, to: TSFile.self) }

  /// A file's body scan, made once.
  func body(_ unitIndex: Int32) -> TSBody {
    let unit = project.units[Int(unitIndex)]
    let facts = file(unit)
    if let known = facts.body { return known }
    let scan = TSBody(unit: unit, file: facts)
    facts.body = scan
    return scan
  }

  // MARK: The global scope

  /// Everything declared globally: the lib files' and type roots' scripts, `declare global` blocks, the project's
  /// scripts (files without imports or exports).
  var globals: [Name: [DeclRef]] {
    if let known = globalTable { return known }
    project.ensureModule(name(TSLayout.globalModule), display: TSLayout.globalModule)
    var table: [Name: [DeclRef]] = [:]
    var ambient: [String: [DeclRef]] = [:]
    var global: Set<Int32> = []
    let globalPaths = Set(layout.globalFiles)
    for (u, unit) in project.units.enumerated() {
      let isGlobalSet = globalPaths.contains(unit.path)
      let isProject = u < project.projectUnits
      guard isGlobalSet || isProject else { continue }
      let facts = file(unit)
      let isScript = !facts.hasModuleSyntax
      if isScript { global.insert(Int32(u)) }
      for (index, item) in unit.decls.enumerated() where item.parent < 0 && !item.isLocal {
        let ref = DeclRef(unit: Int32(u), decl: Int32(index))
        if item.kind == .namespace, unit.tokens[Int(item.nameToken)].kind == .string {
          ambient[unit.tsStringValue(Int(item.nameToken)), default: []].append(ref)
          continue
        }
        if isScript, item.name != 0, !facts.exportOnly.contains(Int32(index)) { table[item.name, default: []].append(ref) }
      }
      for index in facts.assignedGlobals { table[unit.decls[Int(index)].name, default: []].append(DeclRef(unit: Int32(u), decl: index)) }
      for block in facts.globals {
        for child in unit.children(of: block) where unit.decls[Int(child)].name != 0 {
          table[unit.decls[Int(child)].name, default: []].append(DeclRef(unit: Int32(u), decl: child))
        }
      }
    }
    globalTable = table
    ambientTable = ambient
    globalUnits = global
    return table
  }

  /// A global declared as a type: `String`, `Array`, `Promise`.
  func globalType(_ word: Name, _ args: [Ty] = []) -> Ty {
    for ref in globals[word] ?? [] where decl(ref).kind == .protocolType || decl(ref).kind == .classType {
      return .nominal(ref, args)
    }
    return .unknown
  }

  /// Whether a declaration is in the global scope (merges with others of its name there).
  func isGlobal(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    if item.parent >= 0 {
      let parent = self.unit(ref).decls[Int(item.parent)]
      return parent.kind == .namespace && parent.name == TSWord.global && file(self.unit(ref)).globals.contains(item.parent)
    }
    _ = globals
    return globalUnits.contains(ref.unit) || file(self.unit(ref)).assignedGlobals.contains(ref.decl)
  }

  /// The declarations merged with one: interfaces, namespaces, a class and its interface, overloads, in one scope.
  func merged(_ ref: DeclRef) -> [DeclRef] {
    let item = decl(ref)
    guard item.name != 0, !item.isLocal else { return [ref] }
    if item.kind == .namespace, item.parent < 0, self.unit(ref).tokens[Int(item.nameToken)].kind == .string {
      return ambientModule(self.unit(ref).tsStringValue(Int(item.nameToken))).nonEmpty ?? [ref]
    }
    if isGlobal(ref) { return globals[item.name] ?? [ref] }
    if item.parent >= 0 {
      let holder = self.unit(ref)
      let parent = DeclRef(unit: ref.unit, decl: item.parent)
      // In a namespace: its other declarations' members of the name too.
      let holders = holder.decls[Int(item.parent)].kind == .namespace ? merged(parent) : [parent]
      var result: [DeclRef] = []
      for other in holders {
        let owner = self.unit(other)
        for child in owner.children(of: other.decl) where owner.decls[Int(child)].name == item.name && owner.decls[Int(child)].isStatic == item.isStatic {
          result.append(DeclRef(unit: other.unit, decl: child))
        }
      }
      return result.isEmpty ? [ref] : result
    }
    guard let module = project.modules[self.unit(ref).moduleName] else { return [ref] }
    let facts = file(self.unit(ref))
    var result = (module.top[item.name] ?? [ref]).filter { $0.unit == ref.unit && !facts.exportOnly.contains($0.decl) }
    for block in augmentations[module.name] ?? [] {
      let owner = self.unit(block)
      for child in owner.children(of: block.decl) where owner.decls[Int(child)].name == item.name { result.append(DeclRef(unit: block.unit, decl: child)) }
    }
    return result
  }

  /// `declare module "m" { … }` blocks in modules, by the module m resolves to from each.
  var augmentations: [Name: [DeclRef]] {
    if let known = augmentationTable { return known }
    _ = globals
    var table: [Name: [DeclRef]] = [:]
    for (_, blocks) in ambientTable {
      for block in blocks {
        let holder = self.unit(block)
        guard file(holder).hasModuleSyntax else { continue }
        let key = layout.resolve(holder.tsStringValue(Int(decl(block).nameToken)), from: holder.path)
        guard !key.hasPrefix("?") else { continue }
        table[name(key), default: []].append(block)
      }
    }
    augmentationTable = table
    return table
  }

  // MARK: Modules

  /// What a module exports by name: a file's exported declarations, its `export { … }`, `export =`, `export default` and
  /// re-exports, an ambient module's members.
  func exports(_ moduleName: Name) -> [Name: [Site]] {
    if let known = exportTables[moduleName] { return known }
    guard exporting.insert(moduleName).inserted else { return [:] }
    defer { exporting.remove(moduleName) }
    var table: [Name: [Site]] = [:]
    if let module = project.modules[moduleName], module.displayName != TSLayout.globalModule {
      for unitIndex in module.units { fileExports(unitIndex, into: &table) }
    }
    exportTables[moduleName] = table
    return table
  }

  /// An ambient module's declarations (`declare module "fs"`), from the global set.
  func ambientModule(_ specifier: String) -> [DeclRef] {
    _ = globals
    return ambientTable[specifier] ?? []
  }

  private func fileExports(_ unitIndex: Int32, into table: inout [Name: [Site]]) {
    let unit = project.units[Int(unitIndex)]
    let facts = file(unit)
    if !facts.hasModuleSyntax {
      for (index, item) in unit.decls.enumerated() where item.parent < 0 && !item.isLocal && item.name != 0 {
        table[item.name, default: []].append(.decl(DeclRef(unit: unitIndex, decl: Int32(index))))
      }
      return
    }
    for (index, item) in unit.decls.enumerated() where item.parent < 0 && !item.isLocal && item.name != 0 {
      guard item.access == .isPublic || facts.exportOnly.contains(Int32(index)) else { continue }
      if item.kind == .namespace, unit.tokens[Int(item.nameToken)].kind == .string { continue }
      table[item.name, default: []].append(.decl(DeclRef(unit: unitIndex, decl: Int32(index))))
    }
    scopeExports(unitIndex, parent: -1, into: &table)
  }

  /// The exports a scope (a file, -1, or an ambient module) writes as statements: specifiers, `export =`, re-exports.
  func scopeExports(_ unitIndex: Int32, parent: Int32, into table: inout [Name: [Site]]) {
    let unit = project.units[Int(unitIndex)]
    let facts = file(unit)
    let range: (Int32, Int32) = parent >= 0 ? (unit.decls[Int(parent)].first, unit.decls[Int(parent)].end) : (0, Int32(unit.tokens.count))
    for specifier in facts.exportSpecifiers where specifier.parent == parent {
      let found = parent >= 0
        ? unit.children(of: parent).filter { unit.decls[Int($0)].name == specifier.local }.map { Site.decl(DeclRef(unit: unitIndex, decl: $0)) }
        : topLevel(specifier.local, unitIndex: unitIndex, token: specifier.localToken)
      if !found.isEmpty { table[specifier.exported, default: []] += found }
    }
    for item in unit.imports where item.isExported && item.token >= range.0 && item.token < range.1 {
      if parent < 0, innermostNamespace(unit, token: item.token) != nil { continue }
      if item.member == 0, item.alias == 0 {
        for (word, sites) in moduleExports(of: item) where word != TSWord.defaultName && table[word] == nil { table[word] = sites }
      } else if item.member == 0 {
        table[item.alias, default: []] += follow(item)
      } else {
        let found = follow(item)
        if !found.isEmpty { table[item.alias != 0 ? item.alias : item.member, default: []] += found }
      }
    }
    if let assignment = facts.exportAssignments[parent] {
      let sites = assignedSites(unitIndex, assignment.start, assignment.end, parent: parent)
      table[TSWord.exportEquals] = sites
      if table[TSWord.defaultName] == nil { table[TSWord.defaultName] = sites }
      // `export = X` with a namespace X: its members are the module's too.
      for site in sites {
        guard case .decl(let ref) = site else { continue }
        for other in merged(ref) where decl(other).kind == .namespace || decl(other).kind == .structure {
          for child in self.unit(other).children(of: other.decl) where self.unit(other).decls[Int(child)].name != 0 {
            let word = self.unit(other).decls[Int(child)].name
            if table[word] == nil { table[word] = [.decl(DeclRef(unit: other.unit, decl: child))] }
          }
        }
      }
    }
  }

  /// The innermost namespace around a token.
  func innermostNamespace(_ unit: Unit, token: Int32) -> Int32? {
    var found: Int32?
    for (index, item) in unit.decls.enumerated() where item.kind == .namespace && item.bodyOpen >= 0 {
      if item.bodyOpen < token, token < item.bodyClose { found = Int32(index) }
    }
    return found
  }

  /// `export = x`, `module.exports = …`: the declarations the expression names.
  private func assignedSites(_ unitIndex: Int32, _ start: Int32, _ end: Int32, parent: Int32) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    let facts = file(unit)
    if let literal = facts.literals[start] { return [.decl(DeclRef(unit: unitIndex, decl: literal))] }
    if let index = unit.decls.indices.first(where: { unit.decls[$0].initStart == start && unit.decls[$0].name == 0 && facts.exportOnly.contains(Int32($0)) }) {
      return [.decl(DeclRef(unit: unitIndex, decl: Int32(index)))]
    }
    guard end - start == 1, unit.tsIsName(Int(start)) else {
      if case .nominal(let ref, _) = expression(unitIndex, Int(start), Int(end)).ty, decl(ref).kind == .structure { return [.decl(ref)] }
      return []
    }
    let word = unit.hash(Int(start))
    if parent >= 0 {
      let found = unit.children(of: parent).filter { unit.decls[Int($0)].name == word }.map { Site.decl(DeclRef(unit: unitIndex, decl: $0)) }
      if !found.isEmpty { return found }
    }
    return topLevel(word, unitIndex: unitIndex, token: start)
  }

  /// The exports of the module an import names.
  func moduleExports(of item: Import) -> [Name: [Site]] {
    if item.moduleName.hasPrefix("ambient:") {
      var table: [Name: [Site]] = [:]
      for ref in ambientModule(String(item.moduleName.dropFirst(8))) {
        let holder = self.unit(ref)
        for child in holder.children(of: ref.decl) where holder.decls[Int(child)].name != 0 {
          table[holder.decls[Int(child)].name, default: []].append(.decl(DeclRef(unit: ref.unit, decl: child)))
        }
        var own: [Name: [Site]] = [:]
        scopeExports(ref.unit, parent: ref.decl, into: &own)
        for (word, sites) in own { table[word] = sites + (table[word] ?? []) }
      }
      return table
    }
    guard !item.moduleName.hasPrefix("?"), project.ensureModule(item.module, display: item.moduleName) != nil else { return [:] }
    return exports(item.module)
  }

  /// What an import binds: the declarations it takes, or the module.
  func follow(_ item: Import) -> [Site] {
    if item.moduleName.hasPrefix("?") { return [] }
    let table = moduleExports(of: item)
    if item.member == 0 {
      if let assigned = table[TSWord.exportEquals], !assigned.isEmpty { return assigned }
      if item.moduleName.hasPrefix("ambient:") {
        return ambientModule(String(item.moduleName.dropFirst(8))).map { .decl($0) }
      }
      guard project.modules[item.module] != nil else { return [] }
      return [.module(item.module)]
    }
    return table[item.member] ?? []
  }

  // MARK: Names

  /// A file's own top-level declarations of a name (and the global ones it merges with, for a script), else what an
  /// import of that name binds.
  func topLevel(_ word: Name, unitIndex: Int32, token: Int32) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    let facts = file(unit)
    if let module = project.modules[unit.moduleName], let list = module.top[word] {
      let own = list.filter { $0.unit == unitIndex && !facts.exportOnly.contains($0.decl) && !(decl($0).kind == .namespace && decl($0).name == TSWord.global) }
      if !own.isEmpty {
        if !facts.hasModuleSyntax, let shared = globals[word], shared.count > own.count { return shared.map { .decl($0) } }
        return own.map { .decl($0) }
      }
    }
    for item in unit.imports where item.alias == word && item.aliasToken >= 0 {
      // An import in a namespace (`declare module "m" { import … }`) is seen in it only.
      if let namespace = innermostNamespace(unit, token: item.aliasToken) {
        let holder = unit.decls[Int(namespace)]
        if token < holder.bodyOpen || token > holder.bodyClose { continue }
      }
      let found = follow(item)
      return found.isEmpty ? [.local(unit: unitIndex, token: item.aliasToken)] : found
    }
    return []
  }

  /// A name on its own at a token: a body's local, a type parameter, a namespace's member, the file's, an import's,
  /// a global.
  func lookup(_ word: Name, unitIndex: Int32, token: Int32) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    let scan = body(unitIndex)
    if let index = scan.local(named: word, at: token) {
      let local = scan.locals[Int(index)]
      if case .declaration(let declIndex) = local.kind {
        let ref = DeclRef(unit: unitIndex, decl: declIndex)
        return merged(ref).map { .decl($0) }
      }
      return [.local(unit: unitIndex, token: local.token)]
    }
    for index in unit.chain(at: token).reversed() {
      let item = unit.decls[Int(index)]
      for g in 0..<Int(item.genericCount) {
        let generic = unit.generics[Int(item.genericStart) + g]
        if generic.name == word { return [.generic(unit: unitIndex, token: generic.token)] }
      }
      if item.kind == .namespace, item.bodyOpen >= 0, item.bodyOpen < token {
        // Its own members, then those of the namespace's other declarations.
        let found = unit.children(of: index).filter { unit.decls[Int($0)].name == word }
        if !found.isEmpty { return found.map { .decl(DeclRef(unit: unitIndex, decl: $0)) } }
        var shared: [Site] = []
        for other in merged(DeclRef(unit: unitIndex, decl: index)) where other.decl != index || other.unit != unitIndex {
          let owner = self.unit(other)
          for child in owner.children(of: other.decl) where owner.decls[Int(child)].name == word { shared.append(.decl(DeclRef(unit: other.unit, decl: child))) }
        }
        if !shared.isEmpty { return shared }
        // A module augmentation, `declare module "m" { … }` in a module: m's own exports are in scope.
        if item.parent < 0, unit.tokens[Int(item.nameToken)].kind == .string, file(unit).hasModuleSyntax {
          let key = layout.resolve(unit.tsStringValue(Int(item.nameToken)), from: unit.path)
          if !key.hasPrefix("?"), project.ensureModule(name(key), display: key) != nil, let exported = exports(name(key))[word], !exported.isEmpty { return exported }
        }
      }
    }
    let own = topLevel(word, unitIndex: unitIndex, token: token)
    if !own.isEmpty { return resolvingAliases(own) }
    if let found = globals[word], !found.isEmpty { return resolvingAliases(found.map { .decl($0) }) }
    return []
  }

  /// `import x = A.B`'s name stands for what `A.B` names.
  func resolvingAliases(_ sites: [Site]) -> [Site] {
    guard sites.contains(where: { site in
      if case .decl(let ref) = site { return file(self.unit(ref)).aliases.contains(ref.decl) }
      return false
    }) else { return sites }
    var result: [Site] = []
    for site in sites {
      guard case .decl(let ref) = site, file(self.unit(ref)).aliases.contains(ref.decl), resolving.insert(ref).inserted else {
        result.append(site)
        continue
      }
      defer { resolving.remove(ref) }
      let holder = self.unit(ref)
      let item = decl(ref)
      var i = Int(item.initStart)
      guard holder.tsIsName(i) else { continue }
      var found = lookup(holder.hash(i), unitIndex: ref.unit, token: Int32(i))
      i += 1
      while i + 1 < Int(item.initEnd), holder.isByte(i, 0x2E), holder.tsIsWord(i + 1) {
        found = qualified(found, holder.hash(i + 1), from: ref.unit)
        i += 2
      }
      result += found.isEmpty ? [site] : found
    }
    return result
  }

  // MARK: Asking

  public func answer(path: String, line: Int, character: Int) -> Answer {
    guard let unitIndex = project.unitByPath[path] else { return Answer(state: .unknown, sites: []) }
    let unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    guard var token = unit.token(at: offset) else { return Answer(state: .unknown, sites: []) }
    // `#name`: the private name's word.
    if unit.isByte(token, 0x23) || unit.isToken(token, ".#"), token + 1 < unit.tokens.count, unit.tokens[token + 1].start == unit.tokens[token].end { token += 1 }
    return answer(unitIndex: unitIndex, token: token)
  }

  static let none = Answer(state: .unknown, sites: [])

  func answer(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    guard unit.tsIsWord(token) else { return Self.none }
    let facts = file(unit)
    let scan = body(unitIndex)
    let word = unit.hash(token)
    let afterDot = token > 0 && (unit.tsIsDot(token - 1) || unit.isToken(token - 1, ".#") || unit.isByte(token - 1, 0x23) && unit.tsIsDot(token - 2))
    if !afterDot, unit.tokens[token].kind != .identifier, !unit.tsIsName(token) {
      // Reserved words name nothing, except as members and keys.
      if !(unit.isByte(token + 1, 0x3A) || unit.isByte(token + 1, 0x28)) { return Self.none }
    }
    // Imports and exports.
    for item in unit.imports where item.aliasToken == Int32(token) || item.memberToken == Int32(token) {
      let found = follow(item)
      if found.isEmpty { return item.aliasToken >= 0 ? Answer(state: .exact, sites: [.local(unit: unitIndex, token: item.aliasToken)]) : Self.none }
      return settled(found)
    }
    for specifier in facts.exportSpecifiers where specifier.localToken == Int32(token) || specifier.exportedToken == Int32(token) {
      guard specifier.exported != TSWord.defaultName || specifier.localToken == Int32(token) else { break }
      let found = specifier.parent >= 0
        ? unit.children(of: specifier.parent).filter { unit.decls[Int($0)].name == specifier.local }.map { Site.decl(DeclRef(unit: unitIndex, decl: $0)) }
        : topLevel(specifier.local, unitIndex: unitIndex, token: specifier.localToken)
      return found.isEmpty ? Self.none : settled(found)
    }
    if let site = unit.declaredSiteFresh(at: token, unitIndex: unitIndex) ?? unit.declaredSite(at: token, unitIndex: unitIndex) {
      if case .decl(let ref) = site { return declarationAnswer(ref, unitIndex: unitIndex, token: token) }
      return Answer(state: .exact, sites: [site])
    }
    if let index = scan.byToken[Int32(token)] {
      let local = scan.locals[Int(index)]
      if case .declaration(let declIndex) = local.kind { return Answer(state: .exact, sites: [.decl(DeclRef(unit: unitIndex, decl: declIndex))]) }
      return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))])
    }
    if afterDot {
      let dot = unit.isByte(token - 1, 0x23) ? token - 2 : token - 1
      return member(unitIndex: unitIndex, dot: dot, word: word)
    }
    if isFunctionTypeParameter(unit, token) { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))]) }
    // A key of a destructuring pattern: `{ key: name } = value`.
    if unit.isByte(token + 1, 0x3A), let found = patternKey(unitIndex: unitIndex, token: token) { return found }
    let found = narrowedToCall(lookup(word, unitIndex: unitIndex, token: Int32(token)), unitIndex: unitIndex, token: token)
    if found.count == 1, case .module = found[0] {
      // A namespace import's uses go to the import, as TypeScript's do: `import * as X from "m"`.
      for item in unit.imports where item.alias == word && item.member == 0 && item.aliasToken >= 0 {
        let alias = Int(item.aliasToken)
        if unit.isToken(alias - 1, "as"), unit.isByte(alias - 2, 0x2A) { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: item.aliasToken)]) }
      }
    }
    return found.isEmpty ? Self.none : settled(found)
  }

  /// Sites without repeats: exact when one is left or when all are declarations of one symbol (an interface declared
  /// in several lib files, a class and the namespace merged with it), candidates otherwise.
  func settled(_ sites: [Site]) -> Answer {
    var found = Answer(summarizing: sites)
    guard found.state == .candidates, case .decl(let first)? = found.sites.first else { return found }
    let group = Set(merged(first).map { Site.decl($0) })
    if found.sites.allSatisfy(group.contains), !isOverloadChoice(found.sites) { found.state = .exact }
    return found
  }

  /// Several signatures of one function: which one a call takes is a guess.
  private func isOverloadChoice(_ sites: [Site]) -> Bool {
    sites.allSatisfy { site in
      if case .decl(let ref) = site { return decl(ref).kind == .function }
      return false
    }
  }

  /// A called function's overloads: the signatures (not the implementation) that take the call's arguments, the
  /// first that does when only one does.
  func narrowedToCall(_ sites: [Site], unitIndex: Int32, token: Int) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    var open = token + 1
    if unit.isByte(open, 0x23) { open += 1 }
    if unit.isByte(open, 0x3C), let after = unit.tsTypeArgumentsEnd(open, limit: unit.tokens.count) { open = after }
    if unit.isToken(open, "?.") { open += 1 }
    let functions = sites.compactMap { site -> DeclRef? in
      if case .decl(let ref) = site, decl(ref).kind == .function { return ref }
      return nil
    }
    guard functions.count > 1, unit.isByte(open, 0x28) else { return sites }
    // The implementation isn't a signature callers see.
    var signatures = functions.filter { decl($0).bodyOpen < 0 }
    if signatures.isEmpty { signatures = functions }
    let args = arguments(unit, open: open)
    let count = args.count
    var fitting = signatures.filter { fits($0, count) }
    if fitting.count > 1 {
      let typed = fitting.filter { argumentsFit($0, args, in: unitIndex) }
      if !typed.isEmpty { fitting = typed }
    }
    if fitting.count == 1 { return [.decl(fitting[0])] }
    let ordered = fitting + signatures.filter { !fitting.contains($0) }
    return ordered.map { .decl($0) } + sites.filter { site in
      if case .decl(let ref) = site, decl(ref).kind == .function { return false }
      return true
    }
  }

  /// A click on a declaration's name: itself, its merged declarations, or what it stands for (a shorthand property's
  /// value, an object literal's key's property in the type the literal is written for).
  private func declarationAnswer(_ ref: DeclRef, unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    let facts = file(unit)
    let item = decl(ref)
    if facts.shorthand.contains(ref.decl) {
      var sites = literalKeyTargets(ref)
      sites += lookup(item.name, unitIndex: unitIndex, token: Int32(token))
      return sites.isEmpty ? Answer(state: .exact, sites: [.decl(ref)]) : settled(sites)
    }
    if item.parent >= 0, unit.decls[Int(item.parent)].kind == .structure, unit.decls[Int(item.parent)].initStart >= 0 {
      let targets = literalKeyTargets(ref)
      if !targets.isEmpty { return settled(targets) }
      // An argument whose parameter type couldn't be told: the literal's own key, not surely.
      let open = Int(unit.decls[Int(item.parent)].bodyOpen)
      if unit.isByte(open - 1, 0x28) || unit.isByte(open - 1, 0x2C), let call = unit.matchingOpenBefore(open), unit.isByte(call, 0x28), call > 0,
        unit.tsIsName(call - 1) || unit.tokens[call - 1].kind == .close
      {
        return Answer(state: .candidates, sites: [.decl(ref)])
      }
    }
    if item.kind == .function || item.kind == .protocolType || item.kind == .namespace || item.kind == .classType || item.kind == .variable && item.parent < 0 {
      let sites = merged(ref).filter { decl($0).kind == item.kind || item.kind != .function }.map { Site.decl($0) }
      if !sites.isEmpty { return settled(sites) }
    }
    return Answer(state: .exact, sites: [.decl(ref)])
  }

  /// An object literal's property: the property of the type the literal is written for.
  func literalKeyTargets(_ ref: DeclRef) -> [Site] {
    let item = decl(ref)
    let literal = item.parent
    guard literal >= 0 else { return [] }
    let expected = contextualType(ref.unit, Int(self.unit(ref).decls[Int(literal)].bodyOpen))
    guard expected != .unknown else { return [] }
    return members(of: expected, named: item.name, from: ref.unit).map(\.site).filter { $0 != .decl(ref) }
  }

  /// A parameter's name in a function type, `(line: string) => void`: declared there.
  private func isFunctionTypeParameter(_ unit: Unit, _ token: Int) -> Bool {
    guard unit.tsIsName(token), let open = unit.matchingOpenBefore(token), unit.isByte(open, 0x28) else { return false }
    guard token == open + 1 || unit.isByte(token - 1, 0x2C) || unit.isToken(token - 1, "...") else { return false }
    guard unit.isByte(token + 1, 0x3A) || unit.isToken(token + 1, "?:") || unit.isByte(token + 1, 0x3F) || unit.isByte(token + 1, 0x2C) || unit.isByte(token + 1, 0x29) else { return false }
    return unit.isToken(unit.skipBalanced(open), "=>")
  }

  /// `{ key: name } = value` at `key`.
  private func patternKey(unitIndex: Int32, token: Int) -> Answer? {
    let unit = project.units[Int(unitIndex)]
    guard let open = unit.matchingOpenBefore(token), unit.isByte(open, 0x7B), token == open + 1 || unit.isByte(token - 1, 0x2C) else { return nil }
    let close = unit.skipBalanced(open)
    guard unit.isByte(close, 0x3D) || unit.isByte(close, 0x3A) || unit.isByte(close, 0x29) || unit.isByte(close, 0x2C) else { return nil }
    let scan = body(unitIndex)
    // The pattern's own names are locals; find one whose steps start with this key.
    let word = unit.hash(token)
    for local in scan.locals where local.token > Int32(open) && local.token < Int32(close) {
      guard case .member(let key)? = local.steps.first, key == word else { continue }
      var trimmed = local
      trimmed.steps = []
      let ty = localType(unitIndex, trimmed)
      let found = members(of: ty, named: word, from: unitIndex).map(\.site)
      return found.isEmpty ? Self.none : settled(found)
    }
    return nil
  }

  /// `x.name`: what x's type has of that name; by name when x's type can't be told.
  func member(unitIndex: Int32, dot: Int, word: Name) -> Answer {
    let operand = operandType(unitIndex, dot: dot)
    let found = narrowedToCall(members(of: operand, named: word, from: unitIndex).map(\.site), unitIndex: unitIndex, token: dot + 1)
    if !found.isEmpty { return settled(found) }
    guard isUnknown(operand) else { return Self.none }
    let candidates = project.membersNamed(word).filter { decl($0).kind != .subscriptDecl }
    guard !candidates.isEmpty else { return Self.none }
    return Answer(state: .candidates, sites: candidates.prefix(12).map { .decl($0) }, byNameOnly: true)
  }

  /// Unknown, or a union with nothing known in it.
  func isUnknown(_ ty: Ty) -> Bool {
    switch ty {
    case .unknown, .param: return true
    case .constructed(let kind, let parts) where kind == Ty.union || kind == Ty.intersection: return parts.allSatisfy(isUnknown)
    default: return false
    }
  }

  // MARK: References

  public func references(of answer: Answer) -> [(path: String, line: Int)] {
    guard answer.state != .unknown, !answer.byNameOnly, let first = answer.sites.first else { return [] }
    var targets = Set(answer.sites)
    var names: Set<Name> = []
    var restrict: Int32?
    switch first {
    case .decl(let ref):
      names.insert(decl(ref).name)
    case .local(let unitIndex, let token), .generic(let unitIndex, let token):
      names.insert(project.units[Int(unitIndex)].hash(Int(token)))
      restrict = unitIndex
    case .module(let moduleName):
      for u in 0..<project.projectUnits {
        for item in project.units[u].imports where item.module == moduleName && item.alias != 0 { names.insert(item.alias) }
      }
    }
    for target in targets {
      guard case .decl(let ref) = target else { continue }
      names.insert(decl(ref).name)
      for other in merged(ref) { targets.insert(.decl(other)) }
    }
    // Names it's imported by.
    let wanted = names
    for u in 0..<project.projectUnits {
      for item in project.units[u].imports where item.alias != 0 && item.member != 0 && wanted.contains(item.member) { names.insert(item.alias) }
      for specifier in file(project.units[u]).exportSpecifiers where wanted.contains(specifier.local) { names.insert(specifier.exported) }
    }
    if restrict != nil, case .local(let unitIndex, let token) = first {
      // An unresolved import's binding is used across the file only.
      restrict = unitIndex
      _ = token
    }
    return project.references(named: names, in: restrict, landingOn: targets) { self.answer(unitIndex: $0, token: $1) }
  }

  // MARK: Places

  /// As TypeScript's language service places it (CodeModelBench's TypeScript reference): relative to the root,
  /// `lib:<file>` for TypeScript's own lib files, `../` outside the root; a module at its file's first line.
  public func place(of site: Site) -> (path: String, line: Int)? {
    var path: String
    var line: Int
    if case .module(let moduleName) = site {
      guard let module = project.modules[moduleName], let first = module.units.first else { return nil }
      // TypeScript places a file at its first token, after leading comments.
      let holder = project.units[Int(first)]
      path = holder.path
      line = holder.tokens.isEmpty ? 1 : holder.source.lines.position(of: holder.tokens[0].start, in: holder.source.text).line + 1
    } else {
      guard let at = location(of: site) else { return nil }
      path = at.path
      line = at.line + 1
    }
    if let lib = layout.libDirectory, path.hasPrefix(lib + "/") { return ("lib:" + path.dropFirst(lib.count + 1), line) }
    return (project.rootRelative(path), line)
  }
}

extension Array {
  /// Nil when empty.
  var nonEmpty: Self? { isEmpty ? nil : self }
}
