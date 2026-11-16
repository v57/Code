import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its declaration on one line, its doc comment, what it's in (a method's
/// receiver type, a field's struct, out to the package) and a value's type.
extension GoModel {
  public func details(of site: Site) -> SymbolDetails? {
    switch site {
    case .decl(let ref):
      guard let symbol = part(ref) else { return nil }
      let item = decl(ref)
      var parents: [SymbolPart] = []
      var parent = item.parent
      let holder = unit(ref)
      while parent >= 0 {
        let owner = DeclRef(unit: ref.unit, decl: parent)
        if let shown = containerPart(owner) { parents.append(shown) }
        parent = holder.decls[Int(parent)].parent
      }
      parents.append(packagePart(of: holder))
      var type: SymbolPart?
      var inferred: String?
      if item.kind == .variable {
        let ty = valueType(of: ref)
        type = typePart(ty)
        if item.typeStart < 0, ty != .unknown { inferred = describe(ty) }
      }
      let documentation = holder.documentation(above: docToken(ref), linePrefix: "//", blockOpen: "/*")
      return SymbolDetails(symbol: symbol, declaration: declaration(ref, inferred: inferred), documentation: documentation, parents: parents, type: type)
    case .local(let unitIndex, let token):
      return localDetails(unitIndex: unitIndex, token: token)
    case .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = location(of: site) else { return nil }
      let symbol = SymbolPart(
        kind: .generic, name: holder.string(Int(token)), keyword: "", path: at.path, line: at.line, character: at.character,
        module: project.moduleName(of: holder), isSDK: project.isSDK(holder))
      return SymbolDetails(symbol: symbol, declaration: symbol.name, documentation: nil, parents: enclosing(unitIndex, token), type: nil)
    case .module(let moduleName):
      guard let module = project.modules[moduleName] else { return nil }
      let part = modulePart(module)
      return SymbolDetails(symbol: part, declaration: "import \"\(module.displayName)\"", documentation: packageDocumentation(module), parents: [], type: nil)
    }
  }

  /// The doc comment's line: above a grouped spec's own name, else above the declaration.
  private func docToken(_ ref: DeclRef) -> Int {
    let item = decl(ref)
    let holder = unit(ref)
    if item.parent >= 0, holder.decls[Int(item.parent)].kind == .extensionDecl { return Int(holder.decls[Int(item.parent)].first) }
    if item.nameToken >= 0, holder.startsLine(Int(item.nameToken)) { return Int(item.nameToken) }
    return Int(item.first)
  }

  private func part(_ ref: DeclRef) -> SymbolPart? {
    let item = decl(ref)
    guard item.nameToken >= 0 else { return nil }
    let name = unit(ref).string(Int(item.nameToken))
    return project.part(ref, name: item.kind == .function ? name + "()" : name, keyword: keyword(ref))
  }

  /// A method's holder is shown as its receiver's type.
  private func containerPart(_ ref: DeclRef) -> SymbolPart? {
    let item = decl(ref)
    if item.kind == .extensionDecl {
      let types = lookup(item.name, unitIndex: ref.unit, token: item.nameToken)
      if case .decl(let target)? = types.first { return part(target) }
      return nil
    }
    if item.name == 0 { return nil }
    return part(ref)
  }

  private func enclosing(_ unitIndex: Int32, _ token: Int32) -> [SymbolPart] {
    let holder = project.units[Int(unitIndex)]
    var parents: [SymbolPart] = []
    for index in holder.chain(at: token).reversed() {
      if let shown = containerPart(DeclRef(unit: unitIndex, decl: index)) { parents.append(shown) }
    }
    parents.append(packagePart(of: holder))
    return parents
  }

  private func packagePart(of holder: Unit) -> SymbolPart {
    if let module = project.modules[holder.moduleName] { return modulePart(module) }
    return SymbolPart(kind: .module, name: "", keyword: "", path: nil, line: 0, character: 0, module: "", isSDK: project.isSDK(holder))
  }

  /// A package, at its directory's first file.
  private func modulePart(_ module: Module) -> SymbolPart {
    var display = module.displayName
    if display.hasSuffix("#off") { display.removeLast(4) }
    let first = module.units.first.map { project.units[Int($0)].path }
    return SymbolPart(kind: .module, name: display, keyword: "package", path: first, line: 0, character: 0, module: display, isSDK: module.isSDK)
  }

  /// The package's doc comment, from the file that has one.
  private func packageDocumentation(_ module: Module) -> String? {
    for index in module.units {
      let holder = project.units[Int(index)]
      if holder.isToken(0, "package"), let found = holder.documentation(above: 0, linePrefix: "//", blockOpen: "/*") { return found }
    }
    return nil
  }

  private func typePart(_ ty: Ty) -> SymbolPart? {
    guard case .nominal(let ref, _) = dereferenced(ty), decl(ref).name != 0 else { return nil }
    return part(ref)
  }

  private func keyword(_ ref: DeclRef) -> String {
    let item = decl(ref)
    switch item.kind {
    case .function: return "func"
    case .structure, .protocolType, .typeAlias: return "type"
    case .variable:
      if item.parent >= 0, unit(ref).decls[Int(item.parent)].kind.isNominal { return "" }
      return item.isStatic ? "const" : "var"
    default: return ""
    }
  }

  /// One line: `func (s *Server) Serve(l net.Listener) error`, `type Server struct`, `var x int`, `Name string`.
  private func declaration(_ ref: DeclRef, inferred: String?) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    let name = holder.string(Int(item.nameToken))
    switch item.kind {
    case .function:
      var start = Int(item.first)
      if item.parent >= 0, holder.decls[Int(item.parent)].kind == .extensionDecl { start = Int(holder.decls[Int(item.parent)].first) }
      let end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
      let text = holder.text(from: start, to: end)
      return holder.decls[Int(max(item.parent, 0))].kind == .protocolType && item.parent >= 0 ? text : String(text.prefix(400))
    case .structure, .protocolType, .typeAlias:
      if item.bodyOpen >= 0 { return "type " + holder.text(from: Int(item.nameToken), to: Int(item.bodyOpen)) }
      return "type " + holder.text(from: Int(item.nameToken), to: Int(item.end))
    case .variable:
      if isEmbeddedField(ref) { return holder.text(from: Int(item.typeStart), to: Int(item.typeEnd)) }
      if item.parent >= 0, holder.decls[Int(item.parent)].kind.isNominal { return name + " " + holder.text(from: Int(item.typeStart), to: Int(item.typeEnd)) }
      var text = (item.isStatic ? "const " : "var ") + name
      if item.typeStart >= 0 {
        text += " " + holder.text(from: Int(item.typeStart), to: Int(item.typeEnd))
      } else if item.isStatic, item.initStart >= 0, item.valueIndex == 0 {
        text += " = " + holder.text(from: Int(item.initStart), to: Int(item.initEnd))
      } else if let inferred {
        text += " " + inferred
      }
      return String(text.prefix(400))
    default:
      return name
    }
  }

  /// A local or a parameter.
  private func localDetails(unitIndex: Int32, token: Int32) -> SymbolDetails? {
    let holder = project.units[Int(unitIndex)]
    guard let at = location(of: .local(unit: unitIndex, token: token)) else { return nil }
    var isParameter = false
    for index in holder.chain(at: token) {
      let item = holder.decls[Int(index)]
      for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].nameToken == token { isParameter = true }
    }
    var ty = Ty.unknown
    if let body = body(unitIndex: unitIndex, token: token), let index = body.byToken[token] {
      ty = localType(unitIndex: unitIndex, body: body, index: index)
      if case .typed = body.locals[Int(index)].kind, !isParameter, holder.isToken(Int(token) - 1, "(") || holder.isByte(Int(token) - 1, 0x2C) {
        isParameter = true
      }
    } else if case let found = siteType(.local(unit: unitIndex, token: token), unitIndex: unitIndex), found != .unknown {
      ty = found
    }
    let name = holder.string(Int(token))
    let symbol = SymbolPart(
      kind: isParameter ? .parameter : .local, name: name, keyword: isParameter ? "" : "var", path: at.path, line: at.line, character: at.character,
      module: project.moduleName(of: holder), isSDK: project.isSDK(holder))
    var declaration = (isParameter ? "" : "var ") + name
    let text = describe(ty)
    if !text.isEmpty { declaration += " " + text }
    return SymbolDetails(symbol: symbol, declaration: declaration, documentation: nil, parents: enclosing(unitIndex, token), type: typePart(ty))
  }
}

extension GoModel {
  /// As `go/types` places it (CodeModelBench's Go reference): relative to the root (`../x` for a sibling module),
  /// `goroot:<path under GOROOT/src>`, `mod:<path under the module cache>`, `package:<import path>`.
  public func place(of site: Site) -> (path: String, line: Int)? {
    if case .module(let moduleName) = site {
      guard let module = project.modules[moduleName] else { return nil }
      return ("package:" + module.displayName, 0)
    }
    guard let at = location(of: site) else { return nil }
    let path = at.path
    let environment = layout.environment
    if !environment.goroot.isEmpty, path.hasPrefix(environment.goroot + "/src/") { return ("goroot:" + path.dropFirst(environment.goroot.count + 5), at.line + 1) }
    if !environment.modcache.isEmpty, path.hasPrefix(environment.modcache + "/") { return ("mod:" + path.dropFirst(environment.modcache.count + 1), at.line + 1) }
    let root = project.root.split(separator: "/")
    let parts = path.split(separator: "/")
    var common = 0
    while common < root.count, common < parts.count, root[common] == parts[common] { common += 1 }
    let relative = Array(repeating: "..", count: root.count - common) + parts[common...].map(String.init)
    return (relative.joined(separator: "/"), at.line + 1)
  }
}
