import CodeModel
import CodeScan
import Foundation

/// Words the parser tells apart, hashed once.
enum CWord {
  static let typeKeywords: Set<Name> = Set(
    [
      "void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "_Bool", "bool", "wchar_t", "char8_t", "char16_t",
      "char32_t", "__int128", "_Complex", "_Imaginary", "__int64", "__int32", "_Float16", "__fp16", "__bf16", "auto",
    ].map { name($0) })
  static let storage: Set<Name> = Set(
    [
      "static", "extern", "inline", "__inline", "__inline__", "register", "thread_local", "_Thread_local", "__thread", "constexpr", "consteval",
      "constinit", "virtual", "explicit", "friend", "mutable", "_Noreturn", "__extension__", "typedef", "__forceinline", "__private_extern__",
    ].map { name($0) })
  static let qualifiers: Set<Name> = Set(
    [
      "const", "volatile", "restrict", "__restrict", "__restrict__", "__const", "__volatile__", "_Nonnull", "_Nullable", "_Null_unspecified",
      "__nonnull", "__nullable", "_Nullable_result", "__unsafe_unretained", "__strong", "__weak", "__autoreleasing", "__kindof", "__block",
      "__covariant", "__contravariant", "IBOutlet", "IBInspectable", "nonnull", "nullable", "null_unspecified", "null_resettable", "__unaligned",
      "__ptr32", "__ptr64", "__w64", "__cdecl", "__stdcall", "__fastcall", "__thiscall", "__vectorcall", "oneway", "in", "out", "inout", "bycopy",
      "byref", "__sptr", "__uptr", "_Atomic", "__single", "__indexable", "__bidi_indexable", "__unsafe_indexable", "__counted_by",
    ].map { name($0) })
  static let attributes: Set<Name> = Set(
    [
      "__attribute__", "__attribute", "__declspec", "alignas", "_Alignas", "__asm__", "__asm", "asm", "__pragma", "_Pragma", "noexcept",
      "throw", "__has_feature",
    ].map { name($0) })
  static let typeofWords: Set<Name> = Set(["decltype", "typeof", "__typeof__", "__typeof", "__underlying_type", "_Atomic"].map { name($0) })
  static let structWord = name("struct"), unionWord = name("union"), enumWord = name("enum"), classWord = name("class")
  static let typedefWord = name("typedef"), externWord = name("extern"), staticWord = name("static"), inlineWords: Set<Name> = [name("inline"), name("__inline"), name("__inline__")]
  static let virtualWord = name("virtual"), friendWord = name("friend"), namespaceWord = name("namespace"), templateWord = name("template")
  static let libcxxBeginStd = name("_LIBCPP_BEGIN_NAMESPACE_STD"), libcxxEndStd = name("_LIBCPP_END_NAMESPACE_STD")
  static let libcxxBeginUnversionedStd = name("_LIBCPP_BEGIN_UNVERSIONED_NAMESPACE_STD"), libcxxEndUnversionedStd = name("_LIBCPP_END_UNVERSIONED_NAMESPACE_STD")
  /// Words that start a declaration no attribute macro comes before.
  static let declarationStarts: Set<Name> = Set(["namespace", "template", "using", "typedef", "class", "struct", "union", "enum", "extern"].map { name($0) })
  static let usingWord = name("using"), operatorWord = name("operator"), typenameWord = name("typename"), constWord = name("const")
  static let publicWord = name("public"), privateWord = name("private"), protectedWord = name("protected")
  static let staticAssert: Set<Name> = [name("static_assert"), name("_Static_assert")]
  static let defineWord = name("define")
  /// The Foundation and CoreFoundation macros that declare an enum and its type: `typedef NS_ENUM(NSInteger, Name) {…}`.
  static let enumMacros: Set<Name> = Set(
    [
      "NS_ENUM", "NS_OPTIONS", "NS_CLOSED_ENUM", "NS_ERROR_ENUM", "CF_ENUM", "CF_OPTIONS", "CF_CLOSED_ENUM", "NS_SWIFT_ENUM", "OS_ENUM",
      "XPC_ENUM", "DISPATCH_ENUM", "DISPATCH_OPTIONS",
    ].map { name($0) })
}

extension Unit {
  /// An identifier or keyword: a word that can name something or say what something is.
  func isWord(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    let kind = tokens[i].kind
    return kind == .identifier || kind == .keyword || kind == .declarationKeyword
  }

  /// A word written in capitals with an underscore (`API_AVAILABLE`, `CMARK_GFM_EXPORT`) or starting `__`: an
  /// attribute-like macro rather than a type, when something else names the type.
  func isMacroLike(_ i: Int) -> Bool {
    guard isWord(i) else { return false }
    let token = tokens[i]
    let text = source.text + token.start
    if token.length > 2, text[0] == 0x5F, text[1] == 0x5F { return true }
    var underscore = false
    for k in 0..<token.length {
      let c = text[k]
      if c >= 0x61, c <= 0x7A { return false }
      if c == 0x5F { underscore = true }
    }
    return underscore
  }

  /// Punctuation whose first byte is `byte`: lexed runs (`**`, `=-`) count by their first.
  func startsWith(_ i: Int, _ byte: UInt8) -> Bool {
    guard i >= 0, i < tokens.count, tokens[i].kind == .punctuation else { return false }
    return source.text[tokens[i].start] == byte
  }

  /// `=` alone or followed by a unary operator in the same run (`=-1`), not `==`.
  func isAssign(_ i: Int) -> Bool {
    guard startsWith(i, 0x3D) else { return false }
    return tokens[i].length == 1 || source.text[tokens[i].start + 1] != 0x3D
  }
}

/// Reads a C-family file's declarations into the core's tables:
///
/// - Functions, variables, fields, typedefs (`typeAlias`), `struct`/`union` (`structure`), `enum` with its constants
///   (`enumCase`, which C sees in the enclosing scope), macros (`macro`, at their `#define`, with their parameters).
/// - C++: classes (`classType`), namespaces (`namespace`), templates' parameters as generics, `using` aliases,
///   constructors and destructors, and out-of-line definitions (`void A::f() {…}`) held by an `extensionDecl` named A.
/// - Objective-C: `@interface` (`classType`; a category or extension is an `extensionDecl`), `@protocol`
///   (`protocolType`), `@implementation` (an `extensionDecl` of its class), methods named by their selector
///   (`initWithFrame:style:`) and properties.
/// - A declaration's specifiers are its `type…` range, its declarator's other tokens `CFile.declarators`.
struct CParser {
  let unit: Unit
  let file: CFile
  let syntax: CSyntax
  var shape: UInt64 = 14_695_981_039_346_656_037
  private let count: Int
  private let isCpp: Bool
  private let isObjC: Bool

  init(unit: Unit, file: CFile, syntax: CSyntax) {
    self.unit = unit
    self.file = file
    self.syntax = syntax
    count = unit.tokens.count
    isCpp = file.dialect.contains(.cpp)
    isObjC = file.dialect.contains(.objc)
  }

  private mutating func mix(_ from: Int, _ to: Int) {
    var i = from
    while i < min(to, count) {
      shape = (shape ^ unit.hash(i)) &* 1_099_511_628_211
      i += 1
    }
  }

  mutating func parseFile() {
    for i in 0..<count where unit.tokens[i].kind == .directive {
      file.ends[Int32(i)] = Int32(syntax.directiveEnd(unit, i))
    }
    findGuard()
    members(from: 0, to: count, parent: -1, scope: .file)
  }

  /// `#ifndef X` then `#define X` first in a file: X guards it.
  private func findGuard() {
    var i = 0
    while i < count, unit.tokens[i].kind == .directive, syntax.conditional(unit, i) == .none, !isDirective(i, "ifndef") {
      // `#pragma once` and the like before it.
      i = Int(file.ends[Int32(i)] ?? Int32(i + 1))
    }
    guard i + 1 < count, isDirective(i, "ifndef") else { return }
    let next = Int(file.ends[Int32(i)] ?? Int32(i + 2))
    guard next + 1 < count, isDirective(next, "define"), unit.hash(next + 1) == unit.hash(i + 1) else { return }
    file.guardMacro = unit.hash(i + 1)
  }

  private func isDirective(_ i: Int, _ word: String) -> Bool {
    guard i >= 0, i < count, unit.tokens[i].kind == .directive else { return false }
    return syntax.directiveName(unit, i) == word
  }

  // MARK: Tokens

  /// After a directive (a taken branch entered, one not taken skipped, any other line passed).
  private func past(_ i: Int) -> Int {
    if syntax.conditional(unit, i) != .none { return unit.takeDirective(i) }
    return Int(file.ends[Int32(i)] ?? Int32(i + 1))
  }

  /// The next token from `i` that isn't a directive.
  private func skipDirectives(_ i: Int) -> Int {
    var j = i
    while j < count, unit.tokens[j].kind == .directive { j = past(j) }
    return j
  }

  private func next(_ i: Int) -> Int { skipDirectives(i + 1) }

  private func word(_ i: Int) -> Name { unit.hash(i) }

  /// Past a bracket's match.
  private func skipGroup(_ open: Int) -> Int { unit.skipBalanced(open) }

  /// Past `<…>` from its `<`, as template arguments: `>>` closes two.
  private func skipAngles(_ open: Int) -> Int {
    var depth = 0
    var i = open
    while i < count {
      let token = unit.tokens[i]
      if token.kind == .open {
        if unit.isByte(i, 0x7B) { return i }
        i = skipGroup(i)
        continue
      }
      if token.kind == .close { return i }
      if token.kind == .punctuation {
        let text = unit.source.text + token.start
        if text[0] == 0x3B { return i }
        for k in 0..<token.length {
          if text[k] == 0x3C { depth += 1 }
          if text[k] == 0x3E, !(k > 0 && text[k - 1] == 0x2D) {
            depth -= 1
            if depth == 0 { return i + 1 }
          }
        }
      }
      i += 1
    }
    return i
  }

  /// A `<` after a name that opens template arguments (C++ only): its match is found before a `;`, `{` or `)`.
  private func opensTemplate(_ i: Int) -> Bool {
    // Objective-C's generics (`NSArray<NSString *> *`) too.
    guard isCpp || (isObjC && i > 0 && unit.isWord(i - 1) && !unit.isMacroLike(i - 1)), unit.isByte(i, 0x3C) || (unit.startsWith(i, 0x3C) && !unit.isToken(i, "<<") && !unit.isToken(i, "<=")) else { return false }
    let end = skipAngles(i)
    guard end > i + 1, end <= count, end - 1 < count, unit.tokens[end - 1].kind == .punctuation else { return false }
    // `>`, `>*`, `*>`: the closing token holds a `>`.
    let close = unit.tokens[end - 1]
    return (0..<close.length).contains { unit.source.text[close.start + $0] == 0x3E }
  }

  private func addDecl(_ decl: Decl) -> Int32 {
    unit.decls.append(decl)
    return Int32(unit.decls.count - 1)
  }

  // MARK: Scopes

  enum Scope { case file, namespace, record(Int32), objc(Int32) }

  /// Declarations from `from` up to `end` (or an `@end` in an Objective-C container): returns where it stopped.
  @discardableResult
  mutating func members(from: Int, to end: Int, parent: Int32, scope: Scope, access startAccess: Access = .isPublic) -> Int {
    var i = from
    var access = startAccess
    while i < end {
      let token = unit.tokens[i]
      switch token.kind {
      case .directive:
        i = directive(i)
        continue
      case .close:
        i += 1
        continue
      case .attribute:
        if unit.isToken(i, "@end") {
          if case .objc = scope { return i }
          i += 1
          continue
        }
        i = objcAt(i, parent: parent, scope: scope)
        continue
      default: break
      }
      if unit.isByte(i, 0x3B) {
        i += 1
        continue
      }
      if case .objc(let container) = scope, unit.isByte(i, 0x2D) || unit.isByte(i, 0x2B) {
        i = method(i, parent: container)
        continue
      }
      if unit.isWord(i) {
        let w = word(i)
        if (w == CWord.publicWord || w == CWord.privateWord || w == CWord.protectedWord), unit.isByte(i + 1, 0x3A) || unit.isToken(i + 1, ":") {
          access = w == CWord.publicWord ? .isPublic : w == CWord.privateWord ? .isPrivate : .inherited
          i += 2
          continue
        }
        if w == CWord.namespaceWord, isCpp || unit.isWord(i + 1) && unit.isByte(i + 2, 0x7B) {
          i = namespace(i, parent: parent)
          continue
        }
        // libc++ opens and closes `std` with macros.
        if isCpp, w == CWord.libcxxBeginStd || w == CWord.libcxxBeginUnversionedStd, parent < 0 || unit.decls[Int(parent)].kind == .namespace {
          i = macroNamespace(i, end: end, parent: parent)
          continue
        }
        if w == CWord.externWord, unit.tokens.indices.contains(i + 1), unit.tokens[i + 1].kind == .string {
          // `extern "C" { … }` holds declarations as if they weren't in it.
          if unit.isByte(i + 2, 0x7B) {
            let close = skipGroup(i + 2) - 1
            mix(i, i + 3)
            members(from: i + 3, to: close, parent: parent, scope: scope, access: access)
            i = close + 1
          } else {
            i = declaration(i + 2, end: end, parent: parent, scope: scope, access: access)
          }
          continue
        }
        if w == CWord.templateWord {
          i = template(i, end: end, parent: parent, scope: scope, access: access)
          continue
        }
        if w == CWord.usingWord {
          i = using(i, parent: parent, access: access)
          continue
        }
        if CWord.staticAssert.contains(w) || w == CWord.friendWord {
          i = statementEnd(i, end)
          continue
        }
      }
      if unit.isByte(i, 0x5B), unit.isByte(i + 1, 0x5B) {
        i = skipGroup(i)
        continue
      }
      let before = i
      i = declaration(i, end: end, parent: parent, scope: scope, access: access)
      if i <= before { i = before + 1 }
    }
    return i
  }

  /// To past the `;` that ends a statement, or its block's `}`.
  private func statementEnd(_ from: Int, _ end: Int) -> Int {
    var i = from
    while i < end {
      if unit.tokens[i].kind == .directive {
        i = past(i)
        continue
      }
      if unit.tokens[i].kind == .open {
        let isBrace = unit.isByte(i, 0x7B)
        i = skipGroup(i)
        if isBrace, !unit.isByte(i, 0x3B), !unit.isWord(i) { return i }
        continue
      }
      if unit.tokens[i].kind == .close { return i }
      if unit.isByte(i, 0x3B) { return i + 1 }
      i += 1
    }
    return i
  }

  // MARK: Directives

  /// `#define` and `#undef` inside a function's body, which the parser steps over.
  private mutating func bodyMacros(_ open: Int, _ close: Int) {
    var k = open + 1
    while k < close {
      if unit.tokens[k].kind == .directive, syntax.conditional(unit, k) == .none {
        let name = syntax.directiveName(unit, k)
        if name == "define" || name == "undef" {
          k = directive(k)
          continue
        }
      }
      k += 1
    }
  }

  private mutating func directive(_ i: Int) -> Int {
    if syntax.conditional(unit, i) != .none {
      mix(i, i + 1)
      return unit.takeDirective(i)
    }
    let end = Int(file.ends[Int32(i)] ?? Int32(i + 1))
    mix(i, end)
    let name = syntax.directiveName(unit, i)
    switch name {
    case "include", "import", "include_next":
      guard i + 1 < end, unit.tokens[i + 1].kind == .string else { break }
      let spelled = unit.string(i + 1)
      guard spelled.count >= 2 else { break }
      let angled = spelled.hasPrefix("<")
      let header = String(spelled.dropFirst().dropLast())
      let path = syntax.resolve(header, angled, unit.path, name == "include_next")
      var item = Import(module: CodeModel.name(path ?? "?" + header), moduleName: path ?? "?" + header, isExported: true, isTestable: false)
      item.token = Int32(i + 1)
      unit.imports.append(item)
    case "define":
      guard i + 1 < end, unit.tokens[i + 1].kind == .identifier else { break }
      defineMacro(i, end)
    case "undef":
      guard i + 1 < end else { break }
      file.macroEvents[unit.hash(i + 1), default: []].append((Int32(i + 1), -1))
    default: break
    }
    return end
  }

  private mutating func defineMacro(_ i: Int, _ end: Int) {
    let nameToken = i + 1
    var decl = Decl(kind: .macro, name: unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(i), parent: -1)
    decl.end = Int32(end)
    var bodyStart = nameToken + 1
    // `NAME(a, b)`: parameters when the `(` touches the name.
    let isFunction = unit.startsWith(nameToken + 1, 0x28) && unit.touchesPrevious(nameToken + 1)
    if isFunction {
      decl.paramStart = Int32(unit.params.count)
      var j = nameToken + 2
      while j < end, !unit.startsWith(j, 0x29) {
        if unit.tokens[j].kind == .identifier {
          unit.params.append(Param(label: 0, local: unit.hash(j), nameToken: Int32(j), typeStart: -1, typeEnd: -1, hasDefault: false, variadic: false))
        } else if unit.isToken(j, "...") {
          unit.params.append(Param(label: 0, local: CodeModel.name("__VA_ARGS__"), nameToken: -1, typeStart: -1, typeEnd: -1, hasDefault: false, variadic: true))
        }
        j += 1
      }
      decl.paramCount = Int32(unit.params.count) - decl.paramStart
      bodyStart = min(j + 1, end)
    }
    if bodyStart < end {
      decl.initStart = Int32(bodyStart)
      decl.initEnd = Int32(end)
    }
    let index = addDecl(decl)
    if isFunction { file.set(index, .functionMacro) }
    file.macroEvents[decl.name, default: []].append((Int32(nameToken), index))
  }

  // MARK: C++ scopes

  private mutating func namespace(_ at: Int, parent: Int32) -> Int {
    var i = at + 1
    let isInline = at > 0 && unit.isToken(at - 1, "inline")
    var names: [Int] = []
    while unit.isWord(i) {
      if unit.isMacroLike(i), unit.isByte(i + 1, 0x28) {
        i = skipGroup(i + 1)
        continue
      }
      names.append(i)
      i += 1
      if unit.isToken(i, "::") { i += 1 } else { break }
    }
    if unit.isAssign(i) {
      // `namespace X = A::B;`: an alias.
      let end = statementEnd(i, count)
      if let first = names.first {
        var decl = Decl(kind: .namespace, name: unit.hash(first), nameToken: Int32(first), first: Int32(at), parent: parent)
        decl.typeStart = Int32(i + 1)
        decl.typeEnd = Int32(max(i + 1, end - 1))
        decl.end = Int32(end)
        let index = addDecl(decl)
        file.set(index, .alias)
        register(index, parent: parent, ordinary: true, tag: false)
      }
      mix(at, end)
      return end
    }
    while i < count, !unit.isByte(i, 0x7B), !unit.isByte(i, 0x3B) {
      if unit.tokens[i].kind == .open { i = skipGroup(i) } else { i += 1 }
    }
    guard unit.isByte(i, 0x7B) else { return i + 1 }
    mix(at, i + 1)
    let close = skipGroup(i) - 1
    var holder = parent
    if names.isEmpty {
      var decl = Decl(kind: .namespace, name: 0, nameToken: Int32(at), first: Int32(at), parent: parent)
      decl.bodyOpen = Int32(i)
      decl.bodyClose = Int32(close)
      decl.end = Int32(close + 1)
      holder = addDecl(decl)
      file.set(holder, .anonymous)
    } else {
      for nameToken in names {
        var decl = Decl(kind: .namespace, name: unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(at), parent: holder)
        decl.bodyOpen = Int32(i)
        decl.bodyClose = Int32(close)
        decl.end = Int32(close + 1)
        let index = addDecl(decl)
        if isInline { file.set(index, .inline) }
        register(index, parent: holder, ordinary: true, tag: false)
        holder = index
      }
    }
    members(from: i + 1, to: close, parent: holder, scope: .namespace)
    return close + 1
  }

  /// `_LIBCPP_BEGIN_NAMESPACE_STD … _LIBCPP_END_NAMESPACE_STD`: namespace `std` (its inline ABI namespace left out, as
  /// lookup sees through it), named at the opening macro.
  private mutating func macroNamespace(_ at: Int, end: Int, parent: Int32) -> Int {
    var close = at + 1
    while close < end, !(unit.isWord(close) && (word(close) == CWord.libcxxEndStd || word(close) == CWord.libcxxEndUnversionedStd)) { close += 1 }
    var decl = Decl(kind: .namespace, name: CodeModel.name("std"), nameToken: Int32(at), first: Int32(at), parent: parent)
    decl.bodyOpen = Int32(at)
    decl.bodyClose = Int32(close)
    decl.end = Int32(min(close + 1, end))
    let index = addDecl(decl)
    register(index, parent: parent, ordinary: true, tag: false)
    mix(at, at + 1)
    members(from: at + 1, to: close, parent: index, scope: .namespace)
    return min(close + 1, end)
  }

  /// `template <typename T, int N> declaration`: the parameters become the declaration's generics.
  private mutating func template(_ at: Int, end: Int, parent: Int32, scope: Scope, access: Access) -> Int {
    var i = at + 1
    var generics: [Generic] = []
    if unit.startsWith(i, 0x3C) {
      let close = skipAngles(i)
      var j = i + 1
      var last: Int?
      var depth = 0
      while j < close - 1 {
        if unit.tokens[j].kind == .open {
          j = skipGroup(j)
          continue
        }
        if unit.startsWith(j, 0x3C) { depth += 1 }
        if depth == 0, unit.tokens[j].kind == .identifier { last = j }
        if depth == 0, unit.isByte(j, 0x2C) || unit.isAssign(j) {
          if let name = last { generics.append(Generic(name: unit.hash(name), token: Int32(name))) }
          last = nil
          if unit.isAssign(j) {
            // Past its default.
            while j < close - 1, !unit.isByte(j, 0x2C) {
              if unit.tokens[j].kind == .open { j = skipGroup(j) } else if unit.startsWith(j, 0x3C) { j = skipAngles(j) } else { j += 1 }
            }
            continue
          }
        }
        if unit.startsWith(j, 0x3E) { depth = max(0, depth - 1) }
        j += 1
      }
      if let name = last { generics.append(Generic(name: unit.hash(name), token: Int32(name))) }
      i = close
    }
    mix(at, i)
    i = skipDirectives(i)
    if unit.isToken(i, "template") { return template(i, end: end, parent: parent, scope: scope, access: access) }
    let before = unit.decls.count
    let after: Int
    if unit.isToken(i, "using") {
      after = using(i, parent: parent, access: access)
    } else if unit.isToken(i, "friend") {
      return statementEnd(i, end)
    } else {
      after = declaration(i, end: end, parent: parent, scope: scope, access: access)
    }
    // Every declaration it made at this level has the parameters.
    if !generics.isEmpty {
      let start = Int32(unit.generics.count)
      unit.generics.append(contentsOf: generics)
      for index in before..<unit.decls.count where unit.decls[index].parent == parent || unit.decls[index].kind == .extensionDecl
        || (unit.decls[index].parent >= 0 && unit.decls[Int(unit.decls[index].parent)].kind == .extensionDecl && Int(unit.decls[index].parent) >= before)
      {
        unit.decls[index].genericStart = start
        unit.decls[index].genericCount = Int32(generics.count)
      }
    }
    return after
  }

  /// `using namespace N;`, `using N::x;`, `using T = type;`.
  private mutating func using(_ at: Int, parent: Int32, access: Access) -> Int {
    let end = statementEnd(at, count)
    mix(at, end)
    if unit.isToken(at + 1, "namespace") {
      file.usings.append((parent, Int32(at), Int32(at + 2), Int32(max(at + 2, end - 1)), true))
      return end
    }
    if unit.isWord(at + 1), unit.isAssign(at + 2) || (unit.isMacroLike(at + 2) && unit.isAssign(at + 3)) {
      let assign = unit.isAssign(at + 2) ? at + 2 : at + 3
      var decl = Decl(kind: .typeAlias, name: unit.hash(at + 1), nameToken: Int32(at + 1), first: Int32(at), parent: parent)
      decl.typeStart = Int32(assign + 1)
      decl.typeEnd = Int32(max(assign + 1, end - 1))
      decl.end = Int32(end)
      decl.access = access
      let index = addDecl(decl)
      register(index, parent: parent, ordinary: true, tag: false)
      return end
    }
    file.usings.append((parent, Int32(at), Int32(at + 1), Int32(max(at + 1, end - 1)), false))
    return end
  }

  /// Where a declaration goes in the file's tables: at file scope (or a scope as open as it: an anonymous namespace,
  /// `extern "C"`) ordinary lookup finds it.
  private func register(_ index: Int32, parent: Int32, ordinary: Bool, tag: Bool) {
    let decl = unit.decls[Int(index)]
    guard decl.name != 0 else { return }
    var open = parent < 0
    var p = parent
    while !open, p >= 0, file.has(p, .anonymous) {
      p = unit.decls[Int(p)].parent
      open = p < 0
    }
    if tag, open || !isCpp { file.tags[decl.name, default: []].append(index) }
    if ordinary, open { file.ordinary[decl.name, default: []].append(index) }
  }

  // MARK: Declarations

  /// A tag's specifier: `struct name`, with its body when it has one (then it's declared).
  private struct Tag {
    var end: Int
    var decl: Int32?
    var nameToken: Int?
  }

  private mutating func tagSpecifier(_ at: Int, parent: Int32, scope: Scope, isStatementStart: Bool, inTypedef: Bool = false) -> Tag {
    let keyword = word(at)
    var i = at + 1
    var scoped = false
    if keyword == CWord.enumWord, unit.isToken(i, "class") || unit.isToken(i, "struct") {
      scoped = true
      i += 1
    }
    // Attributes and export macros before the name.
    while i < count {
      if unit.tokens[i].kind == .directive {
        i = past(i)
        continue
      }
      // `struct EXPORT name {`, but `typedef struct _NAME name;` names `_NAME`.
      let exportMacro = unit.isMacroLike(i) && (unit.isByte(i + 1, 0x28) || unit.isWord(i + 1) && (unit.isByte(i + 2, 0x7B) || unit.isByte(i + 2, 0x3A) || unit.isWord(i + 2) || opensTemplate(i + 2)))
      if unit.isWord(i), CWord.attributes.contains(word(i)) || exportMacro {
        i = unit.isByte(i + 1, 0x28) ? skipGroup(i + 1) : i + 1
        continue
      }
      if unit.isByte(i, 0x5B), unit.isByte(i + 1, 0x5B) {
        i = skipGroup(i)
        continue
      }
      break
    }
    var nameToken: Int?
    var qualifier: (Int, Int)?
    if unit.isWord(i), !unit.isToken(i, "final") || !(unit.isByte(i + 1, 0x7B) || unit.isByte(i + 1, 0x3A)) {
      let start = i
      nameToken = i
      i += 1
      if opensTemplate(i) { i = skipAngles(i) }
      while unit.isToken(i, "::"), unit.isWord(i + 1) {
        qualifier = (start, i)
        nameToken = i + 1
        i += 2
        if opensTemplate(i) { i = skipAngles(i) }
      }
    }
    if unit.isToken(i, "final") { i += 1 }
    var bases: [(Int32, Int32)] = []
    if unit.isByte(i, 0x3A) || unit.isToken(i, ":") {
      // Bases, or an enum's underlying type, up to the body.
      i += 1
      var start = i
      while i < count, !unit.isByte(i, 0x7B), !unit.isByte(i, 0x3B) {
        if unit.tokens[i].kind == .directive {
          i = past(i)
          continue
        }
        if unit.isByte(i, 0x2C) {
          bases.append((Int32(start), Int32(i)))
          start = i + 1
        } else if unit.isWord(i), unit.isToken(i, "public") || unit.isToken(i, "private") || unit.isToken(i, "protected") || unit.isToken(i, "virtual") {
          if start == i { start = i + 1 }
        }
        if unit.startsWith(i, 0x3C) {
          i = skipAngles(i)
          continue
        }
        if unit.tokens[i].kind == .open {
          i = skipGroup(i)
          continue
        }
        if unit.tokens[i].kind == .close { break }
        i += 1
      }
      if start < i { bases.append((Int32(start), Int32(i))) }
    }
    let kind: DeclKind = keyword == CWord.enumWord ? .enumeration : keyword == CWord.classWord ? .classType : .structure
    if unit.isByte(i, 0x7B) {
      let close = skipGroup(i) - 1
      mix(at, i + 1)
      var holder = parent
      if let qualifier {
        holder = extensionHolder(qualifier.0, qualifier.1, first: at, parent: parent, end: close + 1)
      }
      var decl = Decl(kind: kind, name: nameToken.map { unit.hash($0) } ?? 0, nameToken: Int32(nameToken ?? at), first: Int32(at), parent: holder)
      decl.bodyOpen = Int32(i)
      decl.bodyClose = Int32(close)
      decl.end = Int32(close + 1)
      decl.access = .isPublic
      if kind == .enumeration, let base = bases.first {
        decl.typeStart = base.0
        decl.typeEnd = base.1
      } else if !bases.isEmpty {
        decl.inheritStart = Int32(unit.ranges.count)
        for base in bases { unit.ranges.append((start: base.0, end: base.1)) }
        decl.inheritCount = Int32(bases.count)
      }
      let index = addDecl(decl)
      if keyword == CWord.unionWord { file.set(index, .union) }
      if scoped { file.set(index, .scoped) }
      if keyword == CWord.classWord { file.set(index, .classKeyword) }
      if nameToken == nil { file.set(index, .anonymous) }
      register(index, parent: holder, ordinary: isCpp, tag: true)
      if !isCpp, holder >= 0, decl.name != 0 { file.tags[decl.name, default: []].append(index) }
      if kind == .enumeration {
        enumerators(i + 1, close, parent: index, scoped: scoped)
      } else {
        members(from: i + 1, to: close, parent: index, scope: .record(index), access: keyword == CWord.classWord ? .isPrivate : .isPublic)
      }
      return Tag(end: close + 1, decl: index, nameToken: nameToken)
    }
    if (isStatementStart && unit.isByte(i, 0x3B)) || (inTypedef && !isCpp), let nameToken {
      // `struct foo;`: a forward declaration; so is C's `typedef struct foo foo;` (clangd's first declaration of it).
      if isStatementStart { mix(at, i + 1) }
      var decl = Decl(kind: kind, name: unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(at), parent: parent)
      decl.end = Int32(isStatementStart ? i + 1 : i)
      let index = addDecl(decl)
      file.set(index, .forward)
      if keyword == CWord.unionWord { file.set(index, .union) }
      register(index, parent: parent, ordinary: isCpp, tag: true)
      return Tag(end: i, decl: index, nameToken: nameToken)
    }
    return Tag(end: i, decl: nil, nameToken: nameToken)
  }

  private mutating func enumerators(_ from: Int, _ close: Int, parent: Int32, scoped: Bool) {
    var i = from
    while i < close {
      if unit.tokens[i].kind == .directive {
        i = past(i)
        continue
      }
      if unit.tokens[i].kind == .identifier || (unit.isWord(i) && !unit.isMacroLike(i)) || unit.tokens[i].kind == .keyword {
        var decl = Decl(kind: .enumCase, name: unit.hash(i), nameToken: Int32(i), first: Int32(i), parent: parent)
        decl.access = .isPublic
        var j = i + 1
        // Attributes after the name, then a value.
        while j < close, unit.isWord(j) {
          j = unit.isByte(j + 1, 0x28) ? skipGroup(j + 1) : j + 1
        }
        if unit.isByte(j, 0x28) { j = skipGroup(j) }
        if unit.isAssign(j) {
          decl.initStart = Int32(j + 1)
          j += 1
          while j < close, !unit.isByte(j, 0x2C) {
            if unit.tokens[j].kind == .directive {
              j = past(j)
              continue
            }
            j = unit.tokens[j].kind == .open ? skipGroup(j) : j + 1
          }
          decl.initEnd = Int32(j)
        }
        decl.end = Int32(j)
        mix(i, j)
        let index = addDecl(decl)
        if !scoped { register(index, parent: unit.decls[Int(parent)].parent, ordinary: true, tag: false) }
        if !scoped, !isCpp, unit.decls[Int(parent)].parent >= 0 { file.ordinary[decl.name, default: []].append(index) }
        i = j
        continue
      }
      i += 1
    }
  }

  /// An extension named after the last of `A::B::` (from `start` to the last `::` at `lastColons`), holding an
  /// out-of-line definition.
  private mutating func extensionHolder(_ start: Int, _ lastColons: Int, first: Int, parent: Int32, end: Int) -> Int32 {
    // The qualifier's last name, its template arguments skipped.
    var nameToken = lastColons - 1
    if unit.startsWith(nameToken, 0x3E) || unit.isToken(nameToken, ">") {
      var j = start
      var last = start
      while j < lastColons {
        if unit.isWord(j) { last = j }
        if unit.startsWith(j, 0x3C) {
          j = skipAngles(j)
          continue
        }
        j += 1
      }
      nameToken = last
    }
    var decl = Decl(kind: .extensionDecl, name: unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(first), parent: parent)
    decl.typeStart = Int32(start)
    decl.typeEnd = Int32(lastColons)
    // To the end of the declaration it holds (a function's body is set again when it's read).
    decl.end = Int32(statementEnd(lastColons, end))
    let index = addDecl(decl)
    file.qualified.append(index)
    return index
  }

  /// One declaration: specifiers, then declarators up to `;`, or a function's body. Returns the token after it.
  mutating func declaration(_ start: Int, end: Int, parent: Int32, scope: Scope, access: Access) -> Int {
    var i = start
    var isTypedef = false
    var isExtern = false
    var isStatic = false
    var isInline = false
    var isVirtual = false
    var sawType = false
    var tagDecl: Int32?
    var words: [Int] = []
    var lastWasMacroCall = false
    while i < end {
      let token = unit.tokens[i]
      if token.kind == .directive {
        i = past(i)
        continue
      }
      if token.kind == .attribute || token.kind == .string { break }
      guard unit.isWord(i) else {
        if unit.isByte(i, 0x5B), unit.isByte(i + 1, 0x5B) {
          i = skipGroup(i)
          continue
        }
        if unit.isToken(i, "::"), unit.isWord(i + 1), words.isEmpty || !unit.touchesPrevious(i) {
          // `::name`: the global scope's.
          i += 1
          continue
        }
        if unit.isToken(i, "::"), let last = words.last, last == i - 1 || (unit.startsWith(i - 1, 0x3E)), unit.isWord(i + 1) {
          // `A::B`: one name; the last is what's kept.
          words[words.count - 1] = i + 1
          i += 2
          if opensTemplate(i) { i = skipAngles(i) }
          continue
        }
        break
      }
      let w = word(i)
      if CWord.storage.contains(w) {
        if w == CWord.typedefWord { isTypedef = true }
        if w == CWord.externWord { isExtern = true }
        if w == CWord.staticWord { isStatic = true }
        if CWord.inlineWords.contains(w) { isInline = true }
        if w == CWord.virtualWord { isVirtual = true }
        if unit.isToken(i, "explicit"), unit.isByte(i + 1, 0x28) {
          i = skipGroup(i + 1)
          continue
        }
        i += 1
        continue
      }
      if CWord.qualifiers.contains(w) {
        i = unit.isByte(i + 1, 0x28) && w == CodeModel.name("_Atomic") ? skipGroup(i + 1) : i + 1
        continue
      }
      if CWord.attributes.contains(w) {
        i = unit.isByte(i + 1, 0x28) ? skipGroup(i + 1) : i + 1
        continue
      }
      if CWord.typeofWords.contains(w), unit.isByte(i + 1, 0x28) {
        sawType = true
        i = skipGroup(i + 1)
        continue
      }
      if w == CWord.structWord || w == CWord.unionWord || w == CWord.enumWord || (w == CWord.classWord && isCpp) {
        let tag = tagSpecifier(i, parent: parent, scope: scope, isStatementStart: words.isEmpty && !sawType && !isTypedef, inTypedef: isTypedef && words.isEmpty && !sawType)
        sawType = true
        tagDecl = tag.decl
        if let decl = tag.decl, file.has(decl, .forward), !isTypedef {
          return tag.end + 1
        }
        i = tag.end
        continue
      }
      if CWord.enumMacros.contains(w), unit.isByte(i + 1, 0x28) {
        // `NS_ENUM(NSInteger, Name) { … }`: an enum named Name.
        let close = skipGroup(i + 1) - 1
        var nameToken = close - 1
        while nameToken > i + 1, !unit.isWord(nameToken) { nameToken -= 1 }
        if unit.isByte(close + 1, 0x7B) {
          let bodyClose = skipGroup(close + 1) - 1
          var decl = Decl(kind: .enumeration, name: unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(i), parent: parent)
          decl.typeStart = Int32(i + 2)
          decl.typeEnd = Int32(max(i + 2, nameToken - 1))
          decl.bodyOpen = Int32(close + 1)
          decl.bodyClose = Int32(bodyClose)
          decl.end = Int32(bodyClose + 1)
          mix(i, close + 2)
          let index = addDecl(decl)
          register(index, parent: parent, ordinary: true, tag: true)
          enumerators(close + 2, bodyClose, parent: index, scoped: false)
          tagDecl = index
          sawType = true
          i = bodyClose + 1
          if isTypedef, unit.isByte(i, 0x3B) { return i + 1 }
          continue
        }
        sawType = true
        words.append(nameToken)
        i = close + 1
        continue
      }
      if w == CWord.typenameWord {
        i += 1
        continue
      }
      if w == CWord.operatorWord || CWord.typeKeywords.contains(w) {
        if CWord.typeKeywords.contains(w) {
          sawType = true
          i += 1
          continue
        }
        break
      }
      // A word: the type's name, or the declarator's, or a macro.
      if unit.isByte(i + 1, 0x28) {
        // `name(`: a function's name when a type came before; else a constructor, or a macro.
        let afterGroup = skipGroup(i + 1)
        // `PUSH_WARNINGS(4251)` alone on its line before `namespace`, `class`, `template`: a statement of its own.
        if words.isEmpty, !sawType, unit.isMacroLike(i), unit.startsLine(i), unit.startsLine(afterGroup),
          (unit.isWord(afterGroup) && CWord.declarationStarts.contains(word(afterGroup))) || (afterGroup < count && (unit.tokens[afterGroup].kind == .attribute || unit.tokens[afterGroup].kind == .directive))
        {
          mix(start, afterGroup)
          return afterGroup
        }
        // `ObjectType firstObject API_AVAILABLE(macos(10.6));`: an attribute after the declarator.
        if !words.isEmpty, unit.isMacroLike(i), unit.isByte(afterGroup, 0x3B) || unit.isByte(afterGroup, 0x2C) || unit.isAssign(afterGroup) || unit.isByte(afterGroup, 0x7B) {
          let text = unit.string(i)
          if text.hasPrefix("API_") || text.hasPrefix("NS_") || text.hasPrefix("CF_") || text.hasPrefix("__API_") || text.hasPrefix("__OSX_") || text.hasPrefix("__IOS_")
            || text.contains("AVAILABLE") || text.contains("DEPRECATED") || text.contains("ATTRIBUTE") || text.contains("SWIFT")
          {
            i = afterGroup
            break
          }
        }
        let isAttribute = unit.isMacroLike(i) && (unit.isWord(afterGroup) || unit.startsWith(afterGroup, 0x2A))
        if isAttribute, !words.isEmpty || sawType || unit.isWord(afterGroup) {
          if !sawType, words.isEmpty, unit.startsWith(afterGroup, 0x2A) {
            // `STACK_OF(X509) *p`: the macro is the type.
            words.append(i)
            sawType = true
          }
          lastWasMacroCall = true
          i = afterGroup
          continue
        }
        words.append(i)
        break
      }
      words.append(i)
      lastWasMacroCall = false
      i += 1
      if opensTemplate(i) { i = skipAngles(i) }
      // A statement macro alone on its line (`NS_ASSUME_NONNULL_BEGIN`): the next line is another declaration.
      if words.count == 1, !sawType, unit.isMacroLike(i - 1) || unit.startsWith(i, 0x40), unit.startsLine(i - 1) && unit.startsLine(i),
        !unit.isByte(i, 0x3B), !unit.startsWith(i, 0x2A)
      {
        mix(start, i)
        return i
      }
    }
    _ = lastWasMacroCall
    // `T *name`, `T &name`, `T (*name)(…)`, `T operator+`: the words before a declarator are its type.
    let declaratorNext =
      i < end
      && ((unit.tokens[i].kind == .punctuation && (unit.startsWith(i, 0x2A) || unit.startsWith(i, 0x26) || unit.startsWith(i, 0x5E)) && !unit.isToken(i, "&&="))
        || (unit.isByte(i, 0x28) && (unit.startsWith(i + 1, 0x2A) || unit.startsWith(i + 1, 0x5E) || unit.startsWith(i + 1, 0x26)))
        || unit.isToken(i, "operator"))
    if declaratorNext, let last = words.last, last < i { sawType = true }
    // The last word is the declarator's name when another word or a type comes before it.
    var declaratorStart = i
    // A constructor or destructor has no type before its name: `A(`, `A::A(`, `A::~A(`.
    let special = words.count == 1 && !sawType && words.last.map { isConstructor($0, parent: parent) || isOutOfLineSpecial($0) } == true
    if !declaratorNext || words.last == i, let last = words.last, !(words.count == 1 && !sawType && !special) {
      let followsType = sawType || words.count >= 2
      if followsType || special {
        declaratorStart = last
        // Qualified (`A::f`): its qualifier starts the declarator.
        var q = last
        while q >= 2, unit.isToken(q - 1, "::"), unit.isWord(q - 2) || unit.startsWith(q - 2, 0x3E) {
          q -= 2
          if unit.startsWith(q, 0x3E) {
            var back = q
            var depth = 0
            while back > start {
              if unit.startsWith(back, 0x3E) { depth += 1 }
              if unit.startsWith(back, 0x3C) {
                depth -= 1
                if depth == 0 { break }
              }
              back -= 1
            }
            q = back - 1
          }
        }
        if q < last { declaratorStart = q }
        if declaratorStart > start, unit.isToken(declaratorStart - 1, "~") { declaratorStart -= 1 }
      }
    }
    if words.count == 1, !sawType, tagDecl == nil, declaratorStart == i, !special {
      // Not a declaration: an expression or a macro's use. To its end.
      let after = unit.isByte(i, 0x28) ? skipGroup(i) : i
      // `static LIBSSH2_ALLOC_FUNC(name) { … }`: a macro writes the function's head, named by its argument.
      let group = unit.isByte(i + 1, 0x28) ? skipGroup(i + 1) : i
      if group > i, unit.isByte(group, 0x7B), unit.isMacroLike(i) {
        let after = group
        let close = skipGroup(after) - 1
        if unit.isWord(i + 2), unit.isByte(i + 3, 0x29), !unit.isMacroLike(i + 2) {
          var decl = Decl(kind: .function, name: unit.hash(i + 2), nameToken: Int32(i + 2), first: Int32(start), parent: parent)
          decl.access = access
          decl.isStatic = isStatic
          decl.bodyOpen = Int32(after)
          decl.bodyClose = Int32(close)
          decl.end = Int32(close + 1)
          let index = addDecl(decl)
          register(index, parent: parent, ordinary: true, tag: false)
          bodyMacros(after, close)
        }
        mix(start, after)
        return close + 1
      }
      if after > i, after < end, unit.startsLine(after), !unit.isByte(after, 0x3B), !unit.isByte(after, 0x7B) {
        mix(start, after)
        return after
      }
      return statementEnd(i, end)
    }
    if words.isEmpty, !sawType, tagDecl == nil, !unit.isToken(i, "operator"), !unit.isToken(i, "~") {
      return statementEnd(i, end)
    }
    let specEnd = declaratorStart
    var j = declaratorStart
    var first = true
    if let tagDecl, file.has(tagDecl, .anonymous), unit.isByte(skipDirectives(j), 0x3B) { file.set(tagDecl, .transparent) }
    while j < end {
      j = skipDirectives(j)
      if unit.isByte(j, 0x3B) {
        mix(start, j + 1)
        return j + 1
      }
      guard let found = declarator(j, end: end) else {
        return statementEnd(j, end)
      }
      var kind: DeclKind = isTypedef ? .typeAlias : found.params != nil ? .function : .variable
      let nameText = unit.hash(found.name)
      if kind == .function {
        if found.isDestructor {
          kind = .deinitializer
        } else if isConstructor(found.name, parent: parent) || (found.qualifierEnd != nil && isOutOfLineSpecial(found.name)) {
          kind = .initializer
        }
      }
      var holder = parent
      if let qStart = found.qualifierStart, let qEnd = found.qualifierEnd {
        holder = extensionHolder(qStart, qEnd, first: start, parent: parent, end: end)
      }
      var decl = Decl(kind: kind, name: found.isOperator ? operatorName(found.name) : nameText, nameToken: Int32(found.name), first: Int32(start), parent: holder)
      decl.typeStart = Int32(start)
      decl.typeEnd = Int32(specEnd)
      decl.access = access
      decl.isStatic = isStatic
      if let params = found.params ?? found.pointerParams {
        decl.paramStart = Int32(unit.params.count)
        parameters(params.open, params.close)
        decl.paramCount = Int32(unit.params.count) - decl.paramStart
      }
      j = found.end
      // After a function's declarator: qualifiers, attributes, `= 0`, `-> T`, then a body or `;`.
      if decl.kind == .function || decl.kind == .initializer || decl.kind == .deinitializer {
        while j < end {
          j = skipDirectives(j)
          if unit.isWord(j), !unit.isToken(j, "try") {
            j = unit.isByte(j + 1, 0x28) ? skipGroup(j + 1) : j + 1
            continue
          }
          if unit.isToken(j, "->") {
            j += 1
            while j < end, !unit.isByte(j, 0x7B), !unit.isByte(j, 0x3B), !unit.isAssign(j) {
              j = unit.tokens[j].kind == .open ? skipGroup(j) : unit.startsWith(j, 0x3C) ? skipAngles(j) : j + 1
            }
            continue
          }
          if unit.isAssign(j) {
            // `= 0`, `= default`, `= delete`.
            j = statementEnd(j, end) - 1
            break
          }
          if unit.isByte(j, 0x5B), unit.isByte(j + 1, 0x5B) {
            j = skipGroup(j)
            continue
          }
          if unit.isToken(j, "try") { j += 1 }
          if unit.isByte(j, 0x3A) || unit.isToken(j, ":") {
            // A constructor's initializers, up to the body.
            j += 1
            while j < end, !unit.isByte(j, 0x7B) || (j > 0 && (unit.isWord(j - 1) || unit.startsWith(j - 1, 0x3E))) && !unit.isByte(j - 1, 0x29) {
              if unit.isByte(j, 0x7B), j > 0, unit.isWord(j - 1) || unit.startsWith(j - 1, 0x3E) {
                j = skipGroup(j)
                continue
              }
              if unit.isByte(j, 0x3B) { break }
              j = unit.tokens[j].kind == .open ? skipGroup(j) : j + 1
            }
            continue
          }
          if unit.isWord(j) == false, !unit.isByte(j, 0x7B), !unit.isByte(j, 0x3B), !unit.isByte(j, 0x2C), first, !isCpp, unit.tokens[j].kind != .close {
            // K&R parameter declarations, up to the body.
            var k = j
            while k < end, !unit.isByte(k, 0x7B), !(unit.isByte(k, 0x3B) && unit.isByte(k + 1, 0x7D)) { k += 1 }
            if unit.isByte(k, 0x7B) { j = k }
          }
          break
        }
        if unit.isByte(j, 0x7B) {
          let close = skipGroup(j) - 1
          decl.bodyOpen = Int32(j)
          decl.bodyClose = Int32(close)
          decl.end = Int32(close + 1)
          mix(start, j)
          let index = addDecl(decl)
          finish(index, found: found, holder: holder, parent: parent, isExtern: isExtern, isInline: isInline, isVirtual: isVirtual, isTypedef: isTypedef)
          if holder != parent { unit.decls[Int(holder)].end = Int32(close + 1) }
          bodyMacros(j, close)
          return close + 1
        }
      } else if unit.isAssign(j) || (isCpp && unit.isByte(j, 0x7B)) || unit.isByte(j, 0x3A) || unit.isToken(j, ":") {
        // An initializer, or a bit-field's width.
        let isBits = unit.isByte(j, 0x3A) || unit.isToken(j, ":")
        let valueStart = unit.isByte(j, 0x7B) ? j : j + 1
        var k = valueStart
        while k < end, !unit.isByte(k, 0x2C), !unit.isByte(k, 0x3B), unit.tokens[k].kind != .close {
          if unit.tokens[k].kind == .directive {
            k = past(k)
            continue
          }
          k = unit.tokens[k].kind == .open ? skipGroup(k) : k + 1
        }
        if !isBits {
          decl.initStart = Int32(valueStart)
          decl.initEnd = Int32(k)
        }
        j = k
      }
      decl.end = Int32(j)
      let index = addDecl(decl)
      finish(index, found: found, holder: holder, parent: parent, isExtern: isExtern, isInline: isInline, isVirtual: isVirtual, isTypedef: isTypedef)
      first = false
      // Attributes after a declarator, before `,` or `;`.
      while unit.isWord(j) { j = unit.isByte(j + 1, 0x28) ? skipGroup(j + 1) : j + 1 }
      if unit.isByte(j, 0x2C) {
        j += 1
        continue
      }
      if unit.isByte(j, 0x3B) {
        mix(start, j + 1)
        unit.decls[Int(index)].end = Int32(j + 1)
        return j + 1
      }
      mix(start, j)
      return j > start ? j : start + 1
    }
    return j
  }

  private mutating func finish(_ index: Int32, found: Declarator, holder: Int32, parent: Int32, isExtern: Bool, isInline: Bool, isVirtual: Bool, isTypedef: Bool) {
    file.declarators[index] = (Int32(found.prefix), Int32(found.end))
    if isExtern { file.set(index, .extern) }
    if isInline { file.set(index, .inline) }
    if isVirtual { file.set(index, .virtual) }
    if holder == parent { register(index, parent: parent, ordinary: true, tag: false) }
  }

  private func operatorName(_ token: Int) -> Name {
    var text = "operator"
    var j = token + 1
    while j < count, !unit.isByte(j, 0x28) || j == token + 1 {
      text += unit.string(j)
      j += 1
      if j > token + 4 { break }
    }
    return CodeModel.name(text)
  }

  /// A constructor's name: the class it's in (`Foo(int)` in `class Foo`).
  /// `A::A(` and `A::~A(` (from `A`, the last word before `::~`).
  private func isOutOfLineSpecial(_ token: Int) -> Bool {
    guard isCpp else { return false }
    var after = token + 1
    if opensTemplate(after) { after = skipAngles(after) }
    if unit.isToken(after, "::"), unit.isToken(after + 1, "~"), unit.hash(after + 2) == unit.hash(token) { return true }
    guard unit.isByte(token + 1, 0x28), token >= 2, unit.isToken(token - 1, "::") else { return false }
    var q = token - 2
    // `A<T>::A(`.
    if unit.startsWith(q, 0x3E) {
      var depth = 0
      while q > 0 {
        if unit.startsWith(q, 0x3E) { depth += unit.isToken(q, ">>") ? 2 : 1 }
        if unit.startsWith(q, 0x3C) {
          depth -= 1
          if depth == 0 { break }
        }
        q -= 1
      }
      q -= 1
    }
    return q >= 0 && unit.isWord(q) && unit.hash(q) == unit.hash(token)
  }

  private func isConstructor(_ token: Int, parent: Int32) -> Bool {
    guard isCpp, parent >= 0 else { return false }
    let holder = unit.decls[Int(parent)]
    return (holder.kind == .classType || holder.kind == .structure) && holder.name == unit.hash(token) && unit.isByte(token + 1, 0x28)
  }

  struct Declarator {
    var name: Int
    var prefix: Int
    var end: Int
    var params: (open: Int, close: Int)?
    /// `(*name)(int size)`: the parameters of the function a pointer declarator points to.
    var pointerParams: (open: Int, close: Int)?
    var qualifierStart: Int?
    var qualifierEnd: Int?
    var isOperator = false
    var isDestructor = false
  }

  /// A declarator from `start`: `*name`, `(*name)(args)`, `name[3]`, `name(params)`, `A::name`, `operator+`.
  func declarator(_ start: Int, end: Int) -> Declarator? {
    var i = start
    // Pointers, references, qualifiers, attributes before the name.
    while i < end {
      if unit.tokens[i].kind == .directive {
        i = Int(file.ends[Int32(i)] ?? Int32(i + 1))
        continue
      }
      if unit.tokens[i].kind == .punctuation, unit.startsWith(i, 0x2A) || unit.startsWith(i, 0x26) || unit.startsWith(i, 0x5E) {
        i += 1
        continue
      }
      if unit.isWord(i), CWord.qualifiers.contains(word(i)) || CWord.attributes.contains(word(i)) || (unit.isMacroLike(i) && (unit.isWord(i + 1) || unit.isByte(i + 1, 0x28))) {
        if unit.isByte(i + 1, 0x28) {
          let after = skipGroup(i + 1)
          // `FOO(x)` right before `;` or `=` is the name with a macro's arguments, not an attribute.
          if !unit.isWord(after), !unit.startsWith(after, 0x2A), !unit.isByte(after, 0x28) { break }
          i = after
        } else {
          i += 1
        }
        continue
      }
      if unit.isToken(i, "::"), unit.isWord(i + 1) {
        i += 1
        continue
      }
      break
    }
    // `(*name)(…)`: the name is inside.
    if unit.isByte(i, 0x28) {
      let close = skipGroup(i) - 1
      var inner = i + 1
      while inner < close, unit.tokens[inner].kind == .punctuation || CWord.qualifiers.contains(word(inner)) || unit.isMacroLike(inner) { inner += 1 }
      guard inner < close, unit.isWord(inner), let nested = declarator(i + 1, end: close) else { return nil }
      var after = close + 1
      let pointed = unit.isByte(after, 0x28) ? (open: after, close: skipGroup(after) - 1) : nil
      while unit.isByte(after, 0x28) || unit.isByte(after, 0x5B) { after = skipGroup(after) }
      var found = Declarator(name: nested.name, prefix: start, end: after, params: nil)
      found.pointerParams = nested.pointerParams ?? pointed
      return found
    }
    var qualifierStart: Int?
    var qualifierEnd: Int?
    var isDestructor = false
    var isOperator = false
    var nameToken: Int
    let nameStart = i
    while true {
      if unit.isToken(i, "~") {
        isDestructor = true
        i += 1
      }
      guard unit.isWord(i) else { return nil }
      if unit.isToken(i, "operator") {
        isOperator = true
        nameToken = i
        i += 1
        // The operator's symbol, or a conversion's type, up to its parameters.
        if unit.isByte(i, 0x28), unit.isByte(i + 1, 0x29) {
          i += 2
        } else if unit.isByte(i, 0x5B) {
          i = skipGroup(i)
        } else {
          while i < end, !unit.isByte(i, 0x28) { i += 1 }
        }
        break
      }
      nameToken = i
      i += 1
      if opensTemplate(i), unit.isToken(skipAngles(i), "::") { i = skipAngles(i) }
      if unit.isToken(i, "::"), unit.isWord(i + 1) || unit.isToken(i + 1, "~") {
        if qualifierStart == nil { qualifierStart = nameStart }
        qualifierEnd = i
        i += 1
        continue
      }
      break
    }
    var params: (Int, Int)?
    var j = i
    // A specialization's arguments: `f<int>(…)`.
    if opensTemplate(j), !isOperator { j = skipAngles(j) }
    while j < end {
      if unit.isByte(j, 0x5B) {
        j = skipGroup(j)
        continue
      }
      if unit.isByte(j, 0x28), params == nil {
        let close = skipGroup(j) - 1
        if looksLikeParameters(j, close) {
          params = (j, close)
          j = close + 1
          continue
        }
        break
      }
      break
    }
    return Declarator(
      name: nameToken, prefix: start, end: j, params: params, qualifierStart: qualifierStart, qualifierEnd: qualifierEnd, isOperator: isOperator,
      isDestructor: isDestructor)
  }

  /// `(int a, char *b)` rather than `(1, x + 2)` (C++'s direct initialization).
  private func looksLikeParameters(_ open: Int, _ close: Int) -> Bool {
    guard isCpp else { return true }
    let first = open + 1
    if first >= close { return true }
    if unit.tokens[first].kind == .number || unit.tokens[first].kind == .string { return false }
    if unit.isToken(first, "...") { return true }
    if unit.isWord(first) {
      let w = word(first)
      if CWord.typeKeywords.contains(w) || CWord.qualifiers.contains(w) || w == CWord.structWord || w == CWord.enumWord || w == CWord.classWord
        || w == CWord.typenameWord || w == CWord.unionWord
      {
        return true
      }
      if unit.isToken(first, "this") || unit.isToken(first, "nullptr") || unit.isToken(first, "true") || unit.isToken(first, "false") { return false }
      var k = first + 1
      while unit.isToken(k, "::"), unit.isWord(k + 1) { k += 2 }
      if opensTemplate(k) { k = skipAngles(k) }
      // `Type name`, `Type *`, `Type &`, `Type,` and `Type)` declare; `x.y`, `x + 1`, `f(…)` don't.
      return unit.isWord(k) || unit.isToken(k, "*") || unit.isToken(k, "&") || unit.isToken(k, "&&") || unit.isToken(k, "**") || unit.isByte(k, 0x2C)
        || k == close || unit.isToken(k, "...")
    }
    return unit.startsWith(first, 0x5B) == false && !unit.startsWith(first, 0x26) && !unit.startsWith(first, 0x2A)
  }

  /// A parameter list's names, as the core's parameters: the type is the parameter's tokens, the name among them.
  private mutating func parameters(_ open: Int, _ close: Int) {
    var i = open + 1
    while i < close {
      var j = i
      var assign = -1
      while j < close, !unit.isByte(j, 0x2C) {
        if unit.isAssign(j), assign < 0 { assign = j }
        if unit.tokens[j].kind == .open {
          j = skipGroup(j)
          continue
        }
        if unit.startsWith(j, 0x3C), isCpp, opensTemplate(j) {
          j = skipAngles(j)
          continue
        }
        j += 1
      }
      let typeEnd = assign >= 0 ? assign : j
      if unit.isToken(i, "...") {
        unit.params.append(Param(label: 0, local: 0, nameToken: -1, typeStart: Int32(i), typeEnd: Int32(typeEnd), hasDefault: false, variadic: true))
      } else if typeEnd > i, !(typeEnd == i + 1 && unit.isToken(i, "void")) {
        let nameToken = parameterName(i, typeEnd)
        pointerParameters(i, typeEnd)
        unit.params.append(
          Param(
            label: 0, local: nameToken >= 0 ? unit.hash(nameToken) : 0, nameToken: Int32(nameToken), typeStart: Int32(i), typeEnd: Int32(typeEnd),
            hasDefault: assign >= 0, variadic: false))
      }
      i = j + 1
    }
  }

  /// The names in `(*name)(int size, char *text)` within a parameter, as declarations of their own.
  private func pointerParameters(_ start: Int, _ end: Int) {
    var k = start
    while k < end {
      guard unit.isByte(k, 0x28) else {
        k += 1
        continue
      }
      let close = skipGroup(k) - 1
      if unit.startsWith(k + 1, 0x2A) || unit.startsWith(k + 1, 0x5E), unit.isByte(close + 1, 0x28) {
        let last = skipGroup(close + 1) - 1
        var piece = close + 2
        var j = piece
        while j <= last {
          if j == last || unit.isByte(j, 0x2C) {
            if j > piece {
              let name = parameterName(piece, j)
              if name >= 0 { file.pointerParameters.insert(Int32(name)) }
            }
            piece = j + 1
            j += 1
            continue
          }
          j = unit.tokens[j].kind == .open ? skipGroup(j) : j + 1
        }
        k = last + 1
        continue
      }
      k = close + 1
    }
  }

  /// A parameter's name: the last word after a type (or inside `(*name)`), -1 when it has none.
  func parameterName(_ start: Int, _ end: Int) -> Int {
    var words = 0
    var sawType = false
    var last = -1
    var pointerAfterLast = false
    var i = start
    while i < end {
      if unit.isByte(i, 0x28) {
        let close = skipGroup(i) - 1
        if unit.startsWith(i + 1, 0x2A) || unit.startsWith(i + 1, 0x5E) || unit.startsWith(i + 1, 0x26) {
          var k = i + 1
          while k < close, !unit.isWord(k) || CWord.qualifiers.contains(word(k)) { k += 1 }
          if k < close, unit.isWord(k) { return k }
          return -1
        }
        if last >= 0, last == i - 1, unit.isMacroLike(last) { last = -1 }
        i = close + 1
        continue
      }
      if unit.isByte(i, 0x5B) {
        i = skipGroup(i)
        continue
      }
      if unit.startsWith(i, 0x3C), isCpp, opensTemplate(i) {
        i = skipAngles(i)
        continue
      }
      if unit.isWord(i) {
        let w = word(i)
        if CWord.typeKeywords.contains(w) || w == CWord.structWord || w == CWord.enumWord || w == CWord.unionWord || w == CWord.classWord {
          sawType = true
        } else if !CWord.qualifiers.contains(w), !CWord.attributes.contains(w), w != CWord.typenameWord, !unit.isToken(i + 1, "::") {
          words += 1
          last = i
          pointerAfterLast = false
        }
      } else if unit.tokens[i].kind == .punctuation, unit.startsWith(i, 0x2A) || unit.startsWith(i, 0x26) {
        sawType = true
        if last >= 0 { pointerAfterLast = true }
      }
      i += 1
    }
    guard last >= 0 else { return -1 }
    // `cmark_map_entry *`: a name has nothing after it but brackets.
    if pointerAfterLast { return -1 }
    if words >= 2 || (sawType && words >= 1 && !isTypeLike(last)) { return last }
    // `struct foo *p`: the tag's name is the type's.
    if words == 1, sawType, last > start, !unit.isToken(last - 1, "struct"), !unit.isToken(last - 1, "enum"), !unit.isToken(last - 1, "union"),
      !unit.isToken(last - 1, "class")
    {
      return last
    }
    return -1
  }

  private func isTypeLike(_ i: Int) -> Bool {
    i > 0 && (unit.isToken(i - 1, "struct") || unit.isToken(i - 1, "enum") || unit.isToken(i - 1, "union") || unit.isToken(i - 1, "class"))
  }

  // MARK: Objective-C

  private mutating func objcAt(_ at: Int, parent: Int32, scope: Scope) -> Int {
    if unit.isToken(at, "@interface") || unit.isToken(at, "@implementation") { return container(at, isProtocol: false) }
    if unit.isToken(at, "@protocol") {
      // `@protocol P;` and `@protocol(P)` declare nothing.
      if unit.isWord(at + 1), !unit.isByte(at + 2, 0x3B), !unit.isByte(at + 2, 0x2C) { return container(at, isProtocol: true) }
      return statementEnd(at, count)
    }
    if unit.isToken(at, "@property") {
      var i = at + 1
      if unit.isByte(i, 0x28) { i = skipGroup(i) }
      let before = unit.decls.count
      let end = declaration(i, end: count, parent: parent, scope: scope, access: .isPublic)
      for index in before..<unit.decls.count where unit.decls[index].parent == parent {
        unit.decls[index].first = Int32(at)
        file.set(Int32(index), .property)
      }
      return end
    }
    if unit.isToken(at, "@import") {
      let end = statementEnd(at, count)
      var pieces: [String] = []
      var i = at + 1
      while i < end, unit.isWord(i) {
        pieces.append(unit.string(i))
        i += unit.isByte(i + 1, 0x2E) ? 2 : 1
      }
      if let first = pieces.first {
        let path = syntax.resolve(pieces.count > 1 ? first + "/" + pieces.last! + ".h" : "@" + first, true, unit.path, false)
        var item = Import(module: CodeModel.name(path ?? "?" + first), moduleName: path ?? "?" + first, isExported: true, isTestable: false)
        item.token = Int32(at + 1)
        unit.imports.append(item)
      }
      mix(at, end)
      return end
    }
    if unit.isToken(at, "@class") || unit.isToken(at, "@synthesize") || unit.isToken(at, "@dynamic") || unit.isToken(at, "@compatibility_alias") {
      return statementEnd(at, count)
    }
    return at + 1
  }

  /// `@interface Name : Super <P>`, `@interface Name (Category)`, `@implementation Name`, `@protocol P <Q>`, to `@end`.
  private mutating func container(_ at: Int, isProtocol: Bool) -> Int {
    var i = at + 1
    guard unit.isWord(i) else { return at + 1 }
    let nameToken = i
    i += 1
    var generics: [Generic] = []
    if unit.startsWith(i, 0x3C), !isProtocol {
      // Lightweight generics: `@interface NSArray<ObjectType>`.
      let close = skipAngles(i)
      for k in (i + 1)..<max(i + 1, close - 1) where unit.tokens[k].kind == .identifier && !CWord.qualifiers.contains(word(k)) {
        if unit.isByte(k - 1, 0x3C) || unit.isByte(k - 1, 0x2C) || unit.startsWith(k - 1, 0x3C) { generics.append(Generic(name: unit.hash(k), token: Int32(k))) }
      }
      i = close
    }
    let isImplementation = unit.isToken(at, "@implementation")
    var kind: DeclKind = isProtocol ? .protocolType : isImplementation ? .extensionDecl : .classType
    if unit.isByte(i, 0x28) {
      kind = .extensionDecl
      i = skipGroup(i)
    }
    var bases: [(Int32, Int32)] = []
    if unit.isByte(i, 0x3A) || unit.isToken(i, ":"), unit.isWord(i + 1) {
      bases.append((Int32(i + 1), Int32(i + 2)))
      i += 2
      if unit.startsWith(i, 0x3C), !unit.isWord(i + 1) || true {
        // A superclass's type arguments, `NSObject<Foo *>`? No: protocols follow the superclass in angles.
      }
    }
    if unit.startsWith(i, 0x3C) {
      let close = skipAngles(i)
      for k in (i + 1)..<max(i + 1, close - 1) where unit.isWord(k) { bases.append((Int32(k), Int32(k + 1))) }
      i = close
    }
    var decl = Decl(kind: kind, name: unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(at), parent: -1)
    decl.access = .isPublic
    if !bases.isEmpty {
      decl.inheritStart = Int32(unit.ranges.count)
      for base in bases { unit.ranges.append((start: base.0, end: base.1)) }
      decl.inheritCount = Int32(bases.count)
    }
    if !generics.isEmpty {
      decl.genericStart = Int32(unit.generics.count)
      unit.generics.append(contentsOf: generics)
      decl.genericCount = Int32(generics.count)
    }
    mix(at, i)
    let index = addDecl(decl)
    if isImplementation { file.set(index, .implementation) }
    if kind != .extensionDecl { register(index, parent: -1, ordinary: true, tag: false) }
    if unit.isByte(i, 0x7B) {
      // Instance variables.
      let close = skipGroup(i) - 1
      members(from: i + 1, to: close, parent: index, scope: .record(index))
      i = close + 1
    }
    let stop = members(from: i, to: count, parent: index, scope: .objc(index))
    let end = unit.isToken(stop, "@end") ? stop + 1 : stop
    unit.decls[Int(index)].bodyOpen = Int32(i)
    unit.decls[Int(index)].bodyClose = Int32(stop)
    unit.decls[Int(index)].end = Int32(end)
    mix(stop, end)
    return end
  }

  /// `- (Type)piece:(Type)name piece2:(Type)name2;`, or with a body.
  private mutating func method(_ at: Int, parent: Int32) -> Int {
    var i = at + 1
    var typeStart: Int32 = -1
    var typeEnd: Int32 = -1
    if unit.isByte(i, 0x28) {
      let close = skipGroup(i) - 1
      typeStart = Int32(i + 1)
      typeEnd = Int32(close)
      i = close + 1
    }
    var pieces: [Int] = []
    var selector = ""
    var params: [Param] = []
    while i < count {
      if unit.tokens[i].kind == .directive {
        i = past(i)
        continue
      }
      var piece = -1
      if unit.isWord(i), unit.isByte(i + 1, 0x3A) || unit.isToken(i + 1, ":") || pieces.isEmpty {
        piece = i
        pieces.append(i)
        selector += unit.string(i)
        i += 1
      }
      guard unit.isByte(i, 0x3A) || unit.isToken(i, ":") else { break }
      selector += ":"
      i += 1
      var paramType: (Int32, Int32) = (-1, -1)
      if unit.isByte(i, 0x28) {
        let close = skipGroup(i) - 1
        paramType = (Int32(i + 1), Int32(close))
        i = close + 1
      }
      while unit.isWord(i), CWord.qualifiers.contains(word(i)) { i += 1 }
      if unit.isWord(i) {
        params.append(
          Param(
            label: piece >= 0 ? unit.hash(piece) : 0, local: unit.hash(i), nameToken: Int32(i), typeStart: paramType.0, typeEnd: paramType.1, hasDefault: false,
            variadic: false))
        i += 1
      }
      if unit.isByte(i, 0x2C), unit.isToken(i + 1, "...") { i += 2 }
    }
    guard let first = pieces.first else { return statementEnd(at, count) }
    // Attributes and macros up to the body or `;`.
    while i < count, !unit.isByte(i, 0x3B), !unit.isByte(i, 0x7B) {
      if unit.tokens[i].kind == .directive {
        i = past(i)
        continue
      }
      if unit.tokens[i].kind == .attribute || unit.tokens[i].kind == .close || unit.startsWith(i, 0x2D) || unit.startsWith(i, 0x2B) { break }
      i = unit.isByte(i, 0x28) ? skipGroup(i) : i + 1
    }
    var decl = Decl(kind: .function, name: CodeModel.name(selector), nameToken: Int32(first), first: Int32(at), parent: parent)
    decl.isStatic = unit.isByte(at, 0x2B)
    decl.typeStart = typeStart
    decl.typeEnd = typeEnd
    decl.access = .isPublic
    decl.paramStart = Int32(unit.params.count)
    unit.params.append(contentsOf: params)
    decl.paramCount = Int32(params.count)
    var end = i
    if unit.isByte(i, 0x7B) {
      let close = skipGroup(i) - 1
      decl.bodyOpen = Int32(i)
      decl.bodyClose = Int32(close)
      end = close + 1
      mix(at, i)
    } else {
      if unit.isByte(i, 0x3B) { end = i + 1 }
      mix(at, end)
    }
    decl.end = Int32(end)
    let index = addDecl(decl)
    file.selectors[index] = pieces.map { Int32($0) }
    return end
  }
}
