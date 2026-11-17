import CodeModel
import CodeScan
import Foundation

/// One argument of a call: its tokens (or a type known already, for an operator's), its name when written
/// `name = value`, and its `{` when it's a lambda.
struct KArg {
  var start: Int
  var end: Int
  var name: Name = 0
  var brace = -1
  var known: Ty?
  /// A lambda written after the parentheses, which goes to the last parameter.
  var trailing = false
}

/// What a lambda is given to: its receiver (`T.() -> R`), its parameters and its result.
struct KLambdaTarget {
  var receiver: Ty?
  var params: [Ty]
  var result: Ty
}

/// Expressions' static types: literals, names (smart casts applied), `this`/`super`, calls and constructors
/// (overloads chosen, generics inferred from the receiver, the arguments and lambdas' results), member and extension
/// selections, operators through their functions (`+` is `plus`, `a..b` is `rangeTo`, `x[i]` is `get`), infix calls,
/// `as`, `?:`, `if` and `when` as expressions.
extension KotlinModel {
  func kotlinNominal(_ word: String, _ package: String = "kotlin") -> Ty { kotlinType(package, word).map { .nominal($0, []) } ?? .unknown }

  /// The type of an expression's tokens.
  func expressionType(unitIndex: Int32, start: Int32, end: Int32) -> Ty {
    guard start >= 0, start < end else { return .unknown }
    depth += 1
    defer { depth -= 1 }
    guard depth < 48 else { return .unknown }
    let unit = project.units[Int(unitIndex)]
    let s = Int(start)
    let limit = min(Int(end), unit.tokens.count)
    guard s < limit else { return .unknown }
    // Operators at the top level, by how loosely they bind.
    var boolean = false
    var elvis = -1
    var infix = -1
    var range = -1
    var additive = -1
    var multiplicative = -1
    var cast = -1
    var k = s
    while k < limit {
      let token = unit.tokens[k]
      if token.kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if k > s, token.kind == .punctuation {
        if isAssignment(unit, k) { return expressionType(unitIndex: unitIndex, start: start, end: Int32(k)) }
        if unit.ktStartsWith(k, 0x3C), let after = unit.ktTypeArgumentsEnd(k, limit: limit), unit.isByte(after, 0x28) || unit.isByte(after, 0x7B) || unit.isToken(after, "::") || unit.isByte(after, 0x2E) {
          k = after
          continue
        }
        if unit.isToken(k, "||") || unit.isToken(k, "&&") || unit.isToken(k, "==") || unit.isToken(k, "!=") || unit.isToken(k, "===") || unit.isToken(k, "!==")
          || unit.isToken(k, "<") || unit.isToken(k, ">") || unit.isToken(k, "<=") || unit.isToken(k, ">=")
        {
          boolean = true
        } else if unit.ktIsElvis(k) {
          if elvis < 0 { elvis = k }
          k += 2
          continue
        } else if unit.isToken(k, "..") || unit.isToken(k, "..<") {
          if range < 0 { range = k }
        } else if (unit.isToken(k, "+") || unit.isToken(k, "-")) && endsOperand(unit, k - 1) {
          additive = k
        } else if (unit.isToken(k, "*") || unit.isToken(k, "/") || unit.isToken(k, "%")) && endsOperand(unit, k - 1) {
          multiplicative = k
        }
      } else if k > s, token.kind == .keyword || token.kind == .declarationKeyword {
        // `!is` and `!in` are `!` and the word; `as?` is `as` and `?`.
        if unit.isToken(k, "is") || unit.isToken(k, "in") { boolean = true }
        if unit.isToken(k, "as") { cast = k }
        // The type after `as`, `as?`, `is` or `!is`, whose `<` and `>` aren't comparisons.
        let typeStart = ktTypeAfter(unit, k)
        if unit.isToken(k, "as") || unit.isToken(k, "is"), let typeEnd = unit.ktTypeEnd(typeStart, limit: limit), typeEnd > typeStart {
          k = typeEnd
          continue
        }
        if unit.isToken(k, "if") || unit.isToken(k, "when") || unit.isToken(k, "try") {
          // An expression starting later (`x = if …`) was handled; inside one, stop here.
          break
        }
      } else if k > s, token.kind == .identifier, isInfixName(unit, k) {
        infix = k
      }
      k += 1
    }
    if boolean { return kotlinNominal("Boolean") }
    if elvis >= 0 {
      let left = expressionType(unitIndex: unitIndex, start: start, end: Int32(elvis))
      return left == .unknown ? expressionType(unitIndex: unitIndex, start: Int32(elvis + 2), end: end) : left
    }
    if infix >= 0 {
      let receiver = expressionType(unitIndex: unitIndex, start: start, end: Int32(infix))
      let argument = KArg(start: infix + 1, end: limit)
      let found = callees(of: receiver, named: unit.hash(infix), unitIndex: unitIndex, token: Int32(infix)).filter { decl($0.ref).paramCount == 1 }
      return callResult(found, unitIndex: unitIndex, args: [argument])
    }
    if range >= 0 {
      let receiver = expressionType(unitIndex: unitIndex, start: start, end: Int32(range))
      let other = expressionType(unitIndex: unitIndex, start: Int32(range + 1), end: end)
      return operatorResult(receiver, unit.isToken(range, "..") ? KotlinWord.rangeTo : KotlinWord.rangeUntil, [other], unitIndex: unitIndex)
    }
    if additive >= 0 || multiplicative >= 0 {
      let op = additive >= 0 ? additive : multiplicative
      let receiver = expressionType(unitIndex: unitIndex, start: start, end: Int32(op))
      let other = expressionType(unitIndex: unitIndex, start: Int32(op + 1), end: end)
      let word: Name
      if unit.isToken(op, "+") { word = KotlinWord.plus } else if unit.isToken(op, "-") { word = KotlinWord.minus } else if unit.isToken(op, "*") { word = KotlinWord.times } else if unit.isToken(op, "/") { word = KotlinWord.div } else { word = KotlinWord.rem }
      return operatorResult(receiver, word, [other], unitIndex: unitIndex)
    }
    if cast >= 0 {
      let typeStart = ktTypeAfter(unit, cast)
      let typeEnd = unit.ktTypeEnd(typeStart, limit: limit) ?? limit
      return parseType(unitIndex: unitIndex, start: Int32(typeStart), end: Int32(typeEnd), scope: Int32(cast))
    }
    // Prefix operators.
    if unit.tokens[s].kind == .punctuation {
      if unit.ktStartsWith(s, 0x21), !unit.isToken(s, "!!") { return kotlinNominal("Boolean") }
      if unit.isToken(s, "-") || unit.isToken(s, "+") || unit.isToken(s, "++") || unit.isToken(s, "--") {
        return expressionType(unitIndex: unitIndex, start: start + 1, end: end)
      }
      if unit.isToken(s, "::") { return .unknown }
      return .unknown
    }
    var i = s
    let ty = postfixType(unitIndex: unitIndex, start: &i, end: limit)
    return i < limit ? .unknown : ty
  }

  /// Where the type after `as`, `as?` or `is` starts.
  func ktTypeAfter(_ unit: Unit, _ k: Int) -> Int {
    unit.isToken(k, "as") && unit.isToken(k + 1, "?") && unit.touchesPrevious(k + 1) ? k + 2 : k + 1
  }

  private func isAssignment(_ unit: Unit, _ k: Int) -> Bool {
    unit.isToken(k, "=") || unit.isToken(k, "+=") || unit.isToken(k, "-=") || unit.isToken(k, "*=") || unit.isToken(k, "/=") || unit.isToken(k, "%=")
  }

  /// Whether a token ends an operand (so that `-` after it is binary).
  func endsOperand(_ unit: Unit, _ k: Int) -> Bool {
    guard k >= 0 else { return false }
    let kind = unit.tokens[k].kind
    if kind == .identifier || kind == .number || kind == .string || kind == .close { return true }
    return unit.isToken(k, "this") || unit.isToken(k, "null") || unit.isToken(k, "true") || unit.isToken(k, "false") || unit.isToken(k, "!!") || unit.ktIsName(k)
      || unit.tokens[k].kind == .punctuation && unit.ktOnly(k, ">?") && unit.isByte(k + 1, 0x28) == false && false
  }

  // MARK: Postfix chains

  /// An operand and what follows it: `.name`, `?.name`, `.name(args) { lambda }`, `!!`, `[i]`, `(args)` on a value.
  func postfixType(unitIndex: Int32, start i: inout Int, end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard i < end else { return .unknown }
    var ty = operand(unitIndex: unitIndex, at: &i, end: end)
    while i < end {
      if unit.ktIsDot(i), i + 1 < end {
        let nameToken = i + 1
        if unit.isToken(nameToken, "class") || unit.isToken(nameToken, "this") {
          ty = .unknown
          i = nameToken + 1
          continue
        }
        guard unit.ktIsName(nameToken) else { return .unknown }
        let word = unit.hash(nameToken)
        names[word] = unit.string(nameToken)
        if let open = callOpen(unit, nameToken), open < end {
          var receiver = ty
          if case .meta(let inner) = ty { receiver = inner }
          var found: [Callee]
          switch ty {
          case .module(let package):
            found = constructorsAndFunctions(packageDecls(packageNames[package] ?? "", named: word))
          case .meta:
            let nested = memberTypeRefs(of: receiver, named: word)
            found = nested.isEmpty ? staticCallees(of: receiver, named: word, wantsCall: true) : constructorsAndFunctions(nested)
          default:
            found = callees(of: receiver, named: word, unitIndex: unitIndex, token: Int32(nameToken))
          }
          if found.isEmpty, word == KotlinWord.copy, case .nominal(let ref, _) = memberBase(receiver), isDataClass(ref) {
            // A data class's generated `copy(…)`.
            ty = receiver
          } else if found.isEmpty {
            // A property holding a function.
            let property = selectedType(ty, word: word, unitIndex: unitIndex)
            ty = invocationResult(property)
          } else {
            ty = callResult(chooseOverload(found, unitIndex: unitIndex, nameToken: nameToken), unitIndex: unitIndex, args: callArguments(unit, nameToken: nameToken), nameToken: nameToken)
          }
          i = callEnd(unit, nameToken: nameToken)
          continue
        }
        ty = selectedType(ty, word: word, unitIndex: unitIndex)
        i = nameToken + 1
        continue
      }
      if unit.isToken(i, "!!") || unit.isToken(i, "++") || unit.isToken(i, "--") {
        i += 1
        continue
      }
      if unit.isByte(i, 0x5B) {
        let close = unit.skipBalanced(i)
        let index = expressionType(unitIndex: unitIndex, start: Int32(i + 1), end: Int32(close - 1))
        ty = operatorResult(ty, KotlinWord.get, [index], unitIndex: unitIndex)
        i = close
        continue
      }
      if unit.isByte(i, 0x28), !unit.startsLine(i) {
        // A value called: a function type's result, or its `invoke`.
        ty = invocationResult(ty)
        i = unit.skipBalanced(i)
        if i < end, unit.isByte(i, 0x7B), !unit.startsLine(i) { i = unit.skipBalanced(i) }
        continue
      }
      if unit.isToken(i, "::") {
        // `T::class`, `x::class`: a `KClass`.
        if unit.isToken(i + 1, "class"), let kclass = kotlinType("kotlin.reflect", "KClass") {
          var inner = ty
          if case .meta(let type) = ty { inner = type }
          ty = .nominal(kclass, [inner])
          i += 2
          continue
        }
        i = end
        return .unknown
      }
      break
    }
    return ty
  }

  /// What calling a value gives: a function type's result, else its `invoke`'s.
  func invocationResult(_ ty: Ty) -> Ty {
    switch ty {
    case .function(_, let result): return result
    case .constructed(let kind, let args) where kind == KotlinTy.receiverFunction:
      if args.count == 2, case .function(_, let result) = args[1] { return result }
      return .unknown
    default:
      return .unknown
    }
  }

  /// Where a call's tokens end: past its arguments and a trailing lambda.
  func callEnd(_ unit: Unit, nameToken: Int) -> Int {
    guard var k = callOpen(unit, nameToken) else { return nameToken + 1 }
    if unit.isByte(k, 0x28) {
      k = unit.skipBalanced(k)
      if unit.isByte(k, 0x7B), !unit.startsLine(k), isTrailingLambda(unit, k) { k = unit.skipBalanced(k) }
      return k
    }
    return unit.skipBalanced(k)
  }

  /// `x.name` (no call): a package's declaration or subpackage, a class's nested class, companion property, enum entry
  /// or Java static, a value's property (a Java getter, an extension property).
  func selectedType(_ ty: Ty, word: Name, unitIndex: Int32) -> Ty {
    switch ty {
    case .module(let package):
      let packageName = packageNames[package] ?? ""
      if let ref = packageDecls(packageName, named: word).first { return valueType(of: ref) }
      guard let text = names[word] else { return .unknown }
      let sub = packageName + "." + text
      return isPackage(sub) ? siteType(packageSite(sub), unitIndex: unitIndex) : .unknown
    case .meta(let inner):
      if let ref = memberTypeRefs(of: inner, named: word).first { return valueType(of: ref) }
      if let first = staticCallees(of: inner, named: word, wantsCall: false).first { return substitute(valueType(of: first.ref), first.map) }
      return .unknown
    case .unknown:
      return .unknown
    default:
      for (entry, _) in memberEntries(of: ty, named: word) where isProperty(decl(entry.ref)) { return substitute(valueType(of: entry.ref), entry.substitution) }
      if let getter = syntheticGetter(of: ty, named: word) {
        for (entry, _) in memberEntries(of: ty, named: decl(getter).name) where entry.ref == getter { return substitute(valueType(of: getter), entry.substitution) }
        return valueType(of: getter)
      }
      if let first = extensionCandidates(receiver: ty, named: word, unitIndex: unitIndex, wantsCall: false).first {
        return eraseOwn(substitute(valueType(of: first.ref), first.map), first.ref)
      }
      return .unknown
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
      if unit.source.text[token.start] == 0x27 { return kotlinNominal("Char") }
      // A template's parts: `${…}` and the string after it.
      while i < end, unit.tokens[i].kind == .interpolationOpen {
        var depth = 0
        while i < end {
          if unit.tokens[i].kind == .interpolationOpen { depth += 1 }
          if unit.tokens[i].kind == .interpolationClose {
            depth -= 1
            if depth == 0 { break }
          }
          i += 1
        }
        i += 1
        if i < end, unit.tokens[i].kind == .string { i += 1 }
      }
      return unit.source.text[token.start] == 0x27 ? kotlinNominal("Char") : kotlinNominal("String")
    case .open:
      if unit.isByte(i, 0x28) {
        let close = unit.skipBalanced(i)
        let inner = expressionType(unitIndex: unitIndex, start: Int32(i + 1), end: Int32(close - 1))
        i = close
        return inner
      }
      i = unit.skipBalanced(i)
      return .unknown
    case .keyword, .declarationKeyword:
      if unit.isToken(i, "this") {
        let at = i
        i += 1
        if i < end, unit.tokens[i].kind == .attribute, unit.touchesPrevious(i) {
          let label = hashName(unit.source.text + unit.tokens[i].start + 1, unit.tokens[i].length - 1)
          i += 1
          return labeledThis(label, unitIndex: unitIndex, token: Int32(at))
        }
        return implicitReceivers(unitIndex: unitIndex, token: Int32(at)).first ?? .unknown
      }
      if unit.isToken(i, "super") {
        let at = i
        i += 1
        if i < end, unit.tokens[i].kind == .punctuation, unit.ktStartsWith(i, 0x3C), let after = unit.ktTypeArgumentsEnd(i, limit: end) {
          let ty = parseType(unitIndex: unitIndex, start: Int32(i + 1), end: Int32(after - 1), scope: Int32(at))
          i = after
          return ty
        }
        guard let own = enclosingClasses(unitIndex: unitIndex, token: Int32(at)).first else { return .unknown }
        let parents = supertypes(of: own)
        return parents.first(where: { if case .nominal(let ref, _) = $0 { return decl(ref).kind != .protocolType } else { return false } }) ?? parents.first ?? .unknown
      }
      if unit.isToken(i, "true") || unit.isToken(i, "false") {
        i += 1
        return kotlinNominal("Boolean")
      }
      if unit.isToken(i, "null") {
        i += 1
        return .unknown
      }
      if unit.isToken(i, "if") { return conditionalType(unitIndex: unitIndex, at: &i, end: end) }
      if unit.isToken(i, "when") { return whenType(unitIndex: unitIndex, at: &i, end: end) }
      if unit.isToken(i, "try") {
        i += 1
        guard unit.isByte(i, 0x7B) else { return .unknown }
        let close = unit.skipBalanced(i)
        let ty = blockValueType(unitIndex: unitIndex, open: i, close: close - 1)
        i = end
        return ty
      }
      if unit.isToken(i, "object") {
        // An anonymous object: its declaration.
        let at = i
        i = end
        for (index, item) in unit.decls.enumerated() where item.first == Int32(at) && item.kind == .classType && item.name == 0 {
          return .nominal(DeclRef(unit: unitIndex, decl: Int32(index)), [])
        }
        return .unknown
      }
      if !unit.ktIsName(i) {
        i = end
        return .unknown
      }
      fallthrough
    case .identifier:
      let word = unit.hash(i)
      names[word] = unit.string(i)
      if let open = callOpen(unit, i), open < end || open == end && false {
        let found = simpleCallees(word, unitIndex: unitIndex, token: Int32(i))
        let nameToken = i
        i = callEnd(unit, nameToken: nameToken)
        if found.isEmpty {
          // A local or property of a function type, called.
          let sites = valueSites(word, unitIndex: unitIndex, token: Int32(nameToken))
          guard let site = sites.first else { return .unknown }
          return invocationResult(siteType(site, unitIndex: unitIndex))
        }
        return callResult(chooseOverload(found, unitIndex: unitIndex, nameToken: nameToken), unitIndex: unitIndex, args: callArguments(unit, nameToken: nameToken), nameToken: nameToken)
      }
      let nameToken = i
      i += 1
      // `List<String>::class`, `Foo<T>.Bar`: a type with arguments.
      if i < end, unit.tokens[i].kind == .punctuation, unit.ktStartsWith(i, 0x3C), let after = unit.ktTypeArgumentsEnd(i, limit: end), unit.isToken(after, "::") {
        i = after
        return .unknown
      }
      let found = answer(unitIndex: unitIndex, token: nameToken)
      guard found.state == .exact, let site = found.sites.first else {
        if found.state == .candidates, !found.byNameOnly {
          let types = found.sites.map { siteType($0, unitIndex: unitIndex) }
          if let first = types.first, types.allSatisfy({ $0 == first }) { return first }
        }
        return .unknown
      }
      if let cast = smartCast(word, unitIndex: unitIndex, token: Int32(nameToken), site: site) { return cast }
      return siteType(site, unitIndex: unitIndex)
    case .attribute:
      i += 1
      return .unknown
    default:
      i = end
      return .unknown
    }
  }

  /// A name's type where an `is` check holds: a local's, a parameter's, a `val` property's.
  func smartCast(_ word: Name, unitIndex: Int32, token: Int32, site: Site) -> Ty? {
    guard let body = body(unitIndex: unitIndex, token: token), let cast = body.cast(of: word, at: token) else { return nil }
    if case .decl(let ref) = site, !isProperty(decl(ref)) { return nil }
    if case .module = site { return nil }
    let ty = parseType(unitIndex: unitIndex, start: cast.typeStart, end: cast.typeEnd, scope: cast.typeStart)
    return ty == .unknown ? nil : ty
  }

  /// `this@Label`: the class named so, or the lambda passed to the function named so.
  func labeledThis(_ label: Name, unitIndex: Int32, token: Int32) -> Ty {
    for owner in enclosingClasses(unitIndex: unitIndex, token: token) where decl(owner).name == label { return ownType(owner) }
    let unit = project.units[Int(unitIndex)]
    if let body = body(unitIndex: unitIndex, token: token) {
      for brace in body.lambdasAround(token) {
        var head = Int(brace) - 1
        if unit.isByte(head, 0x29), let open = unit.matchingOpen(head) { head = open - 1 }
        if unit.ktIsName(head), unit.hash(head) == label, let target = lambdaTarget(unitIndex: unitIndex, brace: Int(brace)), let receiver = target.receiver { return receiver }
      }
    }
    // An extension function's receiver, by the function's name.
    for index in unit.chain(at: token).reversed() where unit.decls[Int(index)].kind == .function && unit.decls[Int(index)].name == label {
      let parent = unit.decls[Int(index)].parent
      if parent >= 0, unit.decls[Int(parent)].kind == .extensionDecl { return extensionReceiverType(DeclRef(unit: unitIndex, decl: parent)) }
    }
    return .unknown
  }

  func numberType(_ text: String) -> Ty {
    let lower = text.lowercased()
    let isHex = lower.hasPrefix("0x") || lower.hasPrefix("0b")
    if lower.hasSuffix("ul") || lower.hasSuffix("u") { return kotlinNominal(lower.hasSuffix("l") ? "ULong" : "UInt") }
    if lower.hasSuffix("l") { return kotlinNominal("Long") }
    if !isHex, lower.hasSuffix("f") { return kotlinNominal("Float") }
    if !isHex, lower.contains(".") || lower.contains("e") { return kotlinNominal("Double") }
    // A literal too big for an Int is a Long: `0xFF6750A4`.
    let digits = lower.replacingOccurrences(of: "_", with: "")
    let value = lower.hasPrefix("0x") ? UInt64(digits.dropFirst(2), radix: 16) : lower.hasPrefix("0b") ? UInt64(digits.dropFirst(2), radix: 2) : UInt64(digits)
    if value.map({ $0 > UInt64(Int32.max) }) ?? !digits.isEmpty { return kotlinNominal("Long") }
    return kotlinNominal("Int")
  }

  /// `if (c) a else b` as an expression: a's type, else b's.
  private func conditionalType(unitIndex: Int32, at i: inout Int, end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    defer { i = end }
    guard unit.isByte(i + 1, 0x28) else { return .unknown }
    let thenStart = unit.skipBalanced(i + 1)
    var thenEnd: Int
    var ty: Ty
    if unit.isByte(thenStart, 0x7B) {
      thenEnd = unit.skipBalanced(thenStart)
      ty = blockValueType(unitIndex: unitIndex, open: thenStart, close: thenEnd - 1)
    } else {
      thenEnd = thenStart
      while thenEnd < end, !unit.isToken(thenEnd, "else") { thenEnd = unit.tokens[thenEnd].kind == .open ? unit.skipBalanced(thenEnd) : thenEnd + 1 }
      ty = expressionType(unitIndex: unitIndex, start: Int32(thenStart), end: Int32(thenEnd))
    }
    if ty != .unknown, ty != kotlinNominal("Nothing") { return ty }
    guard unit.isToken(thenEnd, "else") else { return .unknown }
    let elseStart = thenEnd + 1
    if unit.isByte(elseStart, 0x7B) { return blockValueType(unitIndex: unitIndex, open: elseStart, close: unit.skipBalanced(elseStart) - 1) }
    return expressionType(unitIndex: unitIndex, start: Int32(elseStart), end: Int32(end))
  }

  /// `when … { c -> a … }`: the first branch's type that's known.
  private func whenType(unitIndex: Int32, at i: inout Int, end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    defer { i = end }
    var open = i + 1
    if unit.isByte(open, 0x28) { open = unit.skipBalanced(open) }
    guard unit.isByte(open, 0x7B) else { return .unknown }
    let close = unit.skipBalanced(open) - 1
    var k = open + 1
    var tries = 0
    while k < close, tries < 4 {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if unit.isToken(k, "->") {
        tries += 1
        let start = k + 1
        var value: Ty
        var next: Int
        if unit.isByte(start, 0x7B) {
          next = unit.skipBalanced(start)
          value = blockValueType(unitIndex: unitIndex, open: start, close: next - 1)
        } else {
          next = start
          while next < close, next == start || !unit.startsLine(next) { next = unit.tokens[next].kind == .open ? unit.skipBalanced(next) : next + 1 }
          value = expressionType(unitIndex: unitIndex, start: Int32(start), end: Int32(next))
        }
        if value != .unknown, value != kotlinNominal("Nothing") { return value }
        k = next
        continue
      }
      k += 1
    }
    return .unknown
  }

  /// A block's value: its last statement's, when that's an expression.
  func blockValueType(unitIndex: Int32, open: Int, close: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard let start = lastStatement(unit, from: open + 1, to: close) else { return .unknown }
    if unit.isToken(start, "val") || unit.isToken(start, "var") || unit.isToken(start, "fun") || unit.isToken(start, "return") || unit.isToken(start, "throw") || unit.isToken(start, "class") {
      return .unknown
    }
    return expressionType(unitIndex: unitIndex, start: Int32(start), end: Int32(close))
  }

  /// Where a block's last statement starts.
  func lastStatement(_ unit: Unit, from: Int, to: Int) -> Int? {
    var last: Int?
    var k = from
    var continuing = false
    while k < to {
      if k == from || unit.isByte(k - 1, 0x3B) || unit.startsLine(k) && !continuing && !isContinuation(unit, k) {
        last = k
      }
      continuing = false
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continuing = false
        continue
      }
      // A line ending in an operator continues on the next.
      if unit.tokens[k].kind == .punctuation, !unit.isByte(k, 0x3B), !unit.isToken(k, "!!") { continuing = true }
      k += 1
    }
    return last
  }

  /// A line that continues the one before: `.call()`, `?.x`, `?:`, an operator.
  private func isContinuation(_ unit: Unit, _ k: Int) -> Bool {
    unit.ktIsDot(k) || unit.ktIsElvis(k) || unit.isToken(k, "&&") || unit.isToken(k, "||") || unit.isToken(k, "else") || unit.isToken(k, "catch") || unit.isToken(k, "finally")
  }

  // MARK: Calls

  /// A call's arguments: inside its parentheses (named ones by name), then a trailing lambda.
  func callArguments(_ unit: Unit, nameToken: Int) -> [KArg] {
    guard let open = callOpen(unit, nameToken) else { return [] }
    var result: [KArg] = []
    var k = open
    if unit.isByte(open, 0x28) {
      let close = unit.skipBalanced(open) - 1
      var i = open + 1
      while i < close {
        var end = i
        while end < close, !unit.isByte(end, 0x2C) {
          if unit.tokens[end].kind == .open {
            end = unit.skipBalanced(end)
            continue
          }
          if unit.tokens[end].kind == .punctuation, unit.ktStartsWith(end, 0x3C), let after = unit.ktTypeArgumentsEnd(end, limit: close),
            unit.isByte(after, 0x28) || unit.isByte(after, 0x7B) || unit.isToken(after, "::") || unit.isByte(after, 0x2E)
          {
            end = after
            continue
          }
          end += 1
        }
        var arg = KArg(start: i, end: end)
        if unit.ktIsName(i), unit.isToken(i + 1, "="), i + 2 <= end {
          arg.name = unit.hash(i)
          arg.start = i + 2
        }
        if unit.isByte(arg.start, 0x7B), unit.skipBalanced(arg.start) == end { arg.brace = arg.start }
        // `*array`: spread.
        if unit.isToken(arg.start, "*") { arg.start += 1 }
        if arg.start < end { result.append(arg) }
        i = end + 1
      }
      k = close + 1
      guard unit.isByte(k, 0x7B), !unit.startsLine(k), isTrailingLambda(unit, k) else { return result }
    }
    let end = unit.skipBalanced(k)
    result.append(KArg(start: k, end: end, name: 0, brace: k, known: nil, trailing: true))
    return result
  }

  /// Which parameter each argument goes to, if a callee can take them all.
  func assignment(_ callee: Callee, _ args: [KArg]) -> [Int]? {
    let params = parameters(of: callee.ref)
    var used = Array(repeating: false, count: params.count)
    var result: [Int] = []
    var position = 0
    for (index, arg) in args.enumerated() {
      var target: Int
      if arg.name != 0 {
        guard let found = params.firstIndex(where: { $0.name == arg.name }) else { return nil }
        target = found
      } else if arg.trailing, index == args.count - 1, !params.isEmpty {
        target = params.count - 1
        if used[target], !params[target].variadic { return nil }
      } else {
        while position < params.count, used[position], !params[position].variadic { position += 1 }
        guard position < params.count else { return nil }
        target = position
        if !params[position].variadic { position += 1 }
      }
      used[target] = true
      result.append(target)
    }
    for (index, param) in params.enumerated() where !used[index] && !param.hasDefault && !param.variadic { return nil }
    return result
  }

  func chooseOverload(_ callees: [Callee], unitIndex: Int32, nameToken: Int) -> [Callee] {
    guard unitIndex >= 0 else { return callees }
    let unit = project.units[Int(unitIndex)]
    guard nameToken >= 0, nameToken < unit.tokens.count, callOpen(unit, nameToken) != nil else {
      // A reference without a call (`::f`, an infix name): every one.
      return callees
    }
    return chooseOverload(callees, unitIndex: unitIndex, args: callArguments(unit, nameToken: nameToken))
  }

  /// Of a call's callees, those its arguments fit: by count and names, then by the types that are known; the most
  /// specific when several fit. None when none can take them.
  func chooseOverload(_ callees: [Callee], unitIndex: Int32, args: [KArg]) -> [Callee] {
    var unique: [Callee] = []
    for callee in callees where !unique.contains(where: { $0.ref == callee.ref }) { unique.append(callee) }
    let fitting = unique.compactMap { callee in assignment(callee, args).map { (callee, $0) } }
    guard fitting.count > 1 else { return fitting.map(\.0) }
    var argTypes: [Ty?] = Array(repeating: nil, count: args.count)
    func argType(_ index: Int) -> Ty {
      if let known = argTypes[index] { return known }
      let arg = args[index]
      let ty = arg.known ?? (arg.brace >= 0 ? .unknown : expressionType(unitIndex: unitIndex, start: Int32(arg.start), end: Int32(arg.end)))
      argTypes[index] = ty
      return ty
    }
    var fits: [(Callee, [Int])] = []
    for (callee, targets) in fitting {
      let params = parameters(of: callee.ref)
      var ok = true
      for (index, target) in targets.enumerated() {
        let want = substitute(params[target].type, callee.map)
        if args[index].brace >= 0 {
          if !acceptsLambda(want, unit: unitIndex >= 0 ? project.units[Int(unitIndex)] : nil, brace: args[index].brace) { ok = false }
          continue
        }
        if assignable(argType(index), to: want) == false {
          ok = false
          break
        }
      }
      if ok { fits.append((callee, targets)) }
    }
    if fits.count == 1 { return [fits[0].0] }
    guard fits.count > 1 else { return [] }
    // The most specific: each parameter its arguments go to fits the other's.
    let specific = fits.filter { a in
      fits.allSatisfy { b in
        if a.0.ref == b.0.ref { return true }
        let pa = parameters(of: a.0.ref)
        let pb = parameters(of: b.0.ref)
        return zip(a.1, b.1).allSatisfy { assignable(substitute(pa[$0.0].type, a.0.map), to: substitute(pb[$0.1].type, b.0.map)) ?? false }
      }
    }
    // One that surely takes them over those that may (a parameter type not known here).
    let sure = fits.filter { callee, targets in
      let params = parameters(of: callee.ref)
      return targets.enumerated().allSatisfy { index, target in args[index].brace >= 0 || assignable(argType(index), to: substitute(params[target].type, callee.map)) == true }
    }
    // The most specific, unless only an argument not known here makes it fit.
    if specific.count == 1, sure.isEmpty || sure.contains(where: { $0.0.ref == specific[0].0.ref }) { return [specific[0].0] }
    // An argument's own type over a conversion: `1..n` is `Int.rangeTo(Int)`, a literal is an `Int` first.
    let same = fits.filter { callee, targets in
      let params = parameters(of: callee.ref)
      return targets.enumerated().allSatisfy { index, target in
        guard args[index].brace < 0, case .nominal(let have, _) = memberBase(argType(index)), case .nominal(let want, _) = memberBase(substitute(params[target].type, callee.map)) else { return true }
        return have == want || !isNumber(have) || !isNumber(want)
      }
    }
    if same.count == 1 { return [same[0].0] }
    if sure.count == 1 { return [sure[0].0] }
    // Those that need no defaults.
    let exact = fits.filter { parameters(of: $0.0.ref).count == args.count }
    if exact.count == 1 { return [exact[0].0] }
    return fits.map(\.0)
  }

  /// Whether a lambda can be passed where a type is wanted: a function type (of its parameters' count, when it names
  /// them), a functional interface, a type parameter.
  func acceptsLambda(_ want: Ty, unit: Unit?, brace: Int) -> Bool {
    var named = -1
    if let unit, let body = body(unitIndex: project.unitByPath[unit.path] ?? -1, token: Int32(brace)), let lambda = body.lambdas[Int32(brace)], lambda.hasArrow {
      named = lambda.params.count
    }
    switch want {
    case .function(let params, _):
      return named < 0 ? params.count <= 1 : params.count == named
    case .constructed(let kind, let args) where kind == KotlinTy.receiverFunction:
      guard args.count == 2, case .function(let params, _) = args[1] else { return true }
      return named < 0 ? params.count <= 1 : params.count == named
    case .param, .unknown:
      return true
    case .nominal(let ref, _):
      guard decl(ref).kind == .protocolType else { return decl(ref).name == KotlinWord.function || decl(ref).name == name("Any") }
      // A functional interface: its one method's parameters, when the lambda names them.
      guard named >= 0 else { return true }
      let holder = self.unit(ref)
      let methods = holder.children(of: ref.decl).filter { holder.decls[Int($0)].kind == .function && !holder.decls[Int($0)].isStatic }
      return methods.count != 1 || Int(holder.decls[Int(methods[0])].paramCount) == named
    default:
      return false
    }
  }

  /// What a call returns: the chosen callee's result (a constructor's class), its declaring type's and its own
  /// (inferred) parameters put in. The callees must agree when several remain.
  func callResult(_ chosen: [Callee], unitIndex: Int32, args: [KArg], nameToken: Int = -1) -> Ty {
    var result: Ty?
    let explicit = nameToken >= 0 && unitIndex >= 0 ? explicitTypeArguments(unitIndex: unitIndex, nameToken: nameToken) : []
    for callee in chosen {
      let item = decl(callee.ref)
      var own = ownGenerics(callee.ref)
      var base: Ty
      if item.kind.isNominal {
        base = ownType(callee.ref)
      } else if item.kind == .initializer, item.parent >= 0 {
        let owner = DeclRef(unit: callee.ref.unit, decl: item.parent)
        base = ownType(owner)
        own.formUnion(ownGenerics(owner))
      } else {
        base = valueType(of: callee.ref)
      }
      if item.kind.isNominal { own = ownGenerics(callee.ref) }
      var ty = substitute(base, callee.map)
      if !own.isEmpty {
        var bindings: [Name: Ty] = [:]
        for (index, word) in typeParameterNames(callee.ref).enumerated() where index < explicit.count && explicit[index] != .unknown { bindings[word] = explicit[index] }
        if bindings.count < own.count {
          bindings.merge(inferBindings(callee, own: own, unitIndex: unitIndex, args: args, skipping: -1)) { written, _ in written }
        }
        ty = substitute(ty, bindings)
        ty = eraseUnbound(ty, own)
      }
      if let current = result, current != ty {
        if erasure(current) != erasure(ty) { return .unknown }
        continue
      }
      result = ty
    }
    return result ?? .unknown
  }

  /// Own parameters left unbound read as unknown.
  func eraseUnbound(_ ty: Ty, _ own: Set<Name>) -> Ty {
    switch ty {
    case .param(let word, _) where own.contains(word): return .unknown
    case .nominal(let ref, let args): return .nominal(ref, args.map { eraseUnbound($0, own) })
    case .constructed(let kind, let args): return .constructed(kind, args.map { eraseUnbound($0, own) })
    case .function(let params, let result): return .function(params.map { eraseUnbound($0, own) }, eraseUnbound(result, own))
    default: return ty
    }
  }

  /// A generic callee's own parameters as its arguments tell them: values first, then lambdas' results.
  func inferBindings(_ callee: Callee, own: Set<Name>, unitIndex: Int32, args: [KArg], skipping: Int) -> [Name: Ty] {
    guard !own.isEmpty, let targets = assignment(callee, args) else { return [:] }
    let params = parameters(of: callee.ref)
    var bindings: [Name: Ty] = [:]
    for (index, arg) in args.enumerated() where index != skipping && arg.brace < 0 {
      let have = arg.known ?? expressionType(unitIndex: unitIndex, start: Int32(arg.start), end: Int32(arg.end))
      unify(substitute(params[targets[index]].type, callee.map), have, own, &bindings)
    }
    for (index, arg) in args.enumerated() where index != skipping && arg.brace >= 0 {
      let want = substitute(substitute(params[targets[index]].type, callee.map), bindings)
      var result: Ty?
      switch want {
      case .function(_, let r): result = r
      case .constructed(let kind, let parts) where kind == KotlinTy.receiverFunction && parts.count == 2:
        if case .function(_, let r) = parts[1] { result = r }
      default: break
      }
      guard let result, let have = lambdaResultType(unitIndex: unitIndex, brace: arg.brace), have != .unknown else { continue }
      unify(result, have, own, &bindings)
    }
    return bindings
  }

  /// The functions a call's name may mean, for the lambdas and named arguments it's given.
  func callTarget(unitIndex: Int32, nameToken: Int) -> [Callee]? {
    let unit = project.units[Int(unitIndex)]
    guard nameToken >= 0, unit.ktIsName(nameToken) else { return nil }
    let word = unit.hash(nameToken)
    names[word] = unit.string(nameToken)
    if nameToken > 0, unit.ktIsDot(nameToken - 1) {
      let receiver = operandType(unitIndex: unitIndex, dot: nameToken - 1)
      switch receiver {
      case .module(let package): return constructorsAndFunctions(packageDecls(packageNames[package] ?? "", named: word))
      case .meta(let inner):
        let nested = memberTypeRefs(of: inner, named: word)
        return nested.isEmpty ? staticCallees(of: inner, named: word, wantsCall: true) : constructorsAndFunctions(nested)
      default: return callees(of: receiver, named: word, unitIndex: unitIndex, token: Int32(nameToken))
      }
    }
    if isInfixName(unit, nameToken) { return nil }
    return simpleCallees(word, unitIndex: unitIndex, token: Int32(nameToken))
  }

  // MARK: Lambdas

  /// What the lambda at a `{` is given to: the parameter of the call it's an argument of, or the declared type it
  /// initializes.
  func lambdaTarget(unitIndex: Int32, brace: Int) -> KLambdaTarget? {
    let key = Int64(unitIndex) << 32 | Int64(brace)
    if let known = lambdaTargets[key] { return known }
    guard lambdaResolving.insert(key).inserted else { return nil }
    defer { lambdaResolving.remove(key) }
    guard let want = lambdaWanted(unitIndex: unitIndex, brace: brace) else { return nil }
    var target: KLambdaTarget?
    switch want {
    case .function(let params, let result):
      target = KLambdaTarget(receiver: nil, params: params, result: result)
    case .constructed(let kind, let parts) where kind == KotlinTy.receiverFunction && parts.count == 2:
      if case .function(let params, let result) = parts[1] { target = KLambdaTarget(receiver: parts[0], params: params, result: result) }
    case .nominal:
      // A functional interface: its one abstract function.
      if let method = functionalMethod(of: want) {
        let params = parameters(of: method.ref).map { substitute($0.type, method.substitution) }
        target = KLambdaTarget(receiver: nil, params: params, result: substitute(valueType(of: method.ref), method.substitution))
      }
    default:
      break
    }
    if let target { lambdaTargets[key] = target }
    return target
  }

  /// The type a lambda is wanted as.
  private func lambdaWanted(unitIndex: Int32, brace: Int) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    let before = brace - 1
    guard before >= 0 else { return nil }
    // `val f: (A) -> B = {`, `x: T = {`.
    if unit.isToken(before, "=") {
      let nameToken = before - 1
      if unit.ktIsName(nameToken), !unit.isByte(nameToken - 1, 0x28) && !unit.isByte(nameToken - 1, 0x2C) || unit.isToken(nameToken - 1, "val") || unit.isToken(nameToken - 1, "var") {
        if let body = body(unitIndex: unitIndex, token: Int32(nameToken)), let index = body.byToken[Int32(nameToken)] {
          if case .typed(let s, let e, _) = body.locals[Int(index)].kind, s >= 0 { return parseType(unitIndex: unitIndex, start: s, end: e, scope: Int32(nameToken)) }
          return nil
        }
        if case .decl(let ref)? = unit.declaredSite(at: nameToken, unitIndex: unitIndex), decl(ref).typeStart >= 0 { return valueType(of: ref) }
        return nil
      }
    }
    // A call's argument: trailing, positional or named.
    var nameToken = -1
    var position = -1
    var named: Name = 0
    if unit.isByte(before, 0x29), let open = unit.matchingOpen(before), isTrailingLambda(unit, brace) {
      nameToken = callNameBefore(unit, open)
    } else if unit.ktIsName(before) || unit.tokens[before].kind == .punctuation && unit.ktOnly(before, ">"), isTrailingLambda(unit, brace) {
      nameToken = unit.ktIsName(before) ? before : callNameBefore(unit, brace)
    } else if unit.isByte(before, 0x28) || unit.isByte(before, 0x2C) || unit.isToken(before, "="), let open = unit.isByte(before, 0x28) ? before : unit.matchingOpenBefore(before), unit.isByte(open, 0x28) {
      nameToken = callNameBefore(unit, open)
      if unit.isToken(before, "="), unit.ktIsName(before - 1) { named = unit.hash(before - 1) }
    }
    guard nameToken >= 0, let found = callTarget(unitIndex: unitIndex, nameToken: nameToken) else { return nil }
    let args = callArguments(unit, nameToken: nameToken)
    guard let index = args.firstIndex(where: { $0.brace == brace }) else { return nil }
    _ = named
    position = index
    let chosen = chooseOverload(found, unitIndex: unitIndex, args: args)
    var result: Ty?
    for callee in chosen.isEmpty ? found : chosen {
      guard let targets = assignment(callee, args) else { continue }
      let params = parameters(of: callee.ref)
      var own = ownGenerics(callee.ref)
      if decl(callee.ref).kind.isNominal { own = ownGenerics(callee.ref) }
      let bindings = inferBindings(callee, own: own, unitIndex: unitIndex, args: args, skipping: position)
      let param = eraseUnbound(substitute(substitute(params[targets[position]].type, callee.map), bindings), own)
      if let current = result, erasure(current) != erasure(param) { return nil }
      if result == nil { result = param }
    }
    return result
  }

  /// The name a call's `(` or trailing `{` belongs to, past explicit type arguments.
  private func callNameBefore(_ unit: Unit, _ open: Int) -> Int {
    var k = open - 1
    if k >= 0, unit.tokens[k].kind == .punctuation, unit.ktOnly(k, ">") {
      var depth = 0
      while k >= 0 {
        if unit.tokens[k].kind == .punctuation {
          for b in (0..<unit.tokens[k].length).reversed() {
            let byte = unit.source.text[unit.tokens[k].start + b]
            if byte == 0x3E { depth += 1 } else if byte == 0x3C { depth -= 1 }
          }
          if depth == 0 { break }
        } else if unit.tokens[k].kind == .open || unit.isByte(k, 0x3B) {
          return -1
        }
        k -= 1
      }
      k -= 1
    }
    return unit.ktIsName(k) ? k : -1
  }

  /// The one abstract function of a functional interface (`fun interface`, a Java interface).
  func functionalMethod(of ty: Ty) -> KMember? {
    guard case .nominal(let ref, let args) = memberBase(ty), decl(ref).kind == .protocolType else { return nil }
    let map = parameterMap(ref, args)
    var found: KMember?
    for (_, entries) in memberTable(of: ref) {
      for entry in entries {
        let item = decl(entry.ref)
        guard item.kind == .function, item.bodyOpen < 0, item.initStart < 0, !item.isStatic, decl(DeclRef(unit: entry.ref.unit, decl: item.parent)).kind == .protocolType else { continue }
        if isJava(entry.ref), isDefaultJava(entry.ref) { continue }
        // Any's and Object's functions restated don't count.
        if item.name == name("equals") || item.name == name("hashCode") || item.name == name("toString") { continue }
        if found != nil, found!.ref != entry.ref { return nil }
        var composed = entry
        composed.substitution = entry.substitution.mapValues { substitute($0, map) }.merging(map) { first, _ in first }
        found = composed
      }
    }
    return found
  }

  private func isDefaultJava(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    let holder = unit(ref)
    var k = Int(item.first)
    while k < Int(item.nameToken) {
      if holder.isToken(k, "default") { return true }
      k += 1
    }
    return false
  }

  /// What a lambda returns: its last statement's type.
  func lambdaResultType(unitIndex: Int32, brace: Int) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    let close = unit.skipBalanced(brace) - 1
    var start = brace + 1
    if let body = body(unitIndex: unitIndex, token: Int32(brace + 1)), let lambda = body.lambdas[Int32(brace)], lambda.hasArrow {
      var k = brace + 1
      while k < close, !unit.isToken(k, "->") { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
      start = k + 1
    }
    guard start < close else { return kotlinNominal("Unit") }
    let ty = blockValueType(unitIndex: unitIndex, open: start - 1, close: close)
    return ty == .unknown ? nil : ty
  }

  // MARK: Locals

  func localType(unitIndex: Int32, body: KotlinBody, index: Int32) -> Ty {
    if let known = body.types[index] { return known }
    guard body.resolving.insert(index).inserted else { return .unknown }
    defer { body.resolving.remove(index) }
    let local = body.locals[Int(index)]
    var result = Ty.unknown
    switch local.kind {
    case .typed(let start, let end, let variadic):
      if start >= 0 {
        result = parseType(unitIndex: unitIndex, start: start, end: end, scope: local.token)
        if variadic { result = arrayOf(result) }
      }
    case .inferred(let start, let end):
      result = expressionType(unitIndex: unitIndex, start: start, end: end)
    case .delegated(let start, let end):
      result = delegatedType(expressionType(unitIndex: unitIndex, start: start, end: end), unitIndex: unitIndex)
    case .element(let start, let end):
      result = elementType(expressionType(unitIndex: unitIndex, start: start, end: end), unitIndex: unitIndex)
    case .component(let start, let end, let position, let ofElement):
      var base = expressionType(unitIndex: unitIndex, start: start, end: end)
      if ofElement { base = elementType(base, unitIndex: unitIndex) }
      result = componentType(base, Int(position) + 1, unitIndex: unitIndex)
    case .lambdaComponent(let brace, let position, let component):
      if let target = lambdaTarget(unitIndex: unitIndex, brace: Int(brace)), Int(position) < target.params.count {
        result = componentType(target.params[Int(position)], Int(component) + 1, unitIndex: unitIndex)
      }
    case .lambda(let brace, let position):
      if let target = lambdaTarget(unitIndex: unitIndex, brace: Int(brace)), Int(position) < target.params.count { result = target.params[Int(position)] }
    case .setterValue(let property):
      result = valueType(of: DeclRef(unit: unitIndex, decl: property))
    }
    if case .param = result, bound(of: result) == nil, !isInScope(result, unitIndex: unitIndex, token: local.token) { result = .unknown }
    body.types[index] = result
    return result
  }

  /// Whether a type parameter is one a token's declarations have (else it leaked from a callee).
  private func isInScope(_ ty: Ty, unitIndex: Int32, token: Int32) -> Bool {
    guard case .param(_, let owner?) = ty else { return true }
    guard owner.unit == unitIndex else { return false }
    return project.units[Int(unitIndex)].chain(at: token).contains(owner.decl) || decl(owner).parent >= 0 && project.units[Int(unitIndex)].chain(at: token).contains(decl(owner).parent)
  }

  /// What a `for` over a value gives: `iterator().next()`.
  func elementType(_ ty: Ty, unitIndex: Int32) -> Ty {
    let iterator = operatorResult(ty, KotlinWord.iterator, [], unitIndex: unitIndex)
    return operatorResult(iterator, KotlinWord.next, [], unitIndex: unitIndex)
  }

  /// A destructured value's n-th component: a data class's constructor property, else `componentN()`.
  func componentType(_ ty: Ty, _ n: Int, unitIndex: Int32) -> Ty {
    if case .nominal(let ref, let args) = memberBase(ty), !isJava(ref), decl(ref).kind == .classType, isDataClass(ref) {
      let params = parameters(of: ref)
      guard n - 1 < params.count else { return .unknown }
      return substitute(params[n - 1].type, parameterMap(ref, args))
    }
    return operatorResult(ty, name("component" + String(n)), [], unitIndex: unitIndex)
  }

  func isDataClass(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    let holder = unit(ref)
    var k = Int(item.first)
    while k < Int(item.nameToken) {
      if holder.isToken(k, "data") { return true }
      k += 1
    }
    return false
  }

  /// An operator function's result on a receiver (a member, else an extension), its generics bound from the receiver
  /// and the arguments' types.
  func operatorResult(_ receiver: Ty, _ word: Name, _ argTypes: [Ty], unitIndex: Int32) -> Ty {
    if case .unknown = receiver { return .unknown }
    if case .function = receiver, word == KotlinWord.invoke { return invocationResult(receiver) }
    var found: [Callee] = []
    for (entry, _) in memberEntries(of: receiver, named: word) where decl(entry.ref).kind == .function && Int(decl(entry.ref).paramCount) == argTypes.count {
      found.append(Callee(ref: entry.ref, map: entry.substitution, receiver: receiver))
    }
    if found.isEmpty {
      found = extensionCandidates(receiver: receiver, named: word, unitIndex: unitIndex, wantsCall: true).filter { Int(decl($0.ref).paramCount) == argTypes.count }
    }
    let args = argTypes.map { KArg(start: -1, end: -1, known: $0) }
    let chosen = chooseOverload(found, unitIndex: -1, args: args)
    return callResult(chosen.isEmpty ? Array(found.prefix(1)) : chosen, unitIndex: unitIndex, args: args)
  }

  // MARK: Operands left of a dot

  /// The type of the operand left of a `.`, `?.` or `::`: the expression that ends there.
  func operandType(unitIndex: Int32, dot: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let start = expressionStart(unit, before: dot)
    guard start < dot else { return .unknown }
    var i = start
    let ty = postfixType(unitIndex: unitIndex, start: &i, end: dot)
    return i < dot ? .unknown : ty
  }

  /// An infix call's left operand: the postfix expression before its name.
  func infixOperandStart(_ unit: Unit, before end: Int) -> Int { expressionStart(unit, before: end) }

  /// Walking back from just before `end`: names, dots, calls with their trailing lambdas, indexes, `!!`, literals, as
  /// far as one operand goes.
  func expressionStart(_ unit: Unit, before end: Int) -> Int {
    var i = end - 1
    while i >= 0 {
      let token = unit.tokens[i]
      if unit.isToken(i, "!!") {
        i -= 1
        continue
      }
      if token.kind == .close {
        guard let open = unit.matchingOpen(i) else { return i + 1 }
        if unit.isByte(open, 0x7B) {
          // A trailing lambda: part of the call before it.
          let before = open - 1
          if before >= 0, !unit.startsLine(open), unit.isByte(before, 0x29) || unit.ktIsName(before) || unit.tokens[before].kind == .punctuation && unit.ktOnly(before, ">") {
            i = before
            continue
          }
          return open
        }
        i = open
        if i > 0, unit.ktIsName(i - 1) || unit.tokens[i - 1].kind == .close || unit.isToken(i - 1, "this") || unit.isToken(i - 1, "super") || unit.tokens[i - 1].kind == .punctuation && unit.ktOnly(i - 1, ">") && unit.isByte(open, 0x28) {
          if unit.isByte(open, 0x28), unit.tokens[i - 1].kind == .punctuation {
            // `name<T>(`.
            let name = callNameBefore(unit, open)
            guard name >= 0 else { return i }
            i = name
          } else {
            i -= 1
          }
          if unit.tokens[i].kind == .close { continue }
          if unit.isToken(i, "if") || unit.isToken(i, "when") || unit.isToken(i, "for") || unit.isToken(i, "while") { return i + 2 }
          if i > 0, unit.ktIsDot(i - 1) {
            i -= 2
            continue
          }
          if i > 0, unit.isToken(i - 1, "::") {
            i -= 2
            continue
          }
          return i
        }
        return i
      }
      if unit.isToken(i, "class"), i > 1, unit.isToken(i - 1, "::") {
        // `T::class`.
        i -= 2
        continue
      }
      if unit.ktIsName(i) || token.kind == .number || token.kind == .string || unit.isToken(i, "this") || unit.isToken(i, "super") {
        if token.kind == .string {
          // A template's parts: back to its opening part.
          var k = i
          while k > 0, unit.tokens[k - 1].kind == .interpolationClose {
            var depth = 0
            k -= 1
            while k >= 0 {
              if unit.tokens[k].kind == .interpolationClose { depth += 1 }
              if unit.tokens[k].kind == .interpolationOpen {
                depth -= 1
                if depth == 0 { break }
              }
              k -= 1
            }
            if k > 0, unit.tokens[k - 1].kind == .string { k -= 1 } else { break }
          }
          i = max(k, 0)
        }
        if i > 0, unit.ktIsDot(i - 1) {
          i -= 2
          continue
        }
        if i > 0, unit.isToken(i - 1, "::") {
          i -= 2
          continue
        }
        if i > 0, unit.tokens[i - 1].kind == .attribute, unit.isToken(i, "this") == false, unit.touchesPrevious(i) == false {
          return i
        }
        return max(i, 0)
      }
      if token.kind == .attribute, i > 0, unit.isToken(i - 1, "this"), unit.touchesPrevious(i) {
        // `this@Label`.
        i -= 1
        continue
      }
      return i + 1
    }
    return 0
  }
}
