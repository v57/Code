import CodeModel
import CodeScan
import Foundation

/// How a local variable gets a value where it's bound, for its type.
enum RubyBinding {
  /// `x = …`, `x ||= …`: the value's tokens.
  case assign(Int32, Int32)
  /// A method's parameter: the method, which one.
  case parameter(Int32, Int32)
  /// A block's or lambda's parameter: its scope, which one.
  case blockParameter(Int32, Int32)
  /// `rescue A, B => e`: the classes' tokens.
  case rescued(Int32, Int32)
  /// `for x in list`: what's walked.
  case element(Int32, Int32)
  /// Bound without a value that can be told (`a, b = …`).
  case untyped
}

/// A file's local variables, as Ruby's parser tells them: a name is a local where an assignment to it (or a
/// parameter) came before in its scope or a block around it, up to a method, class or module (gates); a block's own
/// assignments stay its own. Each use answers the first binding. Scanned once per file, when a question first lands
/// on a name that may be one.
final class RubyBody: BodyFacts {
  static let key = Int32.min + 1
  /// Each local's tokens (uses and bindings) to its first binding.
  var definition: [Int32: Int32] = [:]
  /// Every binding of a local, by its first binding, in order.
  var bindings: [Int32: [(token: Int32, how: RubyBinding)]] = [:]
  /// The scope a local's first binding is in.
  var scopeOf: [Int32: Int32] = [:]
  var types: [Int32: Ty] = [:]
  var resolving: Set<Int32> = []

  func dropTypes() { types.removeAll() }

  init(unit: Unit, structure: RubyStructure) {
    scan(unit, structure)
  }

  /// The binding a use at `token` reads: the last one before it (the first if none is).
  func binding(of definition: Int32, before token: Int32) -> (token: Int32, how: RubyBinding)? {
    guard let list = bindings[definition] else { return nil }
    var found = list.first
    for item in list where item.token < token { found = item }
    return found
  }

  private func scan(_ unit: Unit, _ structure: RubyStructure) {
    let scopes = structure.scopes
    let count = unit.tokens.count
    var vars: [[Name: Int32]] = Array(repeating: [:], count: scopes.count)
    var stack: [Int32] = [0]
    var next = 1
    var isParam = Set<Int32>()
    var declNames = Set<Int32>()
    for decl in unit.decls { declNames.insert(decl.nameToken) }

    func lookup(_ word: Name) -> Int32? {
      for index in stack.reversed() {
        if let found = vars[Int(index)][word] { return found }
        if scopes[Int(index)].isGate { return nil }
      }
      return nil
    }

    func bind(_ token: Int, _ how: RubyBinding, newScope: Bool = false) {
      let word = unit.hash(token)
      let here = stack.last!
      if !newScope, let found = lookup(word) {
        definition[Int32(token)] = found
        bindings[found, default: []].append((Int32(token), how))
        return
      }
      vars[Int(here)][word] = Int32(token)
      definition[Int32(token)] = Int32(token)
      bindings[Int32(token)] = [(Int32(token), how)]
      scopeOf[Int32(token)] = here
    }

    func enter(_ index: Int) {
      stack.append(Int32(index))
      let scope = scopes[index]
      if scope.kind == .method, scope.decl >= 0 {
        let decl = unit.decls[Int(scope.decl)]
        for p in 0..<Int(decl.paramCount) {
          let token = Int(unit.params[Int(decl.paramStart) + p].nameToken)
          bind(token, .parameter(scope.decl, Int32(p)), newScope: true)
          isParam.insert(Int32(token))
        }
      } else if scope.kind == .block || scope.kind == .lambda, scope.paramStart >= 0 {
        var position: Int32 = 0
        var k = Int(scope.paramStart)
        var depth = 0
        var skipping = false
        while k < Int(scope.paramEnd) {
          let token = unit.tokens[k]
          if token.kind == .open { depth += 1 } else if token.kind == .close { depth -= 1 }
          if token.kind == .punctuation {
            let last = unit.source.text[token.end - 1]
            // After `=` a default value follows, to the next `,`.
            if last == 0x3D { skipping = true } else if last == 0x2C || last == 0x7C || last == 0x3B || last == 0x2A || last == 0x26 { skipping = false }
          } else if unit.isByte(k, 0x2C) || unit.isByte(k, 0x3B) {
            skipping = false
          } else if token.kind == .open {
            skipping = false
          }
          if !skipping, unit.rbIsPlain(k), depth >= 0 {
            let previous = k - 1
            let afterSeparator = k == Int(scope.paramStart) || unit.tokens[previous].kind == .open || unit.tokens[previous].kind == .punctuation || unit.isByte(previous, 0x2C)
            if afterSeparator, !unit.isByte(previous, 0x3D) {
              bind(k, .blockParameter(Int32(index), position), newScope: true)
              isParam.insert(Int32(k))
              position += 1
              // `k:` with a default: skip it.
              if unit.isByte(k + 1, 0x3A), unit.touchesPrevious(k + 1), !unit.isByte(k + 2, 0x2C), !unit.isToken(k + 2, "|") { skipping = true }
            }
          }
          k += 1
        }
      }
    }

    var i = 0
    while i < count {
      while stack.count > 1, Int(scopes[Int(stack.last!)].close) < i { stack.removeLast() }
      while next < scopes.count, Int(scopes[next].open) <= i {
        while stack.count > 1, Int(scopes[Int(stack.last!)].close) < Int(scopes[next].open) { stack.removeLast() }
        enter(next)
        next += 1
      }
      defer { i += 1 }
      guard unit.rbIsPlain(i), !isParam.contains(Int32(i)), !declNames.contains(Int32(i)) else { continue }
      // A method's name after `.`, `::` or `def`; a label `name:`; a call `name(`.
      if unit.rbIsDot(i - 1) || unit.rbIsColon2(i - 1) || unit.isToken(i - 1, "def") && !unit.rbIsDot(i + 1) { continue }
      if unit.isByte(i + 1, 0x3A), unit.touchesPrevious(i + 1), !unit.rbIsColon2(i + 1) { continue }
      if let how = assignment(unit, i) {
        bind(i, how)
        continue
      }
      if unit.isByte(i + 1, 0x28), unit.touchesPrevious(i + 1) { continue }
      if unit.isToken(i - 1, "def") {
        // `def obj.x`: `obj` is read where the method is written.
        let inner = stack.removeLast()
        if let found = lookup(unit.hash(i)) { definition[Int32(i)] = found }
        stack.append(inner)
        continue
      }
      // `file "x" => …` calls `file` even where a local of that name is in scope, as Ruby's grammar reads it.
      if Self.isCommandCall(unit, i) { continue }
      if let found = lookup(unit.hash(i)) { definition[Int32(i)] = found }
    }
  }

  /// A name followed on its line, after a space, by an argument: a string, symbol, number or another name.
  static func isCommandCall(_ unit: Unit, _ i: Int) -> Bool {
    let next = i + 1
    guard next < unit.tokens.count, !unit.touchesPrevious(next), !unit.startsLine(next) else { return false }
    switch unit.tokens[next].kind {
    case .string, .number: return true
    case .identifier: return true
    default: return false
    }
  }

  /// Whether `i` is bound here: `x = …`, `x += …`, `a, b = …`, `for x in`, `rescue … => e`.
  private func assignment(_ unit: Unit, _ i: Int) -> RubyBinding? {
    let next = i + 1
    if Self.isAssignOperator(unit, next) {
      let start = next + 1
      return .assign(Int32(start), Int32(unit.rbStatementEnd(start, limit: unit.tokens.count)))
    }
    // `rescue A => e`.
    if unit.isToken(i - 1, "=>") {
      var k = i - 2
      while k >= 0 {
        if unit.isToken(k, "rescue") { return .rescued(Int32(k + 1), Int32(i - 1)) }
        if unit.startsLine(k) { break }
        k -= 1
      }
    }
    // `for a, b in list`.
    var k = i - 1
    while k >= 0, unit.isByte(k, 0x2C) || unit.rbIsPlain(k) { k -= 1 }
    if unit.isToken(k, "for") {
      var j = i + 1
      while j < unit.tokens.count, !unit.isToken(j, "in") { j += 1 }
      return .element(Int32(j + 1), Int32(unit.rbStatementEnd(j + 1, limit: unit.tokens.count)))
    }
    // `a, (b, c), *d = …`: a statement's targets before a `=`.
    if unit.isByte(i + 1, 0x2C) || unit.isByte(i - 1, 0x2C) || unit.isByte(i + 1, 0x29) || unit.punctuation(i - 1, madeOf: "*(") {
      let start = unit.rbStatementStart(i)
      let end = unit.rbStatementEnd(start, limit: unit.tokens.count)
      var j = start
      var sawComma = false
      while j < end {
        if unit.isByte(j, 0x2C) {
          sawComma = true
        } else if unit.isToken(j, "=") {
          return sawComma && j > i ? .untyped : nil
        } else if !(unit.rbIsIdentifier(j) || unit.tokens[j].kind == .open || unit.tokens[j].kind == .close || unit.punctuation(j, madeOf: "*") || unit.rbIsDot(j)) {
          return nil
        }
        j += 1
      }
    }
    return nil
  }

  static func isAssignOperator(_ unit: Unit, _ k: Int) -> Bool {
    guard k < unit.tokens.count, unit.tokens[k].kind == .punctuation else { return false }
    let token = unit.tokens[k]
    let text = unit.source.text
    guard text[token.end - 1] == 0x3D else { return false }
    if token.length == 1 { return true }
    // `+=`, `||=`, `<<=`; not `==`, `!=`, `>=`, `<=`, `===`.
    let first = text[token.start]
    if token.length == 2 { return first != 0x3D && first != 0x21 && first != 0x3E && first != 0x3C }
    if token.length == 3 { return (first == 0x7C || first == 0x26 || first == 0x2A || first == 0x3C || first == 0x3E) && text[token.start + 1] == first }
    return false
  }
}
