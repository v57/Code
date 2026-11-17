import CodeJavaModel
import CodeModel
import CodeScan
import Foundation

/// Scala's model: definitions, references, completion and details from source, on CodeModel's core and Java's layout
/// (`JavaLayout` with Scala's extensions, syntax and package reader: chained package clauses, sbt, Mill and
/// scala-cli source roots, the platform's and dependencies' sources), its standard library the hand-written stub
/// `ScalaStd`. Names resolve as Scala's compiler resolves them: locals and parameters (the innermost binding), then
/// each enclosing template innermost first, with its members (own, then its parents' from the rightmost) and the
/// imports inside it; then the file's top-level declarations, its imports (explicit before wildcards), the packages of
/// its package clauses innermost first, and `scala.Predef`, `scala` and `java.lang`. A class and its companion object
/// share a name: a type position means the class, `T.x` the object, `T(…)` the class's constructor (a case class's
/// `apply`) unless the companion declares `apply` (`unapply` in a pattern). Members go through the receiver's static
/// type and its parents, generics substituted, then the extension methods (`extension`, Scala 2's implicit classes)
/// visible there. Implicit and given resolution is left out: what only an implicit could tell is unknown.
public final class ScalaModel: LanguageModel, NominalTypes {
  public let project: Project
  let layout: JavaLayout
  /// Java's model of the same project: Java declarations' types, and questions in `.java` files.
  let java: JavaModel
  var valueTypes: [DeclRef: Ty] = [:]
  var resolving: Set<DeclRef> = []
  var supertypeCache: [DeclRef: [Ty]] = [:]
  var packageNames: [Name: String] = [:]
  /// Package objects by the package they make (`a.b` for `package object b` in `a`).
  var packageObjects: [String: [DeclRef]]?
  /// Extension groups and implicit classes by the last name of what they extend (`*` for a type parameter).
  var extensionIndex: [Name: [DeclRef]] = [:]
  var extensionIndexUnits = 0
  var depth = 0
  /// Names' text by their hash, as they're asked about.
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
  }

  /// A Scala project under `root`: its Scala and Java files, its build's other source roots, the platform's sources,
  /// the standard library's stub. `findsPlatform: false` reads the built-in Java stub (tests).
  public convenience init(root: String, findsPlatform: Bool = true) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    let std = JVMSourceSet(path: "code-scala-std", files: ScalaStd.files, kind: .platform, folder: "code-scala-std")
    let layout = JavaLayout(
      root: root, findsPlatform: findsPlatform, extensions: ["scala", "sc", "java"], syntax: ScalaSyntax.shared, extraSets: [std],
      packageOfFile: ScalaSyntax.packageName(ofFile:))
    self.init(project: Project(root: root, layout: layout))
  }

  func reset() {
    valueTypes.removeAll()
    supertypeCache.removeAll()
    packageObjects = nil
    extensionIndex.removeAll()
    extensionIndexUnits = 0
  }

  // MARK: Tables

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }
  func isJava(_ unitIndex: Int32) -> Bool { project.units[Int(unitIndex)].syntax !== ScalaSyntax.shared }
  func isJava(_ ref: DeclRef) -> Bool { isJava(ref.unit) }
  func file(_ unitIndex: Int32) -> ScalaFile? { project.units[Int(unitIndex)].scans[ScalaFile.key] as? ScalaFile }
  func info(_ ref: DeclRef) -> ScalaInfo {
    guard let found = file(ref.unit), Int(ref.decl) < found.info.count else { return ScalaInfo() }
    return found.info[Int(ref.decl)]
  }
  func flags(_ ref: DeclRef) -> ScalaFlag { info(ref).flags }
  func isObject(_ ref: DeclRef) -> Bool { !isJava(ref) && decl(ref).kind == .classType && decl(ref).isStatic }

  static let unknown = Answer(state: .unknown, sites: [])
  func summarize(_ sites: [Site]) -> Answer { sites.isEmpty ? Self.unknown : Answer(summarizing: sites) }

  func nameText(_ unit: Unit, _ i: Int) -> String {
    let text = unit.string(i)
    if text.hasPrefix("`"), text.count > 2 { return String(text.dropFirst().dropLast()) }
    return text
  }

  /// A name's hash at a token, as the parser hashed it.
  func word(_ unitIndex: Int32, _ i: Int) -> Name {
    guard let found = file(unitIndex), i >= 0, i < found.names.count else { return project.units[Int(unitIndex)].hash(i) }
    return found.names[i]
  }

  // MARK: Packages

  /// The package a unit is in, as written.
  func packageOf(_ unitIndex: Int32) -> String {
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

  /// A package's top-level declarations of a name: its files' (extension methods too) and its package object's.
  func packageDecls(_ package: String, _ word: Name) -> [DeclRef] {
    var result: [DeclRef] = []
    for module in packageModules(package) {
      for ref in module.top[word] ?? [] where !flags(ref).contains(.packageObject) { result.append(ref) }
      for unitIndex in module.units {
        let holder = project.units[Int(unitIndex)]
        for child in holder.children(of: -1) where holder.decls[Int(child)].kind == .extensionDecl && !holder.decls[Int(child)].isLocal {
          for member in holder.children(of: child) where holder.decls[Int(member)].name == word { result.append(DeclRef(unit: unitIndex, decl: member)) }
        }
      }
      if !result.isEmpty { break }
    }
    for object in packageObjectRefs(package) {
      for member in self.unit(object).children(of: object.decl) where self.unit(object).decls[Int(member)].name == word && !self.unit(object).decls[Int(member)].isLocal {
        result.append(DeclRef(unit: object.unit, decl: member))
      }
    }
    return result
  }

  func packageObjectRefs(_ package: String) -> [DeclRef] {
    if packageObjects == nil {
      var map: [String: [DeclRef]] = [:]
      for u in 0..<project.projectUnits where !isJava(Int32(u)) {
        let holder = project.units[u]
        for child in holder.children(of: -1) {
          let ref = DeclRef(unit: Int32(u), decl: child)
          guard flags(ref).contains(.packageObject) else { continue }
          let outer = packageOf(Int32(u))
          map[(outer.isEmpty ? "" : outer + ".") + nameText(holder, Int(holder.decls[Int(child)].nameToken)), default: []].append(ref)
        }
      }
      packageObjects = map
    }
    return packageObjects?[package] ?? []
  }

  func packageSite(_ package: String) -> Site {
    let hashed = name(package)
    packageNames[hashed] = package
    return .module(hashed)
  }

  func isPackage(_ package: String) -> Bool {
    !package.isEmpty && (layout.isPackage(package) || !packageObjectRefs(package).isEmpty || project.modules[name(package)] != nil)
  }

  /// A standard library class: `Int`, `List`, `Option`.
  func scalaType(_ word: String, in package: String = "scala") -> DeclRef? {
    packageDecls(package, name(word)).first { decl($0).kind.isNominal || decl($0).kind == .typeAlias }
  }

  /// `java.lang.String`.
  func stringType() -> Ty {
    if let found = packageDecls("java.lang", name("String")).first(where: { decl($0).kind.isNominal }) { return .nominal(found, []) }
    return .unknown
  }

  func scalaInstance(_ word: String, _ args: [Ty] = []) -> Ty { scalaType(word).map { .nominal($0, args) } ?? .unknown }

  // MARK: Asking

  public func answer(path: String, line: Int, character: Int) -> Answer {
    guard let unitIndex = project.unitByPath[path] else { return Self.unknown }
    if isJava(unitIndex) { return java.answer(path: path, line: line, character: character) }
    let unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    guard let token = unit.token(at: offset) else { return Self.unknown }
    if unit.tokens[token].kind == .string, let word = interpolatedName(unit, token: token, offset: offset) {
      // `s"$name"`: the name as a term at the string.
      return summarize(preferByPosition(unitIndex, token, resolveName(unitIndex, token, word, want: .term), forceTerm: true))
    }
    return answer(unitIndex: unitIndex, token: token)
  }

  /// `$name` in an interpolated string (`s"…"`, `f"…"`, `raw"…"`, or a part after `${…}`): the name at an offset.
  func interpolatedName(_ unit: Unit, token: Int, offset: Int) -> Name? {
    guard let low = interpolationStart(unit, token: token, offset: offset), low < unit.tokens[token].end, !(unit.source.text[low] >= 0x30 && unit.source.text[low] <= 0x39) else { return nil }
    let text = unit.source.text
    var high = low
    while high < unit.tokens[token].end, Self.isWordByte(text[high]) { high += 1 }
    guard high > low else { return nil }
    let word = hashName(text + low, high - low)
    names[word] = String(decoding: UnsafeBufferPointer(start: text + low, count: high - low), as: UTF8.self)
    return word
  }

  static func isWordByte(_ byte: UInt8) -> Bool { byte == 0x5F || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte >= 0x80 }

  /// Where the name after a `$` in an interpolated string starts, for an offset in or right after it (`s"$na|"`).
  func interpolationStart(_ unit: Unit, token: Int, offset: Int) -> Int? {
    // The string's interpolator: a name touching its first part, back over earlier parts and `${…}`.
    guard let unitIndex = project.unitByPath[unit.path], let facts = file(unitIndex) else { return nil }
    var first = token
    var budget = 200
    while first > 0, budget > 0 {
      budget -= 1
      let kind = unit.tokens[first - 1].kind
      if kind == .interpolationClose, facts.match[first - 1] >= 0 {
        first = Int(facts.match[first - 1])
      } else if kind == .string || kind == .interpolationOpen {
        first -= 1
      } else {
        break
      }
    }
    guard first > 0, unit.tokens[first].kind == .string, unit.tokens[first - 1].kind == .identifier, unit.touchesPrevious(first) else { return nil }
    let text = unit.source.text
    let start = unit.tokens[token].start
    var low = offset
    while low > start, Self.isWordByte(text[low - 1]) { low -= 1 }
    guard low > start, text[low - 1] == 0x24 else { return nil }
    if low - 2 >= start, text[low - 2] == 0x24 { return nil }
    return low
  }

  func answer(unitIndex: Int32, token: Int) -> Answer {
    guard let facts = file(unitIndex) else { return Self.unknown }
    let unit = project.units[Int(unitIndex)]
    guard token < facts.names.count else { return Self.unknown }
    let word = facts.names[token]
    guard word != 0, unit.tokens[token].kind != .punctuation else { return Self.unknown }
    let quoted = unit.source.text[unit.tokens[token].start] == 0x60
    if !quoted, ScalaWord.hard.contains(word) || word == ScalaWord.underscore {
      return Self.unknown
    }
    names[word] = nameText(unit, token)
    // A declaration's own name.
    if let index = facts.declAt[Int32(token)] {
      let item = unit.decls[Int(index)]
      if item.nameToken == Int32(token), item.name != 0 { return Answer(state: .exact, sites: [.decl(DeclRef(unit: unitIndex, decl: index))]) }
    }
    if let site = unit.declaredSite(at: token, unitIndex: unitIndex) { return Answer(state: .exact, sites: [site]) }
    if let closed = facts.endMarkers[Int32(token)] { return Answer(state: .exact, sites: [.decl(DeclRef(unit: unitIndex, decl: closed))]) }
    if !quoted, word == ScalaWord.endWord, unit.startsLine(token), token + 1 < unit.tokens.count, !unit.startsLine(token + 1) { return Self.unknown }
    // A package clause's words.
    if let package = packageClauseWord(unitIndex, token) { return Answer(state: .exact, sites: [packageSite(package)]) }
    // Imports.
    for (position, item) in facts.imports.enumerated() where item.token <= Int32(token) && (item.path.contains(Int32(token)) || item.selectors.contains { $0.token == Int32(token) || $0.renameToken == Int32(token) }) {
      return importAnswer(unitIndex, position, token)
    }
    // A named argument: `f(name = …)`, `copy(price = …)`.
    if unit.isToken(token + 1, "="), token > 0, unit.isByte(token - 1, 0x28) || unit.isByte(token - 1, 0x2C),
      let open = unit.matchingOpenBefore(token), unit.isByte(open, 0x28)
    {
      let found = namedArgument(unitIndex, open: open, word: word)
      if !found.isEmpty { return summarize(found) }
      return Self.unknown
    }
    // A selection.
    if token >= 2, unit.isByte(token - 1, 0x2E) {
      if unit.isToken(token - 2, "super") {
        return summarize(superMembers(unitIndex, token, word))
      }
      let receiver = expressionType(unitIndex, endingAt: token - 2)
      let found = memberSites(of: receiver, word, unitIndex: unitIndex, at: token)
      return summarize(preferByPosition(unitIndex, token, found))
    }
    // An infix or postfix method: `a compare b`, `xs filter p`.
    if let receiverEnd = infixReceiverEnd(unitIndex, token) {
      let receiver = expressionType(unitIndex, endingAt: receiverEnd)
      if receiver != .unknown {
        let found = memberSites(of: receiver, word, unitIndex: unitIndex, at: token)
        if !found.isEmpty { return summarize(found) }
      }
    }
    var want = positionKind(unitIndex, token)
    // `a.b.C` in a type: its first word may be a package or an object.
    if want == .type, unit.isByte(token + 1, 0x2E) { want = .any }
    let found = resolveName(unitIndex, token, word, want: want)
    if found.count == 1, case .module = found[0] { return Answer(state: .exact, sites: found) }
    return summarize(preferByPosition(unitIndex, token, found))
  }

  /// A word of a `package a.b` clause: the package up to it.
  func packageClauseWord(_ unitIndex: Int32, _ token: Int) -> String? {
    let unit = project.units[Int(unitIndex)]
    var k = token
    var words: [String] = []
    while k >= 0 {
      if unit.isToken(k, "package") { break }
      guard unit.tokens[k].kind == .identifier || unit.isByte(k, 0x2E) else { return nil }
      if unit.tokens[k].kind == .identifier { words.insert(nameText(unit, k), at: 0) }
      if unit.startsLine(k) { return nil }
      k -= 1
    }
    guard k >= 0, unit.isToken(k, "package"), !unit.isToken(k + 1, "object") else { return nil }
    // Chained clauses before this one.
    var outer: [String] = []
    var m = 0
    while m < k {
      if unit.isToken(m, "package") {
        var j = m + 1
        while j < k, unit.tokens[j].kind == .identifier || unit.isByte(j, 0x2E) {
          if unit.tokens[j].kind == .identifier { outer.append(nameText(unit, j)) }
          j += 1
        }
        m = j
        continue
      }
      if !unit.isByte(m, 0x3B), !unit.isByte(m, 0x7B) { return words.joined(separator: ".") }
      m += 1
    }
    return (outer + words).joined(separator: ".")
  }

  // MARK: Positions

  enum Want { case term, type, any }

  /// Whether a name stands for a type: after `:`, `extends`, `with`, `new`, `given`, `<:`, `>:`, inside `[…]`, or in
  /// parentheses that follow `:` or `=>` (a tuple or function type).
  func positionKind(_ unitIndex: Int32, _ i: Int) -> Want {
    let unit = project.units[Int(unitIndex)]
    // `a.b.T` is where its first word is.
    var i = i
    while i > 1, unit.isByte(i - 1, 0x2E), unit.touchesPrevious(i), unit.tokens[i - 2].kind == .identifier { i -= 2 }
    if i > 0 {
      if unit.isToken(i - 1, ":") || unit.isToken(i - 1, "extends") || unit.isToken(i - 1, "with") || unit.isToken(i - 1, "new") || unit.isToken(i - 1, "<:")
        || unit.isToken(i - 1, ">:") || unit.isToken(i - 1, "given") || unit.isToken(i - 1, "derives")
      {
        if unit.isToken(i - 1, "given"), unit.isToken(i + 1, ":") { return .term }
        return .type
      }
      // `case _: T`, `x: A | B`, `=> T` in a type.
      if unit.isToken(i - 1, "|") || unit.isToken(i - 1, "&"), typePositionBefore(unit, i - 1) { return .type }
      if unit.isToken(i - 1, "=>"), typePositionBefore(unit, i - 1) { return .type }
    }
    var o = unit.matchingOpenBefore(i)
    while let open = o {
      if unit.isByte(open, 0x5B) {
        // `xs.sortBy[T]`, `List[Item]`: type arguments.
        return .type
      }
      if unit.isByte(open, 0x7B) || open == 0 { break }
      let before = open - 1
      if unit.isToken(before, ":") || unit.isToken(before, "=>") { return .type }
      if unit.tokens[before].kind == .identifier || unit.tokens[before].kind == .number || unit.tokens[before].kind == .string || unit.tokens[before].kind == .close { break }
      o = unit.matchingOpenBefore(open)
    }
    return .term
  }

  /// Whether what comes before token `i` (an operator) is a type: back to `:`, `extends` or `[` on its line.
  private func typePositionBefore(_ unit: Unit, _ i: Int) -> Bool {
    var k = i - 1
    while k >= 0, i - k < 48 {
      // A bracketed part before it: a lambda's `(a: Int)`, a tuple type's `(A, B)`, read past.
      if unit.isByte(k, 0x29) || unit.isByte(k, 0x5D), let open = unit.matchingOpen(k), open < k {
        k = open - 1
        continue
      }
      if unit.isToken(k, ":") {
        // `case x: T =>`: the case's own arrow, not a function type's.
        var m = k - 1
        while m >= 0, k - m < 24, !unit.isByte(m, 0x28), !unit.isByte(m, 0x7B), !unit.isToken(m, "=") {
          if unit.isToken(m, "case") { return false }
          if unit.startsLine(m) { break }
          m -= 1
        }
        return true
      }
      if unit.isByte(k, 0x5B) || unit.isToken(k, "extends") { return true }
      if unit.isToken(k, "=") || unit.isByte(k, 0x7B) || unit.isToken(k, "case") || unit.startsLine(k + 1) && k + 1 < i && unit.isToken(k + 1, "case") { return false }
      if unit.startsLine(k) { return false }
      k -= 1
    }
    return false
  }

  /// Whether a token is inside a `case` pattern, before its `=>`.
  func inPattern(_ unitIndex: Int32, _ i: Int) -> Bool {
    let unit = project.units[Int(unitIndex)]
    var k = i - 1
    var budget = 64
    while k >= 0, budget > 0 {
      budget -= 1
      if unit.isToken(k, "case") { return true }
      if unit.isToken(k, "=>") || unit.isToken(k, "=") || unit.isByte(k, 0x7B) && unit.startsLine(k + 1) { return false }
      if unit.startsLine(k), !unit.isToken(k, "case") { return false }
      k -= 1
    }
    return false
  }

  /// Between a class and its companion object: a call or pattern `T(…)` means the class (when the companion has no
  /// `apply`/`unapply`, else that method), a selection `T.x` the object, a type the class.
  func preferByPosition(_ unitIndex: Int32, _ i: Int, _ found: [Site], forceTerm: Bool = false) -> [Site] {
    guard !found.isEmpty else { return found }
    let unit = project.units[Int(unitIndex)]
    var classes: [DeclRef] = []
    var objects: [DeclRef] = []
    var others: [Site] = []
    for site in found {
      if case .decl(let ref) = site {
        let item = decl(ref)
        if isObject(ref) {
          objects.append(ref)
          continue
        }
        if item.kind.isNominal || item.kind == .typeAlias {
          classes.append(ref)
          continue
        }
      }
      others.append(site)
    }
    if classes.isEmpty, objects.isEmpty { return others }
    let isType = !forceTerm && positionKind(unitIndex, i) == .type
    if isType { return classes.isEmpty ? [] : [.decl(classes[0])] }
    if !others.isEmpty, classes.isEmpty, objects.isEmpty { return others }
    let follows = i + 1 < unit.tokens.count
    let selected = follows && unit.isByte(i + 1, 0x2E)
    // `T(…)`, `T[A](…)`; `T[A]` alone (`Codec[Money].encode`) names the object.
    var callOpen = i + 1
    if follows, unit.isByte(callOpen, 0x5B), unit.touchesPrevious(callOpen), let close = file(unitIndex)?.match[callOpen], close > callOpen { callOpen = Int(close) + 1 }
    let called = follows && callOpen < unit.tokens.count && unit.isByte(callOpen, 0x28) && !unit.startsLine(callOpen)
    if selected {
      if let object = objects.first { return [.decl(object)] }
      if let cls = classes.first, decl(cls).kind == .enumeration || isJava(cls) { return [.decl(cls)] }
      return []
    }
    if called {
      if let cls = classes.first {
        let item = decl(cls)
        if isJava(cls) { return [.decl(cls)] }
        let wanted = inPattern(unitIndex, i) ? ScalaWord.unapply : ScalaWord.apply
        if let companion = companion(of: cls), !self.unit(companion).children(of: companion.decl).filter({ self.unit(companion).decls[Int($0)].name == wanted }).isEmpty {
          let methods = self.unit(companion).children(of: companion.decl).filter { self.unit(companion).decls[Int($0)].name == wanted }.map { Site.decl(DeclRef(unit: companion.unit, decl: $0)) }
          // A case class's own `apply`/`unapply` is there too, overloaded with what the companion declares.
          if flags(cls).contains(.isCase), unit.isByte(callOpen, 0x28) {
            let count = arguments(unitIndex, open: callOpen).count
            let fits = methods.filter { site in
              guard case .decl(let ref) = site else { return true }
              return accepts(ref, count)
            }
            let list = classParams(cls).filter { info($0).listIndex == 0 }
            let required = list.filter { !info($0).hasDefault }.count
            let classFits = wanted == ScalaWord.unapply ? count == list.count : count >= required && count <= list.count
            if classFits { return fits + [.decl(cls)] }
            return fits.isEmpty ? [] : fits
          }
          return chooseByArity(unitIndex, callOpen, methods)
        }
        if item.kind == .classType || item.kind == .enumCase { return [.decl(cls)] }
        return []
      }
      if let object = objects.first {
        let applies = self.unit(object).children(of: object.decl).filter { self.unit(object).decls[Int($0)].name == ScalaWord.apply }
        if applies.isEmpty { return [.decl(object)] }
        return chooseByArity(unitIndex, callOpen, applies.map { .decl(DeclRef(unit: object.unit, decl: $0)) })
      }
    }
    if let object = objects.first { return [.decl(object)] }
    if let cls = classes.first, decl(cls).kind == .enumCase { return [.decl(cls)] }
    if let cls = classes.first, isJava(cls) { return [.decl(cls)] }
    return others
  }

  /// Methods a call at `open` (its `(`) can mean, by how many arguments it passes.
  func chooseByArity(_ unitIndex: Int32, _ open: Int, _ sites: [Site]) -> [Site] {
    guard sites.count > 1 else { return sites }
    let unit = project.units[Int(unitIndex)]
    guard unit.isByte(open, 0x28) else { return sites }
    let count = arguments(unitIndex, open: open).count
    let fits = sites.filter { site in
      guard case .decl(let ref) = site else { return true }
      return accepts(ref, count)
    }
    return fits.isEmpty ? sites : fits
  }

  /// Whether a function's first parameter list takes this many arguments.
  func accepts(_ ref: DeclRef, _ count: Int) -> Bool {
    let item = decl(ref)
    guard item.kind == .function || item.kind == .initializer else { return true }
    if isJava(ref) {
      let holder = self.unit(ref)
      let params = (0..<Int(item.paramCount)).map { holder.params[Int(item.paramStart) + $0] }
      if params.last?.variadic == true { return count >= params.count - 1 }
      return params.count == count
    }
    let lists = info(ref).lists
    guard let first = lists.first else { return count == 0 }
    let holder = self.unit(ref)
    let params = (0..<Int(first)).map { holder.params[Int(item.paramStart) + $0] }
    let required = params.filter { !$0.hasDefault }.count
    if params.last?.variadic == true { return count >= required - 1 }
    return count >= required && count <= params.count
  }

  // MARK: Names

  /// What a simple name at token `i` means: locals and parameters, then each enclosing template (its members, the
  /// imports inside it), then the file and its packages, then Scala's default imports.
  func resolveName(_ unitIndex: Int32, _ i: Int, _ word: Name, want: Want, skipImport: Int? = nil) -> [Site] {
    guard let facts = file(unitIndex) else { return [] }
    let unit = project.units[Int(unitIndex)]
    if let local = localSite(unitIndex, i, word, want: want) { return [local] }
    for level in templatesAround(unitIndex, i) {
      let ref = DeclRef(unit: unitIndex, decl: level)
      let found = filter(templateMembers(ref, word), want)
      if !found.isEmpty { return found.map { .decl($0) } }
      if let hit = importsHit(unitIndex, i, word, want: want, owner: level, skip: skipImport) { return hit }
    }
    // The file's own top-level declarations.
    var own: [Site] = []
    for child in unit.children(of: -1) {
      let item = unit.decls[Int(child)]
      if item.isLocal { continue }
      let ref = DeclRef(unit: unitIndex, decl: child)
      if item.kind == .extensionDecl {
        for member in unit.children(of: child) where unit.decls[Int(member)].name == word { own.append(.decl(DeclRef(unit: unitIndex, decl: member))) }
        continue
      }
      if item.name == word, wanted(ref, want), !flags(ref).contains(.packageObject) { own.append(.decl(ref)) }
    }
    if !own.isEmpty { return own }
    if let hit = importsHit(unitIndex, i, word, want: want, owner: -1, skip: skipImport) { return hit }
    let text = names[word] ?? nameText(unit, i)
    for package in facts.packages.reversed() {
      let found = packageDecls(package, word).filter { wanted($0, want) }
      if !found.isEmpty { return found.map { .decl($0) } }
      let sub = package + "." + text
      if want != .type, isPackage(sub) { return [packageSite(sub)] }
    }
    if facts.packages.isEmpty {
      let found = packageDecls("", word).filter { wanted($0, want) }
      if !found.isEmpty { return found.map { .decl($0) } }
    }
    if want != .type, isPackage(text) { return [packageSite(text)] }
    // `scala.Predef._`, `scala._`, `java.lang._`.
    if let predef = packageDecls("scala", name("Predef")).first {
      let found = filter(templateMembers(predef, word), want)
      if !found.isEmpty { return found.map { .decl($0) } }
    }
    for package in ["scala", "java.lang"] {
      let found = packageDecls(package, word).filter { wanted($0, want) }
      if !found.isEmpty { return found.map { .decl($0) } }
    }
    // `scala`'s subpackages: `math.max`, `util.Try`.
    if want != .type, isPackage("scala." + text) { return [packageSite("scala." + text)] }
    return []
  }

  /// Whether a declaration fits where a name stands: a type position wants types, a term anything but a plain type.
  func wanted(_ ref: DeclRef, _ want: Want) -> Bool {
    let item = decl(ref)
    switch want {
    case .any: return true
    case .type: return (item.kind.isNominal || item.kind == .typeAlias || item.kind == .enumCase && flags(ref).contains(.hasParams)) && !isObject(ref)
    case .term: return item.kind != .typeAlias && item.kind != .protocolType || isJava(ref)
    }
  }

  func filter(_ refs: [DeclRef], _ want: Want) -> [DeclRef] { refs.filter { wanted($0, want) } }

  /// A local, a parameter or a type parameter seen at `i`: the innermost binding of the name.
  func localSite(_ unitIndex: Int32, _ i: Int, _ word: Name, want: Want) -> Site? {
    guard let facts = file(unitIndex) else { return nil }
    let unit = project.units[Int(unitIndex)]
    let at = Int32(i)
    var best: (start: Int32, site: Site)?
    func offer(_ start: Int32, _ site: Site) {
      if best == nil || start >= best!.start { best = (start, site) }
    }
    for index in facts.localsByName[word] ?? [] {
      let local = facts.info[Int(index)]
      guard local.scopeStart <= at, at < local.scopeEnd else { continue }
      if local.holeStart >= 0, local.holeStart <= at, at < local.holeEnd { continue }
      let ref = DeclRef(unit: unitIndex, decl: index)
      guard wanted(ref, want) || want == .any else { continue }
      if want == .type, !decl(ref).kind.isType { continue }
      offer(local.scopeStart, .decl(ref))
    }
    // Parameters and type parameters of the declarations around it.
    for index in unit.chain(at: at) {
      let item = unit.decls[Int(index)]
      if want != .type, item.kind == .function || item.kind == .initializer || item.kind == .extensionDecl {
        for p in 0..<Int(item.paramCount) {
          let param = unit.params[Int(item.paramStart) + p]
          if param.local == word { offer(item.first, .local(unit: unitIndex, token: param.nameToken)) }
        }
      }
      if want != .term {
        for g in 0..<Int(item.genericCount) {
          let generic = unit.generics[Int(item.genericStart) + g]
          if generic.name == word { offer(item.first, .generic(unit: unitIndex, token: generic.token)) }
        }
      }
    }
    // Local functions' parameters, which the chain doesn't reach.
    if want != .type {
      for index in facts.localsByName.values.joined() where unit.decls[Int(index)].kind == .function {
        let item = unit.decls[Int(index)]
        guard item.first <= at, at < item.end else { continue }
        for p in 0..<Int(item.paramCount) where unit.params[Int(item.paramStart) + p].local == word {
          offer(item.first, .local(unit: unitIndex, token: unit.params[Int(item.paramStart) + p].nameToken))
        }
        if want == .any {
          for g in 0..<Int(item.genericCount) where unit.generics[Int(item.genericStart) + g].name == word { offer(item.first, .generic(unit: unitIndex, token: unit.generics[Int(item.genericStart) + g].token)) }
        }
      }
    } else {
      for index in facts.localsByName.values.joined() where unit.decls[Int(index)].kind == .function {
        let item = unit.decls[Int(index)]
        guard item.first <= at, at < item.end else { continue }
        for g in 0..<Int(item.genericCount) where unit.generics[Int(item.genericStart) + g].name == word { offer(item.first, .generic(unit: unitIndex, token: unit.generics[Int(item.genericStart) + g].token)) }
      }
    }
    return best?.site
  }

  /// Templates whose body holds token `i`, innermost first.
  func templatesAround(_ unitIndex: Int32, _ i: Int) -> [Int32] {
    guard let facts = file(unitIndex) else { return [] }
    let at = Int32(i)
    var result = facts.templates.filter { facts.info[Int($0)].bodyStart <= at && at < facts.info[Int($0)].bodyEnd }
    result.sort { facts.info[Int($0)].bodyStart > facts.info[Int($1)].bodyStart }
    return result
  }

  // MARK: Members

  /// A template's members of a name: its own (an enum's cases; an enum's companion sees them too), then its parents'
  /// from the rightmost. Extension methods are their group's alone.
  func templateMembers(_ ref: DeclRef, _ word: Name, seen: inout Set<DeclRef>) -> [DeclRef] {
    guard seen.insert(ref).inserted, seen.count < 64 else { return [] }
    let holder = self.unit(ref)
    var own: [DeclRef] = []
    for child in holder.children(of: ref.decl) {
      let item = holder.decls[Int(child)]
      if item.name == word, item.kind != .extensionDecl { own.append(DeclRef(unit: ref.unit, decl: child)) }
    }
    if !own.isEmpty { return own }
    if isObject(ref), let cls = companion(of: ref), decl(cls).kind == .enumeration {
      let cases = self.unit(cls).children(of: cls.decl).filter { self.unit(cls).decls[Int($0)].name == word && self.unit(cls).decls[Int($0)].kind == .enumCase }
      if !cases.isEmpty { return cases.map { DeclRef(unit: cls.unit, decl: $0) } }
    }
    for parent in supertypes(of: ref).reversed() {
      guard case .nominal(let target, _) = parent else { continue }
      let found = templateMembers(target, word, seen: &seen)
      if !found.isEmpty { return found }
    }
    return []
  }

  func templateMembers(_ ref: DeclRef, _ word: Name) -> [DeclRef] {
    var seen: Set<DeclRef> = []
    return templateMembers(ref, word, seen: &seen)
  }

  /// The object of the same name in the same scope as a class, or the class (or enum) of an object.
  func companion(of ref: DeclRef) -> DeclRef? {
    guard !isJava(ref) else { return nil }
    let item = decl(ref)
    guard item.name != 0 else { return nil }
    let holder = self.unit(ref)
    let wantsObject = !isObject(ref)
    for sibling in holder.children(of: item.parent) where sibling != ref.decl {
      let other = holder.decls[Int(sibling)]
      guard other.name == item.name, other.isLocal == item.isLocal else { continue }
      let otherRef = DeclRef(unit: ref.unit, decl: sibling)
      if wantsObject, isObject(otherRef) { return otherRef }
      if !wantsObject, other.kind.isNominal, !isObject(otherRef) { return otherRef }
    }
    return nil
  }

  /// `super.name`: the parents' members.
  func superMembers(_ unitIndex: Int32, _ i: Int, _ word: Name) -> [Site] {
    guard let level = templatesAround(unitIndex, i).first else { return [] }
    let ref = DeclRef(unit: unitIndex, decl: level)
    for parent in supertypes(of: ref).reversed() {
      guard case .nominal(let target, _) = parent else { continue }
      let found = templateMembers(target, word)
      if !found.isEmpty { return found.map { .decl($0) } }
    }
    return []
  }

  // MARK: Imports

  /// What an import's path names: a package, or a declaration whose members it takes.
  enum ImportBase: Equatable {
    case package(String)
    case decl(DeclRef)
    case value(Ty)
  }

  /// The imports owned by a level that are seen at `i`, explicit ones before wildcards: what they bring in under a name.
  func importsHit(_ unitIndex: Int32, _ i: Int, _ word: Name, want: Want, owner: Int32, skip: Int?) -> [Site]? {
    guard let facts = file(unitIndex) else { return nil }
    var candidates: [Int] = []
    for (position, item) in facts.imports.enumerated() where position != skip && item.owner == owner && item.scopeStart < Int32(i) && Int32(i) < item.scopeEnd {
      candidates.append(position)
    }
    guard !candidates.isEmpty else { return nil }
    candidates.sort { facts.imports[$0].scopeStart > facts.imports[$1].scopeStart }
    for explicit in [true, false] {
      for position in candidates {
        let item = facts.imports[position]
        if explicit {
          for selector in item.selectors {
            let bound = selector.rename != 0 ? selector.rename : selector.name
            guard bound == word, selector.rename != 1 else { continue }
            guard let base = importBase(unitIndex, position) else { return [] }
            let found = entityMembers(base, selector.name, want: want)
            return found
          }
        } else {
          guard item.wildcard else { continue }
          // A selector renamed or hidden takes its name out of the wildcard.
          if item.selectors.contains(where: { $0.name == word && $0.rename != 0 }) { continue }
          guard let base = importBase(unitIndex, position) else { continue }
          let found = entityMembers(base, word, want: want)
          if !found.isEmpty { return found }
        }
      }
    }
    return nil
  }

  func importBase(_ unitIndex: Int32, _ position: Int) -> ImportBase? {
    guard let facts = file(unitIndex) else { return nil }
    let key = Int32(position)
    if let known = facts.importBases[key] { return known }
    facts.importBases[key] = .some(nil)
    let item = facts.imports[position]
    var result: ImportBase? = nil
    if let firstToken = item.path.first {
      let unit = project.units[Int(unitIndex)]
      result = importPrefix(unitIndex, position, upTo: item.path.count)
      _ = unit
      _ = firstToken
    }
    facts.importBases[key] = .some(result)
    return result
  }

  /// What the first `count` words of an import's path name.
  func importPrefix(_ unitIndex: Int32, _ position: Int, upTo count: Int) -> ImportBase? {
    guard let facts = file(unitIndex), count > 0 else { return nil }
    let item = facts.imports[position]
    let unit = project.units[Int(unitIndex)]
    let words = item.path.prefix(count).map { Int($0) }
    let firstWord = word(unitIndex, words[0])
    let firstText = nameText(unit, words[0])
    names[firstWord] = firstText
    var entity: ImportBase?
    if firstText == "_root_" {
      entity = .package("")
    } else {
      let found = resolveName(unitIndex, Int(item.token), firstWord, want: .any, skipImport: position)
      var preferred: Site?
      for site in found {
        if case .decl(let ref) = site, isObject(ref) || decl(ref).kind == .enumeration { preferred = site }
        if case .module = site { preferred = site }
      }
      if preferred == nil { preferred = found.first }
      switch preferred {
      case .module(let package)?: entity = .package(packageNames[package] ?? firstText)
      case .decl(let ref)?:
        if decl(ref).kind.isNominal { entity = .decl(ref) } else { entity = .value(valueType(of: ref)) }
      case .local(let u, let t)?: entity = .value(siteType(.local(unit: u, token: t)))
      default:
        if isPackage(firstText) { entity = .package(firstText) }
      }
    }
    for k in words.dropFirst() {
      guard let current = entity else { return nil }
      entity = select(current, word(unitIndex, k), text: nameText(unit, k))
    }
    return entity
  }

  func select(_ entity: ImportBase, _ word: Name, text: String) -> ImportBase? {
    switch entity {
    case .package(let package):
      let sub = package.isEmpty ? text : package + "." + text
      let decls = packageDecls(package, word).filter { !flags($0).contains(.packageObject) }
      if let object = decls.first(where: { isObject($0) || decl($0).kind == .enumeration }) ?? decls.first(where: { decl($0).kind.isNominal }) { return .decl(object) }
      if isPackage(sub) { return .package(sub) }
      if let value = decls.first { return .value(valueType(of: value)) }
      return nil
    case .decl(let ref):
      let base = staticBase(ref)
      guard let base else { return nil }
      let found = templateMembers(base, word)
      if let object = found.first(where: { isObject($0) || decl($0).kind.isNominal }) { return .decl(object) }
      if let value = found.first { return .value(valueType(of: value)) }
      return nil
    case .value(let ty):
      let found = memberRefs(of: ty, word)
      if let value = found.first { return .value(valueType(of: value)) }
      return nil
    }
  }

  /// The template whose members a name reaches: an object or enum itself, a class's companion object.
  func staticBase(_ ref: DeclRef) -> DeclRef? {
    if isObject(ref) || decl(ref).kind == .enumeration || isJava(ref) { return ref }
    return companion(of: ref)
  }

  /// The members an import's base has under a name.
  func entityMembers(_ entity: ImportBase, _ word: Name, want: Want) -> [Site] {
    switch entity {
    case .package(let package):
      let found = packageDecls(package, word).filter { wanted($0, want) && !flags($0).contains(.packageObject) }
      if !found.isEmpty { return found.map { .decl($0) } }
      let text = names[word] ?? ""
      let sub = package.isEmpty ? text : package + "." + text
      if want != .type, !text.isEmpty, isPackage(sub) { return [packageSite(sub)] }
      return []
    case .decl(let ref):
      if isJava(ref) {
        return self.unit(ref).children(of: ref.decl).filter { self.unit(ref).decls[Int($0)].name == word && self.unit(ref).decls[Int($0)].isStatic }.map { .decl(DeclRef(unit: ref.unit, decl: $0)) }
      }
      var found: [DeclRef] = []
      if decl(ref).kind == .enumeration {
        found = self.unit(ref).children(of: ref.decl).filter { self.unit(ref).decls[Int($0)].name == word && self.unit(ref).decls[Int($0)].kind == .enumCase }.map { DeclRef(unit: ref.unit, decl: $0) }
        if found.isEmpty, let object = companion(of: ref) { found = templateMembers(object, word) }
      } else if let base = staticBase(ref) {
        found = templateMembers(base, word)
        // Extension methods an object holds are imported with it.
        if found.isEmpty { found = extensionMembers(in: base, word) }
      }
      return filter(found, want).map { .decl($0) }
    case .value(let ty):
      return filter(memberRefs(of: ty, word), want).map { .decl($0) }
    }
  }

  /// The methods of the extension groups a template holds.
  func extensionMembers(in ref: DeclRef, _ word: Name) -> [DeclRef] {
    let holder = self.unit(ref)
    var result: [DeclRef] = []
    for child in holder.children(of: ref.decl) where holder.decls[Int(child)].kind == .extensionDecl {
      for member in holder.children(of: child) where holder.decls[Int(member)].name == word { result.append(DeclRef(unit: ref.unit, decl: member)) }
    }
    return result
  }

  /// The answer at a word of an import: a selector's declaration, a path word's package or object.
  func importAnswer(_ unitIndex: Int32, _ position: Int, _ token: Int) -> Answer {
    guard let facts = file(unitIndex) else { return Self.unknown }
    let item = facts.imports[position]
    for selector in item.selectors where selector.token == Int32(token) || selector.renameToken == Int32(token) {
      guard let base = importBase(unitIndex, position) else { return Self.unknown }
      names[selector.name] = nameText(project.units[Int(unitIndex)], Int(selector.token))
      let found = entityMembers(base, selector.name, want: .any)
      if found.count > 1 {
        // A class and its companion: both are imported; the class names them.
        let refs = found.compactMap { site -> DeclRef? in if case .decl(let ref) = site { return ref } else { return nil } }
        if let cls = refs.first(where: { !isObject($0) && decl($0).kind.isNominal }) { return Answer(state: .exact, sites: [.decl(cls)]) }
      }
      return summarize(found)
    }
    guard let at = item.path.firstIndex(of: Int32(token)) else { return Self.unknown }
    switch importPrefix(unitIndex, position, upTo: at + 1) {
    case .package(let package)?: return package.isEmpty ? Self.unknown : Answer(state: .exact, sites: [packageSite(package)])
    case .decl(let ref)?: return Answer(state: .exact, sites: [.decl(ref)])
    default: return Self.unknown
    }
  }

  // MARK: Named arguments

  /// `f(name = …)`: the parameter of the method or class called; `copy(name = …)` a case class's field.
  func namedArgument(_ unitIndex: Int32, open: Int, word: Name) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    let callee = open - 1
    guard callee >= 0 else { return [] }
    // Which parameter list: `f(a)(name = b)`.
    var listIndex = 0
    var nameEnd = callee
    while nameEnd >= 0, unit.tokens[nameEnd].kind == .close, unit.isByte(nameEnd, 0x29), let back = unit.matchingOpen(nameEnd) {
      listIndex += 1
      nameEnd = back - 1
    }
    guard nameEnd >= 0, unit.tokens[nameEnd].kind == .identifier else { return [] }
    let targets = callTargets(unitIndex, nameToken: nameEnd)
    for target in targets {
      if decl(target).kind == .function || decl(target).kind == .initializer {
        if decl(target).name == ScalaWord.copy, !isJava(target), let owner = enclosingClass(target), flags(owner).contains(.isCase) || decl(owner).kind == .enumCase {
          if let field = classParams(owner).first(where: { decl($0).name == word }) { return [.decl(field)] }
        }
        if let site = parameter(target, list: listIndex, named: word) { return [site] }
        continue
      }
      if decl(target).kind.isNominal || decl(target).kind == .enumCase {
        if let field = classParams(target).first(where: { decl($0).name == word }) { return [.decl(field)] }
      }
    }
    // A synthesized `copy`: on a case class's value, or inside one.
    if unit.isToken(nameEnd, "copy") {
      var owner: DeclRef?
      if nameEnd >= 2, unit.isByte(nameEnd - 1, 0x2E) {
        if case .nominal(let ref, _) = expressionType(unitIndex, endingAt: nameEnd - 2) { owner = ref }
      } else if let level = templatesAround(unitIndex, nameEnd).first(where: { decl(DeclRef(unit: unitIndex, decl: $0)).kind != .extensionDecl }) {
        owner = DeclRef(unit: unitIndex, decl: level)
      }
      if let owner, flags(owner).contains(.isCase) || decl(owner).kind == .enumCase {
        if let field = classParams(owner).first(where: { decl($0).name == word }) { return [.decl(field)] }
      }
    }
    return []
  }

  /// The class a member is declared in.
  func enclosingClass(_ ref: DeclRef) -> DeclRef? {
    let item = decl(ref)
    guard item.parent >= 0 else { return nil }
    return DeclRef(unit: ref.unit, decl: item.parent)
  }

  /// A class's constructor parameters (the first list's and the others'), in order.
  func classParams(_ ref: DeclRef) -> [DeclRef] {
    guard !isJava(ref) else { return [] }
    let holder = self.unit(ref)
    return holder.children(of: ref.decl).filter { child in
      let index = DeclRef(unit: ref.unit, decl: child)
      return flags(index).contains(.classParam)
    }.map { DeclRef(unit: ref.unit, decl: $0) }
  }

  /// A function's parameter of a name in one of its lists.
  func parameter(_ ref: DeclRef, list: Int, named word: Name) -> Site? {
    let item = decl(ref)
    let holder = self.unit(ref)
    if isJava(ref) { return nil }
    let lists = info(ref).lists
    var start = Int(item.paramStart)
    for (index, size) in lists.enumerated() {
      if index == list {
        for p in start..<(start + Int(size)) where holder.params[p].local == word { return .local(unit: ref.unit, token: holder.params[p].nameToken) }
        return nil
      }
      start += Int(size)
    }
    return nil
  }

  /// What a callee name before `(` can mean: methods (overloads), classes, objects.
  func callTargets(_ unitIndex: Int32, nameToken: Int) -> [DeclRef] {
    let unit = project.units[Int(unitIndex)]
    let word = self.word(unitIndex, nameToken)
    var sites: [Site]
    if nameToken >= 2, unit.isByte(nameToken - 1, 0x2E) {
      sites = memberSites(of: expressionType(unitIndex, endingAt: nameToken - 2), word, unitIndex: unitIndex, at: nameToken)
    } else {
      sites = resolveName(unitIndex, nameToken, word, want: .term)
    }
    var result: [DeclRef] = []
    for site in sites {
      guard case .decl(let ref) = site else { continue }
      if isObject(ref) {
        // `Foo(…)` on an object: its `apply`; a companion without one: the case class.
        let applies = templateMembers(ref, ScalaWord.apply)
        if !applies.isEmpty {
          result += applies
        } else if let cls = companion(of: ref) {
          result.append(cls)
        }
        continue
      }
      if decl(ref).kind.isNominal, let object = companion(of: ref) {
        let applies = templateMembers(object, ScalaWord.apply)
        if !applies.isEmpty {
          result += applies
          continue
        }
      }
      result.append(ref)
    }
    return result
  }

  // MARK: References

  public func references(of answer: Answer) -> [(path: String, line: Int)] {
    guard answer.state != .unknown, !answer.byNameOnly else { return [] }
    var targets = Set(answer.sites)
    var words: Set<Name> = []
    var restrict: Int32?
    for site in answer.sites {
      switch site {
      case .decl(let ref):
        if isJava(ref) { return java.references(of: answer) }
        let item = decl(ref)
        words.insert(item.name)
        if item.isLocal { restrict = ref.unit }
      case .local(let unitIndex, let token), .generic(let unitIndex, let token):
        words.insert(word(unitIndex, Int(token)))
        restrict = unitIndex
      case .module:
        return []
      }
    }
    // Names an import gives it: `import a.{B => C}` names it `C` in that file.
    for u in 0..<project.projectUnits where restrict == nil || restrict == Int32(u) {
      for entry in file(Int32(u))?.imports ?? [] {
        for selector in entry.selectors where words.contains(selector.name) && selector.rename > 1 { words.insert(selector.rename) }
      }
    }
    var seen = Set<String>()
    var result: [(String, Int)] = []
    func take(_ found: Answer, _ unit: Unit, line: Int) {
      guard found.state != .unknown, !found.byNameOnly, found.sites.contains(where: targets.contains) else { return }
      let path = project.rootRelative(unit.path)
      if seen.insert("\(path):\(line)").inserted { result.append((path, line)) }
    }
    for u in 0..<project.projectUnits {
      if let restrict, restrict != Int32(u) { continue }
      let unitIndex = Int32(u)
      let unit = project.units[u]
      // Java's files by their tokens' text; Scala's by their names (backquotes dropped) and `$name` in interpolations.
      let facts = file(unitIndex)
      for (index, token) in unit.tokens.enumerated() {
        switch token.kind {
        case .identifier, .keyword, .declarationKeyword:
          if let facts {
            guard index < facts.names.count, words.contains(facts.names[index]) else { continue }
            take(self.answer(unitIndex: unitIndex, token: index), unit, line: unit.source.lines.line(of: token.start) + 1)
          } else {
            guard words.contains(hashName(unit.source.text + token.start, token.length)) else { continue }
            take(java.answer(unitIndex: unitIndex, token: index), unit, line: unit.source.lines.line(of: token.start) + 1)
          }
        case .string where facts != nil:
          var k = token.start
          while k + 1 < token.end {
            defer { k += 1 }
            guard unit.source.text[k] == 0x24 else { continue }
            var e = k + 1
            while e < token.end, unit.source.text[e] == 0x5F || (unit.source.text[e] | 0x20 >= 0x61 && unit.source.text[e] | 0x20 <= 0x7A) || (unit.source.text[e] >= 0x30 && unit.source.text[e] <= 0x39) { e += 1 }
            guard e > k + 1, words.contains(hashName(unit.source.text + k + 1, e - k - 1)), let word = interpolatedName(unit, token: index, offset: k + 1) else { continue }
            let found = summarize(preferByPosition(unitIndex, index, resolveName(unitIndex, index, word, want: .term), forceTerm: true))
            take(found, unit, line: unit.source.lines.line(of: k) + 1)
          }
        default:
          continue
        }
      }
    }
    return result
  }

  public func place(of site: Site) -> (path: String, line: Int)? {
    if case .module(let package) = site { return ("package:" + (packageNames[package] ?? "?"), 1) }
    return project.place(of: site)
  }
}
