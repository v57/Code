import CodeModel
import CodeScan
import Foundation

/// Rust's items into the core's tables:
///
/// - `struct` and `union` are `structure`s with their fields as children (a tuple struct's fields named `0`, `1`… at
///   the token before each), `enum` an `enumeration` with `enumCase` variants holding their fields, `trait` a
///   `protocolType` (supertraits in its inherited ranges; `type Item` an `associatedType`), `mod` a `namespace`
///   (inline with its items, or `mod x;` with no body), `macro_rules!` a `macro`.
/// - `impl [Trait for] Type` is an `extensionDecl` named after Type's last name (`<blanket>` when Type is one of the
///   impl's own parameters, `slice`, `array`, `tuple`, `pointer`, `fn` for those), Type in its `type…` range and the
///   trait in its one inherited range.
/// - `fn` is a `function` (`isStatic` without `self`), its return type the `type…` range, `where` kept as a range;
///   `self` is a parameter labelled `self`. `const` and `static` are static `variable`s, `type` a `typeAlias`.
/// - `use` trees become one `Import` per leaf: `moduleName` the path before it (`crate::a`), `member` the leaf (`*` for a
///   glob, 0 for `self`), `alias` from `as`; `isExported` for `pub use`. `extern crate x as y` is `::x` as y.
/// - Items `#[cfg]` leaves out on this Mac aren't read (their source range is kept in `leftOutRanges` with a key for
///   their conditions, so that a question inside one reads it with every item of the same conditions: the core's
///   focus, a whole branch like `#if`'s), `#[cfg(test)]` modules are, with `test` on inside them;
///   `cfg_if!` takes its first branch that holds, and `cfg_*! { … }` macros (tokio's) are read as their items.
/// - Items in function bodies are the function's children.
struct RustParser {
  let unit: Unit
  let config: RustConfig
  let features: Set<String>
  var shape: UInt64 = 14_695_981_039_346_656_037
  private var count: Int { unit.tokens.count }
  private var focusToken = -1
  private var bodies: [(Int, Int)] = []
  /// `macro_rules! name { () => { items } }` with that one rule: its items, read where `name!()` stands.
  private var trivialMacros: [String: (Int, Int)] = [:]

  init(unit: Unit, config: RustConfig) {
    self.unit = unit
    self.config = config
    features = config.features(forPath: unit.path)
    if let offset = unit.focusOffset, let token = unit.token(at: offset) { focusToken = token }
  }

  mutating func parseFile() {
    let test = config.isTestFile(unit.path)
    var i = 0
    // `#![cfg(…)]` at the top: the whole file.
    var attributes = Attributes()
    while i + 2 < count, unit.isByte(i, 0x23), unit.isByte(i + 1, 0x21), unit.isByte(i + 2, 0x5B) {
      i = attribute(i + 2, into: &attributes, test: test)
    }
    if !attributes.active, focusToken < 0, unit.focusKey == 0 || attributes.offKey != unit.focusKey {
      unit.leftOutRanges.append((0, unit.source.count, attributes.offKey))
      return
    }
    if !attributes.active { unit.focusedRanges.append((0, unit.source.count)) }
    items(from: i, to: count, parent: -1, test: test, container: .module)
    procMacros()
    // The shape: every token outside function bodies.
    bodies.sort { $0.0 < $1.0 }
    var k = 0
    var b = 0
    while k < count {
      if b < bodies.count, k >= bodies[b].0 {
        k = max(k, bodies[b].1)
        b += 1
        continue
      }
      shape = (shape ^ unit.hash(k)) &* 1_099_511_628_211
      k += 1
    }
  }

  enum Container { case module, impl, trait, foreign, body }

  struct Attributes {
    var active = true
    /// The conditions that left it out, as a key (their tokens' text): items with the same key are one branch.
    var offKey: UInt64 = 0
    var path: String?
    var isTestModule = false
    var macroExport = false
  }

  // MARK: Items

  /// Items from `from` to `to` (a `}` or the file's end).
  mutating func items(from: Int, to: Int, parent: Int32, test: Bool, container: Container) {
    var i = from
    while i < to {
      let next = item(i, to: to, parent: parent, test: test, container: container)
      i = max(next, i + 1)
    }
  }

  /// One item from `at` (its attributes first); returns the token after it.
  mutating func item(_ at: Int, to: Int, parent: Int32, test: Bool, container: Container) -> Int {
    var i = at
    var attributes = Attributes()
    while i + 1 < to, unit.isByte(i, 0x23), unit.isByte(i + 1, 0x5B) || (unit.isByte(i + 1, 0x21) && unit.isByte(i + 2, 0x5B)) {
      i = attribute(unit.isByte(i + 1, 0x21) ? i + 2 : i + 1, into: &attributes, test: test)
    }
    guard i < to else { return to }
    let first = i
    var access = Access.isPrivate
    if container == .trait { access = .isPublic }
    if unit.isToken(i, "pub") {
      access = .isPublic
      i += 1
      if unit.isByte(i, 0x28), unit.isToken(i + 1, "crate") || unit.isToken(i + 1, "self") || unit.isToken(i + 1, "super") || unit.isToken(i + 1, "in") {
        access = .package
        i = unit.skipBalanced(i)
      }
    }
    // Qualifiers: `default`, `const fn`, `async`, `unsafe`, `extern "C" fn`, `safe`.
    while i < to {
      if unit.isToken(i, "default") && (unit.isToken(i + 1, "fn") || unit.isToken(i + 1, "type") || unit.isToken(i + 1, "const") || unit.isToken(i + 1, "unsafe") || unit.isToken(i + 1, "async") || unit.isToken(i + 1, "impl")) {
        i += 1
      } else if unit.isToken(i, "const"), unit.isToken(i + 1, "fn") || unit.isToken(i + 1, "unsafe") || unit.isToken(i + 1, "async") || unit.isToken(i + 1, "extern") {
        i += 1
      } else if unit.isToken(i, "async"), unit.isToken(i + 1, "fn") || unit.isToken(i + 1, "unsafe") || unit.isToken(i + 1, "extern") {
        i += 1
      } else if unit.isToken(i, "unsafe") || unit.isToken(i, "safe"), !unit.isByte(i + 1, 0x7B) {
        i += 1
      } else if unit.isToken(i, "extern"), unit.tokens[i + 1].kind == .string, unit.isToken(i + 2, "fn") || unit.isToken(i + 2, "unsafe") {
        i += 2
      } else if unit.isToken(i, "extern"), unit.isToken(i + 1, "fn") {
        i += 1
      } else {
        break
      }
    }
    // Left out, unless the focus is in it or in another item of the same conditions.
    let focused = !attributes.active && (focusToken >= first && focusToken < itemEnd(i, to: to) || unit.focusKey != 0 && attributes.offKey == unit.focusKey)
    if !attributes.active, first < count {
      let end = itemEnd(i, to: to)
      let startOffset = unit.tokens[at].start
      let endOffset = end > 0 && end - 1 < count ? unit.tokens[end - 1].end : unit.source.count
      if focused {
        unit.focusedRanges.append((startOffset, endOffset))
      } else {
        unit.leftOutRanges.append((startOffset, endOffset, attributes.offKey))
        return end
      }
    } else if !attributes.active, !focused {
      return itemEnd(i, to: to)
    }
    let innerTest = test || attributes.isTestModule
    guard i < to else { return to }
    if unit.isToken(i, "fn") { return function(i, first: first, to: to, parent: parent, access: access, test: test, container: container) }
    if unit.isToken(i, "use") { return useItem(i, to: to, isPublic: access == .isPublic) }
    if unit.isToken(i, "struct") || (unit.isToken(i, "union") && unit.tokens[i + 1].kind == .identifier) {
      return structure(i, first: first, to: to, parent: parent, access: access, test: test)
    }
    if unit.isToken(i, "enum") { return enumeration(i, first: first, to: to, parent: parent, access: access, test: test) }
    if unit.isToken(i, "trait") || (unit.isToken(i, "auto") && unit.isToken(i + 1, "trait")) {
      return trait(unit.isToken(i, "auto") ? i + 1 : i, first: first, to: to, parent: parent, access: access, test: test)
    }
    if unit.isToken(i, "impl") { return implementation(i, first: first, to: to, parent: parent, test: test) }
    if unit.isToken(i, "mod") { return module(i, first: first, to: to, parent: parent, access: access, test: innerTest) }
    if unit.isToken(i, "type") { return typeItem(i, first: first, to: to, parent: parent, access: access, container: container) }
    if unit.isToken(i, "const") || unit.isToken(i, "static") {
      if unit.isToken(i, "const"), unit.isByte(i + 1, 0x7B) { return container == .body ? i + 1 : unit.skipBalanced(i + 1) }
      return value(i, first: first, to: to, parent: parent, access: access, test: test)
    }
    if unit.isToken(i, "macro_rules"), unit.isByte(i + 1, 0x21), i + 2 < to {
      return macroRules(i, first: first, to: to, parent: parent, exported: attributes.macroExport)
    }
    if unit.isToken(i, "extern") {
      if unit.isToken(i + 1, "crate") { return externCrate(i, to: to) }
      var k = i + 1
      if k < to, unit.tokens[k].kind == .string { k += 1 }
      if unit.isByte(k, 0x7B) {
        let close = unit.skipBalanced(k) - 1
        items(from: k + 1, to: close, parent: parent, test: test, container: .foreign)
        return close + 1
      }
      return k
    }
    // An item-level macro: `cfg_if! { … }`, tokio's `cfg_rt! { … }`, `thread_local! { … }`.
    if container != .body, unit.tokens[i].kind == .identifier, unit.isByte(i + 1, 0x21), i + 2 < to, unit.tokens[i + 2].kind == .open {
      return macroItem(i, to: to, parent: parent, test: test, container: container)
    }
    if container == .body { return i + 1 }
    // Anything else: past its end.
    return itemEnd(i, to: to)
  }

  /// The end of an item that isn't read: through its `;` or its body's `}`.
  func itemEnd(_ from: Int, to: Int) -> Int {
    var i = from
    while i < to {
      if unit.isByte(i, 0x3B) { return i + 1 }
      if unit.isByte(i, 0x7B) { return unit.skipBalanced(i) }
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.tokens[i].kind == .close { return i }
      i += 1
    }
    return to
  }

  // MARK: Attributes

  /// `[…]` from its `[`: what it says about the item. Returns the token after its `]`.
  mutating func attribute(_ open: Int, into attributes: inout Attributes, test: Bool) -> Int {
    let close = unit.skipBalanced(open)
    read(from: open + 1, to: close - 1, into: &attributes, test: test)
    return close
  }

  /// A key for a condition's text, combined with the one before.
  private func conditionKey(_ before: UInt64, from start: Int, to end: Int) -> UInt64 {
    var key = before &* 1_099_511_628_211 &+ 14_695_981_039_346_656_037
    for t in start..<max(start, end) { key = (key ^ unit.hash(t)) &* 1_099_511_628_211 }
    return key == 0 ? 1 : key
  }

  private func read(from start: Int, to end: Int, into attributes: inout Attributes, test: Bool) {
    guard start < end else { return }
    if unit.isToken(start, "cfg"), unit.isByte(start + 1, 0x28) {
      var k = start + 2
      let holds = condition(&k, test: test)
      if !holds {
        attributes.active = false
        attributes.offKey = conditionKey(attributes.offKey, from: start + 2, to: unit.skipBalanced(start + 1) - 1)
      }
      if mentionsOnlyTest(start + 2, unit.skipBalanced(start + 1) - 1) { attributes.isTestModule = true }
    } else if unit.isToken(start, "cfg_attr"), unit.isByte(start + 1, 0x28) {
      var k = start + 2
      let holds = condition(&k, test: test)
      let close = unit.skipBalanced(start + 1) - 1
      guard holds, unit.isByte(k, 0x2C) else { return }
      k += 1
      // The attributes it adds, each up to a comma.
      while k < close {
        var e = k
        while e < close, !unit.isByte(e, 0x2C) { e = unit.tokens[e].kind == .open ? unit.skipBalanced(e) : e + 1 }
        read(from: k, to: e, into: &attributes, test: test)
        k = e + 1
      }
    } else if unit.isToken(start, "path"), unit.isByte(start + 1, 0x3D), start + 2 < end, unit.tokens[start + 2].kind == .string {
      attributes.path = RustParser.unquote(unit.string(start + 2))
    } else if unit.isToken(start, "macro_export") {
      attributes.macroExport = true
    }
  }

  /// `#[cfg(test)]`, `#[cfg(all(test, …))]`: a test module, read with `test` on.
  private func mentionsOnlyTest(_ start: Int, _ end: Int) -> Bool {
    var sawTest = false
    for k in start..<max(start, end) where unit.tokens[k].kind == .identifier {
      if unit.isToken(k, "test") { sawTest = true }
      if unit.isToken(k, "not"), unit.isByte(k + 1, 0x28), unit.isToken(k + 2, "test") { return false }
      if unit.isToken(k, "any") { return false }
    }
    return sawTest
  }

  static func unquote(_ text: String) -> String {
    var value = text
    if value.hasPrefix("r") { value.removeFirst() }
    while value.hasPrefix("#"), value.hasSuffix("#") {
      value.removeFirst()
      value.removeLast()
    }
    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
    return value
  }

  /// A cfg predicate from `i` (`all(…)`, `any(…)`, `not(…)`, `name`, `name = "value"`), with `i` past it.
  func condition(_ i: inout Int, test: Bool) -> Bool {
    guard i < count else { return false }
    if unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword {
      let word = unit.string(i)
      if (word == "all" || word == "any" || word == "not"), unit.isByte(i + 1, 0x28) {
        let close = unit.skipBalanced(i + 1) - 1
        var k = i + 2
        var values: [Bool] = []
        while k < close {
          let start = k
          values.append(condition(&k, test: test))
          if unit.isByte(k, 0x2C) { k += 1 }
          if k == start { k += 1 }
        }
        i = close + 1
        switch word {
        case "all": return values.allSatisfy { $0 }
        case "any": return values.contains(true)
        default: return !(values.first ?? false)
        }
      }
      i += 1
      if unit.isByte(i, 0x3D), i + 1 < count, unit.tokens[i + 1].kind == .string {
        let value = RustParser.unquote(unit.string(i + 1))
        i += 2
        return RustConfig.holds(word, value, features: features, test: test)
      }
      return RustConfig.holds(word, nil, features: features, test: test)
    }
    i += 1
    return false
  }

  // MARK: Generics and types

  /// The token after the `>` that closes the `<` at `open`: brackets skipped, `<` and `>` counted.
  func angleEnd(_ open: Int, limit: Int? = nil) -> Int {
    let end = limit ?? count
    var depth = 0
    var i = open
    while i < end {
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.tokens[i].kind == .close || unit.isByte(i, 0x3B) { return i }
      if unit.isByte(i, 0x3C) {
        depth += 1
      } else if unit.isByte(i, 0x3E) {
        depth -= 1
        if depth == 0 { return i + 1 }
      }
      i += 1
    }
    return end
  }

  /// `<'a, T: Bound, const N: usize>`: the names into the decl's generics (bounds are read from tokens later).
  mutating func genericParameters(_ open: Int, into decl: inout Decl) -> Int {
    let close = angleEnd(open) - 1
    decl.genericStart = Int32(unit.generics.count)
    var i = open + 1
    while i < close {
      if unit.isToken(i, "const"), i + 1 < close { i += 1 }
      if unit.tokens[i].kind == .identifier || unit.isToken(i, "Self") {
        unit.generics.append(Generic(name: unit.hash(i), token: Int32(i)))
        decl.genericCount += 1
      }
      i = listItemEnd(i, limit: close, angles: true) + 1
    }
    return close + 1
  }

  /// The end of a comma-separated item at depth 0 (the comma's index, or `limit`); with `angles`, `<…>` nests.
  func listItemEnd(_ from: Int, limit: Int, angles: Bool) -> Int {
    var i = from
    var depth = 0
    while i < limit {
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if angles {
        if unit.isByte(i, 0x3C) { depth += 1 } else if unit.isByte(i, 0x3E), depth > 0 { depth -= 1 }
      }
      if depth == 0, unit.isByte(i, 0x2C) { return i }
      i += 1
    }
    return limit
  }

  /// The end of a type written from `i`, before one of `stops` at depth 0 (`,`, `;`, `=`, `{`, `where`…).
  func typeEnd(_ from: Int, limit: Int, stopAtBrace: Bool = true, stopAtEquals: Bool = true) -> Int {
    var i = from
    var depth = 0
    while i < limit {
      let token = unit.tokens[i]
      if token.kind == .open {
        if stopAtBrace, depth == 0, unit.isByte(i, 0x7B) { return i }
        i = unit.skipBalanced(i)
        continue
      }
      if token.kind == .close { return i }
      if unit.isByte(i, 0x3C) {
        depth += 1
      } else if unit.isByte(i, 0x3E) {
        if depth == 0 { return i }
        depth -= 1
      } else if depth == 0 {
        if unit.isByte(i, 0x2C) || unit.isByte(i, 0x3B) || unit.isToken(i, "where") || unit.isToken(i, "=>") { return i }
        if stopAtEquals, unit.isByte(i, 0x3D) { return i }
      }
      i += 1
    }
    return limit
  }

  /// `where …` up to the body or `;`.
  private func whereClause(_ at: Int, limit: Int, into decl: inout Decl) -> Int {
    guard unit.isToken(at, "where") else { return at }
    var i = at + 1
    var depth = 0
    while i < limit {
      if unit.isByte(i, 0x7B), depth == 0 { break }
      if unit.isByte(i, 0x3B), depth == 0 { break }
      if unit.tokens[i].kind == .open, !unit.isByte(i, 0x7B) {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.isByte(i, 0x3C) { depth += 1 } else if unit.isByte(i, 0x3E), depth > 0 { depth -= 1 }
      if unit.tokens[i].kind == .close { break }
      i += 1
    }
    decl.whereStart = Int32(at + 1)
    decl.whereEnd = Int32(i)
    return i
  }

  // MARK: Functions

  mutating func function(_ at: Int, first: Int, to: Int, parent: Int32, access: Access, test: Bool, container: Container) -> Int {
    var i = at + 1
    guard i < to, unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword else { return i }
    var decl = Decl(kind: .function, name: unit.hash(i), nameToken: Int32(i), first: Int32(first), parent: parent)
    decl.access = access
    i += 1
    if unit.isByte(i, 0x3C) { i = genericParameters(i, into: &decl) }
    guard unit.isByte(i, 0x28) else { return i }
    let close = unit.skipBalanced(i) - 1
    let hasSelf = parameters(open: i, close: close, into: &decl)
    decl.isStatic = !hasSelf && (container == .impl || container == .trait)
    i = close + 1
    if unit.isToken(i, "->") {
      let start = i + 1
      i = typeEnd(start, limit: to)
      decl.typeStart = Int32(start)
      decl.typeEnd = Int32(i)
    }
    i = whereClause(i, limit: to, into: &decl)
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    if unit.isByte(i, 0x7B) {
      let end = unit.skipBalanced(i)
      unit.decls[Int(index)].bodyOpen = Int32(i)
      unit.decls[Int(index)].bodyClose = Int32(end - 1)
      bodies.append((i + 1, end - 1))
      bodyItems(open: i, close: end - 1, parent: index, test: test)
      i = end
    } else if unit.isByte(i, 0x3B) {
      i += 1
    }
    unit.decls[Int(index)].end = Int32(i)
    return i
  }

  /// Parameters: `self` forms labelled `self`, `pattern: Type` with the pattern's one name when it has one.
  /// Returns whether there's a `self`.
  mutating func parameters(open: Int, close: Int, into decl: inout Decl) -> Bool {
    decl.paramStart = Int32(unit.params.count)
    var hasSelf = false
    var i = open + 1
    while i < close {
      let end = listItemEnd(i, limit: close, angles: true)
      var start = i
      while start < end, unit.isByte(start, 0x23), unit.isByte(start + 1, 0x5B) { start = unit.skipBalanced(start + 1) }
      defer { i = end + 1 }
      guard start < end else { continue }
      // `self`, `mut self`, `&self`, `&'a mut self`, `self: Box<Self>`.
      var k = start
      while k < end, unit.isByte(k, 0x26) || unit.isToken(k, "&&") || unit.isToken(k, "mut") || (unit.tokens[k].kind == .string && unit.source.text[unit.tokens[k].start] == 0x27) { k += 1 }
      if k < end, unit.isToken(k, "self") {
        hasSelf = true
        if unit.isByte(k + 1, 0x3A), k + 2 < end {
          unit.params.append(Param(label: RustWord.selfValue, local: RustWord.selfValue, nameToken: Int32(k), typeStart: Int32(k + 2), typeEnd: Int32(end), hasDefault: false, variadic: false))
        } else {
          unit.params.append(Param(label: RustWord.selfValue, local: RustWord.selfValue, nameToken: Int32(k), typeStart: Int32(start), typeEnd: Int32(k + 1), hasDefault: false, variadic: false))
        }
        decl.paramCount += 1
        continue
      }
      // The pattern ends at the first `:` at depth 0.
      var colon = start
      while colon < end, !unit.isByte(colon, 0x3A) {
        colon = unit.tokens[colon].kind == .open ? unit.skipBalanced(colon) : colon + 1
      }
      if colon >= end {
        // A type alone (a trait method in 2015, `...` of a C function).
        unit.params.append(Param(label: 0, local: 0, nameToken: -1, typeStart: Int32(start), typeEnd: Int32(end), hasDefault: false, variadic: unit.isToken(start, "...")))
        decl.paramCount += 1
        continue
      }
      var nameAt = start
      while nameAt < colon, unit.isToken(nameAt, "mut") || unit.isToken(nameAt, "ref") { nameAt += 1 }
      let simple = nameAt == colon - 1 && unit.tokens[nameAt].kind == .identifier
      unit.params.append(
        Param(label: 0, local: simple ? unit.hash(nameAt) : 0, nameToken: simple ? Int32(nameAt) : -1, typeStart: Int32(colon + 1), typeEnd: Int32(end), hasDefault: false, variadic: false))
      decl.paramCount += 1
    }
    return hasSelf
  }

  /// Items written inside a function's body: at a statement's start.
  mutating func bodyItems(open: Int, close: Int, parent: Int32, test: Bool) {
    var i = open + 1
    while i < close {
      let previous = i - 1
      let atStatement = unit.isByte(previous, 0x7B) || unit.isByte(previous, 0x3B) || unit.isByte(previous, 0x7D) || unit.isByte(previous, 0x5D)
      if atStatement, startsItem(i) {
        let next = item(i, to: close, parent: parent, test: test, container: .body)
        if next > i {
          i = next
          continue
        }
      }
      i += 1
    }
  }

  private func startsItem(_ i: Int) -> Bool {
    let token = unit.tokens[i]
    if token.kind == .punctuation, unit.isByte(i, 0x23), unit.isByte(i + 1, 0x5B) {
      // An attribute on a statement or an item: look past it.
      let after = unit.skipBalanced(i + 1)
      return after < count && startsItem(after)
    }
    guard token.kind == .keyword || token.kind == .declarationKeyword || token.kind == .identifier else { return false }
    if unit.isToken(i, "fn") || unit.isToken(i, "struct") || unit.isToken(i, "enum") || unit.isToken(i, "trait") || unit.isToken(i, "impl") || unit.isToken(i, "use")
      || unit.isToken(i, "mod") || unit.isToken(i, "static") || unit.isToken(i, "pub")
    {
      return !unit.isByte(i + 1, 0x7B)
    }
    if unit.isToken(i, "type") { return unit.tokens[i + 1].kind == .identifier }
    if unit.isToken(i, "const") { return unit.tokens[i + 1].kind == .identifier && unit.isByte(i + 2, 0x3A) || unit.isToken(i + 1, "fn") || unit.isToken(i + 1, "unsafe") }
    if unit.isToken(i, "macro_rules") { return unit.isByte(i + 1, 0x21) }
    if unit.isToken(i, "unsafe") { return unit.isToken(i + 1, "fn") || unit.isToken(i + 1, "impl") || unit.isToken(i + 1, "trait") || unit.isToken(i + 1, "extern") }
    if unit.isToken(i, "async") { return unit.isToken(i + 1, "fn") || unit.isToken(i + 1, "unsafe") }
    if unit.isToken(i, "extern") { return unit.isToken(i + 1, "crate") || unit.tokens[i + 1].kind == .string || unit.isByte(i + 1, 0x7B) }
    if unit.isToken(i, "union") { return unit.tokens[i + 1].kind == .identifier }
    return false
  }

  // MARK: Types

  mutating func structure(_ at: Int, first: Int, to: Int, parent: Int32, access: Access, test: Bool) -> Int {
    var i = at + 1
    guard i < to, unit.tokens[i].kind == .identifier else { return i }
    var decl = Decl(kind: .structure, name: unit.hash(i), nameToken: Int32(i), first: Int32(first), parent: parent)
    decl.access = access
    i += 1
    if unit.isByte(i, 0x3C) { i = genericParameters(i, into: &decl) }
    i = whereClause(i, limit: to, into: &decl)
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    if unit.isByte(i, 0x7B) || unit.isByte(i, 0x28) {
      let isTuple = unit.isByte(i, 0x28)
      let close = unit.skipBalanced(i) - 1
      unit.decls[Int(index)].bodyOpen = Int32(i)
      unit.decls[Int(index)].bodyClose = Int32(close)
      fields(open: i, close: close, owner: index, tuple: isTuple, test: test)
      i = close + 1
      if isTuple {
        var holder = unit.decls[Int(index)]
        i = whereClause(i, limit: to, into: &holder)
        unit.decls[Int(index)] = holder
      }
    }
    if unit.isByte(i, 0x3B) { i += 1 }
    unit.decls[Int(index)].end = Int32(i)
    return i
  }

  /// A struct's or variant's fields as `variable` children.
  mutating func fields(open: Int, close: Int, owner: Int32, tuple: Bool, test: Bool) {
    var i = open + 1
    var position = 0
    while i < close {
      let end = listItemEnd(i, limit: close, angles: true)
      defer { i = end + 1 }
      var start = i
      var attributes = Attributes()
      while start < end, unit.isByte(start, 0x23), unit.isByte(start + 1, 0x5B) { start = attribute(start + 1, into: &attributes, test: test) }
      guard start < end else { continue }
      let fieldFirst = start
      var access = Access.isPrivate
      if unit.isToken(start, "pub") {
        access = .isPublic
        start += 1
        if unit.isByte(start, 0x28), unit.isToken(start + 1, "crate") || unit.isToken(start + 1, "self") || unit.isToken(start + 1, "super") || unit.isToken(start + 1, "in") {
          access = .package
          start = unit.skipBalanced(start)
        }
      }
      guard start < end else { continue }
      if !attributes.active {
        position += 1
        continue
      }
      if tuple {
        var field = Decl(kind: .variable, name: name(String(position)), nameToken: Int32(start - 1), first: Int32(fieldFirst), parent: owner)
        field.access = access
        field.typeStart = Int32(start)
        field.typeEnd = Int32(end)
        field.end = Int32(end)
        unit.decls.append(field)
      } else if unit.tokens[start].kind == .identifier || unit.tokens[start].kind == .keyword, unit.isByte(start + 1, 0x3A) {
        var field = Decl(kind: .variable, name: unit.hash(start), nameToken: Int32(start), first: Int32(fieldFirst), parent: owner)
        field.access = access
        field.typeStart = Int32(start + 2)
        // `field: Type = default` (default field values).
        field.typeEnd = Int32(typeEnd(start + 2, limit: end, stopAtBrace: false))
        field.end = Int32(end)
        unit.decls.append(field)
      }
      position += 1
    }
  }

  mutating func enumeration(_ at: Int, first: Int, to: Int, parent: Int32, access: Access, test: Bool) -> Int {
    var i = at + 1
    guard i < to, unit.tokens[i].kind == .identifier else { return i }
    var decl = Decl(kind: .enumeration, name: unit.hash(i), nameToken: Int32(i), first: Int32(first), parent: parent)
    decl.access = access
    i += 1
    if unit.isByte(i, 0x3C) { i = genericParameters(i, into: &decl) }
    i = whereClause(i, limit: to, into: &decl)
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    guard unit.isByte(i, 0x7B) else { return i }
    let close = unit.skipBalanced(i) - 1
    unit.decls[Int(index)].bodyOpen = Int32(i)
    unit.decls[Int(index)].bodyClose = Int32(close)
    var k = i + 1
    while k < close {
      let end = listItemEnd(k, limit: close, angles: false)
      defer { k = end + 1 }
      var start = k
      var attributes = Attributes()
      while start < end, unit.isByte(start, 0x23), unit.isByte(start + 1, 0x5B) { start = attribute(start + 1, into: &attributes, test: test) }
      if unit.isToken(start, "pub") { start += 1 }
      guard start < end, unit.tokens[start].kind == .identifier || unit.tokens[start].kind == .keyword, attributes.active else { continue }
      var variant = Decl(kind: .enumCase, name: unit.hash(start), nameToken: Int32(start), first: Int32(start), parent: index)
      variant.access = .isPublic
      variant.end = Int32(end)
      let variantIndex = Int32(unit.decls.count)
      unit.decls.append(variant)
      if unit.isByte(start + 1, 0x28) || unit.isByte(start + 1, 0x7B) {
        let fieldsClose = unit.skipBalanced(start + 1) - 1
        unit.decls[Int(variantIndex)].bodyOpen = Int32(start + 1)
        unit.decls[Int(variantIndex)].bodyClose = Int32(fieldsClose)
        fields(open: start + 1, close: fieldsClose, owner: variantIndex, tuple: unit.isByte(start + 1, 0x28), test: test)
        for f in Int(variantIndex + 1)..<unit.decls.count where unit.decls[f].parent == variantIndex { unit.decls[f].access = .isPublic }
      }
    }
    unit.decls[Int(index)].end = Int32(close + 1)
    return close + 1
  }

  mutating func trait(_ at: Int, first: Int, to: Int, parent: Int32, access: Access, test: Bool) -> Int {
    var i = at + 1
    guard i < to, unit.tokens[i].kind == .identifier else { return i }
    var decl = Decl(kind: .protocolType, name: unit.hash(i), nameToken: Int32(i), first: Int32(first), parent: parent)
    decl.access = access
    i += 1
    if unit.isByte(i, 0x3C) { i = genericParameters(i, into: &decl) }
    if unit.isByte(i, 0x3A) { i = bounds(i + 1, limit: to, into: &decl) }
    if unit.isByte(i, 0x3D) {
      // A trait alias: `trait A = B + C;`.
      i = bounds(i + 1, limit: to, into: &decl)
    }
    i = whereClause(i, limit: to, into: &decl)
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    if unit.isByte(i, 0x7B) {
      let close = unit.skipBalanced(i) - 1
      unit.decls[Int(index)].bodyOpen = Int32(i)
      unit.decls[Int(index)].bodyClose = Int32(close)
      items(from: i + 1, to: close, parent: index, test: test, container: .trait)
      i = close + 1
    } else if unit.isByte(i, 0x3B) {
      i += 1
    }
    unit.decls[Int(index)].end = Int32(i)
    return i
  }

  /// `A + B<C> + 'a + ?Sized` into the decl's inherited ranges, one per bound; returns the token after them.
  mutating func bounds(_ from: Int, limit: Int, into decl: inout Decl) -> Int {
    decl.inheritStart = Int32(unit.ranges.count)
    var i = from
    while i < limit {
      let end = boundEnd(i, limit: limit)
      var start = i
      if unit.isByte(start, 0x28) { start += 1 }
      if unit.isToken(start, "?") || unit.isToken(start, "~") { start += 1 }
      if unit.isToken(start, "const") { start += 1 }
      if unit.isToken(start, "for"), unit.isByte(start + 1, 0x3C) { start = angleEnd(start + 1) }
      if start < end, !(unit.tokens[start].kind == .string), !unit.isByte(i, 0x3F) {
        unit.ranges.append((Int32(start), Int32(end)))
        decl.inheritCount += 1
      }
      i = end
      if unit.isByte(i, 0x2B) { i += 1 } else { break }
    }
    return i
  }

  /// One bound's end: before a `+`, `,`, `{`, `;`, `=`, `where` or `>` at depth 0.
  func boundEnd(_ from: Int, limit: Int) -> Int {
    var i = from
    var depth = 0
    while i < limit {
      if unit.tokens[i].kind == .open {
        if unit.isByte(i, 0x7B), depth == 0 { return i }
        i = unit.skipBalanced(i)
        continue
      }
      if unit.tokens[i].kind == .close { return i }
      if unit.isByte(i, 0x3C) {
        depth += 1
      } else if unit.isByte(i, 0x3E) {
        if depth == 0 { return i }
        depth -= 1
      } else if depth == 0, unit.isByte(i, 0x2B) || unit.isByte(i, 0x2C) || unit.isByte(i, 0x3B) || unit.isByte(i, 0x3D) || unit.isToken(i, "where") {
        return i
      }
      i += 1
    }
    return limit
  }

  mutating func implementation(_ at: Int, first: Int, to: Int, parent: Int32, test: Bool) -> Int {
    var i = at + 1
    var decl = Decl(kind: .extensionDecl, name: 0, nameToken: -1, first: Int32(first), parent: parent)
    if unit.isByte(i, 0x3C) { i = genericParameters(i, into: &decl) }
    if unit.isToken(i, "const") { i += 1 }
    var negative = false
    if unit.isByte(i, 0x21) {
      negative = true
      i += 1
    }
    // `Trait for Type`, or `Type`.
    let start = i
    var forToken = -1
    var depth = 0
    var k = i
    while k < to {
      if unit.tokens[k].kind == .open {
        if unit.isByte(k, 0x7B), depth == 0 { break }
        k = unit.skipBalanced(k)
        continue
      }
      if unit.tokens[k].kind == .close || unit.isByte(k, 0x3B) { break }
      if unit.isByte(k, 0x3C) { depth += 1 } else if unit.isByte(k, 0x3E), depth > 0 { depth -= 1 }
      if depth == 0, unit.isToken(k, "where") { break }
      if depth == 0, unit.isToken(k, "for"), !unit.isByte(k + 1, 0x3C), forToken < 0 { forToken = k }
      k += 1
    }
    let typeStart = forToken >= 0 ? forToken + 1 : start
    decl.typeStart = Int32(typeStart)
    decl.typeEnd = Int32(k)
    if forToken >= 0, !negative {
      decl.inheritStart = Int32(unit.ranges.count)
      unit.ranges.append((Int32(start), Int32(forToken)))
      decl.inheritCount = 1
    }
    let (word, nameToken) = selfTypeName(typeStart, k, generics: decl)
    decl.name = word
    decl.nameToken = Int32(nameToken)
    i = whereClause(k, limit: to, into: &decl)
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    if unit.isByte(i, 0x7B) {
      let close = unit.skipBalanced(i) - 1
      unit.decls[Int(index)].bodyOpen = Int32(i)
      unit.decls[Int(index)].bodyClose = Int32(close)
      items(from: i + 1, to: close, parent: index, test: test, container: .impl)
      i = close + 1
    }
    unit.decls[Int(index)].end = Int32(i)
    return i
  }

  /// The name an impl is indexed by: its self type's last name, or what kind of type it is.
  func selfTypeName(_ start: Int, _ end: Int, generics decl: Decl) -> (Name, Int) {
    var i = start
    while i < end {
      if unit.isByte(i, 0x26) || unit.isToken(i, "&&") || unit.isToken(i, "mut") || unit.isToken(i, "dyn") || unit.isToken(i, "unsafe")
        || (unit.tokens[i].kind == .string && unit.source.text[unit.tokens[i].start] == 0x27)
      {
        i += 1
        continue
      }
      break
    }
    guard i < end else { return (0, start) }
    if unit.isByte(i, 0x2A) { return (RustWord.pointer, i) }
    if unit.isByte(i, 0x5B) {
      let close = unit.skipBalanced(i) - 1
      var k = i + 1
      while k < close {
        if unit.isByte(k, 0x3B) { return (RustWord.array, i) }
        k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
      }
      return (RustWord.slice, i)
    }
    if unit.isByte(i, 0x28) { return (RustWord.tuple, i) }
    if unit.isToken(i, "fn") || unit.isToken(i, "extern") { return (RustWord.function, i) }
    if unit.isByte(i, 0x3C) { return (0, i) }
    // A path: its last segment.
    var last = -1
    while i < end {
      if unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword { last = i }
      i += 1
      if unit.isByte(i, 0x3C) { break }
      if unit.isToken(i, "::") {
        i += 1
        continue
      }
      break
    }
    guard last >= 0 else { return (0, start) }
    let word = unit.hash(last)
    for g in 0..<Int(decl.genericCount) where unit.generics[Int(decl.genericStart) + g].name == word {
      return (RustWord.blanket, last)
    }
    return (word, last)
  }

  // MARK: Other items

  mutating func module(_ at: Int, first: Int, to: Int, parent: Int32, access: Access, test: Bool) -> Int {
    let i = at + 1
    guard i < to, unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword else { return i }
    var decl = Decl(kind: .namespace, name: unit.hash(i), nameToken: Int32(i), first: Int32(first), parent: parent)
    decl.access = access
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    if unit.isByte(i + 1, 0x7B) {
      let close = unit.skipBalanced(i + 1) - 1
      unit.decls[Int(index)].bodyOpen = Int32(i + 1)
      unit.decls[Int(index)].bodyClose = Int32(close)
      var k = i + 2
      // Inner attributes: `#![cfg(…)]` on the module.
      var attributes = Attributes()
      while k + 2 < close, unit.isByte(k, 0x23), unit.isByte(k + 1, 0x21), unit.isByte(k + 2, 0x5B) {
        k = attribute(k + 2, into: &attributes, test: test)
      }
      items(from: k, to: close, parent: index, test: test || attributes.isTestModule, container: .module)
      unit.decls[Int(index)].end = Int32(close + 1)
      return close + 1
    }
    let end = unit.isByte(i + 1, 0x3B) ? i + 2 : i + 1
    unit.decls[Int(index)].end = Int32(end)
    return end
  }

  mutating func typeItem(_ at: Int, first: Int, to: Int, parent: Int32, access: Access, container: Container) -> Int {
    var i = at + 1
    guard i < to, unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword else { return i }
    var decl = Decl(kind: container == .trait ? .associatedType : .typeAlias, name: unit.hash(i), nameToken: Int32(i), first: Int32(first), parent: parent)
    decl.access = access
    i += 1
    if unit.isByte(i, 0x3C) { i = genericParameters(i, into: &decl) }
    if unit.isByte(i, 0x3A) { i = bounds(i + 1, limit: to, into: &decl) }
    i = whereClause(i, limit: to, into: &decl)
    if unit.isByte(i, 0x3D) {
      let start = i + 1
      i = typeEnd(start, limit: to, stopAtBrace: false)
      decl.typeStart = Int32(start)
      decl.typeEnd = Int32(i)
      i = whereClause(i, limit: to, into: &decl)
    }
    if unit.isByte(i, 0x3B) { i += 1 }
    decl.end = Int32(i)
    unit.decls.append(decl)
    return i
  }

  /// `const NAME: T = v;`, `static [mut] NAME: T = v;`.
  mutating func value(_ at: Int, first: Int, to: Int, parent: Int32, access: Access, test: Bool) -> Int {
    var i = at + 1
    if unit.isToken(i, "mut") { i += 1 }
    guard i < to, unit.tokens[i].kind == .identifier || unit.isToken(i, "_") else { return itemEnd(i, to: to) }
    let nameToken = i
    var decl = Decl(kind: .variable, name: unit.hash(i), nameToken: Int32(i), first: Int32(first), parent: parent)
    decl.access = access
    decl.isStatic = true
    i += 1
    if unit.isByte(i, 0x3C) { i = genericParameters(i, into: &decl) }
    if unit.isByte(i, 0x3A) {
      let start = i + 1
      i = typeEnd(start, limit: to)
      decl.typeStart = Int32(start)
      decl.typeEnd = Int32(i)
    }
    if unit.isByte(i, 0x3D) {
      let start = i + 1
      var k = start
      while k < to, !unit.isByte(k, 0x3B) {
        if unit.tokens[k].kind == .close { break }
        k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
      }
      decl.initStart = Int32(start)
      decl.initEnd = Int32(k)
      i = k
    }
    if unit.isByte(i, 0x3B) { i += 1 }
    decl.end = Int32(i)
    if unit.isToken(nameToken, "_") { return i }
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    // Function items in the value (closures' bodies are its own).
    if decl.initStart >= 0 { bodyItems(open: Int(decl.initStart) - 1, close: Int(decl.initEnd), parent: index, test: test) }
    return i
  }

  mutating func macroRules(_ at: Int, first: Int, to: Int, parent: Int32, exported: Bool) -> Int {
    let i = at + 2
    guard i < to, unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword else { return i }
    var decl = Decl(kind: .macro, name: unit.hash(i), nameToken: Int32(i), first: Int32(first), parent: parent)
    decl.access = exported ? .isPublic : .isPrivate
    var end = i + 1
    if end < to, unit.tokens[end].kind == .open {
      decl.bodyOpen = Int32(end)
      end = unit.skipBalanced(end)
      decl.bodyClose = Int32(end - 1)
    }
    if unit.isByte(end, 0x3B) { end += 1 }
    decl.end = Int32(end)
    // One rule taking nothing, `() => { … }`: what it writes is knowable, and read as items where it's invoked, so the
    // declaration covers only its name (its body isn't macro text then).
    if decl.bodyOpen >= 0 {
      let open = Int(decl.bodyOpen)
      let close = Int(decl.bodyClose)
      if unit.isByte(open + 1, 0x28), unit.isByte(open + 2, 0x29), unit.isToken(open + 3, "=>"), unit.tokens[open + 4].kind == .open {
        let bodyClose = unit.skipBalanced(open + 4) - 1
        var after = bodyClose + 1
        if unit.isByte(after, 0x3B) { after += 1 }
        if after == close {
          trivialMacros[unit.string(i)] = (open + 5, bodyClose)
          decl.end = Int32(i + 1)
        }
      }
    }
    unit.decls.append(decl)
    return end
  }

  /// A proc-macro crate's `#[proc_macro_derive(Name)] fn …`, `#[proc_macro] fn name`, `#[proc_macro_attribute] fn
  /// name`: macros, at the function.
  private mutating func procMacros() {
    let count = unit.decls.count
    for index in 0..<count {
      let item = unit.decls[index]
      guard item.kind == .function, item.parent < 0, item.nameToken >= 0 else { continue }
      var k = Int(item.first) - 1
      while k >= 1, unit.isByte(k, 0x5D), let open = unit.matchingOpen(k), open >= 1, unit.isByte(open - 1, 0x23) {
        var name: Name = 0
        if unit.isToken(open + 1, "proc_macro_derive"), unit.isByte(open + 2, 0x28), unit.tokens[open + 3].kind == .identifier {
          name = unit.hash(open + 3)
        } else if unit.isToken(open + 1, "proc_macro") || unit.isToken(open + 1, "proc_macro_attribute") {
          name = item.name
        }
        if name != 0 {
          var macro = Decl(kind: .macro, name: name, nameToken: item.nameToken, first: item.first, parent: -1)
          macro.access = .isPublic
          macro.end = item.nameToken + 1
          unit.decls.append(macro)
        }
        k = open - 2
      }
    }
  }

  /// `name! { … }` where items are: `cfg_if!`'s first branch that holds, `cfg_*!`'s items, `thread_local!`'s statics.
  mutating func macroItem(_ at: Int, to: Int, parent: Int32, test: Bool, container: Container) -> Int {
    let open = at + 2
    let close = unit.skipBalanced(open) - 1
    var end = close + 1
    if unit.isByte(end, 0x3B) { end += 1 }
    let word = unit.string(at)
    if word == "cfg_if" {
      cfgIf(open + 1, close, parent: parent, test: test, container: container)
    } else if word.hasPrefix("cfg_"), !word.contains("not"), unit.isByte(open, 0x7B) {
      items(from: open + 1, to: close, parent: parent, test: test, container: container)
    } else if let body = trivialMacros[word], close == open + 1 {
      items(from: body.0, to: body.1, parent: parent, test: test, container: container)
    } else if word == "thread_local" {
      // Its statics are `LocalKey<T>`s: marked failable for the model to wrap.
      let first = unit.decls.count
      items(from: open + 1, to: close, parent: parent, test: test, container: container)
      for k in first..<unit.decls.count where unit.decls[k].kind == .variable { unit.decls[k].isFailable = true }
    }
    return end
  }

  /// `if #[cfg(a)] { … } else if #[cfg(b)] { … } else { … }`.
  private mutating func cfgIf(_ from: Int, _ to: Int, parent: Int32, test: Bool, container: Container) {
    var i = from
    while i < to {
      if unit.isToken(i, "if") || unit.isToken(i, "else") && unit.isToken(i + 1, "if") {
        i += unit.isToken(i, "else") ? 2 : 1
        var attributes = Attributes()
        if unit.isByte(i, 0x23), unit.isByte(i + 1, 0x5B) { i = attribute(i + 1, into: &attributes, test: test) }
        guard unit.isByte(i, 0x7B) else { return }
        let close = unit.skipBalanced(i) - 1
        if attributes.active {
          items(from: i + 1, to: close, parent: parent, test: test, container: container)
          return
        }
        i = close + 1
      } else if unit.isToken(i, "else"), unit.isByte(i + 1, 0x7B) {
        let close = unit.skipBalanced(i + 1) - 1
        items(from: i + 2, to: close, parent: parent, test: test, container: container)
        return
      } else {
        i += 1
      }
    }
  }

  // MARK: use

  /// `use a::b::{c, d as e, f::*, self};`: one import per leaf.
  mutating func useItem(_ at: Int, to: Int, isPublic: Bool) -> Int {
    var end = at + 1
    while end < to, !unit.isByte(end, 0x3B) {
      if unit.tokens[end].kind == .close { break }
      end = unit.tokens[end].kind == .open ? unit.skipBalanced(end) : end + 1
    }
    useTree(at + 1, end, prefix: [], useToken: at, isPublic: isPublic)
    return unit.isByte(end, 0x3B) ? end + 1 : end
  }

  private mutating func useTree(_ from: Int, _ to: Int, prefix: [String], useToken: Int, isPublic: Bool) {
    var path = prefix
    var i = from
    if unit.isToken(i, "::") {
      path.append("")
      i += 1
    }
    while i < to {
      if unit.isByte(i, 0x7B) {
        let close = unit.skipBalanced(i) - 1
        var k = i + 1
        while k < close {
          let end = listItemEnd(k, limit: close, angles: false)
          if end > k { useTree(k, end, prefix: path, useToken: useToken, isPublic: isPublic) }
          k = end + 1
        }
        return
      }
      if unit.isByte(i, 0x2A) {
        add(path, member: RustWord.glob, memberToken: i, alias: 0, aliasToken: -1, useToken: useToken, isPublic: isPublic)
        return
      }
      guard unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword else { return }
      if unit.isToken(i + 1, "::") {
        path.append(unit.string(i))
        i += 2
        continue
      }
      var alias: Name = 0
      var aliasToken = -1
      if unit.isToken(i + 1, "as"), i + 2 < to {
        alias = unit.hash(i + 2)
        aliasToken = i + 2
      }
      if unit.isToken(i, "self"), !path.isEmpty {
        // `a::{self}`: the module a, named by its last segment unless renamed.
        add(path, member: 0, memberToken: i, alias: alias, aliasToken: aliasToken, useToken: useToken, isPublic: isPublic)
      } else {
        add(path, member: unit.hash(i), memberToken: i, alias: alias, aliasToken: aliasToken, useToken: useToken, isPublic: isPublic)
      }
      return
    }
  }

  private mutating func add(_ path: [String], member: Name, memberToken: Int, alias: Name, aliasToken: Int, useToken: Int, isPublic: Bool) {
    let moduleName = path.joined(separator: "::")
    var item = Import(module: name(moduleName), moduleName: moduleName, isExported: isPublic, isTestable: false)
    item.member = member
    item.memberToken = Int32(memberToken)
    item.alias = alias
    item.aliasToken = Int32(aliasToken)
    item.token = Int32(useToken)
    unit.imports.append(item)
  }

  /// `extern crate a as b;`: `::a` as b.
  mutating func externCrate(_ at: Int, to: Int) -> Int {
    let i = at + 2
    var end = i
    while end < to, !unit.isByte(end, 0x3B) { end += 1 }
    guard i < end, unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword else { return end + 1 }
    var item = Import(module: name("::"), moduleName: "::", isExported: false, isTestable: false)
    item.member = unit.isToken(i, "self") ? 0 : unit.hash(i)
    item.memberToken = Int32(i)
    if unit.isToken(i + 1, "as"), i + 2 < end {
      item.alias = unit.hash(i + 2)
      item.aliasToken = Int32(i + 2)
    }
    item.token = Int32(at)
    unit.imports.append(item)
    return end + 1
  }
}
