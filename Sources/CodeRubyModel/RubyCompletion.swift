import CodeModel
import CodeScan
import Foundation

/// Completion: after `.` or `&.` what the receiver's class answers (its ancestors' methods and attributes; a class's
/// singleton methods and `new`); after `::` a class's or module's constants and singleton methods; `@`, `@@` and `$`
/// the variables `self` (or the program) has; elsewhere the locals in scope, `self`'s methods (Kernel's at a file's
/// level), the constants seen from here (lexical scopes, then the top level) and keywords. A receiver whose class
/// can't be told gives nothing, marked unknown.
extension RubyModel {
  static let keywords = [
    "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module",
    "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while",
    "yield", "__method__", "__FILE__", "__LINE__", "__dir__",
  ]
  /// Methods every object has: listed after a class's own.
  static let everyone: Set<String> = ["Object", "Kernel", "BasicObject", "Module", "Class"]

  public func complete(path: String, line: Int, character: Int, limit: Int = 200) -> ModelCompletionList {
    guard let unitIndex = project.unitByPath[path] else {
      return ModelCompletionList(context: .none, state: .unknown, prefix: "", replaceStart: 0, items: [], isIncomplete: false)
    }
    let unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    return complete(unitIndex: unitIndex, offset: offset, limit: limit)
  }

  func complete(unitIndex: Int32, offset: Int, limit: Int) -> ModelCompletionList {
    let unit = project.units[Int(unitIndex)]
    loadStd()
    indexNewUnits()
    var site = unit.completionSite(at: offset)
    var prefix = site.prefix
    var replaceStart = site.replaceStart
    let at = site.at
    // `@na|`, `$na|`: the sigil is the name's; a lone `@` or `$` before the cursor is a sigil too.
    var sigil = ""
    if let anchor = site.anchor, unit.rbIsIdentifier(anchor), let first = prefix.utf8.first, first == 0x40 || first == 0x24 {
      sigil = prefix.hasPrefix("@@") ? "@@" : String(prefix.prefix(1))
    } else if site.anchor == nil, at > 0, unit.tokens[at - 1].kind == .punctuation, unit.tokens[at - 1].end == offset {
      let text = unit.string(at - 1)
      if let found = ["@@", "@", "$"].first(where: { text.hasSuffix($0) }) {
        sigil = found
        prefix = found
        replaceStart = offset - found.utf8.count
        site.anchor = at - 1
      }
    }
    let typed = Array(prefix.utf8)
    func nothing() -> ModelCompletionList {
      ModelCompletionList(context: .none, state: .exact, prefix: prefix, replaceStart: replaceStart, items: [], isIncomplete: false)
    }
    if sigil.isEmpty, unit.isInCommentOrString(offset) { return nothing() }
    func finish(_ hits: [ModelCompletionHit], _ context: ModelCompletionContext, _ state: AnswerState) -> ModelCompletionList {
      project.rankCompletions(
        hits, context: context, state: state, prefix: prefix, replaceStart: replaceStart, limit: limit, in: unit,
        signature: { ref, text in UInt64(bitPattern: Int64(ref.unit) << 32 | Int64(ref.decl)) &* 31 &+ hashName(text) },
        render: { self.render($0, unitIndex: unitIndex) })
    }
    let token = site.anchor ?? at
    if !sigil.isEmpty {
      return finish(variableHits(unitIndex: unitIndex, token: token, sigil: sigil, typed: typed), .scope, .exact)
    }
    let before = token - 1
    guard before >= 0 else { return finish(scopeHits(unitIndex: unitIndex, token: token, typed: typed), .scope, .exact) }
    // A new name: `def na|`, `class Na|`, `module Na|`, `alias na|`.
    if unit.isToken(before, "def") || unit.isToken(before, "class") || unit.isToken(before, "module") || unit.isToken(before, "alias") { return nothing() }
    // `recv.na|`.
    if unit.rbIsDot(before) {
      guard before > 0, unit.rbIsValueEnd(before - 1) else { return finish([], .member, .unknown) }
      let receiver = expressionType(unitIndex: unitIndex, end: before - 1)
      var hits: [ModelCompletionHit] = []
      guard memberHits(of: receiver, privateToo: unit.isToken(before - 1, "self"), typed: typed, into: &hits) else { return finish([], .member, .unknown) }
      return finish(hits, .member, .exact)
    }
    // `Foo::Na|`.
    if unit.rbIsColon2(before) {
      guard before > 0, unit.rbIsConstant(before - 1), let owner = preferred(resolvePath(unitIndex: unitIndex, end: before - 1)).first, isNamespaceLike(owner) else {
        return finish([], .member, .unknown)
      }
      let qualified = qualifiedName(owner)
      var hits = constantHits(in: qualified, typed: typed, score: 0)
      for (key, ref) in staticTable(qualified) { add(key, ref, typed: typed, score: 20, into: &hits) }
      return finish(hits, .member, .exact)
    }
    return finish(scopeHits(unitIndex: unitIndex, token: token, typed: typed), .scope, .exact)
  }

  /// A decl's name as written: a symbol's text for `attr_reader :x`; nil for a writer (`x=`), shown as its reader.
  func declText(_ ref: DeclRef) -> String? {
    let item = decl(ref)
    guard item.nameToken >= 0 else { return nil }
    let holder = unit(ref)
    let text = holder.rbLiteral(Int(item.nameToken)) ?? holder.string(Int(item.nameToken))
    guard name(text) == item.name else { return nil }
    if text.count > 1, text.hasSuffix("="), text.first.map({ $0.isLetter || $0 == "_" }) == true { return nil }
    return text
  }

  private func add(_ key: Name, _ ref: DeclRef, typed: [UInt8], score: Int32, into hits: inout [ModelCompletionHit]) {
    // Operator methods (`==`, `<=>`, `[]`) are written as operators.
    guard let text = declText(ref), let first = text.unicodeScalars.first, first == "_" || first.properties.isAlphabetic,
      let match = matchClass(typed, text.utf8[...])
    else { return }
    if text == "initialize" || text == "method_missing" || text == "respond_to_missing?" { return }
    hits.append(ModelCompletionHit(name: text, match: match, score: score + (isSDK(ref) ? 10 : 0), ref: ref))
  }

  /// What a receiver answers; false when its class isn't known.
  private func memberHits(of receiver: Ty, privateToo: Bool, typed: [UInt8], into hits: inout [ModelCompletionHit]) -> Bool {
    var parts: [Ty] = []
    func gather(_ ty: Ty) {
      switch ty {
      case .nominal, .meta: parts.append(ty)
      case .optional(let inner): gather(inner)
      case .constructed(let kind, let all) where kind == Ty.union: all.forEach(gather)
      default: break
      }
    }
    gather(receiver)
    guard !parts.isEmpty else { return false }
    var seen: Set<Name> = []
    for part in parts {
      switch part {
      case .nominal(let ref, _):
        for item in ancestors(qualifiedName(ref)) {
          let score: Int32 = Self.everyone.contains(item) ? 60 : 0
          for (key, member) in instanceTable(item) where seen.insert(key).inserted {
            if !privateToo, decl(member).access == .isPrivate { continue }
            add(key, member, typed: typed, score: score, into: &hits)
          }
        }
      case .meta(.nominal(let ref, _)):
        let qualified = qualifiedName(ref)
        if let match = matchClass(typed, "new".utf8[...]), seen.insert(Self.newKey).inserted {
          let initializer = instanceMember(qualified, Self.initializeKey)
          hits.append(ModelCompletionHit(name: "new", match: match, score: 5, ref: initializer, kind: .constructor))
        }
        for (item, isSingleton) in singletonChain(qualified) {
          let score: Int32 = Self.everyone.contains(item) ? 60 : 0
          for (key, member) in isSingleton ? staticTable(item) : instanceTable(item) where seen.insert(key).inserted {
            if !privateToo, decl(member).access == .isPrivate { continue }
            add(key, member, typed: typed, score: score, into: &hits)
          }
        }
      default:
        continue
      }
    }
    return true
  }

  /// A class's or module's own constants (nested classes and modules too).
  private func constantHits(in qualified: String, typed: [UInt8], score: Int32) -> [ModelCompletionHit] {
    let head = qualified.isEmpty ? "" : qualified + "::"
    var hits: [ModelCompletionHit] = []
    for (key, refs) in constants where key.hasPrefix(head) {
      let rest = key.dropFirst(head.count)
      // The stub's `RBS::Unnamed` holds the classes of `ENV` and `ARGF`, not something to write.
      guard !rest.isEmpty, !rest.contains(":"), rest != "RBS", let ref = preferred(refs).first, let match = matchClass(typed, rest.utf8[...]) else { continue }
      hits.append(ModelCompletionHit(name: String(rest), match: match, score: score + (tier(ref) == 0 ? 0 : 30), ref: ref))
    }
    return hits
  }

  /// `@x`, `@@x`, `$x` as the variable lookup sees them from here.
  private func variableHits(unitIndex: Int32, token: Int, sigil: String, typed: [UInt8]) -> [ModelCompletionHit] {
    indexVariables()
    let kind: VariableKind = sigil == "$" ? .global : sigil == "@@" ? .classLevel : .instance
    var hits: [ModelCompletionHit] = []
    var seen: Set<String> = []
    for (index, owner) in variableOwners(unitIndex: unitIndex, token: token, kind: kind).enumerated() {
      for (_, found) in variableDefs[owner] ?? [:] {
        guard case .local(let u, let t) = found.site, u != unitIndex || Int(t) != token else { continue }
        let text = project.units[Int(u)].string(Int(t))
        guard text.hasPrefix(sigil), sigil != "@" || !text.hasPrefix("@@"), seen.insert(text).inserted, let match = matchClass(typed, text.utf8[...]) else { continue }
        hits.append(ModelCompletionHit(name: text, match: match, score: Int32(min(index, 20)), ref: nil, localToken: -1, kind: .field, detail: describe(variableType(unitIndex: u, token: Int(t), kind: kind))))
      }
    }
    if kind == .global, let u = stdUnit {
      let holder = project.units[Int(u)]
      for i in holder.tokens.indices where holder.rbIsGlobal(i) && holder.startsLine(i) {
        let text = holder.string(i)
        guard seen.insert(text).inserted, let match = matchClass(typed, text.utf8[...]) else { continue }
        hits.append(ModelCompletionHit(name: text, match: match, score: 40, ref: nil, kind: .variable))
      }
    }
    return hits
  }

  /// The locals visible at a token: bound before it in its scope or a block around it, up to a method, class or file.
  func visibleLocals(unitIndex: Int32, token: Int) -> [Int32] {
    let holder = project.units[Int(unitIndex)]
    let shape = structure(holder)
    var chain: Set<Int32> = []
    var index = shape.scope(at: Int32(token))
    while index >= 0 {
      chain.insert(index)
      if shape.scopes[Int(index)].isGate { break }
      index = shape.scopes[Int(index)].parent
    }
    let locals = body(unitIndex)
    return locals.scopeOf.filter { chain.contains($0.value) && Int($0.key) < token }.map(\.key).sorted()
  }

  /// Names on their own: locals, `self`'s methods, constants and keywords.
  private func scopeHits(unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let holder = project.units[Int(unitIndex)]
    var hits: [ModelCompletionHit] = []
    var seen: Set<String> = []
    for definition in visibleLocals(unitIndex: unitIndex, token: token).reversed() {
      let text = holder.string(Int(definition))
      guard seen.insert(text).inserted, Int(definition) != token, let match = matchClass(typed, text.utf8[...]) else { continue }
      hits.append(ModelCompletionHit(name: text, match: match, score: 0, ref: nil, localToken: definition, kind: .variable))
    }
    let context = selfContext(unitIndex: unitIndex, token: token)
    var ty = selfType(context)
    if ty == .unknown { ty = selfType(.main) }
    var members: [ModelCompletionHit] = []
    _ = memberHits(of: ty, privateToo: true, typed: typed, into: &members)
    for var hit in members where !seen.contains(hit.name) {
      hit.score += 20
      hits.append(hit)
    }
    var constantsSeen: Set<String> = []
    for (depth, scope) in lexicalScopes(unitIndex: unitIndex, token: token).enumerated() {
      for hit in constantHits(in: scope, typed: typed, score: Int32(10 + depth)) where constantsSeen.insert(hit.name).inserted { hits.append(hit) }
    }
    for hit in constantHits(in: "", typed: typed, score: 40) where constantsSeen.insert(hit.name).inserted { hits.append(hit) }
    for word in Self.keywords {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 250, ref: nil, kind: .keyword)) }
    }
    return hits
  }

  private func itemKind(of ref: DeclRef) -> ModelCompletionItemKind {
    let item = decl(ref)
    switch item.kind {
    case .classType: return .classType
    case .namespace: return .module
    case .initializer: return .constructor
    case .function: return item.parent >= 0 ? .method : .function
    case .variable: return Self.isConstant(item) ? .enumMember : .property
    default: return .variable
    }
  }

  /// A parameter as the method writes it: `*args`, `key:`, `&block`.
  func parameterText(_ holder: Unit, _ param: Param) -> String {
    let k = Int(param.nameToken)
    var text = holder.string(k)
    if k > 0, holder.tokens[k - 1].kind == .punctuation, holder.touchesPrevious(k) {
      let sign = holder.string(k - 1)
      if let found = ["**", "*", "&"].first(where: { sign.hasSuffix($0) }) { text = found + text }
    }
    if holder.isByte(k + 1, 0x3A), holder.touchesPrevious(k + 1), !holder.rbIsColon2(k + 1) { text += ":" }
    return text
  }

  private func render(_ hit: ModelCompletionHit, unitIndex: Int32) -> ModelCompletionEntry {
    guard let ref = hit.ref else {
      var detail = hit.detail ?? ""
      if hit.localToken >= 0 { detail = describe(localType(unitIndex: unitIndex, definition: hit.localToken, at: Int(hit.localToken) + 1)) }
      return ModelCompletionEntry(
        name: hit.name, label: hit.name, detail: detail, module: "", kind: hit.kind ?? .variable, insertText: hit.insert ?? hit.name, isSnippet: false,
        isDeprecated: false, needsUnwrap: false)
    }
    let item = decl(ref)
    let holder = unit(ref)
    var label = hit.name
    var insert = hit.insert ?? hit.name
    var isSnippet = false
    var detail = ""
    if item.kind == .function || item.kind == .initializer {
      var parameters: [String] = []
      var holes: [String] = []
      for p in 0..<Int(item.paramCount) {
        let param = holder.params[Int(item.paramStart) + p]
        let text = parameterText(holder, param)
        parameters.append(param.hasDefault && !text.hasSuffix(":") ? text + " = …" : text)
        guard !param.hasDefault, !param.variadic, !text.hasPrefix("&"), !text.hasPrefix("*") else { continue }
        let word = holder.string(Int(param.nameToken)).replacingOccurrences(of: "}", with: "\\}")
        holes.append(text.hasSuffix(":") ? "\(word): ${\(holes.count + 1):\(word)}" : "${\(holes.count + 1):\(word)}")
      }
      if !parameters.isEmpty { label = hit.name + "(" + parameters.joined(separator: ", ") + ")" }
      if hit.insert == nil, !holes.isEmpty {
        insert = hit.name + "(" + holes.joined(separator: ", ") + ")"
        isSnippet = true
      }
      detail = describe(valueType(of: ref))
    } else if item.kind == .variable {
      detail = describe(valueType(of: ref))
    } else {
      detail = qualifiedName(ref)
    }
    return ModelCompletionEntry(
      name: hit.name, label: label, detail: detail, module: moduleText(holder), kind: hit.kind ?? itemKind(of: ref), insertText: insert, isSnippet: isSnippet,
      isDeprecated: doc(ref).isDeprecated, needsUnwrap: false)
  }
}
