import CodeModel
import CodeScan
import Foundation

/// Swift's reading of a file: its declarations into the core's tables, and its `#if` conditions.
final class SwiftSyntax: LanguageSyntax {
  static let shared = SwiftSyntax()
  let profile = LexProfile.profile(forLanguage: "swift")!
  let parametersHaveLabels = true

  func parse(_ unit: Unit) -> UInt64 {
    var parser = DeclParser(unit: unit)
    parser.parseFile()
    return parser.shape
  }

  // `#if` conditions, for this Mac's Debug build. A compiler or feature check is true, as the toolchain is the newest.
  func evaluateCondition(_ unit: Unit, _ i: inout Int) -> Bool {
    var value = conditionAnd(unit, &i)
    while unit.isToken(i, "||") {
      i += 1
      let next = conditionAnd(unit, &i)
      value = value || next
    }
    return value
  }

  private func conditionAnd(_ unit: Unit, _ i: inout Int) -> Bool {
    var value = conditionUnary(unit, &i)
    while unit.isToken(i, "&&") {
      i += 1
      let next = conditionUnary(unit, &i)
      value = value && next
    }
    return value
  }

  private func conditionUnary(_ unit: Unit, _ i: inout Int) -> Bool {
    if unit.isToken(i, "!") {
      i += 1
      return !conditionUnary(unit, &i)
    }
    if unit.isByte(i, 0x28) {
      i += 1
      let value = evaluateCondition(unit, &i)
      if unit.isByte(i, 0x29) { i += 1 }
      return value
    }
    guard i < unit.tokens.count else { return false }
    let word = unit.string(i)
    i += 1
    guard unit.isByte(i, 0x28) else {
      if word == "DEBUG" || word == "true" || word.hasPrefix("$") { return true }
      return false
    }
    let close = unit.skipBalanced(i)
    let argument = i + 1 < close - 1 ? unit.string(i + 1) : ""
    i = close
    switch word {
    case "os": return argument == "macOS"
    case "arch": return argument == "arm64"
    case "targetEnvironment": return false
    case "canImport": return !["UIKit", "WinSDK", "Glibc", "Musl", "Android", "Bionic", "WASILibc", "GTK", "CGTK", "WatchKit", "TVUIKit"].contains(argument)
    case "compiler", "swift", "hasFeature", "hasAttribute": return true
    default: return false
    }
  }
}

enum Word {
  static let underscore = name("_"), selfValue = name("self"), selfType = name("Self"), superValue = name("super")
  static let initName = name("init"), subscriptName = name("subscript"), deinitName = name("deinit")
  static let dollarZero = name("$0"), newValue = name("newValue"), oldValue = name("oldValue"), error = name("error")
  static let swift = name("Swift"), string = name("String"), int = name("Int"), double = name("Double"), bool = name("Bool")
  static let array = name("Array"), dictionary = name("Dictionary"), optional = name("Optional"), element = name("Element")
  static let dynamicMember = name("dynamicMember")
  static let keyPaths: Set<Name> = [name("KeyPath"), name("WritableKeyPath"), name("ReferenceWritableKeyPath")]
}

extension Unit {
  /// A Swift file's unit.
  convenience init(path: String, source: SourceFile, isInterface: Bool = false, focusOffset: Int? = nil) {
    self.init(path: path, source: source, syntax: SwiftSyntax.shared, isInterface: isInterface, focusOffset: focusOffset)
  }

  /// Past an attribute. `@SwiftUICore::ViewBuilder` and `@SwiftUI.ViewBuilder` go on past the name, and `@convention(c)`
  /// has arguments touching it, where the `(A)` of `@Sendable (A) -> B` is the type's.
  func skipAttribute(_ at: Int) -> Int {
    var i = at + 1
    while isByte(i, 0x2E) || isToken(i, "::"), i + 1 < tokens.count, tokens[i + 1].kind == .identifier { i += 2 }
    if isByte(i, 0x28), touchesPrevious(i) { i = skipBalanced(i) }
    return i
  }

  /// `>.` of `Dictionary<Key, Value>.Keys`, lexed as one operator: closers, then the dot of a member type.
  func isGluedDot(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count, tokens[i].kind == .punctuation, tokens[i].length >= 2 else { return false }
    let token = tokens[i]
    for k in 0..<(token.length - 1) where source.text[token.start + k] != 0x3E { return false }
    return source.text[token.start + token.length - 1] == 0x2E
  }
}

private let modifierWords: Set<String> = [
  "public", "private", "fileprivate", "internal", "package", "open", "static", "final", "override", "mutating", "nonmutating",
  "lazy", "weak", "unowned", "convenience", "required", "optional", "indirect", "nonisolated", "distributed", "dynamic", "prefix",
  "postfix", "infix", "isolated", "__consuming", "consuming", "borrowing", "__setter_access", "unsafe", "sending", "__owned", "__shared",
]

private let starterWords: Set<String> = [
  "func", "var", "let", "init", "deinit", "subscript", "struct", "class", "enum", "protocol", "extension", "typealias", "associatedtype",
  "case", "import", "operator", "precedencegroup", "macro", "actor",
]

struct DeclParser {
  let unit: Unit
  var shape: UInt64 = 14_695_981_039_346_656_037
  var scopeAccess: Access = .inherited

  private var count: Int { unit.tokens.count }

  init(unit: Unit) { self.unit = unit }

  mutating func parseFile() {
    unit.decls.reserveCapacity(unit.tokens.count / 24)
    var i = 0
    parseScope(&i, parent: -1, isTop: true)
  }

  private mutating func mix(_ value: UInt64) {
    shape = (shape ^ value) &* 1_099_511_628_211
  }

  /// Everything of a declaration outside its body goes in the shape.
  private mutating func mixRange(_ start: Int, _ end: Int) {
    var i = start
    while i < end, i < count {
      mix(unit.hash(i))
      i += 1
    }
  }

  private func text(_ i: Int) -> String { unit.string(i) }

  mutating func parseScope(_ i: inout Int, parent: Int32, isTop: Bool) {
    while i < count {
      let token = unit.tokens[i]
      switch token.kind {
      case .close:
        if !isTop { return }
        i += 1
      case .directive:
        i = unit.takeDirective(i)
      case .open:
        i = unit.skipBalanced(i)
      default:
        parseDeclaration(&i, parent: parent)
      }
    }
  }

  /// One declaration at `i`, or steps over a token that doesn't start one.
  @discardableResult
  mutating func parseDeclaration(_ i: inout Int, parent: Int32, isLocal: Bool = false) -> Bool {
    let first = i
    var access = Access.inherited
    var isStatic = false
    var isExported = false
    var isTestable = false
    var word = ""
    while i < count {
      let token = unit.tokens[i]
      if token.kind == .attribute {
        let attribute = text(i)
        if attribute == "@_exported" { isExported = true }
        if attribute == "@testable" { isTestable = true }
        i = unit.skipAttribute(i)
        continue
      }
      guard token.kind == .identifier || token.kind == .keyword || token.kind == .declarationKeyword else {
        if i == first { i += 1 }
        return false
      }
      word = text(i)
      if word == "class", i + 1 < count, ["func", "var", "let", "subscript"].contains(text(i + 1)) {
        isStatic = true
        i += 1
        continue
      }
      guard modifierWords.contains(word) else { break }
      // A modifier only when what follows goes on with a declaration: `open` may be a function's name.
      let next = i + 1
      switch word {
      case "public", "open": access = max(access == .isPrivate || access == .filePrivate ? access : .isPublic, access)
      case "package": if access == .inherited { access = .package }
      case "internal": if access == .inherited { access = .inherited }
      case "private", "fileprivate":
        if unit.isByte(next, 0x28) {
          // `private(set)` says nothing about reading it.
          i = unit.skipBalanced(next)
          continue
        }
        access = word == "private" ? .isPrivate : .filePrivate
      case "static": isStatic = true
      default: break
      }
      if unit.isByte(next, 0x28), ["unowned", "nonisolated", "open", "public", "internal", "package"].contains(word) {
        i = unit.skipBalanced(next)
        continue
      }
      i = next
    }
    guard i < count else { return false }
    let nameFollows = i + 1 < count && (unit.tokens[i + 1].kind == .identifier || unit.isByte(i + 1, 0x60))
    let declared: DeclKind?
    switch word {
    case "struct": declared = .structure
    case "class": declared = .classType
    case "actor": declared = nameFollows ? .actor : nil
    case "enum": declared = .enumeration
    case "protocol": declared = .protocolType
    case "extension": declared = .extensionDecl
    case "macro": declared = nameFollows ? .macro : nil
    default: declared = nil
    }
    if let declared {
      parseType(&i, kind: declared, first: first, access: access, parent: parent, isLocal: isLocal)
      return true
    }
    switch word {
    case "func":
      parseFunction(&i, first: first, access: access, isStatic: isStatic, parent: parent, isLocal: isLocal)
    case "init", "deinit", "subscript":
      guard word != "subscript" || unit.isByte(i + 1, 0x28) || unit.isToken(i + 1, "<") else {
        i += 1
        return false
      }
      parseInitializer(&i, word: word, first: first, access: access, isStatic: isStatic, parent: parent)
    case "var", "let":
      parseVariables(&i, first: first, access: access, isStatic: isStatic, parent: parent, isLocal: isLocal)
    case "case":
      parseCases(&i, first: first, access: access, parent: parent)
    case "typealias", "associatedtype":
      parseAlias(&i, kind: word == "typealias" ? .typeAlias : .associatedType, first: first, access: access, parent: parent, isLocal: isLocal)
    case "import":
      parseImport(&i, isExported: isExported, isTestable: isTestable)
    case "operator", "precedencegroup":
      i += 2
      if unit.isByte(i, 0x7B) { i = unit.skipBalanced(i) }
    default:
      if i == first { i += 1 }
      return false
    }
    return true
  }

  private mutating func nameToken(_ i: inout Int) -> Int {
    if unit.isByte(i, 0x60) {
      let at = i + 1
      i += 3
      return at
    }
    let at = i
    i += 1
    return at
  }

  private mutating func parseImport(_ i: inout Int, isExported: Bool, isTestable: Bool) {
    i += 1
    if i < count, ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias", "actor"].contains(text(i)) { i += 1 }
    guard i < count else { return }
    let moduleName = text(i)
    i += 1
    while unit.isByte(i, 0x2E) { i += 2 }
    unit.imports.append(Import(module: name(moduleName), moduleName: moduleName, isExported: isExported, isTestable: isTestable))
    mix(name(moduleName))
  }

  /// `<T: P, U>`, each name kept; its token range tells where it's written.
  private mutating func parseGenerics(_ i: inout Int) -> (Int32, Int32) {
    let start = Int32(unit.generics.count)
    guard unit.isToken(i, "<") || unit.isToken(i, "?<") || unit.isToken(i, "!<") else { return (start, 0) }
    let end = skipGenerics(i)
    var j = i + 1
    var depth = 0
    var atStart = true
    while j < end - 1 {
      if unit.tokens[j].kind == .open { j = unit.skipBalanced(j); atStart = false; continue }
      if unit.isToken(j, "<") { depth += 1 } else if depth > 0, unit.tokens[j].kind == .punctuation, closes(j) > 0 { depth -= closes(j) }
      if depth == 0, unit.isByte(j, 0x2C) {
        atStart = true
      } else if atStart, depth == 0 {
        if unit.tokens[j].kind == .identifier, !unit.isToken(j, "each"), !unit.isToken(j, "let") {
          unit.generics.append(Generic(name: unit.hash(j), token: Int32(j)))
          atStart = false
        }
      }
      j += 1
    }
    mixRange(i, end)
    i = end
    return (start, Int32(unit.generics.count) - start)
  }

  /// How many `>` a punctuation token closes: `>>?` closes two, `->` none.
  private func closes(_ i: Int) -> Int {
    let token = unit.tokens[i]
    guard token.kind == .punctuation else { return 0 }
    var n = 0
    var previous: UInt8 = 0
    for k in 0..<token.length {
      let c = unit.source.text[token.start + k]
      if c == 0x3E, previous != 0x2D { n += 1 }
      previous = c
    }
    return n
  }

  /// The token after the `>` matching the `<` at `open`.
  private func skipGenerics(_ open: Int) -> Int {
    var depth = 0
    var i = open
    while i < count {
      let token = unit.tokens[i]
      switch token.kind {
      case .open: i = unit.skipBalanced(i); continue
      case .close: return i
      case .punctuation:
        if unit.isToken(i, "<") || i == open { depth += 1 } else {
          depth -= closes(i)
          if depth <= 0 { return i + 1 }
          if unit.isByte(i, 0x3B) || unit.isByte(i, 0x3D) { return i }
        }
      default: break
      }
      i += 1
    }
    return i
  }

  /// The token after a type written at `i`.
  func skipType(_ start: Int) -> Int {
    var i = start
    while i < count {
      while i < count {
        if unit.tokens[i].kind == .attribute {
          i = unit.skipAttribute(i)
          continue
        }
        if unit.isByte(i, 0x7E) { i += 1; continue }
        let word = unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword ? text(i) : ""
        if ["inout", "borrowing", "consuming", "__owned", "__shared", "some", "any", "sending", "isolated", "nonisolated", "repeat", "each"].contains(word),
          i + 1 < count, unit.tokens[i + 1].kind != .punctuation || unit.isByte(i + 1, 0x7E)
        {
          i += 1
          continue
        }
        break
      }
      guard i < count else { return i }
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
      } else if unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword {
        i += 1
        if unit.isToken(i, "<") { i = skipGenerics(i) }
      } else {
        return i
      }
      // Dots, sugar, an arrow or a composition go on.
      while i < count {
        if unit.isByte(i, 0x2E) || unit.isToken(i, "::") || unit.isGluedDot(i - 1) {
          if !unit.isGluedDot(i - 1) || unit.isToken(i, "::") { i += 1 }
          if i < count { i += 1 }
          if unit.isToken(i, "<") { i = skipGenerics(i) }
          continue
        }
        if unit.tokens[i].kind == .punctuation, isSugar(i) {
          i += 1
          continue
        }
        break
      }
      var j = i
      while j < count, ["async", "throws", "rethrows", "reasync"].contains(text(j)) {
        j += 1
        if unit.isByte(j, 0x28) { j = unit.skipBalanced(j) }
      }
      if unit.isToken(j, "->") {
        i = j + 1
        continue
      }
      if unit.isByte(i, 0x26) {
        i += 1
        continue
      }
      return i
    }
    return i
  }

  private func isSugar(_ i: Int) -> Bool {
    let token = unit.tokens[i]
    for k in 0..<token.length {
      let c = unit.source.text[token.start + k]
      if c != 0x3F, c != 0x21 { return false }
    }
    return true
  }

  private mutating func parseParams(_ open: Int) -> (Int32, Int32) {
    let start = Int32(unit.params.count)
    let close = unit.skipBalanced(open) - 1
    var i = open + 1
    while i < close {
      while i < close, unit.tokens[i].kind == .attribute { i = unit.skipAttribute(i) }
      guard i < close else { break }
      // `label name: T`, `name: T` or a type alone (an enum case's `case a(Int)`).
      let firstWord = i
      var second = -1
      if unit.isByte(i, 0x60) { i += 3 } else { i += 1 }
      if i < close, !unit.isByte(i, 0x3A), unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword || unit.isByte(i, 0x60) {
        second = unit.isByte(i, 0x60) ? i + 1 : i
        i += unit.isByte(i, 0x60) ? 3 : 1
      }
      let labelToken = unit.isByte(firstWord, 0x60) ? firstWord + 1 : firstWord
      var param = Param(
        label: unit.hash(labelToken), local: unit.hash(second >= 0 ? second : labelToken), nameToken: Int32(second >= 0 ? second : labelToken),
        typeStart: -1, typeEnd: -1, hasDefault: false, variadic: false)
      if unit.isByte(i, 0x3A) {
        i += 1
        param.typeStart = Int32(i)
        i = skipType(i)
        param.typeEnd = Int32(i)
      } else {
        // A bare type.
        param.typeStart = Int32(firstWord)
        i = skipType(firstWord)
        param.typeEnd = Int32(i)
        param.label = Word.underscore
      }
      if unit.isToken(i, "...") {
        param.variadic = true
        i += 1
      }
      if unit.isByte(i, 0x3D) {
        param.hasDefault = true
        while i < close, !unit.isByte(i, 0x2C) {
          if unit.tokens[i].kind == .open { i = unit.skipBalanced(i) } else { i += 1 }
        }
      }
      unit.params.append(param)
      while i < close, !unit.isByte(i, 0x2C) {
        if unit.tokens[i].kind == .open { i = unit.skipBalanced(i) } else { i += 1 }
      }
      i += 1
    }
    mixRange(open, close + 1)
    return (start, Int32(unit.params.count) - start)
  }

  private func effective(_ access: Access, parent: Int32) -> Access {
    if access != .inherited { return access }
    guard parent >= 0 else { return .inherited }
    let outer = unit.decls[Int(parent)]
    // A member of a public type is internal unless it says otherwise; a public extension or protocol lends its own.
    if outer.kind == .extensionDecl || outer.kind == .protocolType { return outer.access == .isPublic ? .isPublic : outer.access == .package ? .package : .inherited }
    return .inherited
  }

  private mutating func parseType(_ i: inout Int, kind: DeclKind, first: Int, access: Access, parent: Int32, isLocal: Bool) {
    i += 1
    guard i < count else { return }
    let at: Int
    var typeRange: (Int32, Int32) = (-1, -1)
    if kind == .extensionDecl {
      at = i
      let end = skipType(i)
      typeRange = (Int32(i), Int32(end))
      i = end
    } else {
      at = nameToken(&i)
    }
    var decl = Decl(kind: kind, name: 0, nameToken: Int32(at), first: Int32(first), parent: parent)
    decl.access = effective(access, parent: parent)
    decl.isLocal = isLocal
    decl.typeStart = typeRange.0
    decl.typeEnd = typeRange.1
    mix(UInt64(kind.rawValue))
    if kind == .extensionDecl {
      mixRange(at, Int(typeRange.1))
      // Named after the last part of what it extends, without generic arguments.
      var last = at
      var j = at
      while j < Int(typeRange.1) {
        if unit.isToken(j, "<") { break }
        if unit.tokens[j].kind == .identifier || unit.tokens[j].kind == .keyword { last = j }
        j += 1
      }
      decl.name = unit.hash(last)
      decl.nameToken = Int32(last)
    } else {
      decl.name = unit.hash(at)
      mix(decl.name)
    }
    (decl.genericStart, decl.genericCount) = parseGenerics(&i)
    if kind == .macro {
      // `macro name(...) -> T = ...`: its parameters and result, nothing more.
      if unit.isByte(i, 0x28) {
        (decl.paramStart, decl.paramCount) = parseParams(i)
        i = unit.skipBalanced(i)
      }
      if unit.isToken(i, "->") {
        decl.typeStart = Int32(i + 1)
        i = skipType(i + 1)
        decl.typeEnd = Int32(i)
      }
      decl.end = Int32(i)
      unit.decls.append(decl)
      return
    }
    if unit.isByte(i, 0x3A) {
      i += 1
      decl.inheritStart = Int32(unit.ranges.count)
      while i < count {
        let end = skipType(i)
        guard end > i else { break }
        unit.ranges.append((Int32(i), Int32(end)))
        mixRange(i, end)
        i = end
        guard unit.isByte(i, 0x2C) else { break }
        i += 1
      }
      decl.inheritCount = Int32(unit.ranges.count) - decl.inheritStart
    }
    (decl.whereStart, decl.whereEnd) = skipWhere(&i)
    let index = Int32(unit.decls.count)
    guard unit.isByte(i, 0x7B) else {
      decl.end = Int32(i)
      unit.decls.append(decl)
      return
    }
    decl.bodyOpen = Int32(i)
    unit.decls.append(decl)
    i += 1
    parseScope(&i, parent: index, isTop: false)
    unit.decls[Int(index)].bodyClose = Int32(i)
    if i < count { i += 1 }
    unit.decls[Int(index)].end = Int32(i)
  }

  private func startsDeclaration(_ i: Int) -> Bool {
    guard i < count else { return true }
    if unit.tokens[i].kind == .attribute || unit.tokens[i].kind == .directive { return true }
    let word = text(i)
    return modifierWords.contains(word) || starterWords.contains(word)
  }

  /// Returns the requirements' tokens, or (-1, -1) without a `where`.
  @discardableResult
  private mutating func skipWhere(_ i: inout Int) -> (Int32, Int32) {
    guard unit.isToken(i, "where") else { return (-1, -1) }
    let start = i
    i += 1
    while i < count, !unit.isByte(i, 0x7B), !unit.isByte(i, 0x7D) {
      if unit.startsLine(i), startsDeclaration(i) { break }
      if unit.tokens[i].kind == .open { i = unit.skipBalanced(i) } else { i += 1 }
    }
    mixRange(start, i)
    return (Int32(start + 1), Int32(i))
  }

  private mutating func parseFunction(_ i: inout Int, first: Int, access: Access, isStatic: Bool, parent: Int32, isLocal: Bool) {
    i += 1
    guard i < count else { return }
    let at = nameToken(&i)
    var decl = Decl(kind: .function, name: unit.hash(at), nameToken: Int32(at), first: Int32(first), parent: parent)
    decl.access = effective(access, parent: parent)
    decl.isStatic = isStatic
    decl.isLocal = isLocal
    mix(decl.name)
    (decl.genericStart, decl.genericCount) = parseGenerics(&i)
    guard unit.isByte(i, 0x28) else { return }
    (decl.paramStart, decl.paramCount) = parseParams(i)
    i = unit.skipBalanced(i)
    finishCallable(&i, &decl)
  }

  private mutating func finishCallable(_ i: inout Int, _ decl: inout Decl) {
    while i < count, ["async", "throws", "rethrows", "reasync"].contains(text(i)) {
      i += 1
      if unit.isByte(i, 0x28) { i = unit.skipBalanced(i) }
    }
    if unit.isToken(i, "->") {
      i += 1
      decl.typeStart = Int32(i)
      i = skipType(i)
      decl.typeEnd = Int32(i)
      mixRange(Int(decl.typeStart), i)
    }
    (decl.whereStart, decl.whereEnd) = skipWhere(&i)
    if unit.isByte(i, 0x7B) {
      decl.bodyOpen = Int32(i)
      i = unit.skipBalanced(i)
      decl.bodyClose = Int32(i - 1)
    }
    decl.end = Int32(i)
    unit.decls.append(decl)
  }

  private mutating func parseInitializer(_ i: inout Int, word: String, first: Int, access: Access, isStatic: Bool, parent: Int32) {
    let at = i
    i += 1
    let kind: DeclKind = word == "init" ? .initializer : word == "deinit" ? .deinitializer : .subscriptDecl
    var decl = Decl(kind: kind, name: unit.hash(at), nameToken: Int32(at), first: Int32(first), parent: parent)
    decl.access = effective(access, parent: parent)
    decl.isStatic = isStatic
    mix(decl.name)
    // `init?<T>`: the two characters come as one operator, which `parseGenerics` knows.
    if unit.isByte(i, 0x3F) || unit.isToken(i, "?<") {
      decl.isFailable = true
      mix(decl.name &+ 1)
    }
    if unit.isByte(i, 0x3F) || unit.isByte(i, 0x21) { i += 1 }
    (decl.genericStart, decl.genericCount) = parseGenerics(&i)
    if unit.isByte(i, 0x28) {
      (decl.paramStart, decl.paramCount) = parseParams(i)
      i = unit.skipBalanced(i)
      // A subscript's lone name is only a local one: `subscript(index: Int)` is called as `x[1]`.
      if kind == .subscriptDecl {
        for p in Int(decl.paramStart)..<Int(decl.paramStart + decl.paramCount) where unit.params[p].label == unit.params[p].local {
          unit.params[p].label = Word.underscore
        }
      }
    }
    finishCallable(&i, &decl)
  }

  private mutating func parseVariables(_ i: inout Int, first: Int, access: Access, isStatic: Bool, parent: Int32, isLocal: Bool) {
    i += 1
    while i < count {
      if unit.isByte(i, 0x28) {
        // `let (a, b) = ...`: the names, with no type yet.
        let close = unit.skipBalanced(i) - 1
        var j = i + 1
        while j < close {
          if unit.tokens[j].kind == .identifier {
            var decl = Decl(kind: .variable, name: unit.hash(j), nameToken: Int32(j), first: Int32(first), parent: parent)
            decl.access = effective(access, parent: parent)
            decl.end = Int32(j + 1)
            decl.isStatic = isStatic
            decl.isLocal = isLocal
            unit.decls.append(decl)
            mix(decl.name)
          }
          j += 1
        }
        i = close + 1
      } else {
        guard i < count, unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword || unit.isByte(i, 0x60) else { return }
        let at = nameToken(&i)
        var decl = Decl(kind: .variable, name: unit.hash(at), nameToken: Int32(at), first: Int32(first), parent: parent)
        decl.access = effective(access, parent: parent)
        decl.isStatic = isStatic
        decl.isLocal = isLocal
        mix(decl.name)
        if unit.isByte(i, 0x3A) {
          i += 1
          decl.typeStart = Int32(i)
          i = skipType(i)
          decl.typeEnd = Int32(i)
          mixRange(Int(decl.typeStart), i)
        }
        if unit.isByte(i, 0x3D) {
          i += 1
          decl.initStart = Int32(i)
          i = skipExpression(i)
          // `var x = Size() { didSet { } }`: the block isn't a trailing closure.
          var j = i
          var at = Int(decl.initStart)
          while at < i {
            if unit.tokens[at].kind == .open {
              if unit.isByte(at, 0x7B) { j = at }
              at = unit.skipBalanced(at)
            } else {
              at += 1
            }
          }
          if j < i, unit.skipBalanced(j) == i, unit.isToken(j + 1, "didSet") || unit.isToken(j + 1, "willSet") { i = j }
          decl.initEnd = Int32(i)
          // Only with no written type can the initializer decide what others see.
          if decl.typeStart < 0 { mixRange(Int(decl.initStart), i) }
        }
        if unit.isByte(i, 0x7B) {
          decl.bodyOpen = Int32(i)
          i = unit.skipBalanced(i)
          decl.bodyClose = Int32(i - 1)
        }
        decl.end = Int32(i)
        unit.decls.append(decl)
      }
      guard unit.isByte(i, 0x2C) else { return }
      i += 1
    }
  }

  /// The token after an expression that ends at a line break, a comma or a close at its own level.
  func skipExpression(_ start: Int) -> Int {
    var i = start
    while i < count {
      let token = unit.tokens[i]
      switch token.kind {
      case .open:
        i = unit.skipBalanced(i)
        continue
      case .close, .interpolationClose:
        return i
      case .directive:
        return i
      case .punctuation:
        if unit.isByte(i, 0x2C) || unit.isByte(i, 0x3B) { return i }
      default:
        break
      }
      if i > start, unit.startsLine(i), !continuesLine(i) { return i }
      i += 1
    }
    return i
  }

  private func continuesLine(_ i: Int) -> Bool {
    if unit.tokens[i].kind == .punctuation { return true }
    let previous = unit.tokens[i - 1]
    if previous.kind == .punctuation, !isSugar(i - 1), !unit.isByte(i - 1, 0x3E) { return true }
    return false
  }

  private mutating func parseCases(_ i: inout Int, first: Int, access: Access, parent: Int32) {
    i += 1
    while i < count {
      guard unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword || unit.isByte(i, 0x60) else { return }
      let at = nameToken(&i)
      var decl = Decl(kind: .enumCase, name: unit.hash(at), nameToken: Int32(at), first: Int32(first), parent: parent)
      // A case is as visible as its enum.
      decl.access = parent >= 0 ? unit.decls[Int(parent)].access : access
      decl.isStatic = true
      mix(decl.name)
      if unit.isByte(i, 0x28) {
        (decl.paramStart, decl.paramCount) = parseParams(i)
        i = unit.skipBalanced(i)
      }
      if unit.isByte(i, 0x3D) {
        i += 2
      }
      decl.end = Int32(i)
      unit.decls.append(decl)
      guard unit.isByte(i, 0x2C) else { return }
      i += 1
    }
  }

  private mutating func parseAlias(_ i: inout Int, kind: DeclKind, first: Int, access: Access, parent: Int32, isLocal: Bool) {
    i += 1
    guard i < count else { return }
    let at = nameToken(&i)
    var decl = Decl(kind: kind, name: unit.hash(at), nameToken: Int32(at), first: Int32(first), parent: parent)
    decl.access = effective(access, parent: parent)
    decl.isLocal = isLocal
    mix(decl.name)
    (decl.genericStart, decl.genericCount) = parseGenerics(&i)
    if unit.isByte(i, 0x3A) {
      i += 1
      i = skipType(i)
    }
    if unit.isByte(i, 0x3D) {
      i += 1
      decl.typeStart = Int32(i)
      i = skipType(i)
      decl.typeEnd = Int32(i)
      mixRange(Int(decl.typeStart), i)
    }
    skipWhere(&i)
    decl.end = Int32(i)
    unit.decls.append(decl)
  }
}
