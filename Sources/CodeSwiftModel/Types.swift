import CodeScan
import Foundation

/// Types are read from their tokens when someone asks, then kept. `unknown` absorbs: nothing on it is answered or reported.
indirect enum Ty: Hashable {
  case unknown
  case module(Name)
  case nominal(DeclRef, [Ty])
  case meta(Ty)
  case tuple([Ty], [Name])
  case function([Ty], Ty)
  case optional(Ty)
  case param(Name, DeclRef?)
  case selfType
  case existential([Ty])
  /// `S.Element`, of a parameter that isn't known yet: not the receiver's `Element`.
  case dependent(Ty, Name)
}

extension Model {
  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }

  // MARK: Written types

  /// The declaration around a token, outermost first, descending into local types once the scan found them.
  func chain(at token: Int32, unitIndex: Int32) -> [Int32] {
    let unit = project.units[Int(unitIndex)]
    var result: [Int32] = []
    var parent: Int32 = -1
    while true {
      var found: Int32?
      for child in unit.children(of: parent) {
        let decl = unit.decls[Int(child)]
        if decl.first <= token, token < decl.end {
          if decl.isLocal, !decl.kind.isNominal, decl.kind != .function { continue }
          found = child
          break
        }
      }
      guard let found else { return result }
      result.append(found)
      parent = found
    }
  }

  func parseType(unitIndex: Int32, start: Int32, end: Int32, scope: [Int32]) -> Ty {
    guard start >= 0, start < end else { return .unknown }
    var i = Int(start)
    return parseTypeBody(unitIndex, &i, Int(end), scope)
  }

  private func parseTypeBody(_ unitIndex: Int32, _ i: inout Int, _ end: Int, _ scope: [Int32]) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var first = parsePrimaryType(unitIndex, &i, end, scope)
    var parts: [Ty] = []
    while i < end, unit.isByte(i, 0x26) {
      i += 1
      if parts.isEmpty { parts.append(first) }
      parts.append(parsePrimaryType(unitIndex, &i, end, scope))
    }
    if !parts.isEmpty { first = .existential(parts) }
    while i < end, unit.isToken(i, "async") || unit.isToken(i, "throws") || unit.isToken(i, "rethrows") {
      i += 1
      if unit.isByte(i, 0x28) { i = unit.skipBalanced(i) }
    }
    if i < end, unit.isToken(i, "->") {
      i += 1
      let result = parseTypeBody(unitIndex, &i, end, scope)
      if case .tuple(let items, _) = first { return .function(items, result) }
      return .function([first], result)
    }
    return first
  }

  private func parsePrimaryType(_ unitIndex: Int32, _ i: inout Int, _ end: Int, _ scope: [Int32]) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var wrapExistential = false
    while i < end {
      if unit.tokens[i].kind == .attribute {
        i = unit.skipAttribute(i)
        continue
      }
      if unit.isByte(i, 0x7E) {
        i += 1
        continue
      }
      if unit.isToken(i, "some") || unit.isToken(i, "any") {
        wrapExistential = true
        i += 1
        continue
      }
      if unit.isToken(i, "inout") || unit.isToken(i, "borrowing") || unit.isToken(i, "consuming") || unit.isToken(i, "__owned") || unit.isToken(i, "__shared")
        || unit.isToken(i, "sending") || unit.isToken(i, "isolated") || unit.isToken(i, "repeat") || unit.isToken(i, "each")
      {
        i += 1
        continue
      }
      break
    }
    guard i < end else { return .unknown }
    var result: Ty
    if unit.isByte(i, 0x5B) {
      let close = unit.skipBalanced(i) - 1
      var j = i + 1
      let key = parseTypeBody(unitIndex, &j, close, scope)
      if unit.isByte(j, 0x3A) {
        j += 1
        let value = parseTypeBody(unitIndex, &j, close, scope)
        result = standard(Word.dictionary, [key, value])
      } else {
        result = standard(Word.array, [key])
      }
      i = close + 1
    } else if unit.isByte(i, 0x28) {
      let close = unit.skipBalanced(i) - 1
      var j = i + 1
      var items: [Ty] = []
      var labels: [Name] = []
      while j < close {
        var label: Name = 0
        // `name: T` or `_ name: T`.
        if unit.tokens[j].kind == .identifier || unit.tokens[j].kind == .keyword {
          if unit.isByte(j + 1, 0x3A) {
            label = unit.hash(j)
            j += 2
          } else if unit.isByte(j + 2, 0x3A), unit.tokens[j + 1].kind == .identifier {
            label = unit.hash(j + 1)
            j += 3
          }
        }
        let before = j
        items.append(parseTypeBody(unitIndex, &j, close, scope))
        labels.append(label)
        if unit.isToken(j, "...") { j += 1 }
        if unit.isByte(j, 0x2C) { j += 1 }
        if j == before { j += 1 }
      }
      i = close + 1
      if items.count == 1, labels[0] == 0, !unit.isToken(i, "->"), !unit.isToken(i, "async"), !unit.isToken(i, "throws") {
        result = items[0]
      } else {
        result = .tuple(items, labels)
      }
    } else if unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword || unit.isByte(i, 0x60) {
      result = parseNamedType(unitIndex, &i, end, scope)
    } else {
      i += 1
      return .unknown
    }
    while i < end, unit.tokens[i].kind == .punctuation {
      let token = unit.tokens[i]
      var isSugar = true
      for k in 0..<token.length where unit.source.text[token.start + k] != 0x3F && unit.source.text[token.start + k] != 0x21 { isSugar = false }
      guard isSugar else { break }
      for _ in 0..<token.length { result = .optional(result) }
      i += 1
    }
    return wrapExistential ? .existential([result]) : result
  }

  private func parseNamedType(_ unitIndex: Int32, _ i: inout Int, _ end: Int, _ scope: [Int32]) -> Ty {
    let unit = project.units[Int(unitIndex)]
    func take() -> Int {
      if unit.isByte(i, 0x60) {
        i += 3
        return i - 2
      }
      i += 1
      return i - 1
    }
    let head = take()
    let headName = unit.hash(head)
    var args: [Ty] = []
    if unit.isToken(i, "<") { args = angleArguments(unitIndex, &i, end, scope) }
    var result: Ty
    if headName == Word.selfType {
      result = .selfType
    } else {
      result = lookupType(headName, unitIndex: unitIndex, token: Int32(head), scope: scope, args: args)
    }
    while i < end {
      // After `<...>` the dot may have come glued to the closer: `>.`.
      let glued = unit.isGluedDot(i - 1) && !unit.isToken(i, "::")
      guard glued || unit.isByte(i, 0x2E) || unit.isToken(i, "::"), glued || i + 1 < end else { break }
      if !glued { i += 1 }
      if unit.isToken(i, "Type") || unit.isToken(i, "Protocol") {
        i += 1
        result = .meta(result)
        continue
      }
      var member = take()
      // `Swift::String.Swift::Index`: the module in the middle says nothing the first one didn't.
      if unit.isToken(i, "::"), i + 1 < end {
        i += 1
        member = take()
      }
      var inner: [Ty] = []
      if unit.isToken(i, "<") { inner = angleArguments(unitIndex, &i, end, scope) }
      result = memberType(of: result, name: unit.hash(member), args: inner, from: unitIndex)
    }
    return result
  }

  /// `<A, B<C>>`: arguments and past its closer, where `>>` may be a single token, tracked in `pendingCloses`.
  private func angleArguments(_ unitIndex: Int32, _ i: inout Int, _ end: Int, _ scope: [Int32]) -> [Ty] {
    let unit = project.units[Int(unitIndex)]
    var depth = 0
    var j = i
    var close = i
    while j < end {
      let token = unit.tokens[j]
      if token.kind == .open {
        j = unit.skipBalanced(j)
        continue
      }
      if token.kind == .close { break }
      if token.kind == .punctuation {
        if unit.isToken(j, "<") {
          depth += 1
        } else if !unit.isToken(j, "->") {
          for k in 0..<token.length where unit.source.text[token.start + k] == 0x3E { depth -= 1 }
          if depth <= 0 {
            close = j
            break
          }
        }
      }
      j += 1
    }
    guard close > i else { return [] }
    var result: [Ty] = []
    var k = i + 1
    while k < close {
      let before = k
      result.append(parseTypeBody(unitIndex, &k, close, scope))
      if unit.isByte(k, 0x2C) { k += 1 }
      if k == before { break }
    }
    i = close + 1
    return result
  }

  func standard(_ typeName: Name, _ args: [Ty]) -> Ty {
    guard let module = project.ensureModule(Word.swift, display: "Swift"), let ref = module.top[typeName]?.first else { return .unknown }
    return .nominal(ref, args)
  }

  /// A nominal's own generic parameters, as parameters: how it looks from inside.
  func selfNominal(_ ref: DeclRef) -> Ty {
    let owner = decl(ref)
    let unit = unit(ref)
    var args: [Ty] = []
    for g in 0..<Int(owner.genericCount) { args.append(.param(unit.generics[Int(owner.genericStart) + g].name, ref)) }
    return .nominal(ref, args)
  }

  func typeOfTypeDecl(_ ref: DeclRef, args: [Ty]) -> Ty {
    let item = decl(ref)
    switch item.kind {
    case .typeAlias:
      let raw = aliasType(ref)
      guard item.genericCount > 0, !args.isEmpty else { return raw }
      var map: [Name: Ty] = [:]
      for (g, arg) in zip(0..<Int(item.genericCount), args) { map[unit(ref).generics[Int(item.genericStart) + g].name] = arg }
      return substitute(raw, map: map, receiver: nil)
    case .associatedType:
      return .param(item.name, ref)
    case .extensionDecl:
      return .nominal(phantom(for: item.name) ?? ref, args)
    default:
      if args.isEmpty { return selfNominal(ref) }
      return .nominal(ref, args)
    }
  }

  private func aliasType(_ ref: DeclRef) -> Ty {
    if let known = typeMemo[ref] { return known }
    guard resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    let item = decl(ref)
    var scope = parents(of: ref)
    scope.append(ref.decl)
    let raw = parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: scope)
    typeMemo[ref] = raw
    return raw
  }

  func parents(of ref: DeclRef) -> [Int32] {
    var chain: [Int32] = []
    let unit = unit(ref)
    var parent = unit.decls[Int(ref.decl)].parent
    while parent >= 0 {
      chain.append(parent)
      parent = unit.decls[Int(parent)].parent
    }
    return chain.reversed()
  }

  /// A type's name from a scope: generics and nested types outward, then modules, then an SDK class known only by its extensions.
  func lookupType(_ typeName: Name, unitIndex: Int32, token: Int32, scope: [Int32], args: [Ty]) -> Ty {
    let unit = project.units[Int(unitIndex)]
    for index in scope.reversed() {
      let owner = unit.decls[Int(index)]
      let ref = DeclRef(unit: unitIndex, decl: index)
      for g in 0..<Int(owner.genericCount) where unit.generics[Int(owner.genericStart) + g].name == typeName {
        return .param(typeName, ref)
      }
      if let scan = unit.scans[index], let found = scan.local(named: typeName, at: token), case .declaration(let local) = scan.locals[Int(found)].kind,
        unit.decls[Int(local)].kind.isType
      {
        return typeOfTypeDecl(DeclRef(unit: unitIndex, decl: local), args: args)
      }
      if owner.kind.hasMembers {
        if let found = ownGeneric(of: ref, named: typeName) { return found }
        if let target = nominal(forMembersOf: ref),
          let member = memberTable(of: target)[typeName]?.first(where: { decl($0).kind.isType && accessible($0, from: unitIndex) })
        {
          return typeOfTypeDecl(member, args: args)
        }
      }
    }
    let visible = project.visibleModules(of: unitIndex)
    for moduleName in visible {
      guard let list = project.modules[moduleName]?.top[typeName] else { continue }
      if let found = list.first(where: { decl($0).kind.isType && accessible($0, from: unitIndex) }) {
        return typeOfTypeDecl(found, args: args)
      }
    }
    if project.modules[typeName] != nil { return .module(typeName) }
    if let found = project.implicitlyExported(typeName).first(where: { decl($0).kind.isType && accessible($0, from: unitIndex) }) {
      return typeOfTypeDecl(found, args: args)
    }
    // A class known only by extensions has its real declaration in a header, if it has one at all.
    noteMiss(unitIndex)
    if let ghost = phantom(for: typeName) { return .nominal(ghost, args) }
    return .unknown
  }

  /// An extension sees the extended type's generic parameters.
  private func ownGeneric(of ref: DeclRef, named typeName: Name) -> Ty? {
    guard decl(ref).kind == .extensionDecl, let target = nominal(forMembersOf: ref) else { return nil }
    let item = decl(target)
    let owner = unit(target)
    for g in 0..<Int(item.genericCount) where owner.generics[Int(item.genericStart) + g].name == typeName {
      return .param(typeName, target)
    }
    return nil
  }

  func phantom(for typeName: Name) -> DeclRef? {
    if let known = phantoms[typeName] { return known }
    guard let first = project.extensions[typeName]?.first else { return nil }
    phantoms[typeName] = first
    return first
  }

  func memberType(of base: Ty, name member: Name, args: [Ty], from unitIndex: Int32) -> Ty {
    switch base {
    case .module(let moduleName):
      guard let module = project.modules[moduleName] else { return .unknown }
      if let found = module.top[member]?.first(where: { decl($0).kind.isType }) { return typeOfTypeDecl(found, args: args) }
      noteMiss(unitIndex)
      if let ghost = phantom(for: member) { return .nominal(ghost, args) }
      return .unknown
    case .nominal(let ref, _):
      guard let found = memberTable(of: ref)[member]?.first(where: { decl($0).kind.isType }) else {
        for g in genericNames(of: ref) where g == member { return .param(member, ref) }
        if unit(ref).isInterface { noteMiss(unitIndex) }
        return .unknown
      }
      return substitute(typeOfTypeDecl(found, args: args), receiver: base)
    case .selfType:
      return .param(member, nil)
    case .param:
      return .dependent(base, member)
    case .dependent:
      return .dependent(base, member)
    default:
      return .unknown
    }
  }

  func genericNames(of ref: DeclRef) -> [Name] {
    let item = decl(ref)
    let owner = unit(ref)
    return (0..<Int(item.genericCount)).map { owner.generics[Int(item.genericStart) + $0].name }
  }

  // MARK: Substitution

  func substitute(_ ty: Ty, receiver: Ty?) -> Ty {
    guard let receiver else { return ty }
    return substitute(ty, map: [:], receiver: receiver)
  }

  func substitute(_ ty: Ty, map: [Name: Ty], receiver: Ty?, depth: Int = 0) -> Ty {
    guard depth < 16 else { return .unknown }
    func go(_ inner: Ty) -> Ty { substitute(inner, map: map, receiver: receiver, depth: depth + 1) }
    switch ty {
    case .selfType:
      return receiver ?? ty
    case .param(let paramName, _):
      if let bound = map[paramName] { return bound }
      guard let receiver else { return ty }
      return project(paramName, of: receiver, depth: depth) ?? ty
    case .nominal(let ref, let args):
      return .nominal(ref, args.map(go))
    case .meta(let inner):
      return .meta(go(inner))
    case .optional(let inner):
      return .optional(go(inner))
    case .tuple(let items, let labels):
      return .tuple(items.map(go), labels)
    case .function(let params, let result):
      return .function(params.map(go), go(result))
    case .existential(let items):
      return .existential(items.map(go))
    case .dependent(let base, let member):
      let known = go(base)
      switch known {
      case .param, .dependent: return .dependent(known, member)
      case .unknown: return .unknown
      default: return project(member, of: known, depth: depth) ?? .unknown
      }
    default:
      return ty
    }
  }

  /// What a parameter or associated type's name means on a concrete receiver.
  private func project(_ paramName: Name, of receiver: Ty, depth: Int) -> Ty? {
    switch receiver {
    case .optional(let wrapped):
      if let ref = standardRef(Word.optional) { return project(paramName, of: .nominal(ref, [wrapped]), depth: depth) }
      return nil
    case .nominal(let ref, let args):
      for (g, arg) in zip(genericNames(of: ref), args) where g == paramName {
        if case .param(let same, _) = arg, same == paramName { return nil }
        return arg
      }
      guard let member = memberTable(of: ref)[paramName]?.first(where: { decl($0).kind == .typeAlias }) else { return nil }
      return substitute(typeOfTypeDecl(member, args: []), map: [:], receiver: receiver, depth: depth + 1)
    default:
      return nil
    }
  }

  func standardRef(_ typeName: Name) -> DeclRef? {
    project.ensureModule(Word.swift, display: "Swift")?.top[typeName]?.first
  }

  // MARK: Members

  /// The nominal an extension's members belong to, or the nominal itself.
  func nominal(forMembersOf ref: DeclRef) -> DeclRef? {
    let item = decl(ref)
    if item.kind != .extensionDecl { return item.kind.isNominal ? ref : nil }
    if let known = extensionTargets[ref] { return known }
    let target: DeclRef
    let parsed = parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: [])
    switch parsed {
    case .nominal(let found, _): target = found
    case .optional:
      target = standardRef(Word.optional) ?? phantom(for: item.name) ?? ref
    default: target = phantom(for: item.name) ?? ref
    }
    extensionTargets[ref] = target
    return target
  }

  func accessible(_ ref: DeclRef, from unitIndex: Int32) -> Bool {
    let item = decl(ref)
    if item.access == .isPublic { return true }
    if ref.unit == unitIndex { return true }
    if item.access == .isPrivate || item.access == .filePrivate { return false }
    let owner = unit(ref)
    let viewer = project.units[Int(unitIndex)]
    if owner.moduleName == viewer.moduleName { return true }
    if owner.isInterface { return false }
    if item.access == .package { return true }
    return project.isTestable(owner.moduleName, from: viewer)
  }

  private func labelKey(_ ref: DeclRef) -> UInt64 {
    let item = decl(ref)
    let owner = unit(ref)
    var key = UInt64(item.paramCount) &* 31
    if item.kind == .function || item.kind == .initializer || item.kind == .subscriptDecl { key &+= 1 }
    for p in 0..<Int(item.paramCount) {
      key = (key &* 1_099_511_628_211) ^ owner.params[Int(item.paramStart) + p].label
    }
    return key
  }

  /// What an inherited member must differ by to stay. Initializers overload by type: `Int(_: Int8)` doesn't hide
  /// `init?(_: String)` of `FixedWidthInteger`, while a witness of a requirement does hide it.
  private func inheritKey(_ ref: DeclRef) -> UInt64 {
    var key = labelKey(ref)
    let item = decl(ref)
    guard item.kind == .initializer else { return key }
    let owner = unit(ref)
    for p in 0..<Int(item.paramCount) {
      let param = owner.params[Int(item.paramStart) + p]
      guard param.typeStart >= 0 else { continue }
      for t in Int(param.typeStart)..<Int(param.typeEnd) where !owner.isToken(t, "::") && !owner.isToken(t + 1, "::") {
        key = (key &* 1_099_511_628_211) ^ owner.hash(t)
      }
    }
    return key
  }

  /// Every member by name, built once per nominal: its own, its extensions', then inherited unless it restates them.
  func memberTable(of ref: DeclRef) -> [Name: [DeclRef]] {
    if let known = tables[ref] { return known }
    guard building.insert(ref).inserted else { return [:] }
    defer { building.remove(ref) }
    var table: [Name: [DeclRef]] = [:]
    var bases: [(ty: Ty, via: DeclRef?)] = []
    let item = decl(ref)
    func take(_ owner: DeclRef) {
      let unit = unit(owner)
      for child in unit.children(of: owner.decl) where !unit.decls[Int(child)].isLocal {
        let entry = unit.decls[Int(child)]
        table[entry.name, default: []].append(DeclRef(unit: owner.unit, decl: child))
      }
      let holder = unit.decls[Int(owner.decl)]
      var scope = parents(of: owner)
      scope.append(owner.decl)
      // `extension Array: Hashable where Element: Hashable`: what Hashable brings holds only when that does.
      let via = holder.kind == .extensionDecl && holder.whereStart >= 0 ? owner : nil
      for r in 0..<Int(holder.inheritCount) {
        let range = unit.ranges[Int(holder.inheritStart) + r]
        bases.append((parseType(unitIndex: owner.unit, start: range.start, end: range.end, scope: scope), via))
      }
    }
    if item.kind != .extensionDecl { take(ref) }
    for candidate in project.extensions[item.name] ?? [] where nominal(forMembersOf: candidate) == ref { take(candidate) }
    tables[ref] = table
    var seen: Set<DeclRef> = []
    var conditional: [DeclRef: [DeclRef]] = [:]
    var unconditional: Set<DeclRef> = []
    func inherit(_ base: Ty, via: DeclRef?) {
      switch base {
      case .nominal(let parent, _):
        guard parent != ref, seen.insert(parent).inserted else { return }
        // `enum A: String` has a raw value, not String's members.
        if decl(parent).kind == .structure || decl(parent).kind == .enumeration { return }
        for (member, list) in memberTable(of: parent) {
          let present = Set(table[member] ?? [])
          // What's deprecated or disfavored doesn't hide the rest: Collection's old `flatMap` isn't Sequence's. Nor does
          // what holds only under a `where`: `removeLast` of `Self == SubSequence` isn't RangeReplaceableCollection's.
          // Collection's `split` where `Element: Equatable` does hide Sequence's under the same requirement.
          var own: [UInt64: Set<UInt64>] = [:]
          for entry in table[member] ?? [] where !isDeprecated(entry) && !isDisfavored(entry) {
            // What came through `Array: DataProtocol where Element == UInt8` hides nothing: it may not be there.
            if conditional[entry] != nil { continue }
            own[inheritKey(entry), default: []].insert(conditionKey(entry))
          }
          let added = list.filter { inherited in
            guard !present.contains(inherited) else { return false }
            guard let hiding = own[inheritKey(inherited)] else { return true }
            return !hiding.contains(0) && !hiding.contains(conditionKey(inherited))
          }
          if !added.isEmpty { table[member, default: []].append(contentsOf: added) }
          // Equatable's `!=` reached through Hashable's condition and again through Equatable's: either will do.
          for inherited in list where present.contains(inherited) || added.contains(inherited) {
            if let via, !unconditional.contains(inherited), added.contains(inherited) || conditional[inherited] != nil {
              conditional[inherited, default: []].append(via)
            } else {
              unconditional.insert(inherited)
              conditional[inherited] = nil
            }
          }
        }
      case .existential(let items):
        for part in items { inherit(part, via: via) }
      default:
        break
      }
    }
    // What's always there first: what a conditional conformance brings hides nothing, whatever order it's written in.
    for base in bases where base.via == nil { inherit(base.ty, via: nil) }
    for base in bases where base.via != nil { inherit(base.ty, via: base.via) }
    inheritedTypes[ref] = bases.map(\.ty)
    if !conditional.isEmpty { conditions[ref] = conditional }
    tables[ref] = table
    return table
  }

  // MARK: Dynamic members

  /// `subscript(dynamicMember keyPath: KeyPath<Value, T>) -> Binding<T>` of a `@dynamicMemberLookup` type: the root its
  /// key paths start from, and what a member of that root comes back as.
  struct DynamicLookup {
    var root: Ty
    var subject: Name?
    var result: Ty
    var subscriptRef: DeclRef
  }

  func dynamicLookups(of ty: Ty) -> [DynamicLookup] {
    guard case .nominal(let ref, _) = ty, hasDynamicMemberLookup(ref, depth: 0) else { return [] }
    var found: [DynamicLookup] = []
    for member in memberTable(of: ref)[Word.subscriptName] ?? [] {
      let item = decl(member)
      guard item.kind == .subscriptDecl, !item.isStatic, item.paramCount == 1 else { continue }
      let owner = unit(member)
      let param = owner.params[Int(item.paramStart)]
      guard param.label == Word.dynamicMember || param.local == Word.dynamicMember, param.typeStart >= 0 else { continue }
      var scope = parents(of: member)
      scope.append(member.decl)
      // A key path, by its last name: `Swift::WritableKeyPath<Value, Subject>`.
      // Its two arguments are read here, so a project without the SDK reads them too.
      var last = Int(param.typeStart)
      var open = -1
      for t in Int(param.typeStart)..<Int(param.typeEnd) {
        if owner.isToken(t, "<") { open = t; break }
        if owner.tokens[t].kind == .identifier { last = t }
      }
      guard open > 0, Word.keyPaths.contains(owner.hash(last)) else { continue }
      let parser = DeclParser(unit: owner)
      let comma = parser.skipType(open + 1)
      guard owner.isByte(comma, 0x2C) else { continue }
      let close = parser.skipType(comma + 1)
      let args = [
        parseType(unitIndex: member.unit, start: Int32(open + 1), end: Int32(comma), scope: scope),
        parseType(unitIndex: member.unit, start: Int32(comma + 1), end: Int32(close), scope: scope),
      ]
      let root = substitute(args[0], receiver: ty)
      guard root != ty, root != .unknown else { continue }
      var subject: Name?
      if case .param(let paramName, _) = args[1] { subject = paramName }
      let result = substitute(parseType(unitIndex: member.unit, start: item.typeStart, end: item.typeEnd, scope: scope), receiver: ty)
      found.append(DynamicLookup(root: root, subject: subject, result: result, subscriptRef: member))
    }
    return found
  }

  /// What a member of the root comes back as through the subscript: `Binding<Int>` for `count`.
  func dynamicResult(_ lookup: DynamicLookup, memberType: Ty) -> Ty {
    guard let subject = lookup.subject else { return lookup.result }
    var value = memberType
    if case .function(let params, let result) = value, params.isEmpty { value = result }
    return substitute(lookup.result, map: [subject: value], receiver: nil)
  }

  /// The attribute is written on the type, or on a class or protocol it inherits from.
  private func hasDynamicMemberLookup(_ ref: DeclRef, depth: Int) -> Bool {
    guard depth < 6 else { return false }
    let item = decl(ref)
    let owner = unit(ref)
    for t in Int(item.first)..<Int(item.nameToken) where owner.tokens[t].kind == .attribute && owner.isToken(t, "@dynamicMemberLookup") { return true }
    _ = memberTable(of: ref)
    for base in inheritedTypes[ref] ?? [] {
      if case .nominal(let parent, _) = base, decl(parent).kind == .classType || decl(parent).kind == .protocolType, hasDynamicMemberLookup(parent, depth: depth + 1) { return true }
    }
    return false
  }

  // MARK: Requirements

  /// The text of a member's extension's `where`, 0 without one. Its own `where` mostly constrains its own generics:
  /// `map`'s `where E: Error` holds for every receiver.
  func conditionKey(_ ref: DeclRef) -> UInt64 {
    let item = decl(ref)
    guard item.parent >= 0 else { return 0 }
    let owner = unit(ref)
    let holder = owner.decls[Int(item.parent)]
    guard holder.whereStart >= 0 else { return 0 }
    var key: UInt64 = 14_695_981_039_346_656_037
    for t in Int(holder.whereStart)..<Int(holder.whereEnd) { key = (key ^ owner.hash(t)) &* 1_099_511_628_211 }
    return key | 1
  }

  /// Whether a member can be there on this receiver, by its `where`, its extension's and that of a conditional
  /// conformance it came through. Only a requirement known to fail says no: what can't be told holds.
  func requirementsHold(_ member: DeclRef, holder: DeclRef, receiver: Ty) -> Bool {
    // A protocol's own `Self` is open: `ShapeStyle where Self == Color` is for whoever is Color.
    if decl(holder).kind == .protocolType { return true }
    if clauseFails(member, receiver: receiver) { return false }
    let parent = decl(member).parent
    if parent >= 0, clauseFails(DeclRef(unit: member.unit, decl: parent), receiver: receiver) { return false }
    _ = memberTable(of: holder)
    if let via = conditions[holder]?[member], via.allSatisfy({ clauseFails($0, receiver: receiver) }) { return false }
    return true
  }

  private func clauseFails(_ ref: DeclRef, receiver: Ty) -> Bool {
    let item = decl(ref)
    guard item.whereStart >= 0 else { return false }
    let key = ClauseKey(clause: ref, receiver: receiver)
    if let known = clauseMemo[key] { return known }
    let owner = unit(ref)
    var scope = parents(of: ref)
    scope.append(ref.decl)
    let parser = DeclParser(unit: owner)
    var fails = false
    var i = Int(item.whereStart)
    let end = Int(item.whereEnd)
    while i < end, !fails {
      let lhsEnd = parser.skipType(i)
      guard lhsEnd > i, lhsEnd < end else { break }
      let isSame = owner.isToken(lhsEnd, "==")
      guard isSame || owner.isByte(lhsEnd, 0x3A) else { break }
      let rhsStart = lhsEnd + 1
      let rhsEnd = min(parser.skipType(rhsStart), end)
      guard rhsEnd > rhsStart else { break }
      // `~Copyable` takes a conformance away; `AnyObject` and layouts aren't types to look up.
      if !owner.isByte(rhsStart, 0x7E) {
        let lhs = substitute(parseType(unitIndex: ref.unit, start: Int32(i), end: Int32(lhsEnd), scope: scope), receiver: receiver)
        if isSame {
          let rhs = substitute(parseType(unitIndex: ref.unit, start: Int32(rhsStart), end: Int32(rhsEnd), scope: scope), receiver: receiver)
          fails = differs(lhs, rhs)
        } else if rhsEnd == rhsStart + 1, owner.isToken(rhsStart, "AnyObject") {
          fails = isValueType(lhs)
        } else {
          let rhs = parseType(unitIndex: ref.unit, start: Int32(rhsStart), end: Int32(rhsEnd), scope: scope)
          fails = cannotConform(lhs, to: rhs)
            }
      }
      guard rhsEnd < end, owner.isByte(rhsEnd, 0x2C) else { break }
      i = rhsEnd + 1
    }
    clauseMemo[key] = fails
    return fails
  }

  private func concrete(_ ty: Ty) -> Ty {
    if case .optional(let wrapped) = ty, let ref = standardRef(Word.optional) { return .nominal(ref, [wrapped]) }
    return ty
  }

  private func isConcreteKind(_ ref: DeclRef) -> Bool {
    switch decl(ref).kind {
    case .structure, .classType, .enumeration, .actor: return true
    default: return false
    }
  }

  /// Two types known well enough to be told apart.
  private func differs(_ a: Ty, _ b: Ty, depth: Int = 0) -> Bool {
    guard depth < 8 else { return false }
    switch (concrete(a), concrete(b)) {
    case (.nominal(let x, let xArgs), .nominal(let y, let yArgs)):
      guard isConcreteKind(x), isConcreteKind(y) else { return false }
      if x != y { return true }
      return zip(xArgs, yArgs).contains { differs($0, $1, depth: depth + 1) }
    case (.tuple(let x, _), .tuple(let y, _)):
      if x.count != y.count { return true }
      return zip(x, y).contains { differs($0, $1, depth: depth + 1) }
    case (.tuple, .nominal(let y, _)), (.function, .nominal(let y, _)): return isConcreteKind(y)
    case (.nominal(let x, _), .tuple), (.nominal(let x, _), .function): return isConcreteKind(x)
    default: return false
    }
  }

  private func isValueType(_ ty: Ty) -> Bool {
    switch concrete(ty) {
    case .tuple, .function: return true
    case .nominal(let ref, _): return decl(ref).kind == .structure || decl(ref).kind == .enumeration
    default: return false
    }
  }

  /// What every type has, or gets without writing it, so it can't be told missing.
  private static let implicitConformances: Set<String> = ["Copyable", "Escapable", "Sendable", "BitwiseCopyable", "SendableMetatype"]
  /// What an enum gets on its own: without payloads it's Equatable and Hashable, with a raw type RawRepresentable.
  private static let enumConformances: Set<String> = ["Equatable", "Hashable", "RawRepresentable"]

  private func cannotConform(_ value: Ty, to wanted: Ty, depth: Int = 0) -> Bool {
    switch wanted {
    case .existential(let parts): return parts.contains { cannotConform(value, to: $0, depth: depth) }
    case .nominal(let target, _):
      let targetKind = decl(target).kind
      guard targetKind == .protocolType || targetKind == .classType else { return false }
      let targetName = unit(target).string(Int(decl(target).nameToken))
      if Model.implicitConformances.contains(targetName) || targetName.hasPrefix("_") { return false }
      switch concrete(value) {
      case .tuple, .function:
        return true
      case .nominal(let ref, _):
        let kind = decl(ref).kind
        guard isConcreteKind(ref) else { return false }
        if kind == .enumeration, Model.enumConformances.contains(targetName) { return false }
        // An SDK class gets conformances from overlays and headers that may not be read yet.
        if kind == .classType || kind == .actor, unit(ref).isInterface { return false }
        return isCompatible(concrete(value), with: wanted) == false
      default:
        return false
      }
    default:
      return false
    }
  }

  /// Whether a value of one type goes where another is asked for; nil when that can't be known.
  func isCompatible(_ value: Ty, with wanted: Ty, depth: Int = 0) -> Bool? {
    guard depth < 8 else { return nil }
    switch (value, wanted) {
    case (.unknown, _), (_, .unknown), (.param, _), (_, .param), (.selfType, _), (_, .selfType): return nil
    case (.optional(let a), .optional(let b)): return isCompatible(a, with: b, depth: depth + 1)
    case (_, .optional(let b)): return isCompatible(value, with: b, depth: depth + 1)
    case (.optional, .nominal): return false
    case (.nominal(let a, _), .nominal(let b, _)):
      if a == b { return true }
      _ = memberTable(of: a)
      var seen: Set<DeclRef> = []
      func reaches(_ from: DeclRef) -> Bool {
        guard seen.insert(from).inserted else { return false }
        _ = memberTable(of: from)
        for base in inheritedTypes[from] ?? [] {
          if case .nominal(let up, _) = base, up == b || reaches(up) { return true }
          if case .existential(let items) = base {
            for item in items { if case .nominal(let up, _) = item, up == b || reaches(up) { return true } }
          }
        }
        return false
      }
      if reaches(a) { return true }
      // An unresolved parent could be anything, and a protocol may get conformances in ways not read here.
      if (inheritedTypes[a] ?? []).contains(where: { if case .unknown = $0 { return true } else { return false } }) { return nil }
      if decl(a).kind == .extensionDecl || decl(b).kind == .extensionDecl { return nil }
      return false
    case (_, .existential(let items)):
      for item in items where isCompatible(value, with: item, depth: depth + 1) == false { return false }
      return nil
    default: return nil
    }
  }
}

extension Model {
  /// A type for reading in a debug dump.
  func describe(_ ty: Ty) -> String {
    switch ty {
    case .unknown: return "?"
    case .module: return "module"
    case .nominal(let ref, let args):
      let item = decl(ref)
      let text = unit(ref).string(Int(item.nameToken))
      return text + (args.isEmpty ? "" : "<" + args.map(describe).joined(separator: ",") + ">") + (item.kind == .extensionDecl ? "(ext)" : "")
    case .meta(let inner): return describe(inner) + ".Type"
    case .tuple(let items, _): return "(" + items.map(describe).joined(separator: ",") + ")"
    case .function(let params, let result): return "(" + params.map(describe).joined(separator: ",") + ")->" + describe(result)
    case .optional(let inner): return describe(inner) + "?"
    case .param(_, _): return "param"
    case .selfType: return "Self"
    case .existential(let items): return "any " + items.map(describe).joined(separator: "&")
    case .dependent(let base, _): return describe(base) + ".?"
    }
  }
}
