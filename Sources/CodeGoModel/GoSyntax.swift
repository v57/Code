import CodeModel
import CodeScan
import Foundation

/// Go's reading of a file into the core's tables:
///
/// - `type T struct {…}` is a `structure` whose fields are its children, `type T interface {…}` a `protocolType`
///   with its methods (embedded interfaces in its inherited ranges), `type T U` a `structure` whose `type…` range is U,
///   `type T = U` a `typeAlias`. Embedded fields are fields named after their type, and inherited ranges too.
/// - A method `func (r *T) M()` is an `extensionDecl` named T (the receiver its one parameter, the receiver's type
///   parameters its generics) holding the function: the core's extension index finds a type's methods.
/// - `var` and `const` are `variable`s (a constant's `isStatic` is set); a group's later constants without a value
///   repeat the one before (iota).
/// - A function's results are its `type…` range, as written (`(n int, err error)` with its parentheses).
/// - Anonymous `struct {…}` types are `structure`s with no name, at the `struct` keyword, so that their fields are
///   members like any other.
final class GoSyntax: LanguageSyntax {
  static let shared = GoSyntax()
  let profile = LexProfile.profile(forLanguage: "go")!
  let parametersHaveLabels = false

  func parse(_ unit: Unit) -> UInt64 {
    var parser = GoParser(unit: unit)
    parser.parseFile()
    return parser.shape
  }

  func evaluateCondition(_ unit: Unit, _ i: inout Int) -> Bool {
    i += 1
    return true
  }

  /// The name in a file's `package` clause.
  static func packageName(of unit: Unit) -> String? {
    guard unit.isToken(0, "package"), unit.tokens.count > 1 else { return nil }
    return unit.string(1)
  }
}

enum GoWord {
  static let blank = name("_"), dot = name("."), typeWord = name("type"), iota = name("iota")
  static let builtin = name("builtin"), unsafe = name("unsafe"), error = name("error"), string = name("string")
  static let int = name("int"), bool = name("bool"), float64 = name("float64"), rune = name("rune"), byte = name("byte")
  static let complex128 = name("complex128"), any = name("any"), uintptr = name("uintptr")
  static let make = name("make"), new = name("new"), append = name("append"), len = name("len"), cap = name("cap")
  static let min = name("min"), max = name("max"), real = name("real"), imag = name("imag"), complex = name("complex")
  static let recover = name("recover"), copy = name("copy")
  static let trueWord = name("true"), falseWord = name("false"), nilWord = name("nil")
}

extension Unit {
  /// Whether a line break after token `i` ends a statement (Go's semicolon rule): after a name, a literal, a closing
  /// bracket, `++`, `--` and the keywords that end one.
  func goEndsLine(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return true }
    switch tokens[i].kind {
    case .identifier, .number, .string, .close: return true
    case .keyword, .declarationKeyword:
      return isToken(i, "break") || isToken(i, "continue") || isToken(i, "fallthrough") || isToken(i, "return") || isToken(i, "true")
        || isToken(i, "false") || isToken(i, "nil") || isToken(i, "iota")
    case .punctuation: return isToken(i, "++") || isToken(i, "--")
    default: return false
    }
  }

  /// The end of a statement or spec from `i` (exclusive): a `;` or a line break that ends one, brackets skipped, up to `limit`.
  func goStatementEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      if tokens[i].kind == .open {
        i = min(skipBalanced(i), limit)
        if i < limit, startsLine(i), goEndsLine(i - 1) { return i }
        continue
      }
      if tokens[i].kind == .close { return i }
      if isByte(i, 0x3B) { return i }
      if i + 1 < limit, startsLine(i + 1), goEndsLine(i) { return i + 1 }
      i += 1
    }
    return limit
  }
}

struct GoParser {
  let unit: Unit
  var shape: UInt64 = 14_695_981_039_346_656_037
  private var count: Int { unit.tokens.count }

  init(unit: Unit) { self.unit = unit }

  private mutating func mix(_ from: Int, _ to: Int) {
    var i = from
    while i < to {
      shape = (shape ^ unit.hash(i)) &* 1_099_511_628_211
      i += 1
    }
  }

  mutating func parseFile() {
    var i = 0
    while i < count {
      if unit.isToken(i, "package") {
        mix(i, min(i + 2, count))
        i += 2
      } else if unit.isToken(i, "import") {
        let end = importDecl(i)
        mix(i, end)
        i = end
      } else if unit.isToken(i, "func") {
        i = function(i, parent: -1)
      } else if unit.isToken(i, "type") || unit.isToken(i, "var") || unit.isToken(i, "const") {
        let end = genDecl(i, parent: -1, isLocal: false)
        mix(i, end)
        i = end
      } else if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
      } else {
        i += 1
      }
    }
  }

  // MARK: Imports

  private mutating func importDecl(_ at: Int) -> Int {
    if unit.isByte(at + 1, 0x28) {
      let close = unit.skipBalanced(at + 1) - 1
      var i = at + 2
      while i < close {
        let end = unit.goStatementEnd(i, limit: close)
        importSpec(i, end)
        i = max(end, i + 1)
        if unit.isByte(i, 0x3B) { i += 1 }
      }
      return close + 1
    }
    let end = unit.goStatementEnd(at + 1, limit: count)
    importSpec(at + 1, end)
    return end
  }

  private mutating func importSpec(_ start: Int, _ end: Int) {
    var i = start
    var alias: Name = 0
    var aliasToken: Int32 = -1
    if i < end, unit.tokens[i].kind != .string {
      alias = unit.hash(i)
      aliasToken = Int32(i)
      i += 1
    }
    guard i < end, unit.tokens[i].kind == .string else { return }
    let quoted = unit.string(i)
    let path = String(quoted.dropFirst().dropLast())
    var item = Import(module: name(path), moduleName: path, isExported: false, isTestable: false)
    item.alias = alias
    item.aliasToken = aliasToken
    item.token = Int32(i)
    unit.imports.append(item)
  }

  // MARK: Functions

  /// `func [(recv)] Name[T any](params) results { body }`; a method goes inside an extension of its receiver's type.
  mutating func function(_ at: Int, parent: Int32) -> Int {
    var i = at + 1
    var holder = parent
    var receiverOpen = -1
    if unit.isByte(i, 0x28) {
      receiverOpen = i
      i = unit.skipBalanced(i)
    }
    guard i < count, unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword else { return i }
    let nameToken = i
    i += 1
    var extensionIndex: Int32 = -1
    if receiverOpen >= 0 {
      let close = unit.skipBalanced(receiverOpen) - 1
      // The receiver's type name: the last name before its brackets, past `*`.
      var typeToken = -1
      var k = receiverOpen + 1
      while k < close {
        if unit.tokens[k].kind == .identifier, !unit.isByte(k + 1, 0x2E) { typeToken = k }
        if unit.isByte(k, 0x5B) { break }
        k += 1
      }
      guard typeToken >= 0 else { return unit.skipBalanced(receiverOpen) }
      var ext = Decl(kind: .extensionDecl, name: unit.hash(typeToken), nameToken: Int32(typeToken), first: Int32(at), parent: holder)
      // `(r *T[K, V])`: the receiver's own names for T's parameters.
      if unit.isByte(k, 0x5B) {
        let bracketClose = unit.skipBalanced(k) - 1
        ext.genericStart = Int32(unit.generics.count)
        for g in (k + 1)..<bracketClose where unit.tokens[g].kind == .identifier && (unit.isByte(g - 1, 0x5B) || unit.isByte(g - 1, 0x2C)) {
          unit.generics.append(Generic(name: unit.hash(g), token: Int32(g)))
          ext.genericCount += 1
        }
      }
      ext.paramStart = Int32(unit.params.count)
      let first = receiverOpen + 1
      if first < typeToken, unit.tokens[first].kind == .identifier, !unit.isByte(first + 1, 0x2E), first + 1 <= typeToken, !unit.isByte(first + 1, 0x5B) || first + 1 < typeToken {
        if first != typeToken {
          unit.params.append(Param(label: 0, local: unit.hash(first), nameToken: Int32(first), typeStart: Int32(first + 1), typeEnd: Int32(close), hasDefault: false, variadic: false))
          ext.paramCount = 1
        }
      }
      extensionIndex = Int32(unit.decls.count)
      unit.decls.append(ext)
      holder = extensionIndex
    }
    var decl = Decl(kind: .function, name: unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(at), parent: holder)
    if unit.isByte(i, 0x5B) {
      i = typeParameters(i, into: &decl)
    }
    guard unit.isByte(i, 0x28) else { return i }
    let paramsClose = unit.skipBalanced(i)
    parameters(open: i, close: paramsClose - 1, into: &decl)
    i = paramsClose
    // Results: a parenthesized list, or one type up to the body or the line's end.
    let resultStart = i
    if unit.startsLine(i) || unit.isByte(i, 0x7B) {
      // No results.
    } else if unit.isByte(i, 0x28) {
      i = unit.skipBalanced(i)
    } else {
      i = typeEnd(i, limit: count)
    }
    if i > resultStart {
      decl.typeStart = Int32(resultStart)
      decl.typeEnd = Int32(i)
    }
    mix(at, i)
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    if unit.isByte(i, 0x7B), !unit.startsLine(i) {
      let close = unit.skipBalanced(i)
      unit.decls[Int(index)].bodyOpen = Int32(i)
      unit.decls[Int(index)].bodyClose = Int32(close - 1)
      i = close
    }
    unit.decls[Int(index)].end = Int32(i)
    if extensionIndex >= 0 { unit.decls[Int(extensionIndex)].end = Int32(i) }
    return i
  }

  /// `[K comparable, V any]`: the names into the decl's generics (constraints aren't read).
  private mutating func typeParameters(_ open: Int, into decl: inout Decl) -> Int {
    let close = unit.skipBalanced(open) - 1
    decl.genericStart = Int32(unit.generics.count)
    var pending: [Int] = []
    var i = open + 1
    while i < close {
      let itemEnd = listItemEnd(i, limit: close)
      if unit.tokens[i].kind == .identifier, i + 1 < itemEnd {
        pending.append(i)
        for token in pending {
          unit.generics.append(Generic(name: unit.hash(token), token: Int32(token)))
          decl.genericCount += 1
        }
        pending.removeAll()
      } else if unit.tokens[i].kind == .identifier {
        pending.append(i)
      }
      i = itemEnd + 1
    }
    for token in pending {
      unit.generics.append(Generic(name: unit.hash(token), token: Int32(token)))
      decl.genericCount += 1
    }
    return close + 1
  }

  /// The end of a comma-separated item at depth 0 (the comma's index, or `limit`).
  private func listItemEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.isByte(i, 0x2C) { return i }
      i += 1
    }
    return limit
  }

  /// Parameters as `Param`s with no labels: `a, b int` shares its type; a list of types alone has no names.
  mutating func parameters(open: Int, close: Int, into decl: inout Decl) {
    decl.paramStart = Int32(unit.params.count)
    var items: [(start: Int, end: Int)] = []
    var i = open + 1
    while i < close {
      let end = listItemEnd(i, limit: close)
      if end > i { items.append((i, end)) }
      i = end + 1
    }
    // Named when any item is `name Type`.
    let named = items.contains { item in
      item.end - item.start >= 2 && unit.tokens[item.start].kind == .identifier && !unit.isByte(item.start + 1, 0x2E)
        && !(unit.isByte(item.start + 1, 0x5B) && unit.touchesPrevious(item.start + 1))
    }
    var pending: [Int] = []
    for item in items {
      if !named {
        unit.params.append(Param(label: 0, local: 0, nameToken: -1, typeStart: Int32(item.start), typeEnd: Int32(item.end), hasDefault: false, variadic: unit.isToken(item.start, "...")))
        decl.paramCount += 1
        continue
      }
      guard unit.tokens[item.start].kind == .identifier || unit.tokens[item.start].kind == .keyword else { continue }
      if item.end - item.start == 1 {
        pending.append(item.start)
        continue
      }
      pending.append(item.start)
      let typeStart = item.start + 1
      for token in pending {
        unit.params.append(Param(label: 0, local: unit.hash(token), nameToken: Int32(token), typeStart: Int32(typeStart), typeEnd: Int32(item.end), hasDefault: false, variadic: unit.isToken(typeStart, "...")))
        decl.paramCount += 1
      }
      pending.removeAll()
    }
  }

  /// The end of a type written from `i`: brackets, `*`, `[]`, `map[K]`, `chan`, `func(…) R`, `struct {…}`,
  /// `interface {…}`, qualified and generic names.
  func typeEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      if unit.isByte(i, 0x2A) || unit.isToken(i, "...") || unit.isToken(i, "<-") || unit.isToken(i, "~") {
        i += 1
      } else if unit.isByte(i, 0x5B) {
        i = unit.skipBalanced(i)
      } else if unit.isToken(i, "map") {
        i += 1
        if unit.isByte(i, 0x5B) { i = unit.skipBalanced(i) }
      } else if unit.isToken(i, "chan") {
        i += 1
        if unit.isToken(i, "<-") { i += 1 }
      } else if unit.isToken(i, "func") {
        i += 1
        if unit.isByte(i, 0x28) { i = unit.skipBalanced(i) }
        // A result on the same line.
        if i < limit, !unit.startsLine(i), unit.isByte(i, 0x28) {
          return unit.skipBalanced(i)
        }
        if i < limit, !unit.startsLine(i), startsType(i) { continue }
        return i
      } else if unit.isToken(i, "struct") || unit.isToken(i, "interface") {
        i += 1
        if unit.isByte(i, 0x7B) { i = unit.skipBalanced(i) }
        return i
      } else if unit.isByte(i, 0x28) {
        return unit.skipBalanced(i)
      } else if unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword {
        i += 1
        if unit.isByte(i, 0x2E), i + 1 < limit, unit.tokens[i + 1].kind == .identifier {
          i += 2
        }
        if unit.isByte(i, 0x5B), unit.touchesPrevious(i) { i = unit.skipBalanced(i) }
        return i
      } else {
        return i
      }
    }
    return i
  }

  private func startsType(_ i: Int) -> Bool {
    guard i < count else { return false }
    switch unit.tokens[i].kind {
    case .identifier: return true
    case .keyword, .declarationKeyword:
      return unit.isToken(i, "func") || unit.isToken(i, "map") || unit.isToken(i, "chan") || unit.isToken(i, "struct") || unit.isToken(i, "interface")
    default:
      return unit.isByte(i, 0x2A) || unit.isByte(i, 0x5B) || unit.isToken(i, "<-")
    }
  }

  // MARK: type, var, const

  /// `type`, `var` or `const`, one spec or a parenthesized group. Returns the token after it.
  mutating func genDecl(_ at: Int, parent: Int32, isLocal: Bool) -> Int {
    let isType = unit.isToken(at, "type")
    let isConst = unit.isToken(at, "const")
    var previous: (typeStart: Int32, typeEnd: Int32, initStart: Int32, initEnd: Int32, count: Int)?
    func spec(_ start: Int, _ end: Int, parser: inout GoParser) {
      if isType {
        parser.typeSpec(start, end, first: at, parent: parent, isLocal: isLocal)
      } else {
        previous = parser.valueSpec(start, end, first: at, parent: parent, isLocal: isLocal, isConst: isConst, previous: previous)
      }
    }
    if unit.isByte(at + 1, 0x28) {
      let close = unit.skipBalanced(at + 1) - 1
      var i = at + 2
      while i < close {
        let end = unit.goStatementEnd(i, limit: close)
        if end > i { spec(i, end, parser: &self) }
        i = max(end, i + 1)
        if unit.isByte(i, 0x3B) { i += 1 }
      }
      return close + 1
    }
    let end = unit.goStatementEnd(at + 1, limit: count)
    spec(at + 1, end, parser: &self)
    return end
  }

  private mutating func typeSpec(_ start: Int, _ end: Int, first: Int, parent: Int32, isLocal: Bool) {
    guard unit.tokens[start].kind == .identifier || unit.tokens[start].kind == .keyword else { return }
    var decl = Decl(kind: .structure, name: unit.hash(start), nameToken: Int32(start), first: Int32(start == first + 1 ? first : start), parent: parent)
    decl.isLocal = isLocal
    decl.end = Int32(end)
    var i = start + 1
    // `[T any]` is generic, `[N]int` an array.
    if unit.isByte(i, 0x5B), i + 2 < end, unit.tokens[i + 1].kind == .identifier,
      !unit.isByte(i + 2, 0x5D), unit.tokens[i + 2].kind == .identifier || unit.tokens[i + 2].kind == .keyword || unit.isByte(i + 2, 0x2C) || unit.isToken(i + 2, "~") || unit.isByte(i + 2, 0x2A) || unit.isByte(i + 2, 0x5B)
    {
      i = typeParameters(i, into: &decl)
    }
    if unit.isByte(i, 0x3D) {
      decl.kind = .typeAlias
      i += 1
    }
    decl.typeStart = Int32(i)
    decl.typeEnd = Int32(end)
    let index = Int32(unit.decls.count)
    if decl.kind != .typeAlias, unit.isToken(i, "struct"), unit.isByte(i + 1, 0x7B) {
      decl.bodyOpen = Int32(i + 1)
      decl.bodyClose = Int32(unit.skipBalanced(i + 1) - 1)
      unit.decls.append(decl)
      structFields(open: i + 1, owner: index, isLocal: isLocal)
    } else if decl.kind != .typeAlias, unit.isToken(i, "interface"), unit.isByte(i + 1, 0x7B) {
      decl.kind = .protocolType
      decl.bodyOpen = Int32(i + 1)
      decl.bodyClose = Int32(unit.skipBalanced(i + 1) - 1)
      unit.decls.append(decl)
      interfaceElements(open: i + 1, owner: index, isLocal: isLocal)
    } else {
      unit.decls.append(decl)
      anonymousStructs(from: i, to: end, parent: index, isLocal: isLocal)
    }
  }

  /// Fields of a `struct {…}` as children of `owner`; embedded ones are also its inherited ranges.
  mutating func structFields(open: Int, owner: Int32, isLocal: Bool) {
    let close = unit.skipBalanced(open) - 1
    unit.decls[Int(owner)].inheritStart = Int32(unit.ranges.count)
    var i = open + 1
    while i < close {
      var end = unit.goStatementEnd(i, limit: close)
      if end <= i {
        i += 1
        continue
      }
      let next = unit.isByte(end, 0x3B) ? end + 1 : end
      // A tag is no part of the type.
      if end - 1 > i, unit.tokens[end - 1].kind == .string { end -= 1 }
      let embedded = !(unit.tokens[i].kind == .identifier && i + 1 < end && !unit.isByte(i + 1, 0x2E) && !(unit.isByte(i + 1, 0x5B) && unit.touchesPrevious(i + 1)))
      if embedded {
        // `*pkg.T[X]`: named after T.
        var nameToken = i
        var k = i
        while k < end, !unit.isByte(k, 0x5B) {
          if unit.tokens[k].kind == .identifier { nameToken = k }
          k += 1
        }
        var field = Decl(kind: .variable, name: unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(i), parent: owner)
        field.typeStart = Int32(i)
        field.typeEnd = Int32(end)
        field.end = Int32(end)
        field.isLocal = isLocal
        unit.decls.append(field)
        unit.ranges.append((Int32(i), Int32(end)))
        unit.decls[Int(owner)].inheritCount += 1
      } else {
        var names: [Int] = [i]
        var k = i + 1
        while unit.isByte(k, 0x2C), k + 1 < end {
          names.append(k + 1)
          k += 2
        }
        for token in names {
          var field = Decl(kind: .variable, name: unit.hash(token), nameToken: Int32(token), first: Int32(token), parent: owner)
          field.typeStart = Int32(k)
          field.typeEnd = Int32(end)
          field.end = Int32(end)
          field.isLocal = isLocal
          let fieldIndex = Int32(unit.decls.count)
          unit.decls.append(field)
          if token == names.first { anonymousStructs(from: k, to: end, parent: fieldIndex, isLocal: isLocal) }
        }
      }
      i = next
    }
  }

  /// Methods of an `interface {…}` as children; embedded interfaces and type sets as its inherited ranges.
  private mutating func interfaceElements(open: Int, owner: Int32, isLocal: Bool) {
    let close = unit.skipBalanced(open) - 1
    unit.decls[Int(owner)].inheritStart = Int32(unit.ranges.count)
    var i = open + 1
    while i < close {
      let end = unit.goStatementEnd(i, limit: close)
      if end <= i {
        i += 1
        continue
      }
      if unit.tokens[i].kind == .identifier, unit.isByte(i + 1, 0x28) {
        var method = Decl(kind: .function, name: unit.hash(i), nameToken: Int32(i), first: Int32(i), parent: owner)
        method.isLocal = isLocal
        let paramsClose = unit.skipBalanced(i + 1)
        parameters(open: i + 1, close: paramsClose - 1, into: &method)
        if paramsClose < end {
          method.typeStart = Int32(paramsClose)
          method.typeEnd = Int32(end)
        }
        method.end = Int32(end)
        unit.decls.append(method)
      } else {
        unit.ranges.append((Int32(i), Int32(end)))
        unit.decls[Int(owner)].inheritCount += 1
      }
      i = unit.isByte(end, 0x3B) ? end + 1 : end
    }
  }

  /// `struct {…}` (or `interface {…}`) written inside another type: a nameless structure at its keyword.
  mutating func anonymousStructs(from: Int, to: Int, parent: Int32, isLocal: Bool) {
    var i = from
    while i < to {
      if unit.isToken(i, "struct"), unit.isByte(i + 1, 0x7B) {
        let close = unit.skipBalanced(i + 1)
        var decl = Decl(kind: .structure, name: 0, nameToken: Int32(i), first: Int32(i), parent: parent)
        decl.isLocal = isLocal
        decl.bodyOpen = Int32(i + 1)
        decl.bodyClose = Int32(close - 1)
        decl.end = Int32(close)
        let index = Int32(unit.decls.count)
        unit.decls.append(decl)
        structFields(open: i + 1, owner: index, isLocal: isLocal)
        i = close
      } else if unit.isToken(i, "interface"), unit.isByte(i + 1, 0x7B), !unit.isByte(i + 2, 0x7D) {
        // `interface{ Close() error }`: a nameless interface at its keyword.
        let close = unit.skipBalanced(i + 1)
        var decl = Decl(kind: .protocolType, name: 0, nameToken: Int32(i), first: Int32(i), parent: parent)
        decl.isLocal = isLocal
        decl.bodyOpen = Int32(i + 1)
        decl.bodyClose = Int32(close - 1)
        decl.end = Int32(close)
        let index = Int32(unit.decls.count)
        unit.decls.append(decl)
        interfaceElements(open: i + 1, owner: index, isLocal: isLocal)
        i = close
      } else {
        i += 1
      }
    }
  }

  /// `a, b T = x, y`: a variable per name, each with the type and its own value (or all of them, for one call).
  private mutating func valueSpec(
    _ start: Int, _ end: Int, first: Int, parent: Int32, isLocal: Bool, isConst: Bool,
    previous: (typeStart: Int32, typeEnd: Int32, initStart: Int32, initEnd: Int32, count: Int)?
  ) -> (typeStart: Int32, typeEnd: Int32, initStart: Int32, initEnd: Int32, count: Int)? {
    var names: [Int] = []
    var i = start
    while i < end, unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword {
      names.append(i)
      i += 1
      if unit.isByte(i, 0x2C) { i += 1 } else { break }
    }
    guard !names.isEmpty else { return previous }
    var typeStart: Int32 = -1
    var typeEnd: Int32 = -1
    var values: [(Int32, Int32)] = []
    var assign = i
    while assign < end, !unit.isByte(assign, 0x3D) {
      if unit.tokens[assign].kind == .open { assign = unit.skipBalanced(assign) } else { assign += 1 }
    }
    if assign > i {
      typeStart = Int32(i)
      typeEnd = Int32(assign)
    }
    if assign < end {
      var k = assign + 1
      while k < end {
        let itemEnd = listItemEnd(k, limit: end)
        values.append((Int32(k), Int32(itemEnd)))
        k = itemEnd + 1
      }
    }
    var spec = (typeStart: typeStart, typeEnd: typeEnd, initStart: values.first?.0 ?? -1, initEnd: values.last?.1 ?? -1, count: values.count)
    // `const ( A Kind = iota; B; C )`: B and C are A's again.
    if isConst, values.isEmpty, typeStart < 0, let previous { spec = previous }
    for (position, token) in names.enumerated() {
      var decl = Decl(kind: .variable, name: unit.hash(token), nameToken: Int32(token), first: Int32(start == first + 1 ? first : start), parent: parent)
      decl.isLocal = isLocal
      decl.isStatic = isConst
      decl.typeStart = spec.typeStart
      decl.typeEnd = spec.typeEnd
      if values.count == names.count {
        decl.initStart = values[position].0
        decl.initEnd = values[position].1
      } else if isConst, values.isEmpty, let previous, previous.count == 1 {
        decl.initStart = previous.initStart
        decl.initEnd = previous.initEnd
      } else if values.count == 1 {
        // `a, b = f()`: which result is the position's.
        decl.initStart = values[0].0
        decl.initEnd = values[0].1
        decl.valueIndex = Int32(position + 1)
      }
      decl.end = Int32(end)
      let index = Int32(unit.decls.count)
      unit.decls.append(decl)
      if position == 0, typeStart >= 0 { anonymousStructs(from: Int(typeStart), to: Int(typeEnd), parent: index, isLocal: isLocal) }
    }
    return spec
  }
}
