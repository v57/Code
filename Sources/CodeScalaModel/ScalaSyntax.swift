import CodeJavaModel
import CodeModel
import CodeScan
import Foundation

/// Scala's reading of a file into the core's tables, and Java's for a mixed project's `.java` files
/// (`syntax(forPath:)`). Scala 2 and 3, braces and significant indentation alike:
///
/// - `class` and `case class` are `classType`s, `trait` a `protocolType`, `object` (and `case object`, a package object,
///   a given instance with a body, an anonymous given) a `classType` that `isStatic`, `enum` an `enumeration` whose
///   `case`s are `enumCase`s. A class's constructor parameters are `variable` children (`ScalaFlag.classParam`), a case
///   class's and `val`/`var` ones members. Parents after `extends` (and `with`, or `,`) are inherited ranges.
/// - `def` is a `function` (every parameter list's parameters in one run of `params`, `ScalaInfo.lists` telling them
///   apart; its result type the `type…` range, an `=` body the `init…` range), `val`/`var`/`given x: T` a `variable`,
///   `type` a `typeAlias` (an opaque one flagged).
/// - `extension (x: T)` is an `extensionDecl` named as `T`'s last name holding its methods; Scala 2's
///   `implicit class` is a class flagged `implicit`. The model finds both from what they extend.
/// - Locals come after every other declaration, `isLocal`, each with where it's visible (`ScalaInfo.scopeStart…`):
///   local `val`/`var`/`def`/`given`, lambdas' parameters (`x =>`, `(a, b) =>`, `{ case … }`), a `case` pattern's
///   bindings, a `for`'s generators (`x <- xs` not seeing itself), local classes and objects.
/// - Imports are kept whole in `ScalaFile.imports` (selectors, renames, wildcards, `given`) with where they're seen.
final class ScalaSyntax: LanguageSyntax {
  static let shared = ScalaSyntax()
  let profile = LexProfile.profile(forLanguage: "scala")!
  let parametersHaveLabels = false
  let java: any LanguageSyntax = JavaSyntax.shared

  func parse(_ unit: Unit) -> UInt64 {
    var parser = ScalaParser(unit: unit)
    parser.parseFile()
    unit.scans[ScalaFile.key] = parser.file
    return parser.shape
  }

  func evaluateCondition(_ unit: Unit, _ i: inout Int) -> Bool {
    i += 1
    return true
  }

  func syntax(forPath path: String) -> any LanguageSyntax { path.hasSuffix(".java") ? java : self }

  /// A file's package from its package clauses: chained ones joined (`package a.b` then `package c` is `a.b.c`), a
  /// package object's clause left out. Java's reader for anything else.
  static func packageName(ofFile path: String) -> String {
    guard path.hasSuffix(".scala") || path.hasSuffix(".sc") else { return JVMWorkspace.packageName(ofFile: path) }
    guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? handle.close() }
    let data = handle.readData(ofLength: 16_384)
    let source = SourceFile(bytes: data, profile: shared.profile)
    let tokens = shared.codeTokens(source)
    var parts: [String] = []
    var i = 0
    func text(_ k: Int) -> String { source.string(tokens[k]) }
    while i < tokens.count, text(i) == "package" {
      if i + 1 < tokens.count, text(i + 1) == "object" { break }
      i += 1
      var words: [String] = []
      while i < tokens.count, tokens[i].kind == .identifier || tokens[i].kind == .keyword {
        var word = text(i)
        if word.hasPrefix("`"), word.count > 2 { word = String(word.dropFirst().dropLast()) }
        words.append(word)
        i += 1
        guard i < tokens.count, text(i) == "." else { break }
        i += 1
      }
      if !words.isEmpty { parts.append(words.joined(separator: ".")) }
      while i < tokens.count, text(i) == ";" { i += 1 }
      // `package a { … }`: what's inside is the package's too.
      if i < tokens.count, text(i) == "{" { i += 1 }
    }
    return parts.joined(separator: ".")
  }
}

/// What a declaration is beyond its `DeclKind`.
struct ScalaFlag: OptionSet {
  let rawValue: UInt32
  static let isCase = ScalaFlag(rawValue: 1 << 0)
  static let isImplicit = ScalaFlag(rawValue: 1 << 1)
  static let isGiven = ScalaFlag(rawValue: 1 << 2)
  static let isLazy = ScalaFlag(rawValue: 1 << 3)
  static let isAbstract = ScalaFlag(rawValue: 1 << 4)
  static let isSealed = ScalaFlag(rawValue: 1 << 5)
  static let isOverride = ScalaFlag(rawValue: 1 << 6)
  static let isOpaque = ScalaFlag(rawValue: 1 << 7)
  static let packageObject = ScalaFlag(rawValue: 1 << 8)
  /// A class's constructor parameter; `paramVal`/`paramVar` when it's a member (a case class's are).
  static let classParam = ScalaFlag(rawValue: 1 << 9)
  static let paramVal = ScalaFlag(rawValue: 1 << 10)
  static let paramVar = ScalaFlag(rawValue: 1 << 11)
  /// A method of an `extension` group.
  static let extensionMember = ScalaFlag(rawValue: 1 << 12)
  /// `var` (a `variable` without it is a `val`).
  static let isVar = ScalaFlag(rawValue: 1 << 13)
  /// A local bound by a pattern (`case`, `val (a, b) =`), a `for` generator, a lambda.
  static let pattern = ScalaFlag(rawValue: 1 << 14)
  static let forBinding = ScalaFlag(rawValue: 1 << 15)
  static let lambda = ScalaFlag(rawValue: 1 << 16)
  /// `_` in a lambda written with placeholders.
  static let placeholder = ScalaFlag(rawValue: 1 << 17)
  static let isTrait = ScalaFlag(rawValue: 1 << 18)
  static let isObject = ScalaFlag(rawValue: 1 << 19)
  /// A `for`'s `name = value`.
  static let forValue = ScalaFlag(rawValue: 1 << 20)
  /// A `using` or `implicit` parameter.
  static let isUsing = ScalaFlag(rawValue: 1 << 21)
  /// A by-name parameter `=> T`.
  static let byName = ScalaFlag(rawValue: 1 << 22)
  static let isPrivate = ScalaFlag(rawValue: 1 << 23)
  static let isProtected = ScalaFlag(rawValue: 1 << 24)
  /// A `def` written without parameter lists.
  static let parameterless = ScalaFlag(rawValue: 1 << 25)
  /// A `case` of an `enum` with its own parameters or body.
  static let hasParams = ScalaFlag(rawValue: 1 << 26)
}

/// Per-declaration facts the core's `Decl` doesn't hold.
struct ScalaInfo {
  var flags: ScalaFlag = []
  /// Where a local's name is seen, and the part of that where it isn't (a generator's own source).
  var scopeStart: Int32 = -1
  var scopeEnd: Int32 = -1
  var holeStart: Int32 = -1
  var holeEnd: Int32 = -1
  /// A function's parameter lists: how many parameters each holds, in order, and which are `using`/`implicit`.
  var lists: [Int32] = []
  var usingLists: UInt32 = 0
  /// A template's body (or an extension group's), first token to the token after it.
  var bodyStart: Int32 = -1
  var bodyEnd: Int32 = -1
  /// What a pattern says a binding is: `x @ Foo(…)` (the name `Foo`'s tokens, `extractorStart…`); a typed pattern
  /// `x: T` uses the decl's `type…` range.
  var extractorStart: Int32 = -1
  var extractorEnd: Int32 = -1
  /// A lambda parameter: its position among the lambda's parameters, and the lambda's `=>` (for placeholders, the
  /// argument range they're in).
  var lambdaIndex: Int32 = 0
  var lambdaStart: Int32 = -1
  /// A generator's source (`x <- source`), a `case` binding's scrutinee start or a placeholder's argument end.
  var sourceStart: Int32 = -1
  var sourceEnd: Int32 = -1
  /// A `case` binding: the pattern's start and which top-level part of an extractor's arguments the binding is.
  var patternStart: Int32 = -1
  /// A class parameter: which constructor list it's in, and whether it has a default.
  var listIndex: Int32 = 0
  var hasDefault = false
}

/// One import clause's path: `import a.b.{c => d, e as f, *}`.
struct ScalaImport {
  /// The path's name tokens.
  var path: [Int32] = []
  /// Each selector: the name taken, its token, and what it's renamed to (0 when not), with that token.
  var selectors: [(name: Name, token: Int32, rename: Name, renameToken: Int32)] = []
  var wildcard = false
  var givens = false
  /// Where the import is seen: from its token to the end of its block.
  var scopeStart: Int32 = 0
  var scopeEnd: Int32 = 0
  /// The template it's in (a decl index), -1 for the file.
  var owner: Int32 = -1
  var token: Int32 = 0
}

/// What the parser knows about a file that the core's tables don't hold. Kept in `Unit.scans[ScalaFile.key]`.
final class ScalaFile: BodyFacts {
  static let key: Int32 = -7
  /// Package clauses: each one's package, the chain's last the file's.
  var packages: [String] = []
  var package: String { packages.last ?? "" }
  var info: [ScalaInfo] = []
  var imports: [ScalaImport] = []
  /// Per token: bracket depth, the matching bracket (-1 when none), its line's indentation, whether it starts a line.
  var depth: [Int32] = []
  var match: [Int32] = []
  var indent: [Int32] = []
  var first: [Bool] = []
  /// Per token: a name's hash, backquotes taken off, `unary_-` joined; 0 for anything that's no name.
  var names: [Name] = []
  /// Declarations by their name's token.
  var declAt: [Int32: Int32] = [:]
  /// Local declarations by name.
  var localsByName: [Name: [Int32]] = [:]
  /// Templates (decl indexes) whose body holds code: classes, objects, traits, enums, given instances, extension
  /// groups, by their body's start.
  var templates: [Int32] = []
  /// End markers: the `end` token and what it closes (a decl index).
  var endMarkers: [Int32: Int32] = [:]
  /// Types of locals and expressions, dropped when any declaration changes.
  var localTypes: [Int32: Ty] = [:]
  var resolvingLocals: Set<Int32> = []
  /// What each import's path names, once asked.
  var importBases: [Int32: ScalaModel.ImportBase?] = [:]

  func dropTypes() {
    localTypes.removeAll()
    importBases.removeAll()
  }
}

enum ScalaWord {
  static let hard: Set<Name> = Set(
    ["abstract", "case", "catch", "class", "def", "do", "else", "enum", "export", "extends", "false", "final", "finally", "for", "forSome", "given",
     "if", "implicit", "import", "lazy", "macro", "match", "new", "null", "object", "override", "package", "private", "protected", "return", "sealed",
     "super", "then", "this", "throw", "trait", "true", "try", "type", "val", "var", "while", "with", "yield"].map { name($0) })
  static let modifiers: Set<Name> = Set(
    ["private", "protected", "override", "final", "implicit", "lazy", "abstract", "sealed", "inline", "transparent", "opaque", "open", "infix",
     "erased", "tracked"].map { name($0) })
  static let val = name("val"), varWord = name("var"), def = name("def"), classWord = name("class"), trait = name("trait")
  static let object = name("object"), enumWord = name("enum"), typeWord = name("type"), given = name("given"), extensionWord = name("extension")
  static let importWord = name("import"), export = name("export"), packageWord = name("package"), caseWord = name("case"), forWord = name("for")
  static let extends = name("extends"), with = name("with"), derives = name("derives"), endWord = name("end"), using = name("using")
  static let implicitWord = name("implicit"), lazyWord = name("lazy"), abstract = name("abstract"), sealed = name("sealed")
  static let override = name("override"), opaque = name("opaque"), privateWord = name("private"), protectedWord = name("protected")
  static let underscore = name("_"), star = name("*"), asWord = name("as"), this = name("this"), superWord = name("super"), new = name("new")
  static let ifWord = name("if"), yield = name("yield"), doWord = name("do"), then = name("then"), elseWord = name("else"), match = name("match")
  static let catchWord = name("catch"), finally = name("finally"), whileWord = name("while"), tryWord = name("try"), returnWord = name("return")
  static let throwWord = name("throw"), apply = name("apply"), unapply = name("unapply"), copy = name("copy"), selfWord = name("self")
  static let colon = name(":"), arrow = name("=>"), contextArrow = name("?=>"), equals = name("="), larrow = name("<-"), at = name("@")
  static let bar = name("|"), amp = name("&"), plus = name("+"), minus = name("-"), subtype = name("<:"), supertype = name(">:")
  static let dot = name("."), comma = name(","), semicolon = name(";"), hash = name("#"), rarrow = name("->"), viewBound = name("<%")
  static let trueWord = name("true"), falseWord = name("false"), null = name("null")
  /// Words after which a line goes on: `else`, `catch`, … at the start of a line continue the statement above.
  static let continuations: Set<Name> = Set(["else", "catch", "finally", "yield", "do", "then", "with", "extends", "match", "derives"].map { name($0) })
}

/// Bytes of operator characters, which make symbolic names.
@inline(__always) func scIsOperatorByte(_ byte: UInt8) -> Bool {
  switch byte {
  case 0x21, 0x23, 0x25, 0x26, 0x2A, 0x2B, 0x2D, 0x2F, 0x3A, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x5C, 0x5E, 0x7C, 0x7E: return true
  default: return false
  }
}

struct ScalaParser {
  let unit: Unit
  let file = ScalaFile()
  var shape: UInt64 = 14_695_981_039_346_656_037
  /// Token ranges whose text doesn't change what other files see: bodies under a declared type.
  private var bodies: [(Int, Int)] = []
  private let count: Int
  /// Name tokens of declarations made while reading members, so the local scan passes them by.
  private var declared: Set<Int32> = []

  init(unit: Unit) {
    self.unit = unit
    count = unit.tokens.count
  }

  // MARK: Tokens

  @inline(__always) func word(_ i: Int) -> Name { i >= 0 && i < count ? file.names[i] : 0 }
  @inline(__always) func isWord(_ i: Int, _ w: Name) -> Bool { i >= 0 && i < count && file.names[i] == w && !isQuoted(i) }
  @inline(__always) func isQuoted(_ i: Int) -> Bool { unit.source.text[unit.tokens[i].start] == 0x60 }
  /// A name: an identifier (backquoted too) that isn't a hard keyword or `_`.
  func isName(_ i: Int) -> Bool {
    guard i >= 0, i < count else { return false }
    let w = file.names[i]
    guard w != 0 else { return false }
    if isQuoted(i) { return true }
    return !ScalaWord.hard.contains(w) && w != ScalaWord.underscore && unit.tokens[i].kind != .punctuation
  }
  func isOperator(_ i: Int) -> Bool { i >= 0 && i < count && unit.tokens[i].kind == .punctuation && file.names[i] != 0 }
  @inline(__always) func isPunct(_ i: Int, _ w: Name) -> Bool { i >= 0 && i < count && unit.tokens[i].kind == .punctuation && unit.hash(i) == w }
  @inline(__always) func isOpen(_ i: Int, _ byte: UInt8) -> Bool { i >= 0 && i < count && unit.tokens[i].kind == .open && unit.source.text[unit.tokens[i].start] == byte }
  @inline(__always) func isClose(_ i: Int) -> Bool { i >= 0 && i < count && (unit.tokens[i].kind == .close || unit.tokens[i].kind == .interpolationClose) }
  @inline(__always) func depth(_ i: Int) -> Int32 { i < count ? file.depth[i] : 0 }
  @inline(__always) func first(_ i: Int) -> Bool { i < count ? file.first[i] : true }
  @inline(__always) func indent(_ i: Int) -> Int32 { i < count ? file.indent[i] : 0 }
  @inline(__always) func match(_ i: Int) -> Int { i >= 0 && i < count ? Int(file.match[i]) : -1 }

  /// Per-token tables: names, brackets, lines.
  private mutating func readTokens() {
    let tokens = unit.tokens
    let text = unit.source.text
    file.depth = [Int32](repeating: 0, count: count)
    file.match = [Int32](repeating: -1, count: count)
    file.indent = [Int32](repeating: 0, count: count)
    file.first = [Bool](repeating: false, count: count)
    file.names = [Name](repeating: 0, count: count)
    var stack: [Int] = []
    var lineIndent: Int32 = 0
    for i in 0..<count {
      let token = tokens[i]
      if i == 0 || unit.startsLine(i) {
        // Its column: back to the line's start.
        var s = token.start
        while s > 0, text[s - 1] != 0x0A { s -= 1 }
        lineIndent = Int32(token.start - s)
        file.first[i] = token.kind != .interpolationClose
      }
      file.indent[i] = lineIndent
      switch token.kind {
      case .open, .interpolationOpen:
        file.depth[i] = Int32(stack.count)
        stack.append(i)
      case .close, .interpolationClose:
        if let open = stack.popLast() {
          file.match[open] = Int32(i)
          file.match[i] = Int32(open)
        }
        file.depth[i] = Int32(stack.count)
      default:
        file.depth[i] = Int32(stack.count)
      }
      switch token.kind {
      case .identifier, .keyword, .declarationKeyword:
        if text[token.start] == 0x60, token.length > 2 {
          file.names[i] = hashName(text + token.start + 1, token.length - 2)
        } else if text[token.start + token.length - 1] == 0x5F, i + 1 < count, tokens[i + 1].kind == .punctuation, unit.touchesPrevious(i + 1),
          scIsOperatorByte(text[tokens[i + 1].start])
        {
          // `unary_-`, `name_=`: one name over two tokens.
          file.names[i] = hashName(String(decoding: UnsafeBufferPointer(start: text + token.start, count: tokens[i + 1].end - token.start), as: UTF8.self))
        } else {
          file.names[i] = unit.hash(i)
        }
      case .punctuation:
        if scIsOperatorByte(text[token.start]) { file.names[i] = unit.hash(i) }
      default:
        break
      }
    }
  }

  // MARK: Regions

  /// The innermost bracket open before `i` that closes after it.
  func enclosingOpen(_ i: Int) -> Int {
    let d = depth(i)
    var k = i - 1
    while k >= 0 {
      let kind = unit.tokens[k].kind
      if (kind == .open || kind == .interpolationOpen), file.depth[k] < d, file.match[k] < 0 || Int(file.match[k]) > i { return k }
      if d == 0 { return -1 }
      k -= 1
    }
    return -1
  }

  /// The close of the bracket around `i`, or the end.
  func enclosingEnd(_ i: Int) -> Int {
    let o = enclosingOpen(i)
    return o >= 0 && match(o) >= 0 ? match(o) : count
  }

  /// Where the block holding token `i` ends: its bracket's close, or the first line at the same depth indented less
  /// than `indent` (the line of `i` by default).
  func blockEnd(_ i: Int, indent wanted: Int32? = nil) -> Int {
    let end = enclosingEnd(i)
    let line = wanted ?? indent(i)
    let d = depth(i)
    var k = i + 1
    while k < end {
      if file.first[k], file.depth[k] == d, file.indent[k] < line { return k }
      k += 1
    }
    return end
  }

  /// Where a definition or statement starting at `i` ends: the next line at the same depth indented no further than
  /// its own (an operator, `.member`, `else`, `catch` or a closing bracket at its start goes on), or its bracket's close.
  func regionEnd(_ i: Int) -> Int {
    let end = enclosingEnd(i)
    let line = indent(i)
    let d = depth(i)
    var k = i + 1
    while k < end {
      if file.first[k], file.depth[k] == d, file.indent[k] <= line {
        if isClose(k) || unit.isByte(k, 0x2E) || (unit.tokens[k].kind == .punctuation && file.names[k] != 0 && !isPunct(k, ScalaWord.at)) || (ScalaWord.continuations.contains(file.names[k]) && !isQuoted(k)) {
          k += 1
          continue
        }
        // `end name` closes it.
        if isWord(k, ScalaWord.endWord), k + 1 < end, !file.first[k + 1] {
          var m = k + 1
          while m < end, !file.first[m] { m += 1 }
          return m
        }
        return k
      }
      k += 1
    }
    return end
  }

  /// Where a type starting at `k` ends: before `=`, `{`, `<-`, a `,` or `;` or a closing bracket at its depth, `with`
  /// (when `stopAtWith`), `extends`, `derives`, `if`, or a new line.
  func typeEnd(_ k: Int, stopAtWith: Bool = true) -> Int {
    guard k < count else { return k }
    let d = depth(k)
    var j = k
    while j < count {
      let token = unit.tokens[j]
      if file.depth[j] < d { break }
      if file.depth[j] == d {
        if j > k, file.first[j] { break }
        if token.kind == .punctuation, unit.isByte(j, 0x2C) || unit.isByte(j, 0x3B) { break }
        if isClose(j), match(j) < k { break }
        if isPunct(j, ScalaWord.equals) || isPunct(j, ScalaWord.larrow) || isOpen(j, 0x7B) { break }
        if j > k, !isQuoted(j), file.names[j] == ScalaWord.extends || file.names[j] == ScalaWord.derives || file.names[j] == ScalaWord.ifWord { break }
        if j > k, stopAtWith, isWord(j, ScalaWord.with) { break }
        // A pattern's `=>` after a typed binding (`case e: T =>`).
        if isPunct(j, ScalaWord.arrow), j == k { break }
      }
      j += 1
    }
    return j
  }

  // MARK: The file

  mutating func parseFile() {
    readTokens()
    var k = 0
    var package = ""
    // Package clauses, chained.
    while k < count, isWord(k, ScalaWord.packageWord), !isWord(k + 1, ScalaWord.object) {
      var j = k + 1
      var words: [String] = []
      // The clause ends with its line: `package a` then `extension (…)` or `open class` on the next.
      while j < count, isName(j) || unit.isByte(j, 0x2E), j == k + 1 || !file.first[j] {
        if isName(j) { words.append(nameText(j)) }
        j += 1
      }
      let clause = words.joined(separator: ".")
      package = package.isEmpty ? clause : package + "." + clause
      file.packages.append(package)
      while unit.isByte(j, 0x3B) { j += 1 }
      if isOpen(j, 0x7B) { j += 1 }
      k = j
    }
    parseBlock(k, count, owner: -1, depth: k < count ? depth(k) : 0)
    let members = unit.decls.count
    scanLocals()
    // A shape over everything but bodies under a declared type and locals' own text.
    _ = members
    mixShape()
  }

  func nameText(_ i: Int) -> String {
    let text = unit.string(i)
    if text.hasPrefix("`"), text.count > 2 { return String(text.dropFirst().dropLast()) }
    return text
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

  /// The tokens in a body that start a statement at its top level.
  func memberStarts(_ start: Int, _ end: Int, depth wanted: Int32) -> [Int] {
    var result: [Int] = []
    var lineIndent: Int32 = -1
    var k = start
    while k < end {
      if file.depth[k] == wanted {
        let afterSemicolon = k > 0 && unit.isByte(k - 1, 0x3B)
        let afterOpen = k == start && k > 0 && isOpen(k - 1, 0x7B)
        if file.first[k] || afterSemicolon || afterOpen {
          if lineIndent < 0 { lineIndent = file.indent[k] }
          if file.indent[k] == lineIndent || !file.first[k] { result.append(k) }
        }
      }
      k += 1
    }
    return result
  }

  mutating func parseBlock(_ start: Int, _ end: Int, owner: Int32, depth wanted: Int32, isLocal: Bool = false) {
    for k in memberStarts(start, end, depth: wanted) { statement(k, end, owner: owner, isLocal: isLocal) }
  }

  /// Annotations and modifiers before a declaration: past them, with what they said.
  func skipModifiers(_ from: Int, _ end: Int) -> (Int, ScalaFlag) {
    var k = from
    var flags: ScalaFlag = []
    while k < end {
      if isPunct(k, ScalaWord.at) {
        k += 2
        while k + 1 < end, unit.isByte(k, 0x2E) { k += 2 }
        if isOpen(k, 0x5B), match(k) > 0 { k = match(k) + 1 }
        while k < end, isOpen(k, 0x28), !file.first[k], match(k) > 0 { k = match(k) + 1 }
        continue
      }
      let w = word(k)
      if w == ScalaWord.caseWord, !isQuoted(k), isWord(k + 1, ScalaWord.classWord) || isWord(k + 1, ScalaWord.object) {
        flags.insert(.isCase)
        k += 1
        continue
      }
      guard ScalaWord.modifiers.contains(w), !isQuoted(k) else { break }
      // A soft modifier used as a name: `open(…)`, `inline = 3`.
      if unit.tokens[k].kind == .identifier, !(isName(k + 1) || ScalaWord.hard.contains(word(k + 1)) || ScalaWord.modifiers.contains(word(k + 1))) { break }
      switch w {
      case ScalaWord.implicitWord: flags.insert(.isImplicit)
      case ScalaWord.lazyWord: flags.insert(.isLazy)
      case ScalaWord.abstract: flags.insert(.isAbstract)
      case ScalaWord.sealed: flags.insert(.isSealed)
      case ScalaWord.override: flags.insert(.isOverride)
      case ScalaWord.opaque: flags.insert(.isOpaque)
      case ScalaWord.privateWord: flags.insert(.isPrivate)
      case ScalaWord.protectedWord: flags.insert(.isProtected)
      default: break
      }
      k += 1
      // `private[pkg]`, `protected[this]`.
      if (w == ScalaWord.privateWord || w == ScalaWord.protectedWord), isOpen(k, 0x5B), match(k) > 0 { k = match(k) + 1 }
    }
    return (k, flags)
  }

  mutating func statement(_ at: Int, _ end: Int, owner: Int32, isLocal: Bool) {
    let (k, flags) = skipModifiers(at, end)
    guard k < end else { return }
    let w = isQuoted(k) ? 0 : word(k)
    switch w {
    case ScalaWord.packageWord where isWord(k + 1, ScalaWord.object):
      template(k + 1, end, owner: owner, flags: flags.union(.packageObject), isLocal: isLocal)
    case ScalaWord.packageWord:
      // `package x { … }` inside a file: its body's statements, in the file's package.
      var j = k + 1
      while j < end, isName(j) || unit.isByte(j, 0x2E), j == k + 1 || !file.first[j] { j += 1 }
      if isOpen(j, 0x7B), match(j) > 0 { parseBlock(j + 1, match(j), owner: owner, depth: depth(j) + 1, isLocal: isLocal) }
    case ScalaWord.classWord, ScalaWord.trait, ScalaWord.object, ScalaWord.enumWord:
      template(k, end, owner: owner, flags: flags, isLocal: isLocal)
    case ScalaWord.def:
      function(k, end, owner: owner, flags: flags, isLocal: isLocal)
    case ScalaWord.val, ScalaWord.varWord:
      value(k, end, owner: owner, flags: flags, isLocal: isLocal)
    case ScalaWord.typeWord:
      typeAlias(k, end, owner: owner, flags: flags, isLocal: isLocal)
    case ScalaWord.given:
      givenDecl(k, end, owner: owner, flags: flags, isLocal: isLocal)
    case ScalaWord.extensionWord where isOpen(k + 1, 0x28) || isOpen(k + 1, 0x5B):
      extensionGroup(k, end, owner: owner, isLocal: isLocal)
    case ScalaWord.importWord, ScalaWord.export:
      importClause(k, owner: owner)
    case ScalaWord.caseWord where owner >= 0 && unit.decls[Int(owner)].kind == .enumeration:
      enumCases(k, end, owner: owner)
    case ScalaWord.endWord where !file.first[k + 1 < count ? k + 1 : k] || k + 1 >= count:
      break
    default:
      break
    }
  }

  // MARK: Declarations

  @discardableResult
  private mutating func add(_ kind: DeclKind, nameToken: Int, first: Int, parent: Int32, flags: ScalaFlag, isLocal: Bool, name explicit: Name? = nil) -> Int32 {
    var item = Decl(kind: kind, name: explicit ?? word(nameToken), nameToken: Int32(nameToken), first: Int32(first), parent: parent)
    item.isLocal = isLocal
    if flags.contains(.isPrivate) { item.access = .isPrivate } else if flags.contains(.isProtected) { item.access = .filePrivate } else { item.access = .isPublic }
    if flags.contains(.isObject) { item.isStatic = true }
    unit.decls.append(item)
    var info = ScalaInfo()
    info.flags = flags
    file.info.append(info)
    let index = Int32(unit.decls.count - 1)
    file.declAt[Int32(nameToken)] = index
    declared.insert(Int32(nameToken))
    if isLocal { file.localsByName[item.name, default: []].append(index) }
    return index
  }

  /// `[A, +B <: C]`: generics of the declaration being made.
  private mutating func typeParameters(_ open: Int) -> (Int32, Int32) {
    let close = match(open)
    let start = Int32(unit.generics.count)
    guard close > open else { return (start, 0) }
    var k = open + 1
    var expect = true
    let d = depth(open) + 1
    while k < close {
      if file.depth[k] == d {
        if unit.isByte(k, 0x2C) {
          expect = true
        } else if expect, isPunct(k, ScalaWord.plus) || isPunct(k, ScalaWord.minus) {
          // Variance.
        } else if expect, isName(k) || isWord(k, ScalaWord.underscore) {
          unit.generics.append(Generic(name: word(k), token: Int32(k)))
          declared.insert(Int32(k))
          expect = false
        } else {
          expect = false
        }
      }
      k += 1
    }
    return (start, Int32(unit.generics.count) - start)
  }

  /// A parameter list `( … )` at `open`: each name before `:` (or a bare name in a lambda). Returns the parameters'
  /// name tokens with their flags and type ranges.
  private func parameters(_ open: Int) -> [(token: Int, typeStart: Int, typeEnd: Int, hasDefault: Bool, flags: ScalaFlag)] {
    let close = match(open)
    guard close > open else { return [] }
    var result: [(Int, Int, Int, Bool, ScalaFlag)] = []
    var k = open + 1
    var expect = true
    var pending: ScalaFlag = []
    let d = depth(open) + 1
    while k < close {
      if file.depth[k] == d {
        if unit.isByte(k, 0x2C) {
          expect = true
          k += 1
          continue
        }
        if expect {
          if isPunct(k, ScalaWord.at) {
            k += 2
            while k + 1 < close, unit.isByte(k, 0x2E) { k += 2 }
            if isOpen(k, 0x28), match(k) > 0 { k = match(k) + 1 }
            continue
          }
          let w = isQuoted(k) ? 0 : word(k)
          if w == ScalaWord.val {
            pending.insert(.paramVal)
            k += 1
            continue
          }
          if w == ScalaWord.varWord {
            pending.insert(.paramVar)
            k += 1
            continue
          }
          if w == ScalaWord.using || w == ScalaWord.implicitWord {
            pending.insert(.isUsing)
            k += 1
            continue
          }
          if ScalaWord.modifiers.contains(w), isName(k + 1) {
            if w == ScalaWord.privateWord { pending.insert(.isPrivate) }
            k += 1
            if isOpen(k, 0x5B), match(k) > 0 { k = match(k) + 1 }
            continue
          }
          if isName(k) || isWord(k, ScalaWord.underscore), isPunct(k + 1, ScalaWord.colon) || k + 1 == close || unit.isByte(k + 1, 0x2C) {
            var typeStart = -1
            var typeEnd = -1
            var flags = pending
            var hasDefault = false
            if isPunct(k + 1, ScalaWord.colon) {
              typeStart = k + 2
              if isPunct(typeStart, ScalaWord.arrow) {
                flags.insert(.byName)
                typeStart += 1
              }
              typeEnd = self.typeEnd(typeStart, stopAtWith: false)
              hasDefault = isPunct(typeEnd, ScalaWord.equals)
            }
            result.append((k, typeStart, typeEnd, hasDefault, flags))
            expect = false
            k += 1
            continue
          }
          // `using Ordering[T]`: an anonymous context parameter.
          expect = false
        }
      }
      k += 1
    }
    // A `using`/`implicit` list: every parameter of it.
    if result.contains(where: { $0.4.contains(.isUsing) }) {
      for index in result.indices { result[index].4.insert(.isUsing) }
    }
    return result
  }

  /// Whether a parameter list is `(using …)` or `(implicit …)`.
  private func isUsingList(_ open: Int) -> Bool { isWord(open + 1, ScalaWord.using) || isWord(open + 1, ScalaWord.implicitWord) }

  /// A template's body after its header from `k`: `{ … }`, or an indented block after `:` (or `with`) ending a line.
  func bodyAfterHeader(_ k: Int, _ limit: Int, header: Int) -> (start: Int, end: Int, depth: Int32)? {
    guard k < count else { return nil }
    let d = depth(k)
    var j = k
    while j < limit {
      if file.depth[j] < d { return nil }
      if file.depth[j] == d {
        // A later line is another statement (a `{` right after the header may start one).
        if file.first[j], j > k || !isOpen(j, 0x7B) { return nil }
        if isOpen(j, 0x7B) {
          let close = match(j)
          return (j + 1, close > 0 ? close : limit, d + 1)
        }
        if isPunct(j, ScalaWord.colon) || isWord(j, ScalaWord.with), j + 1 >= count || file.first[j + 1] {
          let start = j + 1
          let headIndent = indent(header)
          var e = start
          while e < limit {
            if file.first[e], file.depth[e] == d, file.indent[e] <= headIndent { break }
            e += 1
          }
          // `end Name` closing it is the body's too.
          if isWord(e, ScalaWord.endWord), e + 1 < count, !file.first[e + 1] {
            var m = e + 1
            while m < count, !file.first[m] { m += 1 }
            return (start, m, d)
          }
          return (start, e, d)
        }
        if isPunct(j, ScalaWord.equals) || unit.isByte(j, 0x3B) || (file.first[j] && j > k) { return nil }
      }
      j += 1
    }
    return nil
  }

  private mutating func template(_ k: Int, _ end: Int, owner: Int32, flags given: ScalaFlag, isLocal: Bool) {
    guard k + 1 < end, isName(k + 1) else { return }
    let w = word(k)
    var flags = given
    var kind = DeclKind.classType
    if w == ScalaWord.trait {
      kind = .protocolType
      flags.insert(.isTrait)
    } else if w == ScalaWord.object {
      flags.insert(.isObject)
    } else if w == ScalaWord.enumWord {
      kind = .enumeration
    }
    let nameToken = k + 1
    let index = add(kind, nameToken: nameToken, first: k, parent: owner, flags: flags, isLocal: isLocal)
    let scopeEnd = regionEnd(k)
    var j = nameToken + 1
    if isOpen(j, 0x5B), match(j) > 0 {
      let (start, n) = typeParameters(j)
      unit.decls[Int(index)].genericStart = start
      unit.decls[Int(index)].genericCount = n
      j = match(j) + 1
    }
    // Constructor parameter lists (`private` before them makes the constructor private).
    var isFirstList = true
    while j < end, !file.first[j] {
      if isWord(j, ScalaWord.privateWord) || isWord(j, ScalaWord.protectedWord) || isPunct(j, ScalaWord.at) {
        j += 1
        continue
      }
      guard isOpen(j, 0x28), match(j) > 0 else { break }
      let usingList = isUsingList(j)
      let listNumber = Int32(file.info[Int(index)].lists.count)
      var size: Int32 = 0
      if usingList, file.info[Int(index)].lists.count < 32 { file.info[Int(index)].usingLists |= 1 << UInt32(file.info[Int(index)].lists.count) }
      for p in parameters(j) {
        var pflags = p.flags.union(.classParam)
        if flags.contains(.isCase), isFirstList, !usingList { pflags.insert(.paramVal) }
        let param = add(.variable, nameToken: p.token, first: p.token, parent: index, flags: pflags, isLocal: isLocal)
        if p.typeStart >= 0 {
          unit.decls[Int(param)].typeStart = Int32(p.typeStart)
          unit.decls[Int(param)].typeEnd = Int32(p.typeEnd)
        }
        if p.flags.contains(.paramVar) { file.info[Int(param)].flags.insert(.isVar) }
        if !pflags.contains(.paramVal), !pflags.contains(.paramVar) { unit.decls[Int(param)].access = .isPrivate }
        unit.decls[Int(param)].end = Int32(p.typeEnd >= 0 ? p.typeEnd : p.token + 1)
        file.info[Int(param)].listIndex = listNumber
        file.info[Int(param)].hasDefault = p.hasDefault
        size += 1
      }
      file.info[Int(index)].lists.append(size)
      isFirstList = false
      j = match(j) + 1
    }
    j = parents(j, end, of: index)
    if let body = bodyAfterHeader(j, end, header: k) {
      file.info[Int(index)].bodyStart = Int32(body.start)
      file.info[Int(index)].bodyEnd = Int32(body.end)
      if isOpen(body.start - 1, 0x7B) {
        unit.decls[Int(index)].bodyOpen = Int32(body.start - 1)
        unit.decls[Int(index)].bodyClose = Int32(body.end)
      }
      file.templates.append(index)
      parseBlock(body.start, body.end, owner: index, depth: body.depth, isLocal: isLocal)
      endMarker(at: body.end, closes: index)
    }
    unit.decls[Int(index)].end = Int32(max(scopeEnd, j + 1))
  }

  /// An `end name` marker right before `at` (or at it): what it closes.
  private mutating func endMarker(at: Int, closes index: Int32) {
    var k = min(at, count) - 1
    while k > 0, !file.first[k] { k -= 1 }
    if k >= 0, isWord(k, ScalaWord.endWord), k + 1 < count, !file.first[k + 1] { file.endMarkers[Int32(k + 1)] = index }
  }

  /// `extends A(args) with B, C`: the parents' ranges, from `j`; returns where they end.
  private mutating func parents(_ from: Int, _ end: Int, of index: Int32) -> Int {
    var j = from
    guard j < end, isWord(j, ScalaWord.extends) else { return j }
    let d = depth(j)
    j += 1
    let start = Int32(unit.ranges.count)
    var expect = true
    while j < end {
      if file.depth[j] == d {
        if isOpen(j, 0x7B) || isWord(j, ScalaWord.derives) { break }
        if isPunct(j, ScalaWord.colon), j + 1 >= count || file.first[j + 1] { break }
        if file.first[j], !isWord(j, ScalaWord.with), !isWord(j, ScalaWord.extends), !expect { break }
        if isWord(j, ScalaWord.with) || unit.isByte(j, 0x2C) {
          if isWord(j, ScalaWord.with), j + 1 >= count || file.first[j + 1] { break }
          expect = true
          j += 1
          continue
        }
        if expect, isName(j) {
          // A type: a qualified name with type arguments; its constructor arguments aren't part of it.
          var e = j + 1
          while e + 1 < end, unit.isByte(e, 0x2E), isName(e + 1) { e += 2 }
          if isOpen(e, 0x5B), match(e) > 0 { e = match(e) + 1 }
          unit.ranges.append((Int32(j), Int32(e)))
          expect = false
          j = e
          while isOpen(j, 0x28), match(j) > 0, !file.first[j] { j = match(j) + 1 }
          continue
        }
        if isPunct(j, ScalaWord.equals) || unit.isByte(j, 0x3B) { break }
      } else if file.depth[j] < d {
        break
      }
      j += 1
    }
    unit.decls[Int(index)].inheritStart = start
    unit.decls[Int(index)].inheritCount = Int32(unit.ranges.count) - start
    return j
  }

  private mutating func function(_ k: Int, _ end: Int, owner: Int32, flags: ScalaFlag, isLocal: Bool) {
    guard k + 1 < end, isName(k + 1) || isOperator(k + 1) || isWord(k + 1, ScalaWord.this) else { return }
    let nameToken = k + 1
    // `def this(…)`: an auxiliary constructor.
    let isConstructor = isWord(nameToken, ScalaWord.this)
    let index = add(isConstructor ? .initializer : .function, nameToken: nameToken, first: k, parent: owner, flags: flags, isLocal: isLocal)
    let scopeEnd = regionEnd(k)
    var j = nameToken + 1
    if file.names[nameToken] != 0, unit.isByte(nameToken, 0x5F) == false, unit.string(nameToken).hasSuffix("_"), isOperator(j), unit.touchesPrevious(j) { j += 1 }
    if isOpen(j, 0x5B), match(j) > 0 {
      let (start, n) = typeParameters(j)
      unit.decls[Int(index)].genericStart = start
      unit.decls[Int(index)].genericCount = n
      j = match(j) + 1
    }
    let paramStart = Int32(unit.params.count)
    var lists: [Int32] = []
    var usingLists: UInt32 = 0
    while j < end, isOpen(j, 0x28), match(j) > 0, !file.first[j] {
      if isUsingList(j), lists.count < 32 { usingLists |= 1 << UInt32(lists.count) }
      let found = parameters(j)
      for p in found {
        unit.params.append(
          Param(
            label: word(p.token), local: word(p.token), nameToken: Int32(p.token), typeStart: Int32(p.typeStart), typeEnd: Int32(p.typeEnd), hasDefault: p.hasDefault,
            variadic: p.typeEnd > p.typeStart && isPunct(p.typeEnd - 1, ScalaWord.star)))
        declared.insert(Int32(p.token))
      }
      lists.append(Int32(found.count))
      j = match(j) + 1
    }
    unit.decls[Int(index)].paramStart = paramStart
    unit.decls[Int(index)].paramCount = Int32(unit.params.count) - paramStart
    file.info[Int(index)].lists = lists
    file.info[Int(index)].usingLists = usingLists
    if lists.isEmpty { file.info[Int(index)].flags.insert(.parameterless) }
    if isPunct(j, ScalaWord.colon) {
      let e = typeEnd(j + 1, stopAtWith: false)
      unit.decls[Int(index)].typeStart = Int32(j + 1)
      unit.decls[Int(index)].typeEnd = Int32(e)
      j = e
    }
    if isPunct(j, ScalaWord.equals) {
      unit.decls[Int(index)].initStart = Int32(j + 1)
      unit.decls[Int(index)].initEnd = Int32(scopeEnd)
      if unit.decls[Int(index)].typeStart >= 0 || isConstructor { bodies.append((j + 1, scopeEnd)) }
    } else if isOpen(j, 0x7B), !file.first[j] || isConstructor {
      // Procedure syntax (Scala 2): `def f() { … }`.
      unit.decls[Int(index)].initStart = Int32(j)
      unit.decls[Int(index)].initEnd = Int32(scopeEnd)
      bodies.append((j, scopeEnd))
    }
    unit.decls[Int(index)].end = Int32(scopeEnd)
    if isLocal {
      file.info[Int(index)].scopeStart = Int32(localScopeStart(k))
      file.info[Int(index)].scopeEnd = Int32(blockEnd(k))
    }
    endMarker(at: scopeEnd, closes: index)
  }

  /// Where a local declared at `k` is seen from: the start of the block it's in (local functions see each other).
  private func localScopeStart(_ k: Int) -> Int {
    let o = enclosingOpen(k)
    return o >= 0 ? o : 0
  }

  private mutating func value(_ k: Int, _ end: Int, owner: Int32, flags given: ScalaFlag, isLocal: Bool) {
    var j = k + 1
    guard j < end else { return }
    var flags = given
    if isWord(k, ScalaWord.varWord) { flags.insert(.isVar) }
    var names: [Int] = []
    if isName(j), !isOpen(j + 1, 0x28), !isPunct(j + 1, ScalaWord.at) {
      names.append(j)
      while j + 2 < end, unit.isByte(j + 1, 0x2C), isName(j + 2) {
        j += 2
        names.append(j)
      }
      j += 1
    } else {
      // A pattern: `val (a, b) = …`, `val Foo(x, y) = …`, `val x @ Some(_) = …`.
      var stop = j
      while stop < end, !(isPunct(stop, ScalaWord.equals) && depth(stop) == depth(k)) {
        if file.first[stop], stop > j { break }
        stop += 1
      }
      let scopeEnd = isLocal ? blockEnd(k) : enclosingEnd(k)
      for p in patternBindings(j, stop) {
        let index = add(.variable, nameToken: p, first: k, parent: owner, flags: flags.union(.pattern), isLocal: true)
        file.info[Int(index)].scopeStart = Int32(p)
        file.info[Int(index)].scopeEnd = Int32(scopeEnd)
        file.info[Int(index)].patternStart = Int32(j)
        file.info[Int(index)].sourceStart = Int32(stop + 1)
        unit.decls[Int(index)].end = Int32(p + 1)
        recordPatternFacts(index, p, stop)
      }
      return
    }
    var typeStart = -1
    var typeEndAt = -1
    if isPunct(j, ScalaWord.colon) {
      typeStart = j + 1
      typeEndAt = typeEnd(j + 1, stopAtWith: false)
      j = typeEndAt
    }
    let scopeEnd = regionEnd(k)
    var initStart = -1
    if isPunct(j, ScalaWord.equals) {
      initStart = j + 1
      if typeStart >= 0 { bodies.append((j + 1, scopeEnd)) }
    }
    for n in names {
      let index = add(.variable, nameToken: n, first: k, parent: owner, flags: flags, isLocal: isLocal)
      unit.decls[Int(index)].typeStart = Int32(typeStart)
      unit.decls[Int(index)].typeEnd = Int32(typeEndAt)
      if initStart >= 0 {
        unit.decls[Int(index)].initStart = Int32(initStart)
        unit.decls[Int(index)].initEnd = Int32(scopeEnd)
      }
      unit.decls[Int(index)].end = Int32(scopeEnd)
      if isLocal {
        file.info[Int(index)].scopeStart = Int32(n)
        file.info[Int(index)].scopeEnd = Int32(blockEnd(k))
      }
    }
  }

  private mutating func typeAlias(_ k: Int, _ end: Int, owner: Int32, flags: ScalaFlag, isLocal: Bool) {
    guard k + 1 < end, isName(k + 1) else { return }
    let index = add(.typeAlias, nameToken: k + 1, first: k, parent: owner, flags: flags, isLocal: isLocal)
    var j = k + 2
    if isOpen(j, 0x5B), match(j) > 0 {
      let (start, n) = typeParameters(j)
      unit.decls[Int(index)].genericStart = start
      unit.decls[Int(index)].genericCount = n
      j = match(j) + 1
    }
    // Bounds of an abstract type: `type T <: Upper`.
    while isPunct(j, ScalaWord.subtype) || isPunct(j, ScalaWord.supertype) { j = typeEnd(j + 1) }
    if isPunct(j, ScalaWord.equals) {
      let e = typeEnd(j + 1, stopAtWith: false)
      unit.decls[Int(index)].typeStart = Int32(j + 1)
      unit.decls[Int(index)].typeEnd = Int32(e)
      j = e
    }
    unit.decls[Int(index)].end = Int32(max(j, k + 2))
    if isLocal {
      file.info[Int(index)].scopeStart = Int32(k)
      file.info[Int(index)].scopeEnd = Int32(blockEnd(k))
    }
  }

  /// `given name: T = …`, `given name: T with { … }`, `given T with …`, `given T = …` (anonymous), `given [A]: T`.
  private mutating func givenDecl(_ k: Int, _ end: Int, owner: Int32, flags given: ScalaFlag, isLocal: Bool) {
    var j = k + 1
    let flags = given.union(.isGiven)
    var nameToken = -1
    if isName(j), isPunct(j + 1, ScalaWord.colon) || isOpen(j + 1, 0x5B) || isOpen(j + 1, 0x28) {
      // `given name[A](using x): T`, or `given Ordering[Int] with` (a type, not a name, when no `:` follows its brackets).
      var m = j + 1
      while isOpen(m, 0x5B) || isOpen(m, 0x28), match(m) > 0 { m = match(m) + 1 }
      if isPunct(m, ScalaWord.colon) {
        nameToken = j
        j = m + 1
      }
    } else if isOpen(j, 0x5B), match(j) > 0, isPunct(match(j) + 1, ScalaWord.colon) {
      j = match(j) + 2
    }
    let typeStart = j
    let e = typeEnd(j)
    let index: Int32
    if nameToken >= 0 {
      index = add(.variable, nameToken: nameToken, first: k, parent: owner, flags: flags, isLocal: isLocal)
    } else {
      index = add(.variable, nameToken: k, first: k, parent: owner, flags: flags, isLocal: isLocal, name: 0)
    }
    unit.decls[Int(index)].typeStart = Int32(typeStart)
    unit.decls[Int(index)].typeEnd = Int32(e)
    let scopeEnd = regionEnd(k)
    unit.decls[Int(index)].end = Int32(scopeEnd)
    if isLocal {
      file.info[Int(index)].scopeStart = Int32(nameToken >= 0 ? nameToken : k)
      file.info[Int(index)].scopeEnd = Int32(blockEnd(k))
    }
    if isPunct(e, ScalaWord.equals) {
      unit.decls[Int(index)].initStart = Int32(e + 1)
      unit.decls[Int(index)].initEnd = Int32(scopeEnd)
      bodies.append((e + 1, scopeEnd))
    } else if isWord(e, ScalaWord.with) || isOpen(e, 0x7B), let body = bodyAfterHeader(e, end, header: k) {
      // A given instance: an object of its type.
      unit.decls[Int(index)].kind = .classType
      unit.decls[Int(index)].isStatic = true
      file.info[Int(index)].flags.insert(.isObject)
      let start = Int32(unit.ranges.count)
      unit.ranges.append((Int32(typeStart), Int32(e)))
      unit.decls[Int(index)].inheritStart = start
      unit.decls[Int(index)].inheritCount = 1
      unit.decls[Int(index)].typeStart = -1
      unit.decls[Int(index)].typeEnd = -1
      file.info[Int(index)].bodyStart = Int32(body.start)
      file.info[Int(index)].bodyEnd = Int32(body.end)
      file.templates.append(index)
      parseBlock(body.start, body.end, owner: index, depth: body.depth, isLocal: isLocal)
    }
  }

  /// `extension [A](x: T)(using …) def f… `, or a block of them.
  private mutating func extensionGroup(_ k: Int, _ end: Int, owner: Int32, isLocal: Bool) {
    var j = k + 1
    let groupEnd = regionEnd(k)
    var genericStart = Int32(unit.generics.count)
    var genericCount: Int32 = 0
    if isOpen(j, 0x5B), match(j) > 0 {
      (genericStart, genericCount) = typeParameters(j)
      j = match(j) + 1
    }
    guard isOpen(j, 0x28), match(j) > 0 else { return }
    let receiver = parameters(j)
    var receiverName: Name = 0
    if let first = receiver.first, first.typeStart >= 0 {
      // Its last name: `List[A]` is `List`'s, `a.B` is `B`'s.
      var m = first.typeStart
      var last = -1
      while m < first.typeEnd, isName(m) {
        last = m
        guard unit.isByte(m + 1, 0x2E) else { break }
        m += 2
      }
      if last >= 0 { receiverName = word(last) }
    }
    let index = add(.extensionDecl, nameToken: k, first: k, parent: owner, flags: [], isLocal: isLocal, name: receiverName)
    unit.decls[Int(index)].genericStart = genericStart
    unit.decls[Int(index)].genericCount = genericCount
    if let first = receiver.first {
      unit.decls[Int(index)].typeStart = Int32(first.typeStart)
      unit.decls[Int(index)].typeEnd = Int32(first.typeEnd)
    }
    let paramStart = Int32(unit.params.count)
    var lists: [Int32] = []
    while isOpen(j, 0x28), match(j) > 0 {
      let found = parameters(j)
      for p in found {
        unit.params.append(
          Param(label: word(p.token), local: word(p.token), nameToken: Int32(p.token), typeStart: Int32(p.typeStart), typeEnd: Int32(p.typeEnd), hasDefault: false, variadic: false))
        declared.insert(Int32(p.token))
      }
      lists.append(Int32(found.count))
      j = match(j) + 1
    }
    unit.decls[Int(index)].paramStart = paramStart
    unit.decls[Int(index)].paramCount = Int32(unit.params.count) - paramStart
    file.info[Int(index)].lists = lists
    var bodyStart = j
    var bodyEnd = groupEnd
    if isOpen(j, 0x7B), match(j) > 0 {
      bodyStart = j + 1
      bodyEnd = match(j)
      parseBlock(bodyStart, bodyEnd, owner: index, depth: depth(j) + 1, isLocal: isLocal)
    } else if isPunct(j, ScalaWord.colon), j + 1 < count, file.first[j + 1] {
      bodyStart = j + 1
      parseBlock(bodyStart, bodyEnd, owner: index, depth: depth(j), isLocal: isLocal)
    } else if j < count, !file.first[j] {
      statement(j, groupEnd, owner: index, isLocal: isLocal)
    } else {
      parseBlock(j, groupEnd, owner: index, depth: depth(k), isLocal: isLocal)
    }
    file.info[Int(index)].bodyStart = Int32(bodyStart)
    file.info[Int(index)].bodyEnd = Int32(bodyEnd)
    file.templates.append(index)
    unit.decls[Int(index)].end = Int32(groupEnd)
    for child in index + 1..<Int32(unit.decls.count) where unit.decls[Int(child)].parent == index {
      file.info[Int(child)].flags.insert(.extensionMember)
    }
  }

  /// `case A, B` or `case C(x: Int) extends E(…)` in an enum.
  private mutating func enumCases(_ k: Int, _ end: Int, owner: Int32) {
    var j = k + 1
    while j < end, isName(j) {
      let index = add(.enumCase, nameToken: j, first: k, parent: owner, flags: [.isCase], isLocal: false)
      var n = j + 1
      if isOpen(n, 0x5B), match(n) > 0 {
        let (start, c) = typeParameters(n)
        unit.decls[Int(index)].genericStart = start
        unit.decls[Int(index)].genericCount = c
        n = match(n) + 1
      }
      if isOpen(n, 0x28), match(n) > 0 {
        for p in parameters(n) {
          let param = add(.variable, nameToken: p.token, first: p.token, parent: index, flags: p.flags.union([.classParam, .paramVal]), isLocal: false)
          if p.typeStart >= 0 {
            unit.decls[Int(param)].typeStart = Int32(p.typeStart)
            unit.decls[Int(param)].typeEnd = Int32(p.typeEnd)
          }
          unit.decls[Int(param)].end = Int32(p.typeEnd >= 0 ? p.typeEnd : p.token + 1)
        }
        file.info[Int(index)].flags.insert(.hasParams)
        n = match(n) + 1
      }
      n = parents(n, end, of: index)
      unit.decls[Int(index)].end = Int32(n)
      if unit.isByte(n, 0x2C) {
        j = n + 1
        continue
      }
      break
    }
  }

  // MARK: Imports

  private mutating func importClause(_ k: Int, owner: Int32) {
    let scopeEnd = Int32(blockEnd(k))
    var j = k + 1
    let line = unit.source.lines.line(of: unit.tokens[k].start)
    while j < count {
      var item = ScalaImport()
      item.scopeStart = Int32(k)
      item.scopeEnd = scopeEnd
      item.owner = owner
      item.token = Int32(k)
      // The path's words, a trailing selector or `{…}`.
      while j < count {
        let sameLine = unit.source.lines.line(of: unit.tokens[j].start) == line || (j > 0 && unit.isByte(j - 1, 0x2E))
        guard sameLine || !item.path.isEmpty && unit.isByte(j - 1, 0x2E) else { break }
        if isName(j) || (unit.tokens[j].kind == .keyword && !isWord(j, ScalaWord.given) && file.names[j] != ScalaWord.underscore) {
          item.path.append(Int32(j))
          j += 1
          if unit.isByte(j, 0x2E) {
            j += 1
            continue
          }
          break
        }
        if isPunct(j, ScalaWord.star) || isWord(j, ScalaWord.underscore) {
          item.wildcard = true
          j += 1
          break
        }
        if isWord(j, ScalaWord.given) {
          item.givens = true
          j += 1
          // `given Ordering[?]`: a type after it.
          while j < count, !file.first[j], !unit.isByte(j, 0x2C) { j += 1 }
          break
        }
        if isOpen(j, 0x7B), match(j) > 0 {
          let close = match(j)
          var m = j + 1
          while m < close {
            if isWord(m, ScalaWord.underscore) || isPunct(m, ScalaWord.star) {
              item.wildcard = true
            } else if isWord(m, ScalaWord.given) {
              item.givens = true
              while m + 1 < close, !unit.isByte(m + 1, 0x2C) { m += 1 }
            } else if isName(m) || unit.tokens[m].kind == .keyword {
              if isPunct(m + 1, ScalaWord.arrow) || isWord(m + 1, ScalaWord.asWord), m + 2 < close {
                // `a => b`, `a as b`; `a => _` hides `a`.
                let renamed = isWord(m + 2, ScalaWord.underscore) ? 1 : word(m + 2)
                item.selectors.append((word(m), Int32(m), renamed, Int32(m + 2)))
                m += 3
                continue
              }
              item.selectors.append((word(m), Int32(m), 0, -1))
            }
            m += 1
          }
          j = close + 1
          break
        }
        break
      }
      if !item.path.isEmpty {
        if item.selectors.isEmpty, !item.wildcard, !item.givens, let last = item.path.popLast() {
          item.selectors.append((word(Int(last)), last, 0, -1))
        }
        file.imports.append(item)
        // The core's import: the path's package (or object), as written.
        var entry = Import(module: 0, moduleName: item.path.map { nameText(Int($0)) }.joined(separator: "."), isExported: false, isTestable: false)
        entry.module = name(entry.moduleName)
        entry.token = item.path.first ?? Int32(k)
        unit.imports.append(entry)
      }
      if unit.isByte(j, 0x2C) {
        j += 1
        continue
      }
      break
    }
  }

  // MARK: Patterns and locals

  /// Names a pattern binds: lowercase plain names not selected, called or typed; `x @ …`; not the type after `:`.
  func patternBindings(_ start: Int, _ stop: Int) -> [Int] {
    var result: [Int] = []
    var k = start
    var inType = false
    while k < stop {
      if isPunct(k, ScalaWord.colon) {
        inType = true
      } else if unit.isByte(k, 0x2C) || isOpen(k, 0x28) || isClose(k) || isPunct(k, ScalaWord.bar) || isPunct(k, ScalaWord.at) {
        inType = false
      } else if !inType, isName(k), !isQuoted(k), unit.tokens[k].kind == .identifier {
        let byte = unit.source.text[unit.tokens[k].start]
        let selected = k > 0 && unit.isByte(k - 1, 0x2E)
        let followed = unit.isByte(k + 1, 0x2E) || (isOpen(k + 1, 0x28) && unit.touchesPrevious(k + 1)) || isOpen(k + 1, 0x28)
        if (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F, !selected, !followed { result.append(k) }
      }
      k += 1
    }
    return result
  }

  /// `x @ Foo(…)` and `x: T`: what the pattern says the binding is.
  private mutating func recordPatternFacts(_ index: Int32, _ p: Int, _ stop: Int) {
    if isPunct(p + 1, ScalaWord.at), p + 2 < stop, isName(p + 2) {
      var e = p + 2
      while e + 2 < stop, unit.isByte(e + 1, 0x2E), isName(e + 2) { e += 2 }
      file.info[Int(index)].extractorStart = Int32(p + 2)
      file.info[Int(index)].extractorEnd = Int32(e + 1)
    }
    if isPunct(p + 1, ScalaWord.colon), p + 2 < stop {
      let e = min(typeEnd(p + 2), stop)
      unit.decls[Int(index)].typeStart = Int32(p + 2)
      unit.decls[Int(index)].typeEnd = Int32(e)
    }
  }

  /// Every local: declarations in bodies, `case` bindings, `for` generators, lambdas' parameters, local templates.
  private mutating func scanLocals() {
    var i = 0
    while i < count {
      let w = isQuoted(i) ? 0 : file.names[i]
      switch w {
      case ScalaWord.val, ScalaWord.varWord, ScalaWord.def, ScalaWord.given, ScalaWord.typeWord:
        if i + 1 < count, !declared.contains(Int32(i + 1)), !declared.contains(Int32(i)), !isImportPath(i) {
          let owner = ownerOfLocal(i)
          let (start, flags) = (i, ScalaFlag())
          if w == ScalaWord.def {
            function(start, count, owner: owner, flags: flags, isLocal: true)
          } else if w == ScalaWord.given {
            givenDecl(start, count, owner: owner, flags: flags, isLocal: true)
          } else if w == ScalaWord.typeWord {
            if isName(i + 1), file.first[i] || isLocalStatementStart(i) { typeAlias(start, count, owner: owner, flags: flags, isLocal: true) }
          } else {
            value(start, count, owner: owner, flags: flags, isLocal: true)
          }
        }
      case ScalaWord.classWord, ScalaWord.trait, ScalaWord.object, ScalaWord.enumWord:
        if i + 1 < count, !declared.contains(Int32(i + 1)), isName(i + 1), !isWord(i - 1, ScalaWord.packageWord) || declared.contains(Int32(i + 1)) == false {
          let owner = ownerOfLocal(i)
          var flags: ScalaFlag = []
          if isWord(i - 1, ScalaWord.caseWord) { flags.insert(.isCase) }
          template(i, count, owner: owner, flags: flags, isLocal: true)
        }
      case ScalaWord.caseWord:
        if !isWord(i + 1, ScalaWord.classWord), !isWord(i + 1, ScalaWord.object), !declared.contains(Int32(i + 1)) { caseClause(i) }
      case ScalaWord.forWord:
        forBindings(i)
      default:
        if isPunct(i, ScalaWord.arrow) || isPunct(i, ScalaWord.contextArrow) { lambdaParameters(i) }
        if isWord(i, ScalaWord.underscore) { placeholder(i) }
      }
      i += 1
    }
  }

  private func isImportPath(_ i: Int) -> Bool { i > 0 && unit.isByte(i - 1, 0x2E) }

  private func isLocalStatementStart(_ i: Int) -> Bool { i > 0 && (unit.isByte(i - 1, 0x3B) || isOpen(i - 1, 0x7B)) }

  /// The declaration a local is inside: the innermost one whose extent holds it.
  private func ownerOfLocal(_ i: Int) -> Int32 {
    var best: Int32 = -1
    var bestFirst: Int32 = -1
    for index in 0..<unit.decls.count {
      let item = unit.decls[index]
      if item.first <= Int32(i), Int32(i) < item.end, item.first >= bestFirst, item.kind != .variable || item.isLocal == false {
        if item.kind == .variable, !(item.initStart >= 0 && item.initStart <= Int32(i)) { continue }
        best = Int32(index)
        bestFirst = item.first
      }
    }
    return best
  }

  private mutating func caseClause(_ i: Int) {
    let d = depth(i)
    var k = i + 1
    var arrow = -1
    var guardToken = -1
    while k < count, file.depth[k] >= d {
      if file.depth[k] == d {
        if isPunct(k, ScalaWord.arrow) {
          arrow = k
          break
        }
        if isWord(k, ScalaWord.ifWord), guardToken < 0 { guardToken = k }
        if unit.isByte(k, 0x3B) || isPunct(k, ScalaWord.equals) || isPunct(k, ScalaWord.larrow) { return }
      }
      k += 1
    }
    guard arrow > 0 else { return }
    // The clause ends at the next `case` of the same match, or its block.
    let end = enclosingEnd(i)
    var m = arrow + 1
    while m < end {
      if file.depth[m] == d, file.first[m], file.indent[m] < indent(i) || (file.indent[m] == indent(i)) { break }
      if file.depth[m] == d, isWord(m, ScalaWord.caseWord), !file.first[m], unit.isByte(m - 1, 0x3B) { break }
      m += 1
    }
    let owner = ownerOfLocal(i)
    let patternEnd = guardToken >= 0 ? guardToken : arrow
    for p in patternBindings(i + 1, patternEnd) {
      let index = add(.variable, nameToken: p, first: i, parent: owner, flags: .pattern, isLocal: true)
      file.info[Int(index)].scopeStart = Int32(p)
      file.info[Int(index)].scopeEnd = Int32(m)
      file.info[Int(index)].patternStart = Int32(i + 1)
      unit.decls[Int(index)].end = Int32(p + 1)
      recordPatternFacts(index, p, patternEnd)
    }
  }

  private mutating func forBindings(_ i: Int) {
    var k = i + 1
    guard k < count else { return }
    var enumStart = k
    var enumEnd = k
    var after = k
    if isOpen(k, 0x28) || isOpen(k, 0x7B), match(k) > 0 {
      enumStart = k + 1
      enumEnd = match(k)
      after = enumEnd + 1
    } else {
      // Scala 3: `for x <- xs do`, or generators on the lines below up to `do`/`yield`.
      var m = k
      while m < count, !(file.depth[m] == depth(i) && (isWord(m, ScalaWord.doWord) || isWord(m, ScalaWord.yield))) {
        if file.depth[m] < depth(i) { break }
        m += 1
      }
      enumStart = k
      enumEnd = m
      after = m
    }
    var body = after
    if isWord(body, ScalaWord.yield) || isWord(body, ScalaWord.doWord) { body += 1 }
    var end: Int
    if isOpen(body, 0x7B), match(body) > 0 {
      end = match(body) + 1
    } else {
      end = regionEnd(i)
      if end <= body { end = regionEnd(body) }
    }
    let d = enumStart < count ? depth(enumStart) : 0
    var starts = [enumStart]
    k = enumStart
    while k < enumEnd {
      if file.depth[k] == d, unit.isByte(k, 0x3B) || (file.first[k] && k > enumStart) { starts.append(unit.isByte(k, 0x3B) ? k + 1 : k) }
      k += 1
    }
    let owner = ownerOfLocal(i)
    for (n, s) in starts.enumerated() where s < enumEnd {
      let holeEnd = n + 1 < starts.count ? starts[n + 1] : enumEnd
      var m = s
      while m < enumEnd, !(file.depth[m] == d && (isPunct(m, ScalaWord.larrow) || isPunct(m, ScalaWord.equals))), !(m > s && file.depth[m] == d && (file.first[m] || unit.isByte(m, 0x3B))) { m += 1 }
      guard m < enumEnd, file.depth[m] == d else { continue }
      if isPunct(m, ScalaWord.larrow) {
        for p in patternBindings(s, m) {
          let index = add(.variable, nameToken: p, first: s, parent: owner, flags: .forBinding, isLocal: true)
          file.info[Int(index)].scopeStart = Int32(p)
          file.info[Int(index)].scopeEnd = Int32(end)
          file.info[Int(index)].holeStart = Int32(m)
          file.info[Int(index)].holeEnd = Int32(holeEnd)
          file.info[Int(index)].sourceStart = Int32(m + 1)
          file.info[Int(index)].sourceEnd = Int32(holeEnd)
          file.info[Int(index)].patternStart = Int32(s)
          unit.decls[Int(index)].end = Int32(p + 1)
          recordPatternFacts(index, p, m)
        }
      } else if isPunct(m, ScalaWord.equals), isName(s), s + 1 == m || isPunct(s + 1, ScalaWord.colon) {
        let index = add(.variable, nameToken: s, first: s, parent: owner, flags: .forValue, isLocal: true)
        file.info[Int(index)].scopeStart = Int32(s)
        file.info[Int(index)].scopeEnd = Int32(end)
        file.info[Int(index)].holeStart = Int32(m)
        file.info[Int(index)].holeEnd = Int32(holeEnd)
        unit.decls[Int(index)].initStart = Int32(m + 1)
        unit.decls[Int(index)].initEnd = Int32(holeEnd)
        unit.decls[Int(index)].end = Int32(s + 1)
        if isPunct(s + 1, ScalaWord.colon) {
          unit.decls[Int(index)].typeStart = Int32(s + 2)
          unit.decls[Int(index)].typeEnd = Int32(m)
        }
      }
    }
  }

  /// `x =>`, `(a, b) =>`, `(a: Int, b) =>`, `{ x =>`: a lambda's parameters, seen to the end of its block.
  private mutating func lambdaParameters(_ arrow: Int) {
    let k = arrow - 1
    guard k >= 0 else { return }
    // Not a case clause's arrow, nor a function type, nor an import's rename.
    var s = arrow - 1
    let d = depth(arrow)
    while s >= 0, file.depth[s] >= d {
      if file.depth[s] == d {
        if isWord(s, ScalaWord.caseWord) || isWord(s, ScalaWord.importWord) { return }
        if unit.isByte(s, 0x3B) || file.first[s] || isPunct(s, ScalaWord.arrow) { break }
      }
      s -= 1
    }
    var params: [Int] = []
    var start = k
    if isName(k) || isWord(k, ScalaWord.underscore) {
      let byte = unit.source.text[unit.tokens[k].start]
      guard !(byte >= 0x41 && byte <= 0x5A) else { return }
      let before = k - 1
      // `x =>` right after `(` or `{`, at a line's start, or `implicit x =>`.
      if before < 0 || isOpen(before, 0x28) || isOpen(before, 0x7B) || file.first[k] || isWord(before, ScalaWord.implicitWord) || isPunct(before, ScalaWord.equals) {
        params = [k]
      }
    } else if isClose(k), match(k) >= 0, unit.isByte(k, 0x29) {
      let o = match(k)
      // `(a, b) =>`, `(a: Int) =>`, not a call's `f(x) =>` nor a type `(A, B) =>`.
      if o > 0, (isName(o - 1) && !isWord(o - 1, ScalaWord.implicitWord)) || isClose(o - 1) || isPunct(o - 1, ScalaWord.colon) { return }
      var names: [Int] = []
      var m = o + 1
      var expect = true
      while m < k {
        if file.depth[m] == depth(o) + 1 {
          if unit.isByte(m, 0x2C) {
            expect = true
          } else if expect {
            guard isName(m) || isWord(m, ScalaWord.underscore) else { return }
            let byte = unit.source.text[unit.tokens[m].start]
            if byte >= 0x41 && byte <= 0x5A, !isPunct(m + 1, ScalaWord.colon) { return }
            names.append(m)
            expect = false
          } else if !isPunct(m, ScalaWord.colon), !(isPunct(m - 1, ScalaWord.colon) || file.depth[m] > depth(o) + 1) {
            // Only `name: Type` parts.
          }
        }
        m += 1
      }
      params = names
      start = o
    }
    guard !params.isEmpty else { return }
    let o = enclosingOpen(start)
    var end = o >= 0 && match(o) >= 0 ? match(o) : regionEnd(start)
    if o < 0 { end = regionEnd(start) }
    if o >= 0, isOpen(o, 0x28), !(start == o + 1 || (start == o && false)) {
      // `f(a, x => …)`: to the argument's end.
      var m = arrow
      while m < end, !(file.depth[m] == depth(o) + 1 && unit.isByte(m, 0x2C)) { m += 1 }
      end = m
    }
    let owner = ownerOfLocal(arrow)
    for (n, p) in params.enumerated() where !isWord(p, ScalaWord.underscore) {
      guard !declared.contains(Int32(p)) else { continue }
      let index = add(.variable, nameToken: p, first: p, parent: owner, flags: .lambda, isLocal: true)
      file.info[Int(index)].scopeStart = Int32(p)
      file.info[Int(index)].scopeEnd = Int32(end)
      file.info[Int(index)].lambdaIndex = Int32(n)
      file.info[Int(index)].lambdaStart = Int32(start)
      unit.decls[Int(index)].end = Int32(p + 1)
      if isPunct(p + 1, ScalaWord.colon) {
        let e = min(typeEnd(p + 2, stopAtWith: false), arrow)
        unit.decls[Int(index)].typeStart = Int32(p + 2)
        unit.decls[Int(index)].typeEnd = Int32(e)
      }
    }
  }

  /// `_` standing for a lambda's parameter: `xs.map(_.name)`, `(_ + _)`. Recorded so the model can type it; it has no
  /// name to be found by.
  private mutating func placeholder(_ i: Int) {
    guard !declared.contains(Int32(i)) else { return }
    // Not a pattern's wildcard, an import's, a type's or `x: _*`, `f _`.
    if i > 0, isPunct(i - 1, ScalaWord.colon) || isWord(i - 1, ScalaWord.caseWord) || isPunct(i - 1, ScalaWord.at) || isOpen(i - 1, 0x5B) || isPunct(i + 1, ScalaWord.arrow) { return }
    if i > 0, unit.isByte(i - 1, 0x2E), !(i > 1 && isClose(i - 2)) && !(i > 1 && isName(i - 2)) { return }
    if i > 0, unit.isByte(i - 1, 0x2E) { return }
    let o = enclosingOpen(i)
    guard o >= 0, isOpen(o, 0x28) || isOpen(o, 0x7B) else { return }
    if isWord(o - 1, ScalaWord.caseWord) { return }
    // The argument it's in: from the `(` or `,` before it to the `,` or `)` after, at the bracket's depth.
    var start = o + 1
    var m = i
    while m > o {
      if file.depth[m] == depth(o) + 1, unit.isByte(m, 0x2C) {
        start = m + 1
        break
      }
      m -= 1
    }
    var end = match(o) > 0 ? match(o) : count
    m = i
    while m < end {
      if file.depth[m] == depth(o) + 1, unit.isByte(m, 0x2C) {
        end = m
        break
      }
      m += 1
    }
    // Which placeholder of the argument it is.
    var index: Int32 = 0
    for p in start..<i where isWord(p, ScalaWord.underscore) && file.depth[p] == file.depth[i] { index += 1 }
    let owner = ownerOfLocal(i)
    let local = add(.variable, nameToken: i, first: i, parent: owner, flags: [.lambda, .placeholder], isLocal: true, name: 0)
    file.localsByName[0, default: []].removeAll { $0 == local }
    file.info[Int(local)].scopeStart = Int32(i)
    file.info[Int(local)].scopeEnd = Int32(i + 1)
    file.info[Int(local)].lambdaIndex = index
    file.info[Int(local)].lambdaStart = Int32(start)
    file.info[Int(local)].sourceEnd = Int32(end)
    unit.decls[Int(local)].end = Int32(i + 1)
  }
}
