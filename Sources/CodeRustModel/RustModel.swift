import CodeModel
import CodeScan
import Foundation

/// Rust's model: definitions, references, completion and details from source, on CodeModel's core. Each crate (a
/// package's library, binaries, tests, examples; each dependency's library) is a core module; inside it a module tree
/// from the crate's root (`mod x;` → `x.rs` or `x/mod.rs`, `#[path]`, inline `mod x { }`). Names resolve in Rust's
/// order (locals, type parameters, the function bodies around, the module's items, its `use`s, its globs, the crates
/// it can name, the prelude, the primitive types) and namespaces (types, values, macros); `x.m()` through the
/// receiver's type with autoderef: fields, inherent methods, then traits (impls, derives, bounds), answering a trait
/// method's declaration in the trait.
public final class RustModel: LanguageModel {
  public let project: Project
  let layout: RustLayout
  var nodes: [ModNode] = []
  var nodeIndex: [UInt64: Int32] = [:]
  var crateRoots: [Name: Int32] = [:]
  var builtCrates: Set<Name> = []
  var scopeCache: [ScopeKey: [Entity]] = [:]
  var visiting: Set<ScopeKey> = []
  var externCache: [Name: [Name: Int32]] = [:]
  var macroTables: [Name: [Name: [DeclRef]]] = [:]
  var cachedPrelude: Int32?
  var cachedPrimitives: Int32?
  var implIndex: [Name: [DeclRef]] = [:]
  var indexedUnits = 0
  var implTypes: [DeclRef: Ty] = [:]
  var implTraits: [DeclRef: Ty] = [:]
  var derivedCache: [DeclRef: [DeclRef]] = [:]
  var boundCache: [BoundKey: [Ty]] = [:]
  var valueTypes: [DeclRef: Ty] = [:]
  var resolving: Set<DeclRef> = []
  var resolvingAliases: Set<DeclRef> = []
  var stdTypes: [String: DeclRef?] = [:]
  var depth = 0
  /// How many blanket impls' bounds are being checked inside each other (`impl<T: Read> Read for &mut T`).
  var blanketDepth = 0
  /// Where the question being answered is: which traits are in scope for `Type::method` paths.
  var traitSite: (unit: Int32, token: Int32)?
  /// What impls apply to a type and whether it implements a trait, while the loaded units stay the same.
  var implsCache: [ImplsKey: [(impl: DeclRef, map: [Name: Ty])]] = [:]
  var implementsCache: [ImplementsKey: Bool] = [:]
  /// The questions being answered, by how deep: one asked again inside itself is a cycle and gets no impls. An answer
  /// found while assuming that about a question further out isn't kept (`implCycleHead`, the outermost one assumed).
  var implsPending: [ImplsKey: Int] = [:]
  var implementsPending: [ImplementsKey: Int] = [:]
  var implDepth = 0
  var implCycleHead = Int.max
  var cachedUnitCount = 0
  var stubItems: [Name: [DeclRef]] = [:]
  /// Types written in source, by where (a unit's tokens don't change without a reset or a new unit count).
  var typeCache: [TypeKey: Ty] = [:]
  var supertraitCache: [DeclRef: [DeclRef]] = [:]
  var traitScopeCache: [ScopeKey: Set<DeclRef>] = [:]
  var nodeTraitCache: [Int32: Set<DeclRef>] = [:]

  public init(project: Project) {
    self.project = project
    layout = project.layout as! RustLayout
    project.onShapeChange = { [weak self] in self?.reset() }
  }

  /// A Rust project under `root`: its crates from the `Cargo.toml` files there (and the workspace above).
  public convenience init(root: String) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    self.init(project: Project(root: root, layout: RustLayout(root: root)))
  }

  func reset() {
    nodes.removeAll()
    nodeIndex.removeAll()
    crateRoots.removeAll()
    builtCrates.removeAll()
    scopeCache.removeAll()
    externCache.removeAll()
    macroTables.removeAll()
    cachedPrelude = nil
    cachedPrimitives = nil
    implIndex.removeAll()
    indexedUnits = 0
    implTypes.removeAll()
    implTraits.removeAll()
    derivedCache.removeAll()
    boundCache.removeAll()
    valueTypes.removeAll()
    stdTypes.removeAll()
    implsCache.removeAll()
    implementsCache.removeAll()
    stubItems.removeAll()
    typeCache.removeAll()
    supertraitCache.removeAll()
    traitScopeCache.removeAll()
    nodeTraitCache.removeAll()
  }

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }

  // MARK: Asking

  public func answer(path: String, line: Int, character: Int) -> Answer {
    guard let unitIndex = project.unitByPath[path] else { return Answer(state: .unknown, sites: []) }
    let unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    project.focus(unitIndex: unitIndex, offset: offset)
    let current = project.units[Int(unitIndex)]
    guard let token = current.token(at: offset) else { return Answer(state: .unknown, sites: []) }
    return answer(unitIndex: unitIndex, token: token)
  }

  func answer(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    traitSite = (unitIndex, Int32(token))
    defer { traitSite = nil }
    // `x.name` with x's type unknown: the project's members of that name, as candidates by name.
    if token >= 1, unit.isByte(token - 1, 0x2E), unit.tokens[token].kind == .identifier, attributeContext(unit, token) == nil,
      operandType(unitIndex, dot: token - 1) == .unknown
    {
      let call = unit.isByte(token + 1, 0x28) || unit.isToken(token + 1, "::")
      let found = project.membersNamed(unit.hash(token)).filter { call ? decl($0).kind == .function : decl($0).kind == .variable || decl($0).kind == .function }
      guard !found.isEmpty else { return Answer(state: .unknown, sites: []) }
      return Answer(state: .candidates, sites: found.prefix(12).map { .decl($0) }, byNameOnly: true)
    }
    let found = entities(unitIndex: unitIndex, token: token)
    var sites: [Site] = []
    for entity in found {
      guard let site = site(of: entity) else { continue }
      if !sites.contains(site) { sites.append(site) }
    }
    if sites.isEmpty { return Answer(state: .unknown, sites: []) }
    return Answer(summarizing: sites)
  }

  func site(of entity: Entity) -> Site? {
    switch entity {
    case .decl(let ref): return .decl(ref)
    case .local(let u, let token): return .local(unit: u, token: token)
    case .generic(let u, let token, _): return .generic(unit: u, token: token)
    case .node(let node):
      let holder = nodes[Int(node)]
      if let modDecl = holder.modDecl { return .decl(modDecl) }
      if holder.decl >= 0 { return .decl(DeclRef(unit: holder.unit, decl: holder.decl)) }
      return .module(holder.crate)
    }
  }

  /// What a token names.
  func entities(unitIndex: Int32, token: Int) -> [Entity] {
    let unit = project.units[Int(unitIndex)]
    let kind = unit.tokens[token].kind
    let word = unit.hash(token)
    if kind == .keyword {
      guard unit.isToken(token, "self") || unit.isToken(token, "Self") || unit.isToken(token, "super") || unit.isToken(token, "crate") else { return [] }
    } else if kind != .identifier {
      return []
    }
    // Inside a `macro_rules!` there's no telling.
    for index in unit.chain(at: Int32(token)) where unit.decls[Int(index)].kind == .macro { return [] }
    if let attribute = attributeContext(unit, token) { return attributeEntities(unitIndex: unitIndex, token: token, open: attribute) }
    if let site = unit.declaredSite(at: token, unitIndex: unitIndex) {
      switch site {
      case .decl(let ref):
        if decl(ref).kind == .namespace { return [entity(ref)] }
        return [.decl(ref)]
      case .local(let u, let t): return [.local(u, t)]
      case .generic(let u, let t):
        for index in unit.chain(at: t).reversed() {
          let item = unit.decls[Int(index)]
          for g in 0..<Int(item.genericCount) where unit.generics[Int(item.genericStart) + g].token == t { return [.generic(u, t, index)] }
        }
        return []
      case .module: return []
      }
    }
    // A `let`'s or a pattern's own name.
    if kind == .identifier, let body = body(unitIndex: unitIndex, token: Int32(token)), body.byToken[Int32(token)] != nil {
      return [.local(unitIndex, Int32(token))]
    }
    // An impl's type, a use tree, a path in code.
    if let found = useEntities(unitIndex: unitIndex, token: token) { return found }
    if unit.isToken(token, "Self") { return selfEntity(unitIndex: unitIndex, token: Int32(token)) }
    if token >= 1, unit.isByte(token - 1, 0x2E), !unit.isToken(token - 1, "..") {
      let call = unit.isByte(token + 1, 0x28) || unit.isToken(token + 1, "::")
      let receiver = operandType(unitIndex, dot: token - 1)
      return members(of: receiver, named: word, from: unitIndex, call: call, at: Int32(token)).map { .decl($0) }
    }
    if let field = structLiteralField(unitIndex: unitIndex, token: token) { return field }
    let isMacro = unit.isByte(token + 1, 0x21) && !unit.isToken(token + 1, "!=")
    let (segments, qualified) = pathSegments(unit, to: token)
    let namespace: Namespace?
    if isMacro {
      namespace = .macro
    } else if unit.isToken(token + 1, "::") {
      namespace = .type
    } else if isTypePosition(unit, token) {
      namespace = .type
    } else if !inBody(unitIndex, Int32(token)) {
      // Signatures, where clauses, fields, impl headers: types (a const's value is a body here).
      namespace = .type
    } else if unit.isByte(token + 1, 0x28) {
      // A call: a function, a tuple struct or variant (both also values).
      namespace = .value
    } else {
      namespace = nil
    }
    if segments.count == 1, qualified == nil, isMacro { return lookupMacro(word, unitIndex: unitIndex, token: Int32(token)) }
    if segments.count == 1, qualified == nil, unit.isToken(token, "self") {
      if let local = localSite(RustWord.selfValue, unitIndex: unitIndex, token: Int32(token)) { return [local] }
      return [.node(moduleNode(unitIndex: unitIndex, token: Int32(token)))]
    }
    var found = resolvePath(unitIndex, segments, qualified: qualified, namespace: namespace)
    if found.isEmpty, namespace == .type, segments.count == 1 { found = resolvePath(unitIndex, segments, qualified: qualified, namespace: nil) }
    return found
  }

  /// Whether a token is in code: a function's body or a constant's value.
  func inBody(_ unitIndex: Int32, _ token: Int32) -> Bool {
    let unit = project.units[Int(unitIndex)]
    for index in unit.chain(at: token) {
      let item = unit.decls[Int(index)]
      if item.kind == .function, item.bodyOpen >= 0, item.bodyOpen < token, token < item.bodyClose { return true }
      if item.kind == .variable, item.initStart >= 0, item.initStart <= token, token < item.initEnd { return true }
      if item.kind == .enumCase, item.initStart >= 0, item.initStart <= token { return true }
    }
    return false
  }

  /// The `[` of the attribute a token is in.
  func attributeContext(_ unit: Unit, _ token: Int) -> Int? {
    var k = token
    while let open = unit.matchingOpenBefore(k) {
      if unit.isByte(open, 0x5B), open >= 1, unit.isByte(open - 1, 0x23) || (open >= 2 && unit.isByte(open - 1, 0x21) && unit.isByte(open - 2, 0x23)) { return open }
      if unit.isByte(open, 0x7B) { return nil }
      k = open
    }
    return nil
  }

  /// In `#[derive(A, B)]` the traits; an attribute's own path (`#[tokio::main]`) as a macro; nothing else.
  private func attributeEntities(unitIndex: Int32, token: Int, open: Int) -> [Entity] {
    let unit = project.units[Int(unitIndex)]
    if let inner = unit.matchingOpenBefore(token), unit.isByte(inner, 0x28), inner >= 1, unit.isToken(inner - 1, "derive") {
      let (segments, _) = pathSegments(unit, to: token)
      let found = resolvePath(unitIndex, segments, qualified: nil, namespace: .type)
      return found.isEmpty ? resolvePath(unitIndex, segments, qualified: nil, namespace: .macro) : found
    }
    return []
  }

  /// Whether a name stands where a type does: after `:` or `->` in a signature, in `<…>`, after `impl`/`dyn`/`for`/`as`.
  private func isTypePosition(_ unit: Unit, _ token: Int) -> Bool {
    var k = token - 1
    while k >= 1, unit.isToken(k, "::"), unit.tokens[k - 1].kind == .identifier || unit.tokens[k - 1].kind == .keyword { k -= 2 }
    guard k >= 0 else { return false }
    if unit.isToken(k, "->") || unit.isToken(k, "impl") || unit.isToken(k, "dyn") || unit.isToken(k, "as") || unit.isByte(k, 0x26) && unit.isByte(token + 1, 0x3C) { return true }
    if unit.isToken(k, "for"), k >= 1, unit.tokens[k - 1].kind != .keyword || unit.isToken(k - 1, "impl") { return false }
    if unit.isByte(k, 0x3C), k >= 1, unit.tokens[k - 1].kind == .identifier || unit.isToken(k - 1, "::") { return true }
    return false
  }

  /// `S { field: v }`, `S { field }`: the field (a shorthand also reads the local, which the model answers instead).
  private func structLiteralField(unitIndex: Int32, token: Int) -> [Entity]? {
    let unit = project.units[Int(unitIndex)]
    guard unit.isByte(token + 1, 0x3A), !unit.isToken(token + 1, "::"), token >= 1, unit.isByte(token - 1, 0x7B) || unit.isByte(token - 1, 0x2C) else { return nil }
    guard let open = unit.matchingOpenBefore(token), unit.isByte(open, 0x7B), open >= 1 else { return nil }
    let before = open - 1
    guard unit.tokens[before].kind == .identifier || unit.isToken(before, "Self") else { return nil }
    guard body(unitIndex: unitIndex, token: Int32(token)) != nil else { return nil }
    let (segments, qualified) = pathSegments(unit, to: before)
    var targets = resolvePath(unitIndex, segments, qualified: qualified, namespace: .type)
    if unit.isToken(before, "Self") { targets = selfEntity(unitIndex: unitIndex, token: Int32(before)) }
    for target in targets {
      guard case .decl(var ref) = target else { continue }
      if decl(ref).kind == .typeAlias, let aliased = typeDecl(of: aliasType(ref, [])) { ref = aliased }
      let holder = self.unit(ref)
      let found = holder.children(of: ref.decl).filter { holder.decls[Int($0)].kind == .variable && holder.decls[Int($0)].name == unit.hash(token) }
      if !found.isEmpty { return found.map { .decl(DeclRef(unit: ref.unit, decl: $0)) } }
    }
    return nil
  }

  /// A name in a `use` tree: what its path up to there names.
  func useEntities(unitIndex: Int32, token: Int) -> [Entity]? {
    let unit = project.units[Int(unitIndex)]
    let facts = facts(unitIndex)
    var which = -1
    for (index, item) in unit.imports.enumerated() where Int(item.token) < token && token < Int(facts.importEnd[index]) {
      which = index
      break
    }
    guard which >= 0 else { return nil }
    let item = unit.imports[which]
    let scope = facts.importScope[which]
    // `use a::b as c;`: c is what b is.
    for (index, other) in unit.imports.enumerated() where other.aliasToken == Int32(token) || other.memberToken == Int32(token) {
      if other.member == RustWord.glob { return [] }
      var found: [Entity] = []
      for namespace in [Namespace.type, .value, .macro] {
        for entity in resolveImport(unitIndex, index, namespace) where !found.contains(entity) { found.append(entity) }
      }
      return found
    }
    // A segment of the path: the path's text up to it.
    var segments: [String] = []
    var k = token
    segments.insert(unit.string(k), at: 0)
    while true {
      if k >= 2, unit.isToken(k - 1, "::"), unit.tokens[k - 2].kind == .identifier || unit.tokens[k - 2].kind == .keyword {
        k -= 2
        segments.insert(unit.string(k), at: 0)
        continue
      }
      if k >= 1, unit.isToken(k - 1, "::"), k < 2 || unit.isByte(k - 2, 0x7B) || unit.isByte(k - 2, 0x2C) || unit.isToken(k - 2, "use") {
        segments.insert("", at: 0)
        break
      }
      // Inside `{…}`: the path before the brace.
      if k >= 1, let open = unit.matchingOpenBefore(k), unit.isByte(open, 0x7B), open > Int(item.token), open >= 2, unit.isToken(open - 1, "::") {
        k = open - 2
        guard unit.tokens[k].kind == .identifier || unit.tokens[k].kind == .keyword else { break }
        segments.insert(unit.string(k), at: 0)
        continue
      }
      break
    }
    if segments.count == 1 {
      if segments[0] == "crate" || segments[0] == "self" || segments[0] == "super" {
        return resolveUsePath(segments, unitIndex: unitIndex, scope: scope, excluding: which)
      }
      return firstSegment(name(segments[0]), unitIndex: unitIndex, scope: scope, namespace: .type, excluding: which)
    }
    return resolveUsePath(segments, unitIndex: unitIndex, scope: scope, excluding: which)
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
      names.insert(project.units[Int(unitIndex)].hash(Int(token)))
      restrict = unitIndex
    case .module(let moduleName):
      if let crate = layout.crates[project.modules[moduleName]?.displayName ?? ""] { names.insert(name(crate.pathName)) }
    }
    for target in targets { if case .decl(let ref) = target { names.insert(decl(ref).name) } }
    // A renamed import's name lands on it too.
    for u in 0..<project.projectUnits {
      for item in project.units[u].imports where item.alias != 0 && names.contains(item.member) { names.insert(item.alias) }
    }
    return project.references(named: names, in: restrict, landingOn: targets) { self.answer(unitIndex: $0, token: $1) }
  }

  // MARK: Places

  /// Places as the reference names them: project files by relative path, `registry:<crate>-<version>/<path>`,
  /// `git:<repo>/<path>`, the standard library's stub as `std:<Name>`, `std:<Type>::<member>`, `std:<module>::<fn>`.
  public func place(of site: Site) -> (path: String, line: Int)? {
    switch site {
    case .decl(let ref):
      let holder = unit(ref)
      let item = decl(ref)
      if holder.moduleName == RustWord.std { return (stdPlace(ref), 1) }
      // `mod x;`: its file.
      if item.kind == .namespace, item.bodyOpen < 0, let node = node(of: ref) {
        return (filePlace(project.units[Int(nodes[Int(node)].unit)].path), 1)
      }
      guard let at = project.placeOf(holder, token: Int(item.nameToken)) else { return nil }
      return (filePlace(holder.path, fallback: at.path), at.line)
    case .local(let u, let token), .generic(let u, let token):
      let holder = project.units[Int(u)]
      guard let at = project.placeOf(holder, token: Int(token)) else { return nil }
      return (filePlace(holder.path, fallback: at.path), at.line)
    case .module(let moduleName):
      if moduleName == RustWord.std { return ("std:std", 1) }
      guard let root = crateRoot(ofModule: moduleName) else { return nil }
      return (filePlace(project.units[Int(nodes[Int(root)].unit)].path), 1)
    }
  }

  func filePlace(_ path: String, fallback: String? = nil) -> String {
    if path.hasPrefix(project.root + "/") { return String(path.dropFirst(project.root.count + 1)) }
    if let external = layout.externalPlace(path) { return external }
    return fallback ?? path
  }

  /// A standard library declaration's name in the reference's terms.
  func stdPlace(_ ref: DeclRef) -> String {
    let holder = unit(ref)
    let item = decl(ref)
    let own = holder.string(Int(item.nameToken))
    if item.kind == .namespace || item.kind == .macro { return "std:" + own }
    guard item.parent >= 0 else { return "std:" + own }
    let parent = holder.decls[Int(item.parent)]
    switch parent.kind {
    case .extensionDecl:
      return "std:" + implOwnerName(holder, parent) + "::" + own
    case .structure, .enumeration, .protocolType, .typeAlias:
      return "std:" + holder.string(Int(parent.nameToken)) + "::" + own
    case .namespace:
      if item.kind.isType { return "std:" + own }
      return "std:" + holder.string(Int(parent.nameToken)) + "::" + own
    default:
      return "std:" + own
    }
  }

  func implOwnerName(_ holder: Unit, _ impl: Decl) -> String {
    switch impl.name {
    case RustWord.slice: return "slice"
    case RustWord.array: return "array"
    case RustWord.pointer: return "pointer"
    case RustWord.tuple: return "tuple"
    case RustWord.function: return "fn"
    case RustWord.blanket: return "T"
    default: return impl.nameToken >= 0 ? holder.string(Int(impl.nameToken)) : "?"
    }
  }

  /// Where a site is for an editor: a `mod x;` opens its file, a crate its root.
  public func location(of site: Site) -> (path: String, line: Int, character: Int, name: String, preview: String)? {
    switch site {
    case .decl(let ref):
      let item = decl(ref)
      if item.kind == .namespace, item.bodyOpen < 0, let node = node(of: ref) {
        let path = project.units[Int(nodes[Int(node)].unit)].path
        return (path, 0, 0, unit(ref).string(Int(item.nameToken)), "")
      }
      return project.location(of: site)
    case .module(let moduleName):
      guard let root = crateRoot(ofModule: moduleName) else { return nil }
      let path = project.units[Int(nodes[Int(root)].unit)].path
      return (path, 0, 0, project.modules[moduleName]?.displayName ?? "", "")
    default:
      return project.location(of: site)
    }
  }
}
