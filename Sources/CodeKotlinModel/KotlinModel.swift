import CodeJavaModel
import CodeModel
import CodeScan
import Foundation

/// A member found through a type's hierarchy (the core's `MemberEntry`).
typealias KMember = MemberEntry

/// Kotlin's model: definitions, references, completion and details from source, on CodeModel's core and Java's
/// layout (`JavaLayout` with Kotlin's extensions and syntax: packages from `package` lines whatever the folders, Gradle
/// source roots, the platform's and dependencies' sources), its standard library the generated stub `KotlinStd`.
/// Names resolve as Kotlin's compiler resolves them: locals, then the implicit receivers innermost first (a lambda's
/// receiver, the enclosing classes and their companions), each with its members then the extensions it can see; then
/// top-level declarations: explicit imports, the package, star imports, the default imports (`kotlin.*`, its
/// collections, text, io, ranges, sequences and comparisons, `java.lang.*`). Members go through the receiver's static
/// type and its supertypes, generics substituted, then extensions on it; overloads are chosen by argument count and
/// the argument types that are known, else given as candidates. A mixed project's `.java` files are read with Java's
/// parser into the same packages: Kotlin sees Java (getters as properties, Java's types as Kotlin's), and Java's model
/// (`java`, answering for `.java` files) sees Kotlin's classes.
public final class KotlinModel: LanguageModel, NominalTypes {
  public let project: Project
  let layout: JavaLayout
  /// Java's model of the same project: Java declarations' types, and questions in `.java` files.
  let java: JavaModel
  var tables: [DeclRef: [Name: [KMember]]] = [:]
  var building: Set<DeclRef> = []
  var valueTypes: [DeclRef: Ty] = [:]
  var resolving: Set<DeclRef> = []
  var supertypeCache: [DeclRef: [Ty]] = [:]
  var importCache: [Int32: (ObjectIdentifier, FileImports)] = [:]
  /// A package's module names, hashed once.
  var packageKeys: [String: (own: Name, library: Name, display: String)] = [:]
  var parameterCache: [DeclRef: [KParam]] = [:]
  /// Java's classes Kotlin sees as its own (`java.lang.String` is `kotlin.String`).
  var mapped: [DeclRef: DeclRef?] = [:]
  var packageNames: [Name: String] = [:]
  var lambdaTargets: [Int64: KLambdaTarget] = [:]
  var lambdaResolving: Set<Int64> = []
  var depth = 0
  /// Names' text by their hash, as they're asked about (a Java getter is found from its property's name).
  var names: [Name: String] = [:]

  public init(project: Project) {
    self.project = project
    layout = project.layout as! JavaLayout
    java = JavaModel(project: project)
    let javaReset = project.onShapeChange
    project.onShapeChange = { [weak self] in
      javaReset()
      self?.reset()
    }
    for package in Self.defaultPackages { _ = packageModules(package) }
  }

  /// A Kotlin project under `root`: its Kotlin and Java files, its build's other source roots, the platform's
  /// sources, the standard library's stub. `findsPlatform: false` reads the built-in Java stub (tests).
  public convenience init(root: String, findsPlatform: Bool = true) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    let std = JVMSourceSet(path: "code-kotlin-std", files: KotlinStd.files, kind: .platform, folder: "code-kotlin-std")
    let layout = JavaLayout(root: root, findsPlatform: findsPlatform, extensions: ["kt", "java"], syntax: KotlinSyntax.shared, extraSets: [std])
    self.init(project: Project(root: root, layout: layout))
  }

  func reset() {
    tables.removeAll()
    valueTypes.removeAll()
    supertypeCache.removeAll()
    parameterCache.removeAll()
    lambdaTargets.removeAll()
  }

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }
  func isJava(_ unitIndex: Int32) -> Bool { project.units[Int(unitIndex)].syntax !== KotlinSyntax.shared }
  func isJava(_ ref: DeclRef) -> Bool { isJava(ref.unit) }

  static let unknown = Answer(state: .unknown, sites: [])
  func summarize(_ sites: [Site]) -> Answer { sites.isEmpty ? Self.unknown : Answer(summarizing: sites) }

  // MARK: Packages

  /// What every file imports: `kotlin.*` and the rest of the standard library's defaults, `java.lang.*` on the JVM.
  static let defaultPackages = [
    "kotlin", "kotlin.annotation", "kotlin.collections", "kotlin.comparisons", "kotlin.io", "kotlin.ranges", "kotlin.sequences", "kotlin.text",
    "java.lang", "kotlin.jvm",
  ]

  func packageOf(_ unitIndex: Int32) -> String {
    var display = project.modules[project.units[Int(unitIndex)].moduleName]?.displayName ?? ""
    if display.hasSuffix(JavaLayout.librarySuffix) { display.removeLast(JavaLayout.librarySuffix.count) }
    return display
  }

  func packageModules(_ package: String) -> [Module] {
    var keys: (own: Name, library: Name, display: String)
    if let known = packageKeys[package] {
      keys = known
    } else {
      keys = (name(package), name(package + JavaLayout.librarySuffix), package + JavaLayout.librarySuffix)
      packageKeys[package] = keys
    }
    var result: [Module] = []
    if let own = project.modules[keys.own] { result.append(own) }
    if let other = project.ensureModule(keys.library, display: keys.display) { result.append(other) }
    return result
  }

  /// A package's top-level declarations of a name: its classes, functions, properties and type aliases.
  func packageDecls(_ package: String, named word: Name) -> [DeclRef] {
    var result: [DeclRef] = []
    for module in packageModules(package) {
      for ref in module.top[word] ?? [] where decl(ref).kind != .extensionDecl { result.append(ref) }
    }
    return result
  }

  /// A package's top-level extension functions and properties of a name, which `import a.b.name` brings in too.
  func packageExtensions(_ package: String, named word: Name) -> [DeclRef] {
    var result: [DeclRef] = []
    for module in packageModules(package) {
      for refs in module.top.values {
        for holder in refs where decl(holder).kind == .extensionDecl {
          for child in unit(holder).children(of: holder.decl) where unit(holder).decls[Int(child)].name == word { result.append(DeclRef(unit: holder.unit, decl: child)) }
        }
      }
    }
    return result
  }

  func packageTypes(_ package: String, named word: Name) -> [DeclRef] {
    packageDecls(package, named: word).filter { decl($0).kind.isNominal || decl($0).kind == .typeAlias }
  }

  func packageSite(_ package: String) -> Site {
    let hashed = name(package)
    packageNames[hashed] = package
    return .module(hashed)
  }

  func isPackage(_ package: String) -> Bool { layout.isPackage(package) || !packageModules(package).isEmpty }

  /// A standard library class: `kotlin.Int`, `kotlin.collections.List`.
  func kotlinType(_ package: String, _ word: String) -> DeclRef? {
    packageDecls(package, named: name(word)).first { decl($0).kind.isNominal }
  }

  // MARK: Asking

  public func answer(path: String, line: Int, character: Int) -> Answer {
    guard let unitIndex = project.unitByPath[path] else { return Self.unknown }
    if isJava(unitIndex) { return java.answer(path: path, line: line, character: character) }
    let unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    guard let token = unit.token(at: offset) else { return Self.unknown }
    if unit.tokens[token].kind == .string, let word = templateName(unit, token: token, offset: offset) {
      return summarize(nameSites(word, unitIndex: unitIndex, token: Int32(token), wantsCall: false))
    }
    return answer(unitIndex: unitIndex, token: token)
  }

  /// `$name` in a string template: the name at an offset inside the string token.
  func templateName(_ unit: Unit, token: Int, offset: Int) -> Name? {
    let text = unit.source.text
    let start = unit.tokens[token].start
    func isWord(_ byte: UInt8) -> Bool { byte == 0x5F || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte >= 0x80 }
    var low = offset
    while low > start, isWord(text[low - 1]) { low -= 1 }
    guard low > start, text[low - 1] == 0x24, low < unit.tokens[token].end, isWord(text[low]), !(text[low] >= 0x30 && text[low] <= 0x39) else { return nil }
    // `\$x` is no template.
    if low - 2 >= start, text[low - 2] == 0x5C { return nil }
    var high = low
    while high < unit.tokens[token].end, isWord(text[high]) { high += 1 }
    let word = hashName(text + low, high - low)
    names[word] = String(decoding: UnsafeBufferPointer(start: text + low, count: high - low), as: UTF8.self)
    return word
  }

  func answer(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    if unit.tokens[token].kind == .attribute {
      // `@Name`: the annotation's class.
      guard unit.tokens[token].length > 1 else { return Self.unknown }
      let word = hashName(unit.source.text + unit.tokens[token].start + 1, unit.tokens[token].length - 1)
      if unit.isToken(token + 1, ":") { return Self.unknown }
      let types = typeSites(word, unitIndex: unitIndex, token: Int32(token))
      // A library annotation's constructor, as the compiler links it (a primary one is on the class's line).
      if types.count == 1, case .decl(let ref) = types[0], decl(ref).kind.isNominal {
        let constructors = constructors(of: ref)
        if constructors.contains(where: { decl($0).kind == .initializer }) {
          let args = callOpen(unit, token) != nil ? callArguments(unit, nameToken: token) : []
          let chosen = chooseOverload(constructors.map { Callee(ref: $0, map: [:], receiver: .unknown) }, unitIndex: unitIndex, args: args)
          if chosen.count == 1 { return Answer(state: .exact, sites: [.decl(chosen[0].ref)]) }
        }
      }
      return summarize(types)
    }
    guard unit.ktIsName(token) else { return Self.unknown }
    names[unit.hash(token)] = unit.string(token)
    if let package = packageLineWord(unit, token) { return Answer(state: .exact, sites: [packageSite(package)]) }
    if let item = importAt(unit, token) { return importAnswer(item, unit: unit, unitIndex: unitIndex, token: token) }
    if let site = unit.declaredSite(at: token, unitIndex: unitIndex) ?? unit.declaredSiteFresh(at: token, unitIndex: unitIndex) {
      return Answer(state: .exact, sites: [site])
    }
    let body = body(unitIndex: unitIndex, token: Int32(token))
    if let body, body.byToken[Int32(token)] != nil { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))]) }
    // `_`, an unused parameter or component, names only itself.
    if unit.isToken(token, "_"), body != nil { return Answer(state: .exact, sites: [.local(unit: unitIndex, token: Int32(token))]) }
    // `@file:JvmName(…)`, `@field:Json`: the annotation after the target.
    if token >= 2, unit.isToken(token - 1, ":"), unit.tokens[token - 2].kind == .attribute, unit.touchesPrevious(token - 1) {
      return summarize(typeSites(unit.hash(token), unitIndex: unitIndex, token: Int32(token)))
    }
    if token > 0, unit.ktIsDot(token - 1) { return selection(unitIndex: unitIndex, token: token) }
    if token > 0, unit.isToken(token - 1, "::") { return callableReference(unitIndex: unitIndex, token: token) }
    // `name = value` in a call's arguments: the parameter.
    if unit.isToken(token + 1, "="), let parameter = namedArgument(unitIndex: unitIndex, token: token) { return parameter }
    if isInfixName(unit, token) { return infixAnswer(unitIndex: unitIndex, token: token) }
    let word = unit.hash(token)
    if isTypeContext(unit, token) {
      // A supertype's constructor call: `: RuntimeException(message)` (an alias's class's constructor).
      if let open = callOpen(unit, token), unit.isByte(open, 0x28), unit.isToken(token - 1, ":") {
        let called = callAnswer(unitIndex: unitIndex, token: token, word: word, open: open)
        if called.state != .unknown { return called }
      }
      let types = typeSites(word, unitIndex: unitIndex, token: Int32(token))
      if !types.isEmpty { return summarize(types) }
      if unit.isByte(token + 1, 0x2E), isPackage(unit.string(token)) { return Answer(state: .exact, sites: [packageSite(unit.string(token))]) }
      return Self.unknown
    }
    if let open = callOpen(unit, token) { return callAnswer(unitIndex: unitIndex, token: token, word: word, open: open) }
    return summarize(nameSites(word, unitIndex: unitIndex, token: Int32(token), wantsCall: false))
  }

  /// A word of the `package` line: the package up to it.
  private func packageLineWord(_ unit: Unit, _ token: Int) -> String? {
    var i = token
    while i > 1, unit.isByte(i - 1, 0x2E), unit.ktIsName(i - 2) { i -= 2 }
    guard unit.isToken(i - 1, "package"), !unit.isByte(i - 2, 0x2E) else { return nil }
    var words: [String] = []
    var k = i
    while k <= token {
      if unit.ktIsName(k) { words.append(unit.string(k)) }
      k += 1
    }
    return words.joined(separator: ".")
  }

  /// Where a call's arguments start when a name is called: `name(`, `name<T>(`, `name {` (a trailing lambda).
  func callOpen(_ unit: Unit, _ token: Int) -> Int? {
    var k = token + 1
    if k < unit.tokens.count, unit.tokens[k].kind == .punctuation, unit.startsWith(k, 0x3C), let after = unit.ktTypeArgumentsEnd(k),
      unit.isByte(after, 0x28) || unit.isByte(after, 0x7B) && !unit.startsLine(after)
    {
      // `name<T> {`: a lambda unless it's a declaration's (`class A<T> {`).
      if unit.isByte(after, 0x7B) { return isDeclarationName(unit, token) ? nil : after }
      k = after
    }
    if unit.isByte(k, 0x28), !unit.startsLine(k) { return k }
    if unit.isByte(k, 0x7B), !unit.startsLine(k), isTrailingLambda(unit, k) { return k }
    return nil
  }

  /// Whether a `{` after a name is a lambda passed to it, rather than a body (`class A {`, `if (x) a {`… no such).
  func isTrailingLambda(_ unit: Unit, _ brace: Int) -> Bool {
    let before = brace - 1
    guard before >= 0 else { return false }
    if unit.tokens[before].kind == .close {
      // `f(…) {`: not a declaration's header (`fun f() {`, `class A() {`, `init`, `if (…) {`, `for`, `while`, `catch`).
      guard unit.isByte(before, 0x29), let open = unit.matchingOpen(before), open > 0 else { return false }
      let head = open - 1
      if unit.isToken(head, "if") || unit.isToken(head, "for") || unit.isToken(head, "while") || unit.isToken(head, "catch") || unit.isToken(head, "when")
        || unit.isToken(head, "constructor") || unit.isToken(head, "init") || unit.isToken(head, "get") || unit.isToken(head, "set") || unit.isToken(head, "fun")
      {
        return false
      }
      if unit.ktIsName(head) || unit.tokens[head].kind == .punctuation && unit.punctuation(head, madeOf: ">") {
        if isDeclarationName(unit, head) { return false }
        return true
      }
      return unit.tokens[head].kind == .close
    }
    guard unit.ktIsName(before) else { return false }
    if isDeclarationName(unit, before) { return false }
    return !unit.isToken(before, "else") && !unit.isToken(before, "try") && !unit.isToken(before, "finally") && !unit.isToken(before, "do")
  }

  /// A name that's declared there: `class A {`, `object B {`, `fun f() {`, `val x get() {`, an enum entry.
  private func isDeclarationName(_ unit: Unit, _ token: Int) -> Bool {
    var k = token - 1
    while k >= 0, unit.isByte(k, 0x2E) || unit.ktIsName(k) && !KotlinWord.hard.contains(unit.hash(k)), k > token - 12 {
      if unit.isByte(k, 0x2E) {
        k -= 1
        continue
      }
      break
    }
    if unit.isToken(token - 1, "class") || unit.isToken(token - 1, "object") || unit.isToken(token - 1, "interface") || unit.isToken(token - 1, "fun") { return true }
    // A declaration's name maps to a site.
    let unitIndex = project.unitByPath[unit.path] ?? -1
    if unitIndex >= 0, case .decl? = unit.declaredSite(at: token, unitIndex: unitIndex) { return true }
    return false
  }

  /// A name between two operands on one line: an infix call (`a to b`, `x shl 2`, `1 until n`).
  func isInfixName(_ unit: Unit, _ token: Int) -> Bool {
    guard unit.tokens[token].kind == .identifier, token > 0, token + 1 < unit.tokens.count, !unit.startsLine(token), !unit.startsLine(token + 1) else { return false }
    let before = unit.tokens[token - 1]
    let endsOperand = before.kind == .identifier || unit.ktIsName(token - 1) && !KotlinWord.hard.contains(unit.hash(token - 1)) || before.kind == .number || before.kind == .string || unit.isByte(token - 1, 0x29) || unit.isByte(token - 1, 0x5D)
      || unit.isToken(token - 1, "this") || unit.isToken(token - 1, "null") || unit.isToken(token - 1, "true") || unit.isToken(token - 1, "false") || unit.isToken(token - 1, "!!")
    guard endsOperand else { return false }
    let after = unit.tokens[token + 1]
    let startsOperand = after.kind == .identifier || after.kind == .number || after.kind == .string || unit.isByte(token + 1, 0x28) || unit.isToken(token + 1, "this")
      || unit.isToken(token + 1, "null") || unit.isToken(token + 1, "true") || unit.isToken(token + 1, "false") || unit.isByte(token + 1, 0x7B) && false
      || unit.isToken(token + 1, "-") || unit.isToken(token + 1, "!") || after.kind == .keyword && unit.ktIsName(token + 1)
    guard startsOperand else { return false }
    // A call right after another infix name: `a to f(b)`.
    if unit.isByte(token + 1, 0x28), unit.touchesPrevious(token + 1) { return false }
    // Not a declaration: `val a: B`, a parameter, a lambda's `a, b ->`.
    if before.kind == .identifier, unit.isToken(token + 1, ":") { return false }
    if before.kind == .identifier, isDeclarationKeywordBefore(unit, token - 1) { return false }
    return true
  }

  private func isDeclarationKeywordBefore(_ unit: Unit, _ token: Int) -> Bool {
    unit.isToken(token - 1, "val") || unit.isToken(token - 1, "var") || unit.isToken(token - 1, "fun") || unit.isToken(token - 1, "class") || unit.isToken(token - 1, "object")
      || unit.tokens.indices.contains(token - 1) && unit.tokens[token - 1].kind == .attribute
  }

  /// A name where only a type goes: after `:` in a declaration, `is`, `as`, in type arguments or a function type, a
  /// supertype, a `catch`'s type.
  func isTypeContext(_ unit: Unit, _ token: Int) -> Bool {
    var start = token
    // The first word of a qualified type.
    while start > 1, unit.isByte(start - 1, 0x2E), unit.ktIsName(start - 2) { start -= 2 }
    let before = start - 1
    guard before >= 0 else { return false }
    if unit.isToken(before, "is") || unit.isToken(before, "as") || unit.isToken(before, "?") && unit.isToken(before - 1, "as") && unit.touchesPrevious(before) { return true }
    if unit.isToken(before, ":") { return isTypeColon(unit, before) }
    if unit.tokens[before].kind == .punctuation, unit.punctuation(before, madeOf: "<,") || unit.isToken(before, "->") || unit.isToken(before, "out") || unit.isToken(before, "in") {
      return isInTypeArguments(unit, before)
    }
    if unit.isToken(before, "out") || unit.isToken(before, "in") || unit.isToken(before, "reified") { return isInTypeArguments(unit, before) }
    // `A.(B) -> C`, `(A) -> B`: a function type.
    if unit.isByte(before, 0x28) || unit.isByte(before, 0x2C), let open = unit.isByte(before, 0x28) ? before : unit.matchingOpenBefore(before), unit.isByte(open, 0x28) {
      return isFunctionType(unit, open: open)
    }
    return false
  }

  /// Whether parentheses followed by `->` are a function type's: not a lambda's parameters (`{ (a, b) ->`) or a
  /// call before a `when` branch's arrow (`x.isEmpty() -> y`).
  private func isFunctionType(_ unit: Unit, open: Int) -> Bool {
    guard unit.isByte(open, 0x28), unit.isToken(unit.skipBalanced(open), "->"), !isLambdaHeader(unit, before: open) else { return false }
    return open == 0 || !(unit.ktIsName(open - 1) && !unit.isToken(open - 1, "suspend") || unit.tokens[open - 1].kind == .close || unit.punctuation(open - 1, madeOf: ">"))
  }

  /// A `:` that comes before a type: a declaration's, a parameter's, a function's result, a supertype list (not a
  /// named argument's or a label's).
  private func isTypeColon(_ unit: Unit, _ colon: Int) -> Bool {
    guard colon > 0 else { return false }
    let left = colon - 1
    if unit.tokens[left].kind == .close { return true }
    if unit.ktIsName(left) || unit.tokens[left].kind == .punctuation && unit.punctuation(left, madeOf: ">") { return true }
    return false
  }

  private func isInTypeArguments(_ unit: Unit, _ at: Int) -> Bool {
    var k = at
    var budget = 60
    while k >= 0, budget > 0 {
      budget -= 1
      if unit.tokens[k].kind == .punctuation, unit.startsWith(k, 0x3C), let end = unit.ktTypeArgumentsEnd(k), end > at { return true }
      if unit.tokens[k].kind == .open || unit.isByte(k, 0x3B) || unit.isToken(k, "=") || unit.startsLine(k) && k < at {
        return isFunctionType(unit, open: k)
      }
      k -= 1
    }
    return false
  }

  /// Whether the tokens before `at` back to a `{` are a lambda's parameters: `{ (a, b) ->`, `{ x, (a, b) ->`.
  private func isLambdaHeader(_ unit: Unit, before at: Int) -> Bool {
    var k = at - 1
    while k >= 0, at - k < 40 {
      if unit.isByte(k, 0x7B) { return true }
      if unit.isByte(k, 0x29), let open = unit.matchingOpen(k) {
        k = open - 1
        continue
      }
      guard unit.ktIsName(k) || unit.isByte(k, 0x2C) else { return false }
      k -= 1
    }
    return false
  }

  // MARK: Imports

  func importAt(_ unit: Unit, _ token: Int) -> Import? {
    for item in unit.imports where item.token >= 0 && Int(item.token) <= token {
      var end = Int(item.token)
      while end < unit.tokens.count, end == Int(item.token) || !unit.startsLine(end) {
        if unit.isByte(end, 0x3B) { break }
        end += 1
      }
      if token < end { return item }
    }
    return nil
  }

  /// An import's words, and whether it ends in `*`.
  func importWords(_ item: Import) -> [String] { item.moduleName.split(separator: ".").map(String.init) }

  func isStarImport(_ item: Import, in unit: Unit) -> Bool {
    let words = importWords(item)
    let k = Int(item.token) + max(words.count * 2 - 1, 0)
    if unit.isToken(k, ".*") { return true }
    return unit.isByte(k, 0x2E) && unit.isByte(k + 1, 0x2A)
  }

  /// A file's imports read once (while the file stays the same): the explicit ones by the name they bring in, the star
  /// ones, each one's words.
  struct FileImports {
    var explicit: [Name: [Int]] = [:]
    var stars: [Int] = []
    var words: [[String]] = []
    var explicitPaths: Set<String> = []
    var starPackages: Set<String> = []
  }

  func fileImports(_ unitIndex: Int32) -> FileImports {
    let unit = project.units[Int(unitIndex)]
    if let cached = importCache[unitIndex], cached.0 == ObjectIdentifier(unit) { return cached.1 }
    var result = FileImports()
    for (index, item) in unit.imports.enumerated() {
      let words = importWords(item)
      result.words.append(words)
      if isStarImport(item, in: unit) {
        result.stars.append(index)
        result.starPackages.insert(item.moduleName)
      } else if let last = words.last {
        result.explicit[item.alias != 0 ? item.alias : name(last), default: []].append(index)
        result.explicitPaths.insert(item.moduleName)
      }
    }
    importCache[unitIndex] = (ObjectIdentifier(unit), result)
    return result
  }

  /// What a qualified name's words name, each: packages, then a class, its nested classes, then its members (an
  /// import's last word may also be a top-level function or property of the package).
  func qualifiedSites(_ words: [String], lastIsMember: Bool) -> [[Site]] {
    var result: [[Site]] = []
    var package = ""
    var type: Ty?
    for (index, word) in words.enumerated() {
      let hashed = name(word)
      let isLast = index == words.count - 1
      if let current = type {
        var found = memberTypeRefs(of: current, named: hashed).map { Site.decl($0) }
        if found.isEmpty, isLast, lastIsMember {
          found = staticMembers(of: current, named: hashed).map { .decl($0) }
        }
        if case .decl(let ref)? = found.first, decl(ref).kind.isNominal { type = .nominal(ref, []) } else { type = nil }
        result.append(found)
        if found.isEmpty { break }
        continue
      }
      let candidate = package.isEmpty ? word : package + "." + word
      var declared = isLast && lastIsMember ? packageDecls(package, named: hashed) : packageTypes(package, named: hashed)
      if declared.isEmpty, isLast, lastIsMember, !package.isEmpty { declared = packageExtensions(package, named: hashed) }
      if !declared.isEmpty, !(isPackage(candidate) && !isLast && declared.allSatisfy { !decl($0).kind.isNominal }) {
        result.append(declared.map { .decl($0) })
        if let first = declared.first(where: { decl($0).kind.isNominal }) { type = .nominal(first, []) } else { type = nil }
        if type == nil, !isLast { break }
        continue
      }
      package = candidate
      result.append(isPackage(package) ? [packageSite(package)] : [])
    }
    return result
  }

  private func importAnswer(_ item: Import, unit: Unit, unitIndex: Int32, token: Int) -> Answer {
    if item.aliasToken == Int32(token) {
      let words = importWords(item)
      let sites = qualifiedSites(words, lastIsMember: true)
      return sites.count == words.count ? summarize(sites.last ?? []) : Self.unknown
    }
    var words: [String] = []
    var position = -1
    var k = Int(item.token)
    while k < unit.tokens.count, words.count < importWords(item).count {
      if unit.ktIsName(k) || unit.tokens[k].kind == .keyword {
        if k == token { position = words.count }
        words.append(unit.string(k))
      }
      k += 1
    }
    guard position >= 0 else { return Self.unknown }
    let sites = qualifiedSites(words, lastIsMember: !isStarImport(item, in: unit))
    guard position < sites.count else { return Self.unknown }
    return summarize(sites[position])
  }

  /// What a file's explicit imports bring in under a name: classes, functions, properties (an alias's name too).
  func explicitImports(_ word: Name, unitIndex: Int32) -> [DeclRef] {
    let imports = fileImports(unitIndex)
    var result: [DeclRef] = []
    for index in imports.explicit[word] ?? [] {
      let words = imports.words[index]
      let sites = qualifiedSites(words, lastIsMember: true)
      guard sites.count == words.count, let found = sites.last else { continue }
      for case .decl(let ref) in found { result.append(ref) }
    }
    return result
  }

  /// What a file's star imports bring in under a name: a package's top-level declarations, a class's nested ones.
  func starImports(_ word: Name, unitIndex: Int32) -> [DeclRef] {
    let unit = project.units[Int(unitIndex)]
    let imports = fileImports(unitIndex)
    var result: [DeclRef] = []
    for index in imports.stars {
      let item = unit.imports[index]
      let package = item.moduleName
      let found = packageDecls(package, named: word)
      if !found.isEmpty {
        result += found
        continue
      }
      let words = imports.words[index]
      let sites = qualifiedSites(words, lastIsMember: false)
      if sites.count == words.count, case .decl(let ref)? = sites.last?.first, decl(ref).kind.isNominal {
        result += memberTypeRefs(of: .nominal(ref, []), named: word) + staticMembers(of: .nominal(ref, []), named: word)
      }
    }
    return result
  }

  /// The packages a file sees without naming them: its own, its star imports' and the defaults, with whether a
  /// package's declarations come in by every name.
  func visiblePackages(_ unitIndex: Int32) -> Set<String> {
    var result = Set(Self.defaultPackages)
    result.insert(packageOf(unitIndex))
    result.formUnion(fileImports(unitIndex).starPackages)
    return result
  }

  /// A top-level name, in Kotlin's order: explicit imports, the file's package, star imports, the default imports.
  /// Each level's declarations, the nearest first; `filter` keeps the kinds wanted.
  func topLevels(_ word: Name, unitIndex: Int32, filter: (Decl) -> Bool) -> [[DeclRef]] {
    var levels: [[DeclRef]] = []
    levels.append(explicitImports(word, unitIndex: unitIndex).filter { filter(decl($0)) })
    // The file's own first, then the rest of its package.
    let unit = project.units[Int(unitIndex)]
    var own: [DeclRef] = []
    for index in unit.decls.indices where unit.decls[index].parent < 0 && unit.decls[index].name == word && !unit.decls[index].isLocal
      && unit.decls[index].kind != .extensionDecl && filter(unit.decls[index])
    {
      own.append(DeclRef(unit: unitIndex, decl: Int32(index)))
    }
    for ref in packageDecls(packageOf(unitIndex), named: word) where ref.unit != unitIndex && filter(decl(ref)) && decl(ref).access != .isPrivate { own.append(ref) }
    levels.append(own)
    levels.append(starImports(word, unitIndex: unitIndex).filter { filter(decl($0)) })
    var defaults: [DeclRef] = []
    for package in Self.defaultPackages where package != "java.lang" {
      defaults += packageDecls(package, named: word).filter { filter(decl($0)) && decl($0).access != .isPrivate }
    }
    levels.append(defaults)
    levels.append(packageDecls("java.lang", named: word).filter { filter(decl($0)) })
    return levels.filter { !$0.isEmpty }
  }

  // MARK: Bodies

  /// The declaration whose body holds a token, scanned with what's local inside it: the outermost function, property
  /// initializer or class header (its primary constructor's defaults and its supertypes' arguments).
  func owner(unitIndex: Int32, token: Int32) -> Int32? {
    let unit = project.units[Int(unitIndex)]
    for index in unit.chain(at: token) {
      let item = unit.decls[Int(index)]
      if item.kind == .function || item.kind == .initializer {
        if item.bodyOpen >= 0 || item.initStart >= 0 || item.paramCount > 0 { return index }
      }
      if item.kind == .variable || item.kind == .enumCase, item.initStart >= 0, token >= item.initStart, token <= item.initEnd { return index }
      if item.kind == .variable, item.isLocal == false, token > item.nameToken {
        // An accessor's body: the property owns it.
        if unit.children(of: index).contains(where: { unit.decls[Int($0)].first <= token && token < unit.decls[Int($0)].end }) { return index }
      }
      if item.kind.isNominal, item.bodyOpen < 0 || token < item.bodyOpen, token > item.nameToken { return index }
    }
    return nil
  }

  func body(unitIndex: Int32, token: Int32) -> KotlinBody? {
    guard let owner = owner(unitIndex: unitIndex, token: token) else { return nil }
    let unit = project.units[Int(unitIndex)]
    if let known = unit.scans[owner] { return unsafeDowncast(known, to: KotlinBody.self) }
    let scan = KotlinBody(unit: unit, owner: owner)
    unit.scans[owner] = scan
    return scan
  }

  // MARK: Names

  /// The classes around a token, innermost first: declared ones, objects, anonymous objects, an enum entry's body.
  func enclosingClasses(unitIndex: Int32, token: Int32) -> [DeclRef] {
    let unit = project.units[Int(unitIndex)]
    var result: [DeclRef] = []
    for index in unit.chain(at: token).reversed() {
      let item = unit.decls[Int(index)]
      if item.kind.isNominal || (item.kind == .enumCase && item.bodyOpen >= 0 && token > item.bodyOpen) {
        // A class's own header is outside its body, except for its primary constructor's parameters' defaults.
        if item.bodyOpen >= 0, token < item.bodyOpen, item.name == 0 { continue }
        result.append(DeclRef(unit: unitIndex, decl: index))
      }
    }
    return result
  }

  func ownType(_ ref: DeclRef) -> Ty {
    let item = decl(ref)
    if item.kind == .enumCase { return item.parent >= 0 ? .nominal(DeclRef(unit: ref.unit, decl: item.parent), []) : .unknown }
    let holder = unit(ref)
    var args: [Ty] = []
    for g in 0..<Int(item.genericCount) { args.append(.param(holder.generics[Int(item.genericStart) + g].name, ref)) }
    return .nominal(ref, args)
  }

  /// A class's companion object.
  func companion(of ref: DeclRef) -> DeclRef? {
    let holder = unit(ref)
    for child in holder.children(of: ref.decl) {
      let item = holder.decls[Int(child)]
      guard item.kind == .classType, item.isStatic, item.name != 0 else { continue }
      if isCompanion(DeclRef(unit: ref.unit, decl: child)) { return DeclRef(unit: ref.unit, decl: child) }
    }
    return nil
  }

  func isCompanion(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    guard item.kind == .classType, item.isStatic, !isJava(ref) else { return false }
    let holder = unit(ref)
    var k = Int(item.first)
    while k <= Int(item.nameToken), k < holder.tokens.count {
      if holder.isToken(k, "companion") { return true }
      if holder.isToken(k, "object") { break }
      k += 1
    }
    return false
  }

  /// An `object` (not a class): its name is a value.
  func isObject(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    return item.kind == .classType && item.isStatic && !isJava(ref)
  }

  /// The receivers a token sees without `this`, innermost first: lambdas' with a receiver (`apply { }`), then each
  /// enclosing class and its companion.
  func implicitReceivers(unitIndex: Int32, token: Int32) -> [Ty] {
    var result: [Ty] = []
    let body = body(unitIndex: unitIndex, token: token)
    if let body {
      for lambda in body.lambdasAround(token) {
        if let target = lambdaTarget(unitIndex: unitIndex, brace: Int(lambda)), let receiver = target.receiver { result.append(receiver) }
      }
    }
    // `when (this) { is A -> … }`: `this` as an `A` first (lambdas' receivers aside).
    if let body, let cast = body.cast(of: KotlinWord.this, at: token) {
      let narrowed = parseType(unitIndex: unitIndex, start: cast.typeStart, end: cast.typeEnd, scope: token)
      if narrowed != .unknown { result.append(narrowed) }
    }
    for owner in enclosingClasses(unitIndex: unitIndex, token: token) {
      result.append(ownType(owner))
      if decl(owner).kind.isNominal, let companion = companion(of: owner) { result.append(.nominal(companion, [])) }
    }
    // An extension function's body: its receiver.
    let unit = project.units[Int(unitIndex)]
    for index in unit.chain(at: token).reversed() where unit.decls[Int(index)].kind == .extensionDecl {
      result.insert(extensionReceiverType(DeclRef(unit: unitIndex, decl: index)), at: min(result.count, insertionPoint(result, unitIndex: unitIndex, token: token, holder: index)))
      break
    }
    return result
  }

  /// An extension's receiver comes after the lambdas inside its function, before the classes around it.
  private func insertionPoint(_ receivers: [Ty], unitIndex: Int32, token: Int32, holder: Int32) -> Int {
    guard let body = body(unitIndex: unitIndex, token: token) else { return 0 }
    let unit = project.units[Int(unitIndex)]
    var count = 0
    for lambda in body.lambdasAround(token) where lambda > unit.decls[Int(holder)].first {
      if let target = lambdaTarget(unitIndex: unitIndex, brace: Int(lambda)), target.receiver != nil { count += 1 }
    }
    return count
  }

  /// A simple name used as a type: type parameters, nested classes up the enclosing classes (and their supertypes),
  /// the file's and the package's, imports, the defaults.
  func typeSites(_ word: Name, unitIndex: Int32, token: Int32) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    let chain = unit.chain(at: token)
    for index in chain.reversed() {
      let item = unit.decls[Int(index)]
      for g in 0..<Int(item.genericCount) where unit.generics[Int(item.genericStart) + g].name == word {
        return [.generic(unit: unitIndex, token: unit.generics[Int(item.genericStart) + g].token)]
      }
      // An extension's function sees its own parameters, which the holder doesn't have.
      if item.kind == .extensionDecl {
        for child in unit.children(of: index) {
          let inner = unit.decls[Int(child)]
          for g in 0..<Int(inner.genericCount) where unit.generics[Int(inner.genericStart) + g].name == word {
            return [.generic(unit: unitIndex, token: unit.generics[Int(inner.genericStart) + g].token)]
          }
        }
      }
      if item.kind == .function || item.kind == .initializer || item.kind == .variable {
        for child in unit.children(of: index) {
          let local = unit.decls[Int(child)]
          if local.isLocal, local.kind.isNominal || local.kind == .typeAlias, local.name == word, local.first < token { return [.decl(DeclRef(unit: unitIndex, decl: child))] }
        }
      }
      if item.kind.isNominal || item.kind == .enumCase {
        let ref = DeclRef(unit: unitIndex, decl: index)
        if item.name == word, item.kind.isNominal { return [.decl(ref)] }
        let found = memberTypeRefs(of: ownType(ref), named: word)
        if !found.isEmpty { return found.map { .decl($0) } }
        if item.kind.isNominal, let companion = companion(of: ref) {
          let nested = memberTypeRefs(of: .nominal(companion, []), named: word)
          if !nested.isEmpty { return nested.map { .decl($0) } }
        }
      }
    }
    for level in topLevels(word, unitIndex: unitIndex, filter: { $0.kind.isNominal || $0.kind == .typeAlias }) {
      return level.map { .decl($0) }
    }
    return []
  }

  /// A simple name used as a value, else a type, else a package.
  func nameSites(_ word: Name, unitIndex: Int32, token: Int32, wantsCall: Bool) -> [Site] {
    let values = valueSites(word, unitIndex: unitIndex, token: token)
    if !values.isEmpty { return values }
    let types = typeSites(word, unitIndex: unitIndex, token: token)
    if !types.isEmpty { return types }
    let unit = project.units[Int(unitIndex)]
    if Int(token) < unit.tokens.count, unit.isByte(Int(token) + 1, 0x2E), unit.tokens[Int(token)].kind != .string {
      let package = unit.string(Int(token))
      if isPackage(package) { return [packageSite(package)] }
    }
    return []
  }

  /// The local a name means at a token: a declared one, a constructor parameter in the class's initializers, the
  /// innermost lambda's `it`.
  func localSite(_ word: Name, unitIndex: Int32, token: Int32) -> Site? {
    let unit = project.units[Int(unitIndex)]
    if let body = body(unitIndex: unitIndex, token: token), let local = body.local(named: word, at: token) {
      return .local(unit: unitIndex, token: body.locals[Int(local)].token)
    }
    if word == KotlinWord.it, let body = body(unitIndex: unitIndex, token: token), let brace = body.itLambda(at: token) {
      return .local(unit: unitIndex, token: brace)
    }
    // A primary constructor's parameter in its class's property initializers, `init` blocks, supertypes' arguments.
    for index in unit.chain(at: token).reversed() {
      let item = unit.decls[Int(index)]
      guard item.kind.isNominal else { continue }
      let inMember = unit.chain(at: token).contains { child in
        let member = unit.decls[Int(child)]
        guard member.parent == index else { return false }
        if member.kind == .variable { return member.initStart >= 0 && token >= member.initStart && token <= member.initEnd }
        if member.kind == .function, member.name == 0 { return unit.isToken(Int(member.nameToken), "init") }
        return false
      }
      let inHeader = item.bodyOpen < 0 || token < item.bodyOpen
      guard inMember || inHeader else { break }
      for p in 0..<Int(item.paramCount) where unit.params[Int(item.paramStart) + p].local == word {
        let param = unit.params[Int(item.paramStart) + p]
        if inHeader, param.nameToken >= token { continue }
        return .local(unit: unitIndex, token: param.nameToken)
      }
      break
    }
    return nil
  }

  /// A simple name as a variable: a local, a property of an implicit receiver (or an extension property on it), a
  /// top-level property, an object.
  func valueSites(_ word: Name, unitIndex: Int32, token: Int32) -> [Site] {
    if let local = localSite(word, unitIndex: unitIndex, token: token) { return [local] }
    for receiver in implicitReceivers(unitIndex: unitIndex, token: token) {
      if let mapped = javaMappedProperty(of: receiver, named: word) { return [.decl(mapped)] }
      let found = memberEntries(of: receiver, named: word).map(\.0.ref).filter { isProperty(decl($0)) }
      if !found.isEmpty { return found.map { .decl($0) } }
      // A Java class's getter as a property.
      if let getter = syntheticGetter(of: receiver, named: word) { return [.decl(getter)] }
      let extensions = extensionCandidates(receiver: receiver, named: word, unitIndex: unitIndex, wantsCall: false)
      if !extensions.isEmpty { return extensions.map { .decl($0.ref) } }
    }
    for level in topLevels(word, unitIndex: unitIndex, filter: { $0.kind == .variable || $0.kind == .enumCase }) {
      return level.map { .decl($0) }
    }
    return []
  }

  func isProperty(_ item: Decl) -> Bool { item.kind == .variable || item.kind == .enumCase }

  /// `name(…)` or `name { … }`: a local function or a local of a function type, the implicit receivers' functions
  /// (members, then extensions), top-level functions and classes' constructors, a property of a function type.
  private func callAnswer(unitIndex: Int32, token: Int, word: Name, open: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    if unit.isToken(token, "this") || unit.isToken(token, "super") { return Self.unknown }
    let found = simpleCallees(word, unitIndex: unitIndex, token: Int32(token))
    guard !found.isEmpty else {
      // A local or property holding a function: `block()`.
      return summarize(valueSites(word, unitIndex: unitIndex, token: Int32(token)))
    }
    return chooseAnswer(found, unitIndex: unitIndex, nameToken: token)
  }

  /// The overload a call means, or the ones it may; a class's constructors answer as Kotlin places them (the primary
  /// at the class).
  func chooseAnswer(_ found: [Callee], unitIndex: Int32, nameToken: Int) -> Answer {
    let chosen = chooseOverload(found, unitIndex: unitIndex, nameToken: nameToken)
    if chosen.isEmpty { return found.isEmpty ? Self.unknown : Answer(state: .candidates, sites: unique(found.map { .decl($0.ref) })) }
    return summarize(unique(chosen.map { .decl($0.ref) }))
  }

  func unique(_ sites: [Site]) -> [Site] {
    var seen = Set<Site>()
    return sites.filter { seen.insert($0).inserted }
  }

  /// `x.name`: a member or extension of x's type, a nested class, companion member or enum entry of a class, a
  /// package's declaration or subpackage.
  private func selection(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    let word = unit.hash(token)
    let receiver = operandType(unitIndex: unitIndex, dot: token - 1)
    let isCall = callOpen(unit, token) != nil
    switch receiver {
    case .module(let package):
      let packageName = packageNames[package] ?? ""
      let found = packageDecls(packageName, named: word)
      if !found.isEmpty {
        if isCall {
          let callees = constructorsAndFunctions(found)
          if !callees.isEmpty { return chooseAnswer(callees, unitIndex: unitIndex, nameToken: token) }
        }
        return summarize(found.map { .decl($0) })
      }
      let sub = packageName + "." + unit.string(token)
      return isPackage(sub) ? Answer(state: .exact, sites: [packageSite(sub)]) : Self.unknown
    case .unknown:
      // What couldn't be told: the project's members of that name, as candidates by name.
      // Another file's private members can't be meant.
      let found = project.membersNamed(word).filter { (isCall ? decl($0).kind == .function : isProperty(decl($0))) && (decl($0).access != .isPrivate || $0.unit == unitIndex) }
      guard !found.isEmpty else { return Self.unknown }
      return Answer(state: .candidates, sites: found.prefix(12).map { .decl($0) }, byNameOnly: true)
    case .meta(let type):
      let nested = memberTypeRefs(of: type, named: word)
      if !nested.isEmpty {
        if isCall {
          let callees = constructorsAndFunctions(nested)
          if !callees.isEmpty { return chooseAnswer(callees, unitIndex: unitIndex, nameToken: token) }
        }
        return summarize(nested.map { .decl($0) })
      }
      let statics = staticCallees(of: type, named: word, wantsCall: isCall)
      if isCall {
        if !statics.isEmpty { return chooseAnswer(statics, unitIndex: unitIndex, nameToken: token) }
        return Self.unknown
      }
      if !statics.isEmpty { return summarize(statics.map { .decl($0.ref) }) }
      return Self.unknown
    default:
      if isCall {
        let found = callees(of: receiver, named: word, unitIndex: unitIndex, token: Int32(token))
        if !found.isEmpty {
          let answer = chooseAnswer(found, unitIndex: unitIndex, nameToken: token)
          return inheritsObjectMethod(receiver, answer) ? Self.unknown : answer
        }
        // A property of a function type: `x.onClick()`.
        return summarize(propertySites(of: receiver, named: word, unitIndex: unitIndex))
      }
      let answer = summarize(propertySites(of: receiver, named: word, unitIndex: unitIndex))
      return inheritsObjectMethod(receiver, answer) ? Self.unknown : answer
    }
  }

  /// Whether a Java class's member was found only as a Kotlin built-in's: `toString()` as `Any`'s, `size` or
  /// `add()` as a collection interface's. The JDK's classes implement them, and the stub may not say so.
  private func inheritsObjectMethod(_ receiver: Ty, _ answer: Answer) -> Bool {
    guard case .nominal(let ref, _) = memberBase(receiver), isJava(ref), decl(ref).kind != .protocolType,
      case .decl(let site)? = answer.sites.first, answer.sites.count == 1, decl(site).parent >= 0, !isJava(site),
      decl(site).kind != .extensionDecl, project.isSDK(unit(site))
    else { return false }
    let owner = DeclRef(unit: site.unit, decl: decl(site).parent)
    if decl(owner).kind == .extensionDecl { return false }
    return decl(owner).name != name("Any") || Self.objectMethods.contains(decl(site).name)
  }

  static let objectMethods: Set<Name> = [name("toString"), name("hashCode"), name("equals")]

  /// A value's properties of a name: members, a Java getter, extension properties.
  func propertySites(of receiver: Ty, named word: Name, unitIndex: Int32) -> [Site] {
    if let mapped = javaMappedProperty(of: receiver, named: word) { return [.decl(mapped)] }
    // A Java class's private field is its getter's to Kotlin.
    let members = memberEntries(of: receiver, named: word).map(\.0.ref).filter { isProperty(decl($0)) && !(isJava($0) && decl($0).access == .isPrivate) }
    if !members.isEmpty { return members.map { .decl($0) } }
    if let getter = syntheticGetter(of: receiver, named: word) { return [.decl(getter)] }
    return extensionCandidates(receiver: receiver, named: word, unitIndex: unitIndex, wantsCall: false).map { .decl($0.ref) }
  }

  /// `Type::name`, `x::name`, `::name`.
  private func callableReference(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    let word = unit.hash(token)
    if unit.isToken(token, "class") { return Self.unknown }
    let colons = token - 1
    let start = expressionStart(unit, before: colons)
    if start >= colons {
      // `::name`: a function or property in scope, a class's constructor.
      var found = simpleCallees(word, unitIndex: unitIndex, token: Int32(token))
      if found.isEmpty { return summarize(valueSites(word, unitIndex: unitIndex, token: Int32(token))) }
      found = found.filter { decl($0.ref).kind != .classType || true }
      return summarize(unique(found.map { .decl($0.ref) }))
    }
    let receiver = operandType(unitIndex: unitIndex, dot: colons)
    var type = receiver
    if case .meta(let inner) = receiver { type = inner }
    var sites = callees(of: type, named: word, unitIndex: unitIndex, token: Int32(token)).map { Site.decl($0.ref) }
    if sites.isEmpty { sites = propertySites(of: type, named: word, unitIndex: unitIndex) }
    return summarize(unique(sites))
  }

  /// `f(name = value)`: the parameter of the function called.
  private func namedArgument(unitIndex: Int32, token: Int) -> Answer? {
    let unit = project.units[Int(unitIndex)]
    guard token > 0, unit.isByte(token - 1, 0x28) || unit.isByte(token - 1, 0x2C), let open = unit.isByte(token - 1, 0x28) ? token - 1 : unit.matchingOpenBefore(token - 1),
      unit.isByte(open, 0x28), open > 0
    else { return nil }
    // A named argument's `=` isn't `==`, and an annotation's argument names its class's parameter.
    let nameToken = open - 1
    var callees: [Callee] = []
    if unit.tokens[nameToken].kind == .attribute {
      let word = hashName(unit.source.text + unit.tokens[nameToken].start + 1, unit.tokens[nameToken].length - 1)
      for case .decl(let ref) in typeSites(word, unitIndex: unitIndex, token: Int32(nameToken)) { callees.append(Callee(ref: ref, map: [:], receiver: .unknown)) }
    } else {
      guard let target = callTarget(unitIndex: unitIndex, nameToken: nameToken) else { return Self.unknown }
      callees = chooseOverload(target, unitIndex: unitIndex, nameToken: nameToken)
    }
    let word = unit.hash(token)
    var sites: [Site] = []
    for callee in callees {
      let item = decl(callee.ref)
      let holder = self.unit(callee.ref)
      for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].local == word {
        let param = holder.params[Int(item.paramStart) + p]
        // A `val` parameter of a constructor is its property.
        if case .decl(let property)? = holder.declaredSite(at: Int(param.nameToken), unitIndex: callee.ref.unit), decl(property).kind == .variable {
          sites.append(.decl(property))
        } else {
          sites.append(.local(unit: callee.ref.unit, token: param.nameToken))
        }
      }
    }
    return summarize(unique(sites))
  }

  /// `a name b`: the infix function on a's type.
  private func infixAnswer(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    let word = unit.hash(token)
    let start = infixOperandStart(unit, before: token)
    let receiver = expressionType(unitIndex: unitIndex, start: Int32(start), end: Int32(token))
    let found = callees(of: receiver, named: word, unitIndex: unitIndex, token: Int32(token)).filter { decl($0.ref).paramCount == 1 }
    if !found.isEmpty { return summarize(unique(found.map { .decl($0.ref) })) }
    if receiver == .unknown {
      let named = project.membersNamed(word).filter { decl($0).kind == .function && (decl($0).access != .isPrivate || $0.unit == unitIndex) }
      if !named.isEmpty { return Answer(state: .candidates, sites: named.prefix(12).map { .decl($0) }, byNameOnly: true) }
    }
    return Self.unknown
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
      let holder = project.units[Int(unitIndex)]
      names.insert(holder.isByte(Int(token), 0x7B) ? KotlinWord.it : holder.hash(Int(token)))
      restrict = unitIndex
    case .module(let package):
      guard let text = packageNames[package] else { return [] }
      names.insert(name(String(text.split(separator: ".").last ?? "")))
    }
    for target in targets {
      if case .decl(let ref) = target {
        names.insert(decl(ref).name)
        // A getter is used as a property.
        if isJava(ref), let property = Self.propertyName(ofGetter: unit(ref).string(Int(decl(ref).nameToken))) { names.insert(name(property)) }
        if let property = mappedPropertyName(ref) { names.insert(name(property)) }
      }
    }
    return project.references(named: names, in: restrict, landingOn: targets) { unitIndex, token in
      self.isJava(unitIndex) ? self.java.answer(unitIndex: unitIndex, token: token) : self.answer(unitIndex: unitIndex, token: token)
    }
  }

  /// `getName` → `name`, `isOpen` → `isOpen`.
  static func propertyName(ofGetter getter: String) -> String? {
    if getter.hasPrefix("get"), getter.count > 3, let first = getter.dropFirst(3).first, first.isUppercase {
      return first.lowercased() + getter.dropFirst(4)
    }
    if getter.hasPrefix("is"), getter.count > 2, let first = getter.dropFirst(2).first, first.isUppercase { return getter }
    return nil
  }
}
