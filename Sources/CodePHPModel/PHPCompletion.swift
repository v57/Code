import CodeModel
import CodeScan
import Foundation

/// Completion: after `->` what the receiver's class has (its traits', parents' and interfaces' members too); after
/// `::` a class's constants, cases, static members (every method after `self::`, `static::`, `parent::`); after `$`
/// the variables in scope; after `new` classes; elsewhere functions, classes, constants and keywords.
extension PHPModel {
  static let keywords = [
    "abstract", "array", "as", "break", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "enum",
    "extends", "false", "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements", "include", "include_once", "instanceof",
    "interface", "isset", "list", "match", "namespace", "new", "null", "print", "private", "protected", "public", "readonly", "require", "require_once",
    "return", "static", "switch", "throw", "trait", "true", "try", "unset", "use", "while", "yield", "empty",
  ]

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
    func nothing(_ prefix: String, _ start: Int) -> ModelCompletionList {
      ModelCompletionList(context: .none, state: .exact, prefix: prefix, replaceStart: start, items: [], isIncomplete: false)
    }
    let site = unit.completionSite(at: offset)
    let at = site.at
    let prefix = site.prefix
    let typed = Array(prefix.utf8)
    let before = (site.anchor ?? at) - 1
    if unit.isInCommentOrString(offset), !(site.anchor.map { unit.phIsVariable($0) } ?? false) { return nothing("", offset) }
    func finish(_ hits: [ModelCompletionHit], _ context: ModelCompletionContext, _ state: AnswerState) -> ModelCompletionList {
      project.rankCompletions(
        hits, context: context, state: state, prefix: prefix, replaceStart: site.replaceStart, limit: limit, in: unit,
        signature: { ref, text in UInt64(bitPattern: Int64(ref.unit) << 32 | Int64(ref.decl)) &* 31 &+ hashName(text) },
        render: { self.render($0, unitIndex: unitIndex) })
    }
    guard before >= 0 else { return finish(scopeHits(unitIndex: unitIndex, token: at, typed: typed), .scope, .exact) }
    // A new name: `function na|`, `class Na|`, `const NA|`.
    let declaring: Set<String> = ["function", "class", "interface", "trait", "enum", "const", "namespace", "as", "insteadof", "goto"]
    if unit.phIsWord(before), declaring.contains(unit.string(before).lowercased()), !(unit.isToken(before, "function") && unit.isByte(site.anchor.map { $0 + 1 } ?? at, 0x28)) {
      return nothing(prefix, site.replaceStart)
    }
    // `->na|`: the receiver's members.
    if unit.phIsArrow(before) {
      let receiver = expressionType(unitIndex: unitIndex, end: before - 1)
      var hits: [ModelCompletionHit] = []
      guard collectMembers(of: receiver, statics: false, all: false, typed: typed, dollar: false, into: &hits) else { return finish([], .member, .unknown) }
      return finish(hits, .member, .exact)
    }
    // `X::na|`, `X::$na|`.
    let colons = unit.isToken(before, "::") ? before : unit.phIsDollar(before) && unit.isToken(before - 1, "::") ? before - 1 : -1
    if colons >= 0 {
      let receiver = staticReceiver(unitIndex: unitIndex, end: colons - 1)
      let word = unit.string(colons - 1).lowercased()
      let all = word == "self" || word == "static" || word == "parent"
      var hits: [ModelCompletionHit] = []
      guard collectMembers(of: receiver, statics: true, all: all, typed: typed, dollar: colons != before, into: &hits) else { return finish([], .member, .unknown) }
      if colons == before, let match = matchClass(typed, "class".utf8[...]) { hits.append(ModelCompletionHit(name: "class", match: match, score: 30, ref: nil, kind: .keyword)) }
      return finish(hits, .member, .exact)
    }
    // `$na|`: variables.
    if site.anchor.map({ unit.phIsVariable($0) }) ?? false || site.anchor == nil && unit.tokens[before].kind == .punctuation && unit.string(before).hasSuffix("$") {
      return finish(variableHits(unitIndex: unitIndex, token: site.anchor ?? at, typed: typed), .scope, .exact)
    }
    // `new Na|`, `instanceof Na|`, `extends Na|`: classes.
    if unit.isToken(before, "new") || unit.isToken(before, "instanceof") || unit.isToken(before, "extends") || unit.isToken(before, "implements") {
      return finish(globalHits(unitIndex: unitIndex, token: at, typed: typed, classesOnly: true), .type, .exact)
    }
    return finish(scopeHits(unitIndex: unitIndex, token: at, typed: typed), .scope, .exact)
  }

  /// A class's members as hits; false when the receiver's class isn't known.
  private func collectMembers(of receiver: Ty, statics: Bool, all: Bool, typed: [UInt8], dollar: Bool, into hits: inout [ModelCompletionHit]) -> Bool {
    var classes: [DeclRef] = []
    func gather(_ ty: Ty) {
      switch ty {
      case .nominal(let ref, _): classes.append(ref)
      case .meta(let inner), .optional(let inner): gather(inner)
      case .constructed(let kind, let parts) where kind == Ty.union || kind == Ty.intersection: parts.forEach(gather)
      default: break
      }
    }
    gather(receiver)
    guard !classes.isEmpty else { return false }
    for ref in classes {
      for (_, member) in memberTable(of: ref) {
        let item = decl(member)
        let holder = unit(member)
        guard item.nameToken >= 0 else { continue }
        let isProperty = item.kind == .variable && holder.phIsVariable(Int(item.nameToken))
        let isConstant = item.kind == .enumCase || item.kind == .variable && !isProperty
        if statics {
          guard item.isStatic || all && item.kind == .function else { continue }
          if dollar, !isProperty { continue }
        } else {
          guard !isConstant, !item.isStatic || item.kind == .function else { continue }
        }
        let text = holder.string(Int(item.nameToken))
        if text.hasPrefix("__"), text != "__construct" || !all { continue }
        guard let match = matchClass(typed, text.utf8[...]) else { continue }
        var hit = ModelCompletionHit(name: text, match: match, score: isSDK(member) ? 10 : 0, ref: member)
        if statics, isProperty, !dollar { hit.insert = "$" + text }
        hits.append(hit)
      }
    }
    return true
  }

  /// The variables in scope, `$this` in a class, the superglobals.
  private func variableHits(unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    var hits: [ModelCompletionHit] = []
    var seen: Set<String> = []
    if let body = body(unitIndex: unitIndex, token: token) {
      for (_, definition) in body.visible(at: Int32(token)) {
        let text = unit.string(Int(definition))
        guard seen.insert(text).inserted, let match = matchClass(typed, text.utf8[...]) else { continue }
        hits.append(ModelCompletionHit(name: text, match: match, score: 0, ref: nil, localToken: definition, kind: .variable))
      }
    }
    if enclosingClass(unitIndex: unitIndex, token: token) != nil, let match = matchClass(typed, "this".utf8[...]) {
      hits.append(ModelCompletionHit(name: "this", match: match, score: 5, ref: nil, kind: .variable, detail: describe(thisType(unitIndex: unitIndex, token: token))))
    }
    for word in Self.superglobals.sorted() where !seen.contains(word) {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 80, ref: nil, kind: .variable, detail: "array")) }
    }
    return hits
  }

  /// Names on their own: functions, classes, constants (the namespace's and imports' first), keywords.
  private func scopeHits(unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    var hits = globalHits(unitIndex: unitIndex, token: token, typed: typed, classesOnly: false)
    for word in Self.keywords {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 250, ref: nil, kind: .keyword)) }
    }
    return hits
  }

  private func globalHits(unitIndex: Int32, token: Int, typed: [UInt8], classesOnly: Bool) -> [ModelCompletionHit] {
    loadStd()
    let (namespace, uses) = context(unitIndex, token)
    let imported = Set(uses.map { $0.moduleName.lowercased() })
    let namespacePrefix = namespace.lowercased() + "\\"
    var hits: [ModelCompletionHit] = []
    for (_, refs) in symbols {
      guard let ref = refs.first else { continue }
      let item = decl(ref)
      let isClass = item.kind == .classType || item.kind == .protocolType || item.kind == .enumeration
      if classesOnly, !isClass { continue }
      let holder = unit(ref)
      guard item.nameToken >= 0 else { continue }
      let text = holder.tokens[Int(item.nameToken)].kind == .string ? (holder.phStringValue(Int(item.nameToken)) ?? "") : holder.string(Int(item.nameToken))
      guard !text.isEmpty, let match = matchClass(typed, text.utf8[...]) else { continue }
      let fqn = qualifiedName(ref).lowercased()
      var score: Int32 = isSDK(ref) ? 160 : 130
      if imported.contains(fqn) { score = 90 } else if !namespace.isEmpty, fqn.hasPrefix(namespacePrefix), !fqn.dropFirst(namespacePrefix.count).contains("\\") { score = 100 }
      hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: ref))
    }
    return hits
  }

  private func itemKind(of ref: DeclRef) -> ModelCompletionItemKind {
    let item = decl(ref)
    switch item.kind {
    case .classType: return .classType
    case .protocolType: return .interface
    case .enumeration: return .enumeration
    case .enumCase: return .enumMember
    case .function: return item.parent >= 0 && decl(DeclRef(unit: ref.unit, decl: item.parent)).kind != .namespace ? .method : .function
    case .variable: return unit(ref).phIsVariable(Int(item.nameToken)) ? .property : .enumMember
    default: return .variable
    }
  }

  private func render(_ hit: ModelCompletionHit, unitIndex: Int32) -> ModelCompletionEntry {
    guard let ref = hit.ref else {
      var detail = hit.detail ?? ""
      if hit.localToken >= 0 { detail = describe(variableType(unitIndex: unitIndex, token: Int(hit.localToken))) }
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
    if item.kind == .function {
      var parameters: [String] = []
      var holes: [String] = []
      for p in 0..<Int(item.paramCount) {
        let param = holder.params[Int(item.paramStart) + p]
        let name = "$" + holder.string(Int(param.nameToken))
        let type = param.typeStart >= 0 ? holder.text(from: Int(param.typeStart), to: Int(param.typeEnd)) : ""
        parameters.append(type.isEmpty ? name : type + " " + name)
        if !param.hasDefault, !param.variadic { holes.append("${\(holes.count + 1):\(name.replacingOccurrences(of: "$", with: "\\$").replacingOccurrences(of: "}", with: "\\}"))}") }
      }
      label = hit.name + "(" + parameters.joined(separator: ", ") + ")"
      if hit.insert == nil {
        insert = hit.name + "(" + holes.joined(separator: ", ") + ")"
        isSnippet = !holes.isEmpty
      }
      detail = describe(valueType(of: ref))
    } else if item.kind == .variable || item.kind == .enumCase {
      detail = describe(valueType(of: ref))
    } else {
      detail = qualifiedName(ref)
    }
    return ModelCompletionEntry(
      name: hit.name, label: label, detail: detail, module: moduleText(holder), kind: hit.kind ?? itemKind(of: ref), insertText: insert, isSnippet: isSnippet,
      isDeprecated: doc(ref).isDeprecated, needsUnwrap: false)
  }
}
