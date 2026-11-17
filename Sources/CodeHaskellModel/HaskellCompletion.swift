import CodeModel
import CodeScan
import Foundation

/// Completion: after `Q.` what the imports named `Q` bring in; after `x.` with OverloadedRecordDot the fields in scope;
/// after `import` the modules (the project's and the stub's); elsewhere the locals in scope, the module's own top level,
/// what its imports bring in unqualified (the Prelude's too) and keywords. A comment or string gives nothing.
extension HaskellModel {
  static let keywords = [
    "case", "class", "data", "deriving", "do", "else", "if", "import", "in", "infix", "infixl", "infixr", "instance", "let", "module", "newtype", "of",
    "then", "type", "where", "qualified", "hiding", "forall",
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
    let site = unit.completionSite(at: offset)
    let prefix = site.prefix
    let typed = Array(prefix.utf8)
    func nothing() -> ModelCompletionList {
      ModelCompletionList(context: .none, state: .exact, prefix: prefix, replaceStart: site.replaceStart, items: [], isIncomplete: false)
    }
    if unit.isInCommentOrString(offset) || isAfterLineComment(unit, offset) { return nothing() }
    guard let file = hsFile(unitIndex) else { return nothing() }
    func finish(_ hits: [ModelCompletionHit], _ context: ModelCompletionContext, _ state: AnswerState) -> ModelCompletionList {
      project.rankCompletions(
        hits, context: context, state: state, prefix: prefix, replaceStart: site.replaceStart, limit: limit, in: unit,
        signature: { ref, text in UInt64(bitPattern: Int64(ref.unit) << 32 | Int64(ref.decl)) &* 31 &+ hashName(text) },
        render: { self.render($0) })
    }
    let token = site.anchor ?? site.at
    let before = token - 1
    // `import M|`, `import qualified M|`, `import Data.M|`.
    if let start = importStart(unit, before) {
      var written = ""
      var k = start
      while k <= before {
        written += unit.string(k)
        k += 1
      }
      var hits: [ModelCompletionHit] = []
      for moduleName in moduleNames() where moduleName.hasPrefix(written) {
        let rest = String(moduleName.dropFirst(written.count))
        // The next word alone (`Data`), and the whole rest (`Data.Map`).
        var names = [rest]
        if let dot = rest.firstIndex(of: ".") { names.insert(String(rest[..<dot]), at: 0) }
        for (index, text) in names.enumerated() {
          guard let match = matchClass(typed, text.utf8[...]) else { continue }
          hits.append(ModelCompletionHit(name: text, match: match, score: Int32(index) * 10, ref: nil, kind: .module))
        }
      }
      return finish(hits, .moduleName, .exact)
    }
    // `import M (a, |)` and `hiding (|)`: what the module exports.
    if let entry = importList(unit, file, before) {
      var scope = Scope()
      for target in moduleUnits(entry.module, from: unitIndex) where target != unitIndex { scope.merge(exports(target)) }
      var hits: [ModelCompletionHit] = []
      add(scope, typed: typed, score: 0, into: &hits)
      return finish(hits, .scope, .exact)
    }
    if before >= 1, unit.isToken(before, "."), unit.touchesPrevious(before), site.anchor == nil || unit.touchesPrevious(token) {
      // `Q.na|`: the qualifier's words before the dot.
      if unit.tokens[before - 1].kind == .identifier, isUpper(unit, before - 1) {
        var k = before - 1
        var parts = [unit.string(k)]
        while k >= 2, unit.isToken(k - 1, "."), unit.touchesPrevious(k), unit.touchesPrevious(k - 1), isUpper(unit, k - 2) {
          k -= 2
          parts.insert(unit.string(k), at: 0)
        }
        let qualifier = parts.joined(separator: ".")
        var scope = Scope()
        if qualifier == file.moduleName { scope.merge(ownTop(unitIndex)) }
        for (index, entry) in file.imports.enumerated() where (entry.alias ?? entry.module) == qualifier { scope.merge(importScope(unitIndex, index)) }
        if qualifier == "Prelude", implicitPrelude(file) {
          for target in moduleUnits("Prelude", from: unitIndex) where target != unitIndex { scope.merge(exports(target)) }
        }
        var hits: [ModelCompletionHit] = []
        add(scope, typed: typed, score: 0, into: &hits)
        // A module's name being written (`Data.Ma|` in an expression is rare): nothing known, say so.
        return finish(hits, .member, hits.isEmpty && scope.values.isEmpty && scope.types.isEmpty ? .unknown : .exact)
      }
      if file.extensions.contains("OverloadedRecordDot") {
        var hits: [ModelCompletionHit] = []
        var scope = Scope()
        for (key, refs) in visibleScope(unitIndex, file).values {
          let fields = refs.filter { info($0)?.kind == .field }
          if !fields.isEmpty { scope.values[key] = fields }
        }
        add(scope, typed: typed, score: 0, into: &hits)
        return finish(hits, .member, .exact)
      }
    }
    return finish(scopeHits(unitIndex, file, token: token, typed: typed), .scope, .exact)
  }

  private func isUpper(_ unit: Unit, _ i: Int) -> Bool {
    guard i >= 0, unit.tokens[i].kind == .identifier else { return false }
    let byte = unit.source.text[unit.tokens[i].start]
    return byte >= 0x41 && byte <= 0x5A
  }

  /// The first token of a module's name being written after `import` (and `qualified`), or nil.
  private func importStart(_ unit: Unit, _ before: Int) -> Int? {
    var k = before
    // The words and dots written so far.
    while k >= 0, unit.isToken(k, ".") || isUpper(unit, k), k == before || unit.touchesPrevious(k + 1) {
      k -= 1
    }
    let start = k + 1
    if k >= 0, unit.isToken(k, "qualified") { k -= 1 }
    // `import M` and an export list's `module M`.
    guard k >= 0, unit.isToken(k, "import") || unit.isToken(k, "module") && k > 0 && (unit.isToken(k - 1, "(") || unit.isToken(k - 1, ",")) else { return nil }
    return start
  }

  /// The import whose list (`import M (…)`, `hiding (…)`) a position is in.
  private func importList(_ unit: Unit, _ file: HaskellFile, _ before: Int) -> HsImport? {
    guard before >= 0 else { return nil }
    var open = unit.isByte(before, 0x28) && unit.tokens[before].kind == .open ? before : unit.matchingOpenBefore(before + 1)
    // `T(|)` inside the list: the list's own parenthesis.
    if let inner = open, inner > 0, unit.tokens[inner - 1].kind == .identifier, let outer = unit.matchingOpenBefore(inner) { open = outer }
    guard let open else { return nil }
    var k = open - 1
    var budget = 12
    while k >= 0, budget > 0, !unit.isToken(k, "import") {
      guard unit.tokens[k].kind == .identifier || unit.tokens[k].kind == .keyword || unit.tokens[k].kind == .string || unit.isToken(k, ".") else { return nil }
      k -= 1
      budget -= 1
    }
    guard k >= 0, unit.isToken(k, "import") else { return nil }
    return file.imports.first { $0.line == Int32(k) }
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
    return unit.source.text[tokens[low].start] == 0x2D
  }

  /// What a file sees unqualified: its own top level, its imports', the Prelude's.
  func visibleScope(_ unitIndex: Int32, _ file: HaskellFile) -> Scope {
    var scope = Scope()
    for index in file.imports.indices where !file.imports[index].isQualified { scope.merge(importScope(unitIndex, index)) }
    if implicitPrelude(file) {
      for target in moduleUnits("Prelude", from: unitIndex) where target != unitIndex { scope.merge(exports(target)) }
    }
    let own = ownTop(unitIndex)
    for (key, refs) in own.values { scope.values[key] = refs }
    for (key, refs) in own.types { scope.types[key] = refs }
    return scope
  }

  private func add(_ scope: Scope, typed: [UInt8], score: Int32, into hits: inout [ModelCompletionHit]) {
    for refs in [scope.values, scope.types] {
      for (_, list) in refs {
        guard let ref = list.first else { continue }
        let holder = unit(ref)
        let text = holder.string(Int(decl(ref).nameToken))
        guard let match = matchClass(typed, text.utf8[...]) else { continue }
        hits.append(ModelCompletionHit(name: text, match: match, score: score + (ref.unit == ref.unit && holder.isInterface ? 100 : 0), ref: ref))
      }
    }
  }

  private func scopeHits(_ unitIndex: Int32, _ file: HaskellFile, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    var hits: [ModelCompletionHit] = []
    var shown: Set<Name> = []
    // The innermost local of each name.
    var byName: [Name: (def: Int32, from: Int32)] = [:]
    for (def, local) in file.locals where local.from <= Int32(token) && Int32(token) <= local.to && local.kind != .field {
      let key = unit.hash(Int(def))
      if let known = byName[key], known.from >= local.from { continue }
      byName[key] = (def, local.from)
    }
    for (key, entry) in byName {
      let text = unit.string(Int(entry.def))
      shown.insert(key)
      guard let match = matchClass(typed, text.utf8[...]) else { continue }
      let isType = file.locals[entry.def]?.kind == .typeVariable
      hits.append(ModelCompletionHit(name: text, match: match, score: isType ? 50 : 0, ref: nil, localToken: entry.def, kind: isType ? .typeParameter : .variable))
    }
    var scope = visibleScope(unitIndex, file)
    for key in shown { scope.values[key] = nil }
    for (key, refs) in scope.values {
      guard let ref = refs.first else { continue }
      add(Scope(values: [key: [ref]]), typed: typed, score: ref.unit == unitIndex ? 50 : 100, into: &hits)
    }
    for (key, refs) in scope.types {
      guard let ref = refs.first else { continue }
      add(Scope(types: [key: [ref]]), typed: typed, score: ref.unit == unitIndex ? 50 : 100, into: &hits)
    }
    // Qualifiers: the imports' aliases, else their modules' first words.
    for entry in file.imports {
      let text = String((entry.alias ?? entry.module).split(separator: ".").first ?? "")
      if !text.isEmpty, let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 120, ref: nil, kind: .module)) }
    }
    for word in Self.keywords {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 250, ref: nil, kind: .keyword)) }
    }
    return hits
  }

  // MARK: Rendering

  func itemKind(_ ref: DeclRef) -> ModelCompletionItemKind {
    switch info(ref)?.kind {
    case .function, .foreign: return .function
    case .variable: return .variable
    case .data, .newtype: return .structure
    case .typeSynonym, .typeFamily, .dataFamily, .associatedType: return .classType
    case .classDecl: return .interface
    case .method: return .method
    case .constructor, .patternSynonym: return .enumMember
    case .field: return .field
    case nil: return .variable
    }
  }

  /// A declaration's type as written: its signature, a field's type, a synonym's right side.
  func typeText(_ ref: DeclRef) -> String {
    guard let item = info(ref), item.typeStart >= 0, item.typeEnd > item.typeStart else { return "" }
    return String(unit(ref).text(from: Int(item.typeStart), to: Int(item.typeEnd)).prefix(200))
  }

  func moduleText(_ unitIndex: Int32) -> String { hsFile(unitIndex)?.moduleName ?? "" }

  private func render(_ hit: ModelCompletionHit) -> ModelCompletionEntry {
    guard let ref = hit.ref else {
      return ModelCompletionEntry(
        name: hit.name, label: hit.name, detail: hit.detail ?? "", module: "", kind: hit.kind ?? .variable, insertText: hit.insert ?? hit.name, isSnippet: false,
        isDeprecated: false, needsUnwrap: false)
    }
    // An operator is written in parentheses where it's used as a name.
    let isOperator = unit(ref).tokens[Int(decl(ref).nameToken)].kind == .punctuation
    return ModelCompletionEntry(
      name: hit.name, label: hit.name, detail: typeText(ref), module: moduleText(ref.unit), kind: hit.kind ?? itemKind(ref),
      insertText: isOperator ? "(" + hit.name + ")" : hit.name, isSnippet: false, isDeprecated: false, needsUnwrap: false)
  }
}
