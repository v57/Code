import Foundation

/// A declaration found in a file. Names live in the file's `FileSymbols.names`, so the source can go away.
public struct Symbol: Sendable {
  public var nameOffset: UInt32
  public var nameLength: UInt16
  public var kind: SymbolKind
  public var isLocal: Bool
  /// The symbol it's inside, -1 at the top level.
  public var parent: Int32
  /// Where the name is in the source.
  public var offset: UInt32
  /// The declaration's whole range, from its first word or modifier to the end of its body or line.
  public var start: UInt32
  public var end: UInt32
  /// The part of the source where the name is visible (a local's block), or its body (a type's, a function's).
  public var scopeStart: UInt32
  public var scopeEnd: UInt32
}

public struct BracketProblem: Sendable {
  public var offset: UInt32
  public var length: UInt32
  public var message: String
}

/// A file's declarations and what else one pass over its tokens learns.
public struct FileSymbols: Sendable {
  public var symbols: [Symbol] = []
  public var names: [UInt8] = []
  /// Multi-line brackets, outermost last: what folds.
  public var blocks: [(start: UInt32, end: UInt32)] = []
  public var problems: [BracketProblem] = []

  public func name(_ symbol: Symbol) -> String {
    names.withUnsafeBufferPointer { buffer in
      String(
        decoding: UnsafeBufferPointer(rebasing: buffer[Int(symbol.nameOffset)..<Int(symbol.nameOffset) + Int(symbol.nameLength)]),
        as: UTF8.self)
    }
  }

  @inline(__always) func nameEquals(_ symbol: Symbol, _ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
    guard Int(symbol.nameLength) == bytes.count else { return false }
    return names.withUnsafeBufferPointer { memcmp($0.baseAddress! + Int(symbol.nameOffset), bytes.baseAddress!, bytes.count) == 0 }
  }
}

/// One pass over a file's tokens: the bracket tree and every declaration, from the language's rules.
public func extractSymbols(
  text t: UnsafePointer<UInt8>, length n: Int, tokens: UnsafeBufferPointer<Token>, profile: LexProfile
) -> FileSymbols {
  var extractor = SymbolExtractor(t: t, n: n, tokens: tokens, profile: profile)
  extractor.run()
  return extractor.file
}

private struct SymbolExtractor {
  let t: UnsafePointer<UInt8>
  let n: Int
  let tokens: UnsafeBufferPointer<Token>
  let profile: LexProfile
  let rules: LanguageRules
  var file = FileSymbols()

  struct Frame {
    var token: Int32
    var byte: UInt8
    /// The symbol whose body this is, or -1.
    var owner: Int32
    /// The first symbol index declared since it opened.
    var firstSymbol: Int32
    /// A function's parameter list: a typed name in it is not a local statement.
    var isParameterList = false
  }
  var stack: [Frame] = []
  /// A type or function declared but whose `{` hasn't come yet.
  var pendingOwner: Int32 = -1
  /// Tokens up to here were already consumed as part of a declaration.
  var consumedUntil = -1

  init(t: UnsafePointer<UInt8>, n: Int, tokens: UnsafeBufferPointer<Token>, profile: LexProfile) {
    self.t = t
    self.n = n
    self.tokens = tokens
    self.profile = profile
    rules = profile.rules
    file.symbols.reserveCapacity(tokens.count / 64)
    stack.reserveCapacity(32)
  }

  @inline(__always) func text(_ token: Token) -> UnsafeBufferPointer<UInt8> {
    UnsafeBufferPointer(start: t + token.start, count: token.length)
  }

  @inline(__always) func isByte(_ index: Int, _ byte: UInt8) -> Bool {
    index >= 0 && index < tokens.count && tokens[index].length == 1 && t[tokens[index].start] == byte
  }

  @inline(__always) func equals(_ token: Token, _ word: StaticString) -> Bool {
    token.length == word.utf8CodeUnitCount && memcmp(t + token.start, word.utf8Start, token.length) == 0
  }

  func word(_ token: Token) -> String { String(decoding: text(token), as: UTF8.self) }

  @inline(__always) func isName(_ index: Int) -> Bool {
    index < tokens.count && tokens[index].kind == .identifier
  }

  /// The nearest open owner, and whether it's a type.
  var enclosing: (owner: Int32, inType: Bool, inFunction: Bool) {
    var inFunction = false
    for frame in stack.reversed() where frame.owner >= 0 {
      let kind = file.symbols[Int(frame.owner)].kind
      if kind.isType { return (frame.owner, true, inFunction) }
      if kind.isCallable {
        // A local type inside a function still has members; the first owner decides.
        inFunction = true
        return (frame.owner, false, true)
      }
    }
    return (-1, false, false)
  }

  /// The next token after a balanced bracket that opens at `index`.
  func afterBalanced(_ index: Int) -> Int {
    var i = index
    var depth = 0
    while i < tokens.count {
      switch tokens[i].kind {
      case .open, .interpolationOpen: depth &+= 1
      case .close, .interpolationClose:
        depth &-= 1
        if depth <= 0 { return i &+ 1 }
      default: break
      }
      i &+= 1
    }
    return i
  }

  /// The next token after a `<...>`, assumed balanced within a few tokens.
  func afterAngles(_ index: Int) -> Int {
    guard index < tokens.count, tokens[index].kind == .punctuation, t[tokens[index].start] == 0x3C else { return index }
    var i = index
    var depth = 0
    while i < tokens.count, i < index &+ 64 {
      let token = tokens[i]
      if token.kind == .punctuation {
        for offset in token.start..<token.end {
          if t[offset] == 0x3C { depth &+= 1 } else if t[offset] == 0x3E, offset == token.start || t[offset &- 1] != 0x2D {
            depth &-= 1
          }
        }
        if depth <= 0 { return i &+ 1 }
      } else if token.kind == .open || token.kind == .close {
        if t[token.start] == 0x7B || t[token.start] == 0x7D { return index }
      }
      i &+= 1
    }
    return index
  }

  @discardableResult
  mutating func add(
    name token: Token, kind: SymbolKind, local: Bool, start: Int, parent: Int32? = nil, end: Int? = nil
  ) -> Int32 {
    let nameOffset = file.names.count
    file.names.append(contentsOf: text(token))
    let scope = enclosing
    var resolvedKind = kind
    let inType = parent == nil && scope.inType
    if inType {
      if kind == .function { resolvedKind = .method } else if kind == .variable || kind == .constant { resolvedKind = .property }
    }
    let symbol = Symbol(
      nameOffset: UInt32(nameOffset), nameLength: UInt16(min(token.length, 65535)), kind: resolvedKind, isLocal: local,
      parent: parent ?? scope.owner, offset: token.offset, start: UInt32(start), end: UInt32(end ?? lineEnd(token.end)),
      scopeStart: stack.last.map { UInt32(tokens[Int($0.token)].end) } ?? 0, scopeEnd: 0)
    file.symbols.append(symbol)
    return Int32(file.symbols.count &- 1)
  }

  func lineEnd(_ offset: Int) -> Int {
    guard offset < n, let found = memchr(t + offset, 0x0A, n &- offset) else { return n }
    return UnsafePointer(found.assumingMemoryBound(to: UInt8.self)) - t
  }

  func lineStart(_ offset: Int) -> Int {
    var i = offset
    while i > 0, t[i &- 1] != 0x0A { i &-= 1 }
    return i
  }

  /// Whether the token is the first on its line.
  @inline(__always) func startsLine(_ index: Int) -> Bool {
    if index == 0 { return true }
    let gapStart = tokens[index &- 1].end
    let gap = tokens[index].start &- gapStart
    return gap > 0 && memchr(t + gapStart, 0x0A, gap) != nil
  }

  mutating func run() {
    switch rules.outline {
    case .code: scanCode()
    case .jsonKeys: scanCode(keys: true)
    case .cssSelectors: scanCSS()
    default: scanLines()
    }
    finishScopes()
  }

  // MARK: - Code

  mutating func scanCode(keys: Bool = false) {
    var i = 0
    let tokens = self.tokens
    let hasDeclaringRules = rules.typedDeclarations || rules.bareMembers || rules.assignmentDeclares
    let special = rules.signatureDeclares || rules.bareFunctions || rules.arrowParameters
    while i < tokens.count {
      let token = tokens[i]
      switch token.kind {
      case .open, .interpolationOpen:
        let byte = t[token.end &- 1]
        var owner: Int32 = -1
        if byte == 0x7B, pendingOwner >= 0 {
          owner = pendingOwner
          pendingOwner = -1
        }
        stack.append(Frame(token: Int32(i), byte: byte, owner: owner, firstSymbol: Int32(file.symbols.count)))
        if byte == 0x7B, let head = rules.closureHead, owner < 0 { closureParameters(from: i &+ 1, head: head) }
        if keys, byte == 0x7B || byte == 0x5B { /* keys below */  }
      case .close, .interpolationClose:
        closeBracket(i, token)
      case .declarationKeyword:
        if i > consumedUntil { declaration(i) }
      case .directive:
        if rules.typedDeclarations { macroDefinition(token) }
      case .attribute:
        if let kind = rules.declarations[word(token)], isName(i &+ 1) {
          let symbol = add(name: tokens[i &+ 1], kind: kind, local: false, start: token.start)
          pendingOwner = symbol
          // An Objective-C container ends at @end, not a brace; its own line is its range.
        }
      case .punctuation:
        if rules.arrowParameters, token.length == 2, t[token.start] == 0x3D, t[token.start &+ 1] == 0x3E {
          arrowParameters(before: i)
        } else if t[token.start] == 0x3B {
          pendingOwner = -1
        }
      case .identifier:
        if i > consumedUntil {
          if keys { break }
          if hasDeclaringRules || special { identifier(i, token) }
        }
      case .string:
        if keys, isByte(i &+ 1, 0x3A) {
          // JSON's "key": its text without the quotes.
          let inner = Token(.identifier, token.start &+ 1, max(token.start &+ 1, token.end &- 1))
          let symbol = add(name: inner, kind: .key, local: false, start: token.start)
          if i &+ 2 < tokens.count, tokens[i &+ 2].kind == .open { pendingOwner = symbol }
          if i &+ 2 < tokens.count, tokens[i &+ 2].kind == .open, t[tokens[i &+ 2].start] == 0x5B { pendingOwner = -1 }
        }
      default: break
      }
      i &+= 1
    }
    closeOpenFrames()
  }

  mutating func closeBracket(_ i: Int, _ token: Token) {
    let byte = t[token.start]
    let expected: UInt8 = byte == 0x29 ? 0x28 : byte == 0x5D ? 0x5B : 0x7B
    if token.kind == .interpolationClose {
      if let last = stack.last, last.byte == t[tokens[Int(last.token)].end &- 1] { closeFrame(stack.removeLast(), at: i) }
      return
    }
    // A mismatch closes what it can: blocks of a file with a mistake stay useful.
    guard let top = stack.last else {
      if rules.reportsBrackets {
        file.problems.append(BracketProblem(offset: token.offset, length: 1, message: "Unmatched closing bracket"))
      }
      return
    }
    if top.byte == expected {
      closeFrame(stack.removeLast(), at: i)
      return
    }
    if let found = stack.lastIndex(where: { $0.byte == expected }) {
      if rules.reportsBrackets {
        let open = tokens[Int(stack[stack.count &- 1].token)]
        file.problems.append(BracketProblem(offset: open.offset, length: 1, message: "Bracket not closed before a later one"))
      }
      while stack.count > found { closeFrame(stack.removeLast(), at: i) }
    } else if rules.reportsBrackets {
      file.problems.append(BracketProblem(offset: token.offset, length: 1, message: "Unmatched closing bracket"))
    }
  }

  mutating func closeFrame(_ frame: Frame, at closing: Int) {
    let open = tokens[Int(frame.token)]
    let close = tokens[closing]
    if memchr(t + open.start, 0x0A, close.start &- open.start) != nil {
      file.blocks.append((open.offset, close.offset))
    }
    if frame.owner >= 0 {
      file.symbols[Int(frame.owner)].end = UInt32(close.end)
      file.symbols[Int(frame.owner)].scopeStart = UInt32(open.end)
      file.symbols[Int(frame.owner)].scopeEnd = close.offset
      if frame.byte == 0x7B { pendingOwner = -1 }
    }
    // What's declared in this bracket and still open is visible up to here.
    if frame.byte == 0x7B || frame.byte == 0x28 {
      var index = Int(frame.firstSymbol)
      let count = file.symbols.count
      while index < count {
        if file.symbols[index].scopeEnd == 0 {
          if file.symbols[index].isLocal {
            file.symbols[index].scopeEnd = close.offset
          } else if frame.byte == 0x7B {
            file.symbols[index].scopeEnd = close.offset
          }
        }
        index &+= 1
      }
    }
  }

  mutating func closeOpenFrames() {
    if rules.reportsBrackets, let last = stack.last(where: { $0.byte == 0x7B || $0.byte == 0x28 || $0.byte == 0x5B }) {
      let token = tokens[Int(last.token)]
      file.problems.append(BracketProblem(offset: token.offset, length: UInt32(token.length), message: "Unclosed bracket"))
    }
    stack.removeAll()
  }

  /// Everything still unset ends with the file; indentation languages get their ranges here.
  mutating func finishScopes() {
    if case .indentation = rules.blocks { indentationScopes() }
    let end = UInt32(n)
    for index in file.symbols.indices where file.symbols[index].scopeEnd == 0 {
      file.symbols[index].scopeEnd = end
    }
  }

  /// A declaration's body is what's indented more than its line, up to the next line that isn't.
  mutating func indentationScopes() {
    guard !file.symbols.isEmpty else { return }
    var open: [(index: Int, column: Int)] = []
    var symbolIndex = 0
    var line = 0
    while line < n {
      var first = line
      while t[first] == 0x20 || t[first] == 0x09 { first &+= 1 }
      let end = lineEnd(first)
      // Blank and comment lines don't end a body.
      let isBlank = first >= end || t[first] == 0x23 || t[first] == 0x0D
      if !isBlank {
        let column = first &- line
        while let last = open.last, column <= last.column {
          // Up to the previous line's end: a blank line after a body isn't in it.
          closeIndentation(last.index, at: line)
          open.removeLast()
        }
        while symbolIndex < file.symbols.count, Int(file.symbols[symbolIndex].offset) < end {
          var symbol = file.symbols[symbolIndex]
          symbol.parent = open.last.map { Int32($0.index) } ?? -1
          symbol.scopeStart = UInt32(end)
          if let parent = open.last.map({ file.symbols[$0.index].kind }) {
            symbol.isLocal = parent.isCallable
            if parent.isType, symbol.kind == .function { symbol.kind = .method }
            if parent.isType, symbol.kind == .variable { symbol.kind = .property }
          } else {
            symbol.isLocal = false
          }
          file.symbols[symbolIndex] = symbol
          if symbol.kind.isType || symbol.kind.isCallable || symbol.kind == .key {
            open.append((symbolIndex, column))
          }
          symbolIndex &+= 1
        }
      }
      line = end &+ 1
    }
    for entry in open { closeIndentation(entry.index, at: n) }
    // A local's scope is its owner's body.
    for index in file.symbols.indices where file.symbols[index].isLocal && file.symbols[index].parent >= 0 {
      file.symbols[index].scopeEnd = file.symbols[Int(file.symbols[index].parent)].scopeEnd
    }
  }

  mutating func closeIndentation(_ index: Int, at offset: Int) {
    var end = offset
    while end > 0, t[end &- 1] == 0x0A || t[end &- 1] == 0x20 || t[end &- 1] == 0x09 || t[end &- 1] == 0x0D { end &-= 1 }
    file.symbols[index].end = UInt32(max(end, Int(file.symbols[index].end)))
    file.symbols[index].scopeEnd = UInt32(max(end, Int(file.symbols[index].scopeStart)))
    if end > Int(file.symbols[index].scopeStart) {
      file.blocks.append((file.symbols[index].offset, UInt32(end)))
    }
  }

  // MARK: - Declarations

  mutating func declaration(_ i: Int) {
    let token = tokens[i]
    let keyword = word(token)
    var kind = profile.declarationKinds[keyword] ?? profile.declarationKinds[keyword.lowercased()] ?? .variable
    var next = i &+ 1
    guard next < tokens.count else { return }
    // `class func`, `export default class`, `local function`, `enum class`: the last word decides.
    if tokens[next].kind == .declarationKeyword {
      if rules.blocks == .indentation || !equals(tokens[next], "case") { return }
    }

    switch keyword {
    case "case":
      enumCases(i)
      return
    case "init", "subscript", "deinit":
      // Their keyword is their name. A use like `.init(` or `self.init` isn't a declaration.
      if i > 0, tokens[i &- 1].kind == .punctuation, t[tokens[i &- 1].end &- 1] == 0x2E { return }
      if keyword != "deinit", !isByte(next, 0x28), !(t[tokens[next].start] == 0x3C), !isByte(next, 0x3F), !isByte(next, 0x21) { return }
      let symbol = add(name: token, kind: keyword == "subscript" ? .function : .constructor, local: false, start: start(of: i))
      parameterList(from: next, owner: symbol)
      pendingOwner = symbol
      return
    case "let", "var", "const", "val", "final", "static", "local", "mut", "readonly":
      if keyword == "local", tokens[next].kind == .declarationKeyword { return }
      // Rust: `let mut x`; JS: `const { a, b } = ...`, Swift: `let (a, b) = ...`.
      variables(from: next, kind: kind, start: start(of: i))
      return
    case "impl":
      // `impl<T> Trait for Type`, named by the type.
      next = afterAngles(next)
      var scan = next
      var name: Token?
      while scan < tokens.count, scan < next &+ 48 {
        let candidate = tokens[scan]
        if candidate.kind == .open, t[candidate.start] == 0x7B { break }
        if candidate.kind == .identifier { name = name ?? candidate }
        if candidate.kind == .keyword, equals(candidate, "for") { name = nil }
        if candidate.kind == .punctuation, t[candidate.start] == 0x3C { scan = afterAngles(scan); continue }
        scan &+= 1
      }
      if let name { pendingOwner = add(name: name, kind: .extension, local: false, start: start(of: i)) }
      return
    case "func", "fun", "fn", "def", "function", "macro_rules":
      break
    case "typedef":
      typedefName(from: next, keywordIndex: i)
      return
    default:
      break
    }

    // Go methods: `func (r *Recv) Name(`.
    if isByte(next, 0x28), keyword == "func" { next = afterBalanced(next) }
    next = afterAngles(next)
    // `function* name`, `fn !name!`, `macro_rules! name`, `class ::A`.
    while next < tokens.count, tokens[next].kind == .punctuation, tokens[next].length <= 2, !isByte(next, 0x3D), !isByte(next, 0x3A),
      !isByte(next, 0x3B), !isByte(next, 0x2C)
    {
      next &+= 1
    }
    guard next < tokens.count, tokens[next].kind == .identifier || tokens[next].kind == .keyword else {
      // Anonymous function: only its parameters.
      if kind.isCallable, isByte(i &+ 1, 0x28) { parameterList(from: i &+ 1, owner: pendingOwner) }
      return
    }
    // A dotted name: `extension A.B`, `def self.x`, `fun Foo.bar`, `function M.x`.
    var nameIndex = next
    while nameIndex &+ 2 < tokens.count, tokens[nameIndex &+ 1].kind == .punctuation,
      tokens[nameIndex &+ 1].length == 1 && t[tokens[nameIndex &+ 1].start] == 0x2E
        || (tokens[nameIndex &+ 1].length == 2 && equals(tokens[nameIndex &+ 1], "::")),
      tokens[nameIndex &+ 2].kind == .identifier || tokens[nameIndex &+ 2].kind == .keyword
    {
      nameIndex &+= 2
    }
    // `struct foo *x` in C uses a type, doesn't declare one: only `{` or `;`-like follow-ups count.
    if rules.typedDeclarations, kind.isType, keyword != "namespace" {
      var look = afterAngles(nameIndex &+ 1)
      if isByte(look, 0x3A) {
        while look < tokens.count, !isByte(look, 0x7B), !isByte(look, 0x3B), look < nameIndex &+ 32 { look &+= 1 }
      }
      guard isByte(look, 0x7B) || isByte(look, 0x3B) else { return }
    }
    if keyword == "package", rules.blocks != .indentation, kind == .module {
      add(name: tokens[nameIndex], kind: .module, local: false, start: token.start)
      consumedUntil = nameIndex
      return
    }
    if keyword == "type" || keyword == "typealias" { kind = .typeAlias }
    let inFunction = enclosing.inFunction
    let symbol = add(name: tokens[nameIndex], kind: kind, local: inFunction && !kind.isType, start: start(of: i))
    consumedUntil = nameIndex
    pendingOwner = symbol
    if kind.isCallable {
      var after = afterAngles(nameIndex &+ 1)
      if isByte(after, 0x28) { parameterList(from: after, owner: symbol); after = afterBalanced(after) }
      consumedUntil = max(consumedUntil, after &- 1)
    }
    if rules.blocks == .indentation, kind.isCallable == false, kind.isType == false { pendingOwner = -1 }
    if case .indentation = rules.blocks { pendingOwner = -1 }
  }

  /// The earliest modifier on the declaration's line before its keyword: what a range and an outline start at.
  func start(of index: Int) -> Int {
    var i = index
    while i > 0, !startsLine(i), tokens[i &- 1].kind == .keyword || tokens[i &- 1].kind == .attribute || tokens[i &- 1].kind == .declarationKeyword { i &-= 1 }
    return tokens[i].start
  }

  mutating func variables(from first: Int, kind: SymbolKind, start: Int) {
    var next = first
    while next < tokens.count, tokens[next].kind == .keyword || tokens[next].kind == .declarationKeyword { next &+= 1 }
    guard next < tokens.count else { return }
    let scope = enclosing
    let local = !scope.inType && (scope.inFunction || !stack.isEmpty)
    if tokens[next].kind == .open {
      // Destructuring: every plain name inside, at any depth.
      let end = afterBalanced(next)
      var i = next &+ 1
      while i < end {
        let token = tokens[i]
        if token.kind == .identifier, !isByte(i &+ 1, 0x3A), !isByte(i &+ 1, 0x28) {
          add(name: token, kind: kind, local: local, start: start)
        }
        i &+= 1
      }
      consumedUntil = end
      return
    }
    guard tokens[next].kind == .identifier else { return }
    // `let Some(x) = ...`: what's in the pattern, not the constructor.
    if isByte(next &+ 1, 0x28), tokens[next].kind == .identifier {
      let end = afterBalanced(next &+ 1)
      var i = next &+ 2
      while i < end {
        if tokens[i].kind == .identifier { add(name: tokens[i], kind: kind, local: local, start: start) }
        i &+= 1
      }
      consumedUntil = end
      return
    }
    let symbol = add(name: tokens[next], kind: kind, local: local, start: start)
    consumedUntil = next
    // `var x: Int { ... }`: a computed property's body is its scope.
    var look = next &+ 1
    if isByte(look, 0x3A) {
      look &+= 1
      while look < tokens.count, look < next &+ 24, !startsLine(look) {
        if tokens[look].kind == .open, t[tokens[look].start] == 0x7B {
          pendingOwner = symbol
          break
        }
        if tokens[look].kind == .open { look = afterBalanced(look); continue }
        if isByte(look, 0x3D) { break }
        look &+= 1
      }
    }
    // `var a = 1, b = 2`, `let a, b`: more names after commas on the same statement, at this depth.
    guard rules.bareMembers || rules.typedDeclarations || isByte(next &+ 1, 0x2C) else { return }
    var i = next &+ 1
    var depth = 0
    while i < tokens.count, i < next &+ 256 {
      let token = tokens[i]
      if token.kind == .open { depth &+= 1 } else if token.kind == .close {
        if depth == 0 { break }
        depth &-= 1
      } else if depth == 0 {
        if isByte(i, 0x3B) || (startsLine(i) && !isByte(i &- 1, 0x2C)) { break }
        if isByte(i, 0x2C), isName(i &+ 1) {
          add(name: tokens[i &+ 1], kind: kind, local: local, start: start)
          consumedUntil = i &+ 1
        }
      }
      i &+= 1
    }
  }

  /// `case a, b(Int)` inside an enum declares; in a `switch` it uses, and its `let`s declare on their own.
  mutating func enumCases(_ i: Int) {
    guard let owner = stack.last?.owner, owner >= 0, file.symbols[Int(owner)].kind == .enum else { return }
    var next = i &+ 1
    while isName(next) || (next < tokens.count && tokens[next].kind == .keyword && tokens[next].length > 0) {
      add(name: tokens[next], kind: .enumMember, local: false, start: tokens[i].start, parent: owner)
      next &+= 1
      if isByte(next, 0x28) { next = afterBalanced(next) }
      if isByte(next, 0x3D) { next &+= 2 }
      guard isByte(next, 0x2C) else { break }
      next &+= 1
    }
    consumedUntil = next &- 1
  }

  /// The names in `(...)` at `open`, visible in the owner's body.
  mutating func parameterList(from open: Int, owner: Int32) {
    guard rules.parameters != .none, isByte(open, 0x28), owner >= 0 else { return }
    let end = afterBalanced(open)
    var segmentStart = open &+ 1
    var i = open &+ 1
    var depth = 0
    while i < end {
      let token = tokens[i]
      if token.kind == .open || token.kind == .interpolationOpen { depth &+= 1 }
      if token.kind == .close || token.kind == .interpolationClose {
        if depth == 0 {
          parameter(segmentStart, i, owner)
          break
        }
        depth &-= 1
      }
      if depth == 0, isByte(i, 0x2C) {
        parameter(segmentStart, i, owner)
        segmentStart = i &+ 1
      }
      i &+= 1
    }
    consumedUntil = max(consumedUntil, end &- 1)
  }

  mutating func parameter(_ first: Int, _ limit: Int, _ owner: Int32) {
    guard first < limit else { return }
    var name: Token?
    switch rules.parameters {
    case .nameFirst:
      // Before the first `:`, the last name: `label name: Type`, else the first: `a int`, `x`.
      var i = first
      var firstName: Token?
      var beforeColon: Token?
      while i < limit {
        let token = tokens[i]
        if token.kind == .identifier || token.kind == .keyword && !isKeywordModifier(token) {
          if token.kind == .identifier { firstName = firstName ?? token; beforeColon = token }
        } else if isByte(i, 0x3A) {
          name = beforeColon
          break
        } else if isByte(i, 0x3D) {
          break
        }
        if token.kind == .open { i = afterBalanced(i); continue }
        i &+= 1
      }
      name = name ?? firstName
    case .nameLast:
      var i = first
      while i < limit {
        let token = tokens[i]
        if isByte(i, 0x3D) { break }
        if token.kind == .identifier { name = token }
        if token.kind == .open {
          // `int x[]` keeps x; `void (*f)(int)` has its name inside the first one.
          if isByte(i &+ 1, 0x2A), isName(i &+ 2) { name = tokens[i &+ 2] }
          i = afterBalanced(i)
          continue
        }
        i &+= 1
      }
    case .none: break
    }
    guard let name, name.length > 0 else { return }
    let index = add(name: name, kind: .variable, local: true, start: name.start, parent: owner, end: name.end)
    // A parameter is visible from the list on; the owner's body sets the end.
    file.symbols[Int(index)].scopeStart = name.offset
  }

  func isKeywordModifier(_ token: Token) -> Bool {
    equals(token, "inout") || equals(token, "mut") || equals(token, "self") || equals(token, "const")
  }

  /// `{ a, b in` and `{ (a, b) in`: only in the first tokens after the brace.
  mutating func closureParameters(from first: Int, head: String) {
    var i = first
    let limit = min(tokens.count, first &+ 24)
    let headBytes = Array(head.utf8)
    var found = -1
    while i < limit {
      let token = tokens[i]
      if token.length == headBytes.count, memcmp(t + token.start, headBytes, token.length) == 0 {
        found = i
        break
      }
      if token.kind == .open || token.kind == .close {
        if t[token.start] != 0x28 && t[token.start] != 0x29 { return }
      }
      if token.kind == .string || token.kind == .number { return }
      if token.kind == .keyword, !equals(token, "_"), !isKeywordModifier(token) { return }
      i &+= 1
    }
    guard found > first else { return }
    i = first
    var depth = 0
    while i < found {
      let token = tokens[i]
      if token.kind == .open { depth &+= 1 }
      if token.kind == .close { depth &-= 1 }
      // In `(a: Int, b: Int)` the types are after colons.
      if token.kind == .identifier, depth <= 1, i == first || !isByte(i &- 1, 0x3A) {
        add(name: token, kind: .variable, local: true, start: token.start, end: token.end)
      }
      i &+= 1
    }
    consumedUntil = max(consumedUntil, found)
  }

  mutating func arrowParameters(before arrow: Int) {
    guard arrow > 0 else { return }
    let previous = tokens[arrow &- 1]
    if previous.kind == .identifier {
      add(name: previous, kind: .variable, local: true, start: previous.start, end: previous.end)
      return
    }
    guard previous.kind == .close, t[previous.start] == 0x29 else { return }
    var i = arrow &- 2
    var depth = 1
    var names: [Token] = []
    while i >= 0, arrow &- i < 64 {
      let token = tokens[i]
      if token.kind == .close { depth &+= 1 } else if token.kind == .open {
        depth &-= 1
        if depth == 0 { break }
      } else if token.kind == .identifier, depth == 1, !isByte(i &- 1, 0x3A) {
        names.append(token)
      }
      i &-= 1
    }
    guard depth == 0 else { return }
    // Visible from here, and the block it sits in ends them.
    for name in names.reversed() {
      add(name: name, kind: .variable, local: true, start: name.start, end: name.end)
    }
  }

  mutating func typedefName(from first: Int, keywordIndex: Int) {
    var i = first
    var last: Token?
    var depth = 0
    while i < tokens.count, i < first &+ 4096 {
      let token = tokens[i]
      if token.kind == .open { depth &+= 1 }
      if token.kind == .close { depth &-= 1 }
      if depth == 0 {
        if isByte(i, 0x3B) { break }
        if token.kind == .identifier { last = token }
      }
      if depth == 1, isByte(i, 0x2A), isName(i &+ 1) { last = tokens[i &+ 1] }
      i &+= 1
    }
    if let last {
      add(name: last, kind: .typeAlias, local: false, start: tokens[keywordIndex].start, end: tokens[min(i, tokens.count &- 1)].end)
    }
  }

  mutating func macroDefinition(_ token: Token) {
    // #define NAME ...: the whole line is one token.
    var i = token.start &+ 1
    let end = token.end
    while i < end, t[i] == 0x20 || t[i] == 0x09 { i &+= 1 }
    guard end &- i > 7, memcmp(t + i, "define", 6) == 0, t[i &+ 6] == 0x20 || t[i &+ 6] == 0x09 else { return }
    i &+= 6
    while i < end, t[i] == 0x20 || t[i] == 0x09 { i &+= 1 }
    let start = i
    while i < end, profile.ident[Int(t[i])] != 0 { i &+= 1 }
    guard i > start else { return }
    add(name: Token(.identifier, start, i), kind: .constant, local: false, start: token.start, end: token.end)
  }

  // MARK: - Keywordless declarations

  mutating func identifier(_ i: Int, _ token: Token) {
    let next = i &+ 1
    guard next < tokens.count else { return }
    let scope = enclosing

    if rules.signatureDeclares, startsLine(i), token.start == lineStart(token.start), isTwoColons(next) {
      add(name: token, kind: .function, local: false, start: token.start)
      return
    }
    if rules.bareFunctions, isByte(next, 0x28), isByte(next &+ 1, 0x29), startsLine(i) {
      add(name: token, kind: .function, local: false, start: token.start)
      return
    }
    if rules.assignmentDeclares, isSingleAssignment(next), startsLine(i) {
      // `name = ...` once per scope is enough: the first is the definition.
      add(name: token, kind: .variable, local: false, start: token.start)
      return
    }
    if rules.bareMembers, scope.inType, stack.last?.owner == scope.owner {
      if isByte(next, 0x28), startsLine(i) || isModifier(i &- 1) {
        let after = afterBalanced(next)
        var look = after
        if isByte(look, 0x3A) {
          look &+= 1
          while look < tokens.count, look < after &+ 16, !isByte(look, 0x7B), !isByte(look, 0x3B) { look &+= 1 }
        }
        if isByte(look, 0x7B) || isByte(look, 0x3B) {
          let symbol = add(name: token, kind: .function, local: false, start: token.start)
          parameterList(from: next, owner: symbol)
          pendingOwner = symbol
        }
        return
      }
      if startsLine(i) || isModifier(i &- 1), isByte(next, 0x3A) || isByte(next, 0x3D) || isByte(next, 0x3B) {
        add(name: token, kind: .property, local: false, start: token.start)
        return
      }
    }
    if rules.typedDeclarations { typedDeclaration(i, token, scope) }
  }

  func isModifier(_ index: Int) -> Bool {
    index >= 0 && tokens[index].kind == .keyword
  }

  func isTwoColons(_ index: Int) -> Bool {
    index < tokens.count && tokens[index].length == 2 && t[tokens[index].start] == 0x3A && t[tokens[index].start &+ 1] == 0x3A
  }

  func isSingleAssignment(_ index: Int) -> Bool {
    index < tokens.count && tokens[index].kind == .punctuation && tokens[index].length == 1 && t[tokens[index].start] == 0x3D
  }

  /// `Type name(...)`, `Type name = ...`, `Type *name;`.
  mutating func typedDeclaration(_ i: Int, _ token: Token, _ scope: (owner: Int32, inType: Bool, inFunction: Bool)) {
    guard i > 0 else { return }
    let previous = tokens[i &- 1]
    let afterType: Bool
    switch previous.kind {
    case .identifier: afterType = true
    case .keyword:
      // `int x`, `void f`, `unsigned y`, but not `return x`, `case x`, `new X`, `else x`, `throw x`.
      afterType = !isStatementWord(previous)
    case .close: afterType = t[previous.start] == 0x5D  // int[] x.
    case .punctuation:
      let last = t[previous.end &- 1]
      // `Foo *x`, `Foo &x`, `Foo **x`, `List<int> x`, not `a * b;`: it must start the statement. Not `a->b`, either.
      let first = t[previous.start]
      guard (last == 0x2A || last == 0x26 || last == 0x3E) && first == last else { return }
      guard i >= 2, tokens[i &- 2].kind == .identifier || tokens[i &- 2].kind == .keyword else { return }
      guard
        i < 3 || startsLine(i &- 2) || isByte(i &- 3, 0x3B) || isByte(i &- 3, 0x7B) || isByte(i &- 3, 0x7D) || tokens[i &- 3].kind == .keyword
          || tokens[i &- 3].kind == .declarationKeyword  // `struct T *x`.
      else {
        return
      }
      afterType = true
    default: return
    }
    guard afterType else { return }
    let next = i &+ 1
    guard next < tokens.count else { return }
    let top = stack.last
    let inParameters = top?.byte == 0x28 || top?.byte == 0x5B
    if inParameters { return }
    if isByte(next, 0x28) {
      // A function when its parentheses are followed by a body or `;`, and not inside another function.
      guard !scope.inFunction else { return }
      var after = afterBalanced(next)
      while after < tokens.count, tokens[after].kind == .keyword || tokens[after].kind == .identifier && after < next &+ 64 {
        if tokens[after].kind == .identifier, !startsLine(after) { after &+= 1; continue }
        if tokens[after].kind == .keyword { after &+= 1; continue }
        break
      }
      if isByte(after, 0x3A) {  // C++ constructor initializers.
        while after < tokens.count, !isByte(after, 0x7B), !isByte(after, 0x3B), after < next &+ 128 { after &+= 1 }
      }
      guard isByte(after, 0x7B) || isByte(after, 0x3B) || isByte(after, 0x3D) else { return }
      let symbol = add(name: token, kind: .function, local: false, start: lineFirstToken(i))
      parameterList(from: next, owner: symbol)
      if isByte(after, 0x7B) { pendingOwner = symbol }
      return
    }
    guard isByte(next, 0x3D) || isByte(next, 0x3B) || isByte(next, 0x2C) || isByte(next, 0x5B) else { return }
    add(name: token, kind: .variable, local: scope.inFunction, start: lineFirstToken(i))
    moreDeclarators(after: i, local: scope.inFunction)
  }

  /// `int a, *b = f(1, 2), c[3];`: the names after the first, which nothing else in the statement marks.
  private mutating func moreDeclarators(after first: Int, local: Bool) {
    var i = first &+ 1
    var depth = 0
    let limit = min(tokens.count, first &+ 512)
    var expectsName = false
    while i < limit {
      let token = tokens[i]
      switch token.kind {
      case .open, .interpolationOpen: depth &+= 1
      case .close, .interpolationClose:
        if depth == 0 { return }
        depth &-= 1
      case .punctuation:
        guard depth == 0 else { break }
        if isByte(i, 0x3B) { return }
        if isByte(i, 0x2C) { expectsName = true }
      case .identifier:
        if expectsName, depth == 0 {
          expectsName = false
          let next = i &+ 1
          guard next < tokens.count else { return }
          // Anything else after it means this wasn't a list of names: `a, b(c)`.
          guard isByte(next, 0x3D) || isByte(next, 0x3B) || isByte(next, 0x2C) || isByte(next, 0x5B) else { return }
          add(name: token, kind: .variable, local: local, start: lineFirstToken(i))
        }
      default:
        if expectsName { return }
      }
      i &+= 1
    }
  }

  func lineFirstToken(_ index: Int) -> Int {
    var i = index
    while i > 0, !startsLine(i) { i &-= 1 }
    return tokens[i].start
  }

  func isStatementWord(_ token: Token) -> Bool {
    switch token.length {
    case 2: return equals(token, "do") || equals(token, "if") || equals(token, "in") || equals(token, "is") || equals(token, "as")
    case 3: return equals(token, "new") || equals(token, "for") || equals(token, "try")
    case 4: return equals(token, "case") || equals(token, "else") || equals(token, "goto") || equals(token, "this")
    case 5: return equals(token, "throw") || equals(token, "await") || equals(token, "yield") || equals(token, "using") || equals(token, "class") || equals(token, "break") || equals(token, "super")
    case 6: return equals(token, "return") || equals(token, "delete") || equals(token, "sizeof") || equals(token, "import") || equals(token, "public") || equals(token, "typeof")
    case 7: return equals(token, "default") || equals(token, "package") || equals(token, "extends") || equals(token, "private")
    default: return equals(token, "continue") || equals(token, "protected")
    }
  }

  // MARK: - Formats

  mutating func scanCSS() {
    var selectorStart = -1
    var i = 0
    while i < tokens.count {
      let token = tokens[i]
      if token.kind == .comment || token.kind == .docComment { i &+= 1; continue }
      if selectorStart < 0 { selectorStart = i }
      if token.kind == .open, t[token.start] == 0x7B {
        var symbol: Int32 = -1
        if selectorStart < i {
          var end = tokens[i &- 1].end
          if end &- tokens[selectorStart].start > 200 { end = tokens[selectorStart].start &+ 200 }
          symbol = add(name: Token(.identifier, tokens[selectorStart].start, end), kind: .class, local: false, start: tokens[selectorStart].start)
        }
        stack.append(Frame(token: Int32(i), byte: 0x7B, owner: symbol, firstSymbol: Int32(file.symbols.count)))
        selectorStart = -1
      } else if token.kind == .close {
        closeBracket(i, token)
        selectorStart = -1
      } else if token.kind == .open {
        stack.append(Frame(token: Int32(i), byte: t[token.start], owner: -1, firstSymbol: Int32(file.symbols.count)))
      } else if isByte(i, 0x3B) {
        selectorStart = -1
      }
      i &+= 1
    }
    closeOpenFrames()
  }

  /// YAML keys, TOML sections and keys, Markdown headings, Makefile targets, Dockerfile stages: line by line.
  mutating func scanLines() {
    var parentLevels: [(level: Int, symbol: Int32)] = []
    var line = 0
    var inFence = false
    var tokenIndex = 0
    while line < n {
      let end = lineEnd(line)
      var first = line
      while first < end, t[first] == 0x20 || t[first] == 0x09 { first &+= 1 }
      while tokenIndex < tokens.count, tokens[tokenIndex].end <= line { tokenIndex &+= 1 }
      // Inside a multi-line string or comment there's nothing to find.
      let covered = tokenIndex < tokens.count && tokens[tokenIndex].start < line
      if first < end, !covered {
        switch rules.outline {
        case .markdownHeadings:
          if end &- first >= 3, memcmp(t + first, "```", 3) == 0 || memcmp(t + first, "~~~", 3) == 0 { inFence.toggle() }
          if !inFence, t[first] == 0x23, first == line {
            var level = 0
            while first &+ level < end, t[first &+ level] == 0x23 { level &+= 1 }
            if level <= 6, t[first &+ level] == 0x20 {
              var titleEnd = end
              while titleEnd > first, t[titleEnd &- 1] == 0x20 || t[titleEnd &- 1] == 0x0D || t[titleEnd &- 1] == 0x23 { titleEnd &-= 1 }
              if titleEnd > first &+ level &+ 1 {
                while let last = parentLevels.last, last.level >= level {
                  closeSection(last.symbol, at: line)
                  parentLevels.removeLast()
                }
                let name = Token(.identifier, first &+ level &+ 1, titleEnd)
                let symbol = add(name: name, kind: level == 1 ? .module : .class, local: false, start: first, parent: parentLevels.last?.symbol ?? -1)
                parentLevels.append((level, symbol))
              }
            }
          }
        case .yamlKeys:
          yamlKey(first, end, line, &parentLevels)
        case .tomlKeys:
          tomlLine(first, end, line, &parentLevels)
        case .makeTargets:
          if t[line] != 0x09, t[first] != 0x23, t[first] != 0x2E {
            var i = first
            while i < end, profile.ident[Int(t[i])] != 0 || t[i] == 0x2E || t[i] == 0x2F { i &+= 1 }
            var colon = i
            while colon < end, t[colon] == 0x20 { colon &+= 1 }
            if i > first {
              if colon < end, t[colon] == 0x3A, t[colon &+ 1] != 0x3D {
                add(name: Token(.identifier, first, i), kind: .function, local: false, start: first)
              } else if colon < end, t[colon] == 0x3D || (t[colon] == 0x3A && t[colon &+ 1] == 0x3D) || (t[colon] == 0x3F && t[colon &+ 1] == 0x3D) {
                add(name: Token(.identifier, first, i), kind: .variable, local: false, start: first)
              }
            }
          }
        case .dockerStages:
          if end &- first > 5, memchr(t + first, 0x20, end &- first) != nil, wordEqualsLower(first, "from") {
            // FROM image AS name
            var i = end
            while i > first, t[i &- 1] == 0x20 || t[i &- 1] == 0x0D { i &-= 1 }
            let stop = i
            while i > first, t[i &- 1] != 0x20 { i &-= 1 }
            add(name: Token(.identifier, i, stop), kind: .module, local: false, start: first)
          }
        default: break
        }
      }
      line = end &+ 1
    }
    for entry in parentLevels { closeSection(entry.symbol, at: n) }
  }

  func wordEqualsLower(_ at: Int, _ word: StaticString) -> Bool {
    for offset in 0..<word.utf8CodeUnitCount where t[at &+ offset] | 0x20 != word.utf8Start[offset] { return false }
    return true
  }

  mutating func closeSection(_ symbol: Int32, at offset: Int) {
    var end = offset
    while end > 0, t[end &- 1] == 0x0A || t[end &- 1] == 0x20 || t[end &- 1] == 0x0D { end &-= 1 }
    let index = Int(symbol)
    file.symbols[index].end = UInt32(max(end, Int(file.symbols[index].end)))
    file.symbols[index].scopeStart = file.symbols[index].end > file.symbols[index].offset ? file.symbols[index].offset : 0
    file.symbols[index].scopeEnd = UInt32(end)
    if lineEnd(Int(file.symbols[index].offset)) < end {
      file.blocks.append((file.symbols[index].offset, UInt32(end)))
    }
  }

  mutating func yamlKey(_ first: Int, _ end: Int, _ line: Int, _ levels: inout [(level: Int, symbol: Int32)]) {
    var keyStart = first
    if t[keyStart] == 0x23 { return }
    if t[keyStart] == 0x2D, t[keyStart &+ 1] == 0x20 {
      keyStart &+= 2
      while keyStart < end, t[keyStart] == 0x20 { keyStart &+= 1 }
    }
    guard keyStart < end else { return }
    var i = keyStart
    let quote = t[i] == 0x22 || t[i] == 0x27 ? t[i] : 0
    if quote != 0 {
      i &+= 1
      while i < end, t[i] != quote { i &+= 1 }
      i &+= 1
    } else {
      while i < end, t[i] != 0x3A, t[i] != 0x20, t[i] != 0x23 { i &+= 1 }
    }
    guard i < end, t[i] == 0x3A, i &+ 1 >= end || t[i &+ 1] == 0x20 || t[i &+ 1] == 0x0D else { return }
    let column = keyStart &- line
    while let last = levels.last, last.level >= column {
      closeSection(last.symbol, at: line)
      levels.removeLast()
    }
    let nameStart = quote != 0 ? keyStart &+ 1 : keyStart
    let nameEnd = quote != 0 ? i &- 1 : i
    let symbol = add(name: Token(.identifier, nameStart, nameEnd), kind: .key, local: false, start: keyStart, parent: levels.last?.symbol ?? -1)
    levels.append((column, symbol))
  }

  mutating func tomlLine(_ first: Int, _ end: Int, _ line: Int, _ levels: inout [(level: Int, symbol: Int32)]) {
    if t[first] == 0x5B {
      var i = first
      while i < end, t[i] == 0x5B { i &+= 1 }
      let nameStart = i
      while i < end, t[i] != 0x5D { i &+= 1 }
      for entry in levels { closeSection(entry.symbol, at: line) }
      levels.removeAll()
      let symbol = add(name: Token(.identifier, nameStart, i), kind: .module, local: false, start: first, parent: -1)
      levels.append((0, symbol))
      return
    }
    var i = first
    while i < end, profile.ident[Int(t[i])] != 0 || t[i] == 0x2E { i &+= 1 }
    var equalsAt = i
    while equalsAt < end, t[equalsAt] == 0x20 { equalsAt &+= 1 }
    guard i > first, equalsAt < end, t[equalsAt] == 0x3D else { return }
    add(name: Token(.identifier, first, i), kind: .key, local: false, start: first, parent: levels.last?.symbol ?? -1)
  }
}

/// A file's name hashes as a small Bloom filter: whether it may hold a name, for finding references without
/// positions in memory.
public struct NameFilter: Sendable {
  var words: [UInt64] = []

  public init() {}

  /// Sized from the token count; 2 probes.
  public init(text t: UnsafePointer<UInt8>, tokens: UnsafeBufferPointer<Token>) {
    var size = 1
    let identifiers = tokens.count
    while size &* 64 < max(64, identifiers) { size &*= 2 }
    var filter = [UInt64](repeating: 0, count: size)
    let mask = UInt64(size &* 64 &- 1)
    filter.withUnsafeMutableBufferPointer { words in
      for token in tokens {
        switch token.kind {
        case .identifier, .declarationKeyword, .keyword:
          let hash = hashName(t + token.start, token.length)
          let a = hash & mask
          let b = (hash >> 32) & mask
          words[Int(a >> 6)] |= 1 << (a & 63)
          words[Int(b >> 6)] |= 1 << (b & 63)
        default: break
        }
      }
    }
    words = filter
  }

  @inline(__always) public func mayContain(hash: UInt64) -> Bool {
    guard !words.isEmpty else { return false }
    let mask = UInt64(words.count &* 64 &- 1)
    let a = hash & mask
    let b = (hash >> 32) & mask
    return words[Int(a >> 6)] & (1 << (a & 63)) != 0 && words[Int(b >> 6)] & (1 << (b & 63)) != 0
  }
}

/// A name's hash. Reads words past the end of the name, so the name must be inside a padded text.
@inline(__always) public func hashName(_ t: UnsafePointer<UInt8>, _ length: Int) -> UInt64 {
  let raw = UnsafeRawPointer(t)
  var hash = UInt64(truncatingIfNeeded: length) &* 0x9E37_79B9_7F4A_7C15
  var i = 0
  while i &+ 8 <= length {
    hash = (hash ^ raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)) &* 0xFF51_AFD7_ED55_8CCD
    hash ^= hash >> 32
    i &+= 8
  }
  if i < length {
    let tail = raw.loadUnaligned(fromByteOffset: i, as: UInt64.self) & (~UInt64(0) >> UInt64((8 &- (length &- i)) &* 8))
    hash = (hash ^ tail) &* 0xFF51_AFD7_ED55_8CCD
    hash ^= hash >> 32
  }
  return hash
}

/// A name's hash from a string, padded here.
public func hashName(_ name: String) -> UInt64 {
  var bytes = Array(name.utf8)
  let length = bytes.count
  bytes.append(contentsOf: repeatElement(0, count: 16))
  return bytes.withUnsafeBufferPointer { hashName($0.baseAddress!, length) }
}
