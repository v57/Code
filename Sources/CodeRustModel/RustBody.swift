import CodeModel
import CodeScan
import Foundation

/// A function body's local bindings, read once asked for: `let` patterns, parameters, closure parameters, `for`,
/// `if let`, `while let` and `match` arms, each with where it's seen and how its type is reached.
final class RustBody: BodyFacts {
  enum Source {
    case annotated(Int32, Int32)
    case initializer(Int32, Int32)
    case iterated(Int32, Int32)
    case matched(Int32, Int32)
    /// A closure's parameter: the closure's `|` and which parameter.
    case closureParameter(Int32, Int32)
    /// A function's parameter by its index in the unit's table.
    case parameter(Int32)
    case none
  }

  /// How a binding is reached in what's matched: `(a, b)`, `Some(x)`, `S { f }`, `&x`, `[a, b]`.
  enum Step: Hashable {
    case deref
    case tuple(Int)
    case tupleStruct(Int32, Int)
    case field(Int32, Name)
    case element
  }

  struct Binding {
    var token: Int32
    var visibleFrom: Int32
    var visibleTo: Int32
    var source: Source
    var steps: [Step]
  }

  let unit: Unit
  let owner: Int32
  var bindings: [Binding] = []
  var byName: [Name: [Int]] = [:]
  var byToken: [Int32: Int] = [:]
  var types: [Int32: Ty] = [:]
  var expressionTypes: [Int64: Ty] = [:]

  init(unit: Unit, owner: Int32) {
    self.unit = unit
    self.owner = owner
    scan()
    for (index, binding) in bindings.enumerated() {
      byName[unit.hash(Int(binding.token)), default: []].append(index)
      byToken[binding.token] = index
    }
  }

  func dropTypes() {
    types.removeAll()
    expressionTypes.removeAll()
  }

  /// The binding a name at a token means: the latest one seen there.
  func binding(named word: Name, at token: Int32) -> Int? {
    guard let list = byName[word] else { return nil }
    var best: Int?
    for index in list {
      let binding = bindings[index]
      guard binding.visibleFrom <= token, token < binding.visibleTo else { continue }
      if let current = best, bindings[current].visibleFrom > binding.visibleFrom { continue }
      best = index
    }
    return best
  }

  private var count: Int { unit.tokens.count }

  private func scan() {
    let item = unit.decls[Int(owner)]
    let start: Int
    let end: Int
    if item.kind == .function {
      start = Int(item.bodyOpen)
      end = Int(item.bodyClose)
    } else {
      start = Int(item.initStart) - 1
      end = Int(item.initEnd)
    }
    guard start >= 0, end > start else { return }
    // Parameters of the function and of every function inside it.
    for index in unit.decls.indices where unit.decls[index].kind == .function {
      let fn = unit.decls[index]
      guard fn.bodyOpen >= 0, (index == Int(owner) || (fn.first > Int32(start) && fn.end <= Int32(end) + 1)) else { continue }
      for p in 0..<Int(fn.paramCount) {
        let param = unit.params[Int(fn.paramStart) + p]
        if param.nameToken >= 0 {
          bindings.append(Binding(token: param.nameToken, visibleFrom: fn.bodyOpen, visibleTo: fn.bodyClose, source: .parameter(fn.paramStart + Int32(p)), steps: []))
        } else if param.typeStart >= 2, unit.isByte(Int(param.typeStart) - 1, 0x3A) {
          // A pattern: from after the `(` or `,` before it to its `:`.
          var k = Int(param.typeStart) - 2
          while k > Int(fn.nameToken), !(unit.isByte(k, 0x2C) || unit.isByte(k, 0x28) && unit.skipBalanced(k) > Int(param.typeStart)) {
            if unit.tokens[k].kind == .close, let open = unit.matchingOpen(k) { k = open - 1 } else { k -= 1 }
          }
          var found: [(Int32, [Step])] = []
          pattern(k + 1, Int(param.typeStart) - 1, [], into: &found)
          for (token, steps) in found {
            bindings.append(Binding(token: token, visibleFrom: fn.bodyOpen, visibleTo: fn.bodyClose, source: .parameter(fn.paramStart + Int32(p)), steps: steps))
          }
        }
      }
    }
    var i = start + 1
    while i < end {
      if unit.isToken(i, "let") {
        i = letBinding(i, end: end)
        continue
      }
      if unit.isToken(i, "for"), !unit.isByte(i + 1, 0x3C) {
        forLoop(i, end: end)
      } else if unit.isToken(i, "match") {
        match(i, end: end)
      } else if unit.isToken(i, "||") || unit.isByte(i, 0x7C), startsClosure(i) {
        closure(i, end: end)
      }
      i += 1
    }
  }

  // MARK: Statements

  /// The block `}` that a token is directly in.
  private func enclosingClose(_ token: Int) -> Int32 {
    var k = token
    while let open = unit.matchingOpenBefore(k) {
      if unit.isByte(open, 0x7B) { return Int32(unit.skipBalanced(open) - 1) }
      k = open
    }
    return Int32(count)
  }

  private func letBinding(_ at: Int, end: Int) -> Int {
    // `if let`, `while let`, a let chain: seen in the block that follows.
    let isCondition = at > 0 && (unit.isToken(at - 1, "if") || unit.isToken(at - 1, "while") || unit.isToken(at - 1, "&&"))
    var k = at + 1
    while k < end, !(unit.isByte(k, 0x3D) || unit.isByte(k, 0x3A) && !unit.isToken(k, "::") || unit.isByte(k, 0x3B)) {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.tokens[k].kind == .close { break }
      k += 1
    }
    let patternEnd = k
    var annotation: (Int, Int)?
    if unit.isByte(k, 0x3A) {
      var e = k + 1
      var level = 0
      while e < end {
        if unit.tokens[e].kind == .open {
          e = unit.skipBalanced(e)
          continue
        }
        if unit.tokens[e].kind == .close { break }
        if unit.isByte(e, 0x3C) { level += 1 } else if unit.isByte(e, 0x3E) { level -= 1 }
        if level <= 0, unit.isByte(e, 0x3D) || unit.isByte(e, 0x3B) { break }
        e += 1
      }
      annotation = (k + 1, e)
      k = e
    }
    var initializer: (Int, Int)?
    var statementEnd = k
    if unit.isByte(k, 0x3D) {
      var e = k + 1
      while e < end {
        if unit.tokens[e].kind == .open {
          // A condition's block ends it.
          if isCondition, unit.isByte(e, 0x7B), !isStructLiteral(e) { break }
          e = unit.skipBalanced(e)
          continue
        }
        if unit.tokens[e].kind == .close || unit.isByte(e, 0x3B) { break }
        if isCondition, unit.isToken(e, "&&") || unit.isToken(e, "||") { break }
        if !isCondition, unit.isToken(e, "else"), unit.isByte(e + 1, 0x7B) { break }
        e += 1
      }
      initializer = (k + 1, e)
      statementEnd = e
    }
    var found: [(Int32, [Step])] = []
    pattern(at + 1, patternEnd, [], into: &found)
    var visibleFrom = Int32(statementEnd)
    var visibleTo = enclosingClose(at)
    if isCondition {
      // To the end of the block after the condition.
      var e = statementEnd
      while e < end, !(unit.isByte(e, 0x7B) && !isStructLiteral(e)) {
        e = unit.tokens[e].kind == .open ? unit.skipBalanced(e) : e + 1
      }
      visibleFrom = Int32(statementEnd)
      visibleTo = e < end ? Int32(unit.skipBalanced(e) - 1) : Int32(end)
    }
    let source: Source = annotation.map { .annotated(Int32($0.0), Int32($0.1)) } ?? initializer.map { .initializer(Int32($0.0), Int32($0.1)) } ?? .none
    for (token, steps) in found {
      var binding = Binding(token: token, visibleFrom: visibleFrom, visibleTo: visibleTo, source: source, steps: steps)
      // `let (a, b): (A, B)`: the steps apply to the annotation too.
      if annotation == nil, initializer == nil { binding.source = .none }
      bindings.append(binding)
    }
    return patternEnd
  }

  /// A `{` right after a path in an expression: `S { a: 1 }`, not a block.
  private func isStructLiteral(_ open: Int) -> Bool {
    guard open > 0, unit.tokens[open - 1].kind == .identifier else { return false }
    let word = unit.string(open - 1)
    guard let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) else { return false }
    // `if x == S {`… isn't allowed without parentheses, so an uppercase path before `{` in a condition is still a block
    // only after a keyword.
    return !(open >= 2 && (unit.isToken(open - 2, "in") || unit.isToken(open - 2, "match") || unit.isToken(open - 2, "if") || unit.isToken(open - 2, "while")))
  }

  private func forLoop(_ at: Int, end: Int) {
    var k = at + 1
    while k < end, !unit.isToken(k, "in") {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.tokens[k].kind == .close || unit.isByte(k, 0x3B) { return }
      k += 1
    }
    guard unit.isToken(k, "in") else { return }
    var e = k + 1
    while e < end, !(unit.isByte(e, 0x7B) && !isStructLiteral(e)) {
      if unit.tokens[e].kind == .close || unit.isByte(e, 0x3B) { return }
      e = unit.tokens[e].kind == .open ? unit.skipBalanced(e) : e + 1
    }
    guard e < end else { return }
    let close = unit.skipBalanced(e) - 1
    var found: [(Int32, [Step])] = []
    pattern(at + 1, k, [], into: &found)
    for (token, steps) in found {
      bindings.append(Binding(token: token, visibleFrom: Int32(e), visibleTo: Int32(close), source: .iterated(Int32(k + 1), Int32(e)), steps: steps))
    }
  }

  private func match(_ at: Int, end: Int) {
    var open = at + 1
    while open < end, !(unit.isByte(open, 0x7B) && !isStructLiteral(open)) {
      if unit.tokens[open].kind == .close || unit.isByte(open, 0x3B) { return }
      open = unit.tokens[open].kind == .open ? unit.skipBalanced(open) : open + 1
    }
    guard open < end else { return }
    let close = unit.skipBalanced(open) - 1
    let scrutinee = (Int32(at + 1), Int32(open))
    var k = open + 1
    while k < close {
      // The pattern, to `=>` or an `if` guard.
      var arrow = k
      var guardToken = -1
      while arrow < close, !unit.isToken(arrow, "=>") {
        if unit.isToken(arrow, "if"), guardToken < 0 { guardToken = arrow }
        arrow = unit.tokens[arrow].kind == .open ? unit.skipBalanced(arrow) : arrow + 1
      }
      guard arrow < close else { return }
      var armEnd = arrow + 1
      if unit.isByte(armEnd, 0x7B) {
        armEnd = unit.skipBalanced(armEnd)
        if unit.isByte(armEnd, 0x2C) { armEnd += 1 }
      } else {
        while armEnd < close, !unit.isByte(armEnd, 0x2C) {
          armEnd = unit.tokens[armEnd].kind == .open ? unit.skipBalanced(armEnd) : armEnd + 1
        }
        if armEnd < close { armEnd += 1 }
      }
      var found: [(Int32, [Step])] = []
      var patternStart = k
      while patternStart < arrow, unit.isByte(patternStart, 0x7C) { patternStart += 1 }
      pattern(patternStart, guardToken >= 0 ? guardToken : arrow, [], into: &found)
      for (token, steps) in found {
        bindings.append(Binding(token: token, visibleFrom: token + 1, visibleTo: Int32(armEnd), source: .matched(scrutinee.0, scrutinee.1), steps: steps))
      }
      k = armEnd
    }
  }

  /// Whether a `|` or `||` starts a closure: not after something a binary `|` would follow.
  private func startsClosure(_ i: Int) -> Bool {
    guard i > 0 else { return true }
    let previous = unit.tokens[i - 1]
    switch previous.kind {
    case .identifier, .number, .string:
      return false
    case .keyword:
      return unit.isToken(i - 1, "move") || unit.isToken(i - 1, "return") || unit.isToken(i - 1, "in") || unit.isToken(i - 1, "async") || unit.isToken(i - 1, "else")
    case .close:
      return unit.isByte(i - 1, 0x7D) && false
    default:
      if unit.isByte(i - 1, 0x3F) { return false }
      return true
    }
  }

  private func closure(_ at: Int, end: Int) {
    var bodyStart: Int
    var parameters: [(Int, Int, Int?)] = []
    if unit.isToken(at, "||") {
      bodyStart = at + 1
    } else {
      var k = at + 1
      var close = k
      var level = 0
      while close < end {
        if unit.tokens[close].kind == .open {
          close = unit.skipBalanced(close)
          continue
        }
        if unit.isByte(close, 0x3C) { level += 1 } else if unit.isByte(close, 0x3E) { level -= 1 }
        if level <= 0, unit.isByte(close, 0x7C) { break }
        if unit.tokens[close].kind == .close { return }
        close += 1
      }
      guard close < end else { return }
      while k < close {
        var e = k
        var colon: Int?
        while e < close, !unit.isByte(e, 0x2C) {
          if colon == nil, unit.isByte(e, 0x3A), !unit.isToken(e, "::") { colon = e }
          e = unit.tokens[e].kind == .open ? unit.skipBalanced(e) : e + 1
        }
        parameters.append((k, colon ?? e, colon.map { _ in e }))
        k = e + 1
      }
      bodyStart = close + 1
    }
    if unit.isToken(bodyStart, "->") {
      var e = bodyStart + 1
      while e < end, !unit.isByte(e, 0x7B) { e = unit.tokens[e].kind == .open ? unit.skipBalanced(e) : e + 1 }
      bodyStart = e
    }
    var bodyEnd: Int
    if unit.isByte(bodyStart, 0x7B) {
      bodyEnd = unit.skipBalanced(bodyStart)
    } else {
      bodyEnd = bodyStart
      while bodyEnd < end, !(unit.isByte(bodyEnd, 0x2C) || unit.isByte(bodyEnd, 0x3B)) {
        if unit.tokens[bodyEnd].kind == .close { break }
        bodyEnd = unit.tokens[bodyEnd].kind == .open ? unit.skipBalanced(bodyEnd) : bodyEnd + 1
      }
    }
    for (index, parameter) in parameters.enumerated() {
      var found: [(Int32, [Step])] = []
      pattern(parameter.0, parameter.1, [], into: &found)
      let source: Source = parameter.2.map { .annotated(Int32(parameter.1 + 1), Int32($0)) } ?? .closureParameter(Int32(at), Int32(index))
      for (token, steps) in found {
        bindings.append(Binding(token: token, visibleFrom: Int32(bodyStart), visibleTo: Int32(bodyEnd), source: source, steps: steps))
      }
    }
  }

  // MARK: Patterns

  /// The names a pattern binds, each with how it's reached.
  func pattern(_ from: Int, _ to: Int, _ steps: [Step], into found: inout [(Int32, [Step])]) {
    var i = from
    // Only the first of `a | b`.
    var end = i
    while end < to, !unit.isByte(end, 0x7C) {
      if unit.tokens[end].kind == .open {
        end = unit.skipBalanced(end)
        continue
      }
      end += 1
    }
    let limit = min(end, to)
    while i < limit, unit.isByte(i, 0x7C) { i += 1 }
    guard i < limit else { return }
    if unit.isByte(i, 0x26) || unit.isToken(i, "&&") {
      var next = i + 1
      if unit.isToken(next, "mut") { next += 1 }
      pattern(next, limit, steps + [.deref], into: &found)
      return
    }
    if unit.isToken(i, "ref") || unit.isToken(i, "mut") || unit.isToken(i, "box") {
      pattern(i + 1, limit, steps, into: &found)
      return
    }
    if unit.isByte(i, 0x28) {
      let close = unit.skipBalanced(i) - 1
      var position = 0
      forEachElement(i + 1, close) { start, stop in
        if unit.isToken(start, "..") { position = -1000 }
        if position >= 0 { pattern(start, stop, steps + [.tuple(position)], into: &found) }
        position += 1
      }
      return
    }
    if unit.isByte(i, 0x5B) {
      let close = unit.skipBalanced(i) - 1
      forEachElement(i + 1, close) { start, stop in
        // `rest @ ..` is a slice.
        if stop - start >= 3, unit.isByte(start + 1, 0x40), unit.isToken(start + 2, "..") {
          found.append((Int32(start), steps))
        } else {
          pattern(start, stop, steps + [.element], into: &found)
        }
      }
      return
    }
    guard unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword else { return }
    // A path.
    var last = i
    if unit.isToken(i, "::") { last += 1 }
    while last + 2 < limit, unit.isToken(last + 1, "::"), unit.tokens[last + 2].kind == .identifier || unit.tokens[last + 2].kind == .keyword { last += 2 }
    if last + 1 < limit, unit.isByte(last + 1, 0x28) {
      let close = unit.skipBalanced(last + 1) - 1
      var position = 0
      forEachElement(last + 2, close) { start, stop in
        if unit.isToken(start, "..") { position = -1000 }
        if position >= 0 { pattern(start, stop, steps + [.tupleStruct(Int32(last), position)], into: &found) }
        position += 1
      }
      return
    }
    if last + 1 < limit, unit.isByte(last + 1, 0x7B) {
      let close = unit.skipBalanced(last + 1) - 1
      forEachElement(last + 2, close) { start, stop in
        var k = start
        while k < stop, unit.isToken(k, "ref") || unit.isToken(k, "mut") || unit.isToken(k, "box") { k += 1 }
        guard k < stop, unit.tokens[k].kind == .identifier || unit.tokens[k].kind == .keyword || unit.tokens[k].kind == .number else { return }
        if unit.isByte(k + 1, 0x3A) {
          pattern(k + 2, stop, steps + [.field(Int32(last), unit.hash(k))], into: &found)
        } else if unit.tokens[k].kind == .identifier {
          found.append((Int32(k), steps + [.field(Int32(last), unit.hash(k))]))
        }
      }
      return
    }
    guard last == i, unit.tokens[i].kind == .identifier else { return }
    if unit.isByte(i + 1, 0x40) {
      found.append((Int32(i), steps))
      pattern(i + 2, limit, steps, into: &found)
      return
    }
    if unit.isToken(i, "_") { return }
    // An uppercase name alone is a constant or a unit variant.
    let first = unit.source.text[unit.tokens[i].start]
    if first >= 0x41 && first <= 0x5A { return }
    if i + 1 < limit, unit.isToken(i + 1, "..") || unit.isToken(i + 1, "..=") || unit.isToken(i + 1, "...") { return }
    found.append((Int32(i), steps))
  }

  private func forEachElement(_ from: Int, _ to: Int, _ body: (Int, Int) -> Void) {
    var k = from
    while k < to {
      var e = k
      while e < to, !unit.isByte(e, 0x2C) {
        e = unit.tokens[e].kind == .open ? unit.skipBalanced(e) : e + 1
      }
      if e > k { body(k, e) }
      k = e + 1
    }
  }
}
