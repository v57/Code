import CodeModel
import CodeScan
import Foundation

/// PowerShell for the core: a file is read whole by `PowerShellParser` over `ScriptTokens`' tokens, which notes what
/// each name is in `ScriptFile`, as the shell's parser does. Names compare without case (`Decl.name` is the lowercased
/// name's hash). The declarations are functions and filters (their `param()` or `(…)` parameters as locals in
/// `ScriptFile.parameters`), variables (an assignment in a function declares its local the first time; at the top level
/// and with `$script:`/`$global:` every assignment is the script's variable), `foreach` variables, aliases
/// (`Set-Alias`, `New-Alias`), classes with their properties, methods and constructors, and enums with their members.
final class PowerShellSyntax: LanguageSyntax {
  let profile = LexProfile.profile(forLanguage: "powershell")!
  let parametersHaveLabels = false
  let parses = ScriptCounter()

  func parse(_ unit: CodeModel.Unit) -> UInt64 {
    parses.increment()
    var parser = PowerShellParser(unit: unit)
    parser.parseFile()
    unit.scans[ScriptFile.key] = parser.file
    return parser.shape()
  }

  func codeTokens(_ source: SourceFile) -> [Token] { ScriptTokens.read(source, dialect: .powerShell) }
  func evaluateCondition(_ unit: CodeModel.Unit, _ i: inout Int) -> Bool { true }
  func conditional(_ unit: CodeModel.Unit, _ i: Int) -> ConditionalDirective { .none }
}

struct PowerShellParser {
  enum Kind { case top, block, function, paren, subexpression, call, index, type, hashtable, classBody, enumBody, parameters }
  /// A command whose arguments the parser reads itself.
  enum Special { case none, importModule, alias, exportMember, dotSource, newObject }

  struct Frame {
    var kind: Kind
    /// The enclosing function's (or method's) declaration, -1 for none.
    var function: Int32
    var classDecl: Int32 = -1
    /// A statement or a pipeline's element starts here: a word is a command's name.
    var atCommand = true
    /// The command whose arguments are being read, -1 in an expression.
    var command: Int32 = -1
    var special = Special.none
    /// Arguments of the special command read so far; a value parameter's name waiting for its value.
    var positional = 0
    var pendingParameter = ""
    /// A method call's member expression, which this frame's `)` ends.
    var callExpr: Int32 = -1
    /// A `$name` here declares (parameters, `foreach`'s variable); a word here is a key (hashtable), a member (enum).
    var expectName = false
    /// Parameters: whose (-1: the script's).
    var owner: Int32 = -1
    /// A type literal's name tokens.
    var typeFirst: Int32 = -1
    var typeLast: Int32 = -1
    var dotted = false
    /// Opened where a statement starts (`[int]$x = 1`).
    var atStatement = false
  }

  let unit: Unit
  let count: Int
  var file = ScriptFile()
  var frames: [Frame] = []
  var i = 0
  var pendingFunction: Int32 = -1
  /// A type literal that opens a statement was just closed before `$`: a typed declaration follows.
  var typedDeclarationNext = false
  var pendingClass: Int32 = -1
  var pendingIsEnum = false
  /// Where a pending declaration's `(` would be: `param(`, `function f(`, `foreach (`.
  var pendingParamAt = -1
  var pendingFunctionParen = -1
  var pendingForeachAt = -1
  var declaredLocals: [Int32: Set<Name>] = [:]
  /// The last type literal closed: its name tokens and its `]`.
  var lastType: (first: Int32, last: Int32, close: Int)? = nil

  static let scopes: Set<String> = ["script", "global", "local", "private", "using", "env", "function", "variable", "alias"]
  static let assignments: Set<String> = ["=", "+=", "-=", "*=", "/=", "%=", "??="]
  /// Import-Module's switches: any other parameter takes a value.
  static let importSwitches: Set<String> = [
    "force", "global", "passthru", "disablenamechecking", "ascustomobject", "noclobber", "skipeditioncheck", "verbose", "debug", "usewindowspowershell",
  ]

  init(unit: Unit) {
    self.unit = unit
    count = unit.tokens.count
  }

  // MARK: Tokens

  @inline(__always) func touches(_ at: Int) -> Bool { at > 0 && at < count && unit.touchesPrevious(at) }
  @inline(__always) func kind(_ at: Int) -> TokenKind? { at >= 0 && at < count ? unit.tokens[at].kind : nil }
  func text(_ at: Int) -> String { unit.string(at) }
  func lower(_ at: Int) -> String { at >= 0 && at < count ? unit.string(at).lowercased() : "" }

  func isWord(_ at: Int) -> Bool {
    guard let kind = kind(at) else { return false }
    return kind == .identifier || kind == .keyword || kind == .declarationKeyword
  }

  func isPunct(_ at: Int, _ text: String) -> Bool { kind(at) == .punctuation && unit.string(at) == text }
  func isOpen(_ at: Int, _ text: String) -> Bool { (kind(at) == .open) && unit.string(at) == text }

  @inline(__always) var top: Frame {
    get { frames[frames.count - 1] }
    set { frames[frames.count - 1] = newValue }
  }

  /// A line break before the token that ends a statement: not after a backtick, a `|`, a `,`, an assignment or an
  /// operator, nor before a `|` (PowerShell 7's leading pipe).
  func endsStatement(_ at: Int) -> Bool {
    guard at > 0, unit.startsLine(at) else { return false }
    if isPunct(at, "|") { return false }
    let previous = at - 1
    if kind(previous) == .punctuation {
      let p = text(previous)
      if p == "`" || p == "|" || p == "," || p == "&&" || p == "||" { return false }
      // An operator continues an expression; among a command's arguments `*` and `/` are words (`Format-Table *`).
      if top.command < 0, p.hasSuffix("=") && p != "==" || p == "+" || p == "*" || p == "/" { return false }
    }
    return true
  }

  // MARK: Declarations

  @discardableResult
  mutating func declare(_ kind: DeclKind, _ token: Int, parent: Int32, isLocal: Bool = false, name: Name? = nil, statement: Int? = nil) -> Int32 {
    var decl = Decl(kind: kind, name: name ?? unit.lowerHash(token), nameToken: Int32(token), first: Int32(statement ?? token), parent: parent)
    decl.isLocal = isLocal
    decl.end = Int32(token + 1)
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    return index
  }

  /// A variable's assignment: the function's local the first time (a use of it after), the script's otherwise.
  mutating func define(_ token: Int, scope: String?, statement: Int, valueStart: Int) {
    let fn = top.function
    let key = unit.lowerHash(token)
    var index: Int32
    if scope == "env" {
      index = declare(.variable, token, parent: -1, name: lowerName("env:" + text(token)), statement: statement)
    } else if scope == "script" || scope == "global" || fn < 0 {
      index = declare(.variable, token, parent: -1, statement: statement)
    } else if declaredLocals[fn]?.contains(key) == true {
      file.uses[Int32(token)] = .variable(function: fn)
      return
    } else {
      declaredLocals[fn, default: []].insert(key)
      index = declare(.variable, token, parent: fn, isLocal: true, statement: statement)
    }
    if let type = lastType, type.close == statement - 1 || type.close == token - 2 {
      file.declaredTypes[index] = (type.first, type.last)
    }
    // Several names given one value each (`$a, $b = 1, 2`): no one value is known.
    file.values[index] = valueStart < 0 ? (-1, -1) : (Int32(valueStart), Int32(statementEnd(from: valueStart)))
  }

  /// Where the statement from a token ends: the line's end, or a `;` at the same depth.
  func statementEnd(from start: Int) -> Int {
    var depth = 0
    var k = start
    while k < count {
      if k > start, depth == 0, unit.startsLine(k) { break }
      switch unit.tokens[k].kind {
      case .open, .interpolationOpen: depth += 1
      case .close, .interpolationClose:
        if depth == 0 { return k }
        depth -= 1
      case .punctuation where depth == 0 && (isPunct(k, ";") || isPunct(k, "|")): return k
      default: break
      }
      k += 1
    }
    return k
  }

  mutating func useCommand(_ token: Int, functionsOnly: Bool = false) {
    file.uses[Int32(token)] = .command(function: top.function, functionsOnly: functionsOnly)
    file.calls[top.function, default: []].insert(unit.lowerHash(token))
  }

  mutating func expr(_ value: ScriptExpr, endsAt token: Int) -> Int32 {
    let index = Int32(file.exprs.count)
    file.exprs.append(value)
    file.endsAt[Int32(token)] = index
    return index
  }

  // MARK: Reading

  mutating func parseFile() {
    frames = [Frame(kind: .top, function: -1)]
    while i < count { step() }
    if unit.path.lowercased().hasSuffix(".psd1") { readManifest() }
  }

  mutating func push(_ kind: Kind, atCommand: Bool) {
    var frame = Frame(kind: kind, function: top.function, classDecl: top.classDecl)
    frame.atCommand = atCommand
    frames.append(frame)
  }

  mutating func pop(_ close: Int) {
    guard frames.count > 1 else { return }
    let popped = frames.removeLast()
    if popped.kind == .function, popped.function >= 0, unit.decls[Int(popped.function)].bodyClose < 0 {
      unit.decls[Int(popped.function)].bodyClose = Int32(close)
    }
    if popped.callExpr >= 0 { file.endsAt[Int32(close)] = popped.callExpr }
    if popped.kind == .type { closeType(popped, close) }
    if popped.kind == .paren || popped.kind == .subexpression { _ = expr(.other, endsAt: close) }
  }

  mutating func newStatement() {
    top.atCommand = true
    top.command = -1
    top.special = .none
    top.positional = 0
    top.pendingParameter = ""
    if top.kind == .hashtable || top.kind == .enumBody { top.expectName = true }
  }

  mutating func step() {
    let t = i
    i += 1
    if endsStatement(t) {
      switch top.kind {
      case .top, .block, .function, .subexpression, .hashtable, .classBody, .enumBody: newStatement()
      default: break
      }
    }
    switch unit.tokens[t].kind {
    case .punctuation: punctuation(t)
    case .open: open(t)
    case .close: closeBracket(t)
    case .interpolationOpen: push(.subexpression, atCommand: true)
    case .interpolationClose: popTo([.subexpression], t)
    case .identifier, .keyword, .declarationKeyword: word(t)
    case .string:
      if top.kind == .hashtable, top.expectName {
        top.expectName = false
      } else if top.command >= 0 {
        argument(t)
      } else {
        top.atCommand = false
      }
    default:
      if top.command >= 0 { argument(t) } else { top.atCommand = false }
    }
  }

  mutating func popTo(_ kinds: [Kind], _ close: Int) {
    guard let index = frames.lastIndex(where: { kinds.contains($0.kind) }), index > 0 else { return }
    while frames.count > index + 1 { pop(close) }
    pop(close)
  }

  // MARK: Punctuation

  mutating func punctuation(_ t: Int) {
    let s = text(t)
    switch s {
    case "$":
      variable(t)
    case "@":
      if touches(t + 1), isOpen(t + 1, "(") {
        i = t + 2
        push(.subexpression, atCommand: true)
      } else if touches(t + 1), isOpen(t + 1, "{") {
        i = t + 2
        push(.hashtable, atCommand: false)
        top.expectName = true
      } else if touches(t + 1), isWord(t + 1) {
        // `@params`: splatting.
        file.uses[Int32(t + 1)] = .variable(function: top.function)
        i = t + 2
      }
    case ",":
      if top.kind == .parameters { top.expectName = true }
    case ";":
      switch top.kind {
      case .paren, .call, .index, .type, .parameters: top.atCommand = true
      default: newStatement()
      }
    case "|", "||", "&&":
      top.atCommand = true
      top.command = -1
      top.special = .none
    case "&":
      // The call operator: a command by name, a script by its path.
      if top.atCommand {
        if isWord(t + 1) {
          useCommand(t + 1)
          i = t + 2
          beginArguments(t + 1)
        } else if kind(t + 1) == .string || isPunct(t + 1, "$") || kind(t + 1) == .punctuation {
          if let run = pathRun(from: t + 1) { noteSource(.run, run) }
          top.atCommand = false
          top.command = Int32(t)
        }
      }
    case ".":
      if top.atCommand, t + 1 < count, !touches(t + 1) {
        // Dot-sourcing: a file's path, or a function by name.
        if isWord(t + 1), !(t + 2 < count && touches(t + 2)) {
          useCommand(t + 1)
          i = t + 2
          beginArguments(t + 1)
        } else if let run = pathRun(from: t + 1) {
          noteSource(.source, run)
          top.atCommand = false
          top.command = Int32(t)
        }
        return
      }
      member(t)
    case "::":
      staticMember(t)
    case "-":
      // A parameter's name at a call.
      if top.command >= 0, touches(t + 1), isWord(t + 1), !(t > 0 && touches(t) && kind(t - 1) != .punctuation) {
        let name = t + 1
        i = t + 2
        let command = top.command
        if kind(Int(command)) != .punctuation { file.uses[Int32(name)] = .parameter(command: command) }
        if top.special != .none { top.pendingParameter = lower(name) }
        // `-Name:value`.
        if isPunct(i, ":"), touches(i) { i += 1 }
      }
    default:
      if top.command >= 0, isPathStart(t) {
        argument(t)
      } else if Self.assignments.contains(s) || s == "++" || s == "--" {
        // `$x.Y = …`, `$a[0] = …`: what follows is a pipeline.
        if s.hasSuffix("=") {
          top.atCommand = true
          top.command = -1
        }
      } else if s.hasPrefix(".\\") || s.hasPrefix("./") || s.hasPrefix("..") {
        if top.atCommand, let run = pathRun(from: t) {
          // `.\build.ps1 -Config x`: runs a script.
          noteSource(.run, run)
          top.atCommand = false
          top.command = Int32(t)
        }
      }
    }
  }

  func isPathStart(_ t: Int) -> Bool {
    let s = text(t)
    return s.hasPrefix(".\\") || s.hasPrefix("./") || s.hasPrefix("..") || s == "\\" || s == "/"
  }

  /// A word's tokens from `start`: what touches it, or a `(…)`.
  func pathRun(from start: Int) -> (first: Int, last: Int)? {
    guard start < count else { return nil }
    if isOpen(start, "(") {
      var depth = 0
      var k = start
      while k < count {
        if kind(k) == .open { depth += 1 }
        if kind(k) == .close {
          depth -= 1
          if depth == 0 { return (start, k) }
        }
        k += 1
      }
      return nil
    }
    var k = start
    while k + 1 < count, touches(k + 1), kind(k + 1) != .close || text(k + 1) == "}", !isPunct(k + 1, ";"), !isPunct(k + 1, "|") { k += 1 }
    return (start, k)
  }

  mutating func noteSource(_ kind: ScriptSource.Kind, _ run: (first: Int, last: Int)) {
    let written = unit.source.string(from: unit.tokens[run.first].start, to: unit.tokens[run.last].end)
    let pattern = Self.valuePattern(written)
    let index = Int32(file.sources.count)
    file.sources.append(ScriptSource(kind: kind, first: Int32(run.first), last: Int32(run.last), pattern: pattern, function: top.function))
    for k in run.first...run.last {
      // The path's own words and strings; its variables are read as variables.
      let previous = k > run.first ? text(k - 1) : ""
      if self.kind(k) == .string || (isWord(k) && previous != "$" && previous != ":" && lower(k) != "join-path" && lower(k) != "split-path") {
        if file.uses[Int32(k)] == nil { file.uses[Int32(k)] = .path(index) }
      }
    }
  }

  // MARK: Brackets

  mutating func open(_ t: Int) {
    let s = text(t)
    if s == "{" {
      if pendingFunction >= 0, top.kind != .parameters {
        let fn = pendingFunction
        pendingFunction = -1
        push(.function, atCommand: true)
        top.function = fn
        unit.decls[Int(fn)].bodyOpen = Int32(t)
        return
      }
      if pendingClass >= 0 {
        let decl = pendingClass
        pendingClass = -1
        push(pendingIsEnum ? .enumBody : .classBody, atCommand: false)
        top.classDecl = decl
        top.function = -1
        top.expectName = pendingIsEnum
        unit.decls[Int(decl)].bodyOpen = Int32(t)
        return
      }
      if top.kind == .classBody {
        // A method's body without a header we read: still the class's.
        push(.block, atCommand: true)
        return
      }
      if top.kind == .hashtable { top.expectName = false }
      push(.block, atCommand: true)
      return
    }
    if s == "(" {
      if t == pendingParamAt || t == pendingFunctionParen {
        // `param(…)`, `function f(…)`.
        let owner = t == pendingParamAt ? top.function : pendingFunction
        pendingParamAt = -1
        pendingFunctionParen = -1
        push(.parameters, atCommand: false)
        top.owner = owner
        top.expectName = true
        return
      }
      if t == pendingForeachAt {
        pendingForeachAt = -1
        push(.paren, atCommand: false)
        top.expectName = true
        return
      }
      if t > 0, touches(t), isPunct(t - 1, "$") {
        push(.subexpression, atCommand: true)
        return
      }
      if t > 0, touches(t), let callee = file.endsAt[Int32(t - 1)], isWord(t - 1) {
        // A method's arguments.
        push(.call, atCommand: false)
        top.callExpr = callee
        return
      }
      if top.special == .importModule, top.command >= 0 {
        // `Import-Module (Join-Path $PSScriptRoot x.psm1)`: the path; the parentheses are still read.
        let at = i
        argument(t)
        i = at
      }
      let inType = top.kind == .type
      push(.paren, atCommand: !inType)
      return
    }
    if s == "[" {
      // `$a[0]`, `(…)[1]`: an index; else a type literal or an attribute.
      if t > 0, touches(t), let previous = kind(t - 1), previous == .identifier || previous == .keyword || previous == .close || previous == .string {
        if top.kind == .type {
          push(.type, atCommand: false)
          return
        }
        push(.index, atCommand: false)
        return
      }
      let atStatement = top.atCommand || top.kind == .parameters || top.kind == .classBody
      push(.type, atCommand: false)
      top.atStatement = atStatement
    }
  }

  mutating func closeBracket(_ t: Int) {
    switch text(t) {
    case "}": popTo([.block, .function, .hashtable, .classBody, .enumBody], t)
    case ")": popTo([.paren, .subexpression, .call, .parameters], t)
    case "]": popTo([.type, .index], t)
    default: break
    }
    if top.kind != .classBody, !typedDeclarationNext { top.atCommand = false }
    typedDeclarationNext = false
  }

  mutating func closeType(_ frame: Frame, _ close: Int) {
    guard frame.typeFirst >= 0 else { return }
    file.uses[frame.typeLast] = .type(first: frame.typeFirst)
    lastType = (frame.typeFirst, frame.typeLast, close)
    if !frame.dotted { _ = expr(.type(frame.typeFirst, frame.typeLast), endsAt: close) }
    // `[int]$x = 1`, `[ValidateSet()][string]$s`: a declaration may follow.
    // `[CmdletBinding()]param(` too, with no space between.
    if frame.atStatement, close + 1 < count, isPunct(close + 1, "$") || isOpen(close + 1, "[") || lower(close + 1) == "param" {
      top.atCommand = true
      typedDeclarationNext = true
    }
  }

  // MARK: Names

  mutating func variable(_ t: Int) {
    guard t + 1 < count, touches(t + 1) else { return }
    var name = t + 1
    var scope: String?
    if isOpen(name, "{") {
      // `${name}`.
      var close = name + 1
      while close < count, !(kind(close) == .close && text(close) == "}") { close += 1 }
      i = close + 1
      // `${env:PATH}`, `${script:x}`; a name with spaces or symbols (`${my var}`) isn't followed.
      if close == name + 4, isWord(name + 1), isPunct(name + 2, ":"), isWord(name + 3), Self.scopes.contains(lower(name + 1)) {
        scope = lower(name + 1)
        name += 3
      } else {
        guard close == name + 2, isWord(name + 1) else { return }
        name += 1
      }
    } else {
      guard isWord(name) else { return }
      if isPunct(name + 1, ":"), touches(name + 1), touches(name + 2), isWord(name + 2), Self.scopes.contains(lower(name)) {
        scope = lower(name)
        name += 2
      }
      i = name + 1
    }
    let f = top
    if f.kind == .parameters, f.expectName {
      // A parameter.
      top.expectName = false
      let owner = f.owner
      let key = unit.lowerHash(name)
      let decl: Int32
      if owner >= 0 {
        decl = declare(.variable, name, parent: owner, isLocal: true, statement: t)
        file.parameters.insert(decl)
        declaredLocals[owner, default: []].insert(key)
      } else {
        decl = declare(.variable, name, parent: -1, statement: t)
        // The script's own `param(…)` (not a script block's at the top level).
        if frames.count == 2 { file.parameters.insert(decl) }
      }
      if let type = lastType, type.close == t - 1 { file.declaredTypes[decl] = (type.first, type.last) }
      return
    }
    if f.kind == .paren, f.expectName {
      // `foreach ($item in …)`.
      top.expectName = false
      define(name, scope: scope, statement: t, valueStart: i)
      return
    }
    if f.atCommand || f.kind == .classBody, scope != "env" || isAssignment(i) {
      if isAssignment(i) {
        if f.kind == .classBody {
          classProperty(name, statement: t)
          return
        }
        define(name, scope: scope, statement: t, valueStart: i + 1)
        i += 1
        top.atCommand = true
        top.command = -1
        return
      }
      if f.kind == .classBody {
        classProperty(name, statement: t)
        return
      }
      // `$a, $b = 1, 2`.
      if isPunct(i, ",") {
        var names = [(name, scope)]
        var k = i
        while isPunct(k, ","), isPunct(k + 1, "$"), touches(k + 2), isWord(k + 2) {
          names.append((k + 2, nil))
          k += 3
        }
        if isAssignment(k) {
          for (token, scope) in names { define(token, scope: scope, statement: t, valueStart: -1) }
          i = k + 1
          top.atCommand = true
          top.command = -1
          return
        }
      }
    }
    use(name, scope: scope)
    if top.command < 0 { top.atCommand = false }
  }

  func isAssignment(_ at: Int) -> Bool { kind(at) == .punctuation && Self.assignments.contains(text(at)) }

  mutating func use(_ name: Int, scope: String?) {
    let fn = top.function
    switch scope {
    case "env": file.uses[Int32(name)] = .environment
    case "script", "global": file.uses[Int32(name)] = .scriptVariable
    case "function":
      file.uses[Int32(name)] = .command(function: fn, functionsOnly: true)
      return
    case "alias":
      return
    default:
      if lower(name) == "this", top.classDecl >= 0 {
        file.uses[Int32(name)] = .this(class: top.classDecl)
        _ = expr(.this(top.classDecl), endsAt: name)
        return
      }
      file.uses[Int32(name)] = .variable(function: fn)
    }
    _ = expr(.variable(Int32(name)), endsAt: name)
  }

  /// `value.name`: a member of what's before it.
  mutating func member(_ t: Int) {
    guard t > 0, touches(t), touches(t + 1), isWord(t + 1), let receiver = file.endsAt[Int32(t - 1)] else { return }
    let name = t + 1
    i = name + 1
    file.uses[Int32(name)] = .member(receiver: receiver)
    _ = expr(.member(receiver, Int32(name)), endsAt: name)
  }

  /// `[Type]::name`.
  mutating func staticMember(_ t: Int) {
    guard t + 1 < count, isWord(t + 1), let type = lastType, type.close == t - 1 else { return }
    let name = t + 1
    i = name + 1
    file.uses[Int32(name)] = .staticMember(type: type.last)
    _ = expr(.staticMember(type.first, type.last, Int32(name)), endsAt: name)
  }

  mutating func word(_ t: Int) {
    let w = lower(t)
    let f = top
    switch f.kind {
    case .hashtable where f.expectName:
      top.expectName = false
      return
    case .enumBody where f.expectName:
      top.expectName = false
      declare(.enumCase, t, parent: f.classDecl)
      return
    case .classBody:
      classMember(t)
      return
    case .type:
      if f.typeFirst < 0 {
        top.typeFirst = Int32(t)
      } else if t > 0, isPunct(t - 1, ".") {
        top.dotted = true
      } else {
        return
      }
      top.typeLast = Int32(t)
      return
    default:
      break
    }
    if f.atCommand {
      switch w {
      case "function", "filter", "workflow":
        functionDeclaration(t)
        return
      case "class", "enum":
        guard isWord(t + 1) else { return }
        pendingClass = declare(w == "class" ? .classType : .enumeration, t + 1, parent: -1, statement: t)
        pendingIsEnum = w == "enum"
        i = t + 2
        // `class A : B, I`.
        if isPunct(i, ":") {
          var k = i + 1
          var bases: [(Int32, Int32)] = []
          while isWord(k) {
            var last = k
            while isPunct(last + 1, "."), isWord(last + 2) { last += 2 }
            file.uses[Int32(last)] = .type(first: Int32(k))
            bases.append((Int32(k), Int32(last)))
            k = last + 1
            if isPunct(k, ",") { k += 1 } else { break }
          }
          file.bases[pendingClass] = bases
          i = k
        }
        top.atCommand = false
        return
      case "param":
        if isOpen(t + 1, "(") { pendingParamAt = t + 1 }
        top.atCommand = false
        return
      case "foreach":
        if t > 0, isPunct(t - 1, "|") { break }
        pendingForeachAt = isOpen(t + 1, "(") ? t + 1 : -1
        top.atCommand = false
        return
      case "if", "elseif", "while", "until", "switch", "for", "catch", "trap":
        top.atCommand = false
        return
      case "else", "try", "finally", "do", "begin", "process", "end", "dynamicparam", "clean", "in":
        return
      case "return", "throw", "exit", "break", "continue":
        return
      case "using":
        if lower(t + 1) == "module", let run = pathRun(from: t + 2) {
          noteSource(.module, run)
          i = run.last + 1
        } else {
          i = t + 1
          while i < count, !unit.startsLine(i) { i += 1 }
        }
        return
      default:
        break
      }
      // A command's name: its tokens touching (`Get-Item`, `Microsoft.PowerShell.Utility\Get-Item`).
      var last = t
      while last + 1 < count, touches(last + 1), isWord(last + 1) || isPunct(last + 1, ".") || isPunct(last + 1, "\\") || isPunct(last + 1, ":") { last += 1 }
      if last != t, text(last).hasSuffix("ps1") || (t...last).contains(where: { text($0).contains("\\") || text($0).contains("/") }) {
        noteSource(.run, (t, last))
        i = last + 1
        top.atCommand = false
        top.command = Int32(t)
        return
      }
      useCommand(last)
      i = last + 1
      beginArguments(last)
      return
    }
    if top.command >= 0 { argument(t) }
  }

  mutating func beginArguments(_ name: Int) {
    top.atCommand = false
    top.command = Int32(name)
    top.positional = 0
    top.pendingParameter = ""
    switch lower(name) {
    case "import-module", "ipmo": top.special = .importModule
    case "set-alias", "new-alias", "sal", "nal": top.special = .alias
    case "export-modulemember": top.special = .exportMember
    case "new-object": top.special = .newObject
    default: top.special = .none
    }
  }

  /// A word, string or path among a command's arguments.
  mutating func argument(_ t: Int) {
    guard top.special != .none else { return }
    let parameter = top.pendingParameter
    switch top.special {
    case .importModule:
      if parameter.isEmpty || parameter == "name" || parameter == "fullyqualifiedname" {
        if parameter.isEmpty, top.positional > 0 { return }
        top.positional += 1
        top.pendingParameter = ""
        if let run = pathRun(from: t) { noteSource(.module, run) }
      } else if !Self.importSwitches.contains(parameter) {
        // A value parameter's value.
        top.pendingParameter = ""
        if let run = pathRun(from: t) { i = run.last + 1 }
      } else {
        top.pendingParameter = ""
        top.positional += 1
        if top.positional == 1, let run = pathRun(from: t) { noteSource(.module, run) }
      }
    case .alias:
      guard isWord(t) || kind(t) == .string else { return }
      let isName = parameter == "name" || (parameter.isEmpty && top.positional == 0)
      let isValue = parameter == "value" || (parameter.isEmpty && top.positional == 1)
      if parameter.isEmpty { top.positional += 1 }
      top.pendingParameter = ""
      if isName, isWord(t) {
        let alias = declare(.typeAlias, t, parent: -1, statement: Int(top.command))
        file.values[alias] = (-1, -1)
      } else if isValue, isWord(t) {
        useCommand(t)
        if let alias = unit.decls.indices.last, unit.decls[alias].kind == .typeAlias, file.values[Int32(alias)]?.start == -1 {
          file.values[Int32(alias)] = (Int32(t), Int32(t + 1))
        }
      }
    case .newObject:
      // `New-Object Box`, `New-Object -TypeName Box`: a type of one word (a dotted one is .NET's).
      guard parameter == "typename" || (parameter.isEmpty && top.positional == 0) else { return }
      if parameter.isEmpty { top.positional += 1 }
      top.pendingParameter = ""
      if isWord(t), !(touches(t + 1) && isPunct(t + 1, ".")), !(t > 0 && touches(t) && isPunct(t - 1, ".")) {
        file.uses[Int32(t)] = .type(first: Int32(t))
      }
    case .exportMember:
      guard parameter == "function" || (parameter.isEmpty && top.positional == 0) else { return }
      if isWord(t) || kind(t) == .string {
        var written = text(t)
        if kind(t) == .string {
          written = String(written.dropFirst().dropLast())
        } else {
          // `Get-*`: the word and the wildcards touching it.
          var last = t
          while last + 1 < count, touches(last + 1), isWord(last + 1) || isPunct(last + 1, "*") { last += 1 }
          written = unit.source.string(from: unit.tokens[t].start, to: unit.tokens[last].end)
          i = last + 1
        }
        if written.contains("*") {
          file.exportPatterns.append(written.lowercased())
        } else {
          if file.exportedFunctions == nil { file.exportedFunctions = [] }
          file.exportedFunctions?.insert(lowerName(written))
          if isWord(t) { useCommand(t, functionsOnly: true) }
        }
        if file.exportedFunctions == nil { file.exportedFunctions = [] }
      }
    default:
      break
    }
  }

  mutating func functionDeclaration(_ t: Int) {
    // `function global:Name`, `function Get-Thing`.
    var name = t + 1
    guard isWord(name) else { return }
    if isPunct(name + 1, ":"), touches(name + 1), isWord(name + 2), Self.scopes.contains(lower(name)) { name += 2 }
    var last = name
    while last + 1 < count, touches(last + 1), isWord(last + 1) || isPunct(last + 1, ".") { last += 1 }
    let decl = declare(.function, last == name ? name : name, parent: top.function, statement: t)
    if last != name {
      // A name with dots (`Get.Thing`): its whole text is the name.
      let written = unit.source.string(from: unit.tokens[name].start, to: unit.tokens[last].end)
      unit.decls[Int(decl)].name = lowerName(written)
    }
    pendingFunction = decl
    pendingFunctionParen = last + 1
    i = last + 1
    top.atCommand = false
  }

  // MARK: Classes

  /// A member's start in a class's body: `[type]$Name`, `static [type] Method(…) {…}`, `ClassName(…) {…}`.
  mutating func classMember(_ t: Int) {
    let w = lower(t)
    if w == "static" || w == "hidden" { return }
    guard isOpen(t + 1, "(") else { return }
    let method = declare(.function, t, parent: top.classDecl, statement: t)
    if let type = lastType, type.close == t - 1 || (t >= 2 && type.close == t - 2) { file.declaredTypes[method] = (type.first, type.last) }
    i = t + 2
    push(.parameters, atCommand: false)
    top.owner = method
    top.expectName = true
    pendingFunction = method
  }

  mutating func classProperty(_ name: Int, statement: Int) {
    let decl = declare(.variable, name, parent: top.classDecl, statement: statement)
    if let type = lastType, type.close == statement - 1 { file.declaredTypes[decl] = (type.first, type.last) }
    // A default value: an expression.
    if isAssignment(i) {
      i += 1
      push(.paren, atCommand: false)
      let end = statementEnd(from: i)
      while i < end { step() }
      if frames.count > 1, top.kind == .paren { frames.removeLast() }
    }
  }

  // MARK: Manifests

  /// A `.psd1`'s modules and exported functions: `RootModule`, `ModuleToProcess`, `NestedModules`, `FunctionsToExport`.
  mutating func readManifest() {
    var k = 0
    while k < count {
      guard isWord(k), isPunct(k + 1, "=") else {
        k += 1
        continue
      }
      let key = lower(k)
      var strings: [Int] = []
      var j = k + 2
      let end = max(statementEnd(from: j), j + 1)
      while j < end, j < count {
        if kind(j) == .string { strings.append(j) }
        j += 1
      }
      // A list over several lines.
      if isPunct(k + 2, "@"), isOpen(k + 3, "(") {
        strings = []
        var depth = 0
        j = k + 3
        while j < count {
          if kind(j) == .open { depth += 1 }
          if kind(j) == .close {
            depth -= 1
            if depth == 0 { break }
          }
          if kind(j) == .string { strings.append(j) }
          j += 1
        }
      }
      switch key {
      case "rootmodule", "moduletoprocess", "nestedmodules":
        for s in strings {
          let value = String(text(s).dropFirst().dropLast())
          file.manifestModules.append(value)
          noteSource(.module, (s, s))
        }
      case "functionstoexport":
        let names = strings.map { String(text($0).dropFirst().dropLast()) }
        if names.contains(where: { $0.contains("*") }) {
          file.manifestFunctions = nil
        } else {
          file.manifestFunctions = Set(names.map { lowerName($0) })
        }
      default:
        break
      }
      k = max(j, k + 2)
    }
  }

  // MARK: Values as paths

  /// A path written in PowerShell as a pattern (`ScriptSource.pattern`): a literal or expandable string, a bare word,
  /// `$PSScriptRoot`, `(Join-Path a b)`, `(Split-Path [-Parent] p)`, `(Resolve-Path p).Path`; nil when it can't be told.
  static func valuePattern(_ written: String) -> String? {
    var text = written.trimmingCharacters(in: .whitespaces)
    if text.hasSuffix(".Path") || text.hasSuffix(".ProviderPath") || text.hasSuffix(".FullName") {
      text = String(text[..<text.lastIndex(of: ".")!])
    }
    while text.hasPrefix("("), text.hasSuffix(")"), balanced(String(text.dropFirst().dropLast())) {
      text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }
    if text.hasPrefix("$("), text.hasSuffix(")") { return valuePattern(String(text.dropFirst(2).dropLast())) }
    let words = splitWords(text)
    guard let head = words.first?.lowercased() else { return nil }
    switch head {
    case "join-path":
      var parts: [String] = []
      var k = 1
      while k < words.count {
        let w = words[k]
        if w.hasPrefix("-") {
          k += w.lowercased() == "-resolve" ? 1 : 2
          if ["-path", "-childpath", "-additionalchildpath"].contains(w.lowercased()), k - 1 < words.count { parts.append(words[k - 1]) }
          continue
        }
        parts.append(w)
        k += 1
      }
      guard parts.count >= 2 else { return nil }
      var result: [String] = []
      for part in parts {
        guard let pattern = valuePattern(part) else { return nil }
        result.append(pattern)
      }
      return result.joined(separator: "/")
    case "split-path":
      let rest = words.dropFirst().filter { !$0.hasPrefix("-") }
      let flags = words.dropFirst().filter { $0.hasPrefix("-") }.map { $0.lowercased() }
      guard rest.count == 1, flags.allSatisfy({ $0 == "-parent" || $0 == "-path" }) else { return nil }
      let lower = rest[0].lowercased()
      if lower.contains("myinvocation.mycommand") || lower == "$pscommandpath" { return "\u{1}" }
      guard let inner = valuePattern(rest[0]) else { return nil }
      return inner + "/.."
    case "resolve-path", "convert-path", "get-item":
      let rest = words.dropFirst().filter { !$0.hasPrefix("-") }
      guard rest.count == 1 else { return nil }
      return valuePattern(rest[0])
    default:
      guard words.count == 1 else { return nil }
      return ShellParser.pathPattern(text, dialect: .powerShell).map(stripScopes)
    }
  }

  /// `\u{3}script:x\u{3}` is the variable `x`.
  static func stripScopes(_ pattern: String) -> String {
    var result = pattern
    for scope in ["script:", "global:", "local:", "private:", "using:"] {
      result = result.replacingOccurrences(of: "\u{3}" + scope, with: "\u{3}", options: .caseInsensitive)
    }
    return result
  }

  static func balanced(_ text: String) -> Bool {
    var depth = 0
    for c in text {
      if c == "(" { depth += 1 }
      if c == ")" {
        depth -= 1
        if depth < 0 { return false }
      }
    }
    return depth == 0
  }

  /// Words split at spaces outside quotes and brackets.
  static func splitWords(_ text: String) -> [String] {
    var words: [String] = []
    var current = ""
    var depth = 0
    var quote: Character?
    for c in text {
      if let q = quote {
        current.append(c)
        if c == q { quote = nil }
        continue
      }
      if c == "\"" || c == "'" { quote = c }
      if c == "(" || c == "[" || c == "{" { depth += 1 }
      if c == ")" || c == "]" || c == "}" { depth -= 1 }
      if (c == " " || c == "\t"), depth == 0 {
        if !current.isEmpty { words.append(current) }
        current = ""
        continue
      }
      current.append(c)
    }
    if !current.isEmpty { words.append(current) }
    return words
  }

  // MARK: Shape

  func shape() -> UInt64 {
    var hash: UInt64 = 1469598103934665603
    func mix(_ value: UInt64) { hash = (hash ^ value) &* 1099511628211 }
    for decl in unit.decls {
      mix(decl.name)
      mix(UInt64(decl.kind.rawValue) << 2 | UInt64(decl.parent >= 0 ? 2 : 0) | (decl.isLocal ? 1 : 0))
    }
    for source in file.sources { mix(hashName(source.pattern ?? "?")) }
    if let exported = file.exportedFunctions { for name in exported.sorted() { mix(name) } }
    for module in file.manifestModules { mix(hashName(module)) }
    return hash
  }
}
