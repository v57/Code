import CodeModel
import CodeScan
import Foundation

/// How a variable gets its value where it's bound, for its type.
enum PHPBindingKind {
  /// A parameter of the function that owns the body (its index).
  case parameter(Int32)
  /// Typed tokens: a closure's parameter, `catch (T $e)`.
  case typed(Int32, Int32)
  /// `$x = …`: the value's tokens.
  case assign(Int32, Int32)
  /// `foreach (… as $v)`: what's walked.
  case element(Int32, Int32)
  /// A closure's `use ($x)`: the outer variable at the closure.
  case captured
  /// Bound with a type that can't be told (`global`, a list, a closure's untyped parameter).
  case untyped
  /// `$x .= …`, `$x[] = …`: bound, but its type isn't changed.
  case transparent
}

struct PHPBinding {
  var name: Name
  var token: Int32
  var scope: Int32
  var kind: PHPBindingKind
}

/// A function's, a closure's or an arrow function's variables (an arrow function sees its parent's).
struct PHPScope {
  var start: Int32
  var end: Int32
  var parent: Int32
  var isArrow: Bool
}

/// A variable's type from `start` to `end`: `$x instanceof T` holding, or a `@var` comment (its type's text).
struct PHPNarrowing {
  var name: Name
  var start: Int32
  var end: Int32
  var typeStart: Int32 = -1
  var typeEnd: Int32 = -1
  var docType: String?
  /// For a `@var` comment: the end of the statement it's on, whose binding it types.
  var statementEnd: Int32 = -1
}

/// What one function's body (or a file's top-level code) declares: its scopes, where each variable is bound and first
/// seen, and where a type check narrows one. Scanned once, when a question first lands in it.
final class PHPBody: BodyFacts {
  let owner: Int32
  var scopes: [PHPScope] = []
  var bindings: [PHPBinding] = []
  var narrowings: [PHPNarrowing] = []
  /// Bodies of anonymous classes, where `$this` is that class.
  var anonymousClasses: [(Int32, Int32)] = []
  var types: [Int32: Ty] = [:]
  var resolving: Set<Int32> = []
  private var firstSeen: [ScopeName: Int32] = [:]
  private var scopeOf: [Int32: Int32] = [:]
  private var handled: Set<Int32> = []
  private let unit: Unit

  struct ScopeName: Hashable {
    var scope: Int32
    var name: Name
  }

  func dropTypes() { types.removeAll() }

  init(unit: Unit, owner: Int32) {
    self.unit = unit
    self.owner = owner
    if owner >= 0 {
      let decl = unit.decls[Int(owner)]
      scopes.append(PHPScope(start: decl.first, end: decl.end, parent: -1, isArrow: false))
      for p in 0..<Int(decl.paramCount) {
        let param = unit.params[Int(decl.paramStart) + p]
        bind(param.local, Int32(param.nameToken), scope: 0, .parameter(Int32(p)))
        seen(param.local, param.nameToken, scope: 0)
      }
      if decl.bodyOpen >= 0 { scan(Int(decl.bodyOpen) + 1, Int(decl.bodyClose), scope: 0) }
    } else {
      scopes.append(PHPScope(start: 0, end: Int32(unit.tokens.count), parent: -1, isArrow: false))
      var skips: [(Int, Int)] = []
      for item in unit.decls where !item.isLocal && (item.kind == .function || item.kind == .classType || item.kind == .protocolType || item.kind == .enumeration) {
        skips.append((Int(item.first), Int(item.end)))
      }
      skips.sort { $0.0 < $1.0 }
      var from = 0
      for (start, end) in skips where end > from {
        if start > from { scan(from, start, scope: 0) }
        from = max(from, end)
      }
      if from < unit.tokens.count { scan(from, unit.tokens.count, scope: 0) }
    }
    readVarComments()
    bindings.sort { $0.token < $1.token }
  }

  private func bind(_ word: Name, _ token: Int32, scope: Int32, _ kind: PHPBindingKind) {
    handled.insert(token)
    bindings.append(PHPBinding(name: word, token: token, scope: scope, kind: kind))
  }

  private func seen(_ word: Name, _ token: Int32, scope: Int32) {
    if scopeOf[token] == nil { scopeOf[token] = scope }
    let key = ScopeName(scope: scope, name: word)
    if let first = firstSeen[key], first <= token { return }
    firstSeen[key] = token
  }

  private func addScope(_ start: Int, _ end: Int, parent: Int32, isArrow: Bool) -> Int32 {
    scopes.append(PHPScope(start: Int32(start), end: Int32(end), parent: parent, isArrow: isArrow))
    return Int32(scopes.count - 1)
  }

  // MARK: Scanning

  private func scan(_ from: Int, _ to: Int, scope: Int32) {
    var i = from
    while i < to {
      // `->catch(…)`, `::list(…)`: a method, not the keyword.
      if unit.phIsArrow(i - 1) || unit.isToken(i - 1, "::") {
        i += 1
        continue
      }
      if unit.isToken(i, "function") || unit.isToken(i, "fn") {
        if let next = function(i, to: to, scope: scope) {
          i = next
          continue
        }
      } else if unit.isToken(i, "class"), unit.isToken(i - 1, "new") || unit.isToken(i - 1, "readonly") && unit.isToken(i - 2, "new") {
        // Its arguments are this body's; its methods are their own.
        var k = i + 1
        while k < to, !unit.isByte(k, 0x7B) {
          if unit.tokens[k].kind == .open { k = unit.skipBalanced(k) } else { k += 1 }
        }
        if unit.isByte(i + 1, 0x28) { scan(i + 2, unit.skipBalanced(i + 1) - 1, scope: scope) }
        if k < to {
          anonymousClasses.append((Int32(k), Int32(unit.skipBalanced(k))))
          i = unit.skipBalanced(k)
          continue
        }
      } else if unit.isToken(i, "foreach"), unit.isByte(i + 1, 0x28) {
        foreachHead(i + 1, scope: scope)
      } else if unit.isToken(i, "catch"), unit.isByte(i + 1, 0x28) {
        let close = unit.skipBalanced(i + 1) - 1
        var v = i + 2
        while v < close, !unit.phIsVariable(v) { v += 1 }
        if v < close {
          bind(unit.hash(v), Int32(v), scope: scope, v - 1 > i + 2 ? .typed(Int32(i + 2), Int32(v - 1)) : .untyped)
        }
      } else if unit.isToken(i, "global"), unit.phStartsStatement(i) {
        let end = unit.phStatementEnd(i, limit: to)
        for v in i..<end where unit.phIsVariable(v) { bind(unit.hash(v), Int32(v), scope: scope, .untyped) }
      } else if unit.isToken(i, "static"), unit.phStartsStatement(i), unit.phIsVariable(i + 2) {
        let end = unit.phStatementEnd(i, limit: to)
        var v = i + 1
        while v < end {
          if unit.phIsVariable(v), !unit.isByte(v - 2, 0x3D) {
            if unit.isToken(v + 1, "=") {
              let valueEnd = unit.phExpressionEnd(v + 2, limit: end)
              bind(unit.hash(v), Int32(v), scope: scope, .assign(Int32(v + 2), Int32(valueEnd)))
            } else {
              bind(unit.hash(v), Int32(v), scope: scope, .untyped)
            }
          }
          v += 1
        }
      } else if unit.isToken(i, "list") && unit.isByte(i + 1, 0x28) || unit.isByte(i, 0x5B) && !isOperand(i - 1) {
        destructuring(unit.isByte(i, 0x5B) ? i : i + 1, scope: scope)
      } else if unit.isToken(i, "if") || unit.isToken(i, "elseif"), unit.isByte(i + 1, 0x28) {
        typeCheck(i, to: to)
      } else if unit.isToken(i, "assert"), unit.isByte(i + 1, 0x28) {
        assertion(i, to: to)
      } else if unit.phIsVariable(i) {
        variable(i, to: to, scope: scope)
      }
      i += 1
    }
  }

  /// Whether a token ends an operand: `[` after it indexes rather than opens a list.
  private func isOperand(_ i: Int) -> Bool {
    guard i >= 0 else { return false }
    if unit.tokens[i].kind == .close || unit.tokens[i].kind == .string || unit.tokens[i].kind == .interpolationClose { return true }
    return unit.tokens[i].kind == .identifier || unit.phIsVariable(i)
  }

  /// A variable's use: where it's first seen, and whether it's bound here.
  private func variable(_ v: Int, to: Int, scope: Int32) {
    let word = unit.hash(v)
    if unit.isToken(v, "this") { return }
    // `X::$name`: a static property.
    if unit.phIsDollar(v - 1), unit.isToken(v - 2, "::") { return }
    seen(word, Int32(v), scope: scope)
    guard !handled.contains(Int32(v)) else { return }
    let next = v + 1
    guard next < unit.tokens.count, unit.tokens[next].kind == .punctuation else {
      // `$a[…] = …`: an element written.
      if unit.isByte(next, 0x5B) {
        var k = next
        while unit.isByte(k, 0x5B) { k = unit.skipBalanced(k) }
        if isAssignment(k) { bind(word, Int32(v), scope: scope, .transparent) }
      }
      return
    }
    if isAssignment(next) {
      let start = unit.isToken(next, "=") ? next + 1 : next
      bind(word, Int32(v), scope: scope, .assign(Int32(start), Int32(unit.phExpressionEnd(start, limit: to))))
      return
    }
    var text = unit.string(next)
    while text.hasSuffix("$") || text.hasSuffix("&") { text.removeLast() }
    if Self.compound.contains(text) { bind(word, Int32(v), scope: scope, .transparent) }
  }

  static let compound: Set<String> = ["+=", "-=", "*=", "/=", ".=", "%=", "**=", "??=", "|=", "&=", "^=", "<<=", ">>=", "++", "--"]

  /// `=`, or a run starting with it that isn't `==` or `=>` (`=$x`, `=&$x`, `=-1`).
  private func isAssignment(_ i: Int) -> Bool {
    guard i < unit.tokens.count, unit.tokens[i].kind == .punctuation, unit.startsWith(i, 0x3D) else { return false }
    if unit.tokens[i].length == 1 { return true }
    let second = unit.source.text[unit.tokens[i].start + 1]
    return second != 0x3D && second != 0x3E
  }

  /// A closure (`function (…) use (…) { … }`), a function or method declared in a body (its own scope), or an arrow
  /// function (`fn (…) => …`, its parent's scope seen): the token after it.
  private func function(_ i: Int, to: Int, scope: Int32) -> Int? {
    let isArrow = unit.isToken(i, "fn")
    var k = i + 1
    if unit.isByte(k, 0x26) { k += 1 }
    var isNamed = false
    if !isArrow, unit.phIsWord(k), unit.isByte(k + 1, 0x28) {
      isNamed = true
      k += 1
    }
    guard unit.isByte(k, 0x28) else { return nil }
    let open = k
    let close = unit.skipBalanced(open) - 1
    var j = close + 1
    var captureOpen = -1
    var captureClose = -1
    if !isArrow, unit.isToken(j, "use"), unit.isByte(j + 1, 0x28) {
      captureOpen = j + 1
      captureClose = unit.skipBalanced(j + 1) - 1
      j = captureClose + 1
    }
    if unit.isByte(j, 0x3A) {
      while j < to, !unit.isByte(j, 0x7B), !unit.isToken(j, "=>"), !unit.isByte(j, 0x3B) { j += 1 }
    }
    let bodyStart: Int
    let bodyEnd: Int
    if isArrow {
      guard unit.isToken(j, "=>") else { return nil }
      bodyStart = j + 1
      bodyEnd = unit.phExpressionEnd(bodyStart, limit: to)
    } else {
      guard unit.isByte(j, 0x7B) else { return isNamed ? j + 1 : nil }
      bodyStart = j + 1
      bodyEnd = unit.skipBalanced(j) - 1
    }
    let inner = addScope(open, bodyEnd + 1, parent: isNamed ? -1 : scope, isArrow: isArrow)
    parameters(open, close, scope: inner)
    if captureOpen >= 0 {
      for v in captureOpen + 1..<captureClose where unit.phIsVariable(v) {
        let word = unit.hash(v)
        bind(word, Int32(v), scope: inner, .captured)
        // The `use` list's names are the outer variables'.
        seen(word, Int32(v), scope: scope)
      }
    }
    scan(bodyStart, bodyEnd, scope: inner)
    return isArrow ? bodyEnd : bodyEnd + 1
  }

  /// A closure's parameters: `[type] [&] [...] $name [= default]`.
  private func parameters(_ open: Int, _ close: Int, scope: Int32) {
    var segment = open + 1
    var k = open + 1
    while k <= close {
      if k < close, unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if k == close || unit.isByte(k, 0x2C) {
        var v = segment
        while v < k, !unit.phIsVariable(v) { v += 1 }
        if v < k {
          var typeStart = segment
          while typeStart < v - 1, unit.tokens[typeStart].kind == .attribute || unit.phIsModifier(typeStart) { typeStart += 1 }
          let word = unit.hash(v)
          bind(word, Int32(v), scope: scope, v - 1 > typeStart ? .typed(Int32(typeStart), Int32(v - 1)) : .untyped)
          seen(word, Int32(v), scope: scope)
        }
        segment = k + 1
      }
      k += 1
    }
  }

  /// `foreach (expr as [$k =>] $v)`: the key's and value's bindings (a list's variables untyped).
  private func foreachHead(_ open: Int, scope: Int32) {
    let close = unit.skipBalanced(open) - 1
    var asToken = -1
    var k = open + 1
    while k < close {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.isToken(k, "as") {
        asToken = k
        break
      }
      k += 1
    }
    guard asToken >= 0 else { return }
    var arrow = -1
    k = asToken + 1
    while k < close {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.isToken(k, "=>") || unit.isToken(k, "=>$") || unit.isToken(k, "=>&$") {
        arrow = k
        break
      }
      k += 1
    }
    let valueStart = arrow >= 0 ? arrow : asToken + 1
    if arrow >= 0 {
      for v in asToken + 1..<arrow where unit.phIsVariable(v) { bind(unit.hash(v), Int32(v), scope: scope, .untyped) }
    }
    var variables: [Int] = []
    for v in valueStart..<close where unit.phIsVariable(v) { variables.append(v) }
    let isList = (valueStart..<close).contains { unit.isByte($0, 0x5B) || unit.isToken($0, "list") }
    for v in variables {
      bind(unit.hash(v), Int32(v), scope: scope, isList ? .untyped : .element(Int32(open + 1), Int32(asToken)))
    }
  }

  /// `[$a, $b] = …`, `list($a, 'k' => $b) = …`: each variable bound.
  private func destructuring(_ open: Int, scope: Int32) {
    let after = unit.skipBalanced(open)
    guard isAssignment(after) else { return }
    for v in open + 1..<after - 1 where unit.phIsVariable(v) && !unit.phIsArrow(v + 1) && !unit.isByte(v + 1, 0x5B) && !unit.isToken(v + 1, "::") && !handled.contains(Int32(v)) {
      bind(unit.hash(v), Int32(v), scope: scope, .untyped)
    }
  }

  // MARK: Narrowing

  /// `if ($x instanceof T [&& …]) { … }`: T in the body; `if (!$x instanceof T) { return; }`: T after it.
  private func typeCheck(_ keyword: Int, to: Int) {
    let open = keyword + 1
    let close = unit.skipBalanced(open) - 1
    var terms: [(start: Int, end: Int)] = []
    var start = open + 1
    var k = open + 1
    var hasOr = false
    while k <= close {
      if k < close, unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if k == close || unit.isToken(k, "&&") || unit.isToken(k, "and") {
        terms.append((start, k))
        start = k + 1
      }
      if unit.isToken(k, "||") || unit.isToken(k, "or") { hasOr = true }
      k += 1
    }
    guard !hasOr else { return }
    let bodyOpen = close + 1
    for term in terms {
      guard let check = instanceCheck(term.start, term.end) else { continue }
      if !check.negated, unit.isByte(bodyOpen, 0x7B) {
        let bodyClose = unit.skipBalanced(bodyOpen) - 1
        narrowings.append(PHPNarrowing(name: check.name, start: Int32(bodyOpen), end: Int32(bodyClose), typeStart: Int32(check.typeStart), typeEnd: Int32(check.typeEnd)))
      } else if check.negated, terms.count == 1, unit.isToken(keyword, "if"), unit.isByte(bodyOpen, 0x7B) {
        // The body leaves: after it, the check held.
        let bodyClose = unit.skipBalanced(bodyOpen) - 1
        let last = unit.phStatementStartBefore(max(bodyOpen + 1, bodyClose - 1))
        guard unit.isToken(last, "return") || unit.isToken(last, "throw") || unit.isToken(last, "continue") || unit.isToken(last, "break") || unit.isToken(last, "exit")
          || unit.isToken(last, "die")
        else { continue }
        narrowings.append(
          PHPNarrowing(name: check.name, start: Int32(bodyClose + 1), end: Int32(blockEnd(keyword, to: to)), typeStart: Int32(check.typeStart), typeEnd: Int32(check.typeEnd)))
      }
    }
  }

  /// `assert($x instanceof T);`: T after it.
  private func assertion(_ keyword: Int, to: Int) {
    let open = keyword + 1
    let close = unit.skipBalanced(open) - 1
    guard let check = instanceCheck(open + 1, close), !check.negated else { return }
    narrowings.append(PHPNarrowing(name: check.name, start: Int32(close), end: Int32(blockEnd(keyword, to: to)), typeStart: Int32(check.typeStart), typeEnd: Int32(check.typeEnd)))
  }

  /// The end of the block a statement is in.
  private func blockEnd(_ i: Int, to: Int) -> Int {
    guard let open = unit.matchingOpenBefore(i), unit.isByte(open, 0x7B) else { return to }
    return min(to, unit.skipBalanced(open) - 1)
  }

  /// `$x instanceof T`, `!$x instanceof T`, `!($x instanceof T)`, `$x instanceof T === false` aside.
  private func instanceCheck(_ start: Int, _ end: Int) -> (name: Name, typeStart: Int, typeEnd: Int, negated: Bool)? {
    var s = start
    var negated = false
    var e = end
    if s < e, unit.isToken(s, "!") || unit.isToken(s, "!$") {
      negated = true
      if unit.isByte(s, 0x21) { s += 1 }
    }
    if unit.isByte(s, 0x28), unit.skipBalanced(s) == e {
      s += 1
      e -= 1
    }
    // `$` and the name, `instanceof`, the class's name.
    var v = s
    while v < e, !unit.phIsVariable(v) { v += 1 }
    guard v < e, v <= s + 1, unit.isToken(v + 1, "instanceof"), v + 2 < e else { return nil }
    if unit.isToken(v, "this") { return nil }
    return (unit.hash(v), v + 2, e, negated)
  }

  /// `/** @var T $x */` before a statement: T for x there (or for the variable the statement assigns, when unnamed).
  private func readVarComments() {
    guard let first = scopes.first, first.end > first.start, Int(first.start) < unit.tokens.count else { return }
    let from = unit.tokens[Int(first.start)].start
    let to = Int(first.end) < unit.tokens.count ? unit.tokens[Int(first.end) - 1].end : unit.source.count
    let all = unit.source.tokens
    var low = 0
    var high = all.count
    while low < high {
      let middle = (low + high) / 2
      if all[middle].start < from { low = middle + 1 } else { high = middle }
    }
    var index = low
    while index < all.count, all[index].start < to {
      defer { index += 1 }
      let token = all[index]
      guard token.kind == .docComment || token.kind == .comment, token.length > 6 else { continue }
      let text = unit.source.string(token)
      guard text.hasPrefix("/*"), let tag = text.range(of: "@var") ?? text.range(of: "@psalm-var") ?? text.range(of: "@phpstan-var") else { continue }
      guard let (type, variable) = PHPDocText.typeAndName(text[tag.upperBound...]) else { continue }
      let anchor = unit.firstToken(after: token.end)
      guard anchor < unit.tokens.count else { continue }
      var word: Name
      var at = anchor
      if let variable {
        word = name(variable)
      } else {
        // Unnamed, it types the variable the statement assigns (`/** @var T */ $x = …`), nothing else.
        let v = anchor + 1
        guard unit.phIsDollar(anchor), unit.phIsVariable(v), isAssignment(v + 1) else { continue }
        word = unit.hash(v)
        at = v
      }
      let statementEnd = unit.phStatementEnd(at, limit: unit.tokens.count)
      var end = unit.tokens.count
      if let open = unit.matchingOpenBefore(anchor), unit.isByte(open, 0x7B) { end = unit.skipBalanced(open) - 1 }
      narrowings.append(PHPNarrowing(name: word, start: Int32(anchor), end: Int32(end), docType: type, statementEnd: Int32(statementEnd)))
    }
  }

  // MARK: Questions

  /// The innermost scope holding a token.
  func scope(containing token: Int32) -> Int32 {
    if let known = scopeOf[token] { return known }
    var best: Int32 = 0
    for (index, scope) in scopes.enumerated() where scope.start <= token && token < scope.end && scope.start >= scopes[Int(best)].start {
      best = Int32(index)
    }
    return best
  }

  /// The scopes a variable is looked up in from a token: its own, and an arrow function's parents.
  func lookupChain(_ token: Int32) -> [Int32] {
    var chain: [Int32] = []
    var scope = scope(containing: token)
    while true {
      chain.append(scope)
      guard scopes[Int(scope)].isArrow, scopes[Int(scope)].parent >= 0 else { break }
      scope = scopes[Int(scope)].parent
    }
    return chain
  }

  /// Where a variable seen at a token is defined: its first binding in its scope (an arrow function's parent's when
  /// it binds none), else where it's first seen.
  func definition(of word: Name, at token: Int32) -> Int32? {
    let chain = lookupChain(token)
    for scope in chain {
      if let first = bindings.first(where: { $0.scope == scope && $0.name == word }) { return first.token }
    }
    return chain.compactMap { firstSeen[ScopeName(scope: $0, name: word)] }.min()
  }

  /// The binding that gives a variable its type at a token: the last before it that sets one (the first, before any).
  func typingBinding(of word: Name, at token: Int32) -> PHPBinding? {
    for scope in lookupChain(token) {
      let all = bindings.filter { $0.scope == scope && $0.name == word }
      guard !all.isEmpty else { continue }
      let setting = all.filter { item in
        switch item.kind {
        case .transparent: return false
        // `$x = $x->next`: the right side's `$x` is the one before.
        case .assign(let start, let end): return !(start <= token && token < end)
        case .element(let start, let end): return !(start <= token && token < end)
        default: return true
        }
      }
      return setting.last { $0.token <= token } ?? setting.first
    }
    return nil
  }

  /// The narrowing that holds for a variable at a token, if it's later than its binding (or types that binding).
  func narrowing(of word: Name, at token: Int32, after binding: PHPBinding?) -> PHPNarrowing? {
    var best: PHPNarrowing?
    for item in narrowings where item.name == word && item.start <= token && token < item.end {
      if best == nil || item.start >= best!.start { best = item }
    }
    guard let best else { return nil }
    if let binding {
      if best.docType != nil, best.start <= binding.token, binding.token < best.statementEnd { return best }
      if binding.token > best.start { return nil }
    }
    return best
  }

  /// Every variable seen at a token: its scope's and an arrow function's parents', by name, defined before it.
  func visible(at token: Int32) -> [Name: Int32] {
    var result: [Name: Int32] = [:]
    for scope in lookupChain(token) {
      for (key, first) in firstSeen where key.scope == scope && first < token && result[key.name] == nil {
        result[key.name] = definition(of: key.name, at: first) ?? first
      }
    }
    return result
  }

  /// Whether a token is in an anonymous class's body.
  func isInAnonymousClass(_ token: Int32) -> Bool { anonymousClasses.contains { $0.0 <= token && token < $0.1 } }
}

extension Unit {
  /// The first code token starting at or after a byte offset.
  func firstToken(after offset: Int) -> Int {
    var low = 0
    var high = tokens.count
    while low < high {
      let middle = (low + high) / 2
      if tokens[middle].start < offset { low = middle + 1 } else { high = middle }
    }
    return low
  }
}
