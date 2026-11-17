import CodeModel
import CodeScan
import Foundation

/// What a PowerShell value is, as far as the model follows it: an instance of a script's class, else unknown. .NET's
/// types aren't followed (their members would come from a stub of the whole framework), so a member of one is unknown.
enum ScriptType: Hashable {
  case unknown
  case instance(DeclRef)
}

/// PowerShell's own answers: modules (`Import-Module`, `using module`, a manifest's modules and exports), a parameter's
/// name at a call, a class's members through `$this`, a typed or constructed variable and `[Type]::`, and types.
extension ScriptModel {
  // MARK: Modules

  /// The file a module source names: a path (with `.psd1`, `.psm1` or `.ps1` added, or a folder with its own manifest
  /// or module inside), or a name alone: the project's file of that name, a manifest first.
  func resolveModule(_ source: ScriptSource, of unitIndex: Int32) -> Int32? {
    guard let pattern = source.pattern else { return nil }
    for path in candidates(pattern, of: unitIndex, depth: 0) {
      for candidate in [path, path + ".psd1", path + ".psm1", path + ".ps1"] where ScriptLayout.isFile(candidate) {
        if let found = unit(atPath: candidate) { return found }
      }
      if ScriptLayout.isDirectory(path) {
        let base = (path as NSString).lastPathComponent
        for ext in [".psd1", ".psm1"] where ScriptLayout.isFile(path + "/" + base + ext) {
          if let found = unit(atPath: path + "/" + base + ext) { return found }
        }
      }
    }
    guard !pattern.contains("/"), !pattern.contains("\u{1}"), !pattern.contains("\u{2}"), !pattern.contains("\u{3}") else { return nil }
    let wanted = pattern.lowercased()
    var best: (rank: Int, unit: Int32)?
    for u in 0..<project.projectUnits {
      let fileName = (project.units[u].path as NSString).lastPathComponent.lowercased()
      guard (fileName as NSString).deletingPathExtension == wanted else { continue }
      let ext = (fileName as NSString).pathExtension
      let rank = ext == "psd1" ? 0 : ext == "psm1" ? 1 : 9
      if rank < 9, best == nil || rank < best!.rank { best = (rank, Int32(u)) }
    }
    return best?.unit
  }

  /// The modules a file's program imports.
  func importedModules(_ unitIndex: Int32) -> [Int32] {
    var found: [Int32] = []
    for u in program(unitIndex) {
      guard let facts = file(u) else { continue }
      let resolved = targets(u)
      for (k, source) in facts.sources.enumerated() where source.kind == .module {
        if k < resolved.count, let target = resolved[k], !found.contains(target) { found.append(target) }
      }
    }
    return found
  }

  /// A module's files: a manifest's modules (and theirs), a script module and what it dot-sources.
  func moduleFiles(_ module: Int32, depth: Int = 0) -> [Int32] {
    guard depth < 8, let facts = file(module) else { return [] }
    guard project.units[Int(module)].path.lowercased().hasSuffix(".psd1") else { return forward(module) }
    var found: [Int32] = []
    let resolved = targets(module)
    for (k, source) in facts.sources.enumerated() where source.kind == .module {
      if k < resolved.count, let target = resolved[k], target != module {
        for u in moduleFiles(target, depth: depth + 1) where !found.contains(u) { found.append(u) }
      }
    }
    return found
  }

  /// The functions of a name a module exports: a manifest's `FunctionsToExport`, a script module's
  /// `Export-ModuleMember` (all of them without one).
  func exportedFunctions(_ key: Name, of module: Int32, depth: Int = 0) -> [DeclRef] {
    guard depth < 8, let facts = file(module) else { return [] }
    if project.units[Int(module)].path.lowercased().hasSuffix(".psd1") {
      if let allowed = facts.manifestFunctions, !allowed.contains(key) { return [] }
      var found: [DeclRef] = []
      let resolved = targets(module)
      for (k, source) in facts.sources.enumerated() where source.kind == .module {
        if k < resolved.count, let target = resolved[k], target != module { found += exportedFunctions(key, of: target, depth: depth + 1) }
      }
      return found
    }
    let found = functions(key, in: forward(module))
    guard let exported = facts.exportedFunctions else { return found }
    if exported.contains(key) { return found }
    return found.filter { ref in
      let written = unit(ref).string(Int(decl(ref).nameToken)).lowercased()
      return facts.exportPatterns.contains { Self.wildcard($0, matches: written) }
    }
  }

  /// `Get-*` against a name, both lowercased.
  static func wildcard(_ pattern: String, matches name: String) -> Bool {
    let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
    guard parts.count > 1 else { return pattern == name }
    var rest = Substring(name)
    guard rest.hasPrefix(parts[0]) else { return false }
    rest = rest.dropFirst(parts[0].count)
    for part in parts.dropFirst().dropLast() {
      guard let found = rest.range(of: part) else { return false }
      rest = rest[found.upperBound...]
    }
    return rest.hasSuffix(parts.last!)
  }

  func moduleFunctions(_ key: Name, in unitIndex: Int32) -> [DeclRef] {
    var found: [DeclRef] = []
    for module in importedModules(unitIndex) {
      for ref in exportedFunctions(key, of: module) where !found.contains(ref) { found.append(ref) }
    }
    return found
  }

  // MARK: Parameters

  /// `-Name` at a call: the parameter of the functions the command is (through an alias too), by its whole name or a
  /// prefix only one has; a common parameter (`-Verbose`) is the stub's.
  func parameterAnswer(_ token: Int, command: Int, in unitIndex: Int32) -> Answer {
    let holder = project.units[Int(unitIndex)]
    guard command >= 0, command < holder.tokens.count else { return Self.unknown }
    let key = holder.key(token, dialect)
    let typed = holder.string(token).lowercased()
    let callees = callees(command, in: unitIndex)
    guard !callees.isEmpty else { return Self.unknown }
    let common = commonParameters
    var sites: [Site] = []
    for callee in callees {
      // A cmdlet's and an advanced function's parameters include the common ones; a prefix must name one of them all.
      let parameters = parametersOf(callee)
      let all = parameters + (isAdvanced(callee) ? common : [])
      if let exact = all.first(where: { decl($0).name == key }) {
        sites.append(.decl(exact))
        continue
      }
      let prefixed = all.filter { unit($0).string(Int(decl($0).nameToken)).lowercased().hasPrefix(typed) }
      if prefixed.count == 1 { sites.append(.decl(prefixed[0])) }
    }
    guard !sites.isEmpty else { return Self.unknown }
    return Answer(summarizing: sites)
  }

  /// The stub's common parameters (`-Verbose`, `-ErrorAction`…).
  var commonParameters: [DeclRef] {
    guard let stub = stubUnit, let at = index(stub).functions[lowerName("CommonParameters")]?.first else { return [] }
    return parametersOf(DeclRef(unit: stub, decl: at))
  }

  /// A cmdlet, or a function with `[CmdletBinding()]` or a `[Parameter()]`: one that takes the common parameters.
  func isAdvanced(_ function: DeclRef) -> Bool {
    if isStub(function.unit) { return true }
    let holder = unit(function)
    let item = decl(function)
    guard item.bodyOpen >= 0 else { return false }
    // Attributes come before `param(`'s last parameter; parameters in the header (`function f($a)`) before the body.
    let start = Int(item.bodyOpen)
    let end = min(max(parametersOf(function).last.map { Int(decl($0).nameToken) } ?? 0, start + 12), holder.tokens.count)
    guard start < end else { return false }
    for k in start..<end where holder.tokens[k].kind == .identifier {
      let word = holder.string(k).lowercased()
      if word == "cmdletbinding" || word == "parameter" { return true }
    }
    return false
  }

  /// A function's parameters, in order.
  func parametersOf(_ function: DeclRef) -> [DeclRef] {
    guard let facts = file(function.unit) else { return [] }
    let holder = unit(function)
    var found: [DeclRef] = []
    for (position, item) in holder.decls.enumerated() where item.parent == function.decl && item.kind == .variable && facts.parameters.contains(Int32(position)) {
      found.append(DeclRef(unit: function.unit, decl: Int32(position)))
    }
    return found
  }

  // MARK: Types and members

  /// The classes and enums of a name the file sees: its program's and its modules'.
  func classes(_ key: Name, in unitIndex: Int32) -> [DeclRef] {
    var found: [DeclRef] = []
    var units = program(unitIndex)
    for module in importedModules(unitIndex) { units += moduleFiles(module) }
    var seen: Set<Int32> = []
    for u in units where seen.insert(u).inserted {
      for at in index(u).classes[key] ?? [] { found.append(DeclRef(unit: u, decl: at)) }
    }
    return found
  }

  /// A type literal's class: a name of one word only (`[System.IO.File]` is .NET's).
  func classFor(first: Int, last: Int, in unitIndex: Int32) -> DeclRef? {
    guard first == last else { return nil }
    let found = classes(project.units[Int(unitIndex)].key(last, dialect), in: unitIndex)
    return found.count == 1 ? found[0] : nil
  }

  func typeAnswer(first: Int, last: Int, in unitIndex: Int32) -> Answer {
    guard first == last else { return Self.unknown }
    let found = classes(project.units[Int(unitIndex)].key(last, dialect), in: unitIndex)
    return found.isEmpty ? Self.unknown : Answer(summarizing: found.map { .decl($0) })
  }

  /// A class's members of a name, its own first, then its base's.
  func members(_ key: Name, of type: DeclRef, depth: Int = 0) -> [DeclRef] {
    guard depth < 16 else { return [] }
    let own = (index(type.unit).members[type.decl]?[key] ?? []).map { DeclRef(unit: type.unit, decl: $0) }
    if !own.isEmpty { return own }
    for (first, last) in file(type.unit)?.bases[type.decl] ?? [] {
      guard let base = classFor(first: Int(first), last: Int(last), in: type.unit) else { continue }
      let found = members(key, of: base, depth: depth + 1)
      if !found.isEmpty { return found }
    }
    return []
  }

  func memberAnswer(_ key: Name, receiver: Int32, in unitIndex: Int32) -> Answer {
    guard case .instance(let type) = typeOf(receiver, in: unitIndex) else { return Self.unknown }
    let found = members(key, of: type)
    return found.isEmpty ? Self.unknown : Answer(summarizing: found.map { .decl($0) })
  }

  /// `[Type]::name`: a static member; `::new` the constructors (the class when it has none); an enum's member.
  func staticMemberAnswer(_ key: Name, type: Int, in unitIndex: Int32) -> Answer {
    let holder = project.units[Int(unitIndex)]
    guard type >= 0, !(type > 0 && holder.isToken(type - 1, ".")), let found = classFor(first: type, last: type, in: unitIndex) else { return Self.unknown }
    if key == Self.newName {
      let constructors = members(decl(found).name, of: found).filter { decl($0).kind == .function && $0.unit == found.unit }
      return constructors.isEmpty ? Answer(state: .exact, sites: [.decl(found)]) : Answer(summarizing: constructors.map { .decl($0) })
    }
    let matches = members(key, of: found)
    return matches.isEmpty ? Self.unknown : Answer(summarizing: matches.map { .decl($0) })
  }

  static var newName: Name { lowerName("new") }

  /// What an expression's value is.
  func typeOf(_ expr: Int32, in unitIndex: Int32) -> ScriptType {
    guard let facts = file(unitIndex), expr >= 0, Int(expr) < facts.exprs.count else { return .unknown }
    let cacheKey = Int64(unitIndex) << 32 | Int64(expr)
    if let known = types[cacheKey] { return known }
    guard resolvingTypes.insert(cacheKey).inserted else { return .unknown }
    defer { resolvingTypes.remove(cacheKey) }
    let holder = project.units[Int(unitIndex)]
    var found = ScriptType.unknown
    switch facts.expr(expr) {
    case .this(let type):
      found = .instance(DeclRef(unit: unitIndex, decl: type))
    case .type(let first, let last):
      if let type = classFor(first: Int(first), last: Int(last), in: unitIndex) { found = .instance(type) }
    case .staticMember(let first, let last, let name):
      if let type = classFor(first: Int(first), last: Int(last), in: unitIndex) {
        if holder.key(Int(name), dialect) == Self.newName {
          found = .instance(type)
        } else if let member = members(holder.key(Int(name), dialect), of: type).first {
          found = declaredType(member)
        }
      }
    case .member(let base, let name):
      if case .instance(let type) = typeOf(base, in: unitIndex), let member = members(holder.key(Int(name), dialect), of: type).first {
        found = declaredType(member)
      }
    case .variable(let token):
      guard case .variable(let function)? = facts.uses[token] else { break }
      let answer = variableAnswer(holder.key(Int(token), dialect), in: unitIndex, token: token, function: function)
      guard answer.state == .exact else { break }
      var agreed: ScriptType?
      for site in answer.sites {
        guard case .decl(let ref) = site else {
          agreed = .unknown
          break
        }
        let type = typeOfDecl(ref)
        if agreed == nil { agreed = type } else if agreed != type { agreed = .unknown }
      }
      found = agreed ?? .unknown
    case .paren, .other:
      break
    }
    types[cacheKey] = found
    return found
  }

  /// A member's or variable's declared type (`[Box]$x`, a method's `[Box] Make()`).
  func declaredType(_ ref: DeclRef) -> ScriptType {
    guard let (first, last) = file(ref.unit)?.declaredTypes[ref.decl], let type = classFor(first: Int(first), last: Int(last), in: ref.unit) else {
      return .unknown
    }
    return .instance(type)
  }

  /// A variable's type: declared, else its value's: `[T]::new(…)`, `[T]value` (a cast), `New-Object T`, another
  /// variable, a member.
  func typeOfDecl(_ ref: DeclRef) -> ScriptType {
    let declared = declaredType(ref)
    if declared != .unknown { return declared }
    guard let facts = file(ref.unit), let value = facts.values[ref.decl], value.start >= 0, value.end > value.start else { return .unknown }
    let holder = unit(ref)
    let start = Int(value.start)
    let end = Int(value.end)
    if holder.isToken(start, "["), let close = (start..<end).first(where: { holder.isToken($0, "]") && facts.endsAt[Int32($0)] != nil }),
      close + 1 < end, !holder.isToken(close + 1, "::"), let type = facts.endsAt[Int32(close)]
    {
      return typeOf(type, in: ref.unit)
    }
    if holder.string(start).lowercased() == "new-object" {
      var k = start + 1
      if holder.isToken(k, "-"), k + 1 < end, holder.string(k + 1).lowercased() == "typename" { k += 2 }
      guard k < end, holder.tokens[k].kind == .identifier, k + 1 >= end || !holder.isToken(k + 1, ".") else { return .unknown }
      return classFor(first: k, last: k, in: ref.unit).map { .instance($0) } ?? .unknown
    }
    guard let last = facts.endsAt[Int32(end - 1)] else { return .unknown }
    return typeOf(last, in: ref.unit)
  }
}
