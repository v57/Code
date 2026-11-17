import CodeModel
import CodeScan
import Foundation

/// Expressions' static types: literals, names, `this`/`base`, `new` (target-typed too), casts, `as`, `is`, `await`,
/// operators on the keyword types and strings, `??`, conditionals, `switch` expressions, member access (`?.` too),
/// calls (overloads chosen, a generic method's parameters inferred from its arguments, extension methods), indexers.
/// What it can't tell is `unknown`: a user-defined operator, a lambda, a collection expression.
extension CSharpModel {
  func stringType() -> Ty { systemType("String").map { .nominal($0, []) } ?? .unknown }
  func boolType() -> Ty { systemType("Boolean").map { .nominal($0, []) } ?? .unknown }
  func keywordType(_ text: String) -> Ty { predefinedType(name(text)) }

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
    // Top-level operators, the loosest first: assignment, lambda, conditional, `??`, then binary ones.
    var operators: [Int] = []
    var question = -1
    var coalesce = -1
    var k = s
    while k < limit {
      let token = unit.tokens[k]
      if token.kind == .open || token.kind == .interpolationOpen {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.isToken(k, "new") || unit.isToken(k, "is") || unit.isToken(k, "as") {
        if unit.isToken(k, "is") { return boolType() }
        if unit.isToken(k, "as"), k > s { return parseType(unitIndex: unitIndex, start: Int32(k + 1), end: Int32(unit.csTypeEnd(k + 1, limit: limit) ?? limit), scope: Int32(k)) }
        k = unit.csTypeEnd(k + 1, limit: limit) ?? k + 1
        continue
      }
      if unit.isToken(k, "switch"), k > s, unit.isByte(k + 1, 0x7B) { return switchType(unitIndex: unitIndex, brace: k + 1) }
      if unit.isToken(k, "with"), k > s, unit.isByte(k + 1, 0x7B) { return expressionType(unitIndex: unitIndex, start: start, end: Int32(k)) }
      if token.kind == .punctuation {
        if unit.isToken(k, "=>") { return .unknown }
        if isAssignment(unit, k), k > s { return expressionType(unitIndex: unitIndex, start: start, end: Int32(k)) }
        if unit.isToken(k, "??"), coalesce < 0, k > s { coalesce = k }
        if unit.isByte(k, 0x3F), question < 0, k > s, !isNullableMark(unit, k, limit) { question = k }
        // `List<int>.Empty`, `Foo<T>(`: type arguments, not comparisons.
        if unit.startsWith(k, 0x3C), k > s, unit.csIsName(k - 1), let after = unit.csTypeArgumentsEnd(k, limit: limit),
          unit.isByte(after, 0x28) || unit.csIsDot(after) || after == limit || unit.isByte(after, 0x29) || unit.isByte(after, 0x2C)
        {
          k = after
          continue
        }
        if k > s, !unit.csIsDot(k), !unit.isToken(k, "::"), !unit.isByte(k, 0x2C), !unit.isByte(k, 0x3F), !unit.isByte(k, 0x3A), !unit.isToken(k, "??"), !unit.isByte(k, 0x21),
          !isPrefixPosition(unit, k, start: s)
        {
          operators.append(k)
        }
      }
      k += 1
    }
    if question >= 0, coalesce < 0 || question < coalesce || true {
      // `c ? a : b`: a's type, else b's.
      if let colon = conditionalColon(unit, question, limit), coalesce < 0 || coalesce > question || coalesce < question {
        if coalesce < 0 || coalesce > question {
          let a = expressionType(unitIndex: unitIndex, start: Int32(question + 1), end: Int32(colon))
          let b = expressionType(unitIndex: unitIndex, start: Int32(colon + 1), end: end)
          if a == .unknown || isNull(unit, question + 1, colon) { return b }
          return a
        }
      }
    }
    if coalesce >= 0 {
      let left = expressionType(unitIndex: unitIndex, start: start, end: Int32(coalesce))
      if let inner = nullableValue(left) {
        let right = expressionType(unitIndex: unitIndex, start: Int32(coalesce + 1), end: end)
        return nullableValue(right) != nil ? right : inner
      }
      if left != .unknown { return left }
      return expressionType(unitIndex: unitIndex, start: Int32(coalesce + 1), end: end)
    }
    if !operators.isEmpty { return binaryType(unitIndex: unitIndex, start: s, end: limit, operators: operators) }
    // Prefix operators.
    if unit.isToken(s, "await") {
      let inner = expressionType(unitIndex: unitIndex, start: start + 1, end: end)
      return awaitedType(inner) ?? .unknown
    }
    if unit.isToken(s, "throw") { return .unknown }
    if unit.tokens[s].kind == .punctuation {
      if unit.isByte(s, 0x21) { return boolType() }
      if unit.isToken(s, "..") || unit.isToken(s, "^") && false { return systemType("Range").map { .nominal($0, []) } ?? .unknown }
      if unit.isByte(s, 0x5E) { return systemType("Index").map { .nominal($0, []) } ?? .unknown }
      if unit.isByte(s, 0x2D) || unit.isByte(s, 0x2B) || unit.isByte(s, 0x7E) || unit.isToken(s, "++") || unit.isToken(s, "--") {
        let inner = expressionType(unitIndex: unitIndex, start: start + 1, end: end)
        if unit.isToken(s, "++") || unit.isToken(s, "--") { return inner }
        return promoted(inner)
      }
      if unit.isByte(s, 0x26) {
        let inner = expressionType(unitIndex: unitIndex, start: start + 1, end: end)
        return inner == .unknown ? .unknown : .constructed(Ty.pointer, [inner])
      }
      if unit.isByte(s, 0x2A) {
        if case .constructed(let kind, let args) = expressionType(unitIndex: unitIndex, start: start + 1, end: end), kind == Ty.pointer { return args.first ?? .unknown }
        return .unknown
      }
      return .unknown
    }
    var i = s
    return postfixType(unitIndex: unitIndex, start: &i, end: limit)
  }

  private func isNull(_ unit: Unit, _ start: Int, _ end: Int) -> Bool { end == start + 1 && (unit.isToken(start, "null") || unit.isToken(start, "default")) }

  /// A `?` that marks a nullable type (`x is int? y`, `(string?)x`) rather than a conditional.
  private func isNullableMark(_ unit: Unit, _ k: Int, _ limit: Int) -> Bool {
    if k + 1 >= limit { return true }
    if unit.isByte(k + 1, 0x29) || unit.isByte(k + 1, 0x2C) || unit.isByte(k + 1, 0x5B) && unit.isByte(k + 2, 0x5D) { return true }
    return false
  }

  /// The `:` of the conditional whose `?` is at `question`.
  private func conditionalColon(_ unit: Unit, _ question: Int, _ limit: Int) -> Int? {
    var colon = question + 1
    var nested = 0
    while colon < limit {
      if unit.tokens[colon].kind == .open || unit.tokens[colon].kind == .interpolationOpen {
        colon = unit.skipBalanced(colon)
        continue
      }
      if unit.isByte(colon, 0x3F), !isNullableMark(unit, colon, limit) { nested += 1 }
      if unit.isByte(colon, 0x3A) {
        if nested == 0 { return colon }
        nested -= 1
      }
      colon += 1
    }
    return nil
  }

  private func isAssignment(_ unit: Unit, _ k: Int) -> Bool {
    let token = unit.tokens[k]
    guard token.kind == .punctuation, unit.source.text[token.start + token.length - 1] == 0x3D else { return false }
    if token.length == 1 { return true }
    if unit.isToken(k, "==") || unit.isToken(k, "!=") || unit.isToken(k, "<=") || unit.isToken(k, ">=") { return false }
    return true
  }

  /// Whether a punctuation token is a prefix operator (after another operator, or at the start), or a postfix one.
  private func isPrefixPosition(_ unit: Unit, _ k: Int, start: Int) -> Bool {
    if unit.isToken(k, "++") || unit.isToken(k, "--") { return true }
    guard k > start else { return true }
    let before = unit.tokens[k - 1]
    if before.kind == .punctuation, !unit.isToken(k - 1, "++"), !unit.isToken(k - 1, "--"), !unit.isByte(k - 1, 0x21) { return true }
    if before.kind == .keyword, unit.isToken(k - 1, "return") || unit.isToken(k - 1, "await") { return true }
    return false
  }

  /// The type a numeric operation computes in: `byte`, `short` and `char` as `int`.
  func promoted(_ ty: Ty) -> Ty {
    guard case .nominal(let ref, _) = ty, enclosingNamespace(ref) == "System" else { return ty }
    let text = self.unit(ref).string(Int(decl(ref).nameToken))
    if ["Byte", "SByte", "Int16", "UInt16", "Char"].contains(text) { return keywordType("int") }
    return ty
  }

  private func binaryType(unitIndex: Int32, start: Int, end: Int, operators: [Int]) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var shift = false
    for k in operators {
      if unit.isToken(k, "==") || unit.isToken(k, "!=") || unit.isToken(k, "<") || unit.isToken(k, ">") || unit.isToken(k, "<=") || unit.isToken(k, ">=")
        || unit.isToken(k, "&&") || unit.isToken(k, "||")
      {
        return boolType()
      }
      if unit.isToken(k, "<<") || unit.isToken(k, ">>") || unit.isToken(k, ">>>") { shift = true }
      if unit.isToken(k, "..") { return systemType("Range").map { .nominal($0, []) } ?? .unknown }
    }
    var operands: [Ty] = []
    var from = start
    for k in operators + [end] {
      if k > from { operands.append(expressionType(unitIndex: unitIndex, start: Int32(from), end: Int32(k))) }
      from = k + 1
    }
    if shift { return operands.first.map(promoted) ?? .unknown }
    let hasPlus = operators.contains { unit.isToken($0, "+") }
    let string = stringType()
    if hasPlus, operands.contains(string) { return string }
    // Numeric promotion: the widest; `bool` stays (`&`, `|`, `^`); an enum's `|` and `&` stay the enum.
    var widest: Ty?
    var rank = -1
    for operand in operands {
      let plain = promoted(operand)
      guard case .nominal(let ref, _) = plain else { return .unknown }
      if decl(ref).kind == .enumeration {
        if operands.allSatisfy({ $0 == operand }) { return operand }
        return .unknown
      }
      guard enclosingNamespace(ref) == "System" else { return .unknown }
      let text = self.unit(ref).string(Int(decl(ref).nameToken))
      if text == "Boolean" { return plain }
      guard let order = CSharpWord.numericOrder.firstIndex(of: text) else { return .unknown }
      if order > rank {
        rank = order
        widest = plain
      }
    }
    return widest ?? .unknown
  }

  /// `x switch { p => a, … }`: the first arm's type that's known.
  private func switchType(unitIndex: Int32, brace: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let close = unit.skipBalanced(brace) - 1
    var k = brace + 1
    while k < close {
      if unit.isToken(k, "=>") {
        let end = CSharpParser(unit: unit).expressionEnd(k + 1, limit: close)
        let ty = expressionType(unitIndex: unitIndex, start: Int32(k + 1), end: Int32(end))
        if ty != .unknown, !isNull(unit, k + 1, end) { return ty }
        k = end + 1
        continue
      }
      k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
    }
    return .unknown
  }

  // MARK: Postfix chains

  /// An operand and what follows it: `.name`, `?.name`, `.name(args)`, `[i]`, `!`, `++`.
  func postfixType(unitIndex: Int32, start i: inout Int, end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard i < end else { return .unknown }
    var ty = operand(unitIndex: unitIndex, at: &i, end: end)
    while i < end {
      if unit.csIsDot(i) || unit.isToken(i, "->"), i + 1 < end {
        let conditional = unit.isToken(i, "?.")
        if conditional, let inner = nullableValue(ty) { ty = inner }
        if unit.isToken(i, "->"), case .constructed(let kind, let args) = ty, kind == Ty.pointer { ty = args.first ?? .unknown }
        let nameToken = i + 1
        guard unit.csIsName(nameToken) else { return .unknown }
        let word = unit.hash(nameToken)
        if let open = callOpen(unit, nameToken), open < end {
          let explicit = open > nameToken + 1 ? typeArguments(unitIndex: unitIndex, nameToken: nameToken, open: open) : []
          var receiver = ty
          if case .meta(let inner) = ty { receiver = inner }
          let close = unit.skipBalanced(open)
          if case .meta = ty {
            let methods = memberSites(of: receiver, named: word).filter { decl($0).kind == .function }
            ty = callResult(methods, receiver: receiver, receiverValue: nil, unitIndex: unitIndex, open: open, explicit: explicit)
          } else {
            let methods = memberSites(of: receiver, named: word).filter { decl($0).kind == .function }
            if !methods.isEmpty, !chooseOverload(methods, unitIndex: unitIndex, open: open, receiver: receiver, receiverValue: nil).isEmpty {
              ty = callResult(methods, receiver: receiver, receiverValue: nil, unitIndex: unitIndex, open: open, explicit: explicit)
            } else if receiver != .unknown {
              let extensions = extensionMethods(word, unitIndex: unitIndex, token: Int32(nameToken), receiver: receiver)
              if !extensions.isEmpty {
                ty = callResult(extensions, receiver: .unknown, receiverValue: receiver, unitIndex: unitIndex, open: open, explicit: explicit)
              } else if !methods.isEmpty {
                ty = callResult(methods, receiver: receiver, receiverValue: nil, unitIndex: unitIndex, open: open, explicit: explicit)
              } else {
                // A delegate-typed member called.
                let value = selectedType(receiver, word: word, text: unit.string(nameToken), unitIndex: unitIndex)
                ty = delegateSignature(value)?.result ?? .unknown
              }
            } else {
              ty = .unknown
            }
          }
          if conditional { ty = nullable(ty) }
          i = close
          continue
        }
        ty = selectedType(ty, word: word, text: unit.string(nameToken), unitIndex: unitIndex)
        if conditional { ty = nullable(ty) }
        i = nameToken + 1
        // `List<int>.Enumerator`: type arguments on a nested type's name.
        if unit.tokens.indices.contains(i), i < end, unit.tokens[i].kind == .punctuation, unit.startsWith(i, 0x3C), let after = unit.csTypeArgumentsEnd(i, limit: end), case .meta(let inner) = ty,
          case .nominal(let ref, _) = inner
        {
          ty = .meta(parseType(unitIndex: unitIndex, start: Int32(i - 1), end: Int32(after), scope: Int32(i - 1)) == .unknown ? .nominal(ref, []) : .nominal(ref, typeArguments(unitIndex: unitIndex, nameToken: i - 1, open: after)))
          i = after
        }
        continue
      }
      if unit.isByte(i, 0x5B) || unit.isByte(i, 0x3F) && unit.isByte(i + 1, 0x5B) {
        let open = unit.isByte(i, 0x5B) ? i : i + 1
        let close = unit.skipBalanced(open)
        ty = indexedType(ty, unitIndex: unitIndex, open: open)
        i = close
        continue
      }
      if unit.isByte(i, 0x21) || unit.isToken(i, "++") || unit.isToken(i, "--") {
        i += 1
        continue
      }
      if unit.isByte(i, 0x28) {
        // A delegate called: `handler(x)`, `Func()()`.
        let close = unit.skipBalanced(i)
        ty = delegateSignature(ty)?.result ?? .unknown
        i = close
        continue
      }
      break
    }
    if i < end { return .unknown }
    return ty
  }

  /// `x[i]`: an array's element, a string's char, an indexer's result.
  func indexedType(_ ty: Ty, unitIndex: Int32, open: Int) -> Ty {
    if case .constructed(let kind, let args) = ty, kind == Ty.array || kind == Ty.pointer {
      let unit = project.units[Int(unitIndex)]
      // `a[1..]`: a range gives an array.
      if kind == Ty.array, (open + 1..<unit.skipBalanced(open)).contains(where: { unit.isToken($0, "..") }) { return ty }
      return args.first ?? .unknown
    }
    let indexers = memberEntries(of: ty, named: CSharpWord.thisWord).filter { decl($0.0.ref).kind == .subscriptDecl }
    guard !indexers.isEmpty else { return .unknown }
    let chosen = chooseOverload(indexers.map(\.0.ref), unitIndex: unitIndex, open: open, receiver: ty, receiverValue: nil)
    var result: Ty?
    for ref in chosen {
      guard let entry = indexers.first(where: { $0.0.ref == ref }) else { continue }
      let found = memberValueType(entry.0)
      if let current = result, current != found { return .unknown }
      result = found
    }
    return result ?? .unknown
  }

  /// `x.name` (no call): a namespace's type or namespace, a type's nested type or static member, a value's member, a
  /// tuple's element.
  func selectedType(_ ty: Ty, word: Name, text: String, unitIndex: Int32) -> Ty {
    switch ty {
    case .module(let hashed):
      let namespace = namespaceNames[hashed] ?? ""
      if let ref = namespaceTypes(namespace, named: word, arity: 0, from: unitIndex).first ?? namespaceTypes(namespace, named: word, arity: nil, from: unitIndex).first {
        return .meta(.nominal(canonical(ref), []))
      }
      let sub = namespace + "." + text
      return isNamespace(sub) ? siteType(namespaceSite(sub), unitIndex: unitIndex) : .unknown
    case .meta(let inner):
      if let ref = memberTypeRefs(of: inner, named: word, arity: 0).first ?? memberTypeRefs(of: inner, named: word, arity: nil).first {
        // A nested type of a generic type sees the outer type's arguments.
        return .meta(.nominal(canonical(ref), []))
      }
      return fieldType(inner, word)
    case .tuple(let elements, let labels):
      if let at = labels.firstIndex(of: word), word != 0 { return elements[at] }
      if text.hasPrefix("Item"), let n = Int(text.dropFirst(4)), n >= 1, n <= elements.count { return elements[n - 1] }
      return fieldType(ty, word)
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
      if kind == .function { return .unknown }
    }
    return .unknown
  }

  /// `name<A, B>(`: the type arguments written.
  func typeArguments(unitIndex: Int32, nameToken: Int, open: Int) -> [Ty] {
    let unit = project.units[Int(unitIndex)]
    guard unit.tokens.indices.contains(nameToken + 1), unit.startsWith(nameToken + 1, 0x3C) else { return [] }
    var result: [Ty] = []
    var k = nameToken + 2
    let close = open - 1
    while k < close {
      var itemEnd = k
      while itemEnd < close, !unit.isByte(itemEnd, 0x2C) {
        if unit.tokens[itemEnd].kind == .punctuation, unit.startsWith(itemEnd, 0x3C), let after = unit.csTypeArgumentsEnd(itemEnd, limit: open) {
          itemEnd = after
          continue
        }
        itemEnd = unit.tokens[itemEnd].kind == .open ? unit.skipBalanced(itemEnd) : itemEnd + 1
      }
      result.append(parseType(unitIndex: unitIndex, start: Int32(k), end: Int32(min(itemEnd, close)), scope: Int32(nameToken)))
      k = itemEnd + 1
    }
    return result
  }

  /// What a call returns: the chosen overload's result, its type's parameters and its own (written or inferred) put in.
  /// The overloads must agree when several fit.
  func callResult(_ methods: [DeclRef], receiver: Ty, receiverValue: Ty?, unitIndex: Int32, open: Int, explicit: [Ty] = []) -> Ty {
    guard !methods.isEmpty else { return .unknown }
    var chosen = chooseOverload(methods, unitIndex: unitIndex, open: open, receiver: receiver, receiverValue: receiverValue)
    if chosen.isEmpty { chosen = methods }
    var result: Ty?
    for ref in chosen {
      let item = decl(ref)
      let map = receiverMap(receiver).merging(entryMap(ref, receiver)) { a, _ in a }
      var ty = substitute(valueType(of: ref), map)
      if item.genericCount > 0 {
        var bindings: [Name: Ty] = [:]
        let holder = self.unit(ref)
        if !explicit.isEmpty {
          for g in 0..<min(Int(item.genericCount), explicit.count) { bindings[holder.generics[Int(item.genericStart) + g].name] = explicit[g] }
        } else {
          bindings = inferBindings(ref, call: (chosen, receiver, receiverValue), unitIndex: unitIndex, open: open, skipping: -1)
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

  /// A method's own type parameters left unbound: unknown.
  func eraseOwn(_ ty: Ty, _ method: DeclRef) -> Ty {
    switch ty {
    case .param(_, let owner) where owner == method: return .unknown
    case .nominal(let ref, let args): return .nominal(ref, args.map { eraseOwn($0, method) })
    case .constructed(let kind, let args): return .constructed(kind, args.map { eraseOwn($0, method) })
    case .tuple(let elements, let labels): return .tuple(elements.map { eraseOwn($0, method) }, labels)
    default: return ty
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
      let isChar = unit.source.text[token.start] == 0x27
      i += 1
      // An interpolated string: its holes and the rest of it.
      while i < end, unit.tokens[i].kind == .interpolationOpen || unit.tokens[i].kind == .string && unit.touchesPrevious(i) {
        i = unit.tokens[i].kind == .interpolationOpen ? unit.skipBalanced(i) : i + 1
      }
      return isChar ? keywordType("char") : stringType()
    case .open:
      if unit.isByte(i, 0x5B) {
        // A collection expression: its type is the target's.
        i = unit.skipBalanced(i)
        return .unknown
      }
      guard unit.isByte(i, 0x28) else { return .unknown }
      let close = unit.skipBalanced(i)
      // A cast: `(Type) operand`.
      if let typeEnd = unit.csTypeEnd(i + 1, limit: close - 1), typeEnd == close - 1, close < end, startsOperand(unit, close, typeStart: i + 1) {
        let ty = parseType(unitIndex: unitIndex, start: Int32(i + 1), end: Int32(close - 1), scope: Int32(i))
        i = end
        return ty
      }
      // A tuple: `(a, b)`.
      let args = arguments(unit, open: i)
      if args.count > 1 {
        let elements = args.map { expressionType(unitIndex: unitIndex, start: Int32($0.start), end: Int32($0.end)) }
        i = close
        return .tuple(elements, args.map(\.label))
      }
      let inner = expressionType(unitIndex: unitIndex, start: Int32(i + 1), end: Int32(close - 1))
      i = close
      return inner
    case .keyword, .declarationKeyword:
      if unit.isToken(i, "new") { return creation(unitIndex: unitIndex, at: &i, end: end) }
      if unit.isToken(i, "this") {
        i += 1
        guard let own = enclosingTypes(unitIndex: unitIndex, token: Int32(i - 1)).first else { return .unknown }
        return ownType(own)
      }
      if unit.isToken(i, "base") {
        i += 1
        guard let own = enclosingTypes(unitIndex: unitIndex, token: Int32(i - 1)).first else { return .unknown }
        let parents = supertypes(of: own).map { substitute($0, parameterMap(own, [])) }
        return parents.first ?? .unknown
      }
      if unit.isToken(i, "true") || unit.isToken(i, "false") {
        i += 1
        return boolType()
      }
      if unit.isToken(i, "null") {
        i += 1
        return .unknown
      }
      if unit.isToken(i, "typeof") || unit.isToken(i, "nameof") || unit.isToken(i, "sizeof") || unit.isToken(i, "default") || unit.isToken(i, "checked") || unit.isToken(i, "unchecked") {
        let keyword = unit.string(i)
        i += 1
        guard unit.isByte(i, 0x28) else { return .unknown }
        let open = i
        i = unit.skipBalanced(open)
        switch keyword {
        case "typeof": return systemType("Type").map { .nominal($0, []) } ?? .unknown
        case "nameof": return stringType()
        case "sizeof": return keywordType("int")
        case "default": return parseType(unitIndex: unitIndex, start: Int32(open + 1), end: Int32(i - 1), scope: Int32(open))
        default: return expressionType(unitIndex: unitIndex, start: Int32(open + 1), end: Int32(i - 1))
        }
      }
      if unit.csIsPredefined(i) {
        // `int.Parse`, `string.Empty`: the type, for its static members.
        let ty = predefinedType(unit.hash(i))
        i += 1
        return ty == .unknown ? .unknown : .meta(ty)
      }
      if !unit.csIsName(i) { return .unknown }
      fallthrough
    case .identifier:
      let word = unit.hash(i)
      if let open = callOpen(unit, i), open < end {
        let close = unit.skipBalanced(open)
        let explicit = open > i + 1 ? typeArguments(unitIndex: unitIndex, nameToken: i, open: open) : []
        var ty: Ty
        switch simpleMethods(word, unitIndex: unitIndex, token: Int32(i)) {
        case .value(let sites):
          let value = sites.count == 1 ? siteType(sites[0], unitIndex: unitIndex) : .unknown
          ty = delegateSignature(value)?.result ?? .unknown
        case .methods(let methods, let receiver):
          ty = callResult(methods, receiver: receiver, receiverValue: nil, unitIndex: unitIndex, open: open, explicit: explicit)
        }
        i = close
        return ty
      }
      // `List<int>.Empty`, `Dictionary<K, V>.KeyCollection`: a generic type for its static members.
      if unit.tokens.indices.contains(i + 1), unit.tokens[i + 1].kind == .punctuation, unit.startsWith(i + 1, 0x3C), let after = unit.csTypeArgumentsEnd(i + 1, limit: end), unit.csIsDot(after) {
        let ty = parseType(unitIndex: unitIndex, start: Int32(i), end: Int32(after), scope: Int32(i))
        i = after
        return ty == .unknown ? .unknown : .meta(ty)
      }
      let found = answer(unitIndex: unitIndex, token: i)
      i += 1
      guard found.state == .exact, let site = found.sites.first else {
        if found.state == .candidates, !found.byNameOnly {
          let types = found.sites.map { siteType($0, unitIndex: unitIndex) }
          if let first = types.first, types.allSatisfy({ $0 == first }) { return first }
        }
        return .unknown
      }
      return siteType(site, unitIndex: unitIndex)
    default:
      return .unknown
    }
  }

  /// Whether a token can start the operand of a cast (`(T)x`, `(T)(x)`, `(T)!b`, `(int)-x`).
  private func startsOperand(_ unit: Unit, _ k: Int, typeStart: Int) -> Bool {
    guard k < unit.tokens.count else { return false }
    let token = unit.tokens[k]
    switch token.kind {
    case .identifier, .number, .string: return true
    case .open: return unit.isByte(k, 0x28)
    case .keyword, .declarationKeyword:
      return unit.isToken(k, "this") || unit.isToken(k, "base") || unit.isToken(k, "new") || unit.isToken(k, "true") || unit.isToken(k, "false")
        || unit.isToken(k, "null") || unit.isToken(k, "default") || unit.isToken(k, "typeof") || unit.isToken(k, "await") || unit.csIsName(k) || unit.csIsPredefined(k)
    case .punctuation:
      if unit.isByte(k, 0x21) || unit.isByte(k, 0x7E) { return true }
      return unit.csIsPredefined(typeStart) && (unit.isByte(k, 0x2D) || unit.isByte(k, 0x2B))
    default: return false
    }
  }

  func numberType(_ text: String) -> Ty {
    let lower = text.lowercased().replacingOccurrences(of: "_", with: "")
    let isHex = lower.hasPrefix("0x") || lower.hasPrefix("0b")
    if lower.hasSuffix("ul") || lower.hasSuffix("lu") { return keywordType("ulong") }
    if lower.hasSuffix("l") { return keywordType("long") }
    if lower.hasSuffix("u") { return keywordType("uint") }
    if lower.hasSuffix("m") { return keywordType("decimal") }
    if !isHex, lower.hasSuffix("f") { return keywordType("float") }
    if !isHex, lower.hasSuffix("d") { return keywordType("double") }
    if !isHex, lower.contains(".") || lower.contains("e") { return keywordType("double") }
    return keywordType("int")
  }

  /// `new T(…)`, `new T { … }`, `new T[n]`, `new T[] {…}`, `new[] {…}`, `new()` (the target's type), `new { … }`.
  private func creation(unitIndex: Int32, at i: inout Int, end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let newToken = i
    if unit.isByte(i + 1, 0x28) || unit.isByte(i + 1, 0x7B) && false {
      // Target-typed.
      i = unit.skipBalanced(i + 1)
      if i < end, unit.isByte(i, 0x7B) { i = unit.skipBalanced(i) }
      return targetType(unitIndex: unitIndex, start: newToken) ?? .unknown
    }
    if unit.isByte(i + 1, 0x7B) {
      // An anonymous type.
      i = unit.skipBalanced(i + 1)
      return .unknown
    }
    if unit.isByte(i + 1, 0x5B), unit.isByte(i + 2, 0x5D) {
      // `new[] { a, b }`: the elements' type.
      i += 3
      guard i < end, unit.isByte(i, 0x7B) else { return .unknown }
      let close = unit.skipBalanced(i)
      let elements = arguments(unit, open: i)
      i = close
      _ = elements
      let inner = unit.isByte(newToken + 3, 0x7B) ? firstElementType(unitIndex: unitIndex, brace: newToken + 3) : .unknown
      return inner == .unknown ? .unknown : .constructed(Ty.array, [inner])
    }
    guard let typeEnd = unit.csTypeEnd(i + 1, limit: end, nullable: false) else {
      i = end
      return .unknown
    }
    // `new int[n]`: the dimensions are an index, not part of the type.
    var nameEnd = typeEnd
    var k = i + 1
    while k < typeEnd {
      if unit.isByte(k, 0x5B), !(unit.isByte(k + 1, 0x5D) || unit.isByte(k + 1, 0x2C)) {
        nameEnd = k
        break
      }
      k = unit.tokens[k].kind == .open && !unit.isByte(k, 0x5B) ? unit.skipBalanced(k) : k + 1
    }
    var ty = parseType(unitIndex: unitIndex, start: Int32(i + 1), end: Int32(nameEnd), scope: Int32(i))
    i = nameEnd
    if unit.isByte(i, 0x5B) {
      while i < end, unit.isByte(i, 0x5B) {
        ty = .constructed(Ty.array, [ty])
        i = unit.skipBalanced(i)
      }
      if i < end, unit.isByte(i, 0x7B) { i = unit.skipBalanced(i) }
      return ty
    }
    if i < end, unit.isByte(i, 0x28) { i = unit.skipBalanced(i) }
    if i < end, unit.isByte(i, 0x7B) { i = unit.skipBalanced(i) }
    return ty
  }

  private func firstElementType(unitIndex: Int32, brace: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let close = unit.skipBalanced(brace) - 1
    guard brace + 1 < close else { return .unknown }
    let end = CSharpParser(unit: unit).expressionEnd(brace + 1, limit: close)
    return expressionType(unitIndex: unitIndex, start: Int32(brace + 1), end: Int32(end))
  }

  // MARK: Operands left of a dot

  /// The type of the operand left of a `.`, `?.` or `!.`: the expression that ends there.
  func operandType(unitIndex: Int32, dot: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let start = expressionStart(unit, before: dot)
    guard start < dot else { return .unknown }
    var i = start
    return postfixType(unitIndex: unitIndex, start: &i, end: dot)
  }

  /// Walking back from just before `end`: names, dots, calls, indexes, `new T(…)`, as far as one operand goes.
  func expressionStart(_ unit: Unit, before end: Int) -> Int {
    var i = end - 1
    while i >= 0 {
      let token = unit.tokens[i]
      if token.kind == .close || token.kind == .interpolationClose {
        guard let open = unit.matchingOpen(i) else { return i + 1 }
        i = open
        if unit.isByte(open, 0x7B) {
          // An initializer: back to its `new`.
          var k = open - 1
          if k >= 0, unit.tokens[k].kind == .close, let o = unit.matchingOpen(k) { k = o - 1 }
          while k >= 0, unit.csIsName(k) || unit.csIsDot(k) || unit.csIsPredefined(k) || unit.tokens[k].kind == .punctuation && unit.punctuation(k, madeOf: "<>?,") || unit.isByte(k, 0x5B) || unit.isByte(k, 0x5D) {
            k -= 1
          }
          if k >= 0, unit.isToken(k, "new") { return k }
          return open + 1
        }
        if i > 0, unit.csIsName(i - 1) || unit.csIsPredefined(i - 1) || unit.tokens[i - 1].kind == .close || unit.isToken(i - 1, "this") || unit.isToken(i - 1, "base") || unit.isByte(i - 1, 0x21) || unit.isByte(i - 1, 0x3F) && unit.isByte(open, 0x5B) {
          if unit.isByte(i - 1, 0x3F) || unit.isByte(i - 1, 0x21) {
            i -= 1
            continue
          }
          i -= 1
          if unit.tokens[i].kind == .close { continue }
          if let start = newStart(unit, i) { return start }
          if unit.isToken(i, "typeof") || unit.isToken(i, "nameof") || unit.isToken(i, "default") || unit.isToken(i, "sizeof") || unit.isToken(i, "checked") { return i }
          if i > 0, unit.csIsDot(i - 1) {
            i -= 2
            continue
          }
          return i
        }
        if i > 0, unit.tokens[i - 1].kind == .punctuation, unit.punctuation(i - 1, madeOf: ">"), let lt = typeArgumentsOpen(unit, i - 1), lt > 0, unit.csIsName(lt - 1) {
          // `Foo<Bar>(…)`, `new Foo<Bar>(…)`.
          if let start = newStart(unit, lt - 1) { return start }
          i = lt - 1
          if i > 0, unit.csIsDot(i - 1) {
            i -= 2
            continue
          }
          return i
        }
        if unit.isByte(open, 0x5B), i > 0, unit.isToken(i - 1, "new") { return i - 1 }
        return i
      }
      if unit.isByte(i, 0x21), i > 0, unit.tokens[i - 1].kind == .identifier || unit.tokens[i - 1].kind == .close {
        // `x!`: null-forgiving.
        i -= 1
        continue
      }
      if unit.csIsName(i) || token.kind == .number || token.kind == .string || unit.isToken(i, "this") || unit.isToken(i, "base") || unit.csIsPredefined(i) {
        if token.kind == .string {
          // Back over an interpolated string's parts.
          while i > 0, unit.tokens[i - 1].kind == .interpolationClose || unit.tokens[i - 1].kind == .string && unit.touchesPrevious(i) {
            if unit.tokens[i - 1].kind == .interpolationClose, let o = unit.matchingOpen(i - 1) { i = o } else { i -= 1 }
          }
        }
        if unit.isToken(i - 1, "::") { i -= 1 }
        if i > 0, unit.csIsDot(i - 1) {
          i -= 2
          continue
        }
        return i
      }
      if token.kind == .punctuation, unit.punctuation(i, madeOf: ">"), let lt = typeArgumentsOpen(unit, i), lt > 0, unit.csIsName(lt - 1) {
        // `List<int>.Empty`.
        i = lt - 1
        continue
      }
      return i + 1
    }
    return 0
  }

  /// The `<` of type arguments whose last `>` is in the token at `close`.
  private func typeArgumentsOpen(_ unit: Unit, _ close: Int) -> Int? {
    var depth = 0
    var k = close
    var budget = 60
    while k >= 0, budget > 0 {
      budget -= 1
      if unit.tokens[k].kind == .punctuation {
        for b in (0..<unit.tokens[k].length).reversed() {
          let byte = unit.source.text[unit.tokens[k].start + b]
          if byte == 0x3E { depth += 1 } else if byte == 0x3C { depth -= 1 }
        }
        if depth == 0 { return unit.csTypeArgumentsEnd(k).map { $0 == close + 1 ? k : -1 }.flatMap { $0 >= 0 ? $0 : nil } }
      } else if unit.tokens[k].kind == .open || unit.isByte(k, 0x3B) {
        return nil
      }
      k -= 1
    }
    return nil
  }

  /// When the name at `i` is `new`'s type: where the creation starts.
  private func newStart(_ unit: Unit, _ i: Int) -> Int? {
    var k = i
    while k > 1, unit.isByte(k - 1, 0x2E), unit.csIsName(k - 2) { k -= 2 }
    guard k > 0, unit.isToken(k - 1, "new") else { return nil }
    return k - 1
  }
}
