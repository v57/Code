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
      var declaration = isStubItem ? (keyword.isEmpty ? stubName(ref) : keyword + " " + stubName(ref)) : declarationLine(holder, item)
      var documentation = commentAbove(holder, Int(item.first))
      if dialect == .powerShell, !isStubItem {
        if parameter {
          // `[string]$Name`, its `.PARAMETER Name` in the function's (or script's) help, else a comment right above it.
          if let (first, last) = file(ref.unit)?.declaredTypes[ref.decl] {
            declaration = "[" + holder.source.string(from: holder.tokens[Int(first)].start, to: holder.tokens[Int(last)].end) + "]$" + text
          } else {
            declaration = "$" + text
          }
          let owner = item.parent >= 0 ? help(holder, function: holder.decls[Int(item.parent)]) : scriptHelp(holder)
          documentation = owner?["parameter " + text.lowercased()] ?? plainCommentAbove(holder, Int(item.nameToken))
        } else if item.kind == .function, let found = help(holder, function: item) {
          documentation = found["synopsis"] ?? found["description"] ?? found[""]
        }
      }
      return SymbolDetails(symbol: symbol, declaration: declaration, documentation: documentation, parents: [filePart(holder)], type: nil)
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
    let hasBody = item.kind == .function || item.kind == .classType || item.kind == .enumeration
    let stop = hasBody && item.bodyOpen >= 0 && Int(item.bodyOpen) < holder.tokens.count ? holder.tokens[Int(item.bodyOpen)].start : bytes.count
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

  // MARK: PowerShell's comment-based help

  /// A function's help: the `<# … #>` block right above it or first in its body, by section (`synopsis`,
  /// `parameter name`; "" for text before any section).
  func help(_ holder: Unit, function item: Decl) -> [String: String]? {
    let comments = holder.source.tokens
    if item.bodyOpen >= 0, Int(item.bodyOpen) < holder.tokens.count {
      let open = holder.tokens[Int(item.bodyOpen)].end
      if let first = comments.first(where: { $0.start >= open }), first.kind == .comment || first.kind == .docComment {
        let text = holder.source.string(from: first.start, to: first.end)
        if text.hasPrefix("<#") { return Self.helpSections(text) }
      }
    }
    let statement = Int(item.first >= 0 ? item.first : item.nameToken)
    guard statement < holder.tokens.count else { return nil }
    let start = holder.tokens[statement].start
    if let above = comments.last(where: { $0.end <= start }), above.kind == .comment || above.kind == .docComment {
      let text = holder.source.string(from: above.start, to: above.end)
      let between = holder.source.string(from: above.end, to: start)
      if text.hasPrefix("<#"), between.filter({ $0 == "\n" }).count <= 1 { return Self.helpSections(text) }
    }
    return nil
  }

  /// The script's help: a `<# … #>` block before its first code.
  func scriptHelp(_ holder: Unit) -> [String: String]? {
    let start = holder.tokens.first?.start ?? holder.source.count
    for token in holder.source.tokens where token.start < start {
      guard token.kind == .comment || token.kind == .docComment else { continue }
      let text = holder.source.string(from: token.start, to: token.end)
      if text.hasPrefix("<#") { return Self.helpSections(text) }
    }
    return nil
  }

  /// A `<# … #>` block's sections, each its first paragraph.
  static func helpSections(_ text: String) -> [String: String] {
    var body = text
    if body.hasPrefix("<#") { body.removeFirst(2) }
    if body.hasSuffix("#>") { body.removeLast(2) }
    var sections: [String: String] = [:]
    var key = ""
    var paragraph: [String] = []
    var done = false
    func flush() {
      if !paragraph.isEmpty, sections[key] == nil { sections[key] = paragraph.joined(separator: " ") }
      paragraph = []
    }
    for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("."), let first = line.dropFirst().first, first.isLetter {
        flush()
        let words = line.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
        key = words[0].lowercased() + (words.count > 1 ? " " + words[1].trimmingCharacters(in: .whitespaces).lowercased() : "")
        done = false
        continue
      }
      if line.isEmpty {
        if !paragraph.isEmpty { done = true }
        continue
      }
      if !done { paragraph.append(line) } else { flush() }
    }
    flush()
    return sections
  }

  /// `#` lines right above a token, not a `<# … #>` block (a parameter's own note).
  private func plainCommentAbove(_ holder: Unit, _ token: Int) -> String? {
    guard token >= 0, token < holder.tokens.count else { return nil }
    let line = holder.source.lines.line(of: holder.tokens[token].start) - 1
    guard line >= 0, holder.lineText(line).hasPrefix("#"), !holder.lineText(line).hasSuffix("#>") else { return nil }
    return commentAbove(holder, token)
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
