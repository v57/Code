import CodeModel
import CodeScan
import Foundation

/// Expressions' types: operators by Dart's precedence, literals, calls with their type arguments inferred from what's
/// passed (closures' results too), member chains with `?.`, `!` and cascades, `await`.
extension DartModel {
  func boolType() -> Ty { coreTy(DartWord.boolWord) }
  func stringType() -> Ty { coreTy(DartWord.stringWord) }

  /// The type of the expression between two tokens.
  func expressionType(unitIndex: Int32, start: Int32, end: Int32) -> Ty {
    guard start >= 0, start < end else { return .unknown }
    depth += 1
    defer { depth -= 1 }
    guard depth < 40 else { return .unknown }
    let unit = project.units[Int(unitIndex)]
    let s = Int(start)
    let limit = min(Int(end), unit.tokens.count)
    guard s < limit else { return .unknown }
    var assignment = -1
    var cascade = -1
    var question = -1
    var coalesce = -1
    var logical = -1
    var equality = -1
    var relational = -1
    var asAt = -1
    var binary: [(at: Int, precedence: Int)] = []
    var k = s
    while k < limit {
      let token = unit.tokens[k]
      if token.kind == .open || token.kind == .interpolationOpen {
        k = unit.skipBalanced(k)
        continue
      }
      if token.kind == .string {
        k = unit.daStringEnd(k)
        continue
      }
      if k == s {
        // `<int>[…]`, `<K, V>{…}`: a collection literal's type arguments.
        if token.kind == .punctuation, unit.startsWith(k, 0x3C), let after = unit.daTypeArgumentsEnd(k, limit: limit) {
          k = after
          continue
        }
        k += 1
        continue
      }
      if unit.isToken(k, "is") || unit.isToken(k, "as") {
        if unit.isToken(k, "is") { if relational < 0 { relational = k } } else if asAt < 0 { asAt = k }
        let typeStart = unit.isByte(k + 1, 0x21) ? k + 2 : k + 1
        k = unit.daTypeEnd(typeStart, limit: limit) ?? typeStart
        continue
      }
      if token.kind == .punctuation {
        let operandBefore = endsOperand(unit, k - 1)
        switch unit.string(k) {
        case "=", "+=", "-=", "*=", "/=", "~/=", "%=", "??=", "<<=", ">>=", ">>>=", "&=", "|=", "^=":
          if assignment < 0, cascade < 0 { assignment = k }
        case "..", "?..":
          if cascade < 0 { cascade = k }
        case "?":
          // `a?[i]`: a null-aware index, written without spaces; `a ? [x] : y` is a conditional.
          let nullAwareIndex = unit.isByte(k + 1, 0x5B) && unit.tokens[k].start == unit.tokens[k - 1].end && unit.tokens[k + 1].start == unit.tokens[k].end
          if question < 0, !nullAwareIndex { question = k }
        case "??":
          if coalesce < 0 { coalesce = k }
        case "||", "&&":
          if logical < 0 { logical = k }
        case "==", "!=":
          if equality < 0 { equality = k }
        case "<=", ">=":
          if relational < 0 { relational = k }
        case "<":
          if unit.daIsName(k - 1) || unit.daClosesTypeArguments(k - 1), let after = unit.daTypeArgumentsEnd(k, limit: limit),
            after == limit || unit.isByte(after, 0x28) || unit.daIsDot(after) || unit.tokens[after].kind == .close || unit.isByte(after, 0x2C) || unit.isByte(after, 0x3B)
          {
            k = after
            continue
          }
          // `a ?? <int>[]`: a collection literal's type arguments.
          if !operandBefore, let after = unit.daTypeArgumentsEnd(k, limit: limit), unit.isByte(after, 0x5B) || unit.isByte(after, 0x7B) {
            k = after
            continue
          }
          if operandBefore, relational < 0 { relational = k }
        case ">":
          if operandBefore, relational < 0 { relational = k }
        case "|": if operandBefore { binary.append((k, 1)) }
        case "^": if operandBefore { binary.append((k, 2)) }
        case "&": if operandBefore { binary.append((k, 3)) }
        case "<<", ">>", ">>>": if operandBefore { binary.append((k, 4)) }
        case "+", "-": if operandBefore { binary.append((k, 5)) }
        case "*", "/", "%", "~/": if operandBefore { binary.append((k, 6)) }
        case "=>":
          // `(a) => …`: a closure.
          if unit.isByte(s, 0x28) || unit.tokens[s].kind == .punctuation { return closureValueType(unitIndex: unitIndex, open: s) }
        default:
          break
        }
      }
      k += 1
    }
    if assignment >= 0 { return expressionType(unitIndex: unitIndex, start: Int32(assignment + 1), end: end) }
    if cascade >= 0 { return expressionType(unitIndex: unitIndex, start: start, end: Int32(cascade)) }
    if question >= 0 {
      guard let colon = conditionalColon(unit, question, limit) else { return .unknown }
      let a = expressionType(unitIndex: unitIndex, start: Int32(question + 1), end: Int32(colon))
      if a == .unknown || isNull(unit, question + 1, colon) { return expressionType(unitIndex: unitIndex, start: Int32(colon + 1), end: end) }
      return a
    }
    if coalesce >= 0 {
      let left = expressionType(unitIndex: unitIndex, start: start, end: Int32(coalesce))
      if left != .unknown { return nonNull(left) }
      return expressionType(unitIndex: unitIndex, start: Int32(coalesce + 1), end: end)
    }
    if logical >= 0 || equality >= 0 { return boolType() }
    if asAt >= 0, relational < 0 || relational > asAt {
      let typeEnd = unit.daTypeEnd(asAt + 1, limit: limit) ?? limit
      return parseType(unitIndex: unitIndex, start: Int32(asAt + 1), end: Int32(typeEnd), scope: Int32(asAt))
    }
    if relational >= 0 {
      if unit.isToken(relational, "is") { return boolType() }
      if let found = operatorResult(unitIndex: unitIndex, left: expressionType(unitIndex: unitIndex, start: start, end: Int32(relational)), op: unit.string(relational)) { return found }
      return boolType()
    }
    if let lowest = binary.map(\.precedence).min() {
      let at = binary.last { $0.precedence == lowest }!.at
      let left = expressionType(unitIndex: unitIndex, start: start, end: Int32(at))
      let right = expressionType(unitIndex: unitIndex, start: Int32(at + 1), end: end)
      return binaryType(left, right, op: unit.string(at), unitIndex: unitIndex)
    }
    // Prefix operators.
    if unit.isToken(s, "await") { return awaited(expressionType(unitIndex: unitIndex, start: start + 1, end: end)) }
    if unit.isToken(s, "throw") || unit.isToken(s, "rethrow") { return .unknown }
    if unit.isToken(s, "new") || unit.isToken(s, "const") { return expressionType(unitIndex: unitIndex, start: start + 1, end: end) }
    if unit.isToken(s, "switch"), unit.isByte(s + 1, 0x28) { return switchType(unitIndex: unitIndex, at: s, limit: limit) }
    if unit.tokens[s].kind == .punctuation, !unit.startsWith(s, 0x3C) {
      switch unit.string(s) {
      case "!": return boolType()
      case "~": return coreTy(DartWord.intWord)
      case "-":
        let inner = expressionType(unitIndex: unitIndex, start: start + 1, end: end)
        if isNumber(inner) { return inner }
        return operatorResult(unitIndex: unitIndex, left: inner, op: "unary-") ?? .unknown
      case "++", "--": return expressionType(unitIndex: unitIndex, start: start + 1, end: end)
      default: return .unknown
      }
    }
    var i = s
    return postfixType(unitIndex: unitIndex, start: &i, end: limit, asOperand: false)
  }

  /// Whether a token ends an operand: a name, a literal, a closing bracket, a postfix `!`.
  private func endsOperand(_ unit: Unit, _ k: Int) -> Bool {
    guard k >= 0 else { return false }
    switch unit.tokens[k].kind {
    case .identifier, .number, .string, .close, .interpolationClose: return true
    case .keyword, .declarationKeyword:
      return unit.daIsName(k) || unit.isToken(k, "this") || unit.isToken(k, "null") || unit.isToken(k, "true") || unit.isToken(k, "false") || unit.isToken(k, "super")
    case .punctuation:
      return unit.isByte(k, 0x21) && endsOperand(unit, k - 1)
    default:
      return false
    }
  }

  private func isNull(_ unit: Unit, _ start: Int, _ end: Int) -> Bool { end == start + 1 && unit.isToken(start, "null") }

  /// The `:` of `c ? a : b`, nested conditionals skipped.
  private func conditionalColon(_ unit: Unit, _ question: Int, _ limit: Int) -> Int? {
    var depth = 0
    var k = question + 1
    while k < limit {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.isByte(k, 0x3F) { depth += 1 }
      if unit.isByte(k, 0x3A) {
        if depth == 0 { return k }
        depth -= 1
      }
      k += 1
    }
    return nil
  }

  func isNumber(_ ty: Ty) -> Bool {
    guard case .nominal(let ref, _) = ty, isSDK(ref) else { return false }
    let word = decl(ref).name
    return word == DartWord.intWord || word == DartWord.doubleWord || word == DartWord.numWord
  }

  /// `a op b`: numbers' rules, a string's `+` and `*`, else the left operand's operator.
  private func binaryType(_ left: Ty, _ right: Ty, op: String, unitIndex: Int32) -> Ty {
    if isNumber(left) {
      if op == "/" { return coreTy(DartWord.doubleWord) }
      if op == "~/" || op == "<<" || op == ">>" || op == ">>>" || op == "&" || op == "|" || op == "^" { return coreTy(DartWord.intWord) }
      if case .nominal(let a, _) = left, case .nominal(let b, _) = right, isNumber(right), decl(a).name == DartWord.intWord, decl(b).name != DartWord.intWord { return right }
      return left
    }
    if case .nominal(let ref, _) = left, isSDK(ref), decl(ref).name == DartWord.stringWord, op == "+" || op == "*" { return left }
    return operatorResult(unitIndex: unitIndex, left: left, op: op) ?? .unknown
  }

  /// The result of a type's operator method.
  private func operatorResult(unitIndex: Int32, left: Ty, op: String) -> Ty? {
    guard left != .unknown, let entry = memberEntries(of: left, named: name(op)).first else { return nil }
    return memberValueType(entry.0)
  }

  /// `switch (x) { p => e, … }`: the first arm's.
  private func switchType(unitIndex: Int32, at: Int, limit: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let brace = unit.skipBalanced(at + 1)
    guard unit.isByte(brace, 0x7B) else { return .unknown }
    let close = unit.skipBalanced(brace) - 1
    var k = brace + 1
    while k < close {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.isToken(k, "=>") {
        let end = unit.daExpressionEnd(k + 1, limit: close)
        let found = expressionType(unitIndex: unitIndex, start: Int32(k + 1), end: Int32(end))
        if found != .unknown { return found }
        k = end
        continue
      }
      k += 1
    }
    return .unknown
  }

  // MARK: Postfix

  /// A primary with its selectors: `.name`, `?.name`, `!`, calls, `[i]`, cascades (`a..b()` is `a`; `asOperand`: the
  /// last section's value, for what follows it).
  func postfixType(unitIndex: Int32, start i: inout Int, end: Int, asOperand: Bool) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard i < end else { return .unknown }
    var ty = operand(unitIndex: unitIndex, at: &i, end: end)
    var cascadeBase: Ty?
    while i < end {
      if unit.daIsDot(i) {
        if unit.daIsCascade(i) {
          if cascadeBase == nil { cascadeBase = ty }
          ty = cascadeBase!
        }
        if !unit.isByte(i, 0x2E) { ty = nonNull(ty) }
        if unit.daIsCascade(i), unit.isByte(i + 1, 0x5B) {
          i += 1
          continue
        }
        let nameToken = i + 1
        guard nameToken < end, unit.daIsName(nameToken) else { return .unknown }
        i = nameToken
        ty = member(ty, unitIndex: unitIndex, nameToken: nameToken, at: &i, end: end)
        continue
      }
      if unit.isByte(i, 0x5B) || unit.isByte(i, 0x3F) && unit.isByte(i + 1, 0x5B) {
        let open = unit.isByte(i, 0x5B) ? i : i + 1
        let close = unit.skipBalanced(open)
        ty = indexed(nonNull(ty))
        i = close
        continue
      }
      if unit.isByte(i, 0x21) {
        ty = nonNull(ty)
        i += 1
        continue
      }
      if unit.isToken(i, "++") || unit.isToken(i, "--") {
        i += 1
        continue
      }
      if unit.isByte(i, 0x28) {
        let close = unit.skipBalanced(i)
        ty = calledType(ty)
        i = close
        continue
      }
      if cascadeBase != nil, unit.tokens[i].kind == .punctuation, unit.string(i).hasSuffix("="), !unit.isToken(i, "=="), !unit.isToken(i, "!=") {
        // `..x = value`: on to the next section.
        var k = i + 1
        while k < end, !unit.daIsCascade(k) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
        i = k
        continue
      }
      break
    }
    if asOperand { return i < end ? .unknown : ty }
    if let cascadeBase { return cascadeBase }
    return i < end ? .unknown : ty
  }

  /// `x[i]`: the `[]` operator's result.
  func indexed(_ ty: Ty) -> Ty {
    guard ty != .unknown, let entry = memberEntries(of: ty, named: DartWord.indexOperator).first else { return .unknown }
    return memberValueType(entry.0)
  }

  /// A value called: a function type's result, a `call` method's.
  func calledType(_ ty: Ty) -> Ty {
    switch nonNull(ty) {
    case .function(_, let result): return result
    case .nominal:
      guard let entry = memberEntries(of: ty, named: DartWord.callWord).first else { return .unknown }
      return memberValueType(entry.0)
    default: return .unknown
    }
  }

  /// `.name` on a type: the member's value, or its call's result (with `i` past the call).
  private func member(_ ty: Ty, unitIndex: Int32, nameToken: Int, at i: inout Int, end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let word = unit.hash(nameToken)
    let open = callOpen(unit, nameToken).flatMap { $0 < end ? $0 : nil }
    i = open.map { unit.skipBalanced($0) } ?? nameToken + 1
    let explicit = open.map { typeArguments(unitIndex: unitIndex, from: nameToken + 1, open: $0) } ?? []
    switch ty {
    case .unknown:
      return .unknown
    case .module(let prefix):
      guard let refs = scope(ofUnit: unitIndex).prefixes[prefix]?.names[word], let ref = refs.first else { return .unknown }
      return value(of: ref, map: [:], unitIndex: unitIndex, open: open, explicit: explicit)
    case .meta(let type):
      guard let ref = staticMembers(type, word, setter: nil).first else { return .unknown }
      if ref == (type.nominalRef) { return coreTy(DartWord.listWord, [type]) }
      var map: [Name: Ty] = [:]
      if case .nominal(let owner, let args) = type, !args.isEmpty { map = argumentMap(owner, args) }
      if decl(ref).kind == .enumCase { return type }
      return value(of: ref, map: map, unitIndex: unitIndex, open: open, explicit: explicit)
    case .tuple(let elements, let labels):
      let text = unit.string(nameToken)
      if text.hasPrefix("$"), let n = Int(text.dropFirst()), n >= 1, n <= elements.count { return elements[n - 1] }
      if let at = labels.firstIndex(of: word), at < elements.count { return elements[at] }
      return .unknown
    default:
      var receiver = ty
      if case .existential(let parts) = ty {
        guard let part = parts.first(where: { !memberEntries(of: $0, named: word).isEmpty }) else { return .unknown }
        receiver = part
      }
      if let entry = memberEntries(of: receiver, named: word).first {
        return value(of: entry.0.ref, map: entry.0.substitution, unitIndex: unitIndex, open: open, explicit: explicit)
      }
      if let entry = extensionMembers(word, receiver: receiver, unitIndex: unitIndex).first {
        return value(of: entry.ref, map: entry.substitution, unitIndex: unitIndex, open: open, explicit: explicit)
      }
      return .unknown
    }
  }

  /// A declaration used as a value or called (`open`): a type's constructor, a function's result, a field's value.
  func value(of ref: DeclRef, map: [Name: Ty], unitIndex: Int32, open: Int?, explicit: [Ty]) -> Ty {
    let item = decl(ref)
    switch item.kind {
    case .classType, .enumeration, .structure, .typeAlias:
      guard let open else { return .meta(typeOf(ref, explicit)) }
      if item.kind == .typeAlias {
        let target = typeOf(ref, explicit)
        guard case .nominal(let classRef, let args) = target else { return calledType(target) }
        if let constructor = constructors(of: classRef).first(where: { decl($0).name == DartWord.newWord }), args.isEmpty {
          return callResult(constructor, map: [:], unitIndex: unitIndex, open: open, explicit: [])
        }
        return target
      }
      if let constructor = constructors(of: ref).first(where: { decl($0).name == DartWord.newWord }) {
        return callResult(constructor, map: map, unitIndex: unitIndex, open: open, explicit: explicit)
      }
      return .nominal(ref, explicit)
    case .extensionDecl:
      // `Ext(x)`: x with only the extension's members.
      return open != nil ? .nominal(ref, []) : .meta(.nominal(ref, []))
    case .function, .initializer:
      guard let open else { return substitute(functionType(ref), map) }
      return callResult(ref, map: map, unitIndex: unitIndex, open: open, explicit: explicit)
    case .variable, .enumCase:
      let ty = substitute(valueType(of: ref), map)
      return open != nil ? calledType(ty) : ty
    default:
      return .unknown
    }
  }

  /// Type arguments written before a call's `(`.
  func typeArguments(unitIndex: Int32, from: Int, open: Int) -> [Ty] {
    let unit = project.units[Int(unitIndex)]
    guard from < open, unit.startsWith(from, 0x3C) else { return [] }
    // `f<A, B>(`: read as a type named by the token before, its arguments taken.
    if case .nominal(_, let args) = parseType(unitIndex: unitIndex, start: Int32(from - 1), end: Int32(open), scope: Int32(from)), !args.isEmpty { return args }
    var result: [Ty] = []
    var k = from + 1
    while k < open - 1 {
      guard let end = unit.daTypeEnd(k, limit: open) else { break }
      result.append(parseType(unitIndex: unitIndex, start: Int32(k), end: Int32(end), scope: Int32(k)))
      k = end
      if unit.isByte(k, 0x2C) { k += 1 } else { break }
    }
    return result
  }

  // MARK: Calls

  /// A call's result: the declared type with the receiver's arguments put in, its own type parameters (a constructor's
  /// class's) bound from what's written or what's passed; unbound ones are unknown.
  func callResult(_ ref: DeclRef, map: [Name: Ty], unitIndex: Int32, open: Int, explicit: [Ty]) -> Ty {
    let item = decl(ref)
    var own: [Name] = []
    var owner = ref
    if item.kind == .initializer, item.parent >= 0 { owner = DeclRef(unit: ref.unit, decl: item.parent) }
    let ownerDecl = decl(owner)
    let holder = unit(owner)
    for g in 0..<Int(ownerDecl.genericCount) { own.append(holder.generics[Int(ownerDecl.genericStart) + g].name) }
    var result = substitute(valueType(of: ref), map)
    if own.isEmpty || item.kind == .initializer && own.allSatisfy({ map[$0] != nil }) { return result }
    var bindings: [Name: Ty] = [:]
    if !explicit.isEmpty {
      for (word, ty) in zip(own, explicit) { bindings[word] = ty }
    } else {
      bindings = inferBindings(ref, map: map, own: Set(own), unitIndex: unitIndex, open: open, closures: true)
    }
    for word in own where bindings[word] == nil { bindings[word] = .unknown }
    result = substitute(result, bindings)
    return result
  }

  /// A call's arguments between its parentheses: each one's range and its name (0: positional).
  func arguments(_ unit: Unit, open: Int) -> [(start: Int, end: Int, label: Name)] {
    let close = unit.skipBalanced(open) - 1
    var result: [(start: Int, end: Int, label: Name)] = []
    var k = open + 1
    while k < close {
      var label: Name = 0
      var start = k
      if unit.daIsName(k), unit.isByte(k + 1, 0x3A) {
        label = unit.hash(k)
        start = k + 2
      }
      let end = unit.daExpressionEnd(start, limit: close)
      if end > start { result.append((start, end, label)) }
      k = end + 1
    }
    return result
  }

  /// The parameter an argument goes to: by name, else the next positional one.
  func parameterIndex(_ ref: DeclRef, label: Name, position: Int) -> Int? {
    let item = decl(ref)
    let holder = unit(ref)
    var positional = 0
    for p in 0..<Int(item.paramCount) {
      let param = holder.params[Int(item.paramStart) + p]
      if label != 0 {
        if param.label == label { return p }
      } else if param.label == 0 {
        if positional == position { return p }
        positional += 1
      }
    }
    return nil
  }

  /// Binds a callee's own type parameters from the arguments' types (closures' results when `closures`).
  func inferBindings(_ ref: DeclRef, map: [Name: Ty], own: Set<Name>, unitIndex: Int32, open: Int, closures: Bool) -> [Name: Ty] {
    let unit = project.units[Int(unitIndex)]
    var bindings: [Name: Ty] = [:]
    var later: [(Int, Int)] = []
    var position = 0
    for argument in arguments(unit, open: open) {
      let isPositional = argument.label == 0
      defer { if isPositional { position += 1 } }
      guard let p = parameterIndex(ref, label: argument.label, position: position) else { continue }
      if isClosure(unit, argument.start) {
        later.append((argument.start, p))
        continue
      }
      let want = substitute(parameterType(ref, p), map)
      bind(want, expressionType(unitIndex: unitIndex, start: Int32(argument.start), end: Int32(argument.end)), own, &bindings)
    }
    guard closures else { return bindings }
    for (start, p) in later {
      let want = substitute(substitute(parameterType(ref, p), map), bindings)
      guard case .function(_, let result) = nonNull(want) else { continue }
      let returned = closureResultType(unitIndex: unitIndex, open: start)
      bind(result, returned, own, &bindings)
    }
    return bindings
  }

  /// `unify`, with `FutureOr<T>` taking a future's value or a plain one.
  func bind(_ pattern: Ty, _ actual: Ty, _ own: Set<Name>, _ bindings: inout [Name: Ty]) {
    if case .nominal(let ref, let args) = nonNull(pattern), decl(ref).name == DartWord.futureOrWord, isSDK(ref), let inner = args.first {
      unify(inner, awaited(actual), own, &bindings)
      return
    }
    unify(nonNull(pattern), nonNull(actual), own, &bindings)
  }

  /// Whether a closure starts at a token: `(…) {`, `(…) =>`, `(…) async {`.
  func isClosure(_ unit: Unit, _ at: Int) -> Bool {
    guard unit.isByte(at, 0x28) else { return false }
    var k = unit.skipBalanced(at)
    if unit.isToken(k, "async") || unit.isToken(k, "sync") {
      k += 1
      if unit.isByte(k, 0x2A) { k += 1 }
    }
    return unit.isByte(k, 0x7B) || unit.isToken(k, "=>")
  }

  /// What a call at `(` calls, with its receiver's arguments: functions, methods, constructors (a class's unnamed one).
  func callTarget(unitIndex: Int32, open: Int) -> (refs: [DeclRef], map: [Name: Ty])? {
    let unit = project.units[Int(unitIndex)]
    var nameToken = open - 1
    if nameToken >= 0, unit.tokens[nameToken].kind == .punctuation, unit.daClosesTypeArguments(nameToken) {
      // `f<T>(`: back to the name.
      var k = nameToken
      var budget = 40
      while k > 0, budget > 0, !(unit.startsWith(k, 0x3C) && unit.daTypeArgumentsEnd(k) == open) {
        budget -= 1
        k -= 1
      }
      guard budget > 0 else { return nil }
      nameToken = k - 1
    }
    guard nameToken >= 0 else { return nil }
    let explicit = typeArguments(unitIndex: unitIndex, from: nameToken + 1, open: open)
    if unit.isToken(nameToken, "super") || unit.isToken(nameToken, "this"), let constructor = chain(unit, unitIndex: unitIndex, at: Int32(open)).last.map({ DeclRef(unit: unitIndex, decl: $0) }),
      decl(constructor).kind == .initializer, decl(constructor).parent >= 0
    {
      // `super(…)`, `this(…)` in an initializer list.
      let owner = DeclRef(unit: unitIndex, decl: decl(constructor).parent)
      if unit.isToken(nameToken, "this") { return (constructors(of: owner).filter { decl($0).name == DartWord.newWord }, [:]) }
      guard let superclass = superclassType(owner), case .nominal(let target, let args) = superclass else { return nil }
      return (constructors(of: target).filter { decl($0).name == DartWord.newWord }, argumentMap(target, args))
    }
    guard unit.daIsName(nameToken) else { return nil }
    let word = unit.hash(nameToken)
    if nameToken > 0, unit.daIsDot(nameToken - 1) {
      let dot = nameToken - 1
      if unit.isToken(dot - 1, "this") || unit.isToken(dot - 1, "super"), let constructor = chain(unit, unitIndex: unitIndex, at: Int32(open)).last.map({ DeclRef(unit: unitIndex, decl: $0) }),
        decl(constructor).kind == .initializer, decl(constructor).initStart >= 0, nameToken >= Int(decl(constructor).initStart), nameToken < Int(decl(constructor).initEnd)
      {
        let owner = DeclRef(unit: unitIndex, decl: decl(constructor).parent)
        if unit.isToken(dot - 1, "this") { return (constructors(of: owner).filter { decl($0).name == word }, [:]) }
        guard let superclass = superclassType(owner), case .nominal(let target, let args) = superclass else { return nil }
        return (constructors(of: target).filter { decl($0).name == word }, argumentMap(target, args))
      }
      let receiver = operandType(unitIndex: unitIndex, dot: dot)
      switch receiver {
      case .unknown:
        return nil
      case .module(let prefix):
        guard let refs = scope(ofUnit: unitIndex).prefixes[prefix]?.names[word] else { return nil }
        return callable(refs, explicit: explicit)
      case .meta(let type):
        guard let ref = staticMembers(type, word, setter: nil).first else { return nil }
        var map: [Name: Ty] = [:]
        if case .nominal(let owner, let args) = type, !args.isEmpty { map = argumentMap(owner, args) }
        return ([ref], map)
      default:
        var base = receiver
        if case .existential(let parts) = receiver, let part = parts.first(where: { !memberEntries(of: $0, named: word).isEmpty }) { base = part }
        if let entry = memberEntries(of: base, named: word).first { return ([entry.0.ref], entry.0.substitution) }
        if let entry = extensionMembers(word, receiver: base, unitIndex: unitIndex).first { return ([entry.ref], entry.substitution) }
        return nil
      }
    }
    let sites = nameSites(word, unitIndex: unitIndex, token: Int32(nameToken), assigning: false)
    let refs = sites.compactMap { site -> DeclRef? in if case .decl(let ref) = site { return ref } else { return nil } }
    guard let first = refs.first else { return nil }
    if let found = callable(refs, explicit: explicit), decl(first).kind.isType { return found }
    return ([first], inheritedMap(first, unitIndex: unitIndex, token: Int32(nameToken)))
  }

  /// Declarations called: a type's unnamed constructor (its class's arguments as written), a function.
  private func callable(_ refs: [DeclRef], explicit: [Ty]) -> (refs: [DeclRef], map: [Name: Ty])? {
    guard let first = refs.first else { return nil }
    let item = decl(first)
    if item.kind.isNominal {
      let found = constructors(of: first).filter { decl($0).name == DartWord.newWord }
      return found.isEmpty ? nil : (found, explicit.isEmpty ? [:] : argumentMap(first, explicit))
    }
    if item.kind == .typeAlias, case .nominal(let target, let args) = typeOf(first, explicit) {
      let found = constructors(of: target).filter { decl($0).name == DartWord.newWord }
      return found.isEmpty ? nil : (found, args.isEmpty ? [:] : argumentMap(target, args))
    }
    return ([first], [:])
  }

  /// An inherited member named without a receiver: how its class's parameters read from the class around the token.
  func inheritedMap(_ ref: DeclRef, unitIndex: Int32, token: Int32) -> [Name: Ty] {
    let item = decl(ref)
    guard item.parent >= 0, !item.isStatic, let type = enclosingTypes(unitIndex: unitIndex, token: token).first else { return [:] }
    if type.unit == ref.unit, type.decl == item.parent { return [:] }
    return memberEntries(of: thisType(type), named: item.name).first { $0.0.ref == ref }?.0.substitution ?? [:]
  }

  // MARK: Closures

  /// A closure's type as a value.
  func closureValueType(unitIndex: Int32, open: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard unit.isByte(open, 0x28) else { return .function([], .unknown) }
    let count = arguments(unit, open: open).count
    return .function(Array(repeating: .unknown, count: count), closureResultType(unitIndex: unitIndex, open: open))
  }

  /// What a closure returns: its arrow's expression, its block's first `return`'s; an `async` one's in a `Future`.
  func closureResultType(unitIndex: Int32, open: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard depth < 30 else { return .unknown }
    var k = unit.skipBalanced(open)
    var isAsync = false
    if unit.isToken(k, "async") {
      isAsync = !unit.isByte(k + 1, 0x2A)
      k += 1
      if unit.isByte(k, 0x2A) { k += 1 }
    } else if unit.isToken(k, "sync") {
      return .unknown
    }
    var result = Ty.unknown
    if unit.isToken(k, "=>") {
      let end = unit.daExpressionEnd(k + 1, limit: unit.tokens.count)
      result = expressionType(unitIndex: unitIndex, start: Int32(k + 1), end: Int32(end))
    } else if unit.isByte(k, 0x7B) {
      let close = unit.skipBalanced(k) - 1
      var m = k + 1
      while m < close {
        if unit.tokens[m].kind == .open, unit.isByte(m, 0x28), isClosure(unit, m) {
          // A nested closure's returns are its own.
          var after = unit.skipBalanced(m)
          if unit.isToken(after, "async") { after += 1 }
          m = unit.isByte(after, 0x7B) ? unit.skipBalanced(after) : after + 1
          continue
        }
        if unit.isToken(m, "return"), !unit.isByte(m + 1, 0x3B) {
          let end = unit.daExpressionEnd(m + 1, limit: close)
          result = expressionType(unitIndex: unitIndex, start: Int32(m + 1), end: Int32(end))
          break
        }
        m += 1
      }
      if result == .unknown, !(k + 1..<close).contains(where: { unit.isToken($0, "return") }) { result = .constructed(DartWord.voidWord, []) }
    }
    if isAsync { return coreTy(DartWord.futureWord, [awaited(result)]) }
    return result
  }

  /// A closure's parameter without a type: from the function type of the parameter it's passed to.
  func closureParameterType(unitIndex: Int32, open: Int, position: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard let call = unit.matchingOpenBefore(open), unit.isByte(call, 0x28) || unit.isByte(call, 0x5B) || unit.isByte(call, 0x7B) else { return .unknown }
    if unit.isByte(call, 0x28), let target = callTarget(unitIndex: unitIndex, open: call), let ref = target.refs.first {
      var place = 0
      for argument in arguments(unit, open: call) {
        defer { if argument.label == 0 { place += 1 } }
        guard argument.start == open else { continue }
        guard let p = parameterIndex(ref, label: argument.label, position: place) else { return .unknown }
        var want = substitute(parameterType(ref, p), target.map)
        let item = decl(ref)
        var owner = ref
        if item.kind == .initializer, item.parent >= 0 { owner = DeclRef(unit: ref.unit, decl: item.parent) }
        let ownerDecl = decl(owner)
        var own: Set<Name> = []
        for g in 0..<Int(ownerDecl.genericCount) { own.insert(self.unit(owner).generics[Int(ownerDecl.genericStart) + g].name) }
        if !own.isEmpty, !(item.kind == .initializer && own.allSatisfy { target.map[$0] != nil }) {
          let bindings = inferBindings(ref, map: target.map, own: own, unitIndex: unitIndex, open: call, closures: false)
          want = substitute(want, bindings)
        }
        guard case .function(let params, _) = nonNull(want), position < params.count else { return .unknown }
        return params[position]
      }
      return .unknown
    }
    // `final void Function(int) f = (x) {…};`, `T Function(A) f = …` as a field's or variable's initializer.
    if let declared = declaredFunctionType(unitIndex: unitIndex, open: open), case .function(let params, _) = declared, position < params.count {
      return params[position]
    }
    return .unknown
  }

  /// The written function type of a variable whose initializer is the closure at `open`.
  private func declaredFunctionType(unitIndex: Int32, open: Int) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    guard unit.isToken(open - 1, "="), unit.daIsName(open - 2) else { return nil }
    for (index, item) in unit.decls.enumerated() where item.initStart == Int32(open) {
      return nonNull(valueType(of: DeclRef(unit: unitIndex, decl: Int32(index))))
    }
    if let body = body(unitIndex: unitIndex, token: Int32(open)), let local = body.byToken[Int32(open - 2)], case .typed = body.locals[Int(local)].kind {
      return nonNull(localType(unitIndex: unitIndex, body: body, index: local))
    }
    return nil
  }

  // MARK: Operands

  /// A primary expression: a literal, a name (a local, a member, a type, a prefix), `this`, `super`, a parenthesized
  /// expression, a record, a closure, a collection literal.
  private func operand(unitIndex: Int32, at i: inout Int, end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let token = unit.tokens[i]
    switch token.kind {
    case .number:
      i += 1
      let text = unit.string(i - 1)
      let isDouble = !text.hasPrefix("0x") && !text.hasPrefix("0X") && (text.contains(".") || text.contains("e") || text.contains("E"))
      return coreTy(isDouble ? DartWord.doubleWord : DartWord.intWord)
    case .string:
      i = unit.daStringEnd(i)
      return stringType()
    case .open:
      if unit.isByte(i, 0x28) {
        if isClosure(unit, i) {
          let ty = closureValueType(unitIndex: unitIndex, open: i)
          var k = unit.skipBalanced(i)
          if unit.isToken(k, "async") || unit.isToken(k, "sync") { k += unit.isByte(k + 1, 0x2A) ? 2 : 1 }
          i = unit.isByte(k, 0x7B) ? unit.skipBalanced(k) : unit.daExpressionEnd(k + 1, limit: end)
          return ty
        }
        let close = unit.skipBalanced(i)
        let items = arguments(unit, open: i)
        // `(x,)`: a record of one; a comma in type arguments isn't one.
        let hasComma = items.count == 1 && unit.isByte(items[0].end, 0x2C)
        defer { i = close }
        if items.count == 1, !hasComma, items[0].label == 0 { return expressionType(unitIndex: unitIndex, start: Int32(items[0].start), end: Int32(items[0].end)) }
        return .tuple(items.map { expressionType(unitIndex: unitIndex, start: Int32($0.start), end: Int32($0.end)) }, items.map(\.label))
      }
      return collectionLiteral(unitIndex: unitIndex, at: &i, typeArgs: [])
    case .punctuation:
      if unit.startsWith(i, 0x3C), let after = unit.daTypeArgumentsEnd(i, limit: end), unit.isByte(after, 0x5B) || unit.isByte(after, 0x7B) {
        let args = typeArguments(unitIndex: unitIndex, from: i, open: after)
        i = after
        return collectionLiteral(unitIndex: unitIndex, at: &i, typeArgs: args)
      }
      return .unknown
    case .keyword, .declarationKeyword, .identifier:
      if unit.isToken(i, "this") {
        i += 1
        return enclosingTypes(unitIndex: unitIndex, token: Int32(i - 1)).first.map(thisType) ?? .unknown
      }
      if unit.isToken(i, "super") {
        i += 1
        guard let type = enclosingTypes(unitIndex: unitIndex, token: Int32(i - 1)).first, decl(type).kind != .extensionDecl else { return .unknown }
        return superType(type)
      }
      if unit.isToken(i, "true") || unit.isToken(i, "false") {
        i += 1
        return boolType()
      }
      if unit.isToken(i, "null") {
        i += 1
        return .unknown
      }
      if unit.isToken(i, "new") || unit.isToken(i, "const") {
        i += 1
        guard i < end else { return .unknown }
        return operand(unitIndex: unitIndex, at: &i, end: end)
      }
      guard unit.daIsName(i) else {
        i += 1
        return .unknown
      }
      return nameValue(unitIndex: unitIndex, at: &i, end: end)
    default:
      i += 1
      return .unknown
    }
  }

  /// A name as an operand: what it names, as a value or called.
  private func nameValue(unitIndex: Int32, at i: inout Int, end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let token = i
    let word = unit.hash(token)
    let open = callOpen(unit, token).flatMap { $0 < end ? $0 : nil }
    i = open.map { unit.skipBalanced($0) } ?? token + 1
    let explicit = open.map { typeArguments(unitIndex: unitIndex, from: token + 1, open: $0) } ?? []
    let body = body(unitIndex: unitIndex, token: Int32(token))
    if let body, let index = body.local(named: word, at: Int32(token)) {
      let ty = localType(unitIndex: unitIndex, body: body, index: index, at: Int32(token))
      return open != nil ? calledType(ty) : ty
    }
    // A prefix: `p.Foo`.
    if unit.daIsDot(token + 1), open == nil, scope(ofUnit: unitIndex).prefixes[word] != nil {
      let sites = nameSites(word, unitIndex: unitIndex, token: Int32(token), assigning: false)
      if sites.allSatisfy({ if case .local = $0 { return true } else { return false } }) { return .module(word) }
    }
    // `Foo<int>.named(…)`, `Foo<int>`: a type with arguments.
    var typeArgs: [Ty] = []
    if open == nil, unit.tokens.indices.contains(token + 1), unit.tokens[token + 1].kind == .punctuation, unit.startsWith(token + 1, 0x3C),
      let after = unit.daTypeArgumentsEnd(token + 1, limit: end), unit.daIsDot(after)
    {
      typeArgs = typeArguments(unitIndex: unitIndex, from: token + 1, open: after)
      i = after
    }
    let sites = nameSites(word, unitIndex: unitIndex, token: Int32(token), assigning: false)
    guard let site = sites.first else { return .unknown }
    switch site {
    case .local(let u, let t):
      // An import prefix, or a local seen from a nested declaration.
      if project.units[Int(u)].imports.contains(where: { $0.aliasToken == t }) { return .module(word) }
      return .unknown
    case .generic(let u, let t):
      return .meta(genericSite(project.units[Int(u)].hash(Int(t)), unitIndex: u, token: t)?.1 ?? .unknown)
    case .decl(let ref):
      if !typeArgs.isEmpty, decl(ref).kind.isType { return .meta(typeOf(ref, typeArgs)) }
      return value(of: ref, map: inheritedMap(ref, unitIndex: unitIndex, token: Int32(token)), unitIndex: unitIndex, open: open, explicit: explicit)
    case .module:
      return .unknown
    }
  }

  /// `[…]`, `{…}`: a list, a map (an entry's `:`, or empty), a set; their element types from what's written or the
  /// first element.
  private func collectionLiteral(unitIndex: Int32, at i: inout Int, typeArgs: [Ty]) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let open = i
    let close = unit.skipBalanced(open)
    i = close
    let items = arguments(unit, open: open)
    func elementType(_ item: (start: Int, end: Int, label: Name)) -> Ty {
      if unit.isToken(item.start, "...") || unit.isToken(item.start, "...?") {
        return iterableElement(expressionType(unitIndex: unitIndex, start: Int32(item.start + 1), end: Int32(item.end)))
      }
      if unit.isToken(item.start, "if") || unit.isToken(item.start, "for") { return .unknown }
      return expressionType(unitIndex: unitIndex, start: Int32(item.start), end: Int32(item.end))
    }
    if unit.isByte(open, 0x5B) {
      return coreTy(DartWord.listWord, [typeArgs.first ?? items.first.map(elementType) ?? .unknown])
    }
    if typeArgs.count == 2 { return coreTy(DartWord.mapWord, typeArgs) }
    if typeArgs.count == 1 { return coreTy(DartWord.setWord, typeArgs) }
    guard let first = items.first else { return coreTy(DartWord.mapWord, [.unknown, .unknown]) }
    // A map entry: `key: value` at the element's top (a named label reads as one).
    var colon = -1
    if first.label != 0 { colon = first.start - 1 }
    var k = first.start
    while colon < 0, k < first.end {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.isByte(k, 0x3F) { break }
      if unit.isByte(k, 0x3A) { colon = k }
      k += 1
    }
    if colon >= 0 {
      let keyStart = first.label != 0 ? colon - 1 : first.start
      let key = expressionType(unitIndex: unitIndex, start: Int32(keyStart), end: Int32(colon))
      let value = expressionType(unitIndex: unitIndex, start: Int32(colon + 1), end: Int32(first.end))
      return coreTy(DartWord.mapWord, [key, value])
    }
    return coreTy(DartWord.setWord, [elementType(first)])
  }

  // MARK: Receivers

  /// The type of what's before a dot: a cascade's target for `..`.
  func operandType(unitIndex: Int32, dot: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    if unit.daIsCascade(dot) { return cascadeTarget(unitIndex: unitIndex, dot: dot) }
    let start = expressionStart(unit, before: dot)
    guard start < dot else { return .unknown }
    var i = start
    return postfixType(unitIndex: unitIndex, start: &i, end: dot, asOperand: true)
  }

  /// What a cascade section's `..` applies to: the expression before the first `..` of its cascade.
  func cascadeTarget(unitIndex: Int32, dot: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var first = dot
    var assignment = -1
    var k = dot - 1
    var budget = 4000
    while k >= 0, budget > 0 {
      budget -= 1
      let token = unit.tokens[k]
      if token.kind == .close || token.kind == .interpolationClose {
        guard let open = unit.matchingOpen(k) else { break }
        k = open - 1
        continue
      }
      // `Map<String, int>`: the type arguments' commas aren't the end.
      if unit.daClosesTypeArguments(k), let lt = typeArgumentsStart(unit, closing: k) {
        k = lt - 1
        continue
      }
      if token.kind == .open || unit.isByte(k, 0x3B) || unit.isByte(k, 0x2C) || unit.isToken(k, "=>") || unit.isToken(k, "return") || unit.isByte(k, 0x3A) || unit.isToken(k, "yield") {
        break
      }
      if unit.daIsCascade(k) {
        first = k
        assignment = -1
      } else if token.kind == .punctuation, unit.string(k).hasSuffix("="), !unit.isToken(k, "=="), !unit.isToken(k, "!="), !unit.isToken(k, "<="), !unit.isToken(k, ">="), assignment < 0 {
        assignment = k
      }
      k -= 1
    }
    // Assignments seen before the first cascade (walking back) are the target's own: `x = a..b`.
    let start = max(k + 1, assignment >= 0 && assignment < first ? assignment + 1 : k + 1)
    guard start < first else { return .unknown }
    return expressionType(unitIndex: unitIndex, start: Int32(start), end: Int32(first))
  }

  /// The `<` whose type arguments end with the `>` at `closing` (within a few tokens), when a name is before it.
  func typeArgumentsStart(_ unit: Unit, closing: Int) -> Int? {
    var lt = closing - 1
    var steps = 60
    while lt > 0, steps > 0 {
      if unit.tokens[lt].kind == .punctuation, unit.startsWith(lt, 0x3C), unit.daTypeArgumentsEnd(lt) == closing + 1 { return unit.daIsName(lt - 1) ? lt : nil }
      steps -= 1
      lt -= 1
    }
    return nil
  }

  /// Walking back from just before `end`: names, dots, calls, indexes, `!`, as far as one operand goes.
  func expressionStart(_ unit: Unit, before end: Int) -> Int {
    var i = end - 1
    var budget = 400
    while i >= 0, budget > 0 {
      budget -= 1
      let token = unit.tokens[i]
      if token.kind == .close || token.kind == .interpolationClose {
        guard let open = unit.matchingOpen(i) else { return i + 1 }
        if unit.isByte(i, 0x29) || unit.isByte(i, 0x5D) {
          // A call or an index: what's called comes first.
          var k = open - 1
          if k >= 0, unit.isByte(k, 0x3F), unit.isByte(i, 0x5D) { k -= 1 }
          if k >= 0, unit.tokens[k].kind == .punctuation, unit.daClosesTypeArguments(k), unit.isByte(i, 0x29) {
            var lt = k
            var steps = 40
            while lt > 0, steps > 0, !(unit.startsWith(lt, 0x3C) && unit.tokens[lt].kind == .punctuation && unit.daTypeArgumentsEnd(lt) == open) {
              steps -= 1
              lt -= 1
            }
            if steps > 0 { k = lt - 1 }
          }
          if k >= 0, unit.daIsName(k) && !unit.isToken(k, "await") && !unit.isToken(k, "yield") || unit.tokens[k].kind == .close || unit.isToken(k, "this") || unit.isToken(k, "super") || unit.isByte(k, 0x21) && unit.isByte(i, 0x5D) {
            i = k
            continue
          }
          // A list literal with type arguments, a parenthesized expression, a record.
          if unit.isByte(i, 0x5D), k >= 0, unit.tokens[k].kind == .punctuation, unit.daClosesTypeArguments(k) {
            var lt = k
            while lt > 0, !(unit.startsWith(lt, 0x3C) && unit.daTypeArgumentsEnd(lt) == open) { lt -= 1 }
            return lt
          }
          if k >= 0, unit.isToken(k, "const") { return k }
          return open
        }
        // `{…}`: a map or set literal.
        return open
      }
      // `Future<void>.delayed`: a type's arguments before the dot.
      if i == end - 1, token.kind == .punctuation, unit.daClosesTypeArguments(i) {
        var lt = i - 1
        var steps = 40
        while lt > 0, steps > 0, !(unit.tokens[lt].kind == .punctuation && unit.startsWith(lt, 0x3C) && unit.daTypeArgumentsEnd(lt) == i + 1) {
          steps -= 1
          lt -= 1
        }
        guard steps > 0, lt > 0, unit.daIsName(lt - 1) else { return i + 1 }
        i = lt - 1
        if i > 0, unit.daIsDot(i - 1), !unit.daIsCascade(i - 1) { i -= 2 }
        continue
      }
      if unit.isByte(i, 0x21), i > 0, unit.tokens[i - 1].kind == .identifier || unit.tokens[i - 1].kind == .close || unit.daIsName(i - 1) {
        i -= 1
        continue
      }
      if unit.daIsName(i) || token.kind == .number || token.kind == .string || unit.isToken(i, "this") || unit.isToken(i, "super") || unit.isToken(i, "null")
        || unit.isToken(i, "true") || unit.isToken(i, "false")
      {
        if token.kind == .string || unit.daIsInterpolatedName(i) {
          // Back over a string's pieces and interpolations.
          while i > 0 {
            if unit.tokens[i - 1].kind == .interpolationClose, let o = unit.matchingOpen(i - 1) {
              i = o
            } else if unit.tokens[i - 1].kind == .string || unit.daIsInterpolatedName(i - 1) || unit.daIsInterpolatedName(i) {
              i -= 1
            } else if unit.tokens[i].kind == .interpolationOpen, unit.tokens[i - 1].kind == .string {
              i -= 1
            } else {
              break
            }
          }
          return i
        }
        if i > 0, unit.daIsDot(i - 1), !unit.daIsCascade(i - 1) {
          i -= 2
          continue
        }
        if i > 0, unit.daIsCascade(i - 1) {
          i -= 2
          continue
        }
        return i
      }
      return i + 1
    }
    return max(0, i + 1)
  }
}

extension Ty {
  /// The declaration of a nominal type.
  var nominalRef: DeclRef? {
    if case .nominal(let ref, _) = self { return ref }
    return nil
  }
}
