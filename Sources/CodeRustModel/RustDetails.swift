import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its declaration on one line, its doc comment (`///`, `/** */`), what it's in
/// (an impl's type, a trait, a struct, the modules out to the crate) and a value's type.
extension RustModel {
  public func details(of site: Site) -> SymbolDetails? {
    switch site {
    case .decl(let ref):
      let item = decl(ref)
      let holder = unit(ref)
      guard item.nameToken >= 0 else { return nil }
      let own = holder.string(Int(item.nameToken))
      guard let symbol = project.part(ref, name: item.kind == .function ? own + "()" : own, keyword: keyword(item)) else { return nil }
      var parents: [SymbolPart] = []
      var parent = item.parent
      while parent >= 0 {
        let owner = DeclRef(unit: ref.unit, decl: parent)
        let ownerDecl = decl(owner)
        if ownerDecl.nameToken >= 0, ownerDecl.kind != .function {
          let text = ownerDecl.kind == .extensionDecl ? implOwnerName(holder, ownerDecl) : holder.string(Int(ownerDecl.nameToken))
          if let part = project.part(owner, name: text, keyword: keyword(ownerDecl)) { parents.append(part) }
        }
        parent = ownerDecl.parent
      }
      parents += moduleParents(of: ref)
      var type: SymbolPart?
      var inferred: String?
      if item.kind == .variable {
        let ty = valueType(of: ref)
        if let target = typeDecl(of: ty), let part = project.part(target, name: unit(target).string(Int(decl(target).nameToken)), keyword: keyword(decl(target))) { type = part }
        if item.typeStart < 0, ty != .unknown { inferred = describe(ty) }
      }
      let documentation = holder.documentation(above: Int(item.first), linePrefix: "///", blockOpen: "/**") ?? attributeDocumentation(holder, item)
      return SymbolDetails(symbol: symbol, declaration: declaration(ref, inferred: inferred), documentation: documentation, parents: parents, type: type)
    case .local(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = location(of: site) else { return nil }
      let isParameter = holder.decls.contains { item in
        (0..<Int(item.paramCount)).contains { holder.params[Int(item.paramStart) + $0].nameToken == token }
      }
      let symbol = SymbolPart(
        kind: isParameter ? .parameter : .local, name: holder.string(Int(token)), keyword: isParameter ? "" : "let", path: at.path, line: at.line,
        character: at.character, module: project.moduleName(of: holder), isSDK: project.isSDK(holder))
      let ty = localType(unitIndex: unitIndex, token: token)
      var typePart: SymbolPart?
      if let target = typeDecl(of: ty) { typePart = project.part(target, name: unit(target).string(Int(decl(target).nameToken)), keyword: keyword(decl(target))) }
      let declaration = (isParameter ? "" : "let ") + symbol.name + (ty == .unknown ? "" : ": " + describe(ty))
      var parents: [SymbolPart] = []
      if let owner = owner(unitIndex: unitIndex, token: token) {
        let ref = DeclRef(unit: unitIndex, decl: owner)
        if let part = project.part(ref, name: holder.string(Int(decl(ref).nameToken)) + "()", keyword: "fn") { parents.append(part) }
      }
      return SymbolDetails(symbol: symbol, declaration: declaration, documentation: nil, parents: parents, type: typePart)
    case .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = location(of: site) else { return nil }
      let symbol = SymbolPart(
        kind: .generic, name: holder.string(Int(token)), keyword: "", path: at.path, line: at.line, character: at.character,
        module: project.moduleName(of: holder), isSDK: project.isSDK(holder))
      return SymbolDetails(symbol: symbol, declaration: symbol.name, documentation: nil, parents: [], type: nil)
    case .module(let moduleName):
      guard let module = project.modules[moduleName], let at = location(of: site) else { return nil }
      let part = SymbolPart(kind: .module, name: module.displayName, keyword: "", path: at.path, line: 0, character: 0, module: module.displayName, isSDK: module.isSDK)
      return SymbolDetails(symbol: part, declaration: "extern crate " + (layout.crates[module.displayName]?.pathName ?? module.displayName), documentation: nil, parents: [], type: nil)
    }
  }

  /// `#[doc = "…"]` when there's no `///`.
  private func attributeDocumentation(_ holder: Unit, _ item: Decl) -> String? {
    for (start, end) in attributes(holder, before: Int(item.first)) where holder.isToken(start, "doc") && holder.isByte(start + 1, 0x3D) && start + 2 < end {
      return RustParser.unquote(holder.string(start + 2)).trimmingCharacters(in: .whitespaces)
    }
    return nil
  }

  /// The modules a declaration is in, out to its crate.
  private func moduleParents(of ref: DeclRef) -> [SymbolPart] {
    var result: [SymbolPart] = []
    var node: Int32 = moduleNode(unitIndex: ref.unit, token: decl(ref).first)
    var guardCount = 0
    while node >= 0, guardCount < 32 {
      guardCount += 1
      let holder = nodes[Int(node)]
      if let modDecl = holder.modDecl {
        if let part = project.part(modDecl, name: unit(modDecl).string(Int(decl(modDecl).nameToken)), keyword: "mod") { result.append(part) }
      } else if holder.decl >= 0 {
        let inline = DeclRef(unit: holder.unit, decl: holder.decl)
        if let part = project.part(inline, name: unit(inline).string(Int(decl(inline).nameToken)), keyword: "mod") { result.append(part) }
      } else {
        let display = project.modules[holder.crate]?.displayName ?? ""
        let path = project.units[Int(holder.unit)].path
        result.append(SymbolPart(kind: .module, name: layout.crates[display]?.pathName ?? display, keyword: "", path: path, line: 0, character: 0, module: display, isSDK: project.modules[holder.crate]?.isSDK ?? false))
      }
      node = holder.parent
    }
    return result
  }

  func keyword(_ item: Decl) -> String {
    switch item.kind {
    case .structure: return "struct"
    case .enumeration: return "enum"
    case .protocolType: return "trait"
    case .extensionDecl: return "impl"
    case .function: return "fn"
    case .variable: return item.isStatic ? "const" : ""
    case .enumCase: return ""
    case .typeAlias, .associatedType: return "type"
    case .macro: return "macro_rules!"
    case .namespace: return "mod"
    default: return ""
    }
  }

  /// A declaration as one line, without attributes or body.
  func declaration(_ ref: DeclRef, inferred: String?) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    var end = Int(item.end)
    if item.bodyOpen >= 0 { end = Int(item.bodyOpen) }
    if item.kind == .variable, item.initStart >= 0 { end = Int(item.initStart) - 1 }
    if item.kind == .macro { end = Int(item.nameToken) + 1 }
    while end > Int(item.first), holder.isByte(end - 1, 0x3B) || holder.isByte(end - 1, 0x2C) { end -= 1 }
    var text = holder.text(from: Int(item.first), to: max(end, Int(item.nameToken) + 1))
    if item.kind == .macro { text = "macro_rules! " + holder.string(Int(item.nameToken)) }
    if let inferred { text += ": " + inferred }
    return String(text.prefix(300))
  }
}
