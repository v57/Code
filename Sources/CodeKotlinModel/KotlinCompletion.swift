import CodeJavaModel
import CodeModel
import CodeScan
import Foundation

private let statementKeywords = [
  "as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in", "interface", "is", "null", "object", "package", "return",
  "super", "this", "throw", "true", "try", "typealias", "val", "var", "when", "while", "by", "catch", "constructor", "companion", "data", "enum",
  "finally", "import", "init", "internal", "lateinit", "open", "override", "private", "protected", "public", "sealed", "suspend", "vararg",
  "abstract", "inline", "operator", "infix", "const",
]

/// Completion: what could be typed at a position, from the same tables as definitions. It works on the text being
/// edited, so nothing here looks past the cursor.
extension KotlinModel {
  public func complete(path: String, line: Int, character: Int, limit: Int = 200) -> ModelCompletionList {
    guard let unitIndex = project.unitByPath[path] else {
      return ModelCompletionList(context: .none, state: .unknown, prefix: "", replaceStart: 0, items: [], isIncomplete: false)
    }
    if isJava(unitIndex) { return java.complete(path: path, line: line, character: character, limit: limit) }
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
    // `import |`: the top-level packages.
    if before >= 0, unit.isToken(before, "import") || unit.isToken(before, "package") {
      if unit.isToken(before, "package") { return nothing(prefix, site.replaceStart) }
      var hits: [ModelCompletionHit] = []
      for sub in subpackages(of: "") {
        if let match = matchClass(typed, sub.utf8[...]) { hits.append(ModelCompletionHit(name: sub, match: match, score: 0, ref: nil, kind: .module, detail: sub)) }
      }
      return finish(hits, .moduleName, .exact)
    }
    // A new name: `fun na|`, `val na|`, `class Na|`.
    if before >= 0, !site.splitDot {
      for word: StaticString in ["fun", "val", "var", "class", "interface", "object", "typealias"] where unit.isToken(before, word) {
        if unit.isToken(before, "object"), unit.isToken(before - 1, "companion") == false, unit.isByte(before + 1, 0x3A) { break }
        return nothing(prefix, site.replaceStart)
      }
    }
    if before >= 0, unit.ktIsDot(before) || site.splitDot {
      let operand = operandType(unitIndex: unitIndex, dot: before)
      var hits: [ModelCompletionHit] = []
      switch operand {
      case .unknown:
        return finish([], .member, .unknown)
      case .module(let package):
        let text = packageNames[package] ?? ""
        for module in packageModules(text) {
          for (_, list) in module.top {
            for ref in list where decl(ref).access != .isPrivate && decl(ref).kind != .extensionDecl {
              let name = self.unit(ref).string(Int(decl(ref).nameToken))
              if let match = matchClass(typed, name.utf8[...]) { hits.append(ModelCompletionHit(name: name, match: match, score: 0, ref: ref)) }
            }
          }
        }
        for sub in subpackages(of: text) {
          if let match = matchClass(typed, sub.utf8[...]) { hits.append(ModelCompletionHit(name: sub, match: match, score: 50, ref: nil, kind: .module, detail: text + "." + sub)) }
        }
        return finish(hits, .member, .exact)
      case .meta(let type):
        guard case .nominal(let ref, _) = memberBase(type) else { return finish([], .member, .unknown) }
        collectMembers(of: type, typed: typed, staticOnly: true, into: &hits)
        if !isJava(ref), let companion = companion(of: ref) { collectMembers(of: .nominal(companion, []), typed: typed, staticOnly: false, into: &hits) }
        return finish(hits, .member, .exact)
      default:
        guard case .nominal = memberBase(operand) else { return finish([], .member, .unknown) }
        collectMembers(of: operand, typed: typed, staticOnly: false, into: &hits)
        collectExtensions(on: operand, unitIndex: unitIndex, typed: typed, score: 60, into: &hits)
        return finish(hits, .member, .exact)
      }
    }
    if before >= 0, unit.isToken(before, "::") {
      let operand = operandType(unitIndex: unitIndex, dot: before)
      var hits: [ModelCompletionHit] = []
      var base = operand
      if case .meta(let inner) = operand { base = inner }
      if let match = matchClass(typed, "class".utf8[...]) { hits.append(ModelCompletionHit(name: "class", match: match, score: 100, ref: nil, kind: .keyword)) }
      guard case .nominal = memberBase(base) else { return finish(hits, .member, operand == .unknown ? .unknown : .exact) }
      collectMembers(of: base, typed: typed, staticOnly: false, into: &hits)
      return finish(hits, .member, .exact)
    }
    // Where only a type goes: after `:` in a declaration, `is`, `as`.
    let typeOnly = before >= 0 && (unit.isToken(before, "is") || unit.isToken(before, "as") || unit.isToken(before, "?") && unit.isToken(before - 1, "as") || unit.isToken(before, ":") && before > 0 && (unit.ktIsName(before - 1) || unit.isByte(before - 1, 0x29)))
    // `f(na| = …)`: only the called function's parameters; `f(na|`: them too.
    let named = argumentNameHits(unitIndex: unitIndex, before: before, typed: typed)
    if !named.isEmpty, unit.isToken(prefix.isEmpty ? at : at + 1, "=") { return finish(named, .scope, .exact) }
    var hits = typeHits(unitIndex: unitIndex, token: at, typed: typed)
    if typeOnly { return finish(hits, .type, .exact) }
    hits += named
    hits += scopeHits(unitIndex: unitIndex, token: at, typed: typed)
    return finish(hits, .scope, .exact)
  }

  /// The next names under a package: `kotlin.` gives `collections`, `io`, …
  func subpackages(of package: String) -> [String] {
    var result: Set<String> = []
    let lead = package.isEmpty ? "" : package + "."
    var sources: [Set<String>] = []
    for module in project.modules.values where !module.isSDK { sources.append([module.displayName]) }
    for set in layout.extraSets { sources.append(set.prefixes) }
    if let platform = layout.workspace.platform { sources.append(platform.prefixes) }
    for set in layout.workspace.dependencies { sources.append(set.prefixes) }
    for prefixes in sources {
      for candidate in prefixes where candidate.hasPrefix(lead) && candidate.count > lead.count {
        let rest = candidate.dropFirst(lead.count)
        result.insert(String(rest.prefix { $0 != "." }))
      }
    }
    return result.sorted()
  }

  /// A type's properties, functions and nested classes, inherited ones too (a Java class's getters also as
  /// properties); a type's (`Foo.`) only its nested classes, enum entries and Java statics.
  private func collectMembers(of ty: Ty, typed: [UInt8], staticOnly: Bool, into hits: inout [ModelCompletionHit]) {
    guard case .nominal(let ref, _) = memberBase(ty) else { return }
    for (_, entries) in memberTable(of: ref) {
      for (index, entry) in entries.enumerated() {
        let item = decl(entry.ref)
        if staticOnly {
          let isStatic = isJava(entry.ref) ? item.isStatic || item.kind == .enumCase || item.kind.isNominal : item.kind == .enumCase || item.kind.isNominal
          if !isStatic { continue }
        } else if item.kind.isNominal || item.kind == .typeAlias || isJava(entry.ref) && item.isStatic {
          continue
        }
        if item.name == 0 { continue }
        let text = unit(entry.ref).string(Int(item.nameToken))
        let own = item.parent == ref.decl && entry.ref.unit == ref.unit
        let fromAny = item.parent >= 0 && (unit(entry.ref).decls[Int(item.parent)].name == name("Any") || unit(entry.ref).decls[Int(item.parent)].name == name("Object"))
        let score: Int32 = own ? 0 : (fromAny ? 120 : 40 + Int32(min(index, 5)))
        if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: entry.ref, receiver: ty)) }
        // `getName()` is also `name`.
        if !staticOnly, isJava(entry.ref), item.kind == .function, item.paramCount == 0, let property = Self.propertyName(ofGetter: text), property != text,
          let match = matchClass(typed, property.utf8[...])
        {
          hits.append(ModelCompletionHit(name: property, match: match, score: score + 5, ref: entry.ref, kind: .property, insert: property, receiver: ty))
        }
      }
    }
  }

  /// The extension functions and properties a receiver has here.
  func collectExtensions(on receiver: Ty, unitIndex: Int32, typed: [UInt8], score: Int32, into hits: inout [ModelCompletionHit]) {
    var holderNames: [Name] = hierarchy(of: receiver).map { decl($0.0).name }
    holderNames.append(KotlinWord.anyReceiver)
    let visible = visiblePackages(unitIndex)
    var seen: Set<DeclRef> = []
    for holderName in holderNames {
      for holder in project.extensions[holderName] ?? [] {
        let holderUnit = unit(holder)
        let package = packageOf(holder.unit)
        guard visible.contains(package) || holder.unit == unitIndex else { continue }
        for child in holderUnit.children(of: holder.decl) {
          let item = holderUnit.decls[Int(child)]
          guard item.name != 0, item.kind == .function || item.kind == .variable else { continue }
          let ref = DeclRef(unit: holder.unit, decl: child)
          guard seen.insert(ref).inserted else { continue }
          let text = holderUnit.string(Int(item.nameToken))
          guard let match = matchClass(typed, text.utf8[...]), extensionMatch(holder: holder, function: ref, receiver: receiver) != nil else { continue }
          let extra: Int32 = holderName == KotlinWord.anyReceiver ? 80 : 0
          hits.append(ModelCompletionHit(name: text, match: match, score: score + extra, ref: ref, receiver: receiver))
        }
      }
    }
  }

  /// Type names: type parameters, nested classes up the enclosing classes, the file's, imports, the package's, the
  /// defaults.
  private func typeHits(unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    var hits: [ModelCompletionHit] = []
    var seen: Set<DeclRef> = []
    func add(_ ref: DeclRef, _ score: Int32) {
      let item = decl(ref)
      guard item.kind.isNominal || item.kind == .typeAlias, item.name != 0, seen.insert(ref).inserted else { return }
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
        for (_, entries) in memberTable(of: DeclRef(unit: unitIndex, decl: index)) { for entry in entries { add(entry.ref, 20) } }
      }
    }
    for index in unit.decls.indices where unit.decls[index].parent < 0 && !unit.decls[index].isLocal { add(DeclRef(unit: unitIndex, decl: Int32(index)), 10) }
    for item in unit.imports {
      if isStarImport(item, in: unit) {
        for module in packageModules(item.moduleName) { for (_, list) in module.top { for ref in list where decl(ref).access != .isPrivate { add(ref, 90) } } }
      } else if let last = qualifiedSites(importWords(item), lastIsMember: true).last {
        for case .decl(let ref) in last { add(ref, 30) }
      }
    }
    for module in packageModules(packageOf(unitIndex)) { for (_, list) in module.top { for ref in list { add(ref, 60) } } }
    for package in Self.defaultPackages {
      for module in packageModules(package) { for (_, list) in module.top { for ref in list where decl(ref).access == .isPublic { add(ref, package == "java.lang" ? 160 : 140) } } }
    }
    return hits
  }

  /// Values on their own: locals, the implicit receivers' members and extensions, top-level functions and properties
  /// of the file's package, imports and the defaults, keywords.
  /// After `f(` or a `,` in its arguments: the parameters of the functions `f` may be, inserted as `name = `.
  private func argumentNameHits(unitIndex: Int32, before: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    guard before > 0, unit.isByte(before, 0x28) || unit.isByte(before, 0x2C),
      let open = unit.isByte(before, 0x28) ? before : unit.matchingOpenBefore(before), unit.isByte(open, 0x28), open > 0,
      unit.ktIsName(open - 1), !KotlinWord.hard.contains(unit.hash(open - 1)), let target = callTarget(unitIndex: unitIndex, nameToken: open - 1)
    else { return [] }
    var hits: [ModelCompletionHit] = []
    var seen: Set<String> = []
    // Java's parameters have no names to Kotlin.
    for callee in target.prefix(16) where !isJava(callee.ref) {
      let item = decl(callee.ref)
      let holder = self.unit(callee.ref)
      for p in 0..<Int(item.paramCount) {
        let param = holder.params[Int(item.paramStart) + p]
        guard param.nameToken >= 0 else { continue }
        let text = holder.string(Int(param.nameToken))
        guard seen.insert(text).inserted, let match = matchClass(typed, text.utf8[...]) else { continue }
        hits.append(ModelCompletionHit(name: text, match: match, score: 10, ref: nil, kind: .variable, insert: text + " = ", detail: text + " ="))
      }
    }
    return hits
  }

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
      if body.itLambda(at: Int32(token)) != nil, let match = matchClass(typed, "it".utf8[...]) {
        hits.append(ModelCompletionHit(name: "it", match: match, score: 0, ref: nil, kind: .variable))
      }
    }
    for (depth, receiver) in implicitReceivers(unitIndex: unitIndex, token: Int32(token)).enumerated() {
      var members: [ModelCompletionHit] = []
      collectMembers(of: receiver, typed: typed, staticOnly: false, into: &members)
      collectExtensions(on: receiver, unitIndex: unitIndex, typed: typed, score: 60, into: &members)
      for var hit in members {
        hit.score += 20 + Int32(depth * 30)
        hits.append(hit)
      }
    }
    var seen: Set<DeclRef> = []
    func add(_ ref: DeclRef, _ score: Int32) {
      let item = decl(ref)
      guard item.kind == .function || item.kind == .variable, item.name != 0, item.access != .isPrivate || ref.unit == unitIndex, seen.insert(ref).inserted else { return }
      let text = self.unit(ref).string(Int(item.nameToken))
      if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: ref)) }
    }
    for module in packageModules(packageOf(unitIndex)) { for (_, list) in module.top { for ref in list { add(ref, 70) } } }
    for item in unit.imports {
      if isStarImport(item, in: unit) {
        for module in packageModules(item.moduleName) { for (_, list) in module.top { for ref in list { add(ref, 100) } } }
      } else if let last = qualifiedSites(importWords(item), lastIsMember: true).last {
        for case .decl(let ref) in last { add(ref, 40) }
      }
    }
    for package in Self.defaultPackages where package != "java.lang" {
      for module in packageModules(package) { for (_, list) in module.top { for ref in list where decl(ref).access == .isPublic { add(ref, 150) } } }
    }
    for word in statementKeywords {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 250, ref: nil, kind: .keyword)) }
    }
    return hits
  }

  /// Overloads stay apart: a function's key is its name and parameter types.
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
    case .function: return item.parent >= 0 && !(unit(ref).decls[Int(item.parent)].kind == .extensionDecl) ? .method : .function
    case .initializer: return .constructor
    case .variable: return item.parent >= 0 ? .property : .variable
    default: return .variable
    }
  }

  private func render(_ hit: ModelCompletionHit, unitIndex: Int32) -> ModelCompletionEntry {
    guard let ref = hit.ref else {
      var detail = hit.detail ?? ""
      if hit.localToken >= 0 { detail = describe(localSiteType(unitIndex: unitIndex, token: hit.localToken)) }
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
    if item.kind == .function, hit.insert == nil {
      var parameters: [String] = []
      var holes: [String] = []
      let java = isJava(ref)
      for p in 0..<Int(item.paramCount) {
        let param = owner.params[Int(item.paramStart) + p]
        let type = oneLine(owner.text(from: Int(param.typeStart), to: Int(param.typeEnd)))
        let name = param.nameToken >= 0 ? owner.string(Int(param.nameToken)) : ""
        parameters.append(java ? type + " " + name : name + ": " + type)
        if !param.hasDefault { holes.append("${\(holes.count + 1):\((name.isEmpty ? type : name).replacingOccurrences(of: "}", with: "\\}"))}") }
      }
      label = hit.name + "(" + parameters.joined(separator: ", ") + ")"
      insert = hit.name + "(" + holes.joined(separator: ", ") + ")"
      isSnippet = !holes.isEmpty
      if item.typeStart >= 0 { detail = oneLine(owner.text(from: Int(item.typeStart), to: Int(item.typeEnd))) }
    } else if item.kind == .variable || item.kind == .function {
      detail = describe(valueType(of: ref))
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
