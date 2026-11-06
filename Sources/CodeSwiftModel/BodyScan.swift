import CodeScan
import Foundation

/// Layer 4's first half: the names a body introduces and where each is visible, read once when a position inside asks.
enum LocalKind {
  case written(Int32, Int32)
  case initializer(Int32, Int32, unwrap: Bool)
  case forIn(start: Int32, end: Int32, slot: Int32)
  case tupleSlot(start: Int32, end: Int32, slot: Int32)
  case closureParam(open: Int32, index: Int32)
  case pattern(caseToken: Int32, index: Int32, subjectStart: Int32, subjectEnd: Int32)
  case declaration(Int32)
  case unknown
}

struct Local {
  var name: Name
  var token: Int32
  var scopeStart: Int32
  var scopeEnd: Int32
  var kind: LocalKind
  var hasSite = true
}

struct ClosureInfo {
  var open: Int32
  var close: Int32
  var hasNames: Bool
}

struct SwitchInfo {
  var open: Int32
  var close: Int32
  var subjectStart: Int32
  var subjectEnd: Int32
}

final class BodyScan {
  var locals: [Local] = []
  var byName: [Name: [Int32]] = [:]
  var byToken: [Int32: Int32] = [:]
  var byInitializer: [Int32: Int32] = [:]
  var closures: [ClosureInfo] = []
  var closureOpens: Set<Int32> = []
  var switches: [SwitchInfo] = []
  var types: [Int32: Ty] = [:]
  var resolving: Set<Int32> = []

  private let unit: Unit
  private let owner: Int32

  private enum FrameKind { case block, closure, other, switchBlock }
  private struct Frame {
    var open: Int32
    var kind: FrameKind
    var pending: [Int32] = []
    var index: Int32 = -1
    var inCurrentCase: [Int32] = []
  }

  private var stack: [Frame] = []
  private var expectBlock = -1
  private var guardDepth = -1
  private var pendingCondition: [Int32] = []
  private var pendingSwitch: (Int32, Int32)?
  private var caseToken: Int32 = -1
  private var caseDepth = -1

  init(unit: Unit, owner: Int32) {
    self.unit = unit
    self.owner = owner
    run()
  }

  private var parser: DeclParser { DeclParser(unit: unit) }

  private func add(_ local: Local, scoped: Bool = true) -> Int32 {
    let index = Int32(locals.count)
    locals.append(local)
    byName[local.name, default: []].append(index)
    byToken[local.token] = index
    return index
  }

  /// Adds a name that ends with the current block, or with the block its condition opens.
  private func bind(name: Name, token: Int, kind: LocalKind, end: Int32, from: Int32? = nil) {
    // `let url = url.x` reads the outer one: a name starts after its initializer.
    let index = add(Local(name: name, token: Int32(token), scopeStart: from ?? Int32(token + 1), scopeEnd: end, kind: kind))
    // `case .foo(let x)`: the name outlives the parentheses it's written in.
    let depth = caseToken >= 0 && caseDepth < stack.count ? caseDepth : stack.count
    if expectBlock == depth, guardDepth != depth {
      pendingCondition.append(index)
    } else if depth > 0 {
      stack[depth - 1].pending.append(index)
      if stack[depth - 1].kind == .switchBlock { stack[depth - 1].inCurrentCase.append(index) }
    }
  }

  /// A switch's next `case` or `default`: what the last one bound is out of scope.
  private func endCase(at token: Int) {
    guard let last = stack.indices.last, stack[last].kind == .switchBlock, !stack[last].inCurrentCase.isEmpty else { return }
    let ended = Set(stack[last].inCurrentCase)
    for index in ended { locals[Int(index)].scopeEnd = Int32(token) }
    stack[last].pending.removeAll { ended.contains($0) }
    stack[last].inCurrentCase = []
  }

  private func run() {
    var start = 0
    var end = unit.tokens.count
    var skips: [(Int, Int)] = []
    if owner >= 0 {
      let decl = unit.decls[Int(owner)]
      start = Int(decl.initStart >= 0 ? decl.initStart : decl.bodyOpen)
      end = Int(decl.end)
      guard start >= 0 else { return }
      addParams(of: owner, scopeStart: decl.first, scopeEnd: decl.end)
      // `newValue` and `oldValue`, so that they're not taken for anything else.
      if decl.kind == .variable, decl.bodyOpen >= 0 {
        for implicit in [Word.newValue, Word.oldValue] {
          var kind = LocalKind.unknown
          if decl.typeStart >= 0 {
            kind = .written(decl.typeStart, decl.typeEnd)
          } else if decl.initStart >= 0, decl.initEnd > decl.initStart {
            kind = .initializer(decl.initStart, decl.initEnd, unwrap: false)
          }
          // They stand for the accessor that has them, as far as going to a definition goes.
          let accessor = accessorToken(for: implicit, in: decl)
          _ = add(Local(name: implicit, token: accessor ?? -1 - Int32(locals.count), scopeStart: decl.bodyOpen, scopeEnd: decl.end, kind: kind, hasSite: accessor != nil))
        }
      }
    } else {
      for decl in unit.decls where decl.parent < 0 && !decl.isLocal { skips.append((Int(decl.first), Int(decl.end))) }
    }
    var i = start
    var next = 0
    // A declaration's body is no closure, which a `{` nothing expected would be taken for.
    if owner >= 0, unit.decls[Int(owner)].initStart < 0 { expectBlock = stack.count }
    while i < end {
      while next < skips.count, skips[next].1 <= i { next += 1 }
      if next < skips.count, skips[next].0 == i {
        i = max(skips[next].1, i + 1)
        continue
      }
      step(&i, end: Int32(end))
    }
    for frame in stack { patch(frame, end: Int32(end)) }
  }

  private func accessorToken(for implicit: Name, in decl: Decl) -> Int32? {
    var k = Int(decl.bodyOpen) + 1
    while k < Int(decl.end) {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if implicit == Word.oldValue ? unit.isToken(k, "didSet") : unit.isToken(k, "willSet") || unit.isToken(k, "set") { return Int32(k) }
      k += 1
    }
    return nil
  }

  private func addParams(of declIndex: Int32, scopeStart: Int32, scopeEnd: Int32) {
    let decl = unit.decls[Int(declIndex)]
    for p in 0..<Int(decl.paramCount) {
      let param = unit.params[Int(decl.paramStart) + p]
      guard param.local != Word.underscore else { continue }
      _ = add(Local(name: param.local, token: param.nameToken, scopeStart: scopeStart, scopeEnd: scopeEnd, kind: .written(param.typeStart, param.typeEnd)))
    }
  }

  private func patch(_ frame: Frame, end: Int32) {
    for index in frame.pending { locals[Int(index)].scopeEnd = end }
    if frame.index >= 0 { closures[Int(frame.index)].close = end }
  }

  private func step(_ i: inout Int, end: Int32) {
    let token = unit.tokens[i]
    switch token.kind {
    case .directive:
      i = unit.takeDirective(i)
    case .open:
      open(&i, end: end)
    case .interpolationOpen:
      stack.append(Frame(open: Int32(i), kind: .other))
      i += 1
    case .close, .interpolationClose:
      // A `}` ends what code being typed left open inside it.
      if unit.isByte(i, 0x7D) {
        while let last = stack.last, last.kind == .other {
          patch(last, end: Int32(i))
          stack.removeLast()
        }
      }
      if let frame = stack.popLast() {
        patch(frame, end: Int32(i))
        if frame.kind == .switchBlock, let index = switches.firstIndex(where: { $0.open == frame.open }) { switches[index].close = Int32(i) }
      }
      i += 1
    case .keyword, .declarationKeyword:
      word(&i, end: end)
    case .punctuation:
      // A pattern ends at its `:` or `=`.
      if caseToken >= 0, stack.count == caseDepth, unit.isByte(i, 0x3A) || unit.isByte(i, 0x3D) { caseToken = -1 }
      i += 1
    default:
      i += 1
    }
  }

  private func open(_ i: inout Int, end: Int32) {
    guard unit.isByte(i, 0x7B) else {
      stack.append(Frame(open: Int32(i), kind: .other))
      i += 1
      return
    }
    // Nor is an accessor's.
    if owner >= 0, stack.count == 1, unit.decls[Int(owner)].kind.isAccessorHolder, unit.isToken(i - 1, "get") || unit.isToken(i - 1, "set") || unit.isToken(i - 1, "didSet") || unit.isToken(i - 1, "willSet") || unit.isToken(i - 1, "_read") || unit.isToken(i - 1, "_modify") {
      expectBlock = stack.count
    }
    if expectBlock == stack.count {
      var frame = Frame(open: Int32(i), kind: pendingSwitch == nil ? .block : .switchBlock)
      frame.pending = pendingCondition
      pendingCondition = []
      if let subject = pendingSwitch {
        switches.append(SwitchInfo(open: Int32(i), close: end, subjectStart: subject.0, subjectEnd: subject.1))
        pendingSwitch = nil
      }
      expectBlock = -1
      if guardDepth == stack.count { guardDepth = -1 }
      caseToken = -1
      stack.append(frame)
      i += 1
      return
    }
    // Not a statement's block: a closure.
    let index = Int32(closures.count)
    let open = Int32(i)
    let close = Int32(unit.skipBalanced(i) - 1)
    var frame = Frame(open: open, kind: .closure, index: index)
    closures.append(ClosureInfo(open: open, close: close, hasNames: false))
    closureOpens.insert(open)
    i += 1
    var j = i
    if unit.isByte(j, 0x5B) {
      // `[weak self, a = b.c, d]`: names for the closure, read from outside it.
      let listEnd = unit.skipBalanced(j)
      var k = j + 1
      while k < listEnd - 1 {
        var itemEnd = k
        while itemEnd < listEnd - 1, !unit.isByte(itemEnd, 0x2C) {
          if unit.tokens[itemEnd].kind == .open { itemEnd = unit.skipBalanced(itemEnd) } else { itemEnd += 1 }
        }
        var at = k
        while at < itemEnd, unit.isToken(at, "weak") || unit.isToken(at, "unowned") || unit.isByte(at, 0x28) || unit.isByte(at, 0x29) || unit.isToken(at, "safe") || unit.isToken(at, "unsafe") { at += 1 }
        if at < itemEnd, unit.tokens[at].kind == .identifier {
          var kind = LocalKind.initializer(Int32(at), Int32(at + 1), unwrap: false)
          if unit.isByte(at + 1, 0x3D) { kind = .initializer(Int32(at + 2), Int32(itemEnd), unwrap: false) }
          let local = add(Local(name: unit.hash(at), token: Int32(at), scopeStart: Int32(listEnd), scopeEnd: close, kind: kind))
          frame.pending.append(local)
        }
        k = itemEnd + 1
      }
      j = listEnd
    }
    var names: [(Int, Int32, Int32)] = []
    var header = false
    if unit.isByte(j, 0x28) {
      let paren = unit.skipBalanced(j)
      var k = paren
      while k < unit.tokens.count, unit.isToken(k, "async") || unit.isToken(k, "throws") { k += 1 }
      if unit.isToken(k, "->") { k = parser.skipType(k + 1) }
      if unit.isToken(k, "in") {
        header = true
        var m = j + 1
        while m < paren - 1 {
          guard unit.tokens[m].kind == .identifier || unit.tokens[m].kind == .keyword else {
            m += 1
            continue
          }
          let at = m
          m += 1
          var range: (Int32, Int32) = (-1, -1)
          if unit.isByte(m, 0x3A) {
            let typeEnd = parser.skipType(m + 1)
            range = (Int32(m + 1), Int32(typeEnd))
            m = typeEnd
          }
          names.append((at, range.0, range.1))
          while m < paren - 1, !unit.isByte(m, 0x2C) { m += 1 }
          m += 1
        }
        j = k
      }
    } else {
      var k = j
      var found: [(Int, Int32, Int32)] = []
      // `prefix` and the like are names here, whatever the lexer thinks of them.
      while k < unit.tokens.count, unit.tokens[k].kind == .identifier || unit.tokens[k].kind == .keyword || unit.tokens[k].kind == .declarationKeyword, !unit.isToken(k, "in") {
        found.append((k, -1, -1))
        k += 1
        guard unit.isByte(k, 0x2C) else { break }
        k += 1
      }
      if unit.isToken(k, "in"), !found.isEmpty {
        header = true
        names = found
        j = k
      } else if unit.isToken(j, "in") {
        header = true
      }
    }
    if header {
      closures[Int(index)].hasNames = true
      i = j + 1
      for (slot, item) in names.enumerated() where unit.hash(item.0) != Word.underscore {
        let kind: LocalKind = item.1 >= 0 ? .written(item.1, item.2) : .closureParam(open: open, index: Int32(slot))
        let local = add(Local(name: unit.hash(item.0), token: Int32(item.0), scopeStart: Int32(item.0), scopeEnd: close, kind: kind))
        frame.pending.append(local)
      }
    }
    stack.append(frame)
  }

  private func word(_ i: inout Int, end: Int32) {
    if i > 0, unit.isByte(i - 1, 0x2E) || unit.isToken(i - 1, "?.") {
      i += 1
      return
    }
    // `style(for: kind)`: a label, not a loop.
    if unit.isByte(i + 1, 0x3A), unit.isByte(i - 1, 0x28) || unit.isByte(i - 1, 0x2C) {
      i += 1
      return
    }
    if unit.isToken(i, "default") { endCase(at: i) }
    let token = unit.tokens[i]
    switch token.length {
    case 2:
      if unit.isToken(i, "if") {
        expectBlock = stack.count
        caseToken = -1
      } else if unit.isToken(i, "do") {
        expectBlock = stack.count
      }
    case 3:
      if unit.isToken(i, "let") || unit.isToken(i, "var") {
        binding(&i, end: end)
        return
      }
      if unit.isToken(i, "for") {
        forLoop(&i, end: end)
        return
      }
    case 4:
      if unit.isToken(i, "else") {
        expectBlock = stack.count
      } else if unit.isToken(i, "case") {
        endCase(at: i)
        caseToken = Int32(i)
        caseDepth = stack.count
      } else if unit.isToken(i, "func") {
        localDeclaration(&i)
        return
      } else if unit.isToken(i, "enum") {
        localDeclaration(&i)
        return
      }
    case 5:
      if unit.isToken(i, "while") {
        expectBlock = stack.count
        caseToken = -1
      } else if unit.isToken(i, "guard") {
        expectBlock = stack.count
        guardDepth = stack.count
        caseToken = -1
      } else if unit.isToken(i, "defer") {
        expectBlock = stack.count
      } else if unit.isToken(i, "catch") {
        expectBlock = stack.count
        caseToken = Int32(i)
        caseDepth = stack.count
        pendingCondition.append(add(Local(name: Word.error, token: -1 - Int32(locals.count), scopeStart: Int32(i), scopeEnd: end, kind: .unknown, hasSite: false)))
      } else if unit.isToken(i, "class") {
        localDeclaration(&i)
        return
      }
    case 6:
      if unit.isToken(i, "repeat") {
        expectBlock = stack.count
      } else if unit.isToken(i, "switch") {
        var j = i + 1
        let subjectStart = j
        while j < Int(end), !unit.isByte(j, 0x7B) {
          if unit.tokens[j].kind == .open { j = unit.skipBalanced(j) } else { j += 1 }
        }
        pendingSwitch = (Int32(subjectStart), Int32(j))
        expectBlock = stack.count
      } else if unit.isToken(i, "struct") {
        localDeclaration(&i)
        return
      }
    case 8:
      if unit.isToken(i, "protocol") {
        localDeclaration(&i)
        return
      }
    case 9:
      if unit.isToken(i, "typealias") {
        localDeclaration(&i)
        return
      }
    default:
      break
    }
    i += 1
  }

  private func localDeclaration(_ i: inout Int) {
    var j = i
    let before = unit.decls.count
    var local = DeclParser(unit: unit)
    local.parseDeclaration(&j, parent: owner, isLocal: true)
    guard unit.decls.count > before else {
      i += 1
      return
    }
    // A type's members come after it, so the type is the first one in.
    let index = Int32(before)
    let decl = unit.decls[Int(index)]
    let frameOpen = stack.last?.open ?? Int32(max(0, i - 1))
    let entry = add(Local(name: decl.name, token: decl.nameToken, scopeStart: frameOpen, scopeEnd: Int32(unit.tokens.count), kind: .declaration(index)))
    if !stack.isEmpty { stack[stack.count - 1].pending.append(entry) }
    if decl.kind == .function, decl.bodyOpen >= 0 {
      addParams(of: index, scopeStart: decl.first, scopeEnd: decl.end)
      expectBlock = stack.count
      i = Int(decl.bodyOpen)
    } else {
      i = j
    }
  }

  /// The end of an expression in a condition or a statement: `{` ends it only in a condition.
  private func expressionEnd(_ start: Int, inCondition: Bool, end: Int32) -> Int {
    guard inCondition else { return parser.skipExpression(start) }
    var i = start
    while i < Int(end) {
      switch unit.tokens[i].kind {
      case .open:
        if unit.isByte(i, 0x7B) { return i }
        i = unit.skipBalanced(i)
        continue
      case .close, .interpolationClose: return i
      case .punctuation:
        if unit.isByte(i, 0x2C) { return i }
      case .keyword:
        // `guard let a = b else`.
        if unit.isToken(i, "else") { return i }
      default: break
      }
      i += 1
    }
    return i
  }

  private func binding(_ i: inout Int, end: Int32) {
    i += 1
    let inCondition = expectBlock == stack.count
    let inCase = caseToken >= 0
    while i < Int(end) {
      if unit.isByte(i, 0x2E), inCase {
        // `case let .foo(a, b)`.
        let caseName = i + 1
        i += 2
        if unit.isByte(i, 0x28) {
          patternNames(open: i, caseName: caseName, end: end)
          i = unit.skipBalanced(i)
        }
        return
      }
      if unit.isByte(i, 0x28) {
        let close = unit.skipBalanced(i)
        var after = close
        var range: (Int32, Int32) = (-1, -1)
        if unit.isByte(after, 0x3D) {
          let finish = expressionEnd(after + 1, inCondition: inCondition, end: end)
          range = (Int32(after + 1), Int32(finish))
          after += 1
        }
        var slot: Int32 = 0
        var k = i + 1
        while k < close - 1 {
          if unit.tokens[k].kind == .identifier {
            if unit.hash(k) != Word.underscore {
              bind(name: unit.hash(k), token: k, kind: range.0 >= 0 ? .tupleSlot(start: range.0, end: range.1, slot: slot) : .unknown, end: end)
            }
          } else if unit.isByte(k, 0x2C) {
            slot += 1
          }
          k += 1
        }
        i = after
        return
      }
      guard i < Int(end), unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword || unit.isByte(i, 0x60) else { return }
      let at = unit.isByte(i, 0x60) ? i + 1 : i
      i += unit.isByte(i, 0x60) ? 3 : 1
      var kind = LocalKind.unknown
      var typeRange: (Int32, Int32) = (-1, -1)
      if unit.isByte(i, 0x3A) {
        let finish = parser.skipType(i + 1)
        typeRange = (Int32(i + 1), Int32(finish))
        kind = .written(typeRange.0, typeRange.1)
        i = finish
      } else if inCase, unit.isToken(i, "as") {
        // `case let a as T`, in a switch or a loop.
        let finish = parser.skipType(i + 1)
        typeRange = (Int32(i + 1), Int32(finish))
        kind = .written(typeRange.0, typeRange.1)
        i = finish
      }
      var initialized = false
      if unit.isByte(i, 0x3D) {
        initialized = true
        i += 1
        let finish = expressionEnd(i, inCondition: inCondition, end: end)
        if typeRange.0 < 0 { kind = .initializer(Int32(i), Int32(finish), unwrap: inCondition && !inCase) }
        byInitializer[Int32(i)] = Int32(locals.count)
        if inCase, typeRange.0 < 0 { kind = .unknown }
        bind(name: unit.hash(at), token: at, kind: kind, end: end, from: Int32(finish))
        // Inside the initializer there may be closures: the loop goes on through it.
        let chained = !inCondition && unit.isByte(finish, 0x2C) && !inCase
        if !chained { return }
        // Walk the expression, then come back for the next name.
        var k = i
        while k < finish { step(&k, end: end) }
        i = finish + 1
        continue
      }
      if inCondition, !inCase, typeRange.0 < 0, !initialized {
        // `if let x {`: this name read just before it's bound.
        kind = .initializer(Int32(at), Int32(at + 1), unwrap: true)
      } else if inCase, typeRange.0 < 0 {
        kind = patternKind(at: at, end: end)
      }
      bind(name: unit.hash(at), token: at, kind: kind, end: end)
      if !inCondition, !inCase, unit.isByte(i, 0x2C) {
        if i + 1 < Int(end), unit.tokens[i + 1].kind == .identifier {
          i += 1
          continue
        }
      }
      return
    }
  }

  private func patternNames(open: Int, caseName: Int, end: Int32) {
    let close = unit.skipBalanced(open)
    var slot: Int32 = 0
    var k = open + 1
    let subject = caseSubject(from: open, end: end)
    while k < close - 1 {
      if unit.isByte(k, 0x2C) {
        slot += 1
      } else if unit.tokens[k].kind == .identifier, unit.hash(k) != Word.underscore {
        if !unit.isByte(k + 1, 0x3A) {
          bind(name: unit.hash(k), token: k, kind: .pattern(caseToken: Int32(caseName), index: slot, subjectStart: subject.0, subjectEnd: subject.1), end: end)
        }
      }
      k += 1
    }
  }

  /// `.foo(let x)`: the case and which payload it is.
  private func patternKind(at: Int, end: Int32) -> LocalKind {
    var depth = 0
    var slot: Int32 = 0
    var k = at - 1
    while k >= 0, k > Int(caseToken) {
      if unit.tokens[k].kind == .close { depth += 1 }
      if unit.tokens[k].kind == .open {
        if depth == 0 {
          guard k > 0, unit.tokens[k - 1].kind == .identifier || unit.tokens[k - 1].kind == .keyword else { return .unknown }
          let subject = caseSubject(from: at, end: end)
          return .pattern(caseToken: Int32(k - 1), index: slot, subjectStart: subject.0, subjectEnd: subject.1)
        }
        depth -= 1
      }
      if depth == 0, unit.isByte(k, 0x2C) { slot += 1 }
      k -= 1
    }
    let subject = caseSubject(from: at, end: end)
    return subject.0 >= 0 ? .initializer(subject.0, subject.1, unwrap: false) : .unknown
  }

  /// What a pattern takes apart: the `=` of `if case`, or the switch around it.
  private func caseSubject(from: Int, end: Int32) -> (Int32, Int32) {
    // By the `case`'s depth: inside `.foo(let x)` this is a level deeper.
    if expectBlock == stack.count || (caseToken >= 0 && expectBlock == caseDepth) {
      var k = from
      while k < Int(end), !unit.isByte(k, 0x7B) {
        if unit.tokens[k].kind == .open {
          k = unit.skipBalanced(k)
          continue
        }
        if unit.isByte(k, 0x3D) {
          return (Int32(k + 1), Int32(expressionEnd(k + 1, inCondition: true, end: end)))
        }
        k += 1
      }
      return (-1, -1)
    }
    if let open = stack.last(where: { $0.kind == .switchBlock })?.open, let info = switches.first(where: { $0.open == open }) {
      return (info.subjectStart, info.subjectEnd)
    }
    return (-1, -1)
  }

  private func forLoop(_ i: inout Int, end: Int32) {
    expectBlock = stack.count
    var j = i + 1
    if unit.isToken(j, "case") {
      caseToken = Int32(j)
      caseDepth = stack.count
      i = j + 1
      return
    }
    if unit.isToken(j, "try") || unit.isToken(j, "await") { j += 1 }
    var patternEnd = j
    var depth = 0
    while patternEnd < Int(end), !(depth == 0 && unit.isToken(patternEnd, "in")) {
      if unit.tokens[patternEnd].kind == .open { depth += 1 }
      if unit.tokens[patternEnd].kind == .close { depth -= 1 }
      patternEnd += 1
    }
    guard patternEnd < Int(end) else {
      // No `in`: not a loop after all.
      i += 1
      return
    }
    let start = patternEnd + 1
    let finish = expressionEnd(start, inCondition: true, end: end)
    let isTuple = unit.isByte(j, 0x28)
    var slot: Int32 = 0
    var k = j
    while k < patternEnd {
      if unit.isByte(k, 0x3A) { break }
      if unit.isByte(k, 0x2C) { slot += 1 }
      if unit.tokens[k].kind == .identifier || unit.tokens[k].kind == .keyword, unit.hash(k) != Word.underscore {
        bind(name: unit.hash(k), token: k, kind: .forIn(start: Int32(start), end: Int32(finish), slot: isTuple ? slot : -1), end: end)
      }
      k += 1
    }
    i = start
  }

  /// The innermost visible local of that name at a token, if any.
  func local(named: Name, at token: Int32) -> Int32? {
    guard let list = byName[named] else { return nil }
    var best: Int32?
    var bestStart: Int32 = -1
    for index in list {
      let local = locals[Int(index)]
      if local.scopeStart <= token, token < local.scopeEnd, local.scopeStart >= bestStart {
        best = index
        bestStart = local.scopeStart
      }
    }
    return best
  }

  func innermostClosure(at token: Int32, needsUnnamed: Bool = false) -> ClosureInfo? {
    var best: ClosureInfo?
    for closure in closures where closure.open < token && token < closure.close {
      if needsUnnamed, closure.hasNames { continue }
      if best == nil || closure.open > best!.open { best = closure }
    }
    return best
  }
}
