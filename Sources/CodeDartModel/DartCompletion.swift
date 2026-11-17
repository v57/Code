import CodeModel
import CodeScan
import Foundation

/// Completion: after a dot, what the receiver has (its type's members, inherited ones, the extensions that apply; a
/// type's static members and constructors; a prefix's declarations); in a call's parentheses its named parameters
/// first; elsewhere what's in scope (locals, the enclosing types' members, the library's and its imports' names,
/// prefixes, keywords).
extension DartModel {
  static let keywords = [
    "await", "break", "case", "catch", "class", "const", "continue", "default", "do", "else", "enum", "extends", "extension", "false", "final", "finally",
    "for", "if", "import", "in", "is", "late", "mixin", "new", "null", "on", "required", "return", "static", "super", "switch", "this", "throw", "true",
    "try", "var", "void", "while", "with", "yield", "async", "dynamic", "typedef",
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
    // `'$na|'`: a name in a string is completed like any.
    if unit.isInCommentOrString(offset), !(site.anchor.map { unit.daIsInterpolatedName($0) } ?? false) { return nothing("", offset) }
    func finish(_ hits: [ModelCompletionHit], _ context: ModelCompletionContext, _ state: AnswerState) -> ModelCompletionList {
      project.rankCompletions(
        hits, context: context, state: state, prefix: prefix, replaceStart: site.replaceStart, limit: limit, in: unit,
        signature: { ref, text in UInt64(bitPattern: Int64(ref.unit) << 32 | Int64(ref.decl)) &* 31 &+ hashName(text) },
        render: { self.render($0, unitIndex: unitIndex) })
    }
    // A new name: `class Na|`, `int na|`, `void na|(`.
    if before >= 0 {
      if unit.isToken(before, "class") || unit.isToken(before, "mixin") || unit.isToken(before, "enum") || unit.isToken(before, "typedef") || unit.isToken(before, "extension")
        || unit.isToken(before, "as") && before < directiveEnd(unit)
      {
        return nothing(prefix, site.replaceStart)
      }
      if !site.splitDot, isDeclarationType(unit, before) { return nothing(prefix, site.replaceStart) }
    }
    if before >= 0, unit.daIsDot(before) || site.splitDot {
      let dot = site.splitDot ? at - 1 : before
      let receiver = operandType(unitIndex: unitIndex, dot: dot)
      var hits: [ModelCompletionHit] = []
      switch receiver {
      case .unknown:
        return finish([], .member, .unknown)
      case .module(let prefixName):
        for (word, refs) in scope(ofUnit: unitIndex).prefixes[prefixName]?.names ?? [:] {
          guard let ref = refs.first else { continue }
          _ = word
          add(ref, typed: typed, score: 0, into: &hits)
        }
        return finish(hits, .member, .exact)
      case .meta(let type):
        guard case .nominal(let ref, _) = type else { return finish([], .member, .unknown) }
        let holder = self.unit(ref)
        for child in holder.children(of: ref.decl) {
          let item = holder.decls[Int(child)]
          guard item.isStatic || item.kind == .initializer && item.name != DartWord.newWord || item.kind == .enumCase || decl(ref).kind == .extensionDecl else { continue }
          add(DeclRef(unit: ref.unit, decl: child), typed: typed, score: item.kind == .enumCase ? 0 : 10, into: &hits)
        }
        if decl(ref).kind == .enumeration, let match = matchClass(typed, "values".utf8[...]) {
          hits.append(ModelCompletionHit(name: "values", match: match, score: 20, ref: nil, kind: .field, detail: "List<" + describe(type) + ">"))
        }
        return finish(hits, .member, .exact)
      default:
        collectMembers(of: receiver, unitIndex: unitIndex, typed: typed, score: 0, into: &hits)
        if hits.isEmpty, case .nominal = memberBase(receiver) {} else if hits.isEmpty { return finish([], .member, .unknown) }
        return finish(hits, .member, .exact)
      }
    }
    var hits: [ModelCompletionHit] = []
    // A call's named parameters, right after `(` or `,`.
    if before >= 0, unit.isByte(before, 0x28) || unit.isByte(before, 0x2C), let open = unit.matchingOpenBefore(at), unit.isByte(open, 0x28),
      let call = callTarget(unitIndex: unitIndex, open: open)
    {
      let given = Set(arguments(unit, open: open).map(\.label))
      for ref in call.refs {
        let holder = self.unit(ref)
        let item = decl(ref)
        for p in 0..<Int(item.paramCount) {
          let param = holder.params[Int(item.paramStart) + p]
          guard param.label != 0, !given.contains(param.label) else { continue }
          let text = holder.string(Int(param.nameToken))
          if let match = matchClass(typed, text.utf8[...]) {
            hits.append(ModelCompletionHit(name: text, match: match, score: param.hasDefault ? -40 : -60, ref: nil, kind: .variable, insert: text + ": ", detail: describe(parameterType(ref, p))))
          }
        }
      }
    }
    hits += scopeHits(unitIndex: unitIndex, token: at, typed: typed)
    return finish(hits, .scope, .exact)
  }

  private func directiveEnd(_ unit: Unit) -> Int {
    guard let last = unit.imports.last, last.token >= 0 else { return 0 }
    var end = Int(last.token)
    while end < unit.tokens.count, !unit.isByte(end, 0x3B) { end += 1 }
    return end + 1
  }

  /// Whether the token before the cursor is a declaration's type: `int na|`, `List<int> na|`, `Foo? na|`.
  private func isDeclarationType(_ unit: Unit, _ before: Int) -> Bool {
    let words: Set<String> = [
      "await", "yield", "return", "is", "as", "in", "on", "async", "case", "else", "new", "const", "final", "var", "late", "static", "required", "covariant",
      "throw", "show", "hide", "extends", "implements", "with", "get", "set", "operator", "external", "factory", "abstract", "sealed", "base", "interface",
      "when", "do", "assert", "default",
    ]
    if unit.daIsName(before) {
      guard !words.contains(unit.string(before)) else { return false }
      // A type starts the statement or follows a modifier: `int x`, `final Foo x`.
      var k = before
      while k > 0, unit.isByte(k - 1, 0x2E), unit.daIsName(k - 2) { k -= 2 }
      let previous = k - 1
      if previous < 0 { return true }
      return unit.isByte(previous, 0x3B) || unit.isByte(previous, 0x7B) || unit.isByte(previous, 0x7D) || unit.isToken(previous, "final") || unit.isToken(previous, "const")
        || unit.isToken(previous, "late") || unit.isToken(previous, "static") || unit.isToken(previous, "required") || unit.isToken(previous, "covariant")
        || unit.isByte(previous, 0x28) && false
    }
    if unit.isByte(before, 0x3F), unit.daIsName(before - 1) { return isDeclarationType(unit, before - 1) }
    if unit.tokens[before].kind == .punctuation, unit.punctuation(before, madeOf: ">?"), unit.startsWith(before, 0x3E) {
      var k = before
      var budget = 40
      while k > 0, budget > 0, !(unit.startsWith(k, 0x3C) && unit.tokens[k].kind == .punctuation && unit.daTypeArgumentsEnd(k) == before + 1) {
        budget -= 1
        k -= 1
      }
      return budget > 0 && k > 0 && unit.daIsName(k - 1) && isDeclarationType(unit, k - 1)
    }
    return false
  }

  /// A type's members (inherited ones too) and the members of the extensions that apply to it.
  private func collectMembers(of receiver: Ty, unitIndex: Int32, typed: [UInt8], score: Int32, into hits: inout [ModelCompletionHit]) {
    var base = nonNull(receiver)
    if case .existential(let parts) = base, let first = parts.first { base = first }
    if case .nominal(let ref, _) = memberBase(base) {
      let isExtension = decl(ref).kind == .extensionDecl
      for (_, entries) in memberTable(of: ref) {
        guard let entry = entries.first else { continue }
        let item = decl(entry.ref)
        if item.isStatic, !isExtension { continue }
        add(entry.ref, typed: typed, score: score + (isSDK(entry.ref) ? 10 : 0), into: &hits)
      }
    }
    for ext in scope(ofUnit: unitIndex).extensions where applies(ext, to: base) != nil {
      let holder = self.unit(ext)
      for child in holder.children(of: ext.decl) where !holder.decls[Int(child)].isStatic {
        add(DeclRef(unit: ext.unit, decl: child), typed: typed, score: score + 30, into: &hits)
      }
    }
  }

  /// A declaration as a hit, by the name it's written with (a setter's and an operator's left out).
  private func add(_ ref: DeclRef, typed: [UInt8], score: Int32, into hits: inout [ModelCompletionHit]) {
    let item = decl(ref)
    let holder = unit(ref)
    guard item.nameToken >= 0, holder.daIsName(Int(item.nameToken)), item.kind != .extensionDecl || item.access != .isPrivate else { return }
    if item.kind == .variable, holder.isToken(Int(item.nameToken) - 1, "set") { return }
    if item.kind == .function, holder.isToken(Int(item.nameToken) - 1, "operator") { return }
    if item.access == .isPrivate, isSDK(ref) { return }
    let text = holder.string(Int(item.nameToken))
    guard let match = matchClass(typed, text.utf8[...]) else { return }
    hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: ref))
  }

  /// Names on their own: locals, the enclosing types' members, the library's and its imports', prefixes, keywords.
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
    for (depth, owner) in enclosingTypes(unitIndex: unitIndex, token: Int32(token)).enumerated() {
      var members: [ModelCompletionHit] = []
      for child in unit.children(of: owner.decl) where unit.decls[Int(child)].kind != .initializer {
        add(DeclRef(unit: unitIndex, decl: child), typed: typed, score: 20 + Int32(depth * 30), into: &members)
      }
      collectMembers(of: thisType(owner), unitIndex: unitIndex, typed: typed, score: 40 + Int32(depth * 30), into: &members)
      hits += members
      let item = decl(owner)
      for g in 0..<Int(item.genericCount) {
        let text = unit.string(Int(unit.generics[Int(item.genericStart) + g].token))
        if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 60, ref: nil, kind: .typeParameter)) }
      }
    }
    let scope = scope(ofUnit: unitIndex)
    for (_, refs) in scope.own {
      for ref in refs { add(ref, typed: typed, score: 100, into: &hits) }
    }
    for (_, refs) in scope.imported {
      guard let ref = refs.first else { continue }
      add(ref, typed: typed, score: isSDK(ref) ? 160 : 130, into: &hits)
    }
    for (word, site) in scope.prefixSites {
      guard case .local(let u, let t) = site else { continue }
      let text = project.units[Int(u)].string(Int(t))
      _ = word
      if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 90, ref: nil, kind: .module)) }
    }
    for word in Self.keywords {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 250, ref: nil, kind: .keyword)) }
    }
    return hits
  }

  private func itemKind(of ref: DeclRef) -> ModelCompletionItemKind {
    let item = decl(ref)
    switch item.kind {
    case .classType: return unit(ref).isToken(Int(item.nameToken) - 1, "mixin") ? .interface : .classType
    case .structure: return .structure
    case .enumeration: return .enumeration
    case .enumCase: return .enumMember
    case .function: return item.parent >= 0 ? .method : .function
    case .initializer: return .constructor
    case .typeAlias: return .classType
    case .extensionDecl: return .module
    case .variable:
      if item.bodyOpen >= 0 || unit(ref).isToken(Int(item.nameToken) - 1, "get") { return .property }
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
        let name = holder.string(Int(param.nameToken))
        let type = param.typeStart >= 0 && param.typeEnd <= param.nameToken ? holder.text(from: Int(param.typeStart), to: Int(param.typeEnd)) : ""
        parameters.append(type.isEmpty ? name : type + " " + name)
        if !param.hasDefault {
          let hole = "${\(holes.count + 1):\(name.replacingOccurrences(of: "}", with: "\\}"))}"
          holes.append(param.label != 0 ? name + ": " + hole : hole)
        }
      }
      label = hit.name + "(" + parameters.joined(separator: ", ") + ")"
      if hit.insert == nil {
        insert = hit.name + "(" + holes.joined(separator: ", ") + ")"
        isSnippet = !holes.isEmpty
      }
      detail = describe(valueType(of: ref))
    } else if item.kind == .variable || item.kind == .enumCase {
      detail = describe(valueType(of: ref))
    }
    return ModelCompletionEntry(
      name: hit.name, label: label, detail: detail, module: libraryName(holder), kind: hit.kind ?? itemKind(of: ref), insertText: insert, isSnippet: isSnippet,
      isDeprecated: isDeprecated(ref), needsUnwrap: false)
  }

  /// `@deprecated` or `@Deprecated(…)` before it.
  func isDeprecated(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    let holder = unit(ref)
    var k = Int(item.first)
    while k < Int(item.nameToken), k < holder.tokens.count {
      if holder.isByte(k, 0x40), holder.isToken(k + 1, "deprecated") || holder.isToken(k + 1, "Deprecated") { return true }
      k += 1
    }
    return false
  }
}
