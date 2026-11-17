import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its declaration on one line, its docblock's summary, the class and namespace
/// it's in, and a value's type. Places as `phpref.py` names them.
extension PHPModel {
  public func details(of site: Site) -> SymbolDetails? {
    switch site {
    case .decl(let ref):
      let item = decl(ref)
      guard let symbol = part(ref) else { return nil }
      let holder = unit(ref)
      var parents: [SymbolPart] = []
      if item.parent >= 0, decl(DeclRef(unit: ref.unit, decl: item.parent)).kind != .namespace, let shown = part(DeclRef(unit: ref.unit, decl: item.parent)) {
        parents.append(shown)
      }
      parents.append(filePart(holder, namespace: namespaceText(holder, ref.decl)))
      var type: SymbolPart?
      if item.kind == .variable || item.kind == .function { type = typePart(valueType(of: ref)) }
      let documentation = holder.documentation(above: Int(item.first), linePrefix: "///", blockOpen: "/**")
      return SymbolDetails(symbol: symbol, declaration: declaration(ref), documentation: documentation, parents: parents, type: type)
    case .local(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = project.location(of: site) else { return nil }
      if token < 0 {
        // An included file.
        let name = (holder.path as NSString).lastPathComponent
        let symbol = SymbolPart(kind: .module, name: name, keyword: "file", path: at.path, line: 0, character: 0, module: moduleText(holder), isSDK: project.isSDK(holder))
        return SymbolDetails(symbol: symbol, declaration: name, documentation: nil, parents: [], type: nil)
      }
      let isParameter = isParameter(unitIndex: unitIndex, token: token)
      let ty = variableType(unitIndex: unitIndex, token: Int(token))
      let name = "$" + holder.string(Int(token))
      let symbol = SymbolPart(
        kind: isParameter ? .parameter : .local, name: name, keyword: "", path: at.path, line: at.line, character: at.character, module: moduleText(holder),
        isSDK: project.isSDK(holder))
      let text = describe(ty)
      var parents: [SymbolPart] = []
      for index in holder.chain(at: token).reversed() {
        if holder.decls[Int(index)].kind == .namespace { continue }
        if let shown = part(DeclRef(unit: unitIndex, decl: index)) { parents.append(shown) }
      }
      parents.append(filePart(holder, namespace: context(unitIndex, Int(token)).namespace))
      return SymbolDetails(symbol: symbol, declaration: text.isEmpty ? name : text + " " + name, documentation: nil, parents: parents, type: typePart(ty))
    case .generic, .module:
      return nil
    }
  }

  /// A file's place: its path in the project (or the vendor package's), `php` for the stub.
  func moduleText(_ holder: Unit) -> String {
    if project.isSDK(holder) { return PHPLayout.stdModule }
    if holder.path.hasPrefix(project.root + "/") { return String(holder.path.dropFirst(project.root.count + 1)) }
    return (holder.path as NSString).lastPathComponent
  }

  private func filePart(_ holder: Unit, namespace: String) -> SymbolPart {
    let name = namespace.isEmpty ? moduleText(holder) : namespace
    return SymbolPart(kind: .module, name: name, keyword: namespace.isEmpty ? "file" : "namespace", path: nil, line: 0, character: 0, module: moduleText(holder), isSDK: project.isSDK(holder))
  }

  private func part(_ ref: DeclRef) -> SymbolPart? {
    let item = decl(ref)
    guard item.nameToken >= 0 else { return nil }
    let holder = unit(ref)
    var name = holder.tokens[Int(item.nameToken)].kind == .string ? (holder.phStringValue(Int(item.nameToken)) ?? "") : holder.string(Int(item.nameToken))
    if item.kind == .variable, holder.phIsVariable(Int(item.nameToken)) { name = "$" + name }
    if item.kind == .function { name += "()" }
    return project.part(ref, name: name, keyword: keyword(ref))
  }

  private func keyword(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    switch item.kind {
    case .classType: return holder.isToken(Int(item.nameToken) - 1, "trait") ? "trait" : "class"
    case .protocolType: return "interface"
    case .enumeration: return "enum"
    case .enumCase: return "case"
    case .function: return "function"
    case .variable:
      if holder.phIsVariable(Int(item.nameToken)) { return item.isStatic ? "static" : "" }
      return holder.tokens[Int(item.nameToken)].kind == .string ? "define" : "const"
    default: return ""
    }
  }

  /// One line, without attributes or body: `public function find(int $id): ?User`.
  private func declaration(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    var start = Int(item.first)
    while start < Int(item.nameToken), holder.tokens[start].kind == .attribute { start += 1 }
    var end: Int
    switch item.kind {
    case .classType, .protocolType, .enumeration:
      end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
    case .function:
      end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
    case .variable, .enumCase:
      if holder.tokens[Int(item.nameToken)].kind == .string { return "define(" + holder.string(Int(item.nameToken)) + ", …)" }
      end = item.initEnd >= 0 ? Int(item.initEnd) : Int(item.nameToken) + 1
      if item.first == item.nameToken, holder.phIsVariable(Int(item.nameToken)) {
        // A promoted property: its parameter.
        start = Int(item.typeStart >= 0 ? item.typeStart : item.nameToken) - 0
        while start > 0, holder.phIsModifier(start - 1) { start -= 1 }
        end = Int(item.nameToken) + 1
      }
    default:
      end = Int(item.end)
    }
    if holder.isByte(end - 1, 0x3B) { end -= 1 }
    guard start < end else { return holder.string(Int(item.nameToken)) }
    return String(oneLine(holder.text(from: start, to: end)).prefix(400))
  }

  /// A type as PHP writes it: `?User`, `int|string`, `User[]`.
  func describe(_ ty: Ty) -> String {
    switch ty {
    case .nominal(let ref, let args):
      let item = decl(ref)
      guard item.nameToken >= 0 else { return "" }
      var text = unit(ref).string(Int(item.nameToken))
      if !args.isEmpty { text += "<" + args.map { describe($0).isEmpty ? "mixed" : describe($0) }.joined(separator: ", ") + ">" }
      return text
    case .constructed(let kind, let parts):
      if kind == Ty.slice {
        guard let element = parts.first, element != .unknown else { return "array" }
        let text = describe(element)
        return text.isEmpty ? "array" : text.contains("|") ? "(" + text + ")[]" : text + "[]"
      }
      if kind == Ty.union || kind == Ty.intersection {
        let texts = parts.map(describe)
        return texts.contains("") ? "" : texts.joined(separator: kind == Ty.union ? "|" : "&")
      }
      for word in Self.scalars where name(word) == kind { return word }
      return kind == Self.nullType.nominalName ? "null" : ""
    case .optional(let inner):
      let text = describe(inner)
      return text.isEmpty ? "" : text.contains("|") ? text + "|null" : "?" + text
    case .meta(let inner): return describe(inner)
    case .selfType: return "static"
    default: return ""
    }
  }

  private func typePart(_ ty: Ty) -> SymbolPart? {
    var base = ty
    if case .optional(let inner) = base { base = inner }
    guard case .nominal(let ref, _) = base else { return nil }
    return part(ref)
  }
}

extension Ty {
  /// A constructed type's name.
  var nominalName: Name {
    if case .constructed(let kind, _) = self { return kind }
    return 0
  }
}

extension PHPModel {
  /// As `phpref.py` places it: a path relative to the root (`../x` outside it), the stub's declarations as
  /// `php:<Name>` or `php:<Class>::<member>` (line 1), a superglobal as `php:$<name>`.
  public func place(of site: Site) -> (path: String, line: Int)? {
    switch site {
    case .module: return nil
    case .decl(let ref) where isSDK(ref):
      let item = decl(ref)
      let holder = unit(ref)
      var text = holder.string(Int(item.nameToken))
      if item.kind == .variable, holder.phIsVariable(Int(item.nameToken)) { text = "$" + text }
      if item.parent >= 0 { text = holder.string(Int(holder.decls[Int(item.parent)].nameToken)) + "::" + text }
      return ("php:" + text, 1)
    case .local(let unitIndex, let token) where token >= 0 && project.isSDK(project.units[Int(unitIndex)]):
      let holder = project.units[Int(unitIndex)]
      if holder.chain(at: token).isEmpty { return ("php:$" + holder.string(Int(token)), 1) }
      return nil
    case .local(_, let token) where token < 0:
      // An included file: its first line.
      return project.place(of: site)
    default:
      guard let at = project.location(of: site) else { return nil }
      return (project.rootRelative(at.path), at.line + 1)
    }
  }
}
