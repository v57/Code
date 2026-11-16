import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its declaration on one line, its JSDoc's first paragraph, what it's in (a
/// member's class or interface, namespaces, out to its file) and a value's type.
extension TSModel {
  public func details(of site: Site) -> SymbolDetails? {
    switch site {
    case .decl(let ref):
      let item = decl(ref)
      guard let symbol = part(ref) else { return nil }
      let holder = self.unit(ref)
      var parents: [SymbolPart] = []
      var parent = item.parent
      while parent >= 0 {
        if let shown = part(DeclRef(unit: ref.unit, decl: parent)) { parents.append(shown) }
        parent = holder.decls[Int(parent)].parent
      }
      parents.append(filePart(holder))
      var type: SymbolPart?
      var inferred: String?
      if item.kind == .variable {
        let ty = declValue(ref, env: [:]).ty
        type = typePart(ty)
        if item.typeStart < 0, !isUnknown(ty) { inferred = describe(ty) }
      }
      let documentation = holder.documentation(above: Int(item.first), linePrefix: "///", blockOpen: "/**")
      return SymbolDetails(symbol: symbol, declaration: declaration(ref, inferred: inferred), documentation: documentation, parents: parents, type: type)
    case .local(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = location(of: site) else { return nil }
      var ty = Ty.unknown
      var isParameter = false
      let scan = body(unitIndex)
      if let index = scan.byToken[token] {
        ty = localValue(unitIndex, index).ty
        let local = scan.locals[Int(index)]
        if case .parameter = local.kind { isParameter = true }
        if scan.functions.values.contains(where: { $0.paramsOpen < token && token <= $0.paramsClose }) { isParameter = true }
      }
      let name = holder.string(Int(token))
      let symbol = SymbolPart(
        kind: isParameter ? .parameter : .local, name: name, keyword: isParameter ? "" : localKeyword(holder, token), path: at.path, line: at.line,
        character: at.character, module: moduleLabel(holder), isSDK: project.isSDK(holder))
      var text = (symbol.keyword.isEmpty ? "" : symbol.keyword + " ") + name
      if !isUnknown(ty) { text += ": " + describe(ty) }
      return SymbolDetails(symbol: symbol, declaration: text, documentation: nil, parents: enclosing(unitIndex, token), type: typePart(ty))
    case .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = location(of: site) else { return nil }
      let symbol = SymbolPart(
        kind: .generic, name: holder.string(Int(token)), keyword: "", path: at.path, line: at.line, character: at.character, module: moduleLabel(holder),
        isSDK: project.isSDK(holder))
      return SymbolDetails(symbol: symbol, declaration: symbol.name, documentation: nil, parents: enclosing(unitIndex, token), type: nil)
    case .module(let moduleName):
      guard let module = project.modules[moduleName], let first = module.units.first else { return nil }
      let holder = project.units[Int(first)]
      let shown = filePart(holder)
      return SymbolDetails(symbol: shown, declaration: "module \"" + shown.name + "\"", documentation: nil, parents: [], type: nil)
    }
  }

  private func part(_ ref: DeclRef) -> SymbolPart? {
    let item = decl(ref)
    guard item.nameToken >= 0 else { return nil }
    let holder = self.unit(ref)
    var name: String
    if item.name == 0 {
      guard item.kind == .structure else { return nil }
      name = "{…}"
    } else if holder.tokens[Int(item.nameToken)].kind == .string {
      name = holder.string(Int(item.nameToken))
    } else {
      name = holder.string(Int(item.nameToken))
    }
    if item.kind == .function || item.kind == .initializer { name += "()" }
    return project.part(ref, name: name, keyword: keyword(ref))
  }

  private func filePart(_ holder: Unit) -> SymbolPart {
    SymbolPart(kind: .module, name: moduleLabel(holder), keyword: "module", path: holder.path, line: 0, character: 0, module: moduleLabel(holder), isSDK: project.isSDK(holder))
  }

  private func enclosing(_ unitIndex: Int32, _ token: Int32) -> [SymbolPart] {
    let holder = project.units[Int(unitIndex)]
    var parents: [SymbolPart] = []
    for index in holder.chain(at: token).reversed() {
      if let shown = part(DeclRef(unit: unitIndex, decl: index)) { parents.append(shown) }
    }
    parents.append(filePart(holder))
    return parents
  }

  private func typePart(_ ty: Ty) -> SymbolPart? {
    switch ty {
    case .nominal(let ref, _), .meta(.nominal(let ref, _)):
      guard decl(ref).name != 0 else { return nil }
      return part(ref)
    default:
      return nil
    }
  }

  /// `const`, `let` or `var` before a local's declarator.
  private func localKeyword(_ holder: Unit, _ token: Int32) -> String {
    var k = Int(token) - 1
    var budget = 64
    while k >= 0, budget > 0 {
      if holder.isToken(k, "const") { return "const" }
      if holder.isToken(k, "let") { return "let" }
      if holder.isToken(k, "var") { return "var" }
      if holder.isByte(k, 0x3B) || holder.isByte(k, 0x7B) && holder.startsLine(k + 1) { break }
      k -= 1
      budget -= 1
    }
    return ""
  }

  private func keyword(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = self.unit(ref)
    switch item.kind {
    case .function: return item.parent >= 0 && holder.decls[Int(item.parent)].kind != .namespace ? "" : "function"
    case .initializer: return "constructor"
    case .classType: return "class"
    case .protocolType: return "interface"
    case .typeAlias: return "type"
    case .enumeration: return "enum"
    case .namespace: return holder.tokens[Int(item.nameToken)].kind == .string ? "module" : "namespace"
    case .variable:
      if item.parent >= 0, holder.decls[Int(item.parent)].kind != .namespace { return "" }
      return localKeyword(holder, item.nameToken)
    default: return ""
    }
  }

  /// One line: `function f(a: string): number`, `class A extends B`, `const x: T`, `name?: string`.
  private func declaration(_ ref: DeclRef, inferred: String?) -> String {
    let item = decl(ref)
    let holder = self.unit(ref)
    switch item.kind {
    case .function, .initializer, .classType, .protocolType, .enumeration, .namespace, .subscriptDecl:
      let end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
      var start = Int(item.first)
      while start < Int(item.nameToken), holder.isByte(start, 0x40) {
        start += 2
        if holder.isByte(start, 0x28) { start = holder.skipBalanced(start) }
      }
      var text = holder.text(from: start, to: end)
      if text.hasSuffix(";") { text.removeLast() }
      return String(text.prefix(400))
    case .typeAlias:
      return String(holder.text(from: Int(item.first), to: Int(item.end)).prefix(400))
    case .variable:
      let name = holder.string(Int(item.nameToken))
      let keyword = keyword(ref)
      var text = (keyword.isEmpty ? "" : keyword + " ") + name
      if item.typeStart >= 0 {
        text += ": " + holder.text(from: Int(item.typeStart), to: Int(item.typeEnd))
      } else if let inferred {
        text += ": " + inferred
      }
      return String(text.prefix(400))
    case .enumCase:
      return holder.text(from: Int(item.first), to: Int(item.end))
    default:
      return holder.string(Int(item.nameToken))
    }
  }
}
