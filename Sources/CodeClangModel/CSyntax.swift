import CodeHighlighting
import CodeModel
import CodeScan
import Foundation

/// What a C, C++ or Objective-C file declares beyond the core's tables, kept with the unit (`scans[CFile.key]`).
final class CFile: BodyFacts {
  static let key: Int32 = -1
  func dropTypes() {}

  let dialect: CDialect
  /// A directive's token → the first token after its line.
  var ends: [Int32: Int32] = [:]
  /// `#define` (the macro's declaration) and `#undef` (-1) by name, in the file's order.
  var macroEvents: [Name: [(token: Int32, decl: Int32)]] = [:]
  /// Names the file declares where ordinary lookup finds them: file scope (enumerators, and in C every tag's).
  var ordinary: [Name: [Int32]] = [:]
  /// `struct`, `union` and `enum` tags, and C++ classes, where `struct x` finds them.
  var tags: [Name: [Int32]] = [:]
  var flags: [Int32: CFlags] = [:]
  /// A declarator's tokens around its name: from its first `*` (or the name), to after its `[…]` or `(…)`.
  var declarators: [Int32: (prefix: Int32, suffixEnd: Int32)] = [:]
  /// Out-of-line definitions (`void A::f() {…}`): the extension declarations holding them.
  var qualified: [Int32] = []
  /// `using namespace N;` and `using N::x;`: the scope they're in, where they start, the name's tokens.
  var usings: [(scope: Int32, token: Int32, start: Int32, end: Int32, isNamespace: Bool)] = []
  /// An Objective-C method's selector pieces.
  var selectors: [Int32: [Int32]] = [:]
  /// Parameters named inside a parameter's function pointer type (`int (*f)(int size)`): each its own declaration.
  var pointerParameters: Set<Int32> = []
  /// Offsets in branches the build leaves out, read when first asked.
  var leftOut: [Range<Int>]?
  /// The include guard's macro.
  var guardMacro: Name = 0

  init(dialect: CDialect) { self.dialect = dialect }

  func has(_ decl: Int32, _ flag: CFlags) -> Bool { flags[decl]?.contains(flag) == true }
  func set(_ decl: Int32, _ flag: CFlags) { flags[decl, default: []].insert(flag) }
}

struct CFlags: OptionSet {
  let rawValue: UInt16
  static let extern = CFlags(rawValue: 1)
  static let forward = CFlags(rawValue: 2)
  static let union = CFlags(rawValue: 4)
  static let scoped = CFlags(rawValue: 8)
  static let anonymous = CFlags(rawValue: 16)
  static let inline = CFlags(rawValue: 32)
  static let property = CFlags(rawValue: 64)
  static let implementation = CFlags(rawValue: 128)
  static let functionMacro = CFlags(rawValue: 256)
  static let virtual = CFlags(rawValue: 512)
  static let classKeyword = CFlags(rawValue: 1024)
  static let alias = CFlags(rawValue: 2048)
  /// A struct or union without a name or a declarator: its members are its parent's.
  static let transparent = CFlags(rawValue: 4096)
}

/// C, C++ and Objective-C read into the core's tables (`CParser`), with the preprocessor's part done as the platform
/// builds: a directive's line becomes its words (`#define` declares a macro, `#include` imports the header it finds),
/// and `#if` branches are taken as the predefined macros, the compile commands' `-D` and the project's headers say.
final class CSyntax: LanguageSyntax {
  let profile: LexProfile
  let parametersHaveLabels = false
  /// Finds an included header: `(spelling, angled, includer, include_next)` → its path.
  var resolve: (String, Bool, String, Bool) -> String? = { _, _, _, _ in nil }
  /// The project's macros for `#if`, per dialect.
  var macros: (CDialect) -> CMacroTable = { _ in CMacroTable() }
  /// What an included header leaves defined, by its path.
  var included: (String, CDialect) -> [Name: CMacro?] = { _, _ in [:] }
  /// The dialect of a header: the project's.
  var headerDialect: CDialect = .c

  init() { profile = CSyntax.familyProfile }

  /// One lexer for every file of the family: C's, C++'s and Objective-C's keywords, `@` words and `@"…"` strings. Words
  /// that are declared types or macros in headers (`BOOL`, `id`, `NULL`) stay identifiers.
  static let familyProfile: LexProfile = {
    var words = Set<String>()
    for alias in ["c", "cpp", "objective-c"] { words.formUnion(CodeHighlighter.spec(forLanguage: alias)?.keywords ?? []) }
    words.subtract(["NULL", "BOOL", "Class", "SEL", "id", "instancetype", "YES", "NO", "nil", "Nil", "nonnull", "nullable", "null_resettable", "null_unspecified", "IMP"])
    let spec = LanguageSpec(
      name: "C family (CodeClangModel)", aliases: [], lineComments: ["//"], blockComments: [("/*", "*/")],
      strings: [StringDelim(open: "@\"", close: "\""), StringDelim(open: "\"")], charLiteral: "'", keywords: words,
      hashDirectives: true, hashDirectivesAnchored: true, atWords: true)
    return LexProfile.profile(for: spec)
  }()

  func dialect(of path: String) -> CDialect { CDialect.of(path: path) ?? headerDialect }

  func parse(_ unit: Unit) -> UInt64 {
    let file = CFile(dialect: dialect(of: unit.path))
    unit.scans[CFile.key] = file
    var parser = CParser(unit: unit, file: file, syntax: self)
    parser.parseFile()
    return parser.shape
  }

  // MARK: Directives

  /// The source's tokens without comments, a directive's line split into its words: `#define` (a directive),
  /// then the line's identifiers, numbers, strings and punctuation (brackets as punctuation, so that a macro's `{`
  /// never opens anything); an `#include`'s header is one string.
  func codeTokens(_ source: SourceFile) -> [Token] {
    var kept = [Token]()
    kept.reserveCapacity(source.tokens.count + source.tokens.count / 8)
    let text = source.text
    for token in source.tokens {
      switch token.kind {
      case .comment, .docComment: continue
      case .directive: split(token, text, into: &kept)
      default: kept.append(token)
      }
    }
    return kept
  }

  private func isWordByte(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x24 || c >= 0x80 }

  private func split(_ token: Token, _ t: UnsafePointer<UInt8>, into out: inout [Token]) {
    let end = token.end
    var i = token.start + 1
    while i < end, t[i] == 0x20 || t[i] == 0x09 { i += 1 }
    var wordEnd = i
    while wordEnd < end, isWordByte(t[wordEnd]) { wordEnd += 1 }
    out.append(Token(kind: .directive, start: token.start, end: wordEnd))
    let word = wordEnd - i
    // `include`, `import`, `include_next`: the header's name is one string.
    let isInclude = (word == 7 && memcmp(t + i, "include", 7) == 0) || (word == 6 && memcmp(t + i, "import", 6) == 0)
      || (word == 12 && memcmp(t + i, "include_next", 12) == 0)
    i = wordEnd
    if isInclude {
      while i < end, t[i] == 0x20 || t[i] == 0x09 { i += 1 }
      if i < end, t[i] == 0x3C || t[i] == 0x22 {
        let close: UInt8 = t[i] == 0x3C ? 0x3E : 0x22
        var j = i + 1
        while j < end, t[j] != close, t[j] != 0x0A { j += 1 }
        out.append(Token(kind: .string, start: i, end: min(j + 1, end)))
        return
      }
    }
    while i < end {
      let c = t[i]
      if c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A || c == 0x5C || c == 0x0C {
        i += 1
        continue
      }
      if c == 0x2F, i + 1 < end, t[i + 1] == 0x2F { return }
      if c == 0x2F, i + 1 < end, t[i + 1] == 0x2A {
        i += 2
        while i + 1 < end, !(t[i] == 0x2A && t[i + 1] == 0x2F) { i += 1 }
        i += 2
        continue
      }
      if isWordByte(c), !(c >= 0x30 && c <= 0x39) {
        var j = i + 1
        while j < end, isWordByte(t[j]) { j += 1 }
        out.append(Token(kind: .identifier, start: i, end: j))
        i = j
        continue
      }
      if c >= 0x30, c <= 0x39 {
        var j = i + 1
        while j < end, isWordByte(t[j]) || t[j] == 0x2E { j += 1 }
        out.append(Token(kind: .number, start: i, end: j))
        i = j
        continue
      }
      if c == 0x22 || c == 0x27 {
        var j = i + 1
        while j < end, t[j] != c, t[j] != 0x0A { j += t[j] == 0x5C ? 2 : 1 }
        j = min(j + 1, end)
        out.append(Token(kind: .string, start: i, end: j))
        i = j
        continue
      }
      if c == 0x28 || c == 0x29 || c == 0x5B || c == 0x5D || c == 0x7B || c == 0x7D || c == 0x2C || c == 0x3B {
        out.append(Token(kind: .punctuation, start: i, end: i + 1))
        i += 1
        continue
      }
      var j = i + 1
      let single: Set<UInt8> = [0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x2C, 0x3B, 0x22, 0x27, 0x20, 0x09, 0x0A, 0x0D, 0x5C]
      while j < end, !isWordByte(t[j]), !single.contains(t[j]), !(t[j] == 0x2F && j + 1 < end && (t[j + 1] == 0x2F || t[j + 1] == 0x2A)) { j += 1 }
      out.append(Token(kind: .punctuation, start: i, end: j))
      i = j
    }
  }

  /// The directive's word: `define`, `if`, `include`.
  func directiveName(_ unit: Unit, _ i: Int) -> String {
    let token = unit.tokens[i]
    var start = token.start + 1
    let text = unit.source.text
    while start < token.end, text[start] == 0x20 || text[start] == 0x09 { start += 1 }
    return String(decoding: UnsafeBufferPointer(start: text + start, count: token.end - start), as: UTF8.self)
  }

  func conditional(_ unit: Unit, _ i: Int) -> ConditionalDirective {
    let token = unit.tokens[i]
    let text = unit.source.text
    var start = token.start + 1
    while start < token.end, text[start] == 0x20 || text[start] == 0x09 { start += 1 }
    let length = token.end - start
    guard length >= 2, text[start] == 0x69 || text[start] == 0x65 else { return .none }
    func word(_ literal: StaticString) -> Bool { length == literal.utf8CodeUnitCount && memcmp(text + start, literal.utf8Start, length) == 0 }
    if word("if") || word("ifdef") || word("ifndef") { return .opens }
    if word("endif") { return .closes }
    if word("else") { return .otherwise }
    if word("elif") || word("elifdef") || word("elifndef") { return .alternative }
    return .none
  }

  /// The first token after the directive at `i`: its line ends at a line break that no `\` continues.
  func directiveEnd(_ unit: Unit, _ i: Int) -> Int {
    var j = i + 1
    let text = unit.source.text
    while j < unit.tokens.count {
      let from = unit.tokens[j - 1].end
      let to = unit.tokens[j].start
      var k = from
      var broken = false
      while k < to {
        if text[k] == 0x0A {
          var back = k - 1
          while back >= from, text[back] == 0x0D || text[back] == 0x20 || text[back] == 0x09 { back -= 1 }
          if back < from || text[back] != 0x5C {
            broken = true
            break
          }
        }
        k += 1
      }
      if broken { return j }
      // A directive's own words only: the next code token starts a line.
      j += 1
    }
    return j
  }

  func evaluateCondition(_ unit: Unit, _ i: inout Int) -> Bool {
    let directive = i - 1
    let end = directiveEnd(unit, directive)
    defer { i = end }
    let file = unit.scans[CFile.key] as? CFile
    let dialect = file?.dialect ?? self.dialect(of: unit.path)
    let word = directiveName(unit, directive)
    let table = macros(dialect)
    let path = unit.path
    // A macro as it stands at this token: the file's own `#define`s and `#undef`s before it, then the project's.
    let included = self.included
    let lookup: (Name) -> CMacro? = { key in
      if let events = file?.macroEvents[key], let last = events.last(where: { $0.token < Int32(directive) }) {
        guard last.decl >= 0 else { return nil }
        let decl = unit.decls[Int(last.decl)]
        let value = decl.initStart >= 0 ? unit.rawText(from: Int(decl.initStart), to: Int(decl.initEnd)) : ""
        return CMacro(value: value, isFunction: file?.has(last.decl, .functionMacro) == true)
      }
      // What the headers included before it leave, the last first.
      for item in unit.imports.reversed() where item.token < Int32(directive) && item.moduleName.hasPrefix("/") {
        if let found = included(item.moduleName, dialect)[key] { return found }
      }
      guard let macro = table.macros[key], table.definedIn[key] != path else { return nil }
      return macro
    }
    if word == "ifdef" || word == "ifndef" || word == "elifdef" || word == "elifndef" {
      guard directive + 1 < end else { return true }
      let key = unit.hash(directive + 1)
      // An include guard is always taken: the file defines it right after.
      if word == "ifndef", let file, key == file.guardMacro { return true }
      let defined = lookup(key) != nil || CCondition.checkNames.contains(key)
      return word.hasSuffix("ndef") ? !defined : defined
    }
    guard directive + 1 < end else { return false }
    let condition = CCondition(lookup: lookup, hasInclude: { [weak self] spelling, angled in self?.resolve(spelling, angled, path, false) != nil }, dialect: dialect)
    return condition.evaluate(unit.rawText(from: directive + 1, to: end))
  }
}

extension Unit {
  /// The source between two tokens, as written.
  func rawText(from start: Int, to end: Int) -> String {
    guard start >= 0, end > start, end <= tokens.count else { return "" }
    let from = tokens[start].start
    let to = tokens[end - 1].end
    return String(decoding: UnsafeBufferPointer(start: source.text + from, count: to - from), as: UTF8.self)
  }

  var cFile: CFile { unsafeDowncast(scans[CFile.key]!, to: CFile.self) }
}
