import CodeModel
import CodeScan
import Foundation

/// Go's types, read from their tokens when someone asks (`Ty`, the core's): named types are `nominal`, `*T`, `[]T`,
/// `[N]T`, `map[K]V` and `chan T` are `constructed`, a function's several results a `tuple`, a type used as a value
/// (`T(x)`, `T.Method`) `meta`, a package `module`.
extension GoModel {
  // MARK: Written types

  /// A type written from `start` to `end` in a unit, its names looked up from `scope` (a token: locals and type
  /// parameters around it).
  func parseType(unitIndex: Int32, start: Int32, end: Int32, scope: Int32) -> Ty {
    guard start >= 0, start < end else { return .unknown }
    var i = Int(start)
    return readType(unitIndex, &i, Int(end), scope)
  }

  private func readType(_ unitIndex: Int32, _ i: inout Int, _ end: Int, _ scope: Int32) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard i < end else { return .unknown }
    if unit.isByte(i, 0x2A) {
      i += 1
      return .constructed(Ty.pointer, [readType(unitIndex, &i, end, scope)])
    }
    if unit.isToken(i, "**") {
      i += 1
      return .constructed(Ty.pointer, [.constructed(Ty.pointer, [readType(unitIndex, &i, end, scope)])])
    }
    if unit.isToken(i, "...") {
      i += 1
      return .constructed(Ty.slice, [readType(unitIndex, &i, end, scope)])
    }
    if unit.isByte(i, 0x5B) {
      let close = unit.skipBalanced(i)
      let isSlice = close == i + 2
      i = close
      let element = readType(unitIndex, &i, end, scope)
      return .constructed(isSlice ? Ty.slice : Ty.array, [element])
    }
    if unit.isToken(i, "map"), unit.isByte(i + 1, 0x5B) {
      let close = unit.skipBalanced(i + 1)
      var k = i + 2
      let key = readType(unitIndex, &k, close - 1, scope)
      i = close
      return .constructed(Ty.map, [key, readType(unitIndex, &i, end, scope)])
    }
    if unit.isToken(i, "<-"), unit.isToken(i + 1, "chan") {
      i += 2
      return .constructed(Ty.channel, [readType(unitIndex, &i, end, scope)])
    }
    if unit.isToken(i, "chan") {
      i += 1
      if unit.isToken(i, "<-") { i += 1 }
      return .constructed(Ty.channel, [readType(unitIndex, &i, end, scope)])
    }
    if unit.isToken(i, "func") {
      let open = i + 1
      guard unit.isByte(open, 0x28) else { return .unknown }
      let close = unit.skipBalanced(open)
      let params = typesOfList(unitIndex, open: open, close: close - 1, scope: scope)
      i = close
      var result = Ty.tuple([], [])
      if i < end, !unit.startsLine(i) {
        if unit.isByte(i, 0x28) {
          let resultClose = unit.skipBalanced(i)
          let list = typesOfList(unitIndex, open: i, close: resultClose - 1, scope: scope)
          result = list.count == 1 ? list[0] : .tuple(list, [])
          i = resultClose
        } else if !unit.isByte(i, 0x7B) {
          result = readType(unitIndex, &i, end, scope)
        }
      }
      return .function(params, result)
    }
    if unit.isToken(i, "struct"), unit.isByte(i + 1, 0x7B) {
      let at = i
      i = unit.skipBalanced(i + 1)
      for index in unit.decls.indices where unit.decls[index].nameToken == Int32(at) && unit.decls[index].kind == .structure {
        return .nominal(DeclRef(unit: unitIndex, decl: Int32(index)), [])
      }
      return .unknown
    }
    if unit.isToken(i, "interface"), unit.isByte(i + 1, 0x7B) {
      let close = unit.skipBalanced(i + 1)
      let isEmpty = close == i + 3
      let at = i
      i = close
      if isEmpty, let any = universe?.top[GoWord.any]?.first { return .nominal(any, []) }
      for index in unit.decls.indices where unit.decls[index].nameToken == Int32(at) && unit.decls[index].kind == .protocolType {
        return .nominal(DeclRef(unit: unitIndex, decl: Int32(index)), [])
      }
      return .existential([])
    }
    if unit.isByte(i, 0x28) {
      let close = unit.skipBalanced(i)
      var k = i + 1
      let inner = readType(unitIndex, &k, close - 1, scope)
      i = close
      return inner
    }
    guard unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword else { return .unknown }
    var found: [Site] = []
    let nameToken = i
    if unit.isByte(i + 1, 0x2E), i + 2 < end, let item = importNamed(unit.hash(i), in: unitIndex) {
      i += 2
      if let module = project.ensureModule(item.module, display: item.moduleName) { found = (module.top[unit.hash(i)] ?? []).map { .decl($0) } }
    } else {
      found = lookup(unit.hash(nameToken), unitIndex: unitIndex, token: scope >= 0 ? scope : Int32(nameToken))
    }
    i += 1
    var args: [Ty] = []
    if unit.isByte(i, 0x5B), unit.touchesPrevious(i), i < end {
      let close = unit.skipBalanced(i)
      var k = i + 1
      while k < close - 1 {
        args.append(readType(unitIndex, &k, close - 1, scope))
        if unit.isByte(k, 0x2C) { k += 1 } else { break }
      }
      i = close
    }
    guard let site = found.first else { return .unknown }
    return typeOfTypeSite(site, args: args)
  }

  /// The types of a parameter or result list, one per parameter (`a, b int` is two).
  private func typesOfList(_ unitIndex: Int32, open: Int, close: Int, scope: Int32) -> [Ty] {
    var decl = Decl(kind: .function, name: 0, nameToken: -1, first: 0, parent: -1)
    let unit = project.units[Int(unitIndex)]
    let before = unit.params.count
    var parser = GoParser(unit: unit)
    parser.parameters(open: open, close: close, into: &decl)
    let list = unit.params[before...].map { parseType(unitIndex: unitIndex, start: $0.typeStart, end: $0.typeEnd, scope: scope) }
    unit.params.removeSubrange(before...)
    return list
  }

  /// A type name's site as a type: a declared type, a type parameter.
  func typeOfTypeSite(_ site: Site, args: [Ty]) -> Ty {
    switch site {
    case .decl(let ref):
      let item = decl(ref)
      switch item.kind {
      case .typeAlias:
        return aliasTarget(ref)
      case .structure, .protocolType:
        return .nominal(ref, args)
      default:
        return .unknown
      }
    case .generic(_, let token), .local(_, let token):
      _ = token
      if case .generic(let unitIndex, let token) = site { return .param(project.units[Int(unitIndex)].hash(Int(token)), nil) }
      return .unknown
    case .module(let moduleName):
      return .module(moduleName)
    }
  }

  private func aliasTarget(_ ref: DeclRef) -> Ty {
    guard resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    let item = decl(ref)
    return parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: item.nameToken)
  }

  /// A named type's underlying type, aliases followed: `type X Y` is Y's.
  func underlying(_ ty: Ty, depth: Int = 0) -> Ty {
    guard depth < 8, case .nominal(let ref, _) = ty else { return ty }
    let item = decl(ref)
    guard item.kind == .structure, item.bodyOpen < 0, item.typeStart >= 0 else { return ty }
    let inner = parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: item.nameToken)
    // `type int int` in builtin.go is its own.
    if case .nominal(let other, _) = inner, other == ref { return ty }
    if inner == .unknown { return ty }
    return underlying(inner, depth: depth + 1)
  }

  /// Through one pointer.
  func dereferenced(_ ty: Ty) -> Ty {
    if case .constructed(let kind, let args) = ty, kind == Ty.pointer, let inner = args.first { return inner }
    return ty
  }

  func builtinType(_ word: Name) -> Ty {
    guard let ref = universe?.top[word]?.first else { return .unknown }
    return .nominal(ref, [])
  }

  // MARK: Values

  /// The type of a declaration used as a value.
  func valueType(of ref: DeclRef) -> Ty {
    if let known = valueTypes[ref] { return known }
    guard resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    let item = decl(ref)
    var result = Ty.unknown
    switch item.kind {
    case .variable:
      if item.typeStart >= 0 {
        result = parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: item.nameToken)
      } else if item.initStart >= 0 {
        result = pick(expressionType(unitIndex: ref.unit, start: item.initStart, end: item.initEnd), item.valueIndex)
      }
      if item.isStatic, result == .unknown, item.initStart < 0 { result = builtinType(GoWord.int) }
    case .function:
      result = functionType(ref)
    case .structure, .protocolType:
      result = .meta(.nominal(ref, []))
    case .typeAlias:
      result = .meta(aliasTarget(ref))
    default:
      break
    }
    valueTypes[ref] = result
    return result
  }

  func functionType(_ ref: DeclRef) -> Ty {
    let item = decl(ref)
    let holder = unit(ref)
    var params: [Ty] = []
    for p in 0..<Int(item.paramCount) {
      let param = holder.params[Int(item.paramStart) + p]
      params.append(parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: item.nameToken))
    }
    var result = Ty.tuple([], [])
    if item.typeStart >= 0 {
      if holder.isByte(Int(item.typeStart), 0x28) {
        let list = typesOfList(ref.unit, open: Int(item.typeStart), close: holder.skipBalanced(Int(item.typeStart)) - 1, scope: item.nameToken)
        result = list.count == 1 ? list[0] : .tuple(list, [])
      } else {
        result = parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: item.nameToken)
      }
    }
    return .function(params, result)
  }

  /// One value of several: `a, b := f()` takes b's from the second.
  func pick(_ ty: Ty, _ index: Int32) -> Ty {
    guard index > 0 else {
      if case .tuple(let items, _) = ty, let first = items.first, items.count > 1 { return first }
      return ty
    }
    if case .tuple(let items, _) = ty { return Int(index) <= items.count ? items[Int(index) - 1] : .unknown }
    return index == 1 ? ty : .unknown
  }

  /// A local's type.
  func localType(unitIndex: Int32, body: GoBody, index: Int32) -> Ty {
    if let known = body.types[index] { return known }
    guard body.resolving.insert(index).inserted else { return .unknown }
    defer { body.resolving.remove(index) }
    let local = body.locals[Int(index)]
    let unit = project.units[Int(unitIndex)]
    var result = Ty.unknown
    switch local.kind {
    case .typed(let start, let end):
      result = parseType(unitIndex: unitIndex, start: start, end: end, scope: local.token)
    case .value(let start, let end, let which):
      let value = expressionType(unitIndex: unitIndex, start: start, end: end, commaOK: which == 2)
      result = pick(value, which)
    case .range(let start, let end, let isValue):
      let over = underlying(dereferenced(underlying(expressionType(unitIndex: unitIndex, start: start, end: end))))
      result = rangeType(over, isValue: isValue)
    case .typeSwitch(let start, let end, let clause):
      if clause >= 0 {
        var k = Int(clause) + 1
        var types: [(Int, Int)] = []
        var itemStart = k
        while k < unit.tokens.count, !unit.isByte(k, 0x3A) {
          if unit.isByte(k, 0x2C) {
            types.append((itemStart, k))
            itemStart = k + 1
          }
          k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
        }
        types.append((itemStart, k))
        if types.count == 1, !unit.isToken(types[0].0, "nil") {
          result = parseType(unitIndex: unitIndex, start: Int32(types[0].0), end: Int32(types[0].1), scope: local.token)
          break
        }
      }
      result = expressionType(unitIndex: unitIndex, start: start, end: end)
    case .receive(let start, let end, let which):
      let channel = underlying(expressionType(unitIndex: unitIndex, start: start, end: end))
      if which == 2 {
        result = builtinType(GoWord.bool)
      } else if case .constructed(let kind, let args) = channel, kind == Ty.channel, let element = args.first {
        result = element
      }
    case .declaration(let declIndex):
      result = .meta(.nominal(DeclRef(unit: unitIndex, decl: declIndex), []))
    case .label, .unknown:
      break
    }
    body.types[index] = result
    return result
  }

  private func rangeType(_ over: Ty, isValue: Bool) -> Ty {
    switch over {
    case .constructed(let kind, let args):
      if kind == Ty.map { return isValue ? args[1] : args[0] }
      if kind == Ty.channel { return isValue ? .unknown : args[0] }
      if kind == Ty.slice || kind == Ty.array { return isValue ? args[0] : builtinType(GoWord.int) }
      return .unknown
    case .nominal(let ref, _):
      if decl(ref).name == GoWord.string, isUniverse(ref) { return isValue ? builtinType(GoWord.rune) : builtinType(GoWord.int) }
      if isUniverse(ref) { return isValue ? .unknown : over }
      return .unknown
    case .function(let params, _):
      // A range-over-func iterator: `func(yield func(K, V) bool)`.
      if case .function(let yields, _)? = params.first { return isValue ? (yields.count > 1 ? yields[1] : .unknown) : (yields.first ?? .unknown) }
      return .unknown
    default:
      return .unknown
    }
  }

  func isUniverse(_ ref: DeclRef) -> Bool { project.units[Int(ref.unit)].moduleName == GoWord.builtin }

  // MARK: Expressions

  /// The type of an expression's tokens. `commaOK`: `v, ok := m[k]` asks for both values.
  func expressionType(unitIndex: Int32, start: Int32, end: Int32, commaOK: Bool = false) -> Ty {
    guard start >= 0, start < end else { return .unknown }
    depth += 1
    defer { depth -= 1 }
    guard depth < 48 else { return .unknown }
    let unit = project.units[Int(unitIndex)]
    var i = Int(start)
    let limit = Int(end)
    // Unary operators.
    if unit.isByte(i, 0x26) {
      return .constructed(Ty.pointer, [expressionType(unitIndex: unitIndex, start: Int32(i + 1), end: end)])
    }
    if unit.isByte(i, 0x2A) {
      return dereferenced(underlying(expressionType(unitIndex: unitIndex, start: Int32(i + 1), end: end)))
    }
    if unit.isToken(i, "<-") {
      let channel = underlying(expressionType(unitIndex: unitIndex, start: Int32(i + 1), end: end))
      if case .constructed(let kind, let args) = channel, kind == Ty.channel {
        return commaOK ? .tuple([args[0], builtinType(GoWord.bool)], []) : args[0]
      }
      return .unknown
    }
    if unit.isByte(i, 0x21) { return builtinType(GoWord.bool) }
    if unit.isByte(i, 0x2D) || unit.isByte(i, 0x2B) || unit.isByte(i, 0x5E) {
      return expressionType(unitIndex: unitIndex, start: Int32(i + 1), end: end)
    }
    // A binary operator at depth 0: comparisons are bool, the rest the left operand's type.
    var k = i
    if unit.isByte(i, 0x5B) || unit.isToken(i, "map") || unit.isToken(i, "chan") || unit.isToken(i, "func") || unit.isToken(i, "struct") || unit.isToken(i, "interface") {
      // A type literal's `*` is no operator: `[]*T{}`, `func() *T {…}`.
      k = max(i + 1, GoParser(unit: unit).typeEnd(i, limit: limit))
    }
    while k < limit {
      let token = unit.tokens[k]
      if token.kind == .open {
        if unit.isToken(k, "{"), k > i, unit.isToken(k - 1, ")") || unit.tokens[k - 1].kind == .identifier || unit.isByte(k - 1, 0x5D) || unit.isByte(k - 1, 0x7D) {
          k = unit.skipBalanced(k)
          continue
        }
        k = unit.skipBalanced(k)
        continue
      }
      if token.kind == .punctuation, k > i, !unit.isByte(k, 0x2E), !unit.isToken(k, "..."), !unit.isByte(k, 0x2C) {
        if unit.isToken(k, "==") || unit.isToken(k, "!=") || unit.isToken(k, "<") || unit.isToken(k, "<=") || unit.isToken(k, ">") || unit.isToken(k, ">=")
          || unit.isToken(k, "&&") || unit.isToken(k, "||")
        {
          return builtinType(GoWord.bool)
        }
        if unit.isToken(k, "<<") || unit.isToken(k, ">>") {
          return expressionType(unitIndex: unitIndex, start: start, end: Int32(k))
        }
        let left = expressionType(unitIndex: unitIndex, start: start, end: Int32(k))
        if left != .unknown, !isUntypedLiteral(unitIndex, Int(start), k) { return left }
        let right = expressionType(unitIndex: unitIndex, start: Int32(k + 1), end: end)
        return right == .unknown ? left : right
      }
      if unit.isByte(k, 0x2C) { break }
      k += 1
    }
    return postfixType(unitIndex: unitIndex, start: &i, end: limit, commaOK: commaOK)
  }

  private func isUntypedLiteral(_ unitIndex: Int32, _ start: Int, _ end: Int) -> Bool {
    let unit = project.units[Int(unitIndex)]
    return end == start + 1 && (unit.tokens[start].kind == .number || unit.tokens[start].kind == .string)
  }

  /// An operand and what follows it: `.name`, `(args)`, `[i]`, `[a:b]`, `.(T)`, `{…}`.
  private func postfixType(unitIndex: Int32, start i: inout Int, end: Int, commaOK: Bool) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard i < end else { return .unknown }
    var ty = operandType(unitIndex: unitIndex, at: &i, end: end)
    while i < end {
      if unit.isByte(i, 0x2E), i + 1 < end {
        if unit.isByte(i + 1, 0x28) {
          // `.(T)`, a type assertion.
          let close = unit.skipBalanced(i + 1)
          ty = parseType(unitIndex: unitIndex, start: Int32(i + 2), end: Int32(close - 1), scope: Int32(i))
          if commaOK, close >= end { return .tuple([ty, builtinType(GoWord.bool)], []) }
          i = close
          continue
        }
        let member = unit.hash(i + 1)
        ty = memberValueType(of: ty, named: member, unitIndex: unitIndex)
        i += 2
        continue
      }
      if unit.isByte(i, 0x28) {
        let close = unit.skipBalanced(i)
        ty = callResult(ty, unitIndex: unitIndex, open: i, close: close - 1)
        i = close
        continue
      }
      if unit.isByte(i, 0x5B) {
        let close = unit.skipBalanced(i)
        var isSlice = false
        var k = i + 1
        while k < close - 1 {
          if unit.isByte(k, 0x3A) { isSlice = true }
          k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
        }
        if case .meta(let inner) = ty {
          // `List[int]`: an instance.
          if case .nominal(let ref, _) = inner {
            var args: [Ty] = []
            var a = i + 1
            while a < close - 1 {
              var e = a
              while e < close - 1, !unit.isByte(e, 0x2C) { e = unit.tokens[e].kind == .open ? unit.skipBalanced(e) : e + 1 }
              args.append(parseType(unitIndex: unitIndex, start: Int32(a), end: Int32(e), scope: Int32(a)))
              a = e + 1
            }
            ty = .meta(.nominal(ref, args))
          }
        } else if case .function = ty {
          // `Map[int, string]`: the function, explicitly instantiated.
          let callee = i > 0 && unit.tokens[i - 1].kind == .identifier ? answer(unitIndex: unitIndex, token: i - 1) : Answer(state: .unknown, sites: [])
          if callee.state == .exact, case .decl(let ref)? = callee.sites.first, decl(ref).genericCount > 0 {
            let item = decl(ref)
            let holder = self.unit(ref)
            var map: [Name: Ty] = [:]
            var a = i + 1
            var g = 0
            while a < close - 1, g < Int(item.genericCount) {
              var e = a
              while e < close - 1, !unit.isByte(e, 0x2C) { e = unit.tokens[e].kind == .open ? unit.skipBalanced(e) : e + 1 }
              map[holder.generics[Int(item.genericStart) + g].name] = parseType(unitIndex: unitIndex, start: Int32(a), end: Int32(e), scope: Int32(a))
              a = e + 1
              g += 1
            }
            ty = substitute(ty, map)
          }
        } else if isSlice {
          let base = underlying(ty)
          if case .nominal(let ref, _) = base, decl(ref).name == GoWord.string, isUniverse(ref) {
            // A string slices to a string.
          } else if case .constructed(let kind, let args) = dereferenced(base), kind == Ty.array {
            ty = .constructed(Ty.slice, args)
          }
        } else {
          ty = indexType(ty, commaOK: commaOK && close >= end)
        }
        i = close
        continue
      }
      if unit.isByte(i, 0x7B) {
        // A composite literal: the type it's written with.
        i = unit.skipBalanced(i)
        if case .meta(let inner) = ty { ty = inner }
        continue
      }
      break
    }
    if case .meta(let inner) = ty, end > 0, unit.isByte(end - 1, 0x7D) { return inner }
    return ty
  }

  private func indexType(_ ty: Ty, commaOK: Bool) -> Ty {
    let base = dereferenced(underlying(ty))
    switch base {
    case .constructed(let kind, let args):
      if kind == Ty.map { return commaOK ? .tuple([args[1], builtinType(GoWord.bool)], []) : args[1] }
      if kind == Ty.slice || kind == Ty.array { return args[0] }
      return .unknown
    case .nominal(let ref, _):
      if decl(ref).name == GoWord.string, isUniverse(ref) { return builtinType(GoWord.byte) }
      return .unknown
    default:
      return .unknown
    }
  }

  /// The operand an expression starts with: a name, a literal, a parenthesized expression, a type, a function literal.
  private func operandType(unitIndex: Int32, at i: inout Int, end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let token = unit.tokens[i]
    switch token.kind {
    case .number:
      i += 1
      let text = unit.string(i - 1)
      if text.hasSuffix("i") { return builtinType(GoWord.complex128) }
      let isFloat = (text.contains(".") || text.contains("e") || text.contains("E")) && !text.hasPrefix("0x") && !text.hasPrefix("0X")
      return builtinType(isFloat ? GoWord.float64 : GoWord.int)
    case .string:
      i += 1
      return builtinType(unit.source.text[token.start] == 0x27 ? GoWord.rune : GoWord.string)
    case .open:
      if unit.isByte(i, 0x28) {
        let close = unit.skipBalanced(i)
        let inner = expressionType(unitIndex: unitIndex, start: Int32(i + 1), end: Int32(close - 1))
        i = close
        return inner
      }
      if unit.isByte(i, 0x5B) {
        // `[]T{…}`, `[]byte(s)`: a type.
        var k = i
        let ty = parseTypeAdvancing(unitIndex, &k, end)
        i = k
        return .meta(ty)
      }
      return .unknown
    case .keyword, .declarationKeyword:
      if unit.isToken(i, "func") {
        var k = i
        let ty = parseTypeAdvancing(unitIndex, &k, end)
        if unit.isByte(k, 0x7B) { k = unit.skipBalanced(k) }
        i = k
        return ty
      }
      if unit.isToken(i, "map") || unit.isToken(i, "chan") || unit.isToken(i, "struct") || unit.isToken(i, "interface") {
        var k = i
        let ty = parseTypeAdvancing(unitIndex, &k, end)
        i = k
        return .meta(ty)
      }
      fallthrough
    case .identifier:
      let word = unit.hash(i)
      let sites = lookup(word, unitIndex: unitIndex, token: Int32(i))
      i += 1
      guard let site = sites.first else { return .unknown }
      return siteType(site, unitIndex: unitIndex)
    default:
      return .unknown
    }
  }

  private func parseTypeAdvancing(_ unitIndex: Int32, _ i: inout Int, _ end: Int) -> Ty {
    let start = i
    let unit = project.units[Int(unitIndex)]
    i = GoParser(unit: unit).typeEnd(i, limit: end)
    return parseType(unitIndex: unitIndex, start: Int32(start), end: Int32(i), scope: Int32(start))
  }

  /// What a name's site is as a value.
  func siteType(_ site: Site, unitIndex: Int32) -> Ty {
    switch site {
    case .decl(let ref):
      return valueType(of: ref)
    case .local(let holder, let token):
      let unit = project.units[Int(holder)]
      if let body = body(unitIndex: holder, token: token), let index = body.byToken[token] {
        return localType(unitIndex: holder, body: body, index: index)
      }
      // A parameter the site map knows: its declaration's.
      for item in unit.decls where item.paramCount > 0 {
        for p in 0..<Int(item.paramCount) where unit.params[Int(item.paramStart) + p].nameToken == token {
          let param = unit.params[Int(item.paramStart) + p]
          return parseType(unitIndex: holder, start: param.typeStart, end: param.typeEnd, scope: token)
        }
      }
      return .unknown
    case .generic(let holder, let token):
      return .meta(.param(project.units[Int(holder)].hash(Int(token)), nil))
    case .module(let moduleName):
      return .module(moduleName)
    }
  }

  /// A call's result: a function's results, a conversion's type, a builtin's.
  private func callResult(_ callee: Ty, unitIndex: Int32, open: Int, close: Int) -> Ty {
    switch callee {
    case .meta(let inner):
      return inner
    case .function(_, let result):
      // The universe's functions are typed by their arguments: `make([]T, n)` is a []T.
      if let builtin = builtinCall(unitIndex: unitIndex, open: open, close: close) { return builtin }
      if case .tuple(let items, _) = result, items.isEmpty { return .unknown }
      return result
    case .nominal(let ref, _):
      if case .function(_, let result) = underlying(.nominal(ref, [])) { return result }
      return .unknown
    case .constructed:
      return .unknown
    default:
      return builtinCall(unitIndex: unitIndex, open: open, close: close) ?? .unknown
    }
  }

  /// `len(x)`, `make(T, n)`, `new(T)`, `append(s, …)`, `min(a, b)`: typed by their arguments.
  private func builtinCall(unitIndex: Int32, open: Int, close: Int) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    guard open > 0, unit.tokens[open - 1].kind == .identifier, !unit.isByte(open - 2, 0x2E) else { return nil }
    let word = unit.hash(open - 1)
    guard let site = lookup(word, unitIndex: unitIndex, token: Int32(open - 1)).first, case .decl(let ref) = site, isUniverse(ref) else { return nil }
    var firstEnd = open + 1
    while firstEnd < close, !unit.isByte(firstEnd, 0x2C) { firstEnd = unit.tokens[firstEnd].kind == .open ? unit.skipBalanced(firstEnd) : firstEnd + 1 }
    switch word {
    case GoWord.len, GoWord.cap, GoWord.copy: return builtinType(GoWord.int)
    case GoWord.make: return parseType(unitIndex: unitIndex, start: Int32(open + 1), end: Int32(firstEnd), scope: Int32(open))
    case GoWord.new:
      let inner = parseType(unitIndex: unitIndex, start: Int32(open + 1), end: Int32(firstEnd), scope: Int32(open))
      return .constructed(Ty.pointer, [inner])
    case GoWord.append, GoWord.min, GoWord.max:
      return expressionType(unitIndex: unitIndex, start: Int32(open + 1), end: Int32(firstEnd))
    case GoWord.real, GoWord.imag: return builtinType(GoWord.float64)
    case GoWord.complex: return builtinType(GoWord.complex128)
    case GoWord.recover: return builtinType(GoWord.any)
    default: return nil
    }
  }

  // MARK: Members

  /// A value's member: a field's type, a method's function type.
  private func memberValueType(of ty: Ty, named member: Name, unitIndex: Int32) -> Ty {
    switch ty {
    case .module(let moduleName):
      guard let ref = project.modules[moduleName]?.top[member]?.first else { return .unknown }
      return valueType(of: ref)
    case .meta(let inner):
      // `T.Method`: a function whose first parameter is the receiver.
      guard let ref = members(of: inner, named: member, from: unitIndex).first else { return .unknown }
      return memberType(ref, receiver: inner)
    default:
      guard let ref = members(of: ty, named: member, from: unitIndex).first else { return .unknown }
      return memberType(ref, receiver: ty)
    }
  }

  /// A member's type with the receiver's type arguments put in.
  func memberType(_ ref: DeclRef, receiver: Ty) -> Ty {
    let raw = valueType(of: ref)
    guard case .nominal(let owner, let args) = dereferenced(receiver), !args.isEmpty else { return raw }
    // The names the member uses for the receiver's parameters: the type's own, or the method's receiver's.
    let item = decl(ref)
    let holder = unit(ref)
    var names: [Name] = []
    let source: Decl = item.parent >= 0 ? holder.decls[Int(item.parent)] : decl(owner)
    let generics = source.kind == .extensionDecl || item.parent >= 0 ? source : decl(owner)
    for g in 0..<Int(generics.genericCount) { names.append(holder.generics[Int(generics.genericStart) + g].name) }
    var map: [Name: Ty] = [:]
    for (index, name) in names.enumerated() where index < args.count { map[name] = args[index] }
    return substitute(raw, map)
  }

  func substitute(_ ty: Ty, _ map: [Name: Ty]) -> Ty {
    guard !map.isEmpty else { return ty }
    switch ty {
    case .param(let name, _): return map[name] ?? ty
    case .nominal(let ref, let args): return .nominal(ref, args.map { substitute($0, map) })
    case .constructed(let kind, let args): return .constructed(kind, args.map { substitute($0, map) })
    case .function(let params, let result): return .function(params.map { substitute($0, map) }, substitute(result, map))
    case .tuple(let items, let labels): return .tuple(items.map { substitute($0, map) }, labels)
    case .meta(let inner): return .meta(substitute(inner, map))
    default: return ty
    }
  }

  /// Members of a type named so: its fields and methods, or what an embedded field promotes, the shallowest.
  func members(of ty: Ty, named member: Name, from unitIndex: Int32) -> [DeclRef] {
    var base = dereferenced(ty)
    if case .param = base { return [] }
    guard case .nominal(let ref, _) = base else { return [] }
    var found = memberTable(of: ref)[member] ?? []
    if found.isEmpty {
      // A defined type over a struct or an interface has its fields or methods (not its methods).
      base = underlying(base)
      if case .nominal(let inner, _) = base, inner != ref {
        found = (memberTable(of: inner)[member] ?? []).filter { decl($0).parent >= 0 && unit($0).decls[Int(decl($0).parent)].kind != .extensionDecl }
      }
    }
    // Unexported members are their package's.
    return found.filter { isExported(decl($0).name, $0) || isSamePackage($0.unit, unitIndex) }
  }

  func isExported(_ word: Name, _ ref: DeclRef) -> Bool {
    let holder = unit(ref)
    let token = decl(ref).nameToken
    guard token >= 0, Int(token) < holder.tokens.count else { return false }
    let first = holder.source.text[holder.tokens[Int(token)].start]
    return first >= 0x41 && first <= 0x5A || isUniverse(ref)
  }

  func isStruct(_ ty: Ty) -> Bool {
    guard case .nominal(let ref, _) = underlying(dereferenced(ty)) else { return false }
    let item = decl(ref)
    return item.kind == .structure && item.bodyOpen >= 0
  }

  /// The table of a named type's members: its own (fields, interface methods, methods in its package) by name, then
  /// what embedded fields and interfaces promote, each name only from the shallowest depth that has it.
  func memberTable(of ref: DeclRef) -> [Name: [DeclRef]] {
    if let known = tables[ref] { return known }
    guard building.insert(ref).inserted else { return [:] }
    defer { building.remove(ref) }
    let item = decl(ref)
    if item.kind == .typeAlias {
      if case .nominal(let target, _) = aliasTarget(ref) {
        let table = memberTable(of: target)
        tables[ref] = table
        return table
      }
      return [:]
    }
    let holder = unit(ref)
    var table: [Name: [DeclRef]] = [:]
    for child in holder.children(of: ref.decl) {
      let entry = holder.decls[Int(child)]
      guard entry.kind == .variable || entry.kind == .function, entry.name != 0 else { continue }
      table[entry.name, default: []].append(DeclRef(unit: ref.unit, decl: child))
    }
    if item.name != 0 {
      for candidate in project.extensions[item.name] ?? [] where isSamePackage(candidate.unit, ref.unit) {
        let owner = unit(candidate)
        for child in owner.children(of: candidate.decl) where owner.decls[Int(child)].kind == .function {
          table[owner.decls[Int(child)].name, default: []].append(DeclRef(unit: candidate.unit, decl: child))
        }
      }
    }
    // Promoted: from embedded fields (a struct) or embedded interfaces, one depth at a time.
    var promoted: [Name: [DeclRef]] = [:]
    for r in 0..<Int(item.inheritCount) {
      let range = holder.ranges[Int(item.inheritStart) + r]
      let embedded = dereferenced(parseType(unitIndex: ref.unit, start: range.start, end: range.end, scope: item.nameToken))
      guard case .nominal(let inner, _) = embedded else { continue }
      for (member, list) in memberTable(of: inner) where table[member] == nil {
        promoted[member, default: []].append(contentsOf: list)
      }
      // `type X Y` embedded: Y's fields too.
      if decl(inner).kind == .structure, decl(inner).bodyOpen < 0, case .nominal(let base, _) = underlying(.nominal(inner, [])), base != inner {
        for (member, list) in memberTable(of: base) where table[member] == nil && promoted[member] == nil {
          promoted[member, default: []].append(contentsOf: list.filter { unit($0).decls[Int(decl($0).parent)].kind != .extensionDecl })
        }
      }
    }
    for (member, list) in promoted where table[member] == nil {
      var unique: [DeclRef] = []
      for entry in list where !unique.contains(entry) { unique.append(entry) }
      table[member] = unique
    }
    tables[ref] = table
    return table
  }

  /// A composite literal's type: written before its `{`, or the element type of the literal it's inside.
  func compositeType(unitIndex: Int32, open: Int32, body: GoBody) -> Ty {
    guard let entry = body.composites[open] else { return .unknown }
    if entry.start >= 0 {
      return parseType(unitIndex: unitIndex, start: entry.start, end: entry.end, scope: open)
    }
    let outer = compositeType(unitIndex: unitIndex, open: -1 - entry.start, body: body)
    switch underlying(outer) {
    case .constructed(let kind, let args):
      let element = kind == Ty.map ? args[1] : args[0]
      return dereferenced(element)
    default:
      return .unknown
    }
  }

  /// The type of the operand left of a `.`: the expression that ends there.
  func operandType(unitIndex: Int32, dot: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let start = expressionStart(unit, before: dot)
    guard start < dot else { return .unknown }
    var i = start
    return postfixType(unitIndex: unitIndex, start: &i, end: dot, commaOK: false)
  }

  /// Walking back from just before `end`: names, `.`, and brackets with what they hold, as far as one operand goes.
  func expressionStart(_ unit: Unit, before end: Int) -> Int {
    var i = end - 1
    while i >= 0 {
      let token = unit.tokens[i]
      if token.kind == .close {
        guard let open = unit.matchingOpen(i) else { return i + 1 }
        i = open
        // A call's or index's operand comes before it; `(x)` stands alone.
        if i > 0, unit.tokens[i - 1].kind == .identifier || unit.tokens[i - 1].kind == .close || unit.isByte(i - 1, 0x2E) || unit.tokens[i - 1].kind == .keyword && !isStatementWord(unit, i - 1) {
          if unit.isByte(i - 1, 0x2E) {
            i -= 2
            if i >= 0, unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .close { continue }
            return i + 1
          }
          i -= 1
          continue
        }
        // `[]T{…}`, `map[K]V{…}`: the type before the braces.
        return i
      }
      if token.kind == .identifier || token.kind == .number || token.kind == .string || (token.kind == .keyword && !isStatementWord(unit, i)) {
        if i > 0, unit.isByte(i - 1, 0x2E) {
          i -= 2
          continue
        }
        return i
      }
      return i + 1
    }
    return 0
  }

  private func isStatementWord(_ unit: Unit, _ i: Int) -> Bool {
    for word: StaticString in ["return", "if", "for", "switch", "case", "go", "defer", "range", "else", "select", "var", "const"] where unit.isToken(i, word) { return true }
    return false
  }
}
