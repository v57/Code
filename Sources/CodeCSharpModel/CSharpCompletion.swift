import CodeModel
import CodeScan
import Foundation

private let statementKeywords = [
  "abstract", "as", "async", "await", "base", "bool", "break", "byte", "case", "catch", "char", "class", "const", "continue", "decimal", "default",
  "delegate", "do", "double", "else", "enum", "event", "false", "finally", "float", "for", "foreach", "if", "in", "int", "interface", "internal",
  "is", "lock", "long", "nameof", "namespace", "new", "null", "object", "out", "override", "params", "private", "protected", "public", "readonly",
  "record", "ref", "return", "sealed", "short", "static", "string", "struct", "switch", "this", "throw", "true", "try", "typeof", "uint", "ulong",
  "using", "var", "virtual", "void", "while", "yield",
]

/// Completion: what could be typed at a position, from the same tables as definitions. It works on the text being
/// edited, so nothing here looks past the cursor.
extension CSharpModel {
  public func complete(path: String, line: Int, character: Int, limit: Int = 200) -> ModelCompletionList {
    guard let unitIndex = project.unitByPath[path] else {
      return ModelCompletionList(context: .none, state: .unknown, prefix: "", replaceStart: 0, items: [], isIncomplete: false)
    }
    let unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    project.focus(unitIndex: unitIndex, offset: offset)
    return complete(unitIndex: unitIndex, offset: offset, limit: limit)
  }

  func complete(unitIndex: Int32, offset: Int, limit: Int) -> ModelCompletionList {
    let unit = project.units[Int(unitIndex)]
    func nothing(_ prefix: String, _ start: Int) -> ModelCompletionList {
      ModelCompletionList(context: .none, state: .exact, prefix: prefix, replaceStart: start, items: [], isIncomplete: false)
    }
    if unit.isInCommentOrString(offset) { return nothing("", offset) }
    let site = unit.completionSite(at: offset)
    let at = site.at
    let prefix = site.prefix
    let typed = Array(prefix.utf8)
    let before = at - 1
    func finish(_ hits: [ModelCompletionHit], _ context: ModelCompletionContext, _ state: AnswerState) -> ModelCompletionList {
      project.rankCompletions(
        hits, context: context, state: state, prefix: prefix, replaceStart: site.replaceStart, limit: limit, in: unit,
        signature: { self.signatureKey($0, name: $1) }, render: { self.render($0, unitIndex: unitIndex) })
    }
    // `using |`, `using System.|`, `namespace |`: namespaces (and types after `using static`).
    if let item = importAt(unit, max(0, before)), before >= Int(item.token) - 1 || unit.isToken(before, "using") {
      return finish(namespaceHits(unitIndex: unitIndex, before: before, typed: typed), .moduleName, .exact)
    }
    if before >= 0, unit.isToken(before, "using") || unit.isToken(before, "static") && unit.isToken(before - 1, "using") {
      return finish(namespaceHits(unitIndex: unitIndex, before: before, typed: typed), .moduleName, .exact)
    }
    // A new name: `class Na|`, `int na|`, `List<int> na|`, `namespace A|`.
    if before >= 0 {
      if unit.isToken(before, "class") || unit.isToken(before, "struct") || unit.isToken(before, "interface") || unit.isToken(before, "enum") || unit.isToken(before, "namespace")
        || unit.isToken(before, "record") && !unit.csIsDot(before - 1) || unit.isToken(before, "delegate") && false
      {
        return nothing(prefix, site.replaceStart)
      }
      let isDeclarationType = (unit.csIsName(before) && !unit.isToken(before, "await") && !unit.isToken(before, "yield") && !unit.isToken(before, "return") && !unit.isToken(before, "is") && !unit.isToken(before, "as") && !unit.isToken(before, "in")
        && !unit.isToken(before, "where") && !unit.isToken(before, "select") && !unit.isToken(before, "from") && !unit.isToken(before, "into") && !unit.isToken(before, "on") && !unit.isToken(before, "equals")
        && !unit.isToken(before, "by") && !unit.isToken(before, "let") && !unit.isToken(before, "orderby") && !unit.isToken(before, "group") && !unit.isToken(before, "async") && !unit.isToken(before, "when")
        && !unit.isToken(before, "and") && !unit.isToken(before, "or") && !unit.isToken(before, "not") && !unit.isToken(before, "nameof") && !unit.isToken(before, "global")
        && !unit.isToken(before, "partial") && !unit.isToken(before, "required") && !unit.isToken(before, "file") && !unit.isToken(before, "get") && !unit.isToken(before, "set") && !unit.isToken(before, "init"))
        || unit.csIsPredefined(before) && !unit.isToken(before, "dynamic") || unit.isByte(before, 0x5D) && unit.isByte(before - 1, 0x5B)
        || unit.isByte(before, 0x3F) && (unit.csIsName(before - 1) || unit.csIsPredefined(before - 1))
        || unit.tokens[before].kind == .punctuation && unit.punctuation(before, madeOf: ">") && before > 0 && isTypeArgumentsClose(unit, before)
      if isDeclarationType, !site.splitDot { return nothing(prefix, site.replaceStart) }
    }
    if before >= 0, unit.csIsDot(before) || site.splitDot {
      var operand = operandType(unitIndex: unitIndex, dot: before)
      if unit.isToken(before, "?."), let inner = nullableValue(operand) { operand = inner }
      var hits: [ModelCompletionHit] = []
      switch operand {
      case .unknown:
        return finish([], .member, .unknown)
      case .module(let hashed):
        let text = namespaceNames[hashed] ?? ""
        collectNamespace(text, unitIndex: unitIndex, typed: typed, score: 0, into: &hits)
        for sub in subnamespaces(of: text) {
          if let match = matchClass(typed, sub.utf8[...]) { hits.append(ModelCompletionHit(name: sub, match: match, score: 50, ref: nil, kind: .module, detail: text + "." + sub)) }
        }
        return finish(hits, .member, .exact)
      case .meta(let type):
        collectMembers(of: type, typed: typed, staticOnly: true, into: &hits)
        return finish(hits, .member, .exact)
      default:
        guard case .nominal = memberBase(operand) else { return finish([], .member, .unknown) }
        collectMembers(of: operand, typed: typed, staticOnly: false, into: &hits)
        // Extension methods on it, after its own members.
        for (word, refs) in visibleExtensions(unitIndex: unitIndex, token: Int32(before)) {
          _ = word
          for ref in refs where receiverFits(ref, operand) != false {
            let text = self.unit(ref).string(Int(decl(ref).nameToken))
            if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 60, ref: ref, receiver: operand)) }
          }
        }
        return finish(hits, .member, .exact)
      }
    }
    // Where only a type goes: after `new`, `is`, `as`, `typeof(`, in type arguments, a base list.
    let typeOnly = before >= 0 && (unit.isToken(before, "new") || unit.isToken(before, "is") || unit.isToken(before, "as") || unit.isByte(before, 0x3A) && isBaseListColon(unit, before)
      || unit.isByte(before, 0x28) && unit.isToken(before - 1, "typeof") || unit.tokens[before].kind == .punctuation && unit.punctuation(before, madeOf: "<") && before > 0 && unit.csIsName(before - 1))
    var hits = typeHits(unitIndex: unitIndex, token: at, typed: typed)
    if typeOnly { return finish(hits, .type, .exact) }
    hits += scopeHits(unitIndex: unitIndex, token: at, typed: typed)
    return finish(hits, .scope, .exact)
  }

  private func isBaseListColon(_ unit: Unit, _ colon: Int) -> Bool {
    var k = colon - 1
    if unit.tokens.indices.contains(k), unit.tokens[k].kind == .close, let open = unit.matchingOpen(k) { k = open - 1 }
    guard unit.csIsName(k) else { return false }
    return unit.isToken(k - 1, "class") || unit.isToken(k - 1, "struct") || unit.isToken(k - 1, "interface") || unit.isToken(k - 1, "record")
  }

  private func isTypeArgumentsClose(_ unit: Unit, _ close: Int) -> Bool {
    var depth = 0
    var k = close
    var budget = 60
    while k >= 0, budget > 0 {
      budget -= 1
      if unit.tokens[k].kind == .punctuation {
        for b in (0..<unit.tokens[k].length).reversed() {
          let byte = unit.source.text[unit.tokens[k].start + b]
          if byte == 0x3E { depth += 1 } else if byte == 0x3C { depth -= 1 }
        }
        if depth == 0 { return unit.csTypeArgumentsEnd(k) == close + 1 && k > 0 && unit.csIsName(k - 1) }
      } else if unit.tokens[k].kind == .open || unit.isByte(k, 0x3B) {
        return false
      }
      k -= 1
    }
    return false
  }

  /// After `using` or a dot in one: namespaces under what's written, and the types there for `using static` and aliases.
  private func namespaceHits(unitIndex: Int32, before: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    var words: [String] = []
    var k = before
    while k >= 1, unit.isByte(k, 0x2E), unit.csIsName(k - 1) {
      words.insert(unit.string(k - 1), at: 0)
      k -= 2
    }
    let parent = words.joined(separator: ".")
    var hits: [ModelCompletionHit] = []
    for sub in subnamespaces(of: parent) {
      if let match = matchClass(typed, sub.utf8[...]) { hits.append(ModelCompletionHit(name: sub, match: match, score: 0, ref: nil, kind: .module, detail: parent.isEmpty ? sub : parent + "." + sub)) }
    }
    if !parent.isEmpty { collectNamespace(parent, unitIndex: unitIndex, typed: typed, score: 40, into: &hits) }
    if parent.isEmpty, unit.isToken(before, "using"), let match = matchClass(typed, "static".utf8[...]) {
      hits.append(ModelCompletionHit(name: "static", match: match, score: 100, ref: nil, kind: .keyword))
    }
    return hits
  }

  /// The next names under a namespace: `System.` gives `Collections`, `IO`, …
  func subnamespaces(of namespace: String) -> [String] {
    var result: Set<String> = []
    let lead = namespace.isEmpty ? "" : namespace + "."
    for prefixes in [index.namespaces, layout.libraryPrefixes] {
      for candidate in prefixes where candidate.hasPrefix(lead) && candidate.count > lead.count {
        let rest = candidate.dropFirst(lead.count)
        if !rest.contains(".") { result.insert(String(rest)) }
      }
    }
    return result.sorted()
  }

  /// A namespace's types a unit sees.
  private func collectNamespace(_ namespace: String, unitIndex: Int32, typed: [UInt8], score: Int32, into hits: inout [ModelCompletionHit]) {
    var seen: Set<DeclRef> = []
    let own = index.types[namespace] ?? [:]
    let visible = visibleModules(unitIndex)
    for (_, refs) in own {
      for ref in refs where visible.contains(self.unit(ref).moduleName) && seen.insert(parts(ref)[0]).inserted { addType(ref, typed: typed, score: score, into: &hits) }
    }
    for (_, refs) in library(namespace).types {
      for ref in refs where decl(ref).access == .isPublic { addType(ref, typed: typed, score: score + 20, into: &hits) }
    }
  }

  private func addType(_ ref: DeclRef, typed: [UInt8], score: Int32, into hits: inout [ModelCompletionHit]) {
    let item = decl(ref)
    guard item.kind.isNominal, item.name != 0 else { return }
    let text = self.unit(ref).string(Int(item.nameToken))
    if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: ref)) }
  }

  /// A type's fields, properties, methods and events, inherited ones too; a type's (`Foo.`) only its static ones and
  /// nested types.
  private func collectMembers(of ty: Ty, typed: [UInt8], staticOnly: Bool, into hits: inout [ModelCompletionHit]) {
    guard case .nominal(let ref, _) = memberBase(ty) else { return }
    let own = canonical(ref)
    for (_, entries) in memberTable(of: ref) {
      for (index, entry) in entries.enumerated() {
        let item = decl(entry.ref)
        let isConstant = item.kind == .variable && hasModifier(entry.ref, "const")
        if staticOnly, !(item.isStatic || isConstant || item.kind == .enumCase || item.kind.isNominal) { continue }
        if !staticOnly, item.kind.isNominal || item.isStatic && item.kind != .enumCase { continue }
        if item.name == 0 || item.kind == .subscriptDecl { continue }
        let text = self.unit(entry.ref).string(Int(item.nameToken))
        guard let match = matchClass(typed, text.utf8[...]) else { continue }
        // Own members before inherited ones; object's last.
        let isOwn = item.parent >= 0 && parts(own).contains(DeclRef(unit: entry.ref.unit, decl: item.parent))
        let fromObject = item.parent >= 0 && self.unit(entry.ref).decls[Int(item.parent)].name == CSharpWord.object
        let score: Int32 = isOwn ? 0 : (fromObject ? 120 : 40 + Int32(min(index, 5)))
        hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: entry.ref, receiver: ty))
      }
    }
  }

  /// The extension methods a token's namespaces bring in, by name.
  private func visibleExtensions(unitIndex: Int32, token: Int32) -> [Name: [DeclRef]] {
    var result: [Name: [DeclRef]] = [:]
    func take(_ namespace: String) {
      for (word, refs) in index.extensions[namespace] ?? [:] { result[word, default: []] += refs }
      for (word, refs) in library(namespace).extensions { result[word, default: []] += refs }
    }
    var seen: Set<String> = []
    for level in namespaceLevels(unitIndex: unitIndex, token: token) {
      if seen.insert(level.namespace).inserted { take(level.namespace) }
      if let scope = level.scope { for namespace in usings(unitIndex: unitIndex, scope: scope).namespaces where seen.insert(namespace).inserted { take(namespace) } }
    }
    return result
  }

  /// Type names: type parameters, nested types up the enclosing types, each namespace level's and its usings', the
  /// keyword types.
  private func typeHits(unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    var hits: [ModelCompletionHit] = []
    for index in unit.chain(at: Int32(token)) {
      let item = unit.decls[Int(index)]
      for g in 0..<Int(item.genericCount) {
        let text = unit.string(Int(unit.generics[Int(item.genericStart) + g].token))
        if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 5, ref: nil, kind: .typeParameter)) }
      }
      if item.kind.isNominal {
        for (_, entries) in memberTable(of: DeclRef(unit: unitIndex, decl: index)) {
          for entry in entries where decl(entry.ref).kind.isNominal { addType(entry.ref, typed: typed, score: 20, into: &hits) }
        }
      }
    }
    var seen: Set<String> = []
    for (depth, level) in namespaceLevels(unitIndex: unitIndex, token: Int32(token)).enumerated() {
      if seen.insert(level.namespace).inserted { collectNamespace(level.namespace, unitIndex: unitIndex, typed: typed, score: 30 + Int32(depth * 10), into: &hits) }
      guard let scope = level.scope else { continue }
      let scoped = usings(unitIndex: unitIndex, scope: scope)
      for namespace in scoped.namespaces where seen.insert(namespace).inserted {
        collectNamespace(namespace, unitIndex: unitIndex, typed: typed, score: 90, into: &hits)
      }
      for (alias, entry) in scoped.aliases {
        _ = alias
        let item = project.units[Int(entry.unit)].imports[entry.item]
        let text = project.units[Int(entry.unit)].string(Int(item.aliasToken))
        if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 40, ref: nil, kind: .module, detail: item.moduleName)) }
      }
    }
    for word in CSharpWord.predefinedText.sorted() {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 200, ref: nil, kind: .keyword)) }
    }
    return hits
  }

  /// Values on their own: locals, the enclosing types' members (inherited too), `using static` members, keywords.
  private func scopeHits(unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    var hits: [ModelCompletionHit] = []
    if let body = body(unitIndex: unitIndex, token: Int32(token)) {
      for index in body.visible(at: Int32(token)) {
        let local = body.locals[Int(index)]
        let text = unit.string(Int(local.token))
        guard let match = matchClass(typed, text.utf8[...]) else { continue }
        hits.append(ModelCompletionHit(name: text, match: match, score: 0, ref: nil, localToken: local.token, kind: .variable))
      }
    }
    for index in unit.chain(at: Int32(token)) where unit.decls[Int(index)].kind == .function {
      for child in unit.children(of: index) where unit.decls[Int(child)].isLocal && unit.decls[Int(child)].kind == .function {
        let text = unit.string(Int(unit.decls[Int(child)].nameToken))
        if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 5, ref: DeclRef(unit: unitIndex, decl: child))) }
      }
    }
    for (depth, owner) in enclosingTypes(unitIndex: unitIndex, token: Int32(token)).enumerated() {
      var members: [ModelCompletionHit] = []
      collectMembers(of: ownType(owner), typed: typed, staticOnly: false, into: &members)
      collectMembers(of: ownType(owner), typed: typed, staticOnly: true, into: &members)
      for var hit in members where hit.ref.map({ !decl($0).kind.isNominal }) ?? true {
        hit.score += 20 + Int32(depth * 30)
        hits.append(hit)
      }
      let item = decl(owner)
      for p in 0..<Int(item.paramCount) {
        let param = unit.params[Int(item.paramStart) + p]
        let text = unit.string(Int(param.nameToken))
        if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 10, ref: nil, localToken: param.nameToken, kind: .variable)) }
      }
    }
    for level in namespaceLevels(unitIndex: unitIndex, token: Int32(token)) {
      guard let scope = level.scope else { continue }
      for type in usings(unitIndex: unitIndex, scope: scope).statics {
        guard case .nominal(let ref, _) = memberBase(type) else { continue }
        for (_, entries) in memberTable(of: ref) {
          for entry in entries where decl(entry.ref).isStatic && !decl(entry.ref).kind.isNominal {
            let text = self.unit(entry.ref).string(Int(decl(entry.ref).nameToken))
            if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 80, ref: entry.ref)) }
          }
        }
      }
    }
    for word in statementKeywords {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 250, ref: nil, kind: .keyword)) }
    }
    return hits
  }

  /// Overloads stay apart: a method's key is its name and parameter types.
  func signatureKey(_ ref: DeclRef, name text: String) -> UInt64 {
    let item = decl(ref)
    if item.kind == .function {
      var key = hashName(text) &* 31 &+ UInt64(item.paramCount)
      let holder = self.unit(ref)
      for p in 0..<Int(item.paramCount) {
        let param = holder.params[Int(item.paramStart) + p]
        key = key &* 1_099_511_628_211 &+ hashName(holder.text(from: Int(param.typeStart), to: Int(param.typeEnd)))
      }
      return key
    }
    return hashName(text) &* 31 &+ UInt64(item.kind.rawValue)
  }

  private func itemKind(of ref: DeclRef) -> ModelCompletionItemKind {
    let item = decl(ref)
    switch item.kind {
    case .classType: return .classType
    case .structure: return .structure
    case .protocolType: return .interface
    case .enumeration: return .enumeration
    case .enumCase: return .enumMember
    case .function: return .method
    case .initializer: return .constructor
    case .variable:
      if item.bodyOpen >= 0 { return .property }
      return item.parent >= 0 ? .field : .variable
    default: return .variable
    }
  }

  private func render(_ hit: ModelCompletionHit, unitIndex: Int32) -> ModelCompletionEntry {
    guard let ref = hit.ref else {
      var detail = hit.detail ?? ""
      if hit.localToken >= 0, let body = body(unitIndex: unitIndex, token: hit.localToken), let index = body.byToken[hit.localToken] {
        detail = describe(localType(unitIndex: unitIndex, body: body, index: index))
      }
      return ModelCompletionEntry(
        name: hit.name, label: hit.name, detail: detail, module: "", kind: hit.kind ?? .variable, insertText: hit.insert ?? hit.name, isSnippet: false,
        isDeprecated: false, needsUnwrap: false)
    }
    let item = decl(ref)
    let owner = self.unit(ref)
    var label = hit.name
    var insert = hit.insert ?? hit.name
    var isSnippet = false
    var detail = ""
    if item.kind == .function {
      var parameters: [String] = []
      var holes: [String] = []
      let skip = isExtensionMethod(ref) && hit.receiver != nil ? 1 : 0
      for p in skip..<Int(item.paramCount) {
        let param = owner.params[Int(item.paramStart) + p]
        let type = oneLine(owner.text(from: Int(param.typeStart), to: Int(param.typeEnd)))
        let name = param.nameToken >= 0 ? owner.string(Int(param.nameToken)) : ""
        parameters.append(name.isEmpty ? type : type + " " + name)
        if !param.hasDefault { holes.append("${\(holes.count + 1):\((name.isEmpty ? type : name).replacingOccurrences(of: "}", with: "\\}"))}") }
      }
      label = hit.name + "(" + parameters.joined(separator: ", ") + ")"
      if hit.insert == nil {
        insert = hit.name + "(" + holes.joined(separator: ", ") + ")"
        isSnippet = !holes.isEmpty
      }
      if item.typeStart >= 0 { detail = oneLine(owner.text(from: Int(item.typeStart), to: Int(item.typeEnd))) }
    } else if item.kind == .variable, item.typeStart >= 0 {
      detail = oneLine(owner.text(from: Int(item.typeStart), to: Int(item.typeEnd)))
    }
    let namespace = enclosingNamespace(ref)
    return ModelCompletionEntry(
      name: hit.name, label: label, detail: detail, module: namespace, kind: hit.kind ?? itemKind(of: ref), insertText: insert, isSnippet: isSnippet,
      isDeprecated: isObsolete(ref), needsUnwrap: false)
  }

  /// `[Obsolete]` among its attributes.
  func isObsolete(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    let holder = self.unit(ref)
    var k = Int(item.first)
    let end = Int(item.nameToken >= 0 ? item.nameToken : item.first)
    while k < end, k < holder.tokens.count {
      if holder.isByte(k, 0x5B), holder.isToken(k + 1, "Obsolete") || holder.isToken(k + 1, "ObsoleteAttribute") { return true }
      k += 1
    }
    return false
  }
}
