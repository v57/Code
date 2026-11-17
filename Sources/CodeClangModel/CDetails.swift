import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its declaration on one line, its doc comment (`///`, `/** */`, else the
/// comment right above), what it's in (classes, namespaces, Objective-C containers, out to its file) and a value's type.
extension CModel {
  public func details(of site: Site) -> SymbolDetails? {
    switch site {
    case .decl(let ref):
      guard ref.decl >= 0 else { return nil }
      let item = decl(ref)
      let holder = unit(ref)
      let isCallable = item.kind == .function || item.kind == .initializer || item.kind == .deinitializer || (item.kind == .macro && file(ref).has(ref.decl, .functionMacro))
      let shown = memberName(ref)
      guard let symbol = project.part(ref, name: isCallable && holder.cFile.selectors[ref.decl] == nil ? shown + "()" : shown, keyword: keyword(ref)) else { return nil }
      var parents: [SymbolPart] = []
      var parent = item.parent
      while parent >= 0 {
        let owner = DeclRef(unit: ref.unit, decl: parent)
        if decl(owner).name != 0, let part = project.part(owner, name: memberName(owner).isEmpty ? holder.string(Int(decl(owner).nameToken)) : memberName(owner), keyword: keyword(owner)) {
          parents.append(part)
        }
        parent = holder.decls[Int(parent)].parent
      }
      parents.append(filePart(holder))
      var type: SymbolPart?
      if item.kind == .variable || item.kind == .typeAlias || item.kind == .function {
        var ty = typeOf(ref)
        while case .constructed(_, let inner) = ty, let first = inner.first { ty = first }
        if case .nominal(let target, _) = ty, target.decl >= 0, decl(target).name != 0 { type = project.part(target, name: memberName(target), keyword: keyword(target)) }
      }
      return SymbolDetails(symbol: symbol, declaration: declaration(ref), documentation: documentation(ref), parents: parents, type: type)
    case .local(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = location(of: site) else { return nil }
      let isParameter = owner(unitIndex: unitIndex, token: token).map { index in
        let item = holder.decls[Int(index)]
        return (0..<Int(item.paramCount)).contains { holder.params[Int(item.paramStart) + $0].nameToken == token }
      } ?? false
      let symbol = SymbolPart(
        kind: isParameter ? .parameter : .local, name: holder.string(Int(token)), keyword: "", path: at.path, line: at.line, character: at.character,
        module: (holder.path as NSString).lastPathComponent, isSDK: project.isSDK(holder))
      var declaration = symbol.name
      if let body = body(unitIndex: unitIndex, token: token), let local = body.local(named: holder.hash(Int(token)), at: token) {
        let specifiers = holder.text(from: Int(local.typeStart), to: Int(local.typeEnd))
        if local.declaratorStart == local.token, local.typeEnd > local.token {
          declaration = specifiers
        } else {
          declaration = (specifiers + " " + holder.text(from: Int(local.declaratorStart), to: Int(local.declaratorEnd))).trimmingCharacters(in: .whitespaces)
        }
      }
      return SymbolDetails(symbol: symbol, declaration: declaration, documentation: nil, parents: enclosing(unitIndex, token), type: nil)
    case .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = location(of: site) else { return nil }
      let symbol = SymbolPart(
        kind: .generic, name: holder.string(Int(token)), keyword: "typename", path: at.path, line: at.line, character: at.character,
        module: (holder.path as NSString).lastPathComponent, isSDK: project.isSDK(holder))
      return SymbolDetails(symbol: symbol, declaration: "typename " + symbol.name, documentation: nil, parents: enclosing(unitIndex, token), type: nil)
    case .module:
      return nil
    }
  }

  private func enclosing(_ unitIndex: Int32, _ token: Int32) -> [SymbolPart] {
    let holder = project.units[Int(unitIndex)]
    var parts: [SymbolPart] = []
    for index in holder.chain(at: token).reversed() {
      let ref = DeclRef(unit: unitIndex, decl: index)
      if decl(ref).name != 0, let part = project.part(ref, name: memberName(ref), keyword: keyword(ref)) { parts.append(part) }
    }
    parts.append(filePart(holder))
    return parts
  }

  /// The file a declaration is in, as its module: a header's name.
  private func filePart(_ holder: Unit) -> SymbolPart {
    let name = (holder.path as NSString).lastPathComponent
    return SymbolPart(kind: .module, name: name, keyword: "", path: holder.path, line: 0, character: 0, module: name, isSDK: project.isSDK(holder))
  }

  func keyword(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    let flags = holder.cFile
    switch item.kind {
    case .structure: return flags.has(ref.decl, .union) ? "union" : "struct"
    case .classType: return isObjC(holder, ref.decl) ? "@interface" : "class"
    case .enumeration: return "enum"
    case .protocolType: return "@protocol"
    case .extensionDecl: return flags.has(ref.decl, .implementation) ? "@implementation" : "@interface"
    case .typeAlias: return holder.isToken(Int(item.first), "using") ? "using" : "typedef"
    case .namespace: return "namespace"
    case .macro: return "#define"
    case .function: return item.parent >= 0 && isObjCContainer(holder, item.parent) ? (item.isStatic ? "+" : "-") : ""
    case .variable: return flags.has(ref.decl, .property) ? "@property" : ""
    default: return ""
    }
  }

  /// The declaration on one line, without its body or initializer.
  func declaration(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    let first = Int(item.first)
    switch item.kind {
    case .macro:
      return String(holder.text(from: first, to: Int(item.end)).prefix(200))
    case .function, .initializer, .deinitializer:
      var end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
      while end > first, holder.isByte(end - 1, 0x3B) { end -= 1 }
      return String(holder.text(from: first, to: end).prefix(300))
    case .variable, .typeAlias:
      if let declarator = holder.cFile.declarators[ref.decl] {
        var specifiers = item.typeStart >= 0 ? holder.text(from: Int(item.typeStart), to: Int(item.typeEnd)) : ""
        if flags(ref).contains(.property), first < Int(item.typeStart) { specifiers = holder.text(from: first, to: Int(item.typeStart)) + " " + specifiers }
        let inner = holder.text(from: Int(declarator.prefix), to: Int(declarator.suffixEnd))
        if holder.isToken(first, "typedef"), !specifiers.hasPrefix("typedef") { specifiers = "typedef " + specifiers }
        return String((specifiers + " " + inner).trimmingCharacters(in: .whitespaces).prefix(300))
      }
      var end = item.initStart >= 0 ? Int(item.initStart) - 1 : Int(item.end)
      while end > first, holder.isByte(end - 1, 0x3B) || holder.isByte(end - 1, 0x2C) { end -= 1 }
      return String(holder.text(from: first, to: end).prefix(300))
    case .enumCase:
      return holder.text(from: Int(item.nameToken), to: item.initEnd > item.initStart && item.initStart >= 0 ? Int(item.initEnd) : Int(item.nameToken) + 1)
    default:
      // A type: its head, up to the body.
      var end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
      while end > first, holder.isByte(end - 1, 0x3B) { end -= 1 }
      return String(holder.text(from: first, to: end).prefix(300))
    }
  }

  private func flags(_ ref: DeclRef) -> CFlags { unit(ref).cFile.flags[ref.decl] ?? [] }

  /// The doc comment above a declaration, or a trailing `///<` on its line.
  func documentation(_ ref: DeclRef) -> String? {
    let item = decl(ref)
    let holder = unit(ref)
    var token = Int(item.first)
    // `typedef struct {…} name;`'s comment is above the typedef.
    if token < 0 || token >= holder.tokens.count { return nil }
    if item.kind == .enumCase || (item.parent >= 0 && holder.startsLine(Int(item.nameToken)) == false && holder.decls[Int(item.parent)].kind.hasMembers) { token = Int(item.first) }
    if let found = holder.documentation(above: token, linePrefix: "///", blockOpen: "/**") { return found }
    if let found = holder.documentation(above: token, linePrefix: "//", blockOpen: "/*") { return found }
    return nil
  }
}
