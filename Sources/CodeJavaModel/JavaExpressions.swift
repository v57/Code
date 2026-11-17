import CodeModel
import CodeScan
import Foundation

/// Expressions' static types: literals, names, `this`/`super`, `new`, casts, operators, conditionals, member
/// selections, calls (overloads chosen, a generic method's parameters inferred from its arguments), array access.
extension JavaModel {
  func primitive(_ word: Name) -> Ty { .constructed(word, []) }

  func stringType() -> Ty { langType(JavaWord.string).map { .nominal($0, []) } ?? .unknown }

  /// The type of an expression's tokens.
  func expressionType(unitIndex: Int32, start: Int32, end: Int32) -> Ty {
    guard start >= 0, start < end else { return .unknown }
    depth += 1
    defer { depth -= 1 }
    guard depth < 40 else { return .unknown }
    let unit = project.units[Int(unitIndex)]
    let s = Int(start)
    let limit = min(Int(end), unit.tokens.count)
    guard s < limit else { return .unknown }
    // Top-level operators, the loosest first: assignment, lambda, conditional, then binary ones.
    var operators: [Int] = []
    var question = -1
    var k = s
    while k < limit {
      let token = unit.tokens[k]
      if token.kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.isToken(k, "new") {
        k = unit.javaTypeEnd(k + 1, limit: limit) ?? k + 1
        continue
      }
      if unit.isToken(k, "instanceof") { return primitive(JavaWord.boolean) }
      if token.kind == .punctuation {
        if unit.isByte(k, 0x2E), unit.tokens.indices.contains(k + 1), unit.tokens[k + 1].kind == .punctuation, unit.javaStartsWith(k + 1, 0x3C),
          let after = unit.javaTypeArgumentsEnd(k + 1, limit: limit)
        {
          k = after
          continue
        }
        if unit.isToken(k, "->") { return .unknown }
        if isAssignment(unit, k), k > s { return expressionType(unitIndex: unitIndex, start: start, end: Int32(k)) }
        if unit.isByte(k, 0x3F), question < 0, k > s { question = k }
        if k > s, !unit.isByte(k, 0x2E), !unit.isToken(k, "::"), !unit.isByte(k, 0x2C), !unit.isByte(k, 0x3F), !unit.isByte(k, 0x3A), !isPrefixPosition(unit, k, start: s) {
          operators.append(k)
        }
      }
      k += 1
    }
    if question >= 0 {
      // `c ? a : b`: a's type, else b's.
      var colon = question + 1
      var nested = 0
      while colon < limit {
        if unit.tokens[colon].kind == .open {
          colon = unit.skipBalanced(colon)
          continue
        }
        if unit.isByte(colon, 0x3F) { nested += 1 }
        if unit.isByte(colon, 0x3A) {
          if nested == 0 { break }
          nested -= 1
        }
        colon += 1
      }
      let a = expressionType(unitIndex: unitIndex, start: Int32(question + 1), end: Int32(colon))
      let b = colon < limit ? expressionType(unitIndex: unitIndex, start: Int32(colon + 1), end: end) : .unknown
      if a == .unknown || isNull(unit, question + 1, colon) { return b }
      if isPrimitive(a), !isPrimitive(b), b != .unknown, !isNull(unit, colon + 1, limit) { return box(a) == b ? b : a }
      return a
    }
    if !operators.isEmpty { return binaryType(unitIndex: unitIndex, start: s, end: limit, operators: operators) }
    // Prefix operators.
    if unit.tokens[s].kind == .punctuation {
      if unit.javaStartsWith(s, 0x21) { return primitive(JavaWord.boolean) }
      if unit.javaStartsWith(s, 0x2D) || unit.javaStartsWith(s, 0x2B) || unit.javaStartsWith(s, 0x7E) {
        let inner = unbox(expressionType(unitIndex: unitIndex, start: start + 1, end: end))
        if unit.isToken(s, "++") || unit.isToken(s, "--") { return inner }
        return promoted(inner)
      }
      return .unknown
    }
    var i = s
    return postfixType(unitIndex: unitIndex, start: &i, end: limit)
  }

  private func isNull(_ unit: Unit, _ start: Int, _ end: Int) -> Bool { end == start + 1 && unit.isToken(start, "null") }

  private func isAssignment(_ unit: Unit, _ k: Int) -> Bool {
    let token = unit.tokens[k]
    guard token.kind == .punctuation, unit.source.text[token.start + token.length - 1] == 0x3D else { return false }
    if token.length == 1 { return true }
    if unit.isToken(k, "==") || unit.isToken(k, "!=") || unit.isToken(k, "<=") || unit.isToken(k, ">=") { return false }
    return true
  }

  /// Whether a punctuation token is a prefix operator (after another operator, or at the start).
  private func isPrefixPosition(_ unit: Unit, _ k: Int, start: Int) -> Bool {
    if unit.isToken(k, "++") || unit.isToken(k, "--") {
      // Postfix after an operand, prefix before one.
      return true
    }
    guard k > start else { return true }
    let before = unit.tokens[k - 1]
    if before.kind == .punctuation, !unit.isToken(k - 1, "++"), !unit.isToken(k - 1, "--") { return true }
    if before.kind == .keyword, unit.isToken(k - 1, "return") { return true }
    return false
  }

  /// Numeric promotion: byte, short and char compute as int.
  func promoted(_ ty: Ty) -> Ty {
    let plain = unbox(ty)
    if case .constructed(let kind, let args) = plain, args.isEmpty, kind == JavaWord.byte || kind == JavaWord.short || kind == JavaWord.char {
      return primitive(JavaWord.int)
    }
    return plain
  }

  private func binaryType(unitIndex: Int32, start: Int, end: Int, operators: [Int]) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var comparison = false
    var shift = false
    for k in operators {
      if unit.isToken(k, "==") || unit.isToken(k, "!=") || unit.isToken(k, "<") || unit.isToken(k, ">") || unit.isToken(k, "<=") || unit.isToken(k, ">=")
        || unit.isToken(k, "&&") || unit.isToken(k, "||")
      {
        comparison = true
      }
      if unit.isToken(k, "<<") || unit.isToken(k, ">>") || unit.isToken(k, ">>>") { shift = true }
    }
    if comparison { return primitive(JavaWord.boolean) }
    var operands: [Ty] = []
    var from = start
    for k in operators + [end] {
      if k > from { operands.append(expressionType(unitIndex: unitIndex, start: Int32(from), end: Int32(k))) }
      from = k + 1
    }
    if shift { return operands.first.map(promoted) ?? .unknown }
    let hasPlus = operators.contains { unit.isToken($0, "+") }
    if hasPlus, let string = langType(JavaWord.string), operands.contains(where: { if case .nominal(let ref, _) = $0 { return ref == string } else { return false } }) {
      return .nominal(string, [])
    }
    // Binary numeric promotion: the widest; booleans stay boolean (`&`, `|`, `^`).
    var widest: Ty?
    for operand in operands {
      let plain = promoted(operand)
      guard case .constructed(let kind, let args) = plain, args.isEmpty else { return hasPlus ? .unknown : .unknown }
      if kind == JavaWord.boolean { return plain }
      guard let rank = Self.widening[kind] else { return .unknown }
      if case .constructed(let current, _)? = widest, let currentRank = Self.widening[current], currentRank >= rank { continue }
      widest = plain
    }
    return widest ?? .unknown
  }

  // MARK: Postfix chains

  /// An operand and what follows it: `.name`, `.name(args)`, `[i]`, `.class`, `.this`.
  func postfixType(unitIndex: Int32, start i: inout Int, end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard i < end else { return .unknown }
    var ty = operand(unitIndex: unitIndex, at: &i, end: end)
    while i < end {
      if unit.isByte(i, 0x2E), i + 1 < end {
        var nameToken = i + 1
        var explicit: [Ty] = []
        if unit.tokens[nameToken].kind == .punctuation, unit.javaStartsWith(nameToken, 0x3C), let after = unit.javaTypeArgumentsEnd(nameToken, limit: end) {
          explicit = typeArguments(unitIndex: unitIndex, open: nameToken, end: after)
          nameToken = after
        }
        guard nameToken < end else { return .unknown }
        if unit.isToken(nameToken, "class") {
          let target: Ty = { if case .meta(let inner) = ty { return box(inner) } else { return .unknown } }()
          ty = langType(name("Class")).map { .nominal($0, [target]) } ?? .unknown
          i = nameToken + 1
          continue
        }
        if unit.isToken(nameToken, "this") {
          if case .meta(let inner) = ty { ty = inner } else { ty = .unknown }
          i = nameToken + 1
          continue
        }
        guard unit.javaIsName(nameToken) else { return .unknown }
        let word = unit.hash(nameToken)
        if unit.isByte(nameToken + 1, 0x28), nameToken + 1 < end {
          let close = unit.skipBalanced(nameToken + 1)
          var receiver = ty
          if case .meta(let inner) = ty { receiver = inner }
          let methods = methodSites(of: receiver, named: word, from: unitIndex)
          ty = callResult(methods, receiver: receiver, unitIndex: unitIndex, open: nameToken + 1, explicit: explicit)
          i = close
          continue
        }
        ty = selectedType(ty, word: word, text: unit.string(nameToken), unitIndex: unitIndex)
        i = nameToken + 1
        continue
      }
      if unit.isByte(i, 0x5B) {
        let close = unit.skipBalanced(i)
        if case .constructed(let kind, let args) = ty, kind == Ty.array, let element = args.first { ty = element } else { ty = .unknown }
        i = close
        continue
      }
      if unit.isToken(i, "++") || unit.isToken(i, "--") {
        i += 1
        continue
      }
      break
    }
    if i < end { return .unknown }
    return ty
  }

  /// `x.name` (no call): a package's type or subpackage, a type's member type or static field, a value's field.
  func selectedType(_ ty: Ty, word: Name, text: String, unitIndex: Int32) -> Ty {
    switch ty {
    case .module(let package):
      let packageName = packageNames[package] ?? ""
      if let ref = packageTypes(packageName, named: word).first { return .meta(.nominal(ref, [])) }
      let sub = packageName + "." + text
      return isPackage(sub) ? siteType(packageSite(sub), unitIndex: unitIndex) : .unknown
    case .meta(let inner):
      if let ref = memberTypeRefs(of: inner, named: word).first { return .meta(.nominal(ref, [])) }
      return fieldType(inner, word)
    case .constructed(let kind, _) where kind == Ty.array:
      return word == JavaWord.length ? primitive(JavaWord.int) : .unknown
    case .unknown:
      return .unknown
    default:
      return fieldType(ty, word)
    }
  }

  private func fieldType(_ ty: Ty, _ word: Name) -> Ty {
    for (entry, _) in memberEntries(of: ty, named: word) {
      let kind = decl(entry.ref).kind
      if kind == .variable || kind == .enumCase { return memberValueType(entry) }
    }
    return .unknown
  }

  /// `<A, B>` from `open` to `end` as types.
  func typeArguments(unitIndex: Int32, open: Int, end: Int) -> [Ty] {
    if case .nominal(_, let args) = parseType(unitIndex: unitIndex, start: Int32(open - 1), end: Int32(end), scope: Int32(open)) { return args }
    return []
  }

  /// What a call returns: the chosen overload's result, its class's parameters and its own (inferred) put in. The
  /// overloads must agree when several fit.
  func callResult(_ methods: [DeclRef], receiver: Ty, unitIndex: Int32, open: Int, explicit: [Ty] = []) -> Ty {
    guard !methods.isEmpty else { return .unknown }
    let chosen = chooseOverload(methods, unitIndex: unitIndex, open: open, receiver: receiver)
    var result: Ty?
    for ref in chosen {
      let item = decl(ref)
      // `getClass()` is `Class<? extends |T|>`.
      if item.name == JavaWord.getClass, item.paramCount == 0, let classRef = langType(name("Class")) {
        let ty: Ty = .nominal(classRef, [receiver])
        if result != nil, result != ty { return .unknown }
        result = ty
        continue
      }
      let map = receiverMap(receiver).merging(entryMap(ref, receiver)) { a, _ in a }
      var ty = substitute(valueType(of: ref), map)
      if item.genericCount > 0 {
        var bindings: [Name: Ty] = [:]
        let holder = unit(ref)
        if !explicit.isEmpty {
          for g in 0..<min(Int(item.genericCount), explicit.count) { bindings[holder.generics[Int(item.genericStart) + g].name] = explicit[g] }
        } else {
          bindings = inferBindings(ref, call: (chosen, receiver), unitIndex: unitIndex, open: open, skipping: -1)
        }
        ty = substitute(ty, bindings)
        ty = eraseOwn(ty, ref)
      }
      if let current = result, current != ty {
        if erasure(current) != erasure(ty) { return .unknown }
        continue
      }
      result = ty
    }
    return result ?? .unknown
  }

  /// A method's own type parameters left unbound: their bound at the top, unknown inside.
  func eraseOwn(_ ty: Ty, _ method: DeclRef, top: Bool = true) -> Ty {
    switch ty {
    case .param(_, let owner) where owner == method:
      guard top, let found = bound(of: ty) else { return .unknown }
      return eraseOwn(found, method, top: false)
    case .nominal(let ref, let args):
      return .nominal(ref, args.map { eraseOwn($0, method, top: false) })
    case .constructed(let kind, let args):
      return .constructed(kind, args.map { eraseOwn($0, method, top: kind == Ty.array && top) })
    default:
      return ty
    }
  }

  /// The operand an expression starts with.
  private func operand(unitIndex: Int32, at i: inout Int, end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let token = unit.tokens[i]
    switch token.kind {
    case .number:
      i += 1
      return numberType(unit.string(i - 1))
    case .string:
      i += 1
      return unit.source.text[token.start] == 0x27 ? primitive(JavaWord.char) : stringType()
    case .open:
      guard unit.isByte(i, 0x28) else { return .unknown }
      let close = unit.skipBalanced(i)
      // A cast: `(Type) operand`.
      if let typeEnd = unit.javaTypeEnd(i + 1, limit: close - 1), typeEnd == close - 1 || isIntersection(unit, typeEnd, close - 1), close < end, startsOperand(unit, close, primitiveCast: isPrimitiveType(unit, i + 1)) {
        let ty = parseType(unitIndex: unitIndex, start: Int32(i + 1), end: Int32(close - 1), scope: Int32(i))
        i = end
        return ty
      }
      let inner = expressionType(unitIndex: unitIndex, start: Int32(i + 1), end: Int32(close - 1))
      i = close
      return inner
    case .keyword:
      if unit.isToken(i, "new") { return creation(unitIndex: unitIndex, at: &i, end: end) }
      if unit.isToken(i, "this") {
        i += 1
        if unit.isByte(i, 0x28) {
          i = unit.skipBalanced(i)
          return .unknown
        }
        guard let own = enclosingClasses(unitIndex: unitIndex, token: Int32(i - 1)).first else { return .unknown }
        return ownType(own)
      }
      if unit.isToken(i, "super") {
        i += 1
        if unit.isByte(i, 0x28) {
          i = unit.skipBalanced(i)
          return .unknown
        }
        guard let own = enclosingClasses(unitIndex: unitIndex, token: Int32(i - 1)).first else { return .unknown }
        let parents = supertypes(of: own).map { substitute($0, parameterMap(own, [])) }
        // `super.m()` in a class goes to its superclass; in an interface's default method, `Iface.super.m()`.
        return parents.first(where: { if case .nominal(let ref, _) = $0 { return decl(ref).kind != .protocolType } else { return false } }) ?? parents.first ?? .unknown
      }
      if unit.isToken(i, "true") || unit.isToken(i, "false") {
        i += 1
        return primitive(JavaWord.boolean)
      }
      if unit.isToken(i, "null") {
        i += 1
        return .unknown
      }
      if JavaWord.primitives.contains(unit.hash(i)) {
        // `int.class`, `int[].class`.
        let typeEnd = unit.javaTypeEnd(i, limit: end) ?? i + 1
        let ty = parseType(unitIndex: unitIndex, start: Int32(i), end: Int32(typeEnd), scope: Int32(i))
        i = typeEnd
        return .meta(ty)
      }
      if unit.isToken(i, "switch") { return .unknown }
      if !unit.javaIsName(i) { return .unknown }
      fallthrough
    case .identifier:
      let word = unit.hash(i)
      if unit.isByte(i + 1, 0x28), i + 1 < end {
        let close = unit.skipBalanced(i + 1)
        let found = simpleMethods(word, unitIndex: unitIndex, token: Int32(i))
        let ty = callResult(found.map(\.0), receiver: found.first?.1 ?? .unknown, unitIndex: unitIndex, open: i + 1)
        i = close
        return ty
      }
      // `Type[]::new`, `Type<A>::m`, `Type[].class`.
      if unit.tokens.indices.contains(i + 1), unit.isByte(i + 1, 0x5B), unit.isByte(i + 2, 0x5D) || unit.tokens[i + 1].kind == .punctuation && unit.javaStartsWith(i + 1, 0x3C) {
        if let typeEnd = unit.javaTypeEnd(i, limit: end), typeEnd > i + 1, unit.isToken(typeEnd, "::") || unit.isByte(typeEnd, 0x2E) {
          let ty = parseType(unitIndex: unitIndex, start: Int32(i), end: Int32(typeEnd), scope: Int32(i))
          i = typeEnd
          return .meta(ty)
        }
      }
      let found = answer(unitIndex: unitIndex, token: i)
      i += 1
      guard found.state == .exact, let site = found.sites.first else {
        // Overloads can't be told apart, or nothing found: the same type from each, or unknown.
        if found.state == .candidates, !found.byNameOnly {
          let types = found.sites.map { siteType($0, unitIndex: unitIndex) }
          if let first = types.first, types.allSatisfy({ $0 == first }) { return first }
        }
        return .unknown
      }
      return siteType(site, unitIndex: unitIndex)
    case .attribute:
      return .unknown
    default:
      return .unknown
    }
  }

  private func isIntersection(_ unit: Unit, _ k: Int, _ close: Int) -> Bool { k < close && unit.isByte(k, 0x26) }

  private func isPrimitiveType(_ unit: Unit, _ k: Int) -> Bool { unit.tokens[k].kind == .keyword && JavaWord.primitives.contains(unit.hash(k)) }

  /// Whether a token can start the operand of a cast (`(T) x`, `(T) (x)`, `(T) !b`, `(int) -x`).
  private func startsOperand(_ unit: Unit, _ k: Int, primitiveCast: Bool) -> Bool {
    guard k < unit.tokens.count else { return false }
    let token = unit.tokens[k]
    switch token.kind {
    case .identifier, .number, .string: return true
    case .open: return unit.isByte(k, 0x28)
    case .keyword:
      return unit.isToken(k, "this") || unit.isToken(k, "super") || unit.isToken(k, "new") || unit.isToken(k, "true") || unit.isToken(k, "false")
        || unit.isToken(k, "null") || unit.isToken(k, "switch") || unit.javaIsName(k) || JavaWord.primitives.contains(unit.hash(k))
    case .punctuation:
      if unit.javaStartsWith(k, 0x21) || unit.javaStartsWith(k, 0x7E) { return true }
      return primitiveCast && (unit.javaStartsWith(k, 0x2D) || unit.javaStartsWith(k, 0x2B))
    default: return false
    }
  }

  func numberType(_ text: String) -> Ty {
    let lower = text.lowercased()
    let isHex = lower.hasPrefix("0x")
    if lower.hasSuffix("l") { return primitive(JavaWord.long) }
    if !isHex, lower.hasSuffix("f") { return primitive(JavaWord.float) }
    if !isHex, lower.hasSuffix("d") { return primitive(JavaWord.double) }
    if !isHex, lower.contains(".") || lower.contains("e") { return primitive(JavaWord.double) }
    if isHex, lower.contains("p") { return lower.hasSuffix("f") ? primitive(JavaWord.float) : primitive(JavaWord.double) }
    return primitive(JavaWord.int)
  }

  /// `new T(…)`, `new T<>(…)`, `new T(…) { … }` (the anonymous class), `new T[n]`, `new T[] {…}`, `outer.new Inner()`.
  private func creation(unitIndex: Int32, at i: inout Int, end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let newToken = i
    guard let typeEnd = unit.javaTypeEnd(i + 1, limit: end) else {
      i = end
      return .unknown
    }
    var ty = parseType(unitIndex: unitIndex, start: Int32(i + 1), end: Int32(typeEnd), scope: Int32(i))
    i = typeEnd
    if unit.isByte(i, 0x5B) {
      // Dimensions, then maybe an initializer.
      while i < end, unit.isByte(i, 0x5B) {
        ty = .constructed(Ty.array, [ty])
        i = unit.skipBalanced(i)
      }
      if i < end, unit.isByte(i, 0x7B) { i = unit.skipBalanced(i) }
      return ty
    }
    if i < end, unit.isByte(i, 0x28) {
      // `new Foo<>(args)`: the class's parameters from the constructor's arguments.
      if unit.isToken(i - 1, "<>"), case .nominal(let ref, _) = ty, decl(ref).genericCount > 0 {
        ty = diamondType(ref, unitIndex: unitIndex, open: i)
      }
      i = unit.skipBalanced(i)
    }
    if i < end, unit.isByte(i, 0x7B) {
      i = unit.skipBalanced(i)
      // The anonymous class, declared at its `new`.
      for index in unit.chain(at: Int32(newToken + 1)).reversed() {
        let item = unit.decls[Int(index)]
        if item.name == 0, item.kind == .classType, item.first == Int32(newToken) { return .nominal(DeclRef(unit: unitIndex, decl: index), []) }
      }
    }
    return ty
  }

  /// A diamond's arguments as the chosen constructor's parameters tell them; unknown where they don't.
  private func diamondType(_ ref: DeclRef, unitIndex: Int32, open: Int) -> Ty {
    let holder = unit(ref)
    let item = decl(ref)
    var own: Set<Name> = []
    var names: [Name] = []
    for g in 0..<Int(item.genericCount) {
      names.append(holder.generics[Int(item.genericStart) + g].name)
      own.insert(names[g])
    }
    let raw = Ty.nominal(ref, [])
    let constructors = holder.children(of: ref.decl).filter { holder.decls[Int($0)].kind == .initializer }.map { DeclRef(unit: ref.unit, decl: $0) }
    let chosen = chooseOverload(constructors, unitIndex: unitIndex, open: open, receiver: raw)
    guard chosen.count == 1 else { return .nominal(ref, names.map { _ in .unknown }) }
    let bindings = inferBindings(chosen[0], call: (chosen, raw), unitIndex: unitIndex, open: open, skipping: -1, own: own)
    return .nominal(ref, names.map { bindings[$0] ?? .unknown })
  }

  // MARK: Operands left of a dot

  /// The type of the operand left of a `.` or `::`: the expression that ends there.
  func operandType(unitIndex: Int32, dot: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let start = expressionStart(unit, before: dot)
    guard start < dot else { return .unknown }
    var i = start
    return postfixType(unitIndex: unitIndex, start: &i, end: dot)
  }

  /// Walking back from just before `end`: names, `.`, calls, indexes, `new T(…)`, as far as one operand goes.
  func expressionStart(_ unit: Unit, before end: Int) -> Int {
    var i = end - 1
    while i >= 0 {
      let token = unit.tokens[i]
      if token.kind == .close {
        guard let open = unit.matchingOpen(i) else { return i + 1 }
        i = open
        if unit.isByte(open, 0x7B) {
          // `new T[] {…}` or an anonymous class: back to `new`.
          var k = open - 1
          if k >= 0, unit.tokens[k].kind == .close, let o = unit.matchingOpen(k) { k = o - 1 }
          while k >= 0, unit.javaIsName(k) || unit.isByte(k, 0x2E) || unit.tokens[k].kind == .punctuation && unit.javaOnly(k, "<>?,") || unit.isByte(k, 0x5B) || unit.isByte(k, 0x5D) || unit.tokens[k].kind == .keyword && JavaWord.primitives.contains(unit.hash(k)) {
            k -= 1
          }
          if k >= 0, unit.isToken(k, "new") { return backOverQualifier(unit, k) }
          return open + 1
        }
        if i > 0, unit.javaIsName(i - 1) || unit.tokens[i - 1].kind == .close || unit.isToken(i - 1, "this") || unit.isToken(i - 1, "super") {
          i -= 1
          if unit.javaIsName(i) || unit.isToken(i, "this") || unit.isToken(i, "super") {
            if let start = newStart(unit, i) { return start }
            if i > 0, unit.isByte(i - 1, 0x2E) {
              i -= 2
              continue
            }
            // `.<T>name(`.
            if i > 0, unit.tokens[i - 1].kind == .punctuation, unit.javaOnly(i - 1, ">"), let dot = explicitArgumentsDot(unit, i - 1) {
              i = dot - 1
              continue
            }
            return i
          }
          continue
        }
        if i > 0, unit.tokens[i - 1].kind == .punctuation, unit.javaOnly(i - 1, ">"), let start = newStart(unit, i - 1) {
          // `new Foo<Bar>()`.
          return start
        }
        return i
      }
      if unit.javaIsName(i) || token.kind == .number || token.kind == .string || unit.isToken(i, "this") || unit.isToken(i, "super") || unit.isToken(i, "class")
        || token.kind == .keyword && JavaWord.primitives.contains(unit.hash(i))
      {
        if i > 0, unit.isByte(i - 1, 0x2E) {
          i -= 2
          continue
        }
        return i
      }
      // `String[]::new`, `List<String>::size`: the type before.
      if token.kind == .punctuation, unit.javaOnly(i, ">") {
        var depth = 0
        var k = i
        while k >= 0 {
          if unit.tokens[k].kind == .punctuation {
            for b in (0..<unit.tokens[k].length).reversed() {
              let byte = unit.source.text[unit.tokens[k].start + b]
              if byte == 0x3E { depth += 1 } else if byte == 0x3C { depth -= 1 }
            }
            if depth == 0 { break }
          } else if unit.tokens[k].kind == .open || unit.isByte(k, 0x3B) {
            return i + 1
          }
          k -= 1
        }
        if k > 0, unit.javaIsName(k - 1) {
          i = k - 1
          continue
        }
        return i + 1
      }
      return i + 1
    }
    return 0
  }

  /// When the name at `i` (or the `>` closing its type arguments) is `new`'s type: where the creation starts.
  private func newStart(_ unit: Unit, _ i: Int) -> Int? {
    var k = i
    if unit.tokens[k].kind == .punctuation {
      var depth = 0
      while k >= 0 {
        if unit.tokens[k].kind == .punctuation {
          for b in (0..<unit.tokens[k].length).reversed() {
            let byte = unit.source.text[unit.tokens[k].start + b]
            if byte == 0x3E { depth += 1 } else if byte == 0x3C { depth -= 1 }
          }
          if depth == 0 { break }
        } else if unit.tokens[k].kind == .open || unit.isByte(k, 0x3B) {
          return nil
        }
        k -= 1
      }
      k -= 1
    }
    while k > 0, unit.isByte(k - 1, 0x2E), unit.javaIsName(k - 2) { k -= 2 }
    k = max(k, 0)
    while k > 0, unit.tokens[k - 1].kind == .attribute { k -= 1 }
    guard k > 0, unit.isToken(k - 1, "new") else { return nil }
    return backOverQualifier(unit, k - 1)
  }

  /// `outer.new Inner()`: from the qualifier.
  private func backOverQualifier(_ unit: Unit, _ newToken: Int) -> Int {
    guard newToken > 0, unit.isByte(newToken - 1, 0x2E) else { return newToken }
    return expressionStart(unit, before: newToken - 1)
  }

  private func explicitArgumentsDot(_ unit: Unit, _ close: Int) -> Int? {
    var k = close
    var budget = 40
    while k > 0, budget > 0 {
      budget -= 1
      if unit.tokens[k].kind == .punctuation, unit.javaStartsWith(k, 0x3C) { return unit.isByte(k - 1, 0x2E) ? k - 1 : nil }
      k -= 1
    }
    return nil
  }
}
