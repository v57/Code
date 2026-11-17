import CodeModel
import CodeScan
import Foundation

/// Types from tokens and expressions, impls, and what a type has (fields, methods through autoderef and traits).
///
/// `&T` is `constructed(reference, [T])` (`&mut` too), `*const T` `constructed(raw, [T])`, `[T]` `Ty.slice`, `[T; N]`
/// `Ty.array`, `(A, B)` a tuple, `fn(A) -> B` a function, `dyn A + B` and `impl A` an existential, a type parameter
/// `param(name, owner)` (`Self` in a trait is the trait's `Self` parameter), `T::Item` before it's known
/// `dependent(T, Item)`. A trait's `Item = X` in its arguments is `constructed(binding, [param(Item), X])`.
extension RustModel {
  static let binding = hashName("=binding")

  // MARK: Types from tokens

  func typeFrom(_ unitIndex: Int32, _ start: Int32, _ end: Int32) -> Ty { typeFrom(unitIndex, Int(start), Int(end)) }

  func typeFrom(_ unitIndex: Int32, _ start: Int, _ end: Int) -> Ty {
    guard start >= 0, start < end else { return .unknown }
    checkImplCaches()
    // By the unit's object: a body edit replaces it, shifting the tokens after it without a reset.
    let key = TypeKey(unit: ObjectIdentifier(project.units[Int(unitIndex)]), start: Int32(start), end: Int32(end))
    if let known = typeCache[key] { return known }
    depth += 1
    defer { depth -= 1 }
    guard depth < 40 else { return .unknown }
    // Inside itself (a bound naming its own trait's associated type): unknown.
    typeCache[key] = .unknown
    var i = start
    let ty = parseType(unitIndex, &i, end)
    typeCache[key] = ty
    return ty
  }

  private func isLifetime(_ unit: Unit, _ i: Int) -> Bool {
    i < unit.tokens.count && unit.tokens[i].kind == .string && unit.source.text[unit.tokens[i].start] == 0x27 && unit.source.text[unit.tokens[i].end - 1] != 0x27
  }

  func parseType(_ unitIndex: Int32, _ i: inout Int, _ end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    while i < end, isLifetime(unit, i) || unit.isToken(i, "for") && unit.isByte(i + 1, 0x3C) {
      if unit.isToken(i, "for") { i = angleClose(unit, i + 1) + 1 } else { i += 1 }
      if unit.isByte(i, 0x2B) { i += 1 }
    }
    guard i < end else { return .unknown }
    if unit.isByte(i, 0x26) || unit.isToken(i, "&&") {
      let double = unit.isToken(i, "&&")
      i += 1
      while i < end, isLifetime(unit, i) { i += 1 }
      if unit.isToken(i, "mut") { i += 1 }
      let inner = parseType(unitIndex, &i, end)
      let once = Ty.constructed(RustTy.reference, [inner])
      return double ? .constructed(RustTy.reference, [once]) : once
    }
    if unit.isByte(i, 0x2A) {
      i += 1
      if unit.isToken(i, "const") || unit.isToken(i, "mut") { i += 1 }
      return .constructed(RustTy.raw, [parseType(unitIndex, &i, end)])
    }
    if unit.isByte(i, 0x5B) {
      let close = unit.skipBalanced(i) - 1
      var k = i + 1
      let element = parseType(unitIndex, &k, close)
      let isArray = unit.isByte(k, 0x3B)
      i = close + 1
      return .constructed(isArray ? Ty.array : Ty.slice, [element])
    }
    if unit.isByte(i, 0x28) {
      let close = unit.skipBalanced(i) - 1
      var items: [Ty] = []
      var k = i + 1
      var sawComma = false
      while k < close {
        items.append(parseType(unitIndex, &k, close))
        while k < close, !unit.isByte(k, 0x2C) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
        if unit.isByte(k, 0x2C) {
          sawComma = true
          k += 1
        }
      }
      i = close + 1
      if items.count == 1, !sawComma { return items[0] }
      return .tuple(items, [])
    }
    if unit.isByte(i, 0x21) || unit.isToken(i, "_") {
      i += 1
      return .unknown
    }
    if unit.isToken(i, "unsafe") || unit.isToken(i, "extern") || unit.isToken(i, "fn") {
      while i < end, !unit.isToken(i, "fn") { i += 1 }
      i += 1
      guard unit.isByte(i, 0x28) else { return .unknown }
      let close = unit.skipBalanced(i) - 1
      var args: [Ty] = []
      var k = i + 1
      while k < close {
        // `name: Type` or `Type`.
        if unit.tokens[k].kind == .identifier, unit.isByte(k + 1, 0x3A), !unit.isToken(k + 1, "::") { k += 2 }
        args.append(parseType(unitIndex, &k, close))
        while k < close, !unit.isByte(k, 0x2C) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
        k += 1
      }
      i = close + 1
      var result = Ty.tuple([], [])
      if unit.isToken(i, "->") {
        i += 1
        result = parseType(unitIndex, &i, end)
      }
      return .function(args, result)
    }
    if unit.isToken(i, "dyn") || unit.isToken(i, "impl") {
      i += 1
      var traits: [Ty] = []
      while i < end {
        if unit.isByte(i, 0x28) { i += 1 }
        if unit.isByte(i, 0x3F) || unit.isToken(i, "~") {
          // `?Sized`.
          i += 1
          _ = parseType(unitIndex, &i, end)
        } else if isLifetime(unit, i) {
          i += 1
        } else if unit.isToken(i, "use"), unit.isByte(i + 1, 0x3C) {
          i = angleClose(unit, i + 1) + 1
        } else {
          let bound = parseType(unitIndex, &i, end)
          if bound != .unknown { traits.append(bound) }
        }
        if unit.isByte(i, 0x29) { i += 1 }
        if unit.isByte(i, 0x2B) { i += 1 } else { break }
      }
      return traits.isEmpty ? .unknown : .existential(traits)
    }
    if unit.isByte(i, 0x3C) {
      // `<T as Trait>::Name`.
      let close = qualifiedEnd(unit, i)
      var asToken = -1
      var k = i + 1
      var level = 0
      while k < close {
        if unit.isByte(k, 0x3C) { level += 1 } else if unit.isByte(k, 0x3E) { level -= 1 }
        if level == 0, unit.isToken(k, "as") { asToken = k }
        k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
      }
      let base = typeFrom(unitIndex, i + 1, asToken >= 0 ? asToken : close)
      i = close + 1
      var result = base
      while unit.isToken(i, "::"), i + 1 < end, unit.tokens[i + 1].kind == .identifier {
        result = normalize(.dependent(result, unit.hash(i + 1)))
        i += 2
      }
      return result
    }
    return pathType(unitIndex, &i, end)
  }

  func angleClose(_ unit: Unit, _ open: Int) -> Int {
    var level = 0
    var k = open
    while k < unit.tokens.count {
      if unit.isByte(k, 0x3C) { level += 1 } else if unit.isByte(k, 0x3E) {
        level -= 1
        if level == 0 { return k }
      } else if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      } else if unit.tokens[k].kind == .close || unit.isByte(k, 0x3B) || unit.isByte(k, 0x7B) {
        return k
      }
      k += 1
    }
    return k
  }

  /// `a::b::C<Args>`, `Fn(A) -> B`, `Self::Item`, `T::Output`.
  private func pathType(_ unitIndex: Int32, _ i: inout Int, _ end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var segments: [Int] = []
    var arguments: [Int: (Int, Int)] = [:]
    var fnSugar: (Int, Int, Int)?
    if unit.isToken(i, "::") {
      segments.append(-1)
      i += 1
    }
    while i < end, unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword {
      let segment = i
      segments.append(segment)
      i += 1
      if unit.isToken(i, "::"), unit.isByte(i + 1, 0x3C) { i += 1 }
      if unit.isByte(i, 0x3C) {
        let close = angleClose(unit, i)
        arguments[segments.count - 1] = (i + 1, close)
        i = close + 1
      } else if unit.isByte(i, 0x28), segments.count >= 1 {
        // `Fn(A, B) -> C`.
        let close = unit.skipBalanced(i) - 1
        var outputEnd = close + 1
        if unit.isToken(close + 1, "->") {
          var k = close + 2
          _ = parseType(unitIndex, &k, end)
          outputEnd = k
        }
        fnSugar = (i, close, outputEnd)
        i = outputEnd
        break
      }
      if unit.isToken(i, "::"), i + 1 < end, unit.tokens[i + 1].kind == .identifier || unit.tokens[i + 1].kind == .keyword {
        i += 1
        continue
      }
      break
    }
    guard let last = segments.last, last >= 0 else { return .unknown }
    // `Self::Item`, `T::Output`, `I::Item::Foo`: a projection.
    if segments.count >= 2, segments[0] >= 0, unit.isToken(segments[0], "Self") || isGenericName(unit.hash(segments[0]), unitIndex: unitIndex, token: segments[0]) {
      var base = typeOfSegment(unitIndex, segments[0], arguments: nil)
      for segment in segments.dropFirst() { base = normalize(.dependent(base, unit.hash(segment))) }
      return base
    }
    if segments.count == 1 {
      let word = unit.hash(last)
      if unit.isToken(last, "Self") { return selfType(unitIndex: unitIndex, token: Int32(last)) }
      _ = word
    }
    let found = resolvePath(unitIndex, segments, qualified: nil, namespace: .type)
    guard let entity = found.first else { return .unknown }
    var args: [Ty] = []
    if let (from, to) = arguments[segments.count - 1] { args = typeArguments(unitIndex, from, to) }
    if let (open, close, outputEnd) = fnSugar {
      var inputs: [Ty] = []
      var k = open + 1
      while k < close {
        inputs.append(parseType(unitIndex, &k, close))
        while k < close, !unit.isByte(k, 0x2C) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
        k += 1
      }
      let output = outputEnd > close + 1 ? typeFrom(unitIndex, close + 2, outputEnd) : Ty.tuple([], [])
      args = [.tuple(inputs, []), .constructed(RustModel.binding, [.param(RustWord.output, nil), output])]
    }
    return type(of: entity, arguments: args)
  }

  func isGenericName(_ word: Name, unitIndex: Int32, token: Int) -> Bool {
    let unit = project.units[Int(unitIndex)]
    for index in unit.chain(at: Int32(token)).reversed() {
      let item = unit.decls[Int(index)]
      for g in 0..<Int(item.genericCount) where unit.generics[Int(item.genericStart) + g].name == word { return true }
    }
    return false
  }

  private func typeOfSegment(_ unitIndex: Int32, _ token: Int, arguments: [Ty]?) -> Ty {
    let unit = project.units[Int(unitIndex)]
    if unit.isToken(token, "Self") { return selfType(unitIndex: unitIndex, token: Int32(token)) }
    guard let entity = lexical(unit.hash(token), unitIndex: unitIndex, token: Int32(token), namespace: .type).first else { return .unknown }
    return type(of: entity, arguments: arguments ?? [])
  }

  /// `<A, B, Item = C>`: the types, bindings at the end; lifetimes and constants left out.
  func typeArguments(_ unitIndex: Int32, _ from: Int, _ to: Int) -> [Ty] {
    let unit = project.units[Int(unitIndex)]
    var result: [Ty] = []
    var bindings: [Ty] = []
    var k = from
    while k < to {
      var itemEnd = k
      var level = 0
      while itemEnd < to {
        if unit.tokens[itemEnd].kind == .open {
          itemEnd = unit.skipBalanced(itemEnd)
          continue
        }
        if unit.isByte(itemEnd, 0x3C) { level += 1 } else if unit.isByte(itemEnd, 0x3E) { level -= 1 }
        if level == 0, unit.isByte(itemEnd, 0x2C) { break }
        itemEnd += 1
      }
      if isLifetime(unit, k) {
        // Left out.
      } else if unit.tokens[k].kind == .identifier, unit.isByte(k + 1, 0x3D) {
        bindings.append(.constructed(RustModel.binding, [.param(unit.hash(k), nil), typeFrom(unitIndex, k + 2, itemEnd)]))
      } else if unit.tokens[k].kind == .identifier, unit.isByte(k + 1, 0x3A), !unit.isToken(k + 1, "::") {
        // `Item: Bound`: an associated type bound.
      } else if unit.tokens[k].kind == .number || unit.isByte(k, 0x7B) || unit.isByte(k, 0x2D) {
        result.append(.unknown)
      } else {
        var at = k
        result.append(parseType(unitIndex, &at, itemEnd))
      }
      k = itemEnd + 1
    }
    return result + bindings
  }

  /// A resolved name as a type, with its written arguments.
  func type(of entity: Entity, arguments: [Ty]) -> Ty {
    switch entity {
    case .decl(let ref):
      let item = decl(ref)
      switch item.kind {
      case .structure, .enumeration, .protocolType:
        return .nominal(ref, arguments)
      case .typeAlias:
        return aliasType(ref, arguments)
      case .associatedType:
        return .dependent(.unknown, item.name)
      case .enumCase:
        // A variant names its enum's type.
        return .nominal(DeclRef(unit: ref.unit, decl: item.parent), arguments)
      default:
        return .unknown
      }
    case .generic(let u, let token, let owner):
      return .param(project.units[Int(u)].hash(Int(token)), DeclRef(unit: u, decl: owner))
    default:
      return .unknown
    }
  }

  /// `type A<T> = B<T>;` with its arguments put in.
  func aliasType(_ ref: DeclRef, _ arguments: [Ty]) -> Ty {
    let item = decl(ref)
    guard item.typeStart >= 0 else { return .unknown }
    guard resolvingAliases.insert(ref).inserted else { return .unknown }
    defer { resolvingAliases.remove(ref) }
    let base = typeFrom(ref.unit, item.typeStart, item.typeEnd)
    guard item.genericCount > 0 else { return base }
    let holder = unit(ref)
    var map: [Name: Ty] = [:]
    for g in 0..<Int(item.genericCount) { map[holder.generics[Int(item.genericStart) + g].name] = g < arguments.count ? arguments[g] : .unknown }
    return substitute(base, map, owner: ref)
  }

  func valueTypeOfAlias(_ ref: DeclRef) -> Ty { aliasType(ref, []) }

  /// The declaration a type is named after.
  func typeDecl(of ty: Ty) -> DeclRef? {
    switch ty {
    case .nominal(let ref, _): return ref
    case .constructed(let kind, let args) where kind == RustTy.reference: return args.first.flatMap(typeDecl(of:))
    default: return nil
    }
  }

  /// `Self` at a token: the impl's type, the trait's `Self`, or the type being declared.
  func selfType(unitIndex: Int32, token: Int32) -> Ty {
    guard let owner = selfOwner(unitIndex: unitIndex, token: token) else { return .unknown }
    let ref = DeclRef(unit: unitIndex, decl: owner)
    let item = decl(ref)
    switch item.kind {
    case .extensionDecl: return implSelfType(ref)
    case .protocolType: return .param(RustWord.selfType, ref)
    default: return ownType(ref)
    }
  }

  /// A type declared with its own parameters: `Foo<T>` inside Foo.
  func ownType(_ ref: DeclRef) -> Ty {
    let item = decl(ref)
    let holder = unit(ref)
    var args: [Ty] = []
    for g in 0..<Int(item.genericCount) { args.append(.param(holder.generics[Int(item.genericStart) + g].name, ref)) }
    return .nominal(ref, args)
  }

  func substitute(_ ty: Ty, _ map: [Name: Ty], owner: DeclRef? = nil, selfType: Ty? = nil) -> Ty {
    if map.isEmpty, selfType == nil { return ty }
    switch ty {
    case .param(let word, let from):
      if word == RustWord.selfType, let selfType, from.map({ decl($0).kind == .protocolType }) ?? true { return selfType }
      if let replaced = map[word] { return replaced }
      return ty
    case .nominal(let ref, let args): return .nominal(ref, args.map { substitute($0, map, owner: owner, selfType: selfType) })
    case .constructed(let kind, let args): return .constructed(kind, args.map { substitute($0, map, owner: owner, selfType: selfType) })
    case .tuple(let items, let labels): return .tuple(items.map { substitute($0, map, owner: owner, selfType: selfType) }, labels)
    case .function(let args, let result): return .function(args.map { substitute($0, map, owner: owner, selfType: selfType) }, substitute(result, map, owner: owner, selfType: selfType))
    case .existential(let items): return .existential(items.map { substitute($0, map, owner: owner, selfType: selfType) })
    case .dependent(let base, let word): return normalize(.dependent(substitute(base, map, owner: owner, selfType: selfType), word))
    default: return ty
    }
  }

  /// Binds an impl's (or a function's) parameters in `pattern` to what `actual` has there.
  func unify(_ pattern: Ty, _ actual: Ty, _ map: inout [Name: Ty], bindable: Set<Name>) -> Bool {
    switch (pattern, actual) {
    case (.param(let word, _), _) where bindable.contains(word):
      if let known = map[word], known != .unknown, actual != .unknown { return known == actual || looselyEqual(known, actual) }
      if actual != .unknown || map[word] == nil { map[word] = actual }
      return true
    case (_, .unknown), (.unknown, _):
      return true
    case (.nominal(let a, let xs), .nominal(let b, let ys)):
      guard a == b else { return false }
      for (x, y) in zip(xs, ys) where !unify(x, y, &map, bindable: bindable) { return false }
      return true
    case (.constructed(let k, let xs), .constructed(let l, let ys)):
      guard k == l else { return false }
      for (x, y) in zip(xs, ys) where !unify(x, y, &map, bindable: bindable) { return false }
      return true
    case (.tuple(let xs, _), .tuple(let ys, _)):
      guard xs.count == ys.count else { return false }
      for (x, y) in zip(xs, ys) where !unify(x, y, &map, bindable: bindable) { return false }
      return true
    case (.function(let xs, let r), .function(let ys, let s)):
      for (x, y) in zip(xs, ys) { _ = unify(x, y, &map, bindable: bindable) }
      _ = unify(r, s, &map, bindable: bindable)
      return true
    case (.existential, .existential):
      return true
    case (.param, .param):
      return true
    default:
      return pattern == actual
    }
  }

  private func looselyEqual(_ a: Ty, _ b: Ty) -> Bool {
    if case .nominal(let x, _) = a, case .nominal(let y, _) = b { return x == y }
    return false
  }

  // MARK: Impls

  /// Every impl block, by the last name of what it's for (`<blanket>` for `impl<T> X for T`), across what's loaded.
  func implsNamed(_ word: Name) -> [DeclRef] {
    if indexedUnits < project.units.count {
      for u in indexedUnits..<project.units.count {
        let holder = project.units[u]
        for (index, item) in holder.decls.enumerated() where item.kind == .extensionDecl && item.name != 0 {
          implIndex[item.name, default: []].append(DeclRef(unit: Int32(u), decl: Int32(index)))
        }
      }
      indexedUnits = project.units.count
    }
    return implIndex[word] ?? []
  }

  func implSelfType(_ ref: DeclRef) -> Ty {
    if let known = implTypes[ref] { return known }
    implTypes[ref] = .unknown
    let item = decl(ref)
    let ty = typeFrom(ref.unit, item.typeStart, item.typeEnd)
    implTypes[ref] = ty
    return ty
  }

  /// The trait an impl implements, with its arguments.
  func implTrait(_ ref: DeclRef) -> Ty? {
    let item = decl(ref)
    guard item.inheritCount > 0 else { return nil }
    if let known = implTraits[ref] { return known }
    implTraits[ref] = .unknown
    let range = unit(ref).ranges[Int(item.inheritStart)]
    let ty = typeFrom(ref.unit, range.start, range.end)
    implTraits[ref] = ty
    return ty
  }

  func implGenerics(_ ref: DeclRef) -> Set<Name> {
    let item = decl(ref)
    let holder = unit(ref)
    var names: Set<Name> = []
    for g in 0..<Int(item.genericCount) { names.insert(holder.generics[Int(item.genericStart) + g].name) }
    return names
  }

  /// The name impls of a type are filed under.
  func implName(_ ty: Ty) -> Name? {
    switch ty {
    case .nominal(let ref, _): return decl(ref).name
    case .constructed(let kind, let args):
      if kind == RustTy.reference { return args.first.flatMap(implName) }
      if kind == Ty.slice { return RustWord.slice }
      if kind == Ty.array { return RustWord.array }
      if kind == RustTy.raw { return RustWord.pointer }
      return nil
    case .tuple: return RustWord.tuple
    case .function: return RustWord.function
    case .existential(let traits): return traits.first.flatMap(implName)
    default: return nil
    }
  }

  /// The impls that apply to a type, with what their parameters are for it. Blanket impls apply when their bounds hold.
  func impls(for ty: Ty, traitsOnly: Bool = false, blankets: Bool = true) -> [(impl: DeclRef, map: [Name: Ty])] {
    guard ty != .unknown else { return [] }
    checkImplCaches()
    let key = ImplsKey(ty: ty, traitsOnly: traitsOnly, blankets: blankets)
    if let known = implsCache[key] { return known }
    if let at = implsPending[key] { implCycleHead = min(implCycleHead, at); return [] }
    let (result, final) = pendingImpl { implsPending[key] = $0 } done: { implsPending[key] = nil } find: {
      findImpls(for: ty, traitsOnly: traitsOnly, blankets: blankets)
    }
    if final { implsCache[key] = result }
    return result
  }

  /// Impls and what implements what change when more units load (a dependency read lazily).
  func checkImplCaches() {
    if cachedUnitCount != project.units.count {
      implsCache.removeAll()
      implementsCache.removeAll()
      traitScopeCache.removeAll()
      nodeTraitCache.removeAll()
      typeCache.removeAll()
      supertraitCache.removeAll()
      cachedUnitCount = project.units.count
    }
  }

  private func findImpls(for ty: Ty, traitsOnly: Bool, blankets: Bool) -> [(impl: DeclRef, map: [Name: Ty])] {
    var result: [(DeclRef, [Name: Ty])] = []
    if let word = implName(ty) {
      for ref in implsNamed(word) {
        let item = decl(ref)
        if traitsOnly, item.inheritCount == 0 { continue }
        var map: [Name: Ty] = [:]
        if unify(implSelfType(ref), ty, &map, bindable: implGenerics(ref)) { result.append((ref, map)) }
      }
    }
    if blankets, blanketDepth < 3 {
      for ref in implsNamed(RustWord.blanket) {
        let item = decl(ref)
        guard item.inheritCount > 0 else { continue }
        var map: [Name: Ty] = [:]
        let pattern = implSelfType(ref)
        // `impl<T: Display> ToString for T`, `impl<T> Trait for &T`: only for what the parameter's bounds allow.
        guard unify(pattern, ty, &map, bindable: implGenerics(ref)) else { continue }
        if blanketHolds(ref, map) { result.append((ref, map)) }
      }
    }
    return result
  }

  private func blanketHolds(_ ref: DeclRef, _ map: [Name: Ty]) -> Bool {
    blanketDepth += 1
    defer { blanketDepth -= 1 }
    guard blanketDepth <= 3 else { return false }
    for (word, actual) in map {
      if actual == .unknown { return false }
      for bound in bounds(of: word, owner: ref) {
        guard case .nominal(let trait, _) = bound else { continue }
        if isMarker(trait) { continue }
        if !implements(actual, trait) { return false }
      }
    }
    return true
  }

  func isMarker(_ trait: DeclRef) -> Bool {
    let word = decl(trait).name
    return word == RustWord.sized || word == name("Send") || word == name("Sync") || word == name("Unpin") || word == name("Copy") || word == name("UnwindSafe")
      || word == name("RefUnwindSafe")
  }

  /// Whether a type implements a trait, as far as impls, derives and bounds say.
  func implements(_ ty: Ty, _ trait: DeclRef) -> Bool {
    checkImplCaches()
    let key = ImplementsKey(ty: ty, trait: trait)
    if let known = implementsCache[key] { return known }
    if let at = implementsPending[key] { implCycleHead = min(implCycleHead, at); return false }
    let (result, final) = pendingImpl { implementsPending[key] = $0 } done: { implementsPending[key] = nil } find: {
      findImplements(ty, trait)
    }
    if final { implementsCache[key] = result }
    return result
  }

  /// Answers a question about impls while it's marked pending at this depth, and whether the answer can be kept: no
  /// cycle it ran into goes back to a question further out.
  private func pendingImpl<T>(_ mark: (Int) -> Void, done: () -> Void, find: () -> T) -> (T, Bool) {
    let depth = implDepth
    let outer = implCycleHead
    mark(depth)
    implDepth += 1
    implCycleHead = Int.max
    let result = find()
    implDepth -= 1
    done()
    let head = implCycleHead
    let final = head >= depth
    implCycleHead = final ? outer : min(outer, head)
    return (result, final)
  }

  private func findImplements(_ ty: Ty, _ trait: DeclRef) -> Bool {
    switch ty {
    case .param(let word, let owner?):
      return boundsWithSupertraits(word, owner).contains { if case .nominal(let ref, _) = $0 { return ref == trait } else { return false } }
    case .existential(let traits):
      return traits.contains { if case .nominal(let ref, _) = $0 { return ref == trait || supertraits(ref).contains(trait) } else { return false } }
    case .nominal(let ref, _):
      if derivedTraits(ref).contains(trait) { return true }
    default:
      break
    }
    for (impl, _) in impls(for: ty, traitsOnly: true, blankets: false) {
      if case .nominal(let found, _)? = implTrait(impl), found == trait { return true }
    }
    // Then only the blanket impls of this trait, whose bounds would otherwise all be checked.
    guard blanketDepth < 3 else { return false }
    for ref in implsNamed(RustWord.blanket) {
      guard case .nominal(let found, _)? = implTrait(ref), found == trait else { continue }
      var map: [Name: Ty] = [:]
      guard unify(implSelfType(ref), ty, &map, bindable: implGenerics(ref)) else { continue }
      if blanketHolds(ref, map) { return true }
    }
    return false
  }

  /// The traits `#[derive]` names on a type.
  func derivedTraits(_ ref: DeclRef) -> [DeclRef] {
    if let known = derivedCache[ref] { return known }
    derivedCache[ref] = []
    var result: [DeclRef] = []
    for token in derives(ref) {
      let holder = unit(ref)
      for entity in lexical(holder.hash(token), unitIndex: ref.unit, token: Int32(token), namespace: .type) {
        if case .decl(let trait) = entity, decl(trait).kind == .protocolType { result.append(trait) }
      }
    }
    derivedCache[ref] = result
    return result
  }

  func supertraits(_ trait: DeclRef) -> [DeclRef] {
    if let known = supertraitCache[trait] { return known }
    supertraitCache[trait] = []
    let result = findSupertraits(trait)
    supertraitCache[trait] = result
    return result
  }

  private func findSupertraits(_ trait: DeclRef) -> [DeclRef] {
    var result: [DeclRef] = []
    var queue = [trait]
    var seen: Set<DeclRef> = [trait]
    while let current = queue.popLast(), result.count < 32 {
      let item = decl(current)
      let holder = unit(current)
      for r in 0..<Int(item.inheritCount) {
        let range = holder.ranges[Int(item.inheritStart) + r]
        if case .nominal(let found, _) = typeFrom(current.unit, range.start, range.end), seen.insert(found).inserted {
          result.append(found)
          queue.append(found)
        }
      }
    }
    return result
  }

  /// A type parameter's bounds where it's declared (`<T: A + B>`) and in the `where` clause.
  func bounds(of word: Name, owner: DeclRef) -> [Ty] {
    let key = BoundKey(word: word, owner: owner)
    if let known = boundCache[key] { return known }
    boundCache[key] = []
    let holder = unit(owner)
    let item = decl(owner)
    var result: [Ty] = []
    if word == RustWord.selfType, item.kind == .protocolType { result.append(ownType(owner)) }
    for g in 0..<Int(item.genericCount) where holder.generics[Int(item.genericStart) + g].name == word {
      let token = Int(holder.generics[Int(item.genericStart) + g].token)
      if holder.isByte(token + 1, 0x3A) { result += boundList(owner.unit, token + 2) }
    }
    if item.whereStart >= 0 {
      var k = Int(item.whereStart)
      let end = Int(item.whereEnd)
      while k < end {
        if isLifetime(holder, k) || holder.isToken(k, "for") {
          if holder.isToken(k, "for") { k = angleClose(holder, k + 1) + 1 } else { k += 1 }
          continue
        }
        let target = k
        // `T: Bound`, `Self: Bound`, `T::Item: Bound`.
        var colon = k
        var level = 0
        while colon < end, !(level == 0 && holder.isByte(colon, 0x3A) && !holder.isToken(colon, "::")) {
          if holder.isByte(colon, 0x3C) { level += 1 } else if holder.isByte(colon, 0x3E) { level -= 1 }
          if level == 0, holder.isByte(colon, 0x2C) { break }
          colon += 1
        }
        if colon < end, holder.isByte(colon, 0x3A), colon == target + 1, holder.hash(target) == word {
          result += boundList(owner.unit, colon + 1, limit: end)
        }
        // To the next item.
        var next = colon + 1
        level = 0
        while next < end {
          if holder.tokens[next].kind == .open {
            next = holder.skipBalanced(next)
            continue
          }
          if holder.isByte(next, 0x3C) { level += 1 } else if holder.isByte(next, 0x3E) { level -= 1 }
          if level == 0, holder.isByte(next, 0x2C) { break }
          next += 1
        }
        k = next + 1
      }
    }
    // A method's parameter bound by the impl or trait it's in isn't this declaration's; a trait's `Self` has the trait.
    boundCache[key] = result
    return result
  }

  /// `A + B<C> + 'a` from a token, to a `,` or `>` (or `limit`).
  func boundList(_ unitIndex: Int32, _ from: Int, limit: Int? = nil) -> [Ty] {
    let holder = project.units[Int(unitIndex)]
    let end = limit ?? holder.tokens.count
    var result: [Ty] = []
    var k = from
    while k < end {
      if holder.isByte(k, 0x3F) {
        k += 1
        var skip = k
        _ = parseType(unitIndex, &skip, end)
        k = skip
      } else if isLifetime(holder, k) {
        k += 1
      } else {
        var at = k
        let bound = parseType(unitIndex, &at, end)
        if bound != .unknown { result.append(bound) }
        k = max(at, k + 1)
      }
      if holder.isByte(k, 0x2B) { k += 1 } else { break }
    }
    return result
  }

  func boundsWithSupertraits(_ word: Name, _ owner: DeclRef) -> [Ty] {
    var result = bounds(of: word, owner: owner)
    // A method's `T` may be bound where the impl or trait around it is.
    for bound in result {
      if case .nominal(let trait, _) = bound { result += supertraits(trait).map { Ty.nominal($0, []) } }
    }
    return result
  }

  // MARK: Associated types

  /// `T::Item` once T is known: the impl's `type Item = …`, an `Item = X` in T's bounds or trait arguments.
  func normalize(_ ty: Ty) -> Ty {
    guard case .dependent(let base, let word) = ty else { return ty }
    depth += 1
    defer { depth -= 1 }
    guard depth < 30 else { return ty }
    switch base {
    case .unknown:
      return .unknown
    case .param(let name, let owner?):
      for bound in boundsWithSupertraits(name, owner) {
        if case .nominal(_, let args) = bound, let found = bindingIn(args, word) { return found }
      }
      return ty
    case .existential(let traits):
      for trait in traits {
        if case .nominal(_, let args) = trait, let found = bindingIn(args, word) { return found }
      }
      return ty
    default:
      if let found = associatedType(of: base, named: word) { return found }
      return ty
    }
  }

  func bindingIn(_ args: [Ty], _ word: Name) -> Ty? {
    for arg in args {
      if case .constructed(let kind, let parts) = arg, kind == RustModel.binding, parts.count == 2, case .param(let found, _) = parts[0], found == word { return parts[1] }
    }
    return nil
  }

  /// The type an impl for `ty` gives an associated type.
  func associatedType(of ty: Ty, named word: Name, trait: Name? = nil) -> Ty? {
    for (impl, map) in impls(for: ty, traitsOnly: true) {
      if let trait {
        guard case .nominal(let found, _)? = implTrait(impl), decl(found).name == trait else { continue }
      }
      let holder = unit(impl)
      for child in holder.children(of: impl.decl) where holder.decls[Int(child)].kind == .typeAlias && holder.decls[Int(child)].name == word {
        let alias = DeclRef(unit: impl.unit, decl: child)
        let item = decl(alias)
        guard item.typeStart >= 0 else { continue }
        return substitute(typeFrom(impl.unit, item.typeStart, item.typeEnd), map, owner: impl, selfType: ty)
      }
    }
    return nil
  }

  // MARK: Members

  /// Associated items of a type or trait by path (`Type::new`, `Trait::method`, `Enum::Variant`'s siblings): inherent
  /// impls first, then trait impls (answering the trait's declaration), derived traits, a trait's own and its supertraits'.
  func associatedItems(_ ref: DeclRef, _ word: Name, _ namespace: Namespace?) -> [DeclRef] {
    let item = decl(ref)
    if item.kind == .protocolType { return traitItems(ref, word) }
    let ty = ownType(ref)
    var inherent: [DeclRef] = []
    var traits: [DeclRef] = []
    var traitOf: [DeclRef] = []
    for (impl, _) in impls(for: .nominal(ref, []), blankets: false) {
      let holder = unit(impl)
      let found = holder.children(of: impl.decl).filter { holder.decls[Int($0)].name == word }.map { DeclRef(unit: impl.unit, decl: $0) }
      guard !found.isEmpty else { continue }
      if decl(impl).inheritCount == 0 {
        inherent += found
      } else if case .nominal(let trait, _)? = implTrait(impl) {
        let declared = traitItems(trait, word)
        traits += declared.isEmpty ? found : declared
        traitOf += Array(repeating: trait, count: declared.isEmpty ? found.count : declared.count)
      }
    }
    if !inherent.isEmpty { return filterNamespace(inherent, namespace) }
    // `u64::from`: only traits in scope where it's asked (any, when none of them is).
    var unseen: [DeclRef] = []
    if let site = traitSite, !traits.isEmpty {
      let scope = traitsInScope(unitIndex: site.unit, token: site.token)
      let visible = zip(traits, traitOf).filter { scope.contains($0.1) }.map(\.0)
      if visible.isEmpty { unseen = traits }
      traits = visible
    }
    if !traits.isEmpty { return filterNamespace(Array(Set(traits)).sorted { ($0.unit, $0.decl) < ($1.unit, $1.decl) }, namespace) }
    for trait in derivedTraits(ref) {
      let found = traitItems(trait, word)
      if !found.isEmpty { return found }
    }
    // Blanket impls (`impl<T> From<T> for T`).
    for (impl, _) in impls(for: ty) where decl(impl).name == RustWord.blanket {
      if case .nominal(let trait, _)? = implTrait(impl) {
        let found = traitItems(trait, word)
        if !found.isEmpty { return found }
      }
    }
    return filterNamespace(unseen, namespace)
  }

  private func filterNamespace(_ list: [DeclRef], _ namespace: Namespace?) -> [DeclRef] {
    let kept = list.filter { fits(.decl($0), namespace) }
    return kept.isEmpty ? list : kept
  }

  /// A trait's item by name, or its supertraits'.
  func traitItems(_ trait: DeclRef, _ word: Name) -> [DeclRef] {
    let holder = unit(trait)
    let own = holder.children(of: trait.decl).filter { holder.decls[Int($0)].name == word }.map { DeclRef(unit: trait.unit, decl: $0) }
    if !own.isEmpty { return own }
    for parent in supertraits(trait) {
      let parentHolder = unit(parent)
      let found = parentHolder.children(of: parent.decl).filter { parentHolder.decls[Int($0)].name == word }.map { DeclRef(unit: parent.unit, decl: $0) }
      if !found.isEmpty { return found }
    }
    return []
  }

  struct MemberHit {
    var ref: DeclRef
    /// The type it was found on, after autoderef.
    var receiver: Ty
    var map: [Name: Ty]
  }

  /// `x.name`: a field, else a method, through autoderef: inherent impls, then traits (impls, derives, bounds).
  func memberHits(of ty: Ty, named word: Name, call: Bool, includeFields: Bool = true, at: (unit: Int32, token: Int32)? = nil) -> [MemberHit] {
    let scope = at.map { traitsInScope(unitIndex: $0.unit, token: $0.token) }
    let found = autoderefHits(ty, word, call: call, includeFields: includeFields, scope: scope)
    // A trait this can't see imported (through a macro, say) still beats nothing.
    if found.isEmpty, scope != nil { return autoderefHits(ty, word, call: call, includeFields: includeFields, scope: nil) }
    return found
  }

  private func autoderefHits(_ ty: Ty, _ word: Name, call: Bool, includeFields: Bool, scope: Set<DeclRef>?) -> [MemberHit] {
    var step = ty
    var seen = 0
    while seen < 10, step != .unknown {
      seen += 1
      // `&X`: X's own methods taking `&self` match the reference as it is, before any trait's for `&X`.
      if case .constructed(let kind, let args) = step, kind == RustTy.reference, let inner = args.first {
        let own = hitsAtStep(inner, word, call: call, includeFields: includeFields, scope: scope).filter { decl(DeclRef(unit: $0.ref.unit, decl: decl($0.ref).parent)).kind == .extensionDecl && decl(DeclRef(unit: $0.ref.unit, decl: decl($0.ref).parent)).inheritCount == 0 }
        if !own.isEmpty { return own }
      }
      let hits = hitsAtStep(step, word, call: call, includeFields: includeFields, scope: scope)
      if !hits.isEmpty { return hits }
      guard let next = derefStep(step) else { break }
      step = next
    }
    return []
  }

  func members(of ty: Ty, named word: Name, from unitIndex: Int32, call: Bool, includeFields: Bool = true, at token: Int32? = nil) -> [DeclRef] {
    var result: [DeclRef] = []
    for hit in memberHits(of: ty, named: word, call: call, includeFields: includeFields, at: token.map { (unitIndex, $0) }) where !result.contains(hit.ref) { result.append(hit.ref) }
    return result
  }

  private func hitsAtStep(_ step: Ty, _ word: Name, call: Bool, includeFields: Bool, scope: Set<DeclRef>?) -> [MemberHit] {
    var result: [MemberHit] = []
    if includeFields, !call, case .nominal(let ref, let args) = step, decl(ref).kind == .structure {
      let holder = unit(ref)
      for child in holder.children(of: ref.decl) where holder.decls[Int(child)].kind == .variable && holder.decls[Int(child)].name == word {
        result.append(MemberHit(ref: DeclRef(unit: ref.unit, decl: child), receiver: step, map: genericMap(ref, args)))
      }
      if !result.isEmpty { return result }
    }
    var traitHits: [MemberHit] = []
    for (impl, map) in impls(for: step) {
      let holder = unit(impl)
      let found = holder.children(of: impl.decl).filter {
        let item = holder.decls[Int($0)]
        return item.name == word && (item.kind == .function || item.kind == .variable)
      }
      if decl(impl).inheritCount == 0 {
        for child in found { result.append(MemberHit(ref: DeclRef(unit: impl.unit, decl: child), receiver: step, map: map)) }
      } else if case .nominal(let trait, let traitArgs)? = implTrait(impl), scope?.contains(trait) ?? true {
        var traitMap = map
        for (key, value) in genericMap(trait, traitArgs) { traitMap[key] = value }
        let declared = traitItems(trait, word).filter { decl($0).kind == .function || decl($0).kind == .variable }
        for ref in (declared.isEmpty ? found.map { DeclRef(unit: impl.unit, decl: $0) } : declared) where !traitHits.contains(where: { $0.ref == ref }) {
          traitHits.append(MemberHit(ref: ref, receiver: step, map: traitMap))
        }
      }
    }
    if !result.isEmpty { return result }
    var traits: [(DeclRef, [Ty])] = []
    switch step {
    case .nominal(let ref, _):
      for trait in derivedTraits(ref) where scope?.contains(trait) ?? true { traits.append((trait, [])) }
    case .param(let name, let owner?):
      for bound in boundsWithSupertraits(name, owner) { if case .nominal(let trait, let args) = bound { traits.append((trait, args)) } }
      // A method's own `T` bound in the impl or trait around it: a trait's `Self`.
    case .existential(let list):
      for bound in list {
        if case .nominal(let trait, let args) = bound {
          traits.append((trait, args))
          for parent in supertraits(trait) { traits.append((parent, [])) }
        }
      }
    default:
      break
    }
    for (trait, args) in traits {
      for ref in traitItems(trait, word) where decl(ref).kind == .function && !traitHits.contains(where: { $0.ref == ref }) {
        traitHits.append(MemberHit(ref: ref, receiver: step, map: genericMap(trait, args)))
      }
    }
    return traitHits
  }

  /// A declaration's type parameters bound to arguments.
  func genericMap(_ ref: DeclRef, _ args: [Ty]) -> [Name: Ty] {
    let item = decl(ref)
    guard item.genericCount > 0 else { return [:] }
    let holder = unit(ref)
    var map: [Name: Ty] = [:]
    for g in 0..<Int(item.genericCount) { map[holder.generics[Int(item.genericStart) + g].name] = g < args.count ? args[g] : .unknown }
    return map
  }

  /// One autoderef step: through a reference, `Deref::Target`, an array to its slice.
  func derefStep(_ ty: Ty) -> Ty? {
    switch ty {
    case .constructed(let kind, let args):
      if kind == RustTy.reference { return args.first }
      if kind == Ty.array, let element = args.first { return .constructed(Ty.slice, [element]) }
      return nil
    case .nominal:
      if let target = associatedType(of: ty, named: RustWord.target, trait: RustWord.deref), target != ty { return target }
      return nil
    default:
      return nil
    }
  }

  // MARK: Values

  /// A declaration's type as a value: a field's, a constant's, a function's signature, a unit struct's or variant's own.
  func valueType(of ref: DeclRef) -> Ty {
    if let known = valueTypes[ref] { return known }
    guard resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    let item = decl(ref)
    var result = Ty.unknown
    switch item.kind {
    case .variable:
      if item.typeStart >= 0 {
        result = typeFrom(ref.unit, item.typeStart, item.typeEnd)
        // `thread_local!`'s statics are `LocalKey`s.
        if item.isFailable, let key = stdType("LocalKey") { result = .nominal(key, [result]) }
      } else if item.initStart >= 0 {
        result = expressionType(ref.unit, Int(item.initStart), Int(item.initEnd))
      }
    case .function:
      result = .function([], returnType(of: ref))
    case .structure:
      result = ownType(ref)
    case .enumCase:
      result = ownType(DeclRef(unit: ref.unit, decl: item.parent))
    default:
      break
    }
    valueTypes[ref] = result
    return result
  }

  func returnType(of ref: DeclRef) -> Ty {
    let item = decl(ref)
    guard item.typeStart >= 0 else { return .tuple([], []) }
    return typeFrom(ref.unit, item.typeStart, item.typeEnd)
  }

  /// A standard type the stub declares, by name.
  func stdType(_ word: String) -> DeclRef? {
    if let known = stdTypes[word] { return known }
    var found: DeclRef?
    if let module = project.ensureModule(RustWord.std, display: "std") {
      for index in module.units {
        let holder = project.units[Int(index)]
        if let at = holder.decls.firstIndex(where: { $0.name == name(word) && ($0.kind == .structure || $0.kind == .enumeration || $0.kind == .protocolType) }) {
          found = DeclRef(unit: index, decl: Int32(at))
          break
        }
      }
    }
    stdTypes[word] = found
    return found
  }

  func stdNominal(_ word: String, _ args: [Ty] = []) -> Ty {
    guard let ref = stdType(word) else { return .unknown }
    return .nominal(ref, args)
  }

  func isNamed(_ ty: Ty, _ word: Name) -> Bool {
    if case .nominal(let ref, _) = ty { return decl(ref).name == word }
    return false
  }

  func peelReferences(_ ty: Ty) -> Ty {
    var current = ty
    while case .constructed(let kind, let args) = current, kind == RustTy.reference, let inner = args.first { current = inner }
    return current
  }

  /// A field's type on a receiver, through autoderef.
  func fieldType(_ receiver: Ty, _ word: Name) -> Ty {
    for hit in memberHits(of: receiver, named: word, call: false) {
      let item = decl(hit.ref)
      guard item.kind == .variable, item.typeStart >= 0 else { continue }
      return substitute(typeFrom(hit.ref.unit, item.typeStart, item.typeEnd), hit.map)
    }
    // `t.0` on a tuple.
    let peeled = peelReferences(receiver)
    if case .tuple(let items, _) = peeled, let index = Int(nameText(word) ?? ""), index < items.count { return items[index] }
    return .unknown
  }

  func nameText(_ word: Name) -> String? {
    for k in 0..<16 where name(String(k)) == word { return String(k) }
    return nil
  }
}

struct BoundKey: Hashable {
  var word: Name
  var owner: DeclRef
}

struct ImplsKey: Hashable {
  let ty: Ty
  let traitsOnly: Bool
  let blankets: Bool
}

struct ImplementsKey: Hashable {
  let ty: Ty
  let trait: DeclRef
}

struct TypeKey: Hashable {
  let unit: ObjectIdentifier
  let start: Int32
  let end: Int32
}
