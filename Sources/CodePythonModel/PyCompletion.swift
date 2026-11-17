import CodeModel
import CodeScan
import Foundation

private let statementKeywords = [
  "False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except",
  "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while",
  "with", "yield",
]

/// Completion: what could be typed at a position, from the same tables as definitions. It works on the text being
/// edited, so nothing here looks past the cursor.
extension PyModel {
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
        signature: { self.signatureKey($0, name: $1) }, render: { self.render($0) })
    }
    // A new name isn't asked about.
    if before >= 0, unit.isToken(before, "def") || unit.isToken(before, "class") || unit.isToken(before, "as") || unit.isToken(before, "global")
      || unit.isToken(before, "nonlocal")
    {
      return nothing(site.prefix, site.replaceStart)
    }
    // The statement so far, on its logical line.
    let lines = file(unit).lines!
    let lineStart = before >= 0 ? Int(lines.starts[lines.line(of: before)]) : 0
    // `import a.b|`, `from a.b|`: modules.
    if before >= lineStart, unit.isToken(lineStart, "import") || unit.isToken(lineStart, "from") && !(lineStart..<site.at).contains(where: { unit.isToken($0, "import") }) {
      var k = before
      var dotted: [String] = []
      if unit.isAllDots(k) || unit.isByte(k, 0x2E) {
        // What's before the dot: the package.
        var parts: [String] = []
        var j = k
        var level = 0
        while j > lineStart, unit.isAllDots(j) || unit.isByte(j, 0x2E) {
          if j - 1 > lineStart, unit.tokens[j - 1].kind == .identifier {
            parts.insert(unit.string(j - 1), at: 0)
            j -= 2
          } else {
            level = unit.tokens[j].end - unit.tokens[j].start
            j -= 1
            break
          }
        }
        dotted = parts
        k = j
        let key = layout.resolve(dotted.joined(separator: "."), level: level, from: unit.path)
        guard let package = module(key) else { return finish([], .member, .unknown) }
        var hits: [ModelCompletionHit] = []
        for (_, text) in submodules(of: package) {
          if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 0, ref: nil, kind: .module)) }
        }
        return finish(hits, .member, .exact)
      }
      if unit.isToken(before, "import") || unit.isToken(before, "from") || unit.isByte(before, 0x2C) {
        var hits: [ModelCompletionHit] = []
        for (text, score) in layout.topLevelModules(from: unit.path) {
          if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: nil, kind: .module)) }
        }
        return finish(hits, .scope, .exact)
      }
      return nothing(site.prefix, site.replaceStart)
    }
    // `from m import na|`: what m has.
    if unit.isToken(lineStart, "from"), let importToken = (lineStart..<site.at).first(where: { unit.isToken($0, "import") }) {
      guard before == importToken || unit.isByte(before, 0x2C) || unit.isByte(before, 0x28) else { return nothing(site.prefix, site.replaceStart) }
      var level = 0
      var dotted = ""
      for k in lineStart + 1..<importToken {
        if unit.isAllDots(k), dotted.isEmpty {
          level += unit.tokens[k].end - unit.tokens[k].start
        } else {
          dotted += unit.string(k)
        }
      }
      let key = layout.resolve(dotted, level: level, from: unit.path)
      guard let target = module(key) else { return finish([], .member, .unknown) }
      var hits: [ModelCompletionHit] = []
      collectMembers(of: .module(target.name), typed: typed, from: unitIndex, into: &hits)
      return finish(hits, .member, .exact)
    }
    if before >= 0, unit.isByte(before, 0x2E) && !unit.isAllDots(before) || unit.isByte(before, 0x2E) && unit.tokens[before].end - unit.tokens[before].start == 1 || site.splitDot {
      let operand = operandType(unitIndex, end: before)
      if isUnknown(operand) { return finish([], .member, .unknown) }
      var hits: [ModelCompletionHit] = []
      collectMembers(of: operand, typed: typed, from: unitIndex, into: &hits)
      return finish(hits, .member, .exact)
    }
    return finish(scopeHits(unitIndex: unitIndex, token: site.at, typed: typed), .scope, .exact)
  }

  /// What a value of a type has: a module's names and submodules, a class's members along its MRO (its own first).
  private func collectMembers(of ty: Ty, typed: [UInt8], from unitIndex: Int32, into hits: inout [ModelCompletionHit]) {
    var seen = Set(hits.map(\.name))
    func add(_ text: String, _ ref: DeclRef?, _ score: Int32, kind: ModelCompletionItemKind? = nil, receiver: Ty? = nil) {
      guard seen.insert(text).inserted, let match = matchClass(typed, text.utf8[...]) else { return }
      // Private names after the rest, special ones last.
      let penalty: Int32 = text.hasPrefix("__") && text.hasSuffix("__") ? 300 : text.hasPrefix("_") && typed.first != 0x5F ? 150 : 0
      hits.append(ModelCompletionHit(name: text, match: match, score: score + penalty, ref: ref, kind: kind, receiver: receiver))
    }
    switch ty {
    case .module(let moduleName):
      guard let module = project.modules[moduleName] else { return }
      var visited: Set<Name> = []
      /// A module's top-level names, with what its `from m import *` brings (only `__all__`'s, or the public ones).
      func names(of module: Module, score: Int32, only: (String) -> Bool) {
        guard visited.insert(module.name).inserted, visited.count < 24, let primary = primaryUnit(module) else { return }
        let holder = project.units[Int(primary)]
        let facts = file(holder)
        for binding in facts.bindings where binding.scope == 0 {
          let text = holder.string(Int(binding.token))
          guard only(text) else { continue }
          if binding.importIndex >= 0, holder.imports[Int(binding.importIndex)].member == PyWord.star { continue }
          var tier = score
          if let all = facts.dunderAll, !all.contains(text) { tier += 40 }
          add(text, binding.decl >= 0 ? DeclRef(unit: primary, decl: binding.decl) : nil, tier, kind: binding.decl >= 0 ? nil : binding.importIndex >= 0 ? .module : .variable)
        }
        for importIndex in facts.stars[0] ?? [] {
          guard let target = self.module(holder.imports[Int(importIndex)].moduleName), let targetUnit = primaryUnit(target) else { continue }
          let exported = file(targetUnit).dunderAll.map(Set.init)
          names(of: target, score: score + 10) { text in only(text) && (exported?.contains(text) ?? !text.hasPrefix("_")) }
        }
      }
      names(of: module, score: 0) { _ in true }
      if isPackage(module) {
        for (_, text) in submodules(of: module) { add(text, nil, 20, kind: .module) }
      }
    case .nominal(let ref, _), .meta(.nominal(let ref, _)):
      guard decl(ref).kind == .classType else { return }
      var tier: Int32 = 0
      for entry in mro(ref) {
        guard let entry else { continue }
        let holder = unit(entry)
        for child in holder.children(of: entry.decl) where !holder.decls[Int(child)].isLocal {
          add(holder.string(Int(holder.decls[Int(child)].nameToken)), DeclRef(unit: entry.unit, decl: child), tier, receiver: ty)
        }
        tier = min(tier + 50, 250)
      }
      var fallback = builtinClass(PyWord.object)
      if case .meta = ty { fallback = builtinClass(PyWord.type) }
      if case .nominal(let base, _) = fallback, base != ref {
        let holder = unit(base)
        for child in holder.children(of: base.decl) { add(holder.string(Int(holder.decls[Int(child)].nameToken)), DeclRef(unit: base.unit, decl: child), 300, receiver: ty) }
      }
    case .tuple:
      collectMembers(of: builtinClass(name("tuple")), typed: typed, from: unitIndex, into: &hits)
    case .constructed(let kind, let parts) where kind == Ty.union:
      for part in parts where !isUnknown(part) && part != PyTy.none { collectMembers(of: part, typed: typed, from: unitIndex, into: &hits) }
    case .constructed(let kind, let parts) where kind == PyTy.superKind:
      if case .nominal(let ref, _)? = parts.first, let base = mro(ref).dropFirst().compactMap({ $0 }).first {
        collectMembers(of: .nominal(base, []), typed: typed, from: unitIndex, into: &hits)
      }
    default:
      break
    }
  }

  /// Names on their own: the scope's and enclosing functions', the module's, `import *`'s, builtins, keywords.
  private func scopeHits(unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    let facts = file(unit)
    var hits: [ModelCompletionHit] = []
    var seen: Set<String> = []
    func add(_ binding: PyBinding, _ score: Int32, in holderIndex: Int32) {
      let holder = project.units[Int(holderIndex)]
      if holderIndex == unitIndex, Int(binding.token) == token { return }
      let text = holder.string(Int(binding.token))
      guard !seen.contains(text), let match = matchClass(typed, text.utf8[...]) else { return }
      seen.insert(text)
      if binding.decl >= 0 {
        hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: DeclRef(unit: holderIndex, decl: binding.decl)))
      } else if binding.importIndex >= 0, case .decl(let ref)? = follow(holderIndex, Int(binding.importIndex)).first {
        hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: ref))
      } else {
        hits.append(
          ModelCompletionHit(
            name: text, match: match, score: score, ref: nil, localToken: holderIndex == unitIndex ? binding.token : -1,
            kind: binding.importIndex >= 0 ? .module : .variable))
      }
    }
    // Scopes from the innermost out, classes only their own.
    var scope = facts.scope(at: min(token, max(0, unit.tokens.count - 1)))
    if token >= unit.tokens.count || token > 0 && facts.scope(at: token - 1) != scope && token > 0 {
      scope = facts.scope(at: max(0, token - 1))
    }
    var first = true
    var score: Int32 = 0
    while scope > 0 {
      let item = facts.scopes[Int(scope)]
      if first || item.kind != .classBody {
        for binding in facts.bindings where binding.scope == scope { add(binding, score, in: unitIndex) }
      }
      first = false
      score += 20
      scope = item.parent
    }
    for binding in facts.bindings where binding.scope == 0 {
      if binding.importIndex >= 0, unit.imports[Int(binding.importIndex)].member == PyWord.star { continue }
      add(binding, 100, in: unitIndex)
    }
    for importIndex in facts.stars[0] ?? [] {
      guard let target = module(unit.imports[Int(importIndex)].moduleName), let primary = primaryUnit(target) else { continue }
      let targetFile = file(primary)
      let holder = project.units[Int(primary)]
      for binding in targetFile.bindings where binding.scope == 0 {
        let text = holder.string(Int(binding.token))
        if let all = targetFile.dunderAll { if !all.contains(text) { continue } } else if text.hasPrefix("_") { continue }
        add(binding, 150, in: primary)
      }
    }
    if let builtins, let primary = builtins.units.first {
      let holder = project.units[Int(primary)]
      for binding in file(primary).bindings where binding.scope == 0 && binding.importIndex < 0 {
        let text = holder.string(Int(binding.token))
        if text.hasPrefix("_") { continue }
        add(binding, 300, in: primary)
      }
    }
    for word in statementKeywords where !seen.contains(word) {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 400, ref: nil, kind: .keyword)) }
    }
    return hits
  }

  /// Overloads and a name's several bindings are one entry.
  func signatureKey(_ ref: DeclRef, name text: String) -> UInt64 {
    hashName(text) &* 31 &+ (decl(ref).kind == .classType ? 1 : 0)
  }

  private func itemKind(of ref: DeclRef) -> ModelCompletionItemKind {
    let item = decl(ref)
    let inClass = item.parent >= 0 && unit(ref).decls[Int(item.parent)].kind == .classType
    switch item.kind {
    case .classType: return .classType
    case .function:
      if (file(ref.unit).decorations[ref.decl] ?? []).contains(.property) { return .property }
      return inClass ? .method : .function
    case .variable: return inClass ? .property : .variable
    default: return .variable
    }
  }

  private func render(_ hit: ModelCompletionHit) -> ModelCompletionEntry {
    guard let ref = hit.ref else {
      return ModelCompletionEntry(
        name: hit.name, label: hit.name, detail: hit.detail ?? "", module: "", kind: hit.kind ?? .variable, insertText: hit.insert ?? hit.name,
        isSnippet: false, isDeprecated: false, needsUnwrap: false)
    }
    let item = decl(ref)
    let owner = unit(ref)
    let flags = file(ref.unit).decorations[ref.decl] ?? []
    var label = hit.name
    var insert = hit.insert ?? hit.name
    var isSnippet = false
    var detail = ""
    if item.kind == .function, !flags.contains(.property) {
      var parameters: [String] = []
      var holes: [String] = []
      var skipFirst = item.parent >= 0 && owner.decls[Int(item.parent)].kind == .classType && !flags.contains(.staticMethod)
      for p in 0..<Int(item.paramCount) {
        let param = owner.params[Int(item.paramStart) + p]
        guard param.nameToken >= 0 else { continue }
        if skipFirst {
          skipFirst = false
          continue
        }
        let name = owner.string(Int(param.nameToken))
        let type = param.typeStart >= 0 ? owner.text(from: Int(param.typeStart), to: Int(param.typeEnd)) : ""
        parameters.append((param.variadic ? "*" : "") + name + (type.isEmpty ? "" : ": " + type))
        if !param.hasDefault, !param.variadic { holes.append("${\(holes.count + 1):\(name.replacingOccurrences(of: "}", with: "\\}"))}") }
      }
      label = hit.name + "(" + parameters.joined(separator: ", ") + ")"
      if hit.insert == nil {
        insert = hit.name + "(" + holes.joined(separator: ", ") + ")"
        isSnippet = !holes.isEmpty
      }
      if item.typeStart >= 0 { detail = owner.text(from: Int(item.typeStart), to: Int(item.typeEnd)) }
    } else if item.kind == .function {
      if item.typeStart >= 0 { detail = owner.text(from: Int(item.typeStart), to: Int(item.typeEnd)) }
    } else if item.kind == .variable {
      if let index = file(ref.unit).bindingOfDecl[ref.decl], case let binding = file(ref.unit).bindings[Int(index)], binding.annotationStart >= 0 {
        detail = owner.text(from: Int(binding.annotationStart), to: Int(binding.annotationEnd))
      } else {
        let ty = siteType(.decl(ref))
        if !isUnknown(ty) { detail = describe(ty) }
      }
    }
    return ModelCompletionEntry(
      name: hit.name, label: label, detail: String(detail.prefix(120)), module: moduleLabel(owner), kind: hit.kind ?? itemKind(of: ref), insertText: insert,
      isSnippet: isSnippet, isDeprecated: flags.contains(.deprecated), needsUnwrap: false)
  }
}

extension PyLayout {
  /// Modules an `import` can name: the project's roots' first, then the standard library's, the stubbed C modules
  /// and the environment's packages; with a tier each.
  func topLevelModules(from path: String) -> [(String, Int32)] {
    var result: [String: Int32] = [:]
    let manager = FileManager.default
    func scan(_ base: String, _ score: Int32) {
      for entry in (try? manager.contentsOfDirectory(atPath: base)) ?? [] where !entry.hasPrefix(".") && !entry.hasPrefix("__") {
        var text = entry
        if PyLayout.isSource(entry) {
          text = String(entry[..<entry.firstIndex(of: ".")!])
        } else {
          var isDirectory: ObjCBool = false
          guard !entry.contains("."), !PyLayout.skipped.contains(entry), manager.fileExists(atPath: base + "/" + entry, isDirectory: &isDirectory),
            isDirectory.boolValue
          else { continue }
        }
        guard text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), result[text] == nil else { continue }
        result[text] = score
      }
    }
    scan((path as NSString).deletingLastPathComponent, 0)
    for base in roots { scan(base, 20) }
    if let stdlib { scan(stdlib, 200) }
    for module in PyStubs.modules.keys where !module.hasPrefix("_") && result[module] == nil { result[module] = 200 }
    if let sitePackages { scan(sitePackages, 100) }
    return result.map { ($0.key, $0.value) }
  }
}
