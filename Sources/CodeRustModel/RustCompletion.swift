import CodeModel
import CodeScan
import Foundation

private let rustKeywords = [
  "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let",
  "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe",
  "use", "where", "while",
]

/// Completion: what could be typed at a position, from the same tables as definitions. It reads the text being
/// edited, so nothing here looks past the cursor.
extension RustModel {
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
        signature: { ref, word in hashName(word) &+ UInt64(self.decl(ref).kind.rawValue) }, render: { self.render($0, unitIndex: unitIndex) })
    }
    // A new name isn't asked about.
    // `if let` and `while let` start a pattern, most often a variant (`if let Some(x)`).
    let pattern = before >= 1 && unit.isToken(before, "let") && (unit.isToken(before - 1, "if") || unit.isToken(before - 1, "while"))
    if before >= 0, !pattern, ["fn", "struct", "enum", "trait", "type", "mod", "let", "const", "static", "union", "macro_rules"].contains(unit.string(before)) {
      return nothing(prefix, site.replaceStart)
    }
    if before >= 0, unit.isToken(before, "mut"), before >= 1, unit.isToken(before - 1, "let") { return nothing(prefix, site.replaceStart) }
    if before >= 0, unit.isByte(before, 0x2E) || site.splitDot {
      let receiver = operandType(unitIndex, dot: before)
      guard receiver != .unknown else { return finish([], .member, .unknown) }
      var hits: [ModelCompletionHit] = []
      collectMembers(of: receiver, typed: typed, into: &hits)
      return finish(hits, .member, .exact)
    }
    if before >= 1, unit.isToken(before, "::") {
      var hits: [ModelCompletionHit] = []
      let state = collectPath(unitIndex: unitIndex, colons: before, typed: typed, into: &hits)
      return finish(hits, .member, state)
    }
    // In a `use` group (`use std::sync::{Arc, |}`): the members of the path before the brace.
    if let colons = useGroupColons(unit, before: before) {
      var hits: [ModelCompletionHit] = []
      let state = collectPath(unitIndex: unitIndex, colons: colons, typed: typed, into: &hits)
      return finish(hits, .member, state)
    }
    var hits: [ModelCompletionHit] = []
    collectScope(unitIndex: unitIndex, token: Int32(max(0, min(at, unit.tokens.count - 1))), offset: offset, typed: typed, into: &hits)
    for keyword in rustKeywords {
      if let match = matchClass(typed, keyword.utf8[...]) { hits.append(ModelCompletionHit(name: keyword, match: match, score: 600, ref: nil, kind: .keyword)) }
    }
    return finish(hits, .scope, .exact)
  }

  /// The `::` before the `{` of the `use` group a position is in, when the token before it is `{` or `,` there.
  func useGroupColons(_ unit: Unit, before: Int) -> Int? {
    guard before >= 1, unit.isByte(before, 0x7B) || unit.isByte(before, 0x2C) else { return nil }
    var index = before
    var depth = 0
    while index >= 0 {
      if unit.isByte(index, 0x7D) { depth += 1 }
      else if unit.isByte(index, 0x7B) {
        if depth == 0 { break }
        depth -= 1
      } else if unit.isByte(index, 0x3B) || unit.isByte(index, 0x28) || unit.isByte(index, 0x5B) || unit.isToken(index, "fn") || unit.isToken(index, "let") {
        return nil
      }
      index -= 1
    }
    guard index >= 2, unit.isToken(index - 1, "::") else { return nil }
    // The statement is a `use`: back over the path to `use` (or `pub use`, `pub(crate) use`).
    var start = index - 2
    while start >= 0, unit.tokens[start].kind == .identifier || unit.tokens[start].kind == .keyword || unit.isToken(start, "::") || unit.isByte(start, 0x7B) || unit.isByte(start, 0x2C) || unit.isByte(start, 0x7D) {
      if unit.isToken(start, "use") { return index - 1 }
      start -= 1
    }
    return nil
  }

  /// Fields and methods through autoderef: each step's, nearer first.
  func collectMembers(of receiver: Ty, typed: [UInt8], into hits: inout [ModelCompletionHit]) {
    var step = receiver
    var level: Int32 = 0
    var seenNames: Set<String> = []
    while level < 8, step != .unknown {
      var refs: [DeclRef] = []
      if case .nominal(let ref, _) = step, decl(ref).kind == .structure {
        let holder = unit(ref)
        for child in holder.children(of: ref.decl) where holder.decls[Int(child)].kind == .variable { refs.append(DeclRef(unit: ref.unit, decl: child)) }
      }
      var traits: [DeclRef] = []
      for (impl, _) in impls(for: step) {
        let holder = unit(impl)
        for child in holder.children(of: impl.decl) where holder.decls[Int(child)].kind == .function || holder.decls[Int(child)].kind == .variable {
          refs.append(DeclRef(unit: impl.unit, decl: child))
        }
        if case .nominal(let trait, _)? = implTrait(impl) { traits.append(trait) }
      }
      switch step {
      case .nominal(let ref, _): traits += derivedTraits(ref)
      case .param(let word, let owner?): for bound in boundsWithSupertraits(word, owner) { if case .nominal(let trait, _) = bound { traits.append(trait) } }
      case .existential(let list): for bound in list { if case .nominal(let trait, _) = bound { traits.append(trait); traits += supertraits(trait) } }
      default: break
      }
      for trait in traits {
        let holder = unit(trait)
        for child in holder.children(of: trait.decl) where holder.decls[Int(child)].kind == .function { refs.append(DeclRef(unit: trait.unit, decl: child)) }
      }
      for ref in refs {
        let item = decl(ref)
        guard item.nameToken >= 0 else { continue }
        // Associated functions without `self` aren't called on a value.
        if item.kind == .function, item.isStatic { continue }
        let text = unit(ref).string(Int(item.nameToken))
        guard !seenNames.contains(text), let match = matchClass(typed, text.utf8[...]) else { continue }
        seenNames.insert(text)
        hits.append(ModelCompletionHit(name: text, match: match, score: level * 20, ref: ref, receiver: step))
      }
      guard let next = derefStep(step) else { break }
      step = next
      level += 1
    }
  }

  /// After `a::b::`: a module's items, an enum's variants, a type's or trait's associated items.
  private func collectPath(unitIndex: Int32, colons: Int, typed: [UInt8], into hits: inout [ModelCompletionHit]) -> AnswerState {
    let unit = project.units[Int(unitIndex)]
    guard colons >= 1 else { return .unknown }
    let last = colons - 1
    var bases: [Entity]
    if unit.tokens[last].kind == .identifier || unit.tokens[last].kind == .keyword {
      let (segments, qualified) = pathSegments(unit, to: last)
      bases = useEntities(unitIndex: unitIndex, token: last) ?? resolvePath(unitIndex, segments, qualified: qualified, namespace: .type)
    } else {
      return .unknown
    }
    guard !bases.isEmpty else { return .unknown }
    for base in bases {
      switch base {
      case .node(let node):
        let holder = nodes[Int(node)]
        collectScopeItems(holder.unit, holder.decl, typed: typed, score: 0, into: &hits)
        // A crate's `#[macro_export]` macros are at its root, wherever they're written (`anyhow::bail!`).
        if holder.parent < 0, holder.decl < 0 {
          for (_, list) in exportedMacros(of: holder.crate) {
            for ref in list { add(ref, typed: typed, score: 5, into: &hits) }
          }
        }
      case .decl(let ref):
        var target = ref
        if decl(ref).kind == .typeAlias, let aliased = typeDecl(of: aliasType(ref, [])) { target = aliased }
        let item = decl(target)
        let holder = self.unit(target)
        if item.kind == .enumeration || item.kind == .protocolType {
          for child in holder.children(of: target.decl) { add(DeclRef(unit: target.unit, decl: child), typed: typed, score: 0, into: &hits) }
        }
        if item.kind != .protocolType {
          // A trait impl's block often names none of the trait's methods (the stub's never do), and derives have none.
          var traits: [DeclRef] = derivedTraits(target)
          for (impl, _) in impls(for: ownTypeUnknownArgs(target), blankets: false) {
            let implHolder = self.unit(impl)
            for child in implHolder.children(of: impl.decl) { add(DeclRef(unit: impl.unit, decl: child), typed: typed, score: 10, into: &hits) }
            if case .nominal(let trait, _)? = implTrait(impl) { traits.append(trait) }
          }
          var seen: Set<DeclRef> = []
          for trait in traits where seen.insert(trait).inserted {
            let traitHolder = self.unit(trait)
            for child in traitHolder.children(of: trait.decl) where traitHolder.decls[Int(child)].kind == .function {
              add(DeclRef(unit: trait.unit, decl: child), typed: typed, score: 30, into: &hits)
            }
          }
        }
      default:
        break
      }
    }
    return .exact
  }

  private func add(_ ref: DeclRef, typed: [UInt8], score: Int32, into hits: inout [ModelCompletionHit]) {
    let item = decl(ref)
    guard item.nameToken >= 0, item.kind != .extensionDecl else { return }
    let text = unit(ref).string(Int(item.nameToken))
    guard let match = matchClass(typed, text.utf8[...]) else { return }
    hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: ref))
  }

  /// A scope's items and the names its `use`s bring.
  private func collectScopeItems(_ unitIndex: Int32, _ scope: Int32, typed: [UInt8], score: Int32, into hits: inout [ModelCompletionHit]) {
    let facts = facts(unitIndex)
    for (_, list) in facts.items[scope] ?? [:] {
      for index in list { add(DeclRef(unit: unitIndex, decl: index), typed: typed, score: score, into: &hits) }
    }
    let unit = project.units[Int(unitIndex)]
    for index in facts.importsByScope[scope] ?? [] {
      let item = unit.imports[index]
      if item.member == RustWord.glob {
        for base in importBase(unitIndex, index) {
          if case .node(let node) = base {
            let holder = nodes[Int(node)]
            if holder.unit == unitIndex && holder.decl == scope { continue }
            for (_, list) in self.facts(holder.unit).items[holder.decl] ?? [:] {
              for item in list where decl(DeclRef(unit: holder.unit, decl: item)).access != .isPrivate { add(DeclRef(unit: holder.unit, decl: item), typed: typed, score: score + 20, into: &hits) }
            }
          } else if case .decl(let ref) = base, decl(ref).kind == .enumeration {
            let holder = self.unit(ref)
            for child in holder.children(of: ref.decl) { add(DeclRef(unit: ref.unit, decl: child), typed: typed, score: score + 20, into: &hits) }
          }
        }
        continue
      }
      let word = importName(item)
      guard word != 0 else { continue }
      let token = item.aliasToken >= 0 ? Int(item.aliasToken) : Int(item.memberToken)
      guard token >= 0, token < unit.tokens.count else { continue }
      var text = unit.string(token)
      // `use option::Option::{self, Some}` names `Option`.
      if text == "self", item.aliasToken < 0, let last = item.moduleName.split(separator: ":").last { text = String(last) }
      guard let match = matchClass(typed, text.utf8[...]) else { continue }
      var ref: DeclRef?
      for namespace in [Namespace.type, .value, .macro] {
        if case .decl(let found)? = resolveImport(unitIndex, index, namespace).first {
          ref = found
          break
        }
      }
      hits.append(ModelCompletionHit(name: text, match: match, score: score + 5, ref: ref, kind: ref == nil ? .module : nil))
    }
  }

  /// A name on its own: locals, type parameters, the scopes around, the crates, the prelude, the primitive types.
  private func collectScope(unitIndex: Int32, token: Int32, offset: Int, typed: [UInt8], into hits: inout [ModelCompletionHit]) {
    let unit = project.units[Int(unitIndex)]
    // Before a body's closing `}`, the body is the one the token before is in (bindings already reach the brace).
    let inside = token > 0 && unit.isByte(Int(token), 0x7D) && Int(unit.tokens[Int(token)].start) >= offset ? token - 1 : token
    if let body = body(unitIndex: unitIndex, token: inside) ?? body(unitIndex: unitIndex, token: token) {
      var seen: Set<Name> = []
      for binding in body.bindings.sorted(by: { $0.visibleFrom > $1.visibleFrom }) where binding.visibleFrom <= token && token <= binding.visibleTo {
        let word = unit.hash(Int(binding.token))
        guard seen.insert(word).inserted, unit.tokens[Int(binding.token)].end <= offset || binding.visibleFrom < token else { continue }
        let text = unit.string(Int(binding.token))
        guard let match = matchClass(typed, text.utf8[...]) else { continue }
        hits.append(ModelCompletionHit(name: text, match: match, score: -40, ref: nil, localToken: binding.token, kind: .variable))
      }
    }
    for index in unit.chain(at: token) {
      let item = unit.decls[Int(index)]
      for g in 0..<Int(item.genericCount) {
        let generic = unit.generics[Int(item.genericStart) + g]
        let text = unit.string(Int(generic.token))
        if let match = matchClass(typed, text.utf8[...]) { hits.append(ModelCompletionHit(name: text, match: match, score: 0, ref: nil, kind: .typeParameter)) }
      }
    }
    var score: Int32 = 20
    for (u, s) in scopes(unitIndex: unitIndex, token: token) {
      collectScopeItems(u, s, typed: typed, score: score, into: &hits)
      score += 40
    }
    if let crate = crateInfo(of: unitIndex) {
      for (key, _) in layout.externCrates(of: crate) where key != "core" && key != "alloc" {
        if let match = matchClass(typed, key.utf8[...]) { hits.append(ModelCompletionHit(name: key, match: match, score: 200, ref: nil, kind: .module)) }
      }
    }
    if let prelude = preludeNode { collectScopeItems(nodes[Int(prelude)].unit, nodes[Int(prelude)].decl, typed: typed, score: 150, into: &hits) }
    if let primitives = primitiveNode { collectScopeItems(nodes[Int(primitives)].unit, nodes[Int(primitives)].decl, typed: typed, score: 300, into: &hits) }
    // Macros: this crate's and the standard ones.
    for (_, list) in crateMacros(unit.moduleName) { if let ref = list.first { add(ref, typed: typed, score: 100, into: &hits) } }
    if let root = stdRoot {
      let holder = nodes[Int(root)]
      for (_, list) in facts(holder.unit).items[holder.decl] ?? [:] {
        for index in list where project.units[Int(holder.unit)].decls[Int(index)].kind == .macro { add(DeclRef(unit: holder.unit, decl: index), typed: typed, score: 250, into: &hits) }
      }
    }
  }

  func render(_ hit: ModelCompletionHit, unitIndex: Int32) -> ModelCompletionEntry {
    guard let ref = hit.ref else {
      var detail = ""
      if hit.localToken >= 0 {
        let ty = localType(unitIndex: unitIndex, token: hit.localToken)
        if ty != .unknown { detail = describe(ty) }
      }
      return ModelCompletionEntry(
        name: hit.name, label: hit.name, detail: detail, module: "", kind: hit.kind ?? .variable, insertText: hit.insert ?? hit.name, isSnippet: false,
        isDeprecated: false, needsUnwrap: false)
    }
    let item = decl(ref)
    let holder = unit(ref)
    var label = hit.name
    var insert = hit.name
    var detail = ""
    var isSnippet = false
    var kind: ModelCompletionItemKind
    switch item.kind {
    case .function:
      var params: [String] = []
      for p in 0..<Int(item.paramCount) {
        let param = holder.params[Int(item.paramStart) + p]
        if param.label == RustWord.selfValue { continue }
        let name = param.nameToken >= 0 ? holder.string(Int(param.nameToken)) : "_"
        params.append(name + ": " + holder.text(from: Int(param.typeStart), to: Int(param.typeEnd)))
      }
      label = hit.name + "(" + params.joined(separator: ", ") + ")"
      if item.typeStart >= 0 { detail = holder.text(from: Int(item.typeStart), to: Int(item.typeEnd)) }
      var placeholders: [String] = []
      for (index, param) in params.enumerated() { placeholders.append("${\(index + 1):\(param.split(separator: ":").first ?? "")}") }
      insert = hit.name + "(" + placeholders.joined(separator: ", ") + ")"
      isSnippet = !params.isEmpty
      if params.isEmpty { insert = hit.name + "()" }
      let isMethod = item.paramCount > 0 && holder.params[Int(item.paramStart)].label == RustWord.selfValue
      kind = isMethod ? .method : .function
    case .macro:
      label = hit.name + "!"
      insert = hit.name + "!"
      kind = .function
    case .variable:
      if item.typeStart >= 0 { detail = holder.text(from: Int(item.typeStart), to: Int(item.typeEnd)) }
      kind = item.parent >= 0 && holder.decls[Int(item.parent)].kind == .structure ? .field : .variable
    case .structure: kind = .structure
    case .enumeration: kind = .enumeration
    case .protocolType: kind = .interface
    case .enumCase: kind = .enumMember
    case .namespace: kind = .module
    case .typeAlias, .associatedType: kind = .classType
    default: kind = .variable
    }
    return ModelCompletionEntry(
      name: hit.name, label: label, detail: detail, module: project.moduleName(of: holder), kind: hit.kind ?? kind, insertText: insert, isSnippet: isSnippet,
      isDeprecated: false, needsUnwrap: false)
  }

  /// A type as Rust writes it, for details and completion.
  func describe(_ ty: Ty) -> String {
    switch ty {
    case .unknown: return "_"
    case .nominal(let ref, let args):
      let item = decl(ref)
      let own = item.nameToken >= 0 ? unit(ref).string(Int(item.nameToken)) : "?"
      let shown = args.filter { if case .constructed(let kind, _) = $0, kind == RustModel.binding { return false } else { return true } }
      return shown.isEmpty ? own : own + "<" + shown.map(describe).joined(separator: ", ") + ">"
    case .constructed(let kind, let args):
      let inner = args.first.map(describe) ?? "_"
      if kind == RustTy.reference { return "&" + inner }
      if kind == RustTy.raw { return "*const " + inner }
      if kind == Ty.slice { return "[" + inner + "]" }
      if kind == Ty.array { return "[" + inner + "; _]" }
      return inner
    case .tuple(let items, _): return "(" + items.map(describe).joined(separator: ", ") + (items.count == 1 ? ",)" : ")")
    case .function(let args, let result): return "fn(" + args.map(describe).joined(separator: ", ") + ") -> " + describe(result)
    case .existential(let traits): return "impl " + traits.map(describe).joined(separator: " + ")
    case .param(let word, let owner):
      if let owner, let token = genericToken(word, owner) { return unit(owner).string(Int(token)) }
      return word == RustWord.selfType ? "Self" : "_"
    case .dependent(let base, _): return describe(base) + "::_"
    default: return "_"
    }
  }
}
