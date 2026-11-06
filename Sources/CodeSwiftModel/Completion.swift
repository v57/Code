import CodeScan
import Foundation

/// Completion: what could be typed at a position, read from the same layers as definitions. It works on the text being
/// edited (`Project.update`), which usually doesn't parse, so nothing here looks past the cursor.
public enum SwiftCompletionContext: String {
  /// After `a.`: what `a` has.
  case member
  /// After a lone `.`: what the surroundings ask for has.
  case implicitMember
  /// A name on its own: locals, the enclosing types' members, what the file's imports declare.
  case scope
  /// Where only a type goes.
  case type
  case moduleName
  case attribute
  case directive
  /// In a comment or string, or where a new name is being declared.
  case none
}

/// The values are the Language Server Protocol's `SwiftCompletionItemKind`s.
public enum SwiftCompletionItemKind: Int {
  case method = 2, function, constructor, field, variable, classType, interface, module, property
  case enumeration = 13, keyword, enumMember = 20, structure = 22, typeParameter = 25
}

public struct SwiftCompletionEntry {
  /// The name alone: what's matched against what's typed.
  public var name: String
  /// `name(label: Type)`.
  public var label: String
  /// A return or value type, as written.
  public var detail: String
  /// The module it's declared in, empty for a local or keyword.
  public var module: String
  public var kind: SwiftCompletionItemKind
  /// Plain, or with LSP placeholders when `isSnippet`.
  public var insertText: String
  public var isSnippet: Bool
  public var isDeprecated: Bool
  /// On an optional receiver: accepting this has to write `?.`.
  public var needsUnwrap: Bool
}

public struct SwiftCompletionList {
  public var context: SwiftCompletionContext
  /// How much is known about what's listed: `exact` when the receiver or scope is, `unknown` when these are names only.
  public var state: AnswerState
  public var prefix: String
  /// Where the text being replaced starts, in UTF-8 bytes.
  public var replaceStart: Int
  public var items: [SwiftCompletionEntry]
  /// More matched than `limit`.
  public var isIncomplete: Bool
}

private let expressionKeywords = [
  "self", "Self", "super", "nil", "true", "false", "try", "await", "if", "switch", "let", "var", "return", "guard", "for", "while", "repeat", "do", "defer",
  "throw", "break", "continue", "fallthrough", "func", "struct", "class", "enum", "case", "default", "in", "as", "is", "where", "else", "catch", "any", "some",
  "init", "import", "extension", "protocol", "actor", "typealias", "static", "private", "fileprivate", "internal", "public", "async", "throws", "weak", "unowned",
]

private let declarationKeywords = [
  "func", "var", "let", "init", "deinit", "subscript", "struct", "class", "enum", "case", "actor", "protocol", "extension", "typealias", "associatedtype", "static",
  "private", "fileprivate", "internal", "public", "package", "open", "override", "final", "mutating", "nonmutating", "lazy", "weak", "unowned", "convenience",
  "required", "indirect", "nonisolated", "import",
]

private let typeKeywords = ["Self", "Any", "any", "some", "inout", "consuming", "borrowing", "sending"]

private let attributeNames = [
  "available", "MainActor", "escaping", "autoclosure", "discardableResult", "objc", "objcMembers", "nonobjc", "main", "inlinable", "usableFromInline", "frozen",
  "propertyWrapper", "resultBuilder", "dynamicMemberLookup", "dynamicCallable", "testable", "preconcurrency", "Sendable", "unchecked", "IBAction", "IBOutlet",
  "NSApplicationMain", "UIApplicationMain", "NSCopying", "NSManaged", "warn_unqualified_access", "exported", "retroactive", "backDeployed", "globalActor", "ViewBuilder",
]

private let directiveNames = ["if", "elseif", "else", "endif", "available", "unavailable", "selector", "keyPath", "file", "fileID", "filePath", "line", "column", "function", "warning", "error", "sourceLocation", "dsohandle", "colorLiteral", "imageLiteral"]

/// How well typed text fits a name, best first; nil when it doesn't. Case matters only for telling them apart.
private func matchClass(_ typed: [UInt8], _ candidate: Substring.UTF8View) -> Int32? {
  if typed.isEmpty { return 0 }
  var exact = true
  var i = 0
  var isPrefix = true
  for byte in candidate {
    if i == typed.count { break }
    let a = byte
    let b = typed[i]
    if a != b { exact = false }
    if a | 0x20 != b | 0x20 {
      isPrefix = false
      break
    }
    i += 1
  }
  if isPrefix, i == typed.count { return exact ? 0 : 1 }
  // In order, each typed byte at a word's start: `tV` fits `tableView`.
  var at = 0
  var previous: UInt8 = 0x5F
  var onlyBoundaries = true
  var first = true
  for byte in candidate {
    guard at < typed.count else { break }
    if byte | 0x20 == typed[at] | 0x20 {
      let isBoundary = first || previous == 0x5F || (byte >= 0x41 && byte <= 0x5A && !(previous >= 0x41 && previous <= 0x5A))
      if !isBoundary { onlyBoundaries = false }
      at += 1
    }
    previous = byte
    first = false
  }
  guard at == typed.count else { return nil }
  return onlyBoundaries ? 2 : 3
}

/// An entry before it's rendered: rendering reads tokens, and only what's returned gets that.
private struct Hit {
  var name: String
  var match: Int32
  var score: Int32
  var ref: DeclRef?
  var localToken: Int32 = -1
  var kind: SwiftCompletionItemKind?
  var insert: String? = nil
  var detail: String? = nil
  var receiver: Ty? = nil
  var needsUnwrap = false
}

extension Model {
  // MARK: Asking

  public func complete(path: String, line: Int, character: Int, limit: Int = 200) -> SwiftCompletionList {
    guard let unitIndex = project.unitByPath[path] else { return SwiftCompletionList(context: .none, state: .unknown, prefix: "", replaceStart: 0, items: [], isIncomplete: false) }
    let unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    project.focus(unitIndex: unitIndex, offset: offset)
    return complete(unitIndex: unitIndex, offset: offset, limit: limit)
  }

  func complete(unitIndex: Int32, offset: Int, limit: Int) -> SwiftCompletionList {
    // Headers wait as they do for definitions: only until something asked of them.
    var found = completeFromLoaded(unitIndex: unitIndex, offset: offset, limit: limit)
    while needsHeaders(found), project.loadClang(visibleFrom: [unitIndex]) {
      clangLoads += 1
      resetAfterClang()
      found = completeFromLoaded(unitIndex: unitIndex, offset: offset, limit: limit)
    }
    return found.list
  }

  private func needsHeaders(_ found: (list: SwiftCompletionList, sdkAsked: Bool)) -> Bool {
    found.sdkAsked || found.list.state == .unknown
  }

  private func completeFromLoaded(unitIndex: Int32, offset: Int, limit: Int) -> (list: SwiftCompletionList, sdkAsked: Bool) {
    let unit = project.units[Int(unitIndex)]
    func nothing(_ prefix: String, _ start: Int) -> (SwiftCompletionList, Bool) {
      (SwiftCompletionList(context: .none, state: .exact, prefix: prefix, replaceStart: start, items: [], isIncomplete: false), false)
    }
    if isInCommentOrString(unit, offset) { return nothing("", offset) }
    // The first token that doesn't end before the cursor.
    var low = 0
    var high = unit.tokens.count
    while low < high {
      let middle = (low + high) / 2
      if unit.tokens[middle].end < offset { low = middle + 1 } else { high = middle }
    }
    var anchor: Int?
    if low < unit.tokens.count, unit.tokens[low].start < offset, offset <= unit.tokens[low].end {
      let kind = unit.tokens[low].kind
      if kind == .identifier || kind == .keyword || kind == .declarationKeyword || kind == .attribute || kind == .directive { anchor = low }
    }
    // Where it is among the tokens: the anchor, or what comes after the cursor.
    var at = low
    if anchor == nil, low < unit.tokens.count, unit.tokens[low].end <= offset { at = low + 1 }
    completionToken = Int32(at)
    let replaceStart = anchor.map { unit.tokens[$0].start } ?? offset
    var prefix = ""
    if let anchor {
      let token = unit.tokens[anchor]
      prefix = String(decoding: UnsafeBufferPointer(start: unit.source.text + token.start, count: offset - token.start), as: UTF8.self)
      if token.kind == .attribute || token.kind == .directive {
        prefix.removeFirst()
        let isAttribute = token.kind == .attribute
        let hits = isAttribute ? attributeHits(unitIndex: unitIndex, prefix: prefix) : directiveHits(unitIndex: unitIndex, prefix: prefix)
        return (finish(hits, context: isAttribute ? .attribute : .directive, state: .exact, prefix: prefix, replaceStart: token.start + 1, limit: limit, unitIndex: unitIndex), false)
      }
    }
    let previous = at - 1
    let before = previous >= 0 ? previous : -1
    if before >= 0, isDotToken(unit, before) {
      return memberCompletion(unitIndex: unitIndex, dot: before, prefix: prefix, replaceStart: replaceStart, limit: limit)
    }
    // `\.na|`: what the root has, when what it's given to says the root.
    if before >= 0, unit.string(before).hasPrefix("\\"), unit.tokens[before].kind != .interpolationOpen {
      prepareScans(unitIndex: unitIndex, token: Int32(before))
      var hits: [Hit] = []
      var asked = false
      let typed = Array(prefix.utf8)
      let roots = keyPathRoots(unitIndex: unitIndex, slash: Int32(before))
      for root in roots ?? [] { collectMembers(of: root, typed: typed, tier: 0, unwrap: false, from: unitIndex, expected: nil, into: &hits, sdkAsked: &asked) }
      if !hits.isEmpty { return (finish(hits, context: .member, state: .exact, prefix: prefix, replaceStart: replaceStart, limit: limit, unitIndex: unitIndex), asked) }
      return (finish(namesOnly(typed: typed, from: unitIndex), context: .member, state: .unknown, prefix: prefix, replaceStart: replaceStart, limit: limit, unitIndex: unitIndex), true)
    }
    if before >= 0, unit.isToken(before, "import") {
      return (finish(moduleHits(prefix: prefix), context: .moduleName, state: .exact, prefix: prefix, replaceStart: replaceStart, limit: limit, unitIndex: unitIndex), false)
    }
    if before >= 0, isDeclaringName(unit, before, at: at, unitIndex: unitIndex) { return nothing(prefix, replaceStart) }
    let typed = Array(prefix.utf8)
    if before >= 0, isTypePosition(unitIndex: unitIndex, before: before) {
      let hits = scopeHits(unitIndex: unitIndex, token: at, typed: typed, onlyTypes: true, expected: nil)
      return (finish(hits, context: .type, state: .exact, prefix: prefix, replaceStart: replaceStart, limit: limit, unitIndex: unitIndex), true)
    }
    prepareScans(unitIndex: unitIndex, token: Int32(at))
    var hits: [Hit] = []
    if before >= 0 { hits.append(contentsOf: labelHits(unitIndex: unitIndex, before: before, typed: typed)) }
    let expected = wanted(unitIndex: unitIndex, at: at)
    hits.append(contentsOf: scopeHits(unitIndex: unitIndex, token: at, typed: typed, onlyTypes: false, expected: expected))
    return (finish(hits, context: .scope, state: .exact, prefix: prefix, replaceStart: replaceStart, limit: limit, unitIndex: unitIndex), true)
  }

  private func isDotToken(_ unit: Unit, _ i: Int) -> Bool { unit.isByte(i, 0x2E) || unit.isToken(i, "?.") || unit.isToken(i, "!.") }

  private func isInCommentOrString(_ unit: Unit, _ offset: Int) -> Bool {
    let tokens = unit.source.tokens
    var low = 0
    var high = tokens.count
    while low < high {
      let middle = (low + high) / 2
      if tokens[middle].end < offset { low = middle + 1 } else { high = middle }
    }
    guard low < tokens.count else { return false }
    let token = tokens[low]
    guard token.start < offset else { return false }
    switch token.kind {
    case .comment, .docComment:
      if offset < token.end { return true }
      // At a comment's end only a line comment is still open.
      return token.length >= 2 && unit.source.text[token.start + 1] == 0x2F
    case .string:
      if offset < token.end { return true }
      return unit.source.text[token.end - 1] != 0x22
    default:
      return false
    }
  }

  /// `func na|`, `let na|`: a new name, nothing to complete. In `case`, only in an enum's body.
  private func isDeclaringName(_ unit: Unit, _ before: Int, at: Int, unitIndex: Int32) -> Bool {
    for word in ["func", "let", "var", "class", "struct", "enum", "protocol", "typealias", "actor", "associatedtype", "macro"] where unit.string(before) == word {
      return true
    }
    if unit.isToken(before, "case"), let last = chain(at: Int32(at), unitIndex: unitIndex).last, unit.decls[Int(last)].kind == .enumeration { return true }
    return false
  }

  /// Whether the token before the cursor leaves room only for a type.
  private func isTypePosition(unitIndex: Int32, before: Int) -> Bool {
    let unit = project.units[Int(unitIndex)]
    for word in ["->", "as", "is", "some", "any", "extension", "inout", "as?", "as!"] where unit.string(before) == word { return true }
    if (unit.isByte(before, 0x3F) || unit.isByte(before, 0x21)), before > 0, unit.isToken(before - 1, "as") { return true }
    if unit.isToken(before, "<"), before > 0, unit.tokens[before - 1].end == unit.tokens[before].start, unit.tokens[before - 1].kind == .identifier { return true }
    if unit.isByte(before, 0x5B) || unit.isByte(before, 0x28), before > 0 {
      if unit.isByte(before, 0x28), isCallOpen(unit, before) { return false }
      return isTypePosition(unitIndex: unitIndex, before: before - 1)
    }
    if unit.isByte(before, 0x3A) { return colonTakesType(unitIndex: unitIndex, colon: before) }
    if unit.isByte(before, 0x2C) {
      // In an inheritance list or generic arguments.
      var i = before - 1
      var budget = 64
      while i >= 0, budget > 0, unit.tokens[i].kind != .open, unit.tokens[i].kind != .close {
        if unit.isByte(i, 0x3A) { return colonTakesType(unitIndex: unitIndex, colon: i) && !isInsideCallOrBody(unitIndex: unitIndex, token: i) }
        if unit.isToken(i, "<") { return i > 0 && unit.tokens[i - 1].kind == .identifier && unit.tokens[i - 1].end == unit.tokens[i].start }
        i -= 1
        budget -= 1
      }
    }
    return false
  }

  private func isInsideCallOrBody(unitIndex: Int32, token: Int) -> Bool {
    let unit = project.units[Int(unitIndex)]
    guard let open = enclosingOpen(unit, token) else { return false }
    return unit.isByte(open, 0x28) || unit.isByte(open, 0x5B)
  }

  private func colonTakesType(unitIndex: Int32, colon: Int) -> Bool {
    let unit = project.units[Int(unitIndex)]
    guard colon > 0 else { return false }
    let name = colon - 1
    if colon >= 2 {
      let word = unit.string(colon - 2)
      if ["let", "var", "struct", "class", "enum", "protocol", "actor", "extension", "associatedtype"].contains(word) { return true }
      if unit.isToken(colon - 2, "where") || (unit.isByte(colon - 2, 0x2C) && !isInsideCallOrBody(unitIndex: unitIndex, token: colon)) { return true }
    }
    guard unit.tokens[name].kind == .identifier || unit.tokens[name].kind == .keyword || unit.tokens[name].kind == .declarationKeyword else { return false }
    guard let open = enclosingOpen(unit, colon) else { return false }
    if unit.isByte(open, 0x5B) {
      // `[String: |`, as a type only.
      return open > 0 && isTypePosition(unitIndex: unitIndex, before: open - 1)
    }
    guard unit.isByte(open, 0x28) else { return false }
    // Parameters of a function being declared.
    var i = open - 1
    var budget = 32
    while i >= 0, budget > 0 {
      if unit.isToken(i, "func") || unit.isToken(i, "subscript") || (unit.isToken(i, "init") && !(i > 0 && isDotToken(unit, i - 1))) { return true }
      if unit.isToken(i, "case"), let last = chain(at: Int32(colon), unitIndex: unitIndex).last, unit.decls[Int(last)].kind == .enumeration { return true }
      let kind = unit.tokens[i].kind
      if kind == .open || kind == .close || unit.startsLine(i + 1) { return false }
      i -= 1
      budget -= 1
    }
    return false
  }

  // MARK: Members

  private func memberCompletion(unitIndex: Int32, dot: Int, prefix: String, replaceStart: Int, limit: Int) -> (list: SwiftCompletionList, sdkAsked: Bool) {
    let unit = project.units[Int(unitIndex)]
    let typed = Array(prefix.utf8)
    prepareScans(unitIndex: unitIndex, token: Int32(dot))
    let start = chainStart(unit, dot + 1)
    var hits: [Hit] = []
    var known = false
    var sdkAsked = false
    var context = SwiftCompletionContext.member
    var expected: Ty?
    if start == dot {
      context = .implicitMember
      expectedAlternatives = []
      expected = expectedType(unitIndex: unitIndex, start: Int32(dot))
      for wanted in expected.map({ [$0] }) ?? expectedAlternatives {
        var base = wanted
        while case .optional(let wrapped) = base { base = wrapped }
        if case .optional = wanted, let ref = standardRef(Word.optional) {
          collectMembers(of: .meta(.nominal(ref, [base])), typed: typed, tier: 2, unwrap: false, from: unitIndex, expected: nil, into: &hits, sdkAsked: &sdkAsked)
        }
        collectMembers(of: .meta(base), typed: typed, tier: 0, unwrap: false, from: unitIndex, expected: base, into: &hits, sdkAsked: &sdkAsked)
      }
      known = !hits.isEmpty
    } else {
      let result = evaluate(unitIndex: unitIndex, start: Int32(start), limit: Int32(dot))
      var seen: [Ty] = []
      expected = wanted(unitIndex: unitIndex, chainStart: start)
      for cand in result.sets.last ?? [] {
        var ty = cand.ty
        if !unit.isByte(dot, 0x2E), case .optional(let wrapped) = ty { ty = wrapped }
        guard !seen.contains(ty) else { continue }
        seen.append(ty)
        if ty == .unknown { continue }
        // A generic parameter nothing is known of says nothing about what a closure's `$0` really is.
        if case .dependent = ty { continue }
        if case .param(let paramName, let owner) = ty, owner.map({ constraints(of: paramName, owner: $0).isEmpty }) ?? true { continue }
        known = true
        collectMembers(of: ty, typed: typed, tier: 0, unwrap: false, from: unitIndex, expected: expected, into: &hits, sdkAsked: &sdkAsked)
      }
    }
    if known, context == .member, matchClass(typed, "self".utf8[...]) != nil {
      hits.append(Hit(name: "self", match: matchClass(typed, "self".utf8[...]) ?? 0, score: 900, ref: nil, kind: .keyword))
    }
    if !known {
      // A member of what couldn't be told: the project's members, as names only. Headers may still tell it.
      hits = namesOnly(typed: typed, from: unitIndex, implicitAt: context == .implicitMember ? dot : nil)
      return (finish(hits, context: context, state: .unknown, prefix: prefix, replaceStart: replaceStart, limit: limit, unitIndex: unitIndex), true)
    }
    return (finish(hits, context: context, state: .exact, prefix: prefix, replaceStart: replaceStart, limit: limit, unitIndex: unitIndex), sdkAsked)
  }

  private func collectMembers(of ty: Ty, typed: [UInt8], tier: Int32, unwrap: Bool, from unitIndex: Int32, expected: Ty?, into hits: inout [Hit], sdkAsked: inout Bool) {
    var isStaticSide = false
    var base = ty
    if case .meta(let inner) = base {
      isStaticSide = true
      base = inner
    }
    switch base {
    case .module(let moduleName):
      guard let module = project.modules[moduleName] else { return }
      if module.isSDK { sdkAsked = true }
      collectTop(of: module, typed: typed, tier: tier, onlyTypes: false, from: unitIndex, into: &hits)
      for member in module.units {
        for item in project.units[Int(member)].imports where item.isExported {
          if let exported = project.ensureModule(item.module, display: item.moduleName) { collectTop(of: exported, typed: typed, tier: tier + 1, onlyTypes: false, from: unitIndex, into: &hits) }
        }
      }
    case .optional(let wrapped):
      collectMembers(of: isStaticSide ? .meta(wrapped) : wrapped, typed: typed, tier: tier, unwrap: true, from: unitIndex, expected: expected, into: &hits, sdkAsked: &sdkAsked)
      if let ref = standardRef(Word.optional) {
        collectMembers(of: isStaticSide ? .meta(.nominal(ref, [wrapped])) : .nominal(ref, [wrapped]), typed: typed, tier: tier + 1, unwrap: false, from: unitIndex, expected: expected, into: &hits, sdkAsked: &sdkAsked)
      }
    case .existential(let items):
      for item in items { collectMembers(of: isStaticSide ? .meta(item) : item, typed: typed, tier: tier, unwrap: unwrap, from: unitIndex, expected: expected, into: &hits, sdkAsked: &sdkAsked) }
    case .param(let paramName, let owner):
      guard let owner else { return }
      for item in constraints(of: paramName, owner: owner) { collectMembers(of: isStaticSide ? .meta(item) : item, typed: typed, tier: tier, unwrap: unwrap, from: unitIndex, expected: expected, into: &hits, sdkAsked: &sdkAsked) }
    case .tuple(let items, let labels):
      for (index, item) in items.enumerated() {
        var names = [String(index)]
        if index < labels.count, labels[index] != 0, let text = tupleLabel(labels[index], unitIndex: unitIndex) { names.insert(text, at: 0) }
        for label in names {
          if let match = matchClass(typed, label.utf8[...]) { hits.append(Hit(name: label, match: match, score: tier * 100, ref: nil, kind: .field, detail: describe(item))) }
        }
      }
    case .nominal(let ref, _):
      if unit(ref).isInterface { sdkAsked = true }
      let holder = ref
      for (_, list) in memberTable(of: ref) {
        for member in list {
          let entry = decl(member)
          guard entry.kind != .deinitializer, entry.kind != .subscriptDecl, entry.kind != .extensionDecl else { continue }
          if isStaticSide {
            guard entry.isStatic || entry.kind == .initializer || entry.kind.isType || entry.kind == .enumCase else { continue }
          } else {
            guard !entry.isStatic, !entry.kind.isType, entry.kind != .enumCase, entry.kind != .initializer else { continue }
          }
          guard accessible(member, from: unitIndex), isPrivateVisible(member, holder: holder, unitIndex: unitIndex) else { continue }
          guard requirementsHold(member, holder: holder, receiver: base) else { continue }
          let owner = self.unit(member)
          let text = entry.kind == .initializer ? "init" : owner.string(Int(entry.nameToken))
          if owner.isInterface, text.utf8.first == 0x5F { continue }
          guard let match = matchClass(typed, text.utf8[...]) else { continue }
          var score = tier * 100
          // Its own first, what it inherits from the project next, what it inherits from the SDK last.
          if entry.parent >= 0, let at = nominal(forMembersOf: DeclRef(unit: member.unit, decl: entry.parent)), at != holder { score += owner.isInterface && !self.unit(holder).isInterface ? 60 : 30 }
          if isUnavailable(member) { continue }
          hits.append(Hit(name: text, match: match, score: score, ref: member, receiver: base, needsUnwrap: unwrap))
        }
      }
      collectSynthesized(of: ref, isStaticSide: isStaticSide, typed: typed, tier: tier, unwrap: unwrap, unitIndex: unitIndex, into: &hits)
      // `@dynamicMemberLookup`: the root's properties, as key paths reach them, after the type's own.
      if !isStaticSide, dynamicDepth < 3 {
        for lookup in dynamicLookups(of: base) {
          var through: [Hit] = []
          dynamicDepth += 1
          collectMembers(of: lookup.root, typed: typed, tier: tier, unwrap: unwrap, from: unitIndex, expected: nil, into: &through, sdkAsked: &sdkAsked)
          dynamicDepth -= 1
          let present = Set(hits.map(\.name))
          for var hit in through where !present.contains(hit.name) {
            guard let member = hit.ref, decl(member).kind == .variable else { continue }
            hit.score += 20
            // `isOn: $model.` wants a `Binding<Bool>`: what the subscript gives back, with its argument, not the property.
            if let expected, case .nominal(let wantedRef, let wantedArgs) = expected,
              case .nominal(let givenRef, let givenArgs) = dynamicResult(lookup, memberType: valueType(of: member, receiver: lookup.root)),
              wantedRef == givenRef, wantedArgs.count == givenArgs.count,
              zip(givenArgs, wantedArgs).allSatisfy({ isCompatible($0, with: $1) == true })
            {
              hit.score -= 40
            }
            hits.append(hit)
          }
        }
      }
      if let expected { applyExpected(&hits, wanted: expected) }
    default:
      break
    }
  }

  /// What the compiler writes: a raw value, `allCases`, a struct's memberwise initializer.
  private func collectSynthesized(of ref: DeclRef, isStaticSide: Bool, typed: [UInt8], tier: Int32, unwrap: Bool, unitIndex: Int32, into hits: inout [Hit]) {
    let item = decl(ref)
    let owner = unit(ref)
    func add(_ text: String, kind: SwiftCompletionItemKind, insert: String? = nil, detail: String = "") {
      guard let match = matchClass(typed, text.utf8[...]), !hits.contains(where: { $0.name == text }) else { return }
      hits.append(Hit(name: text, match: match, score: tier * 100, ref: nil, kind: kind, insert: insert, detail: detail, needsUnwrap: unwrap))
    }
    if item.kind == .enumeration {
      _ = memberTable(of: ref)
      var rawType: Ty?
      for base in inheritedTypes[ref] ?? [] {
        guard case .nominal(let parent, _) = base else { continue }
        if decl(parent).kind == .structure { rawType = base }
        if owner.isInterface { continue }
        if isStaticSide, decl(parent).name == hashName("CaseIterable") { add("allCases", kind: .property) }
      }
      if let rawType {
        if isStaticSide {
          add("init", kind: .constructor, insert: "init(rawValue: ${1:\(describe(rawType))})", detail: "")
        } else {
          add("rawValue", kind: .property, detail: describe(rawType))
        }
      }
    }
    if isStaticSide, !owner.isInterface, let properties = memberwiseProperties(of: ref) {
      let labels = properties.map { self.unit($0).string(Int(decl($0).nameToken)) }
      add("init", kind: .constructor, insert: "init(" + labels.map { $0 + ": " }.joined(separator: ", ") + ")")
    }
  }

  /// `private` is for the type it's in and its extensions in that file, not the whole file.
  private func isPrivateVisible(_ member: DeclRef, holder: DeclRef, unitIndex: Int32) -> Bool {
    guard decl(member).access == .isPrivate, member.unit == unitIndex else { return true }
    let unit = project.units[Int(unitIndex)]
    return chain(at: completionToken, unitIndex: unitIndex).contains { index in
      unit.decls[Int(index)].kind.hasMembers && nominal(forMembersOf: DeclRef(unit: unitIndex, decl: index)) == holder
    }
  }

  /// A name is a hash: its text is in some token of a file that wrote it.
  private func tupleLabel(_ label: Name, unitIndex: Int32) -> String? {
    if tupleLabels == nil {
      var found: [Name: String] = [:]
      for owner in project.units.prefix(project.projectUnits) {
        for i in owner.tokens.indices where owner.tokens[i].kind == .identifier && owner.isByte(i + 1, 0x3A) {
          let key = owner.hash(i)
          if found[key] == nil { found[key] = owner.string(i) }
        }
      }
      tupleLabels = found
    }
    return tupleLabels?[label]
  }

  /// What's written `@available(*, unavailable)` isn't there to call, and renamed declarations aren't either.
  private func isUnavailable(_ ref: DeclRef) -> Bool {
    let entry = decl(ref)
    let owner = unit(ref)
    var i = Int(entry.first)
    let end = Int(entry.nameToken)
    while i < end {
      if owner.tokens[i].kind == .attribute, owner.isToken(i, "@available"), owner.isByte(i + 1, 0x28) {
        let close = owner.skipBalanced(i + 1)
        for j in (i + 2)..<max(i + 2, close) where owner.isToken(j, "unavailable") || owner.isToken(j, "obsoleted") { return true }
        i = close
        continue
      }
      i += 1
    }
    return false
  }

  func isDeprecated(_ ref: DeclRef) -> Bool {
    let entry = decl(ref)
    let owner = unit(ref)
    var i = Int(entry.first)
    let end = Int(entry.nameToken)
    while i < end {
      if owner.tokens[i].kind == .attribute, owner.isToken(i, "@available"), owner.isByte(i + 1, 0x28) {
        let close = owner.skipBalanced(i + 1)
        for j in (i + 2)..<max(i + 2, close) where owner.isToken(j, "deprecated") { return true }
        i = close
        continue
      }
      i += 1
    }
    return false
  }

  private func applyExpected(_ hits: inout [Hit], wanted: Ty) {
    for index in hits.indices {
      guard let ref = hits[index].ref else { continue }
      var ty = valueType(of: ref, receiver: hits[index].receiver)
      if case .function(_, let result) = ty { ty = result }
      if case .meta(let inner) = ty { ty = inner }
      if isCompatible(ty, with: wanted) == true { hits[index].score -= 40 }
    }
  }

  // MARK: Scope

  private func scopeHits(unitIndex: Int32, token: Int, typed: [UInt8], onlyTypes: Bool, expected: Ty?) -> [Hit] {
    let unit = project.units[Int(unitIndex)]
    var hits: [Hit] = []
    var seenLocal: Set<Name> = []
    prepareScans(unitIndex: unitIndex, token: Int32(token))
    if !onlyTypes {
      for scan in scans(unitIndex: unitIndex, token: Int32(token)) {
        for local in scan.locals where local.hasSite && local.token >= 0 && local.scopeStart <= Int32(token) && Int32(token) < local.scopeEnd && local.token < Int32(token) {
          guard seenLocal.insert(local.name).inserted else { continue }
          let text = unit.string(Int(local.token))
          guard text != "_", let match = matchClass(typed, text.utf8[...]) else { continue }
          var kind = SwiftCompletionItemKind.variable
          var ref: DeclRef?
          if case .declaration(let index) = local.kind {
            ref = DeclRef(unit: unitIndex, decl: index)
            if let ref { kind = itemKind(of: ref) }
          }
          hits.append(Hit(name: text, match: match, score: 0, ref: ref, localToken: ref == nil ? local.token : -1, kind: kind))
        }
      }
    }
    let scopes = chain(at: Int32(token), unitIndex: unitIndex)
    let isStaticContext = scopes.last(where: { !unit.decls[Int($0)].kind.hasMembers }).map { unit.decls[Int($0)].isStatic } ?? false
    var sawMembers = false
    for index in scopes.reversed() {
      let owner = unit.decls[Int(index)]
      for g in 0..<Int(owner.genericCount) {
        let at = Int(unit.generics[Int(owner.genericStart) + g].token)
        let text = unit.string(at)
        if let match = matchClass(typed, text.utf8[...]) { hits.append(Hit(name: text, match: match, score: 5, ref: nil, kind: .typeParameter)) }
      }
      guard owner.kind.hasMembers, let target = nominal(forMembersOf: DeclRef(unit: unitIndex, decl: index)) else { continue }
      let item = decl(target)
      let holder = self.unit(target)
      for g in 0..<Int(item.genericCount) {
        let text = holder.string(Int(holder.generics[Int(item.genericStart) + g].token))
        if let match = matchClass(typed, text.utf8[...]) { hits.append(Hit(name: text, match: match, score: 5, ref: nil, kind: .typeParameter)) }
      }
      let own = selfNominal(target)
      for (_, list) in memberTable(of: target) {
        for member in list {
          let entry = decl(member)
          guard entry.kind != .deinitializer, entry.kind != .subscriptDecl, entry.kind != .initializer, entry.kind != .extensionDecl else { continue }
          if onlyTypes {
            guard entry.kind.isType else { continue }
          } else if !entry.kind.isType {
            // An instance member from a static method, or an outer type's, isn't there.
            let usable = entry.isStatic || entry.kind == .enumCase ? (isStaticContext || sawMembers) : (!isStaticContext && !sawMembers)
            guard usable else { continue }
          }
          guard accessible(member, from: unitIndex) else { continue }
          let holderUnit = self.unit(member)
          let text = holderUnit.string(Int(entry.nameToken))
          if holderUnit.isInterface, text.utf8.first == 0x5F { continue }
          guard let match = matchClass(typed, text.utf8[...]), !isUnavailable(member) else { continue }
          var score: Int32 = sawMembers ? 130 : 100
          if entry.parent >= 0, let at = nominal(forMembersOf: DeclRef(unit: member.unit, decl: entry.parent)), at != target { score += holderUnit.isInterface ? 60 : 20 }
          hits.append(Hit(name: text, match: match, score: score, ref: member, receiver: own))
        }
      }
      sawMembers = true
    }
    if let expected { applyExpected(&hits, wanted: expected) }
    let visible = completionModules(of: unitIndex)
    for (position, moduleName) in visible.enumerated() {
      guard let module = project.modules[moduleName] else { continue }
      let tier: Int32 = position == 0 ? 2 : module.isSDK ? 4 : 3
      collectTop(of: module, typed: typed, tier: tier, onlyTypes: onlyTypes, from: unitIndex, into: &hits)
    }
    for (keywordList, score) in onlyTypes ? [(typeKeywords, Int32(450))] : [(keywords(for: scopes, unit: unit), Int32(350))] {
      for word in keywordList {
        if let match = matchClass(typed, word.utf8[...]) { hits.append(Hit(name: word, match: match, score: score, ref: nil, kind: .keyword)) }
      }
    }
    return hits
  }

  private func keywords(for scopes: [Int32], unit: Unit) -> [String] {
    if let last = scopes.last, unit.decls[Int(last)].kind.hasMembers { return declarationKeywords }
    return expressionKeywords
  }

  /// A file's own, its imports, and what those re-export, Clang modules' re-exports included.
  private func completionModules(of unitIndex: Int32) -> [Name] {
    var order = project.visibleModules(of: unitIndex)
    var seen = Set(order)
    var at = 0
    while at < order.count {
      if let module = project.modules[order[at]], module.isSDK {
        for dependency in project.clangExports(of: module.displayName) where seen.insert(name(dependency)).inserted {
          if project.ensureModule(name(dependency), display: dependency) != nil { order.append(name(dependency)) }
        }
      }
      at += 1
    }
    return order
  }

  private func collectTop(of module: Module, typed: [UInt8], tier: Int32, onlyTypes: Bool, from unitIndex: Int32, into hits: inout [Hit]) {
    for entry in topEntries(of: module) {
      guard !onlyTypes || entry.isType, let match = matchClass(typed, entry.name.utf8[...]) else { continue }
      guard accessible(entry.ref, from: unitIndex), !isUnavailable(entry.ref) else { continue }
      hits.append(Hit(name: entry.name, match: match, score: tier * 100, ref: entry.ref))
    }
  }

  private func topEntries(of module: Module) -> [TopEntry] {
    if let known = topCache[module.name], known.count == module.top.reduce(0, { $0 + $1.value.count }) { return known }
    var list: [TopEntry] = []
    for (_, refs) in module.top {
      for ref in refs {
        let entry = decl(ref)
        let owner = unit(ref)
        let text = owner.string(Int(entry.nameToken))
        if module.isSDK, text.utf8.first == 0x5F { continue }
        list.append(TopEntry(name: text, ref: ref, isType: entry.kind.isType))
      }
    }
    topCache[module.name] = list
    return list
  }

  private func moduleHits(prefix: String) -> [Hit] {
    let typed = Array(prefix.utf8)
    var hits: [Hit] = []
    for (text, isSDK) in project.moduleNames() {
      if let match = matchClass(typed, text.utf8[...]) { hits.append(Hit(name: text, match: match, score: isSDK ? 100 : 0, ref: nil, kind: .module)) }
    }
    return hits
  }

  private func attributeHits(unitIndex: Int32, prefix: String) -> [Hit] {
    let typed = Array(prefix.utf8)
    var hits: [Hit] = []
    for word in attributeNames {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(Hit(name: word, match: match, score: 0, ref: nil, kind: .keyword)) }
    }
    for moduleName in completionModules(of: unitIndex) {
      if let module = project.modules[moduleName] { collectTop(of: module, typed: typed, tier: module.isSDK ? 2 : 1, onlyTypes: true, from: unitIndex, into: &hits) }
    }
    return hits
  }

  private func directiveHits(unitIndex: Int32, prefix: String) -> [Hit] {
    let typed = Array(prefix.utf8)
    var hits: [Hit] = []
    for word in directiveNames {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(Hit(name: word, match: match, score: 0, ref: nil, kind: .keyword)) }
    }
    for moduleName in completionModules(of: unitIndex) {
      guard let module = project.modules[moduleName] else { continue }
      for entry in topEntries(of: module) where decl(entry.ref).kind == .macro {
        if let match = matchClass(typed, entry.name.utf8[...]) { hits.append(Hit(name: entry.name, match: match, score: 100, ref: entry.ref)) }
      }
    }
    return hits
  }

  /// Argument labels of the call the cursor is in, those not written yet.
  private func labelHits(unitIndex: Int32, before: Int, typed: [UInt8]) -> [Hit] {
    let unit = project.units[Int(unitIndex)]
    guard unit.isByte(before, 0x28) || unit.isByte(before, 0x2C), let open = enclosingOpen(unit, before + 1), unit.isByte(open, 0x28), isCallOpen(unit, open) else { return [] }
    // The callee alone, not what its arguments so far would narrow it to.
    var refs: [DeclRef] = []
    var memberwise: [DeclRef] = []
    for (ref, _) in allCallees(unitIndex: unitIndex, open: open) {
      if let properties = memberwiseProperties(of: ref) { memberwise.append(contentsOf: properties) } else { refs.append(ref) }
    }
    var used: Set<Name> = []
    var i = open + 1
    var depth = 0
    while i <= before {
      let kind = unit.tokens[i].kind
      if kind == .open || kind == .interpolationOpen { depth += 1 }
      if kind == .close || kind == .interpolationClose { depth -= 1 }
      if depth == 0, unit.isByte(i + 1, 0x3A), unit.isByte(i - 1, 0x28) || unit.isByte(i - 1, 0x2C) { used.insert(unit.hash(i)) }
      i += 1
    }
    var seen: Set<Name> = []
    var hits: [Hit] = []
    for (position, property) in memberwise.enumerated() {
      let entry = decl(property)
      guard !used.contains(entry.name), seen.insert(entry.name).inserted else { continue }
      let text = self.unit(property).string(Int(entry.nameToken))
      guard let match = matchClass(typed, text.utf8[...]) else { continue }
      hits.append(Hit(name: text, match: match, score: position <= used.count ? -60 : -30, ref: nil, kind: .field, insert: text + ": "))
    }
    for ref in refs {
      let item = decl(ref)
      let holder = self.unit(ref)
      for p in 0..<Int(item.paramCount) {
        let param = holder.params[Int(item.paramStart) + p]
        guard param.label != 0, param.label != Word.underscore, !used.contains(param.label), seen.insert(param.label).inserted, param.nameToken >= 0 else { continue }
        // `label name: T` has the label a token before the name, `name: T` is both.
        var text = holder.string(Int(param.nameToken))
        if hashName(text) != param.label, param.nameToken > 0 { text = holder.string(Int(param.nameToken) - 1) }
        guard hashName(text) == param.label, let match = matchClass(typed, text.utf8[...]) else { continue }
        let isNext = p < 1 + used.count
        hits.append(Hit(name: text, match: match, score: isNext ? -60 : -30, ref: nil, kind: .field, insert: text + ": "))
      }
    }
    return hits
  }

  private func wanted(unitIndex: Int32, at: Int) -> Ty? {
    guard at > 0 else { return nil }
    return expectedType(unitIndex: unitIndex, start: Int32(at))
  }

  private func wanted(unitIndex: Int32, chainStart start: Int) -> Ty? {
    guard start > 0 else { return nil }
    return expectedType(unitIndex: unitIndex, start: Int32(start))
  }

  /// A receiver no one can tell the type of: the project's member names, which is what a text search would offer.
  private func namesOnly(typed: [UInt8], from unitIndex: Int32, implicitAt: Int? = nil) -> [Hit] {
    var hits: [Hit] = []
    var seen: Set<String> = []
    var enclosing: DeclRef?
    if let implicitAt {
      for index in chain(at: Int32(implicitAt), unitIndex: unitIndex).reversed() {
        let ref = DeclRef(unit: unitIndex, decl: index)
        if decl(ref).kind.hasMembers, let found = nominal(forMembersOf: ref) {
          enclosing = found
          break
        }
      }
    }
    for u in 0..<project.projectUnits {
      let owner = project.units[u]
      for (index, entry) in owner.decls.enumerated() where entry.parent >= 0 && !entry.isLocal && entry.kind != .extensionDecl && entry.kind != .initializer && entry.kind != .subscriptDecl && entry.kind != .deinitializer {
        let ref = DeclRef(unit: Int32(u), decl: Int32(index))
        if implicitAt != nil, entry.kind != .enumCase, !entry.isStatic { continue }
        guard accessible(ref, from: unitIndex) else { continue }
        let text = owner.string(Int(entry.nameToken))
        guard let match = matchClass(typed, text.utf8[...]), seen.insert(text).inserted else { continue }
        var score: Int32 = 300
        if let enclosing, nominal(forMembersOf: DeclRef(unit: Int32(u), decl: entry.parent)) == enclosing { score = 100 }
        hits.append(Hit(name: text, match: match, score: score, ref: ref))
      }
    }
    return hits
  }

  // MARK: Ranking and rendering

  /// Best first: how well it fits what's typed, then where it's from, with names this file and project already use lifted.
  private func finish(_ hits: [Hit], context: SwiftCompletionContext, state: AnswerState, prefix: String, replaceStart: Int, limit: Int, unitIndex: Int32) -> SwiftCompletionList {
    let unit = project.units[Int(unitIndex)]
    let inFile = unit.nameCounts
    let inProject = projectNameCounts()
    var seen: Set<UInt64> = []
    var ranked: [(score: Int64, hit: Hit)] = []
    ranked.reserveCapacity(hits.count)
    for hit in hits {
      var signature = hashName(hit.name)
      if let ref = hit.ref { signature = signatureKey(ref, name: hit.name) }
      if hit.ref == nil, hit.kind == .keyword { signature &+= 1 }
      guard seen.insert(signature).inserted else {
        if let at = ranked.firstIndex(where: { $0.hit.name == hit.name && $0.score > Int64(hit.score) && (hit.ref.map { signatureKey($0, name: hit.name) } ?? 0) == ($0.hit.ref.map { signatureKey($0, name: hit.name) } ?? 0) }) {
          ranked[at] = (Int64(hit.score), hit)
        }
        continue
      }
      ranked.append((Int64(hit.score), hit))
    }
    for index in ranked.indices {
      let hit = ranked[index].hit
      let hash = hashName(hit.name)
      let here = Int64(min(inFile[hash] ?? 0, 16))
      let there = Int64(min(inProject[hash] ?? 0, 4096))
      // Each doubling of use is worth less than one tier of where it's from.
      var lift = Int64(0)
      if here > 0 { lift += 40 + 8 * Int64(log2(Double(here))) }
      if there > 0 { lift += 6 * Int64(log2(Double(there + 1))) }
      if hit.kind == .keyword { lift = min(lift, 20) }
      ranked[index].score = Int64(hit.match) * 100_000 + (Int64(hit.score) - lift) * 16 + Int64(min(hit.name.utf8.count, 15))
    }
    let isIncomplete = ranked.count > limit
    ranked.sort {
      if $0.score != $1.score { return $0.score < $1.score }
      return $0.hit.name < $1.hit.name
    }
    let items = ranked.prefix(limit).map { render($0.hit, unitIndex: unitIndex) }
    return SwiftCompletionList(context: context, state: state, prefix: prefix, replaceStart: replaceStart, items: items, isIncomplete: isIncomplete)
  }

  /// Overloads stay apart, the same declaration restated up a hierarchy doesn't.
  private func signatureKey(_ ref: DeclRef, name text: String) -> UInt64 {
    let item = decl(ref)
    let owner = unit(ref)
    var key = hashName(text) &* 31 &+ UInt64(item.isStatic ? 1 : 0)
    if item.kind.isCallable || item.kind == .enumCase {
      key &+= 7
      for p in 0..<Int(item.paramCount) {
        let param = owner.params[Int(item.paramStart) + p]
        key = (key &* 1_099_511_628_211) ^ param.label
        guard param.typeStart >= 0 else { continue }
        for t in Int(param.typeStart)..<Int(param.typeEnd) where !owner.isToken(t, "::") && !owner.isToken(t + 1, "::") && !owner.isByte(t, 0x2E) && !owner.isByte(t + 1, 0x2E) {
          key = (key &* 1_099_511_628_211) ^ owner.hash(t)
        }
      }
    }
    return key
  }

  private func itemKind(of ref: DeclRef) -> SwiftCompletionItemKind {
    let item = decl(ref)
    switch item.kind {
    case .structure: return .structure
    case .classType, .actor: return .classType
    case .enumeration: return .enumeration
    case .protocolType: return .interface
    case .typeAlias: return .structure
    case .associatedType: return .typeParameter
    case .function, .macro: return item.parent >= 0 ? .method : .function
    case .initializer: return .constructor
    case .enumCase: return .enumMember
    case .variable: return item.parent >= 0 ? .property : .variable
    default: return .variable
    }
  }

  private func render(_ hit: Hit, unitIndex: Int32) -> SwiftCompletionEntry {
    guard let ref = hit.ref else {
      var detail = hit.detail ?? ""
      if hit.localToken >= 0 { detail = localDetail(unitIndex: unitIndex, token: hit.localToken) }
      let insert = hit.insert ?? hit.name
      return SwiftCompletionEntry(name: hit.name, label: hit.insert?.trimmingCharacters(in: .whitespaces) ?? hit.name, detail: detail, module: "", kind: hit.kind ?? .variable, insertText: insert, isSnippet: false, isDeprecated: false, needsUnwrap: false)
    }
    let item = decl(ref)
    let owner = unit(ref)
    var parameters: [String] = []
    var snippet: [String] = []
    var slot = 1
    if item.kind.isCallable || (item.kind == .enumCase && item.paramCount > 0) {
      for p in 0..<Int(item.paramCount) {
        let param = owner.params[Int(item.paramStart) + p]
        let type = param.typeStart >= 0 ? typeText(owner, start: Int(param.typeStart), end: Int(param.typeEnd)) : ""
        var label = ""
        if param.label != Word.underscore, param.label != 0, param.nameToken >= 0 {
          label = owner.string(Int(param.nameToken))
          if hashName(label) != param.label, param.nameToken > 0 { label = owner.string(Int(param.nameToken) - 1) }
        }
        parameters.append(label.isEmpty ? type : label + ": " + type)
        if !param.hasDefault {
          let hole = "${\(slot):\(type.replacingOccurrences(of: "}", with: "\\}"))}"
          snippet.append(label.isEmpty ? hole : label + ": " + hole)
          slot += 1
        }
      }
    }
    let callable = item.kind.isCallable || (item.kind == .enumCase && item.paramCount > 0)
    let label = callable ? hit.name + "(" + parameters.joined(separator: ", ") + ")" : hit.name
    let insert = callable ? hit.name + "(" + snippet.joined(separator: ", ") + ")" : hit.name
    var detail = ""
    if item.kind.isType {
      detail = ""
    } else if item.typeStart >= 0, item.kind != .extensionDecl {
      detail = typeText(owner, start: Int(item.typeStart), end: Int(item.typeEnd))
    } else if item.kind == .variable {
      let ty = valueType(of: ref, receiver: hit.receiver)
      if ty != .unknown { detail = describe(ty) }
    }
    var moduleText = ""
    if let module = project.modules[owner.moduleName] { moduleText = module.publishedName }
    return SwiftCompletionEntry(name: hit.name, label: label, detail: detail, module: moduleText, kind: itemKind(of: ref), insertText: insert, isSnippet: slot > 1, isDeprecated: isDeprecated(ref), needsUnwrap: hit.needsUnwrap)
  }

  private func localDetail(unitIndex: Int32, token: Int32) -> String {
    for scan in scans(unitIndex: unitIndex, token: token) {
      if let index = scan.byToken[token] {
        let ty = localType(scan: scan, index: index, unitIndex: unitIndex)
        return ty == .unknown ? "" : describe(ty)
      }
    }
    return ""
  }

  /// A type as written, without the module qualifiers interfaces carry.
  private func typeText(_ owner: Unit, start: Int, end: Int) -> String {
    guard start >= 0, end > start, end <= owner.tokens.count else { return "" }
    let from = owner.tokens[start].start
    let to = owner.tokens[end - 1].end
    var text = String(decoding: UnsafeBufferPointer(start: owner.source.text + from, count: to - from), as: UTF8.self)
    if owner.isInterface {
      // `Swift::Int`, `Swift.Int`.
      while let range = text.range(of: "::") {
        var head = range.lowerBound
        while head > text.startIndex, text[text.index(before: head)].isLetter || text[text.index(before: head)].isNumber || text[text.index(before: head)] == "_" { head = text.index(before: head) }
        text.removeSubrange(head..<range.upperBound)
      }
      for qualifier in ["Swift.", "Foundation.", "_Concurrency."] { text = text.replacingOccurrences(of: qualifier, with: "") }
    }
    return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
  }

  /// Times each name is used across the project's files, once: what's common here is more likely next.
  private func projectNameCounts() -> [Name: Int32] {
    if let known = projectCounts { return known }
    var counts: [Name: Int32] = [:]
    for u in 0..<project.projectUnits {
      for (key, value) in project.units[u].nameCounts { counts[key, default: 0] += value }
    }
    projectCounts = counts
    return counts
  }
}

struct TopEntry {
  var name: String
  var ref: DeclRef
  var isType: Bool
}

extension Unit {
  /// Times each identifier is used in this file, read when completion first asks.
  var nameCounts: [Name: Int32] {
    if let known = cachedNameCounts { return known }
    var counts: [Name: Int32] = [:]
    for i in tokens.indices where tokens[i].kind == .identifier { counts[hash(i), default: 0] += 1 }
    cachedNameCounts = counts
    return counts
  }
}
