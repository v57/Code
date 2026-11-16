import CodeModel
import CodeScan
import Foundation

/// How a local's type is known.
enum GoLocalKind {
  /// A written type, by its tokens.
  case typed(Int32, Int32)
  /// An initializer's value: the expression's tokens, and which of its values (from 1; 0 for the whole).
  case value(Int32, Int32, index: Int32)
  /// `for k, v := range x`: x's tokens, and whether it's the value (else the key).
  case range(Int32, Int32, isValue: Bool)
  /// `switch v := x.(type)`: x's tokens, and the clause's `case` token (-1 for `default`).
  case typeSwitch(Int32, Int32, clause: Int32)
  /// `case v := <-ch` and `v, ok := <-ch`: what's received from, and which value.
  case receive(Int32, Int32, index: Int32)
  /// A declaration made in the body (a local type): its index in the unit's table.
  case declaration(Int32)
  case label
  case unknown
}

struct GoLocal {
  var name: Name
  var token: Int32
  var scopeStart: Int32
  var scopeEnd: Int32
  var kind: GoLocalKind
}

/// Layer 4 for Go: the names a function (or a variable's initializer) introduces and where each is visible, read once
/// when a position inside asks, and which braces are composite literals, with the type each is written with.
final class GoBody: BodyFacts {
  func dropTypes() { types.removeAll() }

  var locals: [GoLocal] = []
  var byName: [Name: [Int32]] = [:]
  var byToken: [Int32: Int32] = [:]
  /// A composite literal's `{` → its type's tokens, or `start < 0` for an elided one: `-1 - <the enclosing literal's {>`.
  var composites: [Int32: (start: Int32, end: Int32)] = [:]
  /// Function literals' parameter lists by their `func` token, for completion and details.
  var types: [Int32: Ty] = [:]
  var resolving: Set<Int32> = []

  private let unit: Unit
  private var frames: [Set<Name>] = []
  private var parser: GoParser

  init(unit: Unit, owner: Int32) {
    self.unit = unit
    parser = GoParser(unit: unit)
    guard owner >= 0, Int(owner) < unit.decls.count else { return }
    let decl = unit.decls[Int(owner)]
    if decl.kind == .variable {
      // An initializer: its function literals and composite literals.
      if decl.initStart >= 0 {
        frames.append([])
        _ = expressionList(Int(decl.initStart), limit: Int(decl.initEnd))
      }
      return
    }
    guard decl.bodyOpen >= 0 else { return }
    frames.append([])
    // The receiver, the parameters and the named results are the body's outermost names.
    if decl.parent >= 0, unit.decls[Int(decl.parent)].kind == .extensionDecl {
      addParams(of: unit.decls[Int(decl.parent)], scopeStart: decl.first, scopeEnd: decl.end)
    }
    addParams(of: decl, scopeStart: decl.first, scopeEnd: decl.end)
    if decl.typeStart >= 0, unit.isByte(Int(decl.typeStart), 0x28) {
      namedResults(open: Int(decl.typeStart), scopeStart: decl.first, scopeEnd: decl.end)
    }
    statements(from: Int(decl.bodyOpen) + 1, to: Int(decl.bodyClose), scopeEnd: decl.bodyClose)
  }

  // MARK: Names

  private func add(_ name: Name, token: Int, from: Int32, to: Int32, kind: GoLocalKind) {
    guard name != GoWord.blank else { return }
    let index = Int32(locals.count)
    locals.append(GoLocal(name: name, token: Int32(token), scopeStart: from, scopeEnd: to, kind: kind))
    byName[name, default: []].append(index)
    if byToken[Int32(token)] == nil { byToken[Int32(token)] = index }
    if !frames.isEmpty { frames[frames.count - 1].insert(name) }
  }

  private func addParams(of decl: Decl, scopeStart: Int32, scopeEnd: Int32) {
    for p in 0..<Int(decl.paramCount) {
      let param = unit.params[Int(decl.paramStart) + p]
      guard param.nameToken >= 0 else { continue }
      add(param.local, token: Int(param.nameToken), from: scopeStart, to: scopeEnd, kind: .typed(param.typeStart, param.typeEnd))
    }
  }

  /// `(n int, err error)`: named results are locals of the body.
  private func namedResults(open: Int, scopeStart: Int32, scopeEnd: Int32) {
    var decl = Decl(kind: .function, name: 0, nameToken: -1, first: 0, parent: -1)
    let before = unit.params.count
    parser.parametersForBody(open: open, close: unit.skipBalanced(open) - 1, into: &decl)
    addParams(of: decl, scopeStart: scopeStart, scopeEnd: scopeEnd)
    unit.params.removeSubrange(before...)
  }

  /// The local named so that's visible at a token: the innermost.
  func local(named name: Name, at token: Int32, labels: Bool = false) -> Int32? {
    guard let list = byName[name] else { return nil }
    var best: Int32?
    for index in list {
      let local = locals[Int(index)]
      guard local.scopeStart <= token, token < local.scopeEnd else { continue }
      if case .label = local.kind { if !labels { continue } } else if labels { continue }
      if let current = best, locals[Int(current)].scopeStart > local.scopeStart { continue }
      best = index
    }
    return best
  }

  /// Every local visible at a token, innermost first.
  func visible(at token: Int32) -> [Int32] {
    var seen = Set<Name>()
    var result: [Int32] = []
    for index in locals.indices.reversed() {
      let local = locals[index]
      guard local.scopeStart <= token, token < local.scopeEnd else { continue }
      if case .label = local.kind { continue }
      if seen.insert(local.name).inserted { result.append(Int32(index)) }
    }
    return result
  }

  // MARK: Statements

  /// Statements up to `to` (a block's `}`), whose names end at `scopeEnd`.
  private func statements(from: Int, to: Int, scopeEnd: Int32) {
    var i = from
    while i < to {
      let next = statement(i, limit: to, scopeEnd: scopeEnd)
      i = max(next, i + 1)
    }
  }

  private func block(_ open: Int) -> Int {
    let close = unit.skipBalanced(open) - 1
    frames.append([])
    statements(from: open + 1, to: close, scopeEnd: Int32(close))
    frames.removeLast()
    return close + 1
  }

  private func isDefine(_ i: Int) -> Bool {
    unit.isByte(i, 0x3A) && i + 1 < unit.tokens.count && unit.touchesPrevious(i + 1) && unit.source.text[unit.tokens[i + 1].start] == 0x3D
  }

  /// One statement from `i`; returns the token after it.
  private func statement(_ i: Int, limit: Int, scopeEnd: Int32) -> Int {
    guard i < limit else { return limit }
    if unit.isByte(i, 0x3B) { return i + 1 }
    if unit.isByte(i, 0x7B) { return block(i) }
    if unit.tokens[i].kind == .identifier, unit.isByte(i + 1, 0x3A), !isDefine(i + 1), !unit.isByte(i + 2, 0x3A) {
      // A label.
      add(unit.hash(i), token: i, from: 0, to: Int32(unit.tokens.count), kind: .label)
      return i + 2
    }
    if unit.isToken(i, "var") || unit.isToken(i, "const") || unit.isToken(i, "type") {
      return localDeclaration(i, limit: limit, scopeEnd: scopeEnd)
    }
    if unit.isToken(i, "if") { return ifStatement(i, limit: limit) }
    if unit.isToken(i, "for") { return forStatement(i, limit: limit) }
    if unit.isToken(i, "switch") { return switchStatement(i, limit: limit) }
    if unit.isToken(i, "select") { return selectStatement(i, limit: limit) }
    if unit.isToken(i, "case") || unit.isToken(i, "default") {
      // Stray, as in code being typed: past its colon.
      var k = i + 1
      while k < limit, !unit.isByte(k, 0x3A) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
      return k + 1
    }
    return simpleStatement(i, limit: limit, scopeEnd: scopeEnd, header: false).end
  }

  /// `a, b := x`, `x = y`, `f()`, `x++`, `go f()`, `return a, b`. With `header`, a `{` at depth 0 ends it.
  private func simpleStatement(_ i: Int, limit: Int, scopeEnd: Int32, header: Bool, namesFrom: Int32? = nil) -> (end: Int, defined: [Int]) {
    var names: [Int] = []
    var k = i
    while k < limit, unit.tokens[k].kind == .identifier {
      names.append(k)
      if unit.isByte(k + 1, 0x2C) { k += 2 } else { k += 1; break }
    }
    if !names.isEmpty, isDefine(k) {
      let valueStart = k + 2
      if unit.isToken(valueStart, "range") {
        let end = expression(valueStart + 1, limit: limit, header: header)
        for (position, token) in names.enumerated() {
          define(token, from: namesFrom ?? Int32(end), to: scopeEnd, kind: .range(Int32(valueStart + 1), Int32(end), isValue: position == 1))
        }
        return (end, names)
      }
      var values: [(Int, Int)] = []
      var v = valueStart
      var end = valueStart
      while true {
        end = expression(v, limit: limit, header: header)
        values.append((v, end))
        guard unit.isByte(end, 0x2C) else { break }
        v = end + 1
      }
      for (position, token) in names.enumerated() {
        let kind: GoLocalKind
        if values.count == names.count {
          kind = .value(Int32(values[position].0), Int32(values[position].1), index: 0)
        } else if let only = values.first, values.count == 1 {
          if unit.isToken(only.0, "<-") {
            kind = .receive(Int32(only.0 + 1), Int32(only.1), index: Int32(position + 1))
          } else {
            kind = .value(Int32(only.0), Int32(only.1), index: Int32(position + 1))
          }
        } else {
          kind = .unknown
        }
        define(token, from: namesFrom ?? Int32(end), to: scopeEnd, kind: kind)
      }
      return (end, names)
    }
    // Anything else: expressions and the operators between them, to the statement's end.
    var at = i
    while at < limit {
      let end = expression(at, limit: limit, header: header)
      if end >= limit { return (limit, []) }
      if unit.isByte(end, 0x2C) || (unit.tokens[end].kind == .punctuation && !unit.isByte(end, 0x3B) && !unit.isByte(end, 0x3A)) {
        at = end + 1
        continue
      }
      if isDefine(end) {
        at = end + 2
        continue
      }
      return (end, [])
    }
    return (limit, [])
  }

  /// A name `:=` makes: new unless the same block has it already (then it's assigned).
  private func define(_ token: Int, from: Int32, to: Int32, kind: GoLocalKind) {
    let name = unit.hash(token)
    if let frame = frames.last, frame.contains(name) {
      // Assigned, not declared: a use of the earlier one.
      return
    }
    add(name, token: token, from: from, to: to, kind: kind)
  }

  /// `var x T = v`, `const (…)`, `type T struct {…}` in a body: visible from the spec's end to the block's.
  private func localDeclaration(_ i: Int, limit: Int, scopeEnd: Int32) -> Int {
    let before = unit.decls.count
    let end = parser.genDecl(i, parent: -1, isLocal: true)
    for index in before..<unit.decls.count {
      let decl = unit.decls[index]
      guard decl.parent == -1, decl.name != 0 else { continue }
      if decl.kind == .variable {
        // Values are locals, not declarations (the table keeps the entry for its anonymous struct types).
        unit.decls[index].nameToken = -1
        unit.decls[index].name = 0
        let kind: GoLocalKind = decl.typeStart >= 0 ? .typed(decl.typeStart, decl.typeEnd) : decl.initStart >= 0 ? .value(decl.initStart, decl.initEnd, index: decl.valueIndex) : .unknown
        add(decl.name, token: Int(decl.nameToken), from: decl.end, to: scopeEnd, kind: kind)
        if decl.initStart >= 0, decl.valueIndex <= 1 { _ = expression(Int(decl.initStart), limit: Int(decl.initEnd), header: false) }
      } else {
        // A local type: the name is the declaration's, from its own name on (it may refer to itself).
        add(decl.name, token: Int(decl.nameToken), from: decl.nameToken, to: scopeEnd, kind: .declaration(Int32(index)))
      }
    }
    return min(end, limit)
  }

  // MARK: Compound statements

  /// `if [init;] cond { } else …`: the init's names last to the end of the whole chain.
  private func ifStatement(_ at: Int, limit: Int) -> Int {
    frames.append([])
    defer { frames.removeLast() }
    let headerEnd = headerOpen(at + 1, limit: limit)
    let chainEnd = Int32(ifChainEnd(headerEnd, limit: limit))
    header(at + 1, headerEnd, scopeEnd: chainEnd)
    guard unit.isByte(headerEnd, 0x7B) else { return headerEnd }
    var i = block(headerEnd)
    if unit.isToken(i, "else") {
      if unit.isToken(i + 1, "if") {
        i = ifStatement(i + 1, limit: limit)
      } else if unit.isByte(i + 1, 0x7B) {
        i = block(i + 1)
      }
    }
    return i
  }

  private func ifChainEnd(_ open: Int, limit: Int) -> Int {
    guard unit.isByte(open, 0x7B) else { return open }
    var i = unit.skipBalanced(open)
    while unit.isToken(i, "else") {
      if unit.isToken(i + 1, "if") {
        let next = headerOpen(i + 2, limit: limit)
        guard unit.isByte(next, 0x7B) else { return next }
        i = unit.skipBalanced(next)
      } else if unit.isByte(i + 1, 0x7B) {
        i = unit.skipBalanced(i + 1)
      } else {
        break
      }
    }
    return i
  }

  /// The `{` that ends a header: the first at depth 0, past function literals' bodies.
  private func headerOpen(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      if unit.isToken(i, "func"), unit.isByte(i + 1, 0x28) {
        i = functionLiteralEnd(i, limit: limit)
        continue
      }
      if let open = typeLiteralOpen(i, limit: limit) {
        i = unit.skipBalanced(open)
        continue
      }
      if unit.isByte(i, 0x7B) { return i }
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.tokens[i].kind == .close { return i }
      i += 1
    }
    return limit
  }

  /// The `{` of a composite literal written with a type literal at `i` (`[]T{…}`, `map[K]V{…}`, `struct{…}{…}`): one a
  /// header may hold, unlike a type name's.
  private func typeLiteralOpen(_ i: Int, limit: Int) -> Int? {
    if unit.isByte(i, 0x5B) {
      // Not an index or an instantiation: `a[i]`, `f()[i]`.
      if i > 0 {
        let kind = unit.tokens[i - 1].kind
        if kind == .identifier || kind == .close || kind == .string || kind == .number { return nil }
      }
    } else if !(unit.isToken(i, "map") && unit.isByte(i + 1, 0x5B)) && !(unit.isToken(i, "struct") && unit.isByte(i + 1, 0x7B)) {
      return nil
    }
    let end = parser.typeEnd(i, limit: limit)
    return end > i && end < limit && unit.isByte(end, 0x7B) ? end : nil
  }

  /// A header's statements, `;`-separated: names from the first are visible to the rest and to `scopeEnd`.
  private func header(_ from: Int, _ to: Int, scopeEnd: Int32) {
    var i = from
    while i < to {
      let result = simpleStatement(i, limit: to, scopeEnd: scopeEnd, header: true)
      i = max(result.end, i + 1)
      if unit.isByte(i, 0x3B) { i += 1 }
    }
  }

  /// `for`, `for cond`, `for init; cond; post`, `for k, v := range x`.
  private func forStatement(_ at: Int, limit: Int) -> Int {
    frames.append([])
    defer { frames.removeLast() }
    let open = headerOpen(at + 1, limit: limit)
    guard unit.isByte(open, 0x7B) else { return open }
    let close = Int32(unit.skipBalanced(open) - 1)
    var i = at + 1
    while i < open {
      let result = simpleStatement(i, limit: open, scopeEnd: close, header: true)
      i = max(result.end, i + 1)
      if unit.isByte(i, 0x3B) { i += 1 }
    }
    return block(open)
  }

  /// `switch [init;] [x] { case …: … }`, and type switches with their name per clause.
  private func switchStatement(_ at: Int, limit: Int) -> Int {
    frames.append([])
    defer { frames.removeLast() }
    let open = headerOpen(at + 1, limit: limit)
    guard unit.isByte(open, 0x7B) else { return open }
    let close = unit.skipBalanced(open) - 1
    // `v := x.(type)`, after an optional init.
    var guardName = -1
    var subject: (Int32, Int32) = (-1, -1)
    var i = at + 1
    var segments: [(Int, Int)] = []
    var s = i
    while s < open {
      var e = s
      while e < open, !unit.isByte(e, 0x3B) { e = unit.tokens[e].kind == .open ? unit.skipBalanced(e) : e + 1 }
      segments.append((s, e))
      s = e + 1
    }
    if let last = segments.last, last.1 - last.0 >= 4, unit.isToken(last.1 - 1, ")"), unit.isToken(last.1 - 2, "type"), unit.isByte(last.1 - 3, 0x28), unit.isByte(last.1 - 4, 0x2E) {
      if unit.tokens[last.0].kind == .identifier, isDefine(last.0 + 1) {
        guardName = last.0
        subject = (Int32(last.0 + 3), Int32(last.1 - 4))
      } else {
        subject = (Int32(last.0), Int32(last.1 - 4))
      }
      if segments.count > 1 { header(segments[0].0, segments[0].1, scopeEnd: Int32(close)) }
      _ = expression(Int(subject.0), limit: Int(subject.1), header: true)
    } else {
      header(i, open, scopeEnd: Int32(close))
    }
    // The clauses.
    i = open + 1
    while i < close {
      guard unit.isToken(i, "case") || unit.isToken(i, "default") else {
        i = statement(i, limit: close, scopeEnd: Int32(close))
        continue
      }
      let caseToken = i
      var colon = i + 1
      while colon < close, !unit.isByte(colon, 0x3A) {
        if unit.isToken(colon, "func"), unit.isByte(colon + 1, 0x28) {
          colon = functionLiteralEnd(colon, limit: close)
          continue
        }
        colon = unit.tokens[colon].kind == .open ? unit.skipBalanced(colon) : colon + 1
      }
      if subject.0 < 0 { _ = expressionList(caseToken + 1, limit: colon, header: false) }
      let clauseEnd = clauseEnd(colon + 1, limit: close)
      frames.append([])
      if guardName >= 0 {
        add(unit.hash(guardName), token: guardName, from: Int32(colon + 1), to: Int32(clauseEnd), kind: .typeSwitch(subject.0, subject.1, clause: unit.isToken(caseToken, "case") ? Int32(caseToken) : -1))
      }
      statements(from: colon + 1, to: clauseEnd, scopeEnd: Int32(clauseEnd))
      frames.removeLast()
      i = clauseEnd
    }
    return close + 1
  }

  /// The next `case` or `default` at this depth, or the `}`.
  private func clauseEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      if unit.isToken(i, "case") || unit.isToken(i, "default") { return i }
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      i += 1
    }
    return limit
  }

  /// `select { case v, ok := <-ch: … }`.
  private func selectStatement(_ at: Int, limit: Int) -> Int {
    guard unit.isByte(at + 1, 0x7B) else { return at + 1 }
    let open = at + 1
    let close = unit.skipBalanced(open) - 1
    var i = open + 1
    while i < close {
      guard unit.isToken(i, "case") || unit.isToken(i, "default") else {
        i = statement(i, limit: close, scopeEnd: Int32(close))
        continue
      }
      var colon = i + 1
      while colon < close, !unit.isByte(colon, 0x3A) || isDefine(colon) {
        if isDefine(colon) {
          colon += 2
          continue
        }
        colon = unit.tokens[colon].kind == .open ? unit.skipBalanced(colon) : colon + 1
      }
      let end = clauseEnd(colon + 1, limit: close)
      frames.append([])
      if unit.isToken(i, "case") { _ = simpleStatement(i + 1, limit: colon, scopeEnd: Int32(end), header: false, namesFrom: Int32(colon + 1)) }
      statements(from: colon + 1, to: end, scopeEnd: Int32(end))
      frames.removeLast()
      i = end
    }
    return close + 1
  }

  // MARK: Expressions

  private func expressionList(_ from: Int, limit: Int, header: Bool = false) -> Int {
    var i = from
    while i < limit {
      let end = expression(i, limit: limit, header: header)
      guard unit.isByte(end, 0x2C) else { return end }
      i = end + 1
    }
    return limit
  }

  /// An expression from `i`, scanning its function literals and composite literals; returns where it ends: at a `,`,
  /// `;`, `:`, `=`, `:=`, a line break that ends a statement, a closing bracket, or with `header` a `{`.
  private func expression(_ from: Int, limit: Int, header: Bool) -> Int {
    var i = from
    var typeStart = from
    while i < limit {
      let token = unit.tokens[i]
      if unit.isToken(i, "func"), unit.isByte(i + 1, 0x28) {
        i = functionLiteral(i, limit: limit)
        typeStart = i
        if i < limit, unit.startsLine(i), unit.goEndsLine(i - 1) { return i }
        continue
      }
      if unit.isToken(i, "struct"), unit.isByte(i + 1, 0x7B) {
        parser.anonymousStructs(from: i, to: i + 2, parent: -1, isLocal: true)
        i = unit.skipBalanced(i + 1)
        continue
      }
      if unit.isToken(i, "interface"), unit.isByte(i + 1, 0x7B) {
        parser.anonymousStructs(from: i, to: i + 2, parent: -1, isLocal: true)
        i = unit.skipBalanced(i + 1)
        continue
      }
      switch token.kind {
      case .open:
        let byte = unit.source.text[token.start]
        if byte == 0x7B {
          if header, !(typeStart < i && typeLiteralOpen(typeStart, limit: limit) == i) { return i }
          compositeLiteral(i, typeStart: typeStart)
          i = unit.skipBalanced(i)
          if i < limit, unit.startsLine(i) { return i }
          continue
        }
        let close = unit.skipBalanced(i) - 1
        if byte == 0x28 || byte == 0x5B {
          // Arguments, indexes and parenthesized expressions, each a list of their own.
          var k = i + 1
          while k < close {
            let end = expression(k, limit: close, header: false)
            k = end + 1
          }
        }
        i = close + 1
        if i < limit, unit.startsLine(i), unit.goEndsLine(i - 1) { return i }
        continue
      case .close:
        return i
      case .punctuation:
        if unit.isByte(i, 0x2C) || unit.isByte(i, 0x3B) || unit.isByte(i, 0x3A) { return i }
        let text = unit.source.text[token.start]
        // Assignment operators end an expression; comparisons don't.
        if text == 0x3D, token.length == 1 || unit.source.text[token.start + 1] != 0x3D { return i }
        if token.length >= 2, unit.source.text[token.start + token.length - 1] == 0x3D, !unit.isToken(i, "==") && !unit.isToken(i, "!=") && !unit.isToken(i, "<=") && !unit.isToken(i, ">=") {
          return i
        }
        if unit.isToken(i, "++") || unit.isToken(i, "--") { return i + 1 }
        // A composite's type starts after an operator: `&T{}`, `x == T{}`.
        // `[]*T{}`'s `*` is the type's.
        if !unit.isByte(i, 0x2E), !(unit.isByte(i, 0x2A) && i > 0 && unit.isByte(i - 1, 0x5D)) { typeStart = i + 1 }
      case .keyword, .declarationKeyword:
        if unit.isToken(i, "range") || unit.isToken(i, "return") || unit.isToken(i, "go") || unit.isToken(i, "defer") { typeStart = i + 1 }
      default:
        break
      }
      i += 1
      if i < limit, unit.startsLine(i), unit.goEndsLine(i - 1) { return i }
    }
    return limit
  }

  /// `T{…}` (or an elided `{…}` inside another literal): its type, then its elements.
  private func compositeLiteral(_ open: Int, typeStart: Int) {
    let close = unit.skipBalanced(open) - 1
    if typeStart < open {
      composites[Int32(open)] = (Int32(typeStart), Int32(open))
    } else if let outer = enclosingComposite(open) {
      composites[Int32(open)] = (-1 - outer, -1)
    }
    var i = open + 1
    while i < close {
      // `Key: value`, `value`.
      let end = expression(i, limit: close, header: false)
      if unit.isByte(end, 0x3A) {
        i = end + 1
        continue
      }
      i = end + 1
    }
  }

  /// The composite literal whose elements a `{` is among, if any.
  func enclosingComposite(_ token: Int) -> Int32? {
    guard let open = unit.matchingOpenBefore(token), unit.isByte(open, 0x7B), composites[Int32(open)] != nil else { return nil }
    return Int32(open)
  }

  /// `func(a int) (r T) { … }`: its parameters are the body's names.
  private func functionLiteral(_ at: Int, limit: Int) -> Int {
    let end = functionLiteralEnd(at, limit: limit)
    var decl = Decl(kind: .function, name: 0, nameToken: -1, first: Int32(at), parent: -1)
    let paramsClose = unit.skipBalanced(at + 1)
    let before = unit.params.count
    parser.parametersForBody(open: at + 1, close: paramsClose - 1, into: &decl)
    guard let open = bodyOpen(of: at, end: end) else {
      unit.params.removeSubrange(before...)
      return end
    }
    let close = Int32(end - 1)
    frames.append([])
    addParams(of: decl, scopeStart: Int32(open), scopeEnd: close)
    unit.params.removeSubrange(before...)
    if unit.isByte(paramsClose, 0x28) { namedResults(open: paramsClose, scopeStart: Int32(open), scopeEnd: close) }
    statements(from: open + 1, to: Int(close), scopeEnd: close)
    frames.removeLast()
    return end
  }

  private func bodyOpen(of at: Int, end: Int) -> Int? {
    guard end > 0, unit.isByte(end - 1, 0x7D) else { return nil }
    return unit.matchingOpen(end - 1)
  }

  /// Past a function literal's body (or its type, when it has none).
  func functionLiteralEnd(_ at: Int, limit: Int) -> Int {
    var i = unit.skipBalanced(at + 1)
    if unit.isByte(i, 0x7B) { return unit.skipBalanced(i) }
    i = parser.typeEnd(i, limit: limit)
    if unit.isByte(i, 0x7B) { return unit.skipBalanced(i) }
    return i
  }
}

extension GoParser {
  /// A parameter list read for a body's names.
  mutating func parametersForBody(open: Int, close: Int, into decl: inout Decl) {
    parameters(open: open, close: close, into: &decl)
  }
}

extension Unit {
  /// The bracket a token is directly inside, walking back.
  func matchingOpenBefore(_ token: Int) -> Int? {
    var depth = 0
    var i = token - 1
    var budget = 4096
    while i >= 0, budget > 0 {
      budget -= 1
      switch tokens[i].kind {
      case .close: depth += 1
      case .open:
        if depth == 0 { return i }
        depth -= 1
      default: break
      }
      i -= 1
    }
    return nil
  }
}
