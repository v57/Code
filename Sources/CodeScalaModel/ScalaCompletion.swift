import CodeJavaModel
import CodeModel
import CodeScan
import Foundation

private let statementKeywords = [
  "abstract", "case", "catch", "class", "def", "do", "else", "enum", "export", "extends", "extension", "false", "final", "finally", "for", "given",
  "if", "implicit", "import", "lazy", "match", "new", "null", "object", "override", "package", "private", "protected", "return", "sealed", "super",
  "then", "this", "throw", "trait", "true", "try", "type", "using", "val", "var", "while", "with", "yield",
]

/// Completion: what could be typed at a position, from the same tables as definitions. After a `.`, the receiver's
/// members and the extension methods visible there; on its own, every name the scope reaches, each checked to resolve
/// to itself there (so a shadowed name isn't offered twice); after `import a.`, what `a` holds.
extension ScalaModel {
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
    if unit.isInCommentOrString(offset) {
      // `s"… $na|"`: what's in scope.
      if let string = stringToken(unit, offset), let low = interpolationStart(unit, token: string, offset: offset) {
        let prefix = String(decoding: UnsafeBufferPointer(start: unit.source.text + low, count: offset - low), as: UTF8.self)
        let hits = scopeHits(unitIndex: unitIndex, token: string, typed: Array(prefix.utf8), want: .any)
        return project.rankCompletions(
          hits, context: .scope, state: .exact, prefix: prefix, replaceStart: low, limit: limit, in: unit,
          signature: { self.signatureKey($0, name: $1) }, render: { self.render($0, unitIndex: unitIndex) })
      }
      return nothing("", offset)
    }
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
    if before >= 0, unit.isToken(before, "package") { return nothing(prefix, site.replaceStart) }
    // A new name: `def na|`, `val na|`, `class Na|`; `given na|: T` but not `given Show[Int]`.
    if before >= 0, !site.splitDot {
      for word: StaticString in ["def", "val", "var", "class", "trait", "object", "type", "enum"] where unit.isToken(before, word) {
        return nothing(prefix, site.replaceStart)
      }
      let next = prefix.isEmpty ? at : at + 1
      if unit.isToken(before, "given"), next >= unit.tokens.count || unit.isToken(next, ":") { return nothing(prefix, site.replaceStart) }
    }
    // `import a.{b, |`: the path's members.
    if before >= 0, unit.isByte(before, 0x7B) || unit.isByte(before, 0x2C), let open = unit.isByte(before, 0x7B) ? before : unit.matchingOpenBefore(before),
      unit.isByte(open, 0x7B), open >= 2, unit.isByte(open - 1, 0x2E), let entity = importPathEntity(unitIndex, dot: open - 1)
    {
      var hits: [ModelCompletionHit] = []
      collectEntity(entity, typed: typed, into: &hits)
      return finish(hits, .member, .exact)
    }
    // `import |`: top-level packages.
    if before >= 0, unit.isToken(before, "import") {
      var hits: [ModelCompletionHit] = []
      for sub in subpackages(of: "") {
        if let match = matchClass(typed, sub.utf8[...]) { hits.append(ModelCompletionHit(name: sub, match: match, score: 0, ref: nil, kind: .module, detail: sub)) }
      }
      return finish(hits, .moduleName, .exact)
    }
    if before >= 1, unit.isByte(before, 0x2E) || site.splitDot {
      let dot = site.splitDot ? at - 1 : before
      // An import's path: `import a.b.|`, `import a.b.{c, |`.
      if let entity = importPathEntity(unitIndex, dot: dot) {
        var hits: [ModelCompletionHit] = []
        collectEntity(entity, typed: typed, into: &hits)
        return finish(hits, .member, .exact)
      }
      var receiver = Ty.unknown
      if unit.isToken(dot - 1, "super") {
        if let level = templatesAround(unitIndex, dot).first {
          var hits: [ModelCompletionHit] = []
          for parent in supertypes(of: DeclRef(unit: unitIndex, decl: level)) { collectMembers(of: parent, typed: typed, into: &hits) }
          return finish(hits, .member, .exact)
        }
      } else {
        receiver = expressionType(unitIndex, endingAt: dot - 1)
      }
      var hits: [ModelCompletionHit] = []
      switch receiver {
      case .unknown:
        return finish([], .member, .unknown)
      case .module(let package):
        collectEntity(.package(packageNames[package] ?? ""), typed: typed, into: &hits)
      case .meta(let inner):
        guard case .nominal(let ref, _) = inner else { return finish([], .member, .unknown) }
        collectStatics(ref, typed: typed, into: &hits)
      case .nominal(let ref, _) where isObject(ref):
        collectEntity(.decl(ref), typed: typed, into: &hits)
        // An enum's companion: its cases too.
        if let cls = companion(of: ref), decl(cls).kind == .enumeration {
          for child in self.unit(cls).children(of: cls.decl) where self.unit(cls).decls[Int(child)].kind == .enumCase {
            addHit(DeclRef(unit: cls.unit, decl: child), typed: typed, score: 0, into: &hits)
          }
        }
        collectExtensions(on: receiver, unitIndex: unitIndex, at: dot, typed: typed, into: &hits)
      default:
        guard case .nominal = memberBase(receiver) else { return finish([], .member, .unknown) }
        collectMembers(of: receiver, typed: typed, into: &hits, unitIndex: unitIndex, at: dot)
        collectExtensions(on: receiver, unitIndex: unitIndex, at: dot, typed: typed, into: &hits)
      }
      return finish(hits, .member, .exact)
    }
    let typeOnly = before >= 0 && positionKind(unitIndex, at) == .type && !unit.isToken(before, "=") && !unit.isToken(before, "(")
    // Before a close (`}` on the block's last line, `f(|)`) or a later line's first word, the scope is the one the caret
    // ends: `def now() = |` sees its parameters.
    var scopeToken = at
    if prefix.isEmpty, at > 0, at < unit.tokens.count,
      unit.tokens[at].kind == .close || unit.source.lines.line(of: unit.tokens[at].start) > unit.source.lines.line(of: offset)
    {
      scopeToken = at - 1
    }
    var hits = scopeHits(unitIndex: unitIndex, token: scopeToken, typed: typed, want: typeOnly ? .type : .any)
    if typeOnly { return finish(hits, .type, .exact) }
    hits += argumentNameHits(unitIndex: unitIndex, before: before, typed: typed)
    for word in statementKeywords {
      if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 250, ref: nil, kind: .keyword)) }
    }
    return finish(hits, .scope, .exact)
  }

  /// The string token an offset is in or right after (an unterminated one ends at the caret).
  func stringToken(_ unit: Unit, _ offset: Int) -> Int? {
    for at in [offset, offset - 1] where at >= 0 {
      if let token = unit.token(at: at), unit.tokens[token].kind == .string { return token }
    }
    return nil
  }

  /// The package or object an import's path names up to a `.`: `import a.b.` names `a.b`.
  func importPathEntity(_ unitIndex: Int32, dot: Int) -> ImportBase? {
    let unit = project.units[Int(unitIndex)]
    var words: [Int] = []
    var k = dot - 1
    while k >= 0, unit.tokens[k].kind == .identifier || unit.tokens[k].kind == .keyword {
      words.insert(k, at: 0)
      guard k >= 2, unit.isByte(k - 1, 0x2E) else { break }
      k -= 2
    }
    guard let first = words.first, first > 0, unit.isToken(first - 1, "import") else { return nil }
    var entity: ImportBase?
    for (n, token) in words.enumerated() {
      let text = nameText(unit, token)
      if n == 0 {
        let found = resolveName(unitIndex, token, word(unitIndex, token), want: .any)
        for site in found {
          switch site {
          case .module(let package): entity = .package(packageNames[package] ?? text)
          case .decl(let ref): if entity == nil { entity = staticBase(ref).map { .decl($0) } }
          default: break
          }
        }
        if entity == nil, isPackage(text) { entity = .package(text) }
      } else if let current = entity {
        names[word(unitIndex, token)] = text
        entity = select(current, word(unitIndex, token), text: text)
      }
      if entity == nil { return nil }
    }
    return entity
  }

  /// The next names under a package: `scala.` gives `collection`, `concurrent`, …
  func subpackages(of package: String) -> [String] {
    var result: Set<String> = []
    let lead = package.isEmpty ? "" : package + "."
    var sources: [Set<String>] = []
    for module in project.modules.values where !module.isSDK {
      var display = module.displayName
      if display.hasSuffix(JavaLayout.librarySuffix) { display.removeLast(JavaLayout.librarySuffix.count) }
      sources.append([display])
    }
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

  func addHit(_ ref: DeclRef, typed: [UInt8], score: Int32, receiver: Ty? = nil, into hits: inout [ModelCompletionHit]) {
    let item = decl(ref)
    guard item.name != 0, item.nameToken >= 0, item.kind != .extensionDecl, item.kind != .initializer else { return }
    let text = nameText(self.unit(ref), Int(item.nameToken))
    if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: ref, receiver: receiver)) }
  }

  /// A package's declarations and subpackages, or an object's members.
  func collectEntity(_ entity: ImportBase, typed: [UInt8], into hits: inout [ModelCompletionHit]) {
    switch entity {
    case .package(let package):
      for module in packageModules(package) {
        for (_, list) in module.top {
          for ref in list where decl(ref).access != .isPrivate && !flags(ref).contains(.packageObject) { addHit(ref, typed: typed, score: 0, into: &hits) }
        }
        // A top-level extension's methods are the package's too (`import a.{discounted}`).
        for unitIndex in module.units {
          let holder = project.units[Int(unitIndex)]
          for top in holder.children(of: -1) where holder.decls[Int(top)].kind == .extensionDecl {
            for child in holder.children(of: top) { addHit(DeclRef(unit: unitIndex, decl: child), typed: typed, score: 10, into: &hits) }
          }
        }
      }
      for object in packageObjectRefs(package) {
        for child in self.unit(object).children(of: object.decl) { addHit(DeclRef(unit: object.unit, decl: child), typed: typed, score: 10, into: &hits) }
      }
      for sub in subpackages(of: package) {
        if let match = matchClass(typed, sub.utf8[...]) {
          hits.append(ModelCompletionHit(name: sub, match: match, score: 50, ref: nil, kind: .module, detail: package.isEmpty ? sub : package + "." + sub))
        }
      }
    case .decl(let ref):
      if isJava(ref) {
        collectStatics(ref, typed: typed, into: &hits)
        return
      }
      if decl(ref).kind == .enumeration { collectStatics(ref, typed: typed, into: &hits) }
      collectMembers(of: .nominal(ref, []), typed: typed, into: &hits)
    case .value(let ty):
      collectMembers(of: ty, typed: typed, into: &hits)
    }
  }

  /// `T.`: an enum's cases, a Java class's statics, a class's companion's members.
  func collectStatics(_ ref: DeclRef, typed: [UInt8], into hits: inout [ModelCompletionHit]) {
    let holder = self.unit(ref)
    if isJava(ref) {
      for child in holder.children(of: ref.decl) {
        let item = holder.decls[Int(child)]
        if item.isStatic || item.kind == .enumCase || item.kind.isNominal { addHit(DeclRef(unit: ref.unit, decl: child), typed: typed, score: 0, into: &hits) }
      }
      return
    }
    for child in holder.children(of: ref.decl) where holder.decls[Int(child)].kind == .enumCase {
      addHit(DeclRef(unit: ref.unit, decl: child), typed: typed, score: 0, into: &hits)
    }
    if let object = companion(of: ref) { collectMembers(of: .nominal(object, []), typed: typed, into: &hits) }
  }

  /// A type's members, its parents' too (overridden ones once), nearest first.
  func collectMembers(of ty: Ty, typed: [UInt8], into hits: inout [ModelCompletionHit], unitIndex: Int32 = -1, at: Int = 0) {
    var seenNames: Set<Name> = []
    for (depth, (ref, _)) in hierarchy(of: ty).enumerated() {
      let holder = self.unit(ref)
      var own: Set<Name> = []
      for child in holder.children(of: ref.decl) {
        let item = holder.decls[Int(child)]
        guard item.name != 0, !seenNames.contains(item.name), item.kind != .extensionDecl, !item.isLocal else { continue }
        let member = DeclRef(unit: ref.unit, decl: child)
        let f = flags(member)
        if f.contains(.classParam), !f.contains(.paramVal), !f.contains(.paramVar), !(unitIndex == ref.unit && templatesAround(unitIndex, at).contains(ref.decl)) { continue }
        if item.access == .isPrivate, unitIndex != ref.unit { continue }
        if isJava(member), item.isStatic || item.kind == .initializer { continue }
        own.insert(item.name)
        let isRoot = item.parent >= 0 && [name("Any"), name("AnyRef"), name("Object")].contains(holder.decls[Int(item.parent)].name)
        addHit(member, typed: typed, score: isRoot ? 120 : Int32(min(depth, 5) * 10), receiver: ty, into: &hits)
      }
      seenNames.formUnion(own)
    }
  }

  /// The extension methods a receiver has here.
  func collectExtensions(on receiver: Ty, unitIndex: Int32, at: Int, typed: [UInt8], into hits: inout [ModelCompletionHit]) {
    var keys: [Name] = [Self.anyReceiver]
    var targets: [DeclRef] = []
    for (ref, _) in hierarchy(of: receiver) {
      keys.append(decl(ref).name)
      targets.append(ref)
    }
    var seen: Set<DeclRef> = []
    for key in keys {
      for group in extensionGroups(named: key) where seen.insert(group).inserted {
        guard groupVisible(group, unitIndex: unitIndex, at: at, targets: targets) else { continue }
        switch extendedType(group) {
        case .param: break
        case .nominal(let target, _): guard targets.contains(target) else { continue }
        default: continue
        }
        let holder = self.unit(group)
        for child in holder.children(of: group.decl) where !holder.decls[Int(child)].isLocal {
          let item = holder.decls[Int(child)]
          guard item.kind == .function || item.kind == .variable, !flags(DeclRef(unit: group.unit, decl: child)).contains(.classParam) else { continue }
          addHit(DeclRef(unit: group.unit, decl: child), typed: typed, score: key == Self.anyReceiver ? 140 : 60, receiver: receiver, into: &hits)
        }
      }
    }
  }

  /// Every name the scope reaches that resolves to itself here.
  func scopeHits(unitIndex: Int32, token: Int, typed: [UInt8], want: Want) -> [ModelCompletionHit] {
    guard let facts = file(unitIndex) else { return [] }
    let unit = project.units[Int(unitIndex)]
    let at = Int32(token)
    var candidates: [Name: (text: String, score: Int32)] = [:]
    func offer(_ word: Name, _ text: String, _ score: Int32) {
      guard word != 0, !text.isEmpty, matchClass(typed, text.utf8[...]) != nil else { return }
      if let known = candidates[word], known.score <= score { return }
      candidates[word] = (text, score)
    }
    // Locals, parameters, type parameters.
    for (word, list) in facts.localsByName {
      for index in list {
        let local = facts.info[Int(index)]
        guard local.scopeStart <= at, at < local.scopeEnd, !(local.holeStart >= 0 && local.holeStart <= at && at < local.holeEnd) else { continue }
        offer(word, nameText(unit, Int(unit.decls[Int(index)].nameToken)), 0)
      }
    }
    for index in unit.decls.indices where unit.decls[index].first <= at && at < unit.decls[index].end {
      let item = unit.decls[index]
      for p in 0..<Int(item.paramCount) {
        let param = unit.params[Int(item.paramStart) + p]
        if param.nameToken >= 0 { offer(param.local, nameText(unit, Int(param.nameToken)), 0) }
      }
      for g in 0..<Int(item.genericCount) {
        let generic = unit.generics[Int(item.genericStart) + g]
        offer(generic.name, nameText(unit, Int(generic.token)), 5)
      }
    }
    // Enclosing templates' members, their parents' too.
    for (depth, level) in templatesAround(unitIndex, token).enumerated() {
      let ref = DeclRef(unit: unitIndex, decl: level)
      for (n, (holderRef, _)) in hierarchy(of: .nominal(ref, [])).enumerated() {
        let holder = self.unit(holderRef)
        for child in holder.children(of: holderRef.decl) where !holder.decls[Int(child)].isLocal && holder.decls[Int(child)].nameToken >= 0 {
          offer(holder.decls[Int(child)].name, nameText(holder, Int(holder.decls[Int(child)].nameToken)), Int32(20 + depth * 10 + min(n, 4) * 5))
        }
      }
      if let object = companion(of: ref) {
        let holder = self.unit(object)
        for child in holder.children(of: object.decl) where holder.decls[Int(child)].nameToken >= 0 {
          offer(holder.decls[Int(child)].name, nameText(holder, Int(holder.decls[Int(child)].nameToken)), Int32(25 + depth * 10))
        }
      }
    }
    // The file's own, its imports, its packages', the defaults.
    func offerAll(_ refs: [DeclRef], _ score: Int32) {
      for ref in refs where decl(ref).nameToken >= 0 && decl(ref).name != 0 { offer(decl(ref).name, nameText(self.unit(ref), Int(decl(ref).nameToken)), score) }
    }
    func entityRefs(_ entity: ImportBase) -> [DeclRef] {
      switch entity {
      case .package(let package):
        var result: [DeclRef] = []
        for module in packageModules(package) { for (_, list) in module.top { result += list.filter { decl($0).access != .isPrivate } } }
        for object in packageObjectRefs(package) { result += self.unit(object).children(of: object.decl).map { DeclRef(unit: object.unit, decl: $0) } }
        return result
      case .decl(let ref):
        var result: [DeclRef] = []
        for (holderRef, _) in hierarchy(of: .nominal(ref, [])) { result += self.unit(holderRef).children(of: holderRef.decl).map { DeclRef(unit: holderRef.unit, decl: $0) } }
        return result
      case .value:
        return []
      }
    }
    for child in unit.children(of: -1) {
      let item = unit.decls[Int(child)]
      if item.kind == .extensionDecl {
        offerAll(unit.children(of: child).map { DeclRef(unit: unitIndex, decl: $0) }, 40)
      } else {
        offerAll([DeclRef(unit: unitIndex, decl: child)], 40)
      }
    }
    for (position, entry) in facts.imports.enumerated() where entry.scopeStart < at && at < entry.scopeEnd {
      guard let base = importBase(unitIndex, position) else { continue }
      if entry.wildcard { offerAll(entityRefs(base), 100) }
      for selector in entry.selectors where selector.rename != 1 {
        let shown = selector.rename != 0 ? selector.rename : selector.name
        let tokenIndex = Int(selector.rename != 0 ? selector.renameToken : selector.token)
        if tokenIndex >= 0 { offer(shown, nameText(unit, tokenIndex), 30) }
      }
    }
    for package in facts.packages.reversed() { offerAll(entityRefs(.package(package)), 60) }
    if facts.packages.isEmpty { offerAll(entityRefs(.package("")), 60) }
    if let predef = packageDecls("scala", name("Predef")).first {
      offerAll(self.unit(predef).children(of: predef.decl).map { DeclRef(unit: predef.unit, decl: $0) }.filter { !flags($0).contains(.isImplicit) }, 150)
    }
    offerAll(entityRefs(.package("scala")).filter { decl($0).access == .isPublic }, 150)
    offerAll(entityRefs(.package("java.lang")).filter { decl($0).access == .isPublic }, 170)
    // Each candidate as the scope resolves it.
    var hits: [ModelCompletionHit] = []
    for (word, candidate) in candidates {
      names[word] = candidate.text
      guard let match = matchClass(typed, candidate.text.utf8[...]) else { continue }
      var sites = resolveName(unitIndex, token, word, want: want)
      if sites.isEmpty, want == .any { sites = resolveName(unitIndex, token, word, want: .type) }
      for site in sites.prefix(8) {
        switch site {
        case .decl(let ref):
          guard decl(ref).kind != .extensionDecl else { continue }
          hits.append(ModelCompletionHit(name: candidate.text, match: match, score: candidate.score, ref: ref))
        case .local(let u, let t):
          hits.append(ModelCompletionHit(name: candidate.text, match: match, score: candidate.score, ref: nil, localToken: t, kind: .variable))
          _ = u
        case .generic:
          hits.append(ModelCompletionHit(name: candidate.text, match: match, score: candidate.score, ref: nil, kind: .typeParameter))
        case .module(let package):
          hits.append(ModelCompletionHit(name: candidate.text, match: match, score: candidate.score + 50, ref: nil, kind: .module, detail: packageNames[package]))
        }
      }
    }
    return hits
  }

  /// After `f(` or a `,` in its arguments: the parameters of what `f` may be, inserted as `name = `.
  func argumentNameHits(unitIndex: Int32, before: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    let unit = project.units[Int(unitIndex)]
    guard before > 0, unit.isByte(before, 0x28) || unit.isByte(before, 0x2C),
      let open = unit.isByte(before, 0x28) ? before : unit.matchingOpenBefore(before), unit.isByte(open, 0x28), open > 0,
      unit.tokens[open - 1].kind == .identifier
    else { return [] }
    var hits: [ModelCompletionHit] = []
    var seen: Set<String> = []
    let groups = 0
    var callees = Array(callTargets(unitIndex, nameToken: open - 1).prefix(16))
    // A case class's `copy(…)`: its parameters.
    if callees.isEmpty, unit.isToken(open - 1, "copy"), open >= 3, unit.isByte(open - 2, 0x2E),
      case .nominal(let cls, _) = memberBase(expressionType(unitIndex, endingAt: open - 3)), flags(cls).contains(.isCase)
    {
      callees = [cls]
    }
    for callee in callees where !isJava(callee) {
      var list: [DeclRef] = []
      let item = decl(callee)
      if item.kind.isNominal || item.kind == .enumCase {
        list = classParams(callee)
      } else if item.kind == .function, let size = info(callee).lists.first {
        let holder = self.unit(callee)
        for p in 0..<Int(size) {
          let param = holder.params[Int(item.paramStart) + p]
          guard param.nameToken >= 0 else { continue }
          let text = nameText(holder, Int(param.nameToken))
          guard seen.insert(text).inserted, let match = matchClass(typed, text.utf8[...]) else { continue }
          hits.append(ModelCompletionHit(name: text, match: match, score: 10, ref: nil, kind: .variable, insert: text + " = ", detail: text + " ="))
        }
      }
      for param in list {
        let text = nameText(self.unit(param), Int(decl(param).nameToken))
        guard seen.insert(text).inserted, let match = matchClass(typed, text.utf8[...]) else { continue }
        hits.append(ModelCompletionHit(name: text, match: match, score: 10, ref: nil, kind: .variable, insert: text + " = ", detail: text + " ="))
      }
    }
    _ = groups
    return hits
  }

  /// Overloads stay apart: a function's key is its name and parameter types.
  func signatureKey(_ ref: DeclRef, name text: String) -> UInt64 {
    let item = decl(ref)
    if item.kind == .function {
      var key = hashName(text) &* 31 &+ UInt64(item.paramCount)
      let holder = self.unit(ref)
      for p in 0..<Int(item.paramCount) {
        let param = holder.params[Int(item.paramStart) + p]
        key = key &* 1_099_511_628_211 &+ hashName(holder.text(from: Int(param.typeStart), to: Int(param.typeEnd)))
      }
      return key
    }
    return hashName(text) &* 31 &+ UInt64(item.kind.rawValue)
  }

  func itemKind(of ref: DeclRef) -> ModelCompletionItemKind {
    let item = decl(ref)
    switch item.kind {
    case .classType: return isObject(ref) ? .module : .classType
    case .structure: return .structure
    case .protocolType: return .interface
    case .enumeration: return .enumeration
    case .enumCase: return .enumMember
    case .function:
      return item.parent >= 0 && self.unit(ref).decls[Int(item.parent)].kind != .extensionDecl ? .method : .function
    case .initializer: return .constructor
    case .variable: return item.parent >= 0 && !item.isLocal ? .property : .variable
    case .typeAlias: return .classType
    default: return .variable
    }
  }

  func render(_ hit: ModelCompletionHit, unitIndex: Int32) -> ModelCompletionEntry {
    guard let ref = hit.ref else {
      var detail = hit.detail ?? ""
      if hit.localToken >= 0 { detail = describe(siteType(.local(unit: unitIndex, token: hit.localToken))) }
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
    if item.kind == .function, hit.insert == nil, !isJava(ref) {
      // Scala's lists as written; a parameterless method has none.
      var parameters: [String] = []
      var holes: [String] = []
      var index = Int(item.paramStart)
      var groups: [String] = []
      for (n, size) in info(ref).lists.enumerated() {
        parameters = []
        let isUsing = info(ref).usingLists & (1 << UInt32(min(n, 31))) != 0
        for _ in 0..<Int(size) {
          let param = owner.params[index]
          index += 1
          let type = oneLine(owner.text(from: Int(param.typeStart), to: Int(param.typeEnd)))
          let name = param.nameToken >= 0 ? nameText(owner, Int(param.nameToken)) : ""
          parameters.append(name + ": " + type)
          if !param.hasDefault, !isUsing { holes.append("${\(holes.count + 1):\(name.replacingOccurrences(of: "}", with: "\\}"))}") }
        }
        if isUsing { continue }
        groups.append("(" + parameters.joined(separator: ", ") + ")")
      }
      label = hit.name + groups.joined()
      if !groups.isEmpty {
        insert = hit.name + "(" + holes.joined(separator: ", ") + ")"
        isSnippet = !holes.isEmpty
      }
      if item.typeStart >= 0 { detail = oneLine(owner.text(from: Int(item.typeStart), to: Int(item.typeEnd))) }
    } else if item.kind == .function, hit.insert == nil {
      var parameters: [String] = []
      var holes: [String] = []
      for p in 0..<Int(item.paramCount) {
        let param = owner.params[Int(item.paramStart) + p]
        let type = oneLine(owner.text(from: Int(param.typeStart), to: Int(param.typeEnd)))
        let name = param.nameToken >= 0 ? owner.string(Int(param.nameToken)) : ""
        parameters.append(type + " " + name)
        holes.append("${\(holes.count + 1):\(name)}")
      }
      label = hit.name + "(" + parameters.joined(separator: ", ") + ")"
      insert = hit.name + "(" + holes.joined(separator: ", ") + ")"
      isSnippet = !holes.isEmpty
      detail = describe(valueType(of: ref))
    } else if item.kind == .variable {
      detail = describe(valueType(of: ref))
    }
    return ModelCompletionEntry(
      name: hit.name, label: label, detail: detail, module: packageOf(ref.unit), kind: hit.kind ?? itemKind(of: ref), insertText: insert,
      isSnippet: isSnippet, isDeprecated: isDeprecated(ref), needsUnwrap: false)
  }

  /// `@deprecated` among its annotations.
  func isDeprecated(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    let holder = self.unit(ref)
    var k = Int(item.first)
    let end = Int(item.nameToken >= 0 ? item.nameToken : item.first)
    while k < end, k < holder.tokens.count {
      if holder.isByte(k, 0x40), holder.isToken(k + 1, "deprecated") || holder.isToken(k + 1, "Deprecated") { return true }
      k += 1
    }
    return false
  }
}
