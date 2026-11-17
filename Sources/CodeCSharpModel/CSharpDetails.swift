import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its declaration on one line, its doc comment's summary, the types and
/// namespace it's in, and a value's type.
extension CSharpModel {
  public func details(of site: Site) -> SymbolDetails? {
    switch site {
    case .decl(let ref):
      let item = decl(ref)
      guard let symbol = part(ref) else { return nil }
      let holder = self.unit(ref)
      var parents: [SymbolPart] = []
      var parent = item.parent
      while parent >= 0 {
        let owner = DeclRef(unit: ref.unit, decl: parent)
        if holder.decls[Int(parent)].kind == .namespace { break }
        if let shown = part(owner) { parents.append(shown) }
        parent = holder.decls[Int(parent)].parent
      }
      let namespace = item.kind == .namespace ? "" : enclosingNamespace(ref)
      if !namespace.isEmpty { parents.append(namespacePart(namespace, isSDK: project.isSDK(holder))) }
      var type: SymbolPart?
      if item.kind == .variable || item.kind == .function || item.kind == .subscriptDecl { type = typePart(valueType(of: ref)) }
      let documentation = summary(holder.documentation(above: Int(item.first), linePrefix: "///", blockOpen: "/**"))
      return SymbolDetails(symbol: symbol, declaration: declaration(ref), documentation: documentation, parents: parents, type: type)
    case .local(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = project.location(of: site) else { return nil }
      var isParameter = false
      for index in holder.chain(at: token) {
        let item = holder.decls[Int(index)]
        for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].nameToken == token { isParameter = true }
      }
      let ty = siteType(site, unitIndex: unitIndex)
      if let body = body(unitIndex: unitIndex, token: token), let index = body.byToken[token], case .lambda = body.locals[Int(index)].kind { isParameter = true }
      let name = holder.string(Int(token))
      let symbol = SymbolPart(
        kind: isParameter ? .parameter : .local, name: name, keyword: "", path: at.path, line: at.line, character: at.character,
        module: namespaceAt(unitIndex, token), isSDK: project.isSDK(holder))
      let text = describe(ty)
      return SymbolDetails(
        symbol: symbol, declaration: (text.isEmpty ? "var" : text) + " " + name, documentation: nil, parents: enclosingParts(unitIndex, token), type: typePart(ty))
    case .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = project.location(of: site) else { return nil }
      let symbol = SymbolPart(
        kind: .generic, name: holder.string(Int(token)), keyword: "", path: at.path, line: at.line, character: at.character,
        module: namespaceAt(unitIndex, token), isSDK: project.isSDK(holder))
      var declaration = symbol.name
      let bounds = constraints(of: typeOfSite(site, args: [])).map(describe).filter { !$0.isEmpty }
      if !bounds.isEmpty { declaration = "where " + declaration + " : " + bounds.joined(separator: ", ") }
      return SymbolDetails(symbol: symbol, declaration: declaration, documentation: nil, parents: enclosingParts(unitIndex, token), type: nil)
    case .module(let hashed):
      guard let text = namespaceNames[hashed] else { return nil }
      return SymbolDetails(symbol: namespacePart(text, isSDK: false), declaration: "namespace " + text, documentation: nil, parents: [], type: nil)
    }
  }

  /// A `<summary>`'s text without its tags.
  private func summary(_ text: String?) -> String? {
    guard var text else { return nil }
    if let open = text.range(of: "<summary>"), let close = text.range(of: "</summary>", range: open.upperBound..<text.endIndex) {
      text = String(text[open.upperBound..<close.lowerBound])
    }
    var plain = ""
    var inTag = false
    for character in text {
      if character == "<" { inTag = true } else if character == ">" { inTag = false } else if !inTag { plain.append(character) }
    }
    let trimmed = plain.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    return trimmed.isEmpty ? nil : trimmed
  }

  private func namespaceAt(_ unitIndex: Int32, _ token: Int32) -> String {
    let holder = project.units[Int(unitIndex)]
    for index in holder.chain(at: token) where holder.decls[Int(index)].kind == .namespace {
      return namespaceName(of: DeclRef(unit: unitIndex, decl: index))
    }
    // A file-scoped namespace isn't around the token.
    for (position, item) in holder.decls.enumerated() where item.kind == .namespace && item.parent < 0 && item.bodyOpen < 0 {
      return namespaceName(of: DeclRef(unit: unitIndex, decl: Int32(position)))
    }
    return ""
  }

  private func part(_ ref: DeclRef) -> SymbolPart? {
    let item = decl(ref)
    guard item.nameToken >= 0 else { return nil }
    if item.kind == .namespace { return namespacePart(namespaceName(of: ref), isSDK: project.isSDK(self.unit(ref))) }
    var name = self.unit(ref).string(Int(item.nameToken))
    if item.kind == .subscriptDecl { name = "this[]" }
    if item.name == 0, item.kind == .function { name = "operator " + self.unit(ref).string(Int(item.nameToken) + 1) }
    return project.part(ref, name: item.kind == .function || item.kind == .initializer ? name + "()" : name, keyword: keyword(ref))
  }

  private func keyword(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = self.unit(ref)
    switch item.kind {
    case .classType:
      if isDelegate(ref) { return "delegate" }
      return hasModifier(ref, "record") || holder.isToken(Int(item.nameToken) - 1, "record") ? "record" : "class"
    case .structure: return holder.isToken(Int(item.nameToken) - 1, "struct") && holder.isToken(Int(item.nameToken) - 2, "record") ? "record struct" : "struct"
    case .protocolType: return "interface"
    case .enumeration: return "enum"
    default: return ""
    }
  }

  private func namespacePart(_ namespace: String, isSDK: Bool) -> SymbolPart {
    SymbolPart(kind: .module, name: namespace, keyword: "namespace", path: nil, line: 0, character: 0, module: namespace, isSDK: isSDK)
  }

  private func enclosingParts(_ unitIndex: Int32, _ token: Int32) -> [SymbolPart] {
    let holder = project.units[Int(unitIndex)]
    var parents: [SymbolPart] = []
    for index in holder.chain(at: token).reversed() where holder.decls[Int(index)].kind != .namespace {
      if let shown = part(DeclRef(unit: unitIndex, decl: index)) { parents.append(shown) }
    }
    let namespace = namespaceAt(unitIndex, token)
    if !namespace.isEmpty { parents.append(namespacePart(namespace, isSDK: project.isSDK(holder))) }
    return parents
  }

  private func typePart(_ ty: Ty) -> SymbolPart? {
    var base = ty
    if case .constructed(let kind, let args) = ty, kind == Ty.array, let first = args.first { base = first }
    if let inner = nullableValue(base) { base = inner }
    guard case .nominal(let ref, _) = base, decl(ref).name != 0 else { return nil }
    return part(ref)
  }

  /// One line, without attributes: `public static IEnumerable<T> Where<T>(this IEnumerable<T> source, …)`.
  private func declaration(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = self.unit(ref)
    let start = holder.csSkipAttributes(Int(item.first))
    var end: Int
    switch item.kind {
    case .namespace:
      return "namespace " + namespaceName(of: ref)
    case .variable:
      end = Int(item.nameToken) + 1
      if holder.isToken(end, "{") || holder.isByte(end, 0x7B) { end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : end }
      if item.typeStart < 0 { end = Int(item.nameToken) + 1 }
      // A record's positional property: its parameter as written.
      if item.typeStart >= 0, Int(item.typeStart) > start + 40 {
        return oneLine(holder.text(from: Int(item.typeStart), to: Int(item.nameToken) + 1))
      }
      end = Int(item.nameToken) + 1
    case .enumCase:
      return holder.string(Int(item.nameToken))
    case .function, .initializer, .deinitializer, .subscriptDecl:
      end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
      if holder.isByte(end - 1, 0x3B) { end -= 1 }
    default:
      end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
      if holder.isByte(end - 1, 0x3B) { end -= 1 }
    }
    guard start < end else { return holder.string(Int(max(item.nameToken, item.first))) }
    return oneLine(String(holder.text(from: start, to: end).prefix(400)))
  }

  /// A type as C# writes it: `List<string>`, `int?`, `(int a, string b)`, `Func<int, bool>`.
  func describe(_ ty: Ty) -> String {
    switch ty {
    case .nominal(let ref, let args):
      if let inner = nullableValue(ty) { return describe(inner) + "?" }
      let item = decl(ref)
      guard item.name != 0, item.nameToken >= 0 else { return "" }
      var text = self.unit(ref).string(Int(item.nameToken))
      if enclosingNamespace(ref) == CSharpWord.system, args.isEmpty, let keyword = CSharpWord.keywordOf[text] { return keyword }
      if !args.isEmpty { text += "<" + args.map { describe($0) }.joined(separator: ", ") + ">" }
      return text
    case .constructed(let kind, let args):
      if kind == Ty.array { return describe(args.first ?? .unknown) + "[]" }
      if kind == Ty.pointer { return describe(args.first ?? .unknown) + "*" }
      if kind == CSharpWord.voidWord { return "void" }
      return ""
    case .tuple(let elements, _):
      return "(" + elements.map { describe($0) }.joined(separator: ", ") + ")"
    case .param(let word, let owner):
      if let owner {
        let holder = self.unit(owner)
        let item = decl(owner)
        for g in 0..<Int(item.genericCount) where holder.generics[Int(item.genericStart) + g].name == word {
          return holder.string(Int(holder.generics[Int(item.genericStart) + g].token))
        }
      }
      return ""
    case .optional(let inner): return describe(inner) + "?"
    case .meta(let inner): return describe(inner)
    case .module(let hashed): return namespaceNames[hashed] ?? ""
    default: return ""
    }
  }
}

extension CSharpModel {
  /// As CodeModelBench's Roslyn reference places it: a path relative to the root (`../x` outside it), the library's
  /// `net:<qualified name>` (line 1: a generic type with `` `n ``, a method `Type.Name(<n>)`, a constructor
  /// `Type..ctor(<n>)`, an indexer `Type.this[]`), `namespace:<name>` (line 0).
  public func place(of site: Site) -> (path: String, line: Int)? {
    if case .module(let hashed) = site {
      guard let text = namespaceNames[hashed] else { return nil }
      return ("namespace:" + text, 0)
    }
    if case .decl(let ref) = site {
      if decl(ref).kind == .namespace { return ("namespace:" + namespaceName(of: ref), 0) }
      if project.isSDK(self.unit(ref)) {
        guard let qualified = qualifiedName(ref) else { return nil }
        return (CSharpLayout.libraryPrefix + qualified, 1)
      }
    }
    guard let at = project.location(of: site) else { return nil }
    return (project.rootRelative(at.path), at.line + 1)
  }

  /// `System.Collections.Generic.List`1`, `System.Linq.Enumerable.Where(2)`, `System.String..ctor(1)`.
  func qualifiedName(_ ref: DeclRef) -> String? {
    let holder = self.unit(ref)
    let item = decl(ref)
    var types: [String] = []
    var current = item.kind.isNominal ? ref.decl : item.parent
    while current >= 0 {
      let owner = holder.decls[Int(current)]
      if owner.kind == .namespace { break }
      guard owner.kind.isNominal, owner.name != 0 else { return nil }
      types.insert(holder.string(Int(owner.nameToken)) + (owner.genericCount > 0 ? "`" + String(owner.genericCount) : ""), at: 0)
      current = owner.parent
    }
    guard !types.isEmpty else { return nil }
    let namespace = enclosingNamespace(ref)
    let base = (namespace.isEmpty ? "" : namespace + ".") + types.joined(separator: ".")
    switch item.kind {
    case .function:
      guard item.name != 0 else { return nil }
      return base + "." + holder.string(Int(item.nameToken)) + "(" + String(item.paramCount) + ")"
    case .initializer: return base + "..ctor(" + String(item.paramCount) + ")"
    case .subscriptDecl: return base + ".this[]"
    case .variable, .enumCase: return base + "." + holder.string(Int(item.nameToken))
    default: return item.kind.isNominal ? base : nil
    }
  }

  /// Where a site is; a library stub's file is written out first.
  public func location(of site: Site) -> (path: String, line: Int, character: Int, name: String, preview: String)? {
    guard let found = project.location(of: site) else { return nil }
    if found.path.hasPrefix(CSharpLayout.stdDirectory) { layout.materialize(found.path) }
    return found
  }
}
