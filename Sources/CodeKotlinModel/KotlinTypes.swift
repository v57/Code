import CodeJavaModel
import CodeModel
import CodeScan
import Foundation

/// A function a call may mean: the declaration (a class for its primary constructor), how its declaring type's and
/// an extension's receiver's parameters read here, and the receiver it's called on.
struct Callee {
  var ref: DeclRef
  var map: [Name: Ty]
  var receiver: Ty
}

/// A parameter as a call sees it.
struct KParam {
  var name: Name
  var type: Ty
  var hasDefault: Bool
  var variadic: Bool
}

enum KotlinTy {
  /// `R.(A) -> B`: the receiver and the function type.
  static let receiverFunction = hashName("R.()")
}

/// Kotlin's types (`Ty`, the core's): classes, interfaces, objects and enums `nominal` with their arguments (Java's
/// classes too, the ones Kotlin maps read as Kotlin's: `java.lang.String` is `kotlin.String`), a type parameter
/// `param`, a function type `function` (with a receiver, `constructed(receiverFunction, [R, function])`), a class used
/// for its companion, nested classes and Java statics `meta`, a package `module`. Nullability isn't kept: `?.` and
/// `!!` reach the same members.
extension KotlinModel {
  // MARK: Written types

  struct Cursor {
    var i: Int
    var sub = 0
  }

  /// A type written from `start` to `end`, its names looked up from token `scope`.
  func parseType(unitIndex: Int32, start: Int32, end: Int32, scope: Int32) -> Ty {
    guard start >= 0, start < end else { return .unknown }
    if isJava(unitIndex) { return fromJava(java.parseType(unitIndex: unitIndex, start: start, end: end, scope: scope)) }
    depth += 1
    defer { depth -= 1 }
    guard depth < 40 else { return .unknown }
    var cursor = Cursor(i: Int(start))
    return readType(unitIndex, &cursor, Int(end), scope)
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

  private func skipQuestionMarks(_ unit: Unit, _ c: inout Cursor, _ end: Int) {
    while char(unit, c, end) == 0x3F { advance(unit, &c) }
  }

  private func readType(_ unitIndex: Int32, _ c: inout Cursor, _ end: Int, _ scope: Int32) -> Ty {
    let unit = project.units[Int(unitIndex)]
    if c.sub > 0 {
      // Inside a run of punctuation: `<*>`, `>?`.
      if char(unit, c, end) == 0x2A { advance(unit, &c) }
      return .unknown
    }
    c.i = unit.ktSkipAnnotations(c.i, limit: end)
    if unit.isToken(c.i, "suspend") { c.i += 1 }
    guard c.i < end else { return .unknown }
    var ty: Ty
    if unit.isByte(c.i, 0x2A) || char(unit, c, end) == 0x2A {
      advance(unit, &c)
      return .unknown
    }
    if unit.isByte(c.i, 0x28) {
      let close = unit.skipBalanced(c.i)
      if close < end, unit.isToken(close, "->") {
        let params = functionParameters(unitIndex, open: c.i, close: close - 1, scope: scope)
        c.i = close + 1
        c.sub = 0
        let result = readType(unitIndex, &c, end, scope)
        return .function(params, result)
      }
      var inner = Cursor(i: c.i + 1)
      ty = readType(unitIndex, &inner, close - 1, scope)
      c.i = close
      c.sub = 0
    } else if unit.ktIsName(c.i) {
      ty = .unknown
      var package = ""
      var first = true
      while c.i < end, c.sub == 0, unit.ktIsName(c.i) {
        let word = unit.hash(c.i)
        let text = unit.string(c.i)
        c.i += 1
        var args: [Ty] = []
        if char(unit, c, end) == 0x3C, unit.ktTypeArgumentsEnd(c.i, limit: end) != nil {
          advance(unit, &c)
          args = readArguments(unitIndex, &c, end, scope)
        }
        if first {
          first = false
          if let site = typeSites(word, unitIndex: unitIndex, token: scope).first {
            ty = typeOfSite(site, args: args)
          } else {
            package = text
          }
        } else if case .unknown = ty, !package.isEmpty {
          if let ref = packageTypes(package, named: word).first {
            ty = typeOfSite(.decl(ref), args: args)
            package = ""
          } else {
            package += "." + text
          }
        } else if ty != .unknown {
          if let ref = memberTypeRefs(of: ty, named: word).first { ty = typeOfSite(.decl(ref), args: args) } else { return .unknown }
        }
        skipQuestionMarks(unit, &c, end)
        // `A.B`, but not `A.(B) -> C`.
        if c.sub == 0, unit.isByte(c.i, 0x2E), c.i + 1 < end, unit.ktIsName(c.i + 1) {
          c.i += 1
          continue
        }
        break
      }
      if !package.isEmpty, case .unknown = ty { return .unknown }
    } else {
      return .unknown
    }
    skipQuestionMarks(unit, &c, end)
    // `R.(A) -> B`.
    if c.sub == 0, unit.isByte(c.i, 0x2E), unit.isByte(c.i + 1, 0x28) {
      let open = c.i + 1
      let close = unit.skipBalanced(open)
      if close < end, unit.isToken(close, "->") {
        let params = functionParameters(unitIndex, open: open, close: close - 1, scope: scope)
        c.i = close + 1
        c.sub = 0
        let result = readType(unitIndex, &c, end, scope)
        return .constructed(KotlinTy.receiverFunction, [ty, .function(params, result)])
      }
    }
    return ty
  }

  /// A function type's parameters `(A, name: B)`.
  private func functionParameters(_ unitIndex: Int32, open: Int, close: Int, scope: Int32) -> [Ty] {
    let unit = project.units[Int(unitIndex)]
    var result: [Ty] = []
    var i = open + 1
    while i < close {
      var end = i
      while end < close, !unit.isByte(end, 0x2C) {
        if unit.tokens[end].kind == .open {
          end = unit.skipBalanced(end)
          continue
        }
        if unit.tokens[end].kind == .punctuation, unit.ktStartsWith(end, 0x3C), let after = unit.ktTypeArgumentsEnd(end, limit: close) {
          end = after
          continue
        }
        end += 1
      }
      var start = i
      if unit.ktIsName(start), unit.isToken(start + 1, ":") { start += 2 }
      var cursor = Cursor(i: start)
      result.append(readType(unitIndex, &cursor, end, scope))
      i = end + 1
    }
    return result
  }

  /// After `<`: types up to the matching `>`.
  private func readArguments(_ unitIndex: Int32, _ c: inout Cursor, _ end: Int, _ scope: Int32) -> [Ty] {
    let unit = project.units[Int(unitIndex)]
    var args: [Ty] = []
    var guardCount = 0
    while c.i < end, guardCount < 64 {
      guardCount += 1
      if char(unit, c, end) == 0x3E {
        advance(unit, &c)
        return args
      }
      let before = (c.i, c.sub)
      if c.sub == 0, unit.isToken(c.i, "in") || unit.isToken(c.i, "out"), c.i + 1 < end, !unit.isByte(c.i + 1, 0x2C), !unit.ktOnly(c.i + 1, ">") { c.i += 1 }
      args.append(readType(unitIndex, &c, end, scope))
      if char(unit, c, end) == 0x2C {
        advance(unit, &c)
        continue
      }
      if char(unit, c, end) == 0x3E {
        advance(unit, &c)
        return args
      }
      if (c.i, c.sub) == before { advance(unit, &c) }
    }
    return args
  }

  /// A call's type arguments written after its name: `listOf<Int>(…)`, `Box<String>()`.
  func explicitTypeArguments(unitIndex: Int32, nameToken: Int) -> [Ty] {
    let unit = project.units[Int(unitIndex)]
    let open = nameToken + 1
    guard nameToken >= 0, open < unit.tokens.count, unit.tokens[open].kind == .punctuation, unit.ktStartsWith(open, 0x3C), let end = unit.ktTypeArgumentsEnd(open) else { return [] }
    var c = Cursor(i: open)
    advance(unit, &c)
    return readArguments(unitIndex, &c, end, Int32(nameToken))
  }

  /// The type parameters a call's type arguments go to, in order: a function's, a class's (a constructor's class's).
  func typeParameterNames(_ ref: DeclRef) -> [Name] {
    var item = decl(ref)
    var owner = ref
    if item.kind == .initializer, item.parent >= 0 {
      owner = DeclRef(unit: ref.unit, decl: item.parent)
      item = decl(owner)
    }
    let holder = unit(owner)
    return (0..<Int(item.genericCount)).map { holder.generics[Int(item.genericStart) + $0].name }
  }

  /// A type name's site as a type: a class with its arguments, a type alias expanded, a type parameter.
  func typeOfSite(_ site: Site, args: [Ty]) -> Ty {
    switch site {
    case .decl(let ref):
      let item = decl(ref)
      if item.kind == .typeAlias { return expandAlias(ref, args: args) }
      guard item.kind.isNominal else { return .unknown }
      if isJava(ref) { return fromJava(.nominal(ref, args)) }
      return .nominal(ref, args)
    case .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      for (index, item) in holder.decls.enumerated() where item.genericCount > 0 {
        for g in 0..<Int(item.genericCount) where holder.generics[Int(item.genericStart) + g].token == token {
          return .param(holder.hash(Int(token)), DeclRef(unit: unitIndex, decl: Int32(index)))
        }
      }
      return .param(holder.hash(Int(token)), nil)
    case .module(let package):
      return .module(package)
    case .local:
      return .unknown
    }
  }

  /// `typealias A<T> = B<T, Int>` with A's arguments put in.
  func expandAlias(_ ref: DeclRef, args: [Ty]) -> Ty {
    let item = decl(ref)
    guard item.typeStart >= 0, resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    let target = parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: item.nameToken)
    return substitute(target, parameterMap(ref, args))
  }

  /// A type parameter's bound (`T : Comparable<T>`), or nil.
  func bound(of ty: Ty) -> Ty? {
    guard case .param(let word, let owner?) = ty else { return nil }
    if isJava(owner) { return java.bound(of: ty).map(fromJava) }
    let holder = unit(owner)
    let item = decl(owner)
    for g in 0..<Int(item.genericCount) {
      let generic = holder.generics[Int(item.genericStart) + g]
      guard generic.name == word, holder.isToken(Int(generic.token) + 1, ":") else { continue }
      let start = Int(generic.token) + 2
      guard let end = holder.ktTypeEnd(start) else { return nil }
      let found = parseType(unitIndex: owner.unit, start: Int32(start), end: Int32(end), scope: generic.token)
      if case .param(let other, _) = found, other == word { return nil }
      return found
    }
    return nil
  }

  func anyType() -> Ty { kotlinType("kotlin", "Any").map { .nominal($0, []) } ?? .unknown }

  /// What a type's members are looked up in: a type parameter's bound, a function type's `Function`.
  func memberBase(_ ty: Ty, depth: Int = 0) -> Ty {
    switch ty {
    case .param:
      guard depth < 6, let found = bound(of: ty) else { return anyType() }
      return memberBase(found, depth: depth + 1)
    case .optional(let inner): return memberBase(inner, depth: depth + 1)
    case .function(let params, let result):
      // `(A, B) -> R` is a `Function2<A, B, R>`, whose `invoke` it has.
      if let ref = kotlinType("kotlin", "Function" + String(params.count)) { return .nominal(ref, params + [result]) }
      guard let ref = kotlinType("kotlin", "Function") else { return .unknown }
      return .nominal(ref, [result])
    case .constructed(let kind, let args) where kind == KotlinTy.receiverFunction:
      return args.count == 2 ? memberBase(args[1], depth: depth + 1) : .unknown
    default:
      return ty
    }
  }

  // MARK: Java's types as Kotlin sees them

  static let javaToKotlin: [String: (String, String)] = [
    "java.lang.Object": ("kotlin", "Any"), "java.lang.String": ("kotlin", "String"), "java.lang.CharSequence": ("kotlin", "CharSequence"),
    "java.lang.Throwable": ("kotlin", "Throwable"), "java.lang.Cloneable": ("kotlin", "Cloneable"), "java.lang.Number": ("kotlin", "Number"),
    "java.lang.Comparable": ("kotlin", "Comparable"), "java.lang.Enum": ("kotlin", "Enum"), "java.lang.annotation.Annotation": ("kotlin", "Annotation"),
    "java.lang.Integer": ("kotlin", "Int"), "java.lang.Long": ("kotlin", "Long"), "java.lang.Short": ("kotlin", "Short"), "java.lang.Byte": ("kotlin", "Byte"),
    "java.lang.Character": ("kotlin", "Char"), "java.lang.Boolean": ("kotlin", "Boolean"), "java.lang.Float": ("kotlin", "Float"),
    "java.lang.Double": ("kotlin", "Double"), "java.lang.Iterable": ("kotlin.collections", "MutableIterable"),
    "java.util.Iterator": ("kotlin.collections", "MutableIterator"), "java.util.Collection": ("kotlin.collections", "MutableCollection"),
    "java.util.List": ("kotlin.collections", "MutableList"), "java.util.Set": ("kotlin.collections", "MutableSet"),
    "java.util.Map": ("kotlin.collections", "MutableMap"), "java.util.ListIterator": ("kotlin.collections", "MutableListIterator"),
  ]

  static let primitives: [Name: String] = [
    name("int"): "Int", name("long"): "Long", name("short"): "Short", name("byte"): "Byte", name("char"): "Char", name("boolean"): "Boolean",
    name("float"): "Float", name("double"): "Double", name("void"): "Unit",
  ]

  /// The Kotlin class a Java class reads as, if Kotlin maps it.
  func kotlinClass(forJava ref: DeclRef) -> DeclRef? {
    if let known = mapped[ref] { return known }
    var result: DeclRef?
    let item = decl(ref)
    if item.kind.isNominal, item.name != 0 {
      let holder = unit(ref)
      let simple = holder.string(Int(item.nameToken))
      let package = packageOf(ref.unit)
      if item.parent < 0, let target = Self.javaToKotlin[package + "." + simple] {
        result = kotlinType(target.0, target.1)
      } else if item.parent >= 0, simple == "Entry", package == "java.util", holder.decls[Int(item.parent)].name == name("Map") {
        if let map = kotlinType("kotlin.collections", "MutableMap") { result = memberTypeRefs(of: .nominal(map, []), named: name("MutableEntry")).first }
      }
    }
    mapped[ref] = result
    return result
  }

  /// A type from Java's model, in Kotlin's terms.
  func fromJava(_ ty: Ty) -> Ty {
    switch ty {
    case .constructed(let kind, let args):
      if args.isEmpty, let primitive = Self.primitives[kind] { return kotlinType("kotlin", primitive).map { .nominal($0, []) } ?? .unknown }
      if kind == Ty.array, let element = args.first {
        if case .constructed(let inner, let innerArgs) = element, innerArgs.isEmpty, let primitive = Self.primitives[inner], primitive != "Unit" {
          return kotlinType("kotlin", primitive + "Array").map { .nominal($0, []) } ?? .unknown
        }
        return kotlinType("kotlin", "Array").map { .nominal($0, [fromJava(element)]) } ?? .unknown
      }
      if kind == Ty.union, let first = args.first { return fromJava(first) }
      return .unknown
    case .nominal(let ref, let args):
      let converted = args.map(fromJava)
      if isJava(ref), let target = kotlinClass(forJava: ref) { return .nominal(target, converted) }
      return .nominal(ref, converted)
    case .meta(let inner):
      // A Java class used for its statics stays Java's.
      if case .nominal(let ref, let args) = inner { return .meta(.nominal(ref, args.map(fromJava))) }
      return .meta(fromJava(inner))
    default:
      return ty
    }
  }

  // MARK: Hierarchy

  /// A class's direct supertypes as written, in terms of its own parameters, or the implicit ones (`Any`, `Enum<E>`;
  /// an enum entry's body extends its enum).
  func supertypes(of ref: DeclRef) -> [Ty] {
    if let known = supertypeCache[ref] { return known }
    supertypeCache[ref] = []
    let item = decl(ref)
    var result: [Ty] = []
    if isJava(ref) {
      result = java.supertypes(of: ref).map(fromJava)
      // A Java interface is an `Any` too.
      if item.kind == .protocolType, case .nominal(let any, _) = anyType(), !result.contains(where: { if case .nominal(any, _) = $0 { true } else { false } }) {
        result.append(.nominal(any, []))
      }
      supertypeCache[ref] = result
      return result
    }
    let holder = unit(ref)
    if item.kind == .enumCase {
      if item.parent >= 0 { result.append(.nominal(DeclRef(unit: ref.unit, decl: item.parent), [])) }
      supertypeCache[ref] = result
      return result
    }
    var hasClass = false
    for r in 0..<Int(item.inheritCount) {
      let range = holder.ranges[Int(item.inheritStart) + r]
      let ty = parseType(unitIndex: ref.unit, start: range.start, end: range.end, scope: item.name == 0 ? item.first : item.nameToken)
      guard case .nominal(let target, _) = ty, target != ref else { continue }
      if decl(target).kind == .classType || decl(target).kind == .enumeration { hasClass = true }
      result.append(ty)
    }
    let isAny = item.name == name("Any") && item.parent < 0 && packageOf(ref.unit) == "kotlin"
    if item.kind == .enumeration, let enumRef = kotlinType("kotlin", "Enum") {
      result.insert(.nominal(enumRef, [ownType(ref)]), at: 0)
    } else if !hasClass, !isAny, case .nominal(let any, _) = anyType(), any != ref {
      result.append(.nominal(any, []))
    }
    supertypeCache[ref] = result
    return result
  }

  /// The supertype of `ty` that's declared by `target`, with arguments, if `ty` is or extends it.
  func asSupertype(_ ty: Ty, _ target: DeclRef, depth: Int = 0) -> Ty? {
    guard depth < 16, case .nominal(let ref, let args) = memberBase(ty) else { return nil }
    if ref == target { return .nominal(ref, args) }
    let map = parameterMap(ref, args)
    for parent in supertypes(of: ref) {
      if let found = asSupertype(substitute(parent, map), target, depth: depth + 1) { return found }
    }
    return nil
  }

  /// Every class a type is or extends, nearest first, each with how far up it is.
  func hierarchy(of ty: Ty) -> [(DeclRef, Int)] {
    guard case .nominal(let start, _) = memberBase(ty) else { return [] }
    var result: [(DeclRef, Int)] = [(start, 0)]
    var seen: Set<DeclRef> = [start]
    var index = 0
    while index < result.count, result.count < 200 {
      let (ref, distance) = result[index]
      index += 1
      for parent in supertypes(of: ref) {
        guard case .nominal(let next, _) = parent, seen.insert(next).inserted else { continue }
        result.append((next, distance + 1))
      }
    }
    return result
  }

  func parameterMap(_ ref: DeclRef, _ args: [Ty]) -> [Name: Ty] {
    guard !args.isEmpty else { return [:] }
    let item = decl(ref)
    let holder = unit(ref)
    var map: [Name: Ty] = [:]
    for g in 0..<min(Int(item.genericCount), args.count) { map[holder.generics[Int(item.genericStart) + g].name] = args[g] }
    return map
  }

  func substitute(_ ty: Ty, _ map: [Name: Ty]) -> Ty {
    guard !map.isEmpty else { return ty }
    switch ty {
    case .param(let word, _): return map[word] ?? ty
    case .nominal(let ref, let args): return args.isEmpty ? ty : .nominal(ref, args.map { substitute($0, map) })
    case .constructed(let kind, let args): return args.isEmpty ? ty : .constructed(kind, args.map { substitute($0, map) })
    case .function(let params, let result): return .function(params.map { substitute($0, map) }, substitute(result, map))
    case .meta(let inner): return .meta(substitute(inner, map))
    case .optional(let inner): return .optional(substitute(inner, map))
    default: return ty
    }
  }

  /// A type's members by name: its own, then each supertype's that it doesn't override, nearest first.
  func memberTable(of ref: DeclRef) -> [Name: [KMember]] {
    if let known = tables[ref] { return known }
    guard building.insert(ref).inserted else { return [:] }
    defer { building.remove(ref) }
    let holder = unit(ref)
    var table: [Name: [KMember]] = [:]
    var signatures: Set<String> = []
    // A Java interface's `toString()`, `hashCode()` and `equals()` are `Any`'s to Kotlin.
    let javaInterface = isJava(ref) && decl(ref).kind == .protocolType
    for child in holder.children(of: ref.decl) {
      let entry = holder.decls[Int(child)]
      guard entry.name != 0, entry.kind != .initializer, entry.kind != .extensionDecl else { continue }
      if javaInterface, entry.kind == .function, Self.objectMethods.contains(entry.name), !entry.isStatic { continue }
      let member = DeclRef(unit: ref.unit, decl: child)
      table[entry.name, default: []].append(KMember(ref: member, substitution: [:]))
      if entry.kind == .function { signatures.insert(signature(member, [:])) }
    }
    for parent in supertypes(of: ref) {
      guard case .nominal(let target, let args) = parent else { continue }
      let map = parameterMap(target, args)
      for (word, entries) in memberTable(of: target) {
        let own = table[word]
        for entry in entries {
          let item = decl(entry.ref)
          if item.access == .isPrivate { continue }
          // A Java class's statics aren't a Kotlin subclass's.
          if item.isStatic, isJava(entry.ref), !isJava(ref) { continue }
          let composed = entry.substitution.mapValues { substitute($0, map) }.merging(map) { first, _ in first }
          if item.kind == .function {
            if !signatures.insert(signature(entry.ref, composed)).inserted { continue }
          } else if let own, own.contains(where: { decl($0.ref).kind == item.kind || decl($0.ref).kind.isNominal == item.kind.isNominal && item.kind != .function && decl($0.ref).kind != .function }) {
            continue
          }
          table[word, default: []].append(KMember(ref: entry.ref, substitution: composed))
        }
      }
    }
    tables[ref] = table
    return table
  }

  /// A function's name and erased parameter types, as an override restates them.
  func signature(_ ref: DeclRef, _ map: [Name: Ty]) -> String {
    let item = decl(ref)
    var key = String(item.name) + "/" + String(item.paramCount)
    for param in parameters(of: ref) { key += ":" + erasure(substitute(param.type, map)) }
    return key
  }

  func erasure(_ ty: Ty) -> String {
    switch ty {
    case .nominal(let ref, _): return String(decl(ref).name)
    case .function(let params, _): return "fn" + String(params.count)
    case .constructed(let kind, let args): return String(kind) + "[" + args.map(erasure).joined(separator: ",") + "]"
    case .param: return erasure(memberBase(ty))
    default: return "?"
    }
  }

  /// A type's members of a name, nearest first.
  func memberEntries(of ty: Ty, named word: Name) -> [(KMember, Ty)] {
    let base = memberBase(ty)
    guard case .nominal(let ref, let args) = base else { return [] }
    let map = parameterMap(ref, args)
    return (memberTable(of: ref)[word] ?? []).map { entry in
      var composed = entry
      composed.substitution = entry.substitution.mapValues { substitute($0, map) }.merging(map) { first, _ in first }
      return (composed, base)
    }
  }

  /// Nested classes of a type named so (inherited ones too).
  func memberTypeRefs(of ty: Ty, named word: Name) -> [DeclRef] {
    memberEntries(of: ty, named: word).map(\.0.ref).filter { decl($0).kind.isNominal || decl($0).kind == .typeAlias }
  }

  /// What `Type.name` reaches: a Kotlin class's companion members and enum entries, a Java class's statics.
  func staticMembers(of ty: Ty, named word: Name) -> [DeclRef] {
    guard case .nominal(let ref, _) = memberBase(ty) else { return [] }
    if isJava(ref) {
      return memberEntries(of: ty, named: word).map(\.0.ref).filter { decl($0).isStatic || decl($0).kind == .enumCase }
    }
    var result = memberEntries(of: ty, named: word).map(\.0.ref).filter { decl($0).kind == .enumCase }
    if let companion = companion(of: ref) { result += memberEntries(of: .nominal(companion, []), named: word).map(\.0.ref).filter { !decl($0).kind.isNominal } }
    return result
  }

  func staticCallees(of ty: Ty, named word: Name, wantsCall: Bool) -> [Callee] {
    guard case .nominal(let ref, _) = memberBase(ty) else { return [] }
    var result: [Callee] = []
    if isJava(ref) {
      for (entry, _) in memberEntries(of: ty, named: word) {
        let item = decl(entry.ref)
        guard item.isStatic || item.kind == .enumCase else { continue }
        if wantsCall ? item.kind == .function : isProperty(item) { result.append(Callee(ref: entry.ref, map: entry.substitution, receiver: ty)) }
      }
      return result
    }
    for (entry, _) in memberEntries(of: ty, named: word) where !wantsCall && decl(entry.ref).kind == .enumCase {
      result.append(Callee(ref: entry.ref, map: [:], receiver: ty))
    }
    if let companion = companion(of: ref) {
      let companionType = Ty.nominal(companion, [])
      for (entry, _) in memberEntries(of: companionType, named: word) {
        let item = decl(entry.ref)
        if wantsCall ? item.kind == .function : isProperty(item) { result.append(Callee(ref: entry.ref, map: entry.substitution, receiver: companionType)) }
      }
      if result.isEmpty {
        result = extensionCandidates(receiver: companionType, named: word, unitIndex: -1, wantsCall: wantsCall)
      }
    }
    return result
  }

  /// The functions `x.name(…)` may mean: x's member functions, else the extension functions on x's type it sees.
  func callees(of receiver: Ty, named word: Name, unitIndex: Int32, token: Int32) -> [Callee] {
    var result: [Callee] = []
    for (entry, _) in memberEntries(of: receiver, named: word) where decl(entry.ref).kind == .function {
      result.append(Callee(ref: entry.ref, map: entry.substitution, receiver: receiver))
    }
    let unit = unitIndex >= 0 ? project.units[Int(unitIndex)] : nil
    let args = unit.flatMap { unit in token >= 0 && callOpen(unit, Int(token)) != nil ? callArguments(unit, nameToken: Int(token)) : nil }
    let extensions = extensionCandidates(receiver: receiver, named: word, unitIndex: unitIndex, wantsCall: true, args: args)
    if result.isEmpty { return extensions }
    // A member wins over an extension unless it can't take the arguments; a Java class's members may be missing
    // from a stub, so its own name stays the member's.
    if case .nominal(let ref, _) = memberBase(receiver), isJava(ref), !(args?.contains { $0.brace >= 0 } ?? false) { return result }
    if chooseOverload(result, unitIndex: unitIndex, nameToken: Int(token)).isEmpty, !extensions.isEmpty,
      !chooseOverload(extensions, unitIndex: unitIndex, nameToken: Int(token)).isEmpty
    {
      return extensions
    }
    return result
  }

  /// A Java getter read as a property: `name` is `getName()` or `isName()`, `isOpen` is `isOpen()`.
  func syntheticGetter(of receiver: Ty, named word: Name) -> DeclRef? {
    guard let text = names[word] else { return nil }
    var candidates: [String] = []
    if let first = text.first {
      candidates.append("get" + first.uppercased() + text.dropFirst())
    }
    if text.hasPrefix("is"), text.count > 2, text.dropFirst(2).first?.isUppercase == true { candidates.append(text) }
    for candidate in candidates {
      for (entry, _) in memberEntries(of: receiver, named: name(candidate)) where isJava(entry.ref) {
        let item = decl(entry.ref)
        if item.kind == .function, item.paramCount == 0, !item.isStatic { return entry.ref }
      }
    }
    return nil
  }

  /// A Java class's method that Kotlin shows as a mapped built-in's property: `length()` as `CharSequence.length`,
  /// `size()` as `Collection.size`, `keySet()` as `Map.keys`. The compiler links the Java method.
  func javaMappedProperty(of receiver: Ty, named word: Name) -> DeclRef? {
    guard case .nominal(let ref, _) = memberBase(receiver), isJava(ref), let text = names[word],
      let method = Self.mappedMethods.first(where: { $0.value == text })?.key
    else { return nil }
    for (entry, _) in memberEntries(of: receiver, named: name(method)) where isJava(entry.ref) {
      let item = decl(entry.ref)
      if item.kind == .function, item.paramCount == 0, !item.isStatic { return entry.ref }
    }
    return nil
  }

  /// Java methods Kotlin shows as a mapped built-in's property, by the property's name.
  static let mappedMethods = ["length": "length", "size": "size", "values": "values", "keySet": "keys", "entrySet": "entries"]

  /// The property name Kotlin gives a Java class's method: `length` for `StringBuilder.length()` (a `CharSequence`),
  /// `keys` for `HashMap.keySet()`; nil for any other method.
  func mappedPropertyName(_ ref: DeclRef) -> String? {
    let item = decl(ref)
    guard isJava(ref), item.kind == .function, item.paramCount == 0, !item.isStatic, item.parent >= 0,
      let property = Self.mappedMethods[unit(ref).string(Int(item.nameToken))]
    else { return nil }
    let owner = DeclRef(unit: ref.unit, decl: item.parent)
    let mapped: Set<String> = ["kotlin.CharSequence", "kotlin.collections.Collection", "kotlin.collections.Map"]
    for (base, _) in hierarchy(of: .nominal(owner, [])) where !isJava(base) {
      if let qualified = qualifiedName(base), mapped.contains(qualified) { return property }
    }
    return nil
  }

  // MARK: Extensions

  /// What an extension's holder extends, read where it's declared.
  func extensionReceiverType(_ holder: DeclRef) -> Ty {
    let item = decl(holder)
    guard item.typeStart >= 0 else { return .unknown }
    // The function's own parameters are in scope at its name.
    let child = unit(holder).children(of: holder.decl).first
    let scope = child.map { unit(holder).decls[Int($0)].nameToken } ?? item.typeEnd
    return parseType(unitIndex: holder.unit, start: item.typeStart, end: item.typeEnd, scope: scope)
  }

  /// The extension functions (or properties) of a name a receiver has here, the most specific: imported explicitly,
  /// then from the file's package, star imports and the defaults; then the nearest receiver type. With a call's
  /// arguments, only the functions that can take them compete.
  func extensionCandidates(receiver: Ty, named word: Name, unitIndex: Int32, wantsCall: Bool, args: [KArg]? = nil) -> [Callee] {
    if case .unknown = receiver { return [] }
    if case .module = receiver { return [] }
    var holderNames: [(Name, Int)] = hierarchy(of: receiver).map { (decl($0.0).name, $0.1) }
    holderNames.append((KotlinWord.anyReceiver, 1000))
    if case .function = receiver { holderNames.append((KotlinWord.function, 0)) }
    let visible = unitIndex >= 0 ? visiblePackages(unitIndex) : Set(Self.defaultPackages)
    let explicit = unitIndex >= 0 ? fileImports(unitIndex).explicitPaths : []
    var best: [(Callee, Int, Int)] = []
    var seen: Set<DeclRef> = []
    for (holderName, _) in holderNames {
      for holder in project.extensions[holderName] ?? [] {
        let holderUnit = unit(holder)
        for child in holderUnit.children(of: holder.decl) {
          let item = holderUnit.decls[Int(child)]
          guard item.name == word, wantsCall ? item.kind == .function : item.kind == .variable else { continue }
          let ref = DeclRef(unit: holder.unit, decl: child)
          guard seen.insert(ref).inserted else { continue }
          let package = packageOf(holder.unit)
          var level: Int
          if explicit.contains(package.isEmpty ? holderUnit.string(Int(item.nameToken)) : package + "." + holderUnit.string(Int(item.nameToken))) {
            level = 0
          } else if unitIndex >= 0, holder.unit == unitIndex || package == packageOf(unitIndex) && !project.isSDK(holderUnit) {
            level = 1
          } else if visible.contains(package) {
            level = Self.defaultPackages.contains(package) ? 3 : 2
          } else {
            continue
          }
          if item.access == .isPrivate, holder.unit != unitIndex { continue }
          guard let (map, distance) = extensionMatch(holder: holder, function: ref, receiver: receiver) else { continue }
          if let args, assignment(Callee(ref: ref, map: map, receiver: receiver), args) == nil { continue }
          best.append((Callee(ref: ref, map: map, receiver: receiver), level, distance))
        }
      }
    }
    guard let top = best.min(by: { ($0.1, $0.2) < ($1.1, $1.2) }) else { return [] }
    return best.filter { $0.1 == top.1 && $0.2 == top.2 }.map(\.0)
  }

  /// Whether an extension applies to a receiver: its receiver's parameters bound from it, and how far up the
  /// receiver's hierarchy it's declared.
  func extensionMatch(holder: DeclRef, function: DeclRef, receiver: Ty) -> ([Name: Ty], Int)? {
    let pattern = extensionReceiverType(holder)
    let own = ownGenerics(function)
    switch pattern {
    case .param(let word, _):
      // `fun <T> T.let`: anything within its bound (`<T : AutoCloseable?> T.use`).
      if let limit = bound(of: pattern), assignable(receiver, to: limit) == false { return nil }
      var bindings: [Name: Ty] = [:]
      if own.contains(word) { bindings[word] = receiver }
      return (bindings, 1000)
    case .nominal(let target, _):
      guard let distance = hierarchy(of: receiver).first(where: { $0.0 == target })?.1 else { return nil }
      var bindings: [Name: Ty] = [:]
      unify(pattern, receiver, own, &bindings)
      return (bindings, distance)
    case .function, .constructed:
      if case .function = memberBase(receiver) {} else if case .function = receiver {} else { return nil }
      var bindings: [Name: Ty] = [:]
      unify(pattern, receiver, own, &bindings)
      return (bindings, 0)
    default:
      return nil
    }
  }

  func ownGenerics(_ ref: DeclRef) -> Set<Name> {
    let item = decl(ref)
    let holder = unit(ref)
    var own: Set<Name> = []
    for g in 0..<Int(item.genericCount) { own.insert(holder.generics[Int(item.genericStart) + g].name) }
    return own
  }

  /// Binds `own` parameters in `pattern` from `actual`.
  func unify(_ pattern: Ty, _ actual: Ty, _ own: Set<Name>, _ bindings: inout [Name: Ty], depth: Int = 0) {
    guard depth < 8, actual != .unknown else { return }
    switch pattern {
    case .param(let word, _):
      if own.contains(word), bindings[word] == nil { bindings[word] = actual }
    case .nominal(let ref, let args):
      guard !args.isEmpty, case .nominal(_, let actualArgs)? = asSupertype(actual, ref) else { return }
      for (a, b) in zip(args, actualArgs) { unify(a, b, own, &bindings, depth: depth + 1) }
    case .function(let params, let result):
      if case .function(let actualParams, let actualResult) = actual {
        for (a, b) in zip(params, actualParams) { unify(a, b, own, &bindings, depth: depth + 1) }
        unify(result, actualResult, own, &bindings, depth: depth + 1)
      }
    case .constructed(let kind, let args) where kind == KotlinTy.receiverFunction:
      if case .constructed(let other, let actualArgs) = actual, other == kind {
        for (a, b) in zip(args, actualArgs) { unify(a, b, own, &bindings, depth: depth + 1) }
      }
    default:
      break
    }
  }

  // MARK: Calls

  /// What a simple call `name(…)` may mean: local functions, the implicit receivers' functions, then the top-level
  /// functions and constructors of the first level that has ones taking the arguments.
  func simpleCallees(_ word: Name, unitIndex: Int32, token: Int32) -> [Callee] {
    let unit = project.units[Int(unitIndex)]
    if localSite(word, unitIndex: unitIndex, token: token) != nil { return [] }
    for index in unit.chain(at: token).reversed() {
      var found: [Callee] = []
      for child in unit.children(of: index) {
        let item = unit.decls[Int(child)]
        if item.isLocal, item.kind == .function, item.name == word { found.append(Callee(ref: DeclRef(unit: unitIndex, decl: child), map: [:], receiver: .unknown)) }
      }
      if !found.isEmpty { return found }
    }
    for receiver in implicitReceivers(unitIndex: unitIndex, token: token) {
      var found: [Callee] = []
      for (entry, _) in memberEntries(of: receiver, named: word) {
        let item = decl(entry.ref)
        if item.kind == .function { found.append(Callee(ref: entry.ref, map: entry.substitution, receiver: receiver)) }
      }
      if found.isEmpty {
        // A nested class's constructor: `Inner(…)`.
        let nested = memberTypeRefs(of: receiver, named: word)
        if !nested.isEmpty { found = constructorsAndFunctions(nested) }
      }
      if found.isEmpty {
        let args = callOpen(unit, Int(token)) != nil ? callArguments(unit, nameToken: Int(token)) : nil
        found = extensionCandidates(receiver: receiver, named: word, unitIndex: unitIndex, wantsCall: true, args: args)
      }
      if !found.isEmpty { return found }
    }
    // Local classes.
    for case .decl(let ref) in typeSites(word, unitIndex: unitIndex, token: token) where decl(ref).isLocal || decl(ref).parent >= 0 {
      return constructorsAndFunctions([ref])
    }
    var first: [Callee]?
    for level in topLevels(word, unitIndex: unitIndex, filter: { $0.kind == .function || $0.kind.isNominal || $0.kind == .typeAlias }) {
      let found = constructorsAndFunctions(level)
      if found.isEmpty { continue }
      if first == nil { first = found }
      if !chooseOverload(found, unitIndex: unitIndex, nameToken: Int(token)).isEmpty { return found }
    }
    return first ?? []
  }

  /// Functions as themselves, classes as their constructors (the class itself for its primary one), type aliases as
  /// their class's.
  func constructorsAndFunctions(_ refs: [DeclRef]) -> [Callee] {
    var result: [Callee] = []
    for ref in refs {
      let item = decl(ref)
      switch item.kind {
      case .function:
        result.append(Callee(ref: ref, map: [:], receiver: .unknown))
      case .typeAlias:
        if case .nominal(let target, let args) = expandAlias(ref, args: []) {
          result += constructors(of: target).map { Callee(ref: $0, map: parameterMap(target, args), receiver: .unknown) }
        }
      case .classType, .enumeration, .structure, .protocolType:
        if isObject(ref) { continue }
        result += constructors(of: ref).map { Callee(ref: $0, map: [:], receiver: .unknown) }
      default:
        break
      }
    }
    return result
  }

  /// A class's constructors: its primary one (the class), its secondary ones; a Java class's, else the class.
  func constructors(of ref: DeclRef) -> [DeclRef] {
    let holder = unit(ref)
    let item = decl(ref)
    let secondary = holder.children(of: ref.decl).filter { holder.decls[Int($0)].kind == .initializer }.map { DeclRef(unit: ref.unit, decl: $0) }
    if isJava(ref) { return secondary.isEmpty ? [ref] : secondary }
    // Without a primary constructor written, a class with secondary ones has none.
    let hasPrimary = item.paramCount > 0 || holder.isByte(Int(item.nameToken) + 1, 0x28) || holder.isToken(Int(item.nameToken) + 1, "constructor") || secondary.isEmpty
      || hasPrimaryAfterGenerics(ref)
    return (hasPrimary ? [ref] : []) + secondary
  }

  private func hasPrimaryAfterGenerics(_ ref: DeclRef) -> Bool {
    let holder = unit(ref)
    let k = Int(decl(ref).nameToken) + 1
    guard holder.tokens.indices.contains(k), holder.tokens[k].kind == .punctuation, holder.ktStartsWith(k, 0x3C), let after = holder.ktTypeArgumentsEnd(k) else { return false }
    return holder.isByte(after, 0x28)
  }

  /// A callable's parameters, in its own terms.
  func parameters(of ref: DeclRef) -> [KParam] {
    if let known = parameterCache[ref] { return known }
    let item = decl(ref)
    let holder = unit(ref)
    var result: [KParam] = []
    if isJava(ref) {
      if item.kind == .function || item.kind == .initializer {
        let types = java.parameterTypes(ref, [:]).map(fromJava)
        for p in 0..<Int(item.paramCount) {
          let param = holder.params[Int(item.paramStart) + p]
          result.append(KParam(name: param.local, type: p < types.count ? types[p] : .unknown, hasDefault: false, variadic: param.variadic))
        }
      }
    } else {
      for p in 0..<Int(item.paramCount) {
        let param = holder.params[Int(item.paramStart) + p]
        let type = parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: item.nameToken >= 0 ? item.nameToken : item.first)
        result.append(KParam(name: param.local, type: type, hasDefault: param.hasDefault, variadic: param.variadic))
      }
    }
    if !item.isLocal { parameterCache[ref] = result }
    return result
  }

  // MARK: Values

  /// A declaration's type as a value: a property's, a function's result, an object, a class used for its statics.
  func valueType(of ref: DeclRef) -> Ty {
    if let known = valueTypes[ref] { return known }
    guard resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    let item = decl(ref)
    var result = Ty.unknown
    if isJava(ref) {
      result = fromJava(java.valueType(of: ref))
    } else {
      switch item.kind {
      case .variable:
        if item.typeStart >= 0 {
          result = parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: item.nameToken)
        } else if item.initStart >= 0 {
          let holder = unit(ref)
          let value = expressionType(unitIndex: ref.unit, start: item.initStart, end: item.initEnd)
          result = holder.isToken(Int(item.initStart) - 1, "by") ? delegatedType(value, unitIndex: ref.unit) : value
        } else if let getter = unit(ref).children(of: ref.decl).first, unit(ref).decls[Int(getter)].initStart >= 0 {
          let accessor = unit(ref).decls[Int(getter)]
          result = expressionType(unitIndex: ref.unit, start: accessor.initStart, end: accessor.initEnd)
        }
      case .function:
        if item.typeStart >= 0 {
          result = parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: item.nameToken)
        } else if item.initStart >= 0 {
          result = expressionType(unitIndex: ref.unit, start: item.initStart, end: item.initEnd)
        } else {
          result = kotlinType("kotlin", "Unit").map { .nominal($0, []) } ?? .unknown
        }
      case .initializer:
        if item.parent >= 0 { result = ownType(DeclRef(unit: ref.unit, decl: item.parent)) }
      case .enumCase:
        if item.parent >= 0 { result = .nominal(DeclRef(unit: ref.unit, decl: item.parent), []) }
      case .classType, .protocolType, .enumeration, .structure:
        result = isObject(ref) ? .nominal(ref, []) : .meta(.nominal(ref, []))
      case .typeAlias:
        result = .meta(expandAlias(ref, args: []))
      default:
        break
      }
    }
    if !item.isLocal { valueTypes[ref] = result }
    return result
  }

  /// `by d`: what `d.getValue(…)` gives (`Lazy<T>` gives T).
  func delegatedType(_ delegate: Ty, unitIndex: Int32) -> Ty {
    var found = memberEntries(of: delegate, named: KotlinWord.getValue).filter { decl($0.0.ref).kind == .function }.map { Callee(ref: $0.0.ref, map: $0.0.substitution, receiver: delegate) }
    if found.isEmpty { found = extensionCandidates(receiver: delegate, named: KotlinWord.getValue, unitIndex: unitIndex, wantsCall: true) }
    guard let first = found.first else { return .unknown }
    return eraseOwn(substitute(valueType(of: first.ref), first.map), first.ref)
  }

  /// A function's own type parameters left unbound read as unknown.
  func eraseOwn(_ ty: Ty, _ function: DeclRef) -> Ty {
    switch ty {
    case .param(_, let owner) where owner == function: return .unknown
    case .nominal(let ref, let args): return .nominal(ref, args.map { eraseOwn($0, function) })
    case .constructed(let kind, let args): return .constructed(kind, args.map { eraseOwn($0, function) })
    case .function(let params, let result): return .function(params.map { eraseOwn($0, function) }, eraseOwn(result, function))
    default: return ty
    }
  }

  /// What a site is as a value.
  func siteType(_ site: Site, unitIndex: Int32) -> Ty {
    switch site {
    case .decl(let ref):
      return valueType(of: ref)
    case .local(let holder, let token):
      return localSiteType(unitIndex: holder, token: token)
    case .generic(let holder, let token):
      return .meta(typeOfSite(.generic(unit: holder, token: token), args: []))
    case .module(let package):
      return .module(package)
    }
  }

  /// A local's type: a body's local, a lambda's `it`, a parameter outside any body (a primary constructor's).
  func localSiteType(unitIndex: Int32, token: Int32) -> Ty {
    let unit = project.units[Int(unitIndex)]
    if unit.isByte(Int(token), 0x7B) {
      guard let target = lambdaTarget(unitIndex: unitIndex, brace: Int(token)), target.params.count == 1 else { return .unknown }
      return target.params[0]
    }
    if let body = body(unitIndex: unitIndex, token: token), let index = body.byToken[token] {
      return localType(unitIndex: unitIndex, body: body, index: index)
    }
    for item in unit.decls {
      for p in 0..<Int(item.paramCount) where unit.params[Int(item.paramStart) + p].nameToken == token {
        let param = unit.params[Int(item.paramStart) + p]
        let ty = parseType(unitIndex: unitIndex, start: param.typeStart, end: param.typeEnd, scope: item.nameToken >= 0 ? item.nameToken : item.first)
        return param.variadic ? arrayOf(ty) : ty
      }
    }
    return .unknown
  }

  func arrayOf(_ ty: Ty) -> Ty {
    if case .nominal(let ref, _) = ty, packageOf(ref.unit) == "kotlin", let primitive = [name("Int"), name("Long"), name("Short"), name("Byte"), name("Char"), name("Boolean"), name("Float"), name("Double")].first(where: { $0 == decl(ref).name }) {
      _ = primitive
      return kotlinType("kotlin", unit(ref).string(Int(decl(ref).nameToken)) + "Array").map { .nominal($0, []) } ?? .unknown
    }
    return kotlinType("kotlin", "Array").map { .nominal($0, [ty]) } ?? .unknown
  }

  // MARK: Assignability

  /// Whether a value of `from` can be passed where `to` is wanted: `nil` when it can't be told.
  func assignable(_ from: Ty, to: Ty) -> Bool? {
    if to == .unknown { return nil }
    if case .param = to { return true }
    if case .nominal(let target, _) = to, case .nominal(let any, _) = anyType(), target == any { return true }
    if from == .unknown { return nil }
    if case .param = from { return nil }
    if case .function(let a, _) = from {
      if case .function(let b, _) = to { return a.count == b.count ? nil : false }
      if case .constructed(let kind, _) = to, kind == KotlinTy.receiverFunction { return nil }
      if case .nominal(let ref, _) = to, decl(ref).kind == .protocolType { return nil }
      return to == anyType() ? true : nil
    }
    guard case .nominal(let target, _) = memberBase(to) else { return nil }
    guard case .nominal(let source, _) = memberBase(from) else { return nil }
    if source == target { return true }
    if case .nominal(let any, _) = anyType(), target == any { return true }
    if isNumber(source), isNumber(target) { return nil }
    return asSupertype(from, target) != nil
  }

  func isNumber(_ ref: DeclRef) -> Bool {
    guard packageOf(ref.unit) == "kotlin" else { return false }
    return KotlinWord.numbers.contains(decl(ref).name)
  }
}
