import CodeModel
import CodeScan
import Foundation

/// A module of a crate: a file's root, or an inline `mod x { … }`.
struct ModNode {
  var unit: Int32
  /// The inline `mod`'s declaration, -1 for a file's root.
  var decl: Int32
  /// The module it's in, -1 for a crate's root.
  var parent: Int32
  /// The crate: its core module's name.
  var crate: Name
  /// The folder `mod x;` looks in.
  var base: String
  /// The `mod x;` that names a file's module.
  var modDecl: DeclRef?
}

/// Rust's three namespaces: a name can be a type and a function at once.
enum Namespace { case type, value, macro }

/// What a name resolves to before it's an answer.
enum Entity: Hashable {
  case decl(DeclRef)
  case node(Int32)
  case local(Int32, Int32)
  /// A type parameter: its unit, token and the declaration that has it.
  case generic(Int32, Int32, Int32)
}

/// What a file's tables give scopes, kept with the unit (a `BodyFacts`, so that it goes with the file).
final class RustUnitFacts: BodyFacts {
  /// Per scope (an inline module's, a function body's, or -1 for the file): its items by name.
  var items: [Int32: [Name: [Int32]]] = [:]
  /// Per scope: the imports written in it.
  var importsByScope: [Int32: [Int]] = [:]
  var importScope: [Int32] = []
  /// Each import's end token.
  var importEnd: [Int32] = []
  func dropTypes() {}
}

extension RustModel {
  static let factsKey = Int32.min

  func facts(_ unitIndex: Int32) -> RustUnitFacts {
    let unit = project.units[Int(unitIndex)]
    if let known = unit.scans[RustModel.factsKey] { return unsafeDowncast(known, to: RustUnitFacts.self) }
    let facts = RustUnitFacts()
    for index in unit.decls.indices {
      let item = unit.decls[index]
      guard item.kind != .extensionDecl, item.name != 0 else { continue }
      let parent = item.parent
      if parent >= 0 {
        let kind = unit.decls[Int(parent)].kind
        guard kind == .namespace || kind == .function || kind == .variable else { continue }
      }
      facts.items[parent, default: [:]][item.name, default: []].append(Int32(index))
    }
    for (index, item) in unit.imports.enumerated() {
      var scope: Int32 = -1
      for owner in unit.chain(at: item.token).reversed() {
        let holder = unit.decls[Int(owner)]
        if holder.kind == .namespace, holder.bodyOpen >= 0 {
          scope = owner
          break
        }
        if holder.kind == .function, holder.bodyOpen >= 0, holder.bodyOpen < item.token {
          scope = owner
          break
        }
      }
      facts.importScope.append(scope)
      facts.importsByScope[scope, default: []].append(index)
      var end = Int(item.token) + 1
      while end < unit.tokens.count, !unit.isByte(end, 0x3B) {
        if unit.tokens[end].kind == .close { break }
        end = unit.tokens[end].kind == .open ? unit.skipBalanced(end) : end + 1
      }
      facts.importEnd.append(Int32(end))
    }
    unit.scans[RustModel.factsKey] = facts
    return facts
  }

  // MARK: The module tree

  static func nodeKey(_ unit: Int32, _ decl: Int32) -> UInt64 { UInt64(UInt32(bitPattern: unit)) << 32 | UInt64(UInt32(bitPattern: decl &+ 1)) }

  /// The module tree of a crate, from its root file, made the first time it's asked for.
  func buildTree(_ moduleName: Name) {
    guard builtCrates.insert(moduleName).inserted, let module = project.modules[moduleName] else { return }
    let display = module.displayName
    guard let rootPath = layout.crates[display]?.root, let rootUnit = project.unitByPath[rootPath] else { return }
    let root = addNode(ModNode(unit: rootUnit, decl: -1, parent: -1, crate: moduleName, base: (rootPath as NSString).deletingLastPathComponent, modDecl: nil))
    crateRoots[moduleName] = root
    var queue = [root]
    while let current = queue.popLast() {
      let node = nodes[Int(current)]
      let unit = project.units[Int(node.unit)]
      for child in unit.children(of: node.decl) where unit.decls[Int(child)].kind == .namespace {
        let item = unit.decls[Int(child)]
        let word = unit.string(Int(item.nameToken))
        if item.bodyOpen >= 0 {
          var base = node.base + "/" + word
          if let path = pathAttribute(unit, item) { base = node.base + "/" + path }
          let inner = addNode(ModNode(unit: node.unit, decl: child, parent: current, crate: moduleName, base: base, modDecl: nil))
          queue.append(inner)
          continue
        }
        var file: String
        var isRoot: Bool
        if let path = pathAttribute(unit, item) {
          let folder = node.decl < 0 ? (unit.path as NSString).deletingLastPathComponent : node.base
          file = URL(fileURLWithPath: folder + "/" + path).standardizedFileURL.path
          isRoot = true
        } else if FileManager.default.fileExists(atPath: node.base + "/" + word + ".rs") || project.unitByPath[node.base + "/" + word + ".rs"] != nil {
          file = node.base + "/" + word + ".rs"
          isRoot = false
        } else {
          file = node.base + "/" + word + "/mod.rs"
          isRoot = true
        }
        guard let fileUnit = project.unitByPath[file], nodeIndex[RustModel.nodeKey(fileUnit, -1)] == nil else { continue }
        let directory = (file as NSString).deletingLastPathComponent
        let base = isRoot ? directory : directory + "/" + ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        let inner = addNode(ModNode(unit: fileUnit, decl: -1, parent: current, crate: moduleName, base: base, modDecl: DeclRef(unit: node.unit, decl: child)))
        nodeIndex[RustModel.nodeKey(node.unit, child)] = inner
        queue.append(inner)
      }
    }
  }

  @discardableResult
  private func addNode(_ node: ModNode) -> Int32 {
    let index = Int32(nodes.count)
    nodes.append(node)
    nodeIndex[RustModel.nodeKey(node.unit, node.decl)] = index
    return index
  }

  /// `#[path = "…"]` on a declaration.
  func pathAttribute(_ unit: Unit, _ item: Decl) -> String? {
    for (start, end) in attributes(unit, before: Int(item.first)) where unit.isToken(start, "path") && unit.isByte(start + 1, 0x3D) && start + 2 < end {
      return RustParser.unquote(unit.string(start + 2))
    }
    return nil
  }

  /// The attributes written right before a token: each `#[…]`'s inside.
  func attributes(_ unit: Unit, before first: Int) -> [(Int, Int)] {
    var result: [(Int, Int)] = []
    var k = first - 1
    // `pub`, `pub(crate)` come after the attributes.
    while k >= 0, unit.tokens[k].kind == .close, unit.isByte(k, 0x5D), let open = unit.matchingOpen(k), open >= 1, unit.isByte(open, 0x5B), unit.isByte(open - 1, 0x23) {
      result.append((open + 1, k))
      k = open - 2
    }
    return result
  }

  /// The traits a type derives: each name's token in `#[derive(…)]`.
  func derives(_ ref: DeclRef) -> [Int] {
    let holder = unit(ref)
    var result: [Int] = []
    for (start, end) in attributes(holder, before: Int(decl(ref).first)) {
      var at = start
      // `cfg_attr(cond, derive(…))`.
      if holder.isToken(at, "cfg_attr") {
        var k = at + 2
        while k < end, !holder.isToken(k, "derive") { k += 1 }
        at = k
      }
      guard holder.isToken(at, "derive"), holder.isByte(at + 1, 0x28) else { continue }
      let close = holder.skipBalanced(at + 1) - 1
      var k = at + 2
      while k < close {
        var last = k
        while last + 2 < close, holder.isToken(last + 1, "::") { last += 2 }
        if holder.tokens[last].kind == .identifier { result.append(last) }
        k = last + 1
        while k < close, !holder.isByte(k, 0x2C) { k += 1 }
        k += 1
      }
    }
    return result
  }

  /// A file's module: its place in its crate's tree, or a root of its own when no crate reaches it.
  func fileNode(_ unitIndex: Int32) -> Int32 {
    if let known = nodeIndex[RustModel.nodeKey(unitIndex, -1)] { return known }
    let unit = project.units[Int(unitIndex)]
    buildTree(unit.moduleName)
    if let known = nodeIndex[RustModel.nodeKey(unitIndex, -1)] { return known }
    let root = addNode(ModNode(unit: unitIndex, decl: -1, parent: -1, crate: unit.moduleName, base: (unit.path as NSString).deletingLastPathComponent, modDecl: nil))
    return root
  }

  /// The module a token is in.
  func moduleNode(unitIndex: Int32, token: Int32) -> Int32 {
    let unit = project.units[Int(unitIndex)]
    for index in unit.chain(at: token).reversed() where unit.decls[Int(index)].kind == .namespace && unit.decls[Int(index)].bodyOpen >= 0 {
      _ = fileNode(unitIndex)
      if let node = nodeIndex[RustModel.nodeKey(unitIndex, index)] { return node }
    }
    return fileNode(unitIndex)
  }

  func crateRoot(of node: Int32) -> Int32 {
    var current = node
    while nodes[Int(current)].parent >= 0 { current = nodes[Int(current)].parent }
    return current
  }

  func crateRoot(ofModule moduleName: Name) -> Int32? {
    buildTree(moduleName)
    return crateRoots[moduleName]
  }

  /// The node an inline module or `mod x;` stands for.
  func node(of ref: DeclRef) -> Int32? {
    _ = fileNode(ref.unit)
    return nodeIndex[RustModel.nodeKey(ref.unit, ref.decl)]
  }

  /// The crate a unit is compiled in, as the layout knows it.
  func crateInfo(of unitIndex: Int32) -> RustCrate? {
    let unit = project.units[Int(unitIndex)]
    guard let display = project.modules[unit.moduleName]?.displayName else { return nil }
    if let known = layout.crates[display] { return known }
    return nil
  }

  /// A crate a name stands for in a file (`serde`, `std`), as its root module.
  func externCrate(_ word: Name, from unitIndex: Int32) -> Int32? {
    let unit = project.units[Int(unitIndex)]
    if let cached = externCache[unit.moduleName]?[word] { return cached < 0 ? nil : cached }
    var result: Int32 = -1
    let crate = crateInfo(of: unitIndex)
    var table: [String: String]
    if let crate {
      table = layout.externCrates(of: crate)
    } else {
      table = ["std": "std", "core": "std", "alloc": "std"]
      // A file no target reaches: the package's dependencies around it.
      if let lib = layout.crates.values.first(where: { $0.kind == "lib" && $0.package?.isProject == true && unit.path.hasPrefix($0.package!.directory + "/") }) {
        table.merge(layout.externCrates(of: lib)) { a, _ in a }
        table[lib.pathName] = lib.display
      }
    }
    for (key, display) in table where name(key) == word {
      if let module = project.ensureModule(name(display), display: display), let root = crateRoot(ofModule: module.name) { result = root }
      break
    }
    // The crate itself by its name (a test or binary names its package's library that way, `extern crate self as x`).
    if result < 0, let crate, name(crate.pathName) == word, let root = crateRoot(ofModule: unit.moduleName) { result = root }
    externCache[unit.moduleName, default: [:]][word] = result
    return result < 0 ? nil : result
  }

  var stdRoot: Int32? {
    guard let module = project.ensureModule(RustWord.std, display: "std") else { return nil }
    return crateRoot(ofModule: module.name)
  }

  /// The standard library's prelude and its primitive types, as the stub declares them.
  var preludeNode: Int32? {
    if let known = cachedPrelude { return known < 0 ? nil : known }
    var found: Int32 = -1
    if let root = stdRoot, case .node(let node)? = lookupIn(nodes[Int(root)].unit, nodes[Int(root)].decl, RustWord.prelude, .type).first { found = node }
    cachedPrelude = found
    return found < 0 ? nil : found
  }

  var primitiveNode: Int32? {
    if let known = cachedPrimitives { return known < 0 ? nil : known }
    var found: Int32 = -1
    if let root = stdRoot, case .node(let node)? = lookupIn(nodes[Int(root)].unit, nodes[Int(root)].decl, name("primitive"), .type).first { found = node }
    cachedPrimitives = found
    return found < 0 ? nil : found
  }

  // MARK: Scopes

  func fits(_ entity: Entity, _ namespace: Namespace?) -> Bool {
    guard let namespace else { return true }
    switch entity {
    case .node: return namespace == .type
    case .local: return namespace == .value
    case .generic: return namespace == .type
    case .decl(let ref):
      let item = decl(ref)
      switch item.kind {
      case .structure:
        if namespace == .type { return true }
        if namespace == .value { return item.bodyOpen < 0 || !unit(ref).isByte(Int(item.bodyOpen), 0x7B) }
        return false
      case .enumeration, .protocolType, .typeAlias, .associatedType, .namespace: return namespace == .type
      case .function, .variable: return namespace == .value
      case .enumCase: return namespace != .macro
      case .macro: return namespace == .macro
      default: return false
      }
    }
  }

  func entity(_ ref: DeclRef) -> Entity {
    if decl(ref).kind == .namespace, let node = node(of: ref) { return .node(node) }
    return .decl(ref)
  }

  /// A name in a scope (a module's or a function body's): its items, then what its `use`s name, then its globs.
  func lookupIn(_ unitIndex: Int32, _ scope: Int32, _ word: Name, _ namespace: Namespace?) -> [Entity] {
    let key = ScopeKey(unit: unitIndex, scope: scope, word: word, namespace: namespace)
    if let known = scopeCache[key] { return known }
    guard visiting.insert(key).inserted else { return [] }
    defer { visiting.remove(key) }
    var result: [Entity] = []
    let facts = facts(unitIndex)
    if let list = facts.items[scope]?[word] {
      for index in list {
        let found = entity(DeclRef(unit: unitIndex, decl: index))
        if fits(found, namespace) { result.append(found) }
      }
    }
    // A crate's root also has the macros it exports, wherever they're written.
    if result.isEmpty, namespace == .macro || namespace == nil, scope < 0, let node = nodeIndex[RustModel.nodeKey(unitIndex, -1)], nodes[Int(node)].parent < 0 {
      result = exportedMacros(of: nodes[Int(node)].crate)[word]?.map { .decl($0) } ?? []
    }
    if result.isEmpty {
      let unit = project.units[Int(unitIndex)]
      for index in facts.importsByScope[scope] ?? [] where importName(unit.imports[index]) == word {
        for found in resolveImport(unitIndex, index, namespace) where !result.contains(found) { result.append(found) }
      }
    }
    if result.isEmpty {
      let unit = project.units[Int(unitIndex)]
      for index in facts.importsByScope[scope] ?? [] where unit.imports[index].member == RustWord.glob {
        for base in importBase(unitIndex, index) {
          for found in memberOf(base, word, namespace, glob: true) where !result.contains(found) { result.append(found) }
        }
      }
    }
    scopeCache[key] = result
    return result
  }

  /// The name an import gives: its alias, its last name, nothing for a glob or `as _`.
  func importName(_ item: Import) -> Name {
    if item.alias != 0 { return item.alias == RustWord.underscore ? 0 : item.alias }
    if item.member == RustWord.glob { return 0 }
    if item.member == 0 {
      if let last = item.moduleName.split(separator: ":").last { return name(String(last)) }
      return 0
    }
    return item.member
  }

  /// What an import names, in a namespace.
  func resolveImport(_ unitIndex: Int32, _ index: Int, _ namespace: Namespace?) -> [Entity] {
    let unit = project.units[Int(unitIndex)]
    let item = unit.imports[index]
    if item.moduleName == "::" {
      // `extern crate x as y;`, `extern crate self as y;`.
      guard namespace == .type || namespace == nil || namespace == .macro else { return [] }
      if namespace == .macro { return [] }
      if item.member == 0 { return [.node(crateRoot(of: fileNode(unitIndex)))] }
      return externCrate(item.member, from: unitIndex).map { [.node($0)] } ?? []
    }
    if item.member == 0 {
      guard namespace == .type || namespace == nil else { return [] }
      return importBase(unitIndex, index).filter { fits($0, .type) }
    }
    if item.moduleName.isEmpty {
      // `use foo;`: a crate, or a name in scope.
      let scope = facts(unitIndex).importScope[index]
      return firstSegment(item.member, unitIndex: unitIndex, scope: scope, namespace: namespace, excluding: index)
    }
    var result: [Entity] = []
    for base in importBase(unitIndex, index) {
      for found in memberOf(base, item.member, namespace, glob: false) where !result.contains(found) { result.append(found) }
    }
    return result
  }

  /// What an import's path before its leaf names.
  func importBase(_ unitIndex: Int32, _ index: Int) -> [Entity] {
    let unit = project.units[Int(unitIndex)]
    let item = unit.imports[index]
    let scope = facts(unitIndex).importScope[index]
    if item.moduleName.isEmpty {
      // `use foo::*` with foo alone is `use foo::*`: here moduleName holds foo.
      return []
    }
    let segments = item.moduleName.components(separatedBy: "::").map { $0 }
    return resolveUsePath(segments, unitIndex: unitIndex, scope: scope, excluding: index)
  }

  /// `crate::a::b`, `super::x`, `self::y`, `::serde::de`, `std::io`, `a::b` from a scope.
  func resolveUsePath(_ segments: [String], unitIndex: Int32, scope: Int32, excluding: Int?) -> [Entity] {
    guard let first = segments.first else { return [] }
    var current: [Entity]
    var rest = segments.dropFirst()
    let token = scope >= 0 ? project.units[Int(unitIndex)].decls[Int(scope)].first + 1 : 0
    let module = scope >= 0 ? moduleNode(unitIndex: unitIndex, token: token) : fileNode(unitIndex)
    switch first {
    case "":
      guard let next = rest.first else { return [] }
      rest = rest.dropFirst()
      current = externCrate(name(next), from: unitIndex).map { [.node($0)] } ?? []
    case "crate":
      current = [.node(crateRoot(of: module))]
    case "self":
      current = [.node(module)]
    case "super":
      let parent = nodes[Int(module)].parent
      current = parent >= 0 ? [.node(parent)] : []
    case "$crate":
      current = [.node(crateRoot(of: module))]
    default:
      current = firstSegment(name(first), unitIndex: unitIndex, scope: scope, namespace: .type, excluding: excluding)
    }
    for segment in rest {
      if segment == "super" {
        current = current.compactMap { entity in
          if case .node(let node) = entity, nodes[Int(node)].parent >= 0 { return .node(nodes[Int(node)].parent) }
          return nil
        }
        continue
      }
      if segment == "self" { continue }
      var next: [Entity] = []
      for base in current {
        for found in memberOf(base, name(segment), .type, glob: false) where !next.contains(found) { next.append(found) }
      }
      current = next
      if current.isEmpty { break }
    }
    return current
  }

  /// A path's first name in a `use`: what the scope has (not through the import being read), else a crate.
  func firstSegment(_ word: Name, unitIndex: Int32, scope: Int32, namespace: Namespace?, excluding: Int?) -> [Entity] {
    var scopes: [(Int32, Int32)] = []
    if scope >= 0 {
      scopes.append((unitIndex, scope))
      let unit = project.units[Int(unitIndex)]
      let module = moduleNode(unitIndex: unitIndex, token: unit.decls[Int(scope)].first)
      if !(nodes[Int(module)].unit == unitIndex && nodes[Int(module)].decl == scope) { scopes.append((nodes[Int(module)].unit, nodes[Int(module)].decl)) }
    } else {
      let module = fileNode(unitIndex)
      scopes.append((nodes[Int(module)].unit, nodes[Int(module)].decl))
    }
    for (u, s) in scopes {
      let found = lookupIn(u, s, word, namespace)
      if !found.isEmpty { return found }
    }
    if namespace != .value, namespace != .macro, let root = externCrate(word, from: unitIndex) { return [.node(root)] }
    // 2015 paths are from the crate's root.
    if let crate = crateInfo(of: unitIndex), crate.package?.edition == "2015" {
      let root = crateRoot(of: fileNode(unitIndex))
      let found = lookupIn(nodes[Int(root)].unit, nodes[Int(root)].decl, word, namespace)
      if !found.isEmpty { return found }
    }
    return []
  }

  /// A name inside something a path has reached: a module's item, an enum's variant, a type's or trait's associated item.
  func memberOf(_ base: Entity, _ word: Name, _ namespace: Namespace?, glob: Bool) -> [Entity] {
    switch base {
    case .node(let node):
      let holder = nodes[Int(node)]
      return lookupIn(holder.unit, holder.decl, word, namespace)
    case .decl(let ref):
      let item = decl(ref)
      switch item.kind {
      case .enumeration:
        let holder = unit(ref)
        let variants = holder.children(of: ref.decl).filter { holder.decls[Int($0)].kind == .enumCase && holder.decls[Int($0)].name == word }
        if !variants.isEmpty { return variants.map { .decl(DeclRef(unit: ref.unit, decl: $0)) } }
        if glob { return [] }
        return associatedItems(ref, word, namespace).map { .decl($0) }
      case .typeAlias:
        guard !glob, let target = typeDecl(of: valueTypeOfAlias(ref)) else { return [] }
        return memberOf(.decl(target), word, namespace, glob: false)
      case .structure, .protocolType:
        if glob { return [] }
        return associatedItems(ref, word, namespace).map { .decl($0) }
      default:
        return []
      }
    case .generic(let u, let token, let owner):
      if glob { return [] }
      let ty = Ty.param(project.units[Int(u)].hash(Int(token)), DeclRef(unit: u, decl: owner))
      return members(of: ty, named: word, from: u, call: true, includeFields: false).map { .decl($0) }
    case .local:
      return []
    }
  }

  // MARK: Macros

  /// Every `macro_rules!` a crate writes, by name: macros are textual, so any file of the crate sees them (near enough).
  func crateMacros(_ crate: Name) -> [Name: [DeclRef]] {
    if let known = macroTables[crate] { return known }
    var table: [Name: [DeclRef]] = [:]
    for index in project.modules[crate]?.units ?? [] {
      let unit = project.units[Int(index)]
      for (position, item) in unit.decls.enumerated() where item.kind == .macro { table[item.name, default: []].append(DeclRef(unit: index, decl: Int32(position))) }
    }
    macroTables[crate] = table
    return table
  }

  /// `#[macro_export]` macros: at the crate's root, wherever they're written.
  func exportedMacros(of crate: Name) -> [Name: [DeclRef]] {
    crateMacros(crate).mapValues { $0.filter { decl($0).access == .isPublic } }.filter { !$0.value.isEmpty }
  }

  func lookupMacro(_ word: Name, unitIndex: Int32, token: Int32) -> [Entity] {
    let unit = project.units[Int(unitIndex)]
    // `use` in scope first: `use tokio::select;`.
    for (u, s) in scopes(unitIndex: unitIndex, token: token) {
      let found = lookupIn(u, s, word, .macro)
      if !found.isEmpty { return found }
    }
    if let list = crateMacros(unit.moduleName)[word], !list.isEmpty {
      // The one in this file before the use, else any.
      let here = list.filter { $0.unit == unitIndex && decl($0).first < token }
      return (here.isEmpty ? list : [here.last!]).map { .decl($0) }
    }
    if let root = stdRoot {
      let found = lookupIn(nodes[Int(root)].unit, nodes[Int(root)].decl, word, .macro)
      if !found.isEmpty { return found }
    }
    // `#[macro_use] extern crate x;` and the crates a test sees: their exported macros.
    for item in unit.imports where item.moduleName == "::" {
      if let root = externCrate(item.member, from: unitIndex), let list = exportedMacros(of: nodes[Int(root)].crate)[word] { return list.map { .decl($0) } }
    }
    return []
  }

  // MARK: Lexical lookup

  /// The scopes a token sees, innermost first: the function bodies around it, then its module.
  func scopes(unitIndex: Int32, token: Int32) -> [(Int32, Int32)] {
    let unit = project.units[Int(unitIndex)]
    var result: [(Int32, Int32)] = []
    for index in unit.chain(at: token).reversed() {
      let item = unit.decls[Int(index)]
      if item.kind == .function, item.bodyOpen >= 0, item.bodyOpen < token, token < item.bodyClose {
        result.append((unitIndex, index))
      } else if item.kind == .variable, item.initStart >= 0, item.initStart <= token, token < item.initEnd {
        result.append((unitIndex, index))
      } else if item.kind == .namespace, item.bodyOpen >= 0 {
        result.append((unitIndex, index))
        return result
      }
    }
    let node = fileNode(unitIndex)
    result.append((nodes[Int(node)].unit, nodes[Int(node)].decl))
    return result
  }

  /// A name on its own at a token, in a namespace (nil: any, values first): locals, type parameters, the scopes
  /// around it, the crates it can name, the prelude, the primitive types.
  func lexical(_ word: Name, unitIndex: Int32, token: Int32, namespace: Namespace?) -> [Entity] {
    let unit = project.units[Int(unitIndex)]
    if namespace == .macro { return lookupMacro(word, unitIndex: unitIndex, token: token) }
    if namespace != .type, let site = localSite(word, unitIndex: unitIndex, token: token) { return [site] }
    if namespace != .value {
      for index in unit.chain(at: token).reversed() {
        let item = unit.decls[Int(index)]
        for g in 0..<Int(item.genericCount) {
          let generic = unit.generics[Int(item.genericStart) + g]
          if generic.name == word { return [.generic(unitIndex, generic.token, index)] }
        }
        // Items in a body don't see the function's type parameters, and modules see none from outside.
        if item.kind == .namespace { break }
      }
    }
    for (u, s) in scopes(unitIndex: unitIndex, token: token) {
      let found = lookupIn(u, s, word, namespace)
      if !found.isEmpty { return prefer(found, namespace) }
    }
    if namespace != .value, let root = externCrate(word, from: unitIndex) { return [.node(root)] }
    // `extern crate x as y;` at the crate's root.
    if namespace != .value {
      let root = nodes[Int(crateRoot(of: fileNode(unitIndex)))]
      if root.unit != unitIndex || root.decl != -1 {
        let found = lookupIn(root.unit, root.decl, word, .type).filter { if case .node = $0 { return true } else { return false } }
        if !found.isEmpty, project.units[Int(root.unit)].imports.contains(where: { $0.moduleName == "::" && importName($0) == word }) { return found }
      }
    }
    if let prelude = preludeNode {
      let found = lookupIn(nodes[Int(prelude)].unit, nodes[Int(prelude)].decl, word, namespace)
      if !found.isEmpty { return prefer(found, namespace) }
    }
    if namespace != .value, let primitives = primitiveNode {
      let found = lookupIn(nodes[Int(primitives)].unit, nodes[Int(primitives)].decl, word, .type)
      if !found.isEmpty { return found }
    }
    // The stub names std's items without importing them: the first module item of that name in the stub.
    // The enclosing modules come first, so `Write` in `io::stdio` is `io::Write`, not `fmt::Write`.
    if let root = stdRoot, nodes[Int(root)].unit == unitIndex {
      for index in unit.chain(at: token).reversed() where unit.decls[Int(index)].kind == .namespace {
        let found = lookupIn(unitIndex, index, word, namespace)
        if !found.isEmpty { return prefer(found, namespace) }
      }
      return stubItem(word, unitIndex: unitIndex, namespace: namespace)
    }
    return []
  }

  /// An item of the std stub by name, anywhere in it (modules first in source order).
  func stubItem(_ word: Name, unitIndex: Int32, namespace: Namespace?) -> [Entity] {
    if stubItems.isEmpty {
      let unit = project.units[Int(unitIndex)]
      for (index, item) in unit.decls.enumerated() where item.kind != .extensionDecl && item.kind != .macro && item.name != 0 {
        if item.parent >= 0, unit.decls[Int(item.parent)].kind != .namespace { continue }
        stubItems[item.name, default: []].append(DeclRef(unit: unitIndex, decl: Int32(index)))
      }
    }
    for ref in stubItems[word] ?? [] {
      let entity = entity(ref)
      if fits(entity, namespace) { return [entity] }
    }
    return []
  }

  /// Of a name's meanings in several namespaces, the one asked for; values before types when any will do.
  func prefer(_ found: [Entity], _ namespace: Namespace?) -> [Entity] {
    guard namespace == nil, found.count > 1 else { return found }
    let values = found.filter { fits($0, .value) }
    return values.isEmpty ? found : values
  }

  /// The enclosing `impl`'s or `trait`'s declaration for `Self`.
  func selfOwner(unitIndex: Int32, token: Int32) -> Int32? {
    let unit = project.units[Int(unitIndex)]
    for index in unit.chain(at: token).reversed() {
      let kind = unit.decls[Int(index)].kind
      if kind == .extensionDecl || kind == .protocolType { return index }
      if kind == .structure || kind == .enumeration { return index }
      if kind == .namespace { return nil }
    }
    return nil
  }

  // MARK: Paths

  /// A path's segments up to a token: `a::b::c` at c is [a, b, c] as tokens; nil before them when the path starts
  /// with `<T as Trait>::` (its `<`'s index is returned as `qualified`).
  func pathSegments(_ unit: Unit, to token: Int) -> (segments: [Int], qualified: Int?) {
    var segments = [token]
    var k = token
    while k >= 2, unit.isToken(k - 1, "::") {
      var previous = k - 2
      // `Vec::<u8>::new`: past the turbofish.
      if unit.isByte(previous, 0x3E) {
        var depth = 0
        var j = previous
        while j >= 0 {
          if unit.isByte(j, 0x3E) { depth += 1 } else if unit.isByte(j, 0x3C) {
            depth -= 1
            if depth == 0 { break }
          } else if unit.tokens[j].kind == .close, let open = unit.matchingOpen(j) {
            j = open
          }
          j -= 1
        }
        guard j >= 0 else { break }
        if j >= 1, unit.isToken(j - 1, "::"), j >= 2 {
          previous = j - 2
        } else {
          // `<T as Trait>::x` or `<T>::x`.
          return (segments, j)
        }
      }
      guard unit.tokens[previous].kind == .identifier || unit.tokens[previous].kind == .keyword else { break }
      segments.insert(previous, at: 0)
      k = previous
    }
    // `::std::x`: from the crates.
    if k >= 1, unit.isToken(k - 1, "::"), k < 2 || !(unit.tokens[k - 2].kind == .identifier || unit.tokens[k - 2].kind == .keyword || unit.isByte(k - 2, 0x3E)) {
      segments.insert(-1, at: 0)
    }
    return (segments, nil)
  }

  /// What a path in code names: its first segment lexically (or a crate, `crate`, `self`, `super`, `Self`), the rest
  /// inside it, the last in `namespace`.
  func resolvePath(_ unitIndex: Int32, _ segments: [Int], qualified: Int?, namespace: Namespace?) -> [Entity] {
    let unit = project.units[Int(unitIndex)]
    var current: [Entity] = []
    var start = 0
    if let qualified {
      // `<T as Trait>::x`: the trait's; `<T>::x`: T's.
      let close = qualifiedEnd(unit, qualified)
      var asToken = -1
      var k = qualified + 1
      var depth = 0
      while k < close {
        if unit.isByte(k, 0x3C) { depth += 1 } else if unit.isByte(k, 0x3E) { depth -= 1 }
        if depth == 0, unit.isToken(k, "as") { asToken = k }
        k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
      }
      if asToken >= 0 {
        let trait = typeFrom(unitIndex, asToken + 1, close)
        if let ref = typeDecl(of: trait) { current = [.decl(ref)] }
        let selfTy = typeFrom(unitIndex, qualified + 1, asToken)
        if segments.count == 1, current.isEmpty == false {
          // A method through the trait: still the trait's.
          _ = selfTy
        }
      } else {
        let ty = typeFrom(unitIndex, qualified + 1, close)
        if let ref = typeDecl(of: ty) {
          current = [.decl(ref)]
        } else if case .param(let word, let owner?) = ty, let token = genericToken(word, owner) {
          current = [.generic(owner.unit, token, owner.decl)]
        }
      }
      if current.isEmpty { return [] }
    } else {
      let first = segments[0]
      if first == -1 {
        guard segments.count > 1, let root = externCrate(unit.hash(segments[1]), from: unitIndex) else { return [] }
        current = [.node(root)]
        start = 2
      } else {
        let module = moduleNode(unitIndex: unitIndex, token: Int32(first))
        if unit.isToken(first, "crate") || unit.isToken(first, "$crate") {
          current = [.node(crateRoot(of: module))]
        } else if unit.isToken(first, "self"), segments.count > 1 {
          current = [.node(module)]
        } else if unit.isToken(first, "super") {
          current = nodes[Int(module)].parent >= 0 ? [.node(nodes[Int(module)].parent)] : []
        } else if unit.isToken(first, "Self") {
          current = selfEntity(unitIndex: unitIndex, token: Int32(first))
        } else {
          current = lexical(unit.hash(first), unitIndex: unitIndex, token: Int32(first), namespace: segments.count > 1 ? .type : namespace)
        }
        start = 1
      }
    }
    if start >= segments.count { return current }
    for position in start..<segments.count {
      let token = segments[position]
      let isLast = position == segments.count - 1
      if unit.isToken(token, "super") {
        current = current.compactMap { entity in
          if case .node(let node) = entity, nodes[Int(node)].parent >= 0 { return .node(nodes[Int(node)].parent) }
          return nil
        }
        continue
      }
      var next: [Entity] = []
      for base in current {
        for found in memberOf(base, unit.hash(token), isLast ? namespace : .type, glob: false) where !next.contains(found) { next.append(found) }
        // A value's namespace is the type's too for enum variants and associated items: try without one.
        if next.isEmpty, isLast, namespace != nil {
          for found in memberOf(base, unit.hash(token), nil, glob: false) where !next.contains(found) { next.append(found) }
        }
      }
      current = next
      if current.isEmpty { return [] }
    }
    return current
  }

  func qualifiedEnd(_ unit: Unit, _ open: Int) -> Int {
    var depth = 0
    var k = open
    while k < unit.tokens.count {
      if unit.isByte(k, 0x3C) { depth += 1 } else if unit.isByte(k, 0x3E) {
        depth -= 1
        if depth == 0 { return k }
      } else if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      } else if unit.tokens[k].kind == .close || unit.isByte(k, 0x3B) {
        return k
      }
      k += 1
    }
    return k
  }

  func genericToken(_ word: Name, _ owner: DeclRef) -> Int32? {
    let holder = unit(owner)
    let item = decl(owner)
    for g in 0..<Int(item.genericCount) where holder.generics[Int(item.genericStart) + g].name == word { return holder.generics[Int(item.genericStart) + g].token }
    return nil
  }

  /// `Self`: the impl's type, the trait, or the type being declared.
  func selfEntity(unitIndex: Int32, token: Int32) -> [Entity] {
    guard let owner = selfOwner(unitIndex: unitIndex, token: token) else { return [] }
    let ref = DeclRef(unit: unitIndex, decl: owner)
    let item = decl(ref)
    if item.kind == .extensionDecl {
      let ty = implSelfType(ref)
      if let target = typeDecl(of: ty) { return [.decl(target)] }
      return []
    }
    return [.decl(ref)]
  }
}

struct ScopeKey: Hashable {
  var unit: Int32
  var scope: Int32
  var word: Name
  var namespace: Namespace?
}
