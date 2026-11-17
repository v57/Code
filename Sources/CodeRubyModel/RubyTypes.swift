import CodeModel
import CodeScan
import Foundation

/// YARD's tags above a declaration: what the code doesn't say about types.
struct RubyDoc {
  var returns: [String] = []
  /// `@param name [Type]` (or `@param [Type] name`), `@option` aside.
  var params: [String: String] = [:]
  /// `@yieldparam [Type] name`, in order.
  var yields: [String] = []
  /// `@!generics Elem, Key`: a stub class's type parameters.
  var generics: [String] = []
  /// `@yieldsplat`: one array is yielded, its elements as `@yieldparam`s (`Hash#each`'s `|key, value|`).
  var yieldsSplat = false
  var isDeprecated = false

  init(_ lines: [String]) {
    for raw in lines {
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("@") else { continue }
      if line.hasPrefix("@return") {
        if let type = Self.bracketed(line) { returns.append(type) }
      } else if line.hasPrefix("@param") || line.hasPrefix("@yieldparam") {
        let rest = line.drop { $0 != " " }.trimmingCharacters(in: .whitespaces)
        var type: String?
        var nameText = ""
        if rest.hasPrefix("[") {
          type = Self.bracketed(rest)
          let after = rest[(rest.range(of: "]")?.upperBound ?? rest.endIndex)...]
          nameText = String(after.trimmingCharacters(in: .whitespaces).prefix { !$0.isWhitespace })
        } else {
          nameText = String(rest.prefix { !$0.isWhitespace })
          type = Self.bracketed(String(rest.dropFirst(nameText.count)))
        }
        if line.hasPrefix("@yieldparam") {
          yields.append(type ?? "")
        } else if let type {
          params[nameText.trimmingCharacters(in: CharacterSet(charactersIn: "*&:"))] = type
        }
      } else if line.hasPrefix("@!generics") {
        generics = line.dropFirst("@!generics".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      } else if line.hasPrefix("@yieldsplat") {
        yieldsSplat = true
      } else if line.hasPrefix("@deprecated") {
        isDeprecated = true
      }
    }
  }

  /// The text in a tag's first brackets: `[Array<String>, nil]` → `Array<String>, nil`.
  static func bracketed(_ text: String) -> String? {
    guard let open = text.firstIndex(of: "[") else { return nil }
    var depth = 0
    var index = open
    while index < text.endIndex {
      let c = text[index]
      if c == "[" { depth += 1 } else if c == "]" {
        depth -= 1
        if depth == 0 { return String(text[text.index(after: open)..<index]) }
      }
      index = text.index(after: index)
    }
    return nil
  }
}

/// Types: values' from literals, constants, `Foo.new`, locals' and variables' assignments, YARD's tags and Sorbet's
/// `sig`, and methods' last expressions.
extension RubyModel {
  func builtin(_ qualified: String) -> Ty { classRef(qualified).map { .nominal($0, []) } ?? .unknown }

  func doc(_ ref: DeclRef) -> RubyDoc {
    let holder = unit(ref)
    var first = Int(decl(ref).first)
    // `private def x`, `sig { … }` above: the comment above those.
    let line = holder.source.lines.line(of: holder.tokens[first].start)
    while first > 0, holder.source.lines.line(of: holder.tokens[first - 1].start) == line { first -= 1 }
    if let sig = sigStart(holder, first) { first = sig }
    return RubyDoc(holder.rbCommentLines(above: first))
  }

  /// A Sorbet `sig { … }` or `sig do … end` right before a token: its first token.
  func sigStart(_ holder: Unit, _ token: Int) -> Int? {
    let before = token - 1
    guard before > 0 else { return nil }
    if holder.isByte(before, 0x7D), let open = holder.matchingOpen(before), holder.isToken(open - 1, "sig") { return open - 1 }
    if holder.isToken(before, "end") {
      var k = before - 1
      var budget = 400
      while k > 0, budget > 0, !holder.isToken(k, "do") { k -= 1; budget -= 1 }
      if holder.isToken(k - 1, "sig") { return k - 1 }
    }
    return nil
  }

  /// `sig { params(…).returns(T) }`: `T`'s text.
  func sigReturn(_ ref: DeclRef) -> (text: String, token: Int)? {
    let holder = unit(ref)
    guard let start = sigStart(holder, Int(decl(ref).first)) else { return nil }
    var k = start
    while k < Int(decl(ref).first) {
      if holder.isToken(k, "returns"), holder.isByte(k + 1, 0x28) {
        let close = holder.skipBalanced(k + 1) - 1
        return (holder.text(from: k + 2, to: close).replacingOccurrences(of: " ", with: ""), k + 2)
      }
      k += 1
    }
    return nil
  }

  // MARK: Type text

  /// A type as YARD or Sorbet writes it (`String`, `Array<Foo>`, `Hash{Symbol => Foo}`, `Foo, nil`,
  /// `T.nilable(Foo)`, `self`), with names resolved where it's written. Unknown when any part is.
  func textType(_ text: String, unitIndex: Int32, token: Int, generics: [String] = [], arguments: [Ty] = []) -> Ty {
    let parts = Self.splitTop(text, ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    var types: [Ty] = []
    for part in parts {
      if part == "nil" || part == "NilClass" || part == "void" { continue }
      let ty = oneType(part, unitIndex: unitIndex, token: token, generics: generics, arguments: arguments)
      if ty == .unknown { return .unknown }
      if !types.contains(ty) { types.append(ty) }
    }
    if types.count == 1 { return types[0] }
    if types.isEmpty { return .unknown }
    return .constructed(Ty.union, types)
  }

  static func splitTop(_ text: String, _ separator: Character) -> [String] {
    var parts: [String] = []
    var depth = 0
    var current = ""
    for c in text {
      if c == "<" || c == "{" || c == "(" || c == "[" { depth += 1 }
      if c == ">" || c == "}" || c == ")" || c == "]" { depth -= 1 }
      if c == separator, depth == 0 {
        parts.append(current)
        current = ""
      } else {
        current.append(c)
      }
    }
    parts.append(current)
    return parts
  }

  private func oneType(_ text: String, unitIndex: Int32, token: Int, generics: [String], arguments: [Ty]) -> Ty {
    var text = text
    if text.hasPrefix("T.nilable("), text.hasSuffix(")") { text = String(text.dropFirst(10).dropLast()) }
    if text.hasPrefix("T.any("), text.hasSuffix(")") { return textType(String(text.dropFirst(6).dropLast()), unitIndex: unitIndex, token: token, generics: generics, arguments: arguments) }
    if text.hasPrefix("T::Array["), text.hasSuffix("]") {
      let inner = textType(String(text.dropFirst(9).dropLast()), unitIndex: unitIndex, token: token, generics: generics, arguments: arguments)
      return classRef("Array").map { .nominal($0, [inner]) } ?? .unknown
    }
    if text.hasPrefix("T::Hash["), text.hasSuffix("]") {
      let inner = Self.splitTop(String(text.dropFirst(8).dropLast()), ",").map { textType($0, unitIndex: unitIndex, token: token, generics: generics, arguments: arguments) }
      return classRef("Hash").map { .nominal($0, inner.count == 2 ? inner : []) } ?? .unknown
    }
    if text == "self" || text == "T.self_type" { return .selfType }
    if text == "Boolean" || text == "true" || text == "false" || text == "T::Boolean" || text == "bool" {
      guard case .nominal = builtin("TrueClass"), case .nominal = builtin("FalseClass") else { return .unknown }
      return text == "true" ? builtin("TrueClass") : text == "false" ? builtin("FalseClass") : .constructed(Ty.union, [builtin("TrueClass"), builtin("FalseClass")])
    }
    if let index = generics.firstIndex(of: text) { return index < arguments.count ? arguments[index] : .unknown }
    var head = text
    var argumentTexts: [String] = []
    if let open = text.firstIndex(where: { $0 == "<" || $0 == "{" || $0 == "(" }) {
      head = String(text[..<open])
      let inner = text[text.index(after: open)...].dropLast()
      if text[open] == "{" {
        argumentTexts = inner.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
      } else if text[open] == "<" {
        argumentTexts = Self.splitTop(String(inner), ",")
      } else {
        return .unknown
      }
    }
    if head == "Class" || head == "Module", argumentTexts.count == 1 {
      let inner = textType(argumentTexts[0], unitIndex: unitIndex, token: token, generics: generics, arguments: arguments)
      return inner == .unknown ? .unknown : .meta(inner)
    }
    guard let ref = typeName(head, unitIndex: unitIndex, token: token) else { return .unknown }
    let args = argumentTexts.map { textType($0, unitIndex: unitIndex, token: token, generics: generics, arguments: arguments) }
    return .nominal(ref, args)
  }

  /// A class's name as written in a comment at a token: its constants looked up from there.
  func typeName(_ text: String, unitIndex: Int32, token: Int) -> DeclRef? {
    var segments = text.components(separatedBy: "::")
    var absolute = false
    if segments.first == "" {
      absolute = true
      segments.removeFirst()
    }
    guard let first = segments.first, let initial = first.first, initial.isUppercase, segments.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } })
    else { return nil }
    var found: [DeclRef]
    if absolute {
      indexNewUnits()
      found = constantRefs(first) ?? []
      if found.isEmpty {
        loadStd()
        found = constantRefs(first) ?? []
      }
    } else {
      found = lookupConstant(first, unitIndex: unitIndex, token: token)
    }
    for segment in segments.dropFirst() {
      guard let owner = found.first(where: isNamespaceLike) else { return nil }
      found = scopedConstant(segment, in: qualifiedName(owner))
    }
    return preferred(found.filter(isNamespaceLike)).first
  }

  // MARK: Expressions

  /// The type of the expression ending at a token (a receiver).
  func expressionType(unitIndex: Int32, end: Int) -> Ty {
    guard depth < 24 else { return .unknown }
    depth += 1
    defer { depth -= 1 }
    let holder = project.units[Int(unitIndex)]
    guard end >= 0, end < holder.tokens.count else { return .unknown }
    let token = holder.tokens[end]
    switch token.kind {
    case .string, .interpolationClose:
      return literalType(holder, end)
    case .number:
      let text = holder.string(end)
      if text.hasSuffix("r") { return builtin("Rational") }
      if text.hasSuffix("i") { return builtin("Complex") }
      if !text.hasPrefix("0x"), !text.hasPrefix("0X"), text.contains(".") || text.contains("e") || text.contains("E") { return builtin("Float") }
      return builtin("Integer")
    case .close:
      guard let open = holder.matchingOpen(end) else { return .unknown }
      switch holder.rbFirst(end) {
      case 0x29:
        if open > 0, holder.touchesPrevious(open), holder.rbIsWord(open - 1), !holder.tokens[open - 1].kind.isKeywordKind || holder.isToken(open - 1, "super") {
          return callType(unitIndex: unitIndex, nameToken: open - 1)
        }
        if end - 1 > open, chainStart(holder, end - 1) == open + 1 { return expressionType(unitIndex: unitIndex, end: end - 1) }
        return .unknown
      case 0x5D:
        if open > 0, holder.touchesPrevious(open), holder.rbIsValueEnd(open - 1) {
          return elementType(expressionType(unitIndex: unitIndex, end: open - 1), index: true)
        }
        return builtin("Array")
      case 0x7D:
        if isBlockOpen(holder, open) {
          guard let call = blockCall(holder, open) else { return .unknown }
          return callType(unitIndex: unitIndex, nameToken: call.name)
        }
        return builtin("Hash")
      default:
        return .unknown
      }
    case .keyword, .declarationKeyword:
      if holder.isToken(end, "self") { return selfType(selfContext(unitIndex: unitIndex, token: end)) }
      if holder.isToken(end, "nil") { return builtin("NilClass") }
      if holder.isToken(end, "true") { return builtin("TrueClass") }
      if holder.isToken(end, "false") { return builtin("FalseClass") }
      if holder.isToken(end, "__FILE__") { return builtin("String") }
      if holder.isToken(end, "end") {
        // `foo do … end.bar`: the call's.
        let shape = structure(holder)
        for scope in shape.scopes where Int(scope.close) == end && scope.kind == .block {
          guard let call = blockCall(holder, Int(scope.open)) else { return .unknown }
          return callType(unitIndex: unitIndex, nameToken: call.name)
        }
      }
      if holder.isToken(end, "super") { return callType(unitIndex: unitIndex, nameToken: end) }
      return .unknown
    case .identifier:
      if holder.rbIsIvar(end) { return variableType(unitIndex: unitIndex, token: end, kind: .instance) }
      if holder.rbIsCvar(end) { return variableType(unitIndex: unitIndex, token: end, kind: .classLevel) }
      if holder.rbIsGlobal(end) { return variableType(unitIndex: unitIndex, token: end, kind: .global) }
      if holder.rbIsDot(end - 1) || holder.rbIsColon2(end - 1) && !holder.rbIsConstant(end) && end >= 2 && holder.rbIsValueEnd(end - 2) {
        return callType(unitIndex: unitIndex, nameToken: end)
      }
      if holder.rbIsConstant(end) {
        let found = preferred(resolvePath(unitIndex: unitIndex, end: end))
        guard let ref = found.first else { return .unknown }
        if isNamespaceLike(ref) { return .meta(.nominal(ref, [])) }
        return found.count == 1 ? constantValueType(ref) : .unknown
      }
      let locals = body(unitIndex)
      if let definition = locals.definition[Int32(end)] { return localType(unitIndex: unitIndex, definition: definition, at: end) }
      if holder.isToken(end, "__dir__") || holder.isToken(end, "__method__") { return builtin(holder.isToken(end, "__dir__") ? "String" : "Symbol") }
      return callType(unitIndex: unitIndex, nameToken: end)
    default:
      return .unknown
    }
  }

  /// Whether a `{` opens a block (rather than a hash).
  func isBlockOpen(_ holder: Unit, _ open: Int) -> Bool {
    let shape = structure(holder)
    let index = shape.scope(at: Int32(open))
    return index > 0 && Int(shape.scopes[Int(index)].open) == open
  }

  /// A literal's class: a symbol, a string, a regexp, a word list.
  func literalType(_ holder: Unit, _ i: Int) -> Ty {
    let token = holder.tokens[i]
    if token.kind == .interpolationClose { return builtin("String") }
    let first = holder.rbFirst(i)
    if first == 0x3A { return builtin("Symbol") }
    if first == 0x2F { return builtin("Regexp") }
    if first == 0x25, token.length > 1 {
      switch holder.source.text[token.start + 1] {
      case 0x77, 0x57:
        return classRef("Array").map { array in .nominal(array, [builtin("String")]) } ?? .unknown
      case 0x69, 0x49:
        return classRef("Array").map { array in .nominal(array, [builtin("Symbol")]) } ?? .unknown
      case 0x72: return builtin("Regexp")
      case 0x73: return builtin("Symbol")
      default: return builtin("String")
      }
    }
    return builtin("String")
  }

  /// What indexing or walking a value gives: an array's elements, a hash's values.
  func elementType(_ ty: Ty, index: Bool) -> Ty {
    guard case .nominal(let ref, let args) = ty else { return .unknown }
    let qualified = qualifiedName(ref)
    if qualified == "Array" || qualified == "Set", let first = args.first { return first }
    if qualified == "Hash", index, args.count == 2 { return args[1] }
    return .unknown
  }

  /// A call's result: the method's return type, `new`'s instance, `class`'s class.
  func callType(unitIndex: Int32, nameToken: Int) -> Ty {
    let holder = project.units[Int(unitIndex)]
    let word = holder.string(nameToken)
    var receiver: Ty
    if holder.rbIsDot(nameToken - 1) || holder.rbIsColon2(nameToken - 1) {
      receiver = expressionType(unitIndex: unitIndex, end: nameToken - 2)
    } else if holder.isToken(nameToken, "super") {
      let found = callees(unitIndex: unitIndex, nameToken: nameToken)
      guard found.count == 1 else { return .unknown }
      return returnType(found[0], receiver: selfType(selfContext(unitIndex: unitIndex, token: nameToken)))
    } else {
      receiver = selfType(selfContext(unitIndex: unitIndex, token: nameToken))
      if receiver == .unknown { return .unknown }
    }
    if receiver == .unknown { return .unknown }
    if word == "new", case .meta(let inner) = receiver {
      // Unless the class defines its own `self.new`.
      if case .nominal(let ref, _) = inner, let own = staticMember(qualifiedName(ref), Self.newKey), !isSDK(own) { return returnType(own, receiver: receiver) }
      return inner
    }
    if word == "class", case .nominal = receiver { return .meta(receiver) }
    var key = name(word)
    var found = members(of: receiver, key: key)
    if found == nil, holder.rbIsConstant(nameToken) {
      key = name(word)
      found = members(of: selfType(.main), key: key)
    }
    if found == nil, !holder.rbIsDot(nameToken - 1), receiver != .unknown {
      // Kernel's and the file-level methods, from anywhere.
      found = members(of: selfType(.main), key: key)
    }
    guard let refs = found, !refs.isEmpty else { return .unknown }
    var types: [Ty] = []
    for ref in refs {
      let ty = returnType(ref, receiver: receiver)
      if ty == .unknown { return .unknown }
      if !types.contains(ty) { types.append(ty) }
    }
    return types.count == 1 ? types[0] : .constructed(Ty.union, types)
  }

  /// A method's (or attribute's) return type for a receiver: YARD's `@return`, Sorbet's `returns`, an attribute's
  /// variable, the method's last expression.
  func returnType(_ ref: DeclRef, receiver: Ty) -> Ty {
    let raw: Ty
    if let known = valueTypes[ref] {
      raw = known
    } else {
      guard resolving.insert(ref).inserted else { return .unknown }
      raw = computeReturnType(ref)
      resolving.remove(ref)
      valueTypes[ref] = raw
    }
    if case .param = raw { return substituteSelf(bindGenerics(raw, receiver: receiver), receiver: receiver) }
    return substituteSelf(raw, receiver: receiver)
  }

  func substituteSelf(_ ty: Ty, receiver: Ty) -> Ty {
    switch ty {
    case .selfType:
      if case .meta = receiver { return receiver }
      return receiver
    case .constructed(let kind, let parts):
      return .constructed(kind, parts.map { substituteSelf($0, receiver: receiver) })
    case .nominal(let ref, let args) where !args.isEmpty:
      return .nominal(ref, args.map { substituteSelf($0, receiver: receiver) })
    default:
      return ty
    }
  }

  /// Generic parameters stand for unknown until a receiver binds them: a stub method's text is read per receiver.
  private func computeReturnType(_ ref: DeclRef) -> Ty {
    let holder = unit(ref)
    let item = decl(ref)
    let info = doc(ref)
    if let text = info.returns.first {
      let generics = ownerGenerics(ref)
      if !generics.isEmpty, Self.mentions(text, generics) { return .param(name(text), ref) }
      return textType(text, unitIndex: ref.unit, token: Int(item.first))
    }
    if let sig = sigReturn(ref) { return textType(sig.text, unitIndex: ref.unit, token: sig.token) }
    if item.kind == .variable, !item.isStatic {
      // An attribute: its instance variable's type.
      var text = holder.rbLiteral(Int(item.nameToken)) ?? holder.string(Int(item.nameToken))
      if text.hasSuffix("=") { return .unknown }
      text = "@" + text
      guard let owner = owningClass(holder, item.parent) else { return .unknown }
      let qualified = qualifiedName(DeclRef(unit: ref.unit, decl: owner))
      return assignedType(owner: qualified, key: name(text))
    }
    if item.kind == .function, !holder.isInterface, item.bodyClose > item.bodyOpen, item.bodyOpen >= 0 {
      return lastExpressionType(ref)
    }
    return .unknown
  }

  static func mentions(_ text: String, _ generics: [String]) -> Bool {
    var words: [String] = []
    var current = ""
    for c in text {
      if c.isLetter || c.isNumber || c == "_" { current.append(c) } else {
        if !current.isEmpty { words.append(current) }
        current = ""
      }
    }
    if !current.isEmpty { words.append(current) }
    return words.contains { generics.contains($0) }
  }

  /// A stub class's `@!generics`.
  func ownerGenerics(_ ref: DeclRef) -> [String] {
    let holder = unit(ref)
    guard holder.isInterface, let owner = owningClass(holder, decl(ref).parent) else { return [] }
    return doc(DeclRef(unit: ref.unit, decl: owner)).generics
  }

  /// A generic return type (`.param`) read for a receiver: its text with the receiver's arguments.
  func bindGenerics(_ ty: Ty, receiver: Ty) -> Ty {
    guard case .param(_, let owner?) = ty else { return ty }
    let info = doc(owner)
    guard let text = info.returns.first else { return .unknown }
    var arguments: [Ty] = []
    if case .nominal(_, let args) = receiver { arguments = args }
    return textType(text, unitIndex: owner.unit, token: Int(decl(owner).first), generics: ownerGenerics(owner), arguments: arguments)
  }

  /// A method's last expression's type, when the method has one way out.
  private func lastExpressionType(_ ref: DeclRef) -> Ty {
    let holder = unit(ref)
    let item = decl(ref)
    let open = Int(item.bodyOpen)
    let close = Int(item.bodyClose)
    let last = holder.isToken(close, "end") ? close - 1 : close
    guard last >= open, last < holder.tokens.count else { return .unknown }
    var k = open
    while k <= last {
      // A `rescue` or `ensure` of the method, or another way out with a value: not told.
      if holder.isToken(k, "rescue") || holder.isToken(k, "ensure") || holder.isToken(k, "return") || holder.isToken(k, "yield") && k == last { return .unknown }
      k += 1
    }
    var start = holder.rbStatementStart(last, limit: open)
    // An endless method's body starts after its `=`.
    if start == open, holder.isToken(open, "=") { start += 1 }
    if holder.rbIsIdentifier(start), RubyBody.isAssignOperator(holder, start + 1) { start += 2 }
    guard start <= last, chainStart(holder, last) == start else { return .unknown }
    return expressionType(unitIndex: ref.unit, end: last)
  }

  /// A constant's value's type.
  func constantValueType(_ ref: DeclRef) -> Ty {
    let item = decl(ref)
    guard item.initStart >= 0, item.initEnd > item.initStart else { return .unknown }
    if let known = valueTypes[ref] { return known }
    guard resolving.insert(ref).inserted else { return .unknown }
    let ty = rangeType(unitIndex: ref.unit, start: Int(item.initStart), end: Int(item.initEnd))
    resolving.remove(ref)
    valueTypes[ref] = ty
    return ty
  }

  /// The type of a whole expression between two tokens: one call chain only (`a + b`, `x ? y : z` aren't told).
  func rangeType(unitIndex: Int32, start: Int, end: Int) -> Ty {
    let holder = project.units[Int(unitIndex)]
    guard end > start, end <= holder.tokens.count else { return .unknown }
    var last = end - 1
    // `.freeze` and the like keep the value.
    if holder.isToken(last, "freeze"), holder.rbIsDot(last - 1) { last -= 2 }
    guard last >= start, chainStart(holder, last) == start else { return .unknown }
    return expressionType(unitIndex: unitIndex, end: last)
  }

  // MARK: Locals and variables

  /// A local's type at a use: what its bindings give, nil left out; a union where they differ.
  func localType(unitIndex: Int32, definition: Int32, at use: Int) -> Ty {
    let key = "\(unitIndex):\(definition)"
    if let known = variableTypes[key] { return known }
    guard resolvingVariables.insert(key).inserted else { return .unknown }
    defer { resolvingVariables.remove(key) }
    let locals = body(unitIndex)
    var types: [Ty] = []
    for binding in locals.bindings[definition] ?? [] {
      guard let ty = bindingType(unitIndex: unitIndex, binding.how, token: Int(binding.token)) else { continue }
      if ty == .unknown { return cache(key, .unknown) }
      if case .nominal(let ref, _) = ty, qualifiedName(ref) == "NilClass" { continue }
      if !types.contains(ty) { types.append(ty) }
    }
    if types.isEmpty { return cache(key, .unknown) }
    return cache(key, types.count == 1 ? types[0] : .constructed(Ty.union, types))
  }

  private func cache(_ key: String, _ ty: Ty) -> Ty {
    variableTypes[key] = ty
    return ty
  }

  /// A binding's value's type; nil for one that keeps the class (`x += 1`).
  private func bindingType(unitIndex: Int32, _ how: RubyBinding, token: Int) -> Ty? {
    let holder = project.units[Int(unitIndex)]
    switch how {
    case .assign(let start, let end):
      // `x ||= …`, `x += …` keep the earlier value's class too: only `=` and `||=` are read.
      let op = token + 1
      guard holder.isToken(op, "=") || holder.isToken(op, "||=") else { return holder.isToken(op, "+=") || holder.isToken(op, "-=") || holder.isToken(op, "<<=") ? nil : .unknown }
      return rangeType(unitIndex: unitIndex, start: Int(start), end: Int(end))
    case .parameter(let method, let position):
      return parameterType(DeclRef(unit: unitIndex, decl: method), Int(position))
    case .blockParameter(let scope, let position):
      return blockParameterType(unitIndex: unitIndex, scope: Int(scope), position: Int(position))
    case .rescued(let start, let end):
      var types: [Ty] = []
      var k = Int(start)
      while k < Int(end) {
        if holder.rbIsConstant(k), !holder.rbIsColon2(k + 1) {
          guard let ref = preferred(resolvePath(unitIndex: unitIndex, end: k)).first, isNamespaceLike(ref) else { return .unknown }
          types.append(.nominal(ref, []))
        }
        k += 1
      }
      if types.isEmpty { return builtin("StandardError") }
      return types.count == 1 ? types[0] : .constructed(Ty.union, types)
    case .element(let start, let end):
      let list = rangeType(unitIndex: unitIndex, start: Int(start), end: Int(end))
      return elementType(list, index: false)
    case .untyped:
      return .unknown
    }
  }

  /// A method's parameter: YARD's `@param`, else a literal default.
  func parameterType(_ ref: DeclRef, _ position: Int) -> Ty {
    let holder = unit(ref)
    let item = decl(ref)
    guard position < Int(item.paramCount) else { return .unknown }
    let param = holder.params[Int(item.paramStart) + position]
    let word = holder.string(Int(param.nameToken))
    if param.variadic { return .unknown }
    if let text = doc(ref).params[word] { return textType(text, unitIndex: ref.unit, token: Int(item.first)) }
    guard param.hasDefault else { return .unknown }
    var k = Int(param.nameToken) + 1
    guard holder.isByte(k, 0x3D) || holder.isByte(k, 0x3A) else { return .unknown }
    k += 1
    var end = k
    var depth = 0
    while end < holder.tokens.count {
      let kind = holder.tokens[end].kind
      if kind == .open { depth += 1 } else if kind == .close {
        if depth == 0 { break }
        depth -= 1
      }
      if depth == 0, holder.isByte(end, 0x2C) || holder.isByte(end, 0x7C) || holder.startsLine(end) && end > k { break }
      end += 1
    }
    let ty = rangeType(unitIndex: ref.unit, start: k, end: end)
    if case .nominal(let r, _) = ty, qualifiedName(r) == "NilClass" { return .unknown }
    return ty
  }

  /// A block's parameter: what the method it's passed to yields (`@yieldparam`), read for the receiver.
  func blockParameterType(unitIndex: Int32, scope: Int, position: Int) -> Ty {
    let holder = project.units[Int(unitIndex)]
    let shape = structure(holder)
    guard scope < shape.scopes.count, shape.scopes[scope].kind == .block, let call = blockCall(holder, Int(shape.scopes[scope].open)) else { return .unknown }
    // `|a, (b, c)|`: only plain positions are read.
    let receiver: Ty
    if holder.rbIsDot(call.name - 1) {
      receiver = expressionType(unitIndex: unitIndex, end: call.name - 2)
    } else {
      receiver = selfType(selfContext(unitIndex: unitIndex, token: call.name))
    }
    guard receiver != .unknown, let refs = members(of: receiver, key: holder.hash(call.name)), refs.count == 1 else { return .unknown }
    let info = doc(refs[0])
    guard position < info.yields.count, !info.yields[position].isEmpty else { return .unknown }
    // An array yielded whole to one parameter: not its first element.
    if info.yieldsSplat, blockParameterCount(holder, shape.scopes[scope]) < 2 { return .unknown }
    var arguments: [Ty] = []
    if case .nominal(_, let args) = receiver { arguments = args }
    return textType(info.yields[position], unitIndex: refs[0].unit, token: Int(decl(refs[0]).first), generics: ownerGenerics(refs[0]), arguments: arguments)
  }

  /// How many parameters a block names (`|a, (b, c), *d|` is three).
  func blockParameterCount(_ holder: Unit, _ scope: RubyScope) -> Int {
    guard scope.paramStart >= 0 else { return 0 }
    var count = 0
    var depth = 0
    var expecting = true
    for k in Int(scope.paramStart)..<Int(scope.paramEnd) {
      let kind = holder.tokens[k].kind
      if kind == .open { depth += 1 } else if kind == .close { depth -= 1 }
      if depth <= 1, holder.isByte(k, 0x2C) { expecting = true } else if expecting, holder.rbIsIdentifier(k) || kind == .open {
        count += 1
        expecting = false
      }
    }
    return count
  }

  /// An instance, class or global variable's type: its assignments', nil left out.
  func variableType(unitIndex: Int32, token: Int, kind: VariableKind) -> Ty {
    let holder = project.units[Int(unitIndex)]
    let key = holder.hash(token)
    indexVariables()
    for owner in variableOwners(unitIndex: unitIndex, token: token, kind: kind) where variableDefs[owner]?[key] != nil {
      return assignedType(owner: owner, key: key)
    }
    return .unknown
  }

  /// What every assignment of a variable in an owner gives.
  func assignedType(owner: String, key: Name) -> Ty {
    let cacheKey = owner + "#\(key)"
    if let known = variableTypes[cacheKey] { return known }
    guard resolvingVariables.insert(cacheKey).inserted else { return .unknown }
    defer { resolvingVariables.remove(cacheKey) }
    indexVariables()
    var types: [Ty] = []
    for (u, token) in variableAssignments[owner]?[key] ?? [] {
      let holder = project.units[Int(u)]
      let op = token + 1
      guard holder.isToken(op, "=") || holder.isToken(op, "||=") else {
        if holder.isToken(op, "+=") || holder.isToken(op, "-=") || holder.isToken(op, "<<=") || holder.isToken(op, "&&=") { continue }
        return cache(cacheKey, .unknown)
      }
      let start = op + 1
      let end = holder.rbStatementEnd(start, limit: holder.tokens.count)
      let ty = rangeType(unitIndex: u, start: start, end: end)
      if ty == .unknown { return cache(cacheKey, .unknown) }
      if case .nominal(let ref, _) = ty, qualifiedName(ref) == "NilClass" { continue }
      if !types.contains(ty) { types.append(ty) }
    }
    if types.isEmpty { return cache(cacheKey, .unknown) }
    return cache(cacheKey, types.count == 1 ? types[0] : .constructed(Ty.union, types))
  }
}

extension TokenKind {
  var isKeywordKind: Bool { self == .keyword || self == .declarationKeyword }
}
