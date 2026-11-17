import CodeModel
import CodeScan
import Foundation

private let cKeywords = [
  "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline",
  "int", "long", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void",
  "volatile", "while", "bool", "true", "false",
]
private let cppKeywords = [
  "auto", "class", "constexpr", "delete", "namespace", "new", "nullptr", "private", "protected", "public", "template", "this", "throw",
  "try", "catch", "typename", "using", "virtual", "override", "static_cast", "const_cast", "reinterpret_cast", "dynamic_cast", "noexcept",
]
private let objcKeywords = ["self", "super", "nil", "YES", "NO", "id", "instancetype"]

/// Completion: members after `.`, `->` and `::`, else what's in scope (locals, the class's members, the closure's
/// declarations and macros, keywords), from the same tables as definitions.
extension CModel {
  public func complete(path: String, line: Int, character: Int, limit: Int = 200) -> ModelCompletionList {
    guard let unitIndex = project.unitByPath[path] else {
      return ModelCompletionList(context: .none, state: .unknown, prefix: "", replaceStart: 0, items: [], isIncomplete: false)
    }
    let offset = project.units[Int(unitIndex)].source.lines.offset(line: line, character: character, in: project.units[Int(unitIndex)].source.text)
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
    let before = (site.anchor ?? at) - 1
    func finish(_ hits: [ModelCompletionHit], _ context: ModelCompletionContext, _ state: AnswerState) -> ModelCompletionList {
      project.rankCompletions(
        hits, context: context, state: state, prefix: prefix, replaceStart: site.replaceStart, limit: limit, in: unit,
        signature: { self.signatureKey($0, name: $1) }, render: { self.render($0, unitIndex: unitIndex) })
    }
    // The preprocessor's lines: macros after `#if`, `#ifdef`, `defined`; nothing in an `#include`.
    if before >= 0, let directive = directive(containing: before, in: unit) ?? (unit.tokens[before].kind == .directive ? before : nil) {
      let word = layout.csyntax.directiveName(unit, directive)
      if ["include", "import", "include_next", "pragma", "define", "undef", "error", "warning"].contains(word), before == directive || word != "define" {
        return nothing(prefix, site.replaceStart)
      }
      if word != "define" {
        return finish(macroHits(unitIndex: unitIndex, token: at, typed: typed), .directive, .exact)
      }
    }
    // `[receiver sel|`: the receiver's methods (its class methods after a class's name), properties' getters.
    if before > 0, unit.cFile.dialect.contains(.objc), unit.isWord(before) || unit.tokens[before].kind == .close,
      let open = unit.matchingOpenBefore(before + 1), unit.isByte(open, 0x5B), open < before,
      // Not a subscript (`a[i|`).
      open == 0 || (unit.tokens[open - 1].kind != .identifier && unit.tokens[open - 1].kind != .close) || unit.tokens[open - 1].kind == .keyword
    {
      var i = open + 1
      var receiverEnd = -1
      while i <= before {
        if unit.tokens[i].kind == .open {
          i = unit.skipBalanced(i)
          receiverEnd = i - 1
          continue
        }
        if unit.isWord(i), receiverEnd >= 0, unit.isWord(receiverEnd) || unit.tokens[receiverEnd].kind == .close { break }
        receiverEnd = i
        i += 1
      }
      if receiverEnd == before {
        let receiver = receiverType(unitIndex: unitIndex, message: (open, receiverEnd, 0))
        var hits: [ModelCompletionHit] = []
        var seen = Set<String>()
        func add(_ ref: DeclRef, score: Int32) {
          let item = decl(ref)
          let isMethod = item.kind == .function && item.isStatic == receiver.isClass
          let isGetter = item.kind == .variable && !receiver.isClass && file(ref).has(ref.decl, .property)
          guard isMethod || isGetter else { return }
          let text = memberName(ref)
          guard !text.isEmpty, seen.insert(text).inserted, let match = matchClass(typed, text.utf8[...]) else { return }
          hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: ref))
        }
        if case .nominal = receiver.type {
          var visited: Set<DeclRef> = []
          var tier: Int32 = 0
          var lastParent: DeclRef?
          collectMembers(of: receiver.type, from: unitIndex, into: &visited) { ref in
            let parent = DeclRef(unit: ref.unit, decl: decl(ref).parent)
            if lastParent != nil, parent != lastParent, !isSameClass(parent, lastParent!) { tier += 1 }
            lastParent = parent
            add(ref, score: min(tier, 5) * 20)
            return false
          }
          return finish(hits, .member, .exact)
        }
        // `id` or a receiver whose type isn't known: every method the project and what it reads declare.
        for (u, holder) in project.units.enumerated() where visible(DeclRef(unit: Int32(u), decl: 0), from: unitIndex) {
          for (method, _) in holder.cFile.selectors { add(DeclRef(unit: Int32(u), decl: method), score: u < project.projectUnits ? 0 : 50) }
        }
        return finish(hits, .member, .candidates)
      }
    }
    if before >= 0, unit.isByte(before, 0x2E) || unit.isToken(before, "->") {
      let operand = deref(exprType(unitIndex: unitIndex, end: before - 1))
      guard case .nominal = operand else { return finish([], .member, .unknown) }
      var hits: [ModelCompletionHit] = []
      var visited: Set<DeclRef> = []
      var tier: Int32 = 0
      var lastParent: DeclRef?
      collectMembers(of: operand, from: unitIndex, into: &visited) { ref in
        let item = decl(ref)
        guard item.kind != .initializer, item.kind != .deinitializer, item.kind != .extensionDecl, item.kind != .enumCase || unit.isToken(before, "::") else { return false }
        let parent = DeclRef(unit: ref.unit, decl: item.parent)
        if lastParent != nil, parent != lastParent, !isSameClass(parent, lastParent!) { tier += 1 }
        lastParent = parent
        let text = memberName(ref)
        if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: min(tier, 5) * 20, ref: ref, receiver: operand)) }
        return false
      }
      return finish(hits, .member, .exact)
    }
    if before >= 0, unit.isToken(before, "::") {
      var hits: [ModelCompletionHit] = []
      switch qualifierScope(unitIndex: unitIndex, colons: before) {
      case .type(let scope):
        var visited: Set<DeclRef> = []
        collectMembers(of: scope, from: unitIndex, into: &visited) { ref in
          let text = memberName(ref)
          if decl(ref).kind != .extensionDecl, let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 0, ref: ref)) }
          return false
        }
      case .namespace(let key):
        indexEntities()
        for ref in scoped[key] ?? [] where decl(ref).name != 0 {
          let text = memberName(ref)
          // The library's reserved names (`__x`, `_Tp`) aren't for writing.
          if text.hasPrefix("__") || text.hasPrefix("_") && text.dropFirst().first?.isUppercase == true { continue }
          if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: visible(ref, from: unitIndex) ? 0 : 50, ref: ref)) }
        }
      case .global:
        hits = fileScopeHits(unitIndex: unitIndex, typed: typed)
      case .none:
        return finish([], .member, .unknown)
      }
      return finish(hits, .member, .exact)
    }
    // A new name being declared: `struct na|`, `int na|`.
    if before >= 0, unit.isToken(before, "struct") || unit.isToken(before, "union") || unit.isToken(before, "enum") || unit.isToken(before, "class") {
      var hits: [ModelCompletionHit] = []
      for u in closure(unitIndex) {
        for (_, list) in project.units[Int(u)].cFile.tags {
          for index in list {
            let ref = DeclRef(unit: u, decl: index)
            let text = memberName(ref)
            if !text.isEmpty, let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: u == unitIndex ? 0 : 100, ref: ref)) }
          }
        }
      }
      return finish(hits, .type, .exact)
    }
    return finish(scopeHits(unitIndex: unitIndex, token: at, typed: typed), .scope, .exact)
  }

  private func isSameClass(_ a: DeclRef, _ b: DeclRef) -> Bool {
    guard a.decl >= 0, b.decl >= 0 else { return false }
    return decl(a).name == decl(b).name
  }

  /// The name a member is written with: a method's whole selector, else its name.
  func memberName(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    if let pieces = holder.cFile.selectors[ref.decl] {
      let words = pieces.map { holder.string(Int($0)) }
      return item.paramCount == 0 ? (words.first ?? "") : words.map { $0 + ":" }.joined()
    }
    guard item.nameToken >= 0, item.name != 0, holder.isWord(Int(item.nameToken)) else { return "" }
    return holder.string(Int(item.nameToken))
  }

  private func macroHits(unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    var hits: [ModelCompletionHit] = []
    var seen = Set<Name>()
    let order = closure(unitIndex)
    for u in order.reversed() {
      let holder = project.units[Int(u)]
      for (word, events) in holder.cFile.macroEvents where !seen.contains(word) {
        guard let last = (u == unitIndex ? events.last { Int($0.token) < token } : events.last), last.decl >= 0 else { continue }
        seen.insert(word)
        let ref = DeclRef(unit: u, decl: last.decl)
        let text = holder.string(Int(holder.decls[Int(last.decl)].nameToken))
        // A header's include guard isn't something to write.
        if text.hasSuffix("_H") || text.hasSuffix("_H_") || text.hasPrefix("_") { continue }
        if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: u == unitIndex ? 50 : (Int(u) < project.projectUnits ? 120 : 260), ref: ref)) }
      }
    }
    return hits
  }

  private func fileScopeHits(unitIndex: Int32, typed: [UInt8]) -> [ModelCompletionHit] {
    var hits: [ModelCompletionHit] = []
    let isCpp = project.units[Int(unitIndex)].cFile.dialect.contains(.cpp)
    for u in closure(unitIndex) {
      let holder = project.units[Int(u)]
      let score: Int32 = u == unitIndex ? 100 : (Int(u) < project.projectUnits ? 150 : 300)
      for (_, list) in holder.cFile.ordinary {
        for index in list {
          let ref = DeclRef(unit: u, decl: index)
          let text = memberName(ref)
          guard !text.isEmpty, !text.hasPrefix("__"), let match = matchClass(typed, text.utf8[...]) else { continue }
          hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: ref))
        }
      }
      if isCpp {
        for (_, list) in holder.cFile.tags {
          for index in list where holder.decls[Int(index)].name != 0 {
            let ref = DeclRef(unit: u, decl: index)
            let text = memberName(ref)
            guard !text.isEmpty, !text.hasPrefix("__"), let match = matchClass(typed, text.utf8[...]) else { continue }
            hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: ref))
          }
        }
      }
    }
    return hits
  }

  /// Names on their own: locals, parameters, the class's members, template parameters, the closure's declarations,
  /// macros, keywords.
  private func scopeHits(unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    var hits: [ModelCompletionHit] = []
    if let body = body(unitIndex: unitIndex, token: Int32(token)) {
      for local in body.visible(at: Int32(token)) {
        let text = unit.string(Int(local.token))
        guard let match = matchClass(typed, text.utf8[...]) else { continue }
        hits.append(ModelCompletionHit(name: text, match: match, score: 0, ref: nil, localToken: local.token, kind: .variable))
      }
    }
    for index in unit.chain(at: Int32(token)) {
      let item = unit.decls[Int(index)]
      for g in 0..<Int(item.genericCount) {
        let text = unit.string(Int(unit.generics[Int(item.genericStart) + g].token))
        if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 5, ref: nil, kind: .typeParameter)) }
      }
      if let type = enclosingType(unitIndex: unitIndex, holder: index) {
        var visited: Set<DeclRef> = []
        collectMembers(of: type, from: unitIndex, into: &visited) { ref in
          let text = memberName(ref)
          if !text.isEmpty, decl(ref).kind != .extensionDecl, let match = matchClass(typed, text.utf8[...]) {
            hits.append(ModelCompletionHit(name: text, match: match, score: 20, ref: ref))
          }
          return false
        }
      }
    }
    hits += fileScopeHits(unitIndex: unitIndex, typed: typed)
    if unit.cFile.dialect.contains(.cpp) { hits += namespaceHits(unitIndex: unitIndex, token: token, typed: typed) }
    hits += macroHits(unitIndex: unitIndex, token: token, typed: typed)
    var words = cKeywords
    let dialect = unit.cFile.dialect
    if dialect.contains(.cpp) { words += cppKeywords }
    if dialect.contains(.objc) { words += objcKeywords }
    for word in words {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 400, ref: nil, kind: .keyword)) }
    }
    return hits
  }

  /// C++: what the namespaces around a position declare (in any file it reads), and what its `using namespace`s bring.
  private func namespaceHits(unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    let file = unit.cFile
    let chain = unit.chain(at: Int32(token))
    var names: [Name] = []
    for index in chain {
      let item = unit.decls[Int(index)]
      if item.kind == .namespace, item.name != 0, !file.has(index, .inline) { names.append(item.name) }
      // `int A::f() {`: A's members, which a class's own scope key lists.
      if item.kind == .extensionDecl, item.typeStart >= 0 { names += qualifierWords(unit, Int(item.typeStart), Int(item.typeEnd)) }
    }
    var scopes: [(key: UInt64, score: Int32)] = []
    var key: UInt64 = 0
    for (n, word) in names.enumerated() {
      key = CModel.mix(key, word)
      scopes.append((key, Int32(60 - min(names.count - 1 - n, 5) * 5)))
    }
    for using in file.usings where using.isNamespace && using.token < Int32(token) && (using.scope < 0 || chain.contains(using.scope)) {
      var scope: UInt64 = 0
      for w in qualifierWords(unit, Int(using.start), Int(using.end)) { scope = CModel.mix(scope, w) }
      scopes.append((scope, 200))
    }
    guard !scopes.isEmpty else { return [] }
    indexEntities()
    var hits: [ModelCompletionHit] = []
    var seen = Set<UInt64>()
    for scope in scopes where seen.insert(scope.key).inserted {
      for ref in scoped[scope.key] ?? [] where decl(ref).name != 0 && decl(ref).kind != .extensionDecl && visible(ref, from: unitIndex) {
        let text = memberName(ref)
        guard !text.isEmpty, !text.hasPrefix("__"), let match = matchClass(typed, text.utf8[...]) else { continue }
        hits.append(ModelCompletionHit(name: text, match: match, score: scope.score, ref: ref))
      }
    }
    return hits
  }

  /// Overloads apart by their parameter count.
  func signatureKey(_ ref: DeclRef, name text: String) -> UInt64 {
    hashName(text) &* 31 &+ UInt64(decl(ref).kind.rawValue) &* 7 &+ UInt64(decl(ref).paramCount)
  }

  private func itemKind(of ref: DeclRef) -> ModelCompletionItemKind {
    let item = decl(ref)
    switch item.kind {
    case .structure: return .structure
    case .classType: return .classType
    case .enumeration: return .enumeration
    case .protocolType: return .interface
    case .typeAlias: return .structure
    case .enumCase: return .enumMember
    case .macro: return item.paramCount > 0 ? .function : .variable
    case .namespace: return .module
    case .initializer: return .constructor
    case .function: return item.parent >= 0 && unit(ref).decls[Int(item.parent)].kind != .namespace ? .method : .function
    case .variable: return item.parent >= 0 && unit(ref).decls[Int(item.parent)].kind.hasMembers && unit(ref).decls[Int(item.parent)].kind != .namespace ? (file(ref).has(ref.decl, .property) ? .property : .field) : .variable
    default: return .variable
    }
  }

  private func render(_ hit: ModelCompletionHit, unitIndex: Int32) -> ModelCompletionEntry {
    guard let ref = hit.ref else {
      var detail = hit.detail ?? ""
      if hit.localToken >= 0, let body = body(unitIndex: unitIndex, token: hit.localToken), let local = body.local(named: project.units[Int(unitIndex)].hash(Int(hit.localToken)), at: hit.localToken) {
        let holder = project.units[Int(unitIndex)]
        detail = holder.text(from: Int(local.typeStart), to: Int(local.typeEnd))
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
    if let pieces = owner.cFile.selectors[ref.decl], item.paramCount > 0 {
      // `initWithFrame:${1:frame} style:${2:style}`.
      var parts: [String] = []
      var holes: [String] = []
      for (p, piece) in pieces.enumerated() where p < Int(item.paramCount) {
        let param = owner.params[Int(item.paramStart) + p]
        let type = param.typeStart >= 0 ? owner.text(from: Int(param.typeStart), to: Int(param.typeEnd)) : "id"
        parts.append(owner.string(Int(piece)) + ":(" + type + ")")
        holes.append(owner.string(Int(piece)) + ":${\(p + 1):" + (param.nameToken >= 0 ? owner.string(Int(param.nameToken)) : type) + "}")
      }
      label = parts.joined(separator: " ")
      insert = holes.joined(separator: " ")
      isSnippet = true
      if item.typeStart >= 0 { detail = owner.text(from: Int(item.typeStart), to: Int(item.typeEnd)) }
    } else if item.kind == .function || item.kind == .initializer || (item.kind == .macro && file(ref).has(ref.decl, .functionMacro)) {
      var parameters: [String] = []
      var holes: [String] = []
      for p in 0..<Int(item.paramCount) {
        let param = owner.params[Int(item.paramStart) + p]
        let text = param.typeStart >= 0 ? owner.text(from: Int(param.typeStart), to: Int(param.typeEnd)) : (param.nameToken >= 0 ? owner.string(Int(param.nameToken)) : "...")
        parameters.append(text)
        let hole = param.nameToken >= 0 ? owner.string(Int(param.nameToken)) : text
        holes.append("${\(p + 1):\(hole.replacingOccurrences(of: "}", with: "\\}"))}")
      }
      label = hit.name + "(" + parameters.joined(separator: ", ") + ")"
      if hit.insert == nil {
        insert = hit.name + "(" + holes.joined(separator: ", ") + ")"
        isSnippet = !holes.isEmpty
      }
      if item.kind == .function, item.typeStart >= 0 { detail = returnText(ref) }
    } else if item.kind == .variable || item.kind == .typeAlias {
      if item.typeStart >= 0 { detail = owner.text(from: Int(item.typeStart), to: Int(item.typeEnd)) }
      if let declarator = owner.cFile.declarators[ref.decl], declarator.prefix < item.nameToken {
        detail += " " + owner.text(from: Int(declarator.prefix), to: Int(item.nameToken))
      }
    } else if item.kind == .macro, item.initStart >= 0 {
      detail = String(owner.text(from: Int(item.initStart), to: Int(item.initEnd)).prefix(40))
    }
    return ModelCompletionEntry(
      name: hit.name, label: label, detail: detail, module: (owner.path as NSString).lastPathComponent, kind: hit.kind ?? itemKind(of: ref),
      insertText: insert, isSnippet: isSnippet, isDeprecated: false, needsUnwrap: false)
  }

  /// A function's result as written, without storage words or attributes.
  func returnText(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let owner = unit(ref)
    var words: [String] = []
    var i = Int(item.typeStart)
    while i < Int(item.typeEnd) {
      if owner.isWord(i), CWord.storage.contains(owner.hash(i)) || CWord.attributes.contains(owner.hash(i)) || owner.isMacroLike(i) {
        i = owner.isByte(i + 1, 0x28) ? owner.skipBalanced(i + 1) : i + 1
        continue
      }
      if owner.tokens[i].kind == .directive {
        i = Int(owner.cFile.ends[Int32(i)] ?? Int32(i + 1))
        continue
      }
      words.append(owner.string(i))
      i += 1
    }
    if let declarator = owner.cFile.declarators[ref.decl], declarator.prefix < item.nameToken {
      for k in Int(declarator.prefix)..<Int(item.nameToken) where owner.tokens[k].kind == .punctuation { words.append(owner.string(k)) }
    }
    return words.joined(separator: " ").replacingOccurrences(of: " *", with: " *").replacingOccurrences(of: "* ", with: "*")
  }
}
