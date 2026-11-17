import CodeModel
import CodeScan
import Foundation

/// PowerShell's own completion: a command's parameters after `-`, a class's members after `value.` and `[Type]::`,
/// environment variables after `$env:`, and the keywords where a command goes.
extension ScriptModel {
  static let powerShellKeywords = [
    "begin", "break", "catch", "class", "continue", "do", "else", "elseif", "end", "enum", "exit", "filter", "finally", "for", "foreach",
    "function", "if", "param", "process", "return", "switch", "throw", "trap", "try", "until", "using", "while",
  ]

  /// What PowerShell completes at a site, nil when the shared rules decide.
  func powerShellCompletion(
    _ unitIndex: Int32, facts: ScriptFile, site: CompletionSite, typed: [UInt8], finish: ([ModelCompletionHit], ModelCompletionContext) -> ModelCompletionList
  ) -> ModelCompletionList? {
    let holder = project.units[Int(unitIndex)]
    if let anchor = site.anchor, let use = facts.uses[Int32(anchor)] {
      switch use {
      case .parameter(let command): return finish(parameterHits(Int(command), in: unitIndex, typed: typed), .scope)
      case .member(let receiver): return finish(memberHits(typeOf(receiver, in: unitIndex), typed: typed, statics: false), .member)
      case .staticMember(let type): return finish(staticHits(type: Int(type), in: unitIndex, typed: typed), .member)
      case .environment: return finish(environmentHits(unitIndex, typed: typed), .scope)
      default: return nil
      }
    }
    guard site.anchor == nil else { return nil }
    let before = site.at - 1
    guard before >= 0, before < holder.tokens.count, holder.tokens[before].end == site.replaceStart else { return nil }
    let text = holder.string(before)
    if text == "-", before > 0, holder.tokens[before - 1].end < holder.tokens[before].start, let command = commandOfStatement(holder, facts, before: before - 1) {
      return finish(parameterHits(command, in: unitIndex, typed: typed), .scope)
    }
    if text == ".", before > 0, holder.tokens[before - 1].end == holder.tokens[before].start, let receiver = facts.endsAt[Int32(before - 1)] {
      return finish(memberHits(typeOf(receiver, in: unitIndex), typed: typed, statics: false), .member)
    }
    if text == "::", before > 0, holder.isToken(before - 1, "]"), let type = facts.endsAt[Int32(before - 1)], case .type(let first, let last) = facts.expr(type), first == last {
      return finish(staticHits(type: Int(last), in: unitIndex, typed: typed), .member)
    }
    if text == ":", before > 1, holder.isToken(before - 2, "$") {
      switch holder.string(before - 1).lowercased() {
      case "env": return finish(environmentHits(unitIndex, typed: typed), .scope)
      case "using", "script", "global", "local", "private": return finish(variableHits(unitIndex, token: site.at, typed: typed), .scope)
      default: break
      }
    }
    return nil
  }

  /// The command whose arguments a token is among: back to the statement's start.
  private func commandOfStatement(_ holder: Unit, _ facts: ScriptFile, before: Int) -> Int? {
    var depth = 0
    var k = before
    while k >= 0, before - k < 400 {
      let token = holder.tokens[k]
      if token.kind == .close { depth += 1 }
      if token.kind == .open {
        if depth == 0 { return nil }
        depth -= 1
      }
      if depth == 0 {
        if case .command? = facts.uses[Int32(k)] { return k }
        if token.kind == .punctuation, holder.isToken(k, "|") || holder.isToken(k, ";") || holder.isToken(k, "=") { return nil }
        // A line break that isn't continued with a backtick ends the statement.
        if k < before, holder.startsLine(k + 1), !holder.isToken(k, "`") { return nil }
      }
      k -= 1
    }
    return nil
  }

  /// The functions a command names, through an alias too.
  func callees(_ command: Int, in unitIndex: Int32) -> [DeclRef] {
    let holder = project.units[Int(unitIndex)]
    guard command >= 0, command < holder.tokens.count else { return [] }
    var found: [DeclRef] = []
    for site in commandAnswer(holder.key(command, dialect), in: unitIndex, function: -1, functionsOnly: false).sites {
      guard case .decl(let ref) = site else { continue }
      if decl(ref).kind == .function {
        found.append(ref)
      } else if decl(ref).kind == .typeAlias, let value = file(ref.unit)?.values[ref.decl], value.start >= 0 {
        for target in commandAnswer(unit(ref).key(Int(value.start), dialect), in: ref.unit, function: -1, functionsOnly: true).sites {
          if case .decl(let callee) = target, decl(callee).kind == .function { found.append(callee) }
        }
      }
    }
    return found
  }

  private func parameterHits(_ command: Int, in unitIndex: Int32, typed: [UInt8]) -> [ModelCompletionHit] {
    var hits: [ModelCompletionHit] = []
    var seen: Set<Name> = []
    for callee in callees(command, in: unitIndex) {
      for parameter in parametersOf(callee) { addMember(parameter, score: 0, typed: typed, kind: .variable, into: &hits, seen: &seen) }
      if isAdvanced(callee) {
        for parameter in commonParameters { addMember(parameter, score: 100, typed: typed, kind: .variable, into: &hits, seen: &seen) }
      }
    }
    return hits
  }

  /// A class's members (its own first, then its bases'), or an enum's.
  private func memberHits(_ type: ScriptType, typed: [UInt8], statics: Bool) -> [ModelCompletionHit] {
    guard case .instance(let found) = type else { return [] }
    var hits: [ModelCompletionHit] = []
    var seen: Set<Name> = []
    var current: DeclRef? = found
    var depth = 0
    while let type = current, depth < 16 {
      for (_, positions) in index(type.unit).members[type.decl] ?? [:] {
        for at in positions {
          let ref = DeclRef(unit: type.unit, decl: at)
          // A constructor is `::new`, not a member.
          if decl(ref).kind == .function, decl(ref).name == decl(type).name { continue }
          let kind: ModelCompletionItemKind = decl(ref).kind == .function ? .method : decl(ref).kind == .enumCase ? .enumMember : .property
          addMember(ref, score: Int32(depth * 10), typed: typed, kind: kind, into: &hits, seen: &seen)
        }
      }
      current = nil
      for (first, last) in file(type.unit)?.bases[type.decl] ?? [] {
        if let base = classFor(first: Int(first), last: Int(last), in: type.unit) {
          current = base
          break
        }
      }
      depth += 1
    }
    return hits
  }

  private func staticHits(type: Int, in unitIndex: Int32, typed: [UInt8]) -> [ModelCompletionHit] {
    guard let found = classFor(first: type, last: type, in: unitIndex) else { return [] }
    var hits = memberHits(.instance(found), typed: typed, statics: true)
    if decl(found).kind != .enumeration, let match = matchClass(typed, "new".utf8[...]) {
      hits.append(ModelCompletionHit(name: "new", match: match, score: 0, ref: nil, kind: .constructor, detail: "constructor"))
    }
    return hits
  }

  /// `$env:` names: the program's assignments, then the stub's.
  private func environmentHits(_ unitIndex: Int32, typed: [UInt8]) -> [ModelCompletionHit] {
    var hits: [ModelCompletionHit] = []
    var seen: Set<Name> = []
    var units = program(unitIndex)
    if let stub = stubUnit { units.append(stub) }
    for u in units {
      for (_, sites) in index(u).globals {
        guard let at = sites.first else { continue }
        let ref = DeclRef(unit: u, decl: at)
        guard isEnvironment(ref) else { continue }
        addMember(ref, score: isStub(u) ? 200 : u == unitIndex ? 0 : 50, typed: typed, kind: .variable, into: &hits, seen: &seen)
      }
    }
    return hits
  }

  /// `$env:X`'s declaration.
  func isEnvironment(_ ref: DeclRef) -> Bool {
    let found = decl(ref)
    return dialect == .powerShell && found.parent < 0 && found.name == lowerName("env:" + unit(ref).string(Int(found.nameToken)))
  }

  private func addMember(_ ref: DeclRef, score: Int32, typed: [UInt8], kind: ModelCompletionItemKind, into hits: inout [ModelCompletionHit], seen: inout Set<Name>) {
    let found = decl(ref)
    guard seen.insert(found.name).inserted else { return }
    let text = unit(ref).string(Int(found.nameToken))
    guard let match = matchClass(typed, text.utf8[...]) else { return }
    hits.append(ModelCompletionHit(name: text, match: match, score: score, ref: ref, kind: kind))
  }
}
