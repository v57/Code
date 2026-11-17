import CodeModel
import CodeScan
import Foundation

/// Completion: after `$`, `${` (and `${#`, `${!`) and on a name the parser read as a variable, the variables in scope
/// (the function's own locals declared before, locals of the functions that call it, the program's variables, the
/// stub's); where a command goes (a line's start, after `;`, `|`, `&&`, `then`, `do`, `$(`, an assignment prefix), the
/// program's functions, zsh's autoloaded ones, aliases, the stub's builtins and the keywords. A command's arguments, a
/// name being declared, a comment and a quoted string give nothing.
extension ScriptModel {
  static let shellKeywords = [
    "case", "coproc", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select", "then", "time", "until", "while",
  ]
  static let zshKeywords = ["always", "end", "foreach", "nocorrect", "repeat"]
  /// Words after which a command starts.
  static let commandLeaders: Set<String> = [
    "then", "do", "else", "elif", "if", "while", "until", "time", "!", "command", "builtin", "exec", "nohup", "sudo", "noglob",
  ]

  public func complete(path: String, line: Int, character: Int, limit: Int = 200) -> ModelCompletionList {
    refresh()
    guard let unitIndex = unit(asked: path) else {
      return ModelCompletionList(context: .none, state: .unknown, prefix: "", replaceStart: 0, items: [], isIncomplete: false)
    }
    let holder = project.units[Int(unitIndex)]
    let offset = holder.source.lines.offset(line: line, character: character, in: holder.source.text)
    return complete(unitIndex: unitIndex, offset: offset, limit: limit)
  }

  func complete(unitIndex: Int32, offset: Int, limit: Int) -> ModelCompletionList {
    let holder = project.units[Int(unitIndex)]
    var site = holder.completionSite(at: offset)
    // A name the lexer didn't read as one (`"${na` while it's typed): its bytes before the cursor.
    if site.anchor == nil {
      var start = offset
      while start > 0, ScriptTokens.isNameByte(holder.source.text[start - 1]) { start -= 1 }
      if start < offset, followsDollar(holder, start) {
        site.replaceStart = start
        site.prefix = String(decoding: UnsafeBufferPointer(start: holder.source.text + start, count: offset - start), as: UTF8.self)
      }
    }
    let prefix = site.prefix
    let typed = Array(prefix.utf8)
    func finish(_ hits: [ModelCompletionHit], _ context: ModelCompletionContext) -> ModelCompletionList {
      project.rankCompletions(
        hits, context: context, state: .exact, prefix: prefix, replaceStart: site.replaceStart, limit: limit, in: holder,
        signature: { _, text in hashName(text) },
        render: { self.render($0) })
    }
    let nothing = ModelCompletionList(context: .none, state: .exact, prefix: prefix, replaceStart: site.replaceStart, items: [], isIncomplete: false)
    guard let facts = file(unitIndex), !isInComment(holder, offset) else { return nothing }
    let start = site.anchor.map { holder.tokens[$0].start } ?? site.replaceStart
    let token = site.anchor ?? site.at
    // `name=`, `name+=`, `name[…]=`: a variable being assigned.
    if dialect == .shell, let anchor = site.anchor, !followsDollar(holder, start), !isArithmetic(holder, before: anchor - 1), anchor + 1 < holder.tokens.count, holder.tokens[anchor].end == holder.tokens[anchor + 1].start {
      let next = holder.string(anchor + 1)
      if next.hasPrefix("=") || next.hasPrefix("+=") || next == "[" { return nothing }
    }
    // `for name`, `select name`: a name being declared.
    if dialect == .shell, let anchor = site.anchor, anchor > 0, holder.isToken(anchor - 1, "for") || holder.isToken(anchor - 1, "select") { return nothing }
    if dialect == .powerShell, let list = powerShellCompletion(unitIndex, facts: facts, site: site, typed: typed, finish: finish) { return list }
    if followsDollar(holder, start) { return finish(variableHits(unitIndex, token: token, typed: typed), .scope) }
    if let anchor = site.anchor, let use = facts.uses[Int32(anchor)] {
      switch use {
      case .variable, .scriptVariable: return finish(variableHits(unitIndex, token: token, typed: typed), .scope)
      case .command: return finish(commandHits(unitIndex, typed: typed), .scope)
      default: return nothing
      }
    }
    if isInString(holder, offset) { return nothing }
    if dialect == .shell, isArithmetic(holder, before: token - 1) {
      // In `((…))` or `$((…))`: arithmetic's names are variables.
      return finish(variableHits(unitIndex, token: token, typed: typed), .scope)
    }
    if startsCommand(holder, before: token - 1, offset: start) { return finish(commandHits(unitIndex, typed: typed), .scope) }
    return nothing
  }

  // MARK: Where the cursor is

  private func isInComment(_ holder: Unit, _ offset: Int) -> Bool {
    let tokens = holder.source.tokens
    var low = 0
    var high = tokens.count
    while low < high {
      let middle = (low + high) / 2
      if tokens[middle].end < offset { low = middle + 1 } else { high = middle }
    }
    guard low < tokens.count else { return false }
    let token = tokens[low]
    return (token.kind == .comment || token.kind == .docComment) && token.start < offset && offset <= token.end
  }

  /// Inside a quoted string the re-reader kept whole (its expansions are tokens of their own).
  private func isInString(_ holder: Unit, _ offset: Int) -> Bool {
    for token in holder.tokens where token.kind == .string && token.start < offset {
      if offset < token.end { return true }
    }
    return false
  }

  /// Right after `$`, `${`, `${#` or `${!`, or `$` inside a double-quoted string.
  private func followsDollar(_ holder: Unit, _ start: Int) -> Bool {
    let text = holder.source.text
    func byte(_ k: Int) -> UInt8 { k >= 0 && k < holder.source.count ? text[k] : 0 }
    var k = start - 1
    if dialect == .shell, byte(k) == 0x23 || byte(k) == 0x21, byte(k - 1) == 0x7B { k -= 1 }  // `${#`, `${!`
    if byte(k) == 0x7B { k -= 1 }  // `${`
    guard byte(k) == 0x24 else { return false }
    // `\$` is a dollar sign.
    var escapes = 0
    while byte(k - 1 - escapes) == (dialect == .shell ? 0x5C : 0x60) { escapes += 1 }
    return escapes % 2 == 0
  }

  /// Whether a command starts after token `before` (-1: the file's start), at `offset`.
  private func startsCommand(_ holder: Unit, before: Int, offset: Int) -> Bool {
    guard before >= 0 else { return true }
    let tokens = holder.tokens
    let text = holder.source.text
    // A line break between, not after a `\`.
    var k = tokens[before].end
    while k < offset {
      if text[k] == 0x0A {
        var j = k - 1
        while j >= tokens[before].end, text[j] == 0x20 || text[j] == 0x09 { j -= 1 }
        if j < tokens[before].end || text[j] != (dialect == .shell ? 0x5C : 0x60) { return true }
      }
      k += 1
    }
    let token = tokens[before]
    let word = holder.string(before)
    switch token.kind {
    case .punctuation:
      // A backtick is shell's command substitution, PowerShell's line continuation.
      if let last = word.utf8.last, last == 0x3B || last == 0x7C || last == 0x26 || (last == 0x60 && dialect == .shell) { return true }
      // PowerShell: after an assignment (`$x = Get-…`).
      if dialect == .powerShell, ["=", "+=", "-=", "*=", "/=", "%=", "??="].contains(word) { return true }
      if word == "!" { return startsCommand(holder, before: before - 1, offset: token.start) }
    case .close:
      // A `case` pattern's `)`: it has no `(`.
      if dialect == .shell, word == ")", unclosedOpen(holder, before: before - 1, stopsAtPattern: true) == -2 { return true }
    case .open:
      // `(`, `{`, `$(`; not `${`, `((`, `[`.
      guard word == "(" || word == "{" else { return false }
      if before > 0, tokens[before - 1].end == token.start, holder.string(before - 1) == "$", word == "{" { return false }
      if before > 0, tokens[before - 1].end == token.start, holder.string(before - 1) == "(" { return false }
      return true
    case .interpolationOpen:
      // `"…$(cmd…"`.
      return word == "$(" || word == "@("
    case .keyword, .declarationKeyword:
      if Self.commandLeaders.contains(word) || (dialect == .powerShell && ["return", "throw"].contains(word.lowercased())) { return true }
    default:
      break
    }
    guard dialect == .shell else { return false }
    // An assignment before the command (`FOO=1 cmd`): the word it's in, then what's before that.
    var first = before
    var depth = 0
    while first > 0, tokens[first - 1].end == tokens[first].start {
      // Not across a bracket the word is inside (`x=$(cmd arg`: `cmd` is a command's name).
      if tokens[first].kind == .close { depth += 1 }
      if tokens[first].kind == .open {
        if depth == 0 { return false }
        depth -= 1
      }
      first -= 1
    }
    if first < before, tokens[first].kind == .identifier, holder.string(first + 1).hasPrefix("=") || holder.string(first + 1).hasPrefix("+=") {
      return startsCommand(holder, before: first - 1, offset: tokens[first].start)
    }
    return false
  }

  /// In `((…))` or `$((…))`.
  private func isArithmetic(_ holder: Unit, before: Int) -> Bool {
    guard let open = unclosedOpen(holder, before: before), open > 0, holder.string(open) == "(" else { return false }
    return holder.string(open - 1) == "(" && holder.tokens[open - 1].end == holder.tokens[open].start
  }

  /// The nearest bracket before a token that isn't closed by it, nil for none; -2 when a `case`'s `in` or `;;` comes
  /// first (`stopsAtPattern`).
  private func unclosedOpen(_ holder: Unit, before: Int, stopsAtPattern: Bool = false) -> Int? {
    var depth = 0
    var k = before
    while k >= 0, before - k < 2000 {
      switch holder.tokens[k].kind {
      case .close: depth += 1
      case .open:
        if depth == 0 { return k }
        depth -= 1
      case .keyword where stopsAtPattern && depth == 0 && holder.isToken(k, "in"):
        return -2
      case .punctuation where stopsAtPattern && depth == 0:
        if holder.string(k).hasPrefix(";;") || holder.string(k).hasPrefix(";&") || (holder.isToken(k, ";") && k > 0 && holder.isToken(k - 1, ";")) { return -2 }
      default: break
      }
      k -= 1
    }
    return nil
  }

  // MARK: Names

  private func add(_ ref: DeclRef, score: Int32, typed: [UInt8], kind: ModelCompletionItemKind, into hits: inout [ModelCompletionHit], seen: inout Set<Name>) {
    let found = decl(ref)
    guard seen.insert(found.name).inserted else { return }
    let text = unit(ref).string(Int(found.nameToken))
    guard let match = matchClass(typed, text.utf8[...]) else { return }
    hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: ref, kind: kind))
  }

  /// The function whose body holds a token, -1 for none.
  func enclosingFunction(_ unitIndex: Int32, token: Int) -> Int32 {
    let holder = project.units[Int(unitIndex)]
    var found: Int32 = -1
    var size = Int32.max
    for (position, item) in holder.decls.enumerated() where item.kind == .function && item.bodyOpen >= 0 {
      let close = item.bodyClose >= 0 ? item.bodyClose : Int32(holder.tokens.count)
      if Int(item.bodyOpen) < token, token <= Int(close), close - item.bodyOpen < size {
        found = Int32(position)
        size = close - item.bodyOpen
      }
    }
    return found
  }

  func variableHits(_ unitIndex: Int32, token: Int, typed: [UInt8]) -> [ModelCompletionHit] {
    var hits: [ModelCompletionHit] = []
    var seen: Set<Name> = []
    let holder = project.units[Int(unitIndex)]
    let function = enclosingFunction(unitIndex, token: token)
    // Nearest first: the function's locals declared before the cursor, innermost last.
    for (_, sites) in index(unitIndex).locals[function] ?? [:] {
      if let at = sites.last(where: { Int(holder.decls[Int($0)].nameToken) < token }) {
        add(DeclRef(unit: unitIndex, decl: at), score: 0, typed: typed, kind: .variable, into: &hits, seen: &seen)
      }
    }
    if function >= 0 || functionFiles[unitIndex] != nil {
      let own = function >= 0 ? holder.decls[Int(function)].name : functionFiles[unitIndex]!
      for (key, _) in callerLocalNames(of: own) {
        for ref in localsOfCallers(key, of: own) { add(ref, score: 80, typed: typed, kind: .variable, into: &hits, seen: &seen) }
      }
    }
    // `$env:X` is listed after `$env:` only.
    for u in program(unitIndex) {
      for (_, sites) in index(u).globals {
        if let at = sites.first, !isEnvironment(DeclRef(unit: u, decl: at)) {
          add(DeclRef(unit: u, decl: at), score: u == unitIndex ? 50 : 100, typed: typed, kind: .variable, into: &hits, seen: &seen)
        }
      }
    }
    if let stub = stubUnit {
      for (_, sites) in index(stub).globals {
        guard let at = sites.first, stubFits(DeclRef(unit: stub, decl: at), unitIndex), !isEnvironment(DeclRef(unit: stub, decl: at)) else { continue }
        add(DeclRef(unit: stub, decl: at), score: 200, typed: typed, kind: .variable, into: &hits, seen: &seen)
      }
    }
    return hits
  }

  /// The names of the locals that the callers of a function (directly or not) declare.
  private func callerLocalNames(of function: Name) -> [Name: Bool] {
    var names: [Name: Bool] = [:]
    _ = localsOfCallers(0, of: function)
    var seen: Set<Name> = [function]
    var queue = [function]
    var steps = 0
    while let next = queue.first, steps < 64 {
      queue.removeFirst()
      steps += 1
      for caller in callersCache?[next] ?? [] {
        for (key, _) in index(caller.unit).locals[caller.decl] ?? [:] { names[key] = true }
        let holderName: Name? = caller.decl >= 0 ? decl(caller).name : functionFiles[caller.unit]
        if let holderName, seen.insert(holderName).inserted { queue.append(holderName) }
      }
    }
    return names
  }

  func commandHits(_ unitIndex: Int32, typed: [UInt8]) -> [ModelCompletionHit] {
    var hits: [ModelCompletionHit] = []
    var seen: Set<Name> = []
    let program = program(unitIndex)
    for u in program {
      for (_, sites) in index(u).functions {
        if let at = sites.first { add(DeclRef(unit: u, decl: at), score: u == unitIndex ? 0 : 50, typed: typed, kind: .function, into: &hits, seen: &seen) }
      }
    }
    if dialect == .shell {
      for u in program {
        for folder in functionFolders(u) {
          for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder))?.sorted() ?? [] where !entry.hasPrefix(".") {
            guard seen.insert(name(entry)).inserted, let match = matchClass(typed, entry.utf8[...]) else { continue }
            hits.append(ModelCompletionHit(name: entry, match: match, score: 60, ref: nil, kind: .function, detail: "autoload"))
          }
        }
      }
    }
    if dialect == .powerShell {
      // What the imported modules export.
      for module in importedModules(unitIndex) {
        for u in moduleFiles(module) {
          for (key, sites) in index(u).functions where !exportedFunctions(key, of: module).isEmpty {
            if let at = sites.first { add(DeclRef(unit: u, decl: at), score: 60, typed: typed, kind: .function, into: &hits, seen: &seen) }
          }
        }
      }
    }
    for u in program {
      for (_, sites) in index(u).aliases {
        if let at = sites.first { add(DeclRef(unit: u, decl: at), score: 70, typed: typed, kind: .function, into: &hits, seen: &seen) }
      }
    }
    if let stub = stubUnit {
      for (_, sites) in index(stub).functions {
        guard let at = sites.first, stubFits(DeclRef(unit: stub, decl: at), unitIndex) else { continue }
        add(DeclRef(unit: stub, decl: at), score: 200, typed: typed, kind: .function, into: &hits, seen: &seen)
      }
      for (_, sites) in index(stub).aliases {
        if let at = sites.first { add(DeclRef(unit: stub, decl: at), score: 210, typed: typed, kind: .function, into: &hits, seen: &seen) }
      }
    }
    do {
      let isZsh = file(unitIndex)?.isZsh ?? false
      for word in dialect == .powerShell ? Self.powerShellKeywords : Self.shellKeywords + (isZsh ? Self.zshKeywords : []) {
        if let match = matchClass(typed, word.utf8[...]) { hits.append(ModelCompletionHit(name: word, match: match, score: 250, ref: nil, kind: .keyword)) }
      }
    }
    return hits
  }

  private func render(_ hit: ModelCompletionHit) -> ModelCompletionEntry {
    var detail = hit.detail ?? ""
    var module = ""
    if let ref = hit.ref {
      let holder = unit(ref)
      module = moduleText(holder)
      let found = decl(ref)
      let inClass = found.parent >= 0 && holder.decls[Int(found.parent)].kind == .classType
      switch found.kind {
      case .typeAlias: detail = "alias"
      case .function: detail = inClass ? "method" : holder.isInterface ? (dialect == .shell ? "builtin" : "cmdlet") : "function"
      case .enumCase: detail = ""
      default:
        detail = file(ref.unit)?.parameters.contains(ref.decl) == true ? "parameter" : inClass ? "property" : found.isLocal ? "local" : ""
      }
    }
    return ModelCompletionEntry(
      name: hit.name, label: hit.name, detail: detail, module: module, kind: hit.kind ?? .variable, insertText: hit.name, isSnippet: false,
      isDeprecated: false, needsUnwrap: false)
  }
}
