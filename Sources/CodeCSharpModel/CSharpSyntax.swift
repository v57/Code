import CodeModel
import CodeScan
import Foundation

/// C#'s reading of a file into the core's tables:
///
/// - `namespace A.B` (with a block, or file-scoped to the file's end) is a `namespace` declaration named by the dotted
///   name as written, at its last word; what's inside is its children.
/// - `class` and `record` are `classType`s, `struct` and `record struct` `structure`s, `interface` a `protocolType`,
///   `enum` an `enumeration` (its members `enumCase`s), `delegate R D(…)` a `classType` with a return type and
///   parameters and no body. A base list's types are inherited ranges, `where` clauses the `where` range. A primary
///   constructor's parameters are the type's parameters; a record's are also its properties (`variable`s at them).
/// - Methods are `function`s (the return type their `type…` range; an extension method's first parameter has the label
///   `this`), constructors `initializer`s named as their type, `~T()` a `deinitializer`, operators and conversions
///   nameless `function`s, properties, fields, constants and events `variable`s (`isStatic` for `static` and `const`; a
///   property's accessors or `=> e` are its body, from the `{` or `=>`), indexers `subscriptDecl`s named `this`.
/// - Top-level statements are one nameless `function` from the first statement to the last, its body starting at
///   `bodyOpen` itself. Local functions in any body come after every other declaration, `isLocal`, so that an edit to a
///   body moves none of the others.
/// - `using X;`, `using static X;`, `using A = X;` and their `global` forms are `Import`s whose module is the target as
///   written (`isExported` for `global`, `alias` for an alias); the model reads the rest from the tokens at
///   `Import.token`.
package final class CSharpSyntax: LanguageSyntax {
  package let profile = LexProfile.profile(forLanguage: "csharp")!
  package let parametersHaveLabels = false
  /// The preprocessor symbols a file is read with (its project's), by path.
  let symbols: (String) -> Set<String>

  package init(symbols: @escaping (String) -> Set<String> = { _ in CSharpWord.defaultSymbols }) {
    self.symbols = symbols
  }

  package func parse(_ unit: CodeModel.Unit) -> UInt64 {
    var parser = CSharpParser(unit: unit)
    parser.parseFile()
    return parser.shape
  }

  /// Comments and the directives that don't choose code (`#region`, `#nullable`, `#pragma`) are dropped; `@word` (a
  /// verbatim identifier) is the word as an identifier.
  package func codeTokens(_ source: SourceFile) -> [Token] {
    var kept = [Token]()
    kept.reserveCapacity(source.tokens.count)
    let text = source.text
    var skipNext = false
    for (index, token) in source.tokens.enumerated() {
      if skipNext {
        skipNext = false
        continue
      }
      switch token.kind {
      case .comment, .docComment:
        continue
      case .directive:
        if CSharpSyntax.directiveRole(text, token) == nil { continue }
        kept.append(token)
      case .punctuation:
        if token.length == 1, text[token.start] == 0x40, index + 1 < source.tokens.count {
          let next = source.tokens[index + 1]
          if next.start == token.end, next.kind == .keyword || next.kind == .declarationKeyword || next.kind == .identifier {
            kept.append(Token(kind: .identifier, start: next.start, end: next.end))
            skipNext = true
            continue
          }
        }
        kept.append(token)
      default:
        kept.append(token)
      }
    }
    return kept
  }

  enum Directive { case ifDirective, elif, elseDirective, endif, define, undef }

  /// What a directive token (the whole line) is, if it's one the model keeps.
  static func directiveRole(_ text: UnsafePointer<UInt8>, _ token: Token) -> Directive? {
    var i = token.start + 1
    while i < token.end, text[i] == 0x20 || text[i] == 0x09 { i += 1 }
    var j = i
    while j < token.end, (text[j] >= 0x61 && text[j] <= 0x7A) { j += 1 }
    let word = String(decoding: UnsafeBufferPointer(start: text + i, count: j - i), as: UTF8.self)
    switch word {
    case "if": return .ifDirective
    case "elif": return .elif
    case "else": return .elseDirective
    case "endif": return .endif
    case "define": return .define
    case "undef": return .undef
    default: return nil
    }
  }

  package func conditional(_ unit: CodeModel.Unit, _ i: Int) -> ConditionalDirective {
    guard i >= 0, i < unit.tokens.count, unit.tokens[i].kind == .directive else { return .none }
    switch CSharpSyntax.directiveRole(unit.source.text, unit.tokens[i]) {
    case .ifDirective: return .opens
    case .elif: return .alternative
    case .elseDirective: return .otherwise
    case .endif: return .closes
    default: return .none
    }
  }

  /// The condition is the directive token's own text (before `i`, which isn't moved): `!`, `&&`, `||`, `==`, `!=`,
  /// parentheses, `true`, `false` and symbols, defined by the project or by a `#define` above in the file.
  package func evaluateCondition(_ unit: CodeModel.Unit, _ i: inout Int) -> Bool {
    let at = i - 1
    guard at >= 0, at < unit.tokens.count, unit.tokens[at].kind == .directive else { return true }
    let token = unit.tokens[at]
    let line = unit.source.string(token)
    guard let space = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return false }
    var defined = symbols(unit.path)
    // `#define` and `#undef` above, in file order.
    for k in 0..<at where unit.tokens[k].kind == .directive {
      let role = CSharpSyntax.directiveRole(unit.source.text, unit.tokens[k])
      guard role == .define || role == .undef else { continue }
      let words = unit.source.string(unit.tokens[k]).split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard words.count > 1 else { continue }
      let symbol = String(words[1])
      if role == .define { defined.insert(symbol) } else { defined.remove(symbol) }
    }
    var expression = CSharpCondition(text: Array(line[space...].utf8), defined: defined)
    return expression.evaluate()
  }
}

/// A preprocessor condition read from its text.
struct CSharpCondition {
  let text: [UInt8]
  let defined: Set<String>
  var at = 0

  init(text: [UInt8], defined: Set<String>) {
    // A trailing `// comment` is no part of it.
    var bytes = text
    if let slash = (0..<max(0, bytes.count - 1)).first(where: { bytes[$0] == 0x2F && bytes[$0 + 1] == 0x2F }) { bytes = Array(bytes[..<slash]) }
    self.text = bytes
    self.defined = defined
  }

  mutating func evaluate() -> Bool { or() }

  private mutating func space() { while at < text.count, text[at] == 0x20 || text[at] == 0x09 || text[at] == 0x0D { at += 1 } }

  private mutating func take(_ a: UInt8, _ b: UInt8) -> Bool {
    space()
    if at + 1 < text.count, text[at] == a, text[at + 1] == b {
      at += 2
      return true
    }
    return false
  }

  private mutating func or() -> Bool {
    var value = and()
    while take(0x7C, 0x7C) { value = and() || value }
    return value
  }

  private mutating func and() -> Bool {
    var value = equality()
    while take(0x26, 0x26) { value = equality() && value }
    return value
  }

  private mutating func equality() -> Bool {
    var value = unary()
    while true {
      if take(0x3D, 0x3D) { value = value == unary() } else if take(0x21, 0x3D) { value = value != unary() } else { return value }
    }
  }

  private mutating func unary() -> Bool {
    space()
    guard at < text.count else { return false }
    if text[at] == 0x21 {
      at += 1
      return !unary()
    }
    if text[at] == 0x28 {
      at += 1
      let value = or()
      space()
      if at < text.count, text[at] == 0x29 { at += 1 }
      return value
    }
    var end = at
    while end < text.count, text[end] == 0x5F || (text[end] | 0x20 >= 0x61 && text[end] | 0x20 <= 0x7A) || (text[end] >= 0x30 && text[end] <= 0x39) { end += 1 }
    guard end > at else {
      at = text.count
      return false
    }
    let word = String(decoding: text[at..<end], as: UTF8.self)
    at = end
    if word == "true" { return true }
    if word == "false" { return false }
    return defined.contains(word)
  }
}

enum CSharpWord {
  static let thisWord = name("this"), baseWord = name("base"), valueWord = name("value"), varWord = name("var")
  static let topLevel = name("<top-level statements>"), operatorWord = name("operator"), global = name("global")
  static let object = name("Object"), string = name("String"), system = "System"
  static let voidWord = name("void"), dynamicWord = name("dynamic"), nullableWord = name("Nullable"), enumerableInterface = name("IEnumerable")
  static let expressionWord = name("Expression"), delegateWord = name("Delegate"), taskWord = name("Task")
  /// The generic interfaces an array `T[]` implements.
  static let arrayInterfaces: Set<Name> = Set(["IEnumerable", "ICollection", "IList", "IReadOnlyList", "IReadOnlyCollection"].map { name($0) })
  /// The numeric types in the order binary operators promote to (C# 12.4.7).
  static let numericOrder = ["SByte", "Byte", "Int16", "UInt16", "Char", "Int32", "UInt32", "Int64", "UInt64", "Single", "Double", "Decimal"]
  /// C#'s implicit numeric conversions (10.2.3): each type and the types it widens to.
  static let numericWidening: [String: Set<String>] = [
    "SByte": ["Int16", "Int32", "Int64", "Single", "Double", "Decimal", "IntPtr"],
    "Byte": ["Int16", "UInt16", "Int32", "UInt32", "Int64", "UInt64", "Single", "Double", "Decimal", "IntPtr", "UIntPtr"],
    "Int16": ["Int32", "Int64", "Single", "Double", "Decimal", "IntPtr"],
    "UInt16": ["Int32", "UInt32", "Int64", "UInt64", "Single", "Double", "Decimal", "IntPtr", "UIntPtr"],
    "Int32": ["Int64", "Single", "Double", "Decimal", "IntPtr"],
    "UInt32": ["Int64", "UInt64", "Single", "Double", "Decimal", "UIntPtr"],
    "Int64": ["Single", "Double", "Decimal"],
    "UInt64": ["Single", "Double", "Decimal"],
    "Char": ["UInt16", "Int32", "UInt32", "Int64", "UInt64", "Single", "Double", "Decimal", "IntPtr", "UIntPtr"],
    "Single": ["Double"],
    "Double": [],
    "Decimal": [],
    "IntPtr": [],
    "UIntPtr": [],
  ]
  /// The words that start a query clause, where the previous clause's expression ends.
  static let queryClauses: [Name] = ["from", "where", "select", "group", "orderby", "join", "let", "into", "on", "equals", "by", "ascending", "descending"].map { name($0) }
  static let defaultSymbols: Set<String> = ["DEBUG", "TRACE", "NET", "NETCOREAPP"]
  /// The keywords that name a type, and the type they name in `System`.
  static let predefined: [Name: String] = [
    name("int"): "Int32", name("uint"): "UInt32", name("long"): "Int64", name("ulong"): "UInt64", name("short"): "Int16",
    name("ushort"): "UInt16", name("byte"): "Byte", name("sbyte"): "SByte", name("char"): "Char", name("bool"): "Boolean",
    name("float"): "Single", name("double"): "Double", name("decimal"): "Decimal", name("string"): "String",
    name("object"): "Object", name("nint"): "IntPtr", name("nuint"): "UIntPtr", name("void"): "Void",
  ]
  /// The keyword a `System` type is written as: `Int32` → `int`.
  static let keywordOf: [String: String] = [
    "Int32": "int", "UInt32": "uint", "Int64": "long", "UInt64": "ulong", "Int16": "short", "UInt16": "ushort", "Byte": "byte", "SByte": "sbyte",
    "Char": "char", "Boolean": "bool", "Single": "float", "Double": "double", "Decimal": "decimal", "String": "string", "Object": "object",
  ]
  static let predefinedText: Set<String> = [
    "int", "uint", "long", "ulong", "short", "ushort", "byte", "sbyte", "char", "bool", "float", "double", "decimal", "string", "object",
    "void", "nint", "nuint", "dynamic",
  ]
  /// Words the lexer calls keywords that C# lets a program use as names (contextual keywords).
  static let contextual: Set<Name> = Set(
    [
      "var", "dynamic", "get", "set", "value", "record", "init", "file", "required", "async", "await", "nameof", "add", "remove", "partial",
      "when", "yield", "global", "select", "from", "where", "let", "join", "into", "orderby", "group", "by", "on", "equals", "ascending",
      "descending", "managed", "unmanaged", "notnull", "args", "scoped", "with", "and", "or", "not", "field",
    ].map { name($0) })
  static let modifiers: Set<Name> = Set(
    [
      "public", "private", "protected", "internal", "static", "abstract", "sealed", "virtual", "override", "readonly", "const", "volatile",
      "unsafe", "extern", "new", "partial", "async", "required", "file", "fixed", "ref", "scoped",
    ].map { name($0) })
  static let typeKeywords: Set<Name> = Set(["class", "struct", "interface", "enum", "record", "delegate"].map { name($0) })
}

extension Unit {
  /// A name: an identifier, or a contextual keyword (`var`, `value`, `get`, `record`) used as one.
  func csIsName(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    if tokens[i].kind == .identifier { return true }
    return (tokens[i].kind == .keyword || tokens[i].kind == .declarationKeyword) && CSharpWord.contextual.contains(hash(i))
  }

  /// A keyword naming a type: `int`, `string`, `object`.
  func csIsPredefined(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count, tokens[i].kind == .keyword || tokens[i].kind == .declarationKeyword || tokens[i].kind == .identifier else { return false }
    return CSharpWord.predefined[hash(i)] != nil || isToken(i, "dynamic")
  }

  /// `.`, `?.` or `!.`: a member access.
  func csIsDot(_ i: Int) -> Bool { isByte(i, 0x2E) || isToken(i, "?.") || isToken(i, "!.") }

  /// The end of type arguments `<…>` starting at token `i` (the token after the closing `>`, which may hold a `?`), when
  /// what's inside reads as types; nil otherwise (`a < b`).
  func csTypeArgumentsEnd(_ i: Int, limit: Int? = nil) -> Int? {
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
        if isToken(k, "::") { break }
        guard punctuation(k, madeOf: "<>?*,.") else { return nil }
        for b in 0..<token.length {
          let byte = source.text[token.start + b]
          if byte == 0x3C { depth += 1 } else if byte == 0x3E {
            depth -= 1
            if depth == 0 {
              var closesOuter = false
              for rest in (b + 1)..<max(b + 1, token.length) {
                let byte = source.text[token.start + rest]
                if byte == 0x3E { closesOuter = true } else if byte != 0x3F { return nil }
              }
              // `>>` closes an enclosing list too (`Func<Task<int>>`): only when one is open before this one.
              if closesOuter, !csEnclosingTypeArguments(i, closedBy: k) { return nil }
              return k + 1
            }
          }
        }
      case .identifier: break
      case .keyword, .declarationKeyword:
        guard csIsName(k) || csIsPredefined(k) || isToken(k, "in") || isToken(k, "out") else { return nil }
      case .open:
        if isByte(k, 0x28) || isByte(k, 0x5B) {
          k = skipBalanced(k)
          continue
        }
        return nil
      default:
        return nil
      }
      k += 1
    }
    return nil
  }

  /// Whether type arguments `<…` open before `i` and close in the token `close` with it.
  private func csEnclosingTypeArguments(_ i: Int, closedBy close: Int) -> Bool {
    var k = i - 1
    var budget = 120
    while k > 0, budget > 0 {
      budget -= 1
      if tokens[k].kind == .punctuation, startsWith(k, 0x3C), csIsName(k - 1) || csIsPredefined(k - 1) {
        if csTypeArgumentsEnd(k) == close + 1 { return true }
      }
      if tokens[k].kind == .close, let open = matchingOpen(k) {
        k = open - 1
        continue
      }
      if tokens[k].kind == .open || isByte(k, 0x3B) { return false }
      k -= 1
    }
    return false
  }

  /// The end of a type written from `i`: `global::`, a predefined type or a qualified name with type arguments, a tuple
  /// `(A a, B)`, then `?`, `*` and array ranks; nil when no type starts there. `nullable: false` leaves a `?` out (a
  /// conditional's).
  func csTypeEnd(_ from: Int, limit: Int? = nil, nullable: Bool = true) -> Int? {
    let end = limit ?? tokens.count
    var i = from
    guard i < end else { return nil }
    if isByte(i, 0x28) {
      // A tuple type: two or more elements, each a type with an optional name.
      let close = skipBalanced(i)
      guard close <= end else { return nil }
      var k = i + 1
      var elements = 0
      while k < close - 1 {
        guard let typeEnd = csTypeEnd(k, limit: close - 1) else { return nil }
        k = typeEnd
        if csIsName(k) { k += 1 }
        elements += 1
        if isByte(k, 0x2C) { k += 1 } else { break }
      }
      guard elements >= 2, k == close - 1 else { return nil }
      i = close
    } else if csIsPredefined(i) {
      i += 1
    } else if csIsName(i) {
      if isToken(i + 1, "::") { i += 2 }
      guard csIsName(i) else { return nil }
      i += 1
      while i < end {
        if tokens[i].kind == .punctuation, startsWith(i, 0x3C), let after = csTypeArgumentsEnd(i, limit: end) {
          i = after
          if isToken(i - 1, ">?") || isToken(i - 1, ">>?") { return suffixes(i, end, nullable) }
          continue
        }
        if isByte(i, 0x2E), csIsName(i + 1), i + 1 < end {
          i += 2
          continue
        }
        break
      }
    } else {
      return nil
    }
    return suffixes(i, end, nullable)
  }

  private func suffixes(_ from: Int, _ end: Int, _ nullable: Bool) -> Int {
    var i = from
    while i < end {
      if nullable, isByte(i, 0x3F), !isByte(i + 1, 0x3F), !isByte(i + 1, 0x2E) {
        // `T? x`, `T?[]`, `T?)`, `T?>`: a nullable type, not a conditional.
        if csIsName(i + 1) || isByte(i + 1, 0x5B) || isByte(i + 1, 0x29) || isByte(i + 1, 0x2C) || startsWith(i + 1, 0x3E) || isByte(i + 1, 0x3B) || isToken(i + 1, "=") {
          i += 1
          continue
        }
        break
      }
      if isByte(i, 0x2A) || isToken(i, "**") {
        i += 1
        continue
      }
      if isByte(i, 0x5B) {
        // `[]`, `[,]`: a rank, not an index.
        let close = skipBalanced(i)
        var k = i + 1
        while k < close - 1, isByte(k, 0x2C) { k += 1 }
        guard k == close - 1 else { break }
        i = close
        continue
      }
      break
    }
    return i
  }

  /// Past attribute sections: `[A]`, `[A(1), B]`, `[assembly: A]`.
  func csSkipAttributes(_ from: Int, limit: Int? = nil) -> Int {
    let end = limit ?? tokens.count
    var i = from
    while i < end, isByte(i, 0x5B) {
      i = skipBalanced(i)
    }
    return i
  }
}

struct CSharpParser {
  let unit: Unit
  var shape: UInt64 = 14_695_981_039_346_656_037
  /// Token ranges whose text doesn't change what other files see: bodies and initializers.
  private var bodies: [(Int, Int)] = []
  private var count: Int { unit.tokens.count }

  init(unit: Unit) { self.unit = unit }

  mutating func parseFile() {
    namespaceMembers(from: 0, to: count, parent: -1, isFile: true)
    let nonLocal = unit.decls.count
    for index in 0..<nonLocal {
      let decl = unit.decls[index]
      if decl.bodyOpen >= 0, !decl.kind.isNominal, decl.kind != .namespace, decl.kind != .enumCase {
        let from = decl.name == CSharpWord.topLevel ? Int(decl.bodyOpen) : Int(decl.bodyOpen) + 1
        localFunctions(from: from, to: Int(decl.bodyClose), parent: Int32(index))
      }
      if decl.initStart >= 0 { localFunctions(from: Int(decl.initStart), to: Int(decl.initEnd), parent: Int32(index)) }
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

  // MARK: Namespaces and usings

  /// A compilation unit's or a namespace's members: usings, namespaces, types, delegates, and (in a file) top-level
  /// statements.
  private mutating func namespaceMembers(from: Int, to: Int, parent: Int32, isFile: Bool) {
    var i = from
    var statementsStart = -1
    var statementsEnd = -1
    while i < to {
      let start = i
      if unit.tokens[i].kind == .directive {
        i = max(unit.takeDirective(i), i + 1)
        continue
      }
      if unit.isByte(i, 0x3B) {
        i += 1
        continue
      }
      if unit.isToken(i, "extern"), unit.isToken(i + 1, "alias") {
        while i < to, !unit.isByte(i, 0x3B) { i += 1 }
        i += 1
        continue
      }
      if unit.isToken(i, "using") || unit.isToken(i, "global") && unit.isToken(i + 1, "using") {
        if let next = usingDirective(i, limit: to) {
          i = next
          continue
        }
      }
      // `[assembly: X]` and attributes before a type.
      let afterAttributes = unit.csSkipAttributes(i, limit: to)
      if unit.isToken(afterAttributes, "namespace") {
        i = namespaceDeclaration(afterAttributes, parent: parent, limit: to)
        continue
      }
      if afterAttributes > i, afterAttributes >= to || isTypeStart(afterAttributes, limit: to) == false && !unit.isByte(afterAttributes, 0x28) && statementsStart < 0 {
        i = afterAttributes
        continue
      }
      if isTypeStart(i, limit: to) {
        let next = typeDeclaration(i, parent: parent, limit: to)
        if next > start {
          i = next
          continue
        }
      }
      // A top-level statement (or something not understood): to the statement's end.
      if isFile, parent < 0 {
        if statementsStart < 0 { statementsStart = i }
        i = statementEnd(i, limit: to)
        statementsEnd = i
        continue
      }
      i = start + 1
    }
    if statementsStart >= 0 {
      var decl = Decl(kind: .function, name: CSharpWord.topLevel, nameToken: Int32(statementsStart), first: Int32(statementsStart), parent: parent)
      decl.isStatic = true
      decl.bodyOpen = Int32(statementsStart)
      decl.bodyClose = Int32(statementsEnd)
      decl.end = Int32(statementsEnd)
      bodies.append((statementsStart, statementsEnd))
      unit.decls.append(decl)
    }
  }

  /// The token after a statement from `i`: past its `;`, or past a block and what continues it (`else`, `catch`).
  private func statementEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      if unit.isByte(i, 0x7B) {
        i = unit.skipBalanced(i)
        // `if (…) { } else …`, `try { } catch …`, `do { } while (…);`, a local function's body.
        if unit.isToken(i, "else") || unit.isToken(i, "catch") || unit.isToken(i, "finally") || unit.isToken(i, "while") {
          continue
        }
        // `var x = new T { … };` and lambdas: the statement goes on.
        if unit.isByte(i, 0x3B) || unit.isByte(i, 0x29) || unit.isByte(i, 0x2C) || unit.csIsDot(i) || unit.tokens.indices.contains(i) && unit.tokens[i].kind == .punctuation && !unit.isByte(i, 0x3B) {
          continue
        }
        return i
      }
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.isByte(i, 0x3B) { return i + 1 }
      i += 1
    }
    return limit
  }

  /// `using X;`, `using static X;`, `using A = X;`, `global using …;`: nil when it's a `using` statement.
  private mutating func usingDirective(_ at: Int, limit: Int) -> Int? {
    var i = at
    let isGlobal = unit.isToken(i, "global")
    if isGlobal { i += 1 }
    i += 1
    // `using (…)` and `using var x = …` are statements.
    if unit.isByte(i, 0x28) || unit.isToken(i, "var") || unit.isToken(i, "await") { return nil }
    if unit.isToken(i, "static") { i += 1 }
    if unit.isToken(i, "unsafe") { i += 1 }
    var alias: Name = 0
    var aliasToken: Int32 = -1
    if unit.csIsName(i), unit.isToken(i + 1, "=") {
      alias = unit.hash(i)
      aliasToken = Int32(i)
      i += 2
    }
    let targetStart = i
    var words: [String] = []
    while i < limit, !unit.isByte(i, 0x3B) {
      if unit.csIsName(i) || unit.csIsPredefined(i) {
        words.append(unit.string(i))
        i += 1
        if unit.isToken(i, "::") {
          words.removeLast()
          i += 1
          continue
        }
        if unit.isByte(i, 0x2E) {
          i += 1
          continue
        }
      }
      // Type arguments, a tuple or anything else: up to the `;`.
      while i < limit, !unit.isByte(i, 0x3B) { i = unit.tokens[i].kind == .open ? unit.skipBalanced(i) : i + 1 }
    }
    guard !words.isEmpty || alias != 0 else { return i + 1 }
    let target = words.joined(separator: ".")
    var item = Import(module: name(target), moduleName: target, isExported: isGlobal, isTestable: false)
    item.token = Int32(targetStart)
    item.alias = alias
    item.aliasToken = aliasToken
    unit.imports.append(item)
    return unit.isByte(i, 0x3B) ? i + 1 : i
  }

  /// `namespace A.B { … }` or `namespace A.B;` (to the end of the file).
  private mutating func namespaceDeclaration(_ at: Int, parent: Int32, limit: Int) -> Int {
    var i = at + 1
    var words: [String] = []
    var last = i
    while i < limit, unit.csIsName(i) {
      words.append(unit.string(i))
      last = i
      i += 1
      if unit.isByte(i, 0x2E) { i += 1 } else { break }
    }
    guard !words.isEmpty else { return at + 1 }
    var decl = Decl(kind: .namespace, name: name(words.joined(separator: ".")), nameToken: Int32(last), first: Int32(at), parent: parent)
    decl.access = .isPublic
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    if unit.isByte(i, 0x7B) {
      let close = unit.skipBalanced(i)
      unit.decls[Int(index)].bodyOpen = Int32(i)
      unit.decls[Int(index)].bodyClose = Int32(close - 1)
      unit.decls[Int(index)].end = Int32(close)
      namespaceMembers(from: i + 1, to: close - 1, parent: index, isFile: false)
      return close
    }
    // File-scoped.
    let start = unit.isByte(i, 0x3B) ? i + 1 : i
    unit.decls[Int(index)].end = Int32(limit)
    namespaceMembers(from: start, to: limit, parent: index, isFile: true)
    return limit
  }

  // MARK: Types

  /// Modifiers and attributes from `i`: where they end, and what they say.
  private func modifiers(_ from: Int, limit: Int) -> (end: Int, isStatic: Bool, access: Access, isConst: Bool) {
    var i = from
    var isStatic = false
    var access = Access.inherited
    var isConst = false
    var sawAccess = false
    while i < limit {
      if unit.isByte(i, 0x5B) {
        i = unit.skipBalanced(i)
        continue
      }
      guard modifierAt(i) else { break }
      if unit.isToken(i, "static") || unit.isToken(i, "const") { isStatic = true }
      if unit.isToken(i, "const") { isConst = true }
      if unit.isToken(i, "public") { access = .isPublic }
      if unit.isToken(i, "private"), !sawAccess { access = .isPrivate }
      if unit.isToken(i, "protected") { access = access == .package ? .package : .inherited }
      if unit.isToken(i, "internal") { access = access == .inherited && sawAccess ? .package : .package }
      if unit.isToken(i, "public") || unit.isToken(i, "private") || unit.isToken(i, "protected") || unit.isToken(i, "internal") { sawAccess = true }
      i += 1
    }
    if !sawAccess { access = .isPrivate }
    return (i, isStatic, access, isConst)
  }

  /// A modifier at `i`: one of C#'s, and not a name being declared or used (`partial` in `partial class`, not in
  /// `int partial;`).
  private func modifierAt(_ i: Int) -> Bool {
    guard i < count, unit.tokens[i].kind == .keyword || unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .declarationKeyword,
      CSharpWord.modifiers.contains(unit.hash(i))
    else { return false }
    if unit.tokens[i].kind == .identifier || unit.isToken(i, "async") || unit.isToken(i, "required") || unit.isToken(i, "file") {
      // A contextual one is a modifier only before more of a declaration.
      let next = i + 1
      if unit.isByte(next, 0x3B) || unit.isToken(next, "=") || unit.isByte(next, 0x28) || unit.isByte(next, 0x2C) || unit.csIsDot(next) || unit.isByte(next, 0x29) { return false }
    }
    // `new` as an expression: `new(…)`, `new T(…)` in a statement.
    if unit.isToken(i, "new"), unit.isByte(i + 1, 0x28) || unit.isByte(i + 1, 0x5B) { return false }
    // `ref` in `ref x` arguments isn't asked here.
    return true
  }

  /// Whether a type declaration starts at `i` (after attributes and modifiers).
  private func isTypeStart(_ i: Int, limit: Int) -> Bool {
    let mods = modifiers(i, limit: limit)
    return typeKeyword(mods.end) != nil
  }

  /// The keyword at `i` that starts a type declaration, and the kind it declares.
  private func typeKeyword(_ i: Int) -> (kind: DeclKind, name: Int)? {
    if unit.isToken(i, "class") { return unit.csIsName(i + 1) ? (.classType, i + 1) : nil }
    if unit.isToken(i, "struct") { return unit.csIsName(i + 1) ? (.structure, i + 1) : nil }
    if unit.isToken(i, "interface") { return unit.csIsName(i + 1) ? (.protocolType, i + 1) : nil }
    if unit.isToken(i, "enum") { return unit.csIsName(i + 1) ? (.enumeration, i + 1) : nil }
    if unit.isToken(i, "record") {
      if unit.isToken(i + 1, "struct") { return unit.csIsName(i + 2) ? (.structure, i + 2) : nil }
      if unit.isToken(i + 1, "class") { return unit.csIsName(i + 2) ? (.classType, i + 2) : nil }
      if unit.csIsName(i + 1), unit.isByte(i + 2, 0x28) || unit.startsWith(i + 2, 0x3C) || unit.isByte(i + 2, 0x7B) || unit.isByte(i + 2, 0x3A) || unit.isByte(i + 2, 0x3B) {
        return (.classType, i + 1)
      }
      return nil
    }
    if unit.isToken(i, "delegate"), !unit.isByte(i + 1, 0x28), !unit.isByte(i + 1, 0x7B), !unit.isByte(i + 1, 0x2A) {
      // `delegate R Name<T>(…);`: the name before the parameters.
      guard let typeEnd = unit.csTypeEnd(i + 1), unit.csIsName(typeEnd) else { return nil }
      return (.classType, typeEnd)
    }
    return nil
  }

  /// A type declaration at `i` (attributes and modifiers first); returns the token after it, or `i` when there's none.
  @discardableResult
  mutating func typeDeclaration(_ at: Int, parent: Int32, limit: Int, isLocal: Bool = false) -> Int {
    let mods = modifiers(at, limit: limit)
    var i = mods.end
    guard let (kind, nameToken) = typeKeyword(i) else { return at }
    let isDelegate = unit.isToken(i, "delegate")
    let isRecord = unit.isToken(i, "record")
    var decl = Decl(kind: kind, name: unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(at), parent: parent)
    decl.isLocal = isLocal
    decl.isStatic = true
    decl.access = mods.access
    if parent >= 0, unit.decls[Int(parent)].kind == .namespace || !mods.isStatic && mods.access == .isPrivate && parent < 0 {
      if mods.access == .isPrivate { decl.access = .package }
    }
    if parent < 0, mods.access == .isPrivate { decl.access = .package }
    if parent >= 0, unit.decls[Int(parent)].kind == .protocolType, mods.access == .isPrivate { decl.access = .isPublic }
    if isDelegate {
      decl.typeStart = Int32(i + 1)
      decl.typeEnd = Int32(nameToken)
    }
    i = nameToken + 1
    if unit.startsWith(i, 0x3C), unit.tokens[i].kind == .punctuation {
      i = typeParameters(i, into: &decl)
    }
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    // A primary constructor's parameters (a delegate's).
    if unit.isByte(i, 0x28) {
      let close = unit.skipBalanced(i)
      parameters(open: i, close: close - 1, into: &unit.decls[Int(index)])
      i = close
      if isRecord {
        let item = unit.decls[Int(index)]
        for p in 0..<Int(item.paramCount) {
          let param = unit.params[Int(item.paramStart) + p]
          var property = Decl(kind: .variable, name: param.local, nameToken: param.nameToken, first: param.typeStart, parent: index)
          property.typeStart = param.typeStart
          property.typeEnd = param.typeEnd
          property.end = param.nameToken + 1
          property.isLocal = isLocal
          property.access = .isPublic
          unit.decls.append(property)
        }
      }
    }
    // The base list: `: A, B<C>(args)`.
    unit.decls[Int(index)].inheritStart = Int32(unit.ranges.count)
    if unit.isByte(i, 0x3A), !isDelegate {
      i += 1
      while i < limit {
        guard let end = unit.csTypeEnd(i, limit: limit) else { break }
        unit.ranges.append((Int32(i), Int32(end)))
        unit.decls[Int(index)].inheritCount += 1
        i = end
        // A record's or primary constructor's base arguments.
        if unit.isByte(i, 0x28) {
          let close = unit.skipBalanced(i)
          bodies.append((i + 1, close - 1))
          unit.decls[Int(index)].initStart = Int32(i + 1)
          unit.decls[Int(index)].initEnd = Int32(close - 1)
          i = close
        }
        if unit.isByte(i, 0x2C) { i += 1 } else { break }
      }
    }
    if unit.isToken(i, "where") {
      unit.decls[Int(index)].whereStart = Int32(i)
      while i < limit, !unit.isByte(i, 0x7B), !unit.isByte(i, 0x3B) {
        i = unit.tokens[i].kind == .open ? unit.skipBalanced(i) : i + 1
      }
      unit.decls[Int(index)].whereEnd = Int32(i)
    }
    guard unit.isByte(i, 0x7B) else {
      if unit.isByte(i, 0x3B) { i += 1 }
      unit.decls[Int(index)].end = Int32(i)
      return i
    }
    let close = unit.skipBalanced(i)
    unit.decls[Int(index)].bodyOpen = Int32(i)
    unit.decls[Int(index)].bodyClose = Int32(close - 1)
    unit.decls[Int(index)].end = Int32(close)
    classBody(open: i, close: close - 1, owner: index, kind: kind, isLocal: isLocal)
    // `class A { };`
    return unit.isByte(close, 0x3B) ? close + 1 : close
  }

  /// `<T, in U, [A] out V>`: the names, as the decl's generics (constraints are read again when asked).
  private mutating func typeParameters(_ open: Int, into decl: inout Decl) -> Int {
    guard let end = unit.csTypeArgumentsEnd(open) else { return open + 1 }
    decl.genericStart = Int32(unit.generics.count)
    var i = open + 1
    while i < end - 1 {
      i = unit.csSkipAttributes(i, limit: end)
      if unit.isToken(i, "in") || unit.isToken(i, "out") { i += 1 }
      if unit.csIsName(i) {
        unit.generics.append(Generic(name: unit.hash(i), token: Int32(i)))
        decl.genericCount += 1
      }
      while i < end - 1, !unit.isByte(i, 0x2C) { i += 1 }
      i += 1
    }
    return end
  }

  /// A type's body: an enum's members, else each member as a child of `owner`.
  private mutating func classBody(open: Int, close: Int, owner: Int32, kind: DeclKind, isLocal: Bool) {
    var i = open + 1
    if kind == .enumeration {
      enumMembers(i, close: close, owner: owner, isLocal: isLocal)
      return
    }
    while i < close {
      let next = member(i, close: close, owner: owner, isLocal: isLocal)
      i = next > i ? next : i + 1
    }
  }

  /// `A, B = 1, [Attr] C`.
  private mutating func enumMembers(_ from: Int, close: Int, owner: Int32, isLocal: Bool) {
    var i = from
    while i < close {
      let at = i
      i = unit.csSkipAttributes(i, limit: close)
      while i < close, unit.tokens[i].kind == .directive { i = max(unit.takeDirective(i), i + 1) }
      guard unit.csIsName(i) else {
        i = at + 1
        continue
      }
      var member = Decl(kind: .enumCase, name: unit.hash(i), nameToken: Int32(i), first: Int32(at), parent: owner)
      member.isStatic = true
      member.isLocal = isLocal
      member.access = .isPublic
      i += 1
      if unit.isToken(i, "=") {
        let start = i + 1
        i = expressionEnd(start, limit: close)
        member.initStart = Int32(start)
        member.initEnd = Int32(i)
        bodies.append((start, i))
      }
      member.end = Int32(i)
      unit.decls.append(member)
      while i < close, !unit.isByte(i, 0x2C) { i += 1 }
      i += 1
    }
  }

  /// One member of a type's body; returns the token after it.
  private mutating func member(_ at: Int, close: Int, owner: Int32, isLocal: Bool) -> Int {
    if unit.tokens[at].kind == .directive { return max(unit.takeDirective(at), at + 1) }
    if unit.isByte(at, 0x3B) { return at + 1 }
    let mods = modifiers(at, limit: close)
    var i = mods.end
    guard i < close else { return close }
    let ownerDecl = unit.decls[Int(owner)]
    let inInterface = ownerDecl.kind == .protocolType
    let access: Access = inInterface && mods.access == .isPrivate ? .isPublic : mods.access
    if typeKeyword(i) != nil {
      return typeDeclaration(at, parent: owner, limit: close, isLocal: isLocal)
    }
    // A C# 14 extension block: `extension<T>(Receiver r) { members }`.
    if unit.isToken(i, "extension"), unit.isByte(i + 1, 0x28) || unit.startsWith(i + 1, 0x3C) {
      var block = Decl(kind: .extensionDecl, name: 0, nameToken: Int32(i), first: Int32(at), parent: owner)
      block.isLocal = isLocal
      block.isStatic = true
      var k = i + 1
      if unit.startsWith(k, 0x3C), unit.tokens[k].kind == .punctuation { k = typeParameters(k, into: &block) }
      let index = Int32(unit.decls.count)
      unit.decls.append(block)
      if unit.isByte(k, 0x28) {
        let end = unit.skipBalanced(k)
        parameters(open: k, close: end - 1, into: &unit.decls[Int(index)])
        k = end
      }
      while k < close, !unit.isByte(k, 0x7B) { k += 1 }
      guard k < close else { return k }
      let end = unit.skipBalanced(k)
      unit.decls[Int(index)].bodyOpen = Int32(k)
      unit.decls[Int(index)].bodyClose = Int32(end - 1)
      unit.decls[Int(index)].end = Int32(end)
      classBody(open: k, close: end - 1, owner: index, kind: .classType, isLocal: isLocal)
      return end
    }
    // A constructor (`Name(`) or a finalizer (`~Name(`).
    if unit.isToken(i, "~"), unit.csIsName(i + 1), unit.isByte(i + 2, 0x28) {
      var decl = Decl(kind: .deinitializer, name: unit.hash(i + 1), nameToken: Int32(i + 1), first: Int32(at), parent: owner)
      decl.isLocal = isLocal
      let end = unit.skipBalanced(i + 2)
      return finishMethod(&decl, from: end, close: close)
    }
    if unit.csIsName(i), unit.hash(i) == ownerDecl.name, ownerDecl.name != 0, unit.isByte(i + 1, 0x28) {
      var decl = Decl(kind: .initializer, name: unit.hash(i), nameToken: Int32(i), first: Int32(at), parent: owner)
      decl.access = access
      decl.isStatic = mods.isStatic
      decl.isLocal = isLocal
      let end = unit.skipBalanced(i + 1)
      parameters(open: i + 1, close: end - 1, into: &decl)
      return finishMethod(&decl, from: end, close: close)
    }
    // Conversion operators: `implicit operator T(…)`.
    if unit.isToken(i, "implicit") || unit.isToken(i, "explicit"), unit.isToken(i + 1, "operator") {
      var decl = Decl(kind: .function, name: 0, nameToken: Int32(i + 1), first: Int32(at), parent: owner)
      decl.isStatic = true
      decl.isLocal = isLocal
      var k = i + 2
      if unit.isToken(k, "checked") { k += 1 }
      if let typeEnd = unit.csTypeEnd(k, limit: close) {
        decl.typeStart = Int32(k)
        decl.typeEnd = Int32(typeEnd)
        k = typeEnd
      }
      guard unit.isByte(k, 0x28) else { return skipMember(k, close) }
      let end = unit.skipBalanced(k)
      parameters(open: k, close: end - 1, into: &decl)
      return finishMethod(&decl, from: end, close: close)
    }
    guard let typeEnd = unit.csTypeEnd(i, limit: close) else { return skipMember(i, close) }
    let typeStart = i
    i = typeEnd
    // `T operator +(…)`.
    if unit.isToken(i, "operator") {
      var decl = Decl(kind: .function, name: 0, nameToken: Int32(i), first: Int32(at), parent: owner)
      decl.typeStart = Int32(typeStart)
      decl.typeEnd = Int32(typeEnd)
      decl.isStatic = true
      decl.isLocal = isLocal
      var k = i + 1
      while k < close, !unit.isByte(k, 0x28) { k += 1 }
      guard k < close else { return k }
      let end = unit.skipBalanced(k)
      parameters(open: k, close: end - 1, into: &decl)
      return finishMethod(&decl, from: end, close: close)
    }
    // An indexer: `T this[…]`, `T I.this[…]`.
    var nameAt = i
    while unit.csIsName(nameAt), unit.isByte(nameAt + 1, 0x2E) || unit.startsWith(nameAt + 1, 0x3C) && unit.csTypeArgumentsEnd(nameAt + 1).map({ unit.isByte($0, 0x2E) }) == true {
      // An explicit interface implementation: `I.Name`, `I<T>.Name`.
      if unit.isByte(nameAt + 1, 0x2E) { nameAt += 2 } else { nameAt = unit.csTypeArgumentsEnd(nameAt + 1)! + 1 }
    }
    if unit.isToken(nameAt, "this"), unit.isByte(nameAt + 1, 0x5B) {
      var decl = Decl(kind: .subscriptDecl, name: CSharpWord.thisWord, nameToken: Int32(nameAt), first: Int32(at), parent: owner)
      decl.typeStart = Int32(typeStart)
      decl.typeEnd = Int32(typeEnd)
      decl.access = access
      decl.isLocal = isLocal
      let end = unit.skipBalanced(nameAt + 1)
      parameters(open: nameAt + 1, close: end - 1, into: &decl)
      return finishProperty(&decl, from: end, close: close)
    }
    guard unit.csIsName(nameAt) else { return skipMember(i, close) }
    let explicit = nameAt != i
    var k = nameAt + 1
    var generic = Decl(kind: .function, name: 0, nameToken: -1, first: Int32(at), parent: owner)
    if unit.startsWith(k, 0x3C), unit.tokens[k].kind == .punctuation, let after = unit.csTypeArgumentsEnd(k, limit: close), unit.isByte(after, 0x28) {
      k = typeParameters(k, into: &generic)
    }
    if unit.isByte(k, 0x28) {
      var decl = Decl(kind: .function, name: unit.hash(nameAt), nameToken: Int32(nameAt), first: Int32(at), parent: owner)
      decl.genericStart = generic.genericStart
      decl.genericCount = generic.genericCount
      decl.typeStart = Int32(typeStart)
      decl.typeEnd = Int32(typeEnd)
      decl.isStatic = mods.isStatic
      decl.access = explicit ? .isPrivate : access
      decl.isLocal = isLocal
      let end = unit.skipBalanced(k)
      parameters(open: k, close: end - 1, into: &decl)
      return finishMethod(&decl, from: end, close: close)
    }
    // A property: `T Name { get; set; } = x;` or `T Name => e;`.
    if unit.isByte(k, 0x7B) || unit.isToken(k, "=>") {
      var decl = Decl(kind: .variable, name: unit.hash(nameAt), nameToken: Int32(nameAt), first: Int32(at), parent: owner)
      decl.typeStart = Int32(typeStart)
      decl.typeEnd = Int32(typeEnd)
      decl.isStatic = mods.isStatic
      decl.access = explicit ? .isPrivate : access
      decl.isLocal = isLocal
      return finishProperty(&decl, from: k, close: close)
    }
    // Fields and events: `T a = x, b;`.
    let isEvent = unit.isToken(typeStart - 1, "event") || (typeStart > at && unit.isToken(mods.end - 1, "event"))
    _ = isEvent
    var f = nameAt
    while f < close, unit.csIsName(f) {
      var field = Decl(kind: .variable, name: unit.hash(f), nameToken: Int32(f), first: Int32(f == nameAt ? at : f), parent: owner)
      field.typeStart = Int32(typeStart)
      field.typeEnd = Int32(typeEnd)
      field.isStatic = mods.isStatic
      field.access = access
      field.isLocal = isLocal
      var j = f + 1
      // `fixed byte buffer[16]`.
      if unit.isByte(j, 0x5B) { j = unit.skipBalanced(j) }
      if unit.isToken(j, "=") {
        let start = j + 1
        j = expressionEnd(start, limit: close)
        field.initStart = Int32(start)
        field.initEnd = Int32(j)
        bodies.append((start, j))
      } else if unit.isByte(j, 0x7B) {
        // An event's `{ add …; remove …; }`.
        let end = unit.skipBalanced(j)
        field.bodyOpen = Int32(j)
        field.bodyClose = Int32(end - 1)
        bodies.append((j + 1, end - 1))
        j = end
      }
      field.end = Int32(j)
      unit.decls.append(field)
      if unit.isByte(j, 0x2C) {
        f = j + 1
        continue
      }
      f = j
      break
    }
    return unit.isByte(f, 0x3B) ? f + 1 : max(f, i + 1)
  }

  private func skipMember(_ from: Int, _ close: Int) -> Int {
    var k = from
    while k < close, !unit.isByte(k, 0x3B), !unit.isByte(k, 0x7B) { k = unit.tokens[k].kind == .open && !unit.isByte(k, 0x7B) ? unit.skipBalanced(k) : k + 1 }
    return unit.isByte(k, 0x7B) ? unit.skipBalanced(k) : k + 1
  }

  /// After a property's name: its accessors `{ … }` or `=> e;`, then `= initializer;`.
  private mutating func finishProperty(_ decl: inout Decl, from: Int, close: Int) -> Int {
    var k = from
    if unit.isByte(k, 0x7B) {
      let end = unit.skipBalanced(k)
      decl.bodyOpen = Int32(k)
      decl.bodyClose = Int32(end - 1)
      bodies.append((k + 1, end - 1))
      k = end
      if unit.isToken(k, "=") {
        let start = k + 1
        k = expressionEnd(start, limit: close)
        decl.initStart = Int32(start)
        decl.initEnd = Int32(k)
        bodies.append((start, k))
      }
    } else if unit.isToken(k, "=>") {
      let end = expressionEnd(k + 1, limit: close)
      decl.bodyOpen = Int32(k)
      decl.bodyClose = Int32(end)
      bodies.append((k + 1, end))
      k = end
    }
    if unit.isByte(k, 0x3B) { k += 1 }
    decl.end = Int32(k)
    unit.decls.append(decl)
    return k
  }

  /// After a method's parameters: `: base(…)`, `where …`, then its body `{ … }`, `=> e;` or `;`.
  private mutating func finishMethod(_ decl: inout Decl, from: Int, close: Int) -> Int {
    var k = from
    if unit.isByte(k, 0x3A), unit.isToken(k + 1, "base") || unit.isToken(k + 1, "this"), unit.isByte(k + 2, 0x28) {
      let end = unit.skipBalanced(k + 2)
      decl.initStart = Int32(k + 3)
      decl.initEnd = Int32(end - 1)
      bodies.append((k + 3, end - 1))
      k = end
    }
    if unit.isToken(k, "where") {
      decl.whereStart = Int32(k)
      while k < close, !unit.isByte(k, 0x7B), !unit.isByte(k, 0x3B), !unit.isToken(k, "=>") {
        k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
      }
      decl.whereEnd = Int32(k)
    }
    if unit.isByte(k, 0x7B) {
      let end = unit.skipBalanced(k)
      decl.bodyOpen = Int32(k)
      decl.bodyClose = Int32(end - 1)
      bodies.append((k + 1, end - 1))
      k = end
    } else if unit.isToken(k, "=>") {
      let end = expressionEnd(k + 1, limit: close)
      decl.bodyOpen = Int32(k)
      decl.bodyClose = Int32(end)
      bodies.append((k + 1, end))
      k = end
      if unit.isByte(k, 0x3B) { k += 1 }
    } else if unit.isByte(k, 0x3B) {
      k += 1
    }
    decl.end = Int32(k)
    unit.decls.append(decl)
    return k
  }

  /// The end of an expression from `i`: a `,` or `;` outside brackets, a close, or `limit`.
  func expressionEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.tokens[i].kind == .close { return i }
      if unit.isByte(i, 0x2C) || unit.isByte(i, 0x3B) { return i }
      if unit.tokens[i].kind == .punctuation, unit.startsWith(i, 0x3C), i > 0, unit.csIsName(i - 1), let after = unit.csTypeArgumentsEnd(i, limit: limit) {
        i = after
        continue
      }
      i += 1
    }
    return limit
  }

  /// Parameters `([A] this T x, ref int y, params int[] z, int w = 3)` as `Param`s: an extension method's first is
  /// labelled `this`, `params` is variadic.
  mutating func parameters(open: Int, close: Int, into decl: inout Decl) {
    decl.paramStart = Int32(unit.params.count)
    decl.paramCount = 0
    var i = open + 1
    while i < close {
      i = unit.csSkipAttributes(i, limit: close)
      var isThis = false
      var variadic = false
      while i < close, unit.isToken(i, "this") || unit.isToken(i, "ref") || unit.isToken(i, "out") || unit.isToken(i, "in") || unit.isToken(i, "params")
        || unit.isToken(i, "readonly") || unit.isToken(i, "scoped")
      {
        if unit.isToken(i, "this") { isThis = true }
        if unit.isToken(i, "params") { variadic = true }
        i += 1
      }
      guard let typeEnd = unit.csTypeEnd(i, limit: close) else {
        while i < close, !unit.isByte(i, 0x2C) { i = unit.tokens[i].kind == .open ? unit.skipBalanced(i) : i + 1 }
        i += 1
        continue
      }
      let typeStart = i
      i = typeEnd
      if unit.csIsName(i) {
        var hasDefault = false
        var k = i + 1
        if unit.isToken(k, "=") {
          hasDefault = true
          k = expressionEnd(k + 1, limit: close)
        }
        unit.params.append(
          Param(label: isThis ? CSharpWord.thisWord : 0, local: unit.hash(i), nameToken: Int32(i), typeStart: Int32(typeStart), typeEnd: Int32(typeEnd), hasDefault: hasDefault, variadic: variadic))
        decl.paramCount += 1
        i = k
      }
      while i < close, !unit.isByte(i, 0x2C) { i = unit.tokens[i].kind == .open ? unit.skipBalanced(i) : i + 1 }
      i += 1
    }
  }

  // MARK: Local functions

  /// Local functions in a body: `[static] [async] T Name<U>(…) { … }` or `=> e;` where a statement starts.
  private mutating func localFunctions(from: Int, to: Int, parent: Int32) {
    var i = from
    while i < to {
      if unit.tokens[i].kind == .open, !unit.isByte(i, 0x7B) {
        // Lambdas' blocks inside parentheses hold statements too.
        let close = unit.skipBalanced(i)
        localFunctions(from: i + 1, to: min(close - 1, to), parent: parent)
        i = close
        continue
      }
      if i == from || unit.isByte(i - 1, 0x7B) || unit.isByte(i - 1, 0x7D) || unit.isByte(i - 1, 0x3B), let end = localFunction(i, to: to, parent: parent) {
        i = end
        continue
      }
      i += 1
    }
  }

  private mutating func localFunction(_ at: Int, to: Int, parent: Int32) -> Int? {
    var i = unit.csSkipAttributes(at, limit: to)
    var isStatic = false
    while unit.isToken(i, "static") || unit.isToken(i, "async") || unit.isToken(i, "unsafe") || unit.isToken(i, "extern") {
      if unit.isToken(i, "static") { isStatic = true }
      i += 1
    }
    guard !unit.isToken(i, "return"), !unit.isToken(i, "await"), !unit.isToken(i, "new"), !unit.isToken(i, "throw"), !unit.isToken(i, "yield"),
      !unit.isToken(i, "using"), !unit.isToken(i, "else"), !unit.isToken(i, "var"), !unit.isToken(i, "case"), !unit.isToken(i, "goto"),
      let typeEnd = unit.csTypeEnd(i, limit: to), unit.csIsName(typeEnd)
    else { return nil }
    let nameToken = typeEnd
    var decl = Decl(kind: .function, name: unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(at), parent: parent)
    var k = nameToken + 1
    if unit.startsWith(k, 0x3C), unit.tokens[k].kind == .punctuation, let after = unit.csTypeArgumentsEnd(k, limit: to), unit.isByte(after, 0x28) {
      k = typeParameters(k, into: &decl)
    }
    guard unit.isByte(k, 0x28) else { return nil }
    let close = unit.skipBalanced(k)
    guard unit.isByte(close, 0x7B) || unit.isToken(close, "=>") || unit.isToken(close, "where") else { return nil }
    decl.typeStart = Int32(i)
    decl.typeEnd = Int32(typeEnd)
    decl.isLocal = true
    decl.isStatic = isStatic
    decl.access = .isPrivate
    parameters(open: k, close: close - 1, into: &decl)
    let end = finishMethod(&decl, from: close, close: to)
    let index = Int32(unit.decls.count - 1)
    let made = unit.decls[Int(index)]
    if made.bodyOpen >= 0 { localFunctions(from: Int(made.bodyOpen) + 1, to: Int(made.bodyClose), parent: index) }
    return end
  }
}
