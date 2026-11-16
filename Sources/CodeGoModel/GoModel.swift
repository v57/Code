import CodeModel
import CodeScan
import Foundation

/// Go's model: definitions, references, completion and details from source, on CodeModel's core. Names resolve the way
/// `go/types` resolves them (locals, the package's files, imports by package name, the universe in `builtin`), selectors
/// through the operand's type (fields, methods and what embedded fields promote, through pointers), composite literals'
/// keys to their type's fields.
public final class GoModel: LanguageModel {
  public let project: Project
  let layout: GoLayout
  var valueTypes: [DeclRef: Ty] = [:]
  var tables: [DeclRef: [Name: [DeclRef]]] = [:]
  var resolving: Set<DeclRef> = []
  var building: Set<DeclRef> = []
  var depth = 0

  public init(project: Project) {
    self.project = project
    layout = project.layout as! GoLayout
    project.onShapeChange = { [weak self] in
      self?.valueTypes.removeAll()
      self?.tables.removeAll()
    }
  }

  /// A Go project under `root`: its modules from their `go.mod` files.
  public convenience init(root: String) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    self.init(project: Project(root: root, layout: GoLayout(root: root)))
  }

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }

  // MARK: Packages

  /// The universe: `GOROOT/src/builtin`, where `int`, `len` and `error` are declared for reading.
  var universe: Module? { project.ensureModule(GoWord.builtin, display: "builtin") }

  /// The modules a file's package is: its own, and the package itself for a file this platform doesn't build.
  func packageModules(of unitIndex: Int32) -> [Module] {
    let unit = project.units[Int(unitIndex)]
    guard let own = project.modules[unit.moduleName] else { return [] }
    if own.displayName.hasSuffix("#off") {
      let base = String(own.displayName.dropLast(4))
      if let module = project.modules[name(base)] { return [own, module] }
    }
    return [own]
  }

  func isSamePackage(_ a: Int32, _ b: Int32) -> Bool {
    func base(_ index: Int32) -> String {
      let display = project.modules[project.units[Int(index)].moduleName]?.displayName ?? ""
      return display.hasSuffix("#off") ? String(display.dropLast(4)) : display
    }
    return base(a) == base(b)
  }

  /// The name a package is known by in a file: its package clause's, else its path's last element.
  func packageName(of module: Module) -> String {
    for index in module.units { if let found = GoSyntax.packageName(of: project.units[Int(index)]) { return found } }
    return Self.defaultName(module.displayName)
  }

  static func defaultName(_ path: String) -> String {
    var parts = path.split(separator: "/").map(String.init)
    // `…/v2` names the package before it; `gopkg.in/yaml.v3` is yaml.
    if parts.count > 1, let last = parts.last, last.hasPrefix("v"), Int(last.dropFirst()) != nil { parts.removeLast() }
    var last = parts.last ?? path
    if let dot = last.firstIndex(of: "."), path.hasPrefix("gopkg.in") { last = String(last[..<dot]) }
    if last.hasPrefix("go-") { last.removeFirst(3) }
    return last.replacingOccurrences(of: "-", with: "_")
  }

  /// The import a name in a file stands for.
  func importNamed(_ word: Name, in unitIndex: Int32) -> Import? {
    let unit = project.units[Int(unitIndex)]
    for item in unit.imports where item.alias == word { return item }
    for item in unit.imports where item.alias == 0 {
      if let module = project.ensureModule(item.module, display: item.moduleName) {
        if name(packageName(of: module)) == word { return item }
      } else if name(Self.defaultName(item.moduleName)) == word {
        return item
      }
    }
    return nil
  }

  // MARK: Asking

  public func answer(path: String, line: Int, character: Int) -> Answer {
    guard let unitIndex = project.unitByPath[path] else { return Answer(state: .unknown, sites: []) }
    let unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    guard let token = unit.token(at: offset) else { return Answer(state: .unknown, sites: []) }
    return answer(unitIndex: unitIndex, token: token)
  }

  func answer(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    let kind = unit.tokens[token].kind
    let word = unit.hash(token)
    if kind == .keyword {
      guard word == GoWord.trueWord || word == GoWord.falseWord || word == GoWord.nilWord || word == GoWord.iota else {
        return Answer(state: .unknown, sites: [])
      }
    } else if kind != .identifier {
      return Answer(state: .unknown, sites: [])
    }
    if token == 1, unit.isToken(0, "package") { return Answer(state: .unknown, sites: []) }
    if let site = unit.declaredSite(at: token, unitIndex: unitIndex) {
      if case .decl(let ref) = site, isEmbeddedField(ref) {
        // An embedded field's name is its type's.
        let item = decl(ref)
        let found = typeName(at: token, unitIndex: unitIndex, start: Int(item.typeStart))
        return found.isEmpty ? Answer(state: .unknown, sites: []) : summarize(found)
      }
      return Answer(state: .exact, sites: [site])
    }
    for item in unit.imports where item.aliasToken == Int32(token) {
      project.ensureModule(item.module, display: item.moduleName)
      return Answer(state: .exact, sites: [.module(item.module)])
    }
    let body = body(unitIndex: unitIndex, token: Int32(token))
    if let body, let index = body.byToken[Int32(token)] {
      let local = body.locals[Int(index)]
      if case .declaration(let declIndex) = local.kind { return Answer(state: .exact, sites: [.decl(DeclRef(unit: unitIndex, decl: declIndex))]) }
      return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))])
    }
    if let site = declaredLocally(unitIndex: unitIndex, token: token) { return Answer(state: .exact, sites: [site]) }
    if isFunctionTypeParameter(unit, token) { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))]) }
    // `break L`, `goto L`.
    if token > 0, unit.isToken(token - 1, "break") || unit.isToken(token - 1, "continue") || unit.isToken(token - 1, "goto") {
      if let body, let index = body.local(named: word, at: Int32(token), labels: true) {
        return Answer(state: .exact, sites: [.local(unit: unitIndex, token: body.locals[Int(index)].token)])
      }
      return Answer(state: .unknown, sites: [])
    }
    if token > 0, unit.isByte(token - 1, 0x2E) {
      return selector(unitIndex: unitIndex, token: token)
    }
    // `T{Field: v}`.
    if unit.isByte(token + 1, 0x3A), token > 0, unit.isByte(token - 1, 0x7B) || unit.isByte(token - 1, 0x2C), let body,
      let open = unit.matchingOpenBefore(token), unit.isByte(open, 0x7B), body.composites[Int32(open)] != nil
    {
      let literal = compositeType(unitIndex: unitIndex, open: Int32(open), body: body)
      if isStruct(literal) {
        let found = members(of: literal, named: word, from: unitIndex)
        return found.isEmpty ? Answer(state: .unknown, sites: []) : summarize(found.map { .decl($0) })
      }
    }
    let found = lookup(word, unitIndex: unitIndex, token: Int32(token))
    return found.isEmpty ? Answer(state: .unknown, sites: []) : summarize(found)
  }

  private func summarize(_ sites: [Site]) -> Answer {
    var unique: [Site] = []
    for site in sites where !unique.contains(site) { unique.append(site) }
    return Answer(state: unique.count == 1 ? .exact : .candidates, sites: unique)
  }

  func isEmbeddedField(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    return item.kind == .variable && item.parent >= 0 && item.typeStart >= 0 && item.nameToken >= item.typeStart && item.nameToken < item.typeEnd
  }

  /// A parameter's or result's name in a function type, `func(ipv4, ipv6 string) (err error)`: declared there.
  private func isFunctionTypeParameter(_ unit: Unit, _ token: Int) -> Bool {
    guard unit.tokens[token].kind == .identifier, let open = unit.matchingOpenBefore(token), unit.isByte(open, 0x28), open > 0 else { return false }
    guard unit.isByte(token - 1, 0x28) || unit.isByte(token - 1, 0x2C) else { return false }
    var before = open - 1
    var isResults = false
    if unit.isByte(before, 0x29), let inner = unit.matchingOpen(before), inner > 0 {
      before = inner - 1
      isResults = true
    }
    // An interface method's results, `Next() (value any, err error)`.
    let isMethodResults = isResults && unit.decls.contains { item in
      item.nameToken == Int32(before) && item.kind == .function && item.parent >= 0 && unit.decls[Int(item.parent)].kind == .protocolType
    }
    guard unit.isToken(before, "func") || isMethodResults else { return false }
    // Named when any item is `name Type`.
    let close = unit.skipBalanced(open) - 1
    var i = open + 1
    while i < close {
      var end = i
      while end < close, !unit.isByte(end, 0x2C) { end = unit.tokens[end].kind == .open ? unit.skipBalanced(end) : end + 1 }
      if end - i >= 2, unit.tokens[i].kind == .identifier, !unit.isByte(i + 1, 0x2E), !(unit.isByte(i + 1, 0x5B) && unit.touchesPrevious(i + 1)) {
        return true
      }
      i = end + 1
    }
    return false
  }

  /// A declaration made in a body after the site map was built (a local type's fields).
  private func declaredLocally(unitIndex: Int32, token: Int) -> Site? {
    let unit = project.units[Int(unitIndex)]
    for index in unit.decls.indices.reversed() where unit.decls[index].isLocal {
      if unit.decls[index].nameToken == Int32(token), unit.decls[index].kind != .extensionDecl, unit.decls[index].name != 0 {
        let ref = DeclRef(unit: unitIndex, decl: Int32(index))
        if isEmbeddedField(ref) { return nil }
        return .decl(ref)
      }
    }
    return nil
  }

  /// The type name in a type written from `start` whose token is `token` (`*pkg.T` at T).
  private func typeName(at token: Int, unitIndex: Int32, start: Int) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    if token >= 2, unit.isByte(token - 1, 0x2E), let item = importNamed(unit.hash(token - 2), in: unitIndex),
      let module = project.ensureModule(item.module, display: item.moduleName)
    {
      return (module.top[unit.hash(token)] ?? []).map { .decl($0) }
    }
    return lookup(unit.hash(token), unitIndex: unitIndex, token: Int32(token))
  }

  // MARK: Bodies

  /// The function (or variable) whose body holds a token: the outermost, as function literals are scanned with it.
  func owner(unitIndex: Int32, token: Int32) -> Int32? {
    let unit = project.units[Int(unitIndex)]
    for index in unit.chain(at: token) {
      let item = unit.decls[Int(index)]
      if item.kind == .function, item.bodyOpen >= 0 { return index }
      if item.kind == .variable, item.initStart >= 0, item.parent < 0 { return index }
    }
    return nil
  }

  func body(unitIndex: Int32, token: Int32) -> GoBody? {
    guard let owner = owner(unitIndex: unitIndex, token: token) else { return nil }
    return body(unitIndex: unitIndex, owner: owner)
  }

  func body(unitIndex: Int32, owner: Int32) -> GoBody {
    let unit = project.units[Int(unitIndex)]
    if let known = unit.scans[owner] { return unsafeDowncast(known, to: GoBody.self) }
    let scan = GoBody(unit: unit, owner: owner)
    unit.scans[owner] = scan
    return scan
  }

  // MARK: Names

  /// A name on its own at a token: a local, a type parameter, the package's, an import, the universe.
  func lookup(_ word: Name, unitIndex: Int32, token: Int32) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    // A signature's types are the package's: its parameters are seen from its body on.
    if !isInSignature(unitIndex: unitIndex, token: token), let body = body(unitIndex: unitIndex, token: token), let index = body.local(named: word, at: token) {
      let local = body.locals[Int(index)]
      if case .declaration(let declIndex) = local.kind { return [.decl(DeclRef(unit: unitIndex, decl: declIndex))] }
      return [.local(unit: unitIndex, token: local.token)]
    }
    // Type parameters of what's around it, innermost first; a method's receiver names its type's.
    for index in unit.chain(at: token).reversed() {
      let item = unit.decls[Int(index)]
      for g in 0..<Int(item.genericCount) {
        let generic = unit.generics[Int(item.genericStart) + g]
        if generic.name == word { return [.generic(unit: unitIndex, token: generic.token)] }
      }
    }
    for module in packageModules(of: unitIndex) {
      if let found = module.top[word], !found.isEmpty { return found.map { .decl($0) } }
    }
    if let item = importNamed(word, in: unitIndex) {
      project.ensureModule(item.module, display: item.moduleName)
      return [.module(item.module)]
    }
    for item in unit.imports where item.alias == GoWord.dot {
      if let module = project.ensureModule(item.module, display: item.moduleName), let found = module.top[word] { return found.map { .decl($0) } }
    }
    if let found = universe?.top[word], !found.isEmpty { return found.map { .decl($0) } }
    return []
  }

  /// Whether a token is in a function declaration's signature, before its body.
  private func isInSignature(unitIndex: Int32, token: Int32) -> Bool {
    guard let index = owner(unitIndex: unitIndex, token: token) else { return false }
    let item = project.units[Int(unitIndex)].decls[Int(index)]
    return item.kind == .function && item.bodyOpen > token
  }

  /// `x.name`: a package's declaration, or a member of x's type.
  private func selector(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    let word = unit.hash(token)
    let operand = operandType(unitIndex: unitIndex, dot: token - 1)
    switch operand {
    case .module(let moduleName):
      guard let module = project.modules[moduleName], let found = module.top[word], !found.isEmpty else { return Answer(state: .unknown, sites: []) }
      return summarize(found.map { .decl($0) })
    case .unknown:
      // What couldn't be told: the project's members of that name, as candidates by name.
      let found = project.membersNamed(word)
      guard !found.isEmpty else { return Answer(state: .unknown, sites: []) }
      return Answer(state: .candidates, sites: found.prefix(12).map { .decl($0) }, byNameOnly: true)
    case .meta(let inner):
      // A method expression, `T.Method`.
      let found = members(of: inner, named: word, from: unitIndex)
      return found.isEmpty ? Answer(state: .unknown, sites: []) : summarize(found.map { .decl($0) })
    default:
      let found = members(of: operand, named: word, from: unitIndex)
      return found.isEmpty ? Answer(state: .unknown, sites: []) : summarize(found.map { .decl($0) })
    }
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
      guard let module = project.modules[moduleName] else { return [] }
      names.insert(name(packageName(of: module)))
      for unit in project.units.prefix(project.projectUnits) {
        for item in unit.imports where item.module == moduleName && item.alias != 0 { names.insert(item.alias) }
      }
    }
    for target in targets { if case .decl(let ref) = target { names.insert(decl(ref).name) } }
    return project.references(named: names, in: restrict, landingOn: targets) { self.answer(unitIndex: $0, token: $1) }
  }
}

extension Unit {
  /// The token at a byte offset: the first that ends after it, if it starts at or before it.
  func token(at offset: Int) -> Int? {
    var low = 0
    var high = tokens.count - 1
    guard high >= 0 else { return nil }
    while low < high {
      let middle = (low + high) / 2
      if tokens[middle].end <= offset { low = middle + 1 } else { high = middle }
    }
    guard low < tokens.count, tokens[low].start <= offset else { return nil }
    return low
  }
}
