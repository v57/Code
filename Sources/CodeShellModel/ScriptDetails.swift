import CodeModel
import CodeScan
import Foundation

/// What a symbol is, for the symbol menu: its line (a function's up to its body), the `#` comment right above it (a
/// stub builtin's one-line description), its file; a sourced or autoloaded file as itself.
extension ScriptModel {
  public func details(of site: Site) -> SymbolDetails? {
    refresh()
    switch site {
    case .decl(let ref):
      let holder = unit(ref)
      let item = decl(ref)
      guard let at = project.location(of: site) else { return nil }
      let text = holder.string(Int(item.nameToken))
      let isStubItem = holder.isInterface
      let parameter = file(ref.unit)?.parameters.contains(ref.decl) ?? false
      let kind: SymbolPart.Kind
      var keyword = ""
      switch item.kind {
      case .function:
        kind = .function
        keyword = isStubItem ? (dialect == .shell ? "builtin" : "cmdlet") : "function"
      case .typeAlias:
        kind = .typeAlias
        keyword = dialect == .shell ? "alias" : "Set-Alias"
      case .classType:
        kind = .classType
        keyword = "class"
      case .enumeration:
        kind = .enumeration
        keyword = "enum"
      default:
        if parameter {
          kind = .parameter
        } else if item.isLocal {
          kind = .local
          keyword = dialect == .shell ? "local" : ""
        } else {
          kind = item.parent >= 0 && holder.decls[Int(item.parent)].kind != .function ? .property : .variable
        }
      }
      let symbol = SymbolPart(
        kind: kind, name: isStubItem ? stubName(ref) : text, keyword: keyword, path: at.path, line: at.line, character: at.character,
        module: moduleText(holder), isSDK: isStubItem)
      let declaration = isStubItem ? (keyword.isEmpty ? stubName(ref) : keyword + " " + stubName(ref)) : declarationLine(holder, item)
      return SymbolDetails(
        symbol: symbol, declaration: declaration, documentation: commentAbove(holder, Int(item.first)), parents: [filePart(holder)], type: nil)
    case .local(let unitIndex, let token) where token < 0:
      let holder = project.units[Int(unitIndex)]
      let name = moduleText(holder)
      let symbol = SymbolPart(kind: .module, name: name, keyword: "file", path: holder.path, line: 0, character: 0, module: name, isSDK: holder.isInterface)
      return SymbolDetails(symbol: symbol, declaration: name, documentation: headerComment(holder), parents: [], type: nil)
    case .local, .generic, .module:
      return nil
    }
  }

  /// A file's place: its path in the project, the stub's module name, else its path.
  func moduleText(_ holder: Unit) -> String {
    if holder.isInterface { return dialect.stubModule }
    if holder.path.hasPrefix(project.root + "/") { return String(holder.path.dropFirst(project.root.count + 1)) }
    return holder.path
  }

  private func filePart(_ holder: Unit) -> SymbolPart {
    SymbolPart(kind: .module, name: moduleText(holder), keyword: "file", path: nil, line: 0, character: 0, module: moduleText(holder), isSDK: holder.isInterface)
  }

  /// The declaration's line from its statement, up to a function's body, without a trailing comment.
  private func declarationLine(_ holder: Unit, _ item: Decl) -> String {
    let first = Int(item.first >= 0 && Int(item.first) < holder.tokens.count ? item.first : item.nameToken)
    let start = holder.tokens[first].start
    var end = start
    let bytes = holder.source.bytes
    let stop = item.kind == .function && item.bodyOpen >= 0 && Int(item.bodyOpen) < holder.tokens.count ? holder.tokens[Int(item.bodyOpen)].start : bytes.count
    while end < bytes.count, end < stop, bytes[end] != 0x0A { end += 1 }
    var text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
    if let comment = text.range(of: " #") { text = String(text[..<comment.lowerBound]) }
    return String(text.trimmingCharacters(in: .whitespaces).prefix(400))
  }

  /// The paragraph of `#` comment lines right above a token's line (PowerShell's `<# … #>` too), without the shebang
  /// and linter directives.
  func commentAbove(_ holder: Unit, _ token: Int) -> String? {
    guard token >= 0, token < holder.tokens.count else { return nil }
    var line = holder.source.lines.line(of: holder.tokens[token].start) - 1
    var lines: [String] = []
    if line >= 0, holder.lineText(line).hasSuffix("#>") {
      while line >= 0 {
        var current = holder.lineText(line)
        let opens = current.hasPrefix("<#")
        if current.hasSuffix("#>") { current.removeLast(2) }
        if opens { current.removeFirst(2) }
        lines.insert(current.trimmingCharacters(in: .whitespaces), at: 0)
        if opens { break }
        line -= 1
      }
    } else {
      while line >= 0 {
        let current = holder.lineText(line)
        guard current.hasPrefix("#"), !current.hasPrefix("#!"), !current.hasPrefix("#requires") else { break }
        lines.insert(String(current.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces), at: 0)
        line -= 1
      }
    }
    var paragraph: [String] = []
    for text in lines {
      if text.hasPrefix("shellcheck ") || text.hasPrefix("region") || text.hasPrefix("endregion") { continue }
      if text.isEmpty || text.hasPrefix(".") && text.dropFirst().first?.isUppercase == true {
        if paragraph.isEmpty { continue }
        break
      }
      paragraph.append(text)
    }
    return paragraph.isEmpty ? nil : paragraph.joined(separator: " ")
  }

  /// A file's opening comment, after its shebang.
  private func headerComment(_ holder: Unit) -> String? {
    var paragraph: [String] = []
    var line = 0
    while line < 40, holder.source.lines.offset(line: line, character: 0, in: holder.source.text) < holder.source.count {
      let text = holder.lineText(line)
      line += 1
      if text.hasPrefix("#!") || text.hasPrefix("# shellcheck") { continue }
      guard text.hasPrefix("#") else { break }
      let body = String(text.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
      if body.isEmpty {
        if paragraph.isEmpty { continue }
        break
      }
      paragraph.append(body)
    }
    return paragraph.isEmpty ? nil : paragraph.joined(separator: " ")
  }
}
