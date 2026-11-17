import CodeModel
import CodeScan
import Foundation

/// Expressions' types, read backwards from where they end: a receiver before `.`, a `let`'s initializer.
extension RustModel {
  // MARK: Bodies

  /// The outermost function (or constant) whose body holds a token: closures and nested functions are read with it.
  func owner(unitIndex: Int32, token: Int32) -> Int32? {
    let unit = project.units[Int(unitIndex)]
    for index in unit.chain(at: token) {
      let item = unit.decls[Int(index)]
      // The signature too: its parameters are the body's first locals.
      if item.kind == .function, item.bodyOpen >= 0, item.first <= token, token < item.bodyClose { return index }
      if item.kind == .variable, item.initStart >= 0, item.initStart <= token, token < item.initEnd { return index }
    }
    return nil
  }

  func body(unitIndex: Int32, token: Int32) -> RustBody? {
    guard let owner = owner(unitIndex: unitIndex, token: token) else { return nil }
    let unit = project.units[Int(unitIndex)]
    if let known = unit.scans[owner] { return unsafeDowncast(known, to: RustBody.self) }
    let scan = RustBody(unit: unit, owner: owner)
    unit.scans[owner] = scan
    return scan
  }

  /// A local a name at a token means (a parameter's, a `let`'s, a pattern's), or `self`.
  func localSite(_ word: Name, unitIndex: Int32, token: Int32) -> Entity? {
    guard let body = body(unitIndex: unitIndex, token: token), let index = body.binding(named: word, at: token) else { return nil }
    return .local(unitIndex, body.bindings[index].token)
  }

  /// A local's type: from its annotation, initializer, what's iterated or matched, through its pattern.
  func localType(unitIndex: Int32, token: Int32) -> Ty {
    guard let body = body(unitIndex: unitIndex, token: token), let index = body.byToken[token] else { return .unknown }
    if let known = body.types[token] { return known }
    body.types[token] = .unknown
    let binding = body.bindings[index]
    var base: Ty
    switch binding.source {
    case .annotated(let start, let end): base = typeFrom(unitIndex, start, end)
    case .initializer(let start, let end): base = expressionType(unitIndex, Int(start), Int(end))
    case .iterated(let start, let end): base = itemType(expressionType(unitIndex, Int(start), Int(end)))
    case .matched(let start, let end): base = expressionType(unitIndex, Int(start), Int(end))
    case .parameter(let index): base = parameterType(unitIndex, index)
    case .closureParameter(let bar, let position): base = closureParameterType(unitIndex, Int(bar), Int(position))
    case .none: base = .unknown
    }
    let unit = project.units[Int(unitIndex)]
    for step in binding.steps {
      switch step {
      case .deref:
        base = peelOnce(base)
      case .tuple(let position):
        if case .tuple(let items, _) = peelReferences(base), position < items.count { base = items[position] } else { base = .unknown }
      case .element:
        base = elementType(peelReferences(base))
      case .tupleStruct(let pathToken, let position):
        base = patternField(unitIndex, Int(pathToken), matched: base, field: name(String(position)))
      case .field(let pathToken, let word):
        base = patternField(unitIndex, Int(pathToken), matched: base, field: word)
      }
      if base == .unknown { break }
    }
    _ = unit
    body.types[token] = base
    return base
  }

  private func peelOnce(_ ty: Ty) -> Ty {
    if case .constructed(let kind, let args) = ty, kind == RustTy.reference, let inner = args.first { return inner }
    return ty
  }

  /// A field of what a pattern's path names (a variant or a struct), as the matched type has it.
  private func patternField(_ unitIndex: Int32, _ pathToken: Int, matched: Ty, field: Name) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let (segments, qualified) = pathSegments(unit, to: pathToken)
    guard let entity = resolvePath(unitIndex, segments, qualified: qualified, namespace: .value).first ?? resolvePath(unitIndex, segments, qualified: qualified, namespace: .type).first
    else { return .unknown }
    var holderRef: DeclRef
    switch entity {
    case .decl(let ref):
      holderRef = ref
      if decl(ref).kind == .typeAlias, let target = typeDecl(of: aliasType(ref, [])) { holderRef = target }
    default: return .unknown
    }
    let item = decl(holderRef)
    let typeRef = item.kind == .enumCase ? DeclRef(unit: holderRef.unit, decl: item.parent) : holderRef
    var args: [Ty] = []
    if case .nominal(let ref, let matchedArgs) = peelReferences(matched), ref == typeRef { args = matchedArgs }
    let holder = self.unit(holderRef)
    for child in holder.children(of: holderRef.decl) where holder.decls[Int(child)].kind == .variable && holder.decls[Int(child)].name == field {
      let fieldDecl = holder.decls[Int(child)]
      guard fieldDecl.typeStart >= 0 else { return .unknown }
      return substitute(typeFrom(holderRef.unit, fieldDecl.typeStart, fieldDecl.typeEnd), genericMap(typeRef, args))
    }
    return .unknown
  }

  /// A function parameter's type; `self`'s is the impl's type (behind `&` as written).
  func parameterType(_ unitIndex: Int32, _ index: Int32) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let param = unit.params[Int(index)]
    if param.label == RustWord.selfValue {
      let selfTy = selfType(unitIndex: unitIndex, token: param.nameToken)
      if param.typeStart > param.nameToken { return typeFrom(unitIndex, param.typeStart, param.typeEnd) }
      return unit.isByte(Int(param.typeStart), 0x26) || unit.isToken(Int(param.typeStart), "&&") ? .constructed(RustTy.reference, [selfTy]) : selfTy
    }
    return typeFrom(unitIndex, param.typeStart, param.typeEnd)
  }

  /// A closure parameter's type from what it's passed to: `xs.iter().map(|x| …)` gives x the iterator's item, as
  /// the method's `F: FnMut(Self::Item)` says.
  func closureParameterType(_ unitIndex: Int32, _ bar: Int, _ position: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard let open = unit.matchingOpenBefore(bar), unit.isByte(open, 0x28), open >= 1 else { return .unknown }
    // Which argument the closure is.
    var argument = 0
    var k = open + 1
    while k < bar {
      if unit.isByte(k, 0x2C) { argument += 1 }
      k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
    }
    var nameToken = open - 1
    var turbofish: (Int, Int)?
    if unit.isByte(nameToken, 0x3E) {
      var level = 0
      var j = nameToken
      while j > 0 {
        if unit.isByte(j, 0x3E) { level += 1 } else if unit.isByte(j, 0x3C) {
          level -= 1
          if level == 0 { break }
        }
        j -= 1
      }
      guard j >= 2, unit.isToken(j - 1, "::") else { return .unknown }
      turbofish = (j + 1, nameToken)
      nameToken = j - 2
    }
    _ = turbofish
    guard unit.tokens[nameToken].kind == .identifier else { return .unknown }
    var callee: DeclRef?
    var map: [Name: Ty] = [:]
    var selfTy: Ty?
    if nameToken >= 1, unit.isByte(nameToken - 1, 0x2E) {
      let receiver = operandType(unitIndex, dot: nameToken - 1)
      guard let hit = memberHits(of: receiver, named: unit.hash(nameToken), call: true, at: (unitIndex, Int32(nameToken))).first else { return .unknown }
      callee = hit.ref
      map = hit.map
      selfTy = hit.receiver
    } else {
      let (segments, qualified) = pathSegments(unit, to: nameToken)
      if case .decl(let ref)? = resolvePath(unitIndex, segments, qualified: qualified, namespace: .value).first, decl(ref).kind == .function { callee = ref }
    }
    guard let callee else { return .unknown }
    let item = decl(callee)
    let holder = self.unit(callee)
    // Methods count `self` as a parameter.
    var index = argument
    if item.paramCount > 0, holder.params[Int(item.paramStart)].label == RustWord.selfValue, nameToken >= 1, unit.isByte(nameToken - 1, 0x2E) { index += 1 }
    guard index < Int(item.paramCount) else { return .unknown }
    let param = holder.params[Int(item.paramStart) + index]
    let declared = typeFrom(callee.unit, param.typeStart, param.typeEnd)
    var bounds: [Ty] = []
    switch declared {
    case .param(let word, let owner?): bounds = self.bounds(of: word, owner: owner)
    case .existential(let list): bounds = list
    case .function(let args, _): return position < args.count ? substitute(args[position], map, selfType: selfTy) : .unknown
    default: break
    }
    for bound in bounds {
      guard case .nominal(let trait, let args) = bound, [RustWord.fnTrait, RustWord.fnMut, RustWord.fnOnce].contains(decl(trait).name) else { continue }
      guard case .tuple(let inputs, _)? = args.first, position < inputs.count else { continue }
      return substitute(inputs[position], map, selfType: selfTy)
    }
    return .unknown
  }

  /// What `for x in e` gives x: an iterator's `Item`, through `IntoIterator`.
  func itemType(_ ty: Ty) -> Ty {
    let peeled = peelReferences(ty)
    let isReference = peeled != ty
    switch peeled {
    case .constructed(let kind, let args) where kind == Ty.slice || kind == Ty.array:
      guard let element = args.first else { return .unknown }
      return isReference ? .constructed(RustTy.reference, [element]) : element
    case .nominal(let ref, let args):
      let word = decl(ref).name
      if word == RustWord.vec || word == name("VecDeque") || word == name("HashSet") || word == name("BTreeSet") {
        guard let element = args.first else { return .unknown }
        return isReference ? .constructed(RustTy.reference, [element]) : element
      }
      if word == name("HashMap") || word == name("BTreeMap"), args.count >= 2 {
        return isReference ? .tuple([.constructed(RustTy.reference, [args[0]]), .constructed(RustTy.reference, [args[1]])], []) : .tuple([args[0], args[1]], [])
      }
      if word == RustWord.range || word == RustWord.rangeInclusive { return args.first ?? .unknown }
    default:
      break
    }
    if let item = associatedType(of: ty, named: RustWord.item, trait: RustWord.iterator) { return item }
    if let item = associatedType(of: ty, named: RustWord.item, trait: RustWord.intoIterator) { return item }
    if case .param = peeled {
      let found = normalize(.dependent(peeled, RustWord.item))
      if case .dependent = found { return .unknown }
      return found
    }
    if case .existential = peeled {
      let found = normalize(.dependent(peeled, RustWord.item))
      if case .dependent = found { return .unknown }
      return found
    }
    return .unknown
  }

  func elementType(_ ty: Ty) -> Ty {
    switch ty {
    case .constructed(let kind, let args) where kind == Ty.slice || kind == Ty.array: return args.first ?? .unknown
    case .nominal(let ref, let args) where decl(ref).name == RustWord.vec || decl(ref).name == name("VecDeque"): return args.first ?? .unknown
    default: return .unknown
    }
  }

  // MARK: Expressions

  /// An expression's type, from `start` to before `end`.
  func expressionType(_ unitIndex: Int32, _ start: Int, _ end: Int) -> Ty {
    guard start < end else { return .unknown }
    let unit = project.units[Int(unitIndex)]
    let key = Int64(start) << 32 | Int64(end)
    let scan = body(unitIndex: unitIndex, token: Int32(start))
    if let scan, let known = scan.expressionTypes[key] { return known }
    depth += 1
    defer { depth -= 1 }
    guard depth < 48 else { return .unknown }
    scan?.expressionTypes[key] = .unknown
    let result = computeExpressionType(unitIndex, unit, start, end)
    scan?.expressionTypes[key] = result
    return result
  }

  private func computeExpressionType(_ unitIndex: Int32, _ unit: Unit, _ start: Int, _ end: Int) -> Ty {
    // Top level: `as`, comparisons, ranges, arithmetic.
    var k = start
    var lastAs = -1
    var comparison = false
    var range = -1
    var arithmetic = -1
    var assignment = false
    while k < end {
      let token = unit.tokens[k]
      if token.kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.isToken(k, "::"), unit.isByte(k + 1, 0x3C) {
        k = angleClose(unit, k + 1) + 1
        continue
      }
      if token.kind == .keyword {
        if unit.isToken(k, "as") { lastAs = k }
        // A closure's or a block's own operators aren't this expression's.
      } else if token.kind == .punctuation {
        if unit.isToken(k, "==") || unit.isToken(k, "!=") || unit.isToken(k, "<=") || unit.isToken(k, ">=") || unit.isToken(k, "&&") || unit.isToken(k, "||") {
          comparison = true
        } else if unit.isByte(k, 0x3C) || unit.isByte(k, 0x3E) {
          if k > start, isOperandEnd(unit, k - 1) { comparison = true }
        } else if unit.isToken(k, "..") || unit.isToken(k, "..=") {
          if range < 0 { range = k }
        } else if unit.isByte(k, 0x3D) || unit.isToken(k, "+=") || unit.isToken(k, "-=") {
          assignment = true
        } else if k > start, isOperandEnd(unit, k - 1), unit.isByte(k, 0x2B) || unit.isByte(k, 0x2D) || unit.isByte(k, 0x2A) || unit.isByte(k, 0x2F) || unit.isByte(k, 0x25)
          || unit.isByte(k, 0x26) || unit.isByte(k, 0x7C) || unit.isByte(k, 0x5E)
        {
          if arithmetic < 0 { arithmetic = k }
        }
      }
      k += 1
    }
    if unit.isByte(start, 0x7C) || unit.isToken(start, "||") || unit.isToken(start, "move") { return .unknown }
    if assignment { return .tuple([], []) }
    if comparison { return primitive("bool") }
    if range >= 0 {
      let element = range > start ? expressionType(unitIndex, start, range) : (range + 1 < end ? expressionType(unitIndex, range + 1, end) : .unknown)
      return stdNominal(unit.isToken(range, "..=") ? "RangeInclusive" : "Range", [element])
    }
    if lastAs >= 0 { return typeFrom(unitIndex, lastAs + 1, end) }
    if arithmetic >= 0 {
      let left = expressionType(unitIndex, start, arithmetic)
      return left
    }
    // Prefix operators.
    if unit.isByte(start, 0x26) || unit.isToken(start, "&&") {
      var next = start + 1
      if unit.isToken(next, "mut") { next += 1 }
      let inner = expressionType(unitIndex, next, end)
      return .constructed(RustTy.reference, [unit.isToken(start, "&&") ? .constructed(RustTy.reference, [inner]) : inner])
    }
    if unit.isByte(start, 0x2A) { return derefType(expressionType(unitIndex, start + 1, end)) }
    if unit.isByte(start, 0x21) || unit.isByte(start, 0x2D) { return expressionType(unitIndex, start + 1, end) }
    if unit.isToken(start, "unsafe"), unit.isByte(start + 1, 0x7B) { return blockType(unitIndex, start + 1) }
    if unit.isByte(start, 0x7B) { return blockType(unitIndex, start) }
    if unit.isToken(start, "if") || unit.isToken(start, "match") || unit.isToken(start, "loop") || unit.isToken(start, "while") || unit.isToken(start, "for") || unit.isToken(start, "async") || unit.isToken(start, "return") || unit.isToken(start, "break") || unit.isToken(start, "continue") {
      if unit.isToken(start, "if") { return ifType(unitIndex, start, end) }
      if unit.isToken(start, "match") { return matchType(unitIndex, start, end) }
      if unit.isToken(start, "loop") { return .unknown }
      return .unknown
    }
    let (ty, from) = postfix(unitIndex, end - 1, lower: start)
    return from == start ? ty : .unknown
  }

  /// `if c { a } else { b }`: the first branch's tail.
  private func ifType(_ unitIndex: Int32, _ start: Int, _ end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var k = start + 1
    while k < end, !unit.isByte(k, 0x7B) { k = unit.tokens[k].kind == .open && !unit.isByte(k, 0x7B) ? unit.skipBalanced(k) : k + 1 }
    guard k < end else { return .unknown }
    return blockType(unitIndex, k)
  }

  /// `match x { p => a, … }`: the first arm's that has one (an arm that returns, breaks or panics has none).
  private func matchType(_ unitIndex: Int32, _ start: Int, _ end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var k = start + 1
    while k < end, !unit.isByte(k, 0x7B) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
    guard k < end else { return .unknown }
    let close = unit.skipBalanced(k) - 1
    var i = k + 1
    var arms = 0
    while i < close, arms < 16 {
      arms += 1
      // The pattern, to `=>`.
      while i < close, !unit.isToken(i, "=>") { i = unit.tokens[i].kind == .open ? unit.skipBalanced(i) : i + 1 }
      guard i < close else { break }
      let bodyStart = i + 1
      var bodyEnd = bodyStart
      if unit.isByte(bodyStart, 0x7B) {
        bodyEnd = unit.skipBalanced(bodyStart)
      } else {
        while bodyEnd < close, !unit.isByte(bodyEnd, 0x2C) { bodyEnd = unit.tokens[bodyEnd].kind == .open ? unit.skipBalanced(bodyEnd) : bodyEnd + 1 }
      }
      if !divergesAt(unit, bodyStart) {
        let ty = expressionType(unitIndex, bodyStart, bodyEnd)
        if ty != .unknown { return ty }
      }
      i = bodyEnd
      if unit.isByte(i, 0x2C) { i += 1 }
    }
    return .unknown
  }

  /// `return`, `break`, `continue`, `panic!(…)` and friends: no value.
  private func divergesAt(_ unit: Unit, _ i: Int) -> Bool {
    if unit.isToken(i, "return") || unit.isToken(i, "break") || unit.isToken(i, "continue") { return true }
    if unit.isByte(i + 1, 0x21), ["panic", "unreachable", "todo", "unimplemented", "bail"].contains(unit.string(i)) { return true }
    if unit.isByte(i, 0x7B), i + 1 < unit.tokens.count { return divergesAt(unit, i + 1) && unit.skipBalanced(i) - 1 <= i + 6 }
    return false
  }

  /// A block's tail expression's type.
  func blockType(_ unitIndex: Int32, _ open: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let close = unit.skipBalanced(open) - 1
    guard close > open + 1, !unit.isByte(close - 1, 0x3B) else { return .tuple([], []) }
    // The last statement: after the last `;` or block-like statement at depth 0.
    var k = open + 1
    var tailStart = open + 1
    while k < close {
      if unit.isByte(k, 0x3B) { tailStart = k + 1 }
      if unit.tokens[k].kind == .open {
        let next = unit.skipBalanced(k)
        // `if … { }` and `match … { }` as statements end without `;`, but so does the tail itself: a block followed
        // by the start of another statement ended one.
        if unit.isByte(k, 0x7B), next < close, unit.tokens[next].kind == .identifier || unit.tokens[next].kind == .keyword && !unit.isToken(next, "else") && !unit.isToken(next, "as") {
          tailStart = next
        }
        k = next
        continue
      }
      k += 1
    }
    guard tailStart < close else { return .unknown }
    return expressionType(unitIndex, tailStart, close)
  }

  private func isOperandEnd(_ unit: Unit, _ i: Int) -> Bool {
    let token = unit.tokens[i]
    switch token.kind {
    case .identifier, .number, .string: return true
    case .keyword: return unit.isToken(i, "self") || unit.isToken(i, "true") || unit.isToken(i, "false") || unit.isToken(i, "await")
    case .close: return true
    default: return unit.isByte(i, 0x3F)
    }
  }

  func derefType(_ ty: Ty) -> Ty {
    switch ty {
    case .constructed(let kind, let args) where kind == RustTy.reference || kind == RustTy.raw: return args.first ?? .unknown
    default: return derefStep(ty) ?? .unknown
    }
  }

  func primitive(_ word: String) -> Ty {
    guard let node = primitiveNode, case .decl(let ref)? = lookupIn(nodes[Int(node)].unit, nodes[Int(node)].decl, name(word), .type).first else { return .unknown }
    return .nominal(ref, [])
  }

  /// The type before a `.` at `dot`.
  func operandType(_ unitIndex: Int32, dot: Int) -> Ty {
    guard dot >= 1 else { return .unknown }
    return postfix(unitIndex, dot - 1, lower: 0).0
  }

  /// A postfix expression ending at `end` (a path, a call, a field, an index, `?`, `.await`, a literal), with where
  /// it starts.
  func postfix(_ unitIndex: Int32, _ end: Int, lower: Int) -> (Ty, Int) {
    let unit = project.units[Int(unitIndex)]
    guard end >= lower, end >= 0 else { return (.unknown, end + 1) }
    depth += 1
    defer { depth -= 1 }
    guard depth < 64 else { return (.unknown, end) }
    let token = unit.tokens[end]
    if unit.isByte(end, 0x3F) {
      let (inner, from) = postfix(unitIndex, end - 1, lower: lower)
      return (tryType(inner), from)
    }
    if end - 1 >= lower, unit.isByte(end - 1, 0x2E), token.kind == .identifier || token.kind == .keyword || token.kind == .number {
      let (receiver, from) = postfix(unitIndex, end - 2, lower: lower)
      if unit.isToken(end, "await") { return (awaitType(receiver), from) }
      if token.kind == .number {
        if case .tuple(let items, _) = peelReferences(receiver), let index = Int(unit.string(end)), index < items.count { return (items[index], from) }
        return (fieldType(receiver, unit.hash(end)), from)
      }
      return (fieldType(receiver, unit.hash(end)), from)
    }
    switch token.kind {
    case .close:
      guard let open = unit.matchingOpen(end) else { return (.unknown, end) }
      let before = open - 1
      if unit.isByte(end, 0x29) {
        if before >= lower, isCallee(unit, before) { return call(unitIndex, open: open, close: end, lower: lower) }
        // Parentheses or a tuple.
        var items: [Ty] = []
        var k = open + 1
        var itemStart = k
        while k <= end {
          if k == end || unit.isByte(k, 0x2C) {
            if k > itemStart { items.append(expressionType(unitIndex, itemStart, k)) }
            if k < end, items.count == 0 { items.append(.unknown) }
            itemStart = k + 1
            if k == end { break }
          }
          k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
        }
        let hasComma = (open + 1..<end).contains { unit.isByte($0, 0x2C) && unit.matchingOpenBefore($0) == open }
        if items.count == 1, !hasComma { return (items[0], open) }
        return (.tuple(items, []), open)
      }
      if unit.isByte(end, 0x5D) {
        if before >= lower, unit.isByte(before, 0x21) { return (macroType(unitIndex, before - 1, open: open, close: end), pathStart(unit, before - 1)) }
        if before >= lower, isOperandEnd(unit, before) {
          let (receiver, from) = postfix(unitIndex, before, lower: lower)
          return (indexType(unitIndex, receiver, open: open, close: end), from)
        }
        // An array literal.
        var k = open + 1
        while k < end, !unit.isByte(k, 0x2C), !unit.isByte(k, 0x3B) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
        return (.constructed(Ty.array, [k > open + 1 ? expressionType(unitIndex, open + 1, k) : .unknown]), open)
      }
      // `}`.
      if before >= lower, unit.isByte(before, 0x21) { return (macroType(unitIndex, before - 1, open: open, close: end), pathStart(unit, before - 1)) }
      if before >= lower, unit.tokens[before].kind == .identifier || unit.isToken(before, "Self") || unit.isByte(before, 0x3E) {
        // `S { … }`, `E::V { … }`.
        var last = before
        if unit.isByte(before, 0x3E) {
          var level = 0
          var j = before
          while j > lower {
            if unit.isByte(j, 0x3E) { level += 1 } else if unit.isByte(j, 0x3C) {
              level -= 1
              if level == 0 { break }
            }
            j -= 1
          }
          last = j - 1
          if unit.isToken(last, "::") { last -= 1 }
        }
        let (segments, qualified) = pathSegments(unit, to: last)
        let found = resolvePath(unitIndex, segments, qualified: qualified, namespace: .type)
        if let entity = found.first, case .decl(let ref) = entity, [.structure, .enumCase, .typeAlias].contains(decl(ref).kind) {
          let first = segments.first.map { $0 < 0 ? last : $0 } ?? last
          return (literalType(unitIndex, ref, open: open, close: end), qualified ?? first)
        }
        return (blockType(unitIndex, open), open)
      }
      if before >= lower, unit.isToken(before, "unsafe") { return (blockType(unitIndex, open), before) }
      return (blockType(unitIndex, open), open)
    case .string:
      let first = unit.source.text[token.start]
      if first == 0x27 { return (primitive("char"), end) }
      if first == 0x62 {
        // `b"…"`, `b'x'`.
        if unit.source.text[token.start + 1] == 0x27 { return (primitive("u8"), end) }
        return (.constructed(RustTy.reference, [.constructed(Ty.array, [primitive("u8")])]), end)
      }
      if first == 0x63 { return (.constructed(RustTy.reference, [stdNominal("CStr")]), end) }
      return (.constructed(RustTy.reference, [primitive("str")]), end)
    case .number:
      return (numberType(unit.string(end)), end)
    case .identifier, .keyword:
      if unit.isToken(end, "true") || unit.isToken(end, "false") { return (primitive("bool"), end) }
      if unit.isToken(end, "self"), !(end >= 1 && unit.isToken(end - 1, "::")) {
        if case .local(let u, let t)? = localSite(RustWord.selfValue, unitIndex: unitIndex, token: Int32(end)) { return (localType(unitIndex: u, token: t), end) }
        return (.unknown, end)
      }
      let (segments, qualified) = pathSegments(unit, to: end)
      let from = qualified ?? (segments.first.map { $0 < 0 ? end - 1 : $0 } ?? end)
      if from < lower { return (.unknown, end) }
      let found = resolvePath(unitIndex, segments, qualified: qualified, namespace: .value)
      guard let entity = found.first else { return (.unknown, from) }
      return (valueType(of: entity, unitIndex: unitIndex, segments: segments), from)
    default:
      return (.unknown, end)
    }
  }

  private func pathStart(_ unit: Unit, _ last: Int) -> Int {
    let (segments, qualified) = pathSegments(unit, to: last)
    return qualified ?? (segments.first.map { $0 < 0 ? last : $0 } ?? last)
  }

  private func isCallee(_ unit: Unit, _ i: Int) -> Bool {
    let token = unit.tokens[i]
    switch token.kind {
    case .identifier: return true
    case .keyword: return unit.isToken(i, "Self") || unit.isToken(i, "self") || unit.isToken(i, "super") || unit.isToken(i, "crate")
    case .close: return true
    default: return unit.isByte(i, 0x3E) || unit.isByte(i, 0x21) || unit.isByte(i, 0x3F)
    }
  }

  /// A literal `S { a, b: 1 }`'s type, its parameters from the fields' values when it has any.
  private func literalType(_ unitIndex: Int32, _ ref: DeclRef, open: Int, close: Int) -> Ty {
    var target = ref
    let item = decl(ref)
    if item.kind == .typeAlias {
      let aliased = aliasType(ref, [])
      return aliased
    }
    if item.kind == .enumCase { target = DeclRef(unit: ref.unit, decl: item.parent) }
    let generics = decl(target)
    guard generics.genericCount > 0 else { return .nominal(target, []) }
    let unit = project.units[Int(unitIndex)]
    var map: [Name: Ty] = [:]
    let bindable = Set((0..<Int(generics.genericCount)).map { self.unit(target).generics[Int(generics.genericStart) + $0].name })
    var k = open + 1
    let holder = self.unit(ref)
    while k < close {
      var e = k
      while e < close, !unit.isByte(e, 0x2C) { e = unit.tokens[e].kind == .open ? unit.skipBalanced(e) : e + 1 }
      if unit.tokens[k].kind == .identifier {
        let word = unit.hash(k)
        if let child = holder.children(of: ref.decl).first(where: { holder.decls[Int($0)].name == word && holder.decls[Int($0)].kind == .variable }) {
          let field = holder.decls[Int(child)]
          let value = unit.isByte(k + 1, 0x3A) ? expressionType(unitIndex, k + 2, e) : expressionType(unitIndex, k, k + 1)
          _ = unify(typeFrom(ref.unit, field.typeStart, field.typeEnd), value, &map, bindable: bindable)
        }
      }
      k = e + 1
    }
    let args = (0..<Int(generics.genericCount)).map { map[self.unit(target).generics[Int(generics.genericStart) + $0].name] ?? .unknown }
    return .nominal(target, args)
  }

  /// A name used as a value: a local's type, a constant's, a unit struct or variant's type, a function's signature.
  func valueType(of entity: Entity, unitIndex: Int32, segments: [Int]) -> Ty {
    switch entity {
    case .local(let u, let token): return localType(unitIndex: u, token: token)
    case .decl(let ref):
      let item = decl(ref)
      switch item.kind {
      case .variable:
        var ty = valueType(of: ref)
        if item.parent >= 0, decl(DeclRef(unit: ref.unit, decl: item.parent)).kind == .extensionDecl || decl(DeclRef(unit: ref.unit, decl: item.parent)).kind == .protocolType {
          // `Self::CONST`, `u32::MAX`: Self is the type before it.
          let unit = project.units[Int(unitIndex)]
          if segments.count >= 2, segments[segments.count - 2] >= 0 {
            let prefix = typeOfPrefix(unitIndex, segments)
            ty = substitute(ty, [:], selfType: prefix == .unknown ? implSelfOf(ref) : prefix)
          }
          _ = unit
        }
        return ty
      case .structure: return ownTypeUnknownArgs(ref)
      case .enumCase: return ownTypeUnknownArgs(DeclRef(unit: ref.unit, decl: item.parent))
      case .function: return .function([], returnType(of: ref))
      default: return .unknown
      }
    default:
      return .unknown
    }
  }

  func ownTypeUnknownArgs(_ ref: DeclRef) -> Ty {
    let item = decl(ref)
    return .nominal(ref, Array(repeating: .unknown, count: Int(item.genericCount)))
  }

  /// The type a path's segments before the last name: `Vec::<u8>` in `Vec::<u8>::new`.
  func typeOfPrefix(_ unitIndex: Int32, _ segments: [Int]) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard segments.count >= 2 else { return .unknown }
    let prefix = Array(segments.dropLast())
    if prefix.count == 1, prefix[0] >= 0, unit.isToken(prefix[0], "Self") { return selfType(unitIndex: unitIndex, token: Int32(prefix[0])) }
    guard let entity = resolvePath(unitIndex, prefix, qualified: nil, namespace: .type).first else { return .unknown }
    // Written arguments: `Vec::<u8>::new`, `HashMap::<K, V>::new`.
    var args: [Ty] = []
    if let lastToken = prefix.last, lastToken >= 0, unit.isToken(lastToken + 1, "::"), unit.isByte(lastToken + 2, 0x3C) {
      args = typeArguments(unitIndex, lastToken + 3, angleClose(unit, lastToken + 2))
    } else if let lastToken = prefix.last, lastToken >= 0, unit.isByte(lastToken + 1, 0x3C) {
      args = typeArguments(unitIndex, lastToken + 2, angleClose(unit, lastToken + 1))
    }
    if case .decl(let ref) = entity, args.isEmpty, decl(ref).genericCount > 0, decl(ref).kind != .typeAlias {
      return ownTypeUnknownArgs(ref)
    }
    return type(of: entity, arguments: args)
  }

  private func implSelfOf(_ ref: DeclRef) -> Ty {
    let item = decl(ref)
    guard item.parent >= 0 else { return .unknown }
    let parent = DeclRef(unit: ref.unit, decl: item.parent)
    return decl(parent).kind == .extensionDecl ? implSelfType(parent) : .unknown
  }

  // MARK: Calls

  /// `f(…)`, `x.m(…)`, `T::new(…)`, `Some(…)`, `(self.f)(…)`: what it returns.
  private func call(_ unitIndex: Int32, open: Int, close: Int, lower: Int) -> (Ty, Int) {
    let unit = project.units[Int(unitIndex)]
    var nameToken = open - 1
    var turbofish: [Ty] = []
    if unit.isByte(nameToken, 0x21) {
      return (macroType(unitIndex, nameToken - 1, open: open, close: close), pathStart(unit, nameToken - 1))
    }
    if unit.tokens[nameToken].kind == .close || unit.isByte(nameToken, 0x3F) {
      // Calling what an expression gives.
      let (callee, from) = postfix(unitIndex, nameToken, lower: lower)
      return (callResult(callee), from)
    }
    if unit.isByte(nameToken, 0x3E) {
      var level = 0
      var j = nameToken
      while j > lower {
        if unit.isByte(j, 0x3E) { level += 1 } else if unit.isByte(j, 0x3C) {
          level -= 1
          if level == 0 { break }
        } else if unit.tokens[j].kind == .close, let inner = unit.matchingOpen(j) {
          j = inner
        }
        j -= 1
      }
      guard j >= 2, unit.isToken(j - 1, "::") else { return (.unknown, open) }
      turbofish = typeArguments(unitIndex, j + 1, nameToken)
      nameToken = j - 2
    }
    if nameToken >= 1, unit.isByte(nameToken - 1, 0x2E), unit.tokens[nameToken].kind == .identifier || unit.tokens[nameToken].kind == .keyword {
      let (receiver, from) = postfix(unitIndex, nameToken - 2, lower: lower)
      guard let hit = memberHits(of: receiver, named: unit.hash(nameToken), call: true, at: (unitIndex, Int32(nameToken))).first else { return (.unknown, from) }
      return (methodResult(hit, unitIndex: unitIndex, open: open, close: close, turbofish: turbofish, isMethodCall: true), from)
    }
    let (segments, qualified) = pathSegments(unit, to: nameToken)
    let from = qualified ?? (segments.first.map { $0 < 0 ? nameToken - 1 : $0 } ?? nameToken)
    if unit.isToken(nameToken, "Self"), segments.count == 1 {
      // A tuple struct's `Self(…)`.
      return (selfType(unitIndex: unitIndex, token: Int32(nameToken)), from)
    }
    let found = resolvePath(unitIndex, segments, qualified: qualified, namespace: .value)
    guard let entity = found.first else { return (.unknown, from) }
    switch entity {
    case .decl(let ref):
      let item = decl(ref)
      switch item.kind {
      case .function:
        var receiver: Ty = .unknown
        var map: [Name: Ty] = [:]
        if item.parent >= 0 {
          let parent = DeclRef(unit: ref.unit, decl: item.parent)
          let parentKind = decl(parent).kind
          if parentKind == .extensionDecl || parentKind == .protocolType {
            receiver = typeOfPrefix(unitIndex, segments)
            if let qualified { receiver = qualifiedSelf(unitIndex, qualified) }
            // `Arc::clone(&x)`, `Type::method(&value, …)`: the receiver is the first argument.
            if item.paramCount > 0, self.unit(ref).params[Int(item.paramStart)].label == RustWord.selfValue, receiver == .unknown || hasUnknown(receiver),
              let first = argumentRanges(unit, open: open, close: close).first
            {
              var argument = expressionType(unitIndex, first.0, first.1)
              if case .constructed(let kind, let args) = parameterType(ref.unit, item.paramStart), kind == RustTy.reference || kind == RustTy.mutReference,
                case .constructed(let argKind, let inner) = argument, argKind == RustTy.reference || argKind == RustTy.mutReference, !args.isEmpty, let peeled = inner.first
              {
                argument = peeled
              }
              if argument != .unknown { receiver = argument }
            }
            if parentKind == .extensionDecl {
              if receiver == .unknown { receiver = implSelfType(parent) }
              _ = unify(implSelfType(parent), receiver, &map, bindable: implGenerics(parent))
            } else if receiver == .unknown, segments.count >= 2, segments[0] >= 0, unit.isToken(segments[0], "Self") {
              receiver = selfType(unitIndex: unitIndex, token: Int32(segments[0]))
            }
          }
        }
        let hit = MemberHit(ref: ref, receiver: receiver, map: map)
        return (methodResult(hit, unitIndex: unitIndex, open: open, close: close, turbofish: turbofish, isMethodCall: false), from)
      case .structure, .enumCase:
        // A tuple struct or variant: its parameters from the arguments.
        let target = item.kind == .enumCase ? DeclRef(unit: ref.unit, decl: item.parent) : ref
        let generics = decl(target)
        guard generics.genericCount > 0 else { return (.nominal(target, []), from) }
        let holder = self.unit(ref)
        let fields = holder.children(of: ref.decl).filter { holder.decls[Int($0)].kind == .variable }
        let arguments = argumentRanges(unit, open: open, close: close)
        var map: [Name: Ty] = [:]
        let bindable = Set((0..<Int(generics.genericCount)).map { self.unit(target).generics[Int(generics.genericStart) + $0].name })
        for (field, argument) in zip(fields, arguments) {
          let fieldDecl = holder.decls[Int(field)]
          _ = unify(typeFrom(ref.unit, fieldDecl.typeStart, fieldDecl.typeEnd), expressionType(unitIndex, argument.0, argument.1), &map, bindable: bindable)
        }
        let args = (0..<Int(generics.genericCount)).map { map[self.unit(target).generics[Int(generics.genericStart) + $0].name] ?? .unknown }
        return (.nominal(target, args), from)
      case .variable:
        return (callResult(valueType(of: ref)), from)
      default:
        return (.unknown, from)
      }
    case .local(let u, let token):
      return (callResult(localType(unitIndex: u, token: token)), from)
    default:
      return (.unknown, from)
    }
  }

  private func qualifiedSelf(_ unitIndex: Int32, _ open: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let close = qualifiedEnd(unit, open)
    var k = open + 1
    var asToken = close
    var level = 0
    while k < close {
      if unit.isByte(k, 0x3C) { level += 1 } else if unit.isByte(k, 0x3E) { level -= 1 }
      if level == 0, unit.isToken(k, "as") { asToken = k }
      k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
    }
    return typeFrom(unitIndex, open + 1, asToken)
  }

  /// What calling a value of a type gives: a function's result, a closure bound's `Output`.
  func callResult(_ callee: Ty) -> Ty {
    switch peelReferences(callee) {
    case .function(_, let result): return result
    case .param(let word, let owner?):
      for bound in bounds(of: word, owner: owner) {
        if case .nominal(let trait, let args) = bound, [RustWord.fnTrait, RustWord.fnMut, RustWord.fnOnce].contains(decl(trait).name) {
          return bindingIn(args, RustWord.output) ?? .tuple([], [])
        }
      }
      return .unknown
    case .existential(let traits):
      for bound in traits {
        if case .nominal(let trait, let args) = bound, [RustWord.fnTrait, RustWord.fnMut, RustWord.fnOnce].contains(decl(trait).name) {
          return bindingIn(args, RustWord.output) ?? .tuple([], [])
        }
      }
      return .unknown
    case .nominal(let ref, let args) where decl(ref).name == RustWord.box:
      return args.first.map(callResult) ?? .unknown
    default:
      return .unknown
    }
  }

  func argumentRanges(_ unit: Unit, open: Int, close: Int) -> [(Int, Int)] {
    var result: [(Int, Int)] = []
    var k = open + 1
    while k < close {
      var e = k
      while e < close, !unit.isByte(e, 0x2C) { e = unit.tokens[e].kind == .open ? unit.skipBalanced(e) : e + 1 }
      if e > k { result.append((k, e)) }
      k = e + 1
    }
    return result
  }

  /// A method's or function's result for a call: the impl's parameters as the receiver has them, `Self` the
  /// receiver, its own parameters from the turbofish or the arguments.
  /// `0`, `1.5`: a number whose type comes from where it goes.
  func isUnsuffixedNumber(_ unit: Unit, _ start: Int, _ end: Int) -> Bool {
    var k = start
    if unit.isByte(k, 0x2D) { k += 1 }
    guard k + 1 == end, unit.tokens[k].kind == .number else { return false }
    let text = unit.string(k)
    return !["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64"].contains { text.hasSuffix($0) }
  }

  /// Whether a type has an unknown part.
  func hasUnknown(_ ty: Ty) -> Bool {
    switch ty {
    case .unknown: return true
    case .nominal(_, let args), .constructed(_, let args): return args.contains(where: hasUnknown)
    case .tuple(let items, _): return items.contains(where: hasUnknown)
    default: return false
    }
  }

  /// A closure argument's result: its block's or its expression's type (nil when the argument isn't a closure).
  func closureBodyType(_ unitIndex: Int32, _ start: Int, _ end: Int) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    var k = start
    if unit.isToken(k, "async") { return nil }
    if unit.isToken(k, "move") { k += 1 }
    var bodyStart: Int
    if unit.isToken(k, "||") {
      bodyStart = k + 1
    } else if unit.isByte(k, 0x7C) {
      var j = k + 1
      while j < end, !unit.isByte(j, 0x7C) { j = unit.tokens[j].kind == .open ? unit.skipBalanced(j) : j + 1 }
      bodyStart = j + 1
    } else {
      return nil
    }
    if unit.isToken(bodyStart, "->") {
      var j = bodyStart + 1
      while j < end, !unit.isByte(j, 0x7B) { j += 1 }
      return typeFrom(unitIndex, bodyStart + 1, j)
    }
    guard bodyStart < end else { return .unknown }
    return expressionType(unitIndex, bodyStart, end)
  }

  /// The `Output`s a parameter's Fn bounds name: `F: FnMut(T) -> B` gives B.
  func fnOutputs(_ declared: Ty, owner: DeclRef) -> [Ty] {
    var bounds: [Ty] = []
    switch declared {
    case .param(let word, _): bounds = self.bounds(of: word, owner: owner)
    case .existential(let list): bounds = list
    default: return []
    }
    var result: [Ty] = []
    for bound in bounds {
      if case .nominal(_, let args) = bound, let output = bindingIn(args, RustWord.output) { result.append(output) }
    }
    return result
  }

  func methodResult(_ hit: MemberHit, unitIndex: Int32, open: Int, close: Int, turbofish: [Ty], isMethodCall: Bool) -> Ty {
    let item = decl(hit.ref)
    var result = returnType(of: hit.ref)
    guard result != .unknown else { return .unknown }
    var map = hit.map
    let holder = unit(hit.ref)
    // The function's own parameters.
    if item.genericCount > 0 {
      var own: Set<Name> = []
      for g in 0..<Int(item.genericCount) {
        let word = holder.generics[Int(item.genericStart) + g].name
        own.insert(word)
        if g < turbofish.count { map[word] = turbofish[g] }
      }
      if mentions(result, own), turbofish.isEmpty {
        let unit = project.units[Int(unitIndex)]
        let arguments = argumentRanges(unit, open: open, close: close)
        // Unsuffixed number literals last: `map_or(0, |x| x + 1)` takes its type from the closure, not `0`'s default.
        for literalsPass in [false, true] {
        var index = 0
        for p in 0..<Int(item.paramCount) {
          let param = holder.params[Int(item.paramStart) + p]
          if param.label == RustWord.selfValue, isMethodCall { continue }
          if param.label == RustWord.selfValue, !isMethodCall {
            index += 1
            continue
          }
          guard index < arguments.count else { break }
          let isLiteral = isUnsuffixedNumber(unit, arguments[index].0, arguments[index].1)
          if isLiteral != literalsPass {
            index += 1
            continue
          }
          let declared = typeFrom(hit.ref.unit, param.typeStart, param.typeEnd)
          if mentions(declared, own) {
            if let body = closureBodyType(unitIndex, arguments[index].0, arguments[index].1) {
              // `f: F` with `F: FnMut(T) -> B`, or `impl FnOnce(T) -> B`: B is what the closure gives.
              for output in fnOutputs(declared, owner: hit.ref) { _ = unify(output, body, &map, bindable: own) }
            } else {
              _ = unify(declared, expressionType(unitIndex, arguments[index].0, arguments[index].1), &map, bindable: own)
            }
          }
          index += 1
        }
        }
      }
    }
    // The impl's parameters the receiver didn't settle, from the arguments (`Arc::new(x)`).
    if !isMethodCall, item.parent >= 0, decl(DeclRef(unit: hit.ref.unit, decl: item.parent)).kind == .extensionDecl {
      let impl = DeclRef(unit: hit.ref.unit, decl: item.parent)
      let generics = implGenerics(impl)
      let unsettled = generics.filter { map[$0] == nil || map[$0] == .unknown }
      if !unsettled.isEmpty, mentions(result, unsettled) || mentions(implSelfType(impl), unsettled) {
        let unit = project.units[Int(unitIndex)]
        let arguments = argumentRanges(unit, open: open, close: close)
        var index = 0
        for p in 0..<Int(item.paramCount) {
          let param = holder.params[Int(item.paramStart) + p]
          guard index < arguments.count else { break }
          let declared = param.label == RustWord.selfValue ? parameterType(hit.ref.unit, item.paramStart + Int32(p)) : typeFrom(hit.ref.unit, param.typeStart, param.typeEnd)
          if mentions(declared, unsettled) {
            var found = map.filter { !unsettled.contains($0.key) }
            if unify(declared, expressionType(unitIndex, arguments[index].0, arguments[index].1), &found, bindable: unsettled) {
              for word in unsettled where found[word] != nil { map[word] = found[word] }
            }
          }
          index += 1
        }
      }
    }
    let selfTy: Ty? = hit.receiver == .unknown ? nil : hit.receiver
    result = substitute(result, map, selfType: selfTy)
    if case .dependent = result { result = normalize(result) }
    // `impl Future<Output = T>` an `async` block returns, and `async fn`'s result, are what `.await` gives.
    return result
  }

  func mentions(_ ty: Ty, _ names: Set<Name>) -> Bool {
    switch ty {
    case .param(let word, _): return names.contains(word)
    case .nominal(_, let args), .constructed(_, let args), .existential(let args): return args.contains { mentions($0, names) }
    case .tuple(let items, _): return items.contains { mentions($0, names) }
    case .function(let args, let result): return args.contains { mentions($0, names) } || mentions(result, names)
    case .dependent(let base, _): return mentions(base, names)
    default: return false
    }
  }

  // MARK: Operators

  /// `x?`: a `Result`'s or `Option`'s value.
  func tryType(_ ty: Ty) -> Ty {
    switch ty {
    case .nominal(let ref, let args):
      let word = decl(ref).name
      if word == RustWord.result || word == RustWord.option { return args.first ?? .unknown }
      if word == name("Poll"), let inner = args.first { return .nominal(ref, [tryType(inner)]) }
      return .unknown
    default:
      return .unknown
    }
  }

  /// `x.await`: a future's `Output`; what an `async fn` returns is already that.
  func awaitType(_ ty: Ty) -> Ty {
    var current = ty
    // `Pin<Box<dyn Future<Output = T>>>`.
    for _ in 0..<3 {
      if case .nominal(let ref, let args) = current, decl(ref).name == name("Pin") || decl(ref).name == RustWord.box, let inner = args.first {
        current = inner
        continue
      }
      break
    }
    if case .existential = current {
      let found = normalize(.dependent(current, RustWord.output))
      if case .dependent = found { return .unknown }
      return found
    }
    if case .param = current {
      let found = normalize(.dependent(current, RustWord.output))
      if case .dependent = found { return .unknown }
      return found
    }
    if let output = associatedType(of: current, named: RustWord.output, trait: RustWord.future) { return output }
    if let output = associatedType(of: current, named: RustWord.output, trait: RustWord.intoFuture) { return output }
    return ty
  }

  /// `x[i]`: an element, or a slice for a range.
  private func indexType(_ unitIndex: Int32, _ receiver: Ty, open: Int, close: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var isRange = false
    var k = open + 1
    while k < close {
      if unit.isToken(k, "..") || unit.isToken(k, "..=") { isRange = true }
      k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
    }
    let peeled = peelReferences(receiver)
    switch peeled {
    case .constructed(let kind, let args) where kind == Ty.slice || kind == Ty.array:
      guard let element = args.first else { return .unknown }
      return isRange ? .constructed(Ty.slice, [element]) : element
    case .nominal(let ref, let args):
      let word = decl(ref).name
      if word == RustWord.vec || word == name("VecDeque") {
        guard let element = args.first else { return .unknown }
        return isRange ? .constructed(Ty.slice, [element]) : element
      }
      if word == RustWord.string || word == RustWord.str { return primitive("str") }
      if word == name("HashMap") || word == name("BTreeMap"), args.count >= 2 { return args[1] }
      if let output = associatedType(of: peeled, named: RustWord.output, trait: RustWord.index) { return output }
      return .unknown
    default:
      return .unknown
    }
  }

  func numberType(_ text: String) -> Ty {
    for suffix in ["u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f32", "f64"] where text.hasSuffix(suffix) {
      if suffix.hasPrefix("f"), text.hasPrefix("0x") { continue }
      return primitive(suffix)
    }
    if !text.hasPrefix("0x"), text.contains(".") || text.contains("e") || text.contains("E") { return primitive("f64") }
    return primitive("i32")
  }

  /// What a macro call gives, for the standard ones whose result is known.
  private func macroType(_ unitIndex: Int32, _ nameToken: Int, open: Int, close: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard nameToken >= 0, unit.tokens[nameToken].kind == .identifier else { return .unknown }
    switch unit.string(nameToken) {
    case "format": return stdNominal("String")
    case "vec":
      var k = open + 1
      while k < close, !unit.isByte(k, 0x2C), !unit.isByte(k, 0x3B) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
      return stdNominal("Vec", [k > open + 1 ? expressionType(unitIndex, open + 1, k) : .unknown])
    case "matches", "cfg": return primitive("bool")
    case "concat", "stringify", "env", "include_str", "file", "module_path": return .constructed(RustTy.reference, [primitive("str")])
    case "line", "column": return primitive("u32")
    case "assert", "assert_eq", "assert_ne", "debug_assert", "debug_assert_eq", "debug_assert_ne", "println", "eprintln", "print", "eprint": return .tuple([], [])
    case "include_bytes": return .constructed(RustTy.reference, [.constructed(Ty.array, [primitive("u8")])])
    default: return .unknown
    }
  }
}
