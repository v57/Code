import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its declaration on one line (`def f(a: int) -> str`, `class A(B)`,
/// `x: int`), its docstring's first paragraph, what it's in (a method's class, out to its module) and a value's type.
extension PyModel {
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
      parents.append(modulePart(holder))
      var type: SymbolPart?
      var inferred: String?
      if item.kind == .variable {
        let ty = siteType(site)
        type = typePart(ty)
        if !isUnknown(ty) { inferred = describe(ty) }
      }
      return SymbolDetails(symbol: symbol, declaration: declaration(ref, inferred: inferred), documentation: docstring(ref), parents: parents, type: type)
    case .local(let unitIndex, let token), .generic(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = location(of: site) else { return nil }
      let ty = siteType(site)
      let isParameter = file(holder).byToken[token].map { file(holder).bindings[Int($0)].kind == .parameter } ?? false
      let name = holder.string(Int(token))
      let symbol = SymbolPart(
        kind: isParameter ? .parameter : .local, name: name, keyword: "", path: at.path, line: at.line, character: at.character,
        module: moduleLabel(holder), isSDK: project.isSDK(holder))
      var text = name
      if !isUnknown(ty) { text += ": " + describe(ty) }
      var parents: [SymbolPart] = []
      for index in holder.chain(at: token).reversed() {
        if let shown = part(DeclRef(unit: unitIndex, decl: index)) { parents.append(shown) }
      }
      parents.append(modulePart(holder))
      return SymbolDetails(symbol: symbol, declaration: text, documentation: nil, parents: parents, type: typePart(ty))
    case .module(let moduleName):
      guard let module = project.modules[moduleName] else { return nil }
      guard let first = primaryUnit(module) else {
        let label = PyModel.moduleWord(module.displayName)
        let shown = SymbolPart(kind: .module, name: label, keyword: "module", path: nil, line: 0, character: 0, module: label, isSDK: false)
        return SymbolDetails(symbol: shown, declaration: "namespace package " + label, documentation: nil, parents: [], type: nil)
      }
      let holder = project.units[Int(first)]
      let shown = modulePart(holder)
      var documentation: String?
      if let token = file(holder).docstrings[-1] { documentation = firstParagraph(holder.pyStringValue(Int(token))) }
      return SymbolDetails(symbol: shown, declaration: "module " + shown.name, documentation: documentation, parents: [], type: nil)
    }
  }

  private func part(_ ref: DeclRef) -> SymbolPart? {
    let item = decl(ref)
    guard item.nameToken >= 0, item.name != 0 else { return nil }
    var name = unit(ref).string(Int(item.nameToken))
    if item.kind == .function { name += "()" }
    return project.part(ref, name: name, keyword: keyword(ref))
  }

  private func keyword(_ ref: DeclRef) -> String {
    switch decl(ref).kind {
    case .function: return (file(ref.unit).decorations[ref.decl] ?? []).contains(.isAsync) ? "async def" : "def"
    case .classType: return "class"
    default: return ""
    }
  }

  private func modulePart(_ holder: Unit) -> SymbolPart {
    SymbolPart(kind: .module, name: moduleLabel(holder), keyword: "module", path: holder.path, line: 0, character: 0, module: moduleLabel(holder), isSDK: project.isSDK(holder))
  }

  private func typePart(_ ty: Ty) -> SymbolPart? {
    switch ty {
    case .nominal(let ref, _), .meta(.nominal(let ref, _)):
      guard decl(ref).kind == .classType else { return nil }
      return part(ref)
    default:
      return nil
    }
  }

  /// One line: the header up to its `:`, an attribute's annotation or inferred type.
  private func declaration(_ ref: DeclRef, inferred: String?) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    switch item.kind {
    case .function, .classType:
      var start = Int(item.first)
      // Decorators aren't part of it.
      while start < Int(item.nameToken), holder.isByte(start, 0x40) {
        let line = file(holder).lines.line(of: start)
        start = file(holder).lines.end(of: line)
      }
      var end = item.bodyOpen >= 0 ? Int(item.bodyOpen) : Int(item.end)
      if end > start, holder.isByte(end - 1, 0x3A) { end -= 1 }
      return String(holder.text(from: start, to: max(start, end)).prefix(400))
    default:
      var text = holder.string(Int(item.nameToken))
      if let index = file(holder).bindingOfDecl[ref.decl], case let binding = file(holder).bindings[Int(index)], binding.annotationStart >= 0 {
        text += ": " + holder.text(from: Int(binding.annotationStart), to: Int(binding.annotationEnd))
      } else if let inferred {
        text += ": " + inferred
      }
      return String(text.prefix(400))
    }
  }

  /// A definition's docstring's first paragraph; a class without one, its `__init__`'s.
  func docstring(_ ref: DeclRef) -> String? {
    let holder = unit(ref)
    if let token = file(holder).docstrings[ref.decl] { return firstParagraph(holder.pyStringValue(Int(token))) }
    if decl(ref).kind == .classType {
      for child in holder.children(of: ref.decl) where holder.decls[Int(child)].name == PyWord.initName {
        if let token = file(holder).docstrings[child] { return firstParagraph(holder.pyStringValue(Int(token))) }
      }
    }
    return nil
  }

  private func firstParagraph(_ text: String) -> String? {
    var lines: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        if lines.isEmpty { continue }
        break
      }
      lines.append(trimmed)
    }
    return lines.isEmpty ? nil : String(lines.joined(separator: " ").prefix(600))
  }

  /// A file's module as an import names it: dotted from its root (the project's, the standard library's, the
  /// environment's), `builtins` for the stubs'.
  func moduleLabel(_ holder: Unit) -> String {
    let stubs = PyModel.stubDirectory
    var path = holder.path
    if path.hasPrefix(stubs) { return String(path.dropFirst(stubs.count).dropLast(4)) }
    var base = ""
    for candidate in layout.roots + [layout.stdlib, layout.sitePackages].compactMap({ $0 }) where path.hasPrefix(candidate + "/") && candidate.count > base.count {
      base = candidate
    }
    guard !base.isEmpty else { return ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    path = String(path.dropFirst(base.count + 1))
    path = (path as NSString).deletingPathExtension
    if path.hasSuffix("/__init__") { path = String(path.dropLast(9)) }
    return path.replacingOccurrences(of: "/", with: ".")
  }

  /// A type as Python writes it: `list[int]`, `type[A]`, `int | None`, `tuple[str, int]`.
  func describe(_ ty: Ty) -> String {
    switch ty {
    case .nominal(let ref, let args):
      var text = unit(ref).string(Int(decl(ref).nameToken))
      if decl(ref).kind == .function { return "def " + text + "(…)" }
      let shown = args.filter { !isUnknown($0) || args.count > 1 }
      if !shown.isEmpty { text += "[" + args.map(describe).joined(separator: ", ") + "]" }
      return text
    case .meta(let inner): return "type[" + describe(inner) + "]"
    case .tuple(let items, _): return "tuple[" + items.map(describe).joined(separator: ", ") + "]"
    case .module(let moduleName):
      guard let module = project.modules[moduleName], let first = primaryUnit(module) else { return "module" }
      return "module " + moduleLabel(project.units[Int(first)])
    case .constructed(let kind, let parts):
      if kind == Ty.union { return parts.map(describe).joined(separator: " | ") }
      if ty == PyTy.none { return "None" }
      if kind == PyTy.superKind { return "super" }
      return "Any"
    default: return "Any"
    }
  }
}
