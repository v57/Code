import CodeModel
import CodeScan
import Foundation

/// PHP's model: definitions, references, completion and details from source, on CodeModel's core. Names resolve as
/// PHP does: a class name through the file's `use` imports, else in its namespace; a function or constant through
/// `use function`/`use const`, else in the namespace, else in the global one; Composer's autoloading finds the file
/// of a class that isn't the project's. Variables are a function's (a closure's with its `use` captures, an arrow
/// function's with its parent's), defined where first bound: a parameter, an assignment, `foreach`, `catch`, `global`,
/// `static`, a list, else the first use. Members go through a value's type (declared, from PHPDoc where the code has
/// none, from `new`, calls' return types, `instanceof` checks) along its class, the traits it uses, its parents and
/// interfaces; a value whose type can't be told answers by name, as candidates.
public final class PHPModel: LanguageModel, NominalTypes {
  public let project: Project
  let layout: PHPLayout
  /// Fully qualified names (`PHPKey.qualified…`) to their declarations, over every unit read so far.
  var symbols: [Name: [DeclRef]] = [:]
  private var indexedUnits = 0
  private var loadedAutoloadFiles = false
  private var loadedStd = false
  var tables: [DeclRef: [Name: DeclRef]] = [:]
  var building: Set<DeclRef> = []
  var supertypeCache: [DeclRef: [Ty]] = [:]
  var valueTypes: [DeclRef: Ty] = [:]
  var resolving: Set<DeclRef> = []
  var docCache: [DeclRef: PHPDoc] = [:]
  var depth = 0

  init(project: Project) {
    self.project = project
    layout = project.layout as! PHPLayout
    project.onShapeChange = { [weak self] in self?.dropTables() }
  }

  /// A PHP project under `root`: its files, the vendor files its names reach, PHP's own declarations.
  public convenience init(root: String) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    self.init(project: Project(root: root, layout: PHPLayout(root: root)))
  }

  private func dropTables() {
    symbols.removeAll()
    indexedUnits = 0
    tables.removeAll()
    supertypeCache.removeAll()
    valueTypes.removeAll()
    docCache.removeAll()
  }

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }

  static let unknown = Answer(state: .unknown, sites: [])

  func summarize(_ sites: [Site]) -> Answer { sites.isEmpty ? Self.unknown : Answer(summarizing: sites) }

  func isSDK(_ ref: DeclRef) -> Bool { project.isSDK(unit(ref)) }

  // MARK: Symbols

  /// A declaration's namespace: its namespace declaration's name, empty for the global one.
  func namespaceText(_ holder: Unit, _ index: Int32) -> String {
    var parent = holder.decls[Int(index)].parent
    while parent >= 0 {
      let item = holder.decls[Int(parent)]
      if item.kind == .namespace { return item.typeStart >= 0 ? holder.phNameText(Int(item.typeStart), Int(item.typeEnd)) : "" }
      parent = item.parent
    }
    return ""
  }

  /// A top-level declaration's fully qualified name.
  func qualifiedName(_ ref: DeclRef) -> String {
    let holder = unit(ref)
    let item = decl(ref)
    if holder.tokens[Int(item.nameToken)].kind == .string { return holder.phStringValue(Int(item.nameToken)) ?? "" }
    let namespace = namespaceText(holder, ref.decl)
    let short = holder.string(Int(item.nameToken))
    return namespace.isEmpty ? short : namespace + "\\" + short
  }

  /// Adds what's been read since the last time to the table.
  func indexNewUnits() {
    while indexedUnits < project.units.count {
      let u = Int32(indexedUnits)
      indexedUnits += 1
      let holder = project.units[Int(u)]
      for (index, item) in holder.decls.enumerated() {
        let isTop = item.parent < 0 || holder.decls[Int(item.parent)].kind == .namespace
        guard isTop, !item.isLocal, item.kind != .namespace, item.nameToken >= 0 else { continue }
        let ref = DeclRef(unit: u, decl: Int32(index))
        let fqn = qualifiedName(ref)
        let key: Name
        switch item.kind {
        case .function: key = PHPKey.qualifiedFunction(fqn)
        case .variable: key = PHPKey.qualifiedConstant(fqn)
        default: key = PHPKey.qualifiedType(fqn)
        }
        symbols[key, default: []].append(ref)
      }
    }
  }

  /// Declarations of a key, the project's and vendors' over the stub's.
  private func preferProject(_ refs: [DeclRef]) -> [DeclRef] {
    guard refs.count > 1 else { return refs }
    let own = refs.filter { !isSDK($0) }
    return own.isEmpty ? refs : own
  }

  func loadStd() {
    guard !loadedStd else { return }
    loadedStd = true
    project.ensureModule(name(PHPLayout.stdModule), display: PHPLayout.stdModule)
    indexNewUnits()
  }

  /// A file outside the project, read once.
  @discardableResult
  func load(_ path: String) -> Bool {
    if project.unitByPath[path] != nil { return true }
    let found = project.ensureModule(name(path), display: path) != nil
    indexNewUnits()
    return found
  }

  /// A class, interface, trait or enum by its fully qualified name.
  func classes(_ fqn: String) -> [DeclRef] {
    indexNewUnits()
    let key = PHPKey.qualifiedType(fqn)
    if let found = symbols[key], !found.isEmpty { return preferProject(found) }
    if let path = layout.classFile(fqn), load(path), let found = symbols[key], !found.isEmpty { return found }
    if !fqn.contains("\\") {
      loadStd()
      return symbols[key] ?? []
    }
    return []
  }

  /// A function or constant by its fully qualified name, the autoloaded files and the stub read when it isn't found.
  private func globals(_ key: Name, global: Bool) -> [DeclRef] {
    indexNewUnits()
    if let found = symbols[key], !found.isEmpty { return preferProject(found) }
    if !loadedAutoloadFiles {
      loadedAutoloadFiles = true
      for path in layout.autoloadFiles { load(path) }
      if let found = symbols[key], !found.isEmpty { return preferProject(found) }
    }
    guard global else { return [] }
    loadStd()
    return symbols[key] ?? []
  }

  // MARK: Names

  /// The namespace a token is in, and the `use` imports that apply there.
  func context(_ unitIndex: Int32, _ token: Int) -> (namespace: String, uses: [Import]) {
    let holder = project.units[Int(unitIndex)]
    for (index, item) in holder.decls.enumerated() where item.kind == .namespace && Int(item.first) <= token && token < Int(item.end) {
      let text = item.typeStart >= 0 ? holder.phNameText(Int(item.typeStart), Int(item.typeEnd)) : ""
      _ = index
      let uses = holder.imports.filter { Int($0.token) >= Int(item.first) && Int($0.token) < Int(item.end) }
      return (text, uses)
    }
    return ("", holder.imports)
  }

  /// The type names PHP reserves: no class can have them (`Double`, `Scalar` and PHPDoc's other words can).
  static let builtinTypes: Set<String> = [
    "int", "float", "string", "bool", "array", "callable", "iterable", "object", "mixed", "void", "null", "never", "false", "true",
  ]

  /// A class name as written (`Foo`, `A\Foo`, `\A\Foo`) to its fully qualified name: through the imports, else in the
  /// namespace. Nil for a type that's no class (`int`) and `self`/`static`/`parent`.
  func resolveClass(_ text: String, absolute: Bool, unitIndex: Int32, token: Int) -> String? {
    var text = text
    var absolute = absolute
    if text.hasPrefix("\\") {
      text.removeFirst()
      absolute = true
    }
    guard !text.isEmpty else { return nil }
    if absolute { return text }
    let lower = text.lowercased()
    if !text.contains("\\"), Self.builtinTypes.contains(lower) || lower == "self" || lower == "static" || lower == "parent" { return nil }
    let (namespace, uses) = context(unitIndex, token)
    if lower.hasPrefix("namespace\\") { return namespace.isEmpty ? String(text.dropFirst(10)) : namespace + "\\" + text.dropFirst(10) }
    let first = lower.split(separator: "\\", maxSplits: 1).first.map(String.init) ?? lower
    let firstKey = name(first)
    for item in uses where item.member == PHPKey.useClass && item.alias == firstKey {
      let rest = text.dropFirst(first.count)
      return item.moduleName + rest
    }
    return namespace.isEmpty ? text : namespace + "\\" + text
  }

  /// Classes a name as written means at a token (none for `int`; `self`, `static`, `parent` from where it's written).
  func classRefs(_ text: String, absolute: Bool, unitIndex: Int32, token: Int) -> [DeclRef] {
    let lower = text.lowercased()
    if !absolute, lower == "self" || lower == "static" { return enclosingClass(unitIndex: unitIndex, token: token).map { [$0] } ?? [] }
    if !absolute, lower == "parent" {
      guard let owner = enclosingClass(unitIndex: unitIndex, token: token), let parent = parentClass(owner) else { return [] }
      return [parent]
    }
    guard let fqn = resolveClass(text, absolute: absolute, unitIndex: unitIndex, token: token) else { return [] }
    return classes(fqn)
  }

  /// A function call's name: `use function`, the namespace's, then the global one.
  func functionRefs(_ text: String, absolute: Bool, unitIndex: Int32, token: Int) -> [DeclRef] {
    globalRefs(text, absolute: absolute, unitIndex: unitIndex, token: token, kind: PHPKey.useFunction) { PHPKey.qualifiedFunction($0) }
  }

  func constantRefs(_ text: String, absolute: Bool, unitIndex: Int32, token: Int) -> [DeclRef] {
    globalRefs(text, absolute: absolute, unitIndex: unitIndex, token: token, kind: PHPKey.useConstant) { PHPKey.qualifiedConstant($0) }
  }

  private func globalRefs(_ text: String, absolute: Bool, unitIndex: Int32, token: Int, kind: Name, key: (String) -> Name) -> [DeclRef] {
    var text = text
    var absolute = absolute
    if text.hasPrefix("\\") {
      text.removeFirst()
      absolute = true
    }
    if absolute { return globals(key(text), global: !text.contains("\\")) }
    let (namespace, uses) = context(unitIndex, token)
    if text.contains("\\") {
      // Qualified: the first segment through a class-kind import, else under the namespace.
      let first = String(text.split(separator: "\\", maxSplits: 1)[0])
      if let item = uses.first(where: { $0.member == PHPKey.useClass && $0.alias == name(first.lowercased()) }) {
        return globals(key(item.moduleName + text.dropFirst(first.count)), global: false)
      }
      if text.lowercased().hasPrefix("namespace\\") { return globals(key((namespace.isEmpty ? "" : namespace + "\\") + text.dropFirst(10)), global: false) }
      return globals(key(namespace.isEmpty ? text : namespace + "\\" + text), global: false)
    }
    let alias = kind == PHPKey.useConstant ? name(text) : name(text.lowercased())
    if let item = uses.first(where: { $0.member == kind && $0.alias == alias }) { return globals(key(item.moduleName), global: !item.moduleName.contains("\\")) }
    if !namespace.isEmpty {
      let found = globals(key(namespace + "\\" + text), global: false)
      if !found.isEmpty { return found }
    }
    return globals(key(text), global: true)
  }

  // MARK: Classes

  /// The class, interface, trait or enum around a token (not an anonymous class's).
  func enclosingClass(unitIndex: Int32, token: Int) -> DeclRef? {
    let holder = project.units[Int(unitIndex)]
    for index in holder.chain(at: Int32(token)).reversed() {
      let item = holder.decls[Int(index)]
      if item.kind == .classType || item.kind == .protocolType || item.kind == .enumeration { return DeclRef(unit: unitIndex, decl: index) }
    }
    return nil
  }

  /// The function or method whose body (or parameters) holds a token.
  func enclosingFunction(unitIndex: Int32, token: Int) -> Int32? {
    let holder = project.units[Int(unitIndex)]
    for index in holder.chain(at: Int32(token)).reversed() where holder.decls[Int(index)].kind == .function { return index }
    return nil
  }

  /// What a class's supertype names are: `extends`, `implements`, a trait's `use`.
  enum Inheritance { case extends, implements, uses }

  func inheritance(_ ref: DeclRef) -> [(DeclRef, Inheritance)] {
    let holder = unit(ref)
    let item = decl(ref)
    var result: [(DeclRef, Inheritance)] = []
    for r in 0..<Int(item.inheritCount) {
      let range = holder.ranges[Int(item.inheritStart) + r]
      var k = Int(range.start) - 1
      while k > 0, holder.isByte(k, 0x2C) || holder.isByte(k, 0x5C) || holder.phIsWord(k) && !holder.isToken(k, "extends") && !holder.isToken(k, "implements") && !holder.isToken(k, "use") {
        k -= 1
      }
      let how: Inheritance = holder.isToken(k, "use") ? .uses : holder.isToken(k, "implements") ? .implements : .extends
      let start = Int(range.start)
      let absolute = start > 0 && holder.touchesPrevious(start) && holder.tokens[start - 1].kind == .punctuation && holder.source.text[holder.tokens[start - 1].end - 1] == 0x5C
      for found in classRefs(holder.phNameText(start, Int(range.end)), absolute: absolute, unitIndex: ref.unit, token: start) where found != ref {
        result.append((found, how))
      }
    }
    return result
  }

  func parentClass(_ ref: DeclRef) -> DeclRef? {
    guard decl(ref).kind == .classType else { return nil }
    return inheritance(ref).first { $0.1 == .extends }?.0
  }

  package func supertypes(of ref: DeclRef) -> [Ty] {
    if let known = supertypeCache[ref] { return known }
    supertypeCache[ref] = []
    var result = inheritance(ref).map { Ty.nominal($0.0, []) }
    if decl(ref).kind == .enumeration {
      let backed = decl(ref).typeStart >= 0
      if let enumInterface = classes(backed ? "BackedEnum" : "UnitEnum").first { result.append(.nominal(enumInterface, [])) }
    }
    supertypeCache[ref] = result
    return result
  }

  package func memberBase(_ ty: Ty, depth: Int) -> Ty {
    if case .optional(let inner) = ty { return inner }
    return ty
  }

  /// A class's members by key, its own first, then its traits' (with `insteadof` and `as`), its parent's and its
  /// interfaces'.
  func memberTable(of ref: DeclRef) -> [Name: DeclRef] {
    if let known = tables[ref] { return known }
    guard building.insert(ref).inserted else { return [:] }
    defer { building.remove(ref) }
    var table: [Name: DeclRef] = [:]
    let holder = unit(ref)
    for child in holder.children(of: ref.decl) {
      let item = holder.decls[Int(child)]
      if table[item.name] == nil { table[item.name] = DeclRef(unit: ref.unit, decl: child) }
    }
    let supers = inheritance(ref)
    let traits = supers.filter { $0.1 == .uses }.map(\.0)
    if !traits.isEmpty {
      let (excluded, aliases) = traitAdaptations(ref, traits: traits)
      for (alias, target) in aliases where table[alias] == nil { table[alias] = target }
      for trait in traits {
        for (key, member) in memberTable(of: trait) where table[key] == nil && !excluded.contains(TraitMember(trait: trait, key: key)) { table[key] = member }
      }
    }
    for (other, how) in supers where how != .uses {
      for (key, member) in memberTable(of: other) where table[key] == nil { table[key] = member }
    }
    if decl(ref).kind == .enumeration {
      for case .nominal(let other, _) in supertypes(of: ref) {
        for (key, member) in memberTable(of: other) where table[key] == nil { table[key] = member }
      }
    }
    tables[ref] = table
    return table
  }

  struct TraitMember: Hashable {
    var trait: DeclRef
    var key: Name
  }

  /// A class's `use T { A::f insteadof B; B::f as g; f as protected h; }`: what's left out of which trait, and aliases.
  private func traitAdaptations(_ ref: DeclRef, traits: [DeclRef]) -> (Set<TraitMember>, [Name: DeclRef]) {
    let holder = unit(ref)
    let item = decl(ref)
    var excluded: Set<TraitMember> = []
    var aliases: [Name: DeclRef] = [:]
    guard item.bodyOpen >= 0 else { return (excluded, aliases) }
    var i = Int(item.bodyOpen) + 1
    let close = Int(item.bodyClose)
    while i < close {
      if holder.tokens[i].kind == .open, !(holder.isByte(i, 0x7B) && holder.isToken(holder.phStatementStartBefore(i), "use")) {
        i = holder.skipBalanced(i)
        continue
      }
      guard holder.isToken(i, "insteadof") || holder.isToken(i, "as") else {
        i += 1
        continue
      }
      // `[T::]f insteadof U, V` / `[T::]f as [visibility] [g]`.
      var methodToken = i - 1
      var owner: DeclRef?
      if holder.isToken(methodToken - 1, "::") {
        let range = holder.phNameRange(methodToken - 2)
        owner = classRefs(holder.phNameText(range.start, range.end), absolute: false, unitIndex: ref.unit, token: range.start).first
      }
      guard holder.phIsWord(methodToken) else {
        i += 1
        continue
      }
      let key = PHPKey.method(holder.string(methodToken))
      if holder.isToken(i, "insteadof") {
        var k = i + 1
        while k < close, !holder.isByte(k, 0x3B) {
          if holder.phIsWord(k), !holder.isByte(k + 1, 0x5C) {
            let range = holder.phNameRange(k)
            for other in classRefs(holder.phNameText(range.start, range.end), absolute: false, unitIndex: ref.unit, token: range.start) {
              excluded.insert(TraitMember(trait: other, key: key))
            }
          }
          k += 1
        }
        i = k
        continue
      }
      var k = i + 1
      if holder.isToken(k, "public") || holder.isToken(k, "protected") || holder.isToken(k, "private") { k += 1 }
      if holder.phIsWord(k), !holder.isByte(k, 0x3B) {
        let alias = PHPKey.method(holder.string(k))
        let sources = owner.map { [$0] } ?? traits
        for source in sources {
          if let target = memberTable(of: source)[key] {
            aliases[alias] = target
            break
          }
        }
      }
      methodToken = k
      i = k + 1
    }
    return (excluded, aliases)
  }

  /// Members of a type by key (each part of a union's); nil when the type can't be told, or the member may be magic.
  func members(of ty: Ty, key: Name) -> [DeclRef]? {
    switch ty {
    case .nominal(let ref, _):
      if let found = memberTable(of: ref)[key] { return [found] }
      return nil
    case .meta(let inner):
      return members(of: inner, key: key)
    case .optional(let inner):
      return members(of: inner, key: key)
    case .constructed(let kind, let parts) where kind == Ty.union || kind == Ty.intersection:
      var result: [DeclRef] = []
      var anyFound = false
      for part in parts {
        guard case .nominal = memberBase(part, depth: 0) else { continue }
        if let found = members(of: part, key: key) {
          anyFound = true
          for ref in found where !result.contains(ref) { result.append(ref) }
        } else if kind == Ty.union {
          return nil
        }
      }
      return anyFound ? result : nil
    default:
      return nil
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
    guard unit.phIsWord(token) else {
      if unit.tokens.indices.contains(token), unit.tokens[token].kind == .string { return includeAnswer(unitIndex: unitIndex, token: token) }
      return Self.unknown
    }
    if let found = useAnswer(unitIndex: unitIndex, token: token) { return found }
    if let site = unit.declaredSite(at: token, unitIndex: unitIndex) {
      // `namespace A\B;`: no one declaration.
      if case .decl(let ref) = site, unit.decls[Int(ref.decl)].kind == .namespace { return Self.unknown }
      return Answer(state: .exact, sites: [site])
    }
    if unit.phIsVariable(token) { return variableAnswer(unitIndex: unitIndex, token: token) }
    let word = unit.string(token)
    let range = unit.phNameRange(token)
    // A segment before the last: a namespace's, with no one declaration.
    if token != range.end - 1 { return Self.unknown }
    let before = range.start - (range.absolute ? 2 : 1)
    if range.start == token, unit.phIsArrow(token - 1) {
      let receiver = expressionType(unitIndex: unitIndex, end: token - 2)
      let isCall = unit.isByte(token + 1, 0x28)
      return memberAnswer(receiver, key: isCall ? PHPKey.method(word) : PHPKey.property(word), unitIndex: unitIndex, isCall: isCall)
    }
    if range.start == token, unit.isToken(token - 1, "::") {
      if word.lowercased() == "class" { return Self.unknown }
      let receiver = staticReceiver(unitIndex: unitIndex, end: token - 2)
      let isCall = unit.isByte(token + 1, 0x28)
      return memberAnswer(receiver, key: isCall ? PHPKey.method(word) : PHPKey.constant(word), unitIndex: unitIndex, isCall: isCall)
    }
    if let found = namespaceNameAnswer(unit, token) { return found }
    let text = unit.phNameText(range.start, range.end)
    let lower = text.lowercased()
    if unit.tokens[token].kind != .identifier, lower != "static" { return Self.unknown }
    // `name: value` in a call: a named argument.
    if range.start == token, unit.isByte(token + 1, 0x3A), !unit.isToken(token + 1, "::"), unit.isByte(before, 0x28) || unit.isByte(before, 0x2C),
      let open = unit.matchingOpenBefore(token), unit.isByte(open, 0x28)
    {
      return namedArgument(unitIndex: unitIndex, token: token, open: open)
    }
    let absolute = range.absolute
    let classWanted =
      unit.isToken(range.end, "::") || unit.isToken(before, "new") || unit.isToken(before, "instanceof") || unit.isToken(before, "extends")
      || unit.isToken(before, "implements") || unit.isToken(before, "insteadof") || isTraitUse(unit, range.start) || isTypePosition(unit, range.start, range.end)
    if classWanted {
      let found = classRefs(text, absolute: absolute, unitIndex: unitIndex, token: token)
      if !found.isEmpty || !isTypePosition(unit, range.start, range.end) { return summarize(found.map { .decl($0) }) }
    }
    if lower == "self" || lower == "static" || lower == "parent" { return Self.unknown }
    if unit.isByte(range.end, 0x28) {
      if unit.isToken(before, "function") || unit.isToken(before, "fn") { return Self.unknown }
      return summarize(functionRefs(text, absolute: absolute, unitIndex: unitIndex, token: token).map { .decl($0) })
    }
    let constants = constantRefs(text, absolute: absolute, unitIndex: unitIndex, token: token)
    if !constants.isEmpty { return summarize(constants.map { .decl($0) }) }
    if unit.isByte(range.end, 0x3A), !unit.isToken(range.end, "::"), unit.phStartsStatement(range.start) { return Self.unknown }
    return summarize(classRefs(text, absolute: absolute, unitIndex: unitIndex, token: token).map { .decl($0) })
  }

  /// A word in `namespace A\B;`: no one declaration.
  private func namespaceNameAnswer(_ unit: Unit, _ token: Int) -> Answer? {
    for item in unit.decls where item.kind == .namespace && item.typeStart >= 0 && Int(item.typeStart) <= token && token < Int(item.typeEnd) { return Self.unknown }
    return nil
  }

  /// `use T;` in a class's body.
  func isTraitUse(_ unit: Unit, _ start: Int) -> Bool {
    var k = start - 1
    while k > 0, unit.isByte(k, 0x2C) || unit.isByte(k, 0x5C) || unit.phIsName(k) && !unit.isToken(k, "use") { k -= 1 }
    guard unit.isToken(k, "use") else { return false }
    // Inside a class's body, not at a namespace's level (that's an import) or after a closure.
    return !unit.isByte(k - 1, 0x29) && unit.chain(at: Int32(k)).contains { unit.decls[Int($0)].kind == .classType || unit.decls[Int($0)].kind == .enumeration }
      && !unit.chain(at: Int32(k)).contains { unit.decls[Int($0)].kind == .function }
  }

  /// Where only a type goes: before a variable (a parameter's, a property's, `catch`'s), after `?`, `|` or `&` in a type,
  /// after a function's `):`.
  func isTypePosition(_ unit: Unit, _ start: Int, _ end: Int) -> Bool {
    let next = end
    if next < unit.tokens.count, unit.tokens[next].kind == .punctuation, unit.source.text[unit.tokens[next].end - 1] == 0x24, unit.phIsVariable(next + 1) {
      let first = unit.source.text[unit.tokens[next].start]
      // `Foo $x`, `Foo &$x`, `Foo ...$x`; not `FOO=$x`, `A.$b`.
      return unit.tokens[next].length == 1 || first == 0x26 || first == 0x2E
    }
    let before = start - 1 - (start > 0 && unit.isByte(start - 1, 0x5C) && !unit.touchesPrevious(start - 1) ? 1 : 0)
    if unit.isByte(before, 0x7C) || unit.isByte(before, 0x3F) && (unit.isByte(before - 1, 0x28) || unit.isByte(before - 1, 0x2C) || unit.isByte(before - 1, 0x3A)) {
      return true
    }
    if unit.isByte(before, 0x3A), unit.isByte(before - 1, 0x29), let open = unit.matchingOpen(before - 1), unit.isToken(open - 1, "fn") || unit.isToken(open - 1, "function")
      || unit.phIsWord(open - 1) && unit.isToken(open - 2, "function") || unit.isToken(open - 1, "use")
    {
      return true
    }
    if unit.isByte(before, 0x28), unit.isToken(before - 1, "catch") { return true }
    if unit.isByte(before, 0x7C) { return true }
    return false
  }

  /// A name in a `use` statement at a namespace's level: what it imports (its last segment and its alias); any other
  /// word there names a namespace.
  private func useAnswer(unitIndex: Int32, token: Int) -> Answer? {
    let unit = project.units[Int(unitIndex)]
    guard !unit.imports.isEmpty else { return nil }
    var inStatement = false
    for item in unit.imports {
      if token == Int(item.aliasToken) || unit.isToken(token + 1, "as") && token + 2 == Int(item.aliasToken) {
        let refs: [DeclRef]
        switch item.member {
        case PHPKey.useFunction: refs = functionRefs(item.moduleName, absolute: true, unitIndex: unitIndex, token: token)
        case PHPKey.useConstant: refs = constantRefs(item.moduleName, absolute: true, unitIndex: unitIndex, token: token)
        default: refs = classes(item.moduleName)
        }
        return summarize(refs.map { .decl($0) })
      }
      if Int(item.token) <= token, token < unit.phStatementEnd(Int(item.token), limit: unit.tokens.count) { inStatement = true }
    }
    return inStatement ? Self.unknown : nil
  }

  /// `X::name` and `->name`: the receiver's member; by name when the receiver's type is unknown.
  func memberAnswer(_ receiver: Ty, key: Name, unitIndex: Int32, isCall: Bool) -> Answer {
    if let found = members(of: receiver, key: key) { return summarize(found.map { .decl($0) }) }
    if receiver == .unknown { return byName(key, unitIndex: unitIndex) }
    return Self.unknown
  }

  /// The project's members of a key, as candidates by name, when a receiver's type couldn't be told.
  func byName(_ key: Name, unitIndex: Int32) -> Answer {
    let found = project.membersNamed(key).filter { project.units[Int($0.unit)].decls[Int($0.decl)].kind != .namespace }
    guard !found.isEmpty else { return Self.unknown }
    return Answer(state: .candidates, sites: found.prefix(12).map { .decl($0) }, byNameOnly: true)
  }

  /// `$name`: a variable's first binding; `X::$name`: a static property; a superglobal: the stub's.
  private func variableAnswer(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    let word = unit.string(token)
    if word == "this" {
      // The class it's in (an anonymous class's isn't read).
      guard case .nominal(let ref, _) = thisType(unitIndex: unitIndex, token: token) else { return Self.unknown }
      return Answer(state: .exact, sites: [.decl(ref)])
    }
    if unit.phIsDollar(token - 1), unit.isToken(token - 2, "::") {
      let receiver = staticReceiver(unitIndex: unitIndex, end: token - 3)
      return memberAnswer(receiver, key: PHPKey.property(word), unitIndex: unitIndex, isCall: false)
    }
    // `$_SERVER`: always the superglobal; `$argv`: the script's, unless a function binds its own.
    if word.hasPrefix("_") || word == "GLOBALS", let site = superglobal(word) { return Answer(state: .exact, sites: [site]) }
    if let body = body(unitIndex: unitIndex, token: token) {
      let key = name(word)
      if Self.superglobals.contains(word), !body.bindings.contains(where: { $0.name == key }), let site = superglobal(word) {
        return Answer(state: .exact, sites: [site])
      }
      if let definition = body.definition(of: key, at: Int32(token)) { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: definition)]) }
    }
    return Self.unknown
  }

  static let superglobals: Set<String> = ["GLOBALS", "_SERVER", "_GET", "_POST", "_FILES", "_COOKIE", "_SESSION", "_REQUEST", "_ENV", "argv", "argc", "http_response_header"]

  /// A superglobal's line in the stub.
  func superglobal(_ word: String) -> Site? {
    guard Self.superglobals.contains(word) else { return nil }
    loadStd()
    guard let module = project.modules[name(PHPLayout.stdModule)], let u = module.units.first else { return nil }
    let holder = project.units[Int(u)]
    for i in holder.tokens.indices where holder.phIsVariable(i) && holder.string(i) == word { return .local(unit: u, token: Int32(i)) }
    return nil
  }

  /// `include 'x.php'`, `require __DIR__ . '/x.php'`: the file.
  private func includeAnswer(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    var k = token - 1
    var directory = (unit.path as NSString).deletingLastPathComponent
    var prefix = ""
    if unit.isByte(k, 0x2E) || unit.isToken(k, ".") {
      k -= 1
      if unit.isToken(k, "__DIR__") {
        prefix = directory
        k -= 1
      } else if unit.isByte(k, 0x29), unit.isToken(k - 1, "__FILE__"), unit.isByte(k - 2, 0x28), unit.isToken(k - 3, "dirname") {
        prefix = directory
        k -= 4
      } else {
        return Self.unknown
      }
    }
    if unit.isByte(k, 0x28) { k -= 1 }
    guard unit.isToken(k, "include") || unit.isToken(k, "include_once") || unit.isToken(k, "require") || unit.isToken(k, "require_once"),
      let value = unit.phStringValue(token), value.hasSuffix(".php") || value.hasSuffix(".phtml") || value.hasSuffix(".inc")
    else { return Self.unknown }
    if !prefix.isEmpty {
      directory = prefix
    }
    let path = PHPLayout.standardize(value.hasPrefix("/") && prefix.isEmpty ? value : directory + "/" + value)
    guard load(path), let target = project.unitByPath[path] else { return Self.unknown }
    return Answer(state: .exact, sites: [.local(unit: target, token: 0)])
  }

  // MARK: Named arguments

  /// `f(name: value)`: the parameter of what's called.
  private func namedArgument(unitIndex: Int32, token: Int, open: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    let word = unit.hash(token)
    var sites: [Site] = []
    for ref in callees(unitIndex: unitIndex, open: open) {
      let holder = self.unit(ref)
      let item = decl(ref)
      for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].label == word {
        sites.append(.local(unit: ref.unit, token: holder.params[Int(item.paramStart) + p].nameToken))
      }
    }
    return summarize(sites)
  }

  /// What a call's `(` calls: a function, a method, a constructor (`new X(`, `parent::__construct(`).
  func callees(unitIndex: Int32, open: Int) -> [DeclRef] {
    let unit = project.units[Int(unitIndex)]
    let nameToken = open - 1
    guard unit.phIsWord(nameToken), !unit.phIsVariable(nameToken) else { return [] }
    let word = unit.string(nameToken)
    let range = unit.phNameRange(nameToken)
    if range.start == nameToken, unit.phIsArrow(nameToken - 1) {
      return members(of: expressionType(unitIndex: unitIndex, end: nameToken - 2), key: PHPKey.method(word)) ?? []
    }
    if range.start == nameToken, unit.isToken(nameToken - 1, "::") {
      return members(of: staticReceiver(unitIndex: unitIndex, end: nameToken - 2), key: PHPKey.method(word)) ?? []
    }
    let text = unit.phNameText(range.start, range.end)
    let before = range.start - (range.absolute && unit.isByte(range.start - 1, 0x5C) ? 2 : 1)
    if unit.isToken(before, "new") {
      return classRefs(text, absolute: range.absolute, unitIndex: unitIndex, token: nameToken).compactMap { memberTable(of: $0)[PHPKey.method("__construct")] }
    }
    return functionRefs(text, absolute: range.absolute, unitIndex: unitIndex, token: nameToken)
  }

  // MARK: Bodies

  /// The variables of the function a token is in (its closures' too), or of the file's top-level code.
  func body(unitIndex: Int32, token: Int) -> PHPBody? {
    let unit = project.units[Int(unitIndex)]
    let owner = enclosingFunction(unitIndex: unitIndex, token: token) ?? -1
    if owner < 0, enclosingClass(unitIndex: unitIndex, token: token) != nil {
      // A property's default or a constant's value: no variables.
      return nil
    }
    if let known = unit.scans[owner] { return unsafeDowncast(known, to: PHPBody.self) }
    let scan = PHPBody(unit: unit, owner: owner)
    unit.scans[owner] = scan
    return scan
  }

  // MARK: References

  public func references(of answer: Answer) -> [(path: String, line: Int)] {
    guard answer.state != .unknown, !answer.byNameOnly, let first = answer.sites.first else { return [] }
    let targets = Set(answer.sites)
    var names: Set<Name> = []
    var restrict: Int32?
    switch first {
    case .decl:
      for site in answer.sites {
        guard case .decl(let ref) = site else { continue }
        let holder = self.unit(ref)
        let item = decl(ref)
        if holder.tokens[Int(item.nameToken)].kind == .string {
          names.insert(name(holder.phStringValue(Int(item.nameToken)) ?? ""))
        } else {
          names.insert(holder.hash(Int(item.nameToken)))
        }
      }
    case .local(let unitIndex, let token), .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      names.insert(holder.hash(Int(token)))
      // A parameter is named by arguments anywhere (`f(name: …)`); a variable is only seen in its file.
      if !isParameter(unitIndex: unitIndex, token: token) { restrict = unitIndex }
    case .module:
      return []
    }
    return project.references(named: names, in: restrict, landingOn: targets) { self.answer(unitIndex: $0, token: $1) }
  }

  func isParameter(unitIndex: Int32, token: Int32) -> Bool {
    let holder = project.units[Int(unitIndex)]
    for item in holder.decls where item.kind == .function {
      for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].nameToken == token { return true }
    }
    return false
  }
}

extension Unit {
  /// The first token of the statement a token is in (back to `;`, `{` or `}`).
  func phStatementStartBefore(_ i: Int) -> Int {
    var k = i - 1
    while k > 0, !isByte(k, 0x3B), !isByte(k, 0x7B), !isByte(k, 0x7D) { k -= 1 }
    return k + 1
  }
}
