import CodeModel
import CodeScan
import Foundation

/// How a local's type is known.
enum JavaLocalKind {
  /// A written type, by its tokens (a parameter, `Type x`, a pattern's binding, a catch's types joined by `|`).
  case typed(Int32, Int32)
  /// `var x = e`: the initializer's tokens.
  case inferred(Int32, Int32)
  /// `for (var x : e)`: what's iterated.
  case element(Int32, Int32)
  /// A lambda's parameter without a type: the lambda's `->` and which parameter.
  case lambda(arrow: Int32, index: Int32)
}

struct JavaLocal {
  var name: Name
  var token: Int32
  var scopeStart: Int32
  var scopeEnd: Int32
  var kind: JavaLocalKind
}

/// Layer 4 for Java: the locals a member's body (or a field's initializer) declares and where each is visible, read
/// once when a position inside asks: parameters (also of the methods of local and anonymous classes in it), local
/// variables, `for` and resources, catch parameters, lambdas' parameters, patterns' bindings. Java forbids a local
/// that hides another local, so the one declared last before a use, still in scope, is the one meant.
final class JavaBody: BodyFacts {
  func dropTypes() { types.removeAll() }

  var locals: [JavaLocal] = []
  var byName: [Name: [Int32]] = [:]
  var byToken: [Int32: Int32] = [:]
  /// Each lambda's `->` → its parameters' tokens and its body's range.
  var lambdas: [Int32: (params: [Int32], start: Int32, end: Int32)] = [:]
  var types: [Int32: Ty] = [:]
  var resolving: Set<Int32> = []

  private let unit: Unit
  /// Local classes' bodies in this body, by their `{`: their members are scanned one by one.
  private var classBodies: [Int32: Int32] = [:]

  init(unit: Unit, owner: Int32) {
    self.unit = unit
    guard owner >= 0, Int(owner) < unit.decls.count else { return }
    for index in unit.decls.indices where unit.decls[index].isLocal && unit.decls[index].kind.isNominal && unit.decls[index].bodyOpen >= 0 {
      classBodies[unit.decls[index].bodyOpen] = Int32(index)
    }
    member(owner)
  }

  /// A member's parameters and body, or a field's initializer.
  private func member(_ index: Int32) {
    let decl = unit.decls[Int(index)]
    for p in 0..<Int(decl.paramCount) where decl.kind != .structure {
      let param = unit.params[Int(decl.paramStart) + p]
      add(param.nameToken, from: decl.first, to: decl.end, kind: .typed(param.typeStart, param.typeEnd))
    }
    if decl.bodyOpen >= 0, decl.kind == .function || decl.kind == .initializer {
      scan(Int(decl.bodyOpen) + 1, Int(decl.bodyClose), blockEnd: decl.bodyClose)
    }
    if decl.initStart >= 0 { scan(Int(decl.initStart), Int(decl.initEnd), blockEnd: decl.initEnd) }
  }

  private func add(_ token: Int32, from: Int32, to: Int32, kind: JavaLocalKind) {
    guard token >= 0, Int(token) < unit.tokens.count else { return }
    let name = unit.hash(Int(token))
    if byToken[token] != nil { return }
    let index = Int32(locals.count)
    locals.append(JavaLocal(name: name, token: token, scopeStart: from, scopeEnd: to, kind: kind))
    byName[name, default: []].append(index)
    byToken[token] = index
  }

  /// The local named so that a token sees: the last declared before it whose scope holds it.
  func local(named name: Name, at token: Int32) -> Int32? {
    guard let list = byName[name] else { return nil }
    var best: Int32?
    for index in list {
      let local = locals[Int(index)]
      guard local.scopeStart <= token, token < local.scopeEnd, local.token <= token else { continue }
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
    if unit.isByte(i, 0x7B) || unit.isByte(i, 0x7D) || unit.isByte(i, 0x3B) || unit.isByte(i, 0x28) || unit.isByte(i, 0x3A) || unit.isByte(i, 0x29) { return true }
    return unit.isToken(i, "->") || unit.isToken(i, "else") || unit.isToken(i, "do")
  }

  /// The tokens from `from` to `to`; declarations' scopes end at `blockEnd`.
  private func scan(_ from: Int, _ to: Int, blockEnd: Int32) {
    var i = from
    while i < to {
      let token = unit.tokens[i]
      if token.kind == .open {
        let close = unit.skipBalanced(i) - 1
        if unit.isByte(i, 0x7B) {
          if let owner = classBodies[Int32(i)] {
            classMembers(owner)
            i = close + 1
            continue
          }
          scan(i + 1, min(close, to), blockEnd: Int32(min(close, to)))
          i = close + 1
          continue
        }
        if unit.isByte(i, 0x28) {
          if unit.isToken(i - 1, "catch") { catchParameter(i, close) }
          // `(a, b) ->`, `(Type a) ->`.
          if unit.isToken(close + 1, "->") { lambda(paramsOpen: i, arrow: close + 1, to: to) }
          scan(i + 1, min(close, to), blockEnd: blockEnd)
          i = close + 1
          continue
        }
        // `[`: an index or a dimension.
        scan(i + 1, min(close, to), blockEnd: blockEnd)
        i = close + 1
        continue
      }
      if unit.isToken(i, "->"), i > from, unit.javaIsName(i - 1), !isSwitchRule(i) {
        lambda(paramsOpen: -1, arrow: i, to: to)
      }
      if unit.isToken(i, "instanceof") {
        i = pattern(i + 1, to: to, scopeEnd: blockEnd)
        continue
      }
      if unit.isToken(i, "case") {
        var k = i + 1
        while k < to, !unit.isToken(k, "->"), !unit.isByte(k, 0x3A) || unit.isToken(k, "::") {
          let next = pattern(k, to: to, scopeEnd: blockEnd)
          k = next > k ? next : k + 1
          if unit.isByte(k, 0x2C) { k += 1 }
          if unit.isToken(k, "when") { break }
        }
        i = max(k, i + 1)
        continue
      }
      if isStatementBoundary(i - 1), let end = declaration(i, to: to, blockEnd: blockEnd) {
        i = end
        continue
      }
      i += 1
    }
  }

  /// `case A ->` rather than a lambda: a `case` or `default` since the last statement boundary.
  private func isSwitchRule(_ arrow: Int) -> Bool {
    var k = arrow - 1
    var budget = 64
    while k >= 0, budget > 0 {
      budget -= 1
      if unit.isToken(k, "case") || unit.isToken(k, "default") { return true }
      if unit.isByte(k, 0x3B) || unit.isByte(k, 0x7B) || unit.isByte(k, 0x7D) || unit.isToken(k, "->") { return false }
      if unit.tokens[k].kind == .close, let open = unit.matchingOpen(k) {
        k = open - 1
        continue
      }
      if unit.tokens[k].kind == .open { return false }
      k -= 1
    }
    return false
  }

  /// A local class's members: each method's parameters and body, each field's initializer.
  private func classMembers(_ owner: Int32) {
    for child in unit.children(of: owner) {
      let decl = unit.decls[Int(child)]
      if decl.kind.isNominal { continue }
      member(child)
    }
  }

  /// `Type a = x, b[];`, `var a = x;`, `final Type a`, `Type a :` (a for-each): the names, from the type's start.
  /// Returns the token after the type, so that what's written after it is scanned too; nil when none starts here.
  private func declaration(_ at: Int, to: Int, blockEnd: Int32) -> Int? {
    var i = at
    while i < to, unit.isToken(i, "final") || unit.tokens[i].kind == .attribute {
      i = unit.tokens[i].kind == .attribute ? unit.javaSkipAnnotations(i, limit: to) : i + 1
    }
    guard i < to else { return nil }
    if unit.isToken(i, "yield") || unit.isToken(i, "record") { return nil }
    if unit.tokens[i].kind == .keyword, !JavaWord.primitives.contains(unit.hash(i)), !unit.isToken(i, "var") { return nil }
    let isVar = unit.isToken(i, "var") && unit.javaIsName(i + 1)
    guard let typeEnd = isVar ? i + 1 : unit.javaTypeEnd(i, limit: to), typeEnd < to, unit.javaIsName(typeEnd) else { return nil }
    var k = typeEnd
    let after = k + 1
    // What may follow the first name: `=`, `;`, `,`, `:` (for-each), `[`, `)` (a resource's last).
    guard unit.isToken(after, "=") || unit.isByte(after, 0x3B) || unit.isByte(after, 0x2C) || unit.isByte(after, 0x3A) || unit.isByte(after, 0x5B) || unit.isByte(after, 0x29) else {
      return nil
    }
    if unit.isByte(after, 0x3A), unit.isToken(after, "::") { return nil }
    // `x)` and `x,` alone would be an expression's; only a declaration has a type before its name.
    if unit.isByte(after, 0x29) || unit.isByte(after, 0x2C), typeEnd == i + 1, unit.tokens[i].kind == .identifier, !(unit.isByte(at - 1, 0x28) && unit.isToken(at - 2, "try")) {
      if !unit.isByte(after, 0x2C) || !isTypeLike(i) { return nil }
    }
    while k < to, unit.javaIsName(k) {
      let nameToken = Int32(k)
      var j = k + 1
      while unit.isByte(j, 0x5B), unit.isByte(j + 1, 0x5D) { j += 2 }
      if unit.isByte(j, 0x3A), !unit.isToken(j, "::") {
        // for (Type x : e)
        let close = unit.matchingOpenBefore(j).map { unit.skipBalanced($0) - 1 } ?? to
        let kind: JavaLocalKind = isVar ? .element(Int32(j + 1), Int32(close)) : .typed(Int32(i), Int32(typeEnd))
        add(nameToken, from: nameToken, to: forScopeEnd(close, blockEnd: blockEnd), kind: kind)
        return typeEnd
      }
      var kind: JavaLocalKind = .typed(Int32(i), Int32(typeEnd))
      if unit.isToken(j, "=") {
        let start = j + 1
        let end = JavaParser(unit: unit).expressionEnd(start, limit: to)
        if isVar { kind = .inferred(Int32(start), Int32(end)) }
        j = end
      }
      add(nameToken, from: nameToken, to: blockEnd, kind: kind)
      if unit.isByte(j, 0x2C), unit.javaIsName(j + 1), !unit.isByte(at - 1, 0x28) || unit.isToken(at - 2, "for") {
        k = j + 1
        continue
      }
      break
    }
    return typeEnd
  }

  /// A capitalized word reads as a type (`Foo x,` in a lambda's typed parameters).
  private func isTypeLike(_ i: Int) -> Bool {
    let first = unit.source.text[unit.tokens[i].start]
    return first >= 0x41 && first <= 0x5A
  }

  /// A `for` header's names are seen to the end of its body.
  private func forScopeEnd(_ close: Int, blockEnd: Int32) -> Int32 {
    if unit.isByte(close + 1, 0x7B) { return Int32(unit.skipBalanced(close + 1) - 1) }
    return blockEnd
  }

  /// `catch (A | B e)`.
  private func catchParameter(_ open: Int, _ close: Int) {
    var i = open + 1
    while i < close, unit.isToken(i, "final") || unit.tokens[i].kind == .attribute { i = unit.tokens[i].kind == .attribute ? unit.javaSkipAnnotations(i, limit: close) : i + 1 }
    let name = close - 1
    guard name > i, unit.javaIsName(name) else { return }
    let blockEnd = unit.isByte(close + 1, 0x7B) ? Int32(unit.skipBalanced(close + 1) - 1) : Int32(close + 1)
    add(Int32(name), from: Int32(name), to: blockEnd, kind: .typed(Int32(i), Int32(name)))
  }

  /// A lambda's parameters: `x ->` (`paramsOpen` -1) or `(…) ->`, seen in its body.
  private func lambda(paramsOpen: Int, arrow: Int, to: Int) {
    var end: Int
    if unit.isByte(arrow + 1, 0x7B) {
      end = unit.skipBalanced(arrow + 1) - 1
    } else {
      end = JavaParser(unit: unit).expressionEnd(arrow + 1, limit: unit.tokens.count)
    }
    var params: [Int32] = []
    if paramsOpen < 0 {
      params = [Int32(arrow - 1)]
      add(Int32(arrow - 1), from: Int32(arrow - 1), to: Int32(end), kind: .lambda(arrow: Int32(arrow), index: 0))
    } else {
      let close = arrow - 1
      var i = paramsOpen + 1
      var index: Int32 = 0
      while i < close {
        var itemEnd = i
        while itemEnd < close, !unit.isByte(itemEnd, 0x2C) {
          if unit.tokens[itemEnd].kind == .open { itemEnd = unit.skipBalanced(itemEnd); continue }
          if unit.tokens[itemEnd].kind == .punctuation, unit.startsWith(itemEnd, 0x3C), let after = unit.javaTypeArgumentsEnd(itemEnd, limit: close) {
            itemEnd = after
            continue
          }
          itemEnd += 1
        }
        let nameToken = itemEnd - 1
        if nameToken >= i, unit.javaIsName(nameToken) {
          params.append(Int32(nameToken))
          var typeStart = i
          while typeStart < nameToken, unit.isToken(typeStart, "final") || unit.tokens[typeStart].kind == .attribute {
            typeStart = unit.tokens[typeStart].kind == .attribute ? unit.javaSkipAnnotations(typeStart, limit: nameToken) : typeStart + 1
          }
          let kind: JavaLocalKind = nameToken > typeStart && !unit.isToken(typeStart, "var") ? .typed(Int32(typeStart), Int32(nameToken)) : .lambda(arrow: Int32(arrow), index: index)
          add(Int32(nameToken), from: Int32(nameToken), to: Int32(end), kind: kind)
        }
        index += 1
        i = itemEnd + 1
      }
    }
    lambdas[Int32(arrow)] = (params, Int32(arrow + 1), Int32(end))
  }

  /// A pattern from `i`: `Type name`, `final Type name`, `Type(…)` with patterns inside. Returns the token after it.
  @discardableResult
  private func pattern(_ from: Int, to: Int, scopeEnd: Int32) -> Int {
    var i = from
    while i < to, unit.isToken(i, "final") || unit.tokens[i].kind == .attribute { i = unit.tokens[i].kind == .attribute ? unit.javaSkipAnnotations(i, limit: to) : i + 1 }
    guard let typeEnd = unit.isToken(i, "var") ? i + 1 : unit.javaTypeEnd(i, limit: to) else { return from }
    if unit.isByte(typeEnd, 0x28) {
      // A record pattern: the components' patterns.
      let close = unit.skipBalanced(typeEnd) - 1
      var k = typeEnd + 1
      while k < close {
        let next = pattern(k, to: close, scopeEnd: scopeEnd)
        k = next > k ? next : k + 1
        while k < close, !unit.isByte(k, 0x2C) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
        k += 1
      }
      return close + 1
    }
    if unit.javaIsName(typeEnd), !unit.isToken(typeEnd, "when") {
      add(Int32(typeEnd), from: Int32(typeEnd), to: scopeEnd, kind: unit.isToken(i, "var") ? .typed(-1, -1) : .typed(Int32(i), Int32(typeEnd)))
      return typeEnd + 1
    }
    return typeEnd
  }
}
