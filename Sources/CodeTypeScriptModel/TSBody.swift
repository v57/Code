import CodeModel
import CodeScan
import Foundation

/// How a local's type is known.
enum TSLocalKind {
  /// A written type, by its tokens.
  case typed(Int32, Int32)
  /// An initializer's (or a default value's) tokens.
  case value(Int32, Int32)
  /// A parameter without a type of a function written as a value (`x => …`): typed by where the function goes. The
  /// function's key in `TSBody.functions`, and the parameter's position.
  case parameter(function: Int32, index: Int32)
  /// `for (const x of xs)`: what's iterated.
  case iterated(Int32, Int32)
  /// `for (const k in o)`: a key, a string.
  case key
  /// A declaration made in a body (a function, a class, an enum): its index in the unit's table.
  case declaration(Int32)
  case unknown
}

struct TSLocal {
  var name: Name
  var token: Int32
  var scopeStart: Int32
  var scopeEnd: Int32
  var kind: TSLocalKind
  /// Destructured: how it's taken from the value `kind` gives.
  var steps: [TSStep] = []
}

/// A function written in a body or a class: where its parameters and body are, and what `this` is in it.
struct TSFunction {
  var paramsOpen: Int32
  /// The `)` of the parameters, or the parameter itself for `x => …`.
  var paramsClose: Int32
  var bodyStart: Int32
  var bodyEnd: Int32
  var isArrow: Bool
  /// The class or object literal `this` is, -1 when it's nothing known; `isStatic`: the class itself.
  var thisDecl: Int32
  var isStatic = false
}

/// Layer 4 for TypeScript: the names a file's bodies introduce and where each is visible, the functions written in
/// them, and the object literals and local declarations they hold (made into the unit's declarations as they're met),
/// read once when a position in the file asks.
final class TSBody {
  func dropTypes() { types.removeAll() }

  var locals: [TSLocal] = []
  var byName: [Name: [Int32]] = [:]
  var byToken: [Int32: Int32] = [:]
  /// By `paramsOpen` (or the lone parameter's token).
  var functions: [Int32: TSFunction] = [:]
  var functionOrder: [Int32] = []
  /// Types of locals, once asked.
  var types: [Int32: Ty] = [:]
  var resolving: Set<Int32> = []

  private let unit: Unit
  private let file: TSFile
  private var parser: TSParser

  struct Scope {
    var block: (Int32, Int32)
    var function: (Int32, Int32)
    /// File and namespace level: declarations there are the unit's, not locals.
    var isTop: Bool
  }

  init(unit: Unit, file: TSFile) {
    self.unit = unit
    self.file = file
    parser = TSParser(unit: unit, file: file, resolve: { specifier, _ in "?" + specifier })
    parser.isLocal = true
    let count = Int32(unit.tokens.count)
    let top = Scope(block: (0, count), function: (0, count), isTop: true)
    statements(from: 0, to: unit.tokens.count, scope: top)
  }

  // MARK: Names

  private func add(_ token: Int, scope: (Int32, Int32), kind: TSLocalKind, steps: [TSStep] = []) {
    guard token >= 0, token < unit.tokens.count else { return }
    let word = unit.hash(token)
    let index = Int32(locals.count)
    locals.append(TSLocal(name: word, token: Int32(token), scopeStart: scope.0, scopeEnd: scope.1, kind: kind, steps: steps))
    byName[word, default: []].append(index)
    if byToken[Int32(token)] == nil { byToken[Int32(token)] = index }
  }

  /// The local named so that's visible at a token: the innermost.
  func local(named word: Name, at token: Int32) -> Int32? {
    guard let list = byName[word] else { return nil }
    var best: Int32?
    for index in list {
      let local = locals[Int(index)]
      guard local.scopeStart <= token, token < local.scopeEnd else { continue }
      if let current = best, locals[Int(current)].scopeStart > local.scopeStart { continue }
      best = index
    }
    return best
  }

  /// The locals visible at a token, innermost first, one per name.
  func visible(at token: Int32) -> [Int32] {
    var seen = Set<Name>()
    var candidates: [Int32] = []
    for index in locals.indices {
      let local = locals[index]
      if local.scopeStart <= token, token <= local.scopeEnd { candidates.append(Int32(index)) }
    }
    candidates.sort { locals[Int($0)].scopeStart > locals[Int($1)].scopeStart }
    return candidates.filter { seen.insert(locals[Int($0)].name).inserted }
  }

  /// The innermost function around a token.
  func function(at token: Int32) -> TSFunction? {
    var best: TSFunction?
    for key in functionOrder {
      guard let found = functions[key], found.paramsOpen <= token, token < found.bodyEnd else { continue }
      if let current = best, current.paramsOpen > found.paramsOpen { continue }
      best = found
    }
    return best
  }

  /// What `this` is at a token: the class or literal of the nearest function that has its own `this`.
  func thisOwner(at token: Int32) -> (decl: Int32, isStatic: Bool)? {
    var best: TSFunction?
    for key in functionOrder {
      guard let found = functions[key], !found.isArrow, found.paramsOpen <= token, token < found.bodyEnd else { continue }
      if let current = best, current.paramsOpen > found.paramsOpen { continue }
      best = found
    }
    guard let best, best.thisDecl >= 0 else { return nil }
    return (best.thisDecl, best.isStatic)
  }

  // MARK: Statements

  private func statements(from: Int, to: Int, scope: Scope) {
    var i = from
    while i < to {
      let next = statement(i, limit: to, scope: scope)
      i = max(next, i + 1)
    }
  }

  private func block(_ open: Int, scope: Scope) -> Int {
    let close = unit.skipBalanced(open) - 1
    var inner = scope
    inner.block = (Int32(open), Int32(close))
    inner.isTop = false
    statements(from: open + 1, to: close, scope: inner)
    return close + 1
  }

  private func statement(_ at: Int, limit: Int, scope: Scope) -> Int {
    var i = at
    if unit.isByte(i, 0x3B) { return i + 1 }
    while i < limit, unit.isByte(i, 0x40) || unit.tokens[i].kind == .attribute {
      i += unit.tokens[i].kind == .attribute ? 1 : 2
      while unit.isByte(i, 0x2E), unit.tsIsWord(i + 1) { i += 2 }
      if unit.isByte(i, 0x28) { i = unit.skipBalanced(i) }
    }
    while i + 1 < limit, !unit.startsLine(i + 1),
      unit.isToken(i, "export") && !unit.isByte(i + 1, 0x7B) && !unit.isByte(i + 1, 0x2A) && !unit.isByte(i + 1, 0x3D)
        || unit.isToken(i, "declare") && unit.tsIsWord(i + 1) || unit.isToken(i, "default") && i > at || unit.isToken(i, "abstract") && unit.isToken(i + 1, "class")
        || unit.isToken(i, "async") && unit.isToken(i + 1, "function")
    {
      i += 1
    }
    guard i < limit else { return limit }
    if unit.isByte(i, 0x7B) { return block(i, scope: scope) }
    if unit.isToken(i, "function"), !unit.isByte(i + 1, 0x28) {
      return functionDeclaration(i, limit: limit, scope: scope)
    }
    if unit.isToken(i, "class"), unit.tsIsName(i + 1) || unit.isByte(i + 1, 0x7B) {
      return classDeclaration(i, limit: limit, scope: scope)
    }
    if unit.isToken(i, "interface") && unit.tsIsName(i + 1) && !unit.startsLine(i + 1)
      || unit.isToken(i, "type") && unit.tsIsName(i + 1) && !unit.startsLine(i + 1) && (unit.isByte(i + 2, 0x3D) || unit.isByte(i + 2, 0x3C))
      || unit.isToken(i, "enum") && unit.tsIsName(i + 1) || unit.isToken(i, "const") && unit.isToken(i + 1, "enum")
    {
      return typeDeclaration(at, i, limit: limit, scope: scope)
    }
    if unit.isToken(i, "namespace") || unit.isToken(i, "module") || unit.isToken(i, "global"),
      !unit.startsLine(i + 1), unit.tsIsName(i + 1) || unit.tokens[i + 1].kind == .string || unit.isByte(i + 1, 0x7B)
    {
      var open = i + 1
      while open < limit, !unit.isByte(open, 0x7B), !unit.isByte(open, 0x3B), !unit.startsLine(open) || open == i + 1 { open += 1 }
      guard unit.isByte(open, 0x7B) else { return open }
      let close = unit.skipBalanced(open) - 1
      var inner = scope
      inner.block = (Int32(open), Int32(close))
      statements(from: open + 1, to: close, scope: inner)
      return close + 1
    }
    if unit.isToken(i, "import"), !unit.isByte(i + 1, 0x28), !unit.isByte(i + 1, 0x2E) {
      return unit.tsExpressionEnd(i + 1, limit: limit, commaEnds: false)
    }
    if unit.isToken(i, "export") {
      return unit.tsExpressionEnd(i + 1, limit: limit, commaEnds: false)
    }
    if unit.isToken(i, "const") || unit.isToken(i, "let") || unit.isToken(i, "var") || unit.isToken(i, "using"),
      unit.tsIsName(i + 1) || unit.isByte(i + 1, 0x7B) || unit.isByte(i + 1, 0x5B)
    {
      return variables(i, limit: limit, scope: scope, kinds: nil)
    }
    if unit.isToken(i, "if") || unit.isToken(i, "while") || unit.isToken(i, "with") {
      var k = i + 1
      if unit.isByte(k, 0x28) {
        let close = unit.skipBalanced(k) - 1
        expressionList(k + 1, close, scope: scope)
        k = close + 1
      }
      k = statement(k, limit: limit, scope: inner(scope))
      if unit.isToken(i, "if"), unit.isToken(k, "else") { k = statement(k + 1, limit: limit, scope: inner(scope)) }
      return k
    }
    if unit.isToken(i, "for") { return forStatement(i, limit: limit, scope: scope) }
    if unit.isToken(i, "do") {
      var k = statement(i + 1, limit: limit, scope: inner(scope))
      if unit.isToken(k, "while"), unit.isByte(k + 1, 0x28) {
        let close = unit.skipBalanced(k + 1) - 1
        expressionList(k + 2, close, scope: scope)
        k = close + 1
      }
      return k
    }
    if unit.isToken(i, "switch"), unit.isByte(i + 1, 0x28) {
      let close = unit.skipBalanced(i + 1) - 1
      expressionList(i + 2, close, scope: scope)
      guard unit.isByte(close + 1, 0x7B) else { return close + 1 }
      return block(close + 1, scope: scope)
    }
    if unit.isToken(i, "case") {
      // To its `:`, a conditional's own skipped.
      var k = i + 1
      var questions = 0
      while k < limit {
        if unit.tokens[k].kind == .open || unit.tokens[k].kind == .interpolationOpen {
          k = unit.skipBalanced(k)
          continue
        }
        if unit.isByte(k, 0x3F) { questions += 1 }
        if unit.isByte(k, 0x3A) {
          if questions == 0 { break }
          questions -= 1
        }
        k += 1
      }
      _ = expression(i + 1, limit: k, scope: scope, commaEnds: false)
      return k + 1
    }
    if unit.isToken(i, "default"), unit.isByte(i + 1, 0x3A) { return i + 2 }
    if unit.isToken(i, "try") {
      var k = i + 1
      if unit.isByte(k, 0x7B) { k = block(k, scope: scope) }
      if unit.isToken(k, "catch") {
        k += 1
        var catchScope = scope
        if unit.isByte(k, 0x28) {
          let close = unit.skipBalanced(k) - 1
          if unit.isByte(close + 1, 0x7B) {
            let blockClose = unit.skipBalanced(close + 1) - 1
            catchScope.block = (Int32(k), Int32(blockClose))
            catchScope.isTop = false
            var p = k + 1
            if unit.tsIsName(p) {
              var kind = TSLocalKind.unknown
              if unit.isByte(p + 1, 0x3A) { kind = .typed(Int32(p + 2), Int32(unit.tsTypeEnd(p + 2, limit: close))) }
              add(p, scope: catchScope.block, kind: kind)
            } else if unit.isByte(p, 0x7B) || unit.isByte(p, 0x5B) {
              parser.bindings(p, steps: []) { token, steps in add(token, scope: catchScope.block, kind: .unknown, steps: steps) }
              p = unit.skipBalanced(p)
            }
          }
          k = close + 1
        }
        if unit.isByte(k, 0x7B) { k = block(k, scope: catchScope) }
      }
      if unit.isToken(k, "finally"), unit.isByte(k + 1, 0x7B) { k = block(k + 1, scope: scope) }
      return k
    }
    if unit.isToken(i, "return") || unit.isToken(i, "throw") {
      if unit.startsLine(i + 1) || unit.isByte(i + 1, 0x3B) || unit.isByte(i + 1, 0x7D) { return i + 1 }
      return expression(i + 1, limit: limit, scope: scope, commaEnds: false)
    }
    if unit.isToken(i, "break") || unit.isToken(i, "continue") {
      return unit.tsIsName(i + 1) && !unit.startsLine(i + 1) ? i + 2 : i + 1
    }
    // A label.
    if unit.tsIsName(i), unit.isByte(i + 1, 0x3A), !unit.isByte(i + 2, 0x3A) { return i + 2 }
    return expression(i, limit: limit, scope: scope, commaEnds: false)
  }

  private func inner(_ scope: Scope) -> Scope {
    var result = scope
    result.isTop = false
    return result
  }

  /// `function f(…) { … }`: the unit's declaration at the top, a local in a body.
  private func functionDeclaration(_ at: Int, limit: Int, scope: Scope) -> Int {
    var nameToken = at + 1
    if unit.isByte(nameToken, 0x2A) { nameToken += 1 }
    var index = declaration(at: nameToken, kinds: [.function])
    if index == nil, !scope.isTop {
      let before = unit.decls.count
      _ = parser.function(at, at: at, limit: limit, parent: -1, exported: false)
      if unit.decls.count > before { index = Int32(before) }
    }
    guard let index else { return unit.tsExpressionEnd(at + 1, limit: limit, commaEnds: false) }
    if !scope.isTop { add(Int(unit.decls[Int(index)].nameToken), scope: scope.block, kind: .declaration(index)) }
    scanFunction(index, thisDecl: -1, isStatic: false)
    return max(Int(unit.decls[Int(index)].end), at + 1)
  }

  /// A declaration of one of `kinds` whose name is at a token.
  private func declaration(at token: Int, kinds: Set<DeclKind>) -> Int32? {
    for index in unit.decls.indices where unit.decls[index].nameToken == Int32(token) && kinds.contains(unit.decls[index].kind) { return Int32(index) }
    return nil
  }

  private func classDeclaration(_ at: Int, limit: Int, scope: Scope) -> Int {
    var index = declaration(at: unit.tsIsName(at + 1) ? at + 1 : at, kinds: [.classType])
    if index == nil {
      let before = unit.decls.count
      _ = parser.classDeclaration(at, at: at, limit: limit, parent: -1, exported: false)
      if unit.decls.count > before { index = Int32(before) }
    }
    guard let index else { return at + 1 }
    if !scope.isTop, unit.decls[Int(index)].name != 0 { add(Int(unit.decls[Int(index)].nameToken), scope: scope.block, kind: .declaration(index)) }
    scanClass(index)
    return max(Int(unit.decls[Int(index)].end), at + 1)
  }

  /// An interface, a type alias or an enum: made when local, nothing to scan.
  private func typeDeclaration(_ first: Int, _ at: Int, limit: Int, scope: Scope) -> Int {
    let nameToken = unit.isToken(at, "const") ? at + 2 : at + 1
    if let known = declaration(at: nameToken, kinds: [.protocolType, .typeAlias, .enumeration]) {
      for child in unit.children(of: known) where unit.decls[Int(child)].initStart >= 0 {
        _ = expression(Int(unit.decls[Int(child)].initStart), limit: Int(unit.decls[Int(child)].initEnd), scope: scope, commaEnds: false)
      }
      return max(Int(unit.decls[Int(known)].end), at + 1)
    }
    let before = unit.decls.count
    let end = parser.statement(at, limit: limit, parent: -1, ambient: false)
    if unit.decls.count > before { add(nameToken, scope: scope.block, kind: .declaration(Int32(before))) }
    return end
  }

  /// `const a: T = x, { b } = y`: locals in a body, the initializers scanned anywhere. `kinds` overrides how
  /// declarators without an initializer are typed (a `for` head's `of`/`in`).
  private func variables(_ at: Int, limit: Int, scope: Scope, kinds: TSLocalKind?) -> Int {
    let isVar = unit.isToken(at, "var")
    let target = isVar ? scope.function : scope.block
    let end = kinds == nil ? unit.tsExpressionEnd(at + 1, limit: limit, commaEnds: false) : limit
    var i = at + 1
    while i < end {
      var k = i
      let pattern = unit.isByte(k, 0x7B) || unit.isByte(k, 0x5B) ? k : -1
      var nameToken = -1
      if pattern >= 0 {
        k = unit.skipBalanced(k)
      } else if unit.tsIsName(k) {
        nameToken = k
        k += 1
      } else {
        break
      }
      if unit.isByte(k, 0x21) { k += 1 }
      var kind: TSLocalKind = kinds ?? .unknown
      if unit.isByte(k, 0x3A) {
        let typeEnd = unit.tsTypeEnd(k + 1, limit: end)
        parser.objectTypes(from: k + 1, to: typeEnd, parent: -1)
        kind = .typed(Int32(k + 1), Int32(typeEnd))
        k = typeEnd
      }
      var itemEnd = k
      if unit.isByte(k, 0x3D) {
        itemEnd = expression(k + 1, limit: end, scope: scope, commaEnds: true)
        if case .typed = kind {} else { kind = .value(Int32(k + 1), Int32(itemEnd)) }
      } else {
        while itemEnd < end, !unit.isByte(itemEnd, 0x2C) { itemEnd = unit.tokens[itemEnd].kind == .open ? unit.skipBalanced(itemEnd) : itemEnd + 1 }
      }
      if !scope.isTop {
        if nameToken >= 0 {
          add(nameToken, scope: target, kind: kind)
        } else {
          parser.bindings(pattern, steps: []) { token, steps in add(token, scope: target, kind: kind, steps: steps) }
          defaults(in: pattern, scope: scope)
        }
      }
      i = unit.isByte(itemEnd, 0x2C) ? itemEnd + 1 : max(itemEnd, i + 1)
      if !unit.isByte(itemEnd, 0x2C) { break }
    }
    return max(end, i)
  }

  /// Default values inside a pattern: `{ a = f() }`.
  private func defaults(in pattern: Int, scope: Scope) {
    let close = unit.skipBalanced(pattern) - 1
    var i = pattern + 1
    while i < close {
      if unit.isByte(i, 0x3D) {
        i = expression(i + 1, limit: close, scope: scope, commaEnds: true)
        continue
      }
      if unit.isByte(i, 0x7B) || unit.isByte(i, 0x5B) {
        defaults(in: i, scope: scope)
        i = unit.skipBalanced(i)
        continue
      }
      i += 1
    }
  }

  /// `for (init; cond; next)`, `for (const x of xs)`, `for await (…)`.
  private func forStatement(_ at: Int, limit: Int, scope: Scope) -> Int {
    var i = at + 1
    if unit.isToken(i, "await") { i += 1 }
    guard unit.isByte(i, 0x28) else { return i }
    let close = unit.skipBalanced(i) - 1
    // The head's names last through the body.
    var bodyEnd = close + 1
    if bodyEnd < limit {
      if unit.isByte(bodyEnd, 0x7B) {
        bodyEnd = unit.skipBalanced(bodyEnd)
      } else {
        bodyEnd = unit.tsExpressionEnd(bodyEnd, limit: limit, commaEnds: false)
      }
    }
    var head = scope
    head.block = (Int32(i), Int32(bodyEnd))
    head.isTop = false
    // `of`/`in` at depth 0 of the head.
    var k = i + 1
    var ofToken = -1
    while k < close {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.isToken(k, "of") || unit.isToken(k, "in") {
        ofToken = k
        break
      }
      if unit.isByte(k, 0x3B) || unit.isByte(k, 0x3D) { break }
      k += 1
    }
    if ofToken >= 0 {
      let iterated = expression(ofToken + 1, limit: close, scope: scope, commaEnds: false)
      let kind: TSLocalKind = unit.isToken(ofToken, "of") ? .iterated(Int32(ofToken + 1), Int32(iterated)) : .key
      if unit.isToken(i + 1, "const") || unit.isToken(i + 1, "let") || unit.isToken(i + 1, "var") {
        _ = variables(i + 1, limit: ofToken, scope: head, kinds: kind)
      }
    } else {
      var p = i + 1
      while p < close {
        if unit.isToken(p, "const") || unit.isToken(p, "let") || unit.isToken(p, "var") {
          p = variables(p, limit: close, scope: head, kinds: nil)
        } else {
          p = expression(p, limit: close, scope: head, commaEnds: false)
        }
        if unit.isByte(p, 0x3B) { p += 1 } else { p = max(p, p + 1) }
      }
    }
    return statement(close + 1, limit: limit, scope: head)
  }

  // MARK: Classes and functions

  /// A class's members: method bodies and property initializers, `this` the class.
  func scanClass(_ index: Int32) {
    let item = unit.decls[Int(index)]
    if item.typeStart >= 0 { _ = expression(Int(item.typeStart), limit: Int(item.typeEnd), scope: classScope(item), commaEnds: false) }
    for child in unit.children(of: index) {
      let member = unit.decls[Int(child)]
      if member.bodyOpen >= 0, member.kind == .function || member.kind == .initializer || member.kind == .variable {
        scanFunction(child, thisDecl: index, isStatic: member.isStatic)
      } else if member.initStart >= 0, member.kind == .variable {
        // An initializer sees `this` as a method does.
        let key = member.initStart
        functions[key] = TSFunction(paramsOpen: key, paramsClose: key, bodyStart: key, bodyEnd: member.initEnd, isArrow: false, thisDecl: index, isStatic: member.isStatic)
        functionOrder.append(key)
        _ = expression(Int(member.initStart), limit: Int(member.initEnd), scope: classScope(item), commaEnds: false)
      }
    }
  }

  private func classScope(_ item: Decl) -> Scope {
    let start = item.bodyOpen >= 0 ? item.bodyOpen : item.first
    let end = item.bodyClose >= 0 ? item.bodyClose : item.end
    return Scope(block: (start, end), function: (start, end), isTop: false)
  }

  /// The `(` of a declaration's parameters.
  private func paramsOpen(of item: Decl) -> Int? {
    var i = Int(item.nameToken) + 1
    if unit.isByte(Int(item.nameToken), 0x5B) { i = unit.skipBalanced(Int(item.nameToken)) }
    if unit.isByte(i, 0x3F) || unit.isByte(i, 0x21) { i += 1 }
    if unit.isByte(i, 0x3C) { i = unit.tsSkipAngles(i, limit: unit.tokens.count) }
    return unit.isByte(i, 0x28) ? i : nil
  }

  /// A declared function's parameters and body.
  func scanFunction(_ index: Int32, thisDecl: Int32, isStatic: Bool) {
    let item = unit.decls[Int(index)]
    guard item.bodyOpen >= 0, let open = paramsOpen(of: item) else { return }
    let close = unit.skipBalanced(open) - 1
    let end = item.bodyClose + 1
    let key = Int32(open)
    functions[key] = TSFunction(paramsOpen: key, paramsClose: Int32(close), bodyStart: item.bodyOpen, bodyEnd: end, isArrow: false, thisDecl: thisDecl, isStatic: isStatic)
    functionOrder.append(key)
    let scope = Scope(block: (key, end), function: (key, end), isTop: false)
    parameters(open: open, close: close, scope: scope, function: key)
    statements(from: Int(item.bodyOpen) + 1, to: Int(item.bodyClose), scope: scope)
  }

  /// Parameters as locals: typed, defaulted, or typed by where the function goes.
  private func parameters(open: Int, close: Int, scope: Scope, function: Int32) {
    var i = open + 1
    var position: Int32 = 0
    while i < close {
      let itemEnd = unit.tsListItemEnd(i, limit: close)
      defer {
        i = itemEnd + 1
        position += 1
      }
      var k = i
      while k < itemEnd, unit.isByte(k, 0x40) {
        k += 2
        if unit.isByte(k, 0x28) { k = unit.skipBalanced(k) }
      }
      while k + 1 < itemEnd, unit.isToken(k, "public") || unit.isToken(k, "private") || unit.isToken(k, "protected") || unit.isToken(k, "readonly")
        || unit.isToken(k, "override")
      {
        k += 1
      }
      if unit.isToken(k, "...") { k += 1 }
      if unit.isToken(k, "this") {
        position -= 1
        continue
      }
      let pattern = unit.isByte(k, 0x7B) || unit.isByte(k, 0x5B) ? k : -1
      let nameToken = pattern < 0 && unit.tsIsName(k) ? k : -1
      if pattern >= 0 { k = unit.skipBalanced(k) } else if nameToken >= 0 { k += 1 } else { continue }
      if unit.isByte(k, 0x3F) { k += 1 }
      var kind = TSLocalKind.parameter(function: function, index: position)
      if unit.isByte(k, 0x3A) || unit.isToken(k, "?:") {
        let typeEnd = unit.tsTypeEnd(k + 1, limit: itemEnd)
        parser.objectTypes(from: k + 1, to: typeEnd, parent: -1)
        kind = .typed(Int32(k + 1), Int32(typeEnd))
        k = typeEnd
      }
      if unit.isByte(k, 0x3D) {
        let valueEnd = expression(k + 1, limit: itemEnd, scope: scope, commaEnds: true)
        if case .parameter = kind { kind = .value(Int32(k + 1), Int32(valueEnd)) }
      }
      if nameToken >= 0 {
        add(nameToken, scope: scope.function, kind: kind)
      } else {
        parser.bindings(pattern, steps: []) { token, steps in add(token, scope: scope.function, kind: kind, steps: steps) }
        defaults(in: pattern, scope: scope)
      }
    }
  }

  /// `(a, b) => …` or `x => …` from its parameters; returns the token after its body.
  private func arrow(paramsOpen: Int, paramsClose: Int, arrowToken: Int, limit: Int, scope: Scope, commaEnds: Bool) -> Int {
    let bodyStart = arrowToken + 1
    var bodyEnd: Int
    if unit.isByte(bodyStart, 0x7B) {
      bodyEnd = unit.skipBalanced(bodyStart)
    } else {
      bodyEnd = unit.tsExpressionEnd(bodyStart, limit: limit, commaEnds: commaEnds)
    }
    let key = Int32(paramsOpen)
    functions[key] = TSFunction(paramsOpen: key, paramsClose: Int32(paramsClose), bodyStart: Int32(bodyStart), bodyEnd: Int32(bodyEnd), isArrow: true, thisDecl: -1)
    functionOrder.append(key)
    let inner = Scope(block: (key, Int32(bodyEnd)), function: (key, Int32(bodyEnd)), isTop: false)
    if paramsOpen == paramsClose {
      add(paramsOpen, scope: inner.function, kind: .parameter(function: key, index: 0))
    } else {
      parameters(open: paramsOpen, close: paramsClose, scope: inner, function: key)
    }
    if unit.isByte(bodyStart, 0x7B) {
      statements(from: bodyStart + 1, to: bodyEnd - 1, scope: inner)
    } else {
      _ = expression(bodyStart, limit: bodyEnd, scope: inner, commaEnds: commaEnds)
    }
    return bodyEnd
  }

  /// `function [name](…) { … }` written as a value.
  private func functionExpression(_ at: Int, limit: Int, scope: Scope) -> Int {
    var i = at + 1
    if unit.isByte(i, 0x2A) { i += 1 }
    var nameToken = -1
    if unit.tsIsName(i) {
      nameToken = i
      i += 1
    }
    if unit.isByte(i, 0x3C) { i = unit.tsSkipAngles(i, limit: limit) }
    guard unit.isByte(i, 0x28) else { return i }
    let close = unit.skipBalanced(i) - 1
    var k = close + 1
    if unit.isByte(k, 0x3A) { k = unit.tsTypeEnd(k + 1, limit: limit) }
    guard unit.isByte(k, 0x7B) else { return k }
    let bodyEnd = unit.skipBalanced(k)
    let key = Int32(i)
    functions[key] = TSFunction(paramsOpen: key, paramsClose: Int32(close), bodyStart: Int32(k), bodyEnd: Int32(bodyEnd), isArrow: false, thisDecl: -1)
    functionOrder.append(key)
    let inner = Scope(block: (key, Int32(bodyEnd)), function: (key, Int32(bodyEnd)), isTop: false)
    if nameToken >= 0 { add(nameToken, scope: (Int32(at), Int32(bodyEnd)), kind: .unknown) }
    parameters(open: i, close: close, scope: inner, function: key)
    statements(from: k + 1, to: bodyEnd - 1, scope: inner)
    return bodyEnd
  }

  /// An object literal in a body: its structure (made now, local), its values and its methods (`this` the literal).
  private func objectLiteral(_ open: Int, scope: Scope) -> Int {
    let index = parser.objectLiteral(open: open, parent: -1)
    let item = unit.decls[Int(index)]
    for child in unit.children(of: index) {
      let member = unit.decls[Int(child)]
      if member.bodyOpen >= 0 {
        scanFunction(child, thisDecl: index, isStatic: false)
      } else if member.initStart >= 0, !file.shorthand.contains(child) {
        _ = expression(Int(member.initStart), limit: Int(member.initEnd), scope: scope, commaEnds: true)
      }
    }
    for r in 0..<Int(item.inheritCount) {
      let range = unit.ranges[Int(item.inheritStart) + r]
      _ = expression(Int(range.start), limit: Int(range.end), scope: scope, commaEnds: true)
    }
    return unit.skipBalanced(open)
  }

  // MARK: Expressions

  private func expressionList(_ from: Int, _ to: Int, scope: Scope) {
    var i = from
    while i < to {
      i = expression(i, limit: to, scope: scope, commaEnds: true)
      if unit.isByte(i, 0x2C) || unit.isByte(i, 0x3B) { i += 1 } else if i < to { i += 1 }
    }
  }

  /// Whether the `(` at `open` (its `)` at `close`) are an arrow function's parameters; the `=>` if so.
  private func arrowAfter(_ close: Int, limit: Int) -> Int? {
    if unit.isToken(close + 1, "=>") { return close + 1 }
    if unit.isByte(close + 1, 0x3A) {
      let end = unit.tsTypeEnd(close + 2, limit: limit, arrowEnds: true)
      if unit.isToken(end, "=>") { return end }
    }
    return nil
  }

  /// An expression from `from`, its functions, object literals and classes scanned; returns where it ends.
  @discardableResult
  func expression(_ from: Int, limit: Int, scope: Scope, commaEnds: Bool) -> Int {
    var i = from
    while i < limit {
      if i > from, unit.startsLine(i), unit.tsEndsExpression(i - 1), !unit.tsContinues(i) { return i }
      let token = unit.tokens[i]
      switch token.kind {
      case .open:
        let close = unit.skipBalanced(i) - 1
        if unit.isByte(i, 0x28) {
          if let arrowToken = arrowAfter(close, limit: limit) {
            i = arrow(paramsOpen: i, paramsClose: close, arrowToken: arrowToken, limit: limit, scope: scope, commaEnds: commaEnds)
            continue
          }
          expressionList(i + 1, close, scope: scope)
          i = close + 1
        } else if unit.isByte(i, 0x5B) {
          expressionList(i + 1, close, scope: scope)
          i = close + 1
        } else {
          i = objectLiteral(i, scope: scope)
        }
        continue
      case .interpolationOpen:
        let close = unit.skipBalanced(i) - 1
        _ = expression(i + 1, limit: close, scope: scope, commaEnds: false)
        i = close + 1
        continue
      case .close, .interpolationClose:
        return i
      case .punctuation:
        if unit.isByte(i, 0x3B) { return i }
        if unit.isByte(i, 0x2C), commaEnds { return i }
        if unit.isByte(i, 0x3C), let end = unit.tsTypeArgumentsEnd(i, limit: limit) {
          i = end
          continue
        }
      case .identifier, .keyword, .declarationKeyword:
        if unit.isToken(i + 1, "=>"), unit.tsIsName(i), !unit.tsIsDot(i - 1) {
          i = arrow(paramsOpen: i, paramsClose: i, arrowToken: i + 1, limit: limit, scope: scope, commaEnds: commaEnds)
          continue
        }
        if unit.isToken(i, "function"), !unit.tsIsDot(i - 1) {
          i = functionExpression(i, limit: limit, scope: scope)
          continue
        }
        if unit.isToken(i, "class"), !unit.tsIsDot(i - 1), unit.tsIsName(i + 1) || unit.isByte(i + 1, 0x7B) || unit.isToken(i + 1, "extends") {
          let before = unit.decls.count
          let end = parser.classDeclaration(i, at: i, limit: limit, parent: -1, exported: false)
          if unit.decls.count > before { scanClass(Int32(before)) }
          i = max(end, i + 1)
          continue
        }
        if (unit.isToken(i, "as") || unit.isToken(i, "satisfies")) && i > from && !unit.tsIsDot(i - 1) {
          let typeEnd = unit.tsTypeEnd(i + 1, limit: limit)
          parser.objectTypes(from: i + 1, to: typeEnd, parent: -1)
          i = max(typeEnd, i + 1)
          continue
        }
      default:
        break
      }
      i += 1
    }
    return min(i, limit)
  }
}
