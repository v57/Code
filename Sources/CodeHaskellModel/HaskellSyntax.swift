import CodeModel
import CodeScan
import Foundation

/// Haskell's syntax for the core: the layout rule turns a file's tokens into a stream with virtual braces and
/// semicolons (`HaskellBlocks`), and `HaskellParser` reads the stream whole, resolving every local name as Haskell's
/// scoping does (patterns, `where`, `let`, `do`, `case`, lambdas, guards, comprehensions, type variables) and keeping
/// what it found in `HaskellFile`. The file's declarations are what other modules can see: top-level functions and
/// values, data types with their constructors and fields, type synonyms and families, classes with their methods,
/// pattern synonyms and foreign imports. Lines of the C preprocessor (`#if` …) are left out, so both branches are read.
final class HaskellSyntax: LanguageSyntax {
  let profile = LexProfile.profile(forLanguage: "haskell")!
  let parametersHaveLabels = false
  /// Files read, for the model to know its answers about a file's tokens went stale.
  let parses = HaskellCounter()
  /// `default-extensions` by package folder, and the package folders longest first.
  let packageExtensions: [String: Set<String>]
  let packages: [String]

  init(packageExtensions: [String: Set<String>] = [:], packages: [String] = []) {
    self.packageExtensions = packageExtensions
    self.packages = packages
  }

  func parse(_ unit: CodeModel.Unit) -> UInt64 {
    parses.increment()
    var extensions = HaskellSyntax.pragmaExtensions(unit.source)
    if let package = packages.first(where: { unit.path.hasPrefix($0 + "/") }) { extensions.formUnion(packageExtensions[package] ?? []) }
    var parser = HaskellParser(unit: unit, extensions: extensions)
    parser.parseModule()
    unit.scans[HaskellFile.key] = parser.file
    return parser.shape()
  }

  func evaluateCondition(_ unit: CodeModel.Unit, _ i: inout Int) -> Bool { true }

  func conditional(_ unit: CodeModel.Unit, _ i: Int) -> ConditionalDirective { .none }

  /// The source's tokens without comments and without the C preprocessor's lines.
  func codeTokens(_ source: SourceFile) -> [Token] {
    var kept = [Token]()
    kept.reserveCapacity(source.tokens.count)
    let text = source.text
    var skipUntil = -1
    for token in source.tokens where token.kind != .comment && token.kind != .docComment {
      if token.start < skipUntil { continue }
      if text[token.start] == 0x23, token.start == 0 || text[token.start - 1] == 0x0A {
        // To the end of the line, and the next while it ends in `\`.
        var end = token.start
        while end < source.count {
          if text[end] == 0x0A {
            if end > 0, text[end - 1] == 0x5C { end += 1; continue }
            break
          }
          end += 1
        }
        skipUntil = end
        continue
      }
      kept.append(token)
    }
    return kept
  }

  /// `{-# LANGUAGE A, B #-}` pragmas' extensions.
  static func pragmaExtensions(_ source: SourceFile) -> Set<String> {
    var result: Set<String> = []
    for token in source.tokens where token.kind == .comment {
      guard token.length > 6, source.text[token.start] == 0x7B, source.text[token.start + 2] == 0x23 else { continue }
      let text = source.string(token)
      guard let range = text.range(of: "LANGUAGE", options: .caseInsensitive) else { continue }
      let body = text[range.upperBound...].replacingOccurrences(of: "#-}", with: "")
      for word in body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }) { result.insert(String(word)) }
    }
    return result
  }
}

/// Haskell's two namespaces: values (variables, constructors, fields, methods) and types (types, classes, families).
enum HsNamespace: UInt8 {
  case value, type
}

/// What a name token is.
enum HsUse {
  /// A local's use or declaration (a variable or type variable): its declaring token.
  case local(Int32)
  /// A free unqualified name: the module's own top level, then its imports.
  case free(HsNamespace)
  /// A field's name in record syntax (`C { f = … }`, `r { f = … }`): a field, never a local.
  case field
  /// `Q.x`: the qualifier's text, by its hash in `HaskellFile.texts`.
  case qualified(Name, HsNamespace)
  /// A word of the qualifier in `Q.x`: the module the qualifier names.
  case qualifier(Name)
  /// A word of a module's name in `module` or `import` (or an import's alias): the module's file.
  case module(Name)
  /// The name of a method an instance body defines: the class's method, by the instance's index.
  case method(Int32)
  /// `x.f` with OverloadedRecordDot: a field by its name.
  case recordDot
  /// An item of an import's list: the import's index.
  case imported(Int32, HsNamespace)
  /// `T(a)` in an import's list: the import's index, the parent's token.
  case importedSub(Int32, Int32)
  /// `T(a)` in the export list: the parent's token.
  case exportedSub(Int32)
}

struct HsLocal {
  enum Kind: UInt8 { case parameter, binding, typeVariable, field }
  var kind: Kind
  /// Where it can be seen, tokens: from, to (exclusive).
  var from: Int32
  var to: Int32
}

/// A declaration's role, parallel to `Unit.decls`.
struct HsDeclInfo {
  enum Kind: UInt8 {
    case function, variable, data, newtype, typeSynonym, typeFamily, dataFamily, classDecl, method, constructor, field, patternSynonym, foreign
    case associatedType
  }
  var kind: Kind
  /// The signature's type (or a field's, a constructor's arguments, a synonym's right side), tokens; -1 when none.
  var typeStart: Int32 = -1
  var typeEnd: Int32 = -1
  /// The first token of what declares it (the signature's, when there's one before), for its documentation.
  var statement: Int32
}

struct HsItem {
  enum Subs { case none, all, some([(name: Name, token: Int32)]) }
  var name: Name
  var token: Int32
  var namespace: HsNamespace
  var subs: Subs = .none
  /// `module X` in an export list: the module's name.
  var module: String?
  /// `Q.x` in an export list: the qualifier's hash.
  var qualifier: Name = 0
}

struct HsImport {
  var module: String
  var moduleToken: Int32
  var isQualified = false
  var alias: String?
  var isHiding = false
  /// Nil: everything the module exports.
  var items: [HsItem]?
  var line: Int32
}

struct HsInstance {
  /// The class's name token (its last word when qualified) and qualifier.
  var classToken: Int32
  var qualifier: Name
}

/// A file as the parser read it. Kept in `Unit.scans`.
final class HaskellFile: BodyFacts {
  static let key = Int32.min + 2
  var moduleName = "Main"
  /// The tokens of the module's name in its header, -1 without one.
  var moduleToken: Int32 = -1
  var hasHeader = false
  /// Nil: the module exports everything it declares.
  var exports: [HsItem]?
  var imports: [HsImport] = []
  var uses: [Int32: HsUse] = [:]
  var locals: [Int32: HsLocal] = [:]
  var info: [HsDeclInfo] = []
  var topValues: [Name: [Int32]] = [:]
  var topTypes: [Name: [Int32]] = [:]
  /// A constructor's declaration to its fields' declarations.
  var constructorFields: [Int32: [Int32]] = [:]
  var instances: [HsInstance] = []
  /// `C{..}` in patterns: the constructor's token (its last word) and qualifier.
  var wildcards: [(token: Int32, qualifier: Name)] = []
  /// A name a wildcard (`C{..}`) is between it and its binding: the wildcards' indexes, innermost first.
  var wildcardShadow: [Int32: [Int32]] = [:]
  /// A local binding's signature: its type's tokens.
  var localSignatures: [Int32: (Int32, Int32)] = [:]
  /// Qualifiers' and modules' texts by hash.
  var texts: [Name: String] = [:]
  var extensions: Set<String> = []

  func dropTypes() {}

  var importsPrelude: Bool { imports.contains { $0.module == "Prelude" } }
}

/// How many files Haskell's syntax has read, across threads (`Project.parse` reads in parallel).
final class HaskellCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

/// The layout rule (Haskell 2010's §10.3), with its parse-error(t) rule taken as the cases that need it in practice:
/// `in` closes a `let` block, a closing bracket the blocks opened inside it, a comma the blocks opened at its bracket
/// level (not inside a guard), and `then`, `else` and `of` the blocks opened since their `if` or `case`.
enum HaskellBlocks {
  static let open: Int32 = -1, semicolon: Int32 = -2, close: Int32 = -3

  private struct Context {
    /// The block's column, from 1; 0 for explicit braces.
    var indent: Int32
    var depth: Int32
    var isLet: Bool
    /// Opened by `where` (or the module's top level): where a `where` can start an item.
    var isWhere = false
    var inGuard = false
  }

  /// The tokens with virtual braces and semicolons as negative codes.
  static func stream(_ unit: Unit) -> [Int32] {
    let tokens = unit.tokens
    let text = unit.source.text
    var out: [Int32] = []
    out.reserveCapacity(tokens.count + tokens.count / 4 + 8)
    var contexts: [Context] = []
    var depth: Int32 = 0
    var conditionals: [(contexts: Int, isCase: Bool, depth: Int32)] = []
    var pending = false
    var pendingLet = false
    var pendingWhere = false

    func column(_ i: Int) -> Int32 {
      var start = tokens[i].start
      while start > 0, text[start - 1] != 0x0A { start -= 1 }
      var column: Int32 = 0
      var k = start
      while k < tokens[i].start {
        let byte = text[k]
        if byte == 0x09 { column = (column / 8 + 1) * 8 } else if byte & 0xC0 != 0x80 { column += 1 }
        k += 1
      }
      return column + 1
    }
    func word(_ i: Int, _ value: StaticString) -> Bool {
      let kind = tokens[i].kind
      return (kind == .keyword || kind == .declarationKeyword) && unit.isToken(i, value)
    }
    func closeImplicit(while condition: (Context) -> Bool) {
      while let top = contexts.last, top.indent > 0, condition(top) {
        out.append(close)
        contexts.removeLast()
      }
    }

    guard !tokens.isEmpty else { return [] }
    if !word(0, "module") {
      contexts.append(Context(indent: column(0), depth: 0, isLet: false, isWhere: true))
      out.append(open)
    }
    for i in tokens.indices {
      let token = tokens[i]
      let isOpenBrace = token.kind == .open && text[token.start] == 0x7B
      var opened = false
      if pending {
        pending = false
        if isOpenBrace {
          depth += 1
          contexts.append(Context(indent: 0, depth: depth, isLet: pendingLet, isWhere: pendingWhere))
          out.append(Int32(i))
          continue
        }
        let n = column(i)
        if n > (contexts.last?.indent ?? 0) {
          contexts.append(Context(indent: n, depth: depth, isLet: pendingLet, isWhere: pendingWhere))
          out.append(open)
          opened = true
        } else {
          out.append(open)
          out.append(close)
        }
      }
      if !opened, unit.startsLine(i) {
        let n = column(i)
        closeImplicit { n < $0.indent }
        // A `where` lined up with a `do`, `case` or `let` block's items ends it: it's the equation's.
        if word(i, "where") { closeImplicit { n == $0.indent && !$0.isWhere } }
        while let last = conditionals.last, last.contexts > contexts.count { conditionals.removeLast() }
        if let top = contexts.last, top.indent > 0, n == top.indent, !word(i, "then"), !word(i, "else") {
          out.append(semicolon)
          contexts[contexts.count - 1].inGuard = false
        }
      }
      switch token.kind {
      case .keyword, .declarationKeyword:
        if word(i, "in") {
          // Up to and including the innermost `let` among the implicit blocks on top.
          if let at = contexts.lastIndex(where: { $0.isLet || $0.indent == 0 }), contexts[at].isLet, contexts[at].indent > 0,
            contexts[at...].allSatisfy({ $0.indent > 0 })
          {
            while contexts.count > at {
              out.append(close)
              contexts.removeLast()
            }
          }
        } else if word(i, "then") || word(i, "else") || word(i, "of") {
          let isOf = word(i, "of")
          if let at = conditionals.lastIndex(where: { $0.isCase == isOf }), conditionals[at].depth == depth {
            let keep = conditionals[at].contexts
            while contexts.count > keep, let top = contexts.last, top.indent > 0 {
              out.append(close)
              contexts.removeLast()
            }
            if word(i, "else") || isOf { conditionals.remove(at: at) }
          }
        } else if word(i, "if") {
          if i + 1 < tokens.count, !unit.isToken(i + 1, "|") { conditionals.append((contexts.count, false, depth)) }
        } else if word(i, "case") {
          if !(i > 0 && unit.isToken(i - 1, "\\")) { conditionals.append((contexts.count, true, depth)) }
        }
      case .close:
        closeImplicit { $0.depth >= depth }
        while let last = conditionals.last, last.depth >= depth, depth > 0 { conditionals.removeLast() }
        if text[token.start] == 0x7D, let top = contexts.last, top.indent == 0, top.depth == depth { contexts.removeLast() }
        depth = max(0, depth - 1)
      case .open:
        break
      case .punctuation:
        if token.length == 1, text[token.start] == 0x2C {
          closeImplicit { $0.depth == depth && !$0.inGuard && ($0.isLet || depth > 0) }
        } else if token.length == 1, text[token.start] == 0x7C {
          if let top = contexts.last, top.indent > 0, top.depth == depth { contexts[contexts.count - 1].inGuard = true }
        } else if unit.isToken(i, "->") || unit.isToken(i, "=") {
          if let top = contexts.last, top.depth == depth { contexts[contexts.count - 1].inGuard = false }
        }
      default:
        break
      }
      out.append(Int32(i))
      if token.kind == .open { depth += 1 }
      if token.kind == .keyword || token.kind == .declarationKeyword {
        if word(i, "where") || word(i, "let") || word(i, "do") || word(i, "of") || word(i, "mdo") {
          pending = true
          pendingLet = word(i, "let")
          pendingWhere = word(i, "where")
        } else if word(i, "case") || word(i, "cases"), i > 0, unit.isToken(i - 1, "\\") {
          pending = true
          pendingLet = false
          pendingWhere = false
        }
      } else if token.kind == .identifier, unit.isToken(i, "cases"), i > 0, unit.isToken(i - 1, "\\") {
        pending = true
        pendingLet = false
      }
    }
    if pending {
      out.append(open)
      out.append(close)
    }
    for context in contexts.reversed() where context.indent > 0 { out.append(close) }
    return out
  }
}
