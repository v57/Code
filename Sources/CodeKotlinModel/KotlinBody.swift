import CodeModel
import CodeScan
import Foundation

/// How a local's type is known.
enum KotlinLocalKind {
  /// A written type, by its tokens (a parameter, `val x: T`, a catch's parameter). `variadic`: a `vararg` parameter, an
  /// array of it.
  case typed(Int32, Int32, variadic: Bool)
  /// `val x = e`: the initializer's tokens.
  case inferred(Int32, Int32)
  /// `val x by d`: what the delegate gives.
  case delegated(Int32, Int32)
  /// `for (x in e)`: what iterating e gives.
  case element(Int32, Int32)
  /// `val (a, b) = e` (or a `for`'s or a lambda's destructuring): e's `componentN()`; `ofElement`: of what iterating
  /// e gives; `lambda`: e is a lambda's `{` and the parameter's position.
  case component(Int32, Int32, index: Int32, ofElement: Bool)
  case lambdaComponent(brace: Int32, position: Int32, index: Int32)
  /// A lambda's parameter without a type: the lambda's `{` and which parameter.
  case lambda(brace: Int32, index: Int32)
  /// A setter's `value`: the property's type.
  case setterValue(property: Int32)
}

struct KotlinLocal {
  var name: Name
  var token: Int32
  var scopeStart: Int32
  var scopeEnd: Int32
  var kind: KotlinLocalKind
}

/// A smart cast: where `name is Type` holds.
struct KotlinCast {
  var name: Name
  var typeStart: Int32
  var typeEnd: Int32
  var scopeStart: Int32
  var scopeEnd: Int32
}

/// Layer 4 for Kotlin: the locals a declaration's body declares and where each is visible, read once when a position
/// inside asks: parameters (of local functions and classes too), `val`/`var` with destructuring, `for` and `catch`,
/// `when (val x = …)`, lambdas' parameters and their implicit `it`, and the smart casts `is` checks make in `if`
/// conditions and `when` branches. A local may hide an outer one: the one declared last before a use, still in
/// scope, is the one meant.
final class KotlinBody: BodyFacts {
  func dropTypes() {
    types.removeAll()
  }

  var locals: [KotlinLocal] = []
  var byName: [Name: [Int32]] = [:]
  var byToken: [Int32: Int32] = [:]
  /// Each lambda's `{` → its parameters' tokens, its body's end and whether it names its parameters (`->`).
  var lambdas: [Int32: (params: [Int32], end: Int32, hasArrow: Bool)] = [:]
  /// Lambdas' braces in order, for those around a token.
  var lambdaOrder: [Int32] = []
  var casts: [KotlinCast] = []
  var types: [Int32: Ty] = [:]
  var resolving: Set<Int32> = []

  private let unit: Unit
  private var localDecls: [Int32: Int32] = [:]

  init(unit: Unit, owner: Int32) {
    self.unit = unit
    guard owner >= 0, Int(owner) < unit.decls.count else { return }
    for index in unit.decls.indices where unit.decls[index].isLocal {
      if localDecls[unit.decls[index].first] == nil { localDecls[unit.decls[index].first] = Int32(index) }
    }
    member(owner)
    lambdaOrder = lambdas.keys.sorted()
  }

  private func member(_ index: Int32) {
    let decl = unit.decls[Int(index)]
    if decl.kind.isNominal || decl.kind == .enumCase {
      // A class header: its constructor parameters' defaults and its supertypes' arguments.
      let end = decl.bodyOpen >= 0 ? decl.bodyOpen : decl.end
      scan(Int(decl.nameToken) + 1, Int(end), blockEnd: end)
      if decl.kind == .enumCase, decl.initStart >= 0 { scan(Int(decl.initStart), Int(decl.initEnd), blockEnd: decl.initEnd) }
      return
    }
    for p in 0..<Int(decl.paramCount) {
      let param = unit.params[Int(decl.paramStart) + p]
      if decl.kind == .function, decl.name == 0, decl.parent >= 0, unit.decls[Int(decl.parent)].kind == .variable, param.typeStart < 0 {
        add(param.nameToken, from: decl.first, to: decl.end, kind: .setterValue(property: decl.parent))
        continue
      }
      add(param.nameToken, from: decl.first, to: decl.end, kind: .typed(param.typeStart, param.typeEnd, variadic: param.variadic))
    }
    if decl.bodyOpen >= 0 { scan(Int(decl.bodyOpen) + 1, Int(decl.bodyClose), blockEnd: decl.bodyClose) }
    if decl.initStart >= 0 { scan(Int(decl.initStart), Int(decl.initEnd), blockEnd: decl.initEnd) }
    // Parameters' defaults.
    if decl.kind == .function || decl.kind == .initializer, decl.paramCount > 0 {
      let first = unit.params[Int(decl.paramStart)].nameToken
      let last = unit.params[Int(decl.paramStart + decl.paramCount - 1)]
      var end = Int(max(last.typeEnd, last.nameToken + 1))
      while end < unit.tokens.count, !unit.isByte(end, 0x29), !unit.isByte(end, 0x7B) { end = unit.tokens[end].kind == .open ? unit.skipBalanced(end) : end + 1 }
      scan(Int(first), end, blockEnd: decl.end)
    }
    // A property's accessors.
    if decl.kind == .variable {
      for child in unit.children(of: index) where unit.decls[Int(child)].kind == .function && unit.decls[Int(child)].name == 0 { member(child) }
    }
  }

  private func add(_ token: Int32, from: Int32, to: Int32, kind: KotlinLocalKind) {
    guard token >= 0, Int(token) < unit.tokens.count, !unit.isToken(Int(token), "_") else { return }
    let name = unit.hash(Int(token))
    if byToken[token] != nil { return }
    let index = Int32(locals.count)
    locals.append(KotlinLocal(name: name, token: token, scopeStart: from, scopeEnd: to, kind: kind))
    byName[name, default: []].append(index)
    byToken[token] = index
  }

  /// The local named so that a token sees: the last declared before it whose scope holds it.
  func local(named name: Name, at token: Int32) -> Int32? {
    guard let list = byName[name] else { return nil }
    var best: Int32?
    for index in list {
      let local = locals[Int(index)]
      guard local.token == token || local.scopeStart <= token && token < local.scopeEnd && local.token < token else { continue }
      if let current = best, locals[Int(current)].token > local.token { continue }
      best = index
    }
    return best
  }

  /// Every local a token sees, the nearest first.
  func visible(at token: Int32) -> [Int32] {
    var seen = Set<Name>()
    var result: [Int32] = []
    for index in locals.indices.reversed() {
      let local = locals[index]
      guard local.scopeStart <= token, token <= local.scopeEnd, local.token < token else { continue }
      if seen.insert(local.name).inserted { result.append(Int32(index)) }
    }
    return result
  }

  /// The lambdas a token is inside, innermost first.
  func lambdasAround(_ token: Int32) -> [Int32] {
    var result: [Int32] = []
    for brace in lambdaOrder where brace < token {
      if let lambda = lambdas[brace], token <= lambda.end { result.append(brace) }
    }
    return result.reversed()
  }

  /// The innermost lambda around a token whose parameter is the implicit `it`.
  func itLambda(at token: Int32) -> Int32? {
    for brace in lambdasAround(token) {
      guard let lambda = lambdas[brace] else { continue }
      if lambda.hasArrow { continue }
      return brace
    }
    return nil
  }

  /// The smart cast that holds for a name at a token, the innermost.
  func cast(of name: Name, at token: Int32) -> KotlinCast? {
    var best: KotlinCast?
    for cast in casts where cast.name == name && cast.scopeStart <= token && token < cast.scopeEnd {
      if let current = best, current.scopeStart > cast.scopeStart { continue }
      best = cast
    }
    return best
  }

  // MARK: Scanning

  private func isStatementStart(_ i: Int) -> Bool {
    guard i > 0 else { return true }
    if unit.startsLine(i) { return true }
    let before = i - 1
    return unit.isByte(before, 0x7B) || unit.isByte(before, 0x3B) || unit.isToken(before, "->") || unit.isByte(before, 0x7D)
  }

  /// The tokens from `from` to `to`; declarations' scopes end at `blockEnd`.
  private func scan(_ from: Int, _ to: Int, blockEnd: Int32) {
    var i = from
    while i < to {
      if let local = localDecls[Int32(i)] {
        i = localDeclaration(local, limit: to)
        continue
      }
      let token = unit.tokens[i]
      if token.kind == .open {
        let close = unit.skipBalanced(i) - 1
        if unit.isByte(i, 0x7B) {
          if isLambda(i) {
            lambda(i, close: close)
          } else {
            scan(i + 1, min(close, to), blockEnd: Int32(min(close, to)))
          }
          i = close + 1
          continue
        }
        if unit.isByte(i, 0x28) {
          if unit.isToken(i - 1, "catch") { catchParameter(i, close) }
          if unit.isToken(i - 1, "for") { forHeader(i, close, blockEnd: blockEnd) }
          if unit.isToken(i - 1, "when") { whenSubject(i, close) }
          if unit.isToken(i - 1, "if") || unit.isToken(i - 1, "while") { conditionCasts(i, close, blockEnd: blockEnd) }
          scan(i + 1, min(close, to), blockEnd: blockEnd)
          i = close + 1
          continue
        }
        scan(i + 1, min(close, to), blockEnd: blockEnd)
        i = close + 1
        continue
      }
      // `when { x is T -> … }`: x is T in the branch.
      if unit.isToken(i, "is"), i > from, unit.ktIsName(i - 1), isBranchStart(i - 1), let typeEnd = unit.ktTypeEnd(i + 1, limit: to), unit.isToken(typeEnd, "->") {
        let branchEnd = branchBodyEnd(typeEnd + 1, limit: to)
        casts.append(KotlinCast(name: unit.hash(i - 1), typeStart: Int32(i + 1), typeEnd: Int32(typeEnd), scopeStart: Int32(typeEnd), scopeEnd: Int32(branchEnd)))
        i = typeEnd
        continue
      }
      if unit.isToken(i, "val") || unit.isToken(i, "var"), isStatementStart(i) || unit.isByte(i - 1, 0x28) {
        i = declaration(i, to: to, blockEnd: blockEnd)
        continue
      }
      i += 1
    }
  }

  /// A local function, class or anonymous object: its members' parameters and bodies.
  private func localDeclaration(_ index: Int32, limit: Int) -> Int {
    let decl = unit.decls[Int(index)]
    if decl.kind == .extensionDecl {
      for child in unit.children(of: index) { member(child) }
    } else if decl.kind.isNominal {
      for p in 0..<Int(decl.paramCount) {
        let param = unit.params[Int(decl.paramStart) + p]
        add(param.nameToken, from: decl.first, to: decl.end, kind: .typed(param.typeStart, param.typeEnd, variadic: param.variadic))
      }
      member(index)
      for child in unit.children(of: index) {
        let item = unit.decls[Int(child)]
        if item.kind.isNominal || item.kind == .extensionDecl { _ = localDeclaration(child, limit: limit) } else { member(child) }
      }
    } else {
      member(index)
    }
    return max(Int(decl.end), Int(decl.first) + 1)
  }

  /// Whether a `{` opens a lambda rather than a block (after `if (…)`, `else`, `try`, `->` in a `when`, …).
  private func isLambda(_ brace: Int) -> Bool {
    guard brace > 0 else { return false }
    let before = brace - 1
    let token = unit.tokens[before]
    if unit.isToken(before, "else") || unit.isToken(before, "try") || unit.isToken(before, "finally") || unit.isToken(before, "do") || unit.isToken(before, "->") {
      return false
    }
    if unit.isToken(before, "when") { return false }
    if token.kind == .close, unit.isByte(before, 0x29), let open = unit.matchingOpen(before) {
      let head = open - 1
      if unit.isToken(head, "if") || unit.isToken(head, "for") || unit.isToken(head, "while") || unit.isToken(head, "catch") || unit.isToken(head, "when") { return false }
      return true
    }
    if token.kind == .punctuation {
      // `= {`, `({`, `, {`, `?: {`.
      return true
    }
    if token.kind == .open { return true }
    if unit.ktIsName(before) || token.kind == .close { return true }
    if unit.isToken(before, "return") { return true }
    return false
  }

  /// A lambda's parameters (`a, (b, c), d: T ->`), or its implicit `it`, then its body.
  private func lambda(_ brace: Int, close: Int) {
    var arrow = -1
    var k = brace + 1
    var plain = true
    while k < close {
      if unit.isToken(k, "->") {
        arrow = k
        break
      }
      if unit.tokens[k].kind == .open {
        guard unit.isByte(k, 0x28) else {
          plain = false
          break
        }
        k = unit.skipBalanced(k)
        continue
      }
      if unit.ktIsName(k) || unit.isByte(k, 0x2C) || unit.isToken(k, ":") || unit.tokens[k].kind == .punctuation && unit.ktOnly(k, "<>?.*") {
        k += 1
        continue
      }
      plain = false
      break
    }
    var params: [Int32] = []
    if plain, arrow > 0 {
      var i = brace + 1
      var position: Int32 = 0
      while i < arrow {
        var end = i
        while end < arrow, !unit.isByte(end, 0x2C) { end = unit.tokens[end].kind == .open ? unit.skipBalanced(end) : end + 1 }
        if unit.isByte(i, 0x28) {
          // `(a, b)`: a destructured parameter.
          let inner = unit.skipBalanced(i) - 1
          var j = i + 1
          var index: Int32 = 0
          while j < inner {
            if unit.ktIsName(j) {
              params.append(Int32(j))
              add(Int32(j), from: Int32(j), to: Int32(close), kind: .lambdaComponent(brace: Int32(brace), position: position, index: index))
            }
            while j < inner, !unit.isByte(j, 0x2C) { j += 1 }
            j += 1
            index += 1
          }
        } else if unit.ktIsName(i) {
          params.append(Int32(i))
          if unit.isToken(i + 1, ":"), let typeEnd = unit.ktTypeEnd(i + 2, limit: end) {
            add(Int32(i), from: Int32(i), to: Int32(close), kind: .typed(Int32(i + 2), Int32(typeEnd), variadic: false))
          } else {
            add(Int32(i), from: Int32(i), to: Int32(close), kind: .lambda(brace: Int32(brace), index: position))
          }
        }
        position += 1
        i = end + 1
      }
    }
    lambdas[Int32(brace)] = (params, Int32(close), plain && arrow > 0)
    scan(plain && arrow > 0 ? arrow + 1 : brace + 1, close, blockEnd: Int32(close))
  }

  /// `val x: T = e`, `var x by d`, `val (a, b) = e`: the names, seen to the end of the block.
  private func declaration(_ at: Int, to: Int, blockEnd: Int32) -> Int {
    var i = at + 1
    if unit.isByte(i, 0x28) {
      let close = unit.skipBalanced(i) - 1
      var names: [(Int, Int32)] = []
      var k = i + 1
      var index: Int32 = 0
      while k < close {
        if unit.ktIsName(k) { names.append((k, index)) }
        while k < close, !unit.isByte(k, 0x2C) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
        k += 1
        index += 1
      }
      i = close + 1
      if unit.isToken(i, ":"), let typeEnd = unit.ktTypeEnd(i + 1, limit: to) { i = typeEnd }
      guard unit.isToken(i, "=") else { return i }
      let start = i + 1
      let end = unit.ktExpressionEnd(start, limit: to)
      for (token, position) in names {
        add(Int32(token), from: Int32(end), to: blockEnd, kind: .component(Int32(start), Int32(end), index: position, ofElement: false))
      }
      scan(start, end, blockEnd: blockEnd)
      return end
    }
    guard unit.ktIsName(i) else { return at + 1 }
    let nameToken = i
    i += 1
    var kind: KotlinLocalKind = .typed(-1, -1, variadic: false)
    if unit.isToken(i, ":"), let typeEnd = unit.ktTypeEnd(i + 1, limit: to) {
      kind = .typed(Int32(i + 1), Int32(typeEnd), variadic: false)
      i = typeEnd
    }
    if unit.isToken(i, "=") || unit.isToken(i, "by") {
      let isDelegate = unit.isToken(i, "by")
      let start = i + 1
      let end = unit.ktExpressionEnd(start, limit: to)
      if case .typed(let s, _, _) = kind, s >= 0 {} else { kind = isDelegate ? .delegated(Int32(start), Int32(end)) : .inferred(Int32(start), Int32(end)) }
      // Its own initializer doesn't see it: `val service = service()` calls the function.
      add(Int32(nameToken), from: Int32(end), to: blockEnd, kind: kind)
      scan(start, end, blockEnd: blockEnd)
      return end
    }
    add(Int32(nameToken), from: Int32(nameToken), to: blockEnd, kind: kind)
    return i
  }

  /// The end of what a header's `(…)` governs: its block, or its one statement.
  private func governedEnd(_ close: Int, blockEnd: Int32) -> Int32 {
    let next = close + 1
    if unit.isByte(next, 0x7B) { return Int32(unit.skipBalanced(next) - 1) }
    let end = min(unit.ktExpressionEnd(next, limit: Int(blockEnd)), Int(blockEnd))
    // `if (x is T) a else b`: the branch ends before its `else`.
    var k = next
    while k < end {
      if unit.isToken(k, "else") { return Int32(k - 1) }
      k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
    }
    return Int32(end)
  }

  /// `for (x in e)`, `for ((k, v) in e)`, `for (x: T in e)`.
  private func forHeader(_ open: Int, _ close: Int, blockEnd: Int32) {
    var inToken = open + 1
    while inToken < close, !unit.isToken(inToken, "in") { inToken = unit.tokens[inToken].kind == .open ? unit.skipBalanced(inToken) : inToken + 1 }
    guard inToken < close else { return }
    let scopeEnd = governedEnd(close, blockEnd: blockEnd)
    let start = Int32(inToken + 1)
    let end = Int32(close)
    if unit.isByte(open + 1, 0x28) {
      let inner = unit.skipBalanced(open + 1) - 1
      var k = open + 2
      var index: Int32 = 0
      while k < inner {
        if unit.ktIsName(k) { add(Int32(k), from: Int32(k), to: scopeEnd, kind: .component(start, end, index: index, ofElement: true)) }
        while k < inner, !unit.isByte(k, 0x2C) { k += 1 }
        k += 1
        index += 1
      }
      return
    }
    guard unit.ktIsName(open + 1) else { return }
    if unit.isToken(open + 2, ":"), let typeEnd = unit.ktTypeEnd(open + 3, limit: inToken) {
      add(Int32(open + 1), from: Int32(open + 1), to: scopeEnd, kind: .typed(Int32(open + 3), Int32(typeEnd), variadic: false))
      return
    }
    add(Int32(open + 1), from: Int32(open + 1), to: scopeEnd, kind: .element(start, end))
  }

  /// `catch (e: T)`.
  private func catchParameter(_ open: Int, _ close: Int) {
    guard unit.ktIsName(open + 1), unit.isToken(open + 2, ":") else { return }
    let blockEnd = unit.isByte(close + 1, 0x7B) ? Int32(unit.skipBalanced(close + 1) - 1) : Int32(close + 1)
    add(Int32(open + 1), from: Int32(open + 1), to: blockEnd, kind: .typed(Int32(open + 3), Int32(close), variadic: false))
  }

  /// `when (val x = e) { … }`, and the casts its `is` branches make on its subject.
  private func whenSubject(_ open: Int, _ close: Int) {
    let bodyEnd: Int32 = unit.isByte(close + 1, 0x7B) ? Int32(unit.skipBalanced(close + 1) - 1) : Int32(close + 1)
    var subject: Name?
    if unit.isToken(open + 1, "val"), unit.ktIsName(open + 2) {
      var kind: KotlinLocalKind = .inferred(-1, -1)
      var k = open + 3
      if unit.isToken(k, ":"), let typeEnd = unit.ktTypeEnd(k + 1, limit: close) {
        kind = .typed(Int32(k + 1), Int32(typeEnd), variadic: false)
        k = typeEnd
      }
      if unit.isToken(k, "="), case .inferred = kind { kind = .inferred(Int32(k + 1), Int32(close)) }
      add(Int32(open + 2), from: Int32(open + 2), to: bodyEnd, kind: kind)
      subject = unit.hash(open + 2)
    } else if unit.ktIsName(open + 1), close == open + 2 {
      subject = unit.hash(open + 1)
    } else if unit.isToken(open + 1, "this"), close == open + 2 {
      subject = KotlinWord.this
    }
    guard let subject, unit.isByte(close + 1, 0x7B) else { return }
    // `is T ->` branches.
    var k = close + 2
    let end = Int(bodyEnd)
    while k < end {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.isToken(k, "is"), isBranchStart(k), let typeEnd = unit.ktTypeEnd(k + 1, limit: end) {
        var arrow = typeEnd
        while arrow < end, !unit.isToken(arrow, "->") { arrow = unit.tokens[arrow].kind == .open ? unit.skipBalanced(arrow) : arrow + 1 }
        // `is A, is B ->` casts to neither.
        if arrow == typeEnd {
          let branchEnd = branchBodyEnd(arrow + 1, limit: end)
          casts.append(KotlinCast(name: subject, typeStart: Int32(k + 1), typeEnd: Int32(typeEnd), scopeStart: Int32(arrow), scopeEnd: Int32(branchEnd)))
        }
        k = arrow
        continue
      }
      k += 1
    }
  }

  private func isBranchStart(_ k: Int) -> Bool { unit.startsLine(k) || unit.isByte(k - 1, 0x7B) || unit.isByte(k - 1, 0x3B) }

  /// A `when` branch's body after its `->`: a block, or the expression up to the line's end.
  private func branchBodyEnd(_ start: Int, limit: Int) -> Int {
    if unit.isByte(start, 0x7B) { return unit.skipBalanced(start) }
    var k = start
    while k < limit {
      if k > start, unit.startsLine(k) { return k }
      if unit.tokens[k].kind == .close { return k }
      k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
    }
    return limit
  }

  /// `if (x is T && …) …`: x is T in the rest of the condition and the branch; `if (x !is T) return`: in the rest of
  /// the block; `if (x !is T) … else …`: in the `else`; `when { x is T -> … }` is read by its branches below.
  private func conditionCasts(_ open: Int, _ close: Int, blockEnd: Int32) {
    var k = open + 1
    var hasOr = false
    var hasAnd = false
    var scanK = open + 1
    while scanK < close {
      if unit.tokens[scanK].kind == .open {
        scanK = unit.skipBalanced(scanK)
        continue
      }
      if unit.isToken(scanK, "||") { hasOr = true }
      if unit.isToken(scanK, "&&") { hasAnd = true }
      scanK += 1
    }
    while k < close {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      // `x is T`, or `x !is T` (the lexer gives `!` and `is` apart).
      let negated = unit.isToken(k, "is") && unit.isToken(k - 1, "!") && unit.touchesPrevious(k)
      let operand = negated ? k - 2 : k - 1
      if unit.isToken(k, "is"), operand > open, unit.ktIsName(operand) || unit.isToken(operand, "this"), !unit.ktIsDot(operand - 1),
        let typeEnd = unit.ktTypeEnd(k + 1, limit: close)
      {
        let subject = unit.isToken(operand, "this") ? KotlinWord.this : unit.hash(operand)
        if !negated, !hasOr {
          casts.append(KotlinCast(name: subject, typeStart: Int32(k + 1), typeEnd: Int32(typeEnd), scopeStart: Int32(typeEnd), scopeEnd: Int32(close)))
          let branchEnd = governedEnd(close, blockEnd: blockEnd)
          casts.append(KotlinCast(name: subject, typeStart: Int32(k + 1), typeEnd: Int32(typeEnd), scopeStart: Int32(close), scopeEnd: branchEnd + 1))
        } else if negated, !hasAnd {
          let branchEnd = Int(governedEnd(close, blockEnd: blockEnd))
          if unit.isToken(branchEnd + 1, "else") {
            // `if (x !is T) … else …`: x is T in the `else` branch.
            let elseEnd = governedEnd(branchEnd + 1, blockEnd: blockEnd)
            casts.append(KotlinCast(name: subject, typeStart: Int32(k + 1), typeEnd: Int32(typeEnd), scopeStart: Int32(branchEnd + 1), scopeEnd: elseEnd + 1))
          } else if exits(close + 1) {
            // `if (x !is T) return`: in the rest of the block.
            casts.append(KotlinCast(name: subject, typeStart: Int32(k + 1), typeEnd: Int32(typeEnd), scopeStart: Int32(branchEnd + 1), scopeEnd: blockEnd))
          }
        }
        k = typeEnd
        continue
      }
      k += 1
    }
  }

  /// Whether a branch always leaves: `return`, `throw`, `continue`, `break`, or a block that ends in one.
  private func exits(_ start: Int) -> Bool {
    if unit.isToken(start, "return") || unit.isToken(start, "throw") || unit.isToken(start, "continue") || unit.isToken(start, "break") { return true }
    guard unit.isByte(start, 0x7B) else { return false }
    let close = unit.skipBalanced(start) - 1
    var k = close - 1
    while k > start, !unit.startsLine(k) { k -= 1 }
    return unit.isToken(k, "return") || unit.isToken(k, "throw") || unit.isToken(k, "continue") || unit.isToken(k, "break")
  }
}
