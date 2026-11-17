import CodeModel
import CodeScan
import Foundation

/// Completion: after `.` or `:` the fields of the value's tables (its own, its metatable's class's, along `__index`, an
/// annotated class's `---@field`s and parents'; a string's are `string`'s); elsewhere the locals in scope (`self` in a
/// method), the globals the program assigns, the standard library's, a host's (`.luarc.json`'s `diagnostics.globals`)
/// and keywords. A value whose table can't be told gives nothing, marked unknown; a new name (`local x`, a parameter)
/// and a comment or string give nothing.
extension LuaModel {
  static let keywords = [
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
    "then", "true", "until", "while",
  ]

  public func complete(path: String, line: Int, character: Int, limit: Int = 200) -> ModelCompletionList {
    refresh()
    guard let unitIndex = project.unitByPath[path] else {
      return ModelCompletionList(context: .none, state: .unknown, prefix: "", replaceStart: 0, items: [], isIncomplete: false)
    }
    let unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    return complete(unitIndex: unitIndex, offset: offset, limit: limit)
  }

  func complete(unitIndex: Int32, offset: Int, limit: Int) -> ModelCompletionList {
    let unit = project.units[Int(unitIndex)]
    indexFields()
    let site = unit.completionSite(at: offset)
    let prefix = site.prefix
    let typed = Array(prefix.utf8)
    func nothing() -> ModelCompletionList {
      ModelCompletionList(context: .none, state: .exact, prefix: prefix, replaceStart: site.replaceStart, items: [], isIncomplete: false)
    }
    if unit.isInCommentOrString(offset) || isAfterLineComment(unit, offset) { return nothing() }
    guard let file = luaFile(unitIndex) else { return nothing() }
    func finish(_ hits: [ModelCompletionHit], _ context: ModelCompletionContext, _ state: AnswerState, method: Bool = false) -> ModelCompletionList {
      project.rankCompletions(
        hits, context: context, state: state, prefix: prefix, replaceStart: site.replaceStart, limit: limit, in: unit,
        signature: { ref, text in UInt64(bitPattern: Int64(ref.unit) << 32 | Int64(ref.decl)) &* 31 &+ hashName(text) },
        render: { self.render($0, unitIndex: unitIndex, method: method) })
    }
    let token = site.anchor ?? site.at
    let before = token - 1
    guard before >= 0 else { return finish(scopeHits(unitIndex: unitIndex, token: token, typed: typed), .scope, .exact) }
    // `value.na|`, `value:na|`.
    if unit.tokens[before].kind == .punctuation, unit.isToken(before, ".") || unit.isToken(before, ":") || site.splitDot {
      guard before > 0, let receiver = file.endsAt[Int32(before - 1)] else { return finish([], .member, .unknown) }
      let type = type(receiver, unitIndex)
      guard type.isKnown else { return finish([], .member, .unknown) }
      let hits = memberHits(of: type, typed: typed)
      // A host's table (`game.`): what the program assigns on it, else unknown.
      var state = AnswerState.exact
      if hits.isEmpty, typed.isEmpty {
        switch type {
        case .global, .path: state = .unknown
        default: break
        }
      }
      return finish(hits, .member, state, method: unit.isToken(before, ":"))
    }
    if isNewName(unit, before) { return nothing() }
    return finish(scopeHits(unitIndex: unitIndex, token: token, typed: typed), .scope, .exact)
  }

  /// At the end of a `--` comment's line.
  private func isAfterLineComment(_ unit: Unit, _ offset: Int) -> Bool {
    let tokens = unit.source.tokens
    var low = 0
    var high = tokens.count
    while low < high {
      let middle = (low + high) / 2
      if tokens[middle].end < offset { low = middle + 1 } else { high = middle }
    }
    guard low < tokens.count, tokens[low].kind == .comment || tokens[low].kind == .docComment, tokens[low].end == offset else { return false }
    let text = unit.source.string(tokens[low])
    return !(text.hasPrefix("--[") && text.hasSuffix("]"))
  }

  /// A name being declared: after `local`, `for`, `goto`, `::`, in `local a, b` and in a function's parameters.
  private func isNewName(_ unit: Unit, _ before: Int) -> Bool {
    if unit.isToken(before, "local") || unit.isToken(before, "for") || unit.isToken(before, "goto") || unit.isToken(before, "::") { return true }
    if unit.isToken(before, "function"), before > 0, unit.isToken(before - 1, "local") { return true }
    var k = before
    while k >= 1, unit.isToken(k, ","), unit.tokens[k - 1].kind == .identifier { k -= 2 }
    if k != before {
      if k >= 0, unit.isToken(k, "local") || unit.isToken(k, "for") { return true }
    }
    // `function f(a, |`.
    guard let open = unit.matchingOpenBefore(before + 1), unit.isByte(open, 0x28) else { return false }
    var j = open - 1
    if j >= 0, unit.isToken(j, "function") { return true }
    while j >= 0, unit.tokens[j].kind == .identifier {
      if j >= 1, unit.isToken(j - 1, ".") || unit.isToken(j - 1, ":") {
        j -= 2
        continue
      }
      return j >= 1 && unit.isToken(j - 1, "function")
    }
    return false
  }

  // MARK: Members

  /// Every field assigned on a table, read once per time types are.
  func fields(on owner: LuaType) -> [DeclRef] {
    if fieldsByOwner == nil {
      indexFields()
      var map: [LuaType: [DeclRef]] = [:]
      for refs in fieldWrites.values {
        for ref in refs {
          let found = ownerOf(ref)
          if found.isKnown { map[found, default: []].append(ref) }
        }
      }
      fieldsByOwner = map
    }
    var found = fieldsByOwner?[owner] ?? []
    if case .table(let unitIndex, let brace) = owner { found = (keysOfTable[TableKey(unit: unitIndex, brace: brace, name: 0)] ?? []) + found }
    return found
  }

  /// What a value has: its tables' fields along `__index`, annotated `---@field`s.
  func memberHits(of type: LuaType, typed: [UInt8]) -> [ModelCompletionHit] {
    var hits: [ModelCompletionHit] = []
    var seen: Set<LuaType> = []
    func gather(_ type: LuaType, _ score: Int32, _ depth: Int) {
      guard depth < 8, seen.insert(type).inserted else { return }
      switch type {
      case .table, .path, .global:
        for ref in fields(on: type) { add(ref, typed: typed, score: score, into: &hits) }
        if case .path(let parent, let key) = type {
          for value in fieldValues(parent, key) where value.owner != nil { gather(value, score, depth + 1) }
        }
      case .instance(let base, let metatable, let ownedByMetatable):
        gather(base, score, depth + 1)
        if ownedByMetatable, let owner = metatable.owner { gather(owner, score + 10, depth + 1) }
        for index in fieldValues(metatable, Self.indexName) where index.owner != nil { gather(index, score + 10, depth + 1) }
      case .union(let parts):
        for part in parts { gather(part, score, depth + 1) }
      case .string:
        gather(globalType(Self.stringName), score, depth + 1)
      default:
        break
      }
      for className in classNames(of: type) {
        guard let known = classes[className] else { continue }
        for field in known.fields {
          guard let match = matchClass(typed, field.name.utf8[...]) else { continue }
          hits.append(ModelCompletionHit(name: field.name, match: match, score: score + 5, ref: nil, kind: .field, detail: field.type))
        }
        for parent in known.parents {
          let parentType = annotatedType(parent)
          if parentType.isKnown { gather(parentType, score + 20, depth + 1) }
        }
      }
    }
    gather(type, 0, 0)
    // A field assigned in several places is one entry: the nearest table's first assignment.
    var seenNames: Set<String> = []
    return hits.filter { seenNames.insert($0.name).inserted }
  }

  private func add(_ ref: DeclRef, typed: [UInt8], score: Int32, into hits: inout [ModelCompletionHit]) {
    let holder = unit(ref)
    let token = Int(decl(ref).nameToken)
    var text = holder.string(token)
    if holder.tokens[token].kind == .string { text = LuaParser.literal(holder, token) ?? text }
    guard let match = matchClass(typed, text.utf8[...]) else { return }
    hits.append(ModelCompletionHit(name: text, match: match, score: score + (holder.isInterface ? 10 : 0), ref: ref))
  }

  // MARK: Scope

  /// The locals seen at a token, innermost last: declaring tokens.
  func visibleLocals(_ file: LuaFile, _ unit: Unit, at token: Int) -> [Int32] {
    var byName: [Name: Int32] = [:]
    var order: [Name] = []
    for def in file.localOrder {
      guard let local = file.locals[def], local.kind != .label, Int(local.visibleFrom) <= token, token <= Int(local.scopeEnd) else { continue }
      let word = unit.hash(Int(def))
      if byName[word] == nil { order.append(word) }
      byName[word] = def
    }
    return order.compactMap { byName[$0] }
  }

  private func scopeHits(unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    guard let file = luaFile(unitIndex) else { return [] }
    var hits: [ModelCompletionHit] = []
    var shown: Set<Name> = []
    for def in visibleLocals(file, unit, at: token) {
      let text = unit.string(Int(def))
      shown.insert(unit.hash(Int(def)))
      guard let match = matchClass(typed, text.utf8[...]) else { continue }
      let kind: ModelCompletionItemKind = file.locals[def]?.kind == .function ? .function : .variable
      hits.append(ModelCompletionHit(name: text, match: match, score: 0, ref: nil, localToken: def, kind: kind))
    }
    if file.functions.contains(where: { $0.isMethod && Int($0.open) <= token && token <= Int($0.close) }), !shown.contains(LuaParser.selfName),
      let match = matchClass(typed, "self".utf8[...])
    {
      hits.append(ModelCompletionHit(name: "self", match: match, score: 0, ref: nil, kind: .variable))
    }
    for (word, refs) in globalWrites where !shown.contains(word) {
      let own = refs.filter { !isStd($0.unit) }
      guard let ref = own.first ?? refs.first else { continue }
      add(ref, typed: typed, score: own.isEmpty ? 200 : 100, into: &hits)
    }
    for host in layout.hostGlobals.sorted() where globalWrites[name(host)] == nil {
      if let match = matchClass(typed, host.utf8[...]) { hits.append(ModelCompletionHit(name: host, match: match, score: 150, ref: nil, kind: .variable)) }
    }
    for word in Self.keywords {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 250, ref: nil, kind: .keyword)) }
    }
    return hits
  }

  // MARK: Rendering

  private func itemKind(of ref: DeclRef) -> ModelCompletionItemKind {
    let isFunction = decl(ref).kind == .function
    guard let item = field(ref) else { return .variable }
    if item.owner < 0, item.table < 0 { return isFunction ? .function : .variable }
    if isFunction {
      if let file = luaFile(ref.unit), case .function(let index) = file.expr(item.value), file.functions[Int(index)].isMethod { return .method }
      return .function
    }
    return .field
  }

  private func render(_ hit: ModelCompletionHit, unitIndex: Int32, method: Bool) -> ModelCompletionEntry {
    guard let ref = hit.ref else {
      var detail = hit.detail ?? ""
      if hit.localToken >= 0 { detail = describe(localType(unitIndex, hit.localToken)) }
      return ModelCompletionEntry(
        name: hit.name, label: hit.name, detail: detail, module: "", kind: hit.kind ?? .variable, insertText: hit.insert ?? hit.name, isSnippet: false,
        isDeprecated: false, needsUnwrap: false)
    }
    let item = decl(ref)
    let holder = unit(ref)
    var label = hit.name
    var insert = hit.name
    var isSnippet = false
    if item.kind == .function {
      var parameters: [String] = []
      for p in 0..<Int(item.paramCount) {
        let param = holder.params[Int(item.paramStart) + p]
        parameters.append(param.variadic ? "..." : holder.string(Int(param.nameToken)))
      }
      // `t:m()` passes `self` for a function written `function t.m(self)`.
      if method, parameters.first == "self" { parameters.removeFirst() }
      label = hit.name + "(" + parameters.joined(separator: ", ") + ")"
      let holes = parameters.filter { $0 != "..." }.enumerated().map { "${\($0.offset + 1):\($0.element.replacingOccurrences(of: "}", with: "\\}"))}" }
      if !holes.isEmpty {
        insert = hit.name + "(" + holes.joined(separator: ", ") + ")"
        isSnippet = true
      }
    }
    return ModelCompletionEntry(
      name: hit.name, label: label, detail: describe(declValueType(ref), function: ref), module: moduleText(holder), kind: hit.kind ?? itemKind(of: ref),
      insertText: insert, isSnippet: isSnippet, isDeprecated: isDeprecated(ref), needsUnwrap: false)
  }
}
