import CodeModel
import CodeScan
import Foundation

/// Types as far as members need them: a struct, union, class or Objective-C class (`nominal`, at its definition),
/// pointers and arrays (`Ty.pointer`), a function's result (`function`); everything else is unknown, and nothing on it
/// is answered.
extension CModel {
  // MARK: Types of declarations

  func typeOf(_ ref: DeclRef) -> Ty {
    if let known = valueTypes[ref] { return known }
    guard ref.decl >= 0, !resolving.contains(ref), depth < 24 else { return .unknown }
    resolving.insert(ref)
    depth += 1
    defer {
      resolving.remove(ref)
      depth -= 1
    }
    let holder = unit(ref)
    let item = decl(ref)
    var type: Ty = .unknown
    switch item.kind {
    case .structure, .classType, .enumeration, .protocolType:
      type = .nominal(definition(ref), [])
    case .extensionDecl:
      type = .nominal(ref, [])
    case .enumCase:
      if item.parent >= 0 { type = .nominal(DeclRef(unit: ref.unit, decl: item.parent), []) }
    case .function, .initializer, .deinitializer, .variable, .typeAlias:
      if item.parent >= 0, isObjCContainer(holder, item.parent), item.kind == .function {
        // A method's result, `(Type)` before its selector.
        type = item.typeStart >= 0 ? typeFromTokens(ref.unit, Int(item.typeStart), Int(item.typeEnd), name: -1) : .unknown
        if isInstancetype(holder, item) { type = .constructed(Ty.pointer, [.nominal(DeclRef(unit: ref.unit, decl: item.parent), [])]) }
      } else if let declarator = holder.cFile.declarators[ref.decl] {
        type = typeFromTokens(ref.unit, Int(item.typeStart), Int(item.typeEnd), name: Int(item.nameToken), declarator: (Int(declarator.prefix), Int(declarator.suffixEnd)))
      } else if item.typeStart >= 0 {
        type = typeFromTokens(ref.unit, Int(item.typeStart), Int(item.typeEnd), name: -1)
      }
      if item.kind == .function || item.kind == .initializer, case .function(_, let result) = type { type = result }
    default:
      break
    }
    valueTypes[ref] = type
    return type
  }

  func isInstancetype(_ unit: Unit, _ item: Decl) -> Bool {
    item.typeStart >= 0 && item.typeEnd == item.typeStart + 1 && unit.isToken(Int(item.typeStart), "instancetype")
  }

  /// A struct's, class's or enum's definition: the declaration with a body, of the same entity.
  func definition(_ ref: DeclRef) -> DeclRef {
    if decl(ref).bodyOpen >= 0 || isObjC(unit(ref), ref.decl) { return ref }
    return redeclarations(ref).first { decl($0).bodyOpen >= 0 } ?? ref
  }

  /// A type from its specifiers (`start..<end`) and declarator: `struct node *`, `const char **`, `Foo<int>&`.
  func typeFromTokens(_ unitIndex: Int32, _ start: Int, _ end: Int, name: Int, declarator: (Int, Int)? = nil) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var base: Ty = .unknown
    var pointers = 0
    var isFunction = false
    var i = start
    var sawBase = false
    while i < end, i < unit.tokens.count {
      if i == name {
        i += 1
        continue
      }
      if unit.tokens[i].kind == .directive {
        i = Int(unit.cFile.ends[Int32(i)] ?? Int32(i + 1))
        continue
      }
      if unit.isWord(i) {
        let word = unit.hash(i)
        if word == CWord.structWord || word == CWord.unionWord || word == CWord.enumWord || (word == CWord.classWord && unit.cFile.dialect.contains(.cpp)) {
          sawBase = true
          if unit.isByte(i + 1, 0x7B) || (unit.isWord(i + 1) && unit.isByte(i + 2, 0x7B)) {
            // Declared here: `struct { … } x`.
            if let index = unit.decls.firstIndex(where: { $0.first == Int32(i) && $0.kind.isNominal }) { base = .nominal(DeclRef(unit: unitIndex, decl: Int32(index)), []) }
            i = unit.skipBalanced(unit.isByte(i + 1, 0x7B) ? i + 1 : i + 2)
            continue
          }
          if unit.isWord(i + 1) {
            let found = lookup(unit.hash(i + 1), unitIndex: unitIndex, token: i + 1, tag: true)
            if let first = found.first(where: { $0.decl >= 0 && decl($0).kind.isNominal }) {
              base = .nominal(definition(first), [])
            } else {
              // A tag this file only names (`typedef struct x x;`): its definition elsewhere.
              indexEntities()
              let key = CModel.mix(CModel.mix(0, unit.hash(i + 1)), Family.type.rawValue)
              if let defined = (entities[key] ?? []).first(where: { decl($0).bodyOpen >= 0 }) { base = .nominal(defined, []) }
            }
            i += 2
            continue
          }
          i += 1
          continue
        }
        if CWord.typeKeywords.contains(word) || CWord.qualifiers.contains(word) || CWord.storage.contains(word) || word == CWord.typenameWord {
          if CWord.typeKeywords.contains(word) { sawBase = true }
          i += 1
          continue
        }
        if CWord.attributes.contains(word) || CWord.typeofWords.contains(word) {
          i = unit.isByte(i + 1, 0x28) ? unit.skipBalanced(i + 1) : i + 1
          continue
        }
        if unit.tokens[i].kind == .identifier, !sawBase {
          // A name, maybe qualified, maybe with template arguments.
          var last = i
          var j = i + 1
          while unit.isToken(j, "::"), unit.isWord(j + 1) {
            last = j + 1
            j += 2
          }
          if unit.startsWith(j, 0x3C) {
            var depth = 0
            while j < end {
              if unit.startsWith(j, 0x3C) { depth += unit.isToken(j, "<<") ? 2 : 1 }
              if unit.tokens[j].kind == .punctuation, unit.startsWith(j, 0x3E) {
                depth -= unit.startsWith(j, 0x3E) && unit.tokens[j].length > 1 && unit.source.text[unit.tokens[j].start + 1] == 0x3E ? 2 : 1
                if depth <= 0 {
                  j += 1
                  break
                }
              }
              j += 1
            }
          }
          // `API_EXPORT` before the type is an attribute, but `LIBSSH2_CHANNEL *` names one.
          let named = sawBase && unit.isMacroLike(last) ? Ty.unknown : namedType(unitIndex: unitIndex, first: i, last: last)
          if unit.isMacroLike(last), !(last == i && j >= end), case .unknown = named {
            i = j
            continue
          }
          sawBase = true
          base = named
          i = j
          continue
        }
        i += 1
        continue
      }
      if unit.tokens[i].kind == .punctuation {
        let token = unit.tokens[i]
        for k in 0..<token.length where unit.source.text[token.start + k] == 0x2A || unit.source.text[token.start + k] == 0x5E { pointers += 1 }
        i += 1
        continue
      }
      if unit.isByte(i, 0x28) {
        // A function pointer's `(*name)`, then its parameters.
        let close = unit.skipBalanced(i) - 1
        if name > i, name < close || unit.startsWith(i + 1, 0x2A) || unit.startsWith(i + 1, 0x5E) { isFunction = true }
        i = close + 1
        continue
      }
      if unit.isByte(i, 0x5B) {
        pointers += 1
        i = unit.skipBalanced(i)
        continue
      }
      i += 1
    }
    if let declarator {
      var k = declarator.0
      while k < declarator.1, k < unit.tokens.count {
        if k == name {
          k += 1
          continue
        }
        if unit.isByte(k, 0x28) {
          let close = unit.skipBalanced(k) - 1
          if name > k, name < close {
            // `(*name)(…)`: a pointer to what follows.
            isFunction = unit.isByte(close + 1, 0x28)
            if !isFunction {
              for m in (k + 1)..<close where unit.startsWith(m, 0x2A) { pointers += 1 }
            }
          } else if k > name {
            isFunction = true
          }
          k = close + 1
          continue
        }
        if unit.isByte(k, 0x5B) {
          pointers += 1
          k = unit.skipBalanced(k)
          continue
        }
        if unit.tokens[k].kind == .punctuation, k < name {
          let token = unit.tokens[k]
          for m in 0..<token.length where unit.source.text[token.start + m] == 0x2A || unit.source.text[token.start + m] == 0x5E { pointers += 1 }
        }
        k += 1
      }
    }
    var type = base
    if isFunction { return .function([], wrap(type, pointers)) }
    type = wrap(type, pointers)
    return type
  }

  private func wrap(_ type: Ty, _ pointers: Int) -> Ty {
    var result = type
    for _ in 0..<min(pointers, 8) { result = .constructed(Ty.pointer, [result]) }
    return result
  }

  /// A type's name at `first…last` (qualified when they differ): a typedef's type, a class, a template parameter.
  func namedType(unitIndex: Int32, first: Int, last: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let found: [DeclRef]
    if first == last {
      found = lookup(unit.hash(first), unitIndex: unitIndex, token: first, tag: false)
    } else {
      found = qualified(unitIndex: unitIndex, token: last).compactMap { if case .decl(let ref) = $0 { return ref } else { return nil } }
    }
    for ref in found where ref.decl >= 0 {
      let item = decl(ref)
      switch item.kind {
      case .typeAlias: return typeOf(ref)
      case .structure, .classType, .enumeration, .protocolType: return .nominal(definition(ref), [])
      default: continue
      }
    }
    return .unknown
  }

  // MARK: Members

  /// The type a member's body or a class's body is in: a C++ class, an out-of-line definition's class, an Objective-C
  /// container's class.
  func enclosingType(unitIndex: Int32, holder: Int32) -> Ty? {
    guard depth < 24 else { return nil }
    depth += 1
    defer { depth -= 1 }
    let unit = project.units[Int(unitIndex)]
    let item = unit.decls[Int(holder)]
    let file = unit.cFile
    switch item.kind {
    case .structure, .classType, .protocolType:
      guard file.dialect.contains(.cpp) || isObjC(unit, holder) else { return nil }
      return .nominal(DeclRef(unit: unitIndex, decl: holder), [])
    case .extensionDecl:
      if isObjC(unit, holder) { return .nominal(DeclRef(unit: unitIndex, decl: holder), []) }
      guard item.typeStart >= 0 else { return nil }
      var last = Int(item.typeEnd) - 1
      while last > Int(item.typeStart), !unit.isWord(last) {
        // Back past template arguments to the class's name.
        if unit.tokens[last].kind == .punctuation, unit.source.text[unit.tokens[last].end - 1] == 0x3E {
          var depth = 0
          while last > Int(item.typeStart) {
            if unit.tokens[last].kind == .punctuation, unit.source.text[unit.tokens[last].end - 1] == 0x3E { depth += 1 }
            if unit.startsWith(last, 0x3C) {
              depth -= 1
              if depth == 0 { break }
            }
            last -= 1
          }
        }
        last -= 1
      }
      let type = namedType(unitIndex: unitIndex, first: Int(item.typeStart), last: last)
      if case .nominal = type { return type }
      return nil
    default:
      return nil
    }
  }

  /// The declarations that make a type: a class's definition, an Objective-C class's @interface, categories and
  /// @implementation.
  func parts(of ref: DeclRef) -> [DeclRef] {
    let holder = unit(ref)
    let item = decl(ref)
    guard isObjC(holder, ref.decl) else { return [definition(ref)] }
    var result: [DeclRef] = []
    indexEntities()
    let classKey = CModel.mix(CModel.mix(0, item.name), Family.objcClass.rawValue)
    if item.kind == .protocolType {
      let key = CModel.mix(CModel.mix(0, item.name), Family.protocolType.rawValue)
      return entities[key] ?? [ref]
    }
    result += entities[classKey] ?? []
    for u in 0..<project.units.count {
      // Categories and class extensions, wherever they are.
      let other = project.units[u]
      for index in other.cFile.tags[item.name] ?? [] where other.decls[Int(index)].kind == .extensionDecl { result.append(DeclRef(unit: Int32(u), decl: index)) }
    }
    result += (project.extensions[item.name] ?? []).filter { isObjC(unit($0), $0.decl) }
    if !result.contains(ref) { result.append(ref) }
    var unique: [DeclRef] = []
    for part in result where !unique.contains(part) { unique.append(part) }
    return unique
  }

  /// Members of a type named `word`, its bases' and protocols' too, nearest first.
  func members(of type: Ty, named word: Name, from unitIndex: Int32, includeStatic: Bool) -> [DeclRef] {
    var found: [DeclRef] = []
    var visited: Set<DeclRef> = []
    collectMembers(of: type, from: unitIndex, into: &visited) { ref in
      if decl(ref).name == word { found.append(ref) }
      return !found.isEmpty
    }
    return found
  }

  /// Calls `visit` with every member of a type, nearest first, until it returns true.
  func collectMembers(of type: Ty, from unitIndex: Int32, into visited: inout Set<DeclRef>, _ visit: (DeclRef) -> Bool) {
    guard case .nominal(let start, _) = type, visited.insert(start).inserted, visited.count < 64 else { return }
    let all = parts(of: start)
    var stop = false
    for part in all {
      let holder = unit(part)
      if eachChild(of: part.decl, in: holder, unitIndex: part.unit, visit) {
        stop = true
        break
      }
    }
    if stop { return }
    // Bases, superclass and protocols.
    for part in all {
      let holder = unit(part)
      let item = decl(part)
      for b in 0..<Int(item.inheritCount) {
        let range = holder.ranges[Int(item.inheritStart) + b]
        var last = Int(range.end) - 1
        while last > Int(range.start), !holder.isWord(last) { last -= 1 }
        var first = Int(range.start)
        while first < last, !holder.isWord(first) || holder.isToken(first, "public") || holder.isToken(first, "private") || holder.isToken(first, "protected") || holder.isToken(first, "virtual") {
          first += 1
        }
        guard holder.isWord(last) else { continue }
        var base: Ty
        if isObjC(holder, part.decl) {
          let found = fileScope(holder.hash(last), unitIndex: part.unit, tag: false).filter { [.classType, .protocolType].contains(decl($0).kind) }
          base = found.first.map { .nominal($0, []) } ?? .unknown
          if case .unknown = base, let any = (entities[CModel.mix(CModel.mix(0, holder.hash(last)), Family.objcClass.rawValue)] ?? entities[CModel.mix(CModel.mix(0, holder.hash(last)), Family.protocolType.rawValue)])?.first {
            base = .nominal(any, [])
          }
        } else {
          base = namedType(unitIndex: part.unit, first: first, last: last)
        }
        var found = false
        collectMembers(of: base, from: unitIndex, into: &visited) { ref in
          found = visit(ref)
          return found
        }
        if found { return }
      }
    }
  }

  /// A declaration's children, an anonymous struct's or union's flattened into it.
  private func eachChild(of parent: Int32, in holder: Unit, unitIndex: Int32, _ visit: (DeclRef) -> Bool) -> Bool {
    for child in holder.children(of: parent) {
      let item = holder.decls[Int(child)]
      if item.isLocal { continue }
      if item.name == 0, item.kind == .structure || item.kind == .classType, holder.cFile.has(child, .transparent) {
        if eachChild(of: child, in: holder, unitIndex: unitIndex, visit) { return true }
        continue
      }
      if visit(DeclRef(unit: unitIndex, decl: child)) { return true }
      if item.kind == .enumeration, !holder.cFile.has(child, .scoped) {
        // An unscoped enum's constants are its class's.
        if eachChild(of: child, in: holder, unitIndex: unitIndex, visit) { return true }
      }
    }
    return false
  }

  // MARK: Expressions

  func deref(_ type: Ty) -> Ty {
    if case .constructed(let constructor, let inner) = type, constructor == Ty.pointer, let first = inner.first { return first }
    return type
  }

  /// The type of the expression that ends at `end` (a member access's left side): names, calls, subscripts,
  /// members, parentheses, casts, `this`, `self`.
  func exprType(unitIndex: Int32, end: Int) -> Ty {
    guard depth < 24, end >= 0 else { return .unknown }
    depth += 1
    defer { depth -= 1 }
    let unit = project.units[Int(unitIndex)]
    if unit.tokens[end].kind == .close {
      guard let open = unit.matchingOpen(end) else { return .unknown }
      if unit.isByte(end, 0x5D) {
        if isMessage(unit, open) { return messageType(unitIndex: unitIndex, open: open) }
        return deref(exprType(unitIndex: unitIndex, end: open - 1))
      }
      if unit.isByte(end, 0x29) {
        if open > 0, unit.isWord(open - 1) || unit.tokens[open - 1].kind == .close || unit.startsWith(open - 1, 0x3E) {
          // A call: the callee's result.
          if unit.isWord(open - 1), unit.tokens[open - 1].kind == .keyword { return .unknown }
          let callee = exprType(unitIndex: unitIndex, end: open - 1)
          if case .function(_, let result) = callee { return result }
          if case .constructed(_, let inner) = callee, case .function(_, let result)? = inner.first { return result }
          return callee
        }
        // `(T *)x` is a cast when a type is inside; else `(expr)`.
        if let cast = castType(unitIndex: unitIndex, open: open, close: end) { return cast }
        return parenthesized(unitIndex: unitIndex, open: open, close: end)
      }
      return .unknown
    }
    guard unit.isWord(end) else { return .unknown }
    let word = unit.hash(end)
    if unit.isToken(end, "this") || unit.isToken(end, "self") {
      for index in unit.chain(at: Int32(end)).reversed() {
        if let type = enclosingType(unitIndex: unitIndex, holder: index) { return .constructed(Ty.pointer, [type]) }
      }
      return .unknown
    }
    if end > 0, unit.isByte(end - 1, 0x2E) || unit.isToken(end - 1, "->") {
      var operand = exprType(unitIndex: unitIndex, end: end - 2)
      operand = deref(operand)
      let found = members(of: operand, named: word, from: unitIndex, includeStatic: true)
      return found.first.map { typeOfFound($0) } ?? .unknown
    }
    if end > 0, unit.isToken(end - 1, "::") {
      if let first = qualified(unitIndex: unitIndex, token: end).first, case .decl(let ref) = first { return typeOfFound(ref) }
      return .unknown
    }
    if let body = body(unitIndex: unitIndex, token: Int32(end)), let local = body.local(named: word, at: Int32(end)) {
      return typeOfLocal(local, unitIndex: unitIndex)
    }
    let found = lookup(word, unitIndex: unitIndex, token: end, tag: false)
    guard let first = found.first(where: { $0.decl >= 0 }) else { return .unknown }
    return typeOfFound(first)
  }

  /// A found declaration as a value: a function is its result's callee, a type is itself (a constructor's call).
  func typeOfFound(_ ref: DeclRef) -> Ty {
    let item = decl(ref)
    if item.kind == .function || item.kind == .initializer {
      let result = typeOf(ref)
      return .function([], result)
    }
    return typeOf(ref)
  }

  func typeOfLocal(_ local: CLocal, unitIndex: Int32) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var type = typeFromTokens(unitIndex, Int(local.typeStart), Int(local.typeEnd), name: Int(local.token), declarator: (Int(local.declaratorStart), Int(local.declaratorEnd)))
    let isAuto = (Int(local.typeStart)..<Int(local.typeEnd)).contains { unit.isToken($0, "auto") || unit.isToken($0, "__auto_type") || unit.isToken($0, "id") }
    if case .unknown = type, local.initStart >= 0, isAuto || !local.isRangeElement {
      if local.isRangeElement { return .unknown }
      var end = Int(local.initEnd) - 1
      while end > Int(local.initStart), unit.tokens[end].kind == .directive { end -= 1 }
      if unit.isToken(Int(local.initStart), "new"), unit.isWord(Int(local.initStart) + 1) {
        let name = Int(local.initStart) + 1
        return .constructed(Ty.pointer, [namedType(unitIndex: unitIndex, first: name, last: name)])
      }
      if let cast = leadingCast(unitIndex: unitIndex, start: Int(local.initStart)) { return cast }
      if end >= Int(local.initStart) { type = exprType(unitIndex: unitIndex, end: end) }
      if case .function(_, let result) = type { type = result }
    } else if case .constructed(let constructor, let inner) = type, constructor == Ty.pointer, case .unknown? = inner.first, local.initStart >= 0, isAuto {
      // `auto *p = …`.
      let end = Int(local.initEnd) - 1
      if end >= Int(local.initStart) { type = exprType(unitIndex: unitIndex, end: end) }
    }
    return type
  }

  /// `(T *)expr` at the start of an initializer.
  private func leadingCast(unitIndex: Int32, start: Int) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    guard unit.isByte(start, 0x28) else { return nil }
    let close = unit.skipBalanced(start) - 1
    return castType(unitIndex: unitIndex, open: start, close: close)
  }

  /// A cast's type when `(…)` holds a type and is followed by an operand, or is the operand of a member access.
  private func castType(unitIndex: Int32, open: Int, close: Int) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    guard close > open + 1 else { return nil }
    let first = open + 1
    let looksLikeType: Bool
    if unit.isWord(first), unit.isToken(first, "struct") || unit.isToken(first, "union") || unit.isToken(first, "enum") || CWord.typeKeywords.contains(unit.hash(first)) || CWord.qualifiers.contains(unit.hash(first)) {
      looksLikeType = true
    } else if unit.tokens[first].kind == .identifier {
      var k = first + 1
      while k < close, unit.isToken(k, "::") { k += 2 }
      let rest = (k..<close).allSatisfy { unit.tokens[$0].kind == .punctuation && (unit.startsWith($0, 0x2A) || unit.startsWith($0, 0x26)) || unit.isWord($0) && CWord.qualifiers.contains(unit.hash($0)) || unit.startsWith($0, 0x3C) || unit.startsWith($0, 0x3E) || unit.isWord($0) }
      looksLikeType = rest && (k < close || isTypeName(unit.hash(first), unitIndex: unitIndex, token: first))
    } else {
      looksLikeType = false
    }
    guard looksLikeType else { return nil }
    // A cast is followed by its operand; `(x)` alone before `.` is a parenthesized name.
    let next = close + 1
    let followed = next < unit.tokens.count && (unit.isWord(next) || unit.tokens[next].kind == .open || unit.tokens[next].kind == .number || unit.tokens[next].kind == .string || unit.startsWith(next, 0x2A) || unit.startsWith(next, 0x26))
    guard followed || unit.isWord(first) && isTypeName(unit.hash(first), unitIndex: unitIndex, token: first) else { return nil }
    if !followed, close == open + 2 { return nil }
    return typeFromTokens(unitIndex, open + 1, close, name: -1)
  }

  private func parenthesized(unitIndex: Int32, open: Int, close: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard close > open + 1 else { return .unknown }
    // `(*p)`, `(&x)`, `((T *)x)`.
    let first = open + 1
    if unit.isToken(first, "*") { return deref(exprType(unitIndex: unitIndex, end: close - 1)) }
    if unit.isToken(first, "&") { return .constructed(Ty.pointer, [exprType(unitIndex: unitIndex, end: close - 1)]) }
    if unit.isByte(first, 0x28), let inner = unit.matchingOpen(unit.skipBalanced(first) - 1), inner == first, let cast = castType(unitIndex: unitIndex, open: first, close: unit.skipBalanced(first) - 1) {
      return cast
    }
    return exprType(unitIndex: unitIndex, end: close - 1)
  }

  /// `x.name` or `x->name`.
  func memberAccess(unitIndex: Int32, token: Int) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    let word = unit.hash(token)
    guard token >= 2 else { return [] }
    // A designated initializer's `.name`.
    if unit.isByte(token - 1, 0x2E), unit.isByte(token - 2, 0x7B) || unit.isByte(token - 2, 0x2C) || unit.isByte(token - 2, 0x5B) {
      return designated(unitIndex: unitIndex, token: token)
    }
    let operand = deref(exprType(unitIndex: unitIndex, end: token - 2))
    if case .nominal = operand {
      let found = members(of: operand, named: word, from: unitIndex, includeStatic: true)
      if !found.isEmpty { return resolveFound(found, unitIndex: unitIndex, token: token) }
      return []
    }
    // What couldn't be told: the project's members of that name, as candidates by name. Not in C++, whose receivers
    // are so often the standard library's templates that a project's member of the same name is mostly wrong.
    if unit.cFile.dialect.contains(.cpp) { return [] }
    let found = project.membersNamed(word).filter { decl($0).kind != .enumCase }
    guard !found.isEmpty, found.count <= 12 else { return [] }
    byNameOnly = true
    return found.map { .decl($0) }
  }

  /// `{ .name = … }`: a field of the initialized variable's type.
  private func designated(unitIndex: Int32, token: Int) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    guard let open = unit.matchingOpenBefore(token), unit.isByte(open, 0x7B) else { return [] }
    var type: Ty = .unknown
    if open > 0, unit.isAssign(open - 1) {
      // The variable before `=`.
      let nameToken = open - 2
      if nameToken >= 0, let site = sites(unitIndex: unitIndex, token: nameToken).first {
        switch site {
        case .decl(let ref): type = typeOf(ref)
        case .local(_, let local):
          if let body = body(unitIndex: unitIndex, token: local), let found = body.local(named: unit.hash(Int(local)), at: local) { type = typeOfLocal(found, unitIndex: unitIndex) }
        default: break
        }
      } else if let declared = unit.decls.firstIndex(where: { $0.initStart == Int32(open) }) {
        type = typeOf(DeclRef(unit: unitIndex, decl: Int32(declared)))
      }
    } else if open > 0, unit.isByte(open - 1, 0x29), let cast = unit.matchingOpen(open - 1) {
      // `(struct x){ .a = 1 }`.
      type = typeFromTokens(unitIndex, cast + 1, open - 1, name: -1)
    }
    if let declared = unit.decls.firstIndex(where: { $0.initStart == Int32(open) }), case .unknown = type {
      type = typeOf(DeclRef(unit: unitIndex, decl: Int32(declared)))
    }
    // Arrays of structs: the element.
    while case .constructed(let constructor, let inner) = type, constructor == Ty.pointer, let first = inner.first { type = first }
    let found = members(of: type, named: unit.hash(token), from: unitIndex, includeStatic: false)
    return found.isEmpty ? [] : resolveFound(found, unitIndex: unitIndex, token: token)
  }

  // MARK: Qualified names

  enum QualifierScope {
    case global
    case namespace(UInt64)
    case type(Ty)
    case none
  }

  /// `A::B::name`: the scope the qualifier names, then its member.
  func qualified(unitIndex: Int32, token: Int) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    let word = unit.hash(token)
    var found: [DeclRef] = []
    switch qualifierScope(unitIndex: unitIndex, colons: token - 1) {
    case .global: found = fileScope(word, unitIndex: unitIndex, tag: false)
    case .namespace(let key): found = inNamespace(key, word, unitIndex: unitIndex)
    case .type(let scope):
      found = members(of: scope, named: word, from: unitIndex, includeStatic: true)
      // A class's constructor `A::A`.
      if found.isEmpty, case .nominal(let ref, _) = scope, decl(ref).name == word { found = [ref] }
    case .none: return []
    }
    return found.isEmpty ? [] : resolveFound(found, unitIndex: unitIndex, token: token)
  }

  /// What the qualifier ending at the `::` at `colons` names.
  func qualifierScope(unitIndex: Int32, colons: Int) -> QualifierScope {
    let unit = project.units[Int(unitIndex)]
    // The qualifier's names, outermost first.
    var names: [Int] = []
    var i = colons
    while i >= 1, unit.isToken(i, "::") {
      var k = i - 1
      if unit.tokens[k].kind == .punctuation, unit.source.text[unit.tokens[k].end - 1] == 0x3E {
        var depth = 0
        while k > 0 {
          if unit.tokens[k].kind == .punctuation, unit.source.text[unit.tokens[k].end - 1] == 0x3E { depth += 1 }
          if unit.startsWith(k, 0x3C) {
            depth -= 1
            if depth <= 0 { break }
          }
          k -= 1
        }
        k -= 1
      }
      guard k >= 0, unit.isWord(k) else { break }
      names.insert(k, at: 0)
      i = k - 1
    }
    if names.isEmpty { return .global }
    var scope: Ty?
    var namespaceKey: UInt64?
    // The first name, as a name on its own.
    let first = names[0]
    let firstFound = lookup(unit.hash(first), unitIndex: unitIndex, token: first, tag: false).filter { $0.decl >= 0 }
    if let ref = firstFound.first(where: { decl($0).kind == .namespace }) {
      namespaceKey = namespaceKeyOf(ref)
    } else if let ref = firstFound.first(where: { decl($0).kind.isNominal || decl($0).kind == .typeAlias }) {
      scope = decl(ref).kind == .typeAlias ? typeOf(ref) : .nominal(definition(ref), [])
    } else if unit.isToken(first, "std") {
      // libc++ declares `std` through macros: its names are the file scope's.
      namespaceKey = 0
    } else {
      namespaceKey = CModel.mix(0, unit.hash(first))
    }
    for k in names.dropFirst() {
      let part = unit.hash(k)
      if let key = namespaceKey {
        let found = inNamespace(key, part, unitIndex: unitIndex)
        if let ref = found.first(where: { decl($0).kind == .namespace }) {
          namespaceKey = namespaceKeyOf(ref)
        } else if let ref = found.first(where: { decl($0).kind.isNominal || decl($0).kind == .typeAlias }) {
          namespaceKey = nil
          scope = decl(ref).kind == .typeAlias ? typeOf(ref) : .nominal(definition(ref), [])
        } else {
          namespaceKey = CModel.mix(key, part)
        }
      } else if let current = scope {
        let found = members(of: current, named: part, from: unitIndex, includeStatic: true)
        guard let ref = found.first else { return .none }
        scope = decl(ref).kind == .typeAlias ? typeOf(ref) : .nominal(definition(ref), [])
      }
    }
    if let key = namespaceKey { return key == 0 ? .global : .namespace(key) }
    if let scope { return .type(scope) }
    return .none
  }

  func namespaceKeyOf(_ ref: DeclRef) -> UInt64 {
    let item = decl(ref)
    if file(ref).has(ref.decl, .alias), item.typeStart >= 0 {
      var key: UInt64 = 0
      for word in qualifierWords(unit(ref), Int(item.typeStart), Int(item.typeEnd)) { key = CModel.mix(key, word) }
      return key
    }
    return CModel.mix(scopeKey(unit(ref), ref.decl) ?? 0, item.name)
  }

  /// A namespace's declarations of a name; at key 0, the file scope.
  func inNamespace(_ key: UInt64, _ word: Name, unitIndex: Int32) -> [DeclRef] {
    if key == 0 { return fileScope(word, unitIndex: unitIndex, tag: false) }
    indexEntities()
    let all = (scoped[key] ?? []).filter { decl($0).name == word }
    let seen = all.filter { visible($0, from: unitIndex) }
    return seen.isEmpty ? all : seen
  }

  // MARK: Objective-C messages

  /// Whether `[` at `open` starts a message (`[receiver selector]`), not a subscript or an attribute.
  func isMessage(_ unit: Unit, _ open: Int) -> Bool {
    guard unit.cFile.dialect.contains(.objc), unit.isByte(open, 0x5B) else { return false }
    if open > 0, unit.isWord(open - 1) && unit.tokens[open - 1].kind == .identifier || unit.tokens[open - 1].kind == .close { return false }
    return true
  }

  /// The type a message returns: its method's result, `instancetype` as the receiver's class.
  func messageType(unitIndex: Int32, open: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    let close = unit.skipBalanced(open) - 1
    var piece = close - 1
    while piece > open, !(unit.isWord(piece) && (unit.isByte(piece + 1, 0x3A) || piece + 1 == close)) { piece -= 1 }
    // The first piece of the selector.
    var k = open + 1
    while k < close {
      if unit.tokens[k].kind == .open {
        k = unit.skipBalanced(k)
        continue
      }
      if k > open + 1, unit.isWord(k), unit.isByte(k + 1, 0x3A) || k + 1 == close { break }
      k += 1
    }
    guard k < close, let message = messageSelector(unit, k) else { return .unknown }
    let receiver = receiverType(unitIndex: unitIndex, message: message)
    guard let method = methods(receiver.type, message.selector, isClass: receiver.isClass, from: unitIndex).first else { return .unknown }
    let item = decl(method)
    let methodUnit = project.units[Int(method.unit)]
    if isInstancetype(methodUnit, item) || ["init", "alloc", "new", "copy"].contains(where: { unit.string(k).hasPrefix($0) }) && item.typeStart >= 0 && methodUnit.isToken(Int(item.typeStart), "id") {
      if case .nominal = receiver.type { return .constructed(Ty.pointer, [receiver.type]) }
    }
    return typeOf(method)
  }

  /// A message's receiver: a class (`[NSString string]`), `super`, `self`, or an object's type.
  func receiverType(unitIndex: Int32, message: (open: Int, receiverEnd: Int, selector: Name)) -> (type: Ty, isClass: Bool) {
    let unit = project.units[Int(unitIndex)]
    let end = message.receiverEnd
    if end == message.open + 1, unit.tokens[end].kind == .identifier {
      let word = unit.hash(end)
      let isClassMethod = unit.chain(at: Int32(end)).contains { unit.decls[Int($0)].kind == .function && unit.decls[Int($0)].isStatic && unit.decls[Int($0)].parent >= 0 && isObjCContainer(unit, unit.decls[Int($0)].parent) }
      if unit.isToken(end, "super") || unit.isToken(end, "self") {
        for index in unit.chain(at: Int32(end)).reversed() {
          guard let type = enclosingType(unitIndex: unitIndex, holder: index), case .nominal(let ref, _) = type else { continue }
          if unit.isToken(end, "self") { return (type, isClassMethod) }
          // The superclass: the @interface's first base.
          for part in parts(of: ref) where decl(part).kind == .classType && decl(part).inheritCount > 0 {
            let holder = self.unit(part)
            let range = holder.ranges[Int(decl(part).inheritStart)]
            let found = fileScope(holder.hash(Int(range.start)), unitIndex: part.unit, tag: false).filter { decl($0).kind == .classType }
            if let superclass = found.first { return (.nominal(superclass, []), isClassMethod) }
          }
          return (.unknown, isClassMethod)
        }
      }
      if body(unitIndex: unitIndex, token: Int32(end))?.local(named: word, at: Int32(end)) == nil {
        let found = lookup(word, unitIndex: unitIndex, token: end, tag: false).filter { $0.decl >= 0 }
        if let ref = found.first(where: { decl($0).kind == .classType || decl($0).kind == .typeAlias }) {
          return (decl(ref).kind == .typeAlias ? deref(typeOf(ref)) : .nominal(ref, []), true)
        }
      }
    }
    return (deref(exprType(unitIndex: unitIndex, end: end)), false)
  }

  /// Methods with a selector on a class, its categories, superclasses and protocols.
  func methods(_ type: Ty, _ selector: Name, isClass: Bool, from unitIndex: Int32) -> [DeclRef] {
    var found: [DeclRef] = []
    var fallback: [DeclRef] = []
    var visited: Set<DeclRef> = []
    collectMembers(of: type, from: unitIndex, into: &visited) { ref in
      let item = decl(ref)
      guard item.name == selector else { return false }
      if item.kind == .function, item.isStatic == isClass {
        found.append(ref)
        return true
      }
      // A property's getter or setter.
      if item.kind == .variable || item.kind == .function { fallback.append(ref) }
      return false
    }
    return found.isEmpty ? fallback : found
  }

  func messageSites(unitIndex: Int32, token: Int, message: (open: Int, receiverEnd: Int, selector: Name)) -> [Site] {
    let receiver = receiverType(unitIndex: unitIndex, message: message)
    if case .nominal = receiver.type {
      let found = methods(receiver.type, message.selector, isClass: receiver.isClass, from: unitIndex)
      if !found.isEmpty { return resolveFound(found, unitIndex: unitIndex, token: token) }
      // `[obj setName:x]`: a property's setter.
      let unit = project.units[Int(unitIndex)]
      let text = unit.string(token)
      if text.hasPrefix("set"), text.count > 3 {
        let property = String(text.dropFirst(3)).prefix(1).lowercased() + String(text.dropFirst(4))
        let setter = members(of: receiver.type, named: CodeModel.name(property), from: unitIndex, includeStatic: false).filter { file($0).has($0.decl, .property) }
        if !setter.isEmpty { return resolveFound(setter, unitIndex: unitIndex, token: token) }
      }
      let getter = members(of: receiver.type, named: message.selector, from: unitIndex, includeStatic: false).filter { file($0).has($0.decl, .property) }
      if !getter.isEmpty { return resolveFound(getter, unitIndex: unitIndex, token: token) }
      return []
    }
    // `id` and what couldn't be told: the methods with that selector, by name.
    indexEntities()
    var found: [DeclRef] = []
    for (u, holder) in project.units.enumerated() {
      for (method, _) in holder.cFile.selectors where holder.decls[Int(method)].name == message.selector { found.append(DeclRef(unit: Int32(u), decl: method)) }
    }
    guard !found.isEmpty, found.count <= 12 else { return [] }
    byNameOnly = true
    return found.map { .decl($0) }
  }
}
