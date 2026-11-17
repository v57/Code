import CodeModel
import CodeScan
import Foundation

/// Java's model: definitions, references, completion and details from source, on CodeModel's core. Names resolve as
/// javac resolves them: locals, then the fields and methods of the enclosing classes (inherited ones too, innermost
/// class first), static imports; types from type parameters, member types up the enclosing classes and their
/// supertypes, the file's own, single-type imports, the package, on-demand imports, `java.lang`; then packages.
/// Members go through the receiver's static type and its supertypes, generics substituted; overloads are chosen by
/// argument count and the argument types that are known, else given as candidates.
public final class JavaModel: LanguageModel, NominalTypes {
  public let project: Project
  let layout: JavaLayout
  var tables: [DeclRef: [Name: [MemberEntry]]] = [:]
  var building: Set<DeclRef> = []
  var valueTypes: [DeclRef: Ty] = [:]
  var resolving: Set<DeclRef> = []
  var supertypeCache: [DeclRef: [Ty]] = [:]
  /// Package names by their hash, for `.module` sites and places.
  var packageNames: [Name: String] = [:]
  var depth = 0

  public init(project: Project) {
    self.project = project
    layout = project.layout as! JavaLayout
    project.onShapeChange = { [weak self] in
      self?.tables.removeAll()
      self?.valueTypes.removeAll()
      self?.supertypeCache.removeAll()
    }
  }

  /// A Java project under `root`: its files, its build's other source roots, the platform's sources.
  /// `findsPlatform: false` skips looking for a JDK or Android SDK on disk and reads the built-in stub (tests).
  public convenience init(root: String, findsPlatform: Bool = true) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    self.init(project: Project(root: root, layout: JavaLayout(root: root, findsPlatform: findsPlatform)))
  }

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }

  // MARK: Packages

  /// The package a unit is in, as written.
  package func packageOf(_ unitIndex: Int32) -> String {
    var display = project.modules[project.units[Int(unitIndex)].moduleName]?.displayName ?? ""
    if display.hasSuffix(JavaLayout.librarySuffix) { display.removeLast(JavaLayout.librarySuffix.count) }
    return display
  }

  /// A package's modules: the project's own files of it, then everything else's.
  func packageModules(_ package: String) -> [Module] {
    var result: [Module] = []
    if let own = project.modules[name(package)] { result.append(own) }
    if let other = project.ensureModule(name(package + JavaLayout.librarySuffix), display: package + JavaLayout.librarySuffix) { result.append(other) }
    return result
  }

  /// The top-level types of a package named so.
  func packageTypes(_ package: String, named word: Name) -> [DeclRef] {
    var result: [DeclRef] = []
    for module in packageModules(package) {
      for ref in module.top[word] ?? [] where decl(ref).kind.isNominal { result.append(ref) }
      if !result.isEmpty { break }
    }
    return result
  }

  func packageSite(_ package: String) -> Site {
    let hashed = name(package)
    packageNames[hashed] = package
    return .module(hashed)
  }

  func isPackage(_ package: String) -> Bool { layout.isPackage(package) || !packageModules(package).isEmpty }

  /// `java.lang.Object` and the other classes everything leans on.
  func langType(_ word: Name) -> DeclRef? { packageTypes("java.lang", named: word).first }

  // MARK: Asking

  public func answer(path: String, line: Int, character: Int) -> Answer {
    guard let unitIndex = project.unitByPath[path] else { return Answer(state: .unknown, sites: []) }
    let unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    guard let token = unit.token(at: offset) else { return Answer(state: .unknown, sites: []) }
    return answer(unitIndex: unitIndex, token: token)
  }

  static let unknown = Answer(state: .unknown, sites: [])

  package func answer(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    let kind = unit.tokens[token].kind
    if kind == .attribute {
      // `@Name`: the annotation's type.
      guard unit.tokens[token].length > 1, !unit.isToken(token, "@interface") else { return Self.unknown }
      let word = hashName(unit.source.text + unit.tokens[token].start + 1, unit.tokens[token].length - 1)
      return summarize(typeSites(word, unitIndex: unitIndex, token: Int32(token)))
    }
    guard unit.javaIsName(token) else { return Self.unknown }
    if isInPackageLine(unit, token) { return Self.unknown }
    if let item = importAt(unit, token) { return importAnswer(item, unit: unit, unitIndex: unitIndex, token: token) }
    if let site = unit.declaredSite(at: token, unitIndex: unitIndex) ?? unit.declaredSiteFresh(at: token, unitIndex: unitIndex) {
      return Answer(state: .exact, sites: [site])
    }
    let body = body(unitIndex: unitIndex, token: Int32(token))
    if let body, body.byToken[Int32(token)] != nil { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))]) }
    // `@Name(key = …)`: the annotation's element.
    if unit.isToken(token + 1, "="), let open = unit.matchingOpenBefore(token), unit.isByte(open, 0x28), open > 0, unit.tokens[open - 1].kind == .attribute {
      let annotation = answer(unitIndex: unitIndex, token: open - 1)
      if case .decl(let ref)? = annotation.sites.first {
        return summarize(memberSites(of: .nominal(ref, []), named: unit.hash(token), from: unitIndex).filter { decl($0).kind == .function }.map { .decl($0) })
      }
      return Self.unknown
    }
    if isCreationName(unit, token) {
      // `new T(…)`, `new a.B.C<…>(…)`: a type.
      if token > 0, unit.isByte(token - 1, 0x2E) {
        let receiver = operandType(unitIndex: unitIndex, dot: token - 1)
        switch receiver {
        case .module(let package):
          let packageName = packageNames[package] ?? ""
          let types = packageTypes(packageName, named: unit.hash(token))
          if types.isEmpty, unit.isByte(token + 1, 0x2E), isPackage(packageName + "." + unit.string(token)) {
            return Answer(state: .exact, sites: [packageSite(packageName + "." + unit.string(token))])
          }
          return summarize(types.map { .decl($0) })
        case .meta(let type): return summarize(memberTypeRefs(of: type, named: unit.hash(token)).map { .decl($0) })
        default: return Self.unknown
        }
      }
      let types = typeSites(unit.hash(token), unitIndex: unitIndex, token: Int32(token))
      if types.isEmpty, unit.isByte(token + 1, 0x2E), isPackage(unit.string(token)) { return Answer(state: .exact, sites: [packageSite(unit.string(token))]) }
      return summarize(types)
    }
    if token > 0, unit.isByte(token - 1, 0x2E) {
      return selection(unitIndex: unitIndex, token: token)
    }
    if token > 0, unit.isToken(token - 1, "::") {
      return methodReference(unitIndex: unitIndex, token: token)
    }
    let word = unit.hash(token)
    if unit.isByte(token + 1, 0x28) {
      return callAnswer(unitIndex: unitIndex, token: token, word: word)
    }
    if isTypeContext(unit, token) {
      let types = typeSites(word, unitIndex: unitIndex, token: Int32(token))
      if !types.isEmpty { return summarize(types) }
    }
    return summarize(nameSites(word, unitIndex: unitIndex, token: Int32(token)))
  }

  /// Whether a name is (part of) the type a `new` creates.
  func isCreationName(_ unit: Unit, _ token: Int) -> Bool {
    var k = token
    while k > 1, unit.isByte(k - 1, 0x2E), unit.javaIsName(k - 2) { k -= 2 }
    while k > 0, unit.tokens[k - 1].kind == .attribute { k -= 1 }
    return k > 0 && unit.isToken(k - 1, "new")
  }

  func summarize(_ sites: [Site]) -> Answer { sites.isEmpty ? Self.unknown : Answer(summarizing: sites) }

  private func isInPackageLine(_ unit: Unit, _ token: Int) -> Bool {
    var i = token
    while i > 0, unit.isByte(i - 1, 0x2E) || unit.javaIsName(i - 1) { i -= 1 }
    return unit.isToken(i - 1, "package") && !unit.isByte(i - 2, 0x2E)
  }

  /// A name in a place where only a type is written: after `new`, `extends`, `implements`, `throws`, `instanceof`, in
  /// a declaration (`Type name`), in type arguments, as a cast.
  func isTypeContext(_ unit: Unit, _ token: Int) -> Bool {
    let before = token - 1
    if unit.isToken(before, "new") || unit.isToken(before, "extends") || unit.isToken(before, "implements") || unit.isToken(before, "throws")
      || unit.isToken(before, "instanceof") || unit.isToken(before, "permits")
    {
      return true
    }
    let after = token + 1
    if unit.javaIsName(after) || unit.isToken(after, "...") || unit.isToken(after, "::") && unit.isToken(after + 1, "new") { return true }
    if unit.isByte(after, 0x5B), unit.isByte(after + 1, 0x5D) { return true }
    if unit.tokens.indices.contains(after), unit.tokens[after].kind == .punctuation, unit.startsWith(after, 0x3C), let end = unit.javaTypeArgumentsEnd(after),
      unit.javaIsName(end) || unit.isByte(end, 0x29) || unit.isToken(end, "::") || unit.isByte(end, 0x28) && unit.isToken(before, "new")
    {
      return true
    }
    if unit.tokens.indices.contains(before), unit.tokens[before].kind == .punctuation, unit.punctuation(before, madeOf: "<?,&") {
      // In type arguments: `List<Name>`, `Map<K, Name>`.
      return !unit.isByte(before, 0x2C) || isInTypeArguments(unit, before)
    }
    if unit.isByte(before, 0x28), unit.isByte(after, 0x29), let open = Optional(before), open > 0 {
      // `(Name) x`: a cast, when an operand follows.
      let next = after + 1
      if next < unit.tokens.count {
        let kind = unit.tokens[next].kind
        if kind == .identifier || kind == .string || kind == .number || unit.isByte(next, 0x28) || unit.isToken(next, "this") || unit.isToken(next, "new") {
          return !unit.javaIsName(open - 1) || unit.isToken(open - 1, "return")
        }
      }
    }
    return false
  }

  private func isInTypeArguments(_ unit: Unit, _ comma: Int) -> Bool {
    var k = comma - 1
    var budget = 40
    while k >= 0, budget > 0 {
      budget -= 1
      if unit.tokens[k].kind == .punctuation, unit.startsWith(k, 0x3C) { return k > 0 && unit.javaIsName(k - 1) }
      if unit.tokens[k].kind == .open || unit.isByte(k, 0x3B) || unit.isToken(k, "=") { return false }
      k -= 1
    }
    return false
  }

  // MARK: Imports

  /// The import whose path holds a token.
  func importAt(_ unit: Unit, _ token: Int) -> Import? {
    for item in unit.imports where item.token >= 0 && Int(item.token) <= token {
      var end = Int(item.token)
      while end < unit.tokens.count, !unit.isByte(end, 0x3B), end == Int(item.token) || !unit.startsLine(end) || unit.isByte(end, 0x2E) || unit.isByte(end - 1, 0x2E) { end += 1 }
      if token < end { return item }
    }
    return nil
  }

  /// An import's words up to `;`, and whether it's static or ends in `*`.
  func importPath(_ item: Import, in unit: Unit) -> (words: [Int], isStatic: Bool, onDemand: Bool) {
    var words: [Int] = []
    var i = Int(item.token)
    var onDemand = false
    while i < unit.tokens.count, !unit.isByte(i, 0x3B) {
      if unit.isByte(i, 0x2A) || unit.isToken(i, ".*") || unit.isToken(i, "*") { onDemand = true }
      if unit.javaIsName(i) || unit.tokens[i].kind == .keyword && !unit.isToken(i, "import") { words.append(i) }
      if i > Int(item.token), unit.startsLine(i), !unit.isByte(i, 0x2E), !unit.isByte(i - 1, 0x2E) { break }
      i += 1
    }
    return (words, unit.isToken(Int(item.token) - 1, "static"), onDemand)
  }

  /// What a qualified name's words name, each: packages, then a type, then its member types (and, for a static
  /// import's last word, its static members).
  func qualifiedSites(_ words: [String], staticMember: Bool) -> [[Site]] {
    var result: [[Site]] = []
    var package = ""
    var type: Ty?
    for (index, word) in words.enumerated() {
      let hashed = name(word)
      if let current = type {
        let isLast = index == words.count - 1
        var found = memberTypeRefs(of: current, named: hashed).map { Site.decl($0) }
        if found.isEmpty, isLast, staticMember {
          found = memberSites(of: current, named: hashed, from: -1).filter { decl($0).isStatic || decl($0).kind == .enumCase }.map { .decl($0) }
        }
        if case .decl(let ref)? = found.first, decl(ref).kind.isNominal { type = .nominal(ref, []) } else { type = nil }
        result.append(found)
        if found.isEmpty { break }
        continue
      }
      let candidate = package.isEmpty ? word : package + "." + word
      let types = packageTypes(package, named: hashed)
      if !types.isEmpty, !(package.isEmpty && isPackage(candidate) && types.isEmpty) {
        result.append(types.map { .decl($0) })
        type = .nominal(types[0], [])
        continue
      }
      package = candidate
      result.append(isPackage(package) ? [packageSite(package)] : [])
    }
    return result
  }

  private func importAnswer(_ item: Import, unit: Unit, unitIndex: Int32, token: Int) -> Answer {
    let path = importPath(item, in: unit)
    guard let position = path.words.firstIndex(of: token) else { return Self.unknown }
    let words = path.words.map { unit.string($0) }
    let sites = qualifiedSites(words, staticMember: path.isStatic)
    guard position < sites.count else { return Self.unknown }
    return summarize(sites[position])
  }

  /// The types single-type and on-demand imports bring in, by name.
  func importedTypes(_ word: Name, unitIndex: Int32, onDemand: Bool) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    for item in unit.imports {
      let path = importPath(item, in: unit)
      guard path.onDemand == onDemand, !path.words.isEmpty else { continue }
      if !onDemand {
        guard unit.hash(path.words.last!) == word else { continue }
        let sites = qualifiedSites(path.words.map { unit.string($0) }, staticMember: path.isStatic)
        if sites.count == path.words.count, let last = sites.last {
          let types = last.filter { if case .decl(let ref) = $0 { return decl(ref).kind.isNominal } else { return false } }
          if !types.isEmpty { return types }
        }
        continue
      }
      let words = path.words.map { unit.string($0) }
      let joined = words.joined(separator: ".")
      // `import a.b.*` (a package) or `import a.b.C.*` (C's member types).
      let found = packageTypes(joined, named: word)
      if !found.isEmpty { return found.map { .decl($0) } }
      let sites = qualifiedSites(words, staticMember: false)
      if sites.count == words.count, case .decl(let ref)? = sites.last?.first, decl(ref).kind.isNominal {
        let members = memberTypeRefs(of: .nominal(ref, []), named: word)
        if !members.isEmpty { return members.map { .decl($0) } }
      }
    }
    return []
  }

  /// Static members a file's static imports bring in by name: `import static a.B.m;` and `import static a.B.*;`.
  func staticImports(_ word: Name, unitIndex: Int32, wantsMethods: Bool) -> [DeclRef] {
    let unit = project.units[Int(unitIndex)]
    for pass in 0..<2 {
      for item in unit.imports {
        let path = importPath(item, in: unit)
        guard path.isStatic, path.onDemand == (pass == 1), !path.words.isEmpty else { continue }
        var words = path.words.map { unit.string($0) }
        if pass == 0 {
          guard unit.hash(path.words.last!) == word else { continue }
          words.removeLast()
        }
        let sites = qualifiedSites(words, staticMember: false)
        guard sites.count == words.count, case .decl(let ref)? = sites.last?.first, decl(ref).kind.isNominal else { continue }
        let found = memberSites(of: .nominal(ref, []), named: word, from: unitIndex).filter {
          let item = decl($0)
          return (item.isStatic || item.kind == .enumCase) && (wantsMethods ? item.kind == .function : item.kind != .function)
        }
        if !found.isEmpty { return found }
      }
    }
    return []
  }

  // MARK: Bodies

  /// The member whose body holds a token: the outermost, as local classes and lambdas are scanned with it.
  func owner(unitIndex: Int32, token: Int32) -> Int32? {
    let unit = project.units[Int(unitIndex)]
    for index in unit.chain(at: token) {
      let item = unit.decls[Int(index)]
      if item.kind == .function || item.kind == .initializer {
        if item.bodyOpen >= 0 || item.paramCount > 0 { return index }
      }
      if item.kind == .variable || item.kind == .enumCase, item.initStart >= 0, token >= item.initStart, token <= item.initEnd { return index }
    }
    return nil
  }

  func body(unitIndex: Int32, token: Int32) -> JavaBody? {
    guard let owner = owner(unitIndex: unitIndex, token: token) else { return nil }
    let unit = project.units[Int(unitIndex)]
    if let known = unit.scans[owner] { return unsafeDowncast(known, to: JavaBody.self) }
    let scan = JavaBody(unit: unit, owner: owner)
    unit.scans[owner] = scan
    return scan
  }

  // MARK: Names

  /// The classes around a token, innermost first: declared ones, anonymous ones, an enum constant's body.
  func enclosingClasses(unitIndex: Int32, token: Int32) -> [DeclRef] {
    let unit = project.units[Int(unitIndex)]
    var result: [DeclRef] = []
    for index in unit.chain(at: token).reversed() {
      let item = unit.decls[Int(index)]
      if item.kind.isNominal || (item.kind == .enumCase && item.bodyOpen >= 0 && token > item.bodyOpen) {
        // A class's own header (its name, extends) is outside its body.
        if item.bodyOpen >= 0, token < item.bodyOpen, item.kind != .enumCase, item.isLocal, item.name == 0 { continue }
        result.append(DeclRef(unit: unitIndex, decl: index))
      }
    }
    return result
  }

  /// The type of a class seen from inside it: its type parameters as its arguments.
  func ownType(_ ref: DeclRef) -> Ty {
    let item = decl(ref)
    if item.kind == .enumCase { return .nominal(ref, []) }
    let holder = unit(ref)
    var args: [Ty] = []
    for g in 0..<Int(item.genericCount) { args.append(.param(holder.generics[Int(item.genericStart) + g].name, ref)) }
    return .nominal(ref, args)
  }

  /// A simple name used as a type: type parameters, member types of the enclosing classes (inherited too), local
  /// classes, the file's types, single-type imports, the package's, on-demand imports, java.lang.
  func typeSites(_ word: Name, unitIndex: Int32, token: Int32) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    let chain = unit.chain(at: token)
    for index in chain.reversed() {
      let item = unit.decls[Int(index)]
      for g in 0..<Int(item.genericCount) where unit.generics[Int(item.genericStart) + g].name == word {
        return [.generic(unit: unitIndex, token: unit.generics[Int(item.genericStart) + g].token)]
      }
      // Local classes declared before the token in a member's body.
      if item.kind == .function || item.kind == .initializer {
        for child in unit.children(of: index) {
          let local = unit.decls[Int(child)]
          if local.kind.isNominal, local.name == word, local.first < token { return [.decl(DeclRef(unit: unitIndex, decl: child))] }
        }
      }
      if item.kind.isNominal || item.kind == .enumCase {
        let ref = DeclRef(unit: unitIndex, decl: index)
        if item.name == word, item.kind.isNominal { return [.decl(ref)] }
        let found = memberTypeRefs(of: ownType(ref), named: word)
        if !found.isEmpty { return found.map { .decl($0) } }
      }
    }
    for index in unit.decls.indices where unit.decls[index].parent < 0 && unit.decls[index].name == word && unit.decls[index].kind.isNominal {
      return [.decl(DeclRef(unit: unitIndex, decl: Int32(index)))]
    }
    let single = importedTypes(word, unitIndex: unitIndex, onDemand: false)
    if !single.isEmpty { return single }
    let own = packageTypes(packageOf(unitIndex), named: word)
    if !own.isEmpty { return own.map { .decl($0) } }
    let onDemand = importedTypes(word, unitIndex: unitIndex, onDemand: true)
    if !onDemand.isEmpty { return onDemand }
    // Static on-demand imports bring in member types too.
    for ref in staticImports(word, unitIndex: unitIndex, wantsMethods: false) where decl(ref).kind.isNominal { return [.decl(ref)] }
    return packageTypes("java.lang", named: word).map { .decl($0) }
  }

  /// A simple name used as a value, else a type, else a package.
  func nameSites(_ word: Name, unitIndex: Int32, token: Int32) -> [Site] {
    let values = valueSites(word, unitIndex: unitIndex, token: token)
    if !values.isEmpty { return values }
    let types = typeSites(word, unitIndex: unitIndex, token: token)
    if !types.isEmpty { return types }
    let unit = project.units[Int(unitIndex)]
    if unit.isByte(Int(token) + 1, 0x2E) {
      let package = unit.string(Int(token))
      if isPackage(package) { return [packageSite(package)] }
    }
    return []
  }

  /// A simple name as a variable: a local, a field of an enclosing class (inherited too) that no class nearer than the
  /// local declares, a static import.
  func valueSites(_ word: Name, unitIndex: Int32, token: Int32) -> [Site] {
    let body = body(unitIndex: unitIndex, token: token)
    let local = body?.local(named: word, at: token)
    let localToken = local.map { body!.locals[Int($0)].token } ?? -1
    for owner in enclosingClasses(unitIndex: unitIndex, token: token) {
      let item = decl(owner)
      // A class declared after the local (inside its scope) hides it with a field of that name.
      if local != nil, item.first < localToken { break }
      let fields = memberSites(of: ownType(owner), named: word, from: unitIndex).filter { decl($0).kind == .variable || decl($0).kind == .enumCase }
      if !fields.isEmpty { return fields.map { .decl($0) } }
    }
    if local != nil { return [.local(unit: unitIndex, token: localToken)] }
    let imported = staticImports(word, unitIndex: unitIndex, wantsMethods: false)
    return imported.map { .decl($0) }
  }

  /// `name(…)`: the methods of the innermost enclosing class that has one so named, then static imports; `this(…)`
  /// and `super(…)` aren't asked.
  private func callAnswer(unitIndex: Int32, token: Int, word: Name) -> Answer {
    let unit = project.units[Int(unitIndex)]
    if unit.isToken(token, "this") || unit.isToken(token, "super") { return Self.unknown }
    let found = simpleMethods(word, unitIndex: unitIndex, token: Int32(token))
    guard !found.isEmpty else { return Self.unknown }
    return chooseAnswer(found, unitIndex: unitIndex, open: token + 1, receiver: nil)
  }

  /// The methods a simple call names, with the type they're members of.
  func simpleMethods(_ word: Name, unitIndex: Int32, token: Int32) -> [(DeclRef, Ty)] {
    for owner in enclosingClasses(unitIndex: unitIndex, token: token) {
      let own = ownType(owner)
      let found = methodSites(of: own, named: word, from: unitIndex)
      if !found.isEmpty { return found.map { ($0, own) } }
    }
    return staticImports(word, unitIndex: unitIndex, wantsMethods: true).map { ($0, Ty.unknown) }
  }

  /// `x.name`: a member of x's type, a member type or static member of a type, a package's type or subpackage.
  private func selection(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    let word = unit.hash(token)
    let receiver = operandType(unitIndex: unitIndex, dot: token - 1)
    let isCall = unit.isByte(token + 1, 0x28)
    switch receiver {
    case .module(let package):
      let packageName = packageNames[package] ?? ""
      let types = packageTypes(packageName, named: word)
      if !types.isEmpty { return summarize(types.map { .decl($0) }) }
      let sub = packageName + "." + unit.string(token)
      return isPackage(sub) ? Answer(state: .exact, sites: [packageSite(sub)]) : Self.unknown
    case .unknown:
      // What couldn't be told: the project's members of that name, as candidates by name.
      let found = project.membersNamed(word).filter { isCall ? decl($0).kind == .function : decl($0).kind != .function && decl($0).kind != .initializer }
      guard !found.isEmpty else { return Self.unknown }
      return Answer(state: .candidates, sites: found.prefix(12).map { .decl($0) }, byNameOnly: true)
    case .meta(let type):
      if isCall {
        let found = methodSites(of: type, named: word, from: unitIndex)
        return found.isEmpty ? Self.unknown : chooseAnswer(found.map { ($0, type) }, unitIndex: unitIndex, open: token + 1, receiver: type)
      }
      let nested = memberTypeRefs(of: type, named: word)
      if !nested.isEmpty { return summarize(nested.map { .decl($0) }) }
      return summarize(memberSites(of: type, named: word, from: unitIndex).filter { decl($0).kind != .function && decl($0).kind != .initializer }.map { .decl($0) })
    default:
      if isCall {
        let found = methodSites(of: receiver, named: word, from: unitIndex)
        return found.isEmpty ? Self.unknown : chooseAnswer(found.map { ($0, receiver) }, unitIndex: unitIndex, open: token + 1, receiver: receiver)
      }
      return summarize(memberSites(of: receiver, named: word, from: unitIndex).filter { decl($0).kind != .function && decl($0).kind != .initializer }.map { .decl($0) })
    }
  }

  /// `X::name`: the methods of X's type, narrowed by the functional interface it's given to when that's known.
  private func methodReference(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    if unit.isToken(token, "new") { return Self.unknown }
    let receiver = operandType(unitIndex: unitIndex, dot: token - 1)
    var type = receiver
    if case .meta(let inner) = receiver { type = inner }
    let found = methodSites(of: type, named: unit.hash(token), from: unitIndex)
    guard found.count > 1 else { return summarize(found.map { .decl($0) }) }
    // The interface's method takes n: a static method of n, an instance method of n − 1 on a type, of n on a value.
    if let target = functionalTarget(unitIndex: unitIndex, start: expressionStart(unit, before: token - 1)), let method = functionalMethod(of: target) {
      let n = Int(decl(method.ref).paramCount)
      let fits = found.filter {
        let item = decl($0)
        if case .meta = receiver { return item.isStatic ? Int(item.paramCount) == n : Int(item.paramCount) == n - 1 }
        return Int(item.paramCount) == n
      }
      if !fits.isEmpty { return summarize(fits.map { .decl($0) }) }
    }
    return summarize(found.map { .decl($0) })
  }

  /// The overload a call at `open` means, or the ones it may.
  func chooseAnswer(_ found: [(DeclRef, Ty)], unitIndex: Int32, open: Int, receiver: Ty?) -> Answer {
    let chosen = chooseOverload(found.map(\.0), unitIndex: unitIndex, open: open, receiver: found.first?.1 ?? receiver ?? .unknown)
    // No overload takes these arguments: each of them, none sure.
    if chosen.isEmpty { return found.isEmpty ? Self.unknown : Answer(state: .candidates, sites: found.map { .decl($0.0) }) }
    return summarize(chosen.map { .decl($0) })
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
    case .module(let package):
      guard let text = packageNames[package] else { return [] }
      names.insert(name(String(text.split(separator: ".").last ?? "")))
    }
    for target in targets { if case .decl(let ref) = target { names.insert(decl(ref).name) } }
    return project.references(named: names, in: restrict, landingOn: targets) { self.answer(unitIndex: $0, token: $1) }
  }
}
