import CodeModel
import CodeScan
import Foundation

/// Types: written ones read from tokens, a declaration's supertypes and members, a value's type, a local's.
extension DartModel {
  // MARK: Written types

  struct Cursor {
    var i: Int
    var sub = 0
  }

  /// A type written from `start` to `end`, its names looked up from token `scope` (type parameters around it, then the
  /// library's scope).
  package func parseType(unitIndex: Int32, start: Int32, end: Int32, scope: Int32) -> Ty {
    guard start >= 0, start < end else { return .unknown }
    var cursor = Cursor(i: Int(start))
    return readType(unitIndex, &cursor, min(Int(end), project.units[Int(unitIndex)].tokens.count), scope)
  }

  private func char(_ unit: Unit, _ c: Cursor, _ end: Int) -> UInt8? {
    guard c.i < end, unit.tokens[c.i].kind == .punctuation else { return nil }
    return unit.source.text[unit.tokens[c.i].start + c.sub]
  }

  private func advance(_ unit: Unit, _ c: inout Cursor) {
    if unit.tokens[c.i].kind == .punctuation, c.sub + 1 < unit.tokens[c.i].length {
      c.sub += 1
    } else {
      c.i += 1
      c.sub = 0
    }
  }

  private func readType(_ unitIndex: Int32, _ c: inout Cursor, _ end: Int, _ scope: Int32) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard c.i < end, c.sub == 0 else { return .unknown }
    c.i = unit.daSkipMetadata(c.i, limit: end)
    while c.i < end, unit.isToken(c.i, "covariant") || unit.isToken(c.i, "required") || unit.isToken(c.i, "final") {
      c.i += 1
    }
    guard c.i < end else { return .unknown }
    var ty: Ty
    if unit.isToken(c.i, "Function") {
      ty = .unknown
    } else if unit.isByte(c.i, 0x28) {
      let close = unit.skipBalanced(c.i) - 1
      guard close < end else { return .unknown }
      let (elements, labels) = recordElements(unitIndex, open: c.i, close: close, scope: scope)
      ty = .tuple(elements, labels)
      c.i = close + 1
    } else if unit.isToken(c.i, "void") {
      ty = .constructed(DartWord.voidWord, [])
      c.i += 1
    } else if unit.daIsName(c.i) {
      var words = [c.i]
      c.i += 1
      if c.i + 1 < end, unit.isByte(c.i, 0x2E), unit.daIsName(c.i + 1) {
        words.append(c.i + 1)
        c.i += 2
      }
      var args: [Ty] = []
      if char(unit, c, end) == 0x3C { args = readArguments(unitIndex, &c, end, scope) }
      ty = typeNamed(words, args, unitIndex: unitIndex, scope: scope)
    } else {
      return .unknown
    }
    if char(unit, c, end) == 0x3F {
      ty = optional(ty)
      advance(unit, &c)
    }
    // `R Function(…)`, `R Function<T>(…)?`.
    while c.sub == 0, c.i < end, unit.isToken(c.i, "Function") {
      var k = c.i + 1
      if k < end, unit.tokens[k].kind == .punctuation, unit.startsWith(k, 0x3C), let after = unit.daTypeArgumentsEnd(k, limit: end) { k = after }
      guard k < end, unit.isByte(k, 0x28) else {
        c.i += 1
        return coreTy(DartWord.functionWord)
      }
      let close = unit.skipBalanced(k) - 1
      ty = .function(parameterTypes(unitIndex, open: k, close: close, scope: scope), ty)
      c.i = close + 1
      c.sub = 0
      if char(unit, c, end) == 0x3F {
        ty = optional(ty)
        advance(unit, &c)
      }
    }
    return ty
  }

  private func readArguments(_ unitIndex: Int32, _ c: inout Cursor, _ end: Int, _ scope: Int32) -> [Ty] {
    let unit = project.units[Int(unitIndex)]
    advance(unit, &c)
    var args: [Ty] = []
    var budget = 32
    while c.i < end, budget > 0 {
      budget -= 1
      let before = c
      args.append(readType(unitIndex, &c, end, scope))
      if char(unit, c, end) == 0x2C {
        advance(unit, &c)
        continue
      }
      if c.sub == 0, unit.isByte(c.i, 0x2C) {
        c.i += 1
        continue
      }
      if char(unit, c, end) == 0x3E {
        advance(unit, &c)
        break
      }
      if before.i == c.i, before.sub == c.sub { advance(unit, &c) }
      break
    }
    return args
  }

  /// A record type's fields between its parentheses: positional, then `{named}` ones with their names as labels.
  private func recordElements(_ unitIndex: Int32, open: Int, close: Int, scope: Int32) -> ([Ty], [Name]) {
    let unit = project.units[Int(unitIndex)]
    var elements: [Ty] = []
    var labels: [Name] = []
    var named = false
    var c = Cursor(i: open + 1)
    var budget = 64
    while c.i < close, budget > 0 {
      budget -= 1
      if c.sub == 0, unit.isByte(c.i, 0x7B) || unit.isByte(c.i, 0x7D) || unit.isByte(c.i, 0x2C) {
        if unit.isByte(c.i, 0x7B) { named = true }
        c.i += 1
        continue
      }
      let start = c.i
      let ty = readType(unitIndex, &c, close, scope)
      if c.i == start {
        c.i += 1
        continue
      }
      var label: Name = 0
      if c.sub == 0, c.i < close, unit.daIsName(c.i) {
        if named { label = unit.hash(c.i) }
        c.i += 1
      }
      elements.append(ty)
      labels.append(label)
    }
    return (elements, labels)
  }

  /// A function type's or function's positional parameters' types between its parentheses (`[optional]` ones too).
  func parameterTypes(_ unitIndex: Int32, open: Int, close: Int, scope: Int32) -> [Ty] {
    let unit = project.units[Int(unitIndex)]
    var types: [Ty] = []
    var k = open + 1
    while k < close {
      if unit.isByte(k, 0x7B) { break }
      if unit.isByte(k, 0x5B) || unit.isByte(k, 0x5D) || unit.isByte(k, 0x2C) {
        k += 1
        continue
      }
      var end = k
      while end < close, !unit.isByte(end, 0x2C), !unit.isByte(end, 0x5D) {
        if unit.tokens[end].kind == .punctuation, unit.startsWith(end, 0x3C), let after = unit.daTypeArgumentsEnd(end, limit: close) {
          end = after
          continue
        }
        end = unit.tokens[end].kind == .open && !unit.isByte(end, 0x5B) ? unit.skipBalanced(end) : end + 1
      }
      var s = unit.daSkipMetadata(k, limit: end)
      while s < end, unit.isToken(s, "covariant") || unit.isToken(s, "required") || unit.isToken(s, "final") { s += 1 }
      if let typeEnd = unit.daTypeEnd(s, limit: end), typeEnd > s, typeEnd == end || unit.daIsName(typeEnd) && (typeEnd + 1 == end || unit.isToken(typeEnd + 1, "=")) {
        types.append(parseType(unitIndex: unitIndex, start: Int32(s), end: Int32(typeEnd), scope: scope))
      } else if unit.daIsName(s), unit.isByte(s + 1, 0x28) || unit.daIsName(s + 1) && unit.isByte(s + 2, 0x28) {
        types.append(.function([], .unknown))
      } else {
        types.append(.unknown)
      }
      k = end
    }
    return types
  }

  /// `T?`: `dynamic` and nullable types stay as they are.
  func optional(_ ty: Ty) -> Ty {
    switch ty {
    case .unknown, .optional: return ty
    default: return .optional(ty)
    }
  }

  func nonNull(_ ty: Ty) -> Ty {
    if case .optional(let inner) = ty { return inner }
    return ty
  }

  /// A type's name with its arguments: a type parameter, a library's (or a prefix's) type, a typedef's type.
  private func typeNamed(_ words: [Int], _ args: [Ty], unitIndex: Int32, scope: Int32) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let word = unit.hash(words[0])
    var refs: [DeclRef]
    if words.count == 2 {
      guard let names = self.scope(ofUnit: unitIndex).prefixes[word] else { return .unknown }
      refs = names.names[unit.hash(words[1])] ?? []
    } else {
      if word == DartWord.dynamicWord || word == DartWord.neverWord { return .unknown }
      if let (_, ty) = genericSite(word, unitIndex: unitIndex, token: scope) { return ty }
      refs = libraryLookup(word, unitIndex: unitIndex)
    }
    guard let ref = refs.first(where: { decl($0).kind.isType }) else { return .unknown }
    return typeOf(ref, args)
  }

  /// A type declaration with arguments: a typedef expanded.
  func typeOf(_ ref: DeclRef, _ args: [Ty]) -> Ty {
    let item = decl(ref)
    guard item.kind == .typeAlias else { return .nominal(ref, args) }
    guard resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    let map = argumentMap(ref, args)
    let holder = unit(ref)
    if item.typeStart >= 0, item.typeEnd > item.nameToken, item.typeStart <= item.nameToken {
      // `typedef R Name<T>(params);`.
      let result = item.typeStart < item.nameToken ? parseType(unitIndex: ref.unit, start: item.typeStart, end: item.nameToken, scope: item.nameToken) : .unknown
      var open = Int(item.nameToken) + 1
      if holder.tokens[open].kind == .punctuation, holder.startsWith(open, 0x3C), let after = holder.daTypeArgumentsEnd(open) { open = after }
      guard holder.isByte(open, 0x28) else { return .unknown }
      let params = parameterTypes(ref.unit, open: open, close: holder.skipBalanced(open) - 1, scope: item.nameToken)
      return substitute(.function(params, result), map)
    }
    return substitute(parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: item.nameToken), map)
  }

  /// A declaration's parameters to the arguments given; missing ones are unknown (a raw type's are `dynamic`).
  func argumentMap(_ ref: DeclRef, _ args: [Ty]) -> [Name: Ty] {
    let holder = unit(ref)
    let item = decl(ref)
    guard item.genericCount > 0 else { return [:] }
    var map: [Name: Ty] = [:]
    for g in 0..<Int(item.genericCount) { map[holder.generics[Int(item.genericStart) + g].name] = g < args.count ? args[g] : .unknown }
    return map
  }

  // MARK: Hierarchy

  /// A type parameter's bound: `T extends Bound`.
  func bound(of ty: Ty) -> Ty? {
    guard case .param(let word, let owner?) = ty else { return nil }
    let holder = unit(owner)
    let item = decl(owner)
    for g in 0..<Int(item.genericCount) where holder.generics[Int(item.genericStart) + g].name == word {
      let token = Int(holder.generics[Int(item.genericStart) + g].token)
      guard holder.isToken(token + 1, "extends"), let end = holder.daTypeEnd(token + 2) else { return nil }
      let found = parseType(unitIndex: owner.unit, start: Int32(token + 2), end: Int32(end), scope: item.nameToken)
      return found == .unknown ? nil : found
    }
    return nil
  }

  package func memberBase(_ ty: Ty, depth: Int = 0) -> Ty {
    switch ty {
    case .param:
      guard depth < 6, let found = bound(of: ty) else { return coreTy(DartWord.objectWord) }
      return memberBase(found, depth: depth + 1)
    case .optional(let inner):
      return memberBase(inner, depth: depth + 1)
    case .function:
      return coreTy(DartWord.functionWord)
    case .tuple:
      return coreTy(DartWord.recordWord)
    case .constructed:
      return .unknown
    default:
      return ty
    }
  }

  /// A declaration's direct supertypes in the order members are found: mixins (the last first), the superclass (or
  /// `Object`), interfaces, a mixin's `on` types; an enum's `Enum`.
  package func supertypes(of ref: DeclRef) -> [Ty] {
    if let known = supertypeCache[ref] { return known }
    supertypeCache[ref] = []
    let item = decl(ref)
    let holder = unit(ref)
    var result: [Ty] = []
    var objectAt: Int?
    var hasSuperclass = false
    for r in 0..<Int(item.inheritCount) {
      let range = holder.ranges[Int(item.inheritStart) + r]
      if objectAt == nil, holder.isToken(Int(range.start) - 1, "implements") || holder.isToken(Int(range.start) - 1, "on") { objectAt = result.count }
      if holder.isToken(Int(range.start) - 1, "extends") || holder.isToken(Int(range.start) - 1, "=") { hasSuperclass = true }
      let ty = parseType(unitIndex: ref.unit, start: range.start, end: range.end, scope: item.nameToken)
      guard case .nominal(let target, _) = ty, target != ref, !result.contains(ty) else { continue }
      result.append(ty)
    }
    if item.kind == .extensionDecl {
      supertypeCache[ref] = result
      return result
    }
    if item.kind == .enumeration, let base = coreType(DartWord.enumWord) {
      result.insert(.nominal(base, []), at: min(objectAt ?? result.count, result.count))
    } else if !hasSuperclass, let object = coreType(DartWord.objectWord), object != ref {
      result.insert(.nominal(object, []), at: min(objectAt ?? result.count, result.count))
    }
    supertypeCache[ref] = result
    return result
  }

  /// A class's superclass: what it extends, else `Object`.
  func superclassType(_ ref: DeclRef) -> Ty? {
    let item = decl(ref)
    let holder = unit(ref)
    for r in 0..<Int(item.inheritCount) {
      let range = holder.ranges[Int(item.inheritStart) + r]
      if holder.isToken(Int(range.start) - 1, "extends") || holder.isToken(Int(range.start) - 1, "=") {
        return parseType(unitIndex: ref.unit, start: range.start, end: range.end, scope: item.nameToken)
      }
    }
    if item.kind == .enumeration { return coreType(DartWord.enumWord).map { .nominal($0, []) } }
    return coreType(DartWord.objectWord).flatMap { $0 == ref ? nil : .nominal($0, []) }
  }

  /// `super`'s type in a class's body: its mixins and superclass, searched in that order.
  func superType(_ ref: DeclRef) -> Ty {
    let all = supertypes(of: ref)
    guard !all.isEmpty else { return .unknown }
    return .existential(all)
  }

  /// A type's members by name: its own (statics too, not constructors), then what its supertypes have that it doesn't
  /// declare, nearest first (statics aren't inherited). An extension's are its own.
  func memberTable(of ref: DeclRef) -> [Name: [MemberEntry]] {
    if let known = tables[ref] { return known }
    guard building.insert(ref).inserted else { return [:] }
    defer { building.remove(ref) }
    var table: [Name: [MemberEntry]] = [:]
    let holder = unit(ref)
    for child in holder.children(of: ref.decl) {
      let entry = holder.decls[Int(child)]
      guard entry.name != 0, entry.kind != .initializer, !entry.isLocal else { continue }
      table[entry.name, default: []].append(MemberEntry(ref: DeclRef(unit: ref.unit, decl: child), substitution: [:]))
    }
    let own = Set(table.keys)
    for parent in supertypes(of: ref) {
      guard case .nominal(let target, let args) = parent else { continue }
      let map = argumentMap(target, args)
      for (word, entries) in memberTable(of: target) where !own.contains(word) {
        for entry in entries {
          let item = decl(entry.ref)
          if item.isStatic || item.kind == .enumCase { continue }
          let composed = entry.substitution.mapValues { substitute($0, map) }.merging(map) { first, _ in first }
          table[word, default: []].append(MemberEntry(ref: entry.ref, substitution: composed))
        }
      }
    }
    tables[ref] = table
    return table
  }

  /// A type's members of a name, nearest first, with the receiver's arguments put in.
  func memberEntries(of ty: Ty, named word: Name) -> [(MemberEntry, Ty)] {
    let base = memberBase(ty)
    guard case .nominal(let ref, let args) = base else { return [] }
    let map = argumentMap(ref, args)
    return (memberTable(of: ref)[word] ?? []).map { entry in
      var composed = entry
      composed.substitution = entry.substitution.mapValues { substitute($0, map) }.merging(map) { first, _ in first }
      return (composed, base)
    }
  }

  /// What an extension is on.
  func onType(_ ref: DeclRef) -> Ty {
    if let known = onTypes[ref] { return known }
    let item = decl(ref)
    let found = parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: item.nameToken)
    onTypes[ref] = found
    return found
  }

  /// The members of a name of the extensions in scope that apply to a receiver, the most specific's: their own type
  /// parameters bound from it.
  func extensionMembers(_ word: Name, receiver: Ty, unitIndex: Int32) -> [MemberEntry] {
    guard receiver != .unknown else { return [] }
    var found: [(MemberEntry, Int)] = []
    for ext in scope(ofUnit: unitIndex).extensions {
      let holder = unit(ext)
      let members = holder.children(of: ext.decl).filter { holder.decls[Int($0)].name == word && !holder.decls[Int($0)].isStatic }
      guard !members.isEmpty, let (map, distance) = applies(ext, to: receiver) else { continue }
      for member in members { found.append((MemberEntry(ref: DeclRef(unit: ext.unit, decl: member), substitution: map), distance)) }
    }
    guard let best = found.map(\.1).min() else { return [] }
    return found.filter { $0.1 == best }.map(\.0)
  }

  /// Whether an extension applies to a receiver: its type parameters bound, and how far up the receiver's hierarchy
  /// its on-type is (an on-type that's a type parameter is the least specific).
  func applies(_ ext: DeclRef, to receiver: Ty) -> ([Name: Ty], Int)? {
    let on = nonNull(onType(ext))
    let actual = nonNull(receiver)
    let holder = unit(ext)
    let item = decl(ext)
    var own: Set<Name> = []
    for g in 0..<Int(item.genericCount) { own.insert(holder.generics[Int(item.genericStart) + g].name) }
    var bindings: [Name: Ty] = [:]
    switch on {
    case .param(let word, _):
      guard own.contains(word) else { return nil }
      if let bound = bound(of: on), case .nominal(let target, _) = bound, asSupertype(actual, target) == nil { return nil }
      bindings[word] = actual
      return (bindings, 1000)
    case .nominal(let target, let args):
      guard let found = asSupertype(actual, target) else { return nil }
      if case .nominal(_, let actualArgs) = found {
        // `on Pointer<Uint8>` isn't on a `Pointer<Int8>`.
        for (a, b) in zip(args, actualArgs) where !fits(a, b, own) { return nil }
        for (a, b) in zip(args, actualArgs) { unify(a, b, own, &bindings) }
      }
      let distance = hierarchy(of: actual).first { $0.0 == target }?.1 ?? 0
      return (bindings, distance)
    case .function:
      guard case .function = actual else { return nil }
      return (bindings, 0)
    case .tuple:
      guard case .tuple = actual else { return nil }
      return (bindings, 0)
    default:
      return nil
    }
  }

  /// Whether a type argument of an extension's on-type can take an actual one: its own type parameters take anything,
  /// a class its subclasses (covariant); what isn't known fits.
  private func fits(_ pattern: Ty, _ actual: Ty, _ own: Set<Name>) -> Bool {
    switch (nonNull(pattern), nonNull(actual)) {
    case (.param(let word, _), .nominal):
      // `<T extends AbiSpecificInteger> on Pointer<T>` isn't on a `Pointer<Uint64>`.
      guard own.contains(word), let limit = bound(of: pattern), case .nominal(let target, _) = nonNull(limit) else { return true }
      return asSupertype(nonNull(actual), target) != nil
    case (.param, _): return true
    case (.nominal(let target, let args), .nominal):
      guard let found = asSupertype(nonNull(actual), target) else { return false }
      guard case .nominal(_, let actualArgs) = found else { return true }
      return !zip(args, actualArgs).contains { !fits($0, $1, own) }
    default: return true
    }
  }

  // MARK: Values

  /// A declaration's type as a value: a field's, getter's (or setter's parameter's), a function's result, a
  /// constructor's class, an enum value's enum, a type's own (for its static members).
  package func valueType(of ref: DeclRef) -> Ty {
    if let known = valueTypes[ref] { return known }
    guard resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    let item = decl(ref)
    let holder = unit(ref)
    var result = Ty.unknown
    switch item.kind {
    case .variable:
      if item.typeStart >= 0 {
        result = parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: item.nameToken)
      } else if item.paramCount > 0 {
        result = parameterType(ref, 0)
      } else if item.initStart >= 0 {
        result = expressionType(unitIndex: ref.unit, start: item.initStart, end: item.initEnd)
        if case .meta = result { result = .unknown }
        if holder.isToken(Int(item.initStart), "null") { result = .unknown }
      } else if let overridden = overridden(ref) {
        result = valueType(of: overridden)
      }
    case .function:
      if item.typeStart >= 0 {
        result = parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: item.nameToken)
      } else if item.name == name("==") {
        result = coreTy(DartWord.boolWord)
      } else if let overridden = overridden(ref) {
        result = valueType(of: overridden)
      }
    case .initializer:
      if item.parent >= 0 { result = ownType(DeclRef(unit: ref.unit, decl: item.parent)) }
    case .enumCase:
      if item.parent >= 0 { result = .nominal(DeclRef(unit: ref.unit, decl: item.parent), []) }
    case .classType, .enumeration, .structure, .extensionDecl:
      result = .meta(.nominal(ref, []))
    case .typeAlias:
      result = .meta(typeOf(ref, []))
    default:
      break
    }
    valueTypes[ref] = result
    return result
  }

  /// What a member overrides: the nearest supertype's member of its name.
  func overridden(_ ref: DeclRef) -> DeclRef? {
    let item = decl(ref)
    guard item.parent >= 0, !item.isStatic else { return nil }
    let owner = DeclRef(unit: ref.unit, decl: item.parent)
    for parent in supertypes(of: owner) {
      if let entry = memberEntries(of: parent, named: item.name).first, entry.0.ref != ref { return entry.0.ref }
    }
    return nil
  }

  /// A member's type through the type it was found on.
  func memberValueType(_ entry: MemberEntry) -> Ty { substitute(valueType(of: entry.ref), entry.substitution) }

  /// A declaration's parameter's type: written (a function-typed one's function type), a field formal's field's, a super
  /// parameter's, an override's.
  func parameterType(_ ref: DeclRef, _ index: Int) -> Ty {
    let item = decl(ref)
    let holder = unit(ref)
    guard index < Int(item.paramCount) else { return .unknown }
    let param = holder.params[Int(item.paramStart) + index]
    if param.typeStart >= 0 {
      if param.typeEnd > param.nameToken {
        // `void f(int x)`: a function type.
        let result = param.typeStart < param.nameToken ? parseType(unitIndex: ref.unit, start: param.typeStart, end: param.nameToken, scope: param.nameToken) : .unknown
        var open = Int(param.nameToken) + 1
        if holder.tokens[open].kind == .punctuation, holder.startsWith(open, 0x3C), let after = holder.daTypeArgumentsEnd(open) { open = after }
        guard holder.isByte(open, 0x28) else { return .unknown }
        return .function(parameterTypes(ref.unit, open: open, close: holder.skipBalanced(open) - 1, scope: param.nameToken), result)
      }
      return parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: param.nameToken)
    }
    let token = Int(param.nameToken)
    if holder.isByte(token - 1, 0x2E), holder.isToken(token - 2, "this"), item.parent >= 0 {
      let owner = DeclRef(unit: ref.unit, decl: item.parent)
      if let entry = memberEntries(of: ownType(owner), named: param.local).first { return memberValueType(entry.0) }
      return .unknown
    }
    if holder.isByte(token - 1, 0x2E), holder.isToken(token - 2, "super"), let target = superConstructor(ref) {
      let targetDecl = decl(target)
      let targetUnit = unit(target)
      for p in 0..<Int(targetDecl.paramCount) where targetUnit.params[Int(targetDecl.paramStart) + p].local == param.local {
        return parameterType(target, p)
      }
      return .unknown
    }
    if let overridden = overridden(ref) {
      let other = decl(overridden)
      let otherUnit = unit(overridden)
      for p in 0..<Int(other.paramCount) {
        let candidate = otherUnit.params[Int(other.paramStart) + p]
        if param.label != 0 ? candidate.label == param.label : p == index && candidate.label == 0 { return parameterType(overridden, p) }
      }
    }
    return .unknown
  }

  /// What a declaration is as a function: its positional parameters' types and its result.
  func functionType(_ ref: DeclRef) -> Ty {
    let item = decl(ref)
    let holder = unit(ref)
    var params: [Ty] = []
    for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].label == 0 { params.append(parameterType(ref, p)) }
    return .function(params, valueType(of: ref))
  }

  /// A local's type: written, inferred from its initializer, an element of what `for` walks, a closure's parameter from
  /// the function type it's passed as, a caught exception's.
  func localType(unitIndex: Int32, body: DartBody, index: Int32) -> Ty {
    if let known = body.types[index] { return known }
    guard body.resolving.insert(index).inserted else { return .unknown }
    defer { body.resolving.remove(index) }
    let local = body.locals[Int(index)]
    let unit = project.units[Int(unitIndex)]
    var result = Ty.unknown
    switch local.kind {
    case .typed(let start, let end):
      if end > local.token, start <= local.token {
        // A function-typed parameter of a closure or local function: `void f(int x)`.
        let open = Int(local.token) + 1
        if unit.isByte(open, 0x28) {
          let returns = start < local.token ? parseType(unitIndex: unitIndex, start: start, end: local.token, scope: local.token) : .unknown
          result = .function(parameterTypes(unitIndex, open: open, close: unit.skipBalanced(open) - 1, scope: local.token), returns)
        }
      } else {
        result = parseType(unitIndex: unitIndex, start: start, end: end, scope: local.token)
      }
    case .inferred(let start, let end):
      result = expressionType(unitIndex: unitIndex, start: start, end: end)
      if case .meta = result { result = .unknown }
      if unit.isToken(Int(start), "null"), end == start + 1 { result = .unknown }
    case .element(let start, let end, let isAwait):
      let walked = expressionType(unitIndex: unitIndex, start: start, end: end)
      result = isAwait ? streamElement(walked) : iterableElement(walked)
    case .closure(let open, let position):
      result = closureParameterType(unitIndex: unitIndex, open: Int(open), position: Int(position))
    case .caught(let start, let end):
      result = start >= 0 ? parseType(unitIndex: unitIndex, start: start, end: end, scope: local.token) : coreTy(DartWord.objectWord)
    case .stackTrace:
      result = coreTy(DartWord.stackTraceWord)
    case .function(let token):
      result = localFunctionType(unitIndex: unitIndex, token: Int(token))
    case .parameter(let p):
      result = parameterType(DeclRef(unit: unitIndex, decl: body.owner), Int(p))
    case .unknown:
      result = patternVariableType(unitIndex: unitIndex, token: Int(local.token))
    }
    body.types[index] = result
    return result
  }

  /// A local's type at a token: narrowed by an `is` check around it.
  func localType(unitIndex: Int32, body: DartBody, index: Int32, at token: Int32) -> Ty {
    let local = body.locals[Int(index)]
    if let narrowing = body.narrowing(of: local.name, at: token), body.local(named: local.name, at: narrowing.subject) == index {
      let narrowed = parseType(unitIndex: unitIndex, start: narrowing.typeStart, end: narrowing.typeEnd, scope: narrowing.subject)
      if narrowed != .unknown {
        // `x is List` where x is `List<int>`: the arguments it had.
        if case .nominal(let ref, let args) = narrowed, args.isEmpty, decl(ref).genericCount > 0, let had = asSupertype(localType(unitIndex: unitIndex, body: body, index: index), ref) {
          return had
        }
        return narrowed
      }
    }
    return localType(unitIndex: unitIndex, body: body, index: index)
  }

  /// A pattern's variable: `int x`, `final String s` written before it.
  private func patternVariableType(unitIndex: Int32, token: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var k = token - 1
    guard k >= 0, !unit.isToken(k, "var"), !unit.isToken(k, "final") else { return .unknown }
    // Back over a type: names, dots, type arguments, `?`.
    var budget = 30
    while k > 0, budget > 0, unit.daIsName(k - 1) || unit.isByte(k - 1, 0x2E) || unit.tokens[k - 1].kind == .punctuation && unit.punctuation(k - 1, madeOf: "<>?,") {
      budget -= 1
      if unit.isByte(k - 1, 0x2C), !isInsideAngles(unit, k - 1) { break }
      k -= 1
    }
    guard unit.daTypeEnd(k, limit: token) == token else { return .unknown }
    return parseType(unitIndex: unitIndex, start: Int32(k), end: Int32(token), scope: Int32(token))
  }

  private func isInsideAngles(_ unit: Unit, _ comma: Int) -> Bool {
    var depth = 0
    var k = comma - 1
    while k >= 0, comma - k < 30 {
      if unit.tokens[k].kind == .punctuation {
        for b in (0..<unit.tokens[k].length).reversed() {
          let byte = unit.source.text[unit.tokens[k].start + b]
          if byte == 0x3E { depth += 1 } else if byte == 0x3C {
            if depth == 0 { return true }
            depth -= 1
          }
        }
      } else if unit.tokens[k].kind == .open || unit.tokens[k].kind == .close {
        return false
      }
      k -= 1
    }
    return false
  }

  /// A local function as a value: its return type written before its name.
  func localFunctionType(unitIndex: Int32, token: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var start = token
    while start > 0, !unit.isByte(start - 1, 0x3B), !unit.isByte(start - 1, 0x7B), !unit.isByte(start - 1, 0x7D) { start -= 1 }
    let returns = start < token ? parseType(unitIndex: unitIndex, start: Int32(start), end: Int32(token), scope: Int32(token)) : .unknown
    var open = token + 1
    if unit.tokens.indices.contains(open), unit.tokens[open].kind == .punctuation, unit.startsWith(open, 0x3C), let after = unit.daTypeArgumentsEnd(open) { open = after }
    guard unit.isByte(open, 0x28) else { return .function([], returns) }
    return .function(parameterTypes(unitIndex, open: open, close: unit.skipBalanced(open) - 1, scope: Int32(token)), returns)
  }

  /// What `for (x in e)` gives: an `Iterable<T>`'s T.
  func iterableElement(_ ty: Ty) -> Ty {
    guard let iterable = coreType(DartWord.iterableWord), case .nominal(_, let args)? = asSupertype(nonNull(ty), iterable) else { return .unknown }
    return args.first ?? .unknown
  }

  /// What `await for (x in e)` gives: a `Stream<T>`'s T.
  func streamElement(_ ty: Ty) -> Ty {
    guard let stream = coreType(DartWord.streamWord), case .nominal(_, let args)? = asSupertype(nonNull(ty), stream) else { return .unknown }
    return args.first ?? .unknown
  }

  /// What `await e` gives: a `Future<T>`'s or `FutureOr<T>`'s T, else the type itself.
  func awaited(_ ty: Ty) -> Ty {
    let base = nonNull(ty)
    if case .nominal(let ref, let args) = base, decl(ref).name == DartWord.futureOrWord, isSDK(ref) { return args.first ?? .unknown }
    if let future = coreType(DartWord.futureWord), case .nominal(_, let args)? = asSupertype(base, future) { return args.first ?? .unknown }
    return ty
  }
}
