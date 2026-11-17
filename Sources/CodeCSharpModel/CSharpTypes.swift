import CodeModel
import CodeScan
import Foundation

/// C#'s types (`Ty`, the core's): classes, structs, interfaces, enums and delegates are `nominal` with their arguments
/// (a partial type by its first part), the keyword types their `System` structs (`int` is `Int32`), `T?` of a value type
/// `Nullable<T>`, arrays and pointers `constructed`, tuples `tuple`, a type parameter `param` (with the declaration that
/// has it, for its constraints), a type used for its static members `meta`, a namespace `module`.
extension CSharpModel {
  // MARK: Written types

  struct Cursor {
    var i: Int
    var sub = 0
  }

  /// A type written from `start` to `end`, its names looked up from token `scope` (-1: the global namespace).
  package func parseType(unitIndex: Int32, start: Int32, end: Int32, scope: Int32) -> Ty {
    guard start >= 0, start < end else { return .unknown }
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

  /// A keyword type's `System` struct or class: `int` is `Int32`.
  func predefinedType(_ word: Name) -> Ty {
    guard let text = CSharpWord.predefined[word] else { return .unknown }
    if word == CSharpWord.voidWord { return .constructed(CSharpWord.voidWord, []) }
    return systemType(text).map { .nominal($0, []) } ?? .unknown
  }

  private func readType(_ unitIndex: Int32, _ c: inout Cursor, _ end: Int, _ scope: Int32) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard c.i < end else { return .unknown }
    if c.sub == 0 { c.i = unit.csSkipAttributes(c.i, limit: end) }
    while c.sub == 0, c.i < end, unit.isToken(c.i, "ref") || unit.isToken(c.i, "readonly") || unit.isToken(c.i, "scoped") || unit.isToken(c.i, "out") || unit.isToken(c.i, "in") || unit.isToken(c.i, "params") {
      c.i += 1
    }
    guard c.sub == 0, c.i < end else { return .unknown }
    var ty: Ty
    if unit.isByte(c.i, 0x28) {
      // A tuple: `(int a, string b)`.
      let close = unit.skipBalanced(c.i)
      var elements: [Ty] = []
      var labels: [Name] = []
      var k = c.i + 1
      while k < close - 1 {
        var inner = Cursor(i: k)
        elements.append(readType(unitIndex, &inner, close - 1, scope))
        k = inner.i
        if unit.csIsName(k) {
          labels.append(unit.hash(k))
          k += 1
        } else {
          labels.append(0)
        }
        while k < close - 1, !unit.isByte(k, 0x2C) { k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1 }
        k += 1
      }
      c.i = close
      ty = .tuple(elements, labels)
    } else if unit.csIsPredefined(c.i), !unit.isToken(c.i, "dynamic") {
      ty = predefinedType(unit.hash(c.i))
      c.i += 1
    } else if unit.csIsName(c.i) {
      ty = .unknown
      var namespace = ""
      var first = true
      if unit.isToken(c.i, "global"), unit.isToken(c.i + 1, "::") {
        c.i += 2
        first = false
      }
      while c.i < end, unit.csIsName(c.i) {
        let word = unit.hash(c.i)
        let text = unit.string(c.i)
        c.i += 1
        var args: [Ty] = []
        var arity = 0
        if char(unit, c, end) == 0x3C {
          advance(unit, &c)
          args = readArguments(unitIndex, &c, end, scope)
          arity = args.count
        }
        if unit.isToken(c.i, "::") { c.i += 1 }
        if first {
          first = false
          if word == CSharpWord.dynamicWord { return .unknown }
          var found = scope >= 0 ? typeSites(word, arity: arity, unitIndex: unitIndex, token: scope) : namespaceTypes("", named: word, arity: arity, from: unitIndex).map { .decl($0) }
          if found.isEmpty, scope == CSharpModel.aliasScope {
            // An alias's target sees the global usings, not the file's others.
            for namespace in globalUsingNamespaces(unitIndex) where found.isEmpty {
              found = namespaceTypes(namespace, named: word, arity: arity, from: unitIndex).map { .decl($0) }
            }
          }
          if let site = found.first {
            ty = typeOfSite(site, args: args)
          } else if scope >= 0, case .module(let hashed)? = nameSites(word, unitIndex: unitIndex, token: scope).first {
            namespace = namespaceNames[hashed] ?? text
          } else {
            namespace = text
          }
        } else if case .unknown = ty, !namespace.isEmpty || !first {
          if let ref = namespaceTypes(namespace, named: word, arity: arity, from: unitIndex).first {
            ty = .nominal(canonical(ref), args)
            namespace = ""
          } else {
            namespace = namespace.isEmpty ? text : namespace + "." + text
          }
        } else if ty != .unknown {
          // A nested type of a generic type keeps the outer type's arguments.
          let outerMap: [Name: Ty] = { if case .nominal(let outer, let outerArgs) = ty { return parameterMap(outer, outerArgs) } else { return [:] } }()
          if let ref = memberTypeRefs(of: ty, named: word, arity: arity).first {
            ty = .nominal(canonical(ref), args)
            if !outerMap.isEmpty { ty = substituteOuter(ty, outerMap) }
          } else {
            return .unknown
          }
        }
        if c.sub == 0, unit.isByte(c.i, 0x2E), c.i + 1 < end, unit.csIsName(c.i + 1) {
          c.i += 1
          continue
        }
        break
      }
      if case .unknown = ty, !namespace.isEmpty, isNamespace(namespace) { return .module(name(namespace)) }
    } else {
      return .unknown
    }
    // Suffixes: `?`, `*`, `[]`, `[,]`.
    while c.sub == 0, c.i < end {
      if unit.isByte(c.i, 0x3F) {
        ty = nullable(ty)
        c.i += 1
      } else if unit.isByte(c.i, 0x2A) {
        ty = .constructed(Ty.pointer, [ty])
        c.i += 1
      } else if unit.isByte(c.i, 0x5B) {
        let close = unit.skipBalanced(c.i)
        ty = .constructed(Ty.array, [ty])
        c.i = close
      } else {
        break
      }
    }
    if c.sub == 0, char(unit, c, end) == 0x3F {
      // `List<int?>`: the `?` is the first byte of a `?>`.
      ty = nullable(ty)
      advance(unit, &c)
    }
    return ty
  }

  /// A nested type's own type with the outer type's arguments put in: `Outer<int>.Inner` sees `T` as `int`.
  private func substituteOuter(_ ty: Ty, _ map: [Name: Ty]) -> Ty { ty }

  /// `T?`: `Nullable<T>` for a value type, the same type otherwise (a nullable annotation).
  func nullable(_ ty: Ty) -> Ty {
    guard case .nominal(let ref, _) = ty, isValueType(ref), let wrapper = systemType("Nullable", arity: 1), canonical(ref) != wrapper else { return ty }
    return .nominal(wrapper, [ty])
  }

  /// `Nullable<T>`'s T.
  func nullableValue(_ ty: Ty) -> Ty? {
    guard case .nominal(let ref, let args) = ty, args.count == 1, decl(ref).name == CSharpWord.nullableWord, enclosingNamespace(ref) == "System" else { return nil }
    return args[0]
  }

  func isValueType(_ ref: DeclRef) -> Bool {
    let kind = decl(ref).kind
    return kind == .structure || kind == .enumeration
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
      if char(unit, c, end) == 0x2C || c.sub == 0 && unit.isByte(c.i, 0x2C) {
        // `Dictionary<,>`: an argument left out.
        args.append(.unknown)
        advance(unit, &c)
        continue
      }
      let before = (c.i, c.sub)
      args.append(readType(unitIndex, &c, end, scope))
      if char(unit, c, end) == 0x2C || (c.sub == 0 && unit.isByte(c.i, 0x2C)) {
        advance(unit, &c)
        if char(unit, c, end) == 0x3E { args.append(.unknown) }
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
      return .nominal(canonical(ref), args)
    case .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      for (index, item) in holder.decls.enumerated() where item.genericCount > 0 {
        for g in 0..<Int(item.genericCount) where holder.generics[Int(item.genericStart) + g].token == token {
          return .param(holder.hash(Int(token)), DeclRef(unit: unitIndex, decl: Int32(index)))
        }
      }
      return .param(holder.hash(Int(token)), nil)
    case .module(let hashed):
      return .module(hashed)
    case .local:
      return .unknown
    }
  }

  /// A type parameter's constraints, as written: `where T : Base, IFoo, new()` gives Base and IFoo.
  func constraints(of ty: Ty) -> [Ty] {
    guard case .param(let word, let owner?) = ty else { return [] }
    let holder = self.unit(owner)
    let item = decl(owner)
    guard item.whereStart >= 0 else { return [] }
    var k = Int(item.whereStart)
    let end = Int(item.whereEnd)
    var result: [Ty] = []
    while k < end {
      guard holder.isToken(k, "where"), holder.csIsName(k + 1), holder.hash(k + 1) == word, holder.isByte(k + 2, 0x3A) else {
        k += 1
        continue
      }
      k += 3
      while k < end, !holder.isToken(k, "where") {
        var itemEnd = k
        while itemEnd < end, !holder.isByte(itemEnd, 0x2C), !holder.isToken(itemEnd, "where") {
          if holder.tokens[itemEnd].kind == .punctuation, holder.startsWith(itemEnd, 0x3C), let after = holder.csTypeArgumentsEnd(itemEnd, limit: end) {
            itemEnd = after
            continue
          }
          itemEnd = holder.tokens[itemEnd].kind == .open ? holder.skipBalanced(itemEnd) : itemEnd + 1
        }
        let special = holder.isToken(k, "class") || holder.isToken(k, "struct") || holder.isToken(k, "new") || holder.isToken(k, "notnull") || holder.isToken(k, "unmanaged")
          || holder.isToken(k, "default") || holder.isToken(k, "allows")
        if !special {
          let found = parseType(unitIndex: owner.unit, start: Int32(k), end: Int32(itemEnd), scope: item.nameToken)
          if found != .unknown, found != ty { result.append(found) }
        }
        k = itemEnd
        if holder.isByte(k, 0x2C) { k += 1 }
      }
      break
    }
    return result
  }

  /// What a type's members are looked up in: a type parameter's first constraint (else `object`), an array's `Array`,
  /// a tuple's `ValueTuple<…>`.
  package func memberBase(_ ty: Ty, depth: Int = 0) -> Ty {
    switch ty {
    case .param:
      guard depth < 6, let found = constraints(of: ty).first else { return systemType("Object").map { .nominal($0, []) } ?? .unknown }
      return memberBase(found, depth: depth + 1)
    case .constructed(let kind, _) where kind == Ty.array:
      return systemType("Array").map { .nominal($0, []) } ?? .unknown
    case .tuple(let elements, _):
      guard (1...7).contains(elements.count), let ref = systemType("ValueTuple", arity: elements.count) else { return .unknown }
      return .nominal(ref, elements)
    default:
      return ty
    }
  }

  // MARK: Hierarchy

  /// Whether a declaration is a delegate: a class with a return type and no body.
  func isDelegate(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    return item.kind == .classType && item.typeStart >= 0 && self.unit(ref).isToken(Int(item.typeStart) - 1, "delegate")
  }

  /// A type's direct base types as written (every part's), in terms of its own parameters: its base class (or the
  /// implicit one: `object`, `ValueType`, `Enum`, `MulticastDelegate`) first, then its interfaces.
  package func supertypes(of start: DeclRef) -> [Ty] {
    let ref = canonical(start)
    if let known = supertypeCache[ref] { return known }
    supertypeCache[ref] = []
    let item = decl(ref)
    var result: [Ty] = []
    var hasBase = false
    if item.kind != .enumeration, !isDelegate(ref) {
      for part in parts(ref) {
        let holder = self.unit(part)
        let partDecl = decl(part)
        for r in 0..<Int(partDecl.inheritCount) {
          let range = holder.ranges[Int(partDecl.inheritStart) + r]
          let ty = parseType(unitIndex: part.unit, start: range.start, end: range.end, scope: partDecl.nameToken)
          guard case .nominal(let target, _) = ty, target != ref, !result.contains(ty) else { continue }
          if decl(target).kind == .classType, !isDelegate(target) || true, item.kind == .classType {
            if hasBase { continue }
            hasBase = true
            result.insert(ty, at: 0)
          } else {
            result.append(ty)
          }
        }
      }
    }
    let text = self.unit(ref).string(Int(item.nameToken))
    let isObject = text == "Object" && enclosingNamespace(ref) == "System" && item.kind == .classType
    switch item.kind {
    case .structure:
      if let base = systemType("ValueType") { result.insert(.nominal(base, []), at: 0) }
    case .enumeration:
      if let base = systemType("Enum") { result.insert(.nominal(base, []), at: 0) }
    case .protocolType:
      if let object = systemType("Object") { result.append(.nominal(object, [])) }
    case .classType:
      if isDelegate(ref) {
        if let base = systemType("MulticastDelegate") { result.insert(.nominal(base, []), at: 0) }
      } else if !hasBase, !isObject, let object = systemType("Object") {
        result.insert(.nominal(object, []), at: 0)
      }
    default:
      break
    }
    supertypeCache[ref] = result
    return result
  }

  /// An array is also the generic collections' interfaces of its element.
  package func asSupertype(_ ty: Ty, _ target: DeclRef, depth: Int = 0) -> Ty? {
    if case .constructed(let kind, let args) = ty, kind == Ty.array, let element = args.first {
      let item = decl(target)
      if item.genericCount == 1, enclosingNamespace(target) == "System.Collections.Generic", CSharpWord.arrayInterfaces.contains(item.name) {
        return .nominal(target, [element])
      }
    }
    return nominalSupertype(ty, target, depth: depth)
  }

  /// A type's members by name: its own (every part's), then its base class's (or base interfaces') that it doesn't
  /// override or hide, nearest first. A class doesn't inherit its interfaces' members.
  func memberTable(of start: DeclRef) -> [Name: [MemberEntry]] {
    let ref = canonical(start)
    if let known = tables[ref] { return known }
    guard building.insert(ref).inserted else { return [:] }
    defer { building.remove(ref) }
    var table: [Name: [MemberEntry]] = [:]
    var signatures: Set<String> = []
    let isInterface = decl(ref).kind == .protocolType
    for part in parts(ref) {
      let holder = self.unit(part)
      for child in holder.children(of: part.decl) {
        let entry = holder.decls[Int(child)]
        guard entry.name != 0, entry.kind != .initializer, entry.kind != .deinitializer, entry.kind != .extensionDecl, !entry.isLocal else { continue }
        // `void IFoo.Bar()`: an explicit implementation is the interface's.
        if holder.isByte(Int(entry.nameToken) - 1, 0x2E) { continue }
        let member = DeclRef(unit: part.unit, decl: child)
        table[entry.name, default: []].append(MemberEntry(ref: member, substitution: [:]))
        if entry.kind == .function { signatures.insert(signature(member, [:])) }
      }
    }
    for parent in supertypes(of: ref) {
      guard case .nominal(let target, let args) = parent else { continue }
      if !isInterface, decl(target).kind == .protocolType { continue }
      let map = parameterMap(target, args)
      for (word, entries) in memberTable(of: target) {
        let own = table[word]
        for entry in entries {
          let item = decl(entry.ref)
          if item.access == .isPrivate { continue }
          let composed = entry.substitution.mapValues { substitute($0, map) }.merging(map) { first, _ in first }
          if item.kind == .function {
            if !signatures.insert(signature(entry.ref, composed)).inserted { continue }
            // A property or field of the name hides the methods.
            if let own, own.contains(where: { decl($0.ref).kind != .function }) { continue }
          } else if let own, !own.isEmpty, own.contains(where: { decl($0.ref).kind != .function || item.kind != .function }) {
            continue
          }
          table[word, default: []].append(MemberEntry(ref: entry.ref, substitution: composed))
        }
      }
    }
    tables[ref] = table
    return table
  }

  /// A method's name and parameter types, erased, as a derived type would override it.
  func signature(_ ref: DeclRef, _ map: [Name: Ty]) -> String {
    let item = decl(ref)
    let holder = self.unit(ref)
    var key = String(item.name) + "/" + String(item.paramCount) + "/" + String(item.genericCount)
    for p in 0..<Int(item.paramCount) {
      let param = holder.params[Int(item.paramStart) + p]
      key += ":" + erasure(substitute(parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: item.nameToken), map))
    }
    return key
  }

  func erasure(_ ty: Ty) -> String {
    switch ty {
    case .nominal(let ref, let args): return String(decl(ref).name) + "`" + String(args.count)
    case .constructed(let kind, let args): return String(kind) + "[" + args.map(erasure).joined(separator: ",") + "]"
    case .param(let word, let owner): return owner.map { decl($0).kind == .function ? "!!" : "!" } ?? String(word)
    case .tuple(let elements, _): return "(" + elements.map(erasure).joined(separator: ",") + ")"
    default: return "?"
    }
  }

  /// A type's members of a name, nearest first.
  func memberEntries(of ty: Ty, named word: Name) -> [(MemberEntry, Ty)] {
    let base = memberBase(ty)
    guard case .nominal(let ref, let args) = base else { return [] }
    let map = parameterMap(ref, args)
    var result: [(MemberEntry, Ty)] = (memberTable(of: ref)[word] ?? []).map { entry in
      var composed = entry
      composed.substitution = entry.substitution.mapValues { substitute($0, map) }.merging(map) { first, _ in first }
      return (composed, base)
    }
    // A type parameter's other constraints: their members too.
    if result.isEmpty, case .param = ty {
      for other in constraints(of: ty).dropFirst() {
        result = memberEntries(of: other, named: word)
        if !result.isEmpty { break }
      }
    }
    return result
  }

  func memberSites(of ty: Ty, named word: Name) -> [DeclRef] { memberEntries(of: ty, named: word).map(\.0.ref) }

  /// Nested types of a type named so, of the arity asked (nil: any), inherited ones too.
  func memberTypeRefs(of ty: Ty, named word: Name, arity: Int?) -> [DeclRef] {
    memberEntries(of: ty, named: word).map(\.0.ref).filter { decl($0).kind.isNominal && (arity == nil || Int(decl($0).genericCount) == arity!) }
  }

  // MARK: Values

  /// A declaration's type as a value: a field's, property's or event's, a method's result, an enum member's enum, a
  /// type's own (for its static members).
  package func valueType(of ref: DeclRef) -> Ty {
    if let known = valueTypes[ref] { return known }
    guard resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    let item = decl(ref)
    var result = Ty.unknown
    switch item.kind {
    case .variable, .function, .subscriptDecl:
      if item.typeStart >= 0 { result = parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: item.nameToken) }
    case .enumCase:
      if item.parent >= 0 { result = .nominal(canonical(DeclRef(unit: ref.unit, decl: item.parent)), []) }
    case .classType, .protocolType, .enumeration, .structure:
      result = .meta(.nominal(canonical(ref), []))
    default:
      break
    }
    if !item.isLocal { valueTypes[ref] = result }
    return result
  }

  /// A member's type through the type it was found on: its declaring type's parameters put in.
  func memberValueType(_ entry: MemberEntry) -> Ty { substitute(valueType(of: entry.ref), entry.substitution) }

  /// A local's type.
  func localType(unitIndex: Int32, body: CSharpBody, index: Int32) -> Ty {
    if let known = body.types[index] { return known }
    guard body.resolving.insert(index).inserted else { return .unknown }
    defer { body.resolving.remove(index) }
    let local = body.locals[Int(index)]
    var result = Ty.unknown
    switch local.kind {
    case .typed(let start, let end):
      result = parseType(unitIndex: unitIndex, start: start, end: end, scope: local.token)
    case .inferred(let start, let end):
      result = expressionType(unitIndex: unitIndex, start: start, end: end)
      if case .meta = result { result = .unknown }
    case .element(let start, let end):
      result = elementType(expressionType(unitIndex: unitIndex, start: start, end: end))
    case .lambda(let arrow, let position):
      result = lambdaParameterType(unitIndex: unitIndex, arrow: arrow, index: position)
    case .tested(let start, let end):
      result = expressionType(unitIndex: unitIndex, start: start, end: end)
    case .outArgument(let open, let position):
      result = outArgumentType(unitIndex: unitIndex, open: Int(open), position: Int(position))
    case .unknown:
      break
    }
    body.types[index] = result
    return result
  }

  /// What a `foreach` over a value gives: an array's element, an `IEnumerable<T>`'s T.
  func elementType(_ ty: Ty) -> Ty {
    if case .constructed(let kind, let args) = ty, kind == Ty.array { return args.first ?? .unknown }
    guard let enumerable = namespaceTypes("System.Collections.Generic", named: CSharpWord.enumerableInterface, arity: 1, from: -1).first,
      case .nominal(_, let args)? = asSupertype(ty, enumerable), let first = args.first
    else {
      return .unknown
    }
    return first
  }

  /// What a site is as a value.
  func siteType(_ site: Site, unitIndex: Int32) -> Ty {
    switch site {
    case .decl(let ref):
      // A method group isn't a value this model types.
      if decl(ref).kind == .function { return .unknown }
      return valueType(of: ref)
    case .local(let holder, let token):
      if let body = body(unitIndex: holder, token: token), let index = body.byToken[token] {
        return localType(unitIndex: holder, body: body, index: index)
      }
      // A primary constructor's parameter seen from a member.
      let owner = project.units[Int(holder)]
      for item in owner.decls where item.kind.isNominal && item.paramCount > 0 {
        for p in 0..<Int(item.paramCount) where owner.params[Int(item.paramStart) + p].nameToken == token {
          let param = owner.params[Int(item.paramStart) + p]
          return parseType(unitIndex: holder, start: param.typeStart, end: param.typeEnd, scope: token)
        }
      }
      return .unknown
    case .generic(let holder, let token):
      return .meta(typeOfSite(.generic(unit: holder, token: token), args: []))
    case .module(let hashed):
      return .module(hashed)
    }
  }

  // MARK: Assignability

  /// Whether a value of `from` converts implicitly to `to`: nil when it can't be told.
  func assignable(_ from: Ty, to: Ty) -> Bool? {
    if from == .unknown || to == .unknown { return nil }
    if from == to { return true }
    if case .param = to { return true }
    if case .param = from { return nil }
    if case .tuple = from { return nil }
    if case .tuple = to { return nil }
    if case .constructed(let a, let fromArgs) = from, case .constructed(let b, let toArgs) = to {
      if a == Ty.array, b == Ty.array, let x = fromArgs.first, let y = toArgs.first {
        if case .param = y { return true }
        if case .nominal(let ref, _) = x, isValueType(ref) { return x == y }
        return assignable(x, to: y)
      }
      return a == b ? nil : false
    }
    guard case .nominal(let target, _) = memberBase(to) else { return nil }
    let targetName = decl(target).name
    if targetName == CSharpWord.object, enclosingNamespace(target) == "System" { return true }
    if case .constructed(let kind, _) = from {
      if kind == Ty.array {
        if asSupertype(from, target) != nil { return true }
        // Spans and user conversions.
        return implicitConversion(from: from, to: to) ? nil : (decl(target).kind == .protocolType || decl(target).kind == .classType ? asSupertype(.nominal(systemType("Array") ?? target, []), target) != nil : false)
      }
      return nil
    }
    guard case .nominal(let source, _) = memberBase(from) else { return nil }
    if let numeric = numericConversion(source, target) { return numeric }
    if asSupertype(from, target) != nil { return true }
    // `T` to `T?`.
    if let inner = nullableValue(to), assignable(from, to: inner) == true { return true }
    if implicitConversion(from: from, to: to) { return nil }
    if isDelegate(source) || isDelegate(target) { return nil }
    return false
  }

  /// C#'s implicit numeric conversions between the keyword types: nil when either isn't one.
  func numericConversion(_ source: DeclRef, _ target: DeclRef) -> Bool? {
    guard enclosingNamespace(source) == "System", enclosingNamespace(target) == "System" else { return nil }
    let from = self.unit(source).string(Int(decl(source).nameToken))
    let to = self.unit(target).string(Int(decl(target).nameToken))
    guard let widens = CSharpWord.numericWidening[from], CSharpWord.numericWidening[to] != nil else { return nil }
    return from == to || widens.contains(to)
  }

  /// Whether a user-defined `implicit operator` of either type converts one to the other (`string` to
  /// `ReadOnlySpan<char>`, `T[]` to `Span<T>`), matched by declaration, not by type arguments.
  func implicitConversion(from: Ty, to: Ty) -> Bool {
    var owners: [DeclRef] = []
    if case .nominal(let ref, _) = memberBase(from) { owners.append(ref) }
    if case .nominal(let ref, _) = memberBase(to), !owners.contains(ref) { owners.append(ref) }
    func fits(_ have: Ty, _ want: Ty) -> Bool {
      if case .param = want { return true }
      if case .constructed(let a, _) = have, case .constructed(let b, _) = want { return a == b }
      guard case .nominal(let target, _) = memberBase(want) else { return false }
      if let inner = nullableValue(want), case .nominal = memberBase(inner) { return fits(have, inner) }
      return asSupertype(have, target) != nil
    }
    for owner in owners {
      for part in parts(canonical(owner)) {
        let holder = self.unit(part)
        for child in holder.children(of: part.decl) {
          let item = holder.decls[Int(child)]
          guard item.kind == .function, item.name == 0, holder.isToken(Int(item.nameToken) - 1, "implicit"), item.paramCount == 1, item.typeStart >= 0 else { continue }
          let result = parseType(unitIndex: part.unit, start: item.typeStart, end: item.typeEnd, scope: item.nameToken)
          let param = holder.params[Int(item.paramStart)]
          let source = parseType(unitIndex: part.unit, start: param.typeStart, end: param.typeEnd, scope: item.nameToken)
          if fits(from, source), fits(result, to) { return true }
        }
      }
    }
    return false
  }

  // MARK: Calls

  /// A call's arguments: each one's tokens (after `ref`, `out` or `in`), and its name when written `name: value`.
  func arguments(_ unit: Unit, open: Int) -> [(start: Int, end: Int, label: Name)] {
    guard unit.isByte(open, 0x28) || unit.isByte(open, 0x5B) else { return [] }
    let close = unit.skipBalanced(open) - 1
    var result: [(Int, Int, Name)] = []
    var i = open + 1
    let parser = CSharpParser(unit: unit)
    while i < close {
      let end = min(parser.expressionEnd(i, limit: close), close)
      var start = i
      var label: Name = 0
      if unit.csIsName(start), unit.isByte(start + 1, 0x3A) {
        label = unit.hash(start)
        start += 2
      }
      while start < end, unit.isToken(start, "ref") || unit.isToken(start, "out") || unit.isToken(start, "in") { start += 1 }
      result.append((start, end, label))
      i = end + 1
    }
    return result
  }

  /// A lambda's parameter count, or nil for anything else.
  func lambdaArity(_ unit: Unit, _ start: Int, _ end: Int) -> Int? {
    var k = start
    while k < end, unit.isToken(k, "async") || unit.isToken(k, "static") { k += 1 }
    if unit.isToken(k, "delegate") {
      guard unit.isByte(k + 1, 0x28) else { return -1 }
      return parameterCount(unit, k + 1)
    }
    if unit.csIsName(k), unit.isToken(k + 1, "=>") { return 1 }
    if unit.isByte(k, 0x28) {
      let close = unit.skipBalanced(k)
      if unit.isToken(close, "=>") { return parameterCount(unit, k) }
    }
    return nil
  }

  private func parameterCount(_ unit: Unit, _ open: Int) -> Int {
    let close = unit.skipBalanced(open) - 1
    var count = close > open + 1 ? 1 : 0
    var k = open + 1
    while k < close {
      if unit.isByte(k, 0x2C) { count += 1 }
      if unit.tokens[k].kind == .punctuation, unit.startsWith(k, 0x3C), let after = unit.csTypeArgumentsEnd(k, limit: close) {
        k = after
        continue
      }
      k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
    }
    return count
  }

  /// A method's parameter types, its declaring type's parameters put in.
  package func parameterTypes(_ ref: DeclRef, _ map: [Name: Ty]) -> [Ty] {
    let item = decl(ref)
    let holder = self.unit(ref)
    return (0..<Int(item.paramCount)).map { p in
      let param = holder.params[Int(item.paramStart) + p]
      return substitute(parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: item.nameToken), map)
    }
  }

  func isVariadic(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    guard item.paramCount > 0 else { return false }
    return self.unit(ref).params[Int(item.paramStart + item.paramCount - 1)].variadic
  }

  /// A delegate type's parameters and result, its arguments put in (`Expression<Func<…>>` is its delegate's).
  func delegateSignature(_ ty: Ty) -> (params: [Ty], result: Ty)? {
    guard case .nominal(let ref, let args) = memberBase(ty) else { return nil }
    if decl(ref).name == CSharpWord.expressionWord, args.count == 1, enclosingNamespace(ref) == "System.Linq.Expressions" { return delegateSignature(args[0]) }
    guard isDelegate(ref) else { return nil }
    let map = parameterMap(ref, args)
    return (parameterTypes(ref, map), substitute(valueType(of: ref), map))
  }

  /// Of a call's methods, those its arguments fit: by count (optional parameters, `params`), names, then the types
  /// that are known; the better when several fit. All of them that fit by count when none fits by type, none when none
  /// fits by count (the caller gives candidates). `receiverValue`: the methods are extension methods called on it.
  func chooseOverload(_ found: [DeclRef], unitIndex: Int32, open: Int, receiver: Ty, receiverValue: Ty?) -> [DeclRef] {
    var unique: [DeclRef] = []
    for ref in found where !unique.contains(ref) { unique.append(ref) }
    let unit = project.units[Int(unitIndex)]
    guard !unique.isEmpty, unit.isByte(open, 0x28) || unit.isByte(open, 0x5B) else { return unique }
    let args = arguments(unit, open: open)
    let n = args.count
    let skip = receiverValue == nil ? 0 : 1
    let byCount = unique.filter { ref in
      let item = decl(ref)
      let holder = self.unit(ref)
      let count = Int(item.paramCount) - (isExtensionMethod(ref) ? skip : 0)
      var required = 0
      for p in (Int(item.paramCount) - count)..<Int(item.paramCount) {
        let param = holder.params[Int(item.paramStart) + p]
        if !param.hasDefault, !param.variadic { required += 1 }
      }
      guard n >= required, n <= count || isVariadic(ref) else { return false }
      for arg in args where arg.label != 0 {
        var named = false
        for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].local == arg.label { named = true }
        if !named { return false }
      }
      return true
    }
    guard byCount.count > 1 || receiverValue != nil && byCount.count == 1 else { return byCount }
    var argTypes: [Ty?] = Array(repeating: nil, count: n)
    func argType(_ index: Int) -> Ty {
      if let known = argTypes[index] { return known }
      let range = args[index]
      var ty = lambdaArity(unit, range.start, range.end) == nil ? expressionType(unitIndex: unitIndex, start: Int32(range.start), end: Int32(range.end)) : .unknown
      // An integer literal converts to any integral type that holds it.
      if range.end == range.start + 1, unit.tokens[range.start].kind == .number { ty = .unknown }
      if range.end == range.start + 2, unit.isByte(range.start, 0x2D), unit.tokens[range.start + 1].kind == .number { ty = .unknown }
      // `out var x`, `null`, `default`: anything.
      if unit.isToken(range.start, "var") || unit.isToken(range.start, "null") || unit.isToken(range.start, "default") { ty = .unknown }
      argTypes[index] = ty
      return ty
    }
    for expanded in [false, true] {
      var fits: [DeclRef] = []
      // The ones every known argument (and the receiver) converts to without a user-defined conversion.
      var sure: [DeclRef] = []
      for ref in byCount {
        var isSure = true
        let item = decl(ref)
        let holder = self.unit(ref)
        let offset = isExtensionMethod(ref) ? skip : 0
        var map = receiverMap(receiver).merging(entryMap(ref, receiver)) { a, _ in a }
        if let receiverValue, offset == 1 {
          // The method's own parameters from the receiver: `this IEnumerable<T>` on a `List<int>`.
          var own: Set<Name> = []
          for g in 0..<Int(item.genericCount) { own.insert(holder.generics[Int(item.genericStart) + g].name) }
          let first = parameterTypes(ref, map).first ?? .unknown
          var bindings: [Name: Ty] = [:]
          unify(first, receiverValue, own, &bindings)
          map.merge(bindings) { a, _ in a }
          switch receiverFits(ref, receiverValue) {
          case false?: continue
          case nil: isSure = false
          default: break
          }
        }
        let params = Array(parameterTypes(ref, map).dropFirst(offset))
        let names = (offset..<Int(item.paramCount)).map { holder.params[Int(item.paramStart) + $0].local }
        let variadic = isVariadic(ref)
        if expanded, !variadic { continue }
        if !expanded, n > params.count { continue }
        var ok = true
        var position = 0
        for index in 0..<n {
          var p = position
          if args[index].label != 0, let named = names.firstIndex(of: args[index].label) { p = named } else { position += 1 }
          guard p < params.count || variadic && expanded else {
            ok = false
            break
          }
          var want = params[min(p, params.count - 1)]
          if expanded, variadic, p >= params.count - 1 {
            guard case .constructed(_, let element) = params[params.count - 1], let inner = element.first else { continue }
            want = inner
          }
          if let lambda = lambdaArity(unit, args[index].start, args[index].end) {
            if let signature = delegateSignature(want) {
              if lambda >= 0, signature.params.count != lambda { ok = false }
            } else if case .param = want {
            } else if case .nominal(let wanted, _) = memberBase(want), decl(wanted).name == CSharpWord.delegateWord || decl(wanted).name == CSharpWord.object {
            } else if want != .unknown {
              ok = false
            }
            if !ok { break }
            continue
          }
          let converts = assignable(argType(index), to: want)
          if converts == false || isNumberLiteral(unit, args[index]) && numberFits(want) == false {
            ok = false
            break
          }
          if converts == nil, argType(index) != .unknown { isSure = false }
        }
        if ok {
          fits.append(ref)
          if isSure { sure.append(ref) }
        }
      }
      if fits.count == 1 { return fits }
      if !sure.isEmpty, sure.count < fits.count { fits = sure }
      if fits.count == 1 { return fits }
      // The one whose parameters are the known arguments' own types (`Func<A, Task<B>>` over `Func<A, object>`).
      if fits.count > 1 {
        let map = receiverMap(receiver)
        let exact = fits.filter { ref in
          let params = Array(parameterTypes(ref, map).dropFirst(isExtensionMethod(ref) ? skip : 0))
          var differs = false
          for index in 0..<n where args[index].label == 0 && index < params.count {
            let have = argType(index)
            if have == .unknown { continue }
            if have != params[index] { differs = true }
          }
          return !differs
        }
        if exact.count == 1 { return exact }
      }
      if fits.count > 1 {
        let map = receiverMap(receiver)
        // An argument of unknown type where their parameters differ: any of them (`f(new { … })` with `f(object)` and
        // `f(IDictionary<…>)`).
        let unsure = (0..<n).contains { index in
          guard args[index].label == 0, argType(index) == .unknown, lambdaArity(unit, args[index].start, args[index].end) == nil else { return false }
          let range = args[index]
          if range.end == range.start + 1, unit.tokens[range.start].kind == .number || unit.isToken(range.start, "null") { return false }
          let kinds = Set(fits.map { ref -> String in
            let params = parameterTypes(ref, map).dropFirst(isExtensionMethod(ref) ? skip : 0)
            return index < params.count ? erasure(params[params.startIndex + index]) : "…"
          })
          return kinds.count > 1
        }
        if unsure { return fits }
        // The better: each of its parameters converts to the other's; a non-generic one over a generic one.
        let better = fits.filter { a in
          fits.allSatisfy { b in
            a == b || zip(parameterTypes(a, map).dropFirst(isExtensionMethod(a) ? skip : 0), parameterTypes(b, map).dropFirst(isExtensionMethod(b) ? skip : 0)).allSatisfy {
              assignable($0.0, to: $0.1) ?? false
            }
          }
        }
        if better.count == 1 { return better }
        let plain = fits.filter { decl($0).genericCount == 0 }
        if plain.count == 1, fits.count == 2 { return plain }
        return fits
      }
    }
    return byCount
  }

  /// `3`, `-1`, `2.5`: a literal whose type the parameter decides.
  func isNumberLiteral(_ unit: Unit, _ range: (start: Int, end: Int, label: Name)) -> Bool {
    if range.end == range.start + 1 { return unit.tokens[range.start].kind == .number }
    return range.end == range.start + 2 && unit.isByte(range.start, 0x2D) && unit.tokens[range.start + 1].kind == .number
  }

  /// Whether a number converts to a parameter's type: a numeric type, `object` or an interface; false for any other
  /// type that's known (`string`, a class).
  func numberFits(_ want: Ty) -> Bool? {
    var want = want
    if let inner = nullableValue(want) { want = inner }
    guard case .nominal(let ref, _) = memberBase(want) else { return nil }
    let item = decl(ref)
    if item.kind == .protocolType || item.kind == .enumeration { return nil }
    guard enclosingNamespace(ref) == CSharpWord.system else { return false }
    let text = self.unit(ref).string(Int(item.nameToken))
    return CSharpWord.numericWidening[text] != nil || text == "Object" || text == "ValueType" ? true : false
  }

  /// A receiver's arguments for its type's parameters.
  func receiverMap(_ receiver: Ty) -> [Name: Ty] {
    if case .nominal(let ref, let args) = memberBase(receiver) { return parameterMap(ref, args) }
    return [:]
  }

  /// How a method's declaring type's parameters read through the receiver: the member entry's substitution.
  func entryMap(_ ref: DeclRef, _ receiver: Ty) -> [Name: Ty] {
    let item = decl(ref)
    for (entry, _) in memberEntries(of: receiver, named: item.name) where entry.ref == ref { return entry.substitution }
    return [:]
  }

  /// The methods a call's `(` (or an attribute's, or `new T(`'s) belongs to: the type they're members of, and the value
  /// an extension method is called on.
  func callTarget(unitIndex: Int32, open: Int) -> (methods: [DeclRef], receiver: Ty, receiverValue: Ty?)? {
    let unit = project.units[Int(unitIndex)]
    var nameToken = open - 1
    var explicit = false
    if nameToken >= 0, unit.tokens[nameToken].kind == .punctuation, unit.punctuation(nameToken, madeOf: ">") {
      var k = nameToken
      while k > 0, !(unit.tokens[k].kind == .punctuation && unit.startsWith(k, 0x3C)) { k -= 1 }
      nameToken = k - 1
      explicit = true
    }
    guard nameToken >= 0 else { return nil }
    if unit.isToken(nameToken, "new") {
      // `new(…)`: the target's constructors.
      guard let target = targetType(unitIndex: unitIndex, start: nameToken), case .nominal(let ref, _) = target else { return nil }
      return (constructors(ref), target, nil)
    }
    if unit.isToken(nameToken, "base") || unit.isToken(nameToken, "this"), unit.isByte(nameToken - 1, 0x3A) {
      guard let own = enclosingTypes(unitIndex: unitIndex, token: Int32(nameToken)).first else { return nil }
      var type = ownType(own)
      if unit.isToken(nameToken, "base") {
        guard let parent = supertypes(of: own).first else { return nil }
        type = parent
      }
      guard case .nominal(let ref, _) = type else { return nil }
      return (constructors(ref), type, nil)
    }
    guard unit.csIsName(nameToken) else { return nil }
    let word = unit.hash(nameToken)
    if isCreationName(unit, nameToken) {
      let ty = expressionType(unitIndex: unitIndex, start: Int32(creationStart(unit, nameToken)), end: Int32(open))
      guard case .nominal(let ref, _) = ty else { return nil }
      return (constructors(ref), ty, nil)
    }
    if let attribute = attributeName(unit, nameToken) {
      guard case .decl(let ref)? = attributeSites(unitIndex: unitIndex, token: nameToken, qualified: attribute).first else { return nil }
      return (constructors(ref), .nominal(canonical(ref), []), nil)
    }
    _ = explicit
    if unit.csIsDot(nameToken - 1) {
      var receiver = operandType(unitIndex: unitIndex, dot: nameToken - 1)
      if unit.isToken(nameToken - 1, "?."), let inner = nullableValue(receiver) { receiver = inner }
      if case .meta(let inner) = receiver {
        let methods = memberSites(of: inner, named: word).filter { decl($0).kind == .function }
        return methods.isEmpty ? nil : (methods, inner, nil)
      }
      let methods = memberSites(of: receiver, named: word).filter { decl($0).kind == .function }
      if !methods.isEmpty, !chooseOverload(methods, unitIndex: unitIndex, open: open, receiver: receiver, receiverValue: nil).isEmpty { return (methods, receiver, nil) }
      let extensions = extensionMethods(word, unitIndex: unitIndex, token: Int32(nameToken), receiver: receiver)
      if !extensions.isEmpty { return (extensions, .unknown, receiver) }
      return methods.isEmpty ? nil : (methods, receiver, nil)
    }
    switch simpleMethods(word, unitIndex: unitIndex, token: Int32(nameToken)) {
    case .methods(let methods, let receiver): return methods.isEmpty ? nil : (methods, receiver, nil)
    case .value: return nil
    }
  }

  /// A type's constructors, every part's.
  func constructors(_ ref: DeclRef) -> [DeclRef] {
    var result: [DeclRef] = []
    for part in parts(canonical(ref)) {
      for child in self.unit(part).children(of: part.decl) where self.unit(part).decls[Int(child)].kind == .initializer && !self.unit(part).decls[Int(child)].isStatic {
        result.append(DeclRef(unit: part.unit, decl: child))
      }
    }
    return result
  }

  /// The `new` of a creation whose type's name is at `token`.
  func creationStart(_ unit: Unit, _ token: Int) -> Int {
    var k = token
    while k > 1, unit.isByte(k - 1, 0x2E), unit.csIsName(k - 2) { k -= 2 }
    if k > 1, unit.isToken(k - 1, "::") { k -= 2 }
    return k - 1
  }

  /// A generic method's own parameters as a call's arguments tell them (lambdas' results too, unless `skipping` is
  /// theirs); an extension method's first from the receiver.
  func inferBindings(_ ref: DeclRef, call: (methods: [DeclRef], receiver: Ty, receiverValue: Ty?), unitIndex: Int32, open: Int, skipping: Int, own given: Set<Name>? = nil) -> [Name: Ty] {
    let item = decl(ref)
    guard item.genericCount > 0 || given != nil else { return [:] }
    let holder = self.unit(ref)
    var own: Set<Name> = given ?? []
    for g in 0..<Int(item.genericCount) { own.insert(holder.generics[Int(item.genericStart) + g].name) }
    let unit = project.units[Int(unitIndex)]
    let args = arguments(unit, open: open)
    let map = receiverMap(call.receiver).merging(entryMap(ref, call.receiver)) { a, _ in a }
    var params = parameterTypes(ref, map)
    var bindings: [Name: Ty] = [:]
    var offset = 0
    if let value = call.receiverValue, isExtensionMethod(ref), let first = params.first {
      unify(first, value, own, &bindings)
      offset = 1
    }
    params = Array(params.dropFirst(offset))
    let names = (offset..<Int(item.paramCount)).map { holder.params[Int(item.paramStart) + $0].local }
    if isVariadic(ref), args.count >= params.count, case .constructed(_, let element)? = params.last, let inner = element.first, args.count > params.count || !isArrayArgument(unitIndex, args.last!) {
      params[params.count - 1] = inner
    }
    guard !params.isEmpty else { return bindings }
    // Plain arguments first, then lambdas, whose parameters may need what those bound.
    var position = 0
    var order: [(Int, Int)] = []
    for (index, range) in args.enumerated() {
      var p = position
      if range.label != 0, let named = names.firstIndex(of: range.label) { p = named } else { position += 1 }
      order.append((index, min(p, params.count - 1)))
    }
    for pass in 0..<2 {
      for (index, p) in order where index != skipping {
        let range = args[index]
        let isLambda = lambdaArity(unit, range.start, range.end) != nil
        if isLambda != (pass == 1) { continue }
        let param = params[p]
        if isLambda {
          guard let signature = delegateSignature(substitute(param, bindings)), let result = lambdaResultType(unitIndex: unitIndex, range: (range.start, range.end), target: substitute(param, bindings)) else { continue }
          unify(signature.result, result, own, &bindings)
          continue
        }
        let have = expressionType(unitIndex: unitIndex, start: Int32(range.start), end: Int32(range.end))
        unify(param, have, own, &bindings)
      }
    }
    return bindings
  }

  private func isArrayArgument(_ unitIndex: Int32, _ range: (start: Int, end: Int, label: Name)) -> Bool {
    if case .constructed(let kind, _) = expressionType(unitIndex: unitIndex, start: Int32(range.start), end: Int32(range.end)), kind == Ty.array { return true }
    return false
  }

  // MARK: Lambdas

  /// The type a lambda (or `new()`, or `default`) starting at `start` is given to: a parameter of the call it's an
  /// argument of, what it's assigned to or initializes, an event it's added to, what's returned, a cast's type.
  func targetType(unitIndex: Int32, start: Int) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    let before = start - 1
    guard before >= 0 else { return nil }
    // A named argument: `name: lambda`.
    var argumentStart = start
    if unit.isByte(before, 0x3A), unit.csIsName(before - 1), !unit.isToken(before, "::") { argumentStart = before - 1 }
    let previous = argumentStart - 1
    if previous >= 0, unit.isByte(previous, 0x28) || unit.isByte(previous, 0x2C) || unit.isToken(previous, "ref") || unit.isToken(previous, "out"),
      let open = unit.isByte(previous, 0x28) ? previous : unit.matchingOpenBefore(previous), unit.isByte(open, 0x28)
    {
      let args = arguments(unit, open: open)
      guard let position = args.firstIndex(where: { $0.start == start || $0.start == argumentStart + 2 && $0.label != 0 }) else { return nil }
      guard let call = callTarget(unitIndex: unitIndex, open: open) else { return nil }
      let chosen = chooseOverload(call.methods, unitIndex: unitIndex, open: open, receiver: call.receiver, receiverValue: call.receiverValue)
      var result: Ty?
      for ref in chosen {
        let item = decl(ref)
        let holder = self.unit(ref)
        let offset = call.receiverValue != nil && isExtensionMethod(ref) ? 1 : 0
        var params = parameterTypes(ref, receiverMap(call.receiver).merging(entryMap(ref, call.receiver)) { a, _ in a })
        let names = (0..<Int(item.paramCount)).map { holder.params[Int(item.paramStart) + $0].local }
        var p = offset
        var counted = 0
        for (index, arg) in args.enumerated() {
          let at: Int
          if arg.label != 0, let named = names.firstIndex(of: arg.label) {
            at = named
          } else {
            at = offset + counted
            counted += 1
          }
          if index == position { p = at }
        }
        if isVariadic(ref), p >= params.count - 1, case .constructed(_, let element)? = params.last, let inner = element.first {
          params.append(inner)
          p = min(p, params.count - 1)
          if p == params.count - 2, args.count > params.count - 1 - offset { p = params.count - 1 }
        }
        guard p < params.count else { continue }
        var param = params[p]
        let bindings = inferBindings(ref, call: call, unitIndex: unitIndex, open: open, skipping: position)
        param = substitute(param, bindings)
        if let current = result, erasure(current) != erasure(param) { return nil }
        result = param
      }
      return result
    }
    if unit.isToken(before, "=") || unit.isToken(before, "+=") || unit.isToken(before, "-=") || unit.isToken(before, "??=") {
      let nameToken = before - 1
      // `Type name = …` and `name = …`, a member in an initializer, `x.Name = …`.
      if let body = body(unitIndex: unitIndex, token: Int32(nameToken)), let index = body.byToken[Int32(nameToken)] {
        return localType(unitIndex: unitIndex, body: body, index: index)
      }
      if case .decl(let ref)? = unit.declaredSite(at: nameToken, unitIndex: unitIndex) { return valueType(of: ref) }
      let left = expressionStart(unit, before: before)
      let ty = expressionType(unitIndex: unitIndex, start: Int32(left), end: Int32(before))
      if ty != .unknown { return ty }
      let found = answer(unitIndex: unitIndex, token: nameToken)
      if found.state == .exact, let site = found.sites.first { return siteType(site, unitIndex: unitIndex) }
      return nil
    }
    if unit.isByte(before, 0x29), let open = unit.matchingOpen(before) {
      let ty = parseType(unitIndex: unitIndex, start: Int32(open + 1), end: Int32(before), scope: Int32(open))
      return ty == .unknown ? nil : ty
    }
    if unit.isToken(before, "return") || unit.isToken(before, "=>") {
      for index in unit.chain(at: Int32(start)).reversed() {
        let item = unit.decls[Int(index)]
        if item.kind == .function || item.kind == .variable || item.kind == .subscriptDecl {
          var ty = valueType(of: DeclRef(unit: unitIndex, decl: index))
          // `async Task<T>`: what's returned is a T.
          if hasModifier(DeclRef(unit: unitIndex, decl: index), "async"), let result = awaitedType(ty) { ty = result }
          return ty == .unknown ? nil : ty
        }
      }
    }
    return nil
  }

  /// A lambda parameter's type: its delegate's parameter.
  func lambdaParameterType(unitIndex: Int32, arrow: Int32, index: Int32) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var start = Int(arrow) - 1
    if unit.isByte(start, 0x29), let open = unit.matchingOpen(start) { start = open }
    while start > 0, unit.isToken(start - 1, "async") || unit.isToken(start - 1, "static") { start -= 1 }
    guard let target = targetType(unitIndex: unitIndex, start: start), let signature = delegateSignature(target) else { return .unknown }
    guard Int(index) < signature.params.count else { return .unknown }
    let ty = signature.params[Int(index)]
    if case .param(_, let owner) = ty, owner.map({ decl($0).kind == .function }) ?? true { return .unknown }
    return ty
  }

  /// What a lambda (its tokens) returns: its expression's type, or its block's first `return` with a value; an `async`
  /// lambda's wrapped in a `Task`.
  func lambdaResultType(unitIndex: Int32, range: (Int, Int), target: Ty) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    var arrow = range.0
    while arrow < range.1, !unit.isToken(arrow, "=>") { arrow = unit.tokens[arrow].kind == .open ? unit.skipBalanced(arrow) : arrow + 1 }
    guard arrow < range.1 else { return nil }
    let isAsync = unit.isToken(range.0, "async")
    var result: Ty?
    if unit.isByte(arrow + 1, 0x7B) {
      var k = arrow + 2
      let close = unit.skipBalanced(arrow + 1) - 1
      while k < close {
        if unit.isToken(k, "return"), !unit.isByte(k + 1, 0x3B) {
          let end = CSharpParser(unit: unit).expressionEnd(k + 1, limit: close)
          let ty = expressionType(unitIndex: unitIndex, start: Int32(k + 1), end: Int32(end))
          result = ty == .unknown ? nil : ty
          break
        }
        if unit.isToken(k, "=>"), unit.isByte(k + 1, 0x7B) {
          k = unit.skipBalanced(k + 1)
          continue
        }
        k += 1
      }
      if result == nil, !isAsync { return nil }
    } else {
      let ty = expressionType(unitIndex: unitIndex, start: Int32(arrow + 1), end: Int32(range.1))
      if ty == .unknown { return nil }
      if case .constructed(let kind, _) = ty, kind == CSharpWord.voidWord { return isAsync ? systemTask(nil) : nil }
      result = ty
    }
    if isAsync { return systemTask(result) }
    return result
  }

  /// `Task` or `Task<T>`.
  func systemTask(_ result: Ty?) -> Ty? {
    if let result {
      return namespaceTypes("System.Threading.Tasks", named: CSharpWord.taskWord, arity: 1, from: -1).first.map { .nominal($0, [result]) }
    }
    return namespaceTypes("System.Threading.Tasks", named: CSharpWord.taskWord, arity: 0, from: -1).first.map { .nominal($0, []) }
  }

  /// What `await` gives: `Task<T>`'s and `ValueTask<T>`'s T, `void` for the others; through `GetAwaiter().GetResult()`
  /// otherwise.
  func awaitedType(_ ty: Ty) -> Ty? {
    guard case .nominal(let ref, let args) = ty else { return nil }
    let text = self.unit(ref).string(Int(decl(ref).nameToken))
    if text == "Task" || text == "ValueTask", enclosingNamespace(ref) == "System.Threading.Tasks" {
      return args.first ?? .constructed(CSharpWord.voidWord, [])
    }
    if let awaiter = memberEntries(of: ty, named: name("GetAwaiter")).first(where: { decl($0.0.ref).kind == .function && decl($0.0.ref).paramCount == 0 }) {
      let awaiterType = memberValueType(awaiter.0)
      if let result = memberEntries(of: awaiterType, named: name("GetResult")).first(where: { decl($0.0.ref).kind == .function }) { return memberValueType(result.0) }
    }
    return nil
  }

  /// `f(out var x)`: the parameter's type at that position of the method the call chose.
  func outArgumentType(unitIndex: Int32, open: Int, position: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard let call = callTarget(unitIndex: unitIndex, open: open) else { return .unknown }
    let chosen = chooseOverload(call.methods, unitIndex: unitIndex, open: open, receiver: call.receiver, receiverValue: call.receiverValue)
    guard chosen.count == 1, let ref = chosen.first else { return .unknown }
    let args = arguments(unit, open: open)
    let offset = call.receiverValue != nil && isExtensionMethod(ref) ? 1 : 0
    var p = position + offset
    if position < args.count, args[position].label != 0 {
      let holder = self.unit(ref)
      let item = decl(ref)
      if let named = (0..<Int(item.paramCount)).first(where: { holder.params[Int(item.paramStart) + $0].local == args[position].label }) { p = named }
    }
    let params = parameterTypes(ref, receiverMap(call.receiver).merging(entryMap(ref, call.receiver)) { a, _ in a })
    guard p < params.count else { return .unknown }
    let bindings = inferBindings(ref, call: call, unitIndex: unitIndex, open: open, skipping: position)
    let ty = substitute(params[p], bindings)
    if case .param(_, let owner) = ty, owner == ref { return .unknown }
    return ty
  }
}
