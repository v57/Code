import CodeJavaModel
import CodeModel
import CodeScan
import Foundation

/// Kotlin's reading of a file into the core's tables, and Java's for a mixed project's `.java` files
/// (`syntax(forPath:)`):
///
/// - `class` is a `classType` (an `object`, a `companion object` and an anonymous `object :` too, told apart by their
///   keyword token), `interface` a `protocolType`, `enum class` an `enumeration` (its entries `enumCase`s). A class's
///   primary constructor's parameters are the class's own `params`; a `val`/`var` parameter is also a `variable`
///   child. A supertype list's types (without their constructor arguments or `by`) are inherited ranges.
/// - `fun` is a `function` (its return type the `type…` range, an expression body the `init…` range), `constructor` an
///   `initializer` named as its class, `init { }` and a property's `get`/`set` nameless `function`s (an accessor's
///   parent is its property), `val`/`var` a `variable` (`by` puts the delegate in `init…`), `typealias` a `typeAlias`.
/// - An extension `fun A.f()` or `val A.p` is an `extensionDecl` named as the receiver's last name (its type the
///   `type…` range), holding the function or property: the core's index of extensions by name is Kotlin's too.
/// - Local functions and classes and anonymous objects come after every other declaration, `isLocal`.
/// - `import a.b.C`, `import a.b.*` and `import a.b.c as d` are `Import`s whose module is the whole path as written
///   (`moduleName`), with `alias`; the model reads the words again from `Import.token`.
final class KotlinSyntax: LanguageSyntax {
  static let shared = KotlinSyntax()
  let profile = LexProfile.profile(forLanguage: "kotlin")!
  let parametersHaveLabels = false
  let java: any LanguageSyntax = JavaSyntax.shared

  func parse(_ unit: Unit) -> UInt64 {
    var parser = KotlinParser(unit: unit)
    parser.parseFile()
    return parser.shape
  }

  func evaluateCondition(_ unit: Unit, _ i: inout Int) -> Bool {
    i += 1
    return true
  }

  func syntax(forPath path: String) -> any LanguageSyntax { path.hasSuffix(".java") ? java : self }
}

enum KotlinWord {
  /// Words that are always keywords: never a name.
  static let hard: Set<Name> = Set(
    ["as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in", "interface", "is", "null", "object", "package", "return",
     "super", "this", "throw", "true", "try", "typealias", "typeof", "val", "var", "when", "while"].map { name($0) })
  static let modifiers: Set<Name> = Set(
    ["public", "private", "protected", "internal", "abstract", "final", "open", "sealed", "data", "enum", "annotation", "inner", "companion",
     "inline", "noinline", "crossinline", "value", "override", "lateinit", "const", "operator", "infix", "suspend", "tailrec", "external",
     "expect", "actual", "vararg", "reified", "fun", "out", "in"].map { name($0) })
  static let declarationStarts: Set<Name> = Set(
    ["fun", "val", "var", "class", "interface", "object", "typealias", "constructor", "init", "public", "private", "protected", "internal",
     "abstract", "final", "open", "sealed", "data", "enum", "annotation", "inner", "companion", "inline", "override", "lateinit", "const",
     "operator", "infix", "suspend", "tailrec", "external", "expect", "actual"].map { name($0) })
  static let companion = name("Companion"), it = name("it"), this = name("this"), constructorWord = name("constructor")
  static let function = name("Function"), getWord = name("get"), setWord = name("set"), value = name("value"), field = name("field")
  /// The holder of an extension on a type parameter (`fun <T> T.let`): it extends anything.
  static let anyReceiver = name("<T>")
  static let rangeTo = name("rangeTo"), rangeUntil = name("rangeUntil"), plus = name("plus"), minus = name("minus"), times = name("times")
  static let div = name("div"), rem = name("rem"), get = name("get"), copy = name("copy")
  static let getValue = name("getValue"), iterator = name("iterator"), next = name("next"), invoke = name("invoke")
  static let numbers: Set<Name> = Set(["Int", "Long", "Short", "Byte", "Double", "Float"].map { name($0) })
}

extension Unit {
  /// A name: an identifier, or a soft keyword (`value`, `data`, `get`, `out`) used as one.
  func ktIsName(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    if tokens[i].kind == .identifier { return true }
    return (tokens[i].kind == .keyword || tokens[i].kind == .declarationKeyword) && !KotlinWord.hard.contains(hash(i))
  }

  /// `.`, `?.` or `!!.`: a member access.
  func ktIsDot(_ i: Int) -> Bool { isByte(i, 0x2E) || isToken(i, "?.") || isToken(i, "!!.") }

  /// Whether `?` at `i` starts the elvis operator `?:` (the lexer gives `?` and `:` as two tokens).
  func ktIsElvis(_ i: Int) -> Bool { isToken(i, "?") && isToken(i + 1, ":") && touchesPrevious(i + 1) }

  /// Whether a punctuation token longer than one byte ends in `.`: `>.`, `>?.`.
  func ktEndsWithDot(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count, tokens[i].kind == .punctuation, tokens[i].length > 1 else { return false }
    return source.text[tokens[i].start + tokens[i].length - 1] == 0x2E
  }

  /// Past annotations: `@Name`, `@a.b.Name`, `@file:Name`, `@field:Json("x")`, `@[A B]`, each with its arguments.
  func ktSkipAnnotations(_ from: Int, limit: Int? = nil) -> Int {
    let end = limit ?? tokens.count
    var i = from
    while i < end {
      if tokens[i].kind == .attribute {
        i += 1
        if isToken(i, ":"), ktIsName(i + 1) { i += 2 }
        while ktIsDot(i), ktIsName(i + 1) { i += 2 }
        if i < end, isByte(i, 0x3C), let after = ktTypeArgumentsEnd(i, limit: end) { i = after }
        if i < end, isByte(i, 0x28), !startsLine(i) { i = skipBalanced(i) }
        continue
      }
      // `@[A B]`.
      if isByte(i, 0x40), isByte(i + 1, 0x5B) {
        i = skipBalanced(i + 1)
        continue
      }
      break
    }
    return i
  }

  /// The end of type arguments `<…>` starting at token `i` (the token after the closing `>`, which may hold a `?`), when
  /// what's inside reads as types; nil otherwise (`a < b`).
  /// A declaration's type parameters (`declaration`) may also have bounds: `<T : Any, reified R>`.
  func ktTypeArgumentsEnd(_ i: Int, limit: Int? = nil, declaration: Bool = false) -> Int? {
    guard i < tokens.count, tokens[i].kind == .punctuation, startsWith(i, 0x3C) else { return nil }
    let end = limit ?? tokens.count
    var depth = 0
    var k = i
    var budget = 400
    while k < end, budget > 0 {
      budget -= 1
      let token = tokens[k]
      switch token.kind {
      case .punctuation:
        if isToken(k, "->") { break }
        if declaration, isToken(k, ":") { break }
        guard punctuation(k, madeOf: "<>?*,.") else { return nil }
        for b in 0..<token.length {
          let byte = source.text[token.start + b]
          if byte == 0x3C { depth += 1 } else if byte == 0x3E {
            depth -= 1
            if depth == 0 {
              // Only `?` and outer arguments' `>` may follow the closing `>` in the same token (`Map<K, List<V>>`), and
              // a last `.`: the lexer keeps `>.` and `>?.` (`List<T>.second`) as one token.
              for rest in (b + 1)..<max(b + 1, token.length) where source.text[token.start + rest] != 0x3F && source.text[token.start + rest] != 0x3E {
                if rest == token.length - 1, source.text[token.start + rest] == 0x2E { break }
                return nil
              }
              return k + 1
            }
          }
        }
      case .identifier, .attribute: break
      case .keyword, .declarationKeyword:
        guard ktIsName(k) || isToken(k, "in") || isToken(k, "out") || isToken(k, "suspend") || declaration && isToken(k, "reified") else { return nil }
      case .open:
        guard isByte(k, 0x28) else { return nil }
        k = skipBalanced(k)
        continue
      default:
        return nil
      }
      k += 1
    }
    return nil
  }

  /// The end of a type written from `i`: annotations, `suspend`, a qualified name with type arguments, a function type
  /// `(A) -> B` or `R.(A) -> B`, a parenthesized type, each with `?`s; nil when no type starts there.
  func ktTypeEnd(_ from: Int, limit: Int? = nil) -> Int? {
    let end = limit ?? tokens.count
    var i = ktSkipAnnotations(from, limit: end)
    if isToken(i, "suspend") { i += 1 }
    guard i < end else { return nil }
    if isByte(i, 0x28) {
      let close = skipBalanced(i)
      if close <= end, isToken(close, "->") { return ktTypeEnd(close + 1, limit: end) }
      i = close
    } else if ktIsName(i) || isToken(i, "dynamic") {
      i += 1
      while i < end {
        if tokens[i].kind == .punctuation, startsWith(i, 0x3C), let after = ktTypeArgumentsEnd(i, limit: end) {
          i = after
          continue
        }
        if isByte(i, 0x2E), ktIsName(i + 1), i + 1 < end {
          i += 2
          continue
        }
        break
      }
    } else if isByte(i, 0x2A) {
      return i + 1
    } else {
      return nil
    }
    while i < end, punctuation(i, madeOf: "?") { i += 1 }
    // `R.(A) -> B`: a receiver.
    if i + 1 < end, isByte(i, 0x2E), isByte(i + 1, 0x28) {
      let close = skipBalanced(i + 1)
      if close < end, isToken(close, "->") { return ktTypeEnd(close + 1, limit: end) }
    }
    return i
  }

  /// Whether a token begins a declaration at the start of its line: a modifier, `fun`, `val`, an annotation.
  func ktStartsDeclaration(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    if tokens[i].kind == .attribute { return true }
    guard tokens[i].kind == .keyword || tokens[i].kind == .declarationKeyword else { return false }
    let word = hash(i)
    guard KotlinWord.declarationStarts.contains(word) else { return false }
    // A soft keyword used as a name: `value = 3`, `data.size`.
    if !KotlinWord.hard.contains(word) {
      if isToken(i + 1, "=") || ktIsDot(i + 1) || isByte(i + 1, 0x28) && !isToken(i, "constructor") && !isToken(i, "init") || isByte(i + 1, 0x5B) { return false }
      if tokens.indices.contains(i + 1), tokens[i + 1].kind == .punctuation, !isByte(i + 1, 0x40) { return false }
    }
    return true
  }

  /// The end of an expression from `i` in a declaration: a `;`, a close bracket of the enclosing scope, `limit`, or a
  /// line that starts another declaration (or a property's accessor).
  func ktExpressionEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      if tokens[i].kind == .open {
        i = skipBalanced(i)
        continue
      }
      if tokens[i].kind == .close || isByte(i, 0x3B) { return i }
      if i > from, startsLine(i) {
        if ktStartsDeclaration(i) { return i }
        if (isToken(i, "get") || isToken(i, "set")) && (isByte(i + 1, 0x28) || isToken(i + 1, "=")) { return i }
        if isToken(i, "private"), isToken(i + 1, "set") { return i }
        if !ktContinuesLine(i) { return i }
      }
      i += 1
    }
    return limit
  }

  /// Whether a line starting at `i` goes on with the expression the line before it left: that line ended in an operator
  /// or a comma or `if (…)`, or this one starts with `.`, `?.`, `?:`, `&&`, `||`, `as`, `else`, `catch` or `finally`.
  func ktContinuesLine(_ i: Int) -> Bool {
    if ktIsDot(i) || ktIsElvis(i) || isToken(i, "&&") || isToken(i, "||") || isToken(i, "as") || isToken(i, "else")
      || isToken(i, "catch") || isToken(i, "finally") || isToken(i, ":") {
      return true
    }
    guard i > 0 else { return false }
    let before = tokens[i - 1]
    switch before.kind {
    case .punctuation:
      return !(isToken(i - 1, "!!") || isToken(i - 1, "++") || isToken(i - 1, "--") || isByte(i - 1, 0x3B))
    case .interpolationOpen, .open: return true
    case .close:
      // `if (c)` with its branch on the next line.
      guard isByte(i - 1, 0x29), let open = matchingOpen(i - 1) else { return false }
      return isToken(open - 1, "if")
    case .keyword, .declarationKeyword:
      return isToken(i - 1, "in") || isToken(i - 1, "is") || isToken(i - 1, "as") || isToken(i - 1, "else") || isToken(i - 1, "throw")
    default:
      return false
    }
  }

  /// The last name of a type written from `start` to `end`, skipping its arguments and `?`: `List<T>?` is `List`.
  func ktTypeLastName(_ start: Int, _ end: Int) -> Int? {
    var i = ktSkipAnnotations(start, limit: end)
    if isToken(i, "suspend") { i += 1 }
    if isByte(i, 0x28) { return nil }
    var last: Int?
    while i < end {
      guard ktIsName(i) else { break }
      last = i
      i += 1
      if i < end, tokens[i].kind == .punctuation, startsWith(i, 0x3C), let after = ktTypeArgumentsEnd(i, limit: end) { i = after }
      if i < end, isByte(i, 0x2E) { i += 1 } else { break }
    }
    return last
  }
}

struct KotlinParser {
  let unit: Unit
  var shape: UInt64 = 14_695_981_039_346_656_037
  /// Token ranges whose text doesn't change what other files see: bodies, and initializers under a declared type.
  private var bodies: [(Int, Int)] = []
  private var count: Int { unit.tokens.count }

  init(unit: Unit) { self.unit = unit }

  mutating func parseFile() {
    var i = unit.ktSkipAnnotations(0)
    if unit.isToken(i, "package") {
      i += 1
      // `package a.b`: names joined by dots (`import` on the next line is a name too).
      while i < count, unit.ktIsName(i) {
        i += 1
        guard unit.isByte(i, 0x2E) else { break }
        i += 1
      }
      if unit.isByte(i, 0x3B) { i += 1 }
    }
    while i < count {
      let start = i
      if unit.isToken(i, "import") {
        i = importDecl(i)
        continue
      }
      if unit.isByte(i, 0x3B) {
        i += 1
        continue
      }
      let next = declaration(i, parent: -1, isLocal: false, limit: count, inClass: false)
      if next > start {
        i = next
        continue
      }
      // A script's statement, or what isn't understood: past its brackets.
      i = unit.tokens[i].kind == .open ? unit.skipBalanced(i) : i + 1
    }
    let nonLocal = unit.decls.count
    for index in 0..<nonLocal { scanLocals(of: Int32(index)) }
    mixShape()
  }

  private mutating func mixShape() {
    bodies.sort { $0.0 < $1.0 }
    var b = 0
    var i = 0
    while i < count {
      while b < bodies.count, bodies[b].1 <= i { b += 1 }
      if b < bodies.count, bodies[b].0 <= i {
        i = max(i + 1, bodies[b].1)
        continue
      }
      shape = (shape ^ unit.hash(i)) &* 1_099_511_628_211
      i += 1
    }
  }

  // MARK: Imports

  private mutating func importDecl(_ at: Int) -> Int {
    var i = at + 1
    let first = i
    var words: [String] = []
    while i < count, unit.ktIsName(i) || unit.tokens[i].kind == .keyword {
      if i > first, unit.startsLine(i) { break }
      words.append(unit.string(i))
      i += 1
      if unit.isByte(i, 0x2E), unit.ktIsName(i + 1) || unit.tokens.indices.contains(i + 1) && unit.tokens[i + 1].kind == .keyword {
        i += 1
        continue
      }
      break
    }
    // `.*` lexes as one run.
    if unit.isToken(i, ".*") || unit.isByte(i, 0x2E) && unit.isByte(i + 1, 0x2A) { i += unit.isToken(i, ".*") ? 1 : 2 }
    let path = words.joined(separator: ".")
    var item = Import(module: name(path), moduleName: path, isExported: false, isTestable: false)
    item.token = Int32(first)
    if unit.isToken(i, "as"), unit.ktIsName(i + 1) {
      item.alias = unit.hash(i + 1)
      item.aliasToken = Int32(i + 1)
      i += 2
    }
    unit.imports.append(item)
    return unit.isByte(i, 0x3B) ? i + 1 : i
  }

  // MARK: Declarations

  struct Modifiers {
    var end: Int
    var access = Access.isPublic
    var isEnum = false
    var isCompanion = false
    var isFunInterface = false
    var isAnnotation = false
  }

  /// Modifiers and annotations from `i`.
  private func modifiers(_ from: Int, limit: Int) -> Modifiers {
    var result = Modifiers(end: from)
    var i = from
    while i < limit {
      if unit.tokens[i].kind == .attribute || unit.isByte(i, 0x40) {
        let next = unit.ktSkipAnnotations(i, limit: limit)
        if next == i { break }
        i = next
        continue
      }
      guard unit.tokens[i].kind == .keyword || unit.tokens[i].kind == .declarationKeyword, KotlinWord.modifiers.contains(unit.hash(i)) else { break }
      // `fun` is a modifier only before `interface`; the others only before another word.
      if unit.isToken(i, "fun") {
        guard unit.isToken(i + 1, "interface") else { break }
        result.isFunInterface = true
      }
      guard i + 1 < limit, unit.tokens[i + 1].kind == .keyword || unit.tokens[i + 1].kind == .declarationKeyword || unit.tokens[i + 1].kind == .attribute || unit.ktIsName(i + 1) else { break }
      if unit.ktIsName(i + 1), !unit.isToken(i, "fun"), unit.tokens[i + 1].kind == .identifier { break }
      if unit.isToken(i, "private") { result.access = .isPrivate }
      if unit.isToken(i, "protected") { result.access = .inherited }
      if unit.isToken(i, "internal") { result.access = .package }
      if unit.isToken(i, "enum") { result.isEnum = true }
      if unit.isToken(i, "companion") { result.isCompanion = true }
      if unit.isToken(i, "annotation") { result.isAnnotation = true }
      i += 1
    }
    result.end = i
    return result
  }

  /// A declaration at `at` (modifiers first); returns the token after it, or `at` when there's none.
  mutating func declaration(_ at: Int, parent: Int32, isLocal: Bool, limit: Int, inClass: Bool) -> Int {
    let mods = modifiers(at, limit: limit)
    let i = mods.end
    guard i < limit else { return at }
    if unit.isToken(i, "class") || unit.isToken(i, "interface") || unit.isToken(i, "object") {
      return classDeclaration(at, keyword: i, mods: mods, parent: parent, isLocal: isLocal, limit: limit)
    }
    if unit.isToken(i, "fun"), !unit.isByte(i + 1, 0x28) { return function(at, keyword: i, mods: mods, parent: parent, isLocal: isLocal, limit: limit) }
    if unit.isToken(i, "val") || unit.isToken(i, "var"), !unit.isByte(i + 1, 0x28) {
      return property(at, keyword: i, mods: mods, parent: parent, isLocal: isLocal, limit: limit)
    }
    if unit.isToken(i, "typealias"), unit.ktIsName(i + 1) {
      var decl = Decl(kind: .typeAlias, name: unit.hash(i + 1), nameToken: Int32(i + 1), first: Int32(at), parent: parent)
      decl.access = mods.access
      decl.isLocal = isLocal
      var k = i + 2
      if unit.startsWith(k, 0x3C), unit.tokens[k].kind == .punctuation { k = typeParameters(k, into: &decl) }
      if unit.isToken(k, "="), let end = unit.ktTypeEnd(k + 1, limit: limit) {
        decl.typeStart = Int32(k + 1)
        decl.typeEnd = Int32(end)
        k = end
      }
      decl.end = Int32(k)
      unit.decls.append(decl)
      return k
    }
    if inClass, unit.isToken(i, "constructor"), unit.isByte(i + 1, 0x28) {
      let owner = unit.decls[Int(parent)]
      var decl = Decl(kind: .initializer, name: owner.name, nameToken: Int32(i), first: Int32(at), parent: parent)
      decl.access = mods.access
      decl.isLocal = isLocal
      let close = unit.skipBalanced(i + 1)
      parameters(open: i + 1, close: close - 1, into: &decl, limit: limit)
      var k = close
      // `: this(…)`, `: super(…)`.
      if unit.isToken(k, ":"), unit.isToken(k + 1, "this") || unit.isToken(k + 1, "super"), unit.isByte(k + 2, 0x28) {
        decl.initStart = Int32(k + 1)
        k = unit.skipBalanced(k + 2)
        decl.initEnd = Int32(k)
        bodies.append((Int(decl.initStart), k))
      }
      if unit.isByte(k, 0x7B), !unit.startsLine(k) || true {
        if unit.isByte(k, 0x7B) {
          let end = unit.skipBalanced(k)
          decl.bodyOpen = Int32(k)
          decl.bodyClose = Int32(end - 1)
          bodies.append((k + 1, end - 1))
          k = end
        }
      }
      decl.end = Int32(k)
      unit.decls.append(decl)
      return k
    }
    if inClass, unit.isToken(i, "init"), unit.isByte(i + 1, 0x7B) {
      let end = unit.skipBalanced(i + 1)
      var block = Decl(kind: .function, name: 0, nameToken: Int32(i), first: Int32(at), parent: parent)
      block.isLocal = isLocal
      block.bodyOpen = Int32(i + 1)
      block.bodyClose = Int32(end - 1)
      block.end = Int32(end)
      bodies.append((i + 2, end - 1))
      unit.decls.append(block)
      return end
    }
    return at
  }

  /// `<T, out R : Bound, reified S>`: the names, as the decl's generics (bounds are read again when asked).
  private mutating func typeParameters(_ open: Int, into decl: inout Decl) -> Int {
    guard let end = unit.ktTypeArgumentsEnd(open, declaration: true) else { return open + 1 }
    decl.genericStart = Int32(unit.generics.count)
    var i = open
    var depth = 0
    var expectsName = false
    while i < end {
      if unit.tokens[i].kind == .punctuation {
        for k in 0..<unit.tokens[i].length {
          let byte = unit.source.text[unit.tokens[i].start + k]
          if byte == 0x3C {
            depth += 1
            if depth == 1 { expectsName = true }
          } else if byte == 0x3E {
            depth -= 1
          } else if byte == 0x2C, depth == 1 {
            expectsName = true
          }
        }
        if unit.isByte(i, 0x2C), depth == 1 { expectsName = true }
      } else if depth == 1, expectsName, unit.ktIsName(i), !unit.isToken(i, "in") && !unit.isToken(i, "out") && !unit.isToken(i, "reified") || unit.ktIsName(i) && (unit.isToken(i + 1, ":") || unit.isByte(i + 1, 0x2C) || unit.startsWith(i + 1, 0x3E)) {
        unit.generics.append(Generic(name: unit.hash(i), token: Int32(i)))
        decl.genericCount += 1
        expectsName = false
      } else if unit.isByte(i, 0x2C), depth == 1 {
        expectsName = true
      }
      i += 1
    }
    return end
  }

  /// `class`, `interface`, `object`, with what precedes them in `mods`.
  private mutating func classDeclaration(_ at: Int, keyword: Int, mods: Modifiers, parent: Int32, isLocal: Bool, limit: Int) -> Int {
    let isObject = unit.isToken(keyword, "object")
    var kind: DeclKind = unit.isToken(keyword, "interface") ? .protocolType : .classType
    if mods.isEnum { kind = .enumeration }
    var nameToken = keyword + 1
    var declName: Name
    var i: Int
    if unit.ktIsName(nameToken), !(isObject && unit.isToken(nameToken, ":")) {
      declName = unit.hash(nameToken)
      i = nameToken + 1
    } else if isObject, mods.isCompanion {
      nameToken = keyword
      declName = KotlinWord.companion
      i = keyword + 1
    } else if isObject {
      // `object : T { }` or `object { }` in an expression.
      nameToken = keyword
      declName = 0
      i = keyword + 1
    } else {
      return at
    }
    var decl = Decl(kind: kind, name: declName, nameToken: Int32(nameToken), first: Int32(at), parent: parent)
    decl.isLocal = isLocal
    decl.access = mods.access
    decl.isStatic = isObject
    if unit.startsWith(i, 0x3C), unit.tokens[i].kind == .punctuation { i = typeParameters(i, into: &decl) }
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    // The primary constructor: `(…)`, `private constructor(…)`, `@Inject constructor(…)`.
    var k = unit.ktSkipAnnotations(i, limit: limit)
    while k < limit, unit.tokens[k].kind == .keyword, unit.isToken(k, "private") || unit.isToken(k, "public") || unit.isToken(k, "internal") || unit.isToken(k, "protected") {
      k = unit.ktSkipAnnotations(k + 1, limit: limit)
    }
    if unit.isToken(k, "constructor") { k += 1 }
    var properties: [Int] = []
    if unit.isByte(k, 0x28), !isObject, k == i || unit.isToken(k - 1, "constructor") {
      let close = unit.skipBalanced(k)
      properties = parameters(open: k, close: close - 1, into: &unit.decls[Int(index)], limit: limit, properties: true)
      i = close
    }
    // Supertypes: `: A(x), B, C by d`.
    unit.decls[Int(index)].inheritStart = Int32(unit.ranges.count)
    if unit.isToken(i, ":") {
      i += 1
      while i < limit {
        guard let end = unit.ktTypeEnd(i, limit: limit) else { break }
        unit.ranges.append((Int32(i), Int32(end)))
        unit.decls[Int(index)].inheritCount += 1
        i = end
        if unit.isByte(i, 0x28) {
          let close = unit.skipBalanced(i)
          bodies.append((i + 1, close - 1))
          i = close
        }
        if unit.isToken(i, "by") {
          let start = i + 1
          i = delegateEnd(start, limit: limit)
          bodies.append((start, i))
        }
        if unit.isByte(i, 0x2C) { i += 1 } else { break }
      }
    }
    if unit.isToken(i, "where") {
      unit.decls[Int(index)].whereStart = Int32(i + 1)
      var k = i + 1
      while k < limit, !unit.isByte(k, 0x7B), !(k > i + 1 && unit.startsLine(k) && unit.ktStartsDeclaration(k)) { k += 1 }
      unit.decls[Int(index)].whereEnd = Int32(k)
      i = k
    }
    // `val`/`var` constructor parameters are properties.
    let owner = unit.decls[Int(index)]
    for p in properties {
      let param = unit.params[Int(owner.paramStart) + p]
      var field = Decl(kind: .variable, name: param.local, nameToken: param.nameToken, first: param.nameToken - 1, parent: index)
      field.typeStart = param.typeStart
      field.typeEnd = param.typeEnd
      field.end = param.typeEnd
      field.isLocal = isLocal
      field.access = privateParameter(Int(param.nameToken)) ? .isPrivate : .isPublic
      unit.decls.append(field)
    }
    guard unit.isByte(i, 0x7B) else {
      unit.decls[Int(index)].end = Int32(i)
      return i
    }
    let close = unit.skipBalanced(i)
    unit.decls[Int(index)].bodyOpen = Int32(i)
    unit.decls[Int(index)].bodyClose = Int32(close - 1)
    unit.decls[Int(index)].end = Int32(close)
    classBody(open: i, close: close - 1, owner: index, isEnum: kind == .enumeration, isLocal: isLocal)
    return close
  }

  /// Whether the `val` of a constructor parameter is `private`.
  private func privateParameter(_ nameToken: Int) -> Bool {
    var k = nameToken - 1
    while k >= 0, unit.tokens[k].kind == .keyword || unit.tokens[k].kind == .attribute {
      if unit.isToken(k, "private") { return true }
      k -= 1
    }
    return false
  }

  /// The end of `by expr` in a supertype list: the next `,` at this level, or the body.
  private func delegateEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      if unit.isByte(i, 0x28) || unit.isByte(i, 0x5B) {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.isByte(i, 0x2C) || unit.isByte(i, 0x7B) || unit.tokens[i].kind == .close { return i }
      if i > from, unit.startsLine(i), unit.ktStartsDeclaration(i) { return i }
      i += 1
    }
    return limit
  }

  private mutating func classBody(open: Int, close: Int, owner: Int32, isEnum: Bool, isLocal: Bool) {
    var i = open + 1
    if isEnum { i = enumEntries(i, close: close, owner: owner, isLocal: isLocal) }
    while i < close {
      if unit.isByte(i, 0x3B) {
        i += 1
        continue
      }
      let next = declaration(i, parent: owner, isLocal: isLocal, limit: close, inClass: true)
      i = next > i ? next : (unit.tokens[i].kind == .open ? unit.skipBalanced(i) : i + 1)
    }
  }

  /// `A, B(1), C { … };` at an enum body's start.
  private mutating func enumEntries(_ from: Int, close: Int, owner: Int32, isLocal: Bool) -> Int {
    var i = from
    while i < close {
      let at = i
      i = unit.ktSkipAnnotations(i, limit: close)
      guard unit.ktIsName(i), !unit.ktStartsDeclaration(i) || unit.tokens[i].kind == .identifier,
        unit.isByte(i + 1, 0x2C) || unit.isByte(i + 1, 0x28) || unit.isByte(i + 1, 0x7B) || unit.isByte(i + 1, 0x3B) || i + 1 == close
      else {
        return unit.isByte(i, 0x3B) ? i + 1 : at
      }
      var entry = Decl(kind: .enumCase, name: unit.hash(i), nameToken: Int32(i), first: Int32(at), parent: owner)
      entry.isStatic = true
      entry.isLocal = isLocal
      i += 1
      if unit.isByte(i, 0x28) {
        let end = unit.skipBalanced(i)
        entry.initStart = Int32(i + 1)
        entry.initEnd = Int32(end - 1)
        bodies.append((i + 1, end - 1))
        i = end
      }
      let index = Int32(unit.decls.count)
      unit.decls.append(entry)
      if unit.isByte(i, 0x7B) {
        let end = unit.skipBalanced(i)
        unit.decls[Int(index)].bodyOpen = Int32(i)
        unit.decls[Int(index)].bodyClose = Int32(end - 1)
        classBody(open: i, close: end - 1, owner: index, isEnum: false, isLocal: isLocal)
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

  /// Where a receiver ends and the name begins in `fun <T> A.B<T>.name(` or `val A.name:`: the name's token, and the
  /// receiver's range when there is one.
  private func receiverAndName(_ from: Int, limit: Int, isFunction: Bool) -> (name: Int, receiver: (Int, Int)?)? {
    var i = from
    var lastDot = -1
    var budget = 200
    while i < limit, budget > 0 {
      budget -= 1
      if unit.isByte(i, 0x28) {
        if i == from || lastDot == i - 1 {
          // A function type receiver: `(A) -> B`.
          i = unit.skipBalanced(i)
          continue
        }
        break
      }
      if unit.tokens[i].kind == .punctuation, unit.startsWith(i, 0x3C), let after = unit.ktTypeArgumentsEnd(i, limit: limit) {
        i = after
        // `A<T>.name`: the dot is the last byte of the `>.` token.
        if unit.ktEndsWithDot(after - 1) { lastDot = after - 1 }
        continue
      }
      if unit.isByte(i, 0x2E) || unit.isToken(i, "?.") {
        // `A.name`, `A?.name` (`?.` lexes as one token).
        lastDot = i
        i += 1
        continue
      }
      if unit.punctuation(i, madeOf: "?") {
        i += 1
        continue
      }
      if unit.ktIsName(i) {
        if !isFunction, unit.isToken(i + 1, ":") || unit.isToken(i + 1, "=") || unit.isToken(i + 1, "by") || unit.startsLine(i + 1) || unit.isByte(i + 1, 0x3B) || i + 1 >= limit {
          break
        }
        i += 1
        continue
      }
      if unit.tokens[i].kind == .attribute {
        i = unit.ktSkipAnnotations(i, limit: limit)
        continue
      }
      break
    }
    let nameToken = isFunction ? i - 1 : i
    guard nameToken >= from, unit.ktIsName(nameToken) else { return nil }
    if lastDot >= from, lastDot == nameToken - 1 { return (nameToken, (from, unit.isByte(lastDot, 0x2E) || unit.isToken(lastDot, "?.") ? lastDot : lastDot + 1)) }
    return (nameToken, nil)
  }

  /// An extension's holder: an `extensionDecl` named as its receiver's last name, its type the receiver.
  private mutating func extensionHolder(receiver: (Int, Int), at: Int, parent: Int32, isLocal: Bool, generics: Decl) -> Int32 {
    let last = unit.ktTypeLastName(receiver.0, receiver.1)
    var holderName = last.map { unit.hash($0) } ?? KotlinWord.function
    for g in 0..<Int(generics.genericCount) where unit.generics[Int(generics.genericStart) + g].name == holderName { holderName = KotlinWord.anyReceiver }
    var holder = Decl(kind: .extensionDecl, name: holderName, nameToken: Int32(last ?? receiver.0), first: Int32(at), parent: parent)
    holder.typeStart = Int32(receiver.0)
    holder.typeEnd = Int32(receiver.1)
    holder.isLocal = isLocal
    let index = Int32(unit.decls.count)
    unit.decls.append(holder)
    return index
  }

  /// `fun [<T>] [Receiver.]name(params)[: Type] [where …] [= expr | { body }]`.
  private mutating func function(_ at: Int, keyword: Int, mods: Modifiers, parent: Int32, isLocal: Bool, limit: Int) -> Int {
    var decl = Decl(kind: .function, name: 0, nameToken: -1, first: Int32(at), parent: parent)
    var i = keyword + 1
    if unit.startsWith(i, 0x3C), unit.tokens[i].kind == .punctuation { i = typeParameters(i, into: &decl) }
    guard let found = receiverAndName(i, limit: limit, isFunction: true), unit.isByte(found.name + 1, 0x28) else { return keyword + 1 }
    var owner = parent
    var holder: Int32 = -1
    if let receiver = found.receiver {
      holder = extensionHolder(receiver: receiver, at: at, parent: parent, isLocal: isLocal, generics: decl)
      owner = holder
    }
    decl.parent = owner
    decl.name = unit.hash(found.name)
    decl.nameToken = Int32(found.name)
    decl.access = mods.access
    decl.isLocal = isLocal
    let close = unit.skipBalanced(found.name + 1)
    parameters(open: found.name + 1, close: close - 1, into: &decl, limit: limit)
    var k = close
    if unit.isToken(k, ":"), let end = unit.ktTypeEnd(k + 1, limit: limit) {
      decl.typeStart = Int32(k + 1)
      decl.typeEnd = Int32(end)
      k = end
    }
    if unit.isToken(k, "where") {
      decl.whereStart = Int32(k + 1)
      var w = k + 1
      while w < limit, !unit.isByte(w, 0x7B), !unit.isToken(w, "="), !(unit.startsLine(w) && unit.ktStartsDeclaration(w)) { w += 1 }
      decl.whereEnd = Int32(w)
      k = w
    }
    if unit.isToken(k, "=") {
      let start = k + 1
      k = unit.ktExpressionEnd(start, limit: limit)
      decl.initStart = Int32(start)
      decl.initEnd = Int32(k)
      // Without a declared type, what others see is the expression's.
      if decl.typeStart >= 0 { bodies.append((start, k)) }
    } else if unit.isByte(k, 0x7B), !unit.startsLine(k) || !unit.ktStartsDeclaration(k) {
      let end = unit.skipBalanced(k)
      decl.bodyOpen = Int32(k)
      decl.bodyClose = Int32(end - 1)
      bodies.append((k + 1, end - 1))
      k = end
    }
    decl.end = Int32(k)
    unit.decls.append(decl)
    if holder >= 0 { unit.decls[Int(holder)].end = Int32(k) }
    return k
  }

  /// `val|var [<T>] [Receiver.]name[: Type] [= expr | by expr]`, then its accessors.
  private mutating func property(_ at: Int, keyword: Int, mods: Modifiers, parent: Int32, isLocal: Bool, limit: Int) -> Int {
    var decl = Decl(kind: .variable, name: 0, nameToken: -1, first: Int32(at), parent: parent)
    var i = keyword + 1
    if unit.startsWith(i, 0x3C), unit.tokens[i].kind == .punctuation { i = typeParameters(i, into: &decl) }
    // `val (a, b) = …`: a destructuring, only in bodies.
    guard let found = receiverAndName(i, limit: limit, isFunction: false) else { return keyword + 1 }
    var holder: Int32 = -1
    if let receiver = found.receiver {
      holder = extensionHolder(receiver: receiver, at: at, parent: parent, isLocal: isLocal, generics: decl)
      decl.parent = holder
    }
    decl.name = unit.hash(found.name)
    decl.nameToken = Int32(found.name)
    decl.access = mods.access
    decl.isLocal = isLocal
    var k = found.name + 1
    if unit.isToken(k, ":"), let end = unit.ktTypeEnd(k + 1, limit: limit) {
      decl.typeStart = Int32(k + 1)
      decl.typeEnd = Int32(end)
      k = end
    }
    if unit.isToken(k, "=") || unit.isToken(k, "by") {
      let start = k + 1
      k = unit.ktExpressionEnd(start, limit: limit)
      decl.initStart = Int32(start)
      decl.initEnd = Int32(k)
      if decl.typeStart >= 0 { bodies.append((start, k)) }
    }
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    // Accessors: `get() = …`, `get() { … }`, `private set`, `set(value) { … }`.
    while k < limit {
      let mods = modifiers(k, limit: limit)
      let a = mods.end
      guard unit.isToken(a, "get") || unit.isToken(a, "set"), !unit.isToken(a + 1, "=") || unit.isToken(a - 1, ";") || unit.startsLine(a) || a > k else { break }
      guard unit.isByte(a + 1, 0x28) || unit.isToken(a + 1, "=") || unit.isByte(a + 1, 0x7B) || a > k else { break }
      var accessor = Decl(kind: .function, name: 0, nameToken: Int32(a), first: Int32(k), parent: index)
      accessor.isLocal = isLocal
      var e = a + 1
      if unit.isByte(e, 0x28) {
        let close = unit.skipBalanced(e)
        parameters(open: e, close: close - 1, into: &accessor, limit: limit)
        e = close
      }
      if unit.isToken(e, ":"), let end = unit.ktTypeEnd(e + 1, limit: limit) { e = end }
      if unit.isToken(e, "=") {
        let start = e + 1
        e = unit.ktExpressionEnd(start, limit: limit)
        accessor.initStart = Int32(start)
        accessor.initEnd = Int32(e)
        if decl.typeStart >= 0 { bodies.append((start, e)) }
      } else if unit.isByte(e, 0x7B) {
        let end = unit.skipBalanced(e)
        accessor.bodyOpen = Int32(e)
        accessor.bodyClose = Int32(end - 1)
        bodies.append((e + 1, end - 1))
        e = end
      }
      accessor.end = Int32(e)
      unit.decls.append(accessor)
      k = e
      if unit.isByte(k, 0x3B) { k += 1 }
    }
    unit.decls[Int(index)].end = Int32(k)
    if holder >= 0 { unit.decls[Int(holder)].end = Int32(k) }
    return k
  }

  /// Parameters `(a: A, vararg b: B = x, val c: C, f: (Int) -> Unit)` as `Param`s; with `properties`, the indexes of
  /// those declared `val` or `var`.
  @discardableResult
  mutating func parameters(open: Int, close: Int, into decl: inout Decl, limit: Int, properties: Bool = false) -> [Int] {
    decl.paramStart = Int32(unit.params.count)
    decl.paramCount = 0
    var result: [Int] = []
    var i = open + 1
    while i < close {
      var isProperty = false
      var variadic = false
      while i < close {
        if unit.tokens[i].kind == .attribute {
          i = unit.ktSkipAnnotations(i, limit: close)
          continue
        }
        if unit.isToken(i, "val") || unit.isToken(i, "var") {
          isProperty = true
          i += 1
          continue
        }
        if unit.isToken(i, "vararg") { variadic = true }
        if unit.tokens[i].kind == .keyword || unit.tokens[i].kind == .declarationKeyword, KotlinWord.modifiers.contains(unit.hash(i)),
          unit.ktIsName(i + 1) || unit.tokens[i + 1].kind == .keyword || unit.tokens[i + 1].kind == .declarationKeyword || unit.tokens[i + 1].kind == .attribute {
          i += 1
          continue
        }
        break
      }
      if unit.ktIsName(i) {
        let nameToken = i
        var typeStart = -1
        var typeEnd = -1
        var k = i + 1
        if unit.isToken(k, ":"), let end = unit.ktTypeEnd(k + 1, limit: close) {
          typeStart = k + 1
          typeEnd = end
          k = end
        }
        var hasDefault = false
        if unit.isToken(k, "=") {
          hasDefault = true
          let start = k + 1
          while k < close, !unit.isByte(k, 0x2C) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
          bodies.append((start, k))
        }
        unit.params.append(
          Param(label: 0, local: unit.hash(nameToken), nameToken: Int32(nameToken), typeStart: Int32(typeStart), typeEnd: Int32(typeEnd), hasDefault: hasDefault, variadic: variadic))
        if properties, isProperty { result.append(Int(decl.paramCount)) }
        decl.paramCount += 1
        i = k
      }
      while i < close, !unit.isByte(i, 0x2C) { i = unit.tokens[i].kind == .open ? unit.skipBalanced(i) : i + 1 }
      i += 1
    }
    return result
  }

  // MARK: Local declarations

  /// The functions, classes and objects declared in a declaration's bodies and initializers: each `isLocal`, then
  /// theirs.
  private mutating func scanLocals(of index: Int32) {
    let decl = unit.decls[Int(index)]
    if decl.bodyOpen >= 0, !decl.kind.hasMembers, decl.kind != .enumCase { locals(from: Int(decl.bodyOpen) + 1, to: Int(decl.bodyClose), parent: index) }
    if decl.initStart >= 0 { locals(from: Int(decl.initStart), to: Int(decl.initEnd), parent: index) }
    for p in 0..<Int(decl.paramCount) where unit.params[Int(decl.paramStart) + p].hasDefault {
      let param = unit.params[Int(decl.paramStart) + p]
      let start = Int(param.typeEnd >= 0 ? param.typeEnd : param.nameToken + 1) + 1
      var end = start
      while end < unit.tokens.count, !unit.isByte(end, 0x2C), unit.tokens[end].kind != .close { end = unit.tokens[end].kind == .open ? unit.skipBalanced(end) : end + 1 }
      locals(from: start, to: end, parent: index)
    }
  }

  private mutating func locals(from: Int, to: Int, parent: Int32) {
    var i = from
    while i < to {
      // `object : T { … }`, `object { … }`: an anonymous class.
      if unit.isToken(i, "object"), unit.isToken(i + 1, ":") || unit.isByte(i + 1, 0x7B), !unit.ktIsName(i - 1) || unit.isToken(i - 1, "return") {
        let before = unit.decls.count
        let end = classDeclaration(i, keyword: i, mods: Modifiers(end: i), parent: parent, isLocal: true, limit: to)
        if end > i {
          for index in before..<unit.decls.count where unit.decls[index].parent == parent { membersLocals(of: Int32(index)) }
          i = end
          continue
        }
      }
      if unit.isToken(i, "fun") || unit.isToken(i, "class") || unit.isToken(i, "interface") || unit.isToken(i, "object"), unit.ktIsName(i + 1) || unit.startsWith(i + 1, 0x3C) {
        var start = i
        while start - 1 >= from, unit.tokens[start - 1].kind == .keyword || unit.tokens[start - 1].kind == .declarationKeyword || unit.tokens[start - 1].kind == .attribute,
          KotlinWord.modifiers.contains(unit.hash(start - 1)) || unit.tokens[start - 1].kind == .attribute
        {
          start -= 1
        }
        let before = unit.decls.count
        let end = declaration(start, parent: parent, isLocal: true, limit: to, inClass: false)
        if end > start, unit.decls.count > before {
          for index in before..<unit.decls.count where unit.decls[index].parent == parent || unit.decls[index].kind == .function && unit.decls[index].isLocal {
            membersLocals(of: Int32(index))
          }
          i = end
          continue
        }
      }
      i += 1
    }
  }

  /// The local declarations in a local declaration's members.
  private mutating func membersLocals(of owner: Int32) {
    let decl = unit.decls[Int(owner)]
    if decl.kind == .function || decl.kind == .initializer || decl.kind == .variable {
      if decl.bodyOpen >= 0 { locals(from: Int(decl.bodyOpen) + 1, to: Int(decl.bodyClose), parent: owner) }
      if decl.initStart >= 0 { locals(from: Int(decl.initStart), to: Int(decl.initEnd), parent: owner) }
      return
    }
    let snapshot = unit.decls.count
    for index in Int(owner + 1)..<snapshot where unit.decls[index].parent == owner {
      membersLocals(of: Int32(index))
    }
  }
}
