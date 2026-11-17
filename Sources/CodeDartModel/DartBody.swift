import CodeModel
import CodeScan
import Foundation

/// How a local's type is told.
enum DartLocalKind {
  /// Written: `int x`, `final Foo x`.
  case typed(Int32, Int32)
  /// From its initializer: `var x = …`, `final x = …`.
  case inferred(Int32, Int32)
  /// An element of what a `for (… in e)` walks (`await for`: a stream's).
  case element(Int32, Int32, isAwait: Bool)
  /// A closure's parameter without a type: from the function type it's passed as (the closure's `(`, which one).
  case closure(Int32, Int32)
  /// `catch (e)` after `on T`: T (else Object); `catch (e, s)`'s s: StackTrace.
  case caught(Int32, Int32)
  case stackTrace
  /// A local function (its name), typed by its declaration from the token.
  case function(Int32)
  /// A parameter of the declaration that owns the body (its index).
  case parameter(Int32)
  case unknown
}

struct DartLocal {
  var name: Name
  var token: Int32
  /// Where it can be seen: from `token` (or `scopeStart` when earlier, a parameter) to `scopeEnd`, exclusive.
  var scopeStart: Int32
  var scopeEnd: Int32
  var kind: DartLocalKind
}

/// `x is T` holding from `start` to `end`: x's type there is T (when x is the local named at `subject`).
struct DartNarrowing {
  var subject: Int32
  var name: Name
  var typeStart: Int32
  var typeEnd: Int32
  var start: Int32
  var end: Int32
}

/// What one declaration's body declares: its parameters, locals, closures' parameters, local functions, pattern
/// variables, and where an `is` check narrows a local. Scanned once, when a question first lands in it.
final class DartBody: BodyFacts {
  let owner: Int32
  var locals: [DartLocal] = []
  var byToken: [Int32: Int32] = [:]
  var narrowings: [DartNarrowing] = []
  var types: [Int32: Ty] = [:]
  var resolving: Set<Int32> = []
  /// Closures by their parameters' `(`: the range of their body (`{…}` or the arrow's expression).
  var closures: [Int32: (start: Int32, end: Int32)] = [:]
  private let unit: Unit

  func dropTypes() { types.removeAll() }

  init(unit: Unit, owner: Int32) {
    self.unit = unit
    self.owner = owner
    let decl = unit.decls[Int(owner)]
    let start = Int(decl.first)
    let end = min(Int(decl.end), unit.tokens.count)
    // The owner's parameters: initializing formals (`this.x`) only in the initializer list.
    for p in 0..<Int(decl.paramCount) {
      let param = unit.params[Int(decl.paramStart) + p]
      let isFormal = param.nameToken >= 2 && unit.isByte(Int(param.nameToken) - 1, 0x2E)
      var scopeEnd = Int32(end)
      var scopeStart = Int32(start)
      if isFormal {
        scopeStart = decl.initStart >= 0 ? decl.initStart : param.nameToken
        scopeEnd = decl.initStart >= 0 ? decl.initEnd : param.nameToken
      }
      add(DartLocal(name: param.local, token: param.nameToken, scopeStart: scopeStart, scopeEnd: scopeEnd, kind: .parameter(Int32(p))))
    }
    var from = start
    if decl.kind == .variable, decl.initStart >= 0, decl.bodyOpen < 0 { from = Int(decl.initStart) }
    if decl.kind == .enumCase, decl.initStart >= 0 { from = Int(decl.initStart) }
    // A nested declaration's own body is its own (a type's member, scanned with the member).
    scan(from: from, to: end, blockEnd: Int32(end))
    locals.sort { $0.token < $1.token }
    byToken.removeAll()
    for (index, local) in locals.enumerated() { byToken[local.token] = Int32(index) }
  }

  private func add(_ local: DartLocal) {
    if byToken[local.token] != nil { return }
    byToken[local.token] = Int32(locals.count)
    locals.append(local)
  }

  /// The local a name means at a token: the innermost one seen there.
  func local(named word: Name, at token: Int32) -> Int32? {
    var best: Int32?
    var bestStart: Int32 = -1
    for (index, local) in locals.enumerated() where local.name == word {
      let visibleFrom = min(local.token, local.scopeStart)
      guard token >= visibleFrom, token < local.scopeEnd else { continue }
      // A local isn't seen before its declaration, except a parameter (its scope starts before it).
      if local.token > token, case .parameter = local.kind {} else if local.token > token { continue }
      let start = max(local.scopeStart, visibleFrom)
      if start > bestStart || start == bestStart && local.token > (best.map { locals[Int($0)].token } ?? -1) {
        best = Int32(index)
        bestStart = start
      }
    }
    return best
  }

  /// Every local seen at a token, innermost last.
  func visible(at token: Int32) -> [Int32] {
    var result: [Int32] = []
    for (index, local) in locals.enumerated() {
      let visibleFrom = min(local.token, local.scopeStart)
      guard token >= visibleFrom, token < local.scopeEnd else { continue }
      if local.token > token, case .parameter = local.kind {} else if local.token >= token { continue }
      result.append(Int32(index))
    }
    return result
  }

  /// The innermost narrowing of a local named so around a token.
  func narrowing(of word: Name, at token: Int32) -> DartNarrowing? {
    var best: DartNarrowing?
    for item in narrowings where item.name == word && item.start <= token && token < item.end {
      if best == nil || item.start >= best!.start { best = item }
    }
    return best
  }

  // MARK: Scanning

  private func isName(_ i: Int) -> Bool { unit.daIsName(i) }

  /// Whether a statement starts at `i`.
  private func startsStatement(_ i: Int, from: Int) -> Bool {
    guard i > from else { return i == from }
    let previous = i - 1
    if unit.isByte(previous, 0x7B) || unit.isByte(previous, 0x7D) || unit.isByte(previous, 0x3B) { return true }
    if unit.isToken(previous, "else") || unit.isToken(previous, "do") { return true }
    if unit.isByte(previous, 0x3A) {
      // After a `case …:` or `default:`, not a named argument's or a conditional's.
      var k = previous - 1
      var budget = 60
      while k >= from, budget > 0 {
        budget -= 1
        if unit.tokens[k].kind == .close, let open = unit.matchingOpen(k) {
          k = open - 1
          continue
        }
        if unit.isToken(k, "case") || unit.isToken(k, "default") { return true }
        if unit.isByte(k, 0x3B) || unit.isByte(k, 0x7B) || unit.isByte(k, 0x7D) || unit.tokens[k].kind == .open || unit.isByte(k, 0x2C) || unit.isByte(k, 0x3F) { return false }
        k -= 1
      }
      return false
    }
    if unit.isByte(previous, 0x29), let open = unit.matchingOpen(previous) {
      return unit.isToken(open - 1, "if") || unit.isToken(open - 1, "for") || unit.isToken(open - 1, "while")
    }
    return false
  }

  /// The end of the statement starting at `i` (exclusive), within `limit`.
  private func statementEnd(_ i: Int, limit: Int) -> Int {
    if unit.isByte(i, 0x7B) { return min(limit, unit.skipBalanced(i)) }
    if unit.isToken(i, "if") || unit.isToken(i, "for") || unit.isToken(i, "while"), unit.isByte(i + 1, 0x28) {
      let afterHeader = unit.skipBalanced(i + 1)
      var end = statementEnd(afterHeader, limit: limit)
      if unit.isToken(i, "if"), unit.isToken(end, "else") { end = statementEnd(end + 1, limit: limit) }
      return end
    }
    if unit.isToken(i, "await"), unit.isToken(i + 1, "for") { return statementEnd(i + 1, limit: limit) }
    if unit.isToken(i, "switch"), unit.isByte(i + 1, 0x28) {
      let afterHeader = unit.skipBalanced(i + 1)
      if unit.isByte(afterHeader, 0x7B) { return min(limit, unit.skipBalanced(afterHeader)) }
    }
    if unit.isToken(i, "do") {
      var end = statementEnd(i + 1, limit: limit)
      while end < limit, !unit.isByte(end, 0x3B) { end = unit.tokens[end].kind == .open ? unit.skipBalanced(end) : end + 1 }
      return min(limit, end + 1)
    }
    if unit.isToken(i, "try") {
      var end = statementEnd(i + 1, limit: limit)
      while end < limit {
        if unit.isToken(end, "on") {
          var k = end + 1
          while k < limit, !unit.isByte(k, 0x7B), !unit.isToken(k, "catch") { k += 1 }
          if unit.isToken(k, "catch") { k = unit.skipBalanced(k + 1) }
          end = statementEnd(k, limit: limit)
        } else if unit.isToken(end, "catch") {
          end = statementEnd(unit.skipBalanced(end + 1), limit: limit)
        } else if unit.isToken(end, "finally") {
          end = statementEnd(end + 1, limit: limit)
        } else {
          break
        }
      }
      return end
    }
    var k = i
    while k < limit, !unit.isByte(k, 0x3B) {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.tokens[k].kind == .close { return k }
      k += 1
    }
    return min(limit, k + 1)
  }

  /// Walks a range: declarations at statement starts, `for`, `catch`, closures, patterns and `is` checks.
  private func scan(from: Int, to: Int, blockEnd: Int32) {
    var blocks: [Int32] = [blockEnd]
    var i = from
    while i < to {
      while blocks.count > 1, Int32(i) >= blocks.last! { blocks.removeLast() }
      let scopeEnd = blocks.last!
      let token = unit.tokens[i]
      if token.kind == .open, unit.isByte(i, 0x7B) {
        blocks.append(Int32(unit.skipBalanced(i) - 1))
        i += 1
        continue
      }
      if token.kind == .open, unit.isByte(i, 0x28), let next = closure(i, limit: to) {
        _ = next
        i += 1
        continue
      }
      if unit.isToken(i, "for"), unit.isByte(i + 1, 0x28) {
        forHeader(i, limit: to)
        i += 2
        continue
      }
      if unit.isToken(i, "catch"), unit.isByte(i + 1, 0x28) {
        catchClause(i, limit: to)
        i += 2
        continue
      }
      if unit.isToken(i, "if"), unit.isByte(i + 1, 0x28) {
        ifStatement(i, limit: to, scopeEnd: scopeEnd)
        i += 2
        continue
      }
      if unit.isToken(i, "case") {
        casePattern(i, limit: to)
        i += 1
        continue
      }
      if unit.isToken(i, "switch"), unit.isByte(i + 1, 0x28) {
        switchNarrowing(i, limit: to)
        switchArms(i)
        i += 2
        continue
      }
      if unit.isToken(i, "is") { expressionNarrowing(i, limit: to) }
      if startsStatement(i, from: from) {
        if let next = localDeclaration(i, limit: to, scopeEnd: scopeEnd) {
          i = next
          continue
        }
      }
      i += 1
    }
  }

  /// A declaration statement at `i`: variables (a pattern too) or a local function. The token to go on from (inside
  /// initializers, which are scanned too), nil when there's none.
  private func localDeclaration(_ at: Int, limit: Int, scopeEnd: Int32) -> Int? {
    var i = at
    var isVarLike = false
    if unit.isToken(i, "await") || unit.isToken(i, "yield") || unit.isToken(i, "return") { return nil }
    while unit.isToken(i, "late") || unit.isToken(i, "final") || unit.isToken(i, "const") || unit.isToken(i, "var") {
      isVarLike = true
      i += 1
    }
    if isVarLike, unit.isByte(i, 0x28) || unit.isByte(i, 0x5B) || unit.isByte(i, 0x7B) {
      // `var (a, b) = …`: a pattern.
      let close = unit.skipBalanced(i)
      for name in patternVariables(i, close, declaring: true) {
        add(DartLocal(name: unit.hash(name), token: Int32(name), scopeStart: Int32(name), scopeEnd: scopeEnd, kind: .unknown))
      }
      return close
    }
    var typeStart = -1
    var typeEnd = -1
    var nameAt = i
    if isName(i), unit.isToken(i + 1, "=") || unit.isByte(i + 1, 0x3B) || unit.isByte(i + 1, 0x2C) {
      guard isVarLike else { return nil }
    } else if let end = unit.daTypeEnd(i, limit: limit), end > i, isName(end) {
      typeStart = i
      typeEnd = end
      nameAt = end
    } else if isName(i), unit.isByte(i + 1, 0x28) || unit.startsWith(i + 1, 0x3C) && unit.tokens[i + 1].kind == .punctuation {
      nameAt = i
    } else {
      return nil
    }
    // A local function: `name(…) {`, `T name<U>(…) =>`.
    var k = nameAt + 1
    if unit.tokens.indices.contains(k), unit.tokens[k].kind == .punctuation, unit.startsWith(k, 0x3C), let after = unit.daTypeArgumentsEnd(k, limit: limit) { k = after }
    if unit.isByte(k, 0x28), !isVarLike {
      let close = unit.skipBalanced(k)
      var bodyAt = close
      if unit.isToken(bodyAt, "async") || unit.isToken(bodyAt, "sync") {
        bodyAt += 1
        if unit.isByte(bodyAt, 0x2A) { bodyAt += 1 }
      }
      guard unit.isByte(bodyAt, 0x7B) || unit.isToken(bodyAt, "=>") else { return nil }
      add(DartLocal(name: unit.hash(nameAt), token: Int32(nameAt), scopeStart: Int32(nameAt), scopeEnd: scopeEnd, kind: .function(Int32(nameAt))))
      let bodyEnd = unit.isByte(bodyAt, 0x7B) ? unit.skipBalanced(bodyAt) : unit.daExpressionEnd(bodyAt + 1, limit: limit)
      parameters(k, close: close - 1, scopeStart: Int32(k), scopeEnd: Int32(bodyEnd), closure: nil)
      return k + 1
    }
    guard typeStart >= 0 || isVarLike else { return nil }
    // Variables: `a = 1, b`.
    var n = nameAt
    while n < limit, isName(n) {
      var end = n + 1
      var kind = DartLocalKind.unknown
      if typeStart >= 0 { kind = .typed(Int32(typeStart), Int32(typeEnd)) }
      if unit.isToken(end, "=") {
        let initEnd = unit.daExpressionEnd(end + 1, limit: limit)
        if typeStart < 0 { kind = .inferred(Int32(end + 1), Int32(initEnd)) }
        end = initEnd
      } else if !(unit.isByte(end, 0x3B) || unit.isByte(end, 0x2C)) {
        return n == nameAt ? nil : n
      }
      add(DartLocal(name: unit.hash(n), token: Int32(n), scopeStart: Int32(n), scopeEnd: scopeEnd, kind: kind))
      if unit.isToken(n + 1, "=") {
        // Its initializer: closures and other declarations inside it are scanned as the walk goes on.
        return n + 1 + scanInitializerUntilComma(n + 2, end: end, limit: limit, typeStart: typeStart, typeEnd: typeEnd, scopeEnd: scopeEnd)
      }
      guard unit.isByte(end, 0x2C) else { return end }
      n = end + 1
    }
    return n
  }

  /// The rest of a declaration list after one initializer: further names are declared as the walk reaches them.
  /// Returns how many tokens to skip from `n + 2` (none: the walk goes through the initializer).
  private func scanInitializerUntilComma(_ from: Int, end: Int, limit: Int, typeStart: Int, typeEnd: Int, scopeEnd: Int32) -> Int {
    // Further names after a `,`: declared now, their initializers walked as code.
    var n = end
    while unit.isByte(n, 0x2C), isName(n + 1) {
      let nameToken = n + 1
      var kind = DartLocalKind.unknown
      if typeStart >= 0 { kind = .typed(Int32(typeStart), Int32(typeEnd)) }
      var next = nameToken + 1
      if unit.isToken(next, "=") {
        let initEnd = unit.daExpressionEnd(next + 1, limit: limit)
        if typeStart < 0 { kind = .inferred(Int32(next + 1), Int32(initEnd)) }
        next = initEnd
      }
      add(DartLocal(name: unit.hash(nameToken), token: Int32(nameToken), scopeStart: Int32(nameToken), scopeEnd: scopeEnd, kind: kind))
      n = next
    }
    return 0
  }

  /// Parameters of a closure or local function between `open` and `close`: `a`, `int a`, `[a]`, `{a}`.
  private func parameters(_ open: Int, close: Int, scopeStart: Int32, scopeEnd: Int32, closure: Int32?) {
    var i = open + 1
    var position: Int32 = 0
    while i < close {
      if unit.isByte(i, 0x5B) || unit.isByte(i, 0x7B) || unit.isByte(i, 0x5D) || unit.isByte(i, 0x7D) || unit.isByte(i, 0x2C) {
        i += 1
        continue
      }
      var end = i
      while end < close, !unit.isByte(end, 0x2C), !unit.isByte(end, 0x5D), !unit.isByte(end, 0x7D) {
        // `Map<String, int> m`: the type arguments' commas aren't the parameters'.
        if unit.tokens[end].kind == .punctuation, unit.startsWith(end, 0x3C), let after = unit.daTypeArgumentsEnd(end, limit: close) {
          end = after
          continue
        }
        end = unit.tokens[end].kind == .open && !unit.isByte(end, 0x7B) && !unit.isByte(end, 0x5B) ? unit.skipBalanced(end) : end + 1
      }
      var k = unit.daSkipMetadata(i, limit: end)
      while k < end, unit.isToken(k, "required") || unit.isToken(k, "final") || unit.isToken(k, "covariant") || unit.isToken(k, "var") { k += 1 }
      var defaultAt = end
      var j = k
      while j < end {
        if unit.isToken(j, "=") || unit.isByte(j, 0x3A) {
          defaultAt = j
          break
        }
        j = unit.tokens[j].kind == .open ? unit.skipBalanced(j) : j + 1
      }
      var nameToken = -1
      var kind = DartLocalKind.unknown
      if isName(k), k + 1 == defaultAt {
        nameToken = k
        if let closure { kind = .closure(closure, position) }
      } else if let typeEnd = unit.daTypeEnd(k, limit: defaultAt), isName(typeEnd) {
        nameToken = typeEnd
        kind = .typed(Int32(k), Int32(typeEnd))
        if unit.isByte(typeEnd + 1, 0x28) { kind = .typed(Int32(k), Int32(defaultAt)) }
      } else if isName(k) {
        nameToken = k
      }
      if nameToken >= 0 {
        add(DartLocal(name: unit.hash(nameToken), token: Int32(nameToken), scopeStart: scopeStart, scopeEnd: scopeEnd, kind: kind))
      }
      position += 1
      i = end
    }
  }

  /// A closure's parameters at `(` when a body follows them; the body's end.
  @discardableResult
  private func closure(_ open: Int, limit: Int) -> Int? {
    // Not a call's or a header's arguments: what's before the `(` isn't a name, a `)`, `]` or `>`.
    if open > 0 {
      let previous = open - 1
      if isName(previous) || unit.isByte(previous, 0x29) || unit.isByte(previous, 0x5D) || unit.tokens[previous].kind == .punctuation && unit.source.text[unit.tokens[previous].end - 1] == 0x3E && !unit.isToken(previous, "=>") {
        return nil
      }
      if unit.tokens[previous].kind == .keyword || unit.tokens[previous].kind == .declarationKeyword,
        unit.isToken(previous, "if") || unit.isToken(previous, "for") || unit.isToken(previous, "while") || unit.isToken(previous, "switch")
          || unit.isToken(previous, "catch") || unit.isToken(previous, "super") || unit.isToken(previous, "this") || unit.isToken(previous, "assert")
      {
        return nil
      }
    }
    let close = unit.skipBalanced(open)
    var bodyAt = close
    if unit.isToken(bodyAt, "async") || unit.isToken(bodyAt, "sync") {
      bodyAt += 1
      if unit.isByte(bodyAt, 0x2A) { bodyAt += 1 }
    }
    let bodyEnd: Int
    if unit.isByte(bodyAt, 0x7B) {
      bodyEnd = unit.skipBalanced(bodyAt)
    } else if unit.isToken(bodyAt, "=>") {
      bodyEnd = unit.daExpressionEnd(bodyAt + 1, limit: limit)
    } else {
      return nil
    }
    closures[Int32(open)] = (Int32(bodyAt), Int32(bodyEnd))
    parameters(open, close: close - 1, scopeStart: Int32(open), scopeEnd: Int32(bodyEnd), closure: Int32(open))
    return bodyEnd
  }

  /// `for (var x in e)`, `for (final (a, b) in e)`, `for (T x in e)`, `for (var i = 0; …)`: locals of the statement.
  private func forHeader(_ at: Int, limit: Int) {
    let open = at + 1
    let close = unit.skipBalanced(open) - 1
    let end = Int32(statementEnd(at, limit: limit))
    let isAwait = unit.isToken(at - 1, "await")
    var i = open + 1
    while unit.isToken(i, "final") || unit.isToken(i, "var") || unit.isToken(i, "late") || unit.isToken(i, "const") { i += 1 }
    let isVarLike = i > open + 1
    // `in`: one variable (or a pattern) and what it walks.
    var inAt = -1
    var k = i
    while k < close {
      if unit.isToken(k, "in") {
        inAt = k
        break
      }
      if unit.isByte(k, 0x3B) { break }
      k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
    }
    if inAt >= 0 {
      if isVarLike, unit.isByte(i, 0x28) || unit.isByte(i, 0x5B) || unit.isByte(i, 0x7B) {
        for name in patternVariables(i, inAt, declaring: true) {
          add(DartLocal(name: unit.hash(name), token: Int32(name), scopeStart: Int32(name), scopeEnd: end, kind: .unknown))
        }
        return
      }
      if isName(i), i + 1 == inAt {
        add(DartLocal(name: unit.hash(i), token: Int32(i), scopeStart: Int32(i), scopeEnd: end, kind: .element(Int32(inAt + 1), Int32(close), isAwait: isAwait)))
      } else if let typeEnd = unit.daTypeEnd(i, limit: inAt), typeEnd + 1 == inAt, isName(typeEnd) {
        add(DartLocal(name: unit.hash(typeEnd), token: Int32(typeEnd), scopeStart: Int32(typeEnd), scopeEnd: end, kind: .typed(Int32(i), Int32(typeEnd))))
      }
      return
    }
    // `for (init; cond; update)`: the initializer's variables.
    var typeStart = -1
    var typeEnd = -1
    var n = i
    if !(isName(i) && (unit.isToken(i + 1, "=") || unit.isByte(i + 1, 0x2C) || unit.isByte(i + 1, 0x3B))), let end2 = unit.daTypeEnd(i, limit: close), isName(end2) {
      typeStart = i
      typeEnd = end2
      n = end2
    } else if !isVarLike {
      return
    }
    while n < close, isName(n) {
      var kind = DartLocalKind.unknown
      if typeStart >= 0 { kind = .typed(Int32(typeStart), Int32(typeEnd)) }
      var next = n + 1
      if unit.isToken(next, "=") {
        let initEnd = unit.daExpressionEnd(next + 1, limit: close)
        if typeStart < 0 { kind = .inferred(Int32(next + 1), Int32(initEnd)) }
        next = initEnd
      }
      add(DartLocal(name: unit.hash(n), token: Int32(n), scopeStart: Int32(n), scopeEnd: end, kind: kind))
      guard unit.isByte(next, 0x2C) else { break }
      n = next + 1
    }
  }

  /// `on T catch (e, s) { … }`: e and s in the block.
  private func catchClause(_ at: Int, limit: Int) {
    let open = at + 1
    let close = unit.skipBalanced(open)
    guard unit.isByte(close, 0x7B) else { return }
    let end = Int32(unit.skipBalanced(close))
    var typeRange: (Int32, Int32) = (-1, -1)
    // `on T catch`: T is between `on` and `catch`.
    var k = at - 1
    var budget = 40
    while k > 0, budget > 0, !unit.isToken(k, "on"), isName(k) || unit.isByte(k, 0x2E) || unit.tokens[k].kind == .punctuation && !unit.isByte(k, 0x3B) {
      budget -= 1
      k -= 1
    }
    if unit.isToken(k, "on"), k < at - 1 { typeRange = (Int32(k + 1), Int32(at)) }
    var position = 0
    var i = open + 1
    while i < close - 1 || i == close - 1 && isName(i) {
      if isName(i) {
        let kind: DartLocalKind = position == 0 ? .caught(typeRange.0, typeRange.1) : .stackTrace
        add(DartLocal(name: unit.hash(i), token: Int32(i), scopeStart: Int32(close), scopeEnd: end, kind: kind))
        position += 1
      }
      i += 1
    }
  }

  /// `if (x is T …)`: x is T in the branch; `if (x is! T) return;`: after the statement; `if (e case P)`: P's
  /// variables in the branch.
  private func ifStatement(_ at: Int, limit: Int, scopeEnd: Int32) {
    let open = at + 1
    let close = unit.skipBalanced(open) - 1
    let thenEnd = statementEnd(close + 1, limit: limit)
    var caseAt = -1
    var k = open + 1
    while k < close {
      if unit.isToken(k, "case") {
        caseAt = k
        break
      }
      k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
    }
    if caseAt >= 0 {
      var patternEnd = close
      var w = caseAt + 1
      while w < close {
        if unit.isToken(w, "when") {
          patternEnd = w
          break
        }
        w = unit.tokens[w].kind == .open ? unit.skipBalanced(w) : w + 1
      }
      for name in patternVariables(caseAt + 1, patternEnd, declaring: false) {
        add(DartLocal(name: unit.hash(name), token: Int32(name), scopeStart: Int32(name), scopeEnd: Int32(thenEnd), kind: .unknown))
      }
      // `if (x case T())`: x is T in the branch.
      if caseAt == open + 2, isName(open + 1), let typeEnd = unit.daTypeEnd(caseAt + 1, limit: patternEnd), unit.isByte(typeEnd, 0x28) || isName(typeEnd) {
        narrowings.append(DartNarrowing(subject: Int32(open + 1), name: unit.hash(open + 1), typeStart: Int32(caseAt + 1), typeEnd: Int32(typeEnd), start: Int32(close), end: Int32(thenEnd)))
      }
      return
    }
    // The checks joined by `&&` at the top of the condition.
    for check in conjunction(open + 1, close) where !check.negated {
      narrowings.append(DartNarrowing(subject: Int32(check.subject), name: unit.hash(check.subject), typeStart: Int32(check.typeStart), typeEnd: Int32(check.typeEnd), start: Int32(close), end: Int32(thenEnd)))
    }
    // `if (x is! T) return;`: the rest of the block.
    let checks = conjunction(open + 1, close)
    if checks.count == 1, checks[0].negated, exits(close + 1, thenEnd) {
      let check = checks[0]
      narrowings.append(DartNarrowing(subject: Int32(check.subject), name: unit.hash(check.subject), typeStart: Int32(check.typeStart), typeEnd: Int32(check.typeEnd), start: Int32(thenEnd), end: scopeEnd))
    }
  }

  /// `x is T` (and `x is! T`) checks of a condition joined by `&&` at its top, with no `||` there.
  private func conjunction(_ from: Int, _ to: Int) -> [(subject: Int, typeStart: Int, typeEnd: Int, negated: Bool)] {
    var result: [(subject: Int, typeStart: Int, typeEnd: Int, negated: Bool)] = []
    var k = from
    var operandStart = from
    while k < to {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.isToken(k, "||") || unit.isToken(k, "??") || unit.isByte(k, 0x3F) { return [] }
      if unit.isToken(k, "&&") {
        operandStart = k + 1
      } else if unit.isToken(k, "is"), k - 1 == operandStart, isName(k - 1) {
        let negated = unit.isByte(k + 1, 0x21)
        let typeStart = negated ? k + 2 : k + 1
        if let typeEnd = unit.daTypeEnd(typeStart, limit: to) {
          result.append((k - 1, typeStart, typeEnd, negated))
          k = typeEnd
          continue
        }
      }
      k += 1
    }
    return result
  }

  /// Whether a statement always leaves its block: `return`, `throw`, `continue`, `break`, or a block ending in one.
  private func exits(_ from: Int, _ end: Int) -> Bool {
    var start = from
    if unit.isByte(from, 0x7B) {
      // The last statement of the block.
      let close = end - 1
      var k = from + 1
      var last = k
      while k < close {
        last = k
        k = statementEnd(k, limit: close)
      }
      start = last
    }
    return unit.isToken(start, "return") || unit.isToken(start, "throw") || unit.isToken(start, "continue") || unit.isToken(start, "break") || unit.isToken(start, "rethrow")
  }

  /// `x is T && …` or `x is T ? a : b` in an expression: x is T on the right, or in the conditional's first branch.
  private func expressionNarrowing(_ isAt: Int, limit: Int) {
    guard isName(isAt - 1), !unit.daIsDot(isAt - 2) else { return }
    // `x is! T || x.f()`: x is T after the `||`.
    if unit.isByte(isAt + 1, 0x21) {
      guard let typeEnd = unit.daTypeEnd(isAt + 2, limit: limit), unit.isToken(typeEnd, "||") else { return }
      let end = unit.daExpressionEnd(typeEnd, limit: limit)
      narrowings.append(DartNarrowing(subject: Int32(isAt - 1), name: unit.hash(isAt - 1), typeStart: Int32(isAt + 2), typeEnd: Int32(typeEnd), start: Int32(typeEnd), end: Int32(end)))
      return
    }
    guard let typeEnd = unit.daTypeEnd(isAt + 1, limit: limit) else { return }
    let end = unit.daExpressionEnd(typeEnd, limit: limit)
    if unit.isToken(typeEnd, "&&") || unit.isByte(typeEnd, 0x3F) {
      narrowings.append(DartNarrowing(subject: Int32(isAt - 1), name: unit.hash(isAt - 1), typeStart: Int32(isAt + 1), typeEnd: Int32(typeEnd), start: Int32(typeEnd), end: Int32(end)))
    }
  }

  /// `switch (x) { case T(): … }`, `switch (x) { T() => … }`: x is T in that case.
  private func switchNarrowing(_ at: Int, limit: Int) {
    let open = at + 1
    let close = unit.skipBalanced(open) - 1
    guard close == open + 2, isName(open + 1), unit.isByte(close + 1, 0x7B) else { return }
    let subject = open + 1
    let bodyClose = unit.skipBalanced(close + 1) - 1
    var k = close + 2
    while k < bodyClose {
      var patternStart = k
      if unit.isToken(k, "case") { patternStart = k + 1 }
      if let typeEnd = unit.daTypeEnd(patternStart, limit: bodyClose), typeEnd > patternStart, unit.isByte(typeEnd, 0x28) || isName(typeEnd) && unit.isByte(typeEnd + 1, 0x3A) || unit.isToken(typeEnd, "=>") || unit.isByte(typeEnd, 0x3A) {
        // The case's body: to the next case (a statement switch) or the arm's end.
        var armEnd = k
        var depth = 0
        var m = patternStart
        while m < bodyClose {
          if unit.tokens[m].kind == .open {
            m = unit.skipBalanced(m)
            continue
          }
          if m > patternStart, unit.isToken(m, "case") || unit.isToken(m, "default") { break }
          if unit.isByte(m, 0x2C), depth == 0, unit.isToken(k, "case") == false { break }
          m += 1
        }
        armEnd = m
        _ = depth
        narrowings.append(DartNarrowing(subject: Int32(subject), name: unit.hash(subject), typeStart: Int32(patternStart), typeEnd: Int32(typeEnd), start: Int32(typeEnd), end: Int32(armEnd)))
        k = max(armEnd, k + 1)
        continue
      }
      k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
    }
  }

  /// A switch expression's arms, `P when g => e,`: P's variables in its guard and its expression.
  private func switchArms(_ at: Int) {
    let close = unit.skipBalanced(at + 1)
    guard unit.isByte(close, 0x7B) else { return }
    let bodyClose = unit.skipBalanced(close) - 1
    var k = close + 1
    while k < bodyClose {
      guard !unit.isToken(k, "case"), !unit.isToken(k, "default") else { return }
      var arrow = k
      while arrow < bodyClose, !unit.isToken(arrow, "=>") {
        if unit.isByte(arrow, 0x3B) { return }
        arrow = unit.tokens[arrow].kind == .open ? unit.skipBalanced(arrow) : arrow + 1
      }
      guard arrow < bodyClose else { return }
      var patternEnd = k
      while patternEnd < arrow, !unit.isToken(patternEnd, "when") { patternEnd = unit.tokens[patternEnd].kind == .open ? unit.skipBalanced(patternEnd) : patternEnd + 1 }
      let armEnd = unit.daExpressionEnd(arrow + 1, limit: bodyClose)
      for name in patternVariables(k, patternEnd, declaring: false) {
        var kind = DartLocalKind.unknown
        if name > k, name + 1 == patternEnd, let typeEnd = unit.daTypeEnd(k, limit: name), typeEnd == name { kind = .typed(Int32(k), Int32(name)) }
        add(DartLocal(name: unit.hash(name), token: Int32(name), scopeStart: Int32(name), scopeEnd: Int32(armEnd), kind: kind))
      }
      k = armEnd + 1
    }
  }

  /// `case P:` in a switch statement: P's variables to the next case.
  private func casePattern(_ at: Int, limit: Int) {
    var end = at + 1
    while end < limit, !unit.isByte(end, 0x3A) || unit.isByte(end - 1, 0x2C) || unit.isByte(end - 1, 0x28) {
      if unit.tokens[end].kind == .open {
        end = unit.skipBalanced(end)
        continue
      }
      if unit.isToken(end, "when") || unit.tokens[end].kind == .close { break }
      end += 1
    }
    let patternEnd = end
    while end < limit, !unit.isByte(end, 0x3A) { end = unit.tokens[end].kind == .open ? unit.skipBalanced(end) : end + 1 }
    // The case's statements: to the next `case`/`default` or the switch's `}`.
    var bodyEnd = end + 1
    while bodyEnd < limit, !unit.isToken(bodyEnd, "case"), !unit.isToken(bodyEnd, "default"), unit.tokens[bodyEnd].kind != .close {
      bodyEnd = unit.tokens[bodyEnd].kind == .open ? unit.skipBalanced(bodyEnd) : bodyEnd + 1
    }
    for name in patternVariables(at + 1, patternEnd, declaring: false) {
      var kind = DartLocalKind.unknown
      if name > at + 1, name + 1 == patternEnd, let typeEnd = unit.daTypeEnd(at + 1, limit: name), typeEnd == name { kind = .typed(Int32(at + 1), Int32(name)) }
      add(DartLocal(name: unit.hash(name), token: Int32(name), scopeStart: Int32(name), scopeEnd: Int32(bodyEnd), kind: kind))
    }
  }

  /// The variables a pattern declares: after `var`/`final` or a type, `:name` shorthand, and (when the pattern is a
  /// declaration's) bare names.
  private func patternVariables(_ from: Int, _ to: Int, declaring: Bool) -> [Int] {
    var result: [Int] = []
    var k = from
    while k < to {
      guard isName(k), !unit.isToken(k, "_"), !unit.daIsDot(k - 1), !unit.daIsDot(k + 1), !unit.isByte(k + 1, 0x28) else {
        k += 1
        continue
      }
      let next = k + 1
      if next < to, unit.isByte(next, 0x3A) {
        k += 1
        continue
      }
      let ends = next >= to || unit.isByte(next, 0x2C) || unit.isByte(next, 0x29) || unit.isByte(next, 0x5D) || unit.isByte(next, 0x7D) || unit.isToken(next, "=")
        || unit.isToken(next, "when") || unit.isToken(next, "=>") || unit.isToken(next, "in") || unit.isToken(next, "&&") || unit.isToken(next, "||")
      if unit.isToken(k - 1, "var") || unit.isToken(k - 1, "final") {
        result.append(k)
      } else if ends, isName(k - 1) || unit.isByte(k - 1, 0x3F) || unit.tokens[k - 1].kind == .punctuation && unit.source.text[unit.tokens[k - 1].end - 1] == 0x3E,
        !unit.isToken(k - 1, "as"), !unit.isToken(k - 1, "case")
      {
        // `int x`, `List<int> x`.
        result.append(k)
      } else if ends, declaring || unit.isByte(k - 1, 0x3A) && (unit.isByte(k - 2, 0x28) || unit.isByte(k - 2, 0x2C)) && declaring {
        result.append(k)
      }
      k += 1
    }
    return result
  }
}
