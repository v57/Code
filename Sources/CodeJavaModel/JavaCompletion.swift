import CodeModel
import CodeScan
import Foundation

private let statementKeywords = [
  "abstract", "boolean", "break", "byte", "case", "catch", "char", "class", "continue", "default", "do", "double", "else", "enum", "extends",
  "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "new", "null", "private",
  "protected", "public", "return", "short", "static", "super", "switch", "synchronized", "this", "throw", "throws", "try", "var", "void",
  "while", "true", "false", "record", "yield",
]

/// Completion: what could be typed at a position, from the same tables as definitions. It works on the text being
/// edited, so nothing here looks past the cursor.
extension JavaModel {
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
    let at = site.at
    let prefix = site.prefix
    let typed = Array(prefix.utf8)
    let before = at - 1
    func finish(_ hits: [ModelCompletionHit], _ context: ModelCompletionContext, _ state: AnswerState) -> ModelCompletionList {
      project.rankCompletions(
        hits, context: context, state: state, prefix: prefix, replaceStart: site.replaceStart, limit: limit, in: unit,
        signature: { self.signatureKey($0, name: $1) }, render: { self.render($0, unitIndex: unitIndex) })
    }
    // In a run of punctuation (`List<|>`, `Map<K,|>`): what the part before the cursor asks for.
    if at < unit.tokens.count, unit.tokens[at].kind == .punctuation, unit.tokens[at].start < offset, offset < unit.tokens[at].end {
      let last = unit.source.text[offset - 1]
      if last == 0x3C || last == 0x2C || last == 0x3F { return finish(typeHits(unitIndex: unitIndex, token: at, typed: typed), .type, .exact) }
      return finish(scopeHits(unitIndex: unitIndex, token: at, typed: typed) + typeHits(unitIndex: unitIndex, token: at, typed: typed), .scope, .exact)
    }
    // `import |`, `import static |`: the top-level packages.
    if before >= 0, unit.isToken(before, "import") || unit.isToken(before, "static") && unit.isToken(before - 1, "import") {
      var hits: [ModelCompletionHit] = []
      for sub in subpackages(of: "") {
        if let match = matchClass(typed, sub.utf8[...]) { hits.append(ModelCompletionHit(name: sub, match: match, score: 0, ref: nil, kind: .module, detail: sub)) }
      }
      if !unit.isToken(before, "static"), let match = matchClass(typed, "static".utf8[...]) {
        hits.append(ModelCompletionHit(name: "static", match: match, score: 100, ref: nil, kind: .keyword))
      }
      return finish(hits, .moduleName, .exact)
    }
    // A new name: `class Na|`, `int na|`, `Foo<Bar> na|`, `package a|`.
    if before >= 0 {
      if unit.isToken(before, "class") || unit.isToken(before, "interface") || unit.isToken(before, "enum") || unit.isToken(before, "record") && !unit.isByte(before - 1, 0x2E)
        || unit.isToken(before, "package") || unit.isToken(before, "@interface")
      {
        return nothing(prefix, site.replaceStart)
      }
      let isDeclarationType = unit.javaIsName(before) && !unit.isToken(before, "yield") && !unit.isToken(before, "var") || unit.isToken(before, "var")
        || unit.tokens[before].kind == .keyword && JavaWord.primitives.contains(unit.hash(before))
        || unit.isByte(before, 0x5D) && unit.isByte(before - 1, 0x5B)
        || unit.tokens[before].kind == .punctuation && unit.javaOnly(before, ">") && before > 0 && isTypeArgumentsClose(unit, before)
      if isDeclarationType, !site.splitDot { return nothing(prefix, site.replaceStart) }
    }
    if before >= 0, unit.isByte(before, 0x2E) || site.splitDot {
      let operand = operandType(unitIndex: unitIndex, dot: before)
      var hits: [ModelCompletionHit] = []
      switch operand {
      case .unknown:
        return finish([], .member, .unknown)
      case .module(let package):
        let text = packageNames[package] ?? ""
        for module in packageModules(text) {
          for (_, list) in module.top {
            for ref in list where decl(ref).kind.isNominal && decl(ref).access != .isPrivate {
              let name = self.unit(ref).string(Int(decl(ref).nameToken))
              if let match = matchClass(typed, name.utf8[...]) { hits.append(ModelCompletionHit(name: name, match: match, score: 0, ref: ref)) }
            }
          }
        }
        for sub in subpackages(of: text) {
          if let match = matchClass(typed, sub.utf8[...]) {
            hits.append(ModelCompletionHit(name: sub, match: match, score: 50, ref: nil, kind: .module, detail: text + "." + sub))
          }
        }
        return finish(hits, .member, .exact)
      case .meta(let type):
        collectMembers(of: type, typed: typed, staticOnly: true, into: &hits)
        for word in ["class", "this"] {
          if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 300, ref: nil, kind: .keyword)) }
        }
        return finish(hits, .member, .exact)
      case .constructed(let kind, _) where kind == Ty.array:
        if let match = matchClass(typed, "length".utf8[...]) { hits.append(ModelCompletionHit(name: "length", match: match, score: 0, ref: nil, kind: .field, detail: "int")) }
        if let object = langType(JavaWord.object) { collectMembers(of: .nominal(object, []), typed: typed, staticOnly: false, into: &hits) }
        return finish(hits, .member, .exact)
      default:
        guard case .nominal = memberBase(operand) else { return finish([], .member, .unknown) }
        collectMembers(of: operand, typed: typed, staticOnly: false, into: &hits)
        return finish(hits, .member, .exact)
      }
    }
    if before >= 0, unit.isToken(before, "::") {
      let operand = operandType(unitIndex: unitIndex, dot: before)
      var hits: [ModelCompletionHit] = []
      var base = operand
      if case .meta(let inner) = operand {
        base = inner
        if let match = matchClass(typed, "new".utf8[...]) { hits.append(ModelCompletionHit(name: "new", match: match, score: 100, ref: nil, kind: .keyword)) }
      }
      guard case .nominal = memberBase(base) else { return finish(hits, .member, .unknown) }
      var members: [ModelCompletionHit] = []
      collectMembers(of: base, typed: typed, staticOnly: false, into: &members)
      hits += members.filter { $0.ref.map { decl($0).kind == .function } ?? false }
      return finish(hits, .member, .exact)
    }
    // Where only a type goes: after `new`, `extends`, `implements`, `throws`, `instanceof`, in type arguments.
    let typeOnly = before >= 0 && (unit.isToken(before, "new") || unit.isToken(before, "extends") || unit.isToken(before, "implements") || unit.isToken(before, "throws")
      || unit.isToken(before, "instanceof"))
    var hits = typeHits(unitIndex: unitIndex, token: at, typed: typed)
    if typeOnly { return finish(hits, .type, .exact) }
    hits += scopeHits(unitIndex: unitIndex, token: at, typed: typed)
    return finish(hits, .scope, .exact)
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
        if depth == 0 { return unit.javaTypeArgumentsEnd(k) == close + 1 && k > 0 && unit.javaIsName(k - 1) }
      } else if unit.tokens[k].kind == .open || unit.isByte(k, 0x3B) {
        return false
      }
      k -= 1
    }
    return false
  }

  /// The next names under a package: `java.` gives `util`, `io`, …
  func subpackages(of package: String) -> [String] {
    var result: Set<String> = []
    let lead = package.isEmpty ? "" : package + "."
    var sources: [Set<String>] = [layout.projectPrefixes]
    if let platform = layout.workspace.platform { sources.append(platform.prefixes) }
    for set in layout.workspace.dependencies { sources.append(set.prefixes) }
    for prefixes in sources {
      for candidate in prefixes where candidate.hasPrefix(lead) && candidate.count > lead.count {
        let rest = candidate.dropFirst(lead.count)
        if !rest.contains(".") { result.insert(String(rest)) }
      }
    }
    return result.sorted()
  }

  /// A type's fields, methods and member types, inherited ones too; a type's (`Foo.`) only its static ones.
  private func collectMembers(of ty: Ty, typed: [UInt8], staticOnly: Bool, into hits: inout [ModelCompletionHit]) {
    guard case .nominal(let ref, _) = memberBase(ty) else { return }
    for (_, entries) in memberTable(of: ref) {
      for (index, entry) in entries.enumerated() {
        let item = decl(entry.ref)
        if staticOnly, !(item.isStatic || item.kind == .enumCase || item.kind.isNominal) { continue }
        if !staticOnly, item.kind.isNominal { continue }
        if item.name == 0 { continue }
        let text = unit(entry.ref).string(Int(item.nameToken))
        guard let match = matchClass(typed, text.utf8[...]) else { continue }
        // Own members before inherited ones; Object's last.
        let own = item.parent == ref.decl && entry.ref.unit == ref.unit
        let fromObject = item.parent >= 0 && unit(entry.ref).decls[Int(item.parent)].name == JavaWord.object
        let score: Int32 = own ? 0 : (fromObject ? 120 : 40 + Int32(min(index, 5)))
        hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: entry.ref, receiver: ty))
      }
    }
  }

  /// Type names: type parameters, member types up the enclosing classes, the file's, imports, the package's, java.lang.
  private func typeHits(unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    var hits: [ModelCompletionHit] = []
    func add(_ ref: DeclRef, _ score: Int32) {
      let item = decl(ref)
      guard item.kind.isNominal, item.name != 0 else { return }
      let text = self.unit(ref).string(Int(item.nameToken))
      if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: ref)) }
    }
    for index in unit.chain(at: Int32(token)) {
      let item = unit.decls[Int(index)]
      for g in 0..<Int(item.genericCount) {
        let text = unit.string(Int(unit.generics[Int(item.genericStart) + g].token))
        if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 5, ref: nil, kind: .typeParameter)) }
      }
      if item.kind.isNominal {
        for (_, entries) in memberTable(of: DeclRef(unit: unitIndex, decl: index)) {
          for entry in entries where decl(entry.ref).kind.isNominal { add(entry.ref, 20) }
        }
      }
    }
    for index in unit.decls.indices where unit.decls[index].parent < 0 { add(DeclRef(unit: unitIndex, decl: Int32(index)), 10) }
    for item in unit.imports {
      let path = importPath(item, in: unit)
      guard !path.words.isEmpty, !path.isStatic else { continue }
      let words = path.words.map { unit.string($0) }
      if path.onDemand {
        for module in packageModules(words.joined(separator: ".")) {
          for (_, list) in module.top { for ref in list where decl(ref).access != .isPrivate { add(ref, 90) } }
        }
      } else if let last = qualifiedSites(words, staticMember: false).last {
        for case .decl(let ref) in last { add(ref, 30) }
      }
    }
    for module in packageModules(packageOf(unitIndex)) {
      for (_, list) in module.top { for ref in list { add(ref, 60) } }
    }
    for module in packageModules("java.lang") {
      for (_, list) in module.top { for ref in list where decl(ref).access == .isPublic { add(ref, 140) } }
    }
    for word in JavaWord.primitiveNames.values {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 200, ref: nil, kind: .keyword)) }
    }
    return hits
  }

  /// Values on their own: locals, the enclosing classes' fields and methods (inherited too), static imports, keywords.
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
    for (depth, owner) in enclosingClasses(unitIndex: unitIndex, token: Int32(token)).enumerated() {
      var members: [ModelCompletionHit] = []
      collectMembers(of: ownType(owner), typed: typed, staticOnly: false, into: &members)
      for var hit in members {
        hit.score += 20 + Int32(depth * 30)
        hits.append(hit)
      }
    }
    for item in unit.imports {
      let path = importPath(item, in: unit)
      guard path.isStatic, !path.words.isEmpty else { continue }
      var words = path.words.map { unit.string($0) }
      let single = path.onDemand ? nil : words.removeLast()
      guard let last = qualifiedSites(words, staticMember: false).last, case .decl(let ref)? = last.first, decl(ref).kind.isNominal else { continue }
      for (_, entries) in memberTable(of: ref) {
        for entry in entries where decl(entry.ref).isStatic || decl(entry.ref).kind == .enumCase {
          let text = self.unit(entry.ref).string(Int(decl(entry.ref).nameToken))
          if let single, single != text { continue }
          if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 80, ref: entry.ref)) }
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
      let holder = unit(ref)
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
    case .variable: return item.parent >= 0 ? .field : .variable
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
        let type = oneLine(owner.text(from: Int(param.typeStart), to: Int(param.typeEnd)))
        let name = param.nameToken >= 0 ? owner.string(Int(param.nameToken)) : ""
        parameters.append(name.isEmpty ? type : type + " " + name)
        holes.append("${\(p + 1):\((name.isEmpty ? type : name).replacingOccurrences(of: "}", with: "\\}"))}")
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
    return ModelCompletionEntry(
      name: hit.name, label: label, detail: detail, module: packageOf(ref.unit), kind: hit.kind ?? itemKind(of: ref), insertText: insert,
      isSnippet: isSnippet, isDeprecated: isDeprecated(ref), needsUnwrap: false)
  }

  /// `@Deprecated` among its annotations.
  func isDeprecated(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    let holder = unit(ref)
    var k = Int(item.first)
    let end = Int(item.nameToken >= 0 ? item.nameToken : item.first)
    while k < end, k < holder.tokens.count {
      if holder.tokens[k].kind == .attribute, holder.isToken(k, "@Deprecated") { return true }
      k += 1
    }
    return false
  }
}
