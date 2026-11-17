import CodeModel
import CodeScan
import Foundation

/// Reads a file's layout stream (`HaskellBlocks`) whole: the module's header, imports and declarations, and every
/// name's meaning as far as the file alone tells it. Forgiving: what it can't read it steps over, so code being typed
/// keeps its names. Locals are scoped as Haskell scopes them:
///
/// - an equation's argument patterns and its `where` bindings over its guards and right-hand sides, `where` and `let`
///   groups recursive, a function's clauses one binding;
/// - `do` binds from the next statement, `let` statements to the block's end, `case` alternatives, lambdas, guards
///   (pattern guards left to right), list comprehensions' qualifiers before the expression they're written after;
/// - record patterns' puns and `C{..}` (whose names the model finds through the constructor's fields);
/// - type variables in a signature bound at their first occurrence, by `forall`, or by the head of a `data`, `class`
///   or `instance` declaration; a signature's `forall` over its function's equations (ScopedTypeVariables).
struct HaskellParser {
  let unit: Unit
  let file = HaskellFile()
  let s: [Int32]
  var match: [Int32]
  let count: Int
  let tokenCount: Int
  let recordDot: Bool
  private var values: [(name: Name, def: Int32)] = []
  private var types: [(name: Name, def: Int32)] = []
  private var scoped: [Name: [(name: Name, def: Int32)]] = [:]
  private var collecting: [Int]?

  static let soft: Set<Name> = Set(
    ["as", "hiding", "qualified", "family", "role", "stock", "anyclass", "via", "static", "pattern", "otherwise", "forall"].map { name($0) })
  static let forallName = name("forall")

  enum Group {
    case top, local
    case classBody(Int32)
    case instanceBody(Int32)
  }

  init(unit: Unit, extensions: Set<String>) {
    self.unit = unit
    s = HaskellBlocks.stream(unit)
    count = s.count
    tokenCount = unit.tokens.count
    recordDot = extensions.contains("OverloadedRecordDot")
    file.extensions = extensions
    // Brackets and blocks matched both ways, what's left open ending at the stream's end.
    var match = [Int32](repeating: -1, count: s.count)
    var stack: [(position: Int, kind: UInt8)] = []
    for p in s.indices {
      let c = s[p]
      var opens: UInt8 = 0
      var closes: UInt8 = 0
      if c == HaskellBlocks.open {
        opens = 4
      } else if c == HaskellBlocks.close {
        closes = 4
      } else if c >= 0 {
        let token = unit.tokens[Int(c)]
        let byte = unit.source.text[token.start]
        if token.kind == .open { opens = byte == 0x28 ? 1 : byte == 0x5B ? 2 : 3 }
        if token.kind == .close { closes = byte == 0x29 ? 1 : byte == 0x5D ? 2 : 3 }
      }
      if opens != 0 {
        stack.append((p, opens))
      } else if closes != 0 {
        guard let at = stack.lastIndex(where: { $0.kind == closes }) else { continue }
        // A virtual close never closes past a real bracket, and a real one closes the blocks left open inside it.
        if closes == 4, stack[at...].contains(where: { $0.kind != 4 }) { continue }
        for inner in stack[(at + 1)...] { match[inner.position] = Int32(p) }
        match[stack[at].position] = Int32(p)
        match[p] = Int32(stack[at].position)
        stack.removeSubrange(at...)
      }
    }
    for left in stack { match[left.position] = Int32(s.count) }
    self.match = match
  }

  // MARK: Tokens

  /// The token at a stream position, -1 for a virtual one.
  @inline(__always) func t(_ p: Int) -> Int { p >= 0 && p < count && s[p] >= 0 ? Int(s[p]) : -1 }

  /// The first real token at or after a position: where a range starts or ends in tokens.
  func tokenAt(_ p: Int) -> Int32 {
    var q = p
    while q < count, s[q] < 0 { q += 1 }
    return q < count ? s[q] : Int32(tokenCount)
  }

  func isWord(_ p: Int, _ text: StaticString) -> Bool {
    let i = t(p)
    guard i >= 0 else { return false }
    let kind = unit.tokens[i].kind
    return (kind == .keyword || kind == .declarationKeyword || kind == .identifier) && unit.isToken(i, text)
  }

  func isSym(_ p: Int, _ text: StaticString) -> Bool {
    let i = t(p)
    return i >= 0 && unit.tokens[i].kind == .punctuation && unit.isToken(i, text)
  }

  func byte(_ i: Int) -> UInt8 { unit.source.text[unit.tokens[i].start] }

  /// A variable's name (lowercase or `_`, or a word Haskell reserves only in places).
  func isVar(_ p: Int) -> Bool {
    let i = t(p)
    guard i >= 0 else { return false }
    switch unit.tokens[i].kind {
    case .identifier:
      let b = byte(i)
      return !(b >= 0x41 && b <= 0x5A) && !(unit.tokens[i].length == 1 && b == 0x5F)
    case .keyword, .declarationKeyword:
      return Self.soft.contains(unit.hash(i))
    default:
      return false
    }
  }

  func isCon(_ p: Int) -> Bool {
    let i = t(p)
    guard i >= 0, unit.tokens[i].kind == .identifier else { return false }
    let b = byte(i)
    return b >= 0x41 && b <= 0x5A
  }

  /// An operator that names something: not one Haskell reserves (`=`, `->`, `::` …).
  func isOperator(_ p: Int) -> Bool {
    let i = t(p)
    guard i >= 0, unit.tokens[i].kind == .punctuation else { return false }
    let token = unit.tokens[i]
    let b = byte(i)
    if b == 0x2C || b == 0x3B || b == 0x60 || b == 0x27 { return false }
    if token.length == 1 { return !(b == 0x3D || b == 0x5C || b == 0x7C || b == 0x40 || b == 0x7E || b == 0x3A) }
    if token.length == 2 {
      for reserved: StaticString in ["::", "->", "<-", "=>", ".."] where unit.isToken(i, reserved) { return false }
    }
    return true
  }

  /// `:+:`: a constructor operator.
  func isConOperator(_ p: Int) -> Bool { isOperator(p) && byte(t(p)) == 0x3A }

  func isOpen(_ p: Int) -> Bool {
    guard p < count else { return false }
    if s[p] == HaskellBlocks.open { return true }
    let i = t(p)
    return i >= 0 && unit.tokens[i].kind == .open
  }

  func isOpen(_ p: Int, _ b: UInt8) -> Bool {
    let i = t(p)
    return i >= 0 && unit.tokens[i].kind == .open && byte(i) == b
  }

  /// A block at `p`: a virtual open or an explicit `{` right after a layout keyword.
  func isBlock(_ p: Int) -> Bool { p < count && (s[p] == HaskellBlocks.open || isOpen(p, 0x7B)) }

  /// The close of an open at `p`, at most `limit`.
  func closeOf(_ p: Int, _ limit: Int) -> Int {
    let m = Int(match[p])
    return m > p ? min(m, limit) : limit
  }

  @inline(__always) func touching(_ p: Int, _ q: Int) -> Bool {
    let a = t(p)
    let b = t(q)
    guard a >= 0, b >= 0 else { return false }
    return unit.tokens[a].end == unit.tokens[b].start
  }

  /// The next position at the same level.
  func step(_ p: Int, _ limit: Int) -> Int { isOpen(p) ? closeOf(p, limit) + 1 : p + 1 }

  /// The first position at the top level of `[a, b)` that `test` takes, or nil.
  func find(_ a: Int, _ b: Int, _ test: (Int) -> Bool) -> Int? {
    var p = a
    while p < b {
      if test(p) { return p }
      p = step(p, b)
    }
    return nil
  }

  func findSym(_ a: Int, _ b: Int, _ text: StaticString) -> Int? { find(a, b) { isSym($0, text) } }

  func findWord(_ a: Int, _ b: Int, _ text: StaticString) -> Int? {
    find(a, b) {
      let i = t($0)
      return i >= 0 && (unit.tokens[i].kind == .keyword || unit.tokens[i].kind == .declarationKeyword) && unit.isToken(i, text)
    }
  }

  /// `[a, b)` split at its top-level positions that `test` takes.
  func split(_ a: Int, _ b: Int, _ test: (Int) -> Bool) -> [(Int, Int)] {
    var parts: [(Int, Int)] = []
    var start = a
    var p = a
    while p < b {
      if test(p) {
        parts.append((start, p))
        start = p + 1
        p += 1
        continue
      }
      p = step(p, b)
    }
    parts.append((start, b))
    return parts
  }

  func commas(_ a: Int, _ b: Int) -> [(Int, Int)] { split(a, b) { isSym($0, ",") }.filter { $0.0 < $0.1 } }

  /// A block's items.
  func items(_ open: Int) -> [(Int, Int)] {
    let close = closeOf(open, count)
    return split(open + 1, close) { s[$0] == HaskellBlocks.semicolon || isSym($0, ";") }.filter { $0.0 < $0.1 }
  }

  // MARK: Recording

  mutating func set(_ p: Int, _ use: HsUse) {
    let i = t(p)
    guard i >= 0 else { return }
    file.uses[Int32(i)] = use
  }

  mutating func pushValue(_ p: Int, kind: HsLocal.Kind = .binding, from: Int32) {
    let i = t(p)
    guard i >= 0 else { return }
    values.append((unit.hash(i), Int32(i)))
    file.uses[Int32(i)] = .local(Int32(i))
    file.locals[Int32(i)] = HsLocal(kind: kind, from: from, to: Int32(tokenCount))
  }

  mutating func pushType(_ p: Int, from: Int32) {
    let i = t(p)
    guard i >= 0 else { return }
    types.append((unit.hash(i), Int32(i)))
    file.uses[Int32(i)] = .local(Int32(i))
    file.locals[Int32(i)] = HsLocal(kind: .typeVariable, from: from, to: Int32(tokenCount))
  }

  /// Ends the values pushed since `mark` at `p`.
  mutating func popValues(_ mark: Int, at p: Int) {
    let end = tokenAt(p)
    for entry in values[mark...] where entry.def >= 0 { file.locals[entry.def]?.to = end }
    values.removeSubrange(mark...)
  }

  mutating func popTypes(_ mark: Int, at p: Int) {
    let end = tokenAt(p)
    for entry in types[mark...] where entry.def >= 0 { file.locals[entry.def]?.to = end }
    types.removeSubrange(mark...)
  }

  /// A variable or operator used as a value: the innermost local of its name, else free.
  mutating func useValue(_ p: Int) {
    let i = t(p)
    guard i >= 0 else { return }
    let h = unit.hash(i)
    var shadows: [Int32] = []
    var use = HsUse.free(.value)
    for entry in values.reversed() {
      if entry.def <= -10 {
        shadows.append(-entry.def - 10)
        continue
      }
      if entry.name == h {
        use = .local(entry.def)
        break
      }
    }
    file.uses[Int32(i)] = use
    if !shadows.isEmpty { file.wildcardShadow[Int32(i)] = shadows }
  }

  func lookupType(_ h: Name) -> Int32? {
    for entry in types.reversed() where entry.name == h { return entry.def }
    return nil
  }

  /// `A.B.x` from a capitalized word at `p`: the last part's position, the qualifier's hash, its text.
  func qualified(_ p: Int) -> (last: Int, qualifier: Name, text: String)? {
    guard isCon(p), isSym(p + 1, "."), touching(p, p + 1), touching(p + 1, p + 2) else { return nil }
    var parts = [unit.string(t(p))]
    var q = p + 2
    while isCon(q), isSym(q + 1, "."), touching(q, q + 1), touching(q + 1, q + 2), t(q + 2) >= 0 {
      parts.append(unit.string(t(q)))
      q += 2
    }
    guard isVar(q) || isCon(q) || isOperator(q) else { return nil }
    let text = parts.joined(separator: ".")
    return (q, name(text), text)
  }

  /// Marks a qualified name's parts, the last one in `namespace`; returns the position after it.
  mutating func useQualified(_ p: Int, _ found: (last: Int, qualifier: Name, text: String), _ namespace: HsNamespace) -> Int {
    file.texts[found.qualifier] = found.text
    var q = p
    while q < found.last {
      if isCon(q) { set(q, .qualifier(found.qualifier)) }
      q += 1
    }
    set(found.last, .qualified(found.qualifier, namespace))
    return found.last + 1
  }

  /// A module's name from `p`: its words and text.
  func moduleName(_ p: Int, _ limit: Int) -> (end: Int, text: String)? {
    guard isCon(p) else { return nil }
    var parts = [unit.string(t(p))]
    var q = p + 1
    while q + 1 < limit, isSym(q, "."), isCon(q + 1), touching(q - 1, q), touching(q, q + 1) {
      parts.append(unit.string(t(q + 1)))
      q += 2
    }
    return (q, parts.joined(separator: "."))
  }

  mutating func markModule(_ p: Int, _ end: Int, _ text: String) {
    let h = name(text)
    file.texts[h] = text
    for q in p..<end where isCon(q) { set(q, .module(h)) }
  }

  // MARK: Declarations

  mutating func addDecl(_ kind: DeclKind, _ info: HsDeclInfo.Kind, at p: Int, first: Int, end: Int, parent: Int32 = -1, namespace: HsNamespace) -> Int32 {
    let i = t(p)
    guard i >= 0 else { return -1 }
    var decl = Decl(kind: kind, name: unit.hash(i), nameToken: Int32(i), first: tokenAt(first), parent: parent)
    decl.end = max(decl.first + 1, tokenAt(end))
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    file.info.append(HsDeclInfo(kind: info, statement: decl.first))
    file.uses.removeValue(forKey: Int32(i))
    if parent < 0 || info == .method || info == .constructor || info == .field || info == .associatedType {
      if namespace == .value { file.topValues[decl.name, default: []].append(index) } else { file.topTypes[decl.name, default: []].append(index) }
    }
    return index
  }

  mutating func setType(_ decl: Int32, _ a: Int, _ b: Int) {
    guard decl >= 0 else { return }
    file.info[Int(decl)].typeStart = tokenAt(a)
    file.info[Int(decl)].typeEnd = tokenAt(b)
  }

  // MARK: Module

  mutating func parseModule() {
    guard count > 0 else { return }
    var body = 0
    if isWord(0, "module") {
      file.hasHeader = true
      if let found = moduleName(1, count) {
        file.moduleName = found.text
        file.moduleToken = Int32(t(1))
        markModule(1, found.end, found.text)
        var p = found.end
        if isOpen(p, 0x28) {
          let close = closeOf(p, count)
          file.exports = itemList(p, close, importIndex: -1)
          p = close + 1
        }
        guard let whereAt = findWord(p, count, "where"), isBlock(whereAt + 1) else { return }
        body = whereAt + 1
      } else {
        return
      }
    }
    guard isBlock(body) else { return }
    group(body, .top)
  }

  /// An import or export list's items between `(` and its close.
  mutating func itemList(_ open: Int, _ close: Int, importIndex: Int32) -> [HsItem] {
    var result: [HsItem] = []
    for (a, b) in commas(open + 1, close) {
      var p = a
      var namespace = HsNamespace.value
      if isWord(p, "module"), let found = moduleName(p + 1, b) {
        markModule(p + 1, found.end, found.text)
        result.append(HsItem(name: name(found.text), token: Int32(t(p + 1)), namespace: .value, module: found.text))
        continue
      }
      if isWord(p, "type") {
        namespace = .type
        p += 1
      } else if isWord(p, "pattern") {
        p += 1
      }
      var at = p
      var qualifier: Name = 0
      if isOpen(p, 0x28), p + 2 <= b, isOperator(p + 1) {
        at = p + 1
        if isConOperator(at) { namespace = .type }
      } else if let found = qualified(p), importIndex < 0 {
        at = found.last
        qualifier = found.qualifier
        if isCon(at) { namespace = .type }
        if isOpen(at, 0x28) { at = p }
        _ = useQualified(p, found, namespace)
      } else if isCon(p) {
        namespace = isWord(a, "pattern") ? .value : .type
      } else if !isVar(p) {
        continue
      }
      guard t(at) >= 0 else { continue }
      var item = HsItem(name: unit.hash(t(at)), token: Int32(t(at)), namespace: namespace, qualifier: qualifier)
      if qualifier == 0 {
        set(at, importIndex >= 0 ? .imported(importIndex, namespace) : .free(namespace))
      }
      let afterName = isOpen(p, 0x28) && at == p + 1 ? closeOf(p, b) + 1 : at + 1
      if namespace == .type, isOpen(afterName, 0x28) {
        let subClose = closeOf(afterName, b)
        if findSym(afterName + 1, subClose, "..") != nil {
          item.subs = .all
        } else {
          var subs: [(name: Name, token: Int32)] = []
          for (x, _) in commas(afterName + 1, subClose) {
            var q = x
            if isWord(q, "type") || isWord(q, "pattern") { q += 1 }
            if isOpen(q, 0x28), isOperator(q + 1) { q += 1 }
            guard isVar(q) || isCon(q) || isOperator(q) else { continue }
            subs.append((unit.hash(t(q)), Int32(t(q))))
            set(q, importIndex >= 0 ? .importedSub(importIndex, item.token) : .exportedSub(item.token))
          }
          item.subs = .some(subs)
        }
      }
      result.append(item)
    }
    return result
  }

  mutating func importDecl(_ a: Int, _ b: Int) {
    var p = a + 1
    var item = HsImport(module: "", moduleToken: -1, line: tokenAt(a))
    while p < b {
      if isWord(p, "qualified") {
        item.isQualified = true
        p += 1
      } else if isWord(p, "safe") {
        p += 1
      } else if let i = Optional(t(p)), i >= 0, unit.tokens[i].kind == .string {
        p += 1
      } else {
        break
      }
    }
    guard let found = moduleName(p, b) else { return }
    item.module = found.text
    item.moduleToken = Int32(t(p))
    markModule(p, found.end, found.text)
    p = found.end
    let index = Int32(file.imports.count)
    while p < b {
      if isWord(p, "qualified") {
        item.isQualified = true
        p += 1
      } else if isWord(p, "as"), let alias = moduleName(p + 1, b) {
        item.alias = alias.text
        // The alias's words name the module.
        let h = name(found.text)
        for q in (p + 1)..<alias.end where isCon(q) { set(q, .module(h)) }
        p = alias.end
      } else if isWord(p, "hiding") {
        item.isHiding = true
        p += 1
      } else if isOpen(p, 0x28) {
        let close = closeOf(p, b)
        item.items = itemList(p, close, importIndex: index)
        p = close + 1
      } else {
        p += 1
      }
    }
    file.imports.append(item)
  }

  // MARK: Groups

  /// What an equation's left side defines.
  enum Lhs {
    /// `f p1 p2`, `(op) p1 p2`, `p1 op p2`, ``p1 `f` p2``: the name's position and the argument patterns' ranges.
    case function(Int, [(Int, Int)])
    case pattern
    case none
  }

  /// A prefix `!` or `~` (a bang or lazy pattern), not an operator.
  func isPrefixMark(_ p: Int) -> Bool {
    guard isSym(p, "!") || isSym(p, "~") || isSym(p, "-") else { return false }
    let i = t(p)
    return !touching(p - 1, p) && touching(p, p + 1) || i > 0 && isOpen(p - 1)
  }

  func lhs(_ a: Int, _ r: Int) -> Lhs {
    guard a < r else { return .none }
    // An operator or backticked name at the top level defines it.
    var p = a
    while p < r {
      if isOperator(p), !isConOperator(p), !isPrefixMark(p), !isSym(p, "@"), p > a {
        return .function(p, [(a, p), (p + 1, r)])
      }
      if isSym(p, "`"), isVar(p + 1), isSym(p + 2, "`"), p > a { return .function(p + 1, [(a, p), (p + 3, r)]) }
      p = step(p, r)
    }
    if isOpen(a, 0x28), isOperator(a + 1), closeOf(a, r) == a + 2 { return .function(a + 1, [(a + 3, r)]) }
    if isOpen(a, 0x28), closeOf(a, r) < r, let inner = find(a + 1, closeOf(a, r), { isOperator($0) && !isConOperator($0) || isSym($0, "`") }) {
      // `(x <+> y) z = …`: the operator, every pattern around it.
      let at = isSym(inner, "`") ? inner + 1 : inner
      return .function(at, [(a + 1, inner), (isSym(inner, "`") ? inner + 3 : inner + 1, closeOf(a, r)), (closeOf(a, r) + 1, r)])
    }
    if isVar(a), !(isSym(a + 1, "@") && touching(a, a + 1)) { return .function(a, [(a + 1, r)]) }
    return .pattern
  }

  /// A signature's names before its `::`, or nil when the item isn't one.
  func signatureNames(_ a: Int, _ colon: Int) -> [Int]? {
    var names: [Int] = []
    var p = a
    while p < colon {
      if isSym(p, ",") {
        p += 1
      } else if isOpen(p, 0x28), isOperator(p + 1), closeOf(p, colon) == p + 2 {
        names.append(p + 1)
        p += 3
      } else if isVar(p) || isCon(p) {
        names.append(p)
        p += 1
      } else {
        return nil
      }
    }
    return names.isEmpty ? nil : names
  }

  enum ItemShape {
    case signature(Int, [Int])
    case equation(Lhs, Int, Int?)
    case other
  }

  /// Signature, equation (with where its right side starts, and its `where`), or another declaration.
  func shape(_ a: Int, _ b: Int) -> ItemShape {
    if let i = Optional(t(a)), i >= 0, unit.tokens[i].kind == .keyword || unit.tokens[i].kind == .declarationKeyword, !isVar(a) {
      return .other
    }
    if isWord(a, "pattern"), isCon(a + 1) || isOpen(a + 1, 0x28) { return .other }
    let whereAt = findWord(a, b, "where")
    let end = whereAt ?? b
    let rhs = find(a, end) { isSym($0, "=") || isSym($0, "|") }
    if let colon = findSym(a, rhs ?? end, "::"), let names = signatureNames(a, colon) { return .signature(colon, names) }
    guard let rhs else { return .other }
    return .equation(lhs(a, rhs), rhs, whereAt)
  }

  /// A declaration group: its binders first (recursive), then signatures, then bodies.
  /// `from`: where its bindings are seen from, when that's before the block (a `where` serves its equation's right side).
  mutating func group(_ open: Int, _ kind: Group, from start: Int32? = nil) {
    let list = items(open)
    var shapes: [ItemShape] = []
    var binders: [Name: Int32] = [:]
    var decls: [Name: Int32] = [:]
    let from = start ?? tokenAt(open)
    var isTop = false
    if case .top = kind { isTop = true }
    for (a, b) in list {
      let itemShape = shape(a, b)
      shapes.append(itemShape)
      guard case .equation(let lhs, let rhs, _) = itemShape else { continue }
      switch kind {
      case .top, .local:
        var positions: [Int] = []
        if case .function(let at, _) = lhs {
          positions = [at]
        } else if case .pattern = lhs {
          collecting = []
          pattern(a, rhs, mode: .mark)
          positions = collecting ?? []
          collecting = nil
        }
        for at in positions {
          let h = unit.hash(t(at))
          guard binders[h] == nil else { continue }
          binders[h] = Int32(t(at))
          if isTop {
            var hasArguments = false
            if case .function(_, let args) = lhs { hasArguments = args.contains { $0.0 < $0.1 } }
            decls[h] = addDecl(hasArguments ? .function : .variable, hasArguments ? .function : .variable, at: at, first: a, end: b, namespace: .value)
          } else {
            pushValue(at, from: from)
          }
        }
      case .classBody, .instanceBody:
        break
      }
    }
    // Signatures, and their `forall`s for the equations.
    for (index, (a, b)) in list.enumerated() {
      guard case .signature(let colon, let names) = shapes[index] else { continue }
      let typeMark = types.count
      var bound: [(name: Name, def: Int32)] = []
      if isWord(colon + 1, "forall") {
        var p = colon + 2
        while p < b, !isSym(p, ".") {
          if isVar(p) {
            pushType(p, from: tokenAt(colon))
            bound.append(types[types.count - 1])
          } else if isOpen(p, 0x28), isVar(p + 1) {
            pushType(p + 1, from: tokenAt(colon))
            bound.append(types[types.count - 1])
            type(p + 2, closeOf(p, b), bind: false)
            p = closeOf(p, b)
          }
          p += 1
        }
        type(p + 1, b, bind: true)
      } else {
        type(colon + 1, b, bind: true)
      }
      popTypes(typeMark, at: b)
      for at in names {
        let h = unit.hash(t(at))
        if !bound.isEmpty { scoped[h] = bound }
        switch kind {
        case .top:
          if let decl = decls[h] {
            set(at, .free(.value))
            setType(decl, colon + 1, b)
            file.info[Int(decl)].statement = min(file.info[Int(decl)].statement, tokenAt(a))
          } else if binders[h] == nil {
            // No equation here (a boot file's, or one being written): the signature declares it.
            let decl = addDecl(.function, .function, at: at, first: a, end: b, namespace: .value)
            setType(decl, colon + 1, b)
            decls[h] = decl
            binders[h] = Int32(t(at))
          } else {
            set(at, .free(.value))
          }
        case .local:
          useValue(at)
          if case .local(let def) = file.uses[Int32(t(at))] ?? .field { file.localSignatures[def] = (tokenAt(colon + 1), tokenAt(b)) }
        case .classBody(let classDecl):
          let decl = addDecl(.function, .method, at: at, first: a, end: b, parent: classDecl, namespace: .value)
          setType(decl, colon + 1, b)
        case .instanceBody(let instance):
          set(at, .method(instance))
        }
      }
    }
    for (index, (a, b)) in list.enumerated() {
      switch shapes[index] {
      case .signature:
        break
      case .equation(let lhs, let rhs, let whereAt):
        equation(a, b, lhs, rhs, whereAt, kind, binders)
      case .other:
        other(a, b, kind)
      }
    }
  }

  /// A declaration that isn't a signature or an equation.
  mutating func other(_ a: Int, _ b: Int, _ kind: Group) {
    if isWord(a, "import") {
      importDecl(a, b)
    } else if isWord(a, "data") || isWord(a, "newtype") {
      var inClass: Int32 = -1
      var inInstance = false
      if case .classBody(let decl) = kind { inClass = decl }
      if case .instanceBody = kind { inInstance = true }
      dataDecl(a, b, inClass: inClass, inInstance: inInstance)
    } else if isWord(a, "type") {
      var inClass: Int32 = -1
      var inInstance = false
      if case .classBody(let decl) = kind { inClass = decl }
      if case .instanceBody = kind { inInstance = true }
      typeDecl(a, b, inClass: inClass, inInstance: inInstance)
    } else if isWord(a, "class") {
      classDecl(a, b)
    } else if isWord(a, "instance") {
      instanceDecl(a, b)
    } else if isWord(a, "deriving") {
      let mark = types.count
      type(a + 1, b, bind: true)
      popTypes(mark, at: b)
    } else if isWord(a, "foreign") {
      guard let colon = findSym(a, b, "::") else { return }
      let at = colon - 1
      if isWord(a + 1, "import"), isVar(at) {
        let decl = addDecl(.function, .foreign, at: at, first: a, end: b, namespace: .value)
        setType(decl, colon + 1, b)
      } else if isVar(at) {
        useValue(at)
      }
      let mark = types.count
      type(colon + 1, b, bind: true)
      popTypes(mark, at: b)
    } else if isWord(a, "pattern") {
      patternSynonym(a, b)
    } else if isWord(a, "infix") || isWord(a, "infixl") || isWord(a, "infixr") {
      var p = a + 1
      while p < b {
        if isOperator(p) || isVar(p) { fixityName(p, kind) } else if isCon(p) || isConOperator(p) { set(p, .free(.value)) }
        p += 1
      }
    } else if isWord(a, "default") {
      if case .classBody = kind, let colon = findSym(a, b, "::") {
        // `default m :: T`: the method's default signature.
        if isVar(a + 1) { set(a + 1, .free(.value)) }
        let mark = types.count
        type(colon + 1, b, bind: true)
        popTypes(mark, at: b)
      } else {
        type(a + 1, b, bind: false)
      }
    } else {
      // A top-level splice (`makeLenses ''T`) or an expression being typed.
      exp(a, b)
    }
  }

  mutating func fixityName(_ p: Int, _ kind: Group) {
    switch kind {
    case .top, .classBody: set(p, .free(.value))
    case .local: useValue(p)
    case .instanceBody(let instance): set(p, .method(instance))
    }
  }

  mutating func equation(_ a: Int, _ b: Int, _ lhs: Lhs, _ rhs: Int, _ whereAt: Int?, _ kind: Group, _ binders: [Name: Int32]) {
    let valueMark = values.count
    let typeMark = types.count
    switch lhs {
    case .function(let at, let args):
      let i = t(at)
      let h = unit.hash(i)
      switch kind {
      case .top:
        if binders[h] != Int32(i) { set(at, .free(.value)) }
      case .local:
        if binders[h] != Int32(i) { useValue(at) }
      case .classBody:
        set(at, .free(.value))
      case .instanceBody(let instance):
        set(at, .method(instance))
      }
      for entry in scoped[h] ?? [] { types.append(entry) }
      for (x, y) in args where x < y { pattern(x, y, mode: .bind, kind: .parameter) }
    case .pattern:
      pattern(a, rhs, mode: .mark)
    case .none:
      break
    }
    let end = whereAt ?? b
    if let whereAt, isBlock(whereAt + 1) { group(whereAt + 1, .local, from: tokenAt(a)) }
    rightSide(rhs, end, arrow: false)
    popValues(valueMark, at: b)
    // The scoped type variables were the signature's own: they stay where it put them.
    types.removeSubrange(typeMark...)
  }

  /// `= e` or guards `| g = e`, `-> e` or `| g -> e` in alternatives.
  mutating func rightSide(_ rhs: Int, _ end: Int, arrow: Bool) {
    if isSym(rhs, "|") {
      for (g, h) in split(rhs + 1, end, { isSym($0, "|") }) where g < h {
        let separator = find(g, h) { arrow ? isSym($0, "->") : isSym($0, "=") } ?? h
        let mark = values.count
        quals(g, separator)
        if separator < h { exp(separator + 1, h) }
        popValues(mark, at: h)
      }
    } else {
      exp(rhs + 1, end)
    }
  }

  /// Comma-separated qualifiers or guards: `p <- e` binds `p` for what follows, `let` its group, the rest are
  /// expressions.
  mutating func quals(_ a: Int, _ b: Int, from start: Int32? = nil) {
    for (x, y) in commas(a, b) {
      if isWord(x, "let"), isBlock(x + 1) {
        let close = closeOf(x + 1, y)
        group(x + 1, .local)
        if isWord(close + 1, "in") { exp(close + 2, y) }
      } else if let arrow = findSym(x, y, "<-") {
        exp(arrow + 1, y)
        pattern(x, arrow, mode: .bind, from: start ?? tokenAt(y))
      } else {
        exp(x, y)
      }
    }
  }

  mutating func statements(_ open: Int) {
    let mark = values.count
    let close = closeOf(open, count)
    for (a, b) in items(open) {
      if isWord(a, "let"), isBlock(a + 1) {
        let blockClose = closeOf(a + 1, b)
        if isWord(blockClose + 1, "in") {
          let inner = values.count
          group(a + 1, .local)
          exp(blockClose + 2, b)
          popValues(inner, at: b)
        } else {
          group(a + 1, .local)
        }
      } else if isWord(a, "rec"), isBlock(a + 1) {
        for (x, y) in items(a + 1) { statement(x, y) }
      } else {
        statement(a, b)
      }
    }
    popValues(mark, at: close)
  }

  mutating func statement(_ a: Int, _ b: Int) {
    if let arrow = findSym(a, b, "<-") {
      exp(arrow + 1, b)
      pattern(a, arrow, mode: .bind, from: tokenAt(b))
    } else {
      exp(a, b)
    }
  }

  /// `case` alternatives (and `\case`'s, `\cases`' with several patterns).
  mutating func alternatives(_ open: Int) {
    for (a, b) in items(open) {
      let whereAt = findWord(a, b, "where")
      let end = whereAt ?? b
      guard let rhs = find(a, end, { isSym($0, "->") || isSym($0, "|") }) else {
        exp(a, end)
        continue
      }
      let mark = values.count
      pattern(a, rhs, mode: .bind)
      if let whereAt, isBlock(whereAt + 1) { group(whereAt + 1, .local, from: tokenAt(a)) }
      rightSide(rhs, end, arrow: true)
      popValues(mark, at: b)
    }
  }

  // MARK: Expressions

  mutating func exp(_ a: Int, _ b: Int) {
    var p = a
    while p < b {
      let c = s[p]
      if c < 0 {
        p += 1
        continue
      }
      let i = Int(c)
      let token = unit.tokens[i]
      switch token.kind {
      case .open:
        let close = closeOf(p, b)
        switch byte(i) {
        case 0x28:
          for (x, y) in commas(p + 1, close) { exp(x, y) }
        case 0x5B:
          bracket(p, close)
        default:
          recordBraces(p, close, inPattern: false)
        }
        p = close + 1
        continue
      case .identifier:
        if isCon(p) {
          if let found = qualified(p) {
            p = useQualified(p, found, .value)
            continue
          }
          set(p, .free(.value))
        } else if isVar(p) {
          useValue(p)
        }
      case .keyword, .declarationKeyword:
        if isVar(p) {
          useValue(p)
        } else if isWord(p, "let"), isBlock(p + 1) {
          let close = closeOf(p + 1, b)
          let mark = values.count
          group(p + 1, .local)
          if isWord(close + 1, "in") {
            exp(close + 2, b)
            popValues(mark, at: b)
            return
          }
          popValues(mark, at: close)
          p = close + 1
          continue
        } else if isWord(p, "case") {
          if let of = findWord(p + 1, b, "of") {
            exp(p + 1, of)
            if isBlock(of + 1) {
              alternatives(of + 1)
              p = closeOf(of + 1, b) + 1
            } else {
              p = of + 1
            }
            continue
          }
        } else if isWord(p, "do") || isWord(p, "mdo"), isBlock(p + 1) {
          statements(p + 1)
          p = closeOf(p + 1, b) + 1
          continue
        }
      case .punctuation:
        if isSym(p, "\\") {
          if (isWord(p + 1, "case") || isWord(p + 1, "cases")), isBlock(p + 2) {
            alternatives(p + 2)
            p = closeOf(p + 2, b) + 1
            continue
          }
          guard let arrow = findSym(p + 1, b, "->") else { break }
          let mark = values.count
          pattern(p + 1, arrow, mode: .bind, kind: .parameter)
          exp(arrow + 1, b)
          popValues(mark, at: b)
          return
        }
        if isSym(p, "::") {
          let mark = types.count
          type(p + 1, b, bind: true)
          popTypes(mark, at: b)
          return
        }
        if isSym(p, "@"), !touching(p - 1, p), touching(p, p + 1) {
          let end = isOpen(p + 1) ? closeOf(p + 1, b) + 1 : p + 2
          type(p + 1, end, bind: false)
          p = end
          continue
        }
        if isSym(p, "'") {
          // Template Haskell's `'name` and `''Type`.
          if isSym(p + 1, "'") {
            if isCon(p + 2) { set(p + 2, .free(.type)) }
            p += 3
          } else {
            if isVar(p + 1) { useValue(p + 1) } else if isCon(p + 1) { set(p + 1, .free(.value)) }
            p += 2
          }
          continue
        }
        if isSym(p, "."), recordDot, isVar(p + 1), touching(p, p + 1), touching(p - 1, p) || isOpen(p - 1, 0x28) {
          // `x.f`, `(.f)`.
          set(p + 1, .recordDot)
          p += 2
          continue
        }
        if isConOperator(p) {
          set(p, .free(.value))
        } else if isOperator(p) {
          useValue(p)
        }
      default:
        break
      }
      p += 1
    }
  }

  /// `[…]`: a list, a range, a comprehension (its qualifiers before its expression), or a quasi-quote (skipped).
  mutating func bracket(_ open: Int, _ close: Int) {
    if isSym(open + 1, "|") && touching(open, open + 1) || (isVar(open + 1) || isCon(open + 1)) && isSym(open + 2, "|") && touching(open, open + 1) && touching(open + 1, open + 2) {
      return
    }
    let bars = split(open + 1, close) { isSym($0, "|") }
    if bars.count == 1 {
      for (x, y) in commas(open + 1, close) { exp(x, y) }
      return
    }
    let mark = values.count
    // Seen from the bracket: the expression written first uses them.
    for (x, y) in bars.dropFirst() { quals(x, y, from: tokenAt(open)) }
    exp(bars[0].0, bars[0].1)
    popValues(mark, at: close)
  }

  /// `C { f = e, g, .. }` and `r { f = e }`; in a pattern `C { f = p, g, .. }` binds `p`'s names, the pun `g` and,
  /// for `..`, the constructor's fields (as a wildcard the model reads).
  mutating func recordBraces(_ open: Int, _ close: Int, inPattern: Bool, mode: PatternMode = .bind, kind: HsLocal.Kind = .binding, from: Int32? = nil) {
    for (x, y) in commas(open + 1, close) {
      if isSym(x, "..") {
        guard inPattern else { continue }
        let con = open - 1
        guard isCon(con) else { continue }
        var qualifier: Name = 0
        // `M.C{..}`: the qualifier from the words before.
        if con >= 2, isSym(con - 1, "."), isCon(con - 2), touching(con - 2, con - 1), touching(con - 1, con) {
          var q = con - 2
          while q >= 2, isSym(q - 1, "."), isCon(q - 2), touching(q - 2, q - 1), touching(q - 1, q) { q -= 2 }
          var parts: [String] = []
          var r = q
          while r < con {
            parts.append(unit.string(t(r)))
            r += 2
          }
          let text = parts.joined(separator: ".")
          qualifier = name(text)
          file.texts[qualifier] = text
        }
        file.wildcards.append((Int32(t(con)), qualifier))
        if case .bind = mode { values.append((0, -Int32(file.wildcards.count - 1) - 10)) }
        continue
      }
      if let equals = findSym(x, y, "=") {
        if let found = qualified(x) {
          _ = useQualified(x, found, .value)
        } else if isVar(x) {
          set(x, .field)
        }
        if inPattern { pattern(equals + 1, y, mode: mode, kind: kind, from: from) } else { exp(equals + 1, y) }
      } else if isVar(x) {
        if inPattern { pattern(x, x + 1, mode: mode, kind: kind, from: from) } else { set(x, .field) }
      } else if let found = qualified(x) {
        _ = useQualified(x, found, .value)
      }
    }
  }

  // MARK: Patterns

  enum PatternMode {
    /// Binds each variable for what follows.
    case bind
    /// The variables were bound before (a group's pattern binding): each is its own declaration.
    case mark
    /// The variables are uses (a pattern synonym's right side).
    case lookup
  }

  mutating func pattern(_ a: Int, _ b: Int, mode: PatternMode, kind: HsLocal.Kind = .binding, from: Int32? = nil) {
    var p = a
    while p < b {
      let c = s[p]
      if c < 0 {
        p += 1
        continue
      }
      let i = Int(c)
      switch unit.tokens[i].kind {
      case .open:
        let close = closeOf(p, b)
        switch byte(i) {
        case 0x28:
          for (x, y) in commas(p + 1, close) {
            // A view pattern: `(f -> p)`.
            if let arrow = findSym(x, y, "->") {
              if collecting == nil { exp(x, arrow) }
              pattern(arrow + 1, y, mode: mode, kind: kind, from: from)
            } else {
              pattern(x, y, mode: mode, kind: kind, from: from)
            }
          }
        case 0x5B:
          for (x, y) in commas(p + 1, close) { pattern(x, y, mode: mode, kind: kind, from: from) }
        default:
          if collecting != nil {
            for (x, y) in commas(p + 1, close) {
              if let equals = findSym(x, y, "=") { pattern(equals + 1, y, mode: mode) } else if isVar(x) { collecting?.append(x) }
            }
          } else {
            recordBraces(p, close, inPattern: true, mode: mode, kind: kind, from: from)
          }
        }
        p = close + 1
        continue
      case .identifier, .keyword, .declarationKeyword:
        if isVar(p) {
          if collecting != nil {
            collecting?.append(p)
          } else {
            switch mode {
            case .bind: pushValue(p, kind: kind, from: from ?? tokenAt(b))
            case .mark: set(p, .local(Int32(i)))
            case .lookup: useValue(p)
            }
          }
        } else if isCon(p), collecting == nil {
          if let found = qualified(p) {
            p = useQualified(p, found, .value)
            continue
          }
          set(p, .free(.value))
        }
      case .punctuation:
        if isSym(p, "::") {
          if collecting == nil {
            type(p + 1, b, bind: true)
          }
          return
        }
        if isConOperator(p), collecting == nil { set(p, .free(.value)) }
      default:
        break
      }
      p += 1
    }
  }

  // MARK: Types

  /// A type: type variables from the scope, else bound here when `bind`; type constructors and classes free.
  mutating func type(_ a: Int, _ b: Int, bind: Bool) {
    var p = a
    while p < b {
      let c = s[p]
      if c < 0 {
        p += 1
        continue
      }
      let i = Int(c)
      switch unit.tokens[i].kind {
      case .open:
        let close = closeOf(p, b)
        type(p + 1, close, bind: bind)
        p = close + 1
        continue
      case .identifier, .keyword, .declarationKeyword:
        if isWord(p, "forall") {
          var q = p + 1
          while q < b, !isSym(q, "."), !isSym(q, "->") {
            if isVar(q) { pushType(q, from: Int32(i)) }
            if isOpen(q, 0x28), isVar(q + 1) {
              pushType(q + 1, from: Int32(i))
              type(q + 2, closeOf(q, b), bind: false)
              q = closeOf(q, b)
            }
            q += 1
          }
          p = q + 1
          continue
        }
        if isVar(p) {
          let h = unit.hash(i)
          if let def = lookupType(h) {
            set(p, .local(def))
          } else if bind {
            pushType(p, from: Int32(i))
          }
        } else if isCon(p) {
          if let found = qualified(p) {
            p = useQualified(p, found, .type)
            continue
          }
          set(p, .free(.type))
        }
      case .punctuation:
        if isSym(p, "'"), isCon(p + 1) {
          // A promoted constructor (DataKinds).
          set(p + 1, .free(.value))
          p += 2
          continue
        }
        if isOperator(p), !isSym(p, "*"), !isSym(p, "!"), !isSym(p, ".") { set(p, .free(.type)) }
      default:
        break
      }
      p += 1
    }
  }

  // MARK: Data, classes, instances

  mutating func dataDecl(_ a: Int, _ b: Int, inClass: Int32, inInstance: Bool) {
    let isNewtype = isWord(a, "newtype")
    var p = a + 1
    let isFamily = isWord(p, "family")
    if isFamily { p += 1 }
    let isInstance = isWord(p, "instance") || inInstance
    if isWord(p, "instance") { p += 1 }
    let equals = findSym(p, b, "=")
    let whereAt = findWord(p, b, "where")
    let deriving = findWord(p, b, "deriving")
    let headEnd = [equals, whereAt, deriving, b].compactMap { $0 }.min()!
    let typeMark = types.count
    let arrow = findSym(p, headEnd, "=>")
    let head = arrow.map { $0 + 1 } ?? p
    var decl: Int32 = -1
    var nameAt = head
    if isOpen(head, 0x28), isOperator(head + 1) { nameAt = head + 1 }
    if !isCon(nameAt), !isOperator(nameAt), let infix = find(head, headEnd, { isConOperator($0) }) { nameAt = infix }
    if isInstance {
      if let found = qualified(nameAt) {
        nameAt = useQualified(nameAt, found, .type) - 1
      } else {
        set(nameAt, .free(.type))
      }
    } else if isCon(nameAt) || isOperator(nameAt) {
      let kind: HsDeclInfo.Kind = isFamily ? .dataFamily : inClass >= 0 ? .associatedType : isNewtype ? .newtype : .data
      decl = addDecl(.structure, kind, at: nameAt, first: a, end: b, parent: inClass, namespace: .type)
    }
    type(head, nameAt, bind: true)
    type(nameAt + 1, headEnd, bind: true)
    if let arrow { type(p, arrow, bind: false) }
    if let equals {
      let end = deriving ?? b
      setType(decl, equals + 1, end)
      constructors(equals + 1, end, parent: decl, first: a)
    } else if let whereAt, isBlock(whereAt + 1) {
      gadt(whereAt + 1, parent: decl)
    }
    if let deriving { type(deriving + 1, b, bind: false) }
    popTypes(typeMark, at: b)
  }

  /// `C1 t | C2 { f :: t } | a :+ b`, each with `forall` and a context.
  mutating func constructors(_ a: Int, _ b: Int, parent: Int32, first: Int) {
    var fieldsByName: [Name: Int32] = [:]
    for (x, y) in split(a, b, { isSym($0, "|") }) where x < y {
      let typeMark = types.count
      var p = x
      if isWord(p, "forall") {
        p += 1
        while p < y, !isSym(p, ".") {
          if isVar(p) { pushType(p, from: tokenAt(x)) }
          p += 1
        }
        p += 1
      }
      if let arrow = findSym(p, y, "=>") {
        type(p, arrow, bind: false)
        p = arrow + 1
      }
      let brace = find(p, y) { isOpen($0, 0x7B) }
      var nameAt = p
      if isOpen(p, 0x28), isOperator(p + 1) { nameAt = p + 1 }
      var infix: Int?
      if brace == nil {
        infix = find(p, y) { isConOperator($0) || isSym($0, "`") && isCon($0 + 1) }
        if let found = infix, isSym(found, "`") { infix = found + 1 }
      }
      if let infix { nameAt = infix }
      let decl = (isCon(nameAt) || isConOperator(nameAt)) ? addDecl(.enumCase, .constructor, at: nameAt, first: x, end: y, parent: parent, namespace: .value) : -1
      if let infix {
        type(p, infix, bind: false)
        type(infix + (isSym(infix + 1, "`") ? 2 : 1), y, bind: false)
      } else if let brace {
        fields(brace, closeOf(brace, y), parent: parent, constructor: decl, byName: &fieldsByName)
      } else {
        let after = nameAt == p + 1 ? closeOf(p, y) + 1 : nameAt + 1
        setType(decl, after, y)
        type(after, y, bind: false)
      }
      popTypes(typeMark, at: y)
    }
  }

  /// Record fields `{ a, b :: T, c :: U }`: a field declared once per type, each constructor's list kept.
  mutating func fields(_ open: Int, _ close: Int, parent: Int32, constructor: Int32, byName: inout [Name: Int32]) {
    var pending: [Int] = []
    for (x, y) in commas(open + 1, close) {
      guard let colon = findSym(x, y, "::") else {
        if isVar(x) { pending.append(x) }
        continue
      }
      var names = pending
      pending = []
      var q = x
      while q < colon {
        if isVar(q) { names.append(q) }
        q += 1
      }
      for at in names {
        let h = unit.hash(t(at))
        if let known = byName[h] {
          set(at, .free(.value))
          if constructor >= 0 { file.constructorFields[constructor, default: []].append(known) }
          continue
        }
        let decl = addDecl(.variable, .field, at: at, first: x, end: y, parent: parent, namespace: .value)
        setType(decl, colon + 1, y)
        byName[h] = decl
        if constructor >= 0 { file.constructorFields[constructor, default: []].append(decl) }
      }
      type(colon + 1, y, bind: false)
    }
  }

  /// A GADT's constructors: `C1, C2 :: forall a. Ctx => T1 -> T a` and `C :: { f :: Int } -> T`.
  mutating func gadt(_ open: Int, parent: Int32) {
    var fieldsByName: [Name: Int32] = [:]
    for (a, b) in items(open) {
      guard let colon = findSym(a, b, "::"), let names = signatureNames(a, colon) else {
        if isWord(a, "deriving") { type(a + 1, b, bind: false) }
        continue
      }
      var decls: [Int32] = []
      for at in names where isCon(at) || isConOperator(at) {
        let decl = addDecl(.enumCase, .constructor, at: at, first: a, end: b, parent: parent, namespace: .value)
        setType(decl, colon + 1, b)
        decls.append(decl)
      }
      let typeMark = types.count
      if let brace = find(colon + 1, b, { isOpen($0, 0x7B) }) {
        type(colon + 1, brace, bind: true)
        fields(brace, closeOf(brace, b), parent: parent, constructor: decls.first ?? -1, byName: &fieldsByName)
        type(closeOf(brace, b) + 1, b, bind: true)
      } else {
        type(colon + 1, b, bind: true)
      }
      popTypes(typeMark, at: b)
    }
  }

  mutating func typeDecl(_ a: Int, _ b: Int, inClass: Int32, inInstance: Bool) {
    var p = a + 1
    let typeMark = types.count
    defer { popTypes(typeMark, at: b) }
    if isWord(p, "family") {
      p += 1
      let whereAt = findWord(p, b, "where")
      let end = whereAt ?? b
      let colon = findSym(p, end, "::")
      let headEnd = colon ?? end
      var nameAt = p
      if isOpen(p, 0x28), isOperator(p + 1) { nameAt = p + 1 }
      if isCon(nameAt) || isOperator(nameAt) {
        let decl = addDecl(.typeAlias, inClass >= 0 ? .associatedType : .typeFamily, at: nameAt, first: a, end: b, parent: inClass, namespace: .type)
        if let colon { setType(decl, colon + 1, end) }
      }
      type(nameAt + 1, headEnd, bind: true)
      if let colon { type(colon + 1, end, bind: true) }
      if let whereAt, isBlock(whereAt + 1) {
        for (x, y) in items(whereAt + 1) {
          let mark = types.count
          let equals = findSym(x, y, "=") ?? y
          type(x, equals, bind: true)
          if equals < y { type(equals + 1, y, bind: false) }
          popTypes(mark, at: y)
        }
      }
      return
    }
    if isWord(p, "instance") {
      let equals = findSym(p + 1, b, "=") ?? b
      type(p + 1, equals, bind: true)
      if equals < b { type(equals + 1, b, bind: false) }
      return
    }
    if isWord(p, "role") {
      if isCon(p + 1) { set(p + 1, .free(.type)) }
      return
    }
    let equals = findSym(p, b, "=")
    let colon = findSym(p, equals ?? b, "::")
    var nameAt = p
    if isOpen(p, 0x28), isOperator(p + 1) { nameAt = p + 1 }
    if equals == nil, let colon, inClass < 0 {
      // A standalone kind signature: `type T :: K`.
      set(nameAt, .free(.type))
      type(colon + 1, b, bind: true)
      return
    }
    if equals == nil, inClass >= 0 {
      let decl = addDecl(.typeAlias, .associatedType, at: nameAt, first: a, end: b, parent: inClass, namespace: .type)
      if let colon { setType(decl, colon + 1, b) }
      type(nameAt + 1, colon ?? b, bind: true)
      if let colon { type(colon + 1, b, bind: true) }
      return
    }
    guard let equals else { return }
    if inInstance || inClass >= 0 {
      // An instance's (or a default) equation of an associated type.
      type(p, equals, bind: true)
      type(equals + 1, b, bind: false)
      return
    }
    if !isCon(nameAt), !isOperator(nameAt), let infix = find(p, equals, { isOperator($0) && !isSym($0, "::") }) { nameAt = infix }
    let decl = addDecl(.typeAlias, .typeSynonym, at: nameAt, first: a, end: b, namespace: .type)
    setType(decl, equals + 1, b)
    type(p, nameAt, bind: true)
    type(nameAt + 1, colon ?? equals, bind: true)
    if let colon { type(colon + 1, equals, bind: false) }
    type(equals + 1, b, bind: false)
  }

  mutating func classDecl(_ a: Int, _ b: Int) {
    let whereAt = findWord(a + 1, b, "where")
    let headEnd = whereAt ?? b
    let arrow = findSym(a + 1, headEnd, "=>")
    let head = arrow.map { $0 + 1 } ?? a + 1
    let bar = findSym(head, headEnd, "|")
    var nameAt = head
    if isOpen(head, 0x28), isOperator(head + 1) { nameAt = head + 1 }
    let typeMark = types.count
    var decl: Int32 = -1
    if isCon(nameAt) || isOperator(nameAt) { decl = addDecl(.protocolType, .classDecl, at: nameAt, first: a, end: b, namespace: .type) }
    type(nameAt + 1, bar ?? headEnd, bind: true)
    if let arrow { type(a + 1, arrow, bind: false) }
    if let bar { type(bar + 1, headEnd, bind: false) }
    if let whereAt, isBlock(whereAt + 1) { group(whereAt + 1, .classBody(decl)) }
    popTypes(typeMark, at: b)
  }

  mutating func instanceDecl(_ a: Int, _ b: Int) {
    let whereAt = findWord(a + 1, b, "where")
    let headEnd = whereAt ?? b
    let arrow = findSym(a + 1, headEnd, "=>")
    let head = arrow.map { $0 + 1 } ?? a + 1
    let typeMark = types.count
    var instance: Int32 = -1
    var after = head
    if let found = qualified(head) {
      after = useQualified(head, found, .type)
      instance = Int32(file.instances.count)
      file.instances.append(HsInstance(classToken: Int32(t(found.last)), qualifier: found.qualifier))
    } else if isCon(head) {
      set(head, .free(.type))
      after = head + 1
      instance = Int32(file.instances.count)
      file.instances.append(HsInstance(classToken: Int32(t(head)), qualifier: 0))
    }
    type(after, headEnd, bind: true)
    if let arrow { type(a + 1, arrow, bind: false) }
    if let whereAt, isBlock(whereAt + 1), instance >= 0 { group(whereAt + 1, .instanceBody(instance)) }
    popTypes(typeMark, at: b)
  }

  /// `pattern P a <- p where P a = e`, `pattern P a = p`, `pattern P :: T`.
  mutating func patternSynonym(_ a: Int, _ b: Int) {
    let whereAt = findWord(a + 1, b, "where")
    let end = whereAt ?? b
    let arrow = find(a + 1, end) { isSym($0, "=") || isSym($0, "<-") }
    if let colon = findSym(a + 1, arrow ?? end, "::"), signatureNames(a + 1, colon) != nil {
      for at in signatureNames(a + 1, colon) ?? [] { set(at, .free(.value)) }
      let mark = types.count
      type(colon + 1, b, bind: true)
      popTypes(mark, at: b)
      return
    }
    guard let arrow else { return }
    var nameAt = a + 1
    if let infix = find(a + 1, arrow, { isConOperator($0) }) { nameAt = infix }
    _ = addDecl(.enumCase, .patternSynonym, at: nameAt, first: a, end: b, namespace: .value)
    let mark = values.count
    if isOpen(nameAt + 1, 0x7B) {
      for (x, _) in commas(nameAt + 2, closeOf(nameAt + 1, arrow)) where isVar(x) { pushValue(x, kind: .parameter, from: tokenAt(a)) }
    } else {
      var q = a + 1
      while q < arrow {
        if isVar(q) { pushValue(q, kind: .parameter, from: tokenAt(a)) }
        q += 1
      }
    }
    pattern(arrow + 1, end, mode: .lookup)
    popValues(mark, at: end)
    if let whereAt, isBlock(whereAt + 1) {
      for (x, y) in items(whereAt + 1) {
        guard let equals = findSym(x, y, "=") else { continue }
        let inner = values.count
        if isCon(x) { set(x, .free(.value)) }
        pattern(x + 1, equals, mode: .bind, kind: .parameter)
        exp(equals + 1, y)
        popValues(inner, at: y)
      }
    }
  }

  // MARK: Shape

  /// What other files see: the module's name, exports, imports and declarations.
  func shape() -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    func mix(_ x: UInt64) { h = (h ^ x) &* 0x100_0000_01b3 }
    mix(name(file.moduleName))
    for item in file.exports ?? [] { mix(item.name) }
    mix(file.exports == nil ? 1 : 2)
    for item in file.imports {
      mix(name(item.module))
      mix(item.isQualified ? 3 : 4)
      mix(name(item.alias ?? ""))
      mix(item.isHiding ? 5 : 6)
      for entry in item.items ?? [] { mix(entry.name) }
    }
    for (index, decl) in unit.decls.enumerated() {
      mix(decl.name)
      mix(UInt64(decl.kind.rawValue) << 32 | UInt64(UInt32(bitPattern: decl.parent)))
      mix(UInt64(file.info[index].kind.rawValue))
    }
    for (constructor, fields) in file.constructorFields.sorted(by: { $0.key < $1.key }) {
      mix(UInt64(constructor))
      for field in fields { mix(UInt64(field)) }
    }
    return h
  }
}
