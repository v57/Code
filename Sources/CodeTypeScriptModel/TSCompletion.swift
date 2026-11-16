import CodeModel
import CodeScan
import Foundation

private let statementKeywords = [
  "async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do", "else", "enum", "export", "extends",
  "false", "finally", "for", "function", "if", "import", "in", "instanceof", "interface", "let", "new", "null", "return", "switch", "this",
  "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield",
]

/// Completion: what could be typed at a position, from the same tables as definitions. It works on the text being
/// edited, so nothing here looks past the cursor.
extension TSModel {
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
    if unit.isInCommentOrString(offset) { return nothing("", offset) }
    let site = unit.completionSite(at: offset)
    let typed = Array(site.prefix.utf8)
    let before = site.at - 1
    func finish(_ hits: [ModelCompletionHit], _ context: ModelCompletionContext, _ state: AnswerState) -> ModelCompletionList {
      project.rankCompletions(
        hits, context: context, state: state, prefix: site.prefix, replaceStart: site.replaceStart, limit: limit, in: unit,
        signature: { self.signatureKey($0, name: $1) }, render: { self.render($0, unitIndex: unitIndex) })
    }
    // `import { na| } from "m"`, `export { na| } from "m"`: what m exports.
    func isClause(_ k: Int) -> Bool { unit.isToken(k, "import") || unit.isToken(k, "export") }
    if let open = unit.matchingOpenBefore(site.at), unit.isByte(open, 0x7B),
      isClause(open - 1) || unit.isToken(open - 1, "type") && isClause(open - 2) || unit.isByte(open - 1, 0x2C) && isClause(open - 3),
      case let close = unit.skipBalanced(open), unit.isToken(close, "from"), close + 1 < unit.tokens.count, unit.tokens[close + 1].kind == .string
    {
      let key = layout.resolve(unit.tsStringValue(close + 1), from: unit.path)
      guard !key.hasPrefix("?"), project.ensureModule(name(key), display: key) != nil else { return finish([], .member, .unknown) }
      var hits: [ModelCompletionHit] = []
      collectMembers(of: .module(name(key)), typed: typed, from: unitIndex, tier: 0, into: &hits, depth: 0)
      return finish(hits, .member, .exact)
    }
    // A new name isn't asked about.
    if before >= 0, unit.isToken(before, "function") || unit.isToken(before, "class") || unit.isToken(before, "interface") || unit.isToken(before, "type")
      || unit.isToken(before, "enum") || unit.isToken(before, "namespace") || unit.isToken(before, "const") || unit.isToken(before, "let")
      || unit.isToken(before, "var")
    {
      return nothing(site.prefix, site.replaceStart)
    }
    if before >= 0, unit.tsIsDot(before) || unit.isToken(before, ".#") || site.splitDot {
      let operand = operandType(unitIndex, dot: before)
      if isUnknown(operand) { return finish([], .member, .unknown) }
      var hits: [ModelCompletionHit] = []
      collectMembers(of: operand, typed: typed, from: unitIndex, tier: 0, into: &hits, depth: 0)
      return finish(hits, .member, .exact)
    }
    var hits: [ModelCompletionHit] = []
    // `{ ke|`: the properties of the type the literal is written for.
    if before >= 0, unit.isByte(before, 0x7B) || unit.isByte(before, 0x2C), let open = unit.isByte(before, 0x7B) ? before : unit.matchingOpenBefore(site.at),
      unit.isByte(open, 0x7B), file(unit).literals[Int32(open)] != nil || startsObjectLiteral(unit, open)
    {
      let expected = contextualType(unitIndex, open)
      if !isUnknown(expected) {
        var fields: [ModelCompletionHit] = []
        collectMembers(of: expected, typed: typed, from: unitIndex, tier: 0, into: &fields, depth: 0)
        for var field in fields where field.ref.map({ decl($0).kind == .variable }) == true {
          field.score = -60
          field.insert = field.name + ": "
          field.kind = .property
          hits.append(field)
        }
      }
    }
    hits += scopeHits(unitIndex: unitIndex, token: site.at, typed: typed)
    return finish(hits, .scope, .exact)
  }

  /// A `{` where an expression goes, not a block's: after `(`, `,`, `=`, `:`, `[`, `?`, `return`, `??`, `||`, `&&`.
  private func startsObjectLiteral(_ unit: Unit, _ open: Int) -> Bool {
    let k = open - 1
    guard k >= 0 else { return false }
    for byte: UInt8 in [0x28, 0x2C, 0x3D, 0x3A, 0x5B, 0x3F] where unit.isByte(k, byte) { return true }
    return unit.isToken(k, "return") || unit.isToken(k, "??") || unit.isToken(k, "||") || unit.isToken(k, "&&") || unit.isToken(k, "yield")
  }

  /// A type's members, its bases' after its own.
  private func collectMembers(of ty: Ty, typed: [UInt8], from unitIndex: Int32, tier: Int32, into hits: inout [ModelCompletionHit], depth: Int) {
    guard depth < 12 else { return }
    func add(_ ref: DeclRef, _ score: Int32, receiver: Ty) {
      let item = decl(ref)
      guard item.name != 0, item.kind != .initializer, item.kind != .subscriptDecl, item.nameToken >= 0 else { return }
      if item.kind == .function, item.name == TSWord.call { return }
      let holder = self.unit(ref)
      let text = holder.tokens[Int(item.nameToken)].kind == .string ? holder.tsStringValue(Int(item.nameToken)) : holder.string(Int(item.nameToken))
      guard let match = matchClass(typed, text.utf8[...]) else { return }
      hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: ref, receiver: receiver))
    }
    switch ty {
    case .module(let moduleName):
      for (_, sites) in exports(moduleName) {
        for case .decl(let ref) in sites.prefix(1) { add(ref, tier, receiver: ty) }
      }
    case .nominal(let ref, let args), .meta(.nominal(let ref, let args)):
      let isStatic: Bool
      if case .meta = ty { isStatic = true } else { isStatic = false }
      let item = decl(ref)
      if item.kind == .typeAlias {
        collectMembers(of: aliasType(ref, args), typed: typed, from: unitIndex, tier: tier, into: &hits, depth: depth + 1)
        return
      }
      if item.kind == .enumeration, !isStatic {
        collectMembers(of: globalType(TSWord.Number), typed: typed, from: unitIndex, tier: tier + 100, into: &hits, depth: depth + 1)
        return
      }
      for other in merged(ref) where decl(other).kind.hasMembers {
        let kind = decl(other).kind
        for child in self.unit(other).children(of: other.decl) {
          let member = self.unit(other).decls[Int(child)]
          if member.access == .isPrivate, other.unit != unitIndex { continue }
          switch kind {
          case .classType: if member.isStatic != isStatic { continue }
          case .namespace, .enumeration: if !isStatic, item.kind != .namespace { continue }
          default: if isStatic { continue }
          }
          add(DeclRef(unit: other.unit, decl: child), tier, receiver: ty)
        }
        let base = decl(other)
        let env = genericEnv(other, args)
        if base.kind == .classType, base.typeStart >= 0 {
          let parent = parseType(other.unit, Int(base.typeStart), Int(base.typeEnd), env: env)
          collectMembers(of: isStatic ? .meta(parent) : parent, typed: typed, from: unitIndex, tier: tier + 50, into: &hits, depth: depth + 1)
        } else if base.kind == .protocolType && !isStatic {
          for r in 0..<Int(base.inheritCount) {
            let range = self.unit(other).ranges[Int(base.inheritStart) + r]
            let parent = parseType(other.unit, Int(range.start), Int(range.end), env: env)
            collectMembers(of: parent, typed: typed, from: unitIndex, tier: tier + 50, into: &hits, depth: depth + 1)
          }
        }
      }
      if isStatic, item.kind == .classType {
        collectMembers(of: globalType(TSWord.Function), typed: typed, from: unitIndex, tier: tier + 200, into: &hits, depth: depth + 1)
      }
    case .constructed(let kind, let parts) where kind == Ty.union || kind == Ty.intersection:
      // An intersection has every part's members; a union's are listed from each part, each name once.
      var seen = Set(hits.map(\.name))
      for part in parts where !isUnknown(part) {
        var found: [ModelCompletionHit] = []
        collectMembers(of: part, typed: typed, from: unitIndex, tier: tier, into: &found, depth: depth + 1)
        for hit in found where seen.insert(hit.name).inserted { hits.append(hit) }
      }
    case .tuple(let items, _):
      collectMembers(of: globalType(TSWord.Array, [items.first ?? .unknown]), typed: typed, from: unitIndex, tier: tier, into: &hits, depth: depth + 1)
    case .function:
      collectMembers(of: globalType(TSWord.Function), typed: typed, from: unitIndex, tier: tier, into: &hits, depth: depth + 1)
    default:
      break
    }
  }

  /// Names on their own: locals, type parameters, the file's, imports, globals, keywords.
  private func scopeHits(unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    var hits: [ModelCompletionHit] = []
    let scan = body(unitIndex)
    for index in scan.visible(at: Int32(token)) {
      let local = scan.locals[Int(index)]
      guard local.token < Int32(token) || {
        if case .declaration = local.kind { return true }
        return false
      }() else { continue }
      let text = unit.string(Int(local.token))
      guard let match = matchClass(typed, text.utf8[...]) else { continue }
      if case .declaration(let declIndex) = local.kind {
        hits.append(ModelCompletionHit(name: text, match: match, score: 0, ref: DeclRef(unit: unitIndex, decl: declIndex)))
      } else {
        hits.append(ModelCompletionHit(name: text, match: match, score: 0, ref: nil, localToken: local.token, kind: .variable))
      }
    }
    for index in unit.chain(at: Int32(token)) {
      let item = unit.decls[Int(index)]
      for g in 0..<Int(item.genericCount) {
        let text = unit.string(Int(unit.generics[Int(item.genericStart) + g].token))
        if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 5, ref: nil, kind: .typeParameter)) }
      }
    }
    let facts = file(unit)
    for (index, item) in unit.decls.enumerated() where item.parent < 0 && !item.isLocal && item.name != 0 && item.nameToken >= 0 {
      if facts.exportOnly.contains(Int32(index)) || item.name == TSWord.defaultName || unit.tokens[Int(item.nameToken)].kind == .string { continue }
      if item.kind == .namespace, item.name == TSWord.global { continue }
      if Int(item.nameToken) == token { continue }
      let text = unit.string(Int(item.nameToken))
      if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 100, ref: DeclRef(unit: unitIndex, decl: Int32(index)))) }
    }
    for item in unit.imports where item.aliasToken >= 0 && Int(item.aliasToken) != token {
      let text = unit.tokens[Int(item.aliasToken)].kind == .string ? unit.tsStringValue(Int(item.aliasToken)) : unit.string(Int(item.aliasToken))
      guard let match = matchClass(typed, text.utf8[...]) else { continue }
      if case .decl(let ref)? = follow(item).first {
        hits.append(ModelCompletionHit(name: text, match: match, score: 120, ref: ref))
      } else {
        hits.append(ModelCompletionHit(name: text, match: match, score: 120, ref: nil, kind: .module, detail: item.moduleName))
      }
    }
    for (_, list) in globals {
      guard let ref = list.first(where: { decl($0).kind != .protocolType && decl($0).kind != .typeAlias }) ?? list.first else { continue }
      let holder = self.unit(ref)
      let item = decl(ref)
      guard item.nameToken >= 0, holder.tokens[Int(item.nameToken)].kind != .string else { continue }
      let text = holder.string(Int(item.nameToken))
      if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: isLib(holder) ? 300 : 200, ref: ref)) }
    }
    for word in statementKeywords {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 400, ref: nil, kind: .keyword)) }
    }
    return hits
  }

  /// Overloads are one entry: per name and kind of declaration.
  func signatureKey(_ ref: DeclRef, name text: String) -> UInt64 {
    hashName(text) &* 31 &+ UInt64(decl(ref).kind.rawValue)
  }

  private func itemKind(of ref: DeclRef) -> ModelCompletionItemKind {
    let item = decl(ref)
    let inType = item.parent >= 0 && self.unit(ref).decls[Int(item.parent)].kind != .namespace
    switch item.kind {
    case .classType: return .classType
    case .protocolType: return .interface
    case .typeAlias, .structure: return .structure
    case .enumeration: return .enumeration
    case .enumCase: return .enumMember
    case .namespace: return .module
    case .function: return inType ? .method : .function
    case .variable: return inType ? .property : .variable
    default: return .variable
    }
  }

  private func render(_ hit: ModelCompletionHit, unitIndex: Int32) -> ModelCompletionEntry {
    guard let ref = hit.ref else {
      var detail = hit.detail ?? ""
      if hit.localToken >= 0, let index = body(unitIndex).byToken[hit.localToken] {
        let ty = localValue(unitIndex, index).ty
        detail = isUnknown(ty) ? "" : describe(ty)
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
      for p in 0..<Int(item.paramCount) {
        let param = owner.params[Int(item.paramStart) + p]
        let name = param.nameToken >= 0 ? owner.string(Int(param.nameToken)) : "_"
        let type = param.typeStart >= 0 ? owner.text(from: Int(param.typeStart), to: Int(param.typeEnd)) : ""
        parameters.append((param.variadic ? "..." : "") + name + (type.isEmpty ? "" : ": " + type))
        if !param.hasDefault, !param.variadic { holes.append("${\(holes.count + 1):\(name.replacingOccurrences(of: "}", with: "\\}"))}") }
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
        let ty = declValue(ref, env: [:]).ty
        if !isUnknown(ty) { detail = describe(ty) }
      }
    }
    return ModelCompletionEntry(
      name: hit.name, label: label, detail: String(detail.prefix(120)), module: moduleLabel(owner), kind: hit.kind ?? itemKind(of: ref), insertText: insert,
      isSnippet: isSnippet, isDeprecated: isDeprecated(ref), needsUnwrap: false)
  }

  /// The module a file is, as an import would name it: a package's name, a lib file's, or the file's own.
  func moduleLabel(_ holder: Unit) -> String {
    if isLib(holder) { return "lib" }
    if let range = holder.path.range(of: "/node_modules/", options: .backwards) {
      let rest = holder.path[range.upperBound...].split(separator: "/")
      guard let first = rest.first else { return "" }
      if first.hasPrefix("@"), rest.count > 1 { return first + "/" + rest[1] }
      return String(first)
    }
    if holder.path.hasPrefix(project.root + "/") { return String(holder.path.dropFirst(project.root.count + 1)) }
    return URL(fileURLWithPath: holder.path).lastPathComponent
  }

  /// `@deprecated` in its doc comment.
  func isDeprecated(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    let holder = self.unit(ref)
    guard item.first >= 0, Int(item.first) < holder.tokens.count else { return false }
    var line = holder.source.lines.line(of: holder.tokens[Int(item.first)].start) - 1
    var budget = 30
    while line >= 0, budget > 0 {
      let text = holder.lineText(line)
      guard text.hasPrefix("*") || text.hasPrefix("/*") || text.hasPrefix("//") else { break }
      if text.contains("@deprecated") { return true }
      if text.hasPrefix("/*") { break }
      line -= 1
      budget -= 1
    }
    return false
  }

  /// A type as TypeScript writes it.
  func describe(_ ty: Ty) -> String {
    switch ty {
    case .nominal(let ref, let args):
      let item = decl(ref)
      if item.name == 0 { return "{…}" }
      var text = self.unit(ref).string(Int(item.nameToken))
      if item.name == TSWord.String || item.name == TSWord.Number || item.name == TSWord.Boolean, isLib(self.unit(ref)) { text = text.lowercased() }
      if !args.isEmpty { text += "<" + args.map(describe).joined(separator: ", ") + ">" }
      return text
    case .meta(let inner): return "typeof " + describe(inner)
    case .constructed(let kind, let args):
      if kind == Ty.union { return args.map(describe).joined(separator: " | ") }
      if kind == Ty.intersection { return args.map(describe).joined(separator: " & ") }
      if kind == Ty.map { return "Record<" + args.map(describe).joined(separator: ", ") + ">" }
      return ""
    case .function(let params, let result):
      return "(" + params.map(describe).joined(separator: ", ") + ") => " + (isUnknown(result) ? "any" : describe(result))
    case .tuple(let items, _): return "[" + items.map(describe).joined(separator: ", ") + "]"
    case .module(let moduleName): return "module " + (project.modules[moduleName].map { URL(fileURLWithPath: $0.displayName).lastPathComponent } ?? "")
    case .param(let word, _): return word == 0 ? "" : "any"
    default: return "any"
    }
  }
}
