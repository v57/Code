import CodeModel
import CodeScan
import Foundation

private let statementKeywords = [
  "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
  "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var",
]

/// Completion: what could be typed at a position, from the same tables as definitions. It works on the text being
/// edited, so nothing here looks past the cursor.
extension GoModel {
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
    if isInCommentOrString(unit, offset) { return nothing("", offset) }
    var low = 0
    var high = unit.tokens.count
    while low < high {
      let middle = (low + high) / 2
      if unit.tokens[middle].end < offset { low = middle + 1 } else { high = middle }
    }
    var anchor: Int?
    if low < unit.tokens.count, unit.tokens[low].start < offset, offset <= unit.tokens[low].end,
      unit.tokens[low].kind == .identifier || unit.tokens[low].kind == .keyword || unit.tokens[low].kind == .declarationKeyword
    {
      anchor = low
    }
    var at = low
    if anchor == nil, low < unit.tokens.count, unit.tokens[low].end <= offset { at = low + 1 }
    // `x.|.y`, a name deleted between two dots: they lex as one `..`.
    var splitDot = false
    if anchor == nil, low < unit.tokens.count, unit.tokens[low].kind == .punctuation, unit.tokens[low].length == 2,
      unit.tokens[low].start + 1 == offset, unit.source.text[unit.tokens[low].start] == 0x2E, unit.source.text[unit.tokens[low].start + 1] == 0x2E
    {
      at = low + 1
      splitDot = true
    }
    let replaceStart = anchor.map { unit.tokens[$0].start } ?? offset
    var prefix = ""
    if let anchor {
      let token = unit.tokens[anchor]
      prefix = String(decoding: UnsafeBufferPointer(start: unit.source.text + token.start, count: offset - token.start), as: UTF8.self)
    }
    let typed = Array(prefix.utf8)
    let before = at - 1
    func finish(_ hits: [ModelCompletionHit], _ context: ModelCompletionContext, _ state: AnswerState) -> ModelCompletionList {
      project.rankCompletions(
        hits, context: context, state: state, prefix: prefix, replaceStart: replaceStart, limit: limit, in: unit,
        signature: { self.signatureKey($0, name: $1) }, render: { self.render($0, unitIndex: unitIndex) })
    }
    // A new name: `func na|`, `type Na|`, `var na|`, `x, na| :=` aren't asked about.
    if before >= 0, unit.isToken(before, "func") || unit.isToken(before, "type") || unit.isToken(before, "var") || unit.isToken(before, "const") || unit.isToken(before, "package") {
      return nothing(prefix, replaceStart)
    }
    if before >= 0, unit.isByte(before, 0x2E) || splitDot {
      let operand = operandType(unitIndex: unitIndex, dot: before)
      var hits: [ModelCompletionHit] = []
      switch operand {
      case .unknown:
        return finish([], .member, .unknown)
      case .module(let moduleName):
        guard let module = project.modules[moduleName] else { return finish([], .member, .unknown) }
        for (word, list) in module.top {
          guard let ref = list.first, decl(ref).kind != .extensionDecl, isExported(word, ref) else { continue }
          let text = unit.nameText(ref, in: project)
          if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 0, ref: ref)) }
        }
        return finish(hits, .member, .exact)
      default:
        var base = operand
        if case .meta(let inner) = operand { base = inner }
        collectMembers(of: base, typed: typed, from: unitIndex, into: &hits)
        return finish(hits, .member, isKnown(base) ? .exact : .unknown)
      }
    }
    // `T{Fi|`: the literal's fields first.
    var hits: [ModelCompletionHit] = []
    if let body = body(unitIndex: unitIndex, token: Int32(at)), let open = unit.matchingOpenBefore(at), unit.isByte(open, 0x7B), body.composites[Int32(open)] != nil,
      before == open || unit.isByte(before, 0x2C)
    {
      let literal = compositeType(unitIndex: unitIndex, open: Int32(open), body: body)
      if isStruct(literal) {
        var fields: [ModelCompletionHit] = []
        collectMembers(of: literal, typed: typed, from: unitIndex, into: &fields)
        for var field in fields where field.ref.map({ decl($0).kind == .variable }) == true {
          field.score = -60
          field.insert = field.name + ": "
          field.kind = .field
          hits.append(field)
        }
      }
    }
    hits += scopeHits(unitIndex: unitIndex, token: at, typed: typed)
    return finish(hits, .scope, .exact)
  }

  private func isKnown(_ ty: Ty) -> Bool {
    switch dereferenced(ty) {
    case .nominal: return true
    default: return false
    }
  }

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
      return token.length >= 2 && unit.source.text[token.start + 1] == 0x2F
    case .string:
      if offset < token.end { return true }
      let last = unit.source.text[token.end - 1]
      return token.length < 2 || (last != 0x22 && last != 0x60 && last != 0x27)
    default:
      return false
    }
  }

  /// A type's fields and methods, promoted ones too.
  private func collectMembers(of ty: Ty, typed: [UInt8], from unitIndex: Int32, into hits: inout [ModelCompletionHit]) {
    var tables: [[Name: [DeclRef]]] = []
    let base = dereferenced(ty)
    if case .nominal(let ref, _) = base {
      tables.append(memberTable(of: ref))
      if case .nominal(let inner, _) = underlying(base), inner != ref {
        tables.append(memberTable(of: inner).mapValues { $0.filter { decl($0).parent >= 0 && unit($0).decls[Int(decl($0).parent)].kind != .extensionDecl } })
      }
    }
    var seen = Set<Name>()
    for (tier, table) in tables.enumerated() {
      for (word, list) in table where seen.insert(word).inserted {
        for ref in list where isExported(word, ref) || isSamePackage(ref.unit, unitIndex) {
          let text = unit(ref).string(Int(decl(ref).nameToken))
          guard let match = matchClass(typed, text.utf8[...]) else { continue }
          // Own members before promoted ones.
          let promoted = unit(ref).decls[Int(decl(ref).parent)].name != decl(ref).name && !isOwn(ref, of: base)
          hits.append(ModelCompletionHit(name: text, match: match, score: Int32(tier * 100 + (promoted ? 50 : 0)), ref: ref, receiver: ty))
        }
      }
    }
  }

  private func isOwn(_ member: DeclRef, of ty: Ty) -> Bool {
    guard case .nominal(let ref, _) = ty else { return false }
    let parent = decl(member).parent
    if member.unit == ref.unit, parent == ref.decl { return true }
    let holder = unit(member).decls[Int(parent)]
    return holder.kind == .extensionDecl && holder.name == decl(ref).name
  }

  /// Names on their own: locals, type parameters, the package's, imports, the universe, keywords.
  private func scopeHits(unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    var hits: [ModelCompletionHit] = []
    if let body = body(unitIndex: unitIndex, token: Int32(token)) {
      for index in body.visible(at: Int32(token), beforeToken: true) {
        let local = body.locals[Int(index)]
        let text = unit.string(Int(local.token))
        guard let match = matchClass(typed, text.utf8[...]) else { continue }
        if case .declaration(let declIndex) = local.kind {
          hits.append(ModelCompletionHit(name: text, match: match, score: 0, ref: DeclRef(unit: unitIndex, decl: declIndex)))
        } else {
          hits.append(ModelCompletionHit(name: text, match: match, score: 0, ref: nil, localToken: local.token, kind: .variable))
        }
      }
    }
    for index in unit.chain(at: Int32(token)) {
      let item = unit.decls[Int(index)]
      for g in 0..<Int(item.genericCount) {
        let text = unit.string(Int(unit.generics[Int(item.genericStart) + g].token))
        if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 5, ref: nil, kind: .typeParameter)) }
      }
    }
    for module in packageModules(of: unitIndex) {
      for (_, list) in module.top {
        for ref in list where decl(ref).name != 0 {
          let text = self.unit(ref).string(Int(decl(ref).nameToken))
          if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 100, ref: ref)) }
        }
      }
    }
    for item in unit.imports where item.alias != GoWord.blank && item.alias != GoWord.dot {
      var text = item.aliasToken >= 0 ? unit.string(Int(item.aliasToken)) : GoModel.defaultName(item.moduleName)
      if item.aliasToken < 0, let module = project.ensureModule(item.module, display: item.moduleName) { text = packageName(of: module) }
      if let match = matchClass(typed, text.utf8[...]) {
        hits.append(ModelCompletionHit(name: text, match: match, score: 150, ref: nil, kind: .module, detail: item.moduleName))
      }
    }
    if let universe {
      for (_, list) in universe.top {
        guard let ref = list.first else { continue }
        let text = self.unit(ref).string(Int(decl(ref).nameToken))
        // builtin.go's stand-ins (`Type`, `IntegerType`) aren't Go's.
        if text.first?.isUppercase == true { continue }
        // nil, true and false are written as often as a local.
        let isValue = decl(ref).name == GoWord.nilWord || decl(ref).name == GoWord.trueWord || decl(ref).name == GoWord.falseWord
        if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: isValue ? 50 : 300, ref: ref)) }
      }
    }
    for word in statementKeywords {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 400, ref: nil, kind: .keyword)) }
    }
    return hits
  }

  /// Overloads don't exist in Go: one entry per name and kind of holder.
  func signatureKey(_ ref: DeclRef, name text: String) -> UInt64 {
    hashName(text) &* 31 &+ UInt64(decl(ref).kind.rawValue)
  }

  private func itemKind(of ref: DeclRef) -> ModelCompletionItemKind {
    let item = decl(ref)
    switch item.kind {
    case .structure: return item.bodyOpen >= 0 ? .structure : .classType
    case .protocolType: return .interface
    case .typeAlias: return .structure
    case .function: return item.parent >= 0 ? .method : .function
    case .variable: return item.parent >= 0 ? .field : .variable
    default: return .variable
    }
  }

  private func render(_ hit: ModelCompletionHit, unitIndex: Int32) -> ModelCompletionEntry {
    guard let ref = hit.ref else {
      var detail = hit.detail ?? ""
      if hit.localToken >= 0, let body = body(unitIndex: unitIndex, token: hit.localToken), let index = body.byToken[hit.localToken] {
        let ty = localType(unitIndex: unitIndex, body: body, index: index)
        detail = ty == .unknown ? "" : describe(ty)
      }
      return ModelCompletionEntry(
        name: hit.name, label: hit.name, detail: detail, module: "", kind: hit.kind ?? .variable, insertText: hit.insert ?? hit.name, isSnippet: false,
        isDeprecated: false, needsUnwrap: false)
    }
    let item = decl(ref)
    let owner = unit(ref)
    var label = hit.name
    var insert = hit.insert ?? hit.name
    var isSnippet = false
    var detail = ""
    if item.kind == .function {
      var parameters: [String] = []
      var holes: [String] = []
      for p in 0..<Int(item.paramCount) {
        let param = owner.params[Int(item.paramStart) + p]
        let type = owner.text(from: Int(param.typeStart), to: Int(param.typeEnd))
        let name = param.nameToken >= 0 ? owner.string(Int(param.nameToken)) : ""
        parameters.append(name.isEmpty ? type : name + " " + type)
        holes.append("${\(p + 1):\((name.isEmpty ? type : name).replacingOccurrences(of: "}", with: "\\}"))}")
      }
      label = hit.name + "(" + parameters.joined(separator: ", ") + ")"
      if hit.insert == nil {
        insert = hit.name + "(" + holes.joined(separator: ", ") + ")"
        isSnippet = !holes.isEmpty
      }
      if item.typeStart >= 0 { detail = owner.text(from: Int(item.typeStart), to: Int(item.typeEnd)) }
    } else if item.kind == .variable {
      if item.typeStart >= 0 {
        detail = owner.text(from: Int(item.typeStart), to: Int(item.typeEnd))
      } else {
        let ty = memberType(ref, receiver: hit.receiver ?? .unknown)
        if ty != .unknown { detail = describe(ty) }
      }
    }
    let module = project.modules[owner.moduleName]?.displayName ?? ""
    return ModelCompletionEntry(
      name: hit.name, label: label, detail: detail, module: module.hasSuffix("#off") ? String(module.dropLast(4)) : module,
      kind: hit.kind ?? itemKind(of: ref), insertText: insert, isSnippet: isSnippet, isDeprecated: isDeprecated(ref), needsUnwrap: false)
  }

  /// `// Deprecated:` in its doc comment.
  func isDeprecated(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    let holder = unit(ref)
    guard item.first >= 0, Int(item.first) < holder.tokens.count else { return false }
    var line = holder.source.lines.line(of: holder.tokens[Int(item.nameToken >= 0 ? item.nameToken : item.first)].start) - 1
    while line >= 0 {
      let text = holder.lineText(line)
      guard text.hasPrefix("//") else { break }
      if text.hasPrefix("// Deprecated:") { return true }
      line -= 1
    }
    return false
  }

  /// A type as Go writes it.
  func describe(_ ty: Ty) -> String {
    switch ty {
    case .nominal(let ref, let args):
      var text = decl(ref).name == 0 ? "struct{…}" : unit(ref).string(Int(decl(ref).nameToken))
      if !isUniverse(ref), let module = project.modules[unit(ref).moduleName] {
        let package = packageName(of: module)
        if !package.isEmpty, package != "main" { text = package + "." + text }
      }
      if !args.isEmpty { text += "[" + args.map(describe).joined(separator: ", ") + "]" }
      return text
    case .constructed(let kind, let args):
      let inner = args.map(describe)
      switch kind {
      case Ty.pointer: return "*" + (inner.first ?? "")
      case Ty.slice: return "[]" + (inner.first ?? "")
      case Ty.array: return "[…]" + (inner.first ?? "")
      case Ty.map: return "map[" + (inner.first ?? "") + "]" + (inner.count > 1 ? inner[1] : "")
      case Ty.channel: return "chan " + (inner.first ?? "")
      default: return ""
      }
    case .function(let params, let result):
      var text = "func(" + params.map(describe).joined(separator: ", ") + ")"
      if case .tuple(let items, _) = result {
        if !items.isEmpty { text += " (" + items.map(describe).joined(separator: ", ") + ")" }
      } else {
        text += " " + describe(result)
      }
      return text
    case .tuple(let items, _): return "(" + items.map(describe).joined(separator: ", ") + ")"
    case .existential: return "interface{…}"
    case .meta(let inner): return describe(inner)
    case .module(let moduleName): return project.modules[moduleName]?.displayName ?? ""
    default: return ""
    }
  }
}

extension Unit {
  /// Tokens' text as written, on one line.
  func text(from start: Int, to end: Int) -> String {
    guard start >= 0, end > start, end <= tokens.count else { return "" }
    let from = tokens[start].start
    let to = tokens[end - 1].end
    return oneLine(String(decoding: UnsafeBufferPointer(start: source.text + from, count: to - from), as: UTF8.self))
  }

  func nameText(_ ref: DeclRef, in project: Project) -> String {
    let holder = project.units[Int(ref.unit)]
    let token = holder.decls[Int(ref.decl)].nameToken
    return token >= 0 ? holder.string(Int(token)) : ""
  }
}
