import CodeModel
import CodeScan
import Foundation

/// Ruby's reading of a file into the core's tables. CodeScan lexes `@x`, `@@x` and `$x` as one identifier with their
/// sign, `:name` as a string token (a symbol), `%w[…]` and the other percent literals as strings, and a keyword after
/// `.`, after `def` or written as a label (`end:`) as a name, so the words that open and close blocks are only ever
/// what they look like here.
///
/// - `class` is a `classType`, `module` a `namespace`, both named by the last constant of their path (`class A::B` is
///   `B`, the whole path its type range); a superclass and each `include`, `extend` and `prepend` in the body are
///   inherited ranges (the word before tells them apart; a superclass follows `<`, `=` or `(`).
/// - `class << self` is an `extensionDecl` holding singleton methods (static).
/// - `def` is a `function` (`initialize` an `initializer`), static when it's `def self.x` or inside `class << self`,
///   named as Ruby names it (`x=`, `x?`, `[]`, `==`); its parameters carry their name as label and local.
/// - `X = …` at a class's, module's or file's level is a static `variable` (a constant); `X = Struct.new(:a)`,
///   `Data.define`, `Class.new(Base)` and `Module.new` make a class or module whose block holds its methods.
/// - `attr_reader`, `attr_writer`, `attr_accessor` and `attr` declare `variable`s at their symbols (`x` and `x=`),
///   `alias`/`alias_method` and `define_method` `function`s; a struct's members are `variable`s.
/// - `require`, `require_relative`, `load` and `autoload` with a literal path are imports (`RubyImport` kinds in
///   `member`), and so are the folders a file adds to `$LOAD_PATH` (`File.expand_path('../lib', __dir__)`).
///
/// The scopes (files, methods, class bodies, blocks, lambdas) and their parameters are kept in a `RubyStructure` for
/// the body scan.
package final class RubySyntax: LanguageSyntax {
  package let profile = LexProfile.profile(forLanguage: "ruby")!
  package let parametersHaveLabels = false

  package init() {}

  package func parse(_ unit: CodeModel.Unit) -> UInt64 {
    var parser = RubyParser(unit: unit)
    parser.parseFile()
    unit.scans[RubyStructure.key] = parser.structure
    return parser.shape
  }

  package func evaluateCondition(_ unit: CodeModel.Unit, _ i: inout Int) -> Bool { true }

  package func conditional(_ unit: CodeModel.Unit, _ i: Int) -> ConditionalDirective { .none }
}

/// What an import is, in `Import.member`.
enum RubyImport {
  static let require: Name = 0, requireRelative: Name = 1, load: Name = 2, autoload: Name = 3
  /// A folder added to `$LOAD_PATH`, relative to the file's folder.
  static let loadPath: Name = 4
}

/// A scope of local variables: a file, a method, a class or module body (each a gate), or a block or lambda (which
/// sees the scope around it).
struct RubyScope {
  enum Kind: UInt8 { case file, method, classBody, block, lambda }
  var kind: Kind
  /// The first token of the construct (`def`, `class`, `do`, `{`, `->`) and the token that ends it (`end`, `}`, or the
  /// last of an endless method).
  var open: Int32
  var close: Int32
  /// The parameters' tokens.
  var paramStart: Int32 = -1
  var paramEnd: Int32 = -1
  /// The declaration it belongs to (a method, class, module or singleton class), -1 for a block.
  var decl: Int32 = -1
  var parent: Int32 = -1
  var isGate: Bool { kind != .block && kind != .lambda }
}

/// A file's scopes, in the order they open, read with its declarations.
final class RubyStructure: BodyFacts {
  static let key = Int32.min
  var scopes: [RubyScope] = []
  /// Modules whose instance methods are also their own (`module_function`, `extend self`).
  var selfExtending: Set<Int32> = []
  func dropTypes() {}

  /// The innermost scope a token is in.
  func scope(at token: Int32) -> Int32 {
    var found: Int32 = 0
    var low = 0
    var high = scopes.count
    // The last scope opening at or before the token, then out to one that holds it.
    while low < high {
      let middle = (low + high) / 2
      if scopes[middle].open <= token { low = middle + 1 } else { high = middle }
    }
    var index = Int32(low - 1)
    while index > 0 {
      let scope = scopes[Int(index)]
      if scope.open <= token, token <= scope.close { return index }
      index = scope.parent
    }
    found = 0
    return found
  }
}

// MARK: Tokens

extension Unit {
  /// A word: an identifier or a keyword.
  @inline(__always) func rbIsWord(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    let kind = tokens[i].kind
    return kind == .identifier || kind == .keyword || kind == .declarationKeyword
  }

  @inline(__always) func rbIsIdentifier(_ i: Int) -> Bool { i >= 0 && i < tokens.count && tokens[i].kind == .identifier }

  @inline(__always) func rbFirst(_ i: Int) -> UInt8 { source.text[tokens[i].start] }

  /// `Foo`: an identifier starting with a capital.
  func rbIsConstant(_ i: Int) -> Bool {
    guard rbIsIdentifier(i) else { return false }
    let b = rbFirst(i)
    return b >= 0x41 && b <= 0x5A
  }

  /// A local's or method's name: a plain identifier, not a constant or a variable with a sign.
  func rbIsPlain(_ i: Int) -> Bool {
    guard rbIsIdentifier(i) else { return false }
    let b = rbFirst(i)
    return !(b >= 0x41 && b <= 0x5A) && b != 0x40 && b != 0x24
  }

  func rbIsIvar(_ i: Int) -> Bool { rbIsIdentifier(i) && rbFirst(i) == 0x40 && tokens[i].length > 1 && source.text[tokens[i].start + 1] != 0x40 }
  func rbIsCvar(_ i: Int) -> Bool { rbIsIdentifier(i) && rbFirst(i) == 0x40 && tokens[i].length > 2 && source.text[tokens[i].start + 1] == 0x40 }
  func rbIsGlobal(_ i: Int) -> Bool { rbIsIdentifier(i) && rbFirst(i) == 0x24 }

  /// `:name`: a symbol.
  func rbIsSymbol(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count, tokens[i].kind == .string, tokens[i].length > 1, rbFirst(i) == 0x3A else { return false }
    let b = source.text[tokens[i].start + 1]
    return b != 0x22 && b != 0x27
  }

  /// A symbol's or a plain string literal's text: `:name` → `name`, `'a/b'` → `a/b`; nil for anything else (an
  /// interpolated string too).
  func rbLiteral(_ i: Int) -> String? {
    guard i >= 0, i < tokens.count, tokens[i].kind == .string else { return nil }
    let token = tokens[i]
    let first = rbFirst(i)
    if first == 0x3A {
      guard rbIsSymbol(i) else { return nil }
      return String(decoding: UnsafeBufferPointer(start: source.text + token.start + 1, count: token.length - 1), as: UTF8.self)
    }
    guard first == 0x22 || first == 0x27, token.length >= 2, source.text[token.end - 1] == first else { return nil }
    // A string whose interpolation was split off isn't whole.
    if i + 1 < tokens.count, tokens[i + 1].kind == .interpolationOpen, tokens[i + 1].start == token.end { return nil }
    if i > 0, tokens[i - 1].kind == .interpolationClose, tokens[i - 1].end == token.start { return nil }
    return String(decoding: UnsafeBufferPointer(start: source.text + token.start + 1, count: token.length - 2), as: UTF8.self)
  }

  /// `.` or `&.`: a method call on what's before.
  func rbIsDot(_ i: Int) -> Bool { isToken(i, ".") || isToken(i, "&.") }

  func rbIsColon2(_ i: Int) -> Bool { isToken(i, "::") }

  /// A token that ends a value: after it, `if` is a modifier and `{` a block.
  func rbIsValueEnd(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    switch tokens[i].kind {
    case .identifier, .number, .string, .close, .interpolationClose: return true
    case .keyword:
      return isToken(i, "end") || isToken(i, "self") || isToken(i, "nil") || isToken(i, "true") || isToken(i, "false")
        || isToken(i, "__FILE__") || isToken(i, "__LINE__") || isToken(i, "redo") || isToken(i, "retry") || isToken(i, "break")
        || isToken(i, "next") || isToken(i, "return") || isToken(i, "super") || isToken(i, "yield") || isToken(i, "__ENCODING__")
    default: return false
    }
  }

  /// Whether a token can't end a statement: an operator, a comma, an open bracket, `.`, a word like `and`.
  func rbContinues(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    switch tokens[i].kind {
    case .punctuation:
      if isByte(i, 0x3B) { return false }
      // A block's parameters end with `|`; a statement starts after them.
      if isToken(i, "|") {
        let line = source.lines.line(of: tokens[i].start)
        var k = i - 1
        while k >= 0, source.lines.line(of: tokens[k].start) == line {
          if isToken(k, "|") { return !(isToken(k - 1, "do") || isByte(k - 1, 0x7B)) }
          k -= 1
        }
      }
      return true
    case .open, .interpolationOpen: return true
    case .keyword: return isToken(i, "and") || isToken(i, "or") || isToken(i, "not")
    default: return false
    }
  }

  /// The first token of the statement a token is in, scanning back no further than `limit`.
  func rbStatementStart(_ i: Int, limit: Int = 0) -> Int {
    var k = i
    // A closing bracket is in the statement its opening one is.
    if i < tokens.count, tokens[i].kind == .close, let open = matchingOpen(i), open >= limit { k = open }
    var depth = 0
    while k > limit {
      if depth == 0 {
        if isByte(k - 1, 0x3B) { return k }
        if startsLine(k), !rbContinues(k - 1), !rbIsDot(k) { return k }
        if tokens[k - 1].kind == .keyword, isToken(k - 1, "then") || isToken(k - 1, "do") || isToken(k - 1, "else") || isToken(k - 1, "begin") || isToken(k - 1, "ensure") {
          return k
        }
      }
      let kind = tokens[k - 1].kind
      if kind == .close || kind == .interpolationClose { depth += 1 } else if kind == .open || kind == .interpolationOpen {
        if depth == 0 { return k }
        depth -= 1
      }
      k -= 1
    }
    return limit
  }

  /// The token after the statement that starts at or contains `from`: a line's end outside brackets, or `;`.
  func rbStatementEnd(_ from: Int, limit: Int) -> Int {
    var k = from
    var depth = 0
    while k < limit {
      if depth == 0, k > from {
        if isByte(k, 0x3B) { return k }
        if startsLine(k), !rbContinues(k - 1), !rbIsDot(k), tokens[k].kind != .close { return k }
      }
      let kind = tokens[k].kind
      if kind == .open || kind == .interpolationOpen { depth += 1 } else if kind == .close || kind == .interpolationClose {
        if depth == 0 { return k }
        depth -= 1
      }
      k += 1
    }
    return limit
  }

  /// A source line's text (from 0), untrimmed.
  func rbLine(_ line: Int) -> String {
    let start = source.lines.offset(line: line, character: 0, in: source.text)
    var end = start
    let bytes = source.bytes
    while end < bytes.count, bytes[end] != 10 { end += 1 }
    return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
  }

  /// The `#` comment lines right above a token's line, top first, without their `#`.
  func rbCommentLines(above token: Int) -> [String] {
    guard token >= 0, token < tokens.count else { return [] }
    var line = source.lines.line(of: tokens[token].start) - 1
    var lines: [String] = []
    while line >= 0 {
      let text = rbLine(line).trimmingCharacters(in: .whitespaces)
      guard text.hasPrefix("#") else { break }
      lines.insert(String(text.dropFirst()), at: 0)
      line -= 1
    }
    return lines
  }
}

// MARK: Parser

struct RubyParser {
  let unit: Unit
  var shape: UInt64 = 14_695_981_039_346_656_037
  let structure = RubyStructure()
  private var count: Int { unit.tokens.count }

  enum FrameKind { case bracket, interpolation, brace, block, lambda, decl, keyword, loop }

  struct Frame {
    var kind: FrameKind
    var token: Int
    var decl: Int32 = -1
    var scope: Int32 = -1
    /// For a class, module or singleton class: its inherited ranges as they're found, and the access new methods get.
    var inherits: [(Int32, Int32)] = []
    var access: Access = .isPublic
    var moduleFunction = false
  }

  private var frames: [Frame] = []
  /// Method bodies, left out of the shape.
  private var bodies: [(Int, Int)] = []
  /// A block that belongs to a class made by `Struct.new` and its kin.
  private var pendingBlockOwner: Int32 = -1
  /// A lambda's `->`, waiting for its `{` or `do`.
  private var pendingLambda = -1
  /// While a loop's header is read, its `do` is its own.
  private var loopHeader = false
  /// The `|` closing a block's parameters: a statement starts after it.
  private var paramsClose = -1

  init(unit: Unit) { self.unit = unit }

  mutating func parseFile() {
    structure.scopes.append(RubyScope(kind: .file, open: 0, close: Int32(max(0, count - 1))))
    var i = 0
    while i < count { i = step(i) }
    while !frames.isEmpty { close(frames.count - 1, at: count - 1) }
    mixShape()
  }

  private mutating func mixShape() {
    bodies.sort { $0.0 < $1.0 }
    var b = 0
    var i = 0
    while i < count {
      while b < bodies.count, bodies[b].1 <= i { b += 1 }
      if b < bodies.count, bodies[b].0 <= i {
        // Inside a method: only what other files see of it (instance variables) counts.
        if unit.rbIsIvar(i) || unit.rbIsCvar(i) || unit.rbIsGlobal(i) { shape = (shape ^ unit.hash(i)) &* 1_099_511_628_211 }
        i += 1
        continue
      }
      shape = (shape ^ unit.hash(i)) &* 1_099_511_628_211
      i += 1
    }
    for decl in unit.decls { shape = (shape ^ decl.name ^ UInt64(decl.kind.rawValue)) &* 1_099_511_628_211 }
  }

  /// The innermost declaration (class, module, singleton class or method) around.
  private var currentDecl: Int32 {
    for frame in frames.reversed() where frame.decl >= 0 { return frame.decl }
    return -1
  }

  /// The innermost class, module or singleton class frame, not past a method.
  private var bodyFrame: Int? {
    for index in frames.indices.reversed() {
      let frame = frames[index]
      if frame.decl >= 0 {
        let kind = unit.decls[Int(frame.decl)].kind
        return kind == .function || kind == .initializer ? nil : index
      }
    }
    return nil
  }

  private var inMethod: Bool {
    for frame in frames.reversed() where frame.decl >= 0 {
      let kind = unit.decls[Int(frame.decl)].kind
      return kind == .function || kind == .initializer
    }
    return false
  }

  private var currentScope: Int32 {
    for frame in frames.reversed() where frame.scope >= 0 { return frame.scope }
    return 0
  }

  @discardableResult
  private mutating func add(_ decl: Decl) -> Int32 {
    unit.decls.append(decl)
    return Int32(unit.decls.count - 1)
  }

  private func newDecl(_ kind: DeclKind, name text: String, nameToken: Int, first: Int) -> Decl {
    var decl = Decl(kind: kind, name: name(text), nameToken: Int32(nameToken), first: Int32(first), parent: currentDecl)
    decl.access = .isPublic
    return decl
  }

  private mutating func openScope(_ kind: RubyScope.Kind, open: Int, decl: Int32 = -1, params: (Int, Int)? = nil) -> Int32 {
    var scope = RubyScope(kind: kind, open: Int32(open), close: Int32(count - 1))
    scope.decl = decl
    scope.parent = currentScope
    if let params {
      scope.paramStart = Int32(params.0)
      scope.paramEnd = Int32(params.1)
    }
    structure.scopes.append(scope)
    return Int32(structure.scopes.count - 1)
  }

  /// Whether `i` starts a statement.
  private func startsStatement(_ i: Int) -> Bool {
    if i == 0 { return true }
    if i - 1 == paramsClose { return true }
    if unit.isByte(i - 1, 0x3B) { return true }
    if unit.tokens[i - 1].kind == .keyword, unit.isToken(i - 1, "then") || unit.isToken(i - 1, "do") || unit.isToken(i - 1, "else") || unit.isToken(i - 1, "begin")
      || unit.isToken(i - 1, "ensure")
    {
      return true
    }
    if unit.isByte(i - 1, 0x7B), frames.last?.kind == .block || frames.last?.kind == .lambda { return true }
    return unit.startsLine(i) && !unit.rbContinues(i - 1) && !unit.rbIsDot(i)
  }

  /// One token, or a construct from it: the token after.
  private mutating func step(_ i: Int) -> Int {
    let token = unit.tokens[i]
    if loopHeader, startsStatement(i), frames.last?.token != i { loopHeader = false }
    switch token.kind {
    case .open:
      return openBracket(i)
    case .interpolationOpen:
      frames.append(Frame(kind: .interpolation, token: i))
      return i + 1
    case .close, .interpolationClose:
      closeBracket(i)
      return i + 1
    case .keyword, .declarationKeyword:
      return keyword(i)
    case .identifier:
      return identifier(i)
    case .punctuation:
      if unit.isToken(i, "->") { pendingLambda = i }
      return i + 1
    default:
      return i + 1
    }
  }

  // MARK: Brackets and blocks

  /// Whether a `{` opens a block (after a call: a name, `)`, a lambda's `->`) rather than a hash.
  private func isBlockBrace(_ i: Int) -> Bool {
    if pendingLambda >= 0 { return true }
    guard i > 0 else { return false }
    let previous = i - 1
    if unit.tokens[previous].kind == .close { return unit.isByte(previous, 0x29) }
    if unit.rbIsIdentifier(previous) {
      // `foo {`, `items.each {`; a local before `{` can't take one, but names alone can't tell.
      let b = unit.rbFirst(previous)
      return b != 0x40 && b != 0x24
    }
    return unit.isToken(previous, "super")
  }

  private mutating func openBracket(_ i: Int) -> Int {
    guard unit.isByte(i, 0x7B), isBlockBrace(i) else {
      frames.append(Frame(kind: .bracket, token: i))
      return i + 1
    }
    return openBlock(i, isBrace: true)
  }

  /// `do |a, b|`, `{ |x| … }`, `-> (x) { … }`: a block scope with its parameters.
  private mutating func openBlock(_ i: Int, isBrace: Bool) -> Int {
    var params: (Int, Int)?
    var next = i + 1
    let isLambda = pendingLambda >= 0
    if isLambda {
      var start = pendingLambda + 1
      var end = i
      if unit.isByte(start, 0x28), let close = Optional(unit.skipBalanced(start)), close <= i {
        start += 1
        end = close - 1
      }
      if end > start { params = (start, end) }
      pendingLambda = -1
    } else if i + 1 < count, unit.tokens[i + 1].kind == .punctuation, unit.rbFirst(i + 1) == 0x7C {
      if unit.isToken(i + 1, "||") {
        next = i + 2
        paramsClose = i + 1
      } else {
        // The closing `|`: the next token starting with one, outside brackets.
        var k = i + 2
        var depth = 0
        while k < count, k < i + 200 {
          let kind = unit.tokens[k].kind
          if kind == .open { depth += 1 } else if kind == .close { depth -= 1 }
          if depth == 0, kind == .punctuation, unit.rbFirst(k) == 0x7C { break }
          if depth < 0 { break }
          k += 1
        }
        if k < count, unit.rbFirst(k) == 0x7C {
          params = (i + 1, k)
          next = k + 1
          paramsClose = k
        }
      }
    }
    var frame = Frame(kind: isLambda ? .lambda : isBrace ? .brace : .block, token: i)
    if pendingBlockOwner >= 0 {
      frame.decl = pendingBlockOwner
      frame.inherits = pendingBlockInherits
      pendingBlockOwner = -1
      pendingBlockInherits = []
    }
    frame.scope = openScope(isLambda ? .lambda : .block, open: i, decl: frame.decl, params: params)
    frames.append(frame)
    return next
  }

  private mutating func closeBracket(_ i: Int) {
    let isInterpolation = unit.tokens[i].kind == .interpolationClose
    var found: Int?
    for index in frames.indices.reversed() {
      let frame = frames[index]
      if isInterpolation {
        if frame.kind == .interpolation { found = index }
      } else if frame.kind == .bracket {
        if matches(frame.token, i) { found = index }
      } else if frame.kind == .brace || frame.kind == .lambda && unit.isByte(frame.token, 0x7B) {
        if unit.isByte(i, 0x7D) { found = index }
      }
      if found != nil { break }
    }
    guard let at = found else { return }
    while frames.count > at + 1 { close(frames.count - 1, at: i) }
    close(at, at: i)
  }

  private func matches(_ open: Int, _ close: Int) -> Bool {
    let a = unit.rbFirst(open)
    let b = unit.rbFirst(close)
    return a == 0x28 && b == 0x29 || a == 0x5B && b == 0x5D || a == 0x7B && b == 0x7D
  }

  /// Ends the frame at `index` at token `at`.
  private mutating func close(_ index: Int, at: Int) {
    let frame = frames.remove(at: index)
    if frame.scope >= 0 { structure.scopes[Int(frame.scope)].close = Int32(at) }
    guard frame.decl >= 0, frame.kind == .decl || frame.kind == .block || frame.kind == .brace else { return }
    let d = Int(frame.decl)
    if frame.kind == .decl {
      unit.decls[d].end = Int32(at + 1)
      unit.decls[d].bodyClose = Int32(at)
    } else if unit.decls[d].end < Int32(at + 1) {
      // A `Struct.new(…) do … end`: the class ends with its block.
      unit.decls[d].end = Int32(at + 1)
      unit.decls[d].bodyClose = Int32(at)
    }
    let kind = unit.decls[d].kind
    if kind == .function || kind == .initializer {
      bodies.append((Int(unit.decls[d].bodyOpen), at))
    }
    if !frame.inherits.isEmpty {
      // A superclass first, then includes as written: appended once the body is read.
      unit.decls[d].inheritStart = Int32(unit.ranges.count)
      unit.decls[d].inheritCount = Int32(frame.inherits.count)
      unit.ranges += frame.inherits.map { (start: $0.0, end: $0.1) }
    }
    if frame.moduleFunction { structure.selfExtending.insert(frame.decl) }
  }

  // MARK: Keywords

  private mutating func keyword(_ i: Int) -> Int {
    if unit.isToken(i, "end") {
      guard let at = frames.lastIndex(where: { $0.kind == .decl || $0.kind == .keyword || $0.kind == .loop || $0.kind == .block || ($0.kind == .lambda && !unit.isByte($0.token, 0x7B)) })
      else { return i + 1 }
      while frames.count > at + 1 { close(frames.count - 1, at: i) }
      close(at, at: i)
      return i + 1
    }
    if unit.isToken(i, "do") {
      if loopHeader, let last = frames.last, last.kind == .loop {
        loopHeader = false
        return i + 1
      }
      return openBlock(i, isBrace: false)
    }
    if unit.isToken(i, "class") { return classDeclaration(i) }
    if unit.isToken(i, "module") { return moduleDeclaration(i) }
    if unit.isToken(i, "def") { return method(i) }
    if unit.isToken(i, "if") || unit.isToken(i, "unless") || unit.isToken(i, "while") || unit.isToken(i, "until") {
      // A modifier follows a value on its line; a statement's `if` opens a block.
      if !startsStatement(i), unit.rbIsValueEnd(i - 1), !unit.startsLine(i) { return i + 1 }
      let isLoop = unit.isToken(i, "while") || unit.isToken(i, "until")
      frames.append(Frame(kind: isLoop ? .loop : .keyword, token: i))
      if isLoop { loopHeader = true }
      return i + 1
    }
    if unit.isToken(i, "for") {
      frames.append(Frame(kind: .loop, token: i))
      loopHeader = true
      return i + 1
    }
    if unit.isToken(i, "case") || unit.isToken(i, "begin") {
      frames.append(Frame(kind: .keyword, token: i))
      return i + 1
    }
    if unit.isToken(i, "alias"), startsStatement(i) || unit.rbIsIdentifier(i - 1) {
      // `alias new old`, `alias :new :old`.
      let newName = i + 1
      guard newName < count, unit.rbIsWord(newName) || unit.rbIsSymbol(newName) else { return i + 1 }
      if unit.rbIsGlobal(newName) { return i + 2 }
      let text = unit.rbLiteral(newName) ?? unit.string(newName)
      var decl = newDecl(.function, name: text, nameToken: newName, first: i)
      decl.end = Int32(min(count, i + 3))
      if newName + 1 < count { decl.typeStart = Int32(newName + 1) }
      decl.access = frames.indices.contains(bodyFrame ?? -1) ? frames[bodyFrame!].access : .isPublic
      add(decl)
      return min(count, i + 3)
    }
    return i + 1
  }

  /// A constant path from `i` (`A`, `A::B`, `::A::B`): its last constant and the token after it.
  private func constantPath(_ i: Int) -> (last: Int, next: Int)? {
    var k = i
    if unit.rbIsColon2(k) { k += 1 }
    guard unit.rbIsConstant(k) else { return nil }
    while unit.rbIsColon2(k + 1), unit.rbIsConstant(k + 2) { k += 2 }
    return (k, k + 1)
  }

  private mutating func classDeclaration(_ i: Int) -> Int {
    if unit.isToken(i + 1, "<<") {
      // `class << self`: the singleton class.
      let target = i + 2
      var decl = newDecl(.extensionDecl, name: "<<" + (target < count ? unit.string(target) : ""), nameToken: min(target, count - 1), first: i)
      decl.isStatic = unit.isToken(target, "self")
      decl.bodyOpen = Int32(min(count, target + 1))
      let index = add(decl)
      var frame = Frame(kind: .decl, token: i, decl: index)
      frame.scope = openScope(.classBody, open: i, decl: index)
      frames.append(frame)
      return target + 1
    }
    guard let path = constantPath(i + 1) else {
      frames.append(Frame(kind: .keyword, token: i))
      return i + 1
    }
    var decl = newDecl(.classType, name: unit.string(path.last), nameToken: path.last, first: i)
    decl.typeStart = Int32(i + 1)
    decl.typeEnd = Int32(path.next)
    var frame = Frame(kind: .decl, token: i)
    var next = path.next
    if unit.isByte(next, 0x3C), next + 1 < count {
      // `< Superclass`, to the statement's end.
      let start = next + 1
      let end = unit.rbStatementEnd(start, limit: count)
      if end > start {
        frame.inherits.append((Int32(start), Int32(end)))
        if let structOpen = structMembersOpen(start, end) { pendingStructMembers = structOpen }
      }
      next = end
    }
    decl.bodyOpen = Int32(min(count, next))
    let index = add(decl)
    frame.decl = index
    frame.scope = openScope(.classBody, open: i, decl: index)
    frames.append(frame)
    if pendingStructMembers >= 0 {
      structMembers(pendingStructMembers, owner: index)
      pendingStructMembers = -1
    }
    return next
  }

  private var pendingStructMembers = -1
  private var pendingBlockInherits: [(Int32, Int32)] = []

  /// `Struct.new(` or `Data.define(` in a range: the `(`'s token.
  private func structMembersOpen(_ start: Int, _ end: Int) -> Int? {
    var k = start
    while k + 3 < end {
      if unit.isToken(k, "Struct") && unit.rbIsDot(k + 1) && unit.isToken(k + 2, "new") || unit.isToken(k, "Data") && unit.rbIsDot(k + 1) && unit.isToken(k + 2, "define"),
        unit.isByte(k + 3, 0x28)
      {
        return k + 3
      }
      k += 1
    }
    return nil
  }

  /// A struct's members, its symbols up to the `)`: accessors of the class.
  private mutating func structMembers(_ open: Int, owner: Int32) {
    let close = min(count, unit.skipBalanced(open))
    var k = open + 1
    while k < close {
      if unit.rbIsSymbol(k), let text = unit.rbLiteral(k) {
        var writer = Decl(kind: .variable, name: name(text + "="), nameToken: Int32(k), first: Int32(k), parent: owner)
        writer.end = Int32(k + 1)
        writer.access = .isPublic
        var reader = writer
        reader.name = name(text)
        add(writer)
        add(reader)
      }
      k += 1
    }
  }

  private mutating func moduleDeclaration(_ i: Int) -> Int {
    guard let path = constantPath(i + 1) else {
      frames.append(Frame(kind: .keyword, token: i))
      return i + 1
    }
    var decl = newDecl(.namespace, name: unit.string(path.last), nameToken: path.last, first: i)
    decl.typeStart = Int32(i + 1)
    decl.typeEnd = Int32(path.next)
    decl.bodyOpen = Int32(min(count, path.next))
    let index = add(decl)
    var frame = Frame(kind: .decl, token: i, decl: index)
    frame.scope = openScope(.classBody, open: i, decl: index)
    frames.append(frame)
    return path.next
  }

  /// `def name(params)`, `def self.name`, `def name=(v)`, `def ==(o)`, endless `def name = expr`.
  private mutating func method(_ i: Int) -> Int {
    var k = i + 1
    guard k < count else { return k }
    var isStatic = false
    var otherObject = false
    // `self.` or `Const.`: a singleton method; `obj.` another object's.
    if unit.isToken(k, "self") || unit.rbIsIdentifier(k), unit.rbIsDot(k + 1) || unit.rbIsColon2(k + 1), k + 2 < count, unit.touchesPrevious(k + 1) {
      isStatic = true
      otherObject = !unit.isToken(k, "self")
      k += 2
    }
    let nameToken = k
    var text: String
    var after = k + 1
    if unit.rbIsWord(k) {
      text = unit.string(k)
      // `def x=(v)`: a setter.
      if unit.isByte(k + 1, 0x3D), unit.touchesPrevious(k + 1), unit.isByte(k + 2, 0x28) || unit.rbIsIdentifier(k + 2) && !unit.startsLine(k + 2) {
        text += "="
        after = k + 2
      }
    } else if unit.isByte(k, 0x5B), unit.isByte(k + 1, 0x5D) {
      text = "[]"
      after = k + 2
      if unit.isByte(after, 0x3D), unit.touchesPrevious(after) {
        text = "[]="
        after += 1
      }
    } else if unit.tokens[k].kind == .punctuation {
      text = unit.string(k)
      if unit.isByte(k + 1, 0x40), unit.touchesPrevious(k + 1) {
        text += "@"
        after = k + 2
      }
    } else {
      frames.append(Frame(kind: .keyword, token: i))
      return k
    }
    var decl = newDecl(text == "initialize" && !isStatic ? .initializer : .function, name: text, nameToken: nameToken, first: i)
    if let body = bodyFrame {
      if unit.decls[Int(frames[body].decl)].kind == .extensionDecl { isStatic = true }
      decl.access = frames[body].access
      if frames[body].moduleFunction { structure.selfExtending.insert(frames[body].decl) }
    } else if frames.isEmpty || currentDecl < 0 {
      // A method at a file's level is Object's, private.
      decl.access = .isPrivate
    }
    decl.isStatic = isStatic
    // `def obj.x`, `def Const.x`: not the class's own (`Const` may be it, but it's rare and told apart by nothing).
    decl.isLocal = otherObject
    // Parameters: in parentheses, or to the line's end.
    var paramsRange: (Int, Int)
    var bodyStart: Int
    if unit.isByte(after, 0x28) {
      let close = unit.skipBalanced(after)
      paramsRange = (after + 1, max(after + 1, close - 1))
      bodyStart = close
    } else {
      let end = after < count && !unit.startsLine(after) && !unit.isByte(after, 0x3B) && !unit.isByte(after, 0x3D) ? unit.rbStatementEnd(after, limit: count) : after
      paramsRange = (after, end)
      bodyStart = end
    }
    parameters(paramsRange.0, paramsRange.1, into: &decl)
    decl.bodyOpen = Int32(min(count, bodyStart))
    let index = add(decl)
    if unit.isByte(bodyStart, 0x3D), !unit.startsLine(bodyStart) {
      // Endless: the expression to the statement's end.
      let end = unit.rbStatementEnd(bodyStart, limit: count)
      unit.decls[Int(index)].end = Int32(end)
      unit.decls[Int(index)].bodyClose = Int32(max(bodyStart, end - 1))
      let scope = openScope(.method, open: i, decl: index, params: paramsRange)
      structure.scopes[Int(scope)].close = Int32(max(bodyStart, end - 1))
      bodies.append((bodyStart, end))
      // What follows is the method's until its end: read it as part of the scope.
      return bodyStart + 1
    }
    var frame = Frame(kind: .decl, token: i, decl: index)
    frame.scope = openScope(.method, open: i, decl: index, params: paramsRange)
    frames.append(frame)
    return bodyStart
  }

  /// A method's parameters between two tokens: names after `(`, `,`, `*`, `**`, `&` or at the start, labels as keyword
  /// parameters; defaults skipped.
  private mutating func parameters(_ start: Int, _ end: Int, into decl: inout Decl) {
    decl.paramStart = Int32(unit.params.count)
    var k = start
    var expectingName = true
    var depth = 0
    while k < end {
      let token = unit.tokens[k]
      if token.kind == .open {
        depth += 1
        k += 1
        continue
      }
      if token.kind == .close {
        depth -= 1
        k += 1
        continue
      }
      if depth == 0, unit.isByte(k, 0x2C) {
        expectingName = true
        k += 1
        continue
      }
      if depth == 0, token.kind == .punctuation {
        // `*`, `**`, `&`: a name follows; `=`: a default value doesn't.
        let last = unit.source.text[token.end - 1]
        if last == 0x2A || last == 0x26 { expectingName = true } else if expectingName, token.length == 1, last == 0x3D { expectingName = false } else { expectingName = false }
        k += 1
        continue
      }
      if depth == 0, expectingName, unit.rbIsPlain(k) {
        let isLabel = unit.isByte(k + 1, 0x3A) && unit.touchesPrevious(k + 1) && !unit.rbIsColon2(k + 1)
        let variadic = k > start && unit.tokens[k - 1].kind == .punctuation && unit.rbFirst(k - 1) == 0x2A
        let word = unit.hash(k)
        unit.params.append(Param(label: word, local: word, nameToken: Int32(k), typeStart: -1, typeEnd: -1, hasDefault: isLabel ? !unit.isByte(k + 2, 0x2C) && k + 2 < end : unit.isByte(k + 1, 0x3D), variadic: variadic))
        decl.paramCount += 1
        expectingName = false
        if isLabel { k += 1 }
      }
      k += 1
    }
  }

  // MARK: Statements by name

  private mutating func identifier(_ i: Int) -> Int {
    let atStart = startsStatement(i) || (i > 0 && (unit.isToken(i - 1, "private") || unit.isToken(i - 1, "protected") || unit.isToken(i - 1, "public")) && !unit.startsLine(i))
    if !unit.rbIsDot(i - 1), !unit.rbIsColon2(i - 1) {
      if unit.isToken(i, "require") || unit.isToken(i, "require_relative") || unit.isToken(i, "load") || unit.isToken(i, "autoload") {
        requireStatement(i)
      } else if unit.isToken(i, "$LOAD_PATH") || unit.isToken(i, "$:") {
        loadPathStatement(i)
      }
    }
    guard atStart else { return i + 1 }
    if unit.rbIsConstant(i), let next = constantAssignment(i) { return next }
    guard !inMethod || isInBlockOfClassMethod else { return i + 1 }
    let word = unit.string(i)
    switch word {
    case "attr_reader", "attr_writer", "attr_accessor", "attr":
      return attributes(i, reader: word != "attr_writer", writer: word == "attr_writer" || word == "attr_accessor")
    case "alias_method":
      return aliasMethod(i)
    case "define_method", "define_singleton_method":
      return defineMethod(i, isStatic: word == "define_singleton_method")
    case "include", "extend", "prepend":
      return mixins(i)
    case "private", "protected", "public", "module_function", "private_class_method", "public_class_method":
      return visibility(i, word)
    default:
      return i + 1
    }
  }

  /// Methods inside a method's block don't declare (`define_method` in a `self.included` hook aside).
  private var isInBlockOfClassMethod: Bool { false }

  /// `require 'x'`, `require_relative "x"`, `load 'x.rb'`, `autoload :X, 'x'`, also with parentheses or a file
  /// relative path built with `File.expand_path`/`File.join` from `__dir__` or `__FILE__`.
  private mutating func requireStatement(_ i: Int) {
    var k = i + 1
    if unit.isByte(k, 0x28), unit.touchesPrevious(k) { k += 1 }
    let kind: Name
    switch unit.string(i) {
    case "require_relative": kind = RubyImport.requireRelative
    case "load": kind = RubyImport.load
    case "autoload": kind = RubyImport.autoload
    default: kind = RubyImport.require
    }
    var aliasToken = -1
    if kind == RubyImport.autoload {
      guard unit.rbIsSymbol(k), unit.isByte(k + 1, 0x2C) else { return }
      aliasToken = k
      k += 2
    }
    if let text = unit.rbLiteral(k), unit.tokens[k].kind == .string, !unit.rbIsSymbol(k) {
      var item = Import(module: name(text), moduleName: text, isExported: false, isTestable: false)
      item.member = kind
      item.token = Int32(k)
      if aliasToken >= 0 {
        item.aliasToken = Int32(aliasToken)
        item.alias = name(unit.rbLiteral(aliasToken) ?? "")
      }
      unit.imports.append(item)
      return
    }
    if let relative = fileRelativePath(k) {
      var item = Import(module: name(relative.path), moduleName: relative.path, isExported: false, isTestable: false)
      item.member = kind == RubyImport.require || kind == RubyImport.load ? RubyImport.requireRelative : kind
      item.token = Int32(relative.token)
      unit.imports.append(item)
    }
  }

  /// `File.expand_path('../x', __dir__)`, `File.expand_path('../x', __FILE__)`, `File.join(__dir__, 'a', 'b')`,
  /// `File.join(File.dirname(__FILE__), 'x')`: a path relative to the file's folder, and its string's token.
  private func fileRelativePath(_ k: Int) -> (path: String, token: Int)? {
    guard unit.isToken(k, "File"), unit.rbIsDot(k + 1), unit.isByte(k + 3, 0x28) else { return nil }
    let close = unit.skipBalanced(k + 3) - 1
    guard close > k + 3 else { return nil }
    func isDirectory(_ a: Int) -> (Bool, Int)? {
      if unit.isToken(a, "__dir__") { return (true, a + 1) }
      if unit.isToken(a, "__FILE__") { return (false, a + 1) }
      if unit.isToken(a, "File"), unit.rbIsDot(a + 1), unit.isToken(a + 2, "dirname"), unit.isByte(a + 3, 0x28), unit.isToken(a + 4, "__FILE__"), unit.isByte(a + 5, 0x29) {
        return (true, a + 6)
      }
      return nil
    }
    if unit.isToken(k + 2, "expand_path") {
      guard let text = unit.rbLiteral(k + 4), unit.isByte(k + 5, 0x2C), let (isDir, end) = isDirectory(k + 6), end == close else { return nil }
      if isDir { return (text, k + 4) }
      // Relative to the file itself: its first `..` is its folder.
      if text.hasPrefix("../") { return (String(text.dropFirst(3)), k + 4) }
      if text == ".." { return (".", k + 4) }
      return nil
    }
    if unit.isToken(k + 2, "join") {
      guard let (isDir, end) = isDirectory(k + 4), isDir else { return nil }
      var parts: [String] = []
      var a = end
      var first = -1
      while a < close {
        guard unit.isByte(a, 0x2C), let text = unit.rbLiteral(a + 1) else { return nil }
        if first < 0 { first = a + 1 }
        parts.append(text)
        a += 2
      }
      guard !parts.isEmpty else { return nil }
      return (parts.joined(separator: "/"), first)
    }
    return nil
  }

  /// `$LOAD_PATH.unshift(<path>)`, `$LOAD_PATH << <path>`, `$:.push <path>`: a folder relative to this file's.
  private mutating func loadPathStatement(_ i: Int) {
    var k = i + 1
    if unit.rbIsDot(k), unit.isToken(k + 1, "unshift") || unit.isToken(k + 1, "push") || unit.isToken(k + 1, "prepend") || unit.isToken(k + 1, "append") {
      k += 2
      if unit.isByte(k, 0x28) { k += 1 }
    } else if unit.isToken(k, "<<") {
      k += 1
    } else {
      return
    }
    guard let relative = fileRelativePath(k) else { return }
    var item = Import(module: name(relative.path), moduleName: relative.path, isExported: false, isTestable: false)
    item.member = RubyImport.loadPath
    item.token = Int32(relative.token)
    unit.imports.append(item)
  }

  /// `X = …` (or `X ||= …`) at a class's, module's or file's level: a constant, or a class `Struct.new`, `Data.define`,
  /// `Class.new` or `Module.new` makes.
  private mutating func constantAssignment(_ i: Int) -> Int? {
    guard unit.isToken(i + 1, "=") || unit.isToken(i + 1, "||="), !inMethod else { return nil }
    let valueStart = i + 2
    let end = unit.rbStatementEnd(valueStart, limit: count)
    // `Struct.new(:a, :b) do … end`: the block is part of the statement, its `do` read next.
    var made: DeclKind?
    var superStart = -1
    var superEnd = -1
    if unit.isToken(valueStart, "Struct") || unit.isToken(valueStart, "Data"), unit.rbIsDot(valueStart + 1), unit.isToken(valueStart + 2, "new") || unit.isToken(valueStart + 2, "define") {
      made = .classType
      superStart = valueStart
      superEnd = valueStart + 1
    } else if unit.isToken(valueStart, "Class") || unit.isToken(valueStart, "Module"), unit.rbIsDot(valueStart + 1), unit.isToken(valueStart + 2, "new") {
      made = unit.isToken(valueStart, "Class") ? .classType : .namespace
      if made == .classType, unit.isByte(valueStart + 3, 0x28), let path = constantPath(valueStart + 4) {
        superStart = valueStart + 4
        superEnd = path.next
      }
    }
    guard let kind = made else {
      var decl = newDecl(.variable, name: unit.string(i), nameToken: i, first: i)
      decl.isStatic = true
      decl.initStart = Int32(valueStart)
      decl.initEnd = Int32(end)
      decl.end = Int32(end)
      add(decl)
      return i + 1
    }
    var decl = newDecl(kind, name: unit.string(i), nameToken: i, first: i)
    decl.typeStart = Int32(i)
    decl.typeEnd = Int32(i + 1)
    decl.initStart = Int32(valueStart)
    decl.initEnd = Int32(end)
    decl.end = Int32(end)
    let index = add(decl)
    if kind == .classType, let open = structMembersOpen(valueStart, end) { structMembers(open, owner: index) }
    // A block right after the call (`do` or `{`) holds the class's methods.
    var k = valueStart
    while k < count, k <= end {
      if unit.isToken(k, "do") || unit.isByte(k, 0x7B) && unit.isByte(k - 1, 0x29) || unit.isByte(k, 0x7B) && (unit.isToken(k - 1, "new") || unit.isToken(k - 1, "define")) {
        pendingBlockOwner = index
        break
      }
      if unit.tokens[k].kind == .open { k = unit.skipBalanced(k) } else { k += 1 }
    }
    if pendingBlockOwner == index {
      unit.decls[Int(index)].bodyOpen = Int32(k)
      if superStart >= 0 { pendingBlockInherits = [(Int32(superStart), Int32(superEnd))] }
      return k
    }
    if superStart >= 0 {
      unit.decls[Int(index)].inheritStart = Int32(unit.ranges.count)
      unit.decls[Int(index)].inheritCount = 1
      unit.ranges.append((Int32(superStart), Int32(superEnd)))
    }
    return i + 1
  }

  private func accessHere() -> Access {
    guard let body = bodyFrame else { return .isPublic }
    return frames[body].access
  }

  /// `attr_accessor :a, :b` (or strings): readers and writers at their symbols.
  private mutating func attributes(_ i: Int, reader: Bool, writer: Bool) -> Int {
    var k = i + 1
    if unit.isByte(k, 0x28), unit.touchesPrevious(k) { k += 1 }
    let access = accessHere()
    while k < count, let text = unit.rbLiteral(k), unit.tokens[k].kind == .string {
      if writer {
        var decl = newDecl(.variable, name: text + "=", nameToken: k, first: i)
        decl.end = Int32(k + 1)
        decl.access = access
        add(decl)
      }
      if reader {
        var decl = newDecl(.variable, name: text, nameToken: k, first: i)
        decl.end = Int32(k + 1)
        decl.access = access
        add(decl)
      }
      guard unit.isByte(k + 1, 0x2C) else { return k + 1 }
      k += 2
    }
    return k
  }

  /// `alias_method :new, :old`.
  private mutating func aliasMethod(_ i: Int) -> Int {
    var k = i + 1
    if unit.isByte(k, 0x28), unit.touchesPrevious(k) { k += 1 }
    guard let text = unit.rbLiteral(k), unit.isByte(k + 1, 0x2C), unit.rbLiteral(k + 2) != nil else { return i + 1 }
    var decl = newDecl(.function, name: text, nameToken: k, first: i)
    decl.typeStart = Int32(k + 2)
    decl.end = Int32(k + 3)
    decl.access = accessHere()
    add(decl)
    return k + 3
  }

  /// `define_method(:name) do |args| … end`: a method at its symbol; the block stays a block.
  private mutating func defineMethod(_ i: Int, isStatic: Bool) -> Int {
    var k = i + 1
    if unit.isByte(k, 0x28), unit.touchesPrevious(k) { k += 1 }
    guard unit.rbIsSymbol(k), let text = unit.rbLiteral(k) else { return i + 1 }
    var decl = newDecl(.function, name: text, nameToken: k, first: i)
    decl.end = Int32(k + 1)
    decl.isStatic = isStatic
    decl.access = accessHere()
    add(decl)
    return k + 1
  }

  /// `include A, B::C`: inherited ranges of the class or module around.
  private mutating func mixins(_ i: Int) -> Int {
    guard let body = bodyFrame else { return i + 1 }
    var k = i + 1
    if unit.isByte(k, 0x28), unit.touchesPrevious(k) { k += 1 }
    if unit.isToken(i, "extend"), unit.isToken(k, "self") {
      frames[body].moduleFunction = true
      return k + 1
    }
    while let path = constantPath(k) {
      frames[body].inherits.append((Int32(k), Int32(path.next)))
      k = path.next
      guard unit.isByte(k, 0x2C) else { break }
      k += 1
    }
    return k
  }

  /// `private` alone (what follows), `private :a, :b`, `private def x` (the `def` reads it), `module_function`.
  private mutating func visibility(_ i: Int, _ word: String) -> Int {
    guard let body = bodyFrame else { return i + 1 }
    let access: Access = word == "private" ? .isPrivate : word == "protected" ? .inherited : .isPublic
    var k = i + 1
    if unit.isByte(k, 0x28), unit.touchesPrevious(k) { k += 1 }
    if word == "module_function" {
      frames[body].moduleFunction = true
      return i + 1
    }
    if unit.rbIsSymbol(k) {
      // Named: those methods, as declared so far.
      while unit.rbIsSymbol(k), let text = unit.rbLiteral(k) {
        let key = name(text)
        if word != "private_class_method", word != "public_class_method" {
          for index in unit.decls.indices.reversed() where unit.decls[index].name == key && unit.decls[index].parent == frames[body].decl {
            unit.decls[index].access = access
          }
        }
        guard unit.isByte(k + 1, 0x2C) else { break }
        k += 2
      }
      return k + 1
    }
    if word == "private_class_method" || word == "public_class_method" { return i + 1 }
    if unit.startsLine(i + 1) || unit.isByte(i + 1, 0x3B) || i + 1 >= count {
      frames[body].access = access
    } else if unit.isToken(k, "def") {
      // `private def x`: that one.
      let before = unit.decls.count
      let next = method(k)
      if unit.decls.count > before { unit.decls[before].access = access }
      return next
    } else if unit.isToken(k, "attr_reader") || unit.isToken(k, "attr_accessor") || unit.isToken(k, "attr_writer") {
      let before = unit.decls.count
      let w = unit.string(k)
      let next = attributes(k, reader: w != "attr_writer", writer: w != "attr_reader")
      for index in before..<unit.decls.count { unit.decls[index].access = access }
      return next
    }
    return i + 1
  }
}
