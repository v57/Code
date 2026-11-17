import CodeModel
import CodeScan
import Foundation

/// The model of a folder of scripts, shell or PowerShell: definitions, references, completion and details from source,
/// on CodeModel's core. Both dialects' parsers write the same facts (`ScriptFile`: what each name is, the files each
/// script reads, what each function calls), and names resolve the same way:
///
/// - **Programs.** A script sees what it defines, what it sources (`source`, `.`, dot-sourcing, `Import-Module`)
///   with what those source, and, when it is itself sourced, what its sourcing scripts see: its program.
/// - **Commands** are functions by name in the program (the script's own and what it sources first, then its
///   sourcing scripts'), then zsh's autoloaded functions in `fpath`'s folders, aliases, then the dialect's builtins
///   from a stub. An external program is unknown.
/// - **Variables** follow dynamic scope: a function's own local declared before the use, else (when a function that
///   calls it declares one of that name) candidates, else the program's variable: every place it's assigned. A
///   variable no script assigns is the stub's (`HOME`, `PSScriptRoot`) or unknown.
public final class ScriptModel: LanguageModel {
  public let project: Project
  let layout: ScriptLayout
  let dialect: ScriptDialect
  private var seenParses = 0
  private var seenUnits: [Unit] = []
  // Dropped when any file is read again.
  var targetCache: [Int32: [Int32?]] = [:]
  var folderCache: [Int32: [String]] = [:]
  var forwardCache: [Int32: [Int32]] = [:]
  var programCache: [Int32: [Int32]] = [:]
  var includers: [Int32: [Int32]]?
  var callersCache: [Name: [DeclRef]]?
  var indexes: [Int32: UnitIndex] = [:]
  var referenceCache: [[Site]: [(path: String, line: Int)]] = [:]
  var cachedReferences = 0
  /// Units read as one function's body (zsh's autoloaded function files): the function they are, by name.
  var functionFiles: [Int32: Name] = [:]
  var autoloaded: [String: Int32?] = [:]
  private var loadedStub = false
  var types: [Int64: ScriptType] = [:]
  var resolvingTypes: Set<Int64> = []

  /// A file's declarations by what they are and their names.
  struct UnitIndex {
    var functions: [Name: [Int32]] = [:]
    var aliases: [Name: [Int32]] = [:]
    var globals: [Name: [Int32]] = [:]
    /// Locals (variables and parameters) by their function's declaration (-1: the top level of a function's file).
    var locals: [Int32: [Name: [Int32]]] = [:]
    var classes: [Name: [Int32]] = [:]
    var members: [Int32: [Name: [Int32]]] = [:]
  }

  init(project: Project, dialect: ScriptDialect) {
    self.project = project
    self.dialect = dialect
    layout = project.layout as! ScriptLayout
  }

  /// The scripts under `root`.
  public convenience init(root: String, dialect: ScriptDialect) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    self.init(project: Project(root: root, layout: ScriptLayout(root: root, dialect: dialect)), dialect: dialect)
  }

  var parses: ScriptCounter { (layout.syntax as? ShellSyntax)?.parses ?? (layout.syntax as! PowerShellSyntax).parses }

  /// Answers go stale when any file is read again.
  func refresh() {
    let parsed = parses.value
    guard parsed != seenParses || project.units.count != seenUnits.count else { return }
    seenParses = parsed
    var changed = false
    for index in seenUnits.indices where project.units[index] !== seenUnits[index] {
      indexes[Int32(index)] = nil
      seenUnits[index] = project.units[index]
      changed = true
    }
    if project.units.count != seenUnits.count { includers = nil }
    seenUnits.append(contentsOf: project.units[seenUnits.count...])
    if changed {
      targetCache.removeAll()
      folderCache.removeAll()
      includers = nil
    }
    forwardCache.removeAll()
    programCache.removeAll()
    callersCache = nil
    referenceCache.removeAll()
    cachedReferences = 0
    types.removeAll()
  }

  static let unknown = Answer(state: .unknown, sites: [])

  func file(_ unitIndex: Int32) -> ScriptFile? {
    guard unitIndex >= 0, Int(unitIndex) < project.units.count, let scan = project.units[Int(unitIndex)].scans[ScriptFile.key] else { return nil }
    return unsafeDowncast(scan, to: ScriptFile.self)
  }

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }

  func index(_ unitIndex: Int32) -> UnitIndex {
    if let known = indexes[unitIndex] { return known }
    var made = UnitIndex()
    let holder = project.units[Int(unitIndex)]
    let parameters = file(unitIndex)?.parameters ?? []
    for (position, decl) in holder.decls.enumerated() {
      let at = Int32(position)
      switch decl.kind {
      case .function where decl.parent < 0 || holder.decls[Int(decl.parent)].kind == .function:
        if decl.name != 0 { made.functions[decl.name, default: []].append(at) }
      case .typeAlias:
        made.aliases[decl.name, default: []].append(at)
      case .variable where decl.isLocal || (parameters.contains(at) && decl.parent >= 0):
        made.locals[decl.parent, default: [:]][decl.name, default: []].append(at)
      case .variable where decl.parent < 0:
        made.globals[decl.name, default: []].append(at)
      case .classType, .enumeration:
        made.classes[decl.name, default: []].append(at)
      default:
        break
      }
      if decl.parent >= 0, holder.decls[Int(decl.parent)].kind == .classType || holder.decls[Int(decl.parent)].kind == .enumeration {
        made.members[decl.parent, default: [:]][decl.name, default: []].append(at)
      }
    }
    indexes[unitIndex] = made
    return made
  }

  // MARK: Files

  func loadStub() {
    guard !loadedStub else { return }
    loadedStub = true
    project.ensureModule(name(dialect.stubModule), display: dialect.stubModule)
  }

  var stubUnit: Int32? {
    loadStub()
    return project.modules[name(dialect.stubModule)]?.units.first
  }

  func isStub(_ unitIndex: Int32) -> Bool { project.units[Int(unitIndex)].isInterface }

  /// A unit for a file on disk: the project's, or read now.
  func unit(atPath path: String) -> Int32? {
    let path = ScriptLayout.standardize(path)
    if let known = project.unitByPath[path] { return known }
    guard project.ensureModule(name(path), display: path) != nil else { return nil }
    return project.unitByPath[path]
  }

  /// The unit of a file asked about: the project's, or one outside it read now (an extensionless function file in a
  /// folder of `fpath`, a script named on the command line).
  func unit(asked path: String) -> Int32? {
    if let known = project.unitByPath[path] { return known }
    guard ScriptLayout.isFile(path) else { return nil }
    let found = unit(atPath: path)
    refresh()
    return found
  }

  /// Where each of a file's sources leads (a unit, or nil when it can't be told or isn't on disk).
  func targets(_ unitIndex: Int32) -> [Int32?] {
    if let known = targetCache[unitIndex] { return known }
    targetCache[unitIndex] = []
    guard let facts = file(unitIndex) else { return [] }
    var found: [Int32?] = []
    for (position, source) in facts.sources.enumerated() {
      guard source.kind != .functionFolder else {
        found.append(nil)
        continue
      }
      found.append(resolve(source, of: unitIndex, at: position))
    }
    targetCache[unitIndex] = found
    return found
  }

  /// The folders a file adds to zsh's `fpath`.
  func functionFolders(_ unitIndex: Int32) -> [String] {
    if let known = folderCache[unitIndex] { return known }
    var found: [String] = []
    for source in file(unitIndex)?.sources ?? [] where source.kind == .functionFolder {
      for path in candidates(source.pattern, of: unitIndex, depth: 0) where ScriptLayout.isDirectory(path) {
        found.append(path)
        break
      }
    }
    folderCache[unitIndex] = found
    return found
  }

  func resolve(_ source: ScriptSource, of unitIndex: Int32, at position: Int) -> Int32? {
    if dialect == .powerShell, source.kind == .module { return resolveModule(source, of: unitIndex) }
    for path in candidates(source.pattern, of: unitIndex, depth: 0) {
      for candidate in dialect == .powerShell && !path.lowercased().hasSuffix(".ps1") && !path.lowercased().hasSuffix(".psm1") ? [path, path + ".ps1"] : [path]
      where ScriptLayout.isFile(candidate) {
        if let found = unit(atPath: candidate) { return found }
      }
    }
    return nil
  }

  /// The absolute paths a source's pattern may name, the likeliest first: the script's own folder for a relative path
  /// (scripts are mostly run from where they are, or from the root), the root's.
  func candidates(_ pattern: String?, of unitIndex: Int32, depth: Int) -> [String] {
    guard var pattern, depth < 4 else { return [] }
    let holder = project.units[Int(unitIndex)]
    let folder = (holder.path as NSString).deletingLastPathComponent
    // Variables: their one value in this file or the scripts that source it.
    while let open = pattern.firstIndex(of: "\u{3}") {
      let rest = pattern[pattern.index(after: open)...]
      guard let close = rest.firstIndex(of: "\u{3}") else { return [] }
      let variable = String(rest[..<close])
      guard let value = variableValue(variable, in: unitIndex, depth: depth) else { return [] }
      pattern = String(pattern[..<open]) + value + String(rest[rest.index(after: close)...])
    }
    if pattern.hasPrefix("\u{1}") {
      return [ScriptLayout.standardize(folder + "/" + pattern.dropFirst())]
    }
    if pattern.hasPrefix("\u{2}") {
      return [ScriptLayout.standardize(NSHomeDirectory() + "/" + pattern.dropFirst())]
    }
    if pattern.contains("\u{1}") || pattern.contains("\u{2}") { return [] }
    if pattern.hasPrefix("/") { return [ScriptLayout.standardize(pattern)] }
    // Relative to where the script is run from: its folder, a folder above it (`cd "$(dirname "$0")/.."` first), the root.
    var found: [String] = []
    var base = folder
    while true {
      let path = ScriptLayout.standardize(base + "/" + pattern)
      if !found.contains(path) { found.append(path) }
      guard base.count > project.root.count, base.hasPrefix(project.root) else { break }
      base = (base as NSString).deletingLastPathComponent
    }
    let fromRoot = ScriptLayout.standardize(project.root + "/" + pattern)
    if !found.contains(fromRoot) { found.append(fromRoot) }
    return found
  }

  /// A variable's value as a path pattern, when the file (or one sourcing it) assigns it once at the top level.
  func variableValue(_ variable: String, in unitIndex: Int32, depth: Int) -> String? {
    let key = dialect == .shell ? name(variable) : lowerName(variable)
    var seen: Set<Int32> = []
    var queue = [unitIndex]
    while let next = queue.first {
      queue.removeFirst()
      guard seen.insert(next).inserted, seen.count < 16 else { continue }
      let holder = project.units[Int(next)]
      if let sites = index(next).globals[key], let facts = file(next) {
        let values = sites.compactMap { facts.values[$0] }
        if values.count == 1, let value = values.first, value.start < value.end, Int(value.end) <= holder.tokens.count {
          let written = holder.source.string(from: holder.tokens[Int(value.start)].start, to: holder.tokens[Int(value.end) - 1].end)
          let read = dialect == .shell ? ShellParser.pathPattern(written, dialect: .shell) : PowerShellParser.valuePattern(written)
          guard var pattern = read else { return nil }
          // A value relative to its own script's folder, read from another file: made absolute there.
          if pattern.hasPrefix("\u{1}"), next != unitIndex {
            pattern = (holder.path as NSString).deletingLastPathComponent + pattern.dropFirst()
          }
          return pattern
        }
        if !values.isEmpty { return nil }
      }
      if depth == 0 { queue.append(contentsOf: includersOf(next)) }
    }
    if variable == "PWD" || variable.lowercased() == "pwd" { return nil }
    return nil
  }

  /// The files a file reads, and what those read, in order (the file first).
  func forward(_ unitIndex: Int32) -> [Int32] {
    if let known = forwardCache[unitIndex] { return known }
    var order: [Int32] = []
    var seen: Set<Int32> = []
    var queue = [unitIndex]
    var head = 0
    while head < queue.count {
      let next = queue[head]
      head += 1
      guard seen.insert(next).inserted else { continue }
      order.append(next)
      if order.count > 400 { break }
      let sources = file(next)?.sources ?? []
      for (k, target) in targets(next).enumerated() where k < sources.count && sources[k].kind == .source {
        if let target { queue.append(target) }
      }
    }
    forwardCache[unitIndex] = order
    return order
  }

  /// The files that source a file, directly.
  func includersOf(_ unitIndex: Int32) -> [Int32] {
    if includers == nil {
      var map: [Int32: [Int32]] = [:]
      var byFolder: [String: [Int32]] = [:]
      if dialect == .shell {
        for (index, holder) in project.units.enumerated() where !holder.isInterface {
          byFolder[(holder.path as NSString).deletingLastPathComponent, default: []].append(Int32(index))
        }
      }
      var u: Int32 = 0
      while Int(u) < project.units.count {
        if !project.units[Int(u)].isInterface {
          let sources = file(u)?.sources ?? []
          for (k, target) in targets(u).enumerated() where k < sources.count && sources[k].kind == .source {
            if let target, target != u, !(map[target]?.contains(u) ?? false) { map[target, default: []].append(u) }
          }
          // zsh's function files in the folders a script adds to `fpath`: read as its functions.
          for folder in dialect == .shell ? functionFolders(u) : [] {
            for t in byFolder[folder] ?? [] where t != u {
              functionFiles[t] = name((project.units[Int(t)].path as NSString).lastPathComponent)
              file(t)?.isZsh = true
              if !(map[t]?.contains(u) ?? false) { map[t, default: []].append(u) }
            }
          }
        }
        u += 1
      }
      includers = map
    }
    return includers?[unitIndex] ?? []
  }

  /// A file's program: itself and what it reads, then each script that (directly or not) sources it with what that
  /// one reads.
  func program(_ unitIndex: Int32) -> [Int32] {
    if let known = programCache[unitIndex] { return known }
    var order = forward(unitIndex)
    var seen = Set(order)
    var ancestors: [Int32] = []
    var visited: Set<Int32> = [unitIndex]
    var queue = includersOf(unitIndex)
    while let next = queue.first {
      queue.removeFirst()
      guard visited.insert(next).inserted, visited.count < 200 else { continue }
      ancestors.append(next)
      queue.append(contentsOf: includersOf(next))
    }
    for ancestor in ancestors {
      for member in forward(ancestor) where seen.insert(member).inserted { order.append(member) }
    }
    programCache[unitIndex] = order
    return order
  }

  // MARK: Asking

  public func answer(path: String, line: Int, character: Int) -> Answer {
    refresh()
    guard let unitIndex = unit(asked: path) else { return Self.unknown }
    let holder = project.units[Int(unitIndex)]
    let offset = holder.source.lines.offset(line: line, character: character, in: holder.source.text)
    guard let token = holder.token(at: offset) else { return Self.unknown }
    return answer(unitIndex: unitIndex, token: token)
  }

  package func answer(unitIndex: Int32, token: Int) -> Answer {
    let holder = project.units[Int(unitIndex)]
    guard token >= 0, token < holder.tokens.count, let facts = file(unitIndex) else { return Self.unknown }
    if let use = facts.uses[Int32(token)] {
      switch use {
      case .command(let function, let functionsOnly):
        return commandAnswer(holder.key(token, dialect), in: unitIndex, function: function, functionsOnly: functionsOnly)
      case .variable(let function):
        return variableAnswer(holder.key(token, dialect), in: unitIndex, token: Int32(token), function: function)
      case .scriptVariable:
        return globalAnswer(holder.key(token, dialect), in: unitIndex)
      case .environment:
        return globalAnswer(lowerName("env:" + holder.string(token)), in: unitIndex)
      case .path(let source):
        guard Int(source) < facts.sources.count, let target = targets(unitIndex)[Int(source)] else { return Self.unknown }
        return Answer(state: .exact, sites: [.file(target)])
      case .parameter(let command):
        return parameterAnswer(token, command: Int(command), in: unitIndex)
      case .this(let type):
        return Answer(state: .exact, sites: [.decl(DeclRef(unit: unitIndex, decl: type))])
      case .member(let receiver):
        return memberAnswer(holder.key(token, dialect), receiver: receiver, in: unitIndex)
      case .staticMember(let type):
        return staticMemberAnswer(holder.key(token, dialect), type: Int(type), in: unitIndex)
      case .type(let first):
        return typeAnswer(first: Int(first), last: token, in: unitIndex)
      }
    }
    if let site = holder.declaredSite(at: token, unitIndex: unitIndex), case .decl(let ref) = site {
      return declarationAnswer(ref)
    }
    return Self.unknown
  }

  /// A declaration's own name: itself, or a variable's every assignment.
  func declarationAnswer(_ ref: DeclRef) -> Answer {
    let found = decl(ref)
    if found.kind == .variable, !found.isLocal, found.parent < 0 {
      let all = globalAnswer(found.name, in: ref.unit)
      if all.state != .unknown { return all }
    }
    return Answer(state: .exact, sites: [.decl(ref)])
  }

  /// Functions of a name in a list of files.
  func functions(_ key: Name, in units: [Int32]) -> [DeclRef] {
    var found: [DeclRef] = []
    for u in units {
      for at in index(u).functions[key] ?? [] { found.append(DeclRef(unit: u, decl: at)) }
    }
    return found
  }

  func commandAnswer(_ key: Name, in unitIndex: Int32, function: Int32, functionsOnly: Bool) -> Answer {
    let own = forward(unitIndex)
    var sites = functions(key, in: own).map { Site.decl($0) }
    if sites.isEmpty {
      let others = program(unitIndex).dropFirst(own.count)
      sites = functions(key, in: Array(others)).map { Site.decl($0) }
    }
    if sites.isEmpty, dialect == .shell, let file = autoloadedFunction(key, in: unitIndex) {
      sites = [.file(file)]
    }
    if dialect == .powerShell, sites.isEmpty { sites = moduleFunctions(key, in: unitIndex).map { Site.decl($0) } }
    if !functionsOnly {
      var aliases: [Site] = []
      for u in program(unitIndex) {
        for at in index(u).aliases[key] ?? [] { aliases.append(.decl(DeclRef(unit: u, decl: at))) }
      }
      sites += aliases
    }
    if sites.isEmpty, let stub = stubUnit {
      // A builtin, or a cmdlet: the stub's function.
      if let at = index(stub).functions[key]?.first, stubFits(DeclRef(unit: stub, decl: at), unitIndex) { sites = [.decl(DeclRef(unit: stub, decl: at))] }
      if sites.isEmpty, !functionsOnly, let at = index(stub).aliases[key]?.first { sites = [.decl(DeclRef(unit: stub, decl: at))] }
    }
    guard !sites.isEmpty else { return Self.unknown }
    return Answer(state: sites.count == 1 ? .exact : .candidates, sites: sites)
  }

  /// zsh's `autoload name`: the file `name` in a folder of `fpath` the program adds.
  func autoloadedFunction(_ key: Name, in unitIndex: Int32) -> Int32? {
    for u in program(unitIndex) {
      for folder in functionFolders(u) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
        for entry in entries where name(entry) == key {
          let path = folder + "/" + entry
          let cacheKey = path
          if let known = autoloaded[cacheKey] { return known }
          let made = unit(atPath: path)
          autoloaded[cacheKey] = made
          if let made {
            functionFiles[made] = key
            file(made)?.isZsh = true
          }
          return made
        }
      }
    }
    return nil
  }

  /// A variable's use at `token` in a function (or the top level, -1).
  func variableAnswer(_ key: Name, in unitIndex: Int32, token: Int32, function: Int32) -> Answer {
    // The function's own local declared nearest before the use.
    if let local = index(unitIndex).locals[function]?[key]?.last(where: { project.units[Int(unitIndex)].decls[Int($0)].nameToken <= token }) {
      return Answer(state: .exact, sites: [.decl(DeclRef(unit: unitIndex, decl: local))])
    }
    let global = globalAnswer(key, in: unitIndex)
    // A function that calls this one may declare it: then it depends on the caller.
    if function >= 0 || functionFiles[unitIndex] != nil {
      let callerLocals = localsOfCallers(key, of: function >= 0 ? project.units[Int(unitIndex)].decls[Int(function)].name : functionFiles[unitIndex]!)
      if !callerLocals.isEmpty {
        return Answer(state: .candidates, sites: callerLocals.map { .decl($0) } + global.sites)
      }
    }
    return global
  }

  /// Whether a stub's builtin or variable is the script's shell's: zsh's own aren't a bash script's, nor bash's a zsh one's.
  func stubFits(_ ref: DeclRef, _ unitIndex: Int32) -> Bool {
    guard dialect == .shell, let facts = file(unitIndex) else { return true }
    let name = stubName(ref)
    return facts.isZsh ? !ShellStd.bashOnly.contains(name) : !ShellStd.zshOnly.contains(name)
  }

  /// Every assignment of a script variable in the file's program, else the stub's.
  func globalAnswer(_ key: Name, in unitIndex: Int32) -> Answer {
    var sites: [Site] = []
    for u in program(unitIndex) {
      for at in index(u).globals[key] ?? [] { sites.append(.decl(DeclRef(unit: u, decl: at))) }
    }
    if sites.isEmpty, let stub = stubUnit, let at = index(stub).globals[key]?.first, stubFits(DeclRef(unit: stub, decl: at), unitIndex) {
      sites = [.decl(DeclRef(unit: stub, decl: at))]
    }
    return sites.isEmpty ? Self.unknown : Answer(state: .exact, sites: sites)
  }

  /// Locals of a name declared by functions that call a function (directly or through others), from every file.
  func localsOfCallers(_ key: Name, of function: Name) -> [DeclRef] {
    if callersCache == nil {
      var map: [Name: [DeclRef]] = [:]
      for u in 0..<project.units.count where !project.units[u].isInterface {
        guard let facts = file(Int32(u)) else { continue }
        for (caller, names) in facts.calls {
          for called in names { map[called, default: []].append(DeclRef(unit: Int32(u), decl: caller)) }
        }
      }
      callersCache = map
    }
    var found: [DeclRef] = []
    var seen: Set<Name> = [function]
    var queue = [function]
    var steps = 0
    while let next = queue.first, steps < 64 {
      queue.removeFirst()
      steps += 1
      for caller in callersCache?[next] ?? [] {
        let holderName: Name
        if caller.decl >= 0 {
          holderName = decl(caller).name
        } else if let fileFunction = functionFiles[caller.unit] {
          holderName = fileFunction
        } else {
          continue
        }
        for at in index(caller.unit).locals[caller.decl]?[key] ?? [] {
          let ref = DeclRef(unit: caller.unit, decl: at)
          if !found.contains(ref) { found.append(ref) }
        }
        if seen.insert(holderName).inserted { queue.append(holderName) }
      }
    }
    return found
  }

  // MARK: References

  public func references(of answer: Answer) -> [(path: String, line: Int)] {
    refresh()
    guard answer.state != .unknown, !answer.byNameOnly, let first = answer.sites.first else { return [] }
    if let known = referenceCache[answer.sites] { return known }
    var keys: Set<Name> = []
    var restrict: Int32?
    for site in answer.sites {
      switch site {
      case .decl(let ref):
        keys.insert(decl(ref).name)
        // A local is read only in its file, except a parameter: its name is also `-Name` at calls in other files.
        if decl(ref).isLocal, answer.sites.count == 1, !(file(ref.unit)?.parameters.contains(ref.decl) ?? false) { restrict = ref.unit }
      case .local(let unitIndex, -1):
        if let key = functionFiles[unitIndex] { keys.insert(key) }
      default:
        break
      }
    }
    _ = first
    guard !keys.isEmpty else { return [] }
    let targets = Set(answer.sites)
    var seen = Set<String>()
    var found: [(path: String, line: Int)] = []
    for u in 0..<project.projectUnits {
      if let restrict, restrict != Int32(u) { continue }
      let holder = project.units[u]
      for index in holder.tokens.indices {
        let kind = holder.tokens[index].kind
        guard kind == .identifier || kind == .keyword || kind == .declarationKeyword, keys.contains(holder.key(index, dialect)) else { continue }
        let hit = self.answer(unitIndex: Int32(u), token: index)
        guard hit.state != .unknown, !hit.byNameOnly, hit.sites.contains(where: targets.contains) else { continue }
        let line = holder.source.lines.line(of: holder.tokens[index].start) + 1
        let path = project.rootRelative(holder.path)
        if seen.insert("\(path):\(line)").inserted { found.append((path, line)) }
      }
    }
    cachedReferences += found.count
    if cachedReferences > 100_000 {
      referenceCache.removeAll()
      cachedReferences = found.count
    }
    referenceCache[answer.sites] = found
    return found
  }

  // MARK: Places

  /// A place as the bench's references name it: a path relative to the root (`../` outside it), line from 1; a whole
  /// file at line 1; the stub's as `builtin:<name>` (shell) or `ps:<name>` (PowerShell), line 0.
  public func place(of site: Site) -> (path: String, line: Int)? {
    switch site {
    case .decl(let ref):
      let holder = unit(ref)
      if holder.isInterface { return ((dialect == .shell ? "builtin:" : "ps:") + stubName(ref), 0) }
      let token = Int(decl(ref).nameToken)
      guard token >= 0, token < holder.tokens.count else { return nil }
      return (project.rootRelative(holder.path), holder.source.lines.line(of: holder.tokens[token].start) + 1)
    case .local(let unitIndex, let token):
      let holder = project.units[Int(unitIndex)]
      if token < 0 { return project.place(of: site) }
      guard Int(token) < holder.tokens.count else { return nil }
      return (project.rootRelative(holder.path), holder.source.lines.line(of: holder.tokens[Int(token)].start) + 1)
    case .generic, .module:
      return nil
    }
  }

  /// A stub declaration's name: `echo`, `HOME`, `Get-ChildItem`, `Get-ChildItem.Path` (a parameter).
  func stubName(_ ref: DeclRef) -> String {
    let holder = unit(ref)
    let found = decl(ref)
    let own = holder.string(Int(found.nameToken))
    if dialect == .powerShell, found.name == lowerName("env:" + own) { return "env:" + own }
    guard found.parent >= 0 else { return own }
    return holder.string(Int(holder.decls[Int(found.parent)].nameToken)) + "." + own
  }
}
