import CodeModel
import CodeScan
import Foundation

/// A value as an expression gives it: its type, and the functions it names when it's called (a method's overloads, with
/// the receiver's type arguments).
struct TSOperand {
  var ty: Ty
  var callees: [(ref: DeclRef, env: [Name: Ty])] = []

  static let unknown = TSOperand(ty: .unknown)
}

private let utilityPassThrough: Set<Name> = [
  TSWord.Partial, TSWord.Required, TSWord.Readonly, TSWord.NonNullable, TSWord.Pick, TSWord.Omit, TSWord.Exclude, TSWord.Extract,
]
private let iterables: Set<Name> = [
  TSWord.Array, TSWord.ReadonlyArray, TSWord.Set, name("ReadonlySet"), TSWord.Iterable, TSWord.IterableIterator, name("Iterator"),
  TSWord.AsyncIterable, name("AsyncIterableIterator"), TSWord.Generator, TSWord.AsyncGenerator, name("ArrayLike"), name("ArrayIterator"),
  name("SetIterator"), name("NodeListOf"), name("HTMLCollectionOf"),
]
private let controlWords: Set<Name> = Set(
  ["if", "while", "for", "switch", "catch", "return", "typeof", "await", "void", "delete", "throw", "case", "in", "of", "instanceof", "yield", "else", "do", "function"]
    .map { name($0) })

extension TSModel {
  // MARK: Types written

  /// The type written from `start` to `end`, generic parameters taken from `env`.
  func parseType(_ unitIndex: Int32, _ start: Int, _ end: Int, env: [Name: Ty]) -> Ty {
    depth += 1
    defer { depth -= 1 }
    guard depth < 40, start >= 0, start < end else { return .unknown }
    let unit = project.units[Int(unitIndex)]
    var s = start
    while s < end, unit.isByte(s, 0x7C) || unit.isByte(s, 0x26) { s += 1 }
    guard s < end else { return .unknown }
    // `(a: A) => R`, `new (…) => R`, `<T>(…) => R`.
    var conditional = false
    var arrow = -1
    var predicate = -1
    var i = s
    var angles = 0
    while i < end {
      let kind = unit.tokens[i].kind
      if kind == .open || kind == .interpolationOpen {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.isByte(i, 0x3C) {
        angles += 1
      } else if case let n = unit.tsCloseAngles(i), n > 0 {
        angles = max(0, angles - n)
      } else if angles == 0 {
        if unit.isToken(i, "=>") {
          arrow = i
          break
        }
        if unit.isToken(i, "extends") { conditional = true }
        if unit.isToken(i, "is"), i > s { predicate = i }
      }
      i += 1
    }
    if arrow >= 0 {
      var open = s
      if unit.isToken(open, "new") || unit.isToken(open, "abstract") { return .unknown }
      if unit.isByte(open, 0x3C) { open = unit.tsSkipAngles(open, limit: arrow) }
      var params: [Ty] = []
      if unit.isByte(open, 0x28) {
        let close = unit.skipBalanced(open) - 1
        var k = open + 1
        while k < close {
          let itemEnd = unit.tsListItemEnd(k, limit: close)
          var colon = k
          while colon < itemEnd, !unit.isByte(colon, 0x3A), !unit.isToken(colon, "?:") {
            colon = unit.tokens[colon].kind == .open ? unit.skipBalanced(colon) : colon + 1
          }
          if !unit.isToken(k, "this") {
            let rest = unit.isToken(k, "...")
            var ty = colon < itemEnd ? parseType(unitIndex, colon + 1, itemEnd, env: env) : .unknown
            if rest { ty = elementType(ty) }
            params.append(ty)
          }
          k = itemEnd + 1
        }
      }
      return .function(params, parseType(unitIndex, arrow + 1, end, env: env))
    }
    if predicate >= 0 { return globalType(TSWord.Boolean) }
    if conditional {
      // `T extends X ? A : B`: either branch; the first that's known.
      return .unknown
    }
    let unions = split(unit, s, end, byte: 0x7C)
    if unions.count > 1 {
      var kept: [Ty] = []
      for part in unions where !isNullish(unit, part.0, part.1) {
        let ty = parseType(unitIndex, part.0, part.1, env: env)
        if !kept.contains(ty) { kept.append(ty) }
      }
      if kept.count == 1 { return kept[0] }
      return kept.isEmpty ? .unknown : .constructed(Ty.union, kept)
    }
    let intersections = split(unit, s, end, byte: 0x26)
    if intersections.count > 1 {
      return .constructed(Ty.intersection, intersections.map { parseType(unitIndex, $0.0, $0.1, env: env) })
    }
    // Prefixes.
    if unit.isToken(s, "keyof") { return globalType(TSWord.String) }
    if unit.isToken(s, "readonly") || unit.isToken(s, "unique") || unit.isToken(s, "asserts") { return parseType(unitIndex, s + 1, end, env: env) }
    if unit.isToken(s, "infer") { return .unknown }
    if unit.isToken(s, "typeof") {
      let at = postfixStart(unit, s + 1, end)
      var ty = expression(unitIndex, s + 1, at).ty
      ty = typePostfix(unitIndex, ty, at, end, env: env)
      return ty
    }
    // The primary, then `[]` and `[K]`.
    let primaryEnd = postfixStart(unit, s, end)
    var ty = primaryType(unitIndex, s, primaryEnd, env: env)
    ty = typePostfix(unitIndex, ty, primaryEnd, end, env: env)
    return ty
  }

  /// `T[]`, `T[K]` after a type.
  private func typePostfix(_ unitIndex: Int32, _ base: Ty, _ from: Int, _ end: Int, env: [Name: Ty]) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var ty = base
    var i = from
    while i < end, unit.isByte(i, 0x5B) {
      let close = unit.skipBalanced(i) - 1
      if close == i + 1 {
        ty = globalType(TSWord.Array, [ty])
      } else if close == i + 2, unit.tokens[i + 1].kind == .string {
        ty = memberType(ty, name(unit.tsStringValue(i + 1)), from: unitIndex)
      } else {
        ty = elementType(ty)
      }
      i = close + 1
    }
    return ty
  }

  /// Where a type's primary ends: past a word path and its type arguments, or a bracketed group.
  private func postfixStart(_ unit: Unit, _ s: Int, _ end: Int) -> Int {
    var i = s
    if unit.tokens[i].kind == .open { return unit.skipBalanced(i) }
    if unit.isToken(i, "import"), unit.isByte(i + 1, 0x28) { i = unit.skipBalanced(i + 1) } else { i += 1 }
    while i < end {
      if unit.isByte(i, 0x2E), unit.tsIsWord(i + 1) {
        i += 2
      } else if unit.isByte(i, 0x3C) {
        let close = unit.tsSkipAngles(i, limit: end)
        if close <= i { break }
        i = close
      } else {
        break
      }
    }
    return min(i, end)
  }

  /// Parts at depth 0 split by a one-byte operator.
  private func split(_ unit: Unit, _ s: Int, _ end: Int, byte: UInt8) -> [(Int, Int)] {
    var parts: [(Int, Int)] = []
    var from = s
    var i = s
    var angles = 0
    while i < end {
      let kind = unit.tokens[i].kind
      if kind == .open || kind == .interpolationOpen {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.isByte(i, 0x3C) {
        angles += 1
      } else if case let n = unit.tsCloseAngles(i), n > 0 {
        angles = max(0, angles - n)
      } else if angles == 0, unit.isByte(i, byte) {
        if i > from { parts.append((from, i)) }
        from = i + 1
      }
      i += 1
    }
    if from < end { parts.append((from, end)) }
    return parts
  }

  private func isNullish(_ unit: Unit, _ s: Int, _ e: Int) -> Bool {
    e == s + 1 && (unit.isToken(s, "undefined") || unit.isToken(s, "null") || unit.isToken(s, "void") || unit.isToken(s, "never"))
  }

  /// A type's primary: a bracketed type, a literal, a name path with type arguments.
  private func primaryType(_ unitIndex: Int32, _ s: Int, _ end: Int, env: [Name: Ty]) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let token = unit.tokens[s]
    switch token.kind {
    case .open:
      let close = unit.skipBalanced(s) - 1
      if unit.isByte(s, 0x28) { return parseType(unitIndex, s + 1, close, env: env) }
      if unit.isByte(s, 0x5B) {
        var items: [Ty] = []
        var k = s + 1
        while k < close {
          let itemEnd = unit.tsListItemEnd(k, limit: close)
          var from = k
          if unit.tsIsWord(k), unit.isByte(k + 1, 0x3A) || unit.isToken(k + 1, "?:") { from = k + 2 }
          if unit.isToken(from, "...") { from += 1 }
          items.append(parseType(unitIndex, from, itemEnd, env: env))
          k = itemEnd + 1
        }
        return .tuple(items, [])
      }
      if let literal = file(unit).literals[Int32(s)] {
        if unit.children(of: literal).isEmpty { return .unknown }
        return .nominal(DeclRef(unit: unitIndex, decl: literal), [])
      }
      return .unknown
    case .string: return globalType(TSWord.String)
    case .number: return globalType(TSWord.Number)
    default: break
    }
    if unit.isByte(s, 0x2D) { return globalType(TSWord.Number) }
    guard unit.tsIsWord(s) else { return .unknown }
    // `import("m").T`.
    var sites: [Site]
    var i = s + 1
    let word = unit.hash(s)
    if unit.isToken(s, "import"), unit.isByte(s + 1, 0x28), unit.tokens[s + 2].kind == .string {
      let key = layout.resolve(unit.tsStringValue(s + 2), from: unit.path)
      i = unit.skipBalanced(s + 1)
      var item = Import(module: name(key), moduleName: key, isExported: false, isTestable: false)
      item.alias = 1
      sites = follow(item)
    } else {
      if i >= end || !unit.isByte(i, 0x2E) {
        switch word {
        case TSWord.string: return globalType(TSWord.String)
        case TSWord.number: return globalType(TSWord.Number)
        case TSWord.boolean, TSWord.trueWord, TSWord.falseWord: return globalType(TSWord.Boolean)
        case TSWord.bigint: return globalType(TSWord.BigInt)
        case TSWord.symbol: return globalType(TSWord.Symbol)
        case TSWord.object: return globalType(TSWord.Object)
        case TSWord.any, TSWord.unknown, TSWord.never, TSWord.void, TSWord.undefined, TSWord.null: return .unknown
        case TSWord.this: return env[TSWord.this] ?? .unknown
        default: break
        }
        if let bound = env[word] { return bound }
      }
      sites = lookup(word, unitIndex: unitIndex, token: Int32(s))
    }
    // `A.B.C`.
    while i + 1 < end, unit.isByte(i, 0x2E), unit.tsIsWord(i + 1) {
      sites = qualified(sites, unit.hash(i + 1), from: unitIndex)
      i += 2
    }
    var args: [Ty] = []
    if i < end, unit.isByte(i, 0x3C) {
      let close = unit.tsSkipAngles(i, limit: end)
      if close > i { args = typeArguments(unitIndex, i, close, env: env) }
    }
    return type(of: sites, args: args, word: word)
  }

  /// `<A, B>` from its `<` to past its `>`.
  func typeArguments(_ unitIndex: Int32, _ open: Int, _ after: Int, env: [Name: Ty]) -> [Ty] {
    let unit = project.units[Int(unitIndex)]
    var args: [Ty] = []
    var k = open + 1
    let close = after - 1
    while k < close {
      let itemEnd = min(unit.tsListItemEnd(k, limit: close), close)
      args.append(parseType(unitIndex, k, itemEnd, env: env))
      k = itemEnd + 1
    }
    return args
  }

  /// `A.B` from A's sites: a module's export, a namespace's or an enum's member.
  func qualified(_ sites: [Site], _ word: Name, from unitIndex: Int32) -> [Site] {
    var result: [Site] = []
    for site in sites {
      switch site {
      case .module(let moduleName):
        result += exports(moduleName)[word] ?? []
      case .decl(let ref):
        for other in merged(ref) where decl(other).kind.hasMembers {
          let holder = self.unit(other)
          for child in holder.children(of: other.decl) where holder.decls[Int(child)].name == word {
            result.append(.decl(DeclRef(unit: other.unit, decl: child)))
          }
        }
      default:
        break
      }
      if !result.isEmpty { return result }
    }
    return result
  }

  /// The type a name's sites declare.
  func type(of sites: [Site], args: [Ty], word: Name) -> Ty {
    for site in sites {
      switch site {
      case .generic(let unitIndex, let token):
        // A type parameter is its constraint, as far as members go.
        let holder = project.units[Int(unitIndex)]
        if holder.isToken(Int(token) + 1, "extends") {
          let end = holder.tsTypeEnd(Int(token) + 2, limit: holder.tokens.count)
          let constraint = parseType(unitIndex, Int(token) + 2, end, env: [:])
          if !isUnknown(constraint) { return constraint }
        }
        return .param(holder.hash(Int(token)), nil)
      case .decl(let ref):
        let item = decl(ref)
        switch item.kind {
        case .classType, .protocolType, .structure, .enumeration: return .nominal(ref, args)
        case .typeAlias: return aliasType(ref, args)
        case .enumCase: return .nominal(DeclRef(unit: ref.unit, decl: item.parent), [])
        default: continue
        }
      default:
        continue
      }
    }
    for site in sites {
      if case .decl(let ref) = site, decl(ref).kind == .namespace { return .nominal(ref, []) }
      if case .module(let moduleName) = site { return .module(moduleName) }
    }
    return .unknown
  }

  /// A type alias's type with its arguments; the lib's utility types as near as members need.
  func aliasType(_ ref: DeclRef, _ args: [Ty]) -> Ty {
    let item = decl(ref)
    if isLib(self.unit(ref)) {
      let first = args.first ?? .unknown
      if utilityPassThrough.contains(item.name) { return first }
      switch item.name {
      case TSWord.Awaited: return awaited(first)
      case TSWord.ReturnType:
        if case .function(_, let result) = first { return result }
        return .unknown
      case TSWord.InstanceType:
        if case .meta(let inner) = first { return inner }
        return .unknown
      case TSWord.Record: return .constructed(Ty.map, [first, args.count > 1 ? args[1] : .unknown])
      default: break
      }
    }
    guard item.typeStart >= 0, resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    return parseType(ref.unit, Int(item.typeStart), Int(item.typeEnd), env: genericEnv(ref, args))
  }

  func isLib(_ unit: Unit) -> Bool {
    if let lib = layout.libDirectory, unit.path.hasPrefix(lib + "/") { return true }
    return false
  }

  /// A declaration's type parameters bound to arguments.
  func genericEnv(_ ref: DeclRef, _ args: [Ty]) -> [Name: Ty] {
    guard !args.isEmpty else { return [:] }
    let item = decl(ref)
    let holder = self.unit(ref)
    var env: [Name: Ty] = [:]
    for g in 0..<min(Int(item.genericCount), args.count) { env[holder.generics[Int(item.genericStart) + g].name] = args[g] }
    return env
  }

  // MARK: Members

  /// What a type has of a name: each declaration with the type arguments its holder was given.
  func members(of ty: Ty, named word: Name, from unitIndex: Int32) -> [(site: Site, env: [Name: Ty])] {
    depth += 1
    defer { depth -= 1 }
    guard depth < 40 else { return [] }
    switch ty {
    case .module(let moduleName):
      return (exports(moduleName)[word] ?? []).map { ($0, [:]) }
    case .nominal(let ref, let args):
      return typeMembers(ref, args: args, word: word, isStatic: false, receiver: ty)
    case .meta(let inner):
      guard case .nominal(let ref, let args) = inner else { return [] }
      let found = typeMembers(ref, args: args, word: word, isStatic: true, receiver: ty)
      if !found.isEmpty || decl(ref).kind == .enumeration { return found }
      return members(of: globalType(TSWord.Function), named: word, from: unitIndex)
    case .constructed(let kind, let parts) where kind == Ty.union || kind == Ty.intersection:
      var result: [(site: Site, env: [Name: Ty])] = []
      for part in parts {
        for found in members(of: part, named: word, from: unitIndex) where !result.contains(where: { $0.site == found.site }) { result.append(found) }
      }
      return result
    case .tuple(let items, _):
      return members(of: globalType(TSWord.Array, [items.first ?? .unknown]), named: word, from: unitIndex)
    case .function:
      return members(of: globalType(TSWord.Function), named: word, from: unitIndex)
    default:
      return []
    }
  }

  private func typeMembers(_ ref: DeclRef, args: [Ty], word: Name, isStatic: Bool, receiver: Ty) -> [(site: Site, env: [Name: Ty])] {
    let item = decl(ref)
    if item.kind == .typeAlias { return members(of: aliasType(ref, args), named: word, from: ref.unit) }
    if item.kind == .enumeration, !isStatic { return members(of: globalType(TSWord.Number), named: word, from: ref.unit) }
    var result: [(site: Site, env: [Name: Ty])] = []
    let all = merged(ref)
    for other in all where decl(other).kind.hasMembers {
      let holder = self.unit(other)
      let kind = decl(other).kind
      var env = genericEnv(other, args)
      if case .meta = receiver {} else { env[TSWord.this] = receiver }
      for child in holder.children(of: other.decl) where holder.decls[Int(child)].name == word {
        let member = holder.decls[Int(child)]
        if member.kind == .initializer, member.name == TSWord.constructor { continue }
        switch kind {
        case .classType: if member.isStatic != isStatic { continue }
        case .namespace, .enumeration: if !isStatic, decl(ref).kind != .namespace { continue }
        default: if isStatic { continue }
        }
        result.append((.decl(DeclRef(unit: other.unit, decl: child)), env))
      }
    }
    if !result.isEmpty { return result }
    // Bases.
    for other in all {
      let base = decl(other)
      let env = genericEnv(other, args)
      var found: [(site: Site, env: [Name: Ty])] = []
      if base.kind == .classType, base.typeStart >= 0 {
        let parent = parseType(other.unit, Int(base.typeStart), Int(base.typeEnd), env: env)
        found = members(of: isStatic ? .meta(parent) : parent, named: word, from: other.unit)
      } else if base.kind == .protocolType || base.kind == .structure && !isStatic {
        for r in 0..<Int(base.inheritCount) {
          let range = self.unit(other).ranges[Int(base.inheritStart) + r]
          let parent = base.kind == .structure && base.initStart >= 0
            ? expression(other.unit, Int(range.start), Int(range.end)).ty
            : parseType(other.unit, Int(range.start), Int(range.end), env: env)
          found += members(of: parent, named: word, from: other.unit)
        }
      }
      if !found.isEmpty { return found }
    }
    // Everything has Object's members.
    if !isStatic, item.name != TSWord.Object, item.kind == .protocolType || item.kind == .classType || item.kind == .structure {
      return members(of: globalType(TSWord.Object), named: word, from: ref.unit)
    }
    return []
  }

  /// A member's type, the first one's.
  func memberType(_ ty: Ty, _ word: Name, from unitIndex: Int32) -> Ty {
    guard let found = members(of: ty, named: word, from: unitIndex).first else {
      // `Record<K, V>` and index signatures: any key's value.
      if case .constructed(let kind, let parts) = ty, kind == Ty.map { return parts.count > 1 ? parts[1] : .unknown }
      if case .nominal = ty, let index = members(of: ty, named: name("[]"), from: unitIndex).first, case .decl(let ref) = index.site, decl(ref).typeStart >= 0 {
        return parseType(ref.unit, Int(decl(ref).typeStart), Int(decl(ref).typeEnd), env: index.env)
      }
      return .unknown
    }
    return siteValue(found.site, env: found.env).ty
  }

  /// What a value iterates, an index into it gives.
  func elementType(_ ty: Ty) -> Ty {
    switch ty {
    case .tuple(let items, _): return items.first ?? .unknown
    case .nominal(let ref, let args):
      let word = decl(ref).name
      if iterables.contains(word) { return args.first ?? .unknown }
      if word == TSWord.Map || word == name("ReadonlyMap") { return .tuple([args.first ?? .unknown, args.count > 1 ? args[1] : .unknown], []) }
      if word == TSWord.String { return ty }
      if let index = members(of: ty, named: name("[]"), from: ref.unit).first, case .decl(let found) = index.site, decl(found).typeStart >= 0 {
        return parseType(found.unit, Int(decl(found).typeStart), Int(decl(found).typeEnd), env: index.env)
      }
      return .unknown
    case .constructed(let kind, let parts):
      if kind == Ty.map { return parts.count > 1 ? parts[1] : .unknown }
      if kind == Ty.union {
        for part in parts {
          let found = elementType(part)
          if found != .unknown { return found }
        }
      }
      return .unknown
    default:
      return .unknown
    }
  }

  /// `await`: a promise's value.
  func awaited(_ ty: Ty) -> Ty {
    switch ty {
    case .nominal(let ref, let args):
      let word = decl(ref).name
      if word == TSWord.Promise || word == TSWord.PromiseLike { return awaited(args.first ?? .unknown) }
      return ty
    case .constructed(let kind, let parts) where kind == Ty.union:
      let mapped = parts.map(awaited)
      return mapped.count == 1 ? mapped[0] : .constructed(Ty.union, mapped)
    default:
      return ty
    }
  }

  // MARK: Values

  /// What a site is as a value.
  func siteValue(_ site: Site, env: [Name: Ty]) -> TSOperand {
    switch site {
    case .decl(let ref): return declValue(ref, env: env)
    case .local(let unitIndex, let token):
      let scan = body(unitIndex)
      guard let index = scan.byToken[token] else { return .unknown }
      return localValue(unitIndex, index)
    case .module(let moduleName): return TSOperand(ty: .module(moduleName))
    case .generic: return .unknown
    }
  }

  /// The value of the first site that is one (a variable before an interface of its name).
  func value(of sites: [Site]) -> TSOperand {
    for site in sites {
      if case .decl(let ref) = site {
        switch decl(ref).kind {
        case .protocolType, .typeAlias: continue
        case .function:
          let overloads = sites.compactMap { site -> DeclRef? in
            if case .decl(let other) = site, decl(other).kind == .function { return other }
            return nil
          }
          return TSOperand(ty: .function([], .unknown), callees: overloads.map { ($0, [:]) })
        default: break
        }
      }
      return siteValue(site, env: [:])
    }
    return .unknown
  }

  /// A declaration's value: a variable's type, a function to call, a class's or enum's static side.
  func declValue(_ ref: DeclRef, env: [Name: Ty]) -> TSOperand {
    let item = decl(ref)
    let holder = self.unit(ref)
    switch item.kind {
    case .variable:
      if item.bodyOpen >= 0 { return TSOperand(ty: returnType(ref, env: env)) }
      if item.typeStart >= 0 { return TSOperand(ty: parseType(ref.unit, Int(item.typeStart), Int(item.typeEnd), env: env)) }
      if let known = valueTypes[ref] { return TSOperand(ty: known) }
      guard resolving.insert(ref).inserted else { return .unknown }
      defer { resolving.remove(ref) }
      let facts = file(holder)
      var ty = Ty.unknown
      if facts.shorthand.contains(ref.decl) {
        ty = value(of: lookup(item.name, unitIndex: ref.unit, token: item.nameToken)).ty
      } else if let literal = facts.literals[item.initStart], item.initStart >= 0, holder.decls[Int(literal)].parent == ref.decl || item.name == 0 {
        ty = .nominal(DeclRef(unit: ref.unit, decl: literal), [])
      } else if item.initStart >= 0 {
        ty = expression(ref.unit, Int(item.initStart), Int(item.initEnd)).ty
        if let steps = facts.patterns[ref.decl] { ty = apply(steps, to: ty, from: ref.unit) }
      }
      valueTypes[ref] = ty
      return TSOperand(ty: ty)
    case .function:
      let overloads = merged(ref).filter { decl($0).kind == .function }
      return TSOperand(ty: .function([], .unknown), callees: (overloads.isEmpty ? [ref] : overloads).map { ($0, env) })
    case .classType, .enumeration: return TSOperand(ty: .meta(.nominal(ref, [])))
    case .namespace, .structure: return TSOperand(ty: .nominal(ref, []))
    case .enumCase: return TSOperand(ty: .nominal(DeclRef(unit: ref.unit, decl: item.parent), []))
    default: return .unknown
    }
  }

  /// A local's value, kept once read.
  func localValue(_ unitIndex: Int32, _ index: Int32) -> TSOperand {
    let scan = body(unitIndex)
    let local = scan.locals[Int(index)]
    if case .declaration(let declIndex) = local.kind { return declValue(DeclRef(unit: unitIndex, decl: declIndex), env: [:]) }
    if let known = scan.types[local.token] { return TSOperand(ty: known) }
    guard scan.resolving.insert(local.token).inserted else { return .unknown }
    defer { scan.resolving.remove(local.token) }
    let ty = localType(unitIndex, local)
    scan.types[local.token] = ty
    return TSOperand(ty: ty)
  }

  /// A local's type from how it's declared, then the steps that destructure it.
  func localType(_ unitIndex: Int32, _ local: TSLocal) -> Ty {
    var ty: Ty
    switch local.kind {
    case .typed(let start, let end): ty = parseType(unitIndex, Int(start), Int(end), env: [:])
    case .value(let start, let end): ty = expression(unitIndex, Int(start), Int(end)).ty
    case .parameter(let function, let index): ty = contextualParameter(unitIndex, key: function, index: index)
    case .iterated(let start, let end):
      ty = elementType(expression(unitIndex, Int(start), Int(end)).ty)
    case .key: ty = globalType(TSWord.String)
    case .declaration(let declIndex): return declValue(DeclRef(unit: unitIndex, decl: declIndex), env: [:]).ty
    case .unknown: ty = .unknown
    }
    return apply(local.steps, to: ty, from: unitIndex)
  }

  func apply(_ steps: [TSStep], to base: Ty, from unitIndex: Int32) -> Ty {
    var ty = base
    for step in steps {
      switch step {
      case .member(let word): ty = memberType(ty, word, from: unitIndex)
      case .element(let index):
        if case .tuple(let items, _) = ty { ty = index < items.count ? items[index] : .unknown } else { ty = elementType(ty) }
      case .rest: break
      }
      if ty == .unknown { break }
    }
    return ty
  }

  // MARK: Calls

  /// Whether a function's parameters take `count` arguments.
  func fits(_ ref: DeclRef, _ count: Int) -> Bool {
    let item = decl(ref)
    let holder = self.unit(ref)
    var required = 0
    for p in 0..<Int(item.paramCount) {
      let param = holder.params[Int(item.paramStart) + p]
      if param.variadic { return count >= required }
      let optional = param.hasDefault || param.nameToken >= 0 && (holder.isByte(Int(param.nameToken) + 1, 0x3F) || holder.isToken(Int(param.nameToken) + 1, "?:"))
      if !optional { required += 1 }
    }
    return count >= required && count <= Int(item.paramCount)
  }

  /// The overload a call with `count` arguments takes.
  func overload(_ callees: [(ref: DeclRef, env: [Name: Ty])], count: Int, arguments args: [(Int, Int)] = [], in unitIndex: Int32 = -1) -> (ref: DeclRef, env: [Name: Ty])? {
    let fitting = callees.filter { fits($0.ref, count) }
    let typed = unitIndex >= 0 && fitting.count > 1 ? fitting.filter { argumentsFit($0.ref, args, in: unitIndex) } : fitting
    let pool = typed.isEmpty ? fitting : typed
    return pool.first { decl($0.ref).typeStart >= 0 || decl($0.ref).bodyOpen >= 0 } ?? pool.first ?? callees.first
  }

  /// What can be told cheaply about whether arguments suit a signature: none goes to `never`, and a `true` or `false`
  /// (alone, or as an object literal's property) goes where that literal type, or `boolean`, is written.
  func argumentsFit(_ ref: DeclRef, _ args: [(Int, Int)], in unitIndex: Int32) -> Bool {
    let item = decl(ref)
    let holder = self.unit(ref)
    let unit = project.units[Int(unitIndex)]
    for (position, arg) in args.enumerated() where position < Int(item.paramCount) {
      let param = holder.params[Int(item.paramStart) + position]
      guard param.typeStart >= 0, !param.variadic else { continue }
      let ts = Int(param.typeStart)
      if param.typeEnd == param.typeStart + 1, holder.isToken(ts, "never") { return false }
      if arg.1 == arg.0 + 1, let literal = booleanLiteral(unit, arg.0), let written = booleanLiteral(holder, ts), param.typeEnd == param.typeStart + 1, literal != written {
        return false
      }
      if isPredicate(holder, ts, Int(param.typeEnd)), let guarded = arrowIsPredicate(unit, arg.0, arg.1), !guarded { return false }
      if unit.isByte(arg.0, 0x7B), let literal = file(unit).literals[Int32(arg.0)] {
        let expected = parseType(ref.unit, ts, Int(param.typeEnd), env: [:])
        for child in unit.children(of: literal) {
          let property = unit.decls[Int(child)]
          guard property.initStart >= 0, property.initEnd == property.initStart + 1, let value = booleanLiteral(unit, Int(property.initStart)) else { continue }
          guard let found = members(of: expected, named: property.name, from: unitIndex).first, case .decl(let member) = found.site else { continue }
          let written = decl(member)
          if written.typeEnd == written.typeStart + 1, let wanted = booleanLiteral(self.unit(member), Int(written.typeStart)), wanted != value { return false }
        }
      }
    }
    return true
  }

  /// A function type whose result is a type predicate: `(value: T) => value is S`.
  private func isPredicate(_ unit: Unit, _ start: Int, _ end: Int) -> Bool {
    var k = start
    while k + 2 < end {
      if unit.isToken(k, "=>"), unit.tsIsName(k + 1), unit.isToken(k + 2, "is") { return true }
      k += 1
    }
    return false
  }

  /// Whether an arrow function or function expression argument declares a type predicate; nil when it isn't one.
  private func arrowIsPredicate(_ unit: Unit, _ start: Int, _ end: Int) -> Bool? {
    var k = start
    if unit.isToken(k, "async") { k += 1 }
    if unit.isToken(k, "function") {
      while k < end, !unit.isByte(k, 0x28) { k += 1 }
      guard k < end else { return nil }
      let close = unit.skipBalanced(k)
      return unit.isByte(close, 0x3A) && unit.isToken(close + 2, "is")
    }
    if unit.isByte(k, 0x28) {
      let close = unit.skipBalanced(k)
      if unit.isToken(close, "=>") { return false }
      if unit.isByte(close, 0x3A) {
        var j = close + 1
        while j < end, !unit.isToken(j, "=>") {
          if unit.isToken(j, "is") { return true }
          j += 1
        }
        return j < end ? false : nil
      }
      return nil
    }
    if unit.tsIsName(k), unit.isToken(k + 1, "=>") { return false }
    return nil
  }

  private func booleanLiteral(_ unit: Unit, _ token: Int) -> Bool? {
    if unit.isToken(token, "true") { return true }
    if unit.isToken(token, "false") { return false }
    return nil
  }

  /// The arguments of a call from its `(`: each one's tokens.
  func arguments(_ unit: Unit, open: Int) -> [(Int, Int)] {
    let close = unit.skipBalanced(open) - 1
    var result: [(Int, Int)] = []
    var k = open + 1
    while k < close {
      let itemEnd = unit.tsListItemEnd(k, limit: close)
      result.append((k, itemEnd))
      k = itemEnd + 1
    }
    return result
  }

  /// What a call gives: the overload's result with its type parameters inferred from plain arguments.
  func call(_ op: TSOperand, unitIndex: Int32, open: Int, explicit: [Ty]) -> TSOperand {
    let unit = project.units[Int(unitIndex)]
    let args = arguments(unit, open: open)
    if let pick = overload(op.callees, count: args.count, arguments: args, in: unitIndex) {
      var env = pick.env
      let item = decl(pick.ref)
      let holder = self.unit(pick.ref)
      for g in 0..<Int(item.genericCount) {
        let generic = holder.generics[Int(item.genericStart) + g]
        if g < explicit.count { env[generic.name] = explicit[g] }
      }
      if explicit.isEmpty, item.genericCount > 0 {
        let names = Set((0..<Int(item.genericCount)).map { holder.generics[Int(item.genericStart) + $0].name })
        for p in 0..<min(Int(item.paramCount), args.count) {
          let param = holder.params[Int(item.paramStart) + p]
          guard param.typeStart >= 0 else { continue }
          let ts = Int(param.typeStart)
          if param.typeEnd == param.typeStart + 1, names.contains(holder.hash(ts)), env[holder.hash(ts)] == nil {
            env[holder.hash(ts)] = expression(unitIndex, args[p].0, args[p].1).ty
          } else if param.typeEnd == param.typeStart + 3, names.contains(holder.hash(ts)), holder.isByte(ts + 1, 0x5B), env[holder.hash(ts)] == nil {
            env[holder.hash(ts)] = elementType(expression(unitIndex, args[p].0, args[p].1).ty)
          }
        }
      }
      return TSOperand(ty: returnType(pick.ref, env: env))
    }
    switch op.ty {
    case .function(_, let result): return TSOperand(ty: result)
    case .nominal, .constructed:
      let signatures = members(of: op.ty, named: TSWord.call, from: unitIndex).compactMap { found -> (ref: DeclRef, env: [Name: Ty])? in
        if case .decl(let ref) = found.site { return (ref, found.env) }
        return nil
      }
      guard !signatures.isEmpty else { return .unknown }
      return call(TSOperand(ty: .unknown, callees: signatures), unitIndex: unitIndex, open: open, explicit: explicit)
    default:
      return .unknown
    }
  }

  /// `new X(…)`.
  func construct(_ op: TSOperand, explicit: [Ty], unitIndex: Int32, open: Int) -> Ty {
    switch op.ty {
    case .meta(.nominal(let ref, _)): return .nominal(ref, explicit)
    case .nominal, .constructed:
      let signatures = members(of: op.ty, named: TSWord.construct, from: unitIndex)
      let count = open >= 0 ? arguments(project.units[Int(unitIndex)], open: open).count : 0
      let fitting = signatures.filter { found in
        guard case .decl(let ref) = found.site else { return false }
        return Int(decl(ref).genericCount) >= explicit.count && fits(ref, count)
      }
      guard let found = fitting.first ?? signatures.first, case .decl(let ref) = found.site else { return .unknown }
      var env = found.env
      let item = decl(ref)
      for g in 0..<min(Int(item.genericCount), explicit.count) { env[self.unit(ref).generics[Int(item.genericStart) + g].name] = explicit[g] }
      return returnType(ref, env: env)
    default:
      return .unknown
    }
  }

  /// A function's result: as written, else what its body returns (a promise of it when `async`).
  func returnType(_ ref: DeclRef, env: [Name: Ty]) -> Ty {
    let item = decl(ref)
    if item.typeStart >= 0 {
      let written = parseType(ref.unit, Int(item.typeStart), Int(item.typeEnd), env: env)
      return written
    }
    if item.kind == .initializer { return .unknown }
    guard item.bodyOpen >= 0 else { return .unknown }
    if let known = returnTypes[ref] { return known }
    guard resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    let holder = self.unit(ref)
    var ty = returned(ref.unit, bodyOpen: Int(item.bodyOpen), bodyClose: Int(item.bodyClose))
    var k = Int(item.first)
    while k < Int(item.nameToken) {
      if holder.isToken(k, "async") { ty = globalType(TSWord.Promise, [ty]) }
      k += 1
    }
    returnTypes[ref] = ty
    return ty
  }

  /// What a body's `return`s give, the first one that's known.
  func returned(_ unitIndex: Int32, bodyOpen: Int, bodyClose: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let scan = body(unitIndex)
    let own = scan.function(at: Int32(bodyOpen + 1))
    var i = bodyOpen + 1
    while i < bodyClose {
      if unit.isToken(i, "return"), !unit.startsLine(i + 1), !unit.isByte(i + 1, 0x3B), !unit.isByte(i + 1, 0x7D) {
        let inner = scan.function(at: Int32(i))
        if inner?.paramsOpen == own?.paramsOpen {
          let end = unit.tsExpressionEnd(i + 1, limit: bodyClose, commaEnds: false)
          let ty = expression(unitIndex, i + 1, end).ty
          if !isUnknown(ty) { return ty }
          i = end
          continue
        }
      }
      i += 1
    }
    return .unknown
  }

  /// A function written as a value: `.function` of its parameters' types and its result.
  func functionValue(_ unitIndex: Int32, key: Int32) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let scan = body(unitIndex)
    guard let fn = scan.functions[key] else { return .unknown }
    var params: [Ty] = []
    if fn.paramsOpen != fn.paramsClose {
      for (start, end) in arguments(unit, open: Int(fn.paramsOpen)) {
        var colon = start
        while colon < end, !unit.isByte(colon, 0x3A), !unit.isToken(colon, "?:") { colon = unit.tokens[colon].kind == .open ? unit.skipBalanced(colon) : colon + 1 }
        params.append(colon < end ? parseType(unitIndex, colon + 1, unit.tsTypeEnd(colon + 1, limit: end), env: [:]) : .unknown)
      }
    } else {
      params = [.unknown]
    }
    var result = Ty.unknown
    let after = Int(fn.paramsClose) + 1
    if fn.paramsOpen != fn.paramsClose, unit.isByte(after, 0x3A) {
      let end = unit.tsTypeEnd(after + 1, limit: Int(fn.bodyEnd), arrowEnds: true)
      result = parseType(unitIndex, after + 1, end, env: [:])
    } else if unit.isByte(Int(fn.bodyStart), 0x7B) {
      result = returned(unitIndex, bodyOpen: Int(fn.bodyStart), bodyClose: Int(fn.bodyEnd) - 1)
    } else {
      result = expression(unitIndex, Int(fn.bodyStart), Int(fn.bodyEnd)).ty
    }
    return .function(params, result)
  }

  // MARK: Expressions

  /// The type of the expression before a `.`.
  func operandType(_ unitIndex: Int32, dot: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard dot > 0 else { return .unknown }
    let start = expressionStart(unit, last: dot - 1)
    return expression(unitIndex, start, dot).ty
  }

  /// Where the expression ending at `last` (inclusive) starts: back over members, calls and indexes.
  func expressionStart(_ unit: Unit, last: Int) -> Int {
    var i = last
    while i >= 0 {
      let kind = unit.tokens[i].kind
      if kind == .close {
        guard let open = unit.matchingOpen(i) else { return i }
        if unit.isByte(open, 0x7B) { return open }
        var before = open - 1
        if before >= 0, unit.tsCloseAngles(before) > 0 {
          // `f<T>(…)`.
          var angles = 0
          var k = before
          while k >= 0 {
            if unit.tsCloseAngles(k) > 0 { angles += unit.tsCloseAngles(k) } else if unit.isByte(k, 0x3C) {
              angles -= 1
              if angles == 0 { break }
            } else if unit.tokens[k].kind == .close, let inner = unit.matchingOpen(k) {
              k = inner
            }
            k -= 1
          }
          before = k - 1
        }
        if before >= 0, unit.tsIsWord(before) && !controlWords.contains(unit.hash(before)) || unit.tokens[before].kind == .close {
          i = before
          continue
        }
        if before >= 0, unit.isToken(before, "?.") {
          i = before - 1
          continue
        }
        i = open
        break
      }
      if unit.tsIsWord(i) || kind == .string || kind == .number {
        if i > 1, unit.tsIsDot(i - 1) || unit.isToken(i - 1, ".#") {
          i -= 2
          continue
        }
        if i > 2, unit.isByte(i - 1, 0x23), unit.tsIsDot(i - 2) {
          i -= 3
          continue
        }
        break
      }
      break
    }
    if i > 0, unit.isToken(i - 1, "new") { i -= 1 }
    return max(i, 0)
  }

  /// An expression's value from `start` to `end`.
  func expression(_ unitIndex: Int32, _ start: Int, _ end: Int) -> TSOperand {
    depth += 1
    defer { depth -= 1 }
    guard depth < 40, start >= 0, start < end else { return .unknown }
    let unit = project.units[Int(unitIndex)]
    var comma = -1, assign = -1, arrow = -1, question = -1, nullish = -1, and = -1, compare = -1, plus = -1, arith = -1, asToken = -1, satisfies = -1
    var i = start
    scan: while i < end {
      let token = unit.tokens[i]
      if token.kind == .open || token.kind == .interpolationOpen {
        i = unit.skipBalanced(i)
        continue
      }
      if token.kind == .punctuation {
        if unit.isByte(i, 0x3C), let after = unit.tsTypeArgumentsEnd(i, limit: end) {
          i = after
          continue
        }
        if unit.isToken(i, "=>") {
          arrow = i
          break scan
        }
        if unit.isByte(i, 0x2C) {
          comma = i
        } else if unit.isByte(i, 0x3D) || isCompoundAssignment(unit, i) {
          if assign < 0 { assign = i }
        } else if unit.isByte(i, 0x3F) {
          if question < 0 { question = i }
        } else if unit.isToken(i, "??") || unit.isToken(i, "||") {
          if nullish < 0 { nullish = i }
        } else if unit.isToken(i, "&&") {
          if and < 0 { and = i }
        } else if unit.isToken(i, "===") || unit.isToken(i, "!==") || unit.isToken(i, "==") || unit.isToken(i, "!=") || unit.isByte(i, 0x3C)
          || unit.tsCloseAngles(i) == 1 || unit.isToken(i, "<=") || unit.isToken(i, ">=")
        {
          if compare < 0, i > start { compare = i }
        } else if i > start, unit.tsEndsExpression(i - 1) {
          if unit.isByte(i, 0x2B) {
            plus = i
          } else if unit.isByte(i, 0x2D) || unit.isByte(i, 0x2A) || unit.isByte(i, 0x2F) || unit.isByte(i, 0x25) || unit.isToken(i, "**") || unit.isByte(i, 0x7C)
            || unit.isByte(i, 0x26) || unit.isByte(i, 0x5E) || unit.isToken(i, "<<") || unit.tsCloseAngles(i) > 1
          {
            arith = i
          }
        }
      } else if i > start, unit.tsEndsExpression(i - 1) {
        if unit.isToken(i, "as") || unit.isToken(i, "satisfies") {
          if unit.isToken(i, "as") { asToken = i } else { satisfies = i }
          i = max(unit.tsTypeEnd(i + 1, limit: end), i + 1)
          continue
        }
        if unit.isToken(i, "instanceof") || unit.isToken(i, "in") { if compare < 0 { compare = i } }
      }
      i += 1
    }
    if comma >= 0, arrow < 0 { return expression(unitIndex, comma + 1, end) }
    if assign >= 0, arrow < 0 || assign < arrow { return expression(unitIndex, assign + 1, end) }
    if arrow >= 0 {
      var open = start
      if unit.isToken(open, "async"), open + 1 < arrow { open += 1 }
      return TSOperand(ty: functionValue(unitIndex, key: Int32(open)))
    }
    if question >= 0 {
      var colon = question + 1
      var nested = 0
      while colon < end {
        if unit.tokens[colon].kind == .open || unit.tokens[colon].kind == .interpolationOpen {
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
      let first = expression(unitIndex, question + 1, colon)
      if !isUnknown(first.ty) { return first }
      return expression(unitIndex, colon + 1, end)
    }
    if nullish >= 0 {
      let left = expression(unitIndex, start, nullish)
      if !isUnknown(left.ty) { return left }
      return expression(unitIndex, nullish + 1, end)
    }
    if and >= 0 { return expression(unitIndex, and + 1, end) }
    if compare >= 0 { return TSOperand(ty: globalType(TSWord.Boolean)) }
    if asToken >= 0 {
      if unit.isToken(asToken + 1, "const") { return expression(unitIndex, start, asToken) }
      return TSOperand(ty: parseType(unitIndex, asToken + 1, unit.tsTypeEnd(asToken + 1, limit: end), env: [:]))
    }
    if satisfies >= 0 { return expression(unitIndex, start, satisfies) }
    if plus >= 0 {
      let string = globalType(TSWord.String)
      if expression(unitIndex, plus + 1, end).ty == string || expression(unitIndex, start, plus).ty == string { return TSOperand(ty: string) }
      return TSOperand(ty: globalType(TSWord.Number))
    }
    if arith >= 0 { return TSOperand(ty: globalType(TSWord.Number)) }
    // Prefixes.
    if unit.isByte(start, 0x21) || unit.isToken(start, "delete") { return TSOperand(ty: globalType(TSWord.Boolean)) }
    if unit.isToken(start, "typeof") { return TSOperand(ty: globalType(TSWord.String)) }
    if unit.isToken(start, "void") || unit.isToken(start, "yield") { return .unknown }
    if unit.isByte(start, 0x2D) || unit.isByte(start, 0x2B) || unit.isByte(start, 0x7E) || unit.isToken(start, "++") || unit.isToken(start, "--") {
      return TSOperand(ty: globalType(TSWord.Number))
    }
    if unit.isToken(start, "await") { return TSOperand(ty: awaited(expression(unitIndex, start + 1, end).ty)) }
    if unit.isToken(start, "...") { return expression(unitIndex, start + 1, end) }
    if unit.isByte(start, 0x3C), unit.tsIsWord(start + 1) {
      // `<T>x`.
      let close = unit.tsSkipAngles(start, limit: end)
      if close > start { return TSOperand(ty: parseType(unitIndex, start + 1, close - 1, env: [:])) }
    }
    return chain(unitIndex, start, end)
  }

  private func isCompoundAssignment(_ unit: Unit, _ i: Int) -> Bool {
    let token = unit.tokens[i]
    guard token.length >= 2, unit.source.text[token.start + token.length - 1] == 0x3D else { return false }
    return !(unit.isToken(i, "==") || unit.isToken(i, "===") || unit.isToken(i, "!=") || unit.isToken(i, "!==") || unit.isToken(i, "<=") || unit.isToken(i, ">="))
  }

  /// A primary and its members, calls and indexes.
  private func chain(_ unitIndex: Int32, _ start: Int, _ end: Int) -> TSOperand {
    let unit = project.units[Int(unitIndex)]
    var i = start
    var op = TSOperand.unknown
    let token = unit.tokens[i]
    if unit.isToken(i, "new"), i + 1 < end {
      var j = i + 1
      if unit.tokens[j].kind == .open {
        j = unit.skipBalanced(j)
      } else {
        j += 1
        while j + 1 < end, unit.tsIsDot(j), unit.tsIsWord(j + 1) { j += 2 }
      }
      let callee = j > i + 1 ? chain(unitIndex, i + 1, j) : .unknown
      var explicit: [Ty] = []
      if j < end, unit.isByte(j, 0x3C) {
        let close = unit.tsSkipAngles(j, limit: end)
        if close > j {
          explicit = typeArguments(unitIndex, j, close, env: [:])
          j = close
        }
      }
      op = TSOperand(ty: construct(callee, explicit: explicit, unitIndex: unitIndex, open: j < end && unit.isByte(j, 0x28) ? j : -1))
      if j < end, unit.isByte(j, 0x28) { j = unit.skipBalanced(j) }
      i = j
    } else {
      switch token.kind {
      case .open:
        let close = unit.skipBalanced(i) - 1
        if unit.isByte(i, 0x28) {
          op = expression(unitIndex, i + 1, close)
        } else if unit.isByte(i, 0x5B) {
          let items = arguments(unit, open: i)
          var element = Ty.unknown
          for item in items {
            let ty = expression(unitIndex, item.0, item.1).ty
            if !isUnknown(ty) {
              element = unit.isToken(item.0, "...") ? elementType(ty) : ty
              break
            }
          }
          op = TSOperand(ty: globalType(TSWord.Array, [element]))
        } else if let literal = file(unit).literals[Int32(i)] {
          op = TSOperand(ty: .nominal(DeclRef(unit: unitIndex, decl: literal), []))
        }
        i = close + 1
      case .string:
        op = TSOperand(ty: globalType(TSWord.String))
        i += 1
        while i < end, unit.tokens[i].kind == .interpolationOpen {
          i = unit.skipBalanced(i)
          if i < end, unit.tokens[i].kind == .string, unit.touchesPrevious(i) { i += 1 }
        }
      case .number:
        op = TSOperand(ty: globalType(TSWord.Number))
        i += 1
      default:
        guard unit.tsIsWord(i) else { return .unknown }
        let word = unit.hash(i)
        if word == TSWord.this {
          op = TSOperand(ty: thisType(unitIndex, token: i))
          i += 1
        } else if word == TSWord.super {
          op = TSOperand(ty: superType(unitIndex, token: i))
          i += 1
        } else if word == TSWord.trueWord || word == TSWord.falseWord {
          return TSOperand(ty: globalType(TSWord.Boolean))
        } else if word == TSWord.null || word == TSWord.undefined {
          return .unknown
        } else if word == TSWord.require, unit.isByte(i + 1, 0x28), unit.tokens[i + 2].kind == .string, unit.isByte(i + 3, 0x29) {
          let key = layout.resolve(unit.tsStringValue(i + 2), from: unit.path)
          var item = Import(module: name(key), moduleName: key, isExported: false, isTestable: false)
          item.alias = 1
          op = value(of: follow(item))
          i += 4
        } else if unit.isToken(i, "function") {
          var k = i + 1
          if unit.isByte(k, 0x2A) { k += 1 }
          if unit.tsIsName(k) { k += 1 }
          op = TSOperand(ty: functionValue(unitIndex, key: Int32(k)))
          return op
        } else if unit.isToken(i, "class") {
          if let index = unit.decls.firstIndex(where: { $0.first == Int32(i) && $0.kind == .classType }) {
            return TSOperand(ty: .meta(.nominal(DeclRef(unit: unitIndex, decl: Int32(index)), [])))
          }
          return .unknown
        } else {
          op = value(of: lookup(word, unitIndex: unitIndex, token: Int32(i)))
          i += 1
        }
      }
    }
    var explicit: [Ty] = []
    while i < end {
      if unit.tsIsDot(i) || unit.isToken(i, ".#") {
        var nameAt = i + 1
        if unit.isByte(nameAt, 0x23) { nameAt += 1 }
        if unit.isToken(i, "?.") && (unit.isByte(nameAt, 0x28) || unit.isByte(nameAt, 0x5B)) {
          i += 1
          continue
        }
        guard nameAt < end, unit.tsIsWord(nameAt) else { return .unknown }
        let found = members(of: op.ty, named: unit.hash(nameAt), from: unitIndex)
        guard let first = found.first else { return .unknown }
        var next = siteValue(first.site, env: first.env)
        if !next.callees.isEmpty {
          next.callees = found.compactMap { item -> (ref: DeclRef, env: [Name: Ty])? in
            if case .decl(let ref) = item.site, decl(ref).kind == .function { return (ref, item.env) }
            return nil
          }
        }
        op = next
        explicit = []
        i = nameAt + 1
      } else if unit.isByte(i, 0x21) {
        i += 1
      } else if unit.isByte(i, 0x3C), let after = unit.tsTypeArgumentsEnd(i, limit: end) {
        explicit = typeArguments(unitIndex, i, after, env: [:])
        i = after
      } else if unit.isByte(i, 0x28) {
        op = call(op, unitIndex: unitIndex, open: i, explicit: explicit)
        explicit = []
        i = unit.skipBalanced(i)
      } else if unit.isByte(i, 0x5B) {
        let close = unit.skipBalanced(i) - 1
        if close == i + 2, unit.tokens[i + 1].kind == .string {
          op = TSOperand(ty: memberType(op.ty, name(unit.tsStringValue(i + 1)), from: unitIndex))
        } else if close == i + 2, unit.tokens[i + 1].kind == .number, case .tuple(let items, _) = op.ty, let index = Int(unit.string(i + 1)), index < items.count {
          op = TSOperand(ty: items[index])
        } else {
          op = TSOperand(ty: elementType(op.ty))
        }
        i = close + 1
      } else {
        break
      }
    }
    return op
  }

  /// `this` at a token: the class (its static side in a static member) or the object literal of the method around.
  func thisType(_ unitIndex: Int32, token: Int) -> Ty {
    guard let owner = body(unitIndex).thisOwner(at: Int32(token)) else { return .unknown }
    let ref = DeclRef(unit: unitIndex, decl: owner.decl)
    let instance = Ty.nominal(ref, [])
    return owner.isStatic ? .meta(instance) : instance
  }

  /// `super`: the class's base.
  func superType(_ unitIndex: Int32, token: Int) -> Ty {
    guard let owner = body(unitIndex).thisOwner(at: Int32(token)) else { return .unknown }
    let item = project.units[Int(unitIndex)].decls[Int(owner.decl)]
    guard item.kind == .classType, item.typeStart >= 0 else { return .unknown }
    let base = parseType(unitIndex, Int(item.typeStart), Int(item.typeEnd), env: [:])
    return owner.isStatic ? .meta(base) : base
  }

  // MARK: Contextual types

  /// What a function's result is written as: its annotation, else the result of the function type it's written for.
  func functionResult(_ unitIndex: Int32, _ fn: TSFunction) -> Ty {
    let unit = project.units[Int(unitIndex)]
    if let index = unit.decls.firstIndex(where: { $0.bodyOpen == fn.bodyStart && $0.bodyOpen >= 0 }) {
      let item = unit.decls[index]
      if item.typeStart >= 0 { return parseType(unitIndex, Int(item.typeStart), Int(item.typeEnd), env: [:]) }
      // A method of an object literal: the property's type in the literal's.
      guard item.parent >= 0, unit.decls[Int(item.parent)].kind == .structure, unit.decls[Int(item.parent)].initStart >= 0 else { return .unknown }
      let outer = contextualType(unitIndex, Int(unit.decls[Int(item.parent)].bodyOpen))
      if case .function(_, let result) = memberType(outer, item.name, from: unitIndex) { return result }
      return .unknown
    }
    let after = Int(fn.paramsClose) + 1
    if fn.paramsOpen != fn.paramsClose, unit.isByte(after, 0x3A) {
      return parseType(unitIndex, after + 1, unit.tsTypeEnd(after + 1, limit: Int(fn.bodyEnd), arrowEnds: true), env: [:])
    }
    guard fn.isArrow else { return .unknown }
    var start = Int(fn.paramsOpen)
    if unit.isToken(start - 1, "async") { start -= 1 }
    switch contextualType(unitIndex, start) {
    case .function(_, let result): return result
    case .constructed(let kind, let parts) where kind == Ty.union:
      for case .function(_, let result) in parts { return result }
      return .unknown
    default: return .unknown
    }
  }

  /// The type a function's parameter gets from where the function is written (`xs.map(x => …)`).
  func contextualParameter(_ unitIndex: Int32, key: Int32, index: Int32) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let scan = body(unitIndex)
    guard let fn = scan.functions[key] else { return .unknown }
    var start = Int(key)
    if !fn.isArrow {
      if unit.tsIsName(start - 1), !unit.isToken(start - 1, "function") { start -= 1 }
      if unit.isByte(start - 1, 0x2A) { start -= 1 }
      if unit.isToken(start - 1, "function") { start -= 1 } else { return .unknown }
    }
    if unit.isToken(start - 1, "async") { start -= 1 }
    let expected = contextualType(unitIndex, start)
    return parameterType(of: expected, Int(index), unitIndex: unitIndex)
  }

  private func parameterType(of ty: Ty, _ index: Int, unitIndex: Int32) -> Ty {
    switch ty {
    case .function(let params, _): return index < params.count ? params[index] : .unknown
    case .constructed(let kind, let parts) where kind == Ty.union:
      for part in parts {
        if case .function = part { return parameterType(of: part, index, unitIndex: unitIndex) }
      }
      for part in parts {
        let found = parameterType(of: part, index, unitIndex: unitIndex)
        if found != .unknown { return found }
      }
      return .unknown
    case .nominal:
      guard let found = members(of: ty, named: TSWord.call, from: unitIndex).first, case .decl(let ref) = found.site else { return .unknown }
      return parameter(ref, index, env: found.env)
    default:
      return .unknown
    }
  }

  /// A declared function's parameter's type at a position (a rest parameter's element).
  func parameter(_ ref: DeclRef, _ index: Int, env: [Name: Ty]) -> Ty {
    let item = decl(ref)
    guard item.paramCount > 0 else { return .unknown }
    let holder = self.unit(ref)
    var position = index
    if position >= Int(item.paramCount) {
      let last = holder.params[Int(item.paramStart + item.paramCount - 1)]
      guard last.variadic else { return .unknown }
      position = Int(item.paramCount) - 1
    }
    let param = holder.params[Int(item.paramStart) + position]
    guard param.typeStart >= 0 else { return .unknown }
    let ty = parseType(ref.unit, Int(param.typeStart), Int(param.typeEnd), env: env)
    return param.variadic ? elementType(ty) : ty
  }

  /// The type an expression starting at `start` is written for: a call's parameter, a typed variable, a property of a
  /// literal that has one, a function's declared result, an element of a typed array.
  func contextualType(_ unitIndex: Int32, _ start: Int) -> Ty {
    depth += 1
    defer { depth -= 1 }
    guard depth < 40, start > 0 else { return .unknown }
    let unit = project.units[Int(unitIndex)]
    let facts = file(unit)
    let before = start - 1
    if unit.isByte(before, 0x28) || unit.isByte(before, 0x2C), let open = unit.isByte(before, 0x28) ? before : unit.matchingOpenBefore(start) {
      if unit.isByte(open, 0x28), open > 0 {
        let args = arguments(unit, open: open)
        guard let position = args.firstIndex(where: { $0.0 <= start && start < max($0.1, $0.0 + 1) }) else { return .unknown }
        var calleeEnd = open
        var explicit: [Ty] = []
        if unit.tsCloseAngles(open - 1) > 0 {
          let closeAngle = open - 1
          var k = closeAngle
          var angles = 0
          while k > 0 {
            if unit.tsCloseAngles(k) > 0 { angles += unit.tsCloseAngles(k) } else if unit.isByte(k, 0x3C) {
              angles -= 1
              if angles == 0 { break }
            }
            k -= 1
          }
          explicit = typeArguments(unitIndex, k, open, env: [:])
          calleeEnd = k
        }
        guard calleeEnd > 0, unit.tsIsWord(calleeEnd - 1) && !controlWords.contains(unit.hash(calleeEnd - 1)) || unit.tokens[calleeEnd - 1].kind == .close else {
          // Parenthesized: what the parentheses are written for.
          return explicit.isEmpty && args.count == 1 ? contextualType(unitIndex, open) : .unknown
        }
        var calleeStart = expressionStart(unit, last: calleeEnd - 1)
        if unit.isToken(calleeStart, "new") {
          calleeStart += 1
          let callee = expression(unitIndex, calleeStart, calleeEnd).ty
          guard case .meta(.nominal(let ref, _)) = callee else { return .unknown }
          let constructors = merged(ref).flatMap { other in
            self.unit(other).children(of: other.decl).filter { self.unit(other).decls[Int($0)].kind == .initializer }.map { (DeclRef(unit: other.unit, decl: $0), [Name: Ty]()) }
          }
          guard let pick = overload(constructors.map { (ref: $0.0, env: $0.1) }, count: args.count) else { return .unknown }
          return parameter(pick.ref, position, env: pick.env)
        }
        let callee = expression(unitIndex, calleeStart, calleeEnd)
        if let pick = overload(callee.callees, count: args.count, arguments: args, in: unitIndex) {
          var env = pick.env
          let item = decl(pick.ref)
          for g in 0..<min(Int(item.genericCount), explicit.count) { env[self.unit(pick.ref).generics[Int(item.genericStart) + g].name] = explicit[g] }
          return parameter(pick.ref, position, env: env)
        }
        return parameterType(of: callee.ty, position, unitIndex: unitIndex)
      }
    }
    if unit.isByte(before, 0x3D) {
      if let index = unit.decls.firstIndex(where: { $0.initStart == Int32(start) && $0.typeStart >= 0 }) {
        let item = unit.decls[index]
        return parseType(unitIndex, Int(item.typeStart), Int(item.typeEnd), env: [:])
      }
      for local in body(unitIndex).locals {
        if case .typed(let typeStart, let typeEnd) = local.kind, Int(typeEnd) == before, local.steps.isEmpty {
          return parseType(unitIndex, Int(typeStart), Int(typeEnd), env: [:])
        }
      }
      // An assignment: what's assigned to.
      guard before > 0, !unit.tsIsName(before - 1) || !(unit.isToken(before - 2, "const") || unit.isToken(before - 2, "let") || unit.isToken(before - 2, "var")) else {
        return .unknown
      }
      let target = expressionStart(unit, last: before - 1)
      return target < before ? expression(unitIndex, target, before).ty : .unknown
    }
    if unit.isToken(before, "=>") {
      guard let fn = body(unitIndex).function(at: Int32(start)) else { return .unknown }
      return functionResult(unitIndex, fn)
    }
    if unit.isByte(before, 0x3A), let open = unit.matchingOpenBefore(start), unit.isByte(open, 0x7B), facts.literals[Int32(open)] != nil, let key = unit.tsMemberName(before - 1) {
      let outer = contextualType(unitIndex, open)
      guard outer != .unknown else { return .unknown }
      return memberType(outer, key, from: unitIndex)
    }
    if unit.isToken(before, "return") {
      guard let fn = body(unitIndex).function(at: Int32(start)) else { return .unknown }
      return functionResult(unitIndex, fn)
    }
    if unit.isByte(before, 0x5B) || unit.isByte(before, 0x2C), let open = unit.isByte(before, 0x5B) ? before : unit.matchingOpenBefore(start), unit.isByte(open, 0x5B) {
      if open > 0, unit.tsIsWord(open - 1) || unit.tokens[open - 1].kind == .close { return .unknown }
      return elementType(contextualType(unitIndex, open))
    }
    return .unknown
  }
}
