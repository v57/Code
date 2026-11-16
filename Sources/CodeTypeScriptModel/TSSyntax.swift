import CodeModel
import CodeScan
import Foundation

/// TypeScript's and JavaScript's reading of a file into the core's tables:
///
/// - `class` is a `classType` (its `extends` type in its `type…` range, `implements` in its inherited ranges),
///   `interface` a `protocolType` (`extends` in its inherited ranges), `enum` an `enumeration` with `enumCase`s,
///   `type X = …` a `typeAlias`, `namespace`, `module` and `declare module "x"` a `namespace`, `declare global` a
///   namespace named `global`.
/// - Members: properties, accessors and a constructor's parameter properties are `variable`s, methods `function`s,
///   constructors `initializer`s, index signatures `subscriptDecl`s, call signatures `function`s named `()`.
/// - Object types (`{ a: T }`) and object literals in top-level initializers are nameless `structure`s at their `{`,
///   their properties members like any other (`TSFile.literals` finds one by its brace).
/// - `const`, `let` and `var` are `variable`s; a destructured one keeps how it's taken from its initializer
///   (`TSFile.patterns`).
/// - Imports are the core's `Import`s, one per name they bind (`member` what they take, `alias` the local name),
///   with the module already resolved to a key (`TSLayout.resolve`); re-exports (`export … from`) are exported ones.
final class TSSyntax: LanguageSyntax {
  let profile = LexProfile.profile(forLanguage: "typescript")!
  let parametersHaveLabels = false
  /// A module specifier from a file to the key of what it names (`TSLayout`'s), safe from any thread.
  let resolve: (_ specifier: String, _ from: String) -> String

  init(resolve: @escaping (String, String) -> String) { self.resolve = resolve }

  func parse(_ unit: Unit) -> UInt64 {
    let file = TSFile(path: unit.path)
    unit.scans[TSFile.key] = file
    var parser = TSParser(unit: unit, file: file, resolve: resolve)
    parser.parseFile()
    return parser.shapeHash()
  }

  func evaluateCondition(_ unit: Unit, _ i: inout Int) -> Bool {
    i += 1
    return true
  }
}

/// How a destructured name is taken from its initializer's value.
enum TSStep: Equatable {
  /// `{ key: name }`, `{ name }`.
  case member(Name)
  /// `[a, name]`: the element at an index.
  case element(Int)
  /// `...rest`: what's left (the value's own type, near enough).
  case rest
}

/// What a file has beyond the core's tables, read with its declarations.
final class TSFile: BodyFacts {
  static let key: Int32 = -1

  let path: String
  let isDeclarationFile: Bool
  let isJavaScript: Bool
  /// Has a top-level `import` or `export` (or CommonJS exports): its names are its own, not global.
  var hasModuleSyntax = false
  /// `export { a, b as c }`: the exported name, and the local name with its token.
  var exportSpecifiers: [(exported: Name, exportedToken: Int32, local: Name, localToken: Int32, parent: Int32)] = []
  /// `export = x` and `module.exports = x`: the expression's tokens, by the namespace they're in (-1 for the file).
  var exportAssignments: [Int32: (start: Int32, end: Int32)] = [:]
  /// Top-level declarations only exports reach (`exports.a = …`, `module.exports.a = …`).
  var exportOnly: Set<Int32> = []
  /// Shorthand properties (`{ name }`): a click on one is its value's.
  var shorthand: Set<Int32> = []
  /// `import x = A.B`: a second name for what the path names.
  var aliases: Set<Int32> = []
  /// `declare global { … }` blocks.
  var globals: [Int32] = []
  /// `globalThis.name = value` at the top of a file.
  var assignedGlobals: [Int32] = []
  /// `/// <reference path="…" />`, `types`, `lib`.
  var referencePaths: [String] = []
  var referenceTypes: [String] = []
  var referenceLibs: [String] = []
  /// A destructured variable's steps from its initializer.
  var patterns: [Int32: [TSStep]] = [:]
  /// Object types and literals by their `{`.
  var literals: [Int32: Int32] = [:]
  /// The body scan, made when a position inside asks.
  var body: TSBody?

  init(path: String) {
    self.path = path
    isDeclarationFile = path.hasSuffix(".d.ts") || path.hasSuffix(".d.mts") || path.hasSuffix(".d.cts")
    let lower = path.lowercased()
    isJavaScript = lower.hasSuffix(".js") || lower.hasSuffix(".jsx") || lower.hasSuffix(".mjs") || lower.hasSuffix(".cjs")
  }

  func dropTypes() { body?.dropTypes() }
}

enum TSWord {
  static let defaultName = name("default"), call = name("()"), construct = name("new()"), global = name("global")
  static let constructor = name("constructor"), prototype = name("prototype"), length = name("length")
  static let string = name("string"), number = name("number"), boolean = name("boolean"), bigint = name("bigint")
  static let symbol = name("symbol"), object = name("object"), any = name("any"), unknown = name("unknown")
  static let never = name("never"), void = name("void"), undefined = name("undefined"), null = name("null")
  static let this = name("this"), `super` = name("super"), trueWord = name("true"), falseWord = name("false")
  static let String = name("String"), Number = name("Number"), Boolean = name("Boolean"), BigInt = name("BigInt")
  static let Symbol = name("Symbol"), Object = name("Object"), Function = name("Function"), Array = name("Array")
  static let ReadonlyArray = name("ReadonlyArray"), Promise = name("Promise"), PromiseLike = name("PromiseLike")
  static let RegExp = name("RegExp"), Error = name("Error"), Map = name("Map"), Set = name("Set")
  static let Partial = name("Partial"), Required = name("Required"), Readonly = name("Readonly"), Pick = name("Pick")
  static let Omit = name("Omit"), Record = name("Record"), Awaited = name("Awaited"), ReturnType = name("ReturnType")
  static let NonNullable = name("NonNullable"), Parameters = name("Parameters"), InstanceType = name("InstanceType")
  static let Exclude = name("Exclude"), Extract = name("Extract"), Iterable = name("Iterable"), AsyncIterable = name("AsyncIterable")
  static let IterableIterator = name("IterableIterator"), Generator = name("Generator"), AsyncGenerator = name("AsyncGenerator")
  static let then = name("then"), module = name("module"), exports = name("exports"), require = name("require")
  static let globalThis = name("globalThis"), arguments = name("arguments")
  /// `export = x`'s entry in a module's exports.
  static let exportEquals = name("export=")
}

/// Words that can't name anything (property names aside).
private let reservedWords: Set<String> = [
  "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export",
  "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "new", "null", "return", "super",
  "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with",
]
private let reservedHashes: Set<Name> = Set(reservedWords.map { name($0) })

extension Unit {
  /// A word that can name a variable or a type here: an identifier, or a keyword TypeScript reserves only in context.
  func tsIsName(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    switch tokens[i].kind {
    case .identifier: return true
    case .keyword, .declarationKeyword: return !reservedHashes.contains(hash(i))
    default: return false
    }
  }

  /// Any word: what a property can be called (`x.default`, `{ class: 1 }`).
  func tsIsWord(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    let kind = tokens[i].kind
    return kind == .identifier || kind == .keyword || kind == .declarationKeyword
  }

  func tsIsPunct(_ i: Int) -> Bool { i >= 0 && i < tokens.count && tokens[i].kind == .punctuation }

  /// A token of `>` alone (`>`, `>>`, `>>>`): how many angles it closes, 0 for anything else.
  func tsCloseAngles(_ i: Int) -> Int {
    guard i >= 0, i < tokens.count, tokens[i].kind == .punctuation else { return 0 }
    let token = tokens[i]
    for k in 0..<token.length where source.text[token.start + k] != 0x3E { return 0 }
    return token.length
  }

  /// `.`, `?.` or `!.`: a member access.
  func tsIsDot(_ i: Int) -> Bool { isByte(i, 0x2E) || isToken(i, "?.") || isToken(i, "!.") }

  /// Whether a token can end an expression (a line break after it may end the statement).
  func tsEndsExpression(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    switch tokens[i].kind {
    case .identifier, .number, .string, .close, .interpolationClose: return true
    case .keyword, .declarationKeyword:
      return !reservedHashes.contains(hash(i)) || isToken(i, "this") || isToken(i, "super") || isToken(i, "true") || isToken(i, "false")
        || isToken(i, "null") || isToken(i, "break") || isToken(i, "continue") || isToken(i, "return")
    case .punctuation: return isToken(i, "++") || isToken(i, "--") || isByte(i, 0x21)
    default: return false
    }
  }

  /// Whether a token at a line's start carries on the expression above (`.x`, `?? y`, `: b`, `as T`).
  func tsContinues(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    switch tokens[i].kind {
    case .punctuation:
      if isToken(i, "++") || isToken(i, "--") || isToken(i, "!") || isToken(i, "...") || isToken(i, "@") || isToken(i, "#") { return false }
      return true
    case .keyword, .declarationKeyword:
      return isToken(i, "as") || isToken(i, "satisfies") || isToken(i, "instanceof") || isToken(i, "in") || isToken(i, "extends")
    default:
      return false
    }
  }

  /// Past `<…>` at `open`, or `open` itself when it doesn't close as type arguments do (a comparison).
  func tsSkipAngles(_ open: Int, limit: Int) -> Int {
    var depth = 0
    var i = open
    while i < limit {
      if isByte(i, 0x3C) {
        depth += 1
      } else if case let n = tsCloseAngles(i), n > 0 {
        depth -= n
        if depth <= 0 { return i + 1 }
      } else if tokens[i].kind == .open {
        i = skipBalanced(i)
        continue
      } else if tokens[i].kind == .close || isByte(i, 0x3B) || isToken(i, "&&") || isToken(i, "||") {
        return open
      }
      i += 1
    }
    return open
  }

  /// `<` written against a name (`Map<K, V>`, `f<T>(x)`, `new Set<string>()`): type arguments, past their `>`.
  func tsTypeArgumentsEnd(_ i: Int, limit: Int) -> Int? {
    guard isByte(i, 0x3C), i > 0, touchesPrevious(i), tsIsWord(i - 1) || isByte(i - 1, 0x29) == false && tsIsWord(i - 1) else { return nil }
    let end = tsSkipAngles(i, limit: limit)
    guard end > i else { return nil }
    // `a<b>c` is two comparisons; type arguments are followed by `(`, `.`, a close, an operator or a line's end.
    if end < limit, tsIsWord(end), !startsLine(end), !isToken(end, "as") { return nil }
    return end
  }

  /// The end of a type from `from` (exclusive): at depth 0 a `,`, `;`, `=` or a closing bracket, a `{` after a
  /// complete type (a body), `=>` with `arrowEnds`, a word after a complete type, or a line break the next line doesn't
  /// continue. `>` closing more angles than it opened ends it too (type arguments read from inside).
  func tsTypeEnd(_ from: Int, limit: Int, arrowEnds: Bool = false) -> Int {
    var i = from
    var angles = 0
    var conditional = 0
    var operand = true
    while i < limit {
      let kind = tokens[i].kind
      if i > from, angles == 0, !operand, startsLine(i), !tsContinuesType(i) { return i }
      switch kind {
      case .open:
        if isByte(i, 0x7B), !operand, angles == 0 { return i }
        i = skipBalanced(i)
        operand = false
        continue
      case .close, .interpolationClose:
        return i
      case .interpolationOpen:
        i = skipBalanced(i)
        continue
      case .punctuation:
        if isByte(i, 0x2C) {
          if angles == 0 { return i }
          operand = true
        } else if isByte(i, 0x3B) {
          return i
        } else if isByte(i, 0x3C) {
          angles += 1
          operand = true
        } else if case let n = tsCloseAngles(i), n > 0 {
          if angles == 0 { return i }
          if n > angles { return i }
          angles -= n
          operand = false
        } else if isToken(i, "=>") {
          if angles == 0, arrowEnds { return i }
          operand = true
        } else if isByte(i, 0x3D) {
          if angles == 0 { return i }
          operand = true
        } else if isByte(i, 0x3F) {
          if angles == 0, conditional == 0 { return i }
          operand = true
        } else if isByte(i, 0x3A) {
          if angles == 0 {
            if conditional == 0 { return i }
            conditional -= 1
          }
          operand = true
        } else if isByte(i, 0x7C) || isByte(i, 0x26) || isByte(i, 0x2E) || isToken(i, "...") || isByte(i, 0x2D) || isToken(i, "?.") {
          operand = true
        } else if isToken(i, "-?:") || isToken(i, "+?:") || isToken(i, "?:") {
          operand = true
        } else if angles == 0 {
          return i
        }
      case .string, .number:
        if !operand, angles == 0 { return i }
        operand = false
      default:
        if isToken(i, "extends") {
          if !operand, angles == 0 { conditional += 1 }
          operand = true
        } else if isToken(i, "keyof") || isToken(i, "typeof") || isToken(i, "readonly") || isToken(i, "unique") || isToken(i, "infer")
          || isToken(i, "new") || isToken(i, "asserts") || isToken(i, "abstract")
        {
          operand = true
        } else if isToken(i, "is"), !operand {
          operand = true
        } else if !operand, angles == 0 {
          return i
        } else {
          operand = false
        }
      }
      i += 1
    }
    return min(i, limit)
  }

  private func tsContinuesType(_ i: Int) -> Bool {
    isByte(i, 0x7C) || isByte(i, 0x26) || isByte(i, 0x2E) || isByte(i, 0x3F) || isByte(i, 0x3A) || isToken(i, "=>") || isToken(i, "extends")
      || tsCloseAngles(i) > 0
  }

  /// The end of an expression from `from` (exclusive): at depth 0 a `;`, a `,` (with `commaEnds`), a closing bracket,
  /// or a line break after a complete expression that the next line doesn't continue.
  func tsExpressionEnd(_ from: Int, limit: Int, commaEnds: Bool = true) -> Int {
    var i = from
    while i < limit {
      if i > from, startsLine(i), tsEndsExpression(i - 1), !tsContinues(i) {
        // `}` closing a function body ends nothing when the next line carries on (`})\n.then(…)`).
        return i
      }
      switch tokens[i].kind {
      case .open, .interpolationOpen:
        i = skipBalanced(i)
        continue
      case .close, .interpolationClose:
        return i
      case .punctuation:
        if isByte(i, 0x3B) { return i }
        if isByte(i, 0x2C), commaEnds { return i }
        if isByte(i, 0x3C), let end = tsTypeArgumentsEnd(i, limit: limit) {
          i = end
          continue
        }
      default:
        break
      }
      i += 1
    }
    return min(i, limit)
  }

  /// The end of a comma-separated item at depth 0 (the comma's index, or `limit`), type arguments' commas skipped.
  func tsListItemEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    var angles = 0
    while i < limit {
      if tokens[i].kind == .open || tokens[i].kind == .interpolationOpen {
        i = skipBalanced(i)
        continue
      }
      if isByte(i, 0x3C), i > 0, touchesPrevious(i), tsIsWord(i - 1) {
        angles += 1
      } else if angles > 0, case let n = tsCloseAngles(i), n > 0 {
        angles = max(0, angles - n)
      } else if isByte(i, 0x2C), angles == 0 {
        return i
      }
      i += 1
    }
    return limit
  }

  /// A string token's text without its quotes.
  func tsStringValue(_ i: Int) -> String {
    let text = string(i)
    guard text.count >= 2 else { return text }
    return String(text.dropFirst().dropLast())
  }

  /// The name a member token gives: a word, a string's text, a number; `#x` with its sign.
  func tsMemberName(_ i: Int) -> Name? {
    guard i >= 0, i < tokens.count else { return nil }
    switch tokens[i].kind {
    case .identifier, .keyword, .declarationKeyword, .number: return hash(i)
    case .string: return name(tsStringValue(i))
    default: return nil
    }
  }
}

struct TSParser {
  let unit: Unit
  let file: TSFile
  let resolve: (String, String) -> String
  /// Declarations read inside a body are local.
  var isLocal = false
  private var count: Int { unit.tokens.count }

  init(unit: Unit, file: TSFile, resolve: @escaping (String, String) -> String) {
    self.unit = unit
    self.file = file
    self.resolve = resolve
  }

  /// Every token outside function bodies (declared ones and those written as values): what other files can see.
  func shapeHash() -> UInt64 {
    var bodies: [Int32: Int32] = [:]
    var holders: Set<Int32> = []
    for decl in unit.decls where decl.bodyOpen >= 0 {
      if decl.kind == .function || decl.kind == .initializer || decl.kind == .variable { bodies[decl.bodyOpen] = decl.bodyClose } else { holders.insert(decl.bodyOpen) }
    }
    var shape: UInt64 = 14_695_981_039_346_656_037
    var i = 0
    while i < count {
      shape = (shape ^ unit.hash(i)) &* 1_099_511_628_211
      if let close = bodies[Int32(i)] {
        i = Int(close)
        continue
      }
      // `=> {`, `) {`: a function's body, or a statement's block.
      if unit.isByte(i, 0x7B), i > 0, unit.isToken(i - 1, "=>") || unit.isByte(i - 1, 0x29), !holders.contains(Int32(i)) {
        i = unit.skipBalanced(i) - 1
        continue
      }
      i += 1
    }
    return shape
  }

  mutating func parseFile() {
    triplesSlashes()
    statements(from: 0, to: count, parent: -1, ambient: file.isDeclarationFile)
  }

  /// `/// <reference path="…" />` lines at the top of the file.
  private func triplesSlashes() {
    for token in unit.source.tokens where token.kind == .comment || token.kind == .docComment {
      guard token.length > 12 else { continue }
      let text = unit.source.string(token)
      guard text.hasPrefix("///"), text.contains("<reference") else { continue }
      for (attribute, kind) in [("path=", 0), ("types=", 1), ("lib=", 2)] {
        guard let at = text.range(of: attribute) else { continue }
        let rest = text[at.upperBound...]
        guard let quote = rest.first, quote == "\"" || quote == "'" else { continue }
        let value = rest.dropFirst().prefix { $0 != quote }
        switch kind {
        case 0: file.referencePaths.append(String(value))
        case 1: file.referenceTypes.append(String(value))
        default: file.referenceLibs.append(String(value))
        }
      }
    }
  }

  // MARK: Statements

  /// Declarations among statements from `from` to `to` (a file, a namespace's body, a body's block when local).
  mutating func statements(from: Int, to: Int, parent: Int32, ambient: Bool) {
    var i = from
    while i < to {
      let next = statement(i, limit: to, parent: parent, ambient: ambient)
      i = max(next, i + 1)
    }
  }

  /// One statement; returns the token after it.
  mutating func statement(_ at: Int, limit: Int, parent: Int32, ambient: Bool) -> Int {
    var i = at
    if unit.isByte(i, 0x3B) { return i + 1 }
    i = skipDecorators(i, limit: limit)
    guard i < limit else { return limit }
    let first = i
    var exported = false
    var isDefault = false
    var declared = ambient
    // Modifiers.
    while i < limit {
      if unit.isToken(i, "export") {
        if unit.isByte(i + 1, 0x7B) || unit.isByte(i + 1, 0x2A) || unit.isByte(i + 1, 0x3D) || unit.isToken(i + 1, "type") && unit.isByte(i + 2, 0x7B)
          || unit.isToken(i + 1, "type") && unit.isByte(i + 2, 0x2A) || unit.isToken(i + 1, "as")
        {
          return exportStatement(i, limit: limit, parent: parent)
        }
        exported = true
        file.hasModuleSyntax = file.hasModuleSyntax || parent < 0
        i += 1
      } else if unit.isToken(i, "default"), exported {
        isDefault = true
        i += 1
      } else if unit.isToken(i, "declare") && (unit.tsIsWord(i + 1) || unit.tokens[i + 1].kind == .string) && !unit.startsLine(i + 1) {
        declared = true
        i += 1
      } else if (unit.isToken(i, "abstract") || unit.isToken(i, "async")) && unit.tsIsWord(i + 1) && !unit.startsLine(i + 1) {
        i += 1
      } else {
        break
      }
    }
    guard i < limit else { return limit }
    if isDefault {
      return defaultExport(first, at: i, limit: limit, parent: parent)
    }
    if unit.isToken(i, "import"), !unit.isByte(i + 1, 0x28), !unit.isByte(i + 1, 0x2E) {
      if parent < 0 || isNamespace(parent) { file.hasModuleSyntax = file.hasModuleSyntax || parent < 0 }
      return importStatement(i, limit: limit, exported: exported, parent: parent)
    }
    if unit.isToken(i, "function") {
      return function(first, at: i, limit: limit, parent: parent, exported: exported)
    }
    if unit.isToken(i, "class"), unit.tsIsName(i + 1) || unit.isByte(i + 1, 0x7B) {
      return classDeclaration(first, at: i, limit: limit, parent: parent, exported: exported)
    }
    if unit.isToken(i, "interface"), unit.tsIsName(i + 1), !unit.startsLine(i + 1) {
      return interfaceDeclaration(first, at: i, limit: limit, parent: parent, exported: exported)
    }
    if unit.isToken(i, "type"), unit.tsIsName(i + 1), !unit.startsLine(i + 1), unit.isByte(i + 2, 0x3D) || unit.isByte(i + 2, 0x3C) {
      return typeAlias(first, at: i, limit: limit, parent: parent, exported: exported)
    }
    if unit.isToken(i, "enum") || unit.isToken(i, "const") && unit.isToken(i + 1, "enum") {
      return enumDeclaration(first, at: unit.isToken(i, "const") ? i + 1 : i, limit: limit, parent: parent, exported: exported)
    }
    if (unit.isToken(i, "namespace") || unit.isToken(i, "module")) && !unit.startsLine(i + 1)
      && (unit.tsIsName(i + 1) || unit.tokens[i + 1].kind == .string)
    {
      return namespace(first, at: i, limit: limit, parent: parent, exported: exported, ambient: declared)
    }
    if unit.isToken(i, "global"), declared, unit.isByte(i + 1, 0x7B) {
      return globalBlock(first, at: i, limit: limit, parent: parent)
    }
    if unit.isToken(i, "const") || unit.isToken(i, "let") || unit.isToken(i, "var") || unit.isToken(i, "using") && unit.tsIsName(i + 1) {
      if unit.tsIsName(i + 1) || unit.isByte(i + 1, 0x7B) || unit.isByte(i + 1, 0x5B) {
        return variables(first, at: i, limit: limit, parent: parent, exported: exported, ambient: declared)
      }
    }
    // An expression statement: CommonJS exports at the top of a file, else nothing to declare.
    let end = unit.tsExpressionEnd(i, limit: limit, commaEnds: false)
    if parent < 0, !isLocal { commonJS(i, end) }
    return max(end, i + 1)
  }

  private func isNamespace(_ parent: Int32) -> Bool { parent >= 0 && unit.decls[Int(parent)].kind == .namespace }

  private func skipDecorators(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit, unit.isByte(i, 0x40) || unit.tokens[i].kind == .attribute {
      i += unit.tokens[i].kind == .attribute ? 1 : 2
      while unit.isByte(i, 0x2E), unit.tsIsWord(i + 1) { i += 2 }
      if unit.isByte(i, 0x28) { i = unit.skipBalanced(i) }
    }
    return i
  }

  @discardableResult
  private mutating func append(_ decl: Decl) -> Int32 {
    var item = decl
    item.isLocal = item.isLocal || isLocal
    unit.decls.append(item)
    return Int32(unit.decls.count - 1)
  }

  // MARK: Imports and exports

  /// `import …`: one `Import` per name bound; `import x = require("m")` and `import x = A.B` too.
  private mutating func importStatement(_ at: Int, limit: Int, exported: Bool, parent: Int32) -> Int {
    let end = unit.tsExpressionEnd(at + 1, limit: limit, commaEnds: false)
    var i = at + 1
    if unit.isToken(i, "type"), !unit.isByte(i + 1, 0x3D), !unit.isToken(i + 1, "from") || unit.isToken(i + 2, "from") { i += 1 }
    // `import "m"`.
    if unit.tokens[i].kind == .string {
      addImport(specifier: i, member: 0, memberToken: -1, alias: -1, exported: false)
      return end
    }
    // `import x = require("m")`, `import x = A.B`.
    if unit.tsIsName(i), unit.isByte(i + 1, 0x3D) {
      if unit.isToken(i + 2, "require"), unit.isByte(i + 3, 0x28), unit.tokens[i + 4].kind == .string {
        addImport(specifier: i + 4, member: 0, memberToken: -1, alias: i, exported: exported)
      } else {
        // A namespace's alias: a variable whose value is the name.
        var decl = Decl(kind: .variable, name: unit.hash(i), nameToken: Int32(i), first: Int32(at), parent: parent)
        decl.initStart = Int32(i + 2)
        decl.initEnd = Int32(end)
        decl.end = Int32(end)
        if exported { decl.access = .isPublic }
        file.aliases.insert(append(decl))
      }
      return end
    }
    var from = i
    while from < end, !unit.isToken(from, "from") { from = unit.tokens[from].kind == .open ? unit.skipBalanced(from) : from + 1 }
    guard from + 1 < count, unit.tokens[from + 1].kind == .string else { return end }
    let specifier = from + 1
    while i < from {
      if unit.isByte(i, 0x2C) {
        i += 1
      } else if unit.isByte(i, 0x2A), unit.isToken(i + 1, "as"), unit.tsIsWord(i + 2) {
        addImport(specifier: specifier, member: 0, memberToken: -1, alias: i + 2, exported: false)
        i += 3
      } else if unit.isByte(i, 0x7B) {
        let close = unit.skipBalanced(i) - 1
        namedBindings(open: i, close: close, specifier: specifier, exported: false)
        i = close + 1
      } else if unit.tsIsWord(i) {
        addImport(specifier: specifier, member: TSWord.defaultName, memberToken: -1, alias: i, exported: false)
        i += 1
      } else {
        i += 1
      }
    }
    return end
  }

  /// `{ a, b as c, type d, default as e }` of an import or a re-export.
  private mutating func namedBindings(open: Int, close: Int, specifier: Int, exported: Bool) {
    var i = open + 1
    while i < close {
      let itemEnd = unit.tsListItemEnd(i, limit: close)
      var k = i
      if unit.isToken(k, "type"), k + 1 < itemEnd { k += 1 }
      if k < itemEnd, unit.tsIsWord(k) || unit.tokens[k].kind == .string {
        let member = unit.tsMemberName(k) ?? 0
        var alias = k
        if k + 2 < itemEnd + 1, unit.isToken(k + 1, "as"), k + 2 < itemEnd { alias = k + 2 }
        addImport(specifier: specifier, member: member, memberToken: k, alias: alias, exported: exported)
      }
      i = itemEnd + 1
    }
  }

  private mutating func addImport(specifier: Int, member: Name, memberToken: Int, alias: Int, exported: Bool) {
    let text = unit.tsStringValue(specifier)
    let key = resolve(text, unit.path)
    var item = Import(module: name(key), moduleName: key, isExported: exported, isTestable: false)
    item.token = Int32(specifier)
    item.member = member
    item.memberToken = Int32(memberToken)
    if alias >= 0 {
      item.alias = unit.tokens[alias].kind == .string ? name(unit.tsStringValue(alias)) : unit.hash(alias)
      item.aliasToken = Int32(alias)
    }
    unit.imports.append(item)
  }

  /// `export { … } [from "m"]`, `export * [as ns] from "m"`, `export = x`, `export as namespace X`.
  private mutating func exportStatement(_ at: Int, limit: Int, parent: Int32) -> Int {
    if parent < 0 { file.hasModuleSyntax = true }
    let end = unit.tsExpressionEnd(at + 1, limit: limit, commaEnds: false)
    var i = at + 1
    if unit.isToken(i, "type") { i += 1 }
    if unit.isByte(i, 0x3D) {
      file.exportAssignments[parent] = (Int32(i + 1), Int32(end))
      return end
    }
    if unit.isToken(i, "as") { return end }
    var from = i
    while from < end, !unit.isToken(from, "from") { from = unit.tokens[from].kind == .open ? unit.skipBalanced(from) : from + 1 }
    let specifier = from + 1 < count && from < end && unit.tokens[from + 1].kind == .string ? from + 1 : -1
    if unit.isByte(i, 0x2A) {
      guard specifier >= 0 else { return end }
      if unit.isToken(i + 1, "as"), unit.tsIsWord(i + 2) {
        addImport(specifier: specifier, member: 0, memberToken: -1, alias: i + 2, exported: true)
      } else {
        addImport(specifier: specifier, member: 0, memberToken: -1, alias: -1, exported: true)
      }
      return end
    }
    guard unit.isByte(i, 0x7B) else { return end }
    let close = unit.skipBalanced(i) - 1
    if specifier >= 0 {
      namedBindings(open: i, close: close, specifier: specifier, exported: true)
      return end
    }
    var k = i + 1
    while k < close {
      let itemEnd = unit.tsListItemEnd(k, limit: close)
      var local = k
      if unit.isToken(local, "type"), local + 1 < itemEnd { local += 1 }
      if local < itemEnd, unit.tsIsWord(local) {
        var exportedToken = local
        if local + 2 < itemEnd + 1, unit.isToken(local + 1, "as"), local + 2 < itemEnd { exportedToken = local + 2 }
        file.exportSpecifiers.append((unit.tsMemberName(exportedToken) ?? 0, Int32(exportedToken), unit.hash(local), Int32(local), parent))
      }
      k = itemEnd + 1
    }
    return end
  }

  /// `export default function f…`, `export default class …`, `export default expr`.
  private mutating func defaultExport(_ first: Int, at i: Int, limit: Int, parent: Int32) -> Int {
    if unit.isToken(i, "function") || unit.isToken(i, "async") && unit.isToken(i + 1, "function") {
      let at = unit.isToken(i, "async") ? i + 1 : i
      if unit.tsIsName(at + 1) || unit.isByte(at + 1, 0x2A) && unit.tsIsName(at + 2) {
        let end = function(first, at: at, limit: limit, parent: parent, exported: true)
        markDefault(first)
        return end
      }
    }
    if unit.isToken(i, "class"), unit.tsIsName(i + 1) {
      let end = classDeclaration(first, at: i, limit: limit, parent: parent, exported: true)
      markDefault(first)
      return end
    }
    if unit.isToken(i, "abstract"), unit.isToken(i + 1, "class"), unit.tsIsName(i + 2) {
      let end = classDeclaration(first, at: i + 1, limit: limit, parent: parent, exported: true)
      markDefault(first)
      return end
    }
    // An expression (or a nameless function or class): a variable named `default` at the keyword.
    let defaultToken = i - 1
    let end = unit.isToken(i, "class") || unit.isToken(i, "function") ? skipNamelessDeclaration(i, limit: limit) : unit.tsExpressionEnd(i, limit: limit, commaEnds: false)
    var decl = Decl(kind: .variable, name: TSWord.defaultName, nameToken: Int32(defaultToken), first: Int32(first), parent: parent)
    decl.access = .isPublic
    decl.initStart = Int32(i)
    decl.initEnd = Int32(end)
    decl.end = Int32(end)
    let index = append(decl)
    if unit.isByte(i, 0x7B), parent < 0 { _ = objectLiteral(open: i, parent: index) }
    return max(end, i + 1)
  }

  private func skipNamelessDeclaration(_ i: Int, limit: Int) -> Int {
    var k = i
    while k < limit, !unit.isByte(k, 0x7B) { k = unit.tokens[k].kind == .open && !unit.isByte(k, 0x7B) ? unit.skipBalanced(k) : k + 1 }
    return k < limit ? unit.skipBalanced(k) : limit
  }

  /// The declaration that starts at `first` is the module's default export: a second name for it.
  private mutating func markDefault(_ first: Int) {
    guard let index = unit.decls.lastIndex(where: { $0.first == Int32(first) && $0.parent == -1 }) ?? unit.decls.indices.last else { return }
    let decl = unit.decls[index]
    file.exportSpecifiers.append((TSWord.defaultName, Int32(first), decl.name, decl.nameToken, decl.parent))
  }

  /// `module.exports = x`, `module.exports.a = x`, `exports.a = x`: what a CommonJS file exports.
  private mutating func commonJS(_ start: Int, _ end: Int) {
    var i = start
    var isModule = false
    if unit.isToken(i, "module"), unit.isByte(i + 1, 0x2E), unit.isToken(i + 2, "exports") {
      i += 3
      isModule = true
    } else if unit.isToken(i, "exports"), unit.isByte(i + 1, 0x2E) {
      i += 1
    } else if file.isJavaScript, unit.isToken(i, "globalThis"), unit.isByte(i + 1, 0x2E), unit.tsIsWord(i + 2), unit.isByte(i + 3, 0x3D) {
      // `globalThis.name = value` in JavaScript: a global every file sees (TypeScript wants a `declare global`).
      var decl = Decl(kind: .variable, name: unit.hash(i + 2), nameToken: Int32(i + 2), first: Int32(start), parent: -1)
      decl.initStart = Int32(i + 4)
      decl.initEnd = Int32(end)
      decl.end = Int32(end)
      let index = append(decl)
      file.exportOnly.insert(index)
      file.assignedGlobals.append(index)
      return
    } else {
      return
    }
    file.hasModuleSyntax = true
    if isModule, unit.isByte(i, 0x3D) {
      file.exportAssignments[-1] = (Int32(i + 1), Int32(end))
      if unit.isByte(i + 1, 0x7B) {
        var decl = Decl(kind: .variable, name: 0, nameToken: Int32(i - 1), first: Int32(start), parent: -1)
        decl.initStart = Int32(i + 1)
        decl.initEnd = Int32(end)
        decl.end = Int32(end)
        let index = append(decl)
        file.exportOnly.insert(index)
        _ = objectLiteral(open: i + 1, parent: index)
      }
      return
    }
    guard unit.isByte(i, 0x2E), unit.tsIsWord(i + 1), unit.isByte(i + 2, 0x3D) else { return }
    var decl = Decl(kind: .variable, name: unit.hash(i + 1), nameToken: Int32(i + 1), first: Int32(start), parent: -1)
    decl.access = .isPublic
    decl.initStart = Int32(i + 3)
    decl.initEnd = Int32(end)
    decl.end = Int32(end)
    let index = append(decl)
    file.exportOnly.insert(index)
    if unit.isByte(i + 3, 0x7B) { _ = objectLiteral(open: i + 3, parent: index) }
  }

  // MARK: Functions

  /// `function name<T>(params): R { body }`, or a signature (an overload, a declaration) without a body.
  @discardableResult
  mutating func function(_ first: Int, at: Int, limit: Int, parent: Int32, exported: Bool) -> Int {
    var i = at + 1
    if unit.isByte(i, 0x2A) { i += 1 }
    guard i < limit, unit.tsIsName(i) else { return skipNamelessDeclaration(at, limit: limit) }
    var decl = Decl(kind: .function, name: unit.hash(i), nameToken: Int32(i), first: Int32(first), parent: parent)
    if exported { decl.access = .isPublic }
    i += 1
    return signatureAndBody(&decl, from: i, limit: limit)
  }

  /// From a name's end: `<T>(params): R` and a body or not. Appends the declaration; returns the token after it.
  private mutating func signatureAndBody(_ decl: inout Decl, from: Int, limit: Int, membersEnd: Bool = false) -> Int {
    var i = from
    if unit.isByte(i, 0x3F) || unit.isByte(i, 0x21) { i += 1 }
    if unit.isByte(i, 0x3C) { i = typeParameters(i, into: &decl) }
    guard unit.isByte(i, 0x28) else {
      decl.end = Int32(i)
      append(decl)
      return i
    }
    let paramsClose = unit.skipBalanced(i)
    let index = Int32(unit.decls.count)
    append(decl)
    parameters(open: i, close: paramsClose - 1, owner: index)
    i = paramsClose
    if unit.isByte(i, 0x3A) {
      let typeEnd = unit.tsTypeEnd(i + 1, limit: limit)
      unit.decls[Int(index)].typeStart = Int32(i + 1)
      unit.decls[Int(index)].typeEnd = Int32(typeEnd)
      objectTypes(from: i + 1, to: typeEnd, parent: index)
      i = typeEnd
    }
    if i < limit, unit.isByte(i, 0x7B) {
      let close = unit.skipBalanced(i)
      unit.decls[Int(index)].bodyOpen = Int32(i)
      unit.decls[Int(index)].bodyClose = Int32(close - 1)
      i = close
    } else if unit.isByte(i, 0x3B) {
      i += 1
    }
    unit.decls[Int(index)].end = Int32(i)
    return i
  }

  /// `<T extends X = D, U>`: the names into the decl's generics (constraints are read from the tokens when asked).
  private mutating func typeParameters(_ open: Int, into decl: inout Decl) -> Int {
    let close = unit.tsSkipAngles(open, limit: count)
    guard close > open else { return open + 1 }
    decl.genericStart = Int32(unit.generics.count)
    var i = open + 1
    while i < close - 1 {
      let itemEnd = min(unit.tsListItemEnd(i, limit: close - 1), close - 1)
      var k = i
      while k < itemEnd, unit.isToken(k, "const") || unit.isToken(k, "in") || unit.isToken(k, "out") { k += 1 }
      if k < itemEnd, unit.tsIsName(k) {
        unit.generics.append(Generic(name: unit.hash(k), token: Int32(k)))
        decl.genericCount += 1
      }
      i = itemEnd + 1
    }
    return close
  }

  /// A parameter list into `Param`s of the decl at `owner`: name, type, default, rest. A destructured parameter has no
  /// name; its type is still read. A constructor's `private x: T` is a property of its class too.
  mutating func parameters(open: Int, close: Int, owner: Int32) {
    unit.decls[Int(owner)].paramStart = Int32(unit.params.count)
    var i = open + 1
    while i < close {
      let itemEnd = unit.tsListItemEnd(i, limit: close)
      parameter(i, itemEnd, owner: owner)
      i = itemEnd + 1
    }
  }

  private mutating func parameter(_ start: Int, _ end: Int, owner: Int32) {
    var i = skipDecorators(start, limit: end)
    var isProperty = false
    while i + 1 < end, unit.isToken(i, "public") || unit.isToken(i, "private") || unit.isToken(i, "protected") || unit.isToken(i, "readonly")
      || unit.isToken(i, "override")
    {
      isProperty = true
      i += 1
    }
    guard i < end else { return }
    let variadic = unit.isToken(i, "...")
    if variadic { i += 1 }
    // `this: T` types `this`; it's no parameter.
    if unit.isToken(i, "this"), unit.isByte(i + 1, 0x3A) { return }
    var nameToken = -1
    if unit.tsIsName(i) {
      nameToken = i
      i += 1
    } else if unit.isByte(i, 0x7B) || unit.isByte(i, 0x5B) {
      i = unit.skipBalanced(i)
    } else {
      return
    }
    if unit.isByte(i, 0x3F) { i += 1 }
    var typeStart = -1
    var typeEnd = -1
    if unit.isByte(i, 0x3A) || unit.isToken(i, "?:") {
      typeStart = i + 1
      typeEnd = unit.tsTypeEnd(i + 1, limit: end)
      objectTypes(from: typeStart, to: typeEnd, parent: owner)
      i = typeEnd
    }
    let hasDefault = unit.isByte(i, 0x3D)
    unit.params.append(
      Param(
        label: 0, local: nameToken >= 0 ? unit.hash(nameToken) : 0, nameToken: Int32(nameToken), typeStart: Int32(typeStart), typeEnd: Int32(typeEnd),
        hasDefault: hasDefault, variadic: variadic))
    unit.decls[Int(owner)].paramCount += 1
    if isProperty, nameToken >= 0, unit.decls[Int(owner)].parent >= 0 {
      var property = Decl(kind: .variable, name: unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(start), parent: unit.decls[Int(owner)].parent)
      property.typeStart = Int32(typeStart)
      property.typeEnd = Int32(typeEnd)
      if hasDefault {
        property.initStart = Int32(i + 1)
        property.initEnd = Int32(end)
      }
      property.end = Int32(end)
      if unit.isToken(start, "private") { property.access = .isPrivate }
      append(property)
    }
  }

  // MARK: Types

  /// `class Name<T> extends Base<X> implements I, J { members }`.
  @discardableResult
  mutating func classDeclaration(_ first: Int, at: Int, limit: Int, parent: Int32, exported: Bool) -> Int {
    var i = at + 1
    var decl: Decl
    if unit.tsIsName(i), !unit.isToken(i, "extends") && !unit.isToken(i, "implements") {
      decl = Decl(kind: .classType, name: unit.hash(i), nameToken: Int32(i), first: Int32(first), parent: parent)
      i += 1
    } else {
      decl = Decl(kind: .classType, name: 0, nameToken: Int32(at), first: Int32(first), parent: parent)
    }
    if exported { decl.access = .isPublic }
    if unit.isByte(i, 0x3C) { i = typeParameters(i, into: &decl) }
    decl.inheritStart = Int32(unit.ranges.count)
    while i < limit, !unit.isByte(i, 0x7B) {
      if unit.isToken(i, "extends") {
        let end = heritageEnd(i + 1, limit: limit)
        decl.typeStart = Int32(i + 1)
        decl.typeEnd = Int32(end)
        i = end
      } else if unit.isToken(i, "implements") || unit.isByte(i, 0x2C) {
        let end = heritageEnd(i + 1, limit: limit)
        unit.ranges.append((Int32(i + 1), Int32(end)))
        decl.inheritCount += 1
        i = end
      } else if unit.tokens[i].kind == .close || unit.isByte(i, 0x3B) {
        break
      } else {
        i += 1
      }
    }
    guard unit.isByte(i, 0x7B) else {
      decl.end = Int32(i)
      append(decl)
      return i
    }
    let close = unit.skipBalanced(i) - 1
    decl.bodyOpen = Int32(i)
    decl.bodyClose = Int32(close)
    decl.end = Int32(close + 1)
    let index = append(decl)
    classMembers(open: i, close: close, owner: index)
    if file.isJavaScript { thisAssignments(owner: index) }
    return close + 1
  }

  /// A heritage clause's type: to a `,` at depth 0, `implements` or the body's `{`.
  private func heritageEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      if unit.isByte(i, 0x7B) || unit.isByte(i, 0x2C) || unit.isToken(i, "implements") || unit.isToken(i, "extends") { return i }
      if unit.isByte(i, 0x3C) {
        let end = unit.tsSkipAngles(i, limit: limit)
        i = end > i ? end : i + 1
        continue
      }
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.tokens[i].kind == .close { return i }
      i += 1
    }
    return limit
  }

  /// A class body's members.
  private mutating func classMembers(open: Int, close: Int, owner: Int32) {
    var i = open + 1
    while i < close {
      if unit.isByte(i, 0x3B) || unit.isByte(i, 0x2C) {
        i += 1
        continue
      }
      let next = classMember(i, limit: close, owner: owner)
      i = max(next, i + 1)
    }
  }

  private mutating func classMember(_ start: Int, limit: Int, owner: Int32) -> Int {
    var i = skipDecorators(start, limit: limit)
    var isStatic = false
    var access = Access.inherited
    var accessor: StaticString?
    // Modifiers, each only when a name still follows.
    while i + 1 < limit {
      let followsName = !unit.isByte(i + 1, 0x28) && !unit.isByte(i + 1, 0x3A) && !unit.isByte(i + 1, 0x3D) && !unit.isByte(i + 1, 0x3B)
        && !unit.isByte(i + 1, 0x3F) && !unit.isByte(i + 1, 0x3C) && !unit.isByte(i + 1, 0x21) && !unit.startsLine(i + 1)
      guard followsName else { break }
      if unit.isToken(i, "static") {
        if unit.isByte(i + 1, 0x7B) { return unit.skipBalanced(i + 1) }
        isStatic = true
      } else if unit.isToken(i, "private") || unit.isToken(i, "protected") {
        access = .isPrivate
      } else if unit.isToken(i, "public") || unit.isToken(i, "readonly") || unit.isToken(i, "abstract") || unit.isToken(i, "override")
        || unit.isToken(i, "declare") || unit.isToken(i, "async") || unit.isToken(i, "accessor")
      {
      } else if unit.isToken(i, "get") || unit.isToken(i, "set") {
        accessor = unit.isToken(i, "get") ? "get" : "set"
      } else if unit.isByte(i, 0x2A) {
      } else {
        break
      }
      i += 1
    }
    guard i < limit else { return limit }
    // `[key: string]: T` or a computed name.
    if unit.isByte(i, 0x5B) {
      let close = unit.skipBalanced(i)
      if unit.tsIsName(i + 1), unit.isByte(i + 2, 0x3A) {
        return indexSignature(start, open: i, limit: limit, owner: owner)
      }
      // `[Symbol.iterator]() { … }`: no name to find it by.
      var decl = Decl(kind: .function, name: 0, nameToken: Int32(i), first: Int32(start), parent: owner)
      decl.isStatic = isStatic
      if unit.isByte(close, 0x28) || unit.isByte(close, 0x3C) { return signatureAndBody(&decl, from: close, limit: limit) }
      return memberEnd(close, limit: limit)
    }
    var nameToken = i
    if unit.isByte(i, 0x23), i + 1 < limit, unit.touchesPrevious(i + 1) { nameToken = i + 1 }
    guard unit.tsIsWord(nameToken) || unit.tokens[nameToken].kind == .string || unit.tokens[nameToken].kind == .number else {
      return unit.tsExpressionEnd(i, limit: limit, commaEnds: false)
    }
    let memberName = unit.tsMemberName(nameToken) ?? 0
    i = nameToken + 1
    if unit.isByte(i, 0x3F) || unit.isByte(i, 0x21) { i += 1 }
    if unit.isToken(nameToken, "constructor"), unit.isByte(i, 0x28) {
      var decl = Decl(kind: .initializer, name: TSWord.constructor, nameToken: Int32(nameToken), first: Int32(start), parent: owner)
      return signatureAndBody(&decl, from: i, limit: limit)
    }
    if unit.isByte(i, 0x28) || unit.isByte(i, 0x3C) {
      var decl = Decl(kind: accessor == nil ? .function : .variable, name: memberName, nameToken: Int32(nameToken), first: Int32(start), parent: owner)
      decl.isStatic = isStatic
      decl.access = access
      let end = signatureAndBody(&decl, from: i, limit: limit)
      if let accessor, let index = unit.decls.lastIndex(where: { $0.nameToken == Int32(nameToken) }) {
        // A setter's type is its parameter's.
        if accessor.utf8Start.pointee == UInt8(ascii: "s"), unit.decls[index].paramCount > 0 {
          let param = unit.params[Int(unit.decls[index].paramStart)]
          unit.decls[index].typeStart = param.typeStart
          unit.decls[index].typeEnd = param.typeEnd
        }
      }
      return end
    }
    // A property: `name?: T = value`.
    var decl = Decl(kind: .variable, name: memberName, nameToken: Int32(nameToken), first: Int32(start), parent: owner)
    decl.isStatic = isStatic
    decl.access = access
    if unit.isByte(i, 0x3A) || unit.isToken(i, "?:") || unit.isToken(i, "!:") {
      let end = unit.tsTypeEnd(i + 1, limit: limit)
      decl.typeStart = Int32(i + 1)
      decl.typeEnd = Int32(end)
      i = end
    }
    var end = i
    if unit.isByte(i, 0x3D) {
      end = unit.tsExpressionEnd(i + 1, limit: limit, commaEnds: false)
      decl.initStart = Int32(i + 1)
      decl.initEnd = Int32(end)
    }
    decl.end = Int32(end)
    let index = append(decl)
    if decl.typeStart >= 0 { objectTypes(from: Int(decl.typeStart), to: Int(decl.typeEnd), parent: index) }
    return memberEnd(end, limit: limit)
  }

  private func memberEnd(_ from: Int, limit: Int) -> Int {
    unit.isByte(from, 0x3B) || unit.isByte(from, 0x2C) ? from + 1 : from
  }

  /// `[key: string]: T`.
  private mutating func indexSignature(_ start: Int, open: Int, limit: Int, owner: Int32) -> Int {
    let close = unit.skipBalanced(open)
    var decl = Decl(kind: .subscriptDecl, name: name("[]"), nameToken: Int32(open), first: Int32(start), parent: owner)
    let index = append(decl)
    parameters(open: open, close: close - 1, owner: index)
    var i = close
    if unit.isByte(i, 0x3F) { i += 1 }
    if unit.isByte(i, 0x3A) {
      let end = unit.tsTypeEnd(i + 1, limit: limit)
      unit.decls[Int(index)].typeStart = Int32(i + 1)
      unit.decls[Int(index)].typeEnd = Int32(end)
      objectTypes(from: i + 1, to: end, parent: index)
      i = end
    }
    decl = unit.decls[Int(index)]
    unit.decls[Int(index)].end = Int32(i)
    return memberEnd(i, limit: limit)
  }

  /// JavaScript classes declare properties by assigning them: `this.x = …` in the constructor and methods.
  private mutating func thisAssignments(owner: Int32) {
    var known = Set(unit.children(of: owner).map { unit.decls[Int($0)].name })
    let methods = unit.children(of: owner).filter { unit.decls[Int($0)].bodyOpen >= 0 }.sorted { a, b in
      (unit.decls[Int(a)].kind == .initializer ? 0 : 1, a) < (unit.decls[Int(b)].kind == .initializer ? 0 : 1, b)
    }
    for method in methods {
      let item = unit.decls[Int(method)]
      var i = Int(item.bodyOpen) + 1
      while i < Int(item.bodyClose) {
        if unit.isToken(i, "this"), unit.isByte(i + 1, 0x2E), unit.tsIsWord(i + 2), unit.isByte(i + 3, 0x3D), !unit.isByte(i - 1, 0x2E) {
          let word = unit.hash(i + 2)
          if known.insert(word).inserted {
            var decl = Decl(kind: .variable, name: word, nameToken: Int32(i + 2), first: Int32(i), parent: owner)
            let end = unit.tsExpressionEnd(i + 4, limit: Int(item.bodyClose), commaEnds: false)
            decl.initStart = Int32(i + 4)
            decl.initEnd = Int32(end)
            decl.end = Int32(end)
            append(decl)
          }
        }
        i += 1
      }
    }
  }

  /// `interface Name<T> extends A, B { members }`.
  private mutating func interfaceDeclaration(_ first: Int, at: Int, limit: Int, parent: Int32, exported: Bool) -> Int {
    var decl = Decl(kind: .protocolType, name: unit.hash(at + 1), nameToken: Int32(at + 1), first: Int32(first), parent: parent)
    if exported { decl.access = .isPublic }
    var i = at + 2
    if unit.isByte(i, 0x3C) { i = typeParameters(i, into: &decl) }
    decl.inheritStart = Int32(unit.ranges.count)
    if unit.isToken(i, "extends") {
      i += 1
      while i < limit, !unit.isByte(i, 0x7B) {
        let end = heritageEnd(i, limit: limit)
        if end > i {
          unit.ranges.append((Int32(i), Int32(end)))
          decl.inheritCount += 1
        }
        i = unit.isByte(end, 0x2C) ? end + 1 : max(end, i + 1)
        if unit.tokens[min(i, count - 1)].kind == .close { break }
      }
    }
    guard unit.isByte(i, 0x7B) else {
      decl.end = Int32(i)
      append(decl)
      return i
    }
    let close = unit.skipBalanced(i) - 1
    decl.bodyOpen = Int32(i)
    decl.bodyClose = Int32(close)
    decl.end = Int32(close + 1)
    let index = append(decl)
    typeMembers(open: i, close: close, owner: index)
    return close + 1
  }

  /// An interface's or an object type's members.
  mutating func typeMembers(open: Int, close: Int, owner: Int32) {
    var i = open + 1
    while i < close {
      if unit.isByte(i, 0x3B) || unit.isByte(i, 0x2C) {
        i += 1
        continue
      }
      let next = typeMember(i, limit: close, owner: owner)
      i = max(next, i + 1)
    }
  }

  private mutating func typeMember(_ start: Int, limit: Int, owner: Int32) -> Int {
    var i = start
    var accessor: StaticString?
    while i + 1 < limit, unit.isToken(i, "readonly") || unit.isToken(i, "-readonly") || unit.isToken(i, "+readonly") || unit.isToken(i, "-"),
      !unit.isByte(i + 1, 0x3A), !unit.isByte(i + 1, 0x3F), !unit.isByte(i + 1, 0x28)
    {
      i += 1
    }
    if (unit.isToken(i, "get") || unit.isToken(i, "set")) && (unit.tsIsWord(i + 1) || unit.tokens[i + 1].kind == .string) && !unit.isByte(i + 1, 0x28) {
      accessor = unit.isToken(i, "get") ? "get" : "set"
      i += 1
    }
    // Call and construct signatures.
    if unit.isByte(i, 0x28) || unit.isByte(i, 0x3C) {
      var decl = Decl(kind: .function, name: TSWord.call, nameToken: Int32(i), first: Int32(start), parent: owner)
      return memberEnd(signatureAndBody(&decl, from: i, limit: limit), limit: limit)
    }
    if unit.isToken(i, "new"), unit.isByte(i + 1, 0x28) || unit.isByte(i + 1, 0x3C) {
      var decl = Decl(kind: .initializer, name: TSWord.construct, nameToken: Int32(i), first: Int32(start), parent: owner)
      return memberEnd(signatureAndBody(&decl, from: i + 1, limit: limit), limit: limit)
    }
    if unit.isByte(i, 0x5B) {
      if unit.tsIsName(i + 1), unit.isByte(i + 2, 0x3A) { return indexSignature(start, open: i, limit: limit, owner: owner) }
      // A mapped type's `[K in keyof T]: X`, or a computed name: no member to find by name.
      let close = unit.skipBalanced(i)
      var k = close
      if unit.isByte(k, 0x3F) || unit.isToken(k, "-?") || unit.isToken(k, "+?") { k += 1 }
      if unit.isByte(k, 0x3A) || unit.isToken(k, "?:") || unit.isToken(k, "-?:") || unit.isToken(k, "+?:") {
        let end = unit.tsTypeEnd(k + 1, limit: limit)
        objectTypes(from: k + 1, to: end, parent: owner)
        return memberEnd(end, limit: limit)
      }
      if unit.isByte(k, 0x28) {
        var decl = Decl(kind: .function, name: 0, nameToken: Int32(i), first: Int32(start), parent: owner)
        return memberEnd(signatureAndBody(&decl, from: k, limit: limit), limit: limit)
      }
      return memberEnd(unit.tsTypeEnd(k, limit: limit), limit: limit)
    }
    guard unit.tsIsWord(i) || unit.tokens[i].kind == .string || unit.tokens[i].kind == .number else {
      return unit.tsTypeEnd(i + 1, limit: limit)
    }
    let nameToken = i
    let memberName = unit.tsMemberName(i) ?? 0
    i += 1
    if unit.isByte(i, 0x3F) { i += 1 }
    if unit.isByte(i, 0x28) || unit.isByte(i, 0x3C) {
      var decl = Decl(kind: accessor == nil ? .function : .variable, name: memberName, nameToken: Int32(nameToken), first: Int32(start), parent: owner)
      return memberEnd(signatureAndBody(&decl, from: i, limit: limit), limit: limit)
    }
    var decl = Decl(kind: .variable, name: memberName, nameToken: Int32(nameToken), first: Int32(start), parent: owner)
    if unit.isByte(i, 0x3A) || unit.isToken(i, "?:") {
      let end = unit.tsTypeEnd(i + 1, limit: limit)
      decl.typeStart = Int32(i + 1)
      decl.typeEnd = Int32(end)
      i = end
    }
    decl.end = Int32(i)
    let index = append(decl)
    if decl.typeStart >= 0 { objectTypes(from: Int(decl.typeStart), to: Int(decl.typeEnd), parent: index) }
    return memberEnd(i, limit: limit)
  }

  /// Object types written in a type's tokens: a nameless structure at each outermost `{`, its members its children.
  mutating func objectTypes(from: Int, to: Int, parent: Int32) {
    var i = from
    while i < to {
      if unit.isByte(i, 0x7B) {
        let close = unit.skipBalanced(i) - 1
        if file.literals[Int32(i)] == nil {
          var decl = Decl(kind: .structure, name: 0, nameToken: Int32(i), first: Int32(i), parent: parent)
          decl.bodyOpen = Int32(i)
          decl.bodyClose = Int32(close)
          decl.end = Int32(close + 1)
          let index = append(decl)
          file.literals[Int32(i)] = index
          typeMembers(open: i, close: close, owner: index)
        }
        i = close + 1
      } else {
        i += 1
      }
    }
  }

  /// `type Name<T> = Type`.
  private mutating func typeAlias(_ first: Int, at: Int, limit: Int, parent: Int32, exported: Bool) -> Int {
    var decl = Decl(kind: .typeAlias, name: unit.hash(at + 1), nameToken: Int32(at + 1), first: Int32(first), parent: parent)
    if exported { decl.access = .isPublic }
    var i = at + 2
    if unit.isByte(i, 0x3C) { i = typeParameters(i, into: &decl) }
    guard unit.isByte(i, 0x3D) else {
      decl.end = Int32(i)
      append(decl)
      return i
    }
    // A leading `|` or `&` is allowed.
    var start = i + 1
    if unit.isByte(start, 0x7C) || unit.isByte(start, 0x26) { start += 1 }
    let end = unit.tsTypeEnd(start, limit: limit)
    decl.typeStart = Int32(start)
    decl.typeEnd = Int32(end)
    decl.end = Int32(end)
    let index = append(decl)
    objectTypes(from: start, to: end, parent: index)
    return memberEnd(end, limit: limit)
  }

  /// `enum E { A = 1, B }`.
  private mutating func enumDeclaration(_ first: Int, at: Int, limit: Int, parent: Int32, exported: Bool) -> Int {
    guard unit.tsIsName(at + 1) else { return at + 1 }
    var decl = Decl(kind: .enumeration, name: unit.hash(at + 1), nameToken: Int32(at + 1), first: Int32(first), parent: parent)
    if exported { decl.access = .isPublic }
    guard unit.isByte(at + 2, 0x7B) else {
      decl.end = Int32(at + 2)
      append(decl)
      return at + 2
    }
    let open = at + 2
    let close = unit.skipBalanced(open) - 1
    decl.bodyOpen = Int32(open)
    decl.bodyClose = Int32(close)
    decl.end = Int32(close + 1)
    let index = append(decl)
    var i = open + 1
    while i < close {
      let itemEnd = unit.tsListItemEnd(i, limit: close)
      if let memberName = unit.tsMemberName(i) {
        var member = Decl(kind: .enumCase, name: memberName, nameToken: Int32(i), first: Int32(i), parent: index)
        member.isStatic = true
        if unit.isByte(i + 1, 0x3D) {
          member.initStart = Int32(i + 2)
          member.initEnd = Int32(itemEnd)
        }
        member.end = Int32(itemEnd)
        append(member)
      }
      i = itemEnd + 1
    }
    return close + 1
  }

  /// `namespace A.B { … }`, `module A { … }`, `declare module "m" { … }` (or without a body).
  private mutating func namespace(_ first: Int, at: Int, limit: Int, parent: Int32, exported: Bool, ambient: Bool) -> Int {
    var i = at + 1
    var holder = parent
    var outer: [Int32] = []
    while true {
      let nameToken = i
      let word = unit.tokens[i].kind == .string ? name("\"" + unit.tsStringValue(i) + "\"") : unit.hash(i)
      var decl = Decl(kind: .namespace, name: word, nameToken: Int32(nameToken), first: Int32(first), parent: holder)
      if exported || holder != parent { decl.access = .isPublic }
      holder = append(decl)
      outer.append(holder)
      i += 1
      if unit.isByte(i, 0x2E), unit.tsIsName(i + 1) {
        i += 1
        continue
      }
      break
    }
    guard unit.isByte(i, 0x7B) else {
      for index in outer { unit.decls[Int(index)].end = Int32(i) }
      return memberEnd(i, limit: limit)
    }
    let close = unit.skipBalanced(i) - 1
    for index in outer {
      unit.decls[Int(index)].bodyOpen = Int32(i)
      unit.decls[Int(index)].bodyClose = Int32(close)
      unit.decls[Int(index)].end = Int32(close + 1)
    }
    statements(from: i + 1, to: close, parent: holder, ambient: ambient || unit.tokens[at + 1].kind == .string)
    return close + 1
  }

  /// `declare global { … }`: what a module adds to the global scope.
  private mutating func globalBlock(_ first: Int, at: Int, limit: Int, parent: Int32) -> Int {
    let open = at + 1
    let close = unit.skipBalanced(open) - 1
    var decl = Decl(kind: .namespace, name: TSWord.global, nameToken: Int32(at), first: Int32(first), parent: parent)
    decl.bodyOpen = Int32(open)
    decl.bodyClose = Int32(close)
    decl.end = Int32(close + 1)
    let index = append(decl)
    file.globals.append(index)
    statements(from: open + 1, to: close, parent: index, ambient: true)
    // Everything in it is seen by every file.
    for child in unit.children(of: index) { unit.decls[Int(child)].access = .isPublic }
    return close + 1
  }

  // MARK: Variables

  /// `const a: T = x, { b, c: d } = y, [e] = z`: a variable per name. `require` calls are imports.
  mutating func variables(_ first: Int, at: Int, limit: Int, parent: Int32, exported: Bool, ambient: Bool) -> Int {
    let end = unit.tsExpressionEnd(at + 1, limit: limit, commaEnds: false)
    var i = at + 1
    while i < end {
      let itemEnd = declaratorEnd(i, limit: end)
      declarator(i, itemEnd, first: first, parent: parent, exported: exported)
      i = itemEnd + 1
    }
    return memberEnd(end, limit: limit)
  }

  /// The end of one declarator: a `,` at depth 0 outside its initializer's own lists.
  private func declaratorEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    if unit.isByte(i, 0x7B) || unit.isByte(i, 0x5B) { i = unit.skipBalanced(i) }
    while i < limit {
      if unit.isByte(i, 0x3D) { return unit.tsExpressionEnd(i + 1, limit: limit, commaEnds: true) }
      if unit.isByte(i, 0x2C) { return i }
      if unit.isByte(i, 0x3A) {
        i = unit.tsTypeEnd(i + 1, limit: limit)
        continue
      }
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      i += 1
    }
    return limit
  }

  private mutating func declarator(_ start: Int, _ end: Int, first: Int, parent: Int32, exported: Bool) {
    var i = start
    let pattern = unit.isByte(i, 0x7B) || unit.isByte(i, 0x5B) ? i : -1
    var nameToken = -1
    if pattern >= 0 {
      i = unit.skipBalanced(i)
    } else if unit.tsIsName(i) {
      nameToken = i
      i += 1
    } else {
      return
    }
    if unit.isByte(i, 0x21) { i += 1 }
    var typeStart: Int32 = -1
    var typeEnd: Int32 = -1
    if unit.isByte(i, 0x3A) {
      let typeStop = unit.tsTypeEnd(i + 1, limit: end)
      typeStart = Int32(i + 1)
      typeEnd = Int32(typeStop)
      i = typeStop
    }
    var initStart: Int32 = -1
    var initEnd: Int32 = -1
    if unit.isByte(i, 0x3D) {
      initStart = Int32(i + 1)
      initEnd = Int32(end)
    }
    // `const x = require("m")`, `const { a, b: c } = require("m")`.
    if initStart >= 0, unit.isToken(Int(initStart), "require"), unit.isByte(Int(initStart) + 1, 0x28), unit.tokens[Int(initStart) + 2].kind == .string,
      unit.isByte(Int(initStart) + 3, 0x29), Int(initStart) + 4 == end
    {
      if parent < 0 { file.hasModuleSyntax = true }
      let specifier = Int(initStart) + 2
      if nameToken >= 0 {
        addImport(specifier: specifier, member: 0, memberToken: -1, alias: nameToken, exported: false)
        return
      }
      if unit.isByte(pattern, 0x7B) {
        let close = unit.skipBalanced(pattern) - 1
        var k = pattern + 1
        while k < close {
          let itemEnd = unit.tsListItemEnd(k, limit: close)
          if unit.tsIsWord(k) {
            let alias = unit.isByte(k + 1, 0x3A) && unit.tsIsName(k + 2) ? k + 2 : k
            addImport(specifier: specifier, member: unit.hash(k), memberToken: k, alias: alias, exported: false)
          }
          k = itemEnd + 1
        }
        return
      }
    }
    func make(_ token: Int, steps: [TSStep]) {
      var decl = Decl(kind: .variable, name: unit.hash(token), nameToken: Int32(token), first: Int32(first), parent: parent)
      if exported { decl.access = .isPublic }
      decl.typeStart = steps.isEmpty ? typeStart : -1
      decl.typeEnd = steps.isEmpty ? typeEnd : -1
      decl.initStart = initStart
      decl.initEnd = initEnd
      decl.end = Int32(end)
      let index = append(decl)
      if !steps.isEmpty { file.patterns[index] = steps }
      if steps.isEmpty, typeStart >= 0 { objectTypes(from: Int(typeStart), to: Int(typeEnd), parent: index) }
      if steps.isEmpty, parent < 0 || isNamespace(parent), !isLocal, initStart >= 0, unit.isByte(Int(initStart), 0x7B) {
        _ = objectLiteral(open: Int(initStart), parent: index)
      }
    }
    if nameToken >= 0 {
      make(nameToken, steps: [])
    } else {
      bindings(pattern, steps: []) { token, steps in make(token, steps: steps) }
    }
  }

  /// The names a destructuring pattern binds, each with its steps.
  func bindings(_ open: Int, steps: [TSStep], _ found: (Int, [TSStep]) -> Void) {
    let close = unit.skipBalanced(open) - 1
    let isObject = unit.isByte(open, 0x7B)
    var i = open + 1
    var position = 0
    while i <= close {
      let itemEnd = unit.tsListItemEnd(i, limit: close)
      defer {
        i = itemEnd + 1
        position += 1
      }
      guard i < itemEnd else { continue }
      if unit.isToken(i, "...") {
        if unit.tsIsName(i + 1) { found(i + 1, steps + [.rest]) }
        continue
      }
      if isObject {
        guard let key = unit.tsMemberName(i) ?? (unit.isByte(i, 0x5B) ? 0 : nil) else { continue }
        var valueAt = i + 1
        if unit.isByte(i, 0x5B) { valueAt = unit.skipBalanced(i) }
        if unit.isByte(valueAt, 0x3A) {
          let target = valueAt + 1
          if unit.isByte(target, 0x7B) || unit.isByte(target, 0x5B) {
            bindings(target, steps: steps + [.member(key)], found)
          } else if unit.tsIsName(target) {
            found(target, steps + [.member(key)])
          }
        } else if unit.tsIsName(i) {
          found(i, steps + [.member(key)])
        }
      } else {
        if unit.isByte(i, 0x7B) || unit.isByte(i, 0x5B) {
          bindings(i, steps: steps + [.element(position)], found)
        } else if unit.tsIsName(i) {
          found(i, steps + [.element(position)])
        }
      }
    }
  }

  // MARK: Object literals

  /// `{ a: 1, b, f() {}, get g() {}, ...rest }`: a nameless structure at its `{`, each property a member; spreads are its
  /// inherited ranges (expressions).
  mutating func objectLiteral(open: Int, parent: Int32) -> Int32 {
    if let known = file.literals[Int32(open)] { return known }
    let close = unit.skipBalanced(open) - 1
    var decl = Decl(kind: .structure, name: 0, nameToken: Int32(open), first: Int32(open), parent: parent)
    decl.bodyOpen = Int32(open)
    decl.bodyClose = Int32(close)
    decl.end = Int32(close + 1)
    decl.initStart = Int32(open)
    let index = append(decl)
    file.literals[Int32(open)] = index
    var spreads: [(Int32, Int32)] = []
    var i = open + 1
    while i < close {
      let itemEnd = unit.tsListItemEnd(i, limit: close)
      defer { i = itemEnd + 1 }
      guard i < itemEnd else { continue }
      if unit.isToken(i, "...") {
        spreads.append((Int32(i + 1), Int32(itemEnd)))
        continue
      }
      var k = i
      var accessor = false
      while k + 1 < itemEnd, unit.isToken(k, "async") || unit.isToken(k, "get") || unit.isToken(k, "set") || unit.isByte(k, 0x2A),
        !unit.isByte(k + 1, 0x28), !unit.isByte(k + 1, 0x3A), !unit.isByte(k + 1, 0x2C)
      {
        if unit.isToken(k, "get") || unit.isToken(k, "set") { accessor = true }
        k += 1
      }
      guard let key = unit.tsMemberName(k) else { continue }
      if unit.isByte(k + 1, 0x28) || unit.isByte(k + 1, 0x3C) {
        var method = Decl(kind: accessor ? .variable : .function, name: key, nameToken: Int32(k), first: Int32(i), parent: index)
        _ = signatureAndBody(&method, from: k + 1, limit: itemEnd)
        continue
      }
      var property = Decl(kind: .variable, name: key, nameToken: Int32(k), first: Int32(i), parent: index)
      property.end = Int32(itemEnd)
      if unit.isByte(k + 1, 0x3A) {
        property.initStart = Int32(k + 2)
        property.initEnd = Int32(itemEnd)
        let propertyIndex = append(property)
        if unit.isByte(k + 2, 0x7B), k + 2 < itemEnd, unit.skipBalanced(k + 2) == itemEnd { _ = objectLiteral(open: k + 2, parent: propertyIndex) }
      } else if unit.tsIsName(k), k + 1 == itemEnd || unit.isByte(k + 1, 0x3D) {
        // Shorthand: its value is the name in scope.
        property.initStart = Int32(k)
        property.initEnd = Int32(k + 1)
        let propertyIndex = append(property)
        file.shorthand.insert(propertyIndex)
      }
    }
    unit.decls[Int(index)].inheritStart = Int32(unit.ranges.count)
    for spread in spreads { unit.ranges.append(spread) }
    unit.decls[Int(index)].inheritCount = Int32(spreads.count)
    return index
  }
}
