import CodeJavaModel
import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its declaration on one line, its KDoc's first paragraph, the classes and
/// package it's in, and a value's type.
extension KotlinModel {
  public func details(of site: Site) -> SymbolDetails? {
    switch site {
    case .decl(let ref):
      if isJava(ref) { return java.details(of: site) }
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
      if isJava(unitIndex) { return java.details(of: site) }
      let holder = project.units[Int(unitIndex)]
      guard let at = location(of: site) else { return nil }
      var isParameter = holder.isByte(Int(token), 0x7B)
      for item in holder.decls {
        for p in 0..<Int(item.paramCount) where holder.params[Int(item.paramStart) + p].nameToken == token { isParameter = true }
      }
      if let body = body(unitIndex: unitIndex, token: token), let index = body.byToken[token] {
        if case .lambda = body.locals[Int(index)].kind { isParameter = true }
      }
      let ty = localSiteType(unitIndex: unitIndex, token: token)
      let name = holder.isByte(Int(token), 0x7B) ? "it" : holder.string(Int(token))
      let symbol = SymbolPart(
        kind: isParameter ? .parameter : .local, name: name, keyword: "", path: at.path, line: at.line, character: at.character,
        module: packageOf(unitIndex), isSDK: project.isSDK(holder))
      let text = describe(ty)
      return SymbolDetails(
        symbol: symbol, declaration: isParameter ? name + (text.isEmpty ? "" : ": " + text) : "val " + name + (text.isEmpty ? "" : ": " + text), documentation: nil,
        parents: enclosingParts(unitIndex, token), type: typePart(ty))
    case .generic(let unitIndex, let token):
      if isJava(unitIndex) { return java.details(of: site) }
      let holder = project.units[Int(unitIndex)]
      guard let at = location(of: site) else { return nil }
      let symbol = SymbolPart(
        kind: .generic, name: holder.string(Int(token)), keyword: "", path: at.path, line: at.line, character: at.character,
        module: packageOf(unitIndex), isSDK: project.isSDK(holder))
      var declaration = symbol.name
      if let found = bound(of: typeOfSite(site, args: [])) { declaration += " : " + describe(found) }
      return SymbolDetails(symbol: symbol, declaration: declaration, documentation: nil, parents: enclosingParts(unitIndex, token), type: nil)
    case .module(let package):
      guard let text = packageNames[package] else { return nil }
      return SymbolDetails(symbol: packagePart(text, isSDK: false), declaration: "package " + text, documentation: nil, parents: [], type: nil)
    }
  }

  private func part(_ ref: DeclRef) -> SymbolPart? {
    let item = decl(ref)
    if item.kind == .extensionDecl { return nil }
    if item.name == 0 {
      // An anonymous object: shown as what it extends.
      guard item.kind == .classType, item.inheritCount > 0 else { return nil }
      let range = unit(ref).ranges[Int(item.inheritStart)]
      return project.part(ref, name: "object : " + unit(ref).text(from: Int(range.start), to: Int(range.end)), keyword: "")
    }
    guard item.nameToken >= 0 else { return nil }
    let name = item.kind == .initializer ? unit(ref).string(Int(decl(DeclRef(unit: ref.unit, decl: item.parent)).nameToken)) : item.kind == .classType && isCompanion(ref) && unit(ref).isToken(Int(item.nameToken), "object") ? "Companion" : unit(ref).string(Int(item.nameToken))
    return project.part(ref, name: item.kind == .function || item.kind == .initializer ? name + "()" : name, keyword: keyword(ref))
  }

  private func keyword(_ ref: DeclRef) -> String {
    let item = decl(ref)
    switch item.kind {
    case .classType:
      if isCompanion(ref) { return "companion object" }
      if isObject(ref) { return "object" }
      return isDataClass(ref) ? "data class" : "class"
    case .protocolType: return "interface"
    case .enumeration: return "enum class"
    case .typeAlias: return "typealias"
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
    guard case .nominal(let ref, _) = ty, decl(ref).name != 0 else { return nil }
    if isJava(ref) { return nil }
    return part(ref)
  }

  /// One line, without annotations: `fun <T> List<T>.second(): T`, `data class Point(val x: Int, val y: Int)`.
  private func declaration(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    var start = holder.ktSkipAnnotations(Int(item.first))
    var end: Int
    switch item.kind {
    case .enumCase:
      return holder.string(Int(item.nameToken))
    case .variable:
      if holder.isToken(Int(item.nameToken) - 1, "val") || holder.isToken(Int(item.nameToken) - 1, "var") { start = min(start, Int(item.nameToken) - 1) }
      end = Int(item.typeEnd >= 0 ? item.typeEnd : item.nameToken + 1)
      if start >= end { return holder.string(Int(item.nameToken)) }
      var text = holder.text(from: start, to: end)
      if item.typeStart < 0 {
        let ty = describe(valueType(of: ref))
        if !ty.isEmpty { text += ": " + ty }
      }
      return oneLine(String(text.prefix(400)))
    case .function, .initializer:
      end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : item.initStart >= 0 ? Int(item.initStart) - 1 : Int(item.end)
    default:
      end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
    }
    guard start < end else { return holder.string(Int(max(item.nameToken, item.first))) }
    return oneLine(String(holder.text(from: start, to: end).prefix(400)))
  }

  /// A type as Kotlin writes it.
  func describe(_ ty: Ty) -> String {
    switch ty {
    case .nominal(let ref, let args):
      let item = decl(ref)
      var text = item.name == 0 ? "" : unit(ref).string(Int(item.nameToken))
      if item.name == 0, item.inheritCount > 0 {
        let range = unit(ref).ranges[Int(item.inheritStart)]
        text = unit(ref).text(from: Int(range.start), to: Int(range.end))
      }
      if !args.isEmpty { text += "<" + args.map { $0 == .unknown ? "*" : describe($0) }.joined(separator: ", ") + ">" }
      return text
    case .function(let params, let result):
      return "(" + params.map(describe).joined(separator: ", ") + ") -> " + describe(result)
    case .constructed(let kind, let args) where kind == KotlinTy.receiverFunction && args.count == 2:
      return describe(args[0]) + "." + describe(args[1])
    case .param(let word, let owner):
      if let owner {
        let holder = unit(owner)
        let item = decl(owner)
        for g in 0..<Int(item.genericCount) where holder.generics[Int(item.genericStart) + g].name == word {
          return holder.string(Int(holder.generics[Int(item.genericStart) + g].token))
        }
      }
      return names[word] ?? ""
    case .meta(let inner): return describe(inner)
    case .module(let package): return packageNames[package] ?? ""
    default: return ""
    }
  }
}

extension KotlinModel {
  /// As CodeModelBench's Kotlin compiler reference places it: a path relative to the root (`../x` outside it), a
  /// library's declaration by qualified name, `kotlin:` for the standard library, `jdk:` for the JDK and Android, `lib:`
  /// for other libraries (line 1; a function `Owner.name(<n>)`, an extension's owner its package and its receiver's
  /// class name, a constructor `Class.<init>(<n>)`), `package:<name>`.
  public func place(of site: Site) -> (path: String, line: Int)? {
    if case .module(let package) = site {
      guard let text = packageNames[package] else { return nil }
      return ("package:" + text, 0)
    }
    if case .decl(let ref) = site, layout.archived[unit(ref).path] != nil {
      guard var qualified = isJava(ref) ? java.qualifiedName(ref) : qualifiedName(ref) else { return nil }
      if let property = mappedPropertyName(ref), let dot = qualified.lastIndex(of: ".") { qualified = qualified[..<dot] + "." + property }
      return (Self.libraryPrefix(qualified) + qualified, 1)
    }
    guard let at = project.location(of: site) else { return nil }
    let root = project.root.split(separator: "/")
    let parts = at.path.split(separator: "/")
    var common = 0
    while common < root.count, common < parts.count, root[common] == parts[common] { common += 1 }
    let relative = Array(repeating: "..", count: root.count - common) + parts[common...].map(String.init)
    return (relative.joined(separator: "/"), at.line + 1)
  }

  static func libraryPrefix(_ qualified: String) -> String {
    if qualified.hasPrefix("kotlin.") { return "kotlin:" }
    for prefix in ["java.", "javax.", "android.", "dalvik.", "org.json.", "org.w3c.", "org.xml."] where qualified.hasPrefix(prefix) { return "jdk:" }
    return "lib:"
  }

  /// `kotlin.collections.List`, `kotlin.collections.Iterable.map(1)`, `kotlin.text.StringBuilder.<init>(0)`.
  func qualifiedName(_ ref: DeclRef) -> String? {
    let holder = unit(ref)
    let item = decl(ref)
    var owners: [String] = []
    var current = item.kind.isNominal ? ref.decl : item.parent
    var receiver: String?
    while current >= 0 {
      let owner = holder.decls[Int(current)]
      if owner.kind == .extensionDecl {
        receiver = holder.string(Int(owner.nameToken))
        current = owner.parent
        continue
      }
      guard owner.kind.isNominal || owner.kind == .enumCase else { return nil }
      let ownerRef = DeclRef(unit: ref.unit, decl: current)
      owners.insert(owner.name == 0 ? "" : isCompanion(ownerRef) && holder.isToken(Int(owner.nameToken), "object") ? "Companion" : holder.string(Int(owner.nameToken)), at: 0)
      current = owner.parent
    }
    let package = packageOf(ref.unit)
    var base = package
    if !owners.isEmpty { base += (base.isEmpty ? "" : ".") + owners.joined(separator: ".") }
    if let receiver, owners.isEmpty || item.kind.isNominal == false && holder.decls[Int(item.parent)].kind == .extensionDecl { base += (base.isEmpty ? "" : ".") + receiver }
    switch item.kind {
    case .function: return base + "." + holder.string(Int(item.nameToken)) + "(" + String(item.paramCount) + ")"
    case .initializer: return base + ".<init>(" + String(item.paramCount) + ")"
    case .variable, .enumCase, .typeAlias: return base + "." + holder.string(Int(item.nameToken))
    default: return item.kind.isNominal ? base : nil
    }
  }

  /// Where a site is; a library's file is written out of its archive (or the stub) first.
  public func location(of site: Site) -> (path: String, line: Int, character: Int, name: String, preview: String)? {
    guard let found = project.location(of: site) else { return nil }
    if let archived = layout.archived[found.path] { _ = archived.set.materialize(archived.entry) }
    return found
  }
}
