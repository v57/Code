import CodeModel
import CodeScan
import Foundation

/// The project's namespaces: their types (every part of a partial type) and extension methods by name, built when first
/// asked and again after a declaration changed.
final class CSharpIndex {
  var types: [String: [Name: [DeclRef]]] = [:]
  var extensions: [String: [Name: [DeclRef]]] = [:]
  /// Every namespace declared, and every namespace above one.
  var namespaces: Set<String> = []
  /// Each project's `global using`s, by module.
  var globalImports: [Name: [(unit: Int32, item: Int)]] = [:]
}

/// What a scope's `using` directives bring in.
struct CSharpUsings {
  var namespaces: [String] = []
  /// `using static T;`.
  var statics: [Ty] = []
  /// `using A = X;`, by alias: where it's declared, and what it names.
  var aliases: [Name: (unit: Int32, item: Int)] = [:]
}

/// C#'s model: definitions, references, completion and details from source, on CodeModel's core. Names resolve as
/// Roslyn binds them: locals and parameters, then each enclosing type's type parameters and members (inherited ones
/// too) and a primary constructor's parameters, innermost first; then each enclosing namespace from the innermost out,
/// its types and namespaces, then the `using` directives of that declaration (aliases, the namespaces' types,
/// `using static` members); last the compilation unit's usings, the project's `global using`s and the SDK's implicit
/// ones. Members go through the receiver's static type and its base types, generics substituted; overloads are chosen
/// by argument count (optional parameters, `params`, named arguments) and the argument types that are known, else given
/// as candidates; extension methods come from the namespaces in scope when no instance method fits.
public final class CSharpModel: LanguageModel, NominalTypes {
  public let project: Project
  let layout: CSharpLayout
  var tables: [DeclRef: [Name: [MemberEntry]]] = [:]
  var building: Set<DeclRef> = []
  var valueTypes: [DeclRef: Ty] = [:]
  var resolving: Set<DeclRef> = []
  var supertypeCache: [DeclRef: [Ty]] = [:]
  var partsCache: [DeclRef: [DeclRef]] = [:]
  var namespaceCache: [DeclRef: String] = [:]
  var usingsCache: [Int64: CSharpUsings] = [:]
  var aliasCache: [Int64: [Site]] = [:]
  /// Namespace names by their hash, for `.module` sites and places.
  var namespaceNames: [Name: String] = [:]
  var built: CSharpIndex?
  var libraryIndex: [String: (types: [Name: [DeclRef]], extensions: [Name: [DeclRef]])] = [:]
  var depth = 0

  init(project: Project) {
    self.project = project
    layout = project.layout as! CSharpLayout
    project.onShapeChange = { [weak self] in self?.dropTables() }
  }

  /// A C# project under `root`: its `.csproj` projects' files, the .NET library's stub.
  public convenience init(root: String) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    self.init(project: Project(root: root, layout: CSharpLayout(root: root)))
  }

  private func dropTables() {
    tables.removeAll()
    valueTypes.removeAll()
    supertypeCache.removeAll()
    partsCache.removeAll()
    namespaceCache.removeAll()
    usingsCache.removeAll()
    aliasCache.removeAll()
    built = nil
  }

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }

  static let unknown = Answer(state: .unknown, sites: [])

  func summarize(_ sites: [Site]) -> Answer { sites.isEmpty ? Self.unknown : Answer(summarizing: sites) }

  // MARK: Namespaces

  var index: CSharpIndex {
    if let built { return built }
    let made = CSharpIndex()
    for u in 0..<project.projectUnits {
      let holder = project.units[u]
      for (position, item) in holder.decls.enumerated() where !item.isLocal {
        let ref = DeclRef(unit: Int32(u), decl: Int32(position))
        if item.kind == .namespace {
          var current = namespaceName(of: ref)
          while made.namespaces.insert(current).inserted, let dot = current.lastIndex(of: ".") { current = String(current[..<dot]) }
          continue
        }
        let parentKind = item.parent >= 0 ? holder.decls[Int(item.parent)].kind : .namespace
        if item.kind.isNominal, parentKind == .namespace {
          made.types[enclosingNamespace(ref), default: [:]][item.name, default: []].append(ref)
        }
        if item.kind == .function, item.paramCount > 0, holder.params[Int(item.paramStart)].label == CSharpWord.thisWord, item.parent >= 0 {
          let owner = DeclRef(unit: Int32(u), decl: item.parent)
          if decl(owner).kind == .classType, decl(owner).parent < 0 || holder.decls[Int(decl(owner).parent)].kind == .namespace {
            made.extensions[enclosingNamespace(owner), default: [:]][item.name, default: []].append(ref)
          }
        }
      }
      for (position, item) in holder.imports.enumerated() where item.isExported {
        made.globalImports[holder.moduleName, default: []].append((Int32(u), position))
      }
    }
    built = made
    return made
  }

  /// A namespace declaration's full name: its parents' and its own dotted name.
  func namespaceName(of ref: DeclRef) -> String {
    if let known = namespaceCache[ref] { return known }
    let holder = self.unit(ref)
    let item = decl(ref)
    var words: [String] = []
    var k = Int(item.first) + 1
    while k <= Int(item.nameToken) {
      if holder.csIsName(k) { words.append(holder.string(k)) }
      k += 1
    }
    var full = words.joined(separator: ".")
    if item.parent >= 0, holder.decls[Int(item.parent)].kind == .namespace {
      full = namespaceName(of: DeclRef(unit: ref.unit, decl: item.parent)) + "." + full
    }
    namespaceCache[ref] = full
    return full
  }

  /// The namespace a declaration is in ("" for the global one).
  func enclosingNamespace(_ ref: DeclRef) -> String {
    let holder = self.unit(ref)
    var parent = decl(ref).parent
    while parent >= 0 {
      if holder.decls[Int(parent)].kind == .namespace { return namespaceName(of: DeclRef(unit: ref.unit, decl: parent)) }
      parent = holder.decls[Int(parent)].parent
    }
    return ""
  }

  /// The library's types and extension methods of a namespace, its stub read the first time.
  func library(_ namespace: String) -> (types: [Name: [DeclRef]], extensions: [Name: [DeclRef]]) {
    if let known = libraryIndex[namespace] { return known }
    var types: [Name: [DeclRef]] = [:]
    var extensions: [Name: [DeclRef]] = [:]
    if layout.libraryNamespaces.contains(namespace),
      let module = project.ensureModule(name(CSharpLayout.libraryPrefix + namespace), display: CSharpLayout.libraryPrefix + namespace)
    {
      for unitIndex in module.units {
        let holder = project.units[Int(unitIndex)]
        for (position, item) in holder.decls.enumerated() {
          let ref = DeclRef(unit: unitIndex, decl: Int32(position))
          let parentKind = item.parent >= 0 ? holder.decls[Int(item.parent)].kind : .namespace
          if item.kind.isNominal, parentKind == .namespace { types[item.name, default: []].append(ref) }
          if item.kind == .function, item.paramCount > 0, holder.params[Int(item.paramStart)].label == CSharpWord.thisWord, item.parent >= 0 {
            extensions[item.name, default: []].append(ref)
          }
        }
      }
    }
    libraryIndex[namespace] = (types, extensions)
    return (types, extensions)
  }

  /// Whether a dotted name is a namespace the project or the library has.
  func isNamespace(_ namespace: String) -> Bool {
    !namespace.isEmpty && (index.namespaces.contains(namespace) || layout.libraryPrefixes.contains(namespace))
  }

  func namespaceSite(_ namespace: String) -> Site {
    let hashed = name(namespace)
    namespaceNames[hashed] = namespace
    return .module(hashed)
  }

  /// The projects a unit sees types of: its own and what it references (the library's are everyone's).
  func visibleModules(_ unitIndex: Int32) -> Set<Name> {
    let own = project.modules[project.units[Int(unitIndex)].moduleName]?.displayName ?? CSharpLayout.looseName
    return Set(layout.visibleProjects(of: own).map { name($0) })
  }

  /// A namespace's top-level types named so, of the arity asked (nil: any), that a unit can see.
  func namespaceTypes(_ namespace: String, named word: Name, arity: Int?, from unitIndex: Int32) -> [DeclRef] {
    var result: [DeclRef] = []
    if let own = index.types[namespace]?[word] {
      let visible = unitIndex >= 0 && Int(unitIndex) < project.projectUnits ? visibleModules(unitIndex) : nil
      for ref in own where arity == nil || Int(decl(ref).genericCount) == arity! {
        if let visible, !visible.contains(self.unit(ref).moduleName) { continue }
        // Another project's internal types aren't seen.
        if let visible, self.unit(ref).moduleName != project.units[Int(unitIndex)].moduleName, decl(ref).access < .isPublic, !visible.isEmpty { continue }
        result.append(ref)
      }
    }
    if !result.isEmpty { return result }
    for ref in library(namespace).types[word] ?? [] where arity == nil || Int(decl(ref).genericCount) == arity! { result.append(ref) }
    return result
  }

  /// `System.Object` and the other types everything leans on.
  func systemType(_ word: String, arity: Int = 0) -> DeclRef? { namespaceTypes("System", named: name(word), arity: arity, from: -1).first }

  /// A type's declaration and every other part of it (`partial`), the first part first.
  func parts(_ ref: DeclRef) -> [DeclRef] {
    if let known = partsCache[ref] { return known }
    let item = decl(ref)
    var result: [DeclRef] = [ref]
    if item.kind.isNominal, Int(ref.unit) < project.projectUnits {
      let holder = self.unit(ref)
      let parentKind = item.parent >= 0 ? holder.decls[Int(item.parent)].kind : .namespace
      if parentKind == .namespace {
        let module = holder.moduleName
        result = (index.types[enclosingNamespace(ref)]?[item.name] ?? [ref]).filter {
          decl($0).genericCount == item.genericCount && self.unit($0).moduleName == module
        }
      } else if parentKind.isNominal {
        result = []
        for parent in parts(DeclRef(unit: ref.unit, decl: item.parent)) {
          for child in self.unit(parent).children(of: parent.decl) {
            let other = self.unit(parent).decls[Int(child)]
            if other.kind.isNominal, other.name == item.name, other.genericCount == item.genericCount { result.append(DeclRef(unit: parent.unit, decl: child)) }
          }
        }
      }
      if result.isEmpty { result = [ref] }
    }
    for part in result { partsCache[part] = result }
    return result
  }

  /// The part a type is known by.
  func canonical(_ ref: DeclRef) -> DeclRef { decl(ref).kind.isNominal ? parts(ref)[0] : ref }

  // MARK: Usings

  /// The `using` directives of a scope: a namespace declaration's (`scope` its index), or the file's own (-1) with the
  /// project's global ones and the SDK's implicit ones.
  func usings(unitIndex: Int32, scope: Int32) -> CSharpUsings {
    let key = Int64(unitIndex) << 32 | Int64(UInt32(bitPattern: scope))
    if let known = usingsCache[key] { return known }
    var result = CSharpUsings()
    let holder = project.units[Int(unitIndex)]
    var entries: [(Int32, Int)] = []
    for (position, item) in holder.imports.enumerated() where usingScope(holder, item) == scope && !(scope < 0 && item.isExported) {
      entries.append((unitIndex, position))
    }
    if scope < 0 {
      entries += index.globalImports[holder.moduleName] ?? []
      let module = project.modules[holder.moduleName]?.displayName ?? CSharpLayout.looseName
      for implicit in layout.globalUsings(of: module) {
        if implicit.alias == nil, !implicit.isStatic { result.namespaces.append(implicit.name) }
        if implicit.isStatic, let type = qualifiedType(implicit.name.split(separator: ".").map(String.init)) { result.statics.append(type) }
      }
    }
    for (u, position) in entries {
      let owner = project.units[Int(u)]
      let item = owner.imports[position]
      if item.alias != 0 {
        result.aliases[item.alias] = (u, position)
      } else if owner.isToken(Int(item.token) - 1, "static") {
        let words = item.moduleName.split(separator: ".").map(String.init)
        if let type = qualifiedType(words) { result.statics.append(type) }
      } else if !result.namespaces.contains(item.moduleName) {
        result.namespaces.append(item.moduleName)
      }
    }
    usingsCache[key] = result
    return result
  }

  /// `parseType`'s scope for a `using` alias's target: the global namespace and the global usings.
  static let aliasScope: Int32 = -2

  /// The namespaces every file of a unit's project has: `global using`s and the SDK's implicit ones.
  func globalUsingNamespaces(_ unitIndex: Int32) -> [String] {
    let holder = project.units[Int(unitIndex)]
    var result: [String] = []
    for (u, position) in index.globalImports[holder.moduleName] ?? [] {
      let owner = project.units[Int(u)]
      let item = owner.imports[position]
      if item.alias == 0, !owner.isToken(Int(item.token) - 1, "static") { result.append(item.moduleName) }
    }
    let module = project.modules[holder.moduleName]?.displayName ?? CSharpLayout.looseName
    for implicit in layout.globalUsings(of: module) where implicit.alias == nil && !implicit.isStatic { result.append(implicit.name) }
    return result
  }

  /// The namespace declaration a `using` is in, -1 for the file's.
  func usingScope(_ holder: Unit, _ item: Import) -> Int32 {
    var scope: Int32 = -1
    for index in holder.chain(at: item.token) where holder.decls[Int(index)].kind == .namespace { scope = index }
    return scope
  }

  /// What a `using A = X;` alias names: a namespace or a type, read from the global namespace.
  func aliasTarget(unit u: Int32, item position: Int) -> [Site] {
    let key = Int64(u) << 32 | Int64(position)
    if let known = aliasCache[key] { return known }
    aliasCache[key] = []
    let holder = project.units[Int(u)]
    let item = holder.imports[position]
    var result: [Site] = []
    let start = Int(item.token)
    var end = start
    while end < holder.tokens.count, !holder.isByte(end, 0x3B) { end += 1 }
    let ty = parseType(unitIndex: u, start: Int32(start), end: Int32(end), scope: item.isExported ? -1 : Self.aliasScope)
    switch ty {
    case .nominal(let ref, _): result = parts(ref).map { .decl($0) }
    case .module(let hashed): result = [.module(hashed)]
    default:
      let words = item.moduleName.split(separator: ".").map(String.init)
      if !words.isEmpty, isNamespace(item.moduleName) { result = [namespaceSite(words.joined(separator: "."))] }
    }
    aliasCache[key] = result
    return result
  }

  /// A dotted name read from the global namespace: a type, its nested types.
  func qualifiedType(_ words: [String]) -> Ty? {
    var namespace = ""
    var type: Ty?
    for word in words {
      let hashed = name(word)
      if let current = type {
        guard let ref = memberTypeRefs(of: current, named: hashed, arity: nil).first else { return nil }
        type = .nominal(canonical(ref), [])
        continue
      }
      if let ref = namespaceTypes(namespace, named: hashed, arity: nil, from: -1).first {
        type = .nominal(canonical(ref), [])
        continue
      }
      namespace = namespace.isEmpty ? word : namespace + "." + word
    }
    return type
  }

  // MARK: Asking

  public func answer(path: String, line: Int, character: Int) -> Answer {
    guard let unitIndex = project.unitByPath[path] else { return Self.unknown }
    let unit = project.units[Int(unitIndex)]
    var offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    project.focus(unitIndex: unitIndex, offset: offset)
    let current = project.units[Int(unitIndex)]
    // `@class`: the name's token starts after the `@`.
    if offset + 1 < current.source.count, current.source.text[offset] == 0x40 { offset += 1 }
    guard let token = current.token(at: offset) else { return Self.unknown }
    return answer(unitIndex: unitIndex, token: token)
  }

  package func answer(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    guard unit.csIsName(token) else { return Self.unknown }
    // Words that name nothing here: `var` as a type, `nameof(…)`, `global::`, a discard.
    if unit.isToken(token, "_") {
      // A lambda's `_` parameter is declared there; any other `_` is a discard.
      if let body = body(unitIndex: unitIndex, token: Int32(token)), body.byToken[Int32(token)] != nil { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))]) }
      return Self.unknown
    }
    if unit.isToken(token, "var") || unit.isToken(token, "dynamic") { return Self.unknown }
    if unit.isToken(token, "nameof"), unit.isByte(token + 1, 0x28) { return Self.unknown }
    if unit.isToken(token + 1, "::") { return Self.unknown }
    if let item = importAt(unit, token) { return importAnswer(item, unit: unit, unitIndex: unitIndex, token: token) }
    if let namespace = namespaceDeclarationAt(unit, unitIndex: unitIndex, token: token) { return Answer(state: .exact, sites: [namespaceSite(namespace)]) }
    if let site = unit.declaredSite(at: token, unitIndex: unitIndex) ?? unit.declaredSiteFresh(at: token, unitIndex: unitIndex) {
      return declaredAnswer(site)
    }
    let body = body(unitIndex: unitIndex, token: Int32(token))
    if let body, body.byToken[Int32(token)] != nil { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))]) }
    // `name: value`, a named argument: the parameter of the call's method.
    if unit.isByte(token + 1, 0x3A), !unit.isToken(token + 1, "::"), let found = namedArgument(unitIndex: unitIndex, token: token) { return found }
    // `new T { Name = … }`, `x with { Name = … }`, `[A(Name = …)]`: a member of the type.
    if unit.isToken(token + 1, "="), let found = initializerMember(unitIndex: unitIndex, token: token) { return found }
    if let attribute = attributeName(unit, token) {
      return summarize(attributeSites(unitIndex: unitIndex, token: token, qualified: attribute))
    }
    if isCreationName(unit, token) { return creationAnswer(unitIndex: unitIndex, token: token) }
    if token > 0, unit.csIsDot(token - 1) { return selection(unitIndex: unitIndex, token: token) }
    if token > 0, unit.isToken(token - 1, "::") {
      // `global::A.B`.
      let word = unit.string(token)
      let types = namespaceTypes("", named: unit.hash(token), arity: arity(unit, token), from: unitIndex)
      if !types.isEmpty { return typeAnswer(types) }
      return isNamespace(word) ? Answer(state: .exact, sites: [namespaceSite(word)]) : Self.unknown
    }
    let word = unit.hash(token)
    if isTupleElementName(unit, token) { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))]) }
    if let open = callOpen(unit, token) { return callAnswer(unitIndex: unitIndex, token: token, word: word, open: open) }
    if isTypeContext(unit, token) {
      let types = typeSites(word, arity: arity(unit, token), unitIndex: unitIndex, token: Int32(token))
      if !types.isEmpty { return typeSummary(types) }
    }
    return typeSummary(nameSites(word, unitIndex: unitIndex, token: Int32(token)))
  }

  /// An element's name in a tuple type, `(int Count, string Name)`: declared there.
  func isTupleElementName(_ unit: Unit, _ token: Int) -> Bool {
    guard unit.isByte(token + 1, 0x2C) || unit.isByte(token + 1, 0x29) else { return false }
    var k = token - 1
    var budget = 200
    while k >= 0, budget > 0 {
      budget -= 1
      if unit.tokens[k].kind == .close, let open = unit.matchingOpen(k) {
        k = open - 1
        continue
      }
      if unit.tokens[k].kind == .open {
        guard unit.isByte(k, 0x28) else { return false }
        let close = unit.skipBalanced(k)
        guard unit.csTypeEnd(k, limit: close) == close else { return false }
        // Each element: a type, then maybe its name.
        var element = k + 1
        while element < close - 1, let typeEnd = unit.csTypeEnd(element, limit: close - 1) {
          if typeEnd == token { return true }
          element = typeEnd
          if unit.csIsName(element), !unit.isByte(element, 0x2C) { element += 1 }
          guard unit.isByte(element, 0x2C) else { return false }
          element += 1
        }
        return false
      }
      if unit.isByte(k, 0x3B) || unit.tokens[k].kind == .open { return false }
      k -= 1
    }
    return false
  }

  /// A declared name's answer: a type with all its parts, a partial method's implementation as its definition.
  func declaredAnswer(_ site: Site) -> Answer {
    guard case .decl(let ref) = site else { return Answer(state: .exact, sites: [site]) }
    let item = decl(ref)
    if item.kind.isNominal { return typeAnswer([ref]) }
    if item.kind == .function, item.bodyOpen >= 0, let definition = partialDefinition(ref) { return Answer(state: .exact, sites: [.decl(definition)]) }
    return Answer(state: .exact, sites: [site])
  }

  /// A partial method's declaration without a body, for its implementation.
  func partialDefinition(_ ref: DeclRef) -> DeclRef? {
    let item = decl(ref)
    let holder = self.unit(ref)
    guard item.parent >= 0, hasModifier(ref, "partial") else { return nil }
    for part in parts(DeclRef(unit: ref.unit, decl: item.parent)) {
      for child in self.unit(part).children(of: part.decl) {
        let other = self.unit(part).decls[Int(child)]
        if other.kind == .function, other.name == item.name, other.paramCount == item.paramCount, other.bodyOpen < 0 { return DeclRef(unit: part.unit, decl: child) }
      }
    }
    _ = holder
    return nil
  }

  /// Whether a declaration's modifiers include a word.
  func hasModifier(_ ref: DeclRef, _ word: StaticString) -> Bool {
    let item = decl(ref)
    let holder = self.unit(ref)
    var k = Int(item.first)
    let end = Int(item.typeStart >= 0 ? min(item.typeStart, item.nameToken) : item.nameToken)
    while k < end, k < holder.tokens.count {
      if holder.isToken(k, word) { return true }
      if holder.isByte(k, 0x5B) {
        k = holder.skipBalanced(k)
        continue
      }
      k += 1
    }
    return false
  }

  /// Every part of the types found, as one exact answer when they're one type.
  func typeAnswer(_ refs: [DeclRef]) -> Answer {
    guard let first = refs.first else { return Self.unknown }
    let all = parts(first)
    if refs.allSatisfy({ all.contains($0) }) { return Answer(state: .exact, sites: all.map { .decl($0) }) }
    return summarize(refs.map { .decl($0) })
  }

  /// Sites, a type's parts kept together as one answer.
  func typeSummary(_ sites: [Site]) -> Answer {
    guard !sites.isEmpty else { return Self.unknown }
    let refs = sites.compactMap { site -> DeclRef? in if case .decl(let ref) = site { return ref } else { return nil } }
    if refs.count == sites.count, refs.allSatisfy({ decl($0).kind.isNominal }) { return typeAnswer(refs) }
    return summarize(sites)
  }

  /// The arity written after a type's name: `List<int>` 1, `Dictionary<,>` 2, none 0.
  func arity(_ unit: Unit, _ token: Int) -> Int {
    let open = token + 1
    guard open < unit.tokens.count, unit.tokens[open].kind == .punctuation, unit.startsWith(open, 0x3C), let end = unit.csTypeArgumentsEnd(open) else { return 0 }
    // Commas at the list's own depth, counting `<` and `>` by the byte (`>>` closes two).
    var count = 1
    var depth = 0
    var k = open
    while k < end {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.tokens[k].kind == .punctuation {
        for b in 0..<unit.tokens[k].length {
          switch unit.source.text[unit.tokens[k].start + b] {
          case 0x3C: depth += 1
          case 0x3E: depth -= 1
          case 0x2C: if depth == 1 { count += 1 }
          default: break
          }
        }
        if depth <= 0 { break }
      }
      k += 1
    }
    return count
  }

  /// The `(` of a call whose name is at `token`: `f(`, `f<T>(`.
  func callOpen(_ unit: Unit, _ token: Int) -> Int? {
    if unit.isByte(token + 1, 0x28) { return token + 1 }
    // A type argument: `new A<B<C>>()`'s `>>` closes both lists before the `(`.
    let before = token - 1
    if unit.tokens.indices.contains(before), unit.tokens[before].kind == .punctuation,
      unit.startsWith(before, 0x3C) && unit.csIsName(before - 1) && unit.csTypeArgumentsEnd(before) != nil || unit.isByte(before, 0x2C) && isInTypeArguments(unit, before)
    {
      return nil
    }
    if unit.tokens.indices.contains(token + 1), unit.tokens[token + 1].kind == .punctuation, unit.startsWith(token + 1, 0x3C), let end = unit.csTypeArgumentsEnd(token + 1), unit.isByte(end, 0x28) {
      return end
    }
    return nil
  }

  /// A name in `namespace A.B.C`: the namespace its words up to it name.
  private func namespaceDeclarationAt(_ unit: Unit, unitIndex: Int32, token: Int) -> String? {
    var k = token
    while k > 0, unit.isByte(k - 1, 0x2E), unit.csIsName(k - 2) { k -= 2 }
    guard unit.isToken(k - 1, "namespace") else { return nil }
    var words: [String] = []
    var i = k
    while i <= token {
      if unit.csIsName(i) { words.append(unit.string(i)) }
      i += 1
    }
    var full = words.joined(separator: ".")
    for index in unit.chain(at: Int32(k - 1)).reversed() where unit.decls[Int(index)].kind == .namespace && unit.decls[Int(index)].first < Int32(k - 1) {
      full = namespaceName(of: DeclRef(unit: unitIndex, decl: index)) + "." + full
      break
    }
    return full
  }

  /// Whether a name is (part of) the type a `new` creates.
  func isCreationName(_ unit: Unit, _ token: Int) -> Bool {
    var k = token
    while k > 1, unit.isByte(k - 1, 0x2E), unit.csIsName(k - 2) { k -= 2 }
    if k > 1, unit.isToken(k - 1, "::") { k -= 2 }
    return k > 0 && unit.isToken(k - 1, "new")
  }

  private func creationAnswer(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    if token > 0, unit.isByte(token - 1, 0x2E) {
      switch operandType(unitIndex: unitIndex, dot: token - 1) {
      case .module(let hashed):
        let namespace = namespaceNames[hashed] ?? ""
        let types = namespaceTypes(namespace, named: unit.hash(token), arity: arity(unit, token), from: unitIndex)
        if !types.isEmpty { return typeAnswer(types) }
        let sub = namespace + "." + unit.string(token)
        return isNamespace(sub) ? Answer(state: .exact, sites: [namespaceSite(sub)]) : Self.unknown
      case .meta(let type): return typeAnswer(memberTypeRefs(of: type, named: unit.hash(token), arity: arity(unit, token)))
      default: return Self.unknown
      }
    }
    let types = typeSites(unit.hash(token), arity: arity(unit, token), unitIndex: unitIndex, token: Int32(token))
    if types.isEmpty, unit.isByte(token + 1, 0x2E) {
      let found = nameSites(unit.hash(token), unitIndex: unitIndex, token: Int32(token))
      return summarize(found)
    }
    return typeSummary(types)
  }

  /// A name where only a type is written: a declaration's type (`Type name`), type arguments, `is`/`as`, a cast,
  /// `typeof(…)`, a base list, a constraint.
  func isTypeContext(_ unit: Unit, _ token: Int) -> Bool {
    let before = token - 1
    if unit.isToken(before, "is") || unit.isToken(before, "as") || unit.isToken(before, "typeof") && false || unit.isToken(before, "sizeof") && false {
      return true
    }
    if unit.isToken(before, "not") && unit.isToken(before - 1, "is") { return true }
    let after = token + 1
    // `Type name`, `Type? name`, `Type[] name`, `Type<…> name`.
    if unit.csIsName(after), !unit.isToken(after, "is"), !unit.isToken(after, "as"), !unit.isToken(after, "when"), !unit.isToken(after, "and"), !unit.isToken(after, "or") {
      return true
    }
    if let end = unit.csTypeEnd(token), end > token + 1, unit.csIsName(end) || unit.isByte(end, 0x29) && unit.isByte(before, 0x28) { return true }
    if unit.tokens.indices.contains(before), unit.tokens[before].kind == .punctuation, unit.startsWith(before, 0x3C) || unit.isByte(before, 0x2C) && isInTypeArguments(unit, before) {
      return true
    }
    if unit.isByte(before, 0x3A), isInBaseList(unit, before) { return true }
    // `(Type)x`: a cast when an operand follows.
    if unit.isByte(before, 0x28), let end = unit.csTypeEnd(token), unit.isByte(end, 0x29), end + 1 < unit.tokens.count {
      let next = end + 1
      let kind = unit.tokens[next].kind
      if kind == .identifier || kind == .string || kind == .number || unit.isByte(next, 0x28) || unit.isToken(next, "this") || unit.isToken(next, "new") || unit.isToken(next, "await") {
        return before == 0 || !unit.csIsName(before - 1) || unit.isToken(before - 1, "return")
      }
    }
    return false
  }

  private func isInTypeArguments(_ unit: Unit, _ comma: Int) -> Bool {
    var k = comma - 1
    var budget = 40
    while k >= 0, budget > 0 {
      budget -= 1
      if unit.tokens[k].kind == .punctuation, unit.startsWith(k, 0x3C) { return k > 0 && unit.csIsName(k - 1) && unit.csTypeArgumentsEnd(k) != nil }
      if unit.tokens[k].kind == .open || unit.isByte(k, 0x3B) || unit.isToken(k, "=") { return false }
      k -= 1
    }
    return false
  }

  private func isInBaseList(_ unit: Unit, _ colon: Int) -> Bool {
    var k = colon - 1
    if unit.tokens.indices.contains(k), unit.tokens[k].kind == .close, let open = unit.matchingOpen(k) { k = open - 1 }
    if unit.tokens.indices.contains(k), unit.tokens[k].kind == .punctuation, unit.startsWith(k, 0x3E) {
      while k > 0, !(unit.tokens[k].kind == .punctuation && unit.startsWith(k, 0x3C)) { k -= 1 }
      k -= 1
    }
    guard unit.csIsName(k) else { return false }
    return unit.isToken(k - 1, "class") || unit.isToken(k - 1, "struct") || unit.isToken(k - 1, "interface") || unit.isToken(k - 1, "record") || unit.isToken(k - 1, "enum")
  }

  // MARK: Imports

  /// The `using` directive whose target holds a token.
  func importAt(_ unit: Unit, _ token: Int) -> Import? {
    for item in unit.imports {
      var start = Int(item.token)
      if item.aliasToken >= 0 { start = Int(item.aliasToken) }
      guard start <= token else { continue }
      var end = start
      while end < unit.tokens.count, !unit.isByte(end, 0x3B) { end += 1 }
      if token < end { return item }
    }
    return nil
  }

  private func importAnswer(_ item: Import, unit: Unit, unitIndex: Int32, token: Int) -> Answer {
    if Int(item.aliasToken) == token { return Self.unknown }
    // The target as a qualified name: each word a namespace, then a type and its nested types.
    var words: [Int] = []
    var k = Int(item.token)
    while k <= token {
      if unit.csIsName(k) {
        if unit.isToken(k + 1, "::") {
          k += 2
          continue
        }
        words.append(k)
        if !unit.isByte(k + 1, 0x2E) { break }
      }
      k += 1
    }
    guard words.last == token else {
      // Inside type arguments: an ordinary type name, read from the global namespace and its usings.
      let types = typeSites(unit.hash(token), arity: arity(unit, token), unitIndex: unitIndex, token: Int32(token))
      return typeSummary(types)
    }
    let sites = qualifiedSites(words.map { unit.string($0) }, arities: words.map { arity(unit, $0) }, from: unitIndex)
    guard let last = sites.last, sites.count == words.count else { return Self.unknown }
    return typeSummary(last)
  }

  /// What a qualified name's words name, each, from the global namespace: namespaces, then a type, its nested types.
  func qualifiedSites(_ words: [String], arities: [Int], from unitIndex: Int32) -> [[Site]] {
    var result: [[Site]] = []
    var namespace = ""
    var type: Ty?
    for (index, word) in words.enumerated() {
      let hashed = name(word)
      let wanted = index < arities.count ? arities[index] : 0
      if let current = type {
        let found = memberTypeRefs(of: current, named: hashed, arity: wanted)
        result.append(found.map { .decl($0) })
        guard let first = found.first else { break }
        type = .nominal(canonical(first), [])
        continue
      }
      let candidate = namespace.isEmpty ? word : namespace + "." + word
      let types = namespaceTypes(namespace, named: hashed, arity: wanted, from: unitIndex)
      // A namespace wins over a type only where the type isn't there.
      if !types.isEmpty, !(index < words.count - 1 && isNamespace(candidate) && wanted == 0 && types.isEmpty) {
        result.append(types.map { .decl($0) })
        type = .nominal(canonical(types[0]), [])
        continue
      }
      namespace = candidate
      result.append(isNamespace(namespace) ? [namespaceSite(namespace)] : [])
    }
    return result
  }

  // MARK: Bodies

  /// The member whose body holds a token: the outermost, as lambdas and local functions are scanned with it.
  func owner(unitIndex: Int32, token: Int32) -> Int32? {
    let unit = project.units[Int(unitIndex)]
    for index in unit.chain(at: token) {
      let item = unit.decls[Int(index)]
      if item.isLocal { continue }
      switch item.kind {
      case .function, .initializer, .deinitializer, .subscriptDecl:
        if item.bodyOpen >= 0 || item.paramCount > 0 || item.initStart >= 0 { return index }
      case .variable, .enumCase:
        if item.bodyOpen >= 0, token >= item.bodyOpen, token <= item.bodyClose { return index }
        if item.initStart >= 0, token >= item.initStart, token <= item.initEnd { return index }
      case .classType, .structure:
        // A primary constructor's parameters and its base's arguments.
        if item.paramCount > 0, token < item.bodyOpen || item.bodyOpen < 0 { return index }
        if item.initStart >= 0, token >= item.initStart, token <= item.initEnd { return index }
      case .extensionDecl:
        if item.paramCount > 0, token < item.bodyOpen { return index }
      default:
        break
      }
    }
    return nil
  }

  func body(unitIndex: Int32, token: Int32) -> CSharpBody? {
    guard let owner = owner(unitIndex: unitIndex, token: token) else { return nil }
    let unit = project.units[Int(unitIndex)]
    if let known = unit.scans[owner] { return unsafeDowncast(known, to: CSharpBody.self) }
    let scan = CSharpBody(unit: unit, owner: owner)
    unit.scans[owner] = scan
    return scan
  }

  // MARK: Names

  /// The types around a token, innermost first.
  func enclosingTypes(unitIndex: Int32, token: Int32) -> [DeclRef] {
    let unit = project.units[Int(unitIndex)]
    var result: [DeclRef] = []
    for index in unit.chain(at: token).reversed() {
      let item = unit.decls[Int(index)]
      if item.kind.isNominal { result.append(DeclRef(unit: unitIndex, decl: index)) }
    }
    return result
  }

  /// The type of a type seen from inside it: its type parameters as its arguments.
  func ownType(_ ref: DeclRef) -> Ty {
    let item = decl(ref)
    let holder = self.unit(ref)
    var args: [Ty] = []
    for g in 0..<Int(item.genericCount) { args.append(.param(holder.generics[Int(item.genericStart) + g].name, ref)) }
    // A nested type of a generic type is read with its outer type's parameters too: they're in scope.
    return .nominal(canonical(ref), args)
  }

  /// The namespace levels a token sees, innermost first: each with the declaration whose usings come with it (-1 for
  /// the compilation unit; none for a dotted name's outer parts).
  func namespaceLevels(unitIndex: Int32, token: Int32) -> [(namespace: String, scope: Int32?)] {
    let unit = project.units[Int(unitIndex)]
    var levels: [(String, Int32?)] = []
    for index in unit.chain(at: token).reversed() where unit.decls[Int(index)].kind == .namespace {
      let full = namespaceName(of: DeclRef(unit: unitIndex, decl: index))
      let parentFull: String = {
        let parent = unit.decls[Int(index)].parent
        guard parent >= 0, unit.decls[Int(parent)].kind == .namespace else { return "" }
        return namespaceName(of: DeclRef(unit: unitIndex, decl: parent))
      }()
      levels.append((full, index))
      var current = full
      while let dot = current.lastIndex(of: "."), String(current[..<dot]).count > parentFull.count {
        current = String(current[..<dot])
        levels.append((current, nil))
      }
    }
    levels.append(("", -1))
    return levels
  }

  /// A simple name used as a type: type parameters, nested types up the enclosing types (inherited too), then each
  /// namespace level's types, aliases and using namespaces' types.
  func typeSites(_ word: Name, arity: Int?, unitIndex: Int32, token: Int32) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    for index in unit.chain(at: token).reversed() {
      let item = unit.decls[Int(index)]
      if arity == nil || arity == 0 {
        for g in 0..<Int(item.genericCount) where unit.generics[Int(item.genericStart) + g].name == word {
          return [.generic(unit: unitIndex, token: unit.generics[Int(item.genericStart) + g].token)]
        }
      }
      // Local types in a body.
      if item.kind == .function || item.kind == .initializer {
        for child in unit.children(of: index) {
          let local = unit.decls[Int(child)]
          if local.kind.isNominal, local.name == word, arity == nil || Int(local.genericCount) == arity! { return [.decl(DeclRef(unit: unitIndex, decl: child))] }
        }
      }
      if item.kind.isNominal {
        let ref = DeclRef(unit: unitIndex, decl: index)
        let found = memberTypeRefs(of: ownType(ref), named: word, arity: arity)
        if !found.isEmpty { return found.map { .decl($0) } }
        if item.name == word, arity == nil || Int(item.genericCount) == arity! { return [.decl(ref)] }
      }
    }
    for level in namespaceLevels(unitIndex: unitIndex, token: token) {
      let types = namespaceTypes(level.namespace, named: word, arity: arity, from: unitIndex)
      if !types.isEmpty { return types.map { .decl($0) } }
      guard let scope = level.scope else { continue }
      let found = usingTypes(word, arity: arity, unitIndex: unitIndex, scope: scope)
      if !found.isEmpty { return found }
    }
    return []
  }

  /// What a scope's usings bring in as a type named so: an alias's type, the using namespaces' types, `using static`
  /// types' nested types.
  func usingTypes(_ word: Name, arity: Int?, unitIndex: Int32, scope: Int32) -> [Site] {
    let scoped = usings(unitIndex: unitIndex, scope: scope)
    if arity == nil || arity == 0, let alias = scoped.aliases[word] {
      let target = aliasTarget(unit: alias.unit, item: alias.item)
      if !target.isEmpty { return target }
    }
    var found: [Site] = []
    for namespace in scoped.namespaces {
      for ref in namespaceTypes(namespace, named: word, arity: arity, from: unitIndex) where !found.contains(.decl(ref)) { found.append(.decl(ref)) }
    }
    if !found.isEmpty { return found }
    for type in scoped.statics {
      let nested = memberTypeRefs(of: type, named: word, arity: arity)
      if !nested.isEmpty { return nested.map { .decl($0) } }
    }
    return []
  }

  /// A simple name used as a value, else a type, else a namespace.
  func nameSites(_ word: Name, unitIndex: Int32, token: Int32) -> [Site] {
    let values = valueSites(word, unitIndex: unitIndex, token: token)
    if !values.isEmpty { return values }
    let unit = project.units[Int(unitIndex)]
    let types = typeSites(word, arity: arity(unit, Int(token)), unitIndex: unitIndex, token: token)
    if !types.isEmpty { return types }
    // A namespace: `System.Console`, from each level outward (`Inner` in namespace `Outer`), or an alias's.
    for level in namespaceLevels(unitIndex: unitIndex, token: token) {
      let candidate = level.namespace.isEmpty ? unit.string(Int(token)) : level.namespace + "." + unit.string(Int(token))
      if isNamespace(candidate) { return [namespaceSite(candidate)] }
      if let scope = level.scope, let alias = usings(unitIndex: unitIndex, scope: scope).aliases[word] {
        let target = aliasTarget(unit: alias.unit, item: alias.item)
        if !target.isEmpty { return target }
      }
    }
    return []
  }

  /// A simple name as a variable: a local, a member of an enclosing type (inherited too) or a primary constructor's
  /// parameter, a `using static` type's member.
  func valueSites(_ word: Name, unitIndex: Int32, token: Int32) -> [Site] {
    let body = body(unitIndex: unitIndex, token: token)
    if let body, let local = body.local(named: word, at: token) { return [.local(unit: unitIndex, token: body.locals[Int(local)].token)] }
    let unit = project.units[Int(unitIndex)]
    for index in unit.chain(at: token).reversed() {
      let item = unit.decls[Int(index)]
      // A local function's or a lambda's enclosing method's parameters were the body's.
      if item.kind.isNominal {
        let ref = DeclRef(unit: unitIndex, decl: index)
        let members = memberSites(of: ownType(ref), named: word).filter { !decl($0).kind.isNominal && decl($0).kind != .initializer }
        if !members.isEmpty { return members.map { .decl($0) } }
        // A primary constructor's parameter, in the type's body.
        for p in 0..<Int(item.paramCount) where unit.params[Int(item.paramStart) + p].local == word {
          return [.local(unit: unitIndex, token: unit.params[Int(item.paramStart) + p].nameToken)]
        }
      }
    }
    for level in namespaceLevels(unitIndex: unitIndex, token: token) {
      guard let scope = level.scope else { continue }
      for type in usings(unitIndex: unitIndex, scope: scope).statics {
        let members = memberSites(of: type, named: word).filter { (decl($0).isStatic || decl($0).kind == .enumCase) && !decl($0).kind.isNominal }
        if !members.isEmpty { return members.map { .decl($0) } }
      }
    }
    return []
  }

  /// `name(…)`: a local (a delegate), a local function, the methods of the innermost enclosing type that has one so
  /// named, `using static` methods.
  private func callAnswer(unitIndex: Int32, token: Int, word: Name, open: Int) -> Answer {
    let found = simpleMethods(word, unitIndex: unitIndex, token: Int32(token))
    switch found {
    case .value(let sites): return summarize(sites)
    case .methods(let methods, let receiver):
      guard !methods.isEmpty else { return Self.unknown }
      return chooseAnswer(methods, unitIndex: unitIndex, open: open, receiver: receiver, receiverValue: nil)
    }
  }

  enum Callee {
    /// A variable called: a delegate.
    case value([Site])
    case methods([DeclRef], Ty)
  }

  /// What a simple call names.
  func simpleMethods(_ word: Name, unitIndex: Int32, token: Int32) -> Callee {
    let unit = project.units[Int(unitIndex)]
    if let body = body(unitIndex: unitIndex, token: token), let local = body.local(named: word, at: token) {
      return .value([.local(unit: unitIndex, token: body.locals[Int(local)].token)])
    }
    // Local functions: declared in the bodies around the token.
    for index in unit.chain(at: token).reversed() {
      let item = unit.decls[Int(index)]
      guard item.kind == .function || item.kind == .initializer || item.kind == .variable || item.kind == .subscriptDecl || item.kind == .deinitializer else { continue }
      let locals = unit.children(of: index).filter { unit.decls[Int($0)].isLocal && unit.decls[Int($0)].kind == .function && unit.decls[Int($0)].name == word }
      if !locals.isEmpty { return .methods(locals.map { DeclRef(unit: unitIndex, decl: $0) }, .unknown) }
    }
    for index in unit.chain(at: token).reversed() where unit.decls[Int(index)].kind.isNominal {
      let own = ownType(DeclRef(unit: unitIndex, decl: index))
      let members = memberSites(of: own, named: word)
      let methods = members.filter { decl($0).kind == .function }
      if !methods.isEmpty { return .methods(methods, own) }
      let values = members.filter { decl($0).kind == .variable }
      if !values.isEmpty { return .value(values.map { .decl($0) }) }
    }
    for level in namespaceLevels(unitIndex: unitIndex, token: token) {
      guard let scope = level.scope else { continue }
      for type in usings(unitIndex: unitIndex, scope: scope).statics {
        let methods = memberSites(of: type, named: word).filter { decl($0).kind == .function && decl($0).isStatic }
        if !methods.isEmpty { return .methods(methods, type) }
      }
    }
    return .methods([], .unknown)
  }

  /// `x.name`: a namespace's type or namespace, a type's nested type or static member, a value's member, an extension
  /// method.
  private func selection(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    let word = unit.hash(token)
    var receiver = operandType(unitIndex: unitIndex, dot: token - 1)
    if unit.isToken(token - 1, "?."), let inner = nullableValue(receiver) { receiver = inner }
    let open = callOpen(unit, token)
    switch receiver {
    case .module(let hashed):
      let namespace = namespaceNames[hashed] ?? ""
      let types = namespaceTypes(namespace, named: word, arity: arity(unit, token), from: unitIndex)
      if !types.isEmpty { return typeAnswer(types) }
      let sub = namespace + "." + unit.string(token)
      return isNamespace(sub) ? Answer(state: .exact, sites: [namespaceSite(sub)]) : Self.unknown
    case .unknown:
      // What couldn't be told: the project's members of that name, as candidates by name.
      let found = project.membersNamed(word).filter { open != nil ? decl($0).kind == .function : decl($0).kind == .variable || decl($0).kind == .enumCase }
      guard !found.isEmpty else { return Self.unknown }
      return Answer(state: .candidates, sites: found.prefix(12).map { .decl($0) }, byNameOnly: true)
    case .meta(let type):
      let nested = memberTypeRefs(of: type, named: word, arity: arity(unit, token))
      if !nested.isEmpty, open == nil || unit.isToken(token + 1, "<") == false && open == nil { return typeAnswer(nested) }
      let members = memberSites(of: type, named: word).filter { !decl($0).kind.isNominal && decl($0).kind != .initializer }
      if let open {
        let methods = members.filter { decl($0).kind == .function }
        if !methods.isEmpty { return chooseAnswer(methods, unitIndex: unitIndex, open: open, receiver: type, receiverValue: nil) }
        let values = members.filter { decl($0).kind == .variable }
        return summarize(values.map { .decl($0) })
      }
      if !members.isEmpty { return summarize(members.map { .decl($0) }) }
      return typeAnswer(nested)
    default:
      let members = memberSites(of: receiver, named: word).filter { !decl($0).kind.isNominal && decl($0).kind != .initializer }
      if let open {
        let methods = members.filter { decl($0).kind == .function }
        if !methods.isEmpty {
          let chosen = chooseOverload(methods, unitIndex: unitIndex, open: open, receiver: receiver, receiverValue: nil)
          if !chosen.isEmpty { return summarize(chosen.map { .decl($0) }) }
        }
        let values = members.filter { decl($0).kind == .variable }
        if !values.isEmpty, methods.isEmpty { return summarize(values.map { .decl($0) }) }
        let extensions = extensionMethods(word, unitIndex: unitIndex, token: Int32(token), receiver: receiver)
        if !extensions.isEmpty {
          let chosen = chooseOverload(extensions, unitIndex: unitIndex, open: open, receiver: .unknown, receiverValue: receiver)
          if !chosen.isEmpty { return summarize(chosen.map { .decl($0) }) }
          if methods.isEmpty { return Answer(state: .candidates, sites: extensions.map { .decl($0) }) }
        }
        return methods.isEmpty ? Self.unknown : Answer(state: .candidates, sites: methods.map { .decl($0) })
      }
      return summarize(members.map { .decl($0) })
    }
  }

  /// The overload a call at `open` means, or the ones it may.
  func chooseAnswer(_ found: [DeclRef], unitIndex: Int32, open: Int, receiver: Ty, receiverValue: Ty?) -> Answer {
    let chosen = chooseOverload(found, unitIndex: unitIndex, open: open, receiver: receiver, receiverValue: receiverValue)
    if chosen.isEmpty { return found.isEmpty ? Self.unknown : Answer(state: .candidates, sites: found.map { .decl($0) }) }
    return summarize(chosen.map { .decl($0) })
  }

  /// The extension methods named so in the namespaces a token sees (each level's own and its usings') whose `this`
  /// parameter a receiver of this type fits; when its type isn't known, every one of the name.
  func extensionMethods(_ word: Name, unitIndex: Int32, token: Int32, receiver: Ty) -> [DeclRef] {
    var found: [DeclRef] = []
    func take(_ namespace: String) {
      for ref in index.extensions[namespace]?[word] ?? [] where !found.contains(ref) { found.append(ref) }
      for ref in library(namespace).extensions[word] ?? [] where !found.contains(ref) { found.append(ref) }
    }
    for level in namespaceLevels(unitIndex: unitIndex, token: token) {
      take(level.namespace)
      if let scope = level.scope { for namespace in usings(unitIndex: unitIndex, scope: scope).namespaces { take(namespace) } }
    }
    // Static classes `using static` names.
    for level in namespaceLevels(unitIndex: unitIndex, token: token) {
      guard let scope = level.scope else { continue }
      for type in usings(unitIndex: unitIndex, scope: scope).statics {
        for ref in memberSites(of: type, named: word) where isExtensionMethod(ref) && !found.contains(ref) { found.append(ref) }
      }
    }
    guard receiver != .unknown else { return found }
    return found.filter { receiverFits($0, receiver) != false }
  }

  func isExtensionMethod(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    return item.kind == .function && item.paramCount > 0 && self.unit(ref).params[Int(item.paramStart)].label == CSharpWord.thisWord
  }

  /// Whether a receiver fits an extension method's `this` parameter: nil when it can't be told.
  func receiverFits(_ ref: DeclRef, _ receiver: Ty) -> Bool? {
    let holder = self.unit(ref)
    let item = decl(ref)
    let param = holder.params[Int(item.paramStart)]
    let want = parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: item.nameToken)
    if case .param = want { return true }
    // A generic method's parameter in the receiver's type: the declaration must match, the arguments are inferred.
    if case .nominal(let target, _) = want {
      if asSupertype(receiver, target) != nil { return true }
      if case .nominal(let have, _) = memberBase(receiver), decl(have).kind == .protocolType || decl(target).kind == .protocolType {
        return assignable(receiver, to: want)
      }
    }
    return assignable(receiver, to: want)
  }

  // MARK: Named arguments and initializers

  /// `f(name: value)`: the parameter of the method the call chose.
  private func namedArgument(unitIndex: Int32, token: Int) -> Answer? {
    let unit = project.units[Int(unitIndex)]
    guard let open = unit.matchingOpenBefore(token), unit.isByte(open, 0x28) || unit.isByte(open, 0x5B) else { return nil }
    // Only an argument's start: after `(` or `,`.
    guard unit.isByte(token - 1, 0x28) || unit.isByte(token - 1, 0x2C) || unit.isByte(token - 1, 0x5B) else { return nil }
    // `(a: 1, b: 2)`, a tuple, has no call.
    guard let call = callTarget(unitIndex: unitIndex, open: open) else { return Self.unknown }
    let chosen = chooseOverload(call.methods, unitIndex: unitIndex, open: open, receiver: call.receiver, receiverValue: call.receiverValue)
    let word = unit.hash(token)
    var sites: [Site] = []
    for ref in chosen.isEmpty ? call.methods : chosen {
      let holder = self.unit(ref)
      let item = decl(ref)
      for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].local == word {
        sites.append(.local(unit: ref.unit, token: holder.params[Int(item.paramStart) + p].nameToken))
      }
    }
    return summarize(sites)
  }

  /// `new T { Name = … }`, `x with { Name = … }`, `[Attr(Name = …)]`: the member of what's created.
  private func initializerMember(unitIndex: Int32, token: Int) -> Answer? {
    let unit = project.units[Int(unitIndex)]
    guard let open = unit.matchingOpenBefore(token), unit.isByte(token - 1, 0x7B) || unit.isByte(token - 1, 0x2C) || unit.isByte(token - 1, 0x28) else { return nil }
    var type: Ty = .unknown
    if unit.isByte(open, 0x7B), unit.isToken(open - 1, "new") {
      // An anonymous type's member is declared here.
      return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))])
    }
    if unit.isByte(open, 0x7B) {
      guard let created = initializedType(unitIndex: unitIndex, brace: open) else { return nil }
      type = created
    } else if unit.isByte(open, 0x28), open > 0, let attribute = attributeName(unit, open - 1) {
      let sites = attributeSites(unitIndex: unitIndex, token: open - 1, qualified: attribute)
      guard case .decl(let ref)? = sites.first else { return Self.unknown }
      type = .nominal(canonical(ref), [])
    } else {
      return nil
    }
    let members = memberSites(of: type, named: unit.hash(token)).filter { decl($0).kind == .variable || decl($0).kind == .subscriptDecl }
    return summarize(members.map { .decl($0) })
  }

  /// The type an object initializer's `{` initializes: `new T(…) {`, `new T {`, `new() {` (the target's), `x with {`,
  /// or a nested member's `Name = {`.
  func initializedType(unitIndex: Int32, brace: Int) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    var k = brace - 1
    if unit.isToken(k, "with") {
      return expressionType(unitIndex: unitIndex, start: Int32(expressionStart(unit, before: k)), end: Int32(k))
    }
    if unit.isToken(k, "="), unit.csIsName(k - 1), let outer = unit.matchingOpenBefore(k - 1), unit.isByte(outer, 0x7B), let owner = initializedType(unitIndex: unitIndex, brace: outer) {
      guard let entry = memberEntries(of: owner, named: unit.hash(k - 1)).first(where: { decl($0.0.ref).kind == .variable }) else { return .unknown }
      return memberValueType(entry.0)
    }
    if unit.isByte(k, 0x29), let open = unit.matchingOpen(k) { k = open - 1 }
    // Back to `new`.
    var start = k
    var budget = 80
    while start >= 0, !unit.isToken(start, "new") {
      budget -= 1
      // A comma inside the type's arguments (`new A<B, C> {`) doesn't stop it.
      if budget < 0 || unit.isByte(start, 0x3B) || unit.isByte(start, 0x7B) || unit.isByte(start, 0x7D) || unit.isToken(start, "=") || unit.isByte(start, 0x28) || unit.isByte(start, 0x2C) && !isInTypeArguments(unit, start) { return nil }
      if unit.tokens[start].kind == .close, let open = unit.matchingOpen(start) {
        start = open - 1
        continue
      }
      start -= 1
    }
    guard start >= 0 else { return nil }
    let end = brace
    return expressionType(unitIndex: unitIndex, start: Int32(start), end: Int32(end))
  }

  // MARK: Attributes

  /// When a name is an attribute's (`[Name]`, `[A.Name(…)]`, `[return: Name]`): the qualified words' tokens.
  func attributeName(_ unit: Unit, _ token: Int) -> [Int]? {
    var k = token
    while k > 1, unit.isByte(k - 1, 0x2E), unit.csIsName(k - 2) { k -= 2 }
    let before = k - 1
    guard before >= 0 else { return nil }
    var isAttribute = false
    if unit.isByte(before, 0x5B) || unit.isByte(before, 0x2C) || unit.isByte(before, 0x3A) && unit.csIsName(before - 1) && unit.isByte(before - 2, 0x5B) {
      guard let open = unit.isByte(before, 0x5B) ? before : unit.matchingOpenBefore(before), unit.isByte(open, 0x5B) else { return nil }
      // An attribute list starts a declaration, a parameter or a statement, not an index.
      let previous = open - 1
      isAttribute = previous < 0 || unit.isByte(previous, 0x7B) || unit.isByte(previous, 0x7D) || unit.isByte(previous, 0x3B) || unit.isByte(previous, 0x5D)
        || unit.isByte(previous, 0x28) || unit.isByte(previous, 0x2C) && !unit.csIsName(open + 1) == false && unit.matchingOpenBefore(previous).map { unit.isByte($0, 0x28) } == true
        || unit.tokens[previous].kind == .directive || unit.isByte(previous, 0x3C) || unit.isByte(previous, 0x29)
      if unit.isByte(previous, 0x29) {
        // `f(x)[0]` is an index; `)` before an attribute only in a lambda's parameter list, rare: not taken.
        isAttribute = false
      }
      // `x = [a, b]` and `foo[bar]`: a collection expression or an index.
      if unit.isByte(previous, 0x2C) || unit.isByte(previous, 0x28) {
        isAttribute = isParameterAttribute(unit, open)
      }
    }
    guard isAttribute else { return nil }
    var words: [Int] = []
    var i = k
    while i <= token {
      if unit.csIsName(i) { words.append(i) }
      i += 1
    }
    return words
  }

  /// `[A] int x` in a parameter list, `[A] T` in type parameters: an attribute when a declaration follows the `]`.
  private func isParameterAttribute(_ unit: Unit, _ open: Int) -> Bool {
    let close = unit.skipBalanced(open)
    guard close < unit.tokens.count else { return false }
    if unit.isToken(close, "this") || unit.isToken(close, "ref") || unit.isToken(close, "out") || unit.isToken(close, "in") || unit.isToken(close, "params") { return true }
    if let end = unit.csTypeEnd(close), unit.csIsName(end) { return true }
    return false
  }

  /// An attribute's type: `NameAttribute`, else `Name`.
  func attributeSites(unitIndex: Int32, token: Int, qualified words: [Int]) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    guard let last = words.last, last == token else {
      // A namespace or an outer type on the way.
      let sites = qualifiedFromScope(words.filter { $0 <= token }, unitIndex: unitIndex)
      return sites
    }
    let text = unit.string(token)
    for candidate in [text + "Attribute", text] {
      let hashed = name(candidate)
      if words.count == 1 {
        let types = typeSites(hashed, arity: 0, unitIndex: unitIndex, token: Int32(token))
        if !types.isEmpty { return types }
      } else {
        let leading = qualifiedFromScope(Array(words.dropLast()), unitIndex: unitIndex)
        switch leading.first {
        case .module(let hashedNamespace)?:
          let types = namespaceTypes(namespaceNames[hashedNamespace] ?? "", named: hashed, arity: 0, from: unitIndex)
          if !types.isEmpty { return types.map { .decl($0) } }
        case .decl(let ref)?:
          let types = memberTypeRefs(of: .nominal(canonical(ref), []), named: hashed, arity: 0)
          if !types.isEmpty { return types.map { .decl($0) } }
        default:
          break
        }
      }
    }
    return []
  }

  /// A dotted name's last word's sites, its first word read from the scope: `A.B.C`.
  func qualifiedFromScope(_ words: [Int], unitIndex: Int32) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    guard let first = words.first else { return [] }
    var sites = nameSites(unit.hash(first), unitIndex: unitIndex, token: Int32(first))
    for word in words.dropFirst() {
      switch sites.first {
      case .module(let hashed)?:
        let namespace = namespaceNames[hashed] ?? ""
        let types = namespaceTypes(namespace, named: unit.hash(word), arity: arity(unit, word), from: unitIndex)
        if !types.isEmpty {
          sites = types.map { .decl($0) }
        } else {
          let sub = namespace + "." + unit.string(word)
          sites = isNamespace(sub) ? [namespaceSite(sub)] : []
        }
      case .decl(let ref)? where decl(ref).kind.isNominal:
        sites = memberTypeRefs(of: .nominal(canonical(ref), []), named: unit.hash(word), arity: arity(unit, word)).map { .decl($0) }
      default:
        return []
      }
    }
    return sites
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
      // An attribute is used without its suffix.
      let text = self.unit(ref).string(Int(decl(ref).nameToken))
      if decl(ref).kind == .classType, text.hasSuffix("Attribute"), text.count > 9 { names.insert(name(String(text.dropLast(9)))) }
      // A constructor is used by its type's name.
      if decl(ref).kind.isNominal { for part in parts(ref) { targets.insert(.decl(part)) } }
    case .local(let unitIndex, let token), .generic(let unitIndex, let token):
      names.insert(project.units[Int(unitIndex)].hash(Int(token)))
      // A primary constructor's or record's parameter is seen in its whole type, a method's in its body: its file.
      restrict = unitIndex
    case .module(let hashed):
      guard let text = namespaceNames[hashed] else { return [] }
      names.insert(name(String(text.split(separator: ".").last ?? "")))
    }
    for target in targets { if case .decl(let ref) = target { names.insert(decl(ref).name) } }
    return project.references(named: names, in: restrict, landingOn: targets) { self.answer(unitIndex: $0, token: $1) }
  }
}
