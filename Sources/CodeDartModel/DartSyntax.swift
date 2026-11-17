import CodeModel
import CodeScan
import Foundation

/// Dart's reading of a file into the core's tables:
///
/// - `class` (any of its modifiers: `abstract`, `sealed`, `base`, `final`, `interface`, `mixin class`) and `mixin`
///   are `classType`s, `enum` an `enumeration` (its values `enumCase`s), an extension type a `structure` (its
///   representation a `variable`), `typedef` a `typeAlias`, an extension an `extensionDecl` named by its own name (an
///   unnamed one by a name no code can write) with what it's `on` as its type. Supertypes are inherited ranges in the
///   order members are found: the mixins last first, then the superclass, then the interfaces, then a mixin's `on`
///   types.
/// - Functions and methods are `function`s, operators `function`s named by their operator (`==`, `[]`, `unary-`),
///   constructors `initializer`s named by their name after the dot (`new` for the unnamed one) at that name (the class's
///   name for the unnamed one), their initializer list the `init…` range. Getters and fields are `variable`s (a getter
///   with `get` before its name), setters `variable`s named `x=` with their parameter. A body is `{…}`, or `=> …` up to
///   its `;` (from the `=>`).
/// - Parameters: positional ones without a label, named ones (`{…}`) labelled with their name; optional ones (in `[…]`
///   or `{…}` without `required`) have a default. `this.x` and `super.x` are parameters at `x`.
/// - `import`, `export`: `Import`s whose module is the library they name, resolved by the layout (an absolute path, or
///   `dart:core`), `isExported` for `export`, `alias` for `as p`; the model reads `show` and `hide` from the tokens after
///   `Import.token` (the URI). `part` and `part of` are the layout's: a library and its parts are one module.
/// - `$name` in a string is an identifier token of its own (`codeTokens`), so it's answered and found like any use; a
///   `>.` after type arguments is split into `>` and `.`.
package final class DartSyntax: LanguageSyntax {
  package let profile = LexProfile.profile(forLanguage: "dart")!
  package let parametersHaveLabels = false
  /// The library a URI names from a file: an absolute path, or `dart:x`; nil when it can't be found.
  let resolve: (_ fromPath: String, _ uri: String) -> String?

  package init(resolve: @escaping (String, String) -> String? = { _, _ in nil }) {
    self.resolve = resolve
  }

  package func parse(_ unit: CodeModel.Unit) -> UInt64 {
    var parser = DartParser(unit: unit, resolve: resolve)
    parser.parseFile()
    return parser.shape
  }

  package func evaluateCondition(_ unit: CodeModel.Unit, _ i: inout Int) -> Bool { true }

  /// Comments dropped; a string's `$name` interpolations become identifier tokens between the string's pieces (the
  /// piece before one ends with its `$`). Raw strings (`r'…'`) have none.
  package func codeTokens(_ source: SourceFile) -> [Token] {
    var kept = [Token]()
    kept.reserveCapacity(source.tokens.count)
    let text = source.text
    func isStart(_ b: UInt8) -> Bool { b == 0x5F || (b | 0x20 >= 0x61 && b | 0x20 <= 0x7A) }
    func isPart(_ b: UInt8) -> Bool { isStart(b) || (b >= 0x30 && b <= 0x39) }
    for (index, token) in source.tokens.enumerated() {
      switch token.kind {
      case .comment, .docComment:
        continue
      case .string:
        // A raw string: `r` right before it.
        if index > 0, source.tokens[index - 1].kind == .identifier, source.tokens[index - 1].end == token.start, source.tokens[index - 1].length == 1,
          text[source.tokens[index - 1].start] == 0x72
        {
          kept.append(token)
          continue
        }
        var from = token.start
        var i = token.start
        while i < token.end - 1 {
          if text[i] == 0x5C {
            i += 2
            continue
          }
          if text[i] == 0x24, isStart(text[i + 1]) {
            var j = i + 1
            while j < token.end, isPart(text[j]) { j += 1 }
            kept.append(Token(kind: .string, start: from, end: i + 1))
            kept.append(Token(kind: .identifier, start: i + 1, end: j))
            from = j
            i = j
            continue
          }
          i += 1
        }
        if from < token.end { kept.append(Token(kind: .string, start: from, end: token.end)) }
      case .punctuation where token.length > 1 && (text[token.start] == 0x3E || text[token.start] == 0x3F && text[token.start + 1] == 0x3E):
        // `List<int>.filled`, `Map<String, Object?>.from`: the type arguments' `>` and the dot after them are one run of
        // operator bytes; split, so the dot is a dot (`>?`, `>>`, `>=` stay whole).
        var k = token.start
        var last = k
        while k < token.end, text[k] == 0x3E || text[k] == 0x3F {
          if text[k] == 0x3E { last = k }
          k += 1
        }
        k = last + 1
        let rest = token.end - k
        let isDot = rest == 1 && text[k] == 0x2E || rest == 2 && (text[k] == 0x2E || text[k] == 0x3F || text[k] == 0x21) && text[k + 1] == 0x2E
          || rest == 3 && text[k] == 0x3F && text[k + 1] == 0x2E && text[k + 2] == 0x2E
        if isDot {
          kept.append(Token(kind: .punctuation, start: token.start, end: k))
          kept.append(Token(kind: .punctuation, start: k, end: token.end))
        } else {
          kept.append(token)
        }
      default:
        kept.append(token)
      }
    }
    return kept
  }
}

enum DartWord {
  /// Reserved words: never a name.
  static let reserved: Set<Name> = Set(
    [
      "assert", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum", "extends", "false", "final", "finally",
      "for", "if", "in", "is", "new", "null", "rethrow", "return", "super", "switch", "this", "throw", "true", "try", "var", "void", "while",
      "with",
    ].map { name($0) })
  /// Words that start or modify a declaration.
  static let modifiers: Set<Name> = Set(
    ["abstract", "sealed", "base", "final", "interface", "external", "static", "late", "const", "covariant", "augment", "var"].map { name($0) })
  static let newWord = name("new"), thisWord = name("this"), superWord = name("super"), objectWord = name("Object")
  static let enumWord = name("Enum"), functionWord = name("Function"), recordWord = name("Record"), nullWord = name("Null")
  static let iterableWord = name("Iterable"), streamWord = name("Stream"), futureWord = name("Future"), futureOrWord = name("FutureOr")
  static let listWord = name("List"), mapWord = name("Map"), setWord = name("Set"), boolWord = name("bool"), intWord = name("int")
  static let doubleWord = name("double"), numWord = name("num"), stringWord = name("String"), typeWord = name("Type")
  static let dynamicWord = name("dynamic"), voidWord = name("void"), neverWord = name("Never"), indexOperator = name("[]")
  static let stackTraceWord = name("StackTrace"), symbolWord = name("Symbol"), mapEntryWord = name("MapEntry")
  static let valuesWord = name("values"), indexWord = name("index"), nameWord = name("name"), callWord = name("call")
  static let core = "dart:core"
  /// Words that end a statement's expression or can't be inside one.
  static let statementWords: Set<Name> = Set(["return", "if", "for", "while", "do", "switch", "try", "throw", "break", "continue", "yield", "assert", "else"].map { name($0) })
}

extension Unit {
  /// A name: an identifier, or a keyword Dart lets a program use as one (`get`, `on`, `show`, `required`, `async`).
  func daIsName(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    switch tokens[i].kind {
    case .identifier: return true
    case .keyword, .declarationKeyword: return !DartWord.reserved.contains(hash(i))
    default: return false
    }
  }

  /// A `>` that may close type arguments: `>`, `>>`, `?>>` (`Map<String, Object?>>`).
  func daClosesTypeArguments(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count, tokens[i].kind == .punctuation, source.text[tokens[i].end - 1] == 0x3E else { return false }
    return punctuation(i, madeOf: ">?")
  }

  /// A member access: `.`, `?.`, `!.` (a null assertion and a dot), or a cascade `..`, `?..`.
  func daIsDot(_ i: Int) -> Bool {
    isByte(i, 0x2E) || isToken(i, "?.") || isToken(i, "!.") || isToken(i, "..") || isToken(i, "?..") || isToken(i, "!..")
  }

  /// A cascade section's `..` or `?..`.
  func daIsCascade(_ i: Int) -> Bool { isToken(i, "..") || isToken(i, "?..") || isToken(i, "!..") }

  /// The token after type arguments `<…>` starting at `i` (its `>` may hold a `?`), when what's inside reads as types.
  func daTypeArgumentsEnd(_ i: Int, limit: Int? = nil) -> Int? {
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
        guard punctuation(k, madeOf: "<>?,.") else { return nil }
        for b in 0..<token.length {
          let byte = source.text[token.start + b]
          if byte == 0x3C {
            depth += 1
          } else if byte == 0x3E {
            depth -= 1
            if depth == 0 {
              for rest in (b + 1)..<max(b + 1, token.length) where source.text[token.start + rest] != 0x3F { return nil }
              return k + 1
            }
          }
        }
      case .identifier:
        break
      case .keyword, .declarationKeyword:
        // `extends`: a type parameter's bound, `<T extends Comparable<T>>`.
        guard daIsName(k) || isToken(k, "void") || isToken(k, "extends") else { return nil }
      case .open:
        // A function type's parameters, a record type.
        guard isByte(k, 0x28) || isByte(k, 0x7B) else { return nil }
        k = skipBalanced(k)
        continue
      default:
        return nil
      }
      k += 1
    }
    return nil
  }

  /// The end of a type written from `i`: a qualified name with type arguments, `void`, a record `(A, B b)`, a function
  /// type `R Function<T>(A a)`, each with `?`; nil when no type starts there.
  func daTypeEnd(_ from: Int, limit: Int? = nil) -> Int? {
    let end = min(limit ?? tokens.count, tokens.count)
    var i = from
    guard i < end else { return nil }
    if isToken(i, "Function") {
      // A function type with no return type, or the class `Function` itself.
      if functionSuffix(i, end) == i {
        i += 1
        if isByte(i, 0x3F) { i += 1 }
      }
    } else if isByte(i, 0x28) {
      // A record type: `(int, String)`, `({int a})`.
      let close = skipBalanced(i)
      guard close <= end else { return nil }
      var k = i + 1
      var elements = 0
      while k < close - 1 {
        if isByte(k, 0x7B) || isByte(k, 0x5B) {
          k = skipBalanced(k)
          elements += 2
          continue
        }
        guard let typeEnd = daTypeEnd(k, limit: close - 1) else { return nil }
        k = typeEnd
        if daIsName(k) { k += 1 }
        elements += 1
        if isByte(k, 0x2C) { k += 1 } else { break }
      }
      guard elements >= 1, k >= close - 1 else { return nil }
      i = close
      if isByte(i, 0x3F) { i += 1 }
    } else if isToken(i, "void") {
      i += 1
    } else if daIsName(i) {
      i += 1
      while i < end {
        if tokens[i].kind == .punctuation, startsWith(i, 0x3C), let after = daTypeArgumentsEnd(i, limit: end) {
          i = after
          // `List<int>?`: the `?` was the `>`'s.
          if punctuation(i - 1, madeOf: ">?"), source.text[tokens[i - 1].end - 1] == 0x3F { return functionSuffix(i, end) }
          continue
        }
        if isByte(i, 0x2E), daIsName(i + 1), i + 1 < end {
          i += 2
          continue
        }
        break
      }
      if isByte(i, 0x3F) { i += 1 }
    } else {
      return nil
    }
    return functionSuffix(i, end)
  }

  /// `R Function(…)`, `R Function<T>(…)?`: function types after a return type (or none).
  private func functionSuffix(_ from: Int, _ end: Int) -> Int {
    var i = from
    while i < end, isToken(i, "Function") {
      var k = i + 1
      if tokens.indices.contains(k), tokens[k].kind == .punctuation, startsWith(k, 0x3C), let after = daTypeArgumentsEnd(k, limit: end) { k = after }
      guard isByte(k, 0x28) else { break }
      k = skipBalanced(k)
      if isByte(k, 0x3F) { k += 1 }
      i = k
    }
    return i
  }

  /// Past metadata: `@override`, `@Deprecated('x')`, `@a.b.C<T>(…)`.
  func daSkipMetadata(_ from: Int, limit: Int? = nil) -> Int {
    let end = limit ?? tokens.count
    var i = from
    while i < end, isByte(i, 0x40), daIsName(i + 1) {
      i += 2
      while i + 1 < end, isByte(i, 0x2E), daIsName(i + 1) { i += 2 }
      if i < end, tokens[i].kind == .punctuation, startsWith(i, 0x3C), let after = daTypeArgumentsEnd(i, limit: end) { i = after }
      if i < end, isByte(i, 0x28), touchesPrevious(i) || !startsLine(i) { i = skipBalanced(i) }
    }
    return i
  }

  /// The end of an expression from `from`: the first `,`, `;` or closing bracket outside brackets (type arguments of a
  /// constructor or literal kept whole), at most `limit`.
  func daExpressionEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      let token = tokens[i]
      switch token.kind {
      case .open:
        i = skipBalanced(i)
        continue
      case .close:
        return i
      case .punctuation:
        if isByte(i, 0x2C) || isByte(i, 0x3B) { return i }
        if startsWith(i, 0x3C), i == from || daIsName(i - 1) || tokens[i - 1].kind == .punctuation || tokens[i - 1].kind == .open || isToken(i - 1, "return"),
          let after = daTypeArgumentsEnd(i, limit: limit),
          after < limit, isByte(after, 0x28) || isByte(after, 0x5B) || isByte(after, 0x7B) || isByte(after, 0x2E)
        {
          i = after
          continue
        }
      default:
        break
      }
      i += 1
    }
    return limit
  }

  /// A string literal's last token: adjacent strings and their interpolations (`'a $b ${c}'`) are one literal.
  func daStringEnd(_ i: Int) -> Int {
    var k = i
    while k < tokens.count {
      switch tokens[k].kind {
      case .string:
        k += 1
      case .interpolationOpen:
        var depth = 0
        while k < tokens.count {
          if tokens[k].kind == .interpolationOpen { depth += 1 } else if tokens[k].kind == .interpolationClose {
            depth -= 1
            if depth == 0 { break }
          }
          k += 1
        }
        k += 1
      case .identifier:
        // `$name`: right after a piece ending in `$`.
        guard k > 0, tokens[k - 1].kind == .string, tokens[k - 1].end == tokens[k].start, source.text[tokens[k - 1].end - 1] == 0x24 else { return k }
        k += 1
      default:
        return k
      }
    }
    return k
  }

  /// Whether an identifier token is a `$name` inside a string.
  func daIsInterpolatedName(_ i: Int) -> Bool {
    guard i > 0, i < tokens.count, tokens[i].kind == .identifier, tokens[i - 1].kind == .string else { return false }
    return tokens[i - 1].end == tokens[i].start && source.text[tokens[i - 1].end - 1] == 0x24
  }

  /// A string literal's text without quotes (`'package:a/b.dart'`): its first piece.
  func daStringValue(_ i: Int) -> String? {
    guard i >= 0, i < tokens.count, tokens[i].kind == .string else { return nil }
    var text = string(i)
    if text.hasPrefix("'''") || text.hasPrefix("\"\"\"") {
      text = String(text.dropFirst(3).dropLast(text.count >= 6 ? 3 : 0))
    } else {
      text = String(text.dropFirst().dropLast(text.count >= 2 ? 1 : 0))
    }
    return text
  }
}

/// Reads a file's declarations into the core's tables.
struct DartParser {
  let unit: Unit
  let resolve: (String, String) -> String?
  var shape: UInt64 = 14_695_981_039_346_656_037
  /// Token ranges others can't see: bodies, initializers of typed variables, default values.
  var bodies: [(Int, Int)] = []
  private var count: Int { unit.tokens.count }

  init(unit: Unit, resolve: @escaping (String, String) -> String?) {
    self.unit = unit
    self.resolve = resolve
  }

  mutating func parseFile() {
    var i = 0
    while i < count {
      let start = i
      let next = declaration(i, parent: -1, limit: count, className: nil)
      if next > start {
        i = next
        continue
      }
      i = unit.tokens[i].kind == .open ? unit.skipBalanced(i) : i + 1
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
        i = max(i + 1, bodies[b].1)
        continue
      }
      shape = (shape ^ unit.hash(i)) &* 1_099_511_628_211
      i += 1
    }
  }

  // MARK: Declarations

  struct Modifiers {
    var isStatic = false
    var isConst = false
    var isFinal = false
    var isVar = false
    var isLate = false
    var isExternal = false
    var isFactory = false
    var isAbstract = false
  }

  /// One declaration from `at` (metadata and modifiers first): the token after it, or `at` when none starts there.
  mutating func declaration(_ at: Int, parent: Int32, limit: Int, className: Name?) -> Int {
    var i = unit.daSkipMetadata(at, limit: limit)
    let first = at
    var mods = Modifiers()
    if parent < 0 {
      if unit.isToken(i, "import") || unit.isToken(i, "export") { return directive(i, limit: limit) }
      if unit.isToken(i, "library") || unit.isToken(i, "part") { return statementEnd(i, limit: limit) }
    }
    while i < limit {
      if unit.isToken(i, "mixin"), unit.isToken(i + 1, "class") || unit.isToken(i + 1, "mixin") == false && DartWord.modifiers.contains(unit.hash(i + 1)) {
        i += 1
        continue
      }
      if unit.isToken(i, "factory"), className != nil {
        mods.isFactory = true
        i += 1
        continue
      }
      guard unit.tokens[i].kind == .keyword || unit.tokens[i].kind == .declarationKeyword, DartWord.modifiers.contains(unit.hash(i)) else { break }
      // `final x`, `static`… but `final` before a name followed by `(` can't be (a modifier always comes first).
      if unit.isToken(i, "static") { mods.isStatic = true }
      if unit.isToken(i, "const") { mods.isConst = true }
      if unit.isToken(i, "final") { mods.isFinal = true }
      if unit.isToken(i, "var") { mods.isVar = true }
      if unit.isToken(i, "late") { mods.isLate = true }
      if unit.isToken(i, "external") { mods.isExternal = true }
      if unit.isToken(i, "abstract") { mods.isAbstract = true }
      // `interface`, `base`, `sealed` as names: `base.x` isn't a declaration.
      if !unit.daIsName(i + 1) && !unit.isToken(i + 1, "class") && !unit.isToken(i + 1, "mixin") && !unit.isToken(i + 1, "enum") && !unit.isToken(i + 1, "void")
        && !unit.isByte(i + 1, 0x28) && !unit.isToken(i + 1, "Function") && !DartWord.modifiers.contains(unit.hash(i + 1))
      {
        break
      }
      i += 1
    }
    guard i < limit else { return at }
    if unit.isToken(i, "class") { return classDeclaration(i, first: first, parent: parent, limit: limit, kind: .classType) }
    if unit.isToken(i, "mixin"), unit.daIsName(i + 1) { return classDeclaration(i, first: first, parent: parent, limit: limit, kind: .classType, isMixin: true) }
    if unit.isToken(i, "enum"), unit.daIsName(i + 1) { return classDeclaration(i, first: first, parent: parent, limit: limit, kind: .enumeration) }
    if unit.isToken(i, "extension") {
      if unit.isToken(i + 1, "type"), unit.daIsName(i + 2) || unit.isToken(i + 2, "const") { return extensionType(i, first: first, parent: parent, limit: limit) }
      if unit.daIsName(i + 1) || unit.isToken(i + 1, "on") || unit.tokens.indices.contains(i + 1) && unit.startsWith(i + 1, 0x3C) {
        return extensionDeclaration(i, first: first, parent: parent, limit: limit)
      }
    }
    if unit.isToken(i, "typedef") { return typedefDeclaration(i, first: first, parent: parent, limit: limit) }
    // A constructor: `C(`, `C.name(`, `const C(`, `factory C.name(`.
    if let className, unit.daIsName(i), unit.hash(i) == className, unit.isByte(i + 1, 0x28) || unit.isByte(i + 1, 0x2E) && unit.daIsName(i + 2) {
      return constructor(i, first: first, parent: parent, limit: limit, mods: mods)
    }
    // `get x`, `set x`, `operator +` without a return type.
    if unit.isToken(i, "get"), unit.daIsName(i + 1), !unit.isByte(i + 1, 0x28) && !unit.isToken(i + 1, "=") {
      return accessor(i, typeStart: -1, typeEnd: -1, first: first, parent: parent, limit: limit, mods: mods)
    }
    if unit.isToken(i, "set"), unit.daIsName(i + 1), unit.isByte(i + 2, 0x28) {
      return accessor(i, typeStart: -1, typeEnd: -1, first: first, parent: parent, limit: limit, mods: mods)
    }
    if unit.isToken(i, "operator"), !unit.isByte(i + 1, 0x28) || unit.isByte(i + 2, 0x29) {
      return function(i, typeStart: -1, typeEnd: -1, first: first, parent: parent, limit: limit, mods: mods)
    }
    // A name with no type before it: a function `f(`, `f<T>(`, or a variable after `var`/`final`/`const`/`late`.
    if unit.daIsName(i) {
      if unit.isByte(i + 1, 0x28) { return function(i, typeStart: -1, typeEnd: -1, first: first, parent: parent, limit: limit, mods: mods) }
      if unit.startsWith(i + 1, 0x3C), unit.tokens[i + 1].kind == .punctuation, let after = unit.daTypeArgumentsEnd(i + 1, limit: limit), unit.isByte(after, 0x28),
        !(unit.daIsName(after - 1))
      {
        // `f<T>(…)` with no return type, unless `List<T> (…)`'s parenthesis is a record's; a type then a name is below.
        let close = unit.skipBalanced(after)
        if unit.isByte(close, 0x7B) || unit.isToken(close, "=>") || unit.isByte(close, 0x3B) || unit.isToken(close, "async") || unit.isToken(close, "sync") {
          return function(i, typeStart: -1, typeEnd: -1, first: first, parent: parent, limit: limit, mods: mods)
        }
      }
      if mods.isVar || mods.isFinal || mods.isConst || mods.isLate, unit.isToken(i + 1, "=") || unit.isByte(i + 1, 0x3B) || unit.isByte(i + 1, 0x2C) {
        return variables(i, typeStart: -1, typeEnd: -1, first: first, parent: parent, limit: limit, mods: mods)
      }
    }
    // A type, then a name.
    guard let typeEnd = unit.daTypeEnd(i, limit: limit), typeEnd > i else { return at }
    if unit.isToken(typeEnd, "get"), unit.daIsName(typeEnd + 1) {
      return accessor(typeEnd, typeStart: i, typeEnd: typeEnd, first: first, parent: parent, limit: limit, mods: mods)
    }
    if unit.isToken(typeEnd, "set"), unit.daIsName(typeEnd + 1), unit.isByte(typeEnd + 2, 0x28) {
      return accessor(typeEnd, typeStart: i, typeEnd: typeEnd, first: first, parent: parent, limit: limit, mods: mods)
    }
    if unit.isToken(typeEnd, "operator") {
      return function(typeEnd, typeStart: i, typeEnd: typeEnd, first: first, parent: parent, limit: limit, mods: mods)
    }
    guard unit.daIsName(typeEnd) else { return at }
    let after = typeEnd + 1
    if unit.isByte(after, 0x28) || unit.startsWith(after, 0x3C) && unit.tokens[after].kind == .punctuation {
      return function(typeEnd, typeStart: i, typeEnd: typeEnd, first: first, parent: parent, limit: limit, mods: mods)
    }
    if unit.isToken(after, "=") || unit.isByte(after, 0x3B) || unit.isByte(after, 0x2C) {
      return variables(typeEnd, typeStart: i, typeEnd: typeEnd, first: first, parent: parent, limit: limit, mods: mods)
    }
    return at
  }

  /// Past a statement's `;` (or what can't be in one).
  private func statementEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit, !unit.isByte(i, 0x3B) {
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.tokens[i].kind == .close { return i }
      i += 1
    }
    return min(limit, i + 1)
  }

  private func newDecl(_ kind: DeclKind, nameToken: Int, first: Int, parent: Int32) -> Decl {
    var decl = Decl(kind: kind, name: nameToken >= 0 ? unit.hash(nameToken) : 0, nameToken: Int32(nameToken), first: Int32(first), parent: parent)
    if nameToken >= 0, unit.source.text[unit.tokens[nameToken].start] == 0x5F { decl.access = .isPrivate } else { decl.access = .isPublic }
    return decl
  }

  @discardableResult
  private mutating func add(_ decl: Decl) -> Int32 {
    unit.decls.append(decl)
    return Int32(unit.decls.count - 1)
  }

  // MARK: Directives

  /// `import 'uri' [if (c) 'uri']* [deferred] [as p] [show a, b] [hide c];`, `export …`.
  private mutating func directive(_ at: Int, limit: Int) -> Int {
    let isExport = unit.isToken(at, "export")
    var i = at + 1
    guard unit.tokens.indices.contains(i), unit.tokens[i].kind == .string else { return statementEnd(at, limit: limit) }
    var uriToken = i
    var uri = unit.daStringValue(i) ?? ""
    i = unit.daStringEnd(i)
    // Configurable imports: the one a native build takes (`dart.library.io`, `dart.library.ffi`).
    while unit.isToken(i, "if"), unit.isByte(i + 1, 0x28) {
      let close = unit.skipBalanced(i + 1)
      let condition = unit.text(from: i + 2, to: close - 1)
      if unit.tokens.indices.contains(close), unit.tokens[close].kind == .string {
        if condition.contains("dart.library.io") || condition.contains("dart.library.ffi") || condition.contains("dart.library.isolate") {
          uriToken = close
          uri = unit.daStringValue(close) ?? uri
        }
        i = unit.daStringEnd(close)
      } else {
        i = close
      }
    }
    let key = resolve(unit.path, uri) ?? uri
    var item = Import(module: name(key), moduleName: key, isExported: isExport, isTestable: false)
    item.token = Int32(uriToken)
    if unit.isToken(i, "deferred") { i += 1 }
    if unit.isToken(i, "as"), unit.daIsName(i + 1) {
      item.alias = unit.hash(i + 1)
      item.aliasToken = Int32(i + 1)
    }
    unit.imports.append(item)
    return statementEnd(i, limit: limit)
  }

  // MARK: Types

  /// `class`, `mixin`, `enum` (and `mixin class`): its head, supertypes and body.
  private mutating func classDeclaration(_ keyword: Int, first: Int, parent: Int32, limit: Int, kind: DeclKind, isMixin: Bool = false) -> Int {
    let nameToken = keyword + 1
    guard unit.daIsName(nameToken) else { return keyword + 1 }
    var decl = newDecl(kind, nameToken: nameToken, first: first, parent: parent)
    var i = typeParameters(nameToken + 1, into: &decl, limit: limit)
    // `class A = B with M;`: a mixin application.
    var superclass: (Int, Int)?
    var mixins: [(Int, Int)] = []
    var interfaces: [(Int, Int)] = []
    var constraints: [(Int, Int)] = []
    if unit.isToken(i, "=") {
      if let end = unit.daTypeEnd(i + 1, limit: limit) {
        superclass = (i + 1, end)
        i = end
      }
    }
    while i < limit {
      if unit.isToken(i, "extends"), let end = unit.daTypeEnd(i + 1, limit: limit) {
        superclass = (i + 1, end)
        i = end
        continue
      }
      if unit.isToken(i, "with") || unit.isToken(i, "implements") || unit.isToken(i, "on") {
        let word = i
        i += 1
        while let end = unit.daTypeEnd(i, limit: limit), end > i {
          if unit.isToken(word, "with") { mixins.append((i, end)) } else if unit.isToken(word, "implements") { interfaces.append((i, end)) } else { constraints.append((i, end)) }
          i = end
          guard unit.isByte(i, 0x2C) else { break }
          i += 1
        }
        continue
      }
      break
    }
    decl.inheritStart = Int32(unit.ranges.count)
    for range in mixins.reversed() { unit.ranges.append((Int32(range.0), Int32(range.1))) }
    if let superclass { unit.ranges.append((Int32(superclass.0), Int32(superclass.1))) }
    for range in interfaces + constraints { unit.ranges.append((Int32(range.0), Int32(range.1))) }
    decl.inheritCount = Int32(unit.ranges.count) - decl.inheritStart
    _ = isMixin
    guard unit.isByte(i, 0x7B) else {
      // `class A = B with M;`.
      decl.end = Int32(statementEnd(i, limit: limit))
      add(decl)
      return Int(decl.end)
    }
    let close = unit.skipBalanced(i) - 1
    decl.bodyOpen = Int32(i)
    decl.bodyClose = Int32(close)
    decl.end = Int32(close + 1)
    let index = add(decl)
    var k = i + 1
    if kind == .enumeration { k = enumValues(k, close: close, owner: index) }
    members(k, close: close, owner: index, className: unit.hash(nameToken))
    return close + 1
  }

  /// An enum's values, up to the `;` before its members (or its `}`): the token after them.
  private mutating func enumValues(_ from: Int, close: Int, owner: Int32) -> Int {
    var i = from
    while i < close {
      i = unit.daSkipMetadata(i, limit: close)
      guard unit.daIsName(i) else { break }
      var value = newDecl(.enumCase, nameToken: i, first: i, parent: owner)
      value.isStatic = true
      var k = i + 1
      if unit.tokens[k].kind == .punctuation, unit.startsWith(k, 0x3C), let after = unit.daTypeArgumentsEnd(k, limit: close) { k = after }
      if unit.isByte(k, 0x2E), unit.daIsName(k + 1) { k += 2 }
      if unit.isByte(k, 0x28) {
        let end = unit.skipBalanced(k)
        value.initStart = Int32(k)
        value.initEnd = Int32(end)
        bodies.append((k, end))
        k = end
      }
      value.end = Int32(k)
      add(value)
      i = k
      if unit.isByte(i, 0x2C) {
        i += 1
        continue
      }
      break
    }
    if unit.isByte(i, 0x3B) { i += 1 }
    return i
  }

  /// A type's members, from `from` to its `}`.
  private mutating func members(_ from: Int, close: Int, owner: Int32, className: Name?) {
    var i = from
    while i < close {
      if unit.isByte(i, 0x3B) {
        i += 1
        continue
      }
      let next = declaration(i, parent: owner, limit: close, className: className)
      if next > i {
        i = next
        continue
      }
      i = unit.tokens[i].kind == .open ? unit.skipBalanced(i) : i + 1
    }
  }

  /// `extension Name<T> on Type { … }`, `extension on Type { … }`.
  private mutating func extensionDeclaration(_ keyword: Int, first: Int, parent: Int32, limit: Int) -> Int {
    var i = keyword + 1
    var nameToken = keyword
    if unit.daIsName(i), !unit.isToken(i, "on") || unit.isToken(i + 1, "on") || unit.startsWith(i + 1, 0x3C) && unit.tokens[i + 1].kind == .punctuation {
      nameToken = i
      i += 1
    }
    var decl = newDecl(.extensionDecl, nameToken: nameToken, first: first, parent: parent)
    if nameToken == keyword {
      // Unnamed: no code can name it, and it's this library's alone.
      decl.name = name("<extension>@" + String(keyword))
      decl.access = .isPrivate
    }
    i = typeParameters(i, into: &decl, limit: limit)
    guard unit.isToken(i, "on"), let end = unit.daTypeEnd(i + 1, limit: limit) else { return keyword + 1 }
    decl.typeStart = Int32(i + 1)
    decl.typeEnd = Int32(end)
    i = end
    while i < limit, !unit.isByte(i, 0x7B) { i += 1 }
    guard unit.isByte(i, 0x7B) else { return keyword + 1 }
    let close = unit.skipBalanced(i) - 1
    decl.bodyOpen = Int32(i)
    decl.bodyClose = Int32(close)
    decl.end = Int32(close + 1)
    let index = add(decl)
    members(i + 1, close: close, owner: index, className: nil)
    return close + 1
  }

  /// `extension type [const] Name<T>[.ctor](Rep rep) [implements A] { … }`: a type whose representation is a field.
  private mutating func extensionType(_ keyword: Int, first: Int, parent: Int32, limit: Int) -> Int {
    var i = keyword + 2
    if unit.isToken(i, "const") { i += 1 }
    let nameToken = i
    guard unit.daIsName(nameToken) else { return keyword + 1 }
    var decl = newDecl(.structure, nameToken: nameToken, first: first, parent: parent)
    i = typeParameters(nameToken + 1, into: &decl, limit: limit)
    var constructorName = -1
    if unit.isByte(i, 0x2E), unit.daIsName(i + 1) {
      constructorName = i + 1
      i += 2
    }
    guard unit.isByte(i, 0x28) else { return keyword + 1 }
    let open = i
    let paramClose = unit.skipBalanced(i)
    i = paramClose
    decl.inheritStart = Int32(unit.ranges.count)
    if unit.isToken(i, "implements") {
      i += 1
      while let end = unit.daTypeEnd(i, limit: limit), end > i {
        unit.ranges.append((Int32(i), Int32(end)))
        i = end
        guard unit.isByte(i, 0x2C) else { break }
        i += 1
      }
    }
    decl.inheritCount = Int32(unit.ranges.count) - decl.inheritStart
    var close = i
    if unit.isByte(i, 0x7B) {
      close = unit.skipBalanced(i) - 1
      decl.bodyOpen = Int32(i)
      decl.bodyClose = Int32(close)
    }
    decl.end = Int32(close + 1)
    let index = add(decl)
    // The representation: a final field, and the primary constructor's one parameter.
    var k = unit.daSkipMetadata(open + 1, limit: paramClose - 1)
    if unit.isToken(k, "final") { k += 1 }
    if let typeEnd = unit.daTypeEnd(k, limit: paramClose - 1), unit.daIsName(typeEnd) {
      var field = newDecl(.variable, nameToken: typeEnd, first: k, parent: index)
      field.typeStart = Int32(k)
      field.typeEnd = Int32(typeEnd)
      field.end = Int32(typeEnd + 1)
      add(field)
    }
    var primary = newDecl(.initializer, nameToken: constructorName >= 0 ? constructorName : nameToken, first: nameToken, parent: index)
    if constructorName < 0 { primary.name = DartWord.newWord }
    parameters(open: open, close: paramClose - 1, into: &primary)
    primary.end = Int32(paramClose)
    add(primary)
    if decl.bodyOpen >= 0 { members(Int(decl.bodyOpen) + 1, close: close, owner: index, className: unit.hash(nameToken)) }
    return close + 1
  }

  /// `typedef Name<T> = Type;`, `typedef R Name<T>(params);` (the second's type range covers it all, its name inside).
  private mutating func typedefDeclaration(_ keyword: Int, first: Int, parent: Int32, limit: Int) -> Int {
    let end = statementEnd(keyword, limit: limit)
    var i = keyword + 1
    if unit.daIsName(i), unit.isToken(i + 1, "=") || unit.startsWith(i + 1, 0x3C) && unit.tokens[i + 1].kind == .punctuation {
      var decl = newDecl(.typeAlias, nameToken: i, first: first, parent: parent)
      i = typeParameters(i + 1, into: &decl, limit: limit)
      if unit.isToken(i, "="), let typeEnd = unit.daTypeEnd(i + 1, limit: limit) {
        decl.typeStart = Int32(i + 1)
        decl.typeEnd = Int32(typeEnd)
        decl.end = Int32(end)
        add(decl)
        return end
      }
    }
    // The old form: a return type (maybe none), the name, parameters.
    i = keyword + 1
    var nameToken = -1
    if let typeEnd = unit.daTypeEnd(i, limit: limit), unit.daIsName(typeEnd), !unit.isByte(i + 1, 0x28) {
      nameToken = typeEnd
    } else if unit.daIsName(i) {
      nameToken = i
    }
    guard nameToken >= 0 else { return end }
    var decl = newDecl(.typeAlias, nameToken: nameToken, first: first, parent: parent)
    let afterGenerics = typeParameters(nameToken + 1, into: &decl, limit: limit)
    if unit.isByte(afterGenerics, 0x28) {
      decl.typeStart = Int32(keyword + 1)
      decl.typeEnd = Int32(unit.skipBalanced(afterGenerics))
      parameters(open: afterGenerics, close: unit.skipBalanced(afterGenerics) - 1, into: &decl)
    }
    decl.end = Int32(end)
    add(decl)
    return end
  }

  /// Type parameters `<T extends A, U>` at `i`, if any: the token after them.
  private mutating func typeParameters(_ i: Int, into decl: inout Decl, limit: Int) -> Int {
    guard i < limit, unit.tokens[i].kind == .punctuation, unit.startsWith(i, 0x3C), let end = unit.daTypeArgumentsEnd(i, limit: limit) else { return i }
    decl.genericStart = Int32(unit.generics.count)
    var k = i + 1
    var expectsName = true
    var depth = 0
    while k < end - 1 || (k == end - 1 && unit.tokens[k].kind != .punctuation) {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.tokens[k].kind == .punctuation {
        for b in 0..<unit.tokens[k].length {
          let byte = unit.source.text[unit.tokens[k].start + b]
          if byte == 0x3C { depth += 1 } else if byte == 0x3E { depth -= 1 } else if byte == 0x2C, depth == 0 { expectsName = true }
        }
      } else if depth == 0, expectsName, unit.daIsName(k) {
        k = unit.daSkipMetadata(k, limit: end)
        if unit.daIsName(k) {
          unit.generics.append(Generic(name: unit.hash(k), token: Int32(k)))
          decl.genericCount += 1
        }
        expectsName = false
      } else if unit.isByte(k, 0x40) {
        k = unit.daSkipMetadata(k, limit: end)
        continue
      }
      k += 1
    }
    return end
  }

  // MARK: Members

  /// A function or method from its name (or `operator`): type parameters, parameters, body.
  private mutating func function(_ nameAt: Int, typeStart: Int, typeEnd: Int, first: Int, parent: Int32, limit: Int, mods: Modifiers) -> Int {
    var nameToken = nameAt
    var operatorName: Name?
    var i = nameAt + 1
    if unit.isToken(nameAt, "operator") {
      // `operator ==`, `operator []`, `operator []=`, `operator -` (unary when it has no parameter), `operator ~/`.
      nameToken = nameAt + 1
      guard nameToken < limit else { return nameAt + 1 }
      var text = ""
      var k = nameToken
      if unit.isByte(k, 0x5B), unit.isByte(k + 1, 0x5D) {
        text = "[]"
        k += 2
        if unit.isToken(k, "=") {
          text = "[]="
          k += 1
        }
      } else if unit.tokens[k].kind == .punctuation {
        text = unit.string(k)
        k += 1
      } else {
        return nameAt + 1
      }
      i = k
      if text == "-", unit.isByte(i, 0x28), unit.isByte(i + 1, 0x29) { text = "unary-" }
      operatorName = name(text)
    }
    var decl = newDecl(.function, nameToken: nameToken, first: first, parent: parent)
    if let operatorName {
      decl.name = operatorName
      decl.access = .isPublic
    }
    decl.isStatic = mods.isStatic
    decl.typeStart = Int32(typeStart)
    decl.typeEnd = Int32(typeEnd)
    i = typeParameters(i, into: &decl, limit: limit)
    guard unit.isByte(i, 0x28) else { return nameAt + 1 }
    let close = unit.skipBalanced(i)
    parameters(open: i, close: close - 1, into: &decl)
    i = close
    return body(from: i, decl: &decl, limit: limit)
  }

  /// `get x`, `set x(v)` from `get`/`set`.
  private mutating func accessor(_ keyword: Int, typeStart: Int, typeEnd: Int, first: Int, parent: Int32, limit: Int, mods: Modifiers) -> Int {
    let nameToken = keyword + 1
    var decl = newDecl(.variable, nameToken: nameToken, first: first, parent: parent)
    decl.isStatic = mods.isStatic
    decl.typeStart = Int32(typeStart)
    decl.typeEnd = Int32(typeEnd)
    var i = nameToken + 1
    if unit.isToken(keyword, "set") {
      decl.name = name(unit.string(nameToken) + "=")
      guard unit.isByte(i, 0x28) else { return keyword + 1 }
      let close = unit.skipBalanced(i)
      parameters(open: i, close: close - 1, into: &decl)
      i = close
    }
    return body(from: i, decl: &decl, limit: limit)
  }

  /// A constructor from its class's name: `C(…)`, `C.name(…)`, with an initializer list or a redirection.
  private mutating func constructor(_ classToken: Int, first: Int, parent: Int32, limit: Int, mods: Modifiers) -> Int {
    var nameToken = classToken
    var i = classToken + 1
    var constructorName = DartWord.newWord
    if unit.isByte(i, 0x2E) {
      nameToken = i + 1
      constructorName = unit.hash(nameToken)
      i += 2
    }
    var decl = newDecl(.initializer, nameToken: nameToken, first: first, parent: parent)
    decl.name = constructorName
    if nameToken == classToken { decl.access = .isPublic }
    decl.isStatic = mods.isFactory
    guard unit.isByte(i, 0x28) else { return classToken + 1 }
    let close = unit.skipBalanced(i)
    parameters(open: i, close: close - 1, into: &decl)
    i = close
    if unit.isByte(i, 0x3A) {
      // The initializer list, up to the body.
      let start = i + 1
      var k = start
      while k < limit, !unit.isByte(k, 0x7B), !unit.isByte(k, 0x3B), !unit.isToken(k, "=>") {
        k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
      }
      // A `{` inside the list belongs to a closure or a literal; the body's `{` follows a `)` or a name.
      decl.initStart = Int32(start)
      decl.initEnd = Int32(k)
      bodies.append((start, k))
      i = k
    } else if unit.isToken(i, "=") {
      // A redirecting factory: `= Other.name;`.
      decl.initStart = Int32(i + 1)
      let end = statementEnd(i, limit: limit)
      decl.initEnd = Int32(end - 1)
      decl.end = Int32(end)
      add(decl)
      return end
    }
    return body(from: i, decl: &decl, limit: limit)
  }

  /// The body after a signature: `async`/`async*`/`sync*`, then `{…}`, `=> …;` or `;`. Adds the declaration.
  private mutating func body(from: Int, decl: inout Decl, limit: Int) -> Int {
    var i = from
    if unit.isToken(i, "async") || unit.isToken(i, "sync") {
      i += 1
      if unit.isByte(i, 0x2A) { i += 1 }
    }
    if unit.isByte(i, 0x7B) {
      let close = unit.skipBalanced(i)
      decl.bodyOpen = Int32(i)
      decl.bodyClose = Int32(close - 1)
      bodies.append((i, close))
      decl.end = Int32(close)
      add(decl)
      return close
    }
    if unit.isToken(i, "=>") {
      let end = arrowEnd(i + 1, limit: limit)
      decl.bodyOpen = Int32(i)
      decl.bodyClose = Int32(end)
      bodies.append((i, end))
      decl.end = Int32(min(limit, end + 1))
      add(decl)
      return min(limit, end + 1)
    }
    // No body: abstract, external, or a native declaration.
    var k = i
    while k < limit, !unit.isByte(k, 0x3B), !unit.isByte(k, 0x7D) {
      if unit.tokens[k].kind == .open { k = unit.skipBalanced(k) } else { k += 1 }
      if k - i > 40 { break }
    }
    decl.end = Int32(min(limit, k + 1))
    add(decl)
    return Int(decl.end)
  }

  /// An arrow body's `;`: the end of its expression at depth 0.
  func arrowEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.isByte(i, 0x3B) || unit.tokens[i].kind == .close { return i }
      i += 1
    }
    return limit
  }

  /// `T a = 1, b;`, `var a`, `final a = …`: one `variable` per name.
  private mutating func variables(_ nameAt: Int, typeStart: Int, typeEnd: Int, first: Int, parent: Int32, limit: Int, mods: Modifiers) -> Int {
    var i = nameAt
    while i < limit, unit.daIsName(i) {
      var decl = newDecl(.variable, nameToken: i, first: first, parent: parent)
      decl.isStatic = mods.isStatic || parent < 0
      decl.typeStart = Int32(typeStart)
      decl.typeEnd = Int32(typeEnd)
      var k = i + 1
      if unit.isToken(k, "=") {
        let end = unit.daExpressionEnd(k + 1, limit: limit)
        decl.initStart = Int32(k + 1)
        decl.initEnd = Int32(end)
        // An initializer others can see only when the type is inferred from it.
        if typeStart >= 0 { bodies.append((k + 1, end)) }
        k = end
      }
      decl.end = Int32(k)
      add(decl)
      i = k
      guard unit.isByte(i, 0x2C) else { break }
      i += 1
    }
    if unit.isByte(i, 0x3B) { i += 1 }
    return max(i, nameAt + 1)
  }

  /// Parameters between `open` and `close` (the parentheses): positional, `[optional]`, `{named}`.
  mutating func parameters(open: Int, close: Int, into decl: inout Decl) {
    decl.paramStart = Int32(unit.params.count)
    decl.paramCount = 0
    var i = open + 1
    var group = 0  // 0 positional, 1 optional positional, 2 named
    while i < close {
      if unit.isByte(i, 0x5B) {
        group = 1
        i += 1
        continue
      }
      if unit.isByte(i, 0x7B) {
        group = 2
        i += 1
        continue
      }
      if unit.isByte(i, 0x5D) || unit.isByte(i, 0x7D) || unit.isByte(i, 0x2C) {
        i += 1
        continue
      }
      // One parameter, up to its `,` or the group's end.
      var end = i
      while end < close, !unit.isByte(end, 0x2C), !(unit.isByte(end, 0x5D) || unit.isByte(end, 0x7D)) || unit.tokens[end].kind != .close {
        // `Map<String, int> m`: the type arguments' commas aren't the parameters'.
        if unit.tokens[end].kind == .punctuation, unit.startsWith(end, 0x3C), let after = unit.daTypeArgumentsEnd(end, limit: close) {
          end = after
          continue
        }
        end = unit.tokens[end].kind == .open ? unit.skipBalanced(end) : end + 1
      }
      // A `]` or `}` closing the group: the bracket pairs with the group's opener, which `skipBalanced` didn't see.
      end = min(end, close)
      var k = unit.daSkipMetadata(i, limit: end)
      var isRequired = false
      while k < end, unit.isToken(k, "required") || unit.isToken(k, "covariant") || unit.isToken(k, "final") || unit.isToken(k, "const") || unit.isToken(k, "var") {
        if unit.isToken(k, "required") { isRequired = true }
        k += 1
      }
      var defaultAt = end
      var j = k
      while j < end {
        if unit.isToken(j, "=") || unit.isByte(j, 0x3A) {
          defaultAt = j
          break
        }
        j = unit.tokens[j].kind == .open ? unit.skipBalanced(j) : j + 1
      }
      var nameToken = -1
      var typeStart = -1
      var typeEnd = -1
      if unit.isToken(k, "this") || unit.isToken(k, "super"), unit.isByte(k + 1, 0x2E), unit.daIsName(k + 2) {
        // `this.x`, `super.x`, `this.f(int a)`: typed by the field or the super parameter.
        nameToken = k + 2
      } else if let typeEnd2 = unit.daTypeEnd(k, limit: defaultAt), unit.daIsName(typeEnd2), typeEnd2 < defaultAt {
        if (unit.isToken(typeEnd2 - 1, "this") || unit.isToken(typeEnd2 - 1, "super")) {
          nameToken = typeEnd2
        } else {
          nameToken = typeEnd2
          typeStart = k
          typeEnd = typeEnd2
          // `void f(int x)`: a function-typed parameter, its type through its parameters.
          if unit.isByte(nameToken + 1, 0x28) || unit.startsWith(nameToken + 1, 0x3C) {
            typeEnd = defaultAt
          }
        }
      } else if unit.isToken(k + 1, "this") || unit.isToken(k + 1, "super"), unit.isByte(k + 2, 0x2E), unit.daIsName(k + 3) {
        // `int this.x`.
        nameToken = k + 3
        typeStart = k
        typeEnd = k + 1
      } else if unit.daIsName(k) {
        nameToken = k
        if unit.isByte(k + 1, 0x28) {
          // `f(int x)`: a function-typed parameter without a return type.
          typeStart = k
          typeEnd = defaultAt
        }
      }
      if defaultAt < end { bodies.append((defaultAt + 1, end)) }
      if nameToken >= 0 {
        let word = unit.hash(nameToken)
        unit.params.append(
          Param(
            label: group == 2 ? word : 0, local: word, nameToken: Int32(nameToken), typeStart: Int32(typeStart), typeEnd: Int32(typeEnd),
            hasDefault: group == 1 || group == 2 && !isRequired, variadic: false))
        decl.paramCount += 1
      }
      i = end
    }
  }
}
