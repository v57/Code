import CodeModel
import CodeScan
import Foundation

/// A docblock's tags: what PHPDoc says where the code declares no type, or a vaguer one (`array`, `mixed`).
struct PHPDoc {
  /// `@return`, with `@psalm-return`/`@phpstan-return` first.
  var returnTypes: [String] = []
  var varTypes: [String] = []
  var params: [String: [String]] = [:]
  /// `@property`, `@property-read`, `@property-write`: a magic property's type.
  var properties: [String: String] = [:]
  /// `@method [static] T name(…)`: a magic method's return type, by its lowercased name.
  var methods: [String: String] = [:]
  var isDeprecated = false

  init() {}

  init(_ text: String) {
    for raw in text.split(separator: "\n") {
      var line = raw.drop { $0 == " " || $0 == "\t" || $0 == "/" || $0 == "*" }
      guard line.hasPrefix("@") else { continue }
      let tagEnd = line.firstIndex { $0 == " " || $0 == "\t" } ?? line.endIndex
      let tag = line[line.index(after: line.startIndex)..<tagEnd]
      line = line[tagEnd...]
      switch tag {
      case "return", "psalm-return", "phpstan-return":
        if let (type, _) = PHPDocText.typeAndName(line) { tag == "return" ? returnTypes.append(type) : returnTypes.insert(type, at: 0) }
      case "var", "psalm-var", "phpstan-var":
        if let (type, _) = PHPDocText.typeAndName(line) { tag == "var" ? varTypes.append(type) : varTypes.insert(type, at: 0) }
      case "param", "psalm-param", "phpstan-param":
        if let (type, name) = PHPDocText.typeAndName(line), let name {
          tag == "param" ? params[name, default: []].append(type) : params[name, default: []].insert(type, at: 0)
        }
      case "property", "property-read", "property-write":
        if let (type, name) = PHPDocText.typeAndName(line), let name { properties[name] = type }
      case "method":
        var rest = line.drop { $0 == " " || $0 == "\t" }
        if rest.hasPrefix("static ") { rest = rest.dropFirst(7) }
        guard let open = rest.firstIndex(of: "(") else { continue }
        let head = rest[..<open].trimmingCharacters(in: .whitespaces)
        let parts = head.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let methodName = parts.last else { continue }
        methods[methodName.lowercased()] = parts.count > 1 ? parts.dropLast().joined(separator: " ") : "mixed"
      case "deprecated":
        isDeprecated = true
      default:
        break
      }
    }
  }
}

enum PHPDocText {
  /// The type at the start of a tag's text (`array<int, Foo>|null`) and the `$name` after it, without its `$`.
  static func typeAndName(_ text: Substring) -> (String, String?)? {
    let bytes = Array(text.utf8)
    var i = 0
    while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
    let start = i
    var depth = 0
    while i < bytes.count {
      let b = bytes[i]
      if b == 0x3C || b == 0x28 || b == 0x7B || b == 0x5B {
        depth += 1
      } else if b == 0x3E || b == 0x29 || b == 0x7D || b == 0x5D {
        if depth == 0 { break }
        depth -= 1
      } else if depth == 0, b == 0x20 || b == 0x09 || b == 0x0D {
        // `A | B`: spaces around a union's bar.
        var k = i
        while k < bytes.count, bytes[k] == 0x20 || bytes[k] == 0x09 { k += 1 }
        let previous = i > start ? bytes[i - 1] : 0
        if k < bytes.count, bytes[k] == 0x7C || previous == 0x7C {
          i = k
          continue
        }
        break
      } else if depth == 0, b == 0x24, i == start {
        break
      }
      i += 1
    }
    let type = String(decoding: bytes[start..<i], as: UTF8.self)
    guard !type.isEmpty, !type.hasPrefix("$") else { return nil }
    while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x26 || bytes[i] == 0x2E { i += 1 }
    guard i < bytes.count, bytes[i] == 0x24 else { return (type, nil) }
    i += 1
    let nameStart = i
    while i < bytes.count, bytes[i] == 0x5F || bytes[i] >= 0x80 || (bytes[i] | 0x20 >= 0x61 && bytes[i] | 0x20 <= 0x7A) || (bytes[i] >= 0x30 && bytes[i] <= 0x39) { i += 1 }
    return (type, i > nameStart ? String(decoding: bytes[nameStart..<i], as: UTF8.self) : nil)
  }
}

/// Types: declared ones read from their tokens or from PHPDoc's text, values' from declarations, `new`, calls and
/// locals' bindings.
extension PHPModel {
  static let scalars: Set<String> = [
    "int", "float", "string", "bool", "callable", "void", "never", "false", "true", "resource", "integer", "boolean", "double", "number", "scalar", "numeric",
    "class-string", "positive-int", "negative-int", "non-empty-string", "array-key", "callable-string", "literal-string", "non-negative-int", "non-positive-int",
    "non-falsy-string", "numeric-string", "lowercase-string", "int-mask", "int-mask-of", "key-of", "value-of", "truthy-string", "interface-string",
    "enum-string", "trait-string", "open-resource", "closed-resource", "non-empty-lowercase-string",
  ]
  static let arrays: Set<String> = ["array", "list", "non-empty-array", "non-empty-list", "iterable"]

  func scalar(_ word: String) -> Ty { .constructed(name(word), []) }
  static let nullType = Ty.constructed(hashName("null"), [])

  /// A type written in tokens (a parameter's, a return type), read as the text it is.
  func tokenType(unitIndex: Int32, start: Int, end: Int) -> Ty {
    let holder = project.units[Int(unitIndex)]
    guard start >= 0, end > start else { return .unknown }
    return textType(holder.text(from: start, to: end), unitIndex: unitIndex, token: start, native: true)
  }

  /// A type as PHP or PHPDoc writes it, with names resolved where it's written. In code (`native`) only PHP's reserved
  /// names are no classes; in PHPDoc its pseudo-types (`scalar`, `list`, `positive-int`) aren't either.
  func textType(_ text: String, unitIndex: Int32, token: Int, native: Bool = false) -> Ty {
    var reader = TypeReader(bytes: Array(text.utf8), native: native)
    let ty = readUnion(&reader, unitIndex: unitIndex, token: token)
    return ty
  }

  struct TypeReader {
    var bytes: [UInt8]
    var native = false
    var i = 0
    mutating func skipSpace() { while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A || bytes[i] == 0x0D { i += 1 } }
    mutating func peek() -> UInt8? {
      skipSpace()
      return i < bytes.count ? bytes[i] : nil
    }
    /// Past a bracketed group from its opener.
    mutating func skipGroup() {
      var depth = 0
      while i < bytes.count {
        let b = bytes[i]
        if b == 0x3C || b == 0x28 || b == 0x7B || b == 0x5B { depth += 1 }
        if b == 0x3E || b == 0x29 || b == 0x7D || b == 0x5D {
          depth -= 1
          if depth == 0 {
            i += 1
            return
          }
        }
        i += 1
      }
    }
  }

  private func readUnion(_ r: inout TypeReader, unitIndex: Int32, token: Int) -> Ty {
    var parts = [readIntersection(&r, unitIndex: unitIndex, token: token)]
    while r.peek() == 0x7C {
      r.i += 1
      parts.append(readIntersection(&r, unitIndex: unitIndex, token: token))
    }
    return combine(parts, kind: Ty.union)
  }

  private func readIntersection(_ r: inout TypeReader, unitIndex: Int32, token: Int) -> Ty {
    var parts = [readPostfix(&r, unitIndex: unitIndex, token: token)]
    while r.peek() == 0x26, r.i + 1 < r.bytes.count, r.bytes[r.i + 1] != 0x24, r.bytes[r.i + 1] != 0x2E {
      r.i += 1
      parts.append(readPostfix(&r, unitIndex: unitIndex, token: token))
    }
    return parts.count == 1 ? parts[0] : .constructed(Ty.intersection, parts)
  }

  /// A union's parts with `null` taken out as optional.
  private func combine(_ parts: [Ty], kind: Name) -> Ty {
    var nullable = false
    var kept: [Ty] = []
    for part in parts {
      if part == Self.nullType {
        nullable = true
        continue
      }
      if case .optional(let inner) = part {
        nullable = true
        if !kept.contains(inner) { kept.append(inner) }
        continue
      }
      if !kept.contains(part) { kept.append(part) }
    }
    if kept.isEmpty { return Self.nullType }
    let result = kept.count == 1 ? kept[0] : .constructed(kind, kept)
    return nullable ? .optional(result) : result
  }

  private func readPostfix(_ r: inout TypeReader, unitIndex: Int32, token: Int) -> Ty {
    var ty = readPrimary(&r, unitIndex: unitIndex, token: token)
    while r.peek() == 0x5B, r.i + 1 < r.bytes.count, r.bytes[r.i + 1] == 0x5D {
      r.i += 2
      ty = .constructed(Ty.slice, [ty])
    }
    return ty
  }

  private func readPrimary(_ r: inout TypeReader, unitIndex: Int32, token: Int) -> Ty {
    guard let first = r.peek() else { return .unknown }
    if first == 0x3F {
      r.i += 1
      let inner = readPostfix(&r, unitIndex: unitIndex, token: token)
      return inner == .unknown ? .unknown : .optional(inner)
    }
    if first == 0x28 {
      r.i += 1
      let inner = readUnion(&r, unitIndex: unitIndex, token: token)
      if r.peek() == 0x29 { r.i += 1 }
      return inner
    }
    if first == 0x27 || first == 0x22 {
      // A literal string type.
      let quote = first
      r.i += 1
      while r.i < r.bytes.count, r.bytes[r.i] != quote { r.i += 1 }
      r.i += 1
      return scalar("string")
    }
    if first == 0x2D || first >= 0x30 && first <= 0x39 {
      while r.i < r.bytes.count, r.bytes[r.i] == 0x2D || r.bytes[r.i] == 0x2E || r.bytes[r.i] >= 0x30 && r.bytes[r.i] <= 0x39 { r.i += 1 }
      return scalar("int")
    }
    let start = r.i
    while r.i < r.bytes.count {
      let b = r.bytes[r.i]
      let isPart = b == 0x5C || b == 0x5F || b == 0x2D || b == 0x24 || b >= 0x80 || (b | 0x20 >= 0x61 && b | 0x20 <= 0x7A) || (b >= 0x30 && b <= 0x39)
      // `Foo::BAR` and `Foo::*`: a constant's type, unknown.
      if b == 0x3A, r.i + 1 < r.bytes.count, r.bytes[r.i + 1] == 0x3A {
        r.i += 2
        while r.i < r.bytes.count, r.bytes[r.i] == 0x2A || r.bytes[r.i] == 0x5F || (r.bytes[r.i] | 0x20 >= 0x61 && r.bytes[r.i] | 0x20 <= 0x7A) || (r.bytes[r.i] >= 0x30 && r.bytes[r.i] <= 0x39) { r.i += 1 }
        return .unknown
      }
      guard isPart else { break }
      r.i += 1
    }
    guard r.i > start else {
      r.i += 1
      return .unknown
    }
    let word = String(decoding: r.bytes[start..<r.i], as: UTF8.self)
    let lower = word.lowercased()
    var args: [Ty] = []
    if r.i < r.bytes.count, r.bytes[r.i] == 0x3C {
      r.i += 1
      while true {
        args.append(readUnion(&r, unitIndex: unitIndex, token: token))
        guard let next = r.peek() else { break }
        r.i += 1
        if next != 0x2C { break }
      }
    } else if r.i < r.bytes.count, r.bytes[r.i] == 0x7B || r.bytes[r.i] == 0x28 {
      // `array{a: int}`, `callable(int): string`, `Closure(Foo): void`.
      r.skipGroup()
      if r.peek() == 0x3A {
        r.i += 1
        _ = readPostfix(&r, unitIndex: unitIndex, token: token)
      }
    }
    switch lower {
    case "null", "void": return lower == "null" ? Self.nullType : scalar("void")
    case "mixed", "object": return .unknown
    case "$this", "static": return .selfType
    case "self":
      return enclosingClass(unitIndex: unitIndex, token: token).map { .nominal($0, []) } ?? .unknown
    case "parent":
      guard let owner = enclosingClass(unitIndex: unitIndex, token: token), let parent = parentClass(owner) else { return .unknown }
      return .nominal(parent, [])
    default: break
    }
    if r.native, !Self.builtinTypes.contains(lower), lower != "callable", lower != "iterable" {
      guard let fqn = resolveClass(word, absolute: false, unitIndex: unitIndex, token: token), let ref = classes(fqn).first else { return .unknown }
      return .nominal(ref, [])
    }
    if Self.arrays.contains(lower) { return .constructed(Ty.slice, [args.last ?? .unknown]) }
    if Self.scalars.contains(lower) || lower.hasPrefix("$") { return lower.hasPrefix("$") ? .unknown : scalar(lower == "integer" ? "int" : lower == "boolean" ? "bool" : lower == "double" ? "float" : lower) }
    guard let fqn = resolveClass(word, absolute: false, unitIndex: unitIndex, token: token), let ref = classes(fqn).first else { return .unknown }
    return .nominal(ref, args)
  }

  /// `static` and `$this` in a member's type: the receiver's class.
  func substituteSelf(_ ty: Ty, with receiver: Ty) -> Ty {
    switch ty {
    case .selfType: return receiver
    case .optional(let inner): return .optional(substituteSelf(inner, with: receiver))
    case .constructed(let kind, let parts): return .constructed(kind, parts.map { substituteSelf($0, with: receiver) })
    case .nominal(let ref, let args) where !args.isEmpty: return .nominal(ref, args.map { substituteSelf($0, with: receiver) })
    default: return ty
    }
  }

  /// The one class a receiver's type is, for `static` in what its members return.
  func receiverClass(_ ty: Ty) -> Ty? {
    switch ty {
    case .nominal: return ty
    case .meta(let inner), .optional(let inner): return receiverClass(inner)
    default: return nil
    }
  }

  /// What a `foreach` over a value gives: an array's element, a generic iterable's last argument.
  func element(of ty: Ty) -> Ty {
    switch ty {
    case .constructed(let kind, let parts) where kind == Ty.slice: return parts.first ?? .unknown
    case .optional(let inner): return element(of: inner)
    case .nominal(_, let args): return args.last ?? .unknown
    default: return .unknown
    }
  }

  /// A type is vague: PHPDoc may say more.
  func isVague(_ ty: Ty) -> Bool {
    switch ty {
    case .unknown: return true
    case .constructed(let kind, let parts) where kind == Ty.slice: return parts.first.map(isVague) ?? true
    case .nominal(_, let args): return args.isEmpty
    case .optional(let inner): return isVague(inner)
    default: return false
    }
  }

  /// The declared type, else PHPDoc's when it says more.
  func better(_ native: Ty, doc texts: [String], unitIndex: Int32, token: Int) -> Ty {
    guard isVague(native) else { return native }
    for text in texts {
      let ty = textType(text, unitIndex: unitIndex, token: token)
      guard ty != .unknown else { continue }
      if native == .unknown { return ty }
      // `array` with `Foo[]`, `Collection` with `Collection<Foo>`: the doc's, when it's the same kind of thing.
      switch (native, ty) {
      case (.constructed(let a, _), .constructed(let b, _)) where a == b: return ty
      case (.nominal(let a, _), .nominal(let b, _)) where a == b: return ty
      case (.optional, .optional): return ty
      default: continue
      }
    }
    return native
  }

  // MARK: Doc comments

  /// The docblock right above a declaration (attributes between are skipped).
  func doc(_ ref: DeclRef) -> PHPDoc {
    if let known = docCache[ref] { return known }
    let holder = unit(ref)
    let item = decl(ref)
    var result = PHPDoc()
    if let text = docText(holder, first: Int(item.first)) { result = PHPDoc(text) }
    docCache[ref] = result
    return result
  }

  func docText(_ holder: Unit, first: Int) -> String? {
    guard first >= 0, first < holder.tokens.count else { return nil }
    let all = holder.source.tokens
    var k = holder.source.tokenIndex(at: holder.tokens[first].start) - 1
    while k >= 0, all[k].kind == .attribute { k -= 1 }
    guard k >= 0, all[k].kind == .docComment || all[k].kind == .comment else { return nil }
    let text = holder.source.string(all[k])
    return text.hasPrefix("/**") ? text : nil
  }

  // MARK: Declarations' values

  /// What a declaration gives: a function's return type, a property's or constant's type, an enum case's enum.
  func valueType(of ref: DeclRef) -> Ty {
    if let known = valueTypes[ref] { return known }
    guard resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    let ty = computeValueType(ref)
    valueTypes[ref] = ty
    return ty
  }

  private func computeValueType(_ ref: DeclRef) -> Ty {
    let item = decl(ref)
    let holder = unit(ref)
    switch item.kind {
    case .enumCase:
      return item.parent >= 0 ? .nominal(DeclRef(unit: ref.unit, decl: item.parent), []) : .unknown
    case .classType, .protocolType, .enumeration:
      return .meta(.nominal(ref, []))
    case .function:
      let native = item.typeStart >= 0 ? tokenType(unitIndex: ref.unit, start: Int(item.typeStart), end: Int(item.typeEnd)) : .unknown
      return better(native, doc: doc(ref).returnTypes, unitIndex: ref.unit, token: Int(item.nameToken))
    case .variable:
      let native = item.typeStart >= 0 ? tokenType(unitIndex: ref.unit, start: Int(item.typeStart), end: Int(item.typeEnd)) : .unknown
      let isProperty = holder.phIsVariable(Int(item.nameToken))
      var texts = doc(ref).varTypes
      if isProperty, item.first == item.nameToken, let constructor = enclosingFunction(unitIndex: ref.unit, token: Int(item.nameToken)) {
        // A promoted property: the constructor's `@param`.
        texts = doc(DeclRef(unit: ref.unit, decl: constructor)).params[holder.string(Int(item.nameToken))] ?? []
      }
      let ty = better(native, doc: texts, unitIndex: ref.unit, token: Int(item.nameToken))
      if ty == .unknown, item.initStart >= 0 { return constantExpressionType(unitIndex: ref.unit, start: Int(item.initStart), end: Int(item.initEnd)) }
      return ty
    default:
      return .unknown
    }
  }

  /// A literal's or `new`'s type, where no variables are (a property's default, a constant's value).
  func constantExpressionType(unitIndex: Int32, start: Int, end: Int) -> Ty {
    let holder = project.units[Int(unitIndex)]
    guard end > start else { return .unknown }
    if end == start + 1 { return literalType(holder, start) }
    if holder.isToken(start, "new") { return newType(unitIndex: unitIndex, keyword: start, end: end) }
    if holder.isByte(start, 0x5B), holder.skipBalanced(start) == end { return .constructed(Ty.slice, [.unknown]) }
    return .unknown
  }

  func literalType(_ holder: Unit, _ i: Int) -> Ty {
    switch holder.tokens[i].kind {
    case .string: return scalar("string")
    case .number: return holder.string(i).contains(".") ? scalar("float") : scalar("int")
    default:
      let lower = holder.string(i).lowercased()
      if lower == "true" || lower == "false" { return scalar("bool") }
      if lower == "null" { return Self.nullType }
      return .unknown
    }
  }

  /// `new X(…)` from `new` to `end`: X; `new class` and `new $name` aren't told.
  func newType(unitIndex: Int32, keyword: Int, end: Int) -> Ty {
    let holder = project.units[Int(unitIndex)]
    var k = keyword + 1
    if holder.isByte(k, 0x5C) { k += 1 }
    if holder.isToken(k, "class") || holder.isToken(k, "readonly") && holder.isToken(k + 1, "class") {
      // An anonymous class: the local class its keyword names.
      let keyword = holder.isToken(k, "class") ? k : k + 1
      guard let index = holder.decls.firstIndex(where: { $0.nameToken == Int32(keyword) && $0.isLocal }) else { return .unknown }
      return .nominal(DeclRef(unit: unitIndex, decl: Int32(index)), [])
    }
    guard holder.phIsName(k) else { return .unknown }
    let range = holder.phNameRange(k)
    var after = range.end
    if holder.isByte(after, 0x28) { after = holder.skipBalanced(after) }
    guard after == end else { return .unknown }
    let text = holder.phNameText(range.start, range.end)
    let lower = text.lowercased()
    if lower == "static" || lower == "self" { return enclosingClass(unitIndex: unitIndex, token: keyword).map { .nominal($0, []) } ?? .unknown }
    return classRefs(text, absolute: range.absolute, unitIndex: unitIndex, token: k).first.map { .nominal($0, []) } ?? .unknown
  }

  // MARK: Expressions

  /// The type of the expression ending at `end` (the token before `->`).
  func expressionType(unitIndex: Int32, end: Int) -> Ty { chain(unitIndex, end).ty }

  /// The class before `::` (`self`, `static`, `parent`, a name, a variable's value), as a metatype.
  func staticReceiver(unitIndex: Int32, end: Int) -> Ty { staticChain(unitIndex, end).ty }

  func staticChain(_ unitIndex: Int32, _ end: Int) -> (ty: Ty, start: Int) {
    let holder = project.units[Int(unitIndex)]
    guard end >= 0, end < holder.tokens.count else { return (.unknown, end) }
    if holder.phIsVariable(end) {
      let (ty, start) = chain(unitIndex, end)
      guard let base = receiverClass(ty) else { return (.unknown, start) }
      return (.meta(base), start)
    }
    guard holder.phIsName(end) else { return (.unknown, end) }
    let range = holder.phNameRange(end)
    let text = holder.phNameText(range.start, range.end)
    let found = classRefs(text, absolute: range.absolute, unitIndex: unitIndex, token: end).first
    return (found.map { .meta(.nominal($0, [])) } ?? .unknown, range.start)
  }

  /// A chain's type and where it starts: `$a`, `$this`, `->name`, `->name(…)`, `X::name`, `X::name(…)`, `f(…)`,
  /// `new X(…)`, `[…]`, `(…)`.
  func chain(_ unitIndex: Int32, _ end: Int) -> (ty: Ty, start: Int) {
    let holder = project.units[Int(unitIndex)]
    guard end >= 0, end < holder.tokens.count else { return (.unknown, end) }
    guard depth < 48 else { return (.unknown, end) }
    depth += 1
    defer { depth -= 1 }
    if holder.isByte(end, 0x29) {
      guard let open = holder.matchingOpen(end) else { return (.unknown, end) }
      return call(unitIndex, open: open, close: end)
    }
    if holder.isByte(end, 0x5D) {
      guard let open = holder.matchingOpen(end) else { return (.unknown, end) }
      let base = open - 1
      if base >= 0, holder.phIsWord(base) || holder.isByte(base, 0x29) || holder.isByte(base, 0x5D) || holder.isByte(base, 0x7D) {
        let (ty, start) = chain(unitIndex, base)
        return (element(of: ty), start)
      }
      return (.constructed(Ty.slice, [.unknown]), open)
    }
    if holder.phIsVariable(end) {
      let word = holder.string(end)
      if holder.phIsDollar(end - 1), holder.isToken(end - 2, "::") {
        let (receiver, start) = staticChain(unitIndex, end - 3)
        return (memberValue(receiver, key: PHPKey.property(word)), start)
      }
      if word == "this" { return (thisType(unitIndex: unitIndex, token: end), end) }
      return (variableType(unitIndex: unitIndex, token: end), end)
    }
    if holder.phIsWord(end) {
      let range = holder.phNameRange(end)
      let word = holder.string(end)
      if range.start == end, holder.phIsArrow(end - 1) {
        let (base, start) = chain(unitIndex, end - 2)
        return (memberValue(base, key: PHPKey.property(word)), start)
      }
      if range.start == end, holder.isToken(end - 1, "::") {
        let (receiver, start) = staticChain(unitIndex, end - 2)
        if word.lowercased() == "class" { return (scalar("string"), start) }
        return (memberValue(receiver, key: PHPKey.constant(word)), start)
      }
      if range.end == end + 1 {
        let ty = literalType(holder, end)
        if ty != .unknown { return (ty, end) }
      }
      return (.unknown, range.start)
    }
    if holder.tokens[end].kind == .string || holder.tokens[end].kind == .number { return (literalType(holder, end), end) }
    return (.unknown, end)
  }

  /// `(…)` ending a chain: a call's result, or a parenthesized expression's type.
  private func call(_ unitIndex: Int32, open: Int, close: Int) -> (ty: Ty, start: Int) {
    let holder = project.units[Int(unitIndex)]
    let callee = open - 1
    if callee >= 0, holder.phIsName(callee), !Self.notCallees.contains(holder.string(callee).lowercased()) || holder.phIsArrow(callee - 1) || holder.isToken(callee - 1, "::") {
      let word = holder.string(callee)
      let range = holder.phNameRange(callee)
      if range.start == callee, holder.phIsArrow(callee - 1) {
        let (base, start) = chain(unitIndex, callee - 2)
        return (callResult(base, key: PHPKey.method(word)), start)
      }
      if range.start == callee, holder.isToken(callee - 1, "::") {
        let (receiver, start) = staticChain(unitIndex, callee - 2)
        return (callResult(receiver, key: PHPKey.method(word)), start)
      }
      let before = range.start - (range.absolute ? 2 : 1)
      if holder.isToken(before, "new") { return (newType(unitIndex: unitIndex, keyword: before, end: close + 1), before) }
      if holder.isToken(before, "function") || holder.isToken(before, "fn") { return (.unknown, callee) }
      let text = holder.phNameText(range.start, range.end)
      let found = functionRefs(text, absolute: range.absolute, unitIndex: unitIndex, token: callee).first
      return (found.map { valueType(of: $0) } ?? .unknown, range.start)
    }
    if callee >= 0, holder.phIsVariable(callee) || holder.isByte(callee, 0x29) || holder.isByte(callee, 0x5D) {
      // `$f(…)`, `(…)(…)`: what a callable returns isn't told.
      return (.unknown, chain(unitIndex, callee).start)
    }
    if callee >= 0, holder.isToken(callee, "array") || holder.isToken(callee, "list") { return (.constructed(Ty.slice, [.unknown]), callee) }
    // `(new X(…))`, `(clone $x)`, `($a)`.
    let first = open + 1
    if holder.isToken(first, "new") { return (newType(unitIndex: unitIndex, keyword: first, end: close), open) }
    if holder.isToken(first, "clone") {
      let (ty, start) = chain(unitIndex, close - 1)
      return (start <= first + 2 ? ty : .unknown, open)
    }
    let (ty, start) = chain(unitIndex, close - 1)
    let valueStart = holder.phIsVariable(first + 1) && holder.phIsDollar(first) ? first + 1 : first
    return (start == valueStart ? ty : .unknown, open)
  }

  static let notCallees: Set<String> = [
    "if", "elseif", "while", "for", "foreach", "switch", "match", "catch", "array", "list", "isset", "empty", "unset", "eval", "exit", "die", "return", "echo",
    "print", "and", "or", "xor", "use", "declare", "include", "require", "include_once", "require_once", "fn", "function", "new", "clone", "instanceof",
  ]

  /// A property's or constant's type through a receiver.
  func memberValue(_ receiver: Ty, key: Name) -> Ty {
    guard let found = members(of: receiver, key: key)?.first else { return .unknown }
    let ty = valueType(of: found)
    return receiverClass(receiver).map { substituteSelf(ty, with: $0) } ?? ty
  }

  /// What calling a method on a receiver returns, `static` and `$this` as the receiver's class.
  func callResult(_ receiver: Ty, key: Name) -> Ty {
    guard let found = members(of: receiver, key: key)?.first else { return .unknown }
    let ty = valueType(of: found)
    let owner = decl(found).parent >= 0 ? Ty.nominal(DeclRef(unit: found.unit, decl: decl(found).parent), []) : Ty.unknown
    return substituteSelf(ty, with: receiverClass(receiver) ?? owner)
  }

  /// `$this`: the class around (not an anonymous class's, which isn't read).
  func thisType(unitIndex: Int32, token: Int) -> Ty {
    return enclosingClass(unitIndex: unitIndex, token: token).map { .nominal($0, []) } ?? .unknown
  }

  // MARK: Variables

  /// A variable's type where it's used: a narrowing that holds there, else its latest binding's.
  func variableType(unitIndex: Int32, token: Int) -> Ty {
    guard let body = body(unitIndex: unitIndex, token: token) else { return .unknown }
    let holder = project.units[Int(unitIndex)]
    let word = holder.hash(token)
    let binding = body.typingBinding(of: word, at: Int32(token))
    if let narrowing = body.narrowing(of: word, at: Int32(token), after: binding) {
      if let text = narrowing.docType { return textType(text, unitIndex: unitIndex, token: Int(narrowing.start)) }
      return tokenType(unitIndex: unitIndex, start: Int(narrowing.typeStart), end: Int(narrowing.typeEnd))
    }
    guard let binding else { return .unknown }
    return bindingType(unitIndex: unitIndex, body: body, binding: binding)
  }

  func bindingType(unitIndex: Int32, body: PHPBody, binding: PHPBinding) -> Ty {
    if let known = body.types[binding.token] { return known }
    guard body.resolving.insert(binding.token).inserted else { return .unknown }
    defer { body.resolving.remove(binding.token) }
    let ty = computeBindingType(unitIndex: unitIndex, body: body, binding: binding)
    body.types[binding.token] = ty
    return ty
  }

  private func computeBindingType(unitIndex: Int32, body: PHPBody, binding: PHPBinding) -> Ty {
    let holder = project.units[Int(unitIndex)]
    switch binding.kind {
    case .parameter(let index):
      guard body.owner >= 0 else { return .unknown }
      let ref = DeclRef(unit: unitIndex, decl: body.owner)
      let item = holder.decls[Int(body.owner)]
      let param = holder.params[Int(item.paramStart) + Int(index)]
      var ty = param.typeStart >= 0 ? tokenType(unitIndex: unitIndex, start: Int(param.typeStart), end: Int(param.typeEnd)) : .unknown
      ty = better(ty, doc: doc(ref).params[holder.string(Int(param.nameToken))] ?? [], unitIndex: unitIndex, token: Int(param.nameToken))
      return param.variadic ? .constructed(Ty.slice, [ty]) : ty
    case .typed(let start, let end):
      let ty = tokenType(unitIndex: unitIndex, start: Int(start), end: Int(end))
      return holder.string(Int(binding.token) - 1).contains("...") ? .constructed(Ty.slice, [ty]) : ty
    case .assign(let start, let end):
      return valueExpressionType(unitIndex: unitIndex, start: Int(start), end: Int(end))
    case .element(let start, let end):
      return element(of: valueExpressionType(unitIndex: unitIndex, start: Int(start), end: Int(end)))
    case .captured:
      guard let outer = body.typingBinding(of: binding.name, at: binding.token), outer.token != binding.token else { return .unknown }
      if let narrowing = body.narrowing(of: binding.name, at: binding.token, after: outer) {
        if let text = narrowing.docType { return textType(text, unitIndex: unitIndex, token: Int(narrowing.start)) }
        return tokenType(unitIndex: unitIndex, start: Int(narrowing.typeStart), end: Int(narrowing.typeEnd))
      }
      return bindingType(unitIndex: unitIndex, body: body, binding: outer)
    case .untyped, .transparent:
      return .unknown
    }
  }

  /// An assigned value's type: `new`, `clone`, a literal, a chain that's the whole value, `a ?? b`.
  func valueExpressionType(unitIndex: Int32, start: Int, end: Int) -> Ty {
    let holder = project.units[Int(unitIndex)]
    var first = start
    // `=$x`, `=&$x`, `= \Foo::bar()`: the run before the value's first word.
    while first < end, holder.tokens[first].kind == .punctuation, !holder.isByte(first, 0x28), !holder.isByte(first, 0x5B) {
      var text = Substring(holder.string(first))
      if first == start, text.hasPrefix("=") { text = text.dropFirst() }
      guard text.isEmpty || text == "$" || text == "\\" || text == "&" || text == "&$" else { break }
      first += 1
    }
    guard end > first else { return .unknown }
    if holder.isToken(first, "function") || holder.isToken(first, "fn") || holder.isToken(first, "static") && (holder.isToken(first + 1, "function") || holder.isToken(first + 1, "fn")) {
      return classes("Closure").first.map { .nominal($0, []) } ?? .unknown
    }
    // `a ?? b`: a's type without null, else b's; any other operator: not read.
    var k = first
    while k < end {
      if holder.tokens[k].kind == .open {
        k = holder.skipBalanced(k)
        continue
      }
      if holder.isToken(k, "??") || holder.isToken(k, "??$") {
        let left = valueExpressionType(unitIndex: unitIndex, start: first, end: k)
        if case .optional(let inner) = left { return inner }
        if left != .unknown, left != Self.nullType { return left }
        return valueExpressionType(unitIndex: unitIndex, start: holder.isToken(k, "??") ? k + 1 : k, end: end)
      }
      if holder.tokens[k].kind == .punctuation, !isChainPunctuation(holder, k) { return .unknown }
      k += 1
    }
    if end == first + 1, !holder.phIsVariable(first) { return literalType(holder, first) }
    if holder.isToken(first, "new") { return newType(unitIndex: unitIndex, keyword: first, end: end) }
    if holder.isToken(first, "clone") { return valueExpressionType(unitIndex: unitIndex, start: first + 1, end: end) }
    if holder.isByte(first, 0x5B), holder.skipBalanced(first) == end { return .constructed(Ty.slice, [.unknown]) }
    if holder.isToken(first, "array"), holder.isByte(first + 1, 0x28), holder.skipBalanced(first + 1) == end { return .constructed(Ty.slice, [.unknown]) }
    let (ty, chainStart) = chain(unitIndex, end - 1)
    var expected = first
    if holder.phIsDollar(first) { expected = first + 1 }
    return chainStart == expected || chainStart == first ? ty : .unknown
  }

  /// `->`, `?->`, `::`, `\`, `$`: the punctuation inside a chain.
  func isChainPunctuation(_ holder: Unit, _ k: Int) -> Bool {
    holder.phIsArrow(k) || holder.isToken(k, "::") || holder.isByte(k, 0x5C) || holder.isByte(k, 0x24) || holder.isToken(k, "->$") || holder.isToken(k, "?->$")
  }
}
