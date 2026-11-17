import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its declaration on one line, its doc comment's summary, the types and library
/// it's in, and a value's type. Places as the references name them.
extension DartModel {
  public func details(of site: Site) -> SymbolDetails? {
    switch site {
    case .decl(let ref):
      let item = decl(ref)
      guard let symbol = part(ref) else { return nil }
      let holder = unit(ref)
      var parents: [SymbolPart] = []
      if item.parent >= 0, let shown = part(DeclRef(unit: ref.unit, decl: item.parent)) { parents.append(shown) }
      parents.append(libraryPart(holder))
      var type: SymbolPart?
      if item.kind == .variable || item.kind == .function { type = typePart(valueType(of: ref)) }
      let documentation = holder.documentation(above: Int(item.first), linePrefix: "///", blockOpen: "/**")
      return SymbolDetails(symbol: symbol, declaration: declaration(ref), documentation: documentation, parents: parents, type: type)
    case .local(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = project.location(of: site) else { return nil }
      if holder.imports.contains(where: { $0.aliasToken == token }) {
        let symbol = SymbolPart(kind: .module, name: holder.string(Int(token)), keyword: "import", path: at.path, line: at.line, character: at.character, module: libraryName(holder), isSDK: false)
        return SymbolDetails(symbol: symbol, declaration: holder.lineText(at.line), documentation: nil, parents: [libraryPart(holder)], type: nil)
      }
      let isParameter = holder.decls.contains { item in (0..<Int(item.paramCount)).contains { holder.params[Int(item.paramStart) + $0].nameToken == token } }
      var ty = Ty.unknown
      if let body = body(unitIndex: unitIndex, token: token), let index = body.byToken[token] { ty = localType(unitIndex: unitIndex, body: body, index: index) }
      let name = holder.string(Int(token))
      let symbol = SymbolPart(
        kind: isParameter ? .parameter : .local, name: name, keyword: "", path: at.path, line: at.line, character: at.character, module: libraryName(holder),
        isSDK: project.isSDK(holder))
      let text = describe(ty)
      var parents: [SymbolPart] = []
      for index in chain(holder, unitIndex: unitIndex, at: token).reversed() { if let shown = part(DeclRef(unit: unitIndex, decl: index)) { parents.append(shown) } }
      parents.append(libraryPart(holder))
      return SymbolDetails(symbol: symbol, declaration: (text.isEmpty ? "var" : text) + " " + name, documentation: nil, parents: parents, type: typePart(ty))
    case .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = project.location(of: site) else { return nil }
      let symbol = SymbolPart(
        kind: .generic, name: holder.string(Int(token)), keyword: "", path: at.path, line: at.line, character: at.character, module: libraryName(holder),
        isSDK: project.isSDK(holder))
      var declaration = symbol.name
      if holder.isToken(Int(token) + 1, "extends"), let end = holder.daTypeEnd(Int(token) + 2) { declaration = holder.text(from: Int(token), to: end) }
      var parents: [SymbolPart] = []
      for index in chain(holder, unitIndex: unitIndex, at: token).reversed() { if let shown = part(DeclRef(unit: unitIndex, decl: index)) { parents.append(shown) } }
      return SymbolDetails(symbol: symbol, declaration: declaration, documentation: nil, parents: parents, type: nil)
    case .module:
      return nil
    }
  }

  /// A library as a part: its `package:` or `dart:` URI, or its path in the project.
  func libraryName(_ holder: Unit) -> String {
    if let module = project.modules[holder.moduleName], module.displayName.hasPrefix("dart:") { return module.displayName }
    let path = project.modules[holder.moduleName]?.displayName ?? holder.path
    if path.hasPrefix(project.root + "/") { return String(path.dropFirst(project.root.count + 1)) }
    return layout.packageURI(path) ?? (path as NSString).lastPathComponent
  }

  private func libraryPart(_ holder: Unit) -> SymbolPart {
    let name = libraryName(holder)
    return SymbolPart(kind: .module, name: name, keyword: "library", path: nil, line: 0, character: 0, module: name, isSDK: project.isSDK(holder))
  }

  private func part(_ ref: DeclRef) -> SymbolPart? {
    let item = decl(ref)
    guard item.nameToken >= 0 else { return nil }
    let holder = unit(ref)
    var name = holder.string(Int(item.nameToken))
    if item.kind == .extensionDecl, item.access == .isPrivate, holder.isToken(Int(item.nameToken), "extension") { name = "extension on " + holder.text(from: Int(item.typeStart), to: Int(item.typeEnd)) }
    if item.kind == .initializer, item.parent >= 0 {
      let owner = holder.string(Int(holder.decls[Int(item.parent)].nameToken))
      name = item.name == DartWord.newWord ? owner + "()" : owner + "." + name + "()"
    } else if item.kind == .function {
      name += "()"
    }
    return project.part(ref, name: name, keyword: keyword(ref))
  }

  private func keyword(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    switch item.kind {
    case .classType: return holder.isToken(Int(item.nameToken) - 1, "mixin") ? "mixin" : "class"
    case .enumeration: return "enum"
    case .structure: return "extension type"
    case .extensionDecl: return "extension"
    case .typeAlias: return "typedef"
    case .initializer: return holder.isToken(Int(item.first), "factory") || item.isStatic ? "factory" : ""
    case .variable:
      if holder.isToken(Int(item.nameToken) - 1, "get") { return "get" }
      if holder.isToken(Int(item.nameToken) - 1, "set") { return "set" }
      var k = Int(item.first)
      while k < Int(item.nameToken) {
        if holder.isToken(k, "const") { return "const" }
        if holder.isToken(k, "final") { return "final" }
        if holder.isToken(k, "var") { return "var" }
        k += 1
      }
      return ""
    default: return ""
    }
  }

  /// One line, without metadata or body: `Future<String> readAsString({Encoding encoding = utf8})`.
  private func declaration(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    let start = holder.daSkipMetadata(Int(item.first))
    var end: Int
    switch item.kind {
    case .classType, .enumeration, .structure, .extensionDecl:
      end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
    case .enumCase:
      return holder.string(Int(item.nameToken))
    case .variable:
      end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.nameToken) + 1
      if item.paramCount > 0, item.bodyOpen < 0 { end = Int(item.end) }
      if item.initStart >= 0, item.typeStart < 0, holder.isToken(Int(item.nameToken) + 1, "=") {
        // `final x = …`: the inferred type in its place.
        let text = describe(valueType(of: ref))
        if !text.isEmpty { return oneLine(holder.text(from: start, to: Int(item.nameToken))).replacingOccurrences(of: "var", with: "") .trimmingCharacters(in: .whitespaces) + " " + text + " " + holder.string(Int(item.nameToken)) }
      }
    case .function, .initializer:
      end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
      if item.kind == .initializer, item.initStart >= 0 { end = Int(item.initStart) - 1 }
    default:
      end = Int(item.end)
    }
    if holder.isByte(end - 1, 0x3B) { end -= 1 }
    guard start < end else { return holder.string(Int(max(item.nameToken, item.first))) }
    return String(holder.text(from: start, to: end).prefix(400))
  }

  /// A type as Dart writes it: `List<String>`, `int?`, `(int, String)`, `void Function(int)`.
  func describe(_ ty: Ty) -> String {
    switch ty {
    case .nominal(let ref, let args):
      let item = decl(ref)
      guard item.nameToken >= 0 else { return "" }
      var text = unit(ref).string(Int(item.nameToken))
      if !args.isEmpty { text += "<" + args.map { describe($0).isEmpty ? "dynamic" : describe($0) }.joined(separator: ", ") + ">" }
      return text
    case .constructed(let kind, _):
      return kind == DartWord.voidWord ? "void" : ""
    case .tuple(let elements, _):
      return "(" + elements.map { describe($0).isEmpty ? "dynamic" : describe($0) }.joined(separator: ", ") + ")"
    case .function(let params, let result):
      let returns = describe(result)
      return (returns.isEmpty ? "dynamic" : returns) + " Function(" + params.map { describe($0).isEmpty ? "dynamic" : describe($0) }.joined(separator: ", ") + ")"
    case .param(let word, let owner):
      if let owner {
        let holder = unit(owner)
        let item = decl(owner)
        for g in 0..<Int(item.genericCount) where holder.generics[Int(item.genericStart) + g].name == word {
          return holder.string(Int(holder.generics[Int(item.genericStart) + g].token))
        }
      }
      return ""
    case .optional(let inner):
      let text = describe(inner)
      return text.isEmpty ? "" : text + "?"
    case .meta(let inner): return describe(inner)
    default: return ""
    }
  }

  private func typePart(_ ty: Ty) -> SymbolPart? {
    guard case .nominal(let ref, _) = nonNull(ty) else { return nil }
    return part(ref)
  }
}

extension DartModel {
  /// As CodeModelBench's analyzer reference places it: a path relative to the root (`../x` outside it), a package's
  /// file as `package:<name>/<path>`, a `dart:` library's declaration by name, `dart:<library>/<Owner>.<member>`
  /// (`<Owner>.new` for an unnamed constructor, `<Owner>.name=` for a setter, `<Owner>.operator ==`, a parameter as
  /// `<Owner>.<member>.<parameter>`; line 1).
  public func place(of site: Site) -> (path: String, line: Int)? {
    if case .module = site { return nil }
    if case .decl(let ref) = site, isSDK(ref) {
      guard let library = project.modules[unit(ref).moduleName]?.displayName, library.hasPrefix("dart:"), let qualified = qualifiedName(ref) else { return nil }
      return (library + "/" + qualified, 1)
    }
    // A parameter of a `dart:` function: `dart:core/Duration.new.seconds`.
    if case .local(let unitIndex, let token) = site, project.isSDK(project.units[Int(unitIndex)]) {
      let holder = project.units[Int(unitIndex)]
      guard let library = project.modules[holder.moduleName]?.displayName, library.hasPrefix("dart:"), let owner = chain(holder, unitIndex: unitIndex, at: token).last,
        let qualified = qualifiedName(DeclRef(unit: unitIndex, decl: owner))
      else { return nil }
      return (library + "/" + qualified + "." + holder.string(Int(token)), 1)
    }
    guard let at = project.location(of: site) else { return nil }
    if !at.path.hasPrefix(project.root + "/"), let uri = layout.packageURI(at.path) { return (uri, at.line + 1) }
    return (project.rootRelative(at.path), at.line + 1)
  }

  /// `String.length`, `List.new`, `Iterable.map`, `print`, `EnumName.name`.
  func qualifiedName(_ ref: DeclRef) -> String? {
    let item = decl(ref)
    let holder = unit(ref)
    guard item.nameToken >= 0 else { return nil }
    var name = holder.string(Int(item.nameToken))
    if item.kind == .initializer {
      guard item.parent >= 0 else { return nil }
      name = item.name == DartWord.newWord ? "new" : name
    } else if item.kind == .variable, holder.isToken(Int(item.nameToken) - 1, "set") {
      name += "="
    } else if item.kind == .function, holder.tokens[Int(item.nameToken)].kind == .punctuation || holder.isByte(Int(item.nameToken), 0x5B) {
      name = "operator " + (item.name == DartWord.indexOperator ? "[]" : holder.isByte(Int(item.nameToken), 0x5B) ? "[]=" : holder.string(Int(item.nameToken)))
    }
    guard item.parent >= 0 else { return name }
    let owner = holder.decls[Int(item.parent)]
    return holder.string(Int(owner.nameToken)) + "." + name
  }

  /// Where a site is; a stub's file is written out first.
  public func location(of site: Site) -> (path: String, line: Int, character: Int, name: String, preview: String)? {
    guard let found = project.location(of: site) else { return nil }
    if found.path.hasPrefix(DartLayout.stdDirectory) { layout.materialize(found.path) }
    return found
  }
}
