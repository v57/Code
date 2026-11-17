import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its declaration's line, the first paragraph of the comment above it (YARD's
/// tags left out), the classes and modules it's in, and a value's type (as RBS writes types).
extension RubyModel {
  public func details(of site: Site) -> SymbolDetails? {
    switch site {
    case .decl(let ref):
      let item = decl(ref)
      guard let symbol = part(ref) else { return nil }
      let holder = unit(ref)
      var parents: [SymbolPart] = []
      var parent = item.parent
      while parent >= 0 {
        let other = DeclRef(unit: ref.unit, decl: parent)
        if isNamespaceLike(other), let shown = part(other) { parents.append(shown) }
        parent = holder.decls[Int(parent)].parent
      }
      parents.append(filePart(holder))
      var type: SymbolPart?
      if item.kind == .variable || item.kind == .function { type = typePart(valueType(of: ref)) }
      return SymbolDetails(symbol: symbol, declaration: declaration(ref), documentation: documentation(ref), parents: parents, type: type)
    case .local(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = project.location(of: site) else { return nil }
      if token == 0, !holder.rbIsIdentifier(0) || holder.rbIsConstant(0) {
        // A required file.
        let name = (holder.path as NSString).lastPathComponent
        let symbol = SymbolPart(kind: .module, name: name, keyword: "file", path: at.path, line: 0, character: 0, module: moduleText(holder), isSDK: project.isSDK(holder))
        return SymbolDetails(symbol: symbol, declaration: name, documentation: nil, parents: [], type: nil)
      }
      let text = holder.string(Int(token))
      let ty: Ty
      let kind: SymbolPart.Kind
      if holder.rbIsIvar(Int(token)) || holder.rbIsCvar(Int(token)) || holder.rbIsGlobal(Int(token)) {
        let variable: VariableKind = holder.rbIsGlobal(Int(token)) ? .global : holder.rbIsCvar(Int(token)) ? .classLevel : .instance
        ty = variableType(unitIndex: unitIndex, token: Int(token), kind: variable)
        kind = variable == .global ? .variable : .property
      } else {
        ty = localType(unitIndex: unitIndex, definition: token, at: Int(token) + 1)
        kind = isParameter(unitIndex: unitIndex, token: token) ? .parameter : .local
      }
      let symbol = SymbolPart(kind: kind, name: text, keyword: "", path: at.path, line: at.line, character: at.character, module: moduleText(holder), isSDK: project.isSDK(holder))
      var parents: [SymbolPart] = []
      for index in holder.chain(at: token).reversed() {
        if let shown = part(DeclRef(unit: unitIndex, decl: index)) { parents.append(shown) }
      }
      parents.append(filePart(holder))
      let described = describe(ty)
      return SymbolDetails(symbol: symbol, declaration: described.isEmpty ? text : text + ": " + described, documentation: nil, parents: parents, type: typePart(ty))
    case .generic, .module:
      return nil
    }
  }

  /// Whether a local's first binding is a method's or block's parameter.
  func isParameter(unitIndex: Int32, token: Int32) -> Bool {
    guard let first = body(unitIndex).bindings[token]?.first else { return false }
    switch first.how {
    case .parameter, .blockParameter: return true
    default: return false
    }
  }

  /// A file's place: its path in the project, `ruby` for the stub, else the file's name.
  func moduleText(_ holder: Unit) -> String {
    if holder.isInterface { return RubyLayout.stdModule }
    if holder.path.hasPrefix(project.root + "/") { return String(holder.path.dropFirst(project.root.count + 1)) }
    return (holder.path as NSString).lastPathComponent
  }

  private func filePart(_ holder: Unit) -> SymbolPart {
    SymbolPart(kind: .module, name: moduleText(holder), keyword: "file", path: nil, line: 0, character: 0, module: moduleText(holder), isSDK: project.isSDK(holder))
  }

  private func part(_ ref: DeclRef) -> SymbolPart? {
    let item = decl(ref)
    guard item.nameToken >= 0 else { return nil }
    let holder = unit(ref)
    var name = holder.rbLiteral(Int(item.nameToken)) ?? holder.string(Int(item.nameToken))
    if isNamespaceLike(ref) { name = qualifiedName(ref) }
    return project.part(ref, name: name, keyword: keyword(ref))
  }

  private func keyword(_ ref: DeclRef) -> String {
    let item = decl(ref)
    switch item.kind {
    case .classType: return "class"
    case .namespace: return "module"
    case .function, .initializer: return item.isStatic ? "def self." : "def"
    case .variable:
      if Self.isConstant(item) { return "" }
      let holder = unit(ref)
      var k = Int(item.nameToken) - 1
      while k >= 0, !holder.startsLine(k + 1) || k == Int(item.nameToken) - 1 {
        if holder.tokens[k].kind == .identifier, holder.string(k).hasPrefix("attr") { return holder.string(k) }
        k -= 1
      }
      return ""
    default: return ""
    }
  }

  /// The declaration's line: `def find(id, scope: nil)`, `class User < Record`, `attr_reader :name`.
  private func declaration(_ ref: DeclRef) -> String {
    let item = decl(ref)
    let holder = unit(ref)
    let line = holder.source.lines.line(of: holder.tokens[Int(item.nameToken)].start)
    var text = holder.lineText(line)
    if let hash = text.range(of: " # ") { text = String(text[..<hash.lowerBound]) }
    return String(text.prefix(400))
  }

  /// The comment above a declaration, to its first blank line or YARD tag.
  func documentation(_ ref: DeclRef) -> String? {
    let holder = unit(ref)
    var first = Int(decl(ref).first)
    let line = holder.source.lines.line(of: holder.tokens[first].start)
    while first > 0, holder.source.lines.line(of: holder.tokens[first - 1].start) == line { first -= 1 }
    if let sig = sigStart(holder, first) { first = sig }
    var paragraph: [String] = []
    for text in holder.rbCommentLines(above: first) {
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("@") || trimmed.hasPrefix("rubocop:") || trimmed.hasPrefix("frozen_string_literal") || trimmed.hasPrefix("typed:") {
        if paragraph.isEmpty { continue }
        break
      }
      if trimmed.isEmpty {
        if paragraph.isEmpty { continue }
        break
      }
      paragraph.append(trimmed)
    }
    return paragraph.isEmpty ? nil : paragraph.joined(separator: " ")
  }

  /// A method's result, an attribute's or a constant's value.
  func valueType(of ref: DeclRef) -> Ty {
    let item = decl(ref)
    if Self.isConstant(item) { return constantValueType(ref) }
    return returnType(ref, receiver: .unknown)
  }

  /// A type as RBS writes it: `String`, `Array[Integer]`, `singleton(User)`, `String | Symbol`, `Integer?`.
  func describe(_ ty: Ty) -> String {
    switch ty {
    case .nominal(let ref, let args):
      var text = qualifiedName(ref)
      if !args.isEmpty { text += "[" + args.map { describe($0).isEmpty ? "untyped" : describe($0) }.joined(separator: ", ") + "]" }
      return text
    case .meta(let inner):
      let text = describe(inner)
      return text.isEmpty ? "" : "singleton(" + text + ")"
    case .optional(let inner):
      let text = describe(inner)
      return text.isEmpty ? "" : text.contains(" ") ? "(" + text + ")?" : text + "?"
    case .constructed(let kind, let parts) where kind == Ty.union:
      let texts = parts.map(describe)
      return texts.contains("") ? "" : texts.joined(separator: " | ")
    case .selfType: return "self"
    default: return ""
    }
  }

  private func typePart(_ ty: Ty) -> SymbolPart? {
    var base = ty
    if case .optional(let inner) = base { base = inner }
    if case .meta(let inner) = base { base = inner }
    guard case .nominal(let ref, _) = base else { return nil }
    return part(ref)
  }
}
