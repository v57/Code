import CodeJavaModel
import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its declaration on one line, its Scaladoc's first paragraph, the templates
/// and package it's in, and a value's type.
extension ScalaModel {
  public func details(of site: Site) -> SymbolDetails? {
    switch site {
    case .decl(let ref):
      if isJava(ref) { return java.details(of: site) }
      let item = decl(ref)
      guard let symbol = part(ref) else { return nil }
      let holder = self.unit(ref)
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
      let ty = siteType(site)
      let name = nameText(holder, Int(token))
      let symbol = SymbolPart(
        kind: .parameter, name: name, keyword: "", path: at.path, line: at.line, character: at.character, module: packageOf(unitIndex),
        isSDK: project.isSDK(holder))
      let text = describe(ty)
      return SymbolDetails(
        symbol: symbol, declaration: name + (text.isEmpty ? "" : ": " + text), documentation: nil, parents: enclosingParts(unitIndex, token),
        type: typePart(ty))
    case .generic(let unitIndex, let token):
      if isJava(unitIndex) { return java.details(of: site) }
      let holder = project.units[Int(unitIndex)]
      guard let at = location(of: site) else { return nil }
      let symbol = SymbolPart(
        kind: .generic, name: nameText(holder, Int(token)), keyword: "", path: at.path, line: at.line, character: at.character,
        module: packageOf(unitIndex), isSDK: project.isSDK(holder))
      // `A <: Bound`, `+A`, as written.
      var end = Int(token) + 1
      while end < holder.tokens.count, !holder.isByte(end, 0x2C), !holder.isByte(end, 0x5D), end - Int(token) < 24 {
        if holder.tokens[end].kind == .open { break }
        end += 1
      }
      return SymbolDetails(
        symbol: symbol, declaration: oneLine(holder.text(from: Int(token), to: end)), documentation: nil, parents: enclosingParts(unitIndex, token),
        type: nil)
    case .module(let package):
      guard let text = packageNames[package] else { return nil }
      return SymbolDetails(symbol: packagePart(text, isSDK: false), declaration: "package " + text, documentation: nil, parents: [], type: nil)
    }
  }

  func part(_ ref: DeclRef) -> SymbolPart? {
    let item = decl(ref)
    if item.kind == .extensionDecl {
      return project.part(ref, name: "extension (" + oneLine(self.unit(ref).text(from: Int(item.typeStart), to: Int(item.typeEnd))) + ")", keyword: "")
    }
    guard item.name != 0, item.nameToken >= 0 else { return nil }
    let name = item.kind == .initializer ? "this" : nameText(self.unit(ref), Int(item.nameToken))
    return project.part(ref, name: item.kind == .function || item.kind == .initializer ? name + "()" : name, keyword: keyword(ref))
  }

  func keyword(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let f = flags(ref)
    switch item.kind {
    case .classType:
      if f.contains(.isGiven) { return "given" }
      if isObject(ref) { return f.contains(.isCase) ? "case object" : f.contains(.packageObject) ? "package object" : "object" }
      return f.contains(.isCase) ? "case class" : "class"
    case .protocolType: return "trait"
    case .enumeration: return "enum"
    case .enumCase: return "case"
    case .typeAlias: return "type"
    default: return ""
    }
  }

  func packagePart(_ package: String, isSDK: Bool) -> SymbolPart {
    SymbolPart(kind: .module, name: package, keyword: "package", path: nil, line: 0, character: 0, module: package, isSDK: isSDK)
  }

  func enclosingParts(_ unitIndex: Int32, _ token: Int32) -> [SymbolPart] {
    let holder = project.units[Int(unitIndex)]
    var parents: [SymbolPart] = []
    for index in holder.chain(at: token).reversed() {
      if let shown = part(DeclRef(unit: unitIndex, decl: index)) { parents.append(shown) }
    }
    parents.append(packagePart(packageOf(unitIndex), isSDK: project.isSDK(holder)))
    return parents
  }

  func typePart(_ ty: Ty) -> SymbolPart? {
    guard case .nominal(let ref, _) = ty, decl(ref).name != 0, !isJava(ref) else { return nil }
    return part(ref)
  }

  /// One line, without annotations or body: `def second[A](xs: List[A]): A`, `case class Point(x: Int, y: Int)`.
  func declaration(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = self.unit(ref)
    var start = Int(item.first)
    // Annotations before it.
    while start < Int(item.nameToken), holder.isByte(start, 0x40) {
      start += 2
      while start < holder.tokens.count, holder.isByte(start, 0x2E) { start += 2 }
      if holder.isByte(start, 0x28), let close = file(ref.unit)?.match[start], close > start { start = Int(close) + 1 }
    }
    var end: Int
    switch item.kind {
    case .variable:
      end = Int(item.typeEnd >= 0 ? item.typeEnd : item.nameToken + 1)
      if start >= end { return nameText(holder, Int(item.nameToken)) }
      var text = holder.text(from: start, to: end)
      if item.typeStart < 0 {
        let ty = describe(valueType(of: ref))
        if !ty.isEmpty { text += ": " + ty }
      }
      return oneLine(String(text.prefix(400)))
    case .function, .initializer:
      end = item.typeEnd >= 0 ? Int(item.typeEnd) : item.initStart >= 0 ? Int(item.initStart) - 1 : item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
      var text = holder.text(from: start, to: max(end, start + 1))
      if item.typeStart < 0, item.kind == .function {
        let ty = describe(valueType(of: ref))
        if !ty.isEmpty { text += ": " + ty }
      }
      return oneLine(String(text.prefix(400)))
    case .enumCase:
      end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
    default:
      let body = info(ref).bodyStart
      end = body >= 0 ? Int(body) : item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
    }
    guard start < end else { return nameText(holder, Int(max(item.nameToken, item.first))) }
    var text = oneLine(String(holder.text(from: start, to: end).prefix(400)))
    if text.hasSuffix(":") { text.removeLast() }
    return text.trimmingCharacters(in: .whitespaces)
  }

  /// A type as Scala writes it.
  func describe(_ ty: Ty) -> String {
    switch ty {
    case .nominal(let ref, let args):
      let item = decl(ref)
      var text = item.name == 0 ? "" : nameText(self.unit(ref), Int(item.nameToken))
      if !isJava(ref), let n = Self.tupleNames.firstIndex(of: item.name), n >= 2, args.count == n {
        return "(" + args.map(describe).joined(separator: ", ") + ")"
      }
      if !args.isEmpty { text += "[" + args.map { $0 == .unknown ? "?" : describe($0) }.joined(separator: ", ") + "]" }
      return text
    case .function(let params, let result):
      let left = params.count == 1 ? describe(params[0]) : "(" + params.map(describe).joined(separator: ", ") + ")"
      return left + " => " + describe(result)
    case .constructed(let kind, let args) where kind == Ty.union:
      return args.map(describe).joined(separator: " | ")
    case .param(let word, _): return names[word] ?? ""
    case .meta(let inner): return describe(inner)
    case .module(let package): return packageNames[package] ?? ""
    case .tuple(let elements, _): return "(" + elements.map(describe).joined(separator: ", ") + ")"
    default: return ""
    }
  }

  /// Where a site is; a library's file is written out of its archive (or the stub) first.
  public func location(of site: Site) -> (path: String, line: Int, character: Int, name: String, preview: String)? {
    guard let found = project.location(of: site) else { return nil }
    if let archived = layout.archived[found.path] { _ = archived.set.materialize(archived.entry) }
    return found
  }
}
