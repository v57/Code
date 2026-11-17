import CodeModel
import CodeScan
import Foundation

/// PHP's reading of a file into the core's tables:
///
/// - `namespace A\B;` and `namespace A\B { … }` are `namespace` declarations holding what follows them (the statement
///   form up to the next `namespace`), named by the whole name. Code outside any is the global namespace.
/// - `class` and `trait` are `classType`s, `interface` a `protocolType`, `enum` an `enumeration` (its `case`s
///   `enumCase`s, a backed enum's type its type). Supertypes are inherited ranges, one per name: `extends`, `implements`
///   and, inside the body, `use T;` (the model tells them apart by the word before).
/// - Functions and methods are `function`s, properties (a promoted constructor parameter too), class constants and
///   top-level `const`s and `define('X', …)` `variable`s (a `define`'s name is its string). Parameters carry their name
///   as label and local.
/// - `use` at the top of a namespace: an `Import` per name, `moduleName` the full name, `alias` the name it's used by
///   (lowercased for classes and functions, which PHP matches without case), `member` the kind: 0 a class or namespace,
///   1 a function (`use function`), 2 a constant (`use const`).
/// - Names are keyed by kind (`PHPKey`), so a class's method and property of one name stay apart.
///
/// Tokens (`codeTokens`): comments, `<?php` and the markup around the code are dropped (`?>` stays: it ends a
/// statement), and a `"…"` string's or a here-document's `$name` (and `$name->prop`) become tokens of their own.
package final class PHPSyntax: LanguageSyntax {
  package let profile = LexProfile.profile(forLanguage: "php")!
  package let parametersHaveLabels = false

  package init() {}

  package func parse(_ unit: CodeModel.Unit) -> UInt64 {
    var parser = PHPParser(unit: unit)
    parser.parseFile()
    return parser.shape
  }

  package func evaluateCondition(_ unit: CodeModel.Unit, _ i: inout Int) -> Bool { true }

  package func conditional(_ unit: CodeModel.Unit, _ i: Int) -> ConditionalDirective { .none }

  package func codeTokens(_ source: SourceFile) -> [Token] {
    var kept = [Token]()
    kept.reserveCapacity(source.tokens.count)
    let text = source.text
    let all = source.tokens
    func isStart(_ b: UInt8) -> Bool { b == 0x5F || b >= 0x80 || (b | 0x20 >= 0x61 && b | 0x20 <= 0x7A) }
    func isPart(_ b: UInt8) -> Bool { isStart(b) || (b >= 0x30 && b <= 0x39) }
    for (index, token) in all.enumerated() {
      switch token.kind {
      case .comment, .docComment:
        continue
      case .punctuation where token.length >= 3 && text[token.start] == 0x3C && text[token.start + 1] == 0x3F && text[token.start + 2] != 0x3D:
        // `<?php`: no code.
        continue
      case .string:
        let first = text[token.start]
        let previous = index > 0 ? all[index - 1] : nil
        // Markup around the code: output, no code.
        if let previous, previous.kind == .punctuation, previous.length == 2, text[previous.start] == 0x3F, text[previous.start + 1] == 0x3E { continue }
        if index == 0, first != 0x22, first != 0x27 { continue }
        var interpolates = first == 0x22 || previous?.kind == .interpolationClose
        if let previous, previous.kind == .punctuation, previous.length > 3, text[previous.start] == 0x3C, text[previous.start + 1] == 0x3C,
          text[previous.start + 2] == 0x3C
        {
          // A here-document's body; a now-document's (`<<<'X'`) is plain text.
          interpolates = !UnsafeBufferPointer(start: text + previous.start, count: previous.length).contains(0x27)
        }
        guard interpolates else {
          kept.append(token)
          continue
        }
        var from = token.start
        var i = token.start
        while i < token.end - 1 {
          if text[i] == 0x5C {
            i += 2
            continue
          }
          if text[i] == 0x24, isStart(text[i + 1]), i + 1 < token.end {
            var j = i + 1
            while j < token.end, isPart(text[j]) { j += 1 }
            kept.append(Token(kind: .string, start: from, end: i + 1))
            kept.append(Token(kind: .identifier, start: i + 1, end: j))
            from = j
            // `$a->b`: one property, as PHP reads it in a string.
            if j + 2 < token.end, text[j] == 0x2D, text[j + 1] == 0x3E, isStart(text[j + 2]) {
              var k = j + 2
              while k < token.end, isPart(text[k]) { k += 1 }
              kept.append(Token(kind: .punctuation, start: j, end: j + 2))
              kept.append(Token(kind: .identifier, start: j + 2, end: k))
              from = k
              j = k
            }
            i = j
            continue
          }
          i += 1
        }
        if from < token.end { kept.append(Token(kind: .string, start: from, end: token.end)) }
      default:
        kept.append(token)
      }
    }
    return kept
  }
}

/// Declaration names by kind: a class's method and property of one name are two names. Classes, functions and methods
/// are matched without case, as PHP does.
enum PHPKey {
  static func type(_ text: String) -> Name { name("c:" + text.lowercased()) }
  static func function(_ text: String) -> Name { name("f:" + text.lowercased()) }
  static func method(_ text: String) -> Name { name("m:" + text.lowercased()) }
  static func property(_ text: String) -> Name { name("p:" + text) }
  static func constant(_ text: String) -> Name { name("k:" + text) }
  static func namespace(_ text: String) -> Name { name("n:" + text.lowercased()) }
  /// Fully qualified names in the model's symbol table.
  static func qualifiedType(_ fqn: String) -> Name { name("C:" + fqn.lowercased()) }
  static func qualifiedFunction(_ fqn: String) -> Name { name("F:" + fqn.lowercased()) }
  static func qualifiedConstant(_ fqn: String) -> Name {
    guard let slash = fqn.lastIndex(of: "\\") else { return name("K:" + fqn) }
    return name("K:" + fqn[..<slash].lowercased() + "\\" + fqn[fqn.index(after: slash)...])
  }

  /// `use` kinds, in `Import.member`.
  static let useClass: Name = 0, useFunction: Name = 1, useConstant: Name = 2
}

extension Unit {
  /// A word: an identifier or a keyword (methods and constants may be called `list`, `print`, `new`).
  func phIsWord(_ i: Int) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    let kind = tokens[i].kind
    return kind == .identifier || kind == .keyword || kind == .declarationKeyword
  }

  /// `$name`: a word right after a run ending in `$` (`$`, `=$`, `->$`, `{$`, a string piece before `$name`).
  func phIsVariable(_ i: Int) -> Bool {
    guard phIsWord(i), i > 0, touchesPrevious(i) else { return false }
    let previous = tokens[i - 1]
    guard previous.kind != .identifier, previous.kind != .keyword, previous.kind != .declarationKeyword, previous.kind != .number else { return false }
    return source.text[previous.end - 1] == 0x24
  }

  /// A name: a word that isn't a variable.
  func phIsName(_ i: Int) -> Bool { phIsWord(i) && !phIsVariable(i) }

  /// `->` or `?->`.
  func phIsArrow(_ i: Int) -> Bool { isToken(i, "->") || isToken(i, "?->") }

  /// `\` between two segments of a name, touching both.
  func phIsSeparator(_ i: Int) -> Bool { isByte(i, 0x5C) && touchesPrevious(i) && touchesPrevious(i + 1) && phIsWord(i - 1) && phIsWord(i + 1) }

  /// The token is the `$` alone (`::$x`, `$x`).
  func phIsDollar(_ i: Int) -> Bool { isByte(i, 0x24) }

  /// The first and the end (exclusive) of the qualified name a segment is in, and whether it starts with `\`.
  func phNameRange(_ i: Int) -> (start: Int, end: Int, absolute: Bool) {
    var start = i
    while start >= 2, phIsSeparator(start - 1), !phIsVariable(start - 2) { start -= 2 }
    var end = i + 1
    while end + 1 < tokens.count, phIsSeparator(end), phIsWord(end + 1) { end += 2 }
    let absolute = start > 0 && touchesPrevious(start) && tokens[start - 1].kind == .punctuation && source.text[tokens[start - 1].end - 1] == 0x5C
    return (start, end, absolute)
  }

  /// A qualified name's text from its first segment's token to `end`: `A\B\C`.
  func phNameText(_ start: Int, _ end: Int) -> String {
    var text = ""
    var k = start
    while k < end {
      if phIsWord(k) { text += (text.isEmpty ? "" : "\\") + string(k) }
      k += 1
    }
    return text
  }

  /// Whether a statement starts at `i`.
  func phStartsStatement(_ i: Int) -> Bool {
    guard i > 0 else { return true }
    let p = i - 1
    return isByte(p, 0x3B) || isByte(p, 0x7B) || isByte(p, 0x7D) || isToken(p, "?>") || tokens[p].kind == .attribute || isByte(p, 0x3A) && !isByte(p - 1, 0x3F)
  }

  /// A declaration's modifiers: `public`, `static`, …
  func phIsModifier(_ i: Int) -> Bool {
    isToken(i, "public") || isToken(i, "protected") || isToken(i, "private") || isToken(i, "static") || isToken(i, "abstract") || isToken(i, "final")
      || isToken(i, "readonly") || isToken(i, "var")
  }

  /// The end of an expression from `from`: the first `,`, `;`, `?>` or unmatched close at its level, or `limit`.
  func phExpressionEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      switch tokens[i].kind {
      case .open:
        i = skipBalanced(i)
        continue
      case .close:
        return i
      default:
        if isByte(i, 0x3B) || isByte(i, 0x2C) || isToken(i, "?>") { return i }
      }
      i += 1
    }
    return limit
  }

  /// The `;` (or `?>`, or close) ending the statement from `from`, brackets skipped.
  func phStatementEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    while i < limit {
      if tokens[i].kind == .open {
        i = skipBalanced(i)
        continue
      }
      if tokens[i].kind == .close || isByte(i, 0x3B) || isToken(i, "?>") { return i }
      i += 1
    }
    return limit
  }

  /// A string token's text without its quotes.
  func phStringValue(_ i: Int) -> String? {
    guard i >= 0, i < tokens.count, tokens[i].kind == .string else { return nil }
    let text = string(i)
    guard text.count >= 2, let first = text.first, first == "'" || first == "\"", text.last == first else { return nil }
    return String(text.dropFirst().dropLast())
  }
}

struct PHPParser {
  let unit: Unit
  var shape: UInt64 = 14_695_981_039_346_656_037
  /// Token ranges others can't see: function bodies.
  var bodies: [(Int, Int)] = []
  private var count: Int { unit.tokens.count }

  init(unit: Unit) { self.unit = unit }

  mutating func parseFile() {
    var i = 0
    var statementNamespace: Int32 = -1
    while i < count {
      if let next = namespaceDeclaration(i, current: &statementNamespace) {
        i = next
        continue
      }
      i = step(i, parent: statementNamespace)
    }
    if statementNamespace >= 0 { unit.decls[Int(statementNamespace)].end = Int32(count) }
    anonymousClasses()
    mixShape()
  }

  private mutating func mixShape() {
    bodies.sort { $0.0 < $1.0 }
    var b = 0
    var i = 0
    while i < count {
      while b < bodies.count, bodies[b].1 <= i { b += 1 }
      if b < bodies.count, bodies[b].0 <= i {
        i = max(i + 1, bodies[b].1)
        continue
      }
      shape = (shape ^ unit.hash(i)) &* 1_099_511_628_211
      i += 1
    }
  }

  @discardableResult
  private mutating func add(_ decl: Decl) -> Int32 {
    unit.decls.append(decl)
    return Int32(unit.decls.count - 1)
  }

  private func newDecl(_ kind: DeclKind, name word: Name, nameToken: Int, first: Int, parent: Int32) -> Decl {
    var decl = Decl(kind: kind, name: word, nameToken: Int32(nameToken), first: Int32(first), parent: parent)
    decl.access = .isPublic
    return decl
  }

  /// `namespace A\B;` (closing the one before) or `namespace A\B { … }`: the token after it, or nil.
  private mutating func namespaceDeclaration(_ i: Int, current: inout Int32) -> Int? {
    guard unit.isToken(i, "namespace"), unit.phStartsStatement(i) else { return nil }
    var k = i + 1
    var nameStart = -1
    var nameEnd = -1
    if unit.phIsWord(k) {
      let range = unit.phNameRange(k)
      nameStart = range.start
      nameEnd = range.end
      k = range.end
    }
    // `namespace\f()`: the current namespace, not a declaration.
    guard unit.isByte(k, 0x3B) || unit.isByte(k, 0x7B) else { return nil }
    if current >= 0 { unit.decls[Int(current)].end = Int32(i) }
    current = -1
    let text = nameStart >= 0 ? unit.phNameText(nameStart, nameEnd) : ""
    var decl = newDecl(.namespace, name: PHPKey.namespace(text), nameToken: nameStart >= 0 ? nameEnd - 1 : i, first: i, parent: -1)
    decl.typeStart = Int32(nameStart)
    decl.typeEnd = Int32(nameEnd)
    let index = add(decl)
    if unit.isByte(k, 0x7B) {
      let close = unit.skipBalanced(k) - 1
      unit.decls[Int(index)].bodyOpen = Int32(k)
      unit.decls[Int(index)].bodyClose = Int32(close)
      var j = k + 1
      while j < close { j = step(j, parent: index) }
      unit.decls[Int(index)].end = Int32(min(count, close + 1))
      return close + 1
    }
    current = index
    return k + 1
  }

  /// One construct from `i` at a namespace's level (or in a block of top-level code): the token after it.
  private mutating func step(_ i: Int, parent: Int32) -> Int {
    let token = unit.tokens[i]
    guard token.kind == .keyword || token.kind == .declarationKeyword || token.kind == .identifier else { return i + 1 }
    if unit.isToken(i, "use"), unit.phStartsStatement(i) { return useStatement(i) }
    if unit.isToken(i, "class") || unit.isToken(i, "interface") || unit.isToken(i, "trait") || unit.isToken(i, "enum") {
      // `new class(…) { … }`: an anonymous class, whose methods are no functions here.
      if unit.isToken(i - 1, "new") || (unit.isToken(i - 1, "readonly") && unit.isToken(i - 2, "new")) {
        var k = i + 1
        while k < count, !unit.isByte(k, 0x7B), !unit.isByte(k, 0x3B) {
          if unit.tokens[k].kind == .open { k = unit.skipBalanced(k) } else { k += 1 }
        }
        return unit.isByte(k, 0x7B) ? unit.skipBalanced(k) : k
      }
      if unit.phIsName(i + 1), !unit.isToken(i - 1, "::"), !unit.phIsArrow(i - 1) { return classDeclaration(i, parent: parent) }
      return i + 1
    }
    if unit.isToken(i, "function") {
      var k = i + 1
      if unit.isByte(k, 0x26) { k += 1 }
      if unit.phIsWord(k), unit.isByte(k + 1, 0x28), !unit.phIsArrow(i - 1), !unit.isToken(i - 1, "::") {
        return function(nameAt: k, first: i, parent: parent, mods: Modifiers())
      }
      return closureEnd(i)
    }
    if unit.isToken(i, "const"), unit.phStartsStatement(i) { return constants(i, first: i, parent: parent, isMember: false) }
    if unit.isToken(i, "define"), unit.isByte(i + 1, 0x28), unit.tokens.indices.contains(i + 2), unit.tokens[i + 2].kind == .string, unit.isByte(i + 3, 0x2C),
      !unit.phIsArrow(i - 1), !unit.isToken(i - 1, "::"), let value = unit.phStringValue(i + 2), !value.isEmpty
    {
      var decl = newDecl(.variable, name: PHPKey.constant(value), nameToken: i + 2, first: i, parent: -1)
      decl.initStart = Int32(i + 4)
      let end = unit.phStatementEnd(i, limit: count)
      decl.initEnd = Int32(max(i + 4, end - 1))
      decl.end = Int32(end)
      add(decl)
      return i + 3
    }
    return i + 1
  }

  /// A closure (`function (…) use (…) { … }`): past its body, which declares nothing at this level.
  private func closureEnd(_ i: Int) -> Int {
    var k = i + 1
    while k < count, !unit.isByte(k, 0x7B), !unit.isByte(k, 0x3B) {
      if unit.tokens[k].kind == .open, !unit.isByte(k, 0x7B) { k = unit.skipBalanced(k) } else { k += 1 }
    }
    return unit.isByte(k, 0x7B) ? unit.skipBalanced(k) : k
  }

  // MARK: Use

  /// `use [function|const] A\B [as C], …;`, `use A\{B, function c, const D as E};`.
  private mutating func useStatement(_ i: Int) -> Int {
    let end = unit.phStatementEnd(i + 1, limit: count)
    var kind = PHPKey.useClass
    var k = i + 1
    if unit.isToken(k, "function") {
      kind = PHPKey.useFunction
      k += 1
    } else if unit.isToken(k, "const") {
      kind = PHPKey.useConstant
      k += 1
    }
    while k < end {
      guard unit.phIsWord(k) || unit.isByte(k, 0x5C) else {
        k += 1
        continue
      }
      if unit.isByte(k, 0x5C) { k += 1 }
      let range = unit.phNameRange(k)
      let prefix = unit.phNameText(range.start, range.end)
      var after = range.end
      // A group: `A\{…}`.
      if unit.isByte(after, 0x5C), unit.isByte(after + 1, 0x7B) {
        let close = unit.skipBalanced(after + 1) - 1
        var j = after + 2
        while j < close {
          var itemKind = kind
          if unit.isToken(j, "function"), unit.phIsWord(j + 1) {
            itemKind = PHPKey.useFunction
            j += 1
          } else if unit.isToken(j, "const"), unit.phIsWord(j + 1) {
            itemKind = PHPKey.useConstant
            j += 1
          }
          guard unit.phIsWord(j) else {
            j += 1
            continue
          }
          let inner = unit.phNameRange(j)
          j = inner.end
          j = addImport(prefix + "\\" + unit.phNameText(inner.start, inner.end), kind: itemKind, first: range.start, last: inner.end - 1, at: j)
        }
        k = close + 1
        continue
      }
      after = addImport(prefix, kind: kind, first: range.start, last: range.end - 1, at: after)
      k = after
    }
    return end + 1
  }

  /// One imported name, with its `as` alias: the token after it.
  private mutating func addImport(_ fqn: String, kind: Name, first: Int, last: Int, at: Int) -> Int {
    var aliasToken = last
    var next = at
    if unit.isToken(at, "as"), unit.phIsWord(at + 1) {
      aliasToken = at + 1
      next = at + 2
    }
    let aliasText = unit.string(aliasToken)
    var item = Import(module: name(fqn.lowercased()), moduleName: fqn, isExported: false, isTestable: false)
    item.alias = kind == PHPKey.useConstant ? name(aliasText) : name(aliasText.lowercased())
    item.aliasToken = Int32(aliasToken)
    item.token = Int32(first)
    item.member = kind
    unit.imports.append(item)
    return next
  }

  // MARK: Classes

  struct Modifiers {
    var isStatic = false
    var isAbstract = false
    var isPromoting = false
  }

  /// The first token of a declaration whose keyword is at `i`: its modifiers and attributes before it.
  private func firstToken(before i: Int) -> Int {
    var first = i
    while first > 0, unit.phIsModifier(first - 1) || unit.tokens[first - 1].kind == .attribute { first -= 1 }
    return first
  }

  /// `new class(…) extends A implements B { … }`, wherever it is: a local class named by its `class` keyword.
  private mutating func anonymousClasses() {
    var k = 0
    while k < count {
      if unit.isToken(k, "class"), unit.isToken(k - 1, "new") || unit.isToken(k - 1, "readonly") && unit.isToken(k - 2, "new") {
        var parent: Int32 = -1
        for (index, item) in unit.decls.enumerated() where item.first <= Int32(k) && Int32(k) < item.end && item.kind != .variable {
          if parent < 0 || item.first >= unit.decls[Int(parent)].first { parent = Int32(index) }
        }
        _ = classDeclaration(k, parent: parent, anonymous: true)
      }
      k += 1
    }
  }

  private mutating func classDeclaration(_ keyword: Int, parent: Int32, anonymous: Bool = false) -> Int {
    let nameAt = anonymous ? keyword : keyword + 1
    let kind: DeclKind
    if unit.isToken(keyword, "interface") {
      kind = .protocolType
    } else if unit.isToken(keyword, "enum") {
      kind = .enumeration
    } else {
      kind = .classType
    }
    var decl = newDecl(kind, name: PHPKey.type(anonymous ? "class@anonymous" : unit.string(nameAt)), nameToken: nameAt, first: anonymous ? keyword : firstToken(before: keyword), parent: parent)
    decl.isLocal = anonymous
    var i = nameAt + 1
    if anonymous, unit.isByte(i, 0x28) { i = unit.skipBalanced(i) }
    // A backed enum's type: `enum Suit: string`.
    if kind == .enumeration, unit.isByte(i, 0x3A), unit.phIsWord(i + 1) {
      decl.typeStart = Int32(i + 1)
      decl.typeEnd = Int32(i + 2)
      i += 2
    }
    decl.inheritStart = Int32(unit.ranges.count)
    while i < count, !unit.isByte(i, 0x7B), !unit.isByte(i, 0x3B) {
      if unit.isToken(i, "extends") || unit.isToken(i, "implements") || unit.isByte(i, 0x2C) {
        i += 1
        if unit.isByte(i, 0x5C) { i += 1 }
        guard unit.phIsWord(i) else { continue }
        let range = unit.phNameRange(i)
        unit.ranges.append((Int32(range.start), Int32(range.end)))
        i = range.end
        continue
      }
      i += 1
    }
    decl.inheritCount = Int32(unit.ranges.count) - decl.inheritStart
    let index = add(decl)
    guard unit.isByte(i, 0x7B) else {
      unit.decls[Int(index)].end = Int32(min(count, i + 1))
      return i + 1
    }
    let close = unit.skipBalanced(i) - 1
    unit.decls[Int(index)].bodyOpen = Int32(i)
    unit.decls[Int(index)].bodyClose = Int32(close)
    members(i + 1, close: close, owner: index)
    unit.decls[Int(index)].inheritCount = Int32(unit.ranges.count) - unit.decls[Int(index)].inheritStart
    unit.decls[Int(index)].end = Int32(min(count, close + 1))
    return close + 1
  }

  /// A class's body: trait uses, constants, enum cases, methods, properties.
  private mutating func members(_ from: Int, close: Int, owner: Int32) {
    var i = from
    while i < close {
      if unit.tokens[i].kind == .attribute || unit.isByte(i, 0x3B) {
        i += 1
        continue
      }
      let first = i
      var mods = Modifiers()
      while i < close, unit.phIsModifier(i) || unit.tokens[i].kind == .attribute {
        if unit.isToken(i, "static") { mods.isStatic = true }
        if unit.isToken(i, "abstract") { mods.isAbstract = true }
        i += 1
      }
      if unit.isToken(i, "use") {
        // `use A, B;` or `use A, B { A::f insteadof B; B::f as g; }`.
        var k = i + 1
        while k < close, !unit.isByte(k, 0x3B), !unit.isByte(k, 0x7B) {
          if unit.isByte(k, 0x5C) || unit.isByte(k, 0x2C) {
            k += 1
            continue
          }
          if unit.phIsWord(k) {
            let range = unit.phNameRange(k)
            unit.ranges.append((Int32(range.start), Int32(range.end)))
            k = range.end
            continue
          }
          k += 1
        }
        i = unit.isByte(k, 0x7B) ? unit.skipBalanced(k) : k + 1
        continue
      }
      if unit.isToken(i, "case"), unit.phIsWord(i + 1) {
        var decl = newDecl(.enumCase, name: PHPKey.constant(unit.string(i + 1)), nameToken: i + 1, first: first, parent: owner)
        decl.isStatic = true
        let end = unit.phStatementEnd(i + 2, limit: close)
        if unit.isToken(i + 2, "=") {
          decl.initStart = Int32(i + 3)
          decl.initEnd = Int32(end)
        }
        decl.end = Int32(min(close, end + 1))
        add(decl)
        i = end + 1
        continue
      }
      if unit.isToken(i, "const") {
        i = constants(i, first: first, parent: owner, isMember: true)
        continue
      }
      if unit.isToken(i, "function") {
        var k = i + 1
        if unit.isByte(k, 0x26) { k += 1 }
        if unit.phIsWord(k), unit.isByte(k + 1, 0x28) {
          i = function(nameAt: k, first: first, parent: owner, mods: mods)
          continue
        }
        i = closureEnd(i)
        continue
      }
      // A property: `[type] $name [= value], $other;` or with hooks `{ get => …; }`.
      var k = i
      while k < close, !unit.phIsVariable(k), !unit.isByte(k, 0x3B), !unit.isByte(k, 0x7B), !unit.isByte(k, 0x3D) {
        if unit.tokens[k].kind == .open { k = unit.skipBalanced(k) } else { k += 1 }
      }
      guard k < close, unit.phIsVariable(k), k > first else {
        i = max(i + 1, k)
        if i < close, unit.isByte(i, 0x7B) { i = unit.skipBalanced(i) }
        continue
      }
      let typeStart = i
      let typeEnd = k - 1
      while k < close, unit.phIsVariable(k) {
        var decl = newDecl(.variable, name: PHPKey.property(unit.string(k)), nameToken: k, first: first, parent: owner)
        decl.isStatic = mods.isStatic
        if typeEnd > typeStart {
          decl.typeStart = Int32(typeStart)
          decl.typeEnd = Int32(typeEnd)
        }
        var j = k + 1
        if unit.isToken(j, "=") {
          let end = unit.phExpressionEnd(j + 1, limit: close)
          decl.initStart = Int32(j + 1)
          decl.initEnd = Int32(end)
          j = end
        }
        if unit.isByte(j, 0x7B) {
          // Property hooks.
          let after = unit.skipBalanced(j)
          decl.bodyOpen = Int32(j)
          decl.bodyClose = Int32(after - 1)
          bodies.append((j + 1, after - 1))
          j = after
        }
        decl.end = Int32(min(close, j + 1))
        add(decl)
        if unit.isByte(j, 0x2C), unit.phIsVariable(j + 2) {
          k = j + 2
          continue
        }
        k = j
        break
      }
      i = unit.isByte(k, 0x3B) ? k + 1 : max(k, i + 1)
    }
  }

  /// `const [type] A = 1, B = 2;`: each a variable (static in a class).
  private mutating func constants(_ keyword: Int, first: Int, parent: Int32, isMember: Bool) -> Int {
    let end = unit.phStatementEnd(keyword + 1, limit: count)
    var k = keyword + 1
    var typeStart = -1
    var typeEnd = -1
    // A typed constant: the name is the word right before `=`.
    if !unit.isToken(k + 1, "=") {
      typeStart = k
      while k < end, !unit.isToken(k + 1, "=") { k += 1 }
      typeEnd = k
    }
    while k < end {
      guard unit.phIsWord(k), unit.isToken(k + 1, "=") else {
        k += 1
        continue
      }
      var decl = newDecl(.variable, name: PHPKey.constant(unit.string(k)), nameToken: k, first: first, parent: parent)
      decl.isStatic = isMember
      if typeStart >= 0, typeEnd > typeStart {
        decl.typeStart = Int32(typeStart)
        decl.typeEnd = Int32(typeEnd)
      }
      let valueEnd = unit.phExpressionEnd(k + 2, limit: end)
      decl.initStart = Int32(k + 2)
      decl.initEnd = Int32(valueEnd)
      decl.end = Int32(min(count, end + 1))
      add(decl)
      k = valueEnd + 1
    }
    return end + 1
  }

  // MARK: Functions

  private mutating func function(nameAt: Int, first: Int, parent: Int32, mods: Modifiers) -> Int {
    let isMember = parent >= 0 && unit.decls[Int(parent)].kind != .namespace
    let word = unit.string(nameAt)
    var decl = newDecl(.function, name: isMember ? PHPKey.method(word) : PHPKey.function(word), nameToken: nameAt, first: first, parent: parent)
    decl.isStatic = mods.isStatic
    let open = nameAt + 1
    let close = unit.skipBalanced(open) - 1
    var i = close + 1
    if unit.isByte(i, 0x3A) {
      i += 1
      let start = i
      while i < count, !unit.isByte(i, 0x7B), !unit.isByte(i, 0x3B) {
        if unit.tokens[i].kind == .open, !unit.isByte(i, 0x28) { break }
        i += 1
      }
      decl.typeStart = Int32(start)
      decl.typeEnd = Int32(i)
    }
    var promoted: [Param] = []
    parameters(open: open, close: close, into: &decl, promoted: &promoted)
    if !(isMember && word.lowercased() == "__construct") { promoted = [] }
    if unit.isByte(i, 0x7B) {
      let after = unit.skipBalanced(i)
      decl.bodyOpen = Int32(i)
      decl.bodyClose = Int32(after - 1)
      bodies.append((i + 1, after - 1))
      i = after
    } else if unit.isByte(i, 0x3B) {
      i += 1
    }
    decl.end = Int32(min(count, i))
    add(decl)
    for param in promoted {
      var property = newDecl(.variable, name: PHPKey.property(unit.string(Int(param.nameToken))), nameToken: Int(param.nameToken), first: Int(param.nameToken), parent: parent)
      property.typeStart = param.typeStart
      property.typeEnd = param.typeEnd
      property.end = param.nameToken + 1
      add(property)
    }
    return i
  }

  /// Parameters: `[attributes] [modifiers] [type] [&] [...] $name [= default]`.
  mutating func parameters(open: Int, close: Int, into decl: inout Decl, promoted: inout [Param]) {
    decl.paramStart = Int32(unit.params.count)
    var i = open + 1
    while i < close {
      var segmentEnd = i
      while segmentEnd < close, !unit.isByte(segmentEnd, 0x2C) {
        if unit.tokens[segmentEnd].kind == .open { segmentEnd = unit.skipBalanced(segmentEnd) } else { segmentEnd += 1 }
      }
      var k = i
      var promoting = false
      while k < segmentEnd, unit.phIsModifier(k) || unit.tokens[k].kind == .attribute {
        if unit.tokens[k].kind != .attribute { promoting = true }
        k += 1
      }
      let typeStart = k
      var v = k
      while v < segmentEnd, !unit.phIsVariable(v) { v += 1 }
      if v < segmentEnd {
        let dollar = v - 1
        let word = unit.string(v)
        let hasDefault = unit.isToken(v + 1, "=")
        let variadic = unit.string(dollar).contains("...")
        let param = Param(
          label: name(word), local: name(word), nameToken: Int32(v), typeStart: Int32(dollar > typeStart ? typeStart : -1),
          typeEnd: Int32(dollar > typeStart ? dollar : -1), hasDefault: hasDefault, variadic: variadic)
        unit.params.append(param)
        decl.paramCount += 1
        if promoting { promoted.append(param) }
      }
      i = segmentEnd + 1
    }
  }
}
