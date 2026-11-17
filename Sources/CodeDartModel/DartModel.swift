import CodeModel
import CodeScan
import Foundation

/// What a library makes visible to whoever imports it: its public declarations and what it exports, by name, and its
/// extensions (applicable wherever they're imported, with a prefix too).
struct DartNamespace {
  var names: [Name: [DeclRef]] = [:]
  var extensions: [DeclRef] = []

  mutating func add(_ word: Name, _ refs: [DeclRef]) {
    var list = names[word] ?? []
    for ref in refs where !list.contains(ref) { list.append(ref) }
    names[word] = list
  }

  mutating func merge(_ other: DartNamespace, show: Set<Name>?, hide: Set<Name>) {
    for (word, refs) in other.names where show?.contains(word) ?? true && !hide.contains(word) { add(word, refs) }
    for ref in other.extensions where !extensions.contains(ref) { extensions.append(ref) }
  }
}

/// What a library's code sees: its own declarations (its parts' too), what its imports bring without a prefix, each
/// prefix's names, and every extension imported.
final class DartScope {
  var own: [Name: [DeclRef]] = [:]
  var imported: [Name: [DeclRef]] = [:]
  var prefixes: [Name: DartNamespace] = [:]
  /// Where each prefix is declared (`as p`): the first import that names it.
  var prefixSites: [Name: Site] = [:]
  var extensions: [DeclRef] = []
}

/// Dart's model: definitions, references, completion and details from source, on CodeModel's core. Names resolve as the
/// analyzer binds them: a body's locals and parameters (and closures', patterns', `for`'s and `catch`'s), the enclosing
/// declarations' type parameters, the enclosing class's (mixin's, enum's, extension's) own members, the library's
/// declarations (its parts' too), what its imports bring (show/hide applied, a platform library's name losing to a
/// package's), then the members the class inherits (an extension's on-type's). Members go through the receiver's static
/// type and its supertypes (mixins, the superclass, interfaces), generics substituted; a member no type has comes from
/// the extensions in scope that apply. Dart has no overloading, so a member is one declaration.
public final class DartModel: LanguageModel, NominalTypes {
  public let project: Project
  let layout: DartLayout
  var tables: [DeclRef: [Name: [MemberEntry]]] = [:]
  var building: Set<DeclRef> = []
  var valueTypes: [DeclRef: Ty] = [:]
  var resolving: Set<DeclRef> = []
  var supertypeCache: [DeclRef: [Ty]] = [:]
  var scopes: [Name: DartScope] = [:]
  var exports: [Name: DartNamespace] = [:]
  var exporting: Set<Name> = []
  var coreTypes: [Name: DeclRef] = [:]
  var onTypes: [DeclRef: Ty] = [:]
  var depth = 0
  /// Per unit, its declarations' children sorted by where they start, for `chain(_:at:)`: (declarations count, children).
  var sortedChildren: [Int32: (unit: ObjectIdentifier, count: Int, children: [Int32: [Int32]])] = [:]

  init(project: Project) {
    self.project = project
    layout = project.layout as! DartLayout
    project.onShapeChange = { [weak self] in self?.dropTables() }
  }

  /// A Dart project under `root`: its libraries, the packages they import where they're on disk, the `dart:` libraries.
  public convenience init(root: String) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    self.init(project: Project(root: root, layout: DartLayout(root: root)))
  }

  private func dropTables() {
    tables.removeAll()
    valueTypes.removeAll()
    supertypeCache.removeAll()
    scopes.removeAll()
    exports.removeAll()
    coreTypes.removeAll()
    onTypes.removeAll()
  }

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }

  static let unknown = Answer(state: .unknown, sites: [])

  func summarize(_ sites: [Site]) -> Answer { sites.isEmpty ? Self.unknown : Answer(summarizing: sites) }

  func isSDK(_ ref: DeclRef) -> Bool { project.isSDK(unit(ref)) }

  // MARK: Libraries

  /// The tokens after an import's URI: `show` and `hide` names (a setter's too: `show x` shows `x=`).
  func combinators(_ holder: Unit, _ item: Import) -> (show: Set<Name>?, hide: Set<Name>) {
    guard item.token >= 0 else { return (nil, []) }
    var i = holder.daStringEnd(Int(item.token))
    var show: Set<Name>?
    var hide: Set<Name> = []
    var mode = 0
    while i < holder.tokens.count, !holder.isByte(i, 0x3B), i - Int(item.token) < 4000 {
      if holder.tokens[i].kind == .open {
        i = holder.skipBalanced(i)
        continue
      }
      if holder.isToken(i, "show") {
        mode = 1
        if show == nil { show = [] }
      } else if holder.isToken(i, "hide") {
        mode = 2
      } else if holder.isToken(i, "as") || holder.isToken(i, "if") || holder.isToken(i, "deferred") {
        mode = 0
      } else if holder.daIsName(i), mode != 0, !holder.isToken(i - 1, "as") {
        let word = holder.string(i)
        if mode == 1 {
          show!.insert(name(word))
          show!.insert(name(word + "="))
        } else {
          hide.insert(name(word))
          hide.insert(name(word + "="))
        }
      }
      i += 1
    }
    return (show, hide)
  }

  /// A library's export namespace: its public declarations, then what it exports.
  func exportNamespace(_ moduleName: Name) -> DartNamespace {
    if let known = exports[moduleName] { return known }
    guard exporting.insert(moduleName).inserted, let module = project.modules[moduleName] else { return DartNamespace() }
    defer { exporting.remove(moduleName) }
    var result = DartNamespace()
    for (word, refs) in module.top {
      let visible = refs.filter { decl($0).access != .isPrivate }
      if !visible.isEmpty { result.add(word, visible) }
    }
    for unitIndex in module.units {
      let holder = project.units[Int(unitIndex)]
      for (index, item) in holder.decls.enumerated() where item.parent < 0 && item.kind == .extensionDecl && item.access != .isPrivate {
        result.extensions.append(DeclRef(unit: unitIndex, decl: Int32(index)))
      }
    }
    for unitIndex in module.units {
      let holder = project.units[Int(unitIndex)]
      for item in holder.imports where item.isExported {
        guard let target = project.ensureModule(item.module, display: item.moduleName) else { continue }
        let filter = combinators(holder, item)
        result.merge(exportNamespace(target.name), show: filter.show, hide: filter.hide)
      }
    }
    exports[moduleName] = result
    return result
  }

  /// What a library's code sees.
  func scope(of moduleName: Name) -> DartScope {
    if let known = scopes[moduleName] { return known }
    let scope = DartScope()
    scopes[moduleName] = scope
    guard let module = project.modules[moduleName] else { return scope }
    scope.own = module.top
    var imported = DartNamespace()
    var importsCore = false
    for unitIndex in module.units {
      let holder = project.units[Int(unitIndex)]
      for (index, item) in holder.decls.enumerated() where item.parent < 0 && item.kind == .extensionDecl {
        scope.extensions.append(DeclRef(unit: unitIndex, decl: Int32(index)))
      }
      for item in holder.imports where !item.isExported {
        if item.moduleName == DartWord.core { importsCore = true }
        guard let target = project.ensureModule(item.module, display: item.moduleName) else { continue }
        let filter = combinators(holder, item)
        let names = exportNamespace(target.name)
        if item.alias != 0 {
          scope.prefixes[item.alias, default: DartNamespace()].merge(names, show: filter.show, hide: filter.hide)
          if scope.prefixSites[item.alias] == nil { scope.prefixSites[item.alias] = .local(unit: unitIndex, token: item.aliasToken) }
        } else {
          imported.merge(names, show: filter.show, hide: filter.hide)
        }
        for ref in names.extensions where !scope.extensions.contains(ref) {
          let word = decl(ref).name
          if filter.show?.contains(word) ?? true, !filter.hide.contains(word) { scope.extensions.append(ref) }
        }
      }
    }
    if !importsCore, let core = project.ensureModule(name(DartWord.core), display: DartWord.core) {
      let names = exportNamespace(core.name)
      imported.merge(names, show: nil, hide: [])
      for ref in names.extensions where !scope.extensions.contains(ref) { scope.extensions.append(ref) }
    }
    scope.imported = imported.names
    return scope
  }

  func scope(ofUnit unitIndex: Int32) -> DartScope { scope(of: project.units[Int(unitIndex)].moduleName) }

  /// A name in a library's scope: its own declaration, else what its imports bring (a package's over a platform
  /// library's).
  func libraryLookup(_ word: Name, unitIndex: Int32) -> [DeclRef] {
    let scope = scope(ofUnit: unitIndex)
    if let own = scope.own[word], !own.isEmpty { return own }
    guard let found = scope.imported[word], !found.isEmpty else { return [] }
    if found.count > 1 {
      let packages = found.filter { !isSDK($0) }
      if !packages.isEmpty { return packages }
    }
    return found
  }

  /// A dart:core type by name (dart:async's `Future` and `Stream` too, as core exports them).
  func coreType(_ word: Name) -> DeclRef? {
    if let known = coreTypes[word] { return known }
    guard let core = project.ensureModule(name(DartWord.core), display: DartWord.core) else { return nil }
    let found = exportNamespace(core.name).names[word]?.first { decl($0).kind.isType }
    if let found { coreTypes[word] = found }
    return found
  }

  func coreTy(_ word: Name, _ args: [Ty] = []) -> Ty { coreType(word).map { .nominal($0, args) } ?? .unknown }

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
    // `_`: a wildcard since Dart 3.7, which declares nothing.
    guard unit.daIsName(token), !unit.isToken(token, "_") else { return Self.unknown }
    // `void Function(int)`: a keyword there, not the class `Function`.
    if unit.isToken(token, "Function"), unit.isByte(token + 1, 0x28) || unit.startsWith(token + 1, 0x3C) && !unit.daIsDot(token - 1) { return Self.unknown }
    if let found = directiveAnswer(unitIndex: unitIndex, token: token) { return found }
    if let found = declaredAnswer(unitIndex: unitIndex, token: token) { return found }
    let body = body(unitIndex: unitIndex, token: Int32(token))
    if let body, body.byToken[Int32(token)] != nil { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))]) }
    // `name: value` in parentheses: a named argument, or a record's field (declared there).
    if unit.isByte(token + 1, 0x3A), unit.isByte(token - 1, 0x28) || unit.isByte(token - 1, 0x2C), let open = unit.matchingOpenBefore(token), unit.isByte(open, 0x28) {
      return namedArgument(unitIndex: unitIndex, token: token, open: open) ?? Self.unknown
    }
    if let found = initializerTarget(unitIndex: unitIndex, token: token) { return found }
    if token > 0, unit.daIsDot(token - 1) { return selection(unitIndex: unitIndex, token: token) }
    return simpleName(unitIndex: unitIndex, token: token)
  }

  /// A name inside `import`, `export`, `library` or `part`: a prefix declared, a name shown or hidden.
  private func directiveAnswer(unitIndex: Int32, token: Int) -> Answer? {
    let unit = project.units[Int(unitIndex)]
    guard let first = unit.imports.first, first.token >= 0 else {
      return isLibraryDirective(unit, token) ? Self.unknown : nil
    }
    guard token < directivesEnd(unit) else { return nil }
    for item in unit.imports where item.token >= 0 && Int(item.token) < token {
      var end = Int(item.token)
      while end < unit.tokens.count, !unit.isByte(end, 0x3B) { end += 1 }
      guard token < end else { continue }
      if Int(item.aliasToken) == token { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: item.aliasToken)]) }
      guard unit.isByte(token - 1, 0x2C) || unit.isToken(token - 1, "show") || unit.isToken(token - 1, "hide"),
        let target = project.ensureModule(item.module, display: item.moduleName)
      else { return Self.unknown }
      let found = exportNamespace(target.name).names[unit.hash(token)] ?? []
      return summarize(found.map { .decl($0) })
    }
    return isLibraryDirective(unit, token) ? Self.unknown : nil
  }

  /// The token after a file's last directive.
  private func directivesEnd(_ unit: Unit) -> Int {
    guard let last = unit.imports.last, last.token >= 0 else { return 0 }
    var end = Int(last.token)
    while end < unit.tokens.count, !unit.isByte(end, 0x3B) { end += 1 }
    return end + 1
  }

  /// A word of `library a.b;` or `part of a.b;`.
  private func isLibraryDirective(_ unit: Unit, _ token: Int) -> Bool {
    var k = token - 1
    while k >= 0, unit.daIsName(k) || unit.isByte(k, 0x2E) {
      if unit.isToken(k, "library") && (k == 0 || unit.isByte(k - 1, 0x3B) || unit.startsLine(k)) { return true }
      if unit.isToken(k, "of"), unit.isToken(k - 1, "part") { return true }
      k -= 1
    }
    return false
  }

  /// A name where it's declared: itself, a field formal's field (`this.x`), a super parameter's (`super.x`), a named
  /// constructor's class (`Foo` in `Foo.named(…)`).
  private func declaredAnswer(unitIndex: Int32, token: Int) -> Answer? {
    let unit = project.units[Int(unitIndex)]
    if let site = unit.declaredSite(at: token, unitIndex: unitIndex) ?? unit.declaredSiteFresh(at: token, unitIndex: unitIndex) {
      if case .local(_, let at) = site, at == Int32(token), unit.isByte(token - 1, 0x2E) {
        if unit.isToken(token - 2, "this") { return fieldOfFormal(unitIndex: unitIndex, token: token) }
        if unit.isToken(token - 2, "super") { return superParameter(unitIndex: unitIndex, token: token) }
      }
      return Answer(state: .exact, sites: [site])
    }
    // A parameter's name in a function type, `void Function(int id)`: declared there.
    if unit.isByte(token + 1, 0x2C) || unit.isByte(token + 1, 0x29) || unit.isByte(token + 1, 0x5D) || unit.isByte(token + 1, 0x7D),
      token > 0, unit.daIsName(token - 1) || unit.isByte(token - 1, 0x3F) || unit.punctuation(token - 1, madeOf: ">?") || unit.isByte(token - 1, 0x29),
      var open = unit.matchingOpenBefore(token)
    {
      if !unit.isByte(open, 0x28), let outer = unit.matchingOpenBefore(open), unit.isByte(outer, 0x28) { open = outer }
      var before = open - 1
      if before > 0, unit.daClosesTypeArguments(before) {
        while before > 0, !(unit.tokens[before].kind == .punctuation && unit.startsWith(before, 0x3C) && unit.daTypeArgumentsEnd(before) == open) { before -= 1 }
        before -= 1
      }
      if unit.isByte(open, 0x28), unit.isToken(before, "Function") { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))]) }
    }
    // An extension's own name.
    if unit.isToken(token - 1, "extension") {
      for (index, item) in unit.decls.enumerated() where item.kind == .extensionDecl && item.nameToken == Int32(token) {
        return Answer(state: .exact, sites: [.decl(DeclRef(unit: unitIndex, decl: Int32(index)))])
      }
    }
    // `Foo` of `Foo.named(…)` declaring a constructor.
    if unit.isByte(token + 1, 0x2E), unit.daIsName(token + 2), unit.isByte(token + 3, 0x28) || unit.startsWith(token + 3, 0x3C),
      case .decl(let ref)? = unit.declaredSite(at: token + 2, unitIndex: unitIndex), decl(ref).kind == .initializer, decl(ref).parent >= 0
    {
      return Answer(state: .exact, sites: [.decl(DeclRef(unit: unitIndex, decl: decl(ref).parent))])
    }
    return nil
  }

  /// `this.x` in a constructor's parameters: the field.
  private func fieldOfFormal(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    guard let owner = enclosingTypes(unitIndex: unitIndex, token: Int32(token)).first else { return Self.unknown }
    let found = memberTable(of: owner)[unit.hash(token)]?.first.map(\.ref)
    guard let found, found.unit == owner.unit, decl(found).parent == owner.decl else { return Self.unknown }
    return Answer(state: .exact, sites: [.decl(found)])
  }

  /// `super.x` in a constructor's parameters: the parameter of the superclass's constructor it's passed to.
  private func superParameter(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    guard let constructor = chain(unit, unitIndex: unitIndex, at: Int32(token)).last.map({ DeclRef(unit: unitIndex, decl: $0) }), decl(constructor).kind == .initializer,
      let target = superConstructor(constructor)
    else { return Self.unknown }
    let item = decl(constructor)
    let holder = self.unit(target)
    let targetDecl = decl(target)
    // Named: by name; positional: by position among the positional ones.
    var position = 0
    var isNamed = false
    for p in 0..<Int(item.paramCount) {
      let param = unit.params[Int(item.paramStart) + p]
      if param.nameToken == Int32(token) {
        isNamed = param.label != 0
        break
      }
      if param.label == 0, unit.isToken(Int(param.nameToken) - 2, "super") { position += 1 }
    }
    var positional = 0
    for p in 0..<Int(targetDecl.paramCount) {
      let param = holder.params[Int(targetDecl.paramStart) + p]
      if isNamed {
        if param.label == unit.hash(token) { return Answer(state: .exact, sites: [.local(unit: target.unit, token: param.nameToken)]) }
      } else if param.label == 0 {
        if positional == position { return Answer(state: .exact, sites: [.local(unit: target.unit, token: param.nameToken)]) }
        positional += 1
      }
    }
    return Self.unknown
  }

  /// The superclass constructor a constructor calls: `super.name(…)` in its initializer list, else the unnamed one.
  func superConstructor(_ constructor: DeclRef) -> DeclRef? {
    let item = decl(constructor)
    let holder = unit(constructor)
    guard item.parent >= 0, let superclass = superclassType(DeclRef(unit: constructor.unit, decl: item.parent)), case .nominal(let target, _) = superclass else { return nil }
    var word = DartWord.newWord
    if item.initStart >= 0 {
      for k in Int(item.initStart)..<Int(item.initEnd) where holder.isToken(k, "super") && holder.isByte(k + 1, 0x2E) && holder.daIsName(k + 2) {
        word = holder.hash(k + 2)
      }
    }
    return constructors(of: target).first { decl($0).name == word }
  }

  /// A class's constructors.
  func constructors(of ref: DeclRef) -> [DeclRef] {
    unit(ref).children(of: ref.decl).filter { unit(ref).decls[Int($0)].kind == .initializer }.map { DeclRef(unit: ref.unit, decl: $0) }
  }

  /// `x = …` in a constructor's initializer list: the class's field.
  private func initializerTarget(unitIndex: Int32, token: Int) -> Answer? {
    let unit = project.units[Int(unitIndex)]
    guard unit.isToken(token + 1, "="), unit.isByte(token - 1, 0x3A) || unit.isByte(token - 1, 0x2C) || unit.isToken(token - 1, "this") == false && unit.isByte(token - 1, 0x2E) && unit.isToken(token - 2, "this") else { return nil }
    let chain = chain(unit, unitIndex: unitIndex, at: Int32(token))
    guard let last = chain.last else { return nil }
    let item = unit.decls[Int(last)]
    guard item.kind == .initializer, item.initStart >= 0, Int(item.initStart) <= token, token < Int(item.initEnd) else { return nil }
    if unit.isByte(token - 1, 0x2C), unit.matchingOpenBefore(token).map({ $0 >= Int(item.initStart) }) ?? false { return nil }
    return fieldOfFormal(unitIndex: unitIndex, token: token)
  }

  // MARK: Bodies

  /// The declaration whose body (parameters, initializer list, initializer) holds a token.
  func owner(unitIndex: Int32, token: Int32) -> Int32? {
    let unit = project.units[Int(unitIndex)]
    for index in chain(unit, unitIndex: unitIndex, at: token) {
      let item = unit.decls[Int(index)]
      if item.isLocal { continue }
      switch item.kind {
      case .function, .initializer:
        return index
      case .variable:
        if item.bodyOpen >= 0 || item.paramCount > 0 { return index }
        if item.initStart >= 0, token >= item.initStart, token < item.initEnd { return index }
      case .enumCase:
        if item.initStart >= 0, token >= item.initStart, token < item.initEnd { return index }
      default:
        break
      }
    }
    return nil
  }

  func body(unitIndex: Int32, token: Int32) -> DartBody? {
    guard let owner = owner(unitIndex: unitIndex, token: token) else { return nil }
    let unit = project.units[Int(unitIndex)]
    if let known = unit.scans[owner] { return unsafeDowncast(known, to: DartBody.self) }
    let scan = DartBody(unit: unit, owner: owner)
    unit.scans[owner] = scan
    return scan
  }

  /// `Unit.chain(at:)` by binary search: a generated file has thousands of declarations at one level.
  func chain(_ unit: Unit, unitIndex: Int32, at token: Int32) -> [Int32] {
    if let known = sortedChildren[unitIndex], known.unit == ObjectIdentifier(unit), known.count == unit.decls.count {} else {
      var children: [Int32: [Int32]] = [:]
      for index in unit.decls.indices { children[unit.decls[index].parent, default: []].append(Int32(index)) }
      for (parent, list) in children { children[parent] = list.sorted { unit.decls[Int($0)].first < unit.decls[Int($1)].first } }
      sortedChildren[unitIndex] = (ObjectIdentifier(unit), unit.decls.count, children)
    }
    let children = sortedChildren[unitIndex]!.children
    var result: [Int32] = []
    var parent: Int32 = -1
    while let list = children[parent] {
      var low = 0
      var high = list.count
      while low < high {
        let mid = (low + high) / 2
        if unit.decls[Int(list[mid])].first <= token { low = mid + 1 } else { high = mid }
      }
      guard low > 0 else { break }
      let child = list[low - 1]
      let item = unit.decls[Int(child)]
      guard token < item.end else { break }
      // A local variable or the like: as the core walks it.
      guard !(item.isLocal && !item.kind.isNominal && item.kind != .function) else { return unit.chain(at: token) }
      result.append(child)
      parent = child
    }
    return result
  }

  // MARK: Names

  /// The types (classes, mixins, enums, extension types) and extensions around a token, innermost first.
  func enclosingTypes(unitIndex: Int32, token: Int32) -> [DeclRef] {
    let unit = project.units[Int(unitIndex)]
    var result: [DeclRef] = []
    for index in chain(unit, unitIndex: unitIndex, at: token).reversed() {
      let item = unit.decls[Int(index)]
      if item.kind.isNominal || item.kind == .extensionDecl { result.append(DeclRef(unit: unitIndex, decl: index)) }
    }
    return result
  }

  /// The type of a type seen from inside it: its type parameters as its arguments.
  func ownType(_ ref: DeclRef) -> Ty {
    let item = decl(ref)
    let holder = unit(ref)
    var args: [Ty] = []
    for g in 0..<Int(item.genericCount) { args.append(.param(holder.generics[Int(item.genericStart) + g].name, ref)) }
    return .nominal(ref, args)
  }

  /// A type parameter of a declaration around a token.
  func genericSite(_ word: Name, unitIndex: Int32, token: Int32) -> (Site, Ty)? {
    let unit = project.units[Int(unitIndex)]
    for index in chain(unit, unitIndex: unitIndex, at: token).reversed() {
      let item = unit.decls[Int(index)]
      for g in 0..<Int(item.genericCount) where unit.generics[Int(item.genericStart) + g].name == word {
        let generic = unit.generics[Int(item.genericStart) + g]
        return (.generic(unit: unitIndex, token: generic.token), .param(word, DeclRef(unit: unitIndex, decl: index)))
      }
    }
    return nil
  }

  /// A declaration of a member list by name, a setter's when assigning (and there's one).
  func pick(_ table: [Name: [DeclRef]], _ word: Name, setter: Name?) -> [DeclRef]? {
    if let setter, let found = table[setter], !found.isEmpty { return found }
    if let found = table[word], !found.isEmpty { return found }
    return nil
  }

  /// What a simple name means at a token, in Dart's order (see the type's comment).
  func nameSites(_ word: Name, unitIndex: Int32, token: Int32, assigning: Bool) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    if let body = body(unitIndex: unitIndex, token: token), let index = body.local(named: word, at: token) {
      return [.local(unit: unitIndex, token: body.locals[Int(index)].token)]
    }
    let setter = assigning ? name(unit.string(Int(token)) + "=") : nil
    let types = enclosingTypes(unitIndex: unitIndex, token: token)
    // The enclosing declarations' own members and type parameters, innermost first.
    for type in types {
      var own: [Name: [DeclRef]] = [:]
      for child in unit.children(of: type.decl) {
        let item = unit.decls[Int(child)]
        if item.kind == .initializer || item.isLocal { continue }
        own[item.name, default: []].append(DeclRef(unit: unitIndex, decl: child))
      }
      if let found = pick(own, word, setter: setter) { return found.map { .decl($0) } }
    }
    if let (site, _) = genericSite(word, unitIndex: unitIndex, token: token) { return [site] }
    let library = libraryLookup(setter ?? word, unitIndex: unitIndex)
    if !library.isEmpty { return library.map { .decl($0) } }
    if setter != nil {
      let plain = libraryLookup(word, unitIndex: unitIndex)
      if !plain.isEmpty { return plain.map { .decl($0) } }
    }
    if let site = scope(ofUnit: unitIndex).prefixSites[word] { return [site] }
    // `this.name`: inherited members, an extension's on-type's.
    for type in types {
      let receiver = thisType(type)
      let found = instanceMembers(receiver, word, setter: setter, unitIndex: unitIndex)
      if !found.isEmpty { return found.map { .decl($0) } }
    }
    return []
  }

  /// `this`'s type in a type's body: the type, or an extension's on-type.
  func thisType(_ ref: DeclRef) -> Ty {
    if decl(ref).kind == .extensionDecl { return onType(ref) }
    return ownType(ref)
  }

  /// A simple name: a local, a member, a library's declaration; a class called is its constructor.
  private func simpleName(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    let assigning = unit.isToken(token + 1, "=")
    let sites = nameSites(unit.hash(token), unitIndex: unitIndex, token: Int32(token), assigning: assigning)
    if callOpen(unit, token) != nil { return summarize(sites.map { constructorSite($0, named: DartWord.newWord) }) }
    return summarize(sites)
  }

  /// A class called: its constructor of that name when it declares one, else the class (its implicit one).
  func constructorSite(_ site: Site, named word: Name) -> Site {
    guard case .decl(let ref) = site, decl(ref).kind.isNominal else { return site }
    if let found = constructors(of: ref).first(where: { decl($0).name == word }) { return .decl(found) }
    return site
  }

  /// The `(` of a call whose name is at `token`: `f(`, `f<T>(`.
  func callOpen(_ unit: Unit, _ token: Int) -> Int? {
    if unit.isByte(token + 1, 0x28) { return token + 1 }
    if unit.tokens.indices.contains(token + 1), unit.tokens[token + 1].kind == .punctuation, unit.startsWith(token + 1, 0x3C),
      let end = unit.daTypeArgumentsEnd(token + 1), unit.isByte(end, 0x28)
    {
      return end
    }
    return nil
  }

  // MARK: Members

  /// `x.name`: a prefix's declaration, a type's static member or named constructor, a value's member (an extension's).
  private func selection(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    let word = unit.hash(token)
    let assigning = unit.isToken(token + 1, "=")
    let setter = assigning ? name(unit.string(token) + "=") : nil
    let open = callOpen(unit, token)
    // `this.name(…)`, `super.name(…)` redirecting or calling a constructor from an initializer list.
    if open != nil, unit.isToken(token - 2, "this") || unit.isToken(token - 2, "super"), unit.isByte(token - 3, 0x3A) || unit.isByte(token - 3, 0x2C),
      let constructor = chain(unit, unitIndex: unitIndex, at: Int32(token)).last.map({ DeclRef(unit: unitIndex, decl: $0) }), decl(constructor).kind == .initializer,
      decl(constructor).initStart >= 0, token >= Int(decl(constructor).initStart)
    {
      let owner = DeclRef(unit: unitIndex, decl: decl(constructor).parent)
      let target: DeclRef? = unit.isToken(token - 2, "this") ? owner : superclassType(owner).flatMap { if case .nominal(let ref, _) = $0 { return ref } else { return nil } }
      if let target { return summarize(constructors(of: target).filter { decl($0).name == word }.map { .decl($0) }) }
    }
    let receiver = operandType(unitIndex: unitIndex, dot: token - 1)
    switch receiver {
    case .module(let prefix):
      guard let names = scope(ofUnit: unitIndex).prefixes[prefix] else { return Self.unknown }
      let found = pick(names.names, word, setter: setter) ?? []
      let sites = found.map { Site.decl($0) }
      return summarize(open != nil ? sites.map { constructorSite($0, named: DartWord.newWord) } : sites)
    case .meta(let type):
      return summarize(staticMembers(type, word, setter: setter).map { .decl($0) })
    case .unknown:
      return byName(word, open: open != nil, unitIndex: unitIndex)
    default:
      let found = instanceMembers(receiver, word, setter: setter, unitIndex: unitIndex)
      if found.isEmpty, case .param(_, _) = receiver, bound(of: receiver) == nil { return byName(word, open: open != nil, unitIndex: unitIndex) }
      return summarize(found.map { .decl($0) })
    }
  }

  /// The project's members of a name, as candidates by name, when a receiver's type couldn't be told: not another
  /// library's private ones.
  func byName(_ word: Name, open: Bool, unitIndex: Int32) -> Answer {
    let module = project.units[Int(unitIndex)].moduleName
    let found = project.membersNamed(word).filter { ref in
      let item = decl(ref)
      if item.kind == .initializer || item.kind.isNominal || item.isLocal { return false }
      if item.access == .isPrivate, unit(ref).moduleName != module { return false }
      if open { return item.kind == .function || item.kind == .variable }
      return item.kind == .variable || item.kind == .enumCase || item.kind == .function
    }
    guard !found.isEmpty else { return Self.unknown }
    return Answer(state: .candidates, sites: found.prefix(12).map { .decl($0) }, byNameOnly: true)
  }

  /// `T.name`: a static member, a named constructor, an enum's value; `values` is the enum's own.
  func staticMembers(_ type: Ty, _ word: Name, setter: Name?) -> [DeclRef] {
    guard case .nominal(let ref, _) = type else { return [] }
    var own: [Name: [DeclRef]] = [:]
    let holder = unit(ref)
    for child in holder.children(of: ref.decl) {
      let item = holder.decls[Int(child)]
      guard item.isStatic || item.kind == .initializer || item.kind == .enumCase || decl(ref).kind == .extensionDecl else { continue }
      own[item.name, default: []].append(DeclRef(unit: ref.unit, decl: child))
    }
    if let found = pick(own, word, setter: setter) { return [found[0]] }
    if word == DartWord.valuesWord, decl(ref).kind == .enumeration { return [ref] }
    return []
  }

  /// A value's member: its type's (inherited ones too), else an applicable extension's.
  func instanceMembers(_ receiver: Ty, _ word: Name, setter: Name?, unitIndex: Int32) -> [DeclRef] {
    var base = receiver
    if case .optional(let inner) = base { base = inner }
    if case .existential(let parts) = base {
      for part in parts {
        let found = instanceMembers(part, word, setter: setter, unitIndex: unitIndex)
        if !found.isEmpty { return found }
      }
      return []
    }
    if let setter, let entry = memberEntries(of: base, named: setter).first { return [entry.0.ref] }
    if let entry = memberEntries(of: base, named: word).first { return [entry.0.ref] }
    let extensions = extensionMembers(setter ?? word, receiver: base, unitIndex: unitIndex)
    if !extensions.isEmpty || setter == nil { return extensions.map(\.ref) }
    return extensionMembers(word, receiver: base, unitIndex: unitIndex).map(\.ref)
  }

  // MARK: Named arguments

  /// `f(name: value)`: the parameter of what's called; a record's field is declared there.
  private func namedArgument(unitIndex: Int32, token: Int, open: Int) -> Answer? {
    let unit = project.units[Int(unitIndex)]
    guard let call = callTarget(unitIndex: unitIndex, open: open) else {
      // A record literal's field: declared there.
      if open > 0, !unit.daIsName(open - 1), !unit.isByte(open - 1, 0x29), !unit.isByte(open - 1, 0x5D) {
        return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))])
      }
      return nil
    }
    let word = unit.hash(token)
    var sites: [Site] = []
    for ref in call.refs {
      let holder = self.unit(ref)
      let item = decl(ref)
      for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].label == word {
        sites.append(.local(unit: ref.unit, token: holder.params[Int(item.paramStart) + p].nameToken))
      }
    }
    return summarize(sites)
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
        let holder = self.unit(ref)
        names.insert(holder.hash(Int(item.nameToken)))
        if item.kind.isNominal {
          // A class called is its constructor.
          for constructor in constructors(of: ref) {
            targets.insert(.decl(constructor))
            names.insert(holder.hash(Int(decl(constructor).nameToken)))
          }
        }
        if item.kind == .initializer, item.name == DartWord.newWord, item.parent >= 0 {
          targets.insert(.decl(DeclRef(unit: ref.unit, decl: item.parent)))
        }
      }
    case .local(let unitIndex, let token), .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      names.insert(holder.hash(Int(token)))
      // A parameter is named by arguments anywhere (`f(name: …)`); a local is only seen in its file.
      if !isParameter(unitIndex: unitIndex, token: token) { restrict = unitIndex }
    case .module:
      return []
    }
    return project.references(named: names, in: restrict, landingOn: targets) { self.answer(unitIndex: $0, token: $1) }
  }

  func isParameter(unitIndex: Int32, token: Int32) -> Bool {
    let holder = project.units[Int(unitIndex)]
    for item in holder.decls {
      for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].nameToken == token { return holder.params[Int(item.paramStart) + p].label != 0 }
    }
    return false
  }
}
