import CodeModel
import CodeScan
import Foundation

/// Java's reading of a file into the core's tables:
///
/// - `class` is a `classType`, `interface` and `@interface` a `protocolType`, `enum` an `enumeration` (its constants
///   `enumCase`s, a constant's class body their children), `record` a `structure` whose components are its fields
///   (`variable`s). `extends`, `implements` and an anonymous class's type are inherited ranges.
/// - Methods are `function`s (their return type the `type…` range), constructors and a record's compact constructor
///   `initializer`s, `{ }` and `static { }` blocks nameless `function`s, fields `variable`s (`isStatic` when static),
///   each of `int a, b[] = …` its own with the initializer as `init…`.
/// - Local and anonymous classes come after every other declaration, `isLocal`, so that an edit to a body moves none of
///   the others: an anonymous class is a nameless `classType` at its `new`, inheriting the type written after it.
/// - `import a.b.C`, `import a.b.*` and their `static` forms are `Import`s whose module is the package as written (the
///   words up to the first capitalized one) and whose member is the first type's name; the model reads the rest from
///   the tokens at `Import.token`.
package final class JavaSyntax: LanguageSyntax {
  package static let shared = JavaSyntax()
  package let profile = LexProfile.profile(forLanguage: "java")!
  package let parametersHaveLabels = false

  package func parse(_ unit: CodeModel.Unit) -> UInt64 {
    var parser = JavaParser(unit: unit)
    parser.parseFile()
    return parser.shape
  }

  package func evaluateCondition(_ unit: CodeModel.Unit, _ i: inout Int) -> Bool {
    i += 1
    return true
  }
}

enum JavaWord {
  static let object = name("Object"), string = name("String"), enumWord = name("Enum"), record = name("Record"), javaLang = name("java.lang")
  static let classWord = name("class"), this = name("this"), superWord = name("super"), length = name("length"), clone = name("clone")
  static let thisToken = "this", varWord = name("var"), valueWord = name("value"), getClass = name("getClass")
  static let primitives: Set<Name> = Set(["int", "long", "short", "byte", "char", "boolean", "float", "double", "void"].map { name($0) })
  static let boxes: [Name: String] = [
    name("int"): "Integer", name("long"): "Long", name("short"): "Short", name("byte"): "Byte", name("char"): "Character",
    name("boolean"): "Boolean", name("float"): "Float", name("double"): "Double", name("void"): "Void",
  ]
  static let int = name("int"), long = name("long"), double = name("double"), float = name("float"), boolean = name("boolean")
  static let char = name("char"), void = name("void"), short = name("short"), byte = name("byte")
  static let primitiveNames: [Name: String] = Dictionary(
    uniqueKeysWithValues: ["int", "long", "short", "byte", "char", "boolean", "float", "double", "void"].map { (name($0), $0) })
  /// Words the lexer calls keywords that Java lets a program use as names.
  static let contextual: Set<Name> = Set(["record", "var", "yield", "sealed", "permits", "when", "module", "open", "to", "with", "exports", "requires"].map { name($0) })
}

extension Unit {
  /// A name: an identifier, or a word that's a keyword only in some places (`record`, `var`, `yield`).
  func javaIsName(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    if tokens[i].kind == .identifier { return true }
    return tokens[i].kind == .keyword && JavaWord.contextual.contains(hash(i))
  }

  /// Whether a punctuation token is made only of these bytes (`>>`, `<?`, `?>`).
  func javaOnly(_ i: Int, _ allowed: StaticString) -> Bool {
    guard i >= 0, i < tokens.count, tokens[i].kind == .punctuation else { return false }
    let token = tokens[i]
    for k in 0..<token.length {
      let byte = source.text[token.start + k]
      var found = false
      for b in 0..<allowed.utf8CodeUnitCount where allowed.utf8Start[b] == byte { found = true }
      if !found { return false }
    }
    return true
  }

  func javaStartsWith(_ i: Int, _ byte: UInt8) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    return source.text[tokens[i].start] == byte
  }

  /// The end of type arguments `<…>` starting at token `i` (the token after the closing `>`), when what's inside reads
  /// as types; nil otherwise (`a < b`).
  func javaTypeArgumentsEnd(_ i: Int, limit: Int? = nil) -> Int? {
    guard i < tokens.count, tokens[i].kind == .punctuation, javaStartsWith(i, 0x3C) else { return nil }
    let end = limit ?? tokens.count
    var depth = 0
    var k = i
    var budget = 400
    while k < end, budget > 0 {
      budget -= 1
      let token = tokens[k]
      switch token.kind {
      case .punctuation:
        guard javaOnly(k, "<>?&,.") || isToken(k, "...") else { return nil }
        if isToken(k, "...") { break }
        for b in 0..<token.length {
          let byte = source.text[token.start + b]
          if byte == 0x3C { depth += 1 } else if byte == 0x3E {
            depth -= 1
            if depth == 0 { return b == token.length - 1 ? k + 1 : nil }
          }
        }
      case .identifier, .attribute: break
      case .keyword:
        let word = hash(k)
        guard JavaWord.primitives.contains(word) || isToken(k, "extends") || isToken(k, "super") || JavaWord.contextual.contains(word) else { return nil }
      case .open:
        guard isByte(k, 0x5B), isByte(k + 1, 0x5D) else {
          // An annotation's arguments: `List<@Size(max = 3) String>`.
          if k > 0, tokens[k - 1].kind == .attribute, isByte(k, 0x28) {
            k = skipBalanced(k)
            continue
          }
          return nil
        }
      case .close:
        guard isByte(k, 0x5D) else { return nil }
      default:
        return nil
      }
      k += 1
    }
    return nil
  }

  /// The end of a type written from `i` (annotations, a primitive or a qualified name with type arguments, array
  /// dimensions, `...`), or nil when no type starts there.
  func javaTypeEnd(_ from: Int, limit: Int? = nil) -> Int? {
    let end = limit ?? tokens.count
    var i = javaSkipAnnotations(from, limit: end)
    guard i < end else { return nil }
    if tokens[i].kind == .keyword, JavaWord.primitives.contains(hash(i)) {
      i += 1
    } else if javaIsName(i) {
      i += 1
      while i < end {
        if tokens[i].kind == .punctuation, javaStartsWith(i, 0x3C), let after = javaTypeArgumentsEnd(i, limit: end) {
          i = after
          continue
        }
        if isByte(i, 0x2E), i + 1 < end {
          let next = javaSkipAnnotations(i + 1, limit: end)
          if javaIsName(next) {
            i = next + 1
            continue
          }
        }
        break
      }
    } else {
      return nil
    }
    while i + 1 < end {
      let at = javaSkipAnnotations(i, limit: end)
      if isByte(at, 0x5B), isByte(at + 1, 0x5D) {
        i = at + 2
      } else {
        break
      }
    }
    if i < end, isToken(i, "...") { i += 1 }
    return i
  }

  /// Past annotations: `@Name`, `@a.b.Name`, each with its arguments.
  func javaSkipAnnotations(_ from: Int, limit: Int? = nil) -> Int {
    let end = limit ?? tokens.count
    var i = from
    while i < end, tokens[i].kind == .attribute, !isToken(i, "@interface") {
      i += 1
      while isByte(i, 0x2E), javaIsName(i + 1) { i += 2 }
      if i < end, isByte(i, 0x28) { i = skipBalanced(i) }
    }
    return i
  }
}

private let modifierWords: Set<Name> = Set(
  ["public", "protected", "private", "static", "final", "abstract", "native", "synchronized", "transient", "volatile", "strictfp", "default", "sealed"]
    .map { name($0) })

struct JavaParser {
  let unit: Unit
  var shape: UInt64 = 14_695_981_039_346_656_037
  /// Token ranges whose text doesn't change what other files see: bodies and initializers.
  private var bodies: [(Int, Int)] = []
  private var count: Int { unit.tokens.count }

  init(unit: Unit) { self.unit = unit }

  mutating func parseFile() {
    var i = 0
    while i < count {
      let start = i
      if unit.isToken(i, "package") {
        i += 1
        while i < count, !unit.isByte(i, 0x3B) { i += 1 }
        i += 1
        continue
      }
      if unit.isToken(i, "import") {
        i = importDecl(i)
        continue
      }
      if unit.isByte(i, 0x3B) {
        i += 1
        continue
      }
      // A module-info.java: nothing to read.
      if unit.isToken(i, "module") || unit.isToken(i, "open") && unit.isToken(i + 1, "module") { break }
      let next = typeDeclaration(i, parent: -1, isLocal: false, limit: count)
      i = next > start ? next : start + 1
    }
    let nonLocal = unit.decls.count
    for index in 0..<nonLocal {
      let decl = unit.decls[index]
      if decl.bodyOpen >= 0, decl.kind == .function || decl.kind == .initializer {
        locals(from: Int(decl.bodyOpen) + 1, to: Int(decl.bodyClose), parent: Int32(index))
      }
      if decl.initStart >= 0 { locals(from: Int(decl.initStart), to: Int(decl.initEnd), parent: Int32(index)) }
    }
    mixShape()
  }

  private mutating func mixShape() {
    bodies.sort { $0.0 < $1.0 }
    var b = 0
    var i = 0
    while i < count {
      while b < bodies.count, bodies[b].1 <= i { b += 1 }
      if b < bodies.count, bodies[b].0 <= i {
        i = bodies[b].1
        continue
      }
      shape = (shape ^ unit.hash(i)) &* 1_099_511_628_211
      i += 1
    }
  }

  // MARK: Imports

  private mutating func importDecl(_ at: Int) -> Int {
    var i = at + 1
    if unit.isToken(i, "static") { i += 1 }
    let first = i
    var package: [String] = []
    var member: Name = 0
    var memberToken: Int32 = -1
    while i < count, !unit.isByte(i, 0x3B) {
      if unit.javaIsName(i) || unit.tokens[i].kind == .keyword {
        let text = unit.string(i)
        if member == 0, let c = text.first, c.isUppercase {
          member = unit.hash(i)
          memberToken = Int32(i)
        } else if member == 0 {
          package.append(text)
        }
      }
      if unit.startsLine(i), i > first, !unit.isByte(i - 1, 0x2E), !unit.isByte(i, 0x2E) { break }
      i += 1
    }
    let packageName = package.joined(separator: ".")
    var item = Import(module: name(packageName), moduleName: packageName, isExported: false, isTestable: false)
    item.token = Int32(first)
    item.member = member
    item.memberToken = memberToken
    unit.imports.append(item)
    return unit.isByte(i, 0x3B) ? i + 1 : i
  }

  // MARK: Types

  /// Modifiers and annotations from `i`: where they end, and what they say.
  private func modifiers(_ from: Int, limit: Int) -> (end: Int, isStatic: Bool, access: Access, isDefault: Bool) {
    var i = from
    var isStatic = false
    var access = Access.package
    var isDefault = false
    while i < limit {
      if unit.tokens[i].kind == .attribute, !unit.isToken(i, "@interface") {
        i = unit.javaSkipAnnotations(i, limit: limit)
        continue
      }
      // `non-sealed`.
      if unit.isToken(i, "non"), unit.isToken(i + 1, "-"), unit.isToken(i + 2, "sealed") {
        i += 3
        continue
      }
      guard unit.tokens[i].kind == .keyword, modifierWords.contains(unit.hash(i)) else { break }
      // `default:` in a switch is no modifier, nor `sealed` used as a name.
      if unit.isToken(i, "default"), unit.isByte(i + 1, 0x3A) || unit.isToken(i + 1, "->") { break }
      if unit.isToken(i, "static") { isStatic = true }
      if unit.isToken(i, "public") { access = .isPublic }
      if unit.isToken(i, "private") { access = .isPrivate }
      if unit.isToken(i, "protected") { access = .inherited }
      if unit.isToken(i, "default") { isDefault = true }
      i += 1
    }
    return (i, isStatic, access, isDefault)
  }

  /// The keyword at `i` that starts a type declaration, if one does.
  private func typeKeyword(_ i: Int) -> DeclKind? {
    if unit.isToken(i, "class") { return unit.javaIsName(i + 1) ? .classType : nil }
    if unit.isToken(i, "interface") || unit.isToken(i, "@interface") { return unit.javaIsName(i + 1) ? .protocolType : nil }
    if unit.isToken(i, "enum") { return unit.javaIsName(i + 1) ? .enumeration : nil }
    if unit.isToken(i, "record"), unit.javaIsName(i + 1), unit.isByte(i + 2, 0x28) || unit.javaStartsWith(i + 2, 0x3C) { return .structure }
    return nil
  }

  /// A type declaration at `i` (modifiers first); returns the token after it, or `i` when there's none.
  @discardableResult
  mutating func typeDeclaration(_ at: Int, parent: Int32, isLocal: Bool, limit: Int) -> Int {
    let mods = modifiers(at, limit: limit)
    var i = mods.end
    guard let kind = typeKeyword(i) else { return at }
    let isInterface = kind == .protocolType
    let nameToken = i + 1
    var decl = Decl(kind: kind, name: unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(at), parent: parent)
    decl.isLocal = isLocal
    decl.isStatic = mods.isStatic || kind != .classType || (parent >= 0 && unit.decls[Int(parent)].kind == .protocolType)
    decl.access = mods.access
    if parent >= 0, unit.decls[Int(parent)].kind == .protocolType, mods.access == .package { decl.access = .isPublic }
    i = nameToken + 1
    if unit.javaStartsWith(i, 0x3C), unit.tokens[i].kind == .punctuation {
      i = typeParameters(i, into: &decl)
    }
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    // A record's components: its fields.
    var components: (Int, Int)?
    if kind == .structure, unit.isByte(i, 0x28) {
      let close = unit.skipBalanced(i)
      components = (i, close - 1)
      i = close
    }
    // extends, implements, permits.
    unit.decls[Int(index)].inheritStart = Int32(unit.ranges.count)
    while i < limit, !unit.isByte(i, 0x7B) {
      if unit.isToken(i, "extends") || unit.isToken(i, "implements") {
        i += 1
        while i < limit {
          guard let end = unit.javaTypeEnd(i, limit: limit) else { break }
          unit.ranges.append((Int32(i), Int32(end)))
          unit.decls[Int(index)].inheritCount += 1
          i = end
          if unit.isByte(i, 0x2C) { i += 1 } else { break }
        }
      } else if unit.isByte(i, 0x3B) || unit.tokens[i].kind == .close {
        break
      } else {
        // `permits A, B` and anything not understood.
        i += 1
      }
    }
    if let components {
      parameters(open: components.0, close: components.1, into: &unit.decls[Int(index)])
      let decl = unit.decls[Int(index)]
      for p in 0..<Int(decl.paramCount) {
        let param = unit.params[Int(decl.paramStart) + p]
        var field = Decl(kind: .variable, name: param.local, nameToken: param.nameToken, first: param.typeStart, parent: index)
        field.typeStart = param.typeStart
        field.typeEnd = param.typeEnd
        field.end = param.nameToken + 1
        field.isLocal = isLocal
        field.access = .isPublic
        unit.decls.append(field)
      }
    }
    guard unit.isByte(i, 0x7B) else {
      unit.decls[Int(index)].end = Int32(i)
      return i
    }
    let close = unit.skipBalanced(i)
    unit.decls[Int(index)].bodyOpen = Int32(i)
    unit.decls[Int(index)].bodyClose = Int32(close - 1)
    unit.decls[Int(index)].end = Int32(close)
    classBody(open: i, close: close - 1, owner: index, kind: kind, isInterface: isInterface, isLocal: isLocal)
    return close
  }

  /// `<T extends A & B, U>`: the names, as the decl's generics (bounds are read again when asked).
  private mutating func typeParameters(_ open: Int, into decl: inout Decl) -> Int {
    guard let end = unit.javaTypeArgumentsEnd(open) else { return open + 1 }
    decl.genericStart = Int32(unit.generics.count)
    var i = open
    var depth = 0
    while i < end {
      if unit.tokens[i].kind == .punctuation {
        for k in 0..<unit.tokens[i].length {
          let byte = unit.source.text[unit.tokens[i].start + k]
          if byte == 0x3C { depth += 1 } else if byte == 0x3E { depth -= 1 }
        }
      } else if depth == 1, unit.javaIsName(i), unit.javaStartsWith(i - 1, 0x3C) || unit.isByte(i - 1, 0x2C) || unit.tokens[i - 1].kind == .attribute {
        unit.generics.append(Generic(name: unit.hash(i), token: Int32(i)))
        decl.genericCount += 1
      }
      i += 1
    }
    return end
  }

  /// A class body's members as children of `owner`.
  private mutating func classBody(open: Int, close: Int, owner: Int32, kind: DeclKind, isInterface: Bool, isLocal: Bool) {
    var i = open + 1
    if kind == .enumeration { i = enumConstants(i, close: close, owner: owner, isLocal: isLocal) }
    while i < close {
      let next = member(i, close: close, owner: owner, isInterface: isInterface, isLocal: isLocal)
      i = next > i ? next : i + 1
    }
  }

  /// `A, B(1), C { … };` at an enum body's start.
  private mutating func enumConstants(_ from: Int, close: Int, owner: Int32, isLocal: Bool) -> Int {
    var i = from
    while i < close {
      let at = i
      i = unit.javaSkipAnnotations(i, limit: close)
      guard unit.javaIsName(i), unit.isByte(i + 1, 0x2C) || unit.isByte(i + 1, 0x28) || unit.isByte(i + 1, 0x7B) || unit.isByte(i + 1, 0x3B) || i + 1 == close else {
        return unit.isByte(i, 0x3B) ? i + 1 : at
      }
      var constant = Decl(kind: .enumCase, name: unit.hash(i), nameToken: Int32(i), first: Int32(at), parent: owner)
      constant.isStatic = true
      constant.isLocal = isLocal
      constant.access = .isPublic
      i += 1
      if unit.isByte(i, 0x28) {
        let end = unit.skipBalanced(i)
        constant.initStart = Int32(i + 1)
        constant.initEnd = Int32(end - 1)
        bodies.append((i + 1, end - 1))
        i = end
      }
      let index = Int32(unit.decls.count)
      unit.decls.append(constant)
      if unit.isByte(i, 0x7B) {
        let end = unit.skipBalanced(i)
        unit.decls[Int(index)].bodyOpen = Int32(i)
        unit.decls[Int(index)].bodyClose = Int32(end - 1)
        classBody(open: i, close: end - 1, owner: index, kind: .classType, isInterface: false, isLocal: isLocal)
        i = end
      }
      unit.decls[Int(index)].end = Int32(i)
      if unit.isByte(i, 0x2C) {
        i += 1
        continue
      }
      if unit.isByte(i, 0x3B) { return i + 1 }
      return i
    }
    return i
  }

  /// One member of a class body; returns the token after it.
  private mutating func member(_ at: Int, close: Int, owner: Int32, isInterface: Bool, isLocal: Bool) -> Int {
    if unit.isByte(at, 0x3B) { return at + 1 }
    let mods = modifiers(at, limit: close)
    var i = mods.end
    guard i < close else { return close }
    let ownerDecl = unit.decls[Int(owner)]
    let access = isInterface && mods.access == .package ? Access.isPublic : mods.access
    // An initializer block.
    if unit.isByte(i, 0x7B) {
      let end = unit.skipBalanced(i)
      var block = Decl(kind: .function, name: 0, nameToken: Int32(i), first: Int32(at), parent: owner)
      block.isStatic = mods.isStatic
      block.isLocal = isLocal
      block.bodyOpen = Int32(i)
      block.bodyClose = Int32(end - 1)
      block.end = Int32(end)
      bodies.append((i + 1, end - 1))
      unit.decls.append(block)
      return end
    }
    if typeKeyword(i) != nil {
      return typeDeclaration(at, parent: owner, isLocal: isLocal, limit: close)
    }
    var generic = Decl(kind: .function, name: 0, nameToken: -1, first: Int32(at), parent: owner)
    if unit.tokens[i].kind == .punctuation, unit.javaStartsWith(i, 0x3C) {
      i = typeParameters(i, into: &generic)
    }
    i = unit.javaSkipAnnotations(i, limit: close)
    // A constructor (`Name(`), or a record's compact one (`Name {`).
    if unit.javaIsName(i), unit.hash(i) == ownerDecl.name, ownerDecl.name != 0, unit.isByte(i + 1, 0x28) || (ownerDecl.kind == .structure && unit.isByte(i + 1, 0x7B)) {
      var decl = Decl(kind: .initializer, name: unit.hash(i), nameToken: Int32(i), first: Int32(at), parent: owner)
      decl.genericStart = generic.genericStart
      decl.genericCount = generic.genericCount
      decl.access = access
      decl.isLocal = isLocal
      var k = i + 1
      if unit.isByte(k, 0x28) {
        let end = unit.skipBalanced(k)
        parameters(open: k, close: end - 1, into: &decl)
        k = end
      }
      return finishMethod(&decl, from: k, close: close)
    }
    guard let typeEnd = unit.javaTypeEnd(i, limit: close) else {
      // Not understood: past the next `;` or block.
      var k = i
      while k < close, !unit.isByte(k, 0x3B), !unit.isByte(k, 0x7B) { k += 1 }
      return unit.isByte(k, 0x7B) ? unit.skipBalanced(k) : k + 1
    }
    let typeStart = i
    i = typeEnd
    guard unit.javaIsName(i) else {
      var k = i
      while k < close, !unit.isByte(k, 0x3B), !unit.isByte(k, 0x7B) { k += 1 }
      return unit.isByte(k, 0x7B) ? unit.skipBalanced(k) : k + 1
    }
    if unit.isByte(i + 1, 0x28) {
      var decl = Decl(kind: .function, name: unit.hash(i), nameToken: Int32(i), first: Int32(at), parent: owner)
      decl.genericStart = generic.genericStart
      decl.genericCount = generic.genericCount
      decl.typeStart = Int32(typeStart)
      decl.typeEnd = Int32(typeEnd)
      decl.isStatic = mods.isStatic
      decl.access = access
      decl.isLocal = isLocal
      let end = unit.skipBalanced(i + 1)
      parameters(open: i + 1, close: end - 1, into: &decl)
      var k = end
      // `int f()[]`, the old way.
      while unit.isByte(k, 0x5B), unit.isByte(k + 1, 0x5D) { k += 2 }
      return finishMethod(&decl, from: k, close: close)
    }
    // Fields: `Type a [= x], b[] [= y];`
    var k = i
    while k < close, unit.javaIsName(k) {
      var field = Decl(kind: .variable, name: unit.hash(k), nameToken: Int32(k), first: Int32(k == i ? at : k), parent: owner)
      field.typeStart = Int32(typeStart)
      field.typeEnd = Int32(typeEnd)
      field.isStatic = mods.isStatic || isInterface
      field.access = access
      field.isLocal = isLocal
      var j = k + 1
      while unit.isByte(j, 0x5B), unit.isByte(j + 1, 0x5D) { j += 2 }
      if unit.isToken(j, "=") {
        let start = j + 1
        j = expressionEnd(start, limit: close)
        field.initStart = Int32(start)
        field.initEnd = Int32(j)
        bodies.append((start, j))
      }
      field.end = Int32(j)
      unit.decls.append(field)
      if unit.isByte(j, 0x2C) {
        k = j + 1
        continue
      }
      k = j
      break
    }
    return unit.isByte(k, 0x3B) ? k + 1 : max(k, i + 1)
  }

  /// After a method's parameters: `throws …`, `default …`, then its body or `;`.
  private mutating func finishMethod(_ decl: inout Decl, from: Int, close: Int) -> Int {
    var k = from
    while k < close, !unit.isByte(k, 0x7B), !unit.isByte(k, 0x3B) {
      if unit.tokens[k].kind == .open { k = unit.skipBalanced(k) } else { k += 1 }
      // A missing body (code being typed): the next member starts on its own line.
      if k < close, unit.startsLine(k), unit.tokens[k].kind == .keyword, modifierWords.contains(unit.hash(k)) { break }
    }
    if unit.isByte(k, 0x7B) {
      let end = unit.skipBalanced(k)
      decl.bodyOpen = Int32(k)
      decl.bodyClose = Int32(end - 1)
      bodies.append((k + 1, end - 1))
      k = end
    } else if unit.isByte(k, 0x3B) {
      k += 1
    }
    decl.end = Int32(k)
    unit.decls.append(decl)
    return k
  }

  /// The end of an expression from `i`: a `,` or `;` outside brackets (and outside type arguments), or `limit`.
  func expressionEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.tokens[i].kind == .close { return i }
      if unit.isByte(i, 0x2C) || unit.isByte(i, 0x3B) { return i }
      if unit.tokens[i].kind == .punctuation, unit.javaStartsWith(i, 0x3C), i > 0, unit.javaIsName(i - 1), let after = unit.javaTypeArgumentsEnd(i, limit: limit) {
        i = after
        continue
      }
      i += 1
    }
    return limit
  }

  /// Parameters `(final A a, B<C, D>... rest, int x[])` as `Param`s, typed by their tokens.
  mutating func parameters(open: Int, close: Int, into decl: inout Decl) {
    decl.paramStart = Int32(unit.params.count)
    decl.paramCount = 0
    var i = open + 1
    while i < close {
      while i < close, unit.isToken(i, "final") || unit.tokens[i].kind == .attribute {
        i = unit.tokens[i].kind == .attribute ? unit.javaSkipAnnotations(i, limit: close) : i + 1
      }
      guard let typeEnd = unit.javaTypeEnd(i, limit: close) else {
        while i < close, !unit.isByte(i, 0x2C) { i = unit.tokens[i].kind == .open ? unit.skipBalanced(i) : i + 1 }
        i += 1
        continue
      }
      let typeStart = i
      i = typeEnd
      // `Foo this`, a receiver parameter: no name to declare.
      if unit.isToken(i, "this") || (unit.isByte(i + 1, 0x2E) && unit.isToken(i + 2, "this")) {
        while i < close, !unit.isByte(i, 0x2C) { i += 1 }
        i += 1
        continue
      }
      if unit.javaIsName(i) {
        unit.params.append(
          Param(label: 0, local: unit.hash(i), nameToken: Int32(i), typeStart: Int32(typeStart), typeEnd: Int32(typeEnd), hasDefault: false, variadic: unit.isToken(typeEnd - 1, "...")))
        decl.paramCount += 1
        i += 1
      }
      while i < close, !unit.isByte(i, 0x2C) { i = unit.tokens[i].kind == .open ? unit.skipBalanced(i) : i + 1 }
      i += 1
    }
  }

  // MARK: Local and anonymous classes

  /// Classes declared in a body or an initializer: `new T(…) { … }` and `class X { … }` (with `interface`, `enum` and
  /// `record`), each with its members, then theirs.
  private mutating func locals(from: Int, to: Int, parent: Int32) {
    var i = from
    while i < to {
      if unit.isToken(i, "new"), let typeEnd = unit.javaTypeEnd(i + 1, limit: to), unit.isByte(typeEnd, 0x28) {
        let argsEnd = unit.skipBalanced(typeEnd)
        if unit.isByte(argsEnd, 0x7B), argsEnd < to {
          let bodyEnd = unit.skipBalanced(argsEnd)
          var decl = Decl(kind: .classType, name: 0, nameToken: Int32(i), first: Int32(i), parent: parent)
          decl.isLocal = true
          decl.bodyOpen = Int32(argsEnd)
          decl.bodyClose = Int32(bodyEnd - 1)
          decl.end = Int32(bodyEnd)
          decl.inheritStart = Int32(unit.ranges.count)
          decl.inheritCount = 1
          unit.ranges.append((Int32(i + 1), Int32(typeEnd)))
          let index = Int32(unit.decls.count)
          unit.decls.append(decl)
          // The arguments can hold classes of their own.
          locals(from: typeEnd + 1, to: argsEnd - 1, parent: parent)
          classBody(open: argsEnd, close: bodyEnd - 1, owner: index, kind: .classType, isInterface: false, isLocal: true)
          membersLocals(of: index)
          i = bodyEnd
          continue
        }
      }
      if (unit.isToken(i, "class") || unit.isToken(i, "interface") || unit.isToken(i, "enum") || unit.isToken(i, "record")), !unit.isByte(i - 1, 0x2E),
        typeKeyword(i) != nil
      {
        // Modifiers before it: `final class`, `abstract class`, `static record`.
        var start = i
        while start - 1 >= from, unit.tokens[start - 1].kind == .keyword, modifierWords.contains(unit.hash(start - 1)) { start -= 1 }
        let before = unit.decls.count
        let end = typeDeclaration(start, parent: parent, isLocal: true, limit: to)
        if end > start, unit.decls.count > before {
          for index in before..<unit.decls.count where unit.decls[index].parent == parent && unit.decls[index].kind.isNominal {
            membersLocals(of: Int32(index))
          }
          i = end
          continue
        }
      }
      i += 1
    }
  }

  /// The local classes in the bodies of a local class's members.
  private mutating func membersLocals(of owner: Int32) {
    let snapshot = unit.decls.count
    for index in Int(owner + 1)..<snapshot where unit.decls[index].parent == owner {
      let decl = unit.decls[index]
      if decl.bodyOpen >= 0, decl.kind == .function || decl.kind == .initializer {
        locals(from: Int(decl.bodyOpen) + 1, to: Int(decl.bodyClose), parent: Int32(index))
      }
      if decl.initStart >= 0 { locals(from: Int(decl.initStart), to: Int(decl.initEnd), parent: Int32(index)) }
      if decl.kind.isNominal || decl.kind == .enumCase, decl.bodyOpen >= 0 { membersLocals(of: Int32(index)) }
    }
  }
}
