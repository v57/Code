import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its declaration on one line, its Javadoc's first paragraph, the classes and
/// package it's in, and a value's type.
extension JavaModel {
  public func details(of site: Site) -> SymbolDetails? {
    switch site {
    case .decl(let ref):
      let item = decl(ref)
      guard let symbol = part(ref) else { return nil }
      let holder = unit(ref)
      var parents: [SymbolPart] = []
      var parent = item.parent
      while parent >= 0 {
        if let shown = part(DeclRef(unit: ref.unit, decl: parent)) { parents.append(shown) }
        parent = holder.decls[Int(parent)].parent
      }
      parents.append(packagePart(packageOf(ref.unit), isSDK: project.isSDK(holder)))
      var type: SymbolPart?
      if item.kind == .variable || item.kind == .function { type = typePart(valueType(of: ref)) }
      let documentation = holder.documentation(above: Int(item.first), linePrefix: "//", blockOpen: "/**")
      return SymbolDetails(symbol: symbol, declaration: declaration(ref), documentation: documentation, parents: parents, type: type)
    case .local(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = location(of: site) else { return nil }
      var isParameter = false
      for index in holder.chain(at: token) {
        let item = holder.decls[Int(index)]
        for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].nameToken == token { isParameter = true }
      }
      var ty = Ty.unknown
      if let body = body(unitIndex: unitIndex, token: token), let index = body.byToken[token] {
        ty = localType(unitIndex: unitIndex, body: body, index: index)
        if case .lambda = body.locals[Int(index)].kind { isParameter = true }
      }
      let name = holder.string(Int(token))
      let symbol = SymbolPart(
        kind: isParameter ? .parameter : .local, name: name, keyword: "", path: at.path, line: at.line, character: at.character,
        module: packageOf(unitIndex), isSDK: project.isSDK(holder))
      let text = describe(ty)
      return SymbolDetails(
        symbol: symbol, declaration: (text.isEmpty ? "var" : text) + " " + name, documentation: nil, parents: enclosingParts(unitIndex, token), type: typePart(ty))
    case .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = location(of: site) else { return nil }
      let symbol = SymbolPart(
        kind: .generic, name: holder.string(Int(token)), keyword: "", path: at.path, line: at.line, character: at.character,
        module: packageOf(unitIndex), isSDK: project.isSDK(holder))
      var declaration = symbol.name
      if holder.isToken(Int(token) + 1, "extends") {
        let ty = typeOfSite(site, args: [])
        if let found = bound(of: ty) { declaration += " extends " + describe(found) }
      }
      return SymbolDetails(symbol: symbol, declaration: declaration, documentation: nil, parents: enclosingParts(unitIndex, token), type: nil)
    case .module(let package):
      guard let text = packageNames[package] else { return nil }
      return SymbolDetails(symbol: packagePart(text, isSDK: false), declaration: "package " + text, documentation: nil, parents: [], type: nil)
    }
  }

  private func part(_ ref: DeclRef) -> SymbolPart? {
    let item = decl(ref)
    if item.name == 0 {
      // An anonymous class: shown as what it extends.
      guard item.kind == .classType, item.inheritCount > 0 else { return nil }
      let range = unit(ref).ranges[Int(item.inheritStart)]
      return project.part(ref, name: "new " + unit(ref).text(from: Int(range.start), to: Int(range.end)) + "() {…}", keyword: "")
    }
    guard item.nameToken >= 0 else { return nil }
    let name = unit(ref).string(Int(item.nameToken))
    return project.part(ref, name: item.kind == .function || item.kind == .initializer ? name + "()" : name, keyword: keyword(ref))
  }

  private func keyword(_ ref: DeclRef) -> String {
    let item = decl(ref)
    switch item.kind {
    case .classType: return "class"
    case .protocolType: return unit(ref).isToken(Int(item.nameToken) - 1, "@interface") ? "@interface" : "interface"
    case .enumeration: return "enum"
    case .structure: return "record"
    default: return ""
    }
  }

  private func packagePart(_ package: String, isSDK: Bool) -> SymbolPart {
    SymbolPart(kind: .module, name: package, keyword: "package", path: nil, line: 0, character: 0, module: package, isSDK: isSDK)
  }

  private func enclosingParts(_ unitIndex: Int32, _ token: Int32) -> [SymbolPart] {
    let holder = project.units[Int(unitIndex)]
    var parents: [SymbolPart] = []
    for index in holder.chain(at: token).reversed() {
      if let shown = part(DeclRef(unit: unitIndex, decl: index)) { parents.append(shown) }
    }
    parents.append(packagePart(packageOf(unitIndex), isSDK: project.isSDK(holder)))
    return parents
  }

  private func typePart(_ ty: Ty) -> SymbolPart? {
    var base = ty
    if case .constructed(let kind, let args) = ty, kind == Ty.array, let first = args.first { base = first }
    guard case .nominal(let ref, _) = base, decl(ref).name != 0 else { return nil }
    return part(ref)
  }

  /// One line, without annotations: `public static <T> List<T> of(T... items)`, `public class Foo<T> extends Bar`.
  private func declaration(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    var start = Int(item.first)
    start = holder.javaSkipAnnotations(start)
    var end: Int
    switch item.kind {
    case .variable:
      if item.typeStart >= 0 { start = min(start, Int(item.typeStart)) }
      end = Int(item.nameToken) + 1
      if item.typeStart >= 0, Int(item.typeStart) < start { start = Int(item.typeStart) }
      let prefix = holder.text(from: start, to: Int(item.typeEnd >= 0 ? item.typeEnd : item.nameToken))
      return oneLine(String((prefix + " " + holder.string(Int(item.nameToken))).prefix(400)))
    case .enumCase:
      return holder.string(Int(item.nameToken))
    case .function, .initializer:
      end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
      if holder.isByte(end - 1, 0x3B) { end -= 1 }
    default:
      end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
    }
    guard start < end else { return holder.string(Int(max(item.nameToken, item.first))) }
    return oneLine(String(holder.text(from: start, to: end).prefix(400)))
  }

  /// A type as Java writes it.
  func describe(_ ty: Ty) -> String {
    switch ty {
    case .nominal(let ref, let args):
      let item = decl(ref)
      var text = item.name == 0 ? "" : unit(ref).string(Int(item.nameToken))
      if item.name == 0, item.inheritCount > 0 {
        let range = unit(ref).ranges[Int(item.inheritStart)]
        text = unit(ref).text(from: Int(range.start), to: Int(range.end))
      }
      if !args.isEmpty { text += "<" + args.map { $0 == .unknown ? "?" : describe($0) }.joined(separator: ", ") + ">" }
      return text
    case .constructed(let kind, let args):
      if kind == Ty.array { return describe(args.first ?? .unknown) + "[]" }
      if kind == Ty.union { return args.map(describe).joined(separator: " | ") }
      return JavaWord.primitiveNames[kind] ?? ""
    case .param(let word, let owner):
      if let owner {
        let holder = unit(owner)
        let item = decl(owner)
        for g in 0..<Int(item.genericCount) where holder.generics[Int(item.genericStart) + g].name == word {
          return holder.string(Int(holder.generics[Int(item.genericStart) + g].token))
        }
      }
      return ""
    case .meta(let inner): return describe(inner)
    case .module(let package): return packageNames[package] ?? ""
    default: return ""
    }
  }
}

extension JavaModel {
  /// As CodeModelBench's javac reference places it: a path relative to the root (`../x` outside it), the platform's
  /// `jdk:<qualified name>` and a dependency's `lib:<qualified name>` (line 1; a method `Class.name(<n>)`, a
  /// constructor `Class.<init>(<n>)`), `package:<name>`.
  public func place(of site: Site) -> (path: String, line: Int)? {
    if case .module(let package) = site {
      guard let text = packageNames[package] else { return nil }
      return ("package:" + text, 0)
    }
    if case .decl(let ref) = site {
      let holder = unit(ref)
      if let archived = layout.archived[holder.path] {
        guard let qualified = qualifiedName(ref) else { return nil }
        return ((archived.set.kind == .platform ? "jdk:" : "lib:") + qualified, 1)
      }
    }
    guard let at = project.location(of: site) else { return nil }
    let root = project.root.split(separator: "/")
    let parts = at.path.split(separator: "/")
    var common = 0
    while common < root.count, common < parts.count, root[common] == parts[common] { common += 1 }
    let relative = Array(repeating: "..", count: root.count - common) + parts[common...].map(String.init)
    return (relative.joined(separator: "/"), at.line + 1)
  }

  /// `java.util.Map.Entry`, `java.util.List.of(2)`, `java.lang.String.<init>(1)`.
  func qualifiedName(_ ref: DeclRef) -> String? {
    let holder = unit(ref)
    let item = decl(ref)
    var types: [String] = []
    var current = item.kind.isNominal ? ref.decl : item.parent
    while current >= 0 {
      let owner = holder.decls[Int(current)]
      guard owner.kind.isNominal, owner.name != 0 else { return nil }
      types.insert(holder.string(Int(owner.nameToken)), at: 0)
      current = owner.parent
    }
    guard !types.isEmpty else { return nil }
    let package = packageOf(ref.unit)
    let base = (package.isEmpty ? "" : package + ".") + types.joined(separator: ".")
    switch item.kind {
    case .function: return base + "." + holder.string(Int(item.nameToken)) + "(" + String(item.paramCount) + ")"
    case .initializer: return base + ".<init>(" + String(item.paramCount) + ")"
    case .variable, .enumCase: return base + "." + holder.string(Int(item.nameToken))
    default: return item.kind.isNominal ? base : nil
    }
  }

  /// Where a site is; a platform or dependency file is written out of its archive first.
  public func location(of site: Site) -> (path: String, line: Int, character: Int, name: String, preview: String)? {
    guard let found = project.location(of: site) else { return nil }
    if let archived = layout.archived[found.path] { _ = archived.set.materialize(archived.entry) }
    return found
  }
}
