import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its line, the description above it (LuaLS's `---` lines, its `---@` tags
/// left out), its file and a value's type (a `---@class`'s name, `string`, `table`).
extension LuaModel {
  public func details(of site: Site) -> SymbolDetails? {
    refresh()
    switch site {
    case .decl(let ref):
      let holder = unit(ref)
      let item = decl(ref)
      guard let at = project.location(of: site), let assigned = field(ref) else { return nil }
      var text = holder.string(Int(item.nameToken))
      if holder.tokens[Int(item.nameToken)].kind == .string { text = LuaParser.literal(holder, Int(item.nameToken)) ?? text }
      let isGlobal = assigned.owner < 0 && assigned.table < 0
      let kind: SymbolPart.Kind = item.kind == .function ? .function : isGlobal ? .variable : .property
      let symbol = SymbolPart(
        kind: kind, name: holder.isInterface ? stdName(ref) : text, keyword: item.kind == .function ? "function" : "", path: at.path, line: at.line,
        character: at.character, module: moduleText(holder), isSDK: holder.isInterface)
      let value = declValueType(ref)
      return SymbolDetails(
        symbol: symbol, declaration: declaration(holder, Int(item.nameToken)), documentation: documentation(ref.unit, assigned.statement), parents: [filePart(holder)],
        type: typePart(value))
    case .local(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      guard let at = project.location(of: site), let file = luaFile(unitIndex) else { return nil }
      guard let local = file.locals[token] else {
        // A required file.
        let name = moduleText(holder)
        let symbol = SymbolPart(kind: .module, name: name, keyword: "file", path: at.path, line: 0, character: 0, module: name, isSDK: holder.isInterface)
        return SymbolDetails(symbol: symbol, declaration: name, documentation: nil, parents: [], type: nil)
      }
      let text = holder.string(Int(token))
      let kind: SymbolPart.Kind = local.kind == .parameter ? .parameter : local.kind == .function ? .function : .local
      let keyword = local.kind == .local || local.kind == .function ? "local" : local.kind == .label ? "::" : ""
      let symbol = SymbolPart(kind: kind, name: text, keyword: keyword, path: at.path, line: at.line, character: at.character, module: moduleText(holder), isSDK: false)
      let type = local.kind == .label ? LuaType.unknown : localType(unitIndex, token)
      let described = describe(type)
      var declaration = local.kind == .function ? self.declaration(holder, Int(token)) : (keyword == "local" ? "local " : "") + text
      if local.kind != .function, !described.isEmpty { declaration += ": " + described }
      let notes = local.kind == .local || local.kind == .function ? documentation(unitIndex, local.statement) : nil
      return SymbolDetails(symbol: symbol, declaration: declaration, documentation: notes, parents: [filePart(holder)], type: typePart(type))
    case .generic, .module:
      return nil
    }
  }

  /// A file's place: its path in the project, `lua` for the stub, else its path.
  func moduleText(_ holder: Unit) -> String {
    if holder.isInterface { return LuaLayout.stdModule }
    if holder.path.hasPrefix(project.root + "/") { return String(holder.path.dropFirst(project.root.count + 1)) }
    return holder.path
  }

  private func filePart(_ holder: Unit) -> SymbolPart {
    SymbolPart(kind: .module, name: moduleText(holder), keyword: "file", path: nil, line: 0, character: 0, module: moduleText(holder), isSDK: holder.isInterface)
  }

  /// The line a name is declared on, without a trailing comment.
  private func declaration(_ holder: Unit, _ token: Int) -> String {
    var text = holder.lineText(holder.source.lines.line(of: holder.tokens[token].start))
    if let comment = text.range(of: " --") { text = String(text[..<comment.lowerBound]) }
    return String(text.prefix(400))
  }

  /// The description above a statement: its `---` (or `--`) lines up to the first `---@` tag.
  func documentation(_ unitIndex: Int32, _ statement: Int32) -> String? {
    var paragraph: [String] = []
    for line in comments(above: statement, in: project.units[Int(unitIndex)]) {
      var text = line.drop { $0 == "-" }
      if text.hasPrefix("@") {
        if paragraph.isEmpty { continue }
        break
      }
      text = text.drop { $0 == " " }
      if text.isEmpty {
        if paragraph.isEmpty { continue }
        break
      }
      paragraph.append(String(text))
    }
    return paragraph.isEmpty ? nil : paragraph.joined(separator: " ")
  }

  func isDeprecated(_ ref: DeclRef) -> Bool {
    guard let item = field(ref) else { return false }
    return comments(above: item.statement, in: unit(ref)).contains { $0.hasPrefix("---@deprecated") }
  }

  /// A type as LuaLS writes it.
  func describe(_ type: LuaType, function ref: DeclRef? = nil) -> String {
    switch type {
    case .unknown, .path, .global: return ""
    case .string: return "string"
    case .number: return "number"
    case .boolean: return "boolean"
    case .named(let className): return className
    case .function(let unitIndex, let index):
      let result = describe(returnType(unitIndex, index, valueIndex: 0))
      return result.isEmpty ? "function" : "fun(): " + result
    case .table, .instance:
      if let className = classNames(of: type).first { return className }
      if case .instance(_, let metatable, _) = type, let className = classNames(of: metatable).first { return className }
      return "table"
    case .union(let parts):
      return parts.map { describe($0) }.filter { !$0.isEmpty }.joined(separator: " | ")
    }
  }

  /// A value's class, where a `---@class` names it.
  private func typePart(_ type: LuaType) -> SymbolPart? {
    var className = classNames(of: type).first
    if className == nil, case .instance(_, let metatable, _) = type { className = classNames(of: metatable).first }
    guard let className, let known = classes[className] else { return nil }
    let holder = project.units[Int(known.unit)]
    return SymbolPart(kind: .classType, name: className, keyword: "class", path: holder.path, line: known.line, character: 0, module: moduleText(holder), isSDK: holder.isInterface)
  }
}
