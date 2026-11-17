import CodeModel
import CodeScan
import Foundation

/// How a local's type is known.
enum CSharpLocalKind {
  /// A written type, by its tokens.
  case typed(Int32, Int32)
  /// `var x = e`: the initializer's tokens.
  case inferred(Int32, Int32)
  /// `foreach (var x in e)`, `from x in e`: what's iterated.
  case element(Int32, Int32)
  /// A lambda's parameter without a type: the lambda's `=>` and which parameter.
  case lambda(arrow: Int32, index: Int32)
  /// `e is var x`: the tested expression's tokens.
  case tested(Int32, Int32)
  /// `f(out var x)`: the call's `(` and which argument.
  case outArgument(open: Int32, position: Int32)
  /// A deconstruction's or a query continuation's: not told.
  case unknown
}

struct CSharpLocal {
  var name: Name
  var token: Int32
  var scopeStart: Int32
  var scopeEnd: Int32
  var kind: CSharpLocalKind
}

/// Layer 4 for C#: the locals a member's body declares (or an initializer's, or a type's primary constructor's) and
/// where each is visible, read once when a position inside asks: parameters (local functions' too), local variables
/// (`var`, `using`, `const`, deconstructions), `for`, `foreach`, `using` and `fixed` headers, catch variables, lambdas'
/// and anonymous methods' parameters, pattern variables (`is`, `case`, switch expression arms, property, positional and
/// list patterns), `out` variables, and query range variables (`from`, `let`, `join`, `into`). A local can't hide a
/// local of an enclosing scope, so the one declared last before a use, still in scope, is the one meant.
final class CSharpBody: BodyFacts {
  func dropTypes() { types.removeAll() }

  var locals: [CSharpLocal] = []
  var byName: [Name: [Int32]] = [:]
  var byToken: [Int32: Int32] = [:]
  /// Each lambda's `=>` → its parameters' tokens.
  var lambdas: [Int32: [Int32]] = [:]
  var types: [Int32: Ty] = [:]
  var resolving: Set<Int32> = []

  private let unit: Unit
  /// Local functions and types in this body, by their first token.
  private var localDecls: [Int32: Int32] = [:]

  init(unit: Unit, owner: Int32) {
    self.unit = unit
    guard owner >= 0, Int(owner) < unit.decls.count else { return }
    for index in unit.decls.indices where unit.decls[index].isLocal && (unit.decls[index].kind == .function || unit.decls[index].kind.isNominal) {
      localDecls[unit.decls[index].first] = Int32(index)
    }
    member(owner)
  }

  /// A member's parameters and body, or an initializer.
  private func member(_ index: Int32) {
    let decl = unit.decls[Int(index)]
    for p in 0..<Int(decl.paramCount) {
      let param = unit.params[Int(decl.paramStart) + p]
      add(param.nameToken, from: decl.first, to: decl.end, kind: .typed(param.typeStart, param.typeEnd))
    }
    if decl.bodyOpen >= 0, !decl.kind.isNominal {
      let isTopLevel = decl.name == CSharpWord.topLevel
      let from = isTopLevel || unit.isToken(Int(decl.bodyOpen), "=>") ? Int(decl.bodyOpen) + (isTopLevel ? 0 : 1) : Int(decl.bodyOpen) + 1
      scan(from, Int(decl.bodyClose), blockEnd: decl.bodyClose, expression: !isTopLevel && unit.isToken(Int(decl.bodyOpen), "=>"))
    }
    if decl.initStart >= 0 { scan(Int(decl.initStart), Int(decl.initEnd), blockEnd: decl.initEnd, expression: true) }
  }

  /// `parameter`: a lambda's `_` is a parameter declared there (one a later `_` doesn't name).
  private func add(_ token: Int32, from: Int32, to: Int32, kind: CSharpLocalKind, parameter: Bool = false) {
    guard token >= 0, Int(token) < unit.tokens.count, unit.csIsName(Int(token)) else { return }
    let isDiscard = unit.isToken(Int(token), "_")
    if isDiscard, !parameter { return }
    let name = unit.hash(Int(token))
    if byToken[token] != nil { return }
    let index = Int32(locals.count)
    locals.append(CSharpLocal(name: name, token: token, scopeStart: from, scopeEnd: to, kind: kind))
    if !isDiscard { byName[name, default: []].append(index) }
    byToken[token] = index
  }

  /// The local named so that a token sees: the last declared before it whose scope holds it.
  func local(named name: Name, at token: Int32) -> Int32? {
    guard let list = byName[name] else { return nil }
    var best: Int32?
    for index in list {
      let local = locals[Int(index)]
      guard local.scopeStart <= token, token <= local.scopeEnd, local.token <= token else { continue }
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

  // MARK: Scanning

  private func isStatementBoundary(_ i: Int) -> Bool {
    guard i >= 0 else { return true }
    if unit.isByte(i, 0x7B) || unit.isByte(i, 0x7D) || unit.isByte(i, 0x3B) || unit.isByte(i, 0x29) { return true }
    if unit.isByte(i, 0x3A), !unit.isToken(i, "::") { return true }
    return unit.isToken(i, "else") || unit.isToken(i, "do") || unit.tokens[i].kind == .directive
  }

  /// The tokens from `from` to `to`; declarations' scopes end at `blockEnd`. `expression`: inside an expression, where
  /// no statement declares (`a * b` multiplies; a block in it, a lambda's, has statements again).
  private func scan(_ from: Int, _ to: Int, blockEnd: Int32, expression: Bool = false) {
    var i = from
    while i < to {
      if let local = localDecls[Int32(i)] {
        i = localDeclaration(local, to: to)
        continue
      }
      let token = unit.tokens[i]
      if !expression, unit.isByte(i, 0x28), isStatementBoundary(i - 1) || i == from, let end = declaration(i, to: to, blockEnd: blockEnd) {
        // `(int a, var b) = x;`
        i = end
        continue
      }
      if token.kind == .open {
        let close = unit.skipBalanced(i) - 1
        if unit.isByte(i, 0x7B) {
          // A switch expression's arms, else a block or an initializer.
          if unit.isToken(i - 1, "switch") {
            switchArms(i, close)
          } else {
            // In an expression, a lambda's or an anonymous method's block has statements; an initializer's doesn't.
            let isBlock = !expression || unit.isToken(i - 1, "=>") || unit.isByte(i - 1, 0x29) || unit.isToken(i - 1, "delegate")
            scan(i + 1, min(close, to), blockEnd: Int32(min(close, to)), expression: !isBlock)
          }
          i = close + 1
          continue
        }
        if unit.isByte(i, 0x28) {
          if header(i, close, blockEnd: blockEnd) {
            i = close + 1
            continue
          }
          if unit.isToken(close + 1, "=>") { lambda(paramsOpen: i, arrow: close + 1) }
          scan(i + 1, min(close, to), blockEnd: blockEnd, expression: true)
          i = close + 1
          continue
        }
        scan(i + 1, min(close, to), blockEnd: blockEnd, expression: true)
        i = close + 1
        continue
      }
      if unit.isToken(i, "=>"), i > from, unit.csIsName(i - 1), !unit.isByte(i - 2, 0x2E) {
        lambda(paramsOpen: -1, arrow: i)
      }
      if unit.isToken(i, "is") {
        i = pattern(i + 1, to: to, scopeEnd: blockEnd, tested: (expressionStartBack(i), i))
        continue
      }
      if unit.isToken(i, "case") {
        i = pattern(i + 1, to: to, scopeEnd: caseScopeEnd(i, blockEnd), tested: nil)
        continue
      }
      if unit.isToken(i, "out"), let declared = outVariable(i, to: to, blockEnd: blockEnd) {
        i = declared
        continue
      }
      if unit.isToken(i, "from"), let end = query(i, to: to, blockEnd: blockEnd) {
        i = end
        continue
      }
      if !expression, isStatementBoundary(i - 1) || i == from, let end = declaration(i, to: to, blockEnd: blockEnd) {
        i = end
        continue
      }
      i += 1
    }
  }

  /// A local function's parameters and body; a local type's members.
  private func localDeclaration(_ index: Int32, to: Int) -> Int {
    let decl = unit.decls[Int(index)]
    if decl.kind == .function {
      for p in 0..<Int(decl.paramCount) {
        let param = unit.params[Int(decl.paramStart) + p]
        add(param.nameToken, from: decl.first, to: decl.end, kind: .typed(param.typeStart, param.typeEnd))
      }
      if decl.bodyOpen >= 0 {
        scan(Int(decl.bodyOpen) + 1, Int(decl.bodyClose), blockEnd: decl.bodyClose, expression: unit.isToken(Int(decl.bodyOpen), "=>"))
      }
    } else {
      for child in unit.children(of: index) {
        let item = unit.decls[Int(child)]
        if item.kind.isNominal { continue }
        member(child)
      }
    }
    return max(Int(decl.end), Int(decl.first) + 1)
  }

  /// `for (…)`, `foreach (…)`, `using (…)`, `fixed (…)`, `catch (…)`: their declarations, seen in the statement's body.
  private func header(_ open: Int, _ close: Int, blockEnd: Int32) -> Bool {
    let keyword = open - 1
    let isForeach = unit.isToken(keyword, "foreach")
    let isFor = unit.isToken(keyword, "for")
    let isUsing = unit.isToken(keyword, "using") || unit.isToken(keyword, "fixed")
    let isCatch = unit.isToken(keyword, "catch")
    guard isForeach || isFor || isUsing || isCatch else { return false }
    let scopeEnd = statementEnd(close + 1, blockEnd: blockEnd)
    if isCatch {
      let nameToken = close - 1
      if nameToken > open + 1, unit.csIsName(nameToken) { add(Int32(nameToken), from: Int32(nameToken), to: scopeEnd, kind: .typed(Int32(open + 1), Int32(nameToken))) }
      // A `when` filter sees it too.
      return true
    }
    if isForeach {
      var k = open + 1
      while unit.isToken(k, "await") || unit.isToken(k, "ref") || unit.isToken(k, "readonly") || unit.isToken(k, "scoped") { k += 1 }
      var inToken = k
      while inToken < close, !unit.isToken(inToken, "in") { inToken = unit.tokens[inToken].kind == .open ? unit.skipBalanced(inToken) : inToken + 1 }
      guard inToken < close else { return false }
      let iterated: CSharpLocalKind = .element(Int32(inToken + 1), Int32(close))
      if unit.isToken(k, "var"), unit.isByte(k + 1, 0x28) {
        deconstruction(k + 1, scopeStart: Int32(k), scopeEnd: scopeEnd)
      } else if unit.isByte(k, 0x28) {
        deconstruction(k, scopeStart: Int32(k), scopeEnd: scopeEnd)
      } else if inToken - 1 > k, unit.csIsName(inToken - 1) {
        let kind: CSharpLocalKind = unit.isToken(k, "var") ? iterated : .typed(Int32(k), Int32(inToken - 1))
        add(Int32(inToken - 1), from: Int32(inToken - 1), to: scopeEnd, kind: kind)
      }
      scan(inToken + 1, close, blockEnd: scopeEnd, expression: true)
      return true
    }
    // `for (int i = 0, j = 1; …)`, `using (var x = …)`: a declaration, then the rest of the header.
    var k = open + 1
    if let end = declaration(k, to: close, blockEnd: scopeEnd) { k = end }
    scan(k, close, blockEnd: scopeEnd, expression: true)
    return true
  }

  /// Where a statement starting at `start` ends: its block's `}`, else its `;`.
  private func statementEnd(_ start: Int, blockEnd: Int32) -> Int32 {
    if unit.isByte(start, 0x7B) { return Int32(unit.skipBalanced(start) - 1) }
    var k = start
    while k < Int(blockEnd) {
      if unit.isByte(k, 0x3B) { return Int32(k) }
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      k += 1
    }
    return blockEnd
  }

  /// A `case` label's variables are seen to the next `case` or the switch's end; ending at the block is close enough.
  private func caseScopeEnd(_ caseToken: Int, _ blockEnd: Int32) -> Int32 { blockEnd }

  /// `Type a = x, b;`, `var a = x;`, `var (a, b) = x;`, `(int a, var b) = x;`, `using var a = x;`, `const int a = 1;`:
  /// the names. Returns the token after the type, so that the initializers are scanned too; nil when no declaration
  /// starts here.
  private func declaration(_ at: Int, to: Int, blockEnd: Int32) -> Int? {
    var i = at
    if unit.isToken(i, "await"), unit.isToken(i + 1, "using") { i += 1 }
    while i < to, unit.isToken(i, "using") || unit.isToken(i, "const") || unit.isToken(i, "ref") || unit.isToken(i, "readonly") || unit.isToken(i, "scoped") || unit.isToken(i, "unsafe") && false {
      i += 1
    }
    guard i < to else { return nil }
    if unit.isToken(i, "var"), unit.isByte(i + 1, 0x28) {
      let close = unit.skipBalanced(i + 1)
      guard unit.isToken(close, "=") else { return nil }
      deconstruction(i + 1, scopeStart: Int32(i), scopeEnd: blockEnd)
      return close
    }
    if unit.isByte(i, 0x28), i == at {
      // `(int a, var b) = x;`
      let close = unit.skipBalanced(i)
      guard unit.isToken(close, "=") else { return nil }
      var hasDeclaration = false
      var k = i + 1
      while k < close - 1 {
        if let end = unit.csTypeEnd(k, limit: close - 1), unit.csIsName(end) {
          hasDeclaration = true
          break
        }
        k += 1
      }
      guard hasDeclaration else { return nil }
      deconstruction(i, scopeStart: Int32(i), scopeEnd: blockEnd)
      return close
    }
    let token = unit.tokens[i]
    if token.kind == .keyword || token.kind == .declarationKeyword, !unit.csIsName(i), !unit.csIsPredefined(i) { return nil }
    if unit.isToken(i, "await") || unit.isToken(i, "yield") || unit.isToken(i, "nameof") || unit.isToken(i, "from") && unit.csIsName(i + 1) && false { return nil }
    let isVar = unit.isToken(i, "var") && unit.csIsName(i + 1)
    guard let typeEnd = isVar ? i + 1 : unit.csTypeEnd(i, limit: to), typeEnd < to, unit.csIsName(typeEnd) else { return nil }
    let after = typeEnd + 1
    guard unit.isToken(after, "=") || unit.isByte(after, 0x3B) || unit.isByte(after, 0x2C) && !unit.isByte(at - 1, 0x28) || unit.isByte(after, 0x2C) && unit.isToken(at - 2, "for") || after == to else {
      return nil
    }
    // `a = b` alone is an assignment: a declaration has a type and a name.
    if unit.isToken(typeEnd - 1, "=") { return nil }
    var k = typeEnd
    while k < to, unit.csIsName(k) {
      let nameToken = Int32(k)
      var j = k + 1
      var kind: CSharpLocalKind = isVar ? .unknown : .typed(Int32(i), Int32(typeEnd))
      if unit.isToken(j, "=") {
        let start = j + 1
        var valueStart = start
        if unit.isToken(valueStart, "ref") { valueStart += 1 }
        let end = CSharpParser(unit: unit).expressionEnd(start, limit: to)
        if isVar { kind = .inferred(Int32(valueStart), Int32(end)) }
        // The initializer's own declarations (`out var`, patterns, lambdas).
        scan(start, end, blockEnd: blockEnd, expression: true)
        j = end
      }
      add(nameToken, from: nameToken, to: blockEnd, kind: kind)
      if unit.isByte(j, 0x2C), unit.csIsName(j + 1), !isVar {
        k = j + 1
        continue
      }
      return j
    }
    return typeEnd
  }

  /// `(a, b)`, `(int a, var (b, c))`: the names inside, their types not told unless written.
  private func deconstruction(_ open: Int, scopeStart: Int32, scopeEnd: Int32) {
    let close = unit.skipBalanced(open) - 1
    var k = open + 1
    while k < close {
      var itemEnd = k
      while itemEnd < close, !unit.isByte(itemEnd, 0x2C) {
        if unit.tokens[itemEnd].kind == .punctuation, unit.startsWith(itemEnd, 0x3C), let after = unit.csTypeArgumentsEnd(itemEnd, limit: close) {
          itemEnd = after
          continue
        }
        itemEnd = unit.tokens[itemEnd].kind == .open ? unit.skipBalanced(itemEnd) : itemEnd + 1
      }
      if unit.isByte(k, 0x28) {
        deconstruction(k, scopeStart: scopeStart, scopeEnd: scopeEnd)
      } else if unit.isToken(k, "var"), unit.isByte(k + 1, 0x28) {
        deconstruction(k + 1, scopeStart: scopeStart, scopeEnd: scopeEnd)
      } else {
        let nameToken = itemEnd - 1
        if unit.csIsName(nameToken) {
          let typed = nameToken > k && !unit.isToken(k, "var")
          add(Int32(nameToken), from: Int32(nameToken), to: scopeEnd, kind: typed ? .typed(Int32(k), Int32(nameToken)) : .unknown)
        }
      }
      k = itemEnd + 1
    }
  }

  /// A lambda's parameters: `x =>` (`paramsOpen` -1), `(a, b) =>`, `(int a, string b) =>`, seen in its body.
  private func lambda(paramsOpen: Int, arrow: Int) {
    var end: Int
    if unit.isByte(arrow + 1, 0x7B) {
      end = unit.skipBalanced(arrow + 1) - 1
    } else {
      end = CSharpParser(unit: unit).expressionEnd(arrow + 1, limit: unit.tokens.count)
    }
    var params: [Int32] = []
    if paramsOpen < 0 {
      params = [Int32(arrow - 1)]
      add(Int32(arrow - 1), from: Int32(arrow - 1), to: Int32(end), kind: .lambda(arrow: Int32(arrow), index: 0), parameter: true)
    } else {
      let close = arrow - 1
      var i = paramsOpen + 1
      var index: Int32 = 0
      while i < close {
        var itemEnd = i
        while itemEnd < close, !unit.isByte(itemEnd, 0x2C) {
          if unit.tokens[itemEnd].kind == .open {
            itemEnd = unit.skipBalanced(itemEnd)
            continue
          }
          if unit.tokens[itemEnd].kind == .punctuation, unit.startsWith(itemEnd, 0x3C), let after = unit.csTypeArgumentsEnd(itemEnd, limit: close) {
            itemEnd = after
            continue
          }
          itemEnd += 1
        }
        var nameToken = itemEnd - 1
        // `int x = 3`: a default value.
        if let equals = (i..<itemEnd).first(where: { unit.isToken($0, "=") }) { nameToken = equals - 1 }
        if nameToken >= i, unit.csIsName(nameToken) {
          params.append(Int32(nameToken))
          var typeStart = unit.csSkipAttributes(i, limit: nameToken)
          while typeStart < nameToken, unit.isToken(typeStart, "ref") || unit.isToken(typeStart, "out") || unit.isToken(typeStart, "in") || unit.isToken(typeStart, "scoped") || unit.isToken(typeStart, "params") {
            typeStart += 1
          }
          let kind: CSharpLocalKind = nameToken > typeStart && !unit.isToken(typeStart, "var") ? .typed(Int32(typeStart), Int32(nameToken)) : .lambda(arrow: Int32(arrow), index: index)
          add(Int32(nameToken), from: Int32(nameToken), to: Int32(end), kind: kind, parameter: true)
        }
        index += 1
        i = itemEnd + 1
      }
    }
    lambdas[Int32(arrow)] = params
  }

  /// `delegate (int x) { … }`: an anonymous method's parameters are typed; the scan reads them as a lambda's when
  /// untyped, so nothing more is needed. Its header is a parenthesis followed by a block.

  /// Walking back from `is`: where the tested expression starts.
  private func expressionStartBack(_ isToken: Int) -> Int {
    var k = isToken - 1
    while k >= 0 {
      if unit.tokens[k].kind == .close, let open = unit.matchingOpen(k) {
        k = open - 1
        continue
      }
      if unit.csIsName(k) || unit.csIsDot(k) || unit.isToken(k, "this") || unit.isByte(k, 0x21) && k > 0 && unit.tokens[k - 1].kind != .punctuation || unit.tokens[k].kind == .number || unit.tokens[k].kind == .string {
        k -= 1
        continue
      }
      break
    }
    return k + 1
  }

  /// `f(out var x)`, `f(out Type x)`: declared in the enclosing statement's block.
  private func outVariable(_ outToken: Int, to: Int, blockEnd: Int32) -> Int? {
    guard let open = unit.matchingOpenBefore(outToken), unit.isByte(open, 0x28) || unit.isByte(open, 0x5B) else { return nil }
    let i = outToken + 1
    if unit.isToken(i, "var"), unit.csIsName(i + 1), unit.isByte(i + 2, 0x29) || unit.isByte(i + 2, 0x2C) || unit.isByte(i + 2, 0x5D) {
      add(Int32(i + 1), from: Int32(i + 1), to: blockEnd, kind: .outArgument(open: Int32(open), position: Int32(argumentPosition(open, outToken))))
      return i + 2
    }
    if unit.isToken(i, "var"), unit.isByte(i + 1, 0x28) {
      deconstruction(i + 1, scopeStart: Int32(i), scopeEnd: blockEnd)
      return unit.skipBalanced(i + 1)
    }
    if let typeEnd = unit.csTypeEnd(i, limit: to), unit.csIsName(typeEnd), unit.isByte(typeEnd + 1, 0x29) || unit.isByte(typeEnd + 1, 0x2C) || unit.isByte(typeEnd + 1, 0x5D) {
      add(Int32(typeEnd), from: Int32(typeEnd), to: blockEnd, kind: .typed(Int32(i), Int32(typeEnd)))
      return typeEnd + 1
    }
    return nil
  }

  /// Which argument of the call at `open` a token is in.
  private func argumentPosition(_ open: Int, _ token: Int) -> Int {
    var position = 0
    var k = open + 1
    while k < token {
      if unit.isByte(k, 0x2C) { position += 1 }
      k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
    }
    return position
  }

  // MARK: Patterns

  /// A pattern from `from` (after `is` or `case`, or a switch arm's): `Type x`, `var x`, `{ … } x`, `Type(…)`, `[…]`,
  /// `not`, `and`, `or`, parentheses. Returns the token after it.
  @discardableResult
  private func pattern(_ from: Int, to: Int, scopeEnd: Int32, tested: (Int, Int)?) -> Int {
    var i = from
    var budget = 64
    while i < to, budget > 0 {
      budget -= 1
      if unit.isToken(i, "not") || unit.isToken(i, "and") || unit.isToken(i, "or") {
        i += 1
        continue
      }
      let next = primaryPattern(i, to: to, scopeEnd: scopeEnd, tested: tested)
      if next <= i { return i + 1 }
      i = next
      if unit.isToken(i, "and") || unit.isToken(i, "or") {
        i += 1
        continue
      }
      return i
    }
    return i
  }

  private func primaryPattern(_ from: Int, to: Int, scopeEnd: Int32, tested: (Int, Int)?) -> Int {
    var i = from
    guard i < to else { return from }
    if unit.isToken(i, "var") {
      if unit.isByte(i + 1, 0x28) {
        deconstruction(i + 1, scopeStart: Int32(i), scopeEnd: scopeEnd)
        return unit.skipBalanced(i + 1)
      }
      if unit.csIsName(i + 1) {
        let kind: CSharpLocalKind = tested.map { .tested(Int32($0.0), Int32($0.1)) } ?? .unknown
        add(Int32(i + 1), from: Int32(i + 1), to: scopeEnd, kind: kind)
        return i + 2
      }
      return i + 1
    }
    if unit.isByte(i, 0x5B) {
      // A list pattern.
      let close = unit.skipBalanced(i)
      subpatterns(i, close - 1, scopeEnd: scopeEnd)
      return designation(close, scopeEnd: scopeEnd, type: nil)
    }
    if unit.isByte(i, 0x28) {
      let close = unit.skipBalanced(i)
      subpatterns(i, close - 1, scopeEnd: scopeEnd)
      return designation(close, scopeEnd: scopeEnd, type: nil)
    }
    if unit.isByte(i, 0x7B) {
      let close = unit.skipBalanced(i)
      propertyPatterns(i, close - 1, scopeEnd: scopeEnd)
      return designation(close, scopeEnd: scopeEnd, type: nil)
    }
    if unit.tokens[i].kind == .punctuation {
      // A relational pattern: `> 3`, `<= x`.
      if unit.isByte(i, 0x3C) || unit.isByte(i, 0x3E) || unit.isToken(i, "<=") || unit.isToken(i, ">=") || unit.isByte(i, 0x2D) {
        i += 1
        while i < to, unit.tokens[i].kind == .number || unit.csIsName(i) || unit.csIsDot(i) || unit.isByte(i, 0x2D) { i += 1 }
        return i
      }
      return from
    }
    guard let typeEnd = unit.csTypeEnd(i, limit: to, nullable: false) else {
      // A constant: a literal.
      return i + 1
    }
    var k = typeEnd
    if unit.isByte(k, 0x28) {
      let close = unit.skipBalanced(k)
      subpatterns(k, close - 1, scopeEnd: scopeEnd)
      k = close
    }
    if unit.isByte(k, 0x7B) {
      let close = unit.skipBalanced(k)
      propertyPatterns(k, close - 1, scopeEnd: scopeEnd)
      k = close
    }
    return designation(k, scopeEnd: scopeEnd, type: (i, typeEnd))
  }

  /// A pattern's variable after its type or braces: `Type x`, `{ … } x`.
  private func designation(_ at: Int, scopeEnd: Int32, type: (Int, Int)?) -> Int {
    guard unit.csIsName(at), !unit.isToken(at, "when"), !unit.isToken(at, "and"), !unit.isToken(at, "or"), !unit.isToken(at, "not") else { return at }
    let kind: CSharpLocalKind = type.map { .typed(Int32($0.0), Int32($0.1)) } ?? .unknown
    add(Int32(at), from: Int32(at), to: scopeEnd, kind: kind)
    return at + 1
  }

  /// `(var a, Type b)`, `[var first, ..]`: each pattern inside.
  private func subpatterns(_ open: Int, _ close: Int, scopeEnd: Int32) {
    var k = open + 1
    while k < close {
      // `name: pattern` in a positional pattern.
      if unit.csIsName(k), unit.isByte(k + 1, 0x3A) { k += 2 }
      if unit.isToken(k, "..") { k += 1 }
      let next = pattern(k, to: close, scopeEnd: scopeEnd, tested: nil)
      k = next > k ? next : k + 1
      while k < close, !unit.isByte(k, 0x2C) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
      k += 1
    }
  }

  /// `{ Name: pattern, A.B: pattern }`.
  private func propertyPatterns(_ open: Int, _ close: Int, scopeEnd: Int32) {
    var k = open + 1
    while k < close {
      while k < close, !unit.isByte(k, 0x3A), !unit.isByte(k, 0x2C) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
      if unit.isByte(k, 0x3A) {
        let next = pattern(k + 1, to: close, scopeEnd: scopeEnd, tested: nil)
        k = next > k ? next : k + 1
      }
      while k < close, !unit.isByte(k, 0x2C) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
      k += 1
    }
  }

  /// `e switch { pattern [when c] => value, … }`: each arm's variables, seen in that arm.
  private func switchArms(_ open: Int, _ close: Int) {
    var k = open + 1
    while k < close {
      var arrow = k
      while arrow < close, !unit.isToken(arrow, "=>"), !unit.isByte(arrow, 0x2C) { arrow = unit.tokens[arrow].kind == .open ? unit.skipBalanced(arrow) : arrow + 1 }
      guard arrow < close, unit.isToken(arrow, "=>") else {
        k = arrow + 1
        continue
      }
      let end = CSharpParser(unit: unit).expressionEnd(arrow + 1, limit: close)
      let next = pattern(k, to: arrow, scopeEnd: Int32(end), tested: nil)
      if next < arrow { scan(next, arrow, blockEnd: Int32(end), expression: true) }
      scan(arrow + 1, end, blockEnd: Int32(end), expression: true)
      k = end + 1
    }
  }

  // MARK: Queries

  /// `from x in e … select …`: the range variables (`from`, `let`, `join`, `into`), seen to the query's end.
  private func query(_ fromToken: Int, to: Int, blockEnd: Int32) -> Int? {
    var nameToken = fromToken + 1
    var typed: (Int, Int)?
    if let typeEnd = unit.csTypeEnd(nameToken, limit: to), unit.csIsName(typeEnd), unit.isToken(typeEnd + 1, "in") {
      typed = (nameToken, typeEnd)
      nameToken = typeEnd
    }
    guard unit.csIsName(nameToken), unit.isToken(nameToken + 1, "in") else { return nil }
    let end = CSharpParser(unit: unit).expressionEnd(fromToken, limit: to)
    var k = fromToken
    while k < end {
      if unit.tokens[k].kind == .open {
        let close = unit.skipBalanced(k)
        scan(k + 1, close - 1, blockEnd: Int32(close - 1), expression: true)
        k = close
        continue
      }
      if unit.isToken(k, "from") || unit.isToken(k, "join") {
        var name = k + 1
        var written: (Int, Int)? = nil
        if let typeEnd = unit.csTypeEnd(name, limit: end), unit.csIsName(typeEnd), unit.isToken(typeEnd + 1, "in") {
          written = (name, typeEnd)
          name = typeEnd
        }
        if k == fromToken { written = typed }
        if unit.csIsName(name), unit.isToken(name + 1, "in") {
          let sourceEnd = clauseEnd(name + 2, end)
          let kind: CSharpLocalKind = written.map { .typed(Int32($0.0), Int32($0.1)) } ?? .element(Int32(name + 2), Int32(sourceEnd))
          add(Int32(name), from: Int32(name), to: Int32(end), kind: kind)
          k = name + 2
          continue
        }
      }
      if unit.isToken(k, "let"), unit.csIsName(k + 1), unit.isToken(k + 2, "=") {
        let valueEnd = clauseEnd(k + 3, end)
        add(Int32(k + 1), from: Int32(k + 1), to: Int32(end), kind: .inferred(Int32(k + 3), Int32(valueEnd)))
        k += 3
        continue
      }
      if unit.isToken(k, "into"), unit.csIsName(k + 1) {
        add(Int32(k + 1), from: Int32(k + 1), to: Int32(end), kind: .unknown)
        k += 2
        continue
      }
      k += 1
    }
    return end
  }

  /// Where a query clause's expression ends: at the next clause's keyword.
  private func clauseEnd(_ from: Int, _ end: Int) -> Int {
    var k = from
    while k < end {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      for word in CSharpWord.queryClauses where unit.hash(k) == word { return k }
      k += 1
    }
    return end
  }
}
