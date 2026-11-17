import CodeJavaModel
import CodeModel
import CodeScan
import Foundation

/// Types: read from their tokens where they're written (a class's own type parameters in scope, aliases followed,
/// tuples as `TupleN`), values' types from declarations and initializers, expressions read back from a `.` (chains,
/// calls with their overload and generic bindings, `new`, literals, `this`, parentheses, infix operators), lambdas'
/// parameters from the function type the call expects, pattern bindings from the scrutinee or the extractor.
extension ScalaModel {
  // MARK: Reading types

  static let tupleNames = (0...22).map { name("Tuple\($0)") }
  static let functionWord = name("Function")
  static let javaPrimitives: [Name: String] = [
    name("int"): "Int", name("long"): "Long", name("short"): "Short", name("byte"): "Byte", name("char"): "Char", name("boolean"): "Boolean",
    name("float"): "Float", name("double"): "Double", name("void"): "Unit",
  ]

  /// A type written from `start` to `end` in a unit, its names resolved at `scope` (a token whose surroundings see
  /// them: the declaration's name).
  func readType(_ unitIndex: Int32, _ start: Int, _ end: Int, scope: Int) -> Ty {
    guard start >= 0, end > start, depth < 48 else { return .unknown }
    depth += 1
    defer { depth -= 1 }
    let unit = project.units[Int(unitIndex)]
    guard let facts = file(unitIndex) else { return .unknown }
    var s = start
    var e = end
    // `=> T` (by name), `T*` (repeated).
    if unit.isToken(s, "=>") { s += 1 }
    var repeated = false
    if e - 1 > s, unit.isToken(e - 1, "*") {
      repeated = true
      e -= 1
    }
    guard s < e else { return .unknown }
    let base = facts.depth[s]
    // Function types and unions at the top level, from the right.
    var k = s
    var arrow = -1
    var bars: [Int] = []
    while k < e {
      if facts.depth[k] == base {
        if (unit.isToken(k, "=>") || unit.isToken(k, "?=>")), arrow < 0 { arrow = k }
        if unit.isToken(k, "|") || unit.isToken(k, "&") || (unit.isToken(k, "with") && arrow < 0) { bars.append(k) }
      }
      k += 1
    }
    var result: Ty
    if arrow >= 0 {
      var params: [Ty] = []
      if unit.isByte(s, 0x28), facts.match[s] == Int32(arrow - 1) {
        params = typeArguments(unitIndex, s, scope: scope)
      } else {
        params = [readType(unitIndex, s, arrow, scope: scope)]
      }
      result = .function(params, readType(unitIndex, arrow + 1, e, scope: scope))
    } else if !bars.isEmpty {
      var parts: [Ty] = []
      var from = s
      for bar in bars + [e] {
        parts.append(readType(unitIndex, from, bar, scope: scope))
        from = bar + 1
      }
      result = unit.isToken(bars[0], "|") ? .constructed(Ty.union, parts) : (parts.first ?? .unknown)
    } else if unit.isByte(s, 0x28), facts.match[s] == Int32(e - 1) {
      let elements = typeArguments(unitIndex, s, scope: scope)
      result = elements.count == 1 ? elements[0] : tupleType(elements)
    } else {
      result = namedType(unitIndex, s, e, scope: scope)
    }
    if repeated { result = scalaInstance("Seq", [result]) }
    return result
  }

  /// The types between a bracket at `open` and its match, split at its commas.
  func typeArguments(_ unitIndex: Int32, _ open: Int, scope: Int) -> [Ty] {
    guard let facts = file(unitIndex), facts.match[open] > open else { return [] }
    let close = Int(facts.match[open])
    let unit = project.units[Int(unitIndex)]
    var result: [Ty] = []
    var from = open + 1
    var k = open + 1
    while k <= close {
      if k == close || (facts.depth[k] == facts.depth[open] + 1 && unit.isByte(k, 0x2C)) {
        if k > from {
          // `name: Type` in a named tuple or a dependent function's parameter.
          var typeStart = from
          if k > from + 2, unit.isToken(from + 1, ":") { typeStart = from + 2 }
          result.append(readType(unitIndex, typeStart, k, scope: scope))
        }
        from = k + 1
      }
      k += 1
    }
    return result
  }

  func tupleType(_ elements: [Ty]) -> Ty {
    guard elements.count >= 2, elements.count <= 22, let tuple = scalaType("Tuple\(elements.count)") else { return .tuple(elements, []) }
    return .nominal(tuple, elements)
  }

  /// `a.b.C[A, B]`, `C#D` (unknown), `x.type` (unknown).
  func namedType(_ unitIndex: Int32, _ s: Int, _ e: Int, scope: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var words: [Int] = []
    var k = s
    while k < e, unit.tokens[k].kind == .identifier || unit.tokens[k].kind == .keyword {
      words.append(k)
      k += 1
      guard k < e, unit.isByte(k, 0x2E) else { break }
      k += 1
    }
    guard !words.isEmpty else { return .unknown }
    var args: [Ty] = []
    if k < e, unit.isByte(k, 0x5B) {
      args = typeArguments(unitIndex, k, scope: scope)
      k = Int(file(unitIndex)?.match[k] ?? Int32(e)) + 1
    }
    guard k >= e else { return .unknown }
    if unit.isToken(words.last!, "type") { return .unknown }
    guard let site = typeSite(unitIndex, words, scope: scope) else { return .unknown }
    return typeOf(site, args: args)
  }

  /// The type a resolved name stands for, with arguments.
  func typeOf(_ site: Site, args: [Ty]) -> Ty {
    switch site {
    case .generic(let unitIndex, let token):
      return .param(word(unitIndex, Int(token)), nil)
    case .decl(let ref):
      let item = decl(ref)
      if item.kind == .typeAlias, !isJava(ref), item.typeStart >= 0, !flags(ref).contains(.isOpaque) {
        guard resolving.insert(ref).inserted else { return .unknown }
        defer { resolving.remove(ref) }
        let target = readType(ref.unit, Int(item.typeStart), Int(item.typeEnd), scope: Int(item.nameToken))
        return substitute(target, parameterMap(ref, args))
      }
      if item.kind == .enumCase, !flags(ref).contains(.hasParams), item.parent >= 0 { return .nominal(DeclRef(unit: ref.unit, decl: item.parent), args) }
      return .nominal(ref, args)
    default:
      return .unknown
    }
  }

  /// What a type's words name: the first resolved as a type (or a package or object on the way), the rest selected.
  func typeSite(_ unitIndex: Int32, _ words: [Int], scope: Int) -> Site? {
    let unit = project.units[Int(unitIndex)]
    let first = word(unitIndex, words[0])
    names[first] = nameText(unit, words[0])
    if words.count == 1 {
      let found = resolveName(unitIndex, scope, first, want: .type)
      return found.first { if case .module = $0 { return false } else { return true } }
    }
    var current: ImportBase?
    let found = resolveName(unitIndex, scope, first, want: .any)
    for site in found {
      switch site {
      case .module(let package): current = .package(packageNames[package] ?? names[first] ?? "")
      case .decl(let ref): if current == nil || isObject(ref) { current = .decl(ref) }
      default: break
      }
    }
    if current == nil, isPackage(nameText(unit, words[0])) { current = .package(nameText(unit, words[0])) }
    for (n, k) in words.enumerated().dropFirst() {
      guard let entity = current else { return nil }
      let w = word(unitIndex, k)
      names[w] = nameText(unit, k)
      if n == words.count - 1 {
        let sites = entityMembers(entity, w, want: .type)
        if let site = sites.first(where: { if case .decl = $0 { return true } else { return false } }) { return site }
        // A member type of a class: `Outer.Inner` through the class itself.
        if case .decl(let ref) = entity {
          if let inner = self.unit(ref).children(of: ref.decl).first(where: { self.unit(ref).decls[Int($0)].name == w && self.unit(ref).decls[Int($0)].kind.isType }) {
            return .decl(DeclRef(unit: ref.unit, decl: inner))
          }
        }
        return nil
      }
      current = select(entity, w, text: nameText(unit, k))
    }
    return nil
  }

  /// Java's types as Scala sees them: primitives as `Int`, arrays as `Array`.
  func fromJava(_ ty: Ty) -> Ty {
    switch ty {
    case .constructed(let kind, let args):
      if args.isEmpty, let primitive = Self.javaPrimitives[kind] { return scalaInstance(primitive) }
      if kind == Ty.array, let element = args.first { return scalaInstance("Array", [fromJava(element)]) }
      return .unknown
    case .nominal(let ref, let args): return .nominal(ref, args.map(fromJava))
    case .meta(let inner): return .meta(fromJava(inner))
    default: return ty
    }
  }

  // MARK: Hierarchy

  /// A template's parents as written (`extends A with B`), in terms of its own parameters; an enum's case extends its
  /// enum; a Java class's from Java's model.
  package func supertypes(of ref: DeclRef) -> [Ty] {
    if let known = supertypeCache[ref] { return known }
    supertypeCache[ref] = []
    var result: [Ty] = []
    if isJava(ref) {
      result = java.supertypes(of: ref).map(fromJava)
    } else {
      let item = decl(ref)
      let holder = self.unit(ref)
      for r in 0..<Int(item.inheritCount) {
        let range = holder.ranges[Int(item.inheritStart) + r]
        let scope = item.parent >= 0 && item.kind != .enumCase ? Int(item.first) : Int(item.first)
        let ty = readType(ref.unit, Int(range.start), Int(range.end), scope: scope)
        guard case .nominal(let target, _) = ty, target != ref else { continue }
        result.append(ty)
      }
      if item.kind == .enumCase, result.isEmpty, item.parent >= 0 { result.append(.nominal(DeclRef(unit: ref.unit, decl: item.parent), [])) }
    }
    supertypeCache[ref] = result
    return result
  }

  package func memberBase(_ ty: Ty, depth: Int = 0) -> Ty {
    switch ty {
    case .tuple(let elements, _): return tupleType(elements)
    default: return ty
    }
  }

  // MARK: Members of types

  /// A type's instance members of a name, through its parents, with how the declaring class's parameters read.
  func memberEntries(of ty: Ty, _ word: Name) -> [MemberEntry] {
    guard case .nominal(let start, let args) = memberBase(ty) else { return [] }
    var seen: Set<DeclRef> = []
    var queue: [(DeclRef, [Name: Ty])] = [(start, parameterMap(start, args))]
    var index = 0
    var result: [MemberEntry] = []
    // Own members first, then each parent's from the rightmost: Scala's linearization, near enough.
    while index < queue.count, queue.count < 200 {
      let (ref, map) = queue[index]
      index += 1
      guard seen.insert(ref).inserted else { continue }
      let holder = self.unit(ref)
      for child in holder.children(of: ref.decl) {
        let item = holder.decls[Int(child)]
        guard item.name == word, item.kind != .extensionDecl, !item.isLocal || decl(ref).isLocal else { continue }
        result.append(MemberEntry(ref: DeclRef(unit: ref.unit, decl: child), substitution: map))
      }
      if !result.isEmpty { return result }
      for parent in supertypes(of: ref).reversed() {
        guard case .nominal(let target, let parentArgs) = substitute(parent, map) else { continue }
        queue.append((target, parameterMap(target, parentArgs)))
      }
    }
    return result
  }

  func memberRefs(of ty: Ty, _ word: Name) -> [DeclRef] {
    switch ty {
    case .module(let package): return packageDecls(packageNames[package] ?? "", word)
    case .meta(let inner):
      guard case .nominal(let ref, _) = inner else { return [] }
      return staticMembers(ref, word)
    case .nominal(let ref, _) where isObject(ref):
      return templateMembers(ref, word)
    default:
      return memberEntries(of: ty, word).map(\.ref)
    }
  }

  /// What `T.name` reaches when `T` is a class used as a term: an enum's cases and its companion's members, a Java
  /// class's statics, a Scala class's companion object's members.
  func staticMembers(_ ref: DeclRef, _ word: Name) -> [DeclRef] {
    let holder = self.unit(ref)
    if isJava(ref) {
      var result: [DeclRef] = []
      for target in [ref] + hierarchyRefs(.nominal(ref, [])) {
        for child in self.unit(target).children(of: target.decl) where self.unit(target).decls[Int(child)].name == word && (self.unit(target).decls[Int(child)].isStatic || self.unit(target).decls[Int(child)].kind.isNominal || self.unit(target).decls[Int(child)].kind == .enumCase) {
          result.append(DeclRef(unit: target.unit, decl: child))
        }
        if !result.isEmpty { break }
      }
      return result
    }
    if decl(ref).kind == .enumeration {
      let cases = holder.children(of: ref.decl).filter { holder.decls[Int($0)].name == word && holder.decls[Int($0)].kind == .enumCase }
      if !cases.isEmpty { return cases.map { DeclRef(unit: ref.unit, decl: $0) } }
    }
    if let object = companion(of: ref) { return templateMembers(object, word) }
    return []
  }

  func hierarchyRefs(_ ty: Ty) -> [DeclRef] { hierarchy(of: ty).map(\.0).dropFirst().map { $0 } }

  /// What `receiver.name` means at a token: members (a class's plain constructor parameters only inside it), then
  /// extension methods and implicit classes' methods visible there.
  func memberSites(of receiver: Ty, _ word: Name, unitIndex: Int32, at: Int) -> [Site] {
    switch receiver {
    case .unknown: return []
    case .module(let package):
      return entityMembers(.package(packageNames[package] ?? ""), word, want: .any)
    case .meta(let inner):
      guard case .nominal(let ref, _) = inner else { return [] }
      return staticMembers(ref, word).map { .decl($0) }
    default:
      break
    }
    if case .nominal(let ref, _) = receiver, isObject(ref) {
      var found = templateMembers(ref, word)
      if found.isEmpty { found = extensionMembers(in: ref, word).filter { _ in false } }
      if !found.isEmpty { return found.map { .decl($0) } }
      return extensionSites(receiver, word, unitIndex: unitIndex, at: at)
    }
    var found = memberEntries(of: receiver, word).map(\.ref)
    found = found.filter { ref in
      let f = flags(ref)
      guard f.contains(.classParam), !f.contains(.paramVal), !f.contains(.paramVar), let owner = enclosingClass(ref) else { return true }
      return owner.unit == unitIndex && templatesAround(unitIndex, at).contains(owner.decl)
    }
    if !found.isEmpty { return found.map { .decl($0) } }
    return extensionSites(receiver, word, unitIndex: unitIndex, at: at)
  }

  // MARK: Extensions

  static let anyReceiver = name("*")

  /// Extension groups and implicit classes, by the last name of what they extend.
  func extensionGroups(named word: Name) -> [DeclRef] {
    if extensionIndexUnits != project.units.count {
      extensionIndex.removeAll()
      for u in 0..<project.units.count where !isJava(Int32(u)) {
        let holder = project.units[u]
        for (index, item) in holder.decls.enumerated() {
          let ref = DeclRef(unit: Int32(u), decl: Int32(index))
          if item.kind == .extensionDecl {
            var key = item.name
            if item.typeStart >= 0, item.typeEnd == item.typeStart + 1 {
              for g in 0..<Int(item.genericCount) where holder.generics[Int(item.genericStart) + g].name == item.name { key = Self.anyReceiver }
            }
            extensionIndex[key, default: []].append(ref)
          } else if item.kind == .classType, flags(ref).contains(.isImplicit), let receiver = implicitReceiverRange(ref) {
            var last: Name = 0
            var k = receiver.0
            while k < receiver.1, holder.tokens[k].kind == .identifier {
              last = self.word(Int32(u), k)
              guard holder.isByte(k + 1, 0x2E) else { break }
              k += 2
            }
            for g in 0..<Int(item.genericCount) where holder.generics[Int(item.genericStart) + g].name == last { last = Self.anyReceiver }
            if last != 0 { extensionIndex[last, default: []].append(ref) }
          }
        }
      }
      extensionIndexUnits = project.units.count
    }
    return extensionIndex[word] ?? []
  }

  /// An implicit class's first constructor parameter's type.
  func implicitReceiverRange(_ ref: DeclRef) -> (Int, Int)? {
    guard let first = classParams(ref).first else { return nil }
    let item = decl(first)
    guard item.typeStart >= 0 else { return nil }
    return (Int(item.typeStart), Int(item.typeEnd))
  }

  /// What a group extends.
  func extendedType(_ group: DeclRef) -> Ty {
    let item = decl(group)
    if item.kind == .extensionDecl {
      guard item.typeStart >= 0 else { return .unknown }
      return readType(group.unit, Int(item.typeStart), Int(item.typeEnd), scope: Int(item.first))
    }
    guard let range = implicitReceiverRange(group) else { return .unknown }
    return readType(group.unit, range.0, range.1, scope: Int(item.nameToken))
  }

  func extensionSites(_ receiver: Ty, _ word: Name, unitIndex: Int32, at: Int) -> [Site] {
    var keys: [Name] = [Self.anyReceiver]
    var targets: [DeclRef] = []
    if case .nominal(let start, _) = receiver {
      for (ref, _) in hierarchy(of: receiver) {
        keys.append(decl(ref).name)
        targets.append(ref)
      }
      _ = start
    } else {
      return []
    }
    var found: [Site] = []
    for key in keys {
      for group in extensionGroups(named: key) {
        let members: [DeclRef]
        if decl(group).kind == .extensionDecl {
          members = self.unit(group).children(of: group.decl).filter { self.unit(group).decls[Int($0)].name == word }.map { DeclRef(unit: group.unit, decl: $0) }
        } else {
          members = templateMembers(group, word)
        }
        guard !members.isEmpty, groupVisible(group, unitIndex: unitIndex, at: at, targets: targets) else { continue }
        let extended = extendedType(group)
        switch extended {
        case .param: break
        case .nominal(let target, _):
          guard targets.contains(target) else { continue }
        default:
          continue
        }
        found += members.map { .decl($0) }
      }
    }
    return found
  }

  /// Whether a group is visible from a place: inside the template that holds it, in one of the file's packages (or
  /// its package object), Scala's own, in the companion of what it extends, or brought in by an import there.
  func groupVisible(_ group: DeclRef, unitIndex: Int32, at: Int, targets: [DeclRef]) -> Bool {
    let item = decl(group)
    let owner = item.parent
    let groupPackage = packageOf(group.unit)
    let filePackages = file(unitIndex)?.packages ?? []
    if group.unit == unitIndex, owner >= 0, templatesAround(unitIndex, at).contains(owner) { return true }
    if group.unit == unitIndex, owner < 0 { return true }
    if owner < 0, filePackages.contains(groupPackage) || groupPackage == "scala" || (filePackages.isEmpty && groupPackage.isEmpty) { return true }
    let ownerRef = DeclRef(unit: group.unit, decl: owner)
    if owner >= 0 {
      if flags(ownerRef).contains(.packageObject) {
        let package = (groupPackage.isEmpty ? "" : groupPackage + ".") + nameText(self.unit(ownerRef), Int(decl(ownerRef).nameToken))
        if filePackages.contains(package) { return true }
      }
      if groupPackage == "scala", nameText(self.unit(ownerRef), Int(decl(ownerRef).nameToken)) == "Predef" { return true }
      // The implicit scope: the companion of what it extends.
      for target in targets where companion(of: target) == ownerRef { return true }
    }
    guard let facts = file(unitIndex) else { return false }
    var groupNames = Set(self.unit(group).children(of: group.decl).map { self.unit(group).decls[Int($0)].name })
    if item.kind != .extensionDecl { groupNames.insert(item.name) }
    for (position, entry) in facts.imports.enumerated() where entry.scopeStart < Int32(at) && Int32(at) < entry.scopeEnd {
      guard let base = importBase(unitIndex, position) else { continue }
      let named = entry.wildcard || entry.selectors.contains { groupNames.contains($0.name) }
      guard named else { continue }
      switch base {
      case .package(let package):
        if owner < 0, groupPackage == package { return true }
        if owner >= 0, flags(ownerRef).contains(.packageObject), entry.wildcard {
          let objectPackage = (groupPackage.isEmpty ? "" : groupPackage + ".") + nameText(self.unit(ownerRef), Int(decl(ownerRef).nameToken))
          if objectPackage == package { return true }
        }
      case .decl(let ref):
        if owner >= 0, ref == ownerRef { return true }
      case .value:
        break
      }
    }
    return false
  }

  // MARK: Values

  /// A declaration's type as a value: a field's, a method's result, an object's own type, a case's enum.
  func valueType(of ref: DeclRef) -> Ty {
    let item = decl(ref)
    if item.isLocal, let facts = file(ref.unit), let known = facts.localTypes[ref.decl] { return known }
    if !item.isLocal, let known = valueTypes[ref] { return known }
    guard resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    var result = Ty.unknown
    if isJava(ref) {
      result = fromJava(java.valueType(of: ref))
    } else {
      let f = flags(ref)
      switch item.kind {
      case .variable:
        if f.contains(.placeholder) || f.contains(.lambda), item.typeStart < 0 {
          result = lambdaParameterType(ref)
        } else if item.typeStart >= 0 {
          result = readType(ref.unit, Int(item.typeStart), Int(item.typeEnd), scope: Int(item.nameToken))
        } else if info(ref).extractorStart >= 0 {
          let facts = info(ref)
          let words = Array(Int(facts.extractorStart)..<Int(facts.extractorEnd)).filter { self.unit(ref).tokens[$0].kind == .identifier }
          if let site = typeSite(ref.unit, words, scope: Int(item.nameToken)) ?? resolveName(ref.unit, Int(item.nameToken), word(ref.unit, words.first ?? 0), want: .any).first {
            if case .decl(let target) = site, isObject(target) { result = .nominal(target, []) } else { result = typeOf(site, args: []) }
          }
        } else if f.contains(.forBinding) {
          result = generatorBindingType(ref)
        } else if f.contains(.pattern) {
          result = patternBindingType(ref)
        } else if item.initStart >= 0 {
          result = rangeType(ref.unit, Int(item.initStart), Int(item.initEnd))
        }
      case .function:
        if item.typeStart >= 0 {
          result = readType(ref.unit, Int(item.typeStart), Int(item.typeEnd), scope: Int(item.nameToken))
        } else if item.initStart >= 0 {
          result = rangeType(ref.unit, Int(item.initStart), Int(item.initEnd))
        }
      case .classType where item.isStatic:
        result = .nominal(ref, [])
      case .classType, .protocolType, .enumeration, .structure:
        result = companion(of: ref).map { .nominal($0, []) } ?? .meta(.nominal(ref, []))
      case .enumCase:
        if f.contains(.hasParams) {
          result = .meta(.nominal(ref, []))
        } else if item.parent >= 0 {
          result = .nominal(DeclRef(unit: ref.unit, decl: item.parent), [])
        }
      default:
        break
      }
    }
    if item.isLocal { file(ref.unit)?.localTypes[ref.decl] = result } else { valueTypes[ref] = result }
    return result
  }

  /// A site's type as a value.
  func siteType(_ site: Site) -> Ty {
    switch site {
    case .decl(let ref): return valueType(of: ref)
    case .local(let unitIndex, let token):
      if isJava(unitIndex) { return .unknown }
      let holder = project.units[Int(unitIndex)]
      for (index, item) in holder.decls.enumerated() where item.paramCount > 0 && item.first <= token && token < max(item.end, item.first + 1) {
        for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].nameToken == token {
          let param = holder.params[Int(item.paramStart) + p]
          guard param.typeStart >= 0 else { return .unknown }
          var ty = readType(unitIndex, Int(param.typeStart), Int(param.typeEnd), scope: Int(token))
          if param.variadic, case .nominal = ty {} else if param.variadic { ty = .unknown }
          _ = index
          return ty
        }
      }
      return .unknown
    case .module(let package):
      return .module(package)
    case .generic:
      return .unknown
    }
  }

  // MARK: Expressions

  /// The tokens of one argument list at `open`, split at its commas.
  func arguments(_ unitIndex: Int32, open: Int) -> [(Int, Int)] {
    guard let facts = file(unitIndex), open < facts.match.count, facts.match[open] > open else { return [] }
    let close = Int(facts.match[open])
    let unit = project.units[Int(unitIndex)]
    var result: [(Int, Int)] = []
    var from = open + 1
    for k in (open + 1)...close where k == close || (facts.depth[k] == facts.depth[open] + 1 && unit.isByte(k, 0x2C)) {
      if k > from { result.append((from, k)) }
      from = k + 1
    }
    return result
  }

  /// Whether the token before `i` ends an expression that a name at `i` is applied to infix: `a compare b`.
  func infixReceiverEnd(_ unitIndex: Int32, _ i: Int) -> Int? {
    let unit = project.units[Int(unitIndex)]
    guard i > 0, !unit.startsLine(i), let facts = file(unitIndex) else { return nil }
    let before = i - 1
    let kind = unit.tokens[before].kind
    if kind == .identifier {
      let w = facts.names[before]
      if ScalaWord.hard.contains(w) || w == ScalaWord.underscore || [ScalaWord.derives, ScalaWord.extensionWord, ScalaWord.using, ScalaWord.asWord, ScalaWord.endWord, name("inline"), name("open"), name("infix"), name("transparent"), name("opaque")].contains(w) { return nil }
      // A name declared right there (`def f`, `val x`), or an interpolator.
      if facts.declAt[Int32(before)] != nil, unit.decls.indices.contains(Int(facts.declAt[Int32(before)]!)) { return nil }
    } else if kind == .close {
      if unit.isByte(before, 0x5D) { return nil }
    } else if kind != .number && kind != .string {
      return nil
    }
    // `x: T` and type positions aren't infix calls; nor is what's followed by `:` or `=`.
    if positionKind(unitIndex, i) == .type { return nil }
    if unit.isToken(i + 1, ":") || unit.isToken(i + 1, "=") || unit.isToken(i + 1, "<-") { return nil }
    if inPattern(unitIndex, i) { return nil }
    return before
  }

  /// The type of the expression that ends at token `j`: a chain read back from its end.
  func expressionType(_ unitIndex: Int32, endingAt j: Int) -> Ty {
    guard j >= 0, depth < 48, let facts = file(unitIndex) else { return .unknown }
    depth += 1
    defer { depth -= 1 }
    let unit = project.units[Int(unitIndex)]
    let token = unit.tokens[j]
    switch token.kind {
    case .number:
      let text = unit.string(j).lowercased()
      if text.hasSuffix("l") { return scalaInstance("Long") }
      if text.hasSuffix("f") { return scalaInstance("Float") }
      if text.hasSuffix("d") || (text.contains(".") || text.contains("e")) && !text.hasPrefix("0x") { return scalaInstance("Double") }
      return scalaInstance("Int")
    case .string, .interpolationClose:
      if token.kind == .string, unit.string(j).hasPrefix("'") { return scalaInstance("Char") }
      return stringType()
    case .close:
      return closeType(unitIndex, j)
    case .identifier, .keyword, .declarationKeyword:
      let w = facts.names[j]
      if w == ScalaWord.this, !unit.isByte(j - 1, 0x2E) { return thisType(unitIndex, j) }
      if w == ScalaWord.trueWord || w == ScalaWord.falseWord { return scalaInstance("Boolean") }
      if w == 0 || (ScalaWord.hard.contains(w) && unit.source.text[token.start] != 0x60) { return .unknown }
      names[w] = nameText(unit, j)
      if w == ScalaWord.underscore {
        if let local = facts.declAt[Int32(j)] { return valueType(of: DeclRef(unit: unitIndex, decl: local)) }
        return .unknown
      }
      // `new T`.
      if let newToken = newBefore(unitIndex, j) { return readType(unitIndex, newToken + 1, j + 1, scope: j) }
      if j >= 2, unit.isByte(j - 1, 0x2E) {
        let receiver = expressionType(unitIndex, endingAt: j - 2)
        return selectionType(unitIndex, receiver: receiver, w, at: j, groups: [])
      }
      let sites = preferByPosition(unitIndex, j, resolveName(unitIndex, j, w, want: .term), forceTerm: true)
      guard let site = sites.first else { return .unknown }
      return applied(siteType(site), site: site, unitIndex: unitIndex, groups: [], at: j)
    default:
      return .unknown
    }
  }

  /// `new a.B` ending at `j`: the `new` token.
  func newBefore(_ unitIndex: Int32, _ j: Int) -> Int? {
    let unit = project.units[Int(unitIndex)]
    var k = j
    while k >= 2, unit.isByte(k - 1, 0x2E), unit.tokens[k - 2].kind == .identifier { k -= 2 }
    return k >= 1 && unit.isToken(k - 1, "new") ? k - 1 : nil
  }

  /// The enclosing class's own type (not an extension group's, an anonymous given's).
  func thisType(_ unitIndex: Int32, _ j: Int) -> Ty {
    for level in templatesAround(unitIndex, j) {
      let ref = DeclRef(unit: unitIndex, decl: level)
      let item = decl(ref)
      if item.kind == .extensionDecl { continue }
      if item.name == 0 { return .unknown }
      let holder = self.unit(ref)
      let args = (0..<Int(item.genericCount)).map { Ty.param(holder.generics[Int(item.genericStart) + $0].name, nil) }
      return .nominal(ref, args)
    }
    return .unknown
  }

  /// An expression ending in a bracket: a call (with what it's applied to), type arguments, a block argument, or
  /// parentheses around an expression or a tuple.
  func closeType(_ unitIndex: Int32, _ j: Int) -> Ty {
    guard let facts = file(unitIndex), facts.match[j] >= 0 else { return .unknown }
    let unit = project.units[Int(unitIndex)]
    var groups: [Int] = []
    var k = j
    while k >= 0, unit.tokens[k].kind == .close, facts.match[k] >= 0 {
      let open = Int(facts.match[k])
      groups.insert(open, at: 0)
      k = open - 1
      // A group starting a line, or after an operator, isn't applied to what's before it.
      if k < 0 || unit.startsLine(open) && !unit.isByte(open, 0x7B) { break }
      if !(unit.tokens[k].kind == .close || unit.tokens[k].kind == .identifier || unit.tokens[k].kind == .keyword) { break }
      if unit.tokens[k].kind == .close { continue }
      break
    }
    // Nothing applied: parentheses or a block.
    let callee = k
    let first = groups[0]
    let isCallee = callee >= 0 && (unit.tokens[callee].kind == .identifier || unit.tokens[callee].kind == .keyword && facts.names[callee] == ScalaWord.this)
      && !(ScalaWord.hard.contains(facts.names[callee]) && facts.names[callee] != ScalaWord.this) && !unit.startsLine(first) && !(unit.isByte(first, 0x7B) && unit.isToken(callee, "match"))
    if !isCallee {
      // The groups after the first apply to its value.
      var value: Ty
      if unit.isByte(first, 0x28) {
        let parts = arguments(unitIndex, open: first)
        if parts.count == 1 {
          value = rangeType(unitIndex, parts[0].0, parts[0].1)
        } else if parts.count > 1 {
          value = tupleType(parts.map { rangeType(unitIndex, $0.0, $0.1) })
        } else {
          value = scalaInstance("Unit")
        }
      } else if unit.isByte(first, 0x7B) {
        value = rangeType(unitIndex, first + 1, Int(facts.match[first]))
      } else {
        return .unknown
      }
      for group in groups.dropFirst() where unit.isByte(group, 0x28) {
        value = callType(unitIndex, receiver: value, ScalaWord.apply, at: group, groups: [group])
      }
      return value
    }
    let w = facts.names[callee]
    names[w] = nameText(unit, callee)
    if let newToken = newBefore(unitIndex, callee) {
      // `new T[A](…)`.
      var end = callee + 1
      if unit.isByte(end, 0x5B), facts.match[end] > 0 { end = Int(facts.match[end]) + 1 }
      return readType(unitIndex, newToken + 1, end, scope: callee)
    }
    if callee >= 2, unit.isByte(callee - 1, 0x2E) {
      let receiver = expressionType(unitIndex, endingAt: callee - 2)
      return selectionType(unitIndex, receiver: receiver, w, at: callee, groups: groups)
    }
    let sites = resolveName(unitIndex, callee, w, want: .term)
    return applied(.unknown, sites: sites, unitIndex: unitIndex, callee: callee, groups: groups)
  }

  /// `receiver.name` applied to these groups.
  func selectionType(_ unitIndex: Int32, receiver: Ty, _ word: Name, at: Int, groups: [Int]) -> Ty {
    let sites = memberSites(of: receiver, word, unitIndex: unitIndex, at: at)
    if sites.isEmpty { return .unknown }
    return applied(receiver, sites: sites, unitIndex: unitIndex, callee: at, groups: groups)
  }

  func callType(_ unitIndex: Int32, receiver: Ty, _ word: Name, at: Int, groups: [Int]) -> Ty {
    if case .function(_, let result) = receiver, word == ScalaWord.apply { return result }
    let sites = memberSites(of: receiver, word, unitIndex: unitIndex, at: at)
    return applied(receiver, sites: sites, unitIndex: unitIndex, callee: at, groups: groups)
  }

  /// A value's type, applied to argument groups when it's called.
  func applied(_ ty: Ty, site: Site, unitIndex: Int32, groups: [Int], at: Int) -> Ty {
    guard case .decl(let ref) = site else { return ty }
    let item = decl(ref)
    if item.kind == .function, !isJava(ref) {
      return methodResult(ref, receiver: .unknown, unitIndex: unitIndex, groups: groups, callee: at)
    }
    return ty
  }

  /// What calling one of `sites` with `groups` gives: a method's result (its generics bound from the receiver, type
  /// arguments and arguments), a class's instance, an object's `apply`, a value's `apply`.
  func applied(_ receiver: Ty, sites: [Site], unitIndex: Int32, callee: Int, groups: [Int]) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let parens = groups.filter { unit.isByte($0, 0x28) || unit.isByte($0, 0x7B) }
    var methods: [DeclRef] = []
    var other: Site?
    for site in sites {
      if case .decl(let ref) = site, decl(ref).kind == .function || decl(ref).kind == .initializer { methods.append(ref) } else if other == nil { other = site }
    }
    if !methods.isEmpty {
      var chosen = methods
      if let first = parens.first, unit.isByte(first, 0x28) {
        let count = arguments(unitIndex, open: first).count
        let fits = methods.filter { accepts($0, count) }
        if !fits.isEmpty { chosen = fits }
      } else if parens.isEmpty {
        let fits = methods.filter { info($0).lists.isEmpty || isJava($0) && decl($0).paramCount == 0 }
        if !fits.isEmpty { chosen = fits }
      }
      var results: [Ty] = []
      for method in chosen.prefix(4) {
        results.append(methodResult(method, receiver: receiver, unitIndex: unitIndex, groups: groups, callee: callee))
      }
      guard let first = results.first, results.allSatisfy({ $0 == first }) else { return .unknown }
      return first
    }
    guard let site = other else { return .unknown }
    guard case .decl(let ref) = site else {
      return applyRest(siteType(site), unitIndex: unitIndex, groups: parens, at: callee)
    }
    let item = decl(ref)
    if parens.isEmpty {
      // Explicit type arguments on a value or class name aren't a call.
      return valueType(of: ref)
    }
    if isObject(ref) {
      let applies = templateMembers(ref, ScalaWord.apply)
      if !applies.isEmpty { return applied(.nominal(ref, []), sites: applies.map { .decl($0) }, unitIndex: unitIndex, callee: callee, groups: groups) }
      if let cls = companion(of: ref) { return constructed(cls, unitIndex: unitIndex, groups: groups) }
      return .unknown
    }
    if item.kind.isNominal || item.kind == .enumCase {
      if let object = companion(of: ref) {
        let applies = templateMembers(object, ScalaWord.apply)
        if !applies.isEmpty { return applied(.nominal(object, []), sites: applies.map { .decl($0) }, unitIndex: unitIndex, callee: callee, groups: groups) }
      }
      if isJava(ref) { return .unknown }
      return constructed(ref, unitIndex: unitIndex, groups: groups)
    }
    return applyRest(valueType(of: ref), unitIndex: unitIndex, groups: parens, at: callee)
  }

  /// `T(…)` for a class: its instance, its parameters bound from the arguments where they can be.
  func constructed(_ ref: DeclRef, unitIndex: Int32, groups: [Int]) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let item = decl(ref)
    guard item.genericCount > 0 else { return .nominal(ref, []) }
    let holder = self.unit(ref)
    let own = Set((0..<Int(item.genericCount)).map { holder.generics[Int(item.genericStart) + $0].name })
    var bindings: [Name: Ty] = [:]
    if let typeGroup = groups.first, unit.isByte(typeGroup, 0x5B) {
      let args = typeArguments(unitIndex, typeGroup, scope: typeGroup)
      for (g, arg) in args.enumerated() where g < Int(item.genericCount) { bindings[holder.generics[Int(item.genericStart) + g].name] = arg }
    } else if let first = groups.first(where: { unit.isByte($0, 0x28) }) {
      let params = classParams(ref).filter { info($0).listIndex == 0 }
      for (index, argument) in arguments(unitIndex, open: first).enumerated() where index < params.count {
        let param = decl(params[index])
        guard param.typeStart >= 0 else { continue }
        let pattern = readType(ref.unit, Int(param.typeStart), Int(param.typeEnd), scope: Int(param.nameToken))
        unify(pattern, rangeType(unitIndex, argument.0, argument.1), own, &bindings)
      }
    }
    let args = (0..<Int(item.genericCount)).map { bindings[holder.generics[Int(item.genericStart) + $0].name] ?? .unknown }
    return .nominal(ref, args)
  }

  /// Further groups applied to a value: its `apply`, or a function's result.
  func applyRest(_ ty: Ty, unitIndex: Int32, groups: [Int], at: Int) -> Ty {
    var value = ty
    for group in groups {
      if case .function(_, let result) = value {
        value = result
        continue
      }
      value = callType(unitIndex, receiver: value, ScalaWord.apply, at: at, groups: [group])
      if value == .unknown { break }
    }
    return value
  }

  /// A method's result: generics bound from the receiver's arguments, explicit type arguments and the arguments of each
  /// group; groups past its parameter lists apply to the result.
  func methodResult(_ ref: DeclRef, receiver: Ty, unitIndex: Int32, groups: [Int], callee: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let item = decl(ref)
    var map: [Name: Ty] = [:]
    if case .nominal(let base, _) = memberBase(receiver), let owner = enclosingClass(ref), let found = asSupertype(receiver, owner) {
      if case .nominal(_, let args) = found { map = parameterMap(owner, args) }
      _ = base
    }
    if isJava(ref) {
      return substitute(fromJava(java.valueType(of: ref)), map)
    }
    // An extension method's group (or implicit class) binds its own parameters from the receiver.
    if item.parent >= 0, map.isEmpty, receiver != .unknown {
      let group = DeclRef(unit: ref.unit, decl: item.parent)
      let groupItem = decl(group)
      if groupItem.kind == .extensionDecl || flags(group).contains(.isImplicit), groupItem.genericCount > 0 {
        let groupHolder = self.unit(group)
        let groupOwn = Set((0..<Int(groupItem.genericCount)).map { groupHolder.generics[Int(groupItem.genericStart) + $0].name })
        var bound: [Name: Ty] = [:]
        let pattern = extendedType(group)
        if case .nominal(let target, _) = pattern, let lifted = asSupertype(receiver, target) { unify(pattern, lifted, groupOwn, &bound) } else { unify(pattern, receiver, groupOwn, &bound) }
        map = bound
      }
    }
    let holder = self.unit(ref)
    let own = Set((0..<Int(item.genericCount)).map { holder.generics[Int(item.genericStart) + $0].name })
    var bindings: [Name: Ty] = [:]
    var rest = groups
    if let typeGroup = rest.first, unit.isByte(typeGroup, 0x5B) {
      let args = typeArguments(unitIndex, typeGroup, scope: typeGroup)
      for (g, arg) in args.enumerated() where g < Int(item.genericCount) { bindings[holder.generics[Int(item.genericStart) + g].name] = arg }
      rest.removeFirst()
    }
    let lists = info(ref).lists
    var listIndex = 0
    var paramIndex = Int(item.paramStart)
    var usedGroups = 0
    while listIndex < lists.count {
      let size = Int(lists[listIndex])
      let isUsing = info(ref).usingLists & (1 << UInt32(min(listIndex, 31))) != 0
      if isUsing, rest.isEmpty || !unit.isToken(rest[0] + 1, "using") {
        // Passed implicitly.
        paramIndex += size
        listIndex += 1
        continue
      }
      guard let group = rest.first else { break }
      rest.removeFirst()
      usedGroups += 1
      if !own.isEmpty {
        let args = unit.isByte(group, 0x7B) ? [(group, Int(file(unitIndex)!.match[group]) + 1)] : arguments(unitIndex, open: group)
        let repeated = size > 0 && holder.params[paramIndex + size - 1].variadic
        for (n, argument) in args.enumerated() where n < size || repeated {
          let param = holder.params[paramIndex + min(n, size - 1)]
          guard param.typeStart >= 0 else { continue }
          var pattern = substitute(readType(ref.unit, Int(param.typeStart), Int(param.typeEnd), scope: Int(item.nameToken)), map)
          // `xs: A*` takes each argument as an `A`.
          if param.variadic, case .nominal(_, let parts) = pattern, let element = parts.first { pattern = element }
          if case .function(let paramTypes, let result) = pattern {
            // A lambda: its parameters from what's bound, its result from its body.
            let known = paramTypes.map { substitute($0, bindings) }
            if let body = lambdaBodyType(unitIndex, argument.0, argument.1, parameters: known) { unify(result, body, own, &bindings) }
            continue
          }
          unify(pattern, rangeType(unitIndex, argument.0, argument.1), own, &bindings)
        }
      }
      paramIndex += size
      listIndex += 1
    }
    var result = valueType(of: ref)
    result = substitute(substitute(result, map), bindings)
    if containsOwn(result, own) { result = eraseParams(result, own) }
    return applyRest(result, unitIndex: unitIndex, groups: rest.filter { unit.isByte($0, 0x28) }, at: callee)
  }

  func containsOwn(_ ty: Ty, _ own: Set<Name>) -> Bool {
    switch ty {
    case .param(let w, _): return own.contains(w)
    case .nominal(_, let args), .constructed(_, let args): return args.contains { containsOwn($0, own) }
    case .function(let params, let result): return params.contains { containsOwn($0, own) } || containsOwn(result, own)
    case .tuple(let elements, _): return elements.contains { containsOwn($0, own) }
    default: return false
    }
  }

  /// Unbound method generics become unknown: a guess would be wrong more often than it helps.
  func eraseParams(_ ty: Ty, _ own: Set<Name>) -> Ty {
    switch ty {
    case .param(let w, _): return own.contains(w) ? .unknown : ty
    case .nominal(let ref, let args): return .nominal(ref, args.map { eraseParams($0, own) })
    case .function(let params, let result): return .function(params.map { eraseParams($0, own) }, eraseParams(result, own))
    case .tuple(let elements, let labels): return .tuple(elements.map { eraseParams($0, own) }, labels)
    case .constructed(let kind, let args): return .constructed(kind, args.map { eraseParams($0, own) })
    default: return ty
    }
  }

  /// The type of a statement or block: its last statement's value.
  func rangeType(_ unitIndex: Int32, _ start: Int, _ end: Int) -> Ty {
    guard start < end, depth < 48, let facts = file(unitIndex) else { return .unknown }
    let unit = project.units[Int(unitIndex)]
    var s = start
    var e = end
    // `{ … }` around it: its last statement.
    if unit.isByte(s, 0x7B), facts.match[s] == Int32(e - 1) {
      return rangeType(unitIndex, s + 1, e - 1)
    }
    // Statements on several lines: the last one at the block's indentation.
    if e - 1 > s, unit.startsLine(s) || (s > 0 && unit.isToken(s - 1, "=")), facts.depth[s] == facts.depth[e - 1] {
      var last = s
      let base = facts.depth[s]
      let lineIndent = facts.indent[s]
      var k = s + 1
      while k < e {
        if facts.depth[k] == base, facts.first[k], facts.indent[k] == lineIndent, unit.startsLine(k) { last = k }
        if facts.depth[k] == base, unit.isByte(k, 0x3B), k + 1 < e { last = k + 1 }
        k += 1
      }
      s = last
    }
    while e > s, unit.isByte(e - 1, 0x3B) { e -= 1 }
    // An `end` marker after it.
    var k = s
    while k < e {
      if facts.first[k], k > s, unit.isToken(k, "end"), facts.depth[k] == facts.depth[s] {
        e = k
        break
      }
      k += 1
    }
    guard s < e else { return .unknown }
    let w = facts.names[s]
    if w == ScalaWord.ifWord || w == ScalaWord.whileWord || w == ScalaWord.tryWord || w == ScalaWord.forWord || w == ScalaWord.throwWord || w == ScalaWord.returnWord
      || w == ScalaWord.val || w == ScalaWord.varWord || w == ScalaWord.def || w == ScalaWord.importWord
    {
      return .unknown
    }
    // Infix operators at the top level: left to right, an operator ending in `:` taken from the right.
    let base = facts.depth[s]
    var operators: [Int] = []
    k = s
    while k < e {
      if facts.depth[k] == base, k > s, unit.tokens[k].kind == .punctuation, facts.names[k] != 0, !unit.isToken(k, "."), !unit.isToken(k, "@") {
        if unit.isToken(k, "=") || unit.isToken(k, "=>") || unit.isToken(k, "<-") || unit.isToken(k, ":") { return .unknown }
        operators.append(k)
      }
      if facts.depth[k] == base, k > s, unit.isToken(k, "match") { return .unknown }
      k += 1
    }
    if operators.isEmpty {
      return expressionType(unitIndex, endingAt: e - 1)
    }
    // A prefix operator `-x`, `!b`.
    if operators.first == s { return .unknown }
    let firstOp = operators[0]
    if unit.source.text[unit.tokens[firstOp].end - 1] == 0x3A { return .unknown }
    var value = expressionType(unitIndex, endingAt: firstOp - 1)
    for (n, op) in operators.enumerated() {
      let operandEnd = n + 1 < operators.count ? operators[n + 1] : e
      let ty = memberSites(of: value, facts.names[op], unitIndex: unitIndex, at: op)
      if ty.isEmpty {
        // Comparisons and equality are Booleans whatever they compare.
        if ["==", "!=", "<", ">", "<=", ">=", "&&", "||"].contains(unit.string(op)) {
          value = scalaInstance("Boolean")
          continue
        }
        return .unknown
      }
      _ = operandEnd
      value = applied(value, sites: ty, unitIndex: unitIndex, callee: op, groups: [])
      if value == .unknown { return .unknown }
    }
    return value
  }

  // MARK: Lambdas and patterns

  /// The parameters a call gives a lambda argument: the function type its parameter expects, as far as the callee and
  /// the earlier arguments tell.
  func lambdaParameterType(_ ref: DeclRef) -> Ty {
    let local = info(ref)
    guard local.lambdaStart >= 0, let facts = file(ref.unit) else { return .unknown }
    let unit = project.units[Int(ref.unit)]
    let start = Int(local.lambdaStart)
    // The bracket the lambda is an argument of: `f(x => …)`, `f { x => … }`, `f(_.x)`.
    guard let open = unit.matchingOpenBefore(start) ?? (unit.isByte(start - 1, 0x7B) ? start - 1 : nil) else { return .unknown }
    var bracket = open
    if unit.isByte(open, 0x28), unit.isByte(open + 1, 0x7B) == false {
      // fine
    }
    // `xs.map { x => … }`: the brace is the argument; `xs.map(x => …)`: the parenthesis.
    if unit.isByte(bracket, 0x7B), bracket > 0, unit.isByte(bracket - 1, 0x28) { bracket -= 1 }
    let argumentIndex: Int
    if unit.isByte(bracket, 0x28) {
      var index = 0
      for (n, part) in arguments(ref.unit, open: bracket).enumerated() where part.0 <= start && start < part.1 { index = n }
      argumentIndex = index
    } else {
      argumentIndex = 0
    }
    guard let expected = expectedParameterType(ref.unit, open: bracket, argument: argumentIndex) else { return .unknown }
    _ = facts
    switch expected {
    case .function(let params, _):
      let index = Int(local.lambdaIndex)
      if index < params.count { return params[index] }
      // `{ case (a, b) => … }` reads one tuple.
      return .unknown
    default:
      return .unknown
    }
  }

  /// The type a call's parameter expects at an argument of the group at `open`.
  func expectedParameterType(_ unitIndex: Int32, open: Int, argument: Int) -> Ty? {
    guard let facts = file(unitIndex) else { return nil }
    let unit = project.units[Int(unitIndex)]
    // Back over earlier groups to the callee.
    var groups: [Int] = [open]
    var k = open - 1
    while k >= 0, unit.tokens[k].kind == .close, facts.match[k] >= 0 {
      groups.insert(Int(facts.match[k]), at: 0)
      k = Int(facts.match[k]) - 1
    }
    guard k >= 0, unit.tokens[k].kind == .identifier || unit.tokens[k].kind == .punctuation && facts.names[k] != 0 else { return nil }
    let callee = k
    var receiver = Ty.unknown
    var sites: [Site]
    if unit.tokens[callee].kind == .punctuation {
      // An operator: `xs :+ (x => …)`; rare enough to leave.
      return nil
    }
    if callee >= 2, unit.isByte(callee - 1, 0x2E) {
      receiver = expressionType(unitIndex, endingAt: callee - 2)
      sites = memberSites(of: receiver, facts.names[callee], unitIndex: unitIndex, at: callee)
    } else if let before = infixReceiverEnd(unitIndex, callee), unit.isByte(open, 0x7B) || unit.isByte(open, 0x28) {
      receiver = expressionType(unitIndex, endingAt: before)
      sites = memberSites(of: receiver, facts.names[callee], unitIndex: unitIndex, at: callee)
    } else {
      sites = resolveName(unitIndex, callee, facts.names[callee], want: .term)
    }
    var methods: [DeclRef] = sites.compactMap { if case .decl(let ref) = $0, decl(ref).kind == .function, !isJava(ref) { return ref } else { return nil } }
    if methods.isEmpty {
      // An object's or a value's `apply`.
      for site in sites {
        guard case .decl(let ref) = site else { continue }
        if isObject(ref) { methods = templateMembers(ref, ScalaWord.apply).filter { decl($0).kind == .function } }
      }
    }
    // Which list, skipping type arguments.
    let callGroups = groups.filter { !unit.isByte($0, 0x5B) }
    let listIndex = callGroups.firstIndex(of: open) ?? 0
    var candidates: [Ty] = []
    for method in methods.prefix(6) {
      let item = decl(method)
      let lists = info(method).lists
      guard listIndex < lists.count else { continue }
      if listIndex == 0, unit.isByte(open, 0x28), !accepts(method, arguments(unitIndex, open: open).count) { continue }
      var start = Int(item.paramStart)
      for size in lists.prefix(listIndex) { start += Int(size) }
      let size = Int(lists[listIndex])
      guard size > 0 else { continue }
      let holder = self.unit(method)
      var param = holder.params[start + min(argument, size - 1)]
      if argument >= size, param.variadic == false { continue }
      if argument < size { param = holder.params[start + argument] }
      guard param.typeStart >= 0 else { continue }
      var map: [Name: Ty] = [:]
      if let owner = enclosingClass(method), case .nominal(_, let args)? = asSupertype(receiver, owner) { map = parameterMap(owner, args) }
      // The method's own generics bound from earlier groups' arguments.
      let own = Set((0..<Int(item.genericCount)).map { holder.generics[Int(item.genericStart) + $0].name })
      var bindings: [Name: Ty] = [:]
      if !own.isEmpty, listIndex > 0 {
        var p = Int(item.paramStart)
        for (n, group) in callGroups.prefix(listIndex).enumerated() where n < lists.count {
          for (a, part) in arguments(unitIndex, open: group).enumerated() where a < Int(lists[n]) {
            let earlier = holder.params[p + a]
            guard earlier.typeStart >= 0 else { continue }
            let pattern = substitute(readType(method.unit, Int(earlier.typeStart), Int(earlier.typeEnd), scope: Int(item.nameToken)), map)
            unify(pattern, rangeType(unitIndex, part.0, part.1), own, &bindings)
          }
          p += Int(lists[n])
        }
      }
      var ty = substitute(substitute(readType(method.unit, Int(param.typeStart), Int(param.typeEnd), scope: Int(item.nameToken)), map), bindings)
      if param.variadic, case .nominal(_, let args) = ty, let element = args.first { ty = element }
      candidates.append(eraseParams(ty, own))
    }
    guard let first = candidates.first, candidates.allSatisfy({ $0 == first }) else { return nil }
    return first
  }

  /// A lambda argument's body type, its parameters typed: `x => body`, `(a, b) => body`, `_.name`, `{ x => … }`.
  func lambdaBodyType(_ unitIndex: Int32, _ start: Int, _ end: Int, parameters: [Ty]) -> Ty? {
    guard let facts = file(unitIndex), depth < 40 else { return nil }
    let unit = project.units[Int(unitIndex)]
    var s = start
    var e = end
    if unit.isByte(s, 0x7B), facts.match[s] == Int32(e - 1) {
      s += 1
      e -= 1
    }
    // Its arrow at the top level.
    var arrow = -1
    var k = s
    while k < e {
      if facts.depth[k] == facts.depth[s], unit.isToken(k, "=>") {
        arrow = k
        break
      }
      if unit.isToken(k, "case") { return nil }
      k += 1
    }
    if arrow >= 0 {
      // The parameters are typed from the call already (`lambdaParameterType`).
      return rangeType(unitIndex, arrow + 1, e)
    }
    // Placeholders: the argument itself.
    var hasPlaceholder = false
    for p in s..<e where facts.names[p] == ScalaWord.underscore && facts.declAt[Int32(p)] != nil { hasPlaceholder = true }
    guard hasPlaceholder else {
      // A function value or method reference: `map(f)`.
      if case .function(_, let result) = rangeType(unitIndex, s, e) { return result }
      return nil
    }
    return rangeType(unitIndex, s, e)
  }

  /// `x <- source`: what the source yields, from its `foreach` (or `map`, `flatMap`) parameter's function type.
  func generatorBindingType(_ ref: DeclRef) -> Ty {
    let local = info(ref)
    guard local.sourceStart >= 0 else { return .unknown }
    let source = rangeType(ref.unit, Int(local.sourceStart), Int(local.sourceEnd))
    guard let element = elementType(source) else { return .unknown }
    return bindingType(ref, whole: element)
  }

  /// What a container's `foreach` hands its function.
  func elementType(_ ty: Ty) -> Ty? {
    for word in [name("foreach"), name("map")] {
      for entry in memberEntries(of: ty, word) {
        let item = decl(entry.ref)
        guard item.paramCount > 0, !isJava(entry.ref) else { continue }
        let param = self.unit(entry.ref).params[Int(item.paramStart)]
        guard param.typeStart >= 0 else { continue }
        let pattern = substitute(readType(entry.ref.unit, Int(param.typeStart), Int(param.typeEnd), scope: Int(item.nameToken)), entry.substitution)
        if case .function(let params, _) = pattern, let first = params.first { return first }
      }
    }
    return nil
  }

  /// A `case` binding: the scrutinee's type (or what a lambda's case gets) narrowed by the pattern.
  func patternBindingType(_ ref: DeclRef) -> Ty {
    let local = info(ref)
    guard local.patternStart >= 0, let facts = file(ref.unit) else { return .unknown }
    let unit = project.units[Int(ref.unit)]
    let caseToken = Int(local.patternStart) - 1
    var whole: Ty = .unknown
    if local.sourceStart >= 0 {
      // `val (a, b) = …`.
      let item = decl(ref)
      whole = rangeType(ref.unit, Int(local.sourceStart), Int(item.end > item.first ? regionEnd(ref.unit, Int(local.sourceStart)) : Int(local.sourceStart) + 1))
    } else if unit.isToken(caseToken, "case"), let open = unit.matchingOpenBefore(caseToken), unit.isByte(open, 0x7B) {
      if open > 0, unit.isToken(open - 1, "match") {
        whole = expressionType(ref.unit, endingAt: open - 2)
      } else {
        // `xs.map { case … }`: the function's single parameter.
        var bracket = open
        if bracket > 0, unit.isByte(bracket - 1, 0x28) { bracket -= 1 }
        if case .function(let params, _)? = expectedParameterType(ref.unit, open: bracket, argument: 0) {
          whole = params.count == 1 ? params[0] : tupleType(params)
        }
      }
    } else if unit.isToken(caseToken, "case") {
      // Indented `match` cases: the `match` above at a lower indentation.
      var k = caseToken - 1
      while k > 0, !(unit.isToken(k, "match") && facts.depth[k] == facts.depth[caseToken]) {
        if facts.first[k], facts.indent[k] < facts.indent[caseToken], !unit.isToken(k, "case") {
          // The line that holds `match`.
          var m = k
          while m < caseToken, !unit.isToken(m, "match") { m += 1 }
          if m < caseToken { k = m }
          break
        }
        k -= 1
      }
      if unit.isToken(k, "match") { whole = expressionType(ref.unit, endingAt: k - 1) }
    }
    guard whole != .unknown else { return .unknown }
    return bindingType(ref, whole: whole)
  }

  func regionEnd(_ unitIndex: Int32, _ i: Int) -> Int {
    guard let facts = file(unitIndex) else { return i + 1 }
    let unit = project.units[Int(unitIndex)]
    var k = i + 1
    while k < unit.tokens.count, !(facts.first[k] && facts.depth[k] <= facts.depth[i]) { k += 1 }
    return k
  }

  /// Where a binding sits in its pattern: the whole (`case x =>`), a tuple's part, an extractor's argument.
  func bindingType(_ ref: DeclRef, whole: Ty) -> Ty {
    let local = info(ref)
    guard let facts = file(ref.unit) else { return .unknown }
    let unit = project.units[Int(ref.unit)]
    let token = Int(decl(ref).nameToken)
    var ty = whole
    // The brackets from the pattern's start down to the binding: each a tuple or an extractor.
    var path: [(open: Int, index: Int)] = []
    var k = token
    while let open = unit.matchingOpenBefore(k), open >= Int(local.patternStart) {
      var index = 0
      for (n, part) in arguments(ref.unit, open: open).enumerated() where part.0 <= token && token < part.1 { index = n }
      path.insert((open, index), at: 0)
      k = open
    }
    _ = facts
    for step in path {
      let before = step.open - 1
      if unit.isByte(step.open, 0x28), before >= 0, unit.tokens[before].kind == .identifier, before >= Int(local.patternStart) {
        // `Foo(a, b)`: Foo's parameters, its generics bound from the scrutinee.
        // `Status.Done(n)`: the qualified extractor.
        var words = [before]
        while words[0] - 2 >= Int(local.patternStart), unit.isByte(words[0] - 1, 0x2E), unit.tokens[words[0] - 2].kind == .identifier { words.insert(words[0] - 2, at: 0) }
        let site =
          words.count > 1
          ? typeSite(ref.unit, words, scope: before)
          : preferByPosition(ref.unit, before, resolveName(ref.unit, before, word(ref.unit, before), want: .any)).first
        var target: DeclRef?
        if case .decl(let found)? = site {
          if isObject(found), let cls = companion(of: found) { target = cls } else if decl(found).kind.isNominal || decl(found).kind == .enumCase { target = found }
        }
        guard let cls = target else { return .unknown }
        let params = classParams(cls).filter { info($0).listIndex == 0 }
        guard step.index < params.count, decl(params[step.index]).typeStart >= 0 else { return .unknown }
        let item = decl(cls)
        let holder = self.unit(cls)
        let own = Set((0..<Int(item.genericCount)).map { holder.generics[Int(item.genericStart) + $0].name })
        var bindings: [Name: Ty] = [:]
        if !own.isEmpty, case .nominal(let scrutinee, _) = ty {
          let pattern = Ty.nominal(cls, (0..<Int(item.genericCount)).map { .param(holder.generics[Int(item.genericStart) + $0].name, nil) })
          if let lifted = asSupertype(pattern, scrutinee) { unify(lifted, ty, own, &bindings) }
        }
        let param = decl(params[step.index])
        ty = eraseParams(substitute(readType(cls.unit, Int(param.typeStart), Int(param.typeEnd), scope: Int(param.nameToken)), bindings), own)
      } else if unit.isByte(step.open, 0x28) {
        // `(a, b)`: a tuple's element.
        guard case .nominal(let tuple, let args) = memberBase(ty), Self.tupleNames.contains(decl(tuple).name), step.index < args.count else { return .unknown }
        ty = args[step.index]
      } else {
        return .unknown
      }
    }
    return ty
  }
}
