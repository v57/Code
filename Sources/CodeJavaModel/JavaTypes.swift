import CodeModel
import CodeScan
import Foundation

/// Java's types (`Ty`, the core's): classes, interfaces, enums and records are `nominal` with their arguments, a type
/// parameter `param` (with the declaration that has it, for its bounds), primitives and arrays `constructed`, a type
/// used for its static members `meta`, a package `module`. Wildcards read as their bound.
extension JavaModel {
  // MARK: Written types

  struct Cursor {
    var i: Int
    var sub = 0
  }

  /// A type written from `start` to `end`, its names looked up from token `scope`.
  package func parseType(unitIndex: Int32, start: Int32, end: Int32, scope: Int32) -> Ty {
    guard start >= 0, start < end else { return .unknown }
    let unit = project.units[Int(unitIndex)]
    var cursor = Cursor(i: Int(start))
    var first = readType(unitIndex, &cursor, Int(end), scope)
    // `A | B` (a catch) or `A & B` (a cast's intersection): the first, with the others for members.
    var others: [Ty] = []
    while cursor.i < Int(end), unit.isToken(cursor.i, "|") || unit.isToken(cursor.i, "&") {
      cursor.i += 1
      cursor.sub = 0
      others.append(readType(unitIndex, &cursor, Int(end), scope))
    }
    if !others.isEmpty { first = .constructed(Ty.union, [first] + others) }
    return first
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
    if c.sub == 0 { c.i = unit.javaSkipAnnotations(c.i, limit: end) }
    guard c.i < end else { return .unknown }
    if char(unit, c, end) == 0x3F {
      // `?`, `? extends T`, `? super T`.
      advance(unit, &c)
      if c.sub == 0, unit.isToken(c.i, "extends") || unit.isToken(c.i, "super") {
        c.i += 1
        return readType(unitIndex, &c, end, scope)
      }
      return langType(JavaWord.object).map { .nominal($0, []) } ?? .unknown
    }
    guard c.sub == 0 else { return .unknown }
    var ty: Ty
    if unit.tokens[c.i].kind == .keyword, JavaWord.primitives.contains(unit.hash(c.i)) {
      ty = .constructed(unit.hash(c.i), [])
      c.i += 1
    } else if unit.javaIsName(c.i) {
      ty = .unknown
      var package = ""
      var first = true
      while c.i < end, unit.javaIsName(c.i) {
        let word = unit.hash(c.i)
        let text = unit.string(c.i)
        c.i += 1
        var args: [Ty] = []
        if char(unit, c, end) == 0x3C {
          advance(unit, &c)
          args = readArguments(unitIndex, &c, end, scope)
        }
        if first {
          first = false
          let found = typeSites(word, unitIndex: unitIndex, token: scope)
          if let site = found.first {
            ty = typeOfSite(site, args: args)
          } else {
            package = text
          }
        } else if case .unknown = ty, !package.isEmpty {
          if let ref = packageTypes(package, named: word).first {
            ty = .nominal(ref, args)
            package = ""
          } else {
            package += "." + text
          }
        } else if ty != .unknown {
          if let ref = memberTypeRefs(of: ty, named: word).first { ty = .nominal(ref, args) } else { return .unknown }
        }
        if c.sub == 0, unit.isByte(c.i, 0x2E), unit.javaIsName(unit.javaSkipAnnotations(c.i + 1, limit: end)) {
          c.i = unit.javaSkipAnnotations(c.i + 1, limit: end)
          continue
        }
        break
      }
    } else {
      return .unknown
    }
    while c.sub == 0, c.i + 1 < end || c.i + 1 == end && unit.isToken(c.i, "...") {
      let at = unit.javaSkipAnnotations(c.i, limit: end)
      if unit.isByte(at, 0x5B), unit.isByte(at + 1, 0x5D) {
        ty = .constructed(Ty.array, [ty])
        c.i = at + 2
      } else if unit.isToken(at, "...") {
        ty = .constructed(Ty.array, [ty])
        c.i = at + 1
      } else {
        break
      }
    }
    return ty
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
      args.append(readType(unitIndex, &c, end, scope))
      if char(unit, c, end) == 0x2C || (c.sub == 0 && unit.isByte(c.i, 0x2C)) {
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

  /// A type name's site as a type.
  func typeOfSite(_ site: Site, args: [Ty]) -> Ty {
    switch site {
    case .decl(let ref):
      let item = decl(ref)
      guard item.kind.isNominal else { return .unknown }
      // A raw type reads its parameters as their bounds when a member's type is asked.
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

  /// A type parameter's first bound (`T extends Foo & Bar` is Foo), or nil.
  package func bound(of ty: Ty) -> Ty? {
    guard case .param(let word, let owner?) = ty else { return nil }
    let holder = unit(owner)
    let item = decl(owner)
    for g in 0..<Int(item.genericCount) {
      let generic = holder.generics[Int(item.genericStart) + g]
      guard generic.name == word, holder.isToken(Int(generic.token) + 1, "extends") else { continue }
      let start = Int(generic.token) + 2
      var endToken = start
      var depth = 0
      while endToken < holder.tokens.count {
        if holder.tokens[endToken].kind == .punctuation {
          var closes = false
          for k in 0..<holder.tokens[endToken].length {
            let byte = holder.source.text[holder.tokens[endToken].start + k]
            if byte == 0x3C { depth += 1 } else if byte == 0x3E {
              if depth == 0 { closes = true; break }
              depth -= 1
            } else if byte == 0x26, depth == 0 { closes = true; break }
          }
          if closes { break }
        }
        if holder.isByte(endToken, 0x2C), depth == 0 { break }
        endToken += 1
      }
      let found = parseType(unitIndex: owner.unit, start: Int32(start), end: Int32(endToken), scope: generic.token)
      if case .param(let other, _) = found, other == word { return nil }
      return found
    }
    return nil
  }

  /// What a type's members are looked up in: a type parameter's bound, a union's first.
  package func memberBase(_ ty: Ty, depth: Int = 0) -> Ty {
    switch ty {
    case .param:
      guard depth < 6, let found = bound(of: ty) else { return langType(JavaWord.object).map { .nominal($0, []) } ?? .unknown }
      return memberBase(found, depth: depth + 1)
    case .constructed(let kind, let args) where kind == Ty.union:
      return args.first.map { memberBase($0, depth: depth + 1) } ?? .unknown
    case .constructed(let kind, _) where kind == Ty.array:
      return langType(JavaWord.object).map { .nominal($0, []) } ?? .unknown
    default:
      return ty
    }
  }

  // MARK: Hierarchy

  /// A class's direct supertypes as written, in terms of its own parameters: `extends` and `implements`, or the
  /// implicit ones (Object, `Enum<E>`, `Record`; an enum constant's body extends its enum).
  package func supertypes(of ref: DeclRef) -> [Ty] {
    if let known = supertypeCache[ref] { return known }
    supertypeCache[ref] = []
    let item = decl(ref)
    let holder = unit(ref)
    var result: [Ty] = []
    if item.kind == .enumCase {
      if item.parent >= 0 { result.append(.nominal(DeclRef(unit: ref.unit, decl: item.parent), [])) }
      supertypeCache[ref] = result
      return result
    }
    var hasSuperclass = false
    for r in 0..<Int(item.inheritCount) {
      let range = holder.ranges[Int(item.inheritStart) + r]
      // Read where the class is declared: its own member types aren't in scope here, its parameters are.
      let ty = parseType(unitIndex: ref.unit, start: range.start, end: range.end, scope: item.name == 0 ? item.first : item.nameToken)
      guard case .nominal(let target, _) = ty, target != ref else { continue }
      if item.kind == .classType, holder.isToken(Int(range.start) - 1, "extends") { hasSuperclass = true }
      if item.kind == .classType, item.name == 0, decl(target).kind == .classType || decl(target).kind == .enumeration { hasSuperclass = true }
      result.append(ty)
    }
    let isObject = item.name == JavaWord.object && packageOf(ref.unit) == "java.lang"
    if item.kind == .enumeration, let enumRef = langType(JavaWord.enumWord) {
      result.insert(.nominal(enumRef, [ownType(ref)]), at: 0)
    } else if item.kind == .structure, let recordRef = langType(JavaWord.record) {
      result.insert(.nominal(recordRef, []), at: 0)
    } else if !hasSuperclass, !isObject, let object = langType(JavaWord.object) {
      // Interfaces have Object's public methods too; last, so their own come first.
      if item.kind == .protocolType { result.append(.nominal(object, [])) } else { result.insert(.nominal(object, []), at: 0) }
    }
    supertypeCache[ref] = result
    return result
  }




  /// A type's members by name: its own, then each supertype's that it doesn't override or hide, nearest first.
  func memberTable(of ref: DeclRef) -> [Name: [MemberEntry]] {
    if let known = tables[ref] { return known }
    guard building.insert(ref).inserted else { return [:] }
    defer { building.remove(ref) }
    let holder = unit(ref)
    var table: [Name: [MemberEntry]] = [:]
    var signatures: Set<String> = []
    for child in holder.children(of: ref.decl) {
      let entry = holder.decls[Int(child)]
      guard entry.name != 0, entry.kind != .initializer else { continue }
      let member = DeclRef(unit: ref.unit, decl: child)
      table[entry.name, default: []].append(MemberEntry(ref: member, substitution: [:]))
      if entry.kind == .function { signatures.insert(signature(member, [:])) }
    }
    for parent in supertypes(of: ref) {
      guard case .nominal(let target, let args) = parent else { continue }
      let map = parameterMap(target, args)
      for (word, entries) in memberTable(of: target) {
        let own = table[word]
        for entry in entries {
          let item = decl(entry.ref)
          // Private members aren't inherited; a field or member type is hidden by one of its name.
          if item.access == .isPrivate { continue }
          let composed = entry.substitution.mapValues { substitute($0, map) }.merging(map) { first, _ in first }
          if item.kind == .function {
            let key = signature(entry.ref, composed)
            if !signatures.insert(key).inserted { continue }
          } else if let own, own.contains(where: { decl($0.ref).kind == item.kind || decl($0.ref).kind.isNominal == item.kind.isNominal && item.kind != .function }) {
            continue
          }
          table[word, default: []].append(MemberEntry(ref: entry.ref, substitution: composed))
        }
      }
    }
    tables[ref] = table
    return table
  }

  /// A method's name and parameter types, erased, as its subclasses would override it.
  func signature(_ ref: DeclRef, _ map: [Name: Ty]) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    var key = String(item.name) + "/" + String(item.paramCount)
    for p in 0..<Int(item.paramCount) {
      let param = holder.params[Int(item.paramStart) + p]
      key += ":" + erasure(substitute(parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: item.nameToken), map))
    }
    return key
  }

  func erasure(_ ty: Ty) -> String {
    switch ty {
    case .nominal(let ref, _): return String(decl(ref).name)
    case .constructed(let kind, let args): return String(kind) + "[" + args.map(erasure).joined(separator: ",") + "]"
    case .param: return erasure(memberBase(ty))
    default: return "?"
    }
  }

  /// A type's members of a name, nearest first; `from` is the asking unit (-1: anyone).
  func memberEntries(of ty: Ty, named word: Name) -> [(MemberEntry, Ty)] {
    let base = memberBase(ty)
    guard case .nominal(let ref, let args) = base else { return [] }
    let map = parameterMap(ref, args)
    return (memberTable(of: ref)[word] ?? []).map { entry in
      (entry, base == ty ? ty : base)
    }.map { pair in
      var entry = pair.0
      entry.substitution = entry.substitution.mapValues { substitute($0, map) }.merging(map) { first, _ in first }
      return (entry, pair.1)
    }
  }

  func memberSites(of ty: Ty, named word: Name, from unitIndex: Int32) -> [DeclRef] {
    var found = memberEntries(of: ty, named: word).map(\.0.ref)
    // An array's `length` and `clone()`.
    if case .constructed(let kind, _) = ty, kind == Ty.array, word != JavaWord.clone { found = [] }
    return found
  }

  /// The methods a call `x.name(…)` may mean: x's methods of the name, else a record's component, whose accessor isn't
  /// written (javac places it at the component).
  func methodSites(of ty: Ty, named word: Name, from unitIndex: Int32) -> [DeclRef] {
    let all = memberSites(of: ty, named: word, from: unitIndex)
    let functions = all.filter { decl($0).kind == .function }
    if !functions.isEmpty { return functions }
    return all.filter { isRecordComponent($0) }
  }

  func isRecordComponent(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    return item.kind == .variable && !item.isStatic && item.parent >= 0 && unit(ref).decls[Int(item.parent)].kind == .structure
  }

  /// Member types of a type named so (nested classes, inherited ones too).
  func memberTypeRefs(of ty: Ty, named word: Name) -> [DeclRef] {
    memberEntries(of: ty, named: word).map(\.0.ref).filter { decl($0).kind.isNominal }
  }

  // MARK: Values

  /// A declaration's type as a value: a field's, a method's result (as written), an enum constant's enum.
  package func valueType(of ref: DeclRef) -> Ty {
    if let known = valueTypes[ref] { return known }
    guard resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    let item = decl(ref)
    var result = Ty.unknown
    switch item.kind {
    case .variable, .function:
      if item.typeStart >= 0 { result = parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: item.nameToken) }
      // `int a[]`.
      if item.kind == .variable {
        var k = Int(item.nameToken) + 1
        let holder = unit(ref)
        while holder.isByte(k, 0x5B), holder.isByte(k + 1, 0x5D) {
          result = .constructed(Ty.array, [result])
          k += 2
        }
      }
    case .enumCase:
      if item.parent >= 0 { result = .nominal(DeclRef(unit: ref.unit, decl: item.parent), []) }
    case .classType, .protocolType, .enumeration, .structure:
      result = .meta(.nominal(ref, []))
    default:
      break
    }
    if !item.isLocal { valueTypes[ref] = result }
    return result
  }

  /// A member's type through the type it was found on: its declaring class's parameters put in.
  func memberValueType(_ entry: MemberEntry) -> Ty { substitute(valueType(of: entry.ref), entry.substitution) }

  /// A local's type.
  func localType(unitIndex: Int32, body: JavaBody, index: Int32) -> Ty {
    if let known = body.types[index] { return known }
    guard body.resolving.insert(index).inserted else { return .unknown }
    defer { body.resolving.remove(index) }
    let local = body.locals[Int(index)]
    let unit = project.units[Int(unitIndex)]
    var result = Ty.unknown
    switch local.kind {
    case .typed(let start, let end):
      result = parseType(unitIndex: unitIndex, start: start, end: end, scope: local.token)
      var k = Int(local.token) + 1
      while unit.isByte(k, 0x5B), unit.isByte(k + 1, 0x5D) {
        result = .constructed(Ty.array, [result])
        k += 2
      }
    case .inferred(let start, let end):
      result = expressionType(unitIndex: unitIndex, start: start, end: end)
    case .element(let start, let end):
      result = elementType(expressionType(unitIndex: unitIndex, start: start, end: end))
    case .lambda(let arrow, let position):
      result = lambdaParameterType(unitIndex: unitIndex, arrow: arrow, index: position, body: body)
    }
    body.types[index] = result
    return result
  }

  /// What a for-each over a value gives: an array's element, an `Iterable<T>`'s T.
  func elementType(_ ty: Ty) -> Ty {
    if case .constructed(let kind, let args) = ty, kind == Ty.array { return args.first ?? .unknown }
    guard let iterable = packageTypes("java.lang", named: name("Iterable")).first, case .nominal(_, let args)? = asSupertype(ty, iterable), let first = args.first else {
      return .unknown
    }
    return first
  }

  /// What a site is as a value.
  func siteType(_ site: Site, unitIndex: Int32) -> Ty {
    switch site {
    case .decl(let ref):
      return valueType(of: ref)
    case .local(let holder, let token):
      if let body = body(unitIndex: holder, token: token), let index = body.byToken[token] {
        return localType(unitIndex: holder, body: body, index: index)
      }
      return .unknown
    case .generic(let holder, let token):
      return .meta(typeOfSite(.generic(unit: holder, token: token), args: []))
    case .module(let package):
      return .module(package)
    }
  }

  // MARK: Assignability and overloads

  static let widening: [Name: Int] = [
    JavaWord.byte: 1, JavaWord.short: 2, JavaWord.char: 2, JavaWord.int: 3, JavaWord.long: 4, JavaWord.float: 5, JavaWord.double: 6,
  ]

  func box(_ ty: Ty) -> Ty {
    guard case .constructed(let kind, let args) = ty, args.isEmpty, let boxed = JavaWord.boxes[kind], let ref = langType(name(boxed)) else { return ty }
    return .nominal(ref, [])
  }

  func unbox(_ ty: Ty) -> Ty {
    guard case .nominal(let ref, _) = ty, packageOf(ref.unit) == "java.lang" else { return ty }
    let word = decl(ref).name
    for (primitive, boxed) in JavaWord.boxes where name(boxed) == word { return .constructed(primitive, []) }
    return ty
  }

  func isPrimitive(_ ty: Ty) -> Bool {
    if case .constructed(let kind, let args) = ty, args.isEmpty, JavaWord.primitives.contains(kind) { return true }
    return false
  }

  /// Whether a value of `from` can be passed where `to` is wanted: `nil` when it can't be told.
  func assignable(_ from: Ty, to: Ty, strict: Bool = false) -> Bool? {
    if from == .unknown || to == .unknown { return nil }
    if case .param = to { return true }
    if case .param = from { return nil }
    if case .constructed(let a, let fromArgs) = from, case .constructed(let b, let toArgs) = to {
      if a == Ty.array, b == Ty.array, let x = fromArgs.first, let y = toArgs.first {
        if isPrimitive(x) || isPrimitive(y) { return x == y }
        return assignable(x, to: y, strict: strict)
      }
      if let wa = Self.widening[a], let wb = Self.widening[b] {
        if a == b { return true }
        if a == JavaWord.char, b == JavaWord.short { return false }
        return wa <= wb && !(b == JavaWord.char)
      }
      return a == b
    }
    if isPrimitive(from) {
      if strict { return false }
      if isPrimitive(unbox(to)), unbox(to) != to { return assignable(from, to: unbox(to), strict: true) }
      return assignable(box(from), to: to, strict: true)
    }
    if isPrimitive(to) {
      if strict { return false }
      let unboxed = unbox(from)
      return unboxed == from ? false : assignable(unboxed, to: to, strict: true)
    }
    if case .constructed(let kind, _) = from, kind == Ty.array {
      if case .nominal(let ref, _) = to { return decl(ref).name == JavaWord.object || decl(ref).name == name("Cloneable") || decl(ref).name == name("Serializable") }
      return false
    }
    guard case .nominal(let target, _) = memberBase(to) else { return nil }
    if decl(target).name == JavaWord.object { return true }
    if case .nominal = memberBase(from) { return asSupertype(from, target) != nil }
    return nil
  }

  /// The arguments of the call whose `(` is at `open`: each one's tokens.
  func arguments(_ unit: Unit, open: Int) -> [(Int, Int)] {
    guard unit.isByte(open, 0x28) else { return [] }
    let close = unit.skipBalanced(open) - 1
    var result: [(Int, Int)] = []
    var i = open + 1
    let parser = JavaParser(unit: unit)
    while i < close {
      let end = min(parser.expressionEnd(i, limit: close), close)
      result.append((i, end))
      i = end + 1
    }
    return result
  }

  /// A lambda's parameter count, or nil for anything else; a method reference is -1.
  func functionalArgument(_ unit: Unit, _ range: (Int, Int)) -> Int? {
    let (start, end) = range
    if unit.isToken(start + 1, "->"), unit.javaIsName(start) { return 1 }
    if unit.isByte(start, 0x28) {
      let close = unit.skipBalanced(start) - 1
      if unit.isToken(close + 1, "->") {
        var count = 0
        var k = start + 1
        if k < close { count = 1 }
        while k < close {
          if unit.isByte(k, 0x2C) { count += 1 }
          k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
        }
        return count
      }
    }
    var k = start
    while k < end {
      if unit.isToken(k, "::") { return -1 }
      k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
    }
    return nil
  }

  /// A method's parameter types, its declaring class's parameters put in.
  package func parameterTypes(_ ref: DeclRef, _ map: [Name: Ty]) -> [Ty] {
    let item = decl(ref)
    let holder = unit(ref)
    return (0..<Int(item.paramCount)).map { p in
      let param = holder.params[Int(item.paramStart) + p]
      return substitute(parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: item.nameToken), map)
    }
  }

  package func isVariadic(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    guard item.paramCount > 0 else { return false }
    return unit(ref).params[Int(item.paramStart + item.paramCount - 1)].variadic
  }

  /// Of a call's methods, those its arguments fit: by count, then by the types that are known; the most specific when
  /// several fit. All of them when none does (code being typed).
  func chooseOverload(_ found: [DeclRef], unitIndex: Int32, open: Int, receiver: Ty) -> [DeclRef] {
    var unique: [DeclRef] = []
    for ref in found where !unique.contains(ref) { unique.append(ref) }
    let unit = project.units[Int(unitIndex)]
    guard !unique.isEmpty, unit.isByte(open, 0x28) else { return unique }
    let args = arguments(unit, open: open)
    let n = args.count
    // None that takes this many: what's declared isn't all there is (a stub, a missing overload). The caller gives
    // candidates.
    let byCount = unique.filter { ref in
      let count = Int(decl(ref).paramCount)
      return count == n || (isVariadic(ref) && n >= count - 1)
    }
    guard byCount.count > 1 else { return byCount }
    let map = receiverMap(receiver)
    var argTypes: [Ty?] = Array(repeating: nil, count: n)
    func argType(_ index: Int) -> Ty {
      if let known = argTypes[index] { return known }
      let ty = functionalArgument(unit, args[index]) == nil ? expressionType(unitIndex: unitIndex, start: Int32(args[index].0), end: Int32(args[index].1)) : .unknown
      argTypes[index] = ty
      return ty
    }
    // Phase 1 and 2: without spreading varargs; phase 3: spread.
    for spread in [false, true] {
      var fits: [DeclRef] = []
      var exactness: [DeclRef: Int] = [:]
      for ref in byCount {
        let params = parameterTypes(ref, map.merging(entryMap(ref, receiver)) { a, _ in a })
        let variadic = isVariadic(ref)
        if !spread, params.count != n { continue }
        if spread, !variadic { continue }
        var ok = true
        var exact = 0
        for index in 0..<n {
          var want: Ty
          if spread, variadic, index >= params.count - 1 {
            guard case .constructed(_, let element) = params[params.count - 1], let inner = element.first else { continue }
            want = inner
          } else {
            want = params[index]
          }
          if let lambda = functionalArgument(unit, args[index]) {
            if case .nominal = memberBase(want), let method = functionalMethod(of: want) {
              if lambda >= 0, Int(decl(method.ref).paramCount) != lambda { ok = false }
            } else if case .param = want {
            } else if want != .unknown {
              ok = false
            }
            continue
          }
          let have = argType(index)
          switch assignable(have, to: want) {
          case false?: ok = false
          case true?: if have == want || isPrimitive(have) == isPrimitive(want) { exact += 1 }
          case nil: break
          }
          if !ok { break }
        }
        if ok {
          fits.append(ref)
          exactness[ref] = exact
        }
      }
      if fits.count == 1 { return fits }
      if fits.count > 1 {
        // The most specific: each of its parameters fits the other's.
        let specific = fits.filter { a in
          fits.allSatisfy { b in
            a == b || zip(parameterTypes(a, map), parameterTypes(b, map)).allSatisfy { assignable($0.0, to: $0.1) ?? false }
          }
        }
        if specific.count == 1 { return specific }
        return fits
      }
    }
    return byCount
  }

  /// A receiver's arguments for its class's parameters.
  func receiverMap(_ receiver: Ty) -> [Name: Ty] {
    if case .nominal(let ref, let args) = memberBase(receiver) { return parameterMap(ref, args) }
    return [:]
  }

  /// How a method's declaring class's parameters read through the receiver: the member entry's substitution.
  func entryMap(_ ref: DeclRef, _ receiver: Ty) -> [Name: Ty] {
    let item = decl(ref)
    for (entry, _) in memberEntries(of: receiver, named: item.name) where entry.ref == ref { return entry.substitution }
    return [:]
  }

  // MARK: Functional interfaces and lambdas

  /// The one abstract method of a functional interface type, with the substitution to read it through.
  func functionalMethod(of ty: Ty) -> MemberEntry? {
    guard case .nominal(let ref, let args) = memberBase(ty), decl(ref).kind == .protocolType else { return nil }
    let map = parameterMap(ref, args)
    var found: MemberEntry?
    for (_, entries) in memberTable(of: ref) {
      for entry in entries {
        let item = decl(entry.ref)
        guard item.kind == .function, item.bodyOpen < 0, !item.isStatic, !isDefaultMethod(entry.ref), decl(DeclRef(unit: entry.ref.unit, decl: item.parent)).kind == .protocolType else { continue }
        // Object's methods (`equals`) restated in an interface don't count.
        if let object = langType(JavaWord.object), memberTable(of: object)[item.name]?.contains(where: { signature($0.ref, [:]) == signature(entry.ref, entry.substitution) }) == true { continue }
        if found != nil, found!.ref != entry.ref { return nil }
        var composed = entry
        composed.substitution = entry.substitution.mapValues { substitute($0, map) }.merging(map) { first, _ in first }
        found = composed
      }
    }
    return found
  }

  /// An interface's `default` method (a stub's may have no body).
  func isDefaultMethod(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    let holder = unit(ref)
    var k = Int(item.first)
    while k < Int(item.nameToken) {
      if holder.isToken(k, "default") { return true }
      k += 1
    }
    return false
  }

  /// The type a lambda or method reference starting at `start` is given to: a parameter of the call it's an
  /// argument of, the declared type it initializes, a cast's type.
  func functionalTarget(unitIndex: Int32, start: Int) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    let before = start - 1
    guard before >= 0 else { return nil }
    if unit.isByte(before, 0x28) || unit.isByte(before, 0x2C), let open = unit.isByte(before, 0x28) ? before : unit.matchingOpenBefore(before), unit.isByte(open, 0x28) {
      // A cast: `(Runnable) () -> …`.
      if unit.isByte(before, 0x29) { return nil }
      let args = arguments(unit, open: open)
      guard let position = args.firstIndex(where: { $0.0 == start }) else { return nil }
      guard let call = callTarget(unitIndex: unitIndex, open: open) else { return nil }
      let chosen = chooseOverload(call.methods, unitIndex: unitIndex, open: open, receiver: call.receiver)
      // The overloads must agree on the parameter's interface.
      var result: Ty?
      for ref in chosen {
        var params = parameterTypes(ref, receiverMap(call.receiver).merging(entryMap(ref, call.receiver)) { a, _ in a })
        if isVariadic(ref), position >= params.count - 1, case .constructed(_, let element)? = params.last, let inner = element.first { params.append(inner) }
        guard position < params.count else { continue }
        var param = params[min(position, params.count - 1)]
        // What the other arguments tell of the method's own parameters.
        let bindings = inferBindings(ref, call: call, unitIndex: unitIndex, open: open, skipping: position)
        param = substitute(param, bindings)
        if let current = result, erasure(current) != erasure(param) { return nil }
        result = param
      }
      return result
    }
    if unit.isToken(before, "=") {
      // `Type name = …` or `name = …`.
      let nameToken = before - 1
      if let body = body(unitIndex: unitIndex, token: Int32(nameToken)), let index = body.byToken[Int32(nameToken)] {
        return localType(unitIndex: unitIndex, body: body, index: index)
      }
      if case .decl(let ref)? = unit.declaredSite(at: nameToken, unitIndex: unitIndex) { return valueType(of: ref) }
      let found = answer(unitIndex: unitIndex, token: nameToken)
      if found.state == .exact, let site = found.sites.first { return siteType(site, unitIndex: unitIndex) }
      return nil
    }
    if unit.isByte(before, 0x29), let open = unit.matchingOpen(before) {
      let ty = parseType(unitIndex: unitIndex, start: Int32(open + 1), end: Int32(before), scope: Int32(open))
      return ty == .unknown ? nil : ty
    }
    if unit.isToken(before, "return") {
      for index in unit.chain(at: Int32(start)).reversed() where unit.decls[Int(index)].kind == .function {
        return valueType(of: DeclRef(unit: unitIndex, decl: index))
      }
    }
    return nil
  }

  /// The methods a call's `(` belongs to, and the type they're members of.
  func callTarget(unitIndex: Int32, open: Int) -> (methods: [DeclRef], receiver: Ty)? {
    let unit = project.units[Int(unitIndex)]
    let nameToken = open - 1
    guard unit.javaIsName(nameToken) else { return nil }
    let word = unit.hash(nameToken)
    if unit.isToken(nameToken - 1, "new") || (unit.tokens[nameToken - 1].kind == .punctuation && unit.startsWith(nameToken - 1, 0x2E) == false && false) {
      return nil
    }
    // Explicit type arguments: `x.<T>name(`.
    var dot = nameToken - 1
    if dot >= 0, unit.tokens[dot].kind == .punctuation, unit.punctuation(dot, madeOf: ">"), var k = Optional(dot) {
      while k > 0, !(unit.tokens[k].kind == .punctuation && unit.startsWith(k, 0x3C)) { k -= 1 }
      dot = k - 1
    }
    if unit.isByte(dot, 0x2E) {
      let receiver = operandType(unitIndex: unitIndex, dot: dot)
      var type = receiver
      if case .meta(let inner) = receiver { type = inner }
      let methods = methodSites(of: type, named: word, from: unitIndex)
      return methods.isEmpty ? nil : (methods, type)
    }
    let found = simpleMethods(word, unitIndex: unitIndex, token: Int32(nameToken))
    return found.isEmpty ? nil : (found.map(\.0), found.first?.1 ?? .unknown)
  }

  /// A generic method's own parameters as its arguments tell them (lambdas' results too, unless `skipping` is theirs).
  func inferBindings(_ ref: DeclRef, call: (methods: [DeclRef], receiver: Ty), unitIndex: Int32, open: Int, skipping: Int, own given: Set<Name>? = nil) -> [Name: Ty] {
    let item = decl(ref)
    guard item.genericCount > 0 || given != nil else { return [:] }
    let holder = unit(ref)
    var own: Set<Name> = given ?? []
    for g in 0..<Int(item.genericCount) { own.insert(holder.generics[Int(item.genericStart) + g].name) }
    let unit = project.units[Int(unitIndex)]
    let args = arguments(unit, open: open)
    let map = receiverMap(call.receiver).merging(entryMap(ref, call.receiver)) { a, _ in a }
    var params = parameterTypes(ref, map)
    if isVariadic(ref), args.count >= params.count, case .constructed(_, let element)? = params.last, let inner = element.first {
      params[params.count - 1] = inner
    }
    var bindings: [Name: Ty] = [:]
    for (index, range) in args.enumerated() where index != skipping {
      let param = params[min(index, max(params.count - 1, 0))]
      guard !params.isEmpty else { break }
      if functionalArgument(unit, range) != nil {
        // A lambda's result binds what its interface's method returns.
        guard let lambdaResult = lambdaResultType(unitIndex: unitIndex, range: range, target: substitute(param, bindings)),
          let method = functionalMethod(of: param)
        else { continue }
        let declared = substitute(valueType(of: method.ref), method.substitution)
        unify(declared, box(lambdaResult), own, &bindings)
        continue
      }
      let have = expressionType(unitIndex: unitIndex, start: Int32(range.0), end: Int32(range.1))
      unify(param, box(have), own, &bindings)
    }
    return bindings
  }


  /// A lambda parameter's type: its interface's method's parameter.
  func lambdaParameterType(unitIndex: Int32, arrow: Int32, index: Int32, body: JavaBody) -> Ty {
    guard let lambda = body.lambdas[arrow] else { return .unknown }
    let unit = project.units[Int(unitIndex)]
    let start = lambda.params.count == 1 && Int(lambda.params[0]) == Int(arrow) - 1 ? Int(arrow) - 1 : unit.matchingOpen(Int(arrow) - 1) ?? Int(arrow) - 1
    guard let target = functionalTarget(unitIndex: unitIndex, start: start), let method = functionalMethod(of: target) else { return .unknown }
    let params = parameterTypes(method.ref, method.substitution)
    guard Int(index) < params.count else { return .unknown }
    let ty = params[Int(index)]
    if case .param = ty, bound(of: ty) == nil { return .unknown }
    return ty
  }

  /// What a lambda (its tokens) returns, given the interface it's for: its expression's type, or its block's first
  /// `return` with a value.
  func lambdaResultType(unitIndex: Int32, range: (Int, Int), target: Ty) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    var arrow = range.0
    while arrow < range.1, !unit.isToken(arrow, "->") { arrow = unit.tokens[arrow].kind == .open ? unit.skipBalanced(arrow) : arrow + 1 }
    guard arrow < range.1 else {
      // A method reference: its method's result.
      return methodReferenceResult(unitIndex: unitIndex, range: range, target: target)
    }
    if unit.isByte(arrow + 1, 0x7B) {
      var k = arrow + 2
      let close = unit.skipBalanced(arrow + 1) - 1
      while k < close {
        if unit.isToken(k, "return"), !unit.isByte(k + 1, 0x3B) {
          let end = JavaParser(unit: unit).expressionEnd(k + 1, limit: close)
          let ty = expressionType(unitIndex: unitIndex, start: Int32(k + 1), end: Int32(end))
          return ty == .unknown ? nil : ty
        }
        // Not into nested lambdas or classes.
        if unit.isByte(k, 0x7B), unit.isToken(k - 1, "->") || unit.isByte(k - 1, 0x29) && false {
          k = unit.skipBalanced(k)
          continue
        }
        k += 1
      }
      return nil
    }
    let ty = expressionType(unitIndex: unitIndex, start: Int32(arrow + 1), end: Int32(range.1))
    return ty == .unknown ? nil : ty
  }

  private func methodReferenceResult(unitIndex: Int32, range: (Int, Int), target: Ty) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    var k = range.0
    while k < range.1, !unit.isToken(k, "::") { k += 1 }
    guard k + 1 < range.1 || k + 1 == range.1 - 0, unit.javaIsName(k + 1) || unit.isToken(k + 1, "new") else { return nil }
    let receiver = operandType(unitIndex: unitIndex, dot: k)
    var type = receiver
    if case .meta(let inner) = receiver { type = inner }
    if unit.isToken(k + 1, "new") { return type == .unknown ? nil : type }
    let methods = memberEntries(of: type, named: unit.hash(k + 1)).filter { decl($0.0.ref).kind == .function }
    guard let first = methods.first else { return nil }
    let ty = memberValueType(first.0)
    return ty == .unknown ? nil : ty
  }
}
