import CodeModel
import CodeScan
import Foundation

/// sh, bash and zsh for the core: a file is read whole by `ShellParser` over `ScriptTokens`' words, which notes what
/// each name is (a command, a variable's use, a definition) in `ScriptFile`. The declarations are functions
/// (`f() {…}`, `function f {…}`), variables' assignments (`x=…`, `local`/`declare`/`typeset`/`export`/`readonly`,
/// `read`, `for`, `getopts`, `mapfile`, `printf -v`, arithmetic `((x = …))`), `local`s (a declaration with `isLocal`
/// and its function as `parent`) and aliases.
final class ShellSyntax: LanguageSyntax {
  let profile = LexProfile.profile(forLanguage: "shell")!
  let parametersHaveLabels = false
  /// Files read, for the model to know its answers about a file's tokens went stale.
  let parses = ScriptCounter()

  func parse(_ unit: CodeModel.Unit) -> UInt64 {
    parses.increment()
    var parser = ShellParser(unit: unit)
    parser.parseFile()
    unit.scans[ScriptFile.key] = parser.file
    return parser.shape()
  }

  func codeTokens(_ source: SourceFile) -> [Token] { ScriptTokens.read(source, dialect: .shell) }

  func evaluateCondition(_ unit: CodeModel.Unit, _ i: inout Int) -> Bool { true }

  func conditional(_ unit: CodeModel.Unit, _ i: Int) -> ConditionalDirective { .none }
}

/// How many files a syntax has read, across threads (`Project.parse` reads in parallel).
final class ScriptCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

/// A forgiving reader of a shell file: one pass over the tokens with a stack of what's open (a group, a subshell, a
/// substitution, arithmetic, a test, a function's body), knowing at each word whether a command's name goes there.
/// What it can't read it steps over.
struct ShellParser {
  let unit: Unit
  let count: Int
  let file = ScriptFile()

  enum FrameKind {
    case top, group, subshell, substitution, backtick, arithmetic, test, singleTest, expansion, array, index, function
  }

  /// What the words of a simple command are, after its name.
  enum Mode: Equatable {
    case arguments
    /// `local`, `declare`, `typeset`, `export`, `readonly`: names declared; `local` makes them the function's.
    case declare(isLocal: Bool, functions: Bool)
    case unset(functions: Bool)
    case read
    case getopts(seen: Int)
    case mapfile
    case printf(nameNext: Bool)
    case alias
    case unalias
    case autoload
    case source
    case trap(seen: Int)
    /// `let x=1 y+=x`: arithmetic words.
    case letWords
    /// `for x` / `select x`: the name, then `in` words.
    case forName
    case words
  }

  struct Frame {
    var kind: FrameKind
    /// The function whose scope this is (a declaration), -1 at the top.
    var function: Int32
    var atCommand = true
    var mode = Mode.arguments
    /// `case … in` is open in this frame: whether a pattern is being read, per open `case`.
    var cases: [Bool] = []
    /// Assignments read in this command so far, committed when it ends without a command name.
    var pending: [(token: Int32, value: (Int32, Int32))] = []
    var commandSeen = false
    /// `case word` read: `in` starts its patterns.
    var awaitingIn = false
    /// The command's name, -1 before it.
    var commandToken: Int32 = -1
    /// A function's declaration this frame is the body of.
    var body: Int32 = -1
    /// Arithmetic: parentheses open inside it, and how many `)` close it (`((…))`: 2, `"$((…))"`'s inner: 1).
    var depth = 0
    var closers = 1
  }

  var frames: [Frame] = []
  var i = 0
  /// Arrays declared associative (`declare -A m`): their subscripts are strings.
  var associative: Set<Name> = []
  /// Locals declared so far per function, to tell a local's later declarations from new ones.
  var declaredLocals: [Int32: Set<Name>] = [:]
  static let fpathName = name("fpath"), upperFpathName = name("FPATH")

  init(unit: Unit) {
    self.unit = unit
    count = unit.tokens.count
    let path = unit.path
    let fileName = (path as NSString).lastPathComponent
    file.isZsh = path.hasSuffix(".zsh") || fileName.hasPrefix(".z") || unit.source.count > 2 && firstLineNamesZsh(unit)
  }

  // MARK: Tokens

  @inline(__always) func byte(_ at: Int) -> UInt8 {
    guard at >= 0, at < count else { return 0 }
    return unit.source.text[unit.tokens[at].start]
  }

  @inline(__always) func isPunct(_ at: Int, _ text: StaticString) -> Bool {
    at < count && unit.tokens[at].kind == .punctuation && unit.isToken(at, text)
  }

  @inline(__always) func touches(_ at: Int) -> Bool { unit.touchesPrevious(at) }

  @inline(__always) func isWord(_ at: Int) -> Bool {
    guard at < count else { return false }
    let kind = unit.tokens[at].kind
    return kind == .identifier || kind == .keyword || kind == .declarationKeyword
  }

  @inline(__always) func isOpen(_ at: Int, _ b: UInt8) -> Bool { at < count && unit.tokens[at].kind == .open && byte(at) == b }
  @inline(__always) func isClose(_ at: Int, _ b: UInt8) -> Bool { at < count && unit.tokens[at].kind == .close && byte(at) == b }

  func text(_ at: Int) -> String { unit.string(at) }

  /// Whether a token is a variable's name: letters, digits and `_`, not starting with a digit.
  func isName(_ at: Int) -> Bool {
    guard at < count, unit.tokens[at].kind == .identifier || unit.tokens[at].kind == .keyword else { return false }
    let token = unit.tokens[at]
    guard ScriptTokens.isNameStart(unit.source.text[token.start]) else { return false }
    for k in token.start..<token.end where !ScriptTokens.isNameByte(unit.source.text[k]) { return false }
    return true
  }

  /// A line break before the token, not escaped by a `\` at the end of the line right before it.
  func startsCommandLine(_ at: Int) -> Bool {
    guard at > 0, unit.startsLine(at) else { return false }
    let previous = unit.tokens[at - 1]
    guard previous.kind == .punctuation, unit.source.text[previous.end - 1] == 0x5C else { return true }
    // A blank or comment line after the `\` ends the command there.
    var breaks = 0
    for k in previous.end..<unit.tokens[at].start where unit.source.text[k] == 0x0A { breaks += 1 }
    return breaks > 1
  }

  /// The separators that end a simple command: `;`, `&`, `|`, `&&`, `||`, `;;`, `|&`, `;&`.
  func isSeparator(_ at: Int) -> Bool {
    guard at < count, unit.tokens[at].kind == .punctuation else { return false }
    let token = unit.tokens[at]
    for k in token.start..<token.end {
      let b = unit.source.text[k]
      if b != 0x3B && b != 0x26 && b != 0x7C { return false }
    }
    // `&>`, `>&` are redirections; a lone `&` ends the command.
    return true
  }

  /// `;;`, `;&`, `;;&`, `;|` (CodeScan writes `;` alone): how many tokens it takes, 0 when it's none.
  func caseEnd(_ at: Int) -> Int {
    guard isPunct(at, ";") else { return isPunct(at, ";;") || isPunct(at, ";&") || isPunct(at, ";;&") || isPunct(at, ";|") ? 1 : 0 }
    var k = at + 1
    var text = ";"
    while k < count, k < at + 3, touches(k), unit.tokens[k].kind == .punctuation, unit.punctuation(k, madeOf: ";&|") {
      text += unit.string(k)
      k += 1
    }
    return [";;", ";&", ";;&", ";|"].contains(text) ? k - at : 0
  }

  @inline(__always) var top: Frame {
    get { frames[frames.count - 1] }
    set { frames[frames.count - 1] = newValue }
  }

  var function: Int32 { top.function }

  // MARK: Declarations

  @discardableResult
  mutating func declare(_ kind: DeclKind, _ token: Int, statement: Int, isLocal: Bool = false, parent: Int32 = -1, value: (Int32, Int32)? = nil) -> Int32 {
    var decl = Decl(kind: kind, name: unit.hash(token), nameToken: Int32(token), first: Int32(statement), parent: parent)
    decl.isLocal = isLocal
    decl.end = Int32(token + 1)
    let index = Int32(unit.decls.count)
    unit.decls.append(decl)
    if let value { file.values[index] = value }
    return index
  }

  /// A variable's definition at `token`: a local of the enclosing function when it's declared one (here or before in
  /// the function), else the script's.
  mutating func defineVariable(_ token: Int, statement: Int, local: Bool, value: (Int32, Int32)? = nil) {
    guard isName(token) else { return }
    let fn = function
    let key = unit.hash(token)
    if local {
      // `local x` again in the same function (another branch's) declares it again: uses after it find the nearest.
      declaredLocals[fn, default: []].insert(key)
      declare(.variable, token, statement: statement, isLocal: true, parent: fn, value: value)
      return
    }
    if declaredLocals[fn]?.contains(key) == true {
      // An assignment to a local declared before: a use of it.
      file.uses[Int32(token)] = .variable(function: fn)
      return
    }
    if key == Self.fpathName || key == Self.upperFpathName, let value { noteFunctionFolders(value) }
    declare(.variable, token, statement: statement, value: value)
  }

  mutating func useVariable(_ token: Int) {
    guard isName(token) else { return }
    file.uses[Int32(token)] = .variable(function: function)
  }

  mutating func useCommand(_ token: Int, functionsOnly: Bool = false) {
    guard isWord(token) else { return }
    // A word written into more (`pre$x`, `name"…"`) names no command.
    if token + 1 < count, touches(token + 1), unit.tokens[token + 1].kind == .string || isPunct(token + 1, "$") { return }
    file.uses[Int32(token)] = .command(function: function, functionsOnly: functionsOnly)
    file.calls[function, default: []].insert(unit.hash(token))
  }

  // MARK: Reading

  mutating func parseFile() {
    frames = [Frame(kind: .top, function: -1)]
    while i < count {
      step()
    }
    while frames.count > 1 { popFrame() }
    commit()
  }

  /// Ends the simple command being read: its assignments are definitions unless it had a command name.
  mutating func commit() {
    let pending = top.pending
    let isPrefix = top.commandSeen
    top.pending = []
    for (token, value) in pending {
      if isPrefix {
        useVariable(Int(token))
      } else {
        defineVariable(Int(token), statement: Int(token), local: false, value: value)
      }
    }
    top.commandSeen = false
    top.commandToken = -1
    top.mode = .arguments
    pendingAssociative = false
  }

  mutating func endCommand() {
    commit()
    top.atCommand = true
  }

  mutating func push(_ kind: FrameKind, atCommand: Bool) {
    var frame = Frame(kind: kind, function: function)
    frame.atCommand = atCommand
    frames.append(frame)
  }

  mutating func pushArithmetic(closers: Int) {
    push(.arithmetic, atCommand: false)
    frames[frames.count - 1].closers = closers
  }

  mutating func popFrame() {
    guard frames.count > 1 else { return }
    commit()
    let popped = frames.removeLast()
    if popped.body >= 0 {
      unit.decls[Int(popped.body)].bodyClose = Int32(min(i, count - 1))
      unit.decls[Int(popped.body)].end = Int32(min(i + 1, count))
    }
    switch popped.kind {
    case .group, .subshell, .function, .test, .singleTest:
      // A command ended: what follows is a redirection or a separator.
      top.atCommand = false
      top.commandSeen = true
    default:
      // Part of a word (`x=$(…)`, `${y}`, `(a b)`): the word's start decided.
      break
    }
  }

  /// Closes frames down to (and including) the innermost of these kinds.
  mutating func close(_ kinds: Set<FrameKind>) {
    guard let at = frames.lastIndex(where: { kinds.contains($0.kind) }), at > 0 else { return }
    while frames.count > at { popFrame() }
  }

  mutating func step() {
    let t = i
    let token = unit.tokens[t]
    if stopsAtLine, startsCommandLine(t) {
      // After a top-level `exit` or `exec` the shell reads no further: what follows is data (an embedded script).
      i = count
      return
    }
    if startsCommandLine(t), top.kind != .arithmetic, top.kind != .test, top.kind != .singleTest, top.kind != .expansion, top.kind != .array, top.kind != .index {
      if top.cases.last == false || top.cases.isEmpty {
        endCommand()
      }
    }
    if top.mode == .source, top.kind != .arithmetic, top.kind != .expansion, !continuesWord(t), startsPath(t) {
      // `source path`, `. path`: the path's word, whatever it starts with (`"$DIR/x.sh"`); its pieces are read as usual.
      top.mode = .arguments
      noteSource(from: t)
    }
    switch top.kind {
    case .arithmetic, .index:
      arithmetic(t)
      return
    case .expansion:
      expansion(t)
      return
    default:
      break
    }
    switch token.kind {
    case .punctuation:
      punctuation(t)
    case .open:
      open(t)
    case .close:
      closeToken(t)
    case .interpolationOpen:
      if unit.isToken(t, "`") {
        push(.backtick, atCommand: true)
        i += 1
      } else if isOpen(t + 1, 0x28), touches(t + 1) {
        // `"$((…))"`: arithmetic inside the substitution.
        push(.substitution, atCommand: false)
        pushArithmetic(closers: 1)
        i += 2
      } else {
        push(.substitution, atCommand: true)
        i += 1
      }
      if !touches(t) { wasWord() }
    case .interpolationClose:
      close([.substitution, .backtick])
      i += 1
    case .identifier, .keyword, .declarationKeyword:
      word(t)
    default:
      // A string, number: a word of the command, unless it's part of one (`x="…"`).
      if top.atCommand, top.cases.last != true, !touches(t) { top.atCommand = false; top.commandSeen = true }
      i += 1
    }
  }

  // MARK: Punctuation

  mutating func punctuation(_ t: Int) {
    if top.cases.last == true, top.kind != .test {
      // A case pattern: `a|b)`; `$x` in it is a use.
      if isPunct(t, "$") { dollar(t) } else { i += 1 }
      return
    }
    if isPunct(t, "$") {
      dollar(t)
      return
    }
    let ends = caseEnd(t)
    if ends > 0 {
      endCommand()
      if !top.cases.isEmpty { top.cases[top.cases.count - 1] = true }
      i += ends
      return
    }
    if isSeparator(t) {
      endCommand()
      i += 1
      return
    }
    if isPunct(t, "`") {
      if top.kind == .backtick { close([.backtick]) } else { push(.backtick, atCommand: true) }
      i += 1
      return
    }
    if isPunct(t, "!"), top.atCommand {
      i += 1
      return
    }
    if isPunct(t, "."), top.atCommand, top.kind != .test, !continuesWord(t) {
      // `. file`: sourcing.
      useCommand(t)
      top.atCommand = false
      top.commandSeen = true
      top.mode = .source
      i += 1
      return
    }
    // A redirection's target (`> file`, `2>&1`) is a word, not a command's name.
    i += 1
  }

  /// `$name`, `${…}`, `$(…)`, `$((…))`.
  mutating func dollar(_ t: Int) {
    let next = t + 1
    i = next
    guard next < count, touches(next) else { return }
    if isName(next) || (isWord(next) && unit.tokens[next].kind == .keyword) {
      useVariable(next)
      i = next + 1
      if top.atCommand, top.cases.last != true, !touches(t) { top.atCommand = false; top.commandSeen = true }
      return
    }
    if isOpen(next, 0x7B) {
      if !touches(t) { wasWordHere() }
      push(.expansion, atCommand: false)
      i = next + 1
      if top.kind == .expansion { readExpansionName() }
      return
    }
    if isOpen(next, 0x28) {
      if isOpen(next + 1, 0x28), touches(next + 1) {
        pushArithmetic(closers: 2)
        i = next + 2
      } else {
        push(.substitution, atCommand: true)
        i = next + 1
      }
      if !touches(t) { wasWord() }
      return
    }
  }

  /// A word that isn't a command's name starts here: the command has one.
  mutating func wasWordHere() {
    if top.atCommand, top.cases.last != true {
      top.atCommand = false
      top.commandSeen = true
    }
  }

  /// After a word that isn't a command's name: the command has one.
  mutating func wasWord() {
    let outer = frames.count - 2
    if outer >= 0, frames[outer].atCommand, frames[outer].cases.last != true {
      frames[outer].atCommand = false
      frames[outer].commandSeen = true
    }
  }

  /// `${#x}`, `${!x}`, `${x:-…}`, zsh's `${(j:,:)x}`, `${~x}`: the name after the flags.
  mutating func readExpansionName() {
    while i < count {
      if isOpen(i, 0x28) {
        // zsh's flags: `(j:,:)`.
        var depth = 0
        while i < count {
          if isOpen(i, 0x28) { depth += 1 } else if isClose(i, 0x29) {
            depth -= 1
            if depth == 0 { break }
          }
          i += 1
        }
        i += 1
        continue
      }
      if unit.tokens[i].kind == .punctuation, unit.punctuation(i, madeOf: "#!~=^+") {
        i += 1
        continue
      }
      break
    }
    if isName(i) {
      useVariable(i)
      i += 1
      // `${arr[i]}`: a subscript.
      if isOpen(i, 0x5B) {
        push(unit.hash(i - 1).isAssociative(associative) ? .array : .index, atCommand: false)
        i += 1
      }
    } else if top.kind == .expansion, isOpen(i, 0x7B) {
      // zsh's `${${x}:h}`: nested.
    }
  }

  mutating func expansion(_ t: Int) {
    let token = unit.tokens[t]
    switch token.kind {
    case .close where byte(t) == 0x7D:
      close([.expansion])
      i += 1
    case .punctuation where isPunct(t, "$"):
      dollar(t)
    case .open where byte(t) == 0x7B:
      push(.expansion, atCommand: false)
      i += 1
    case .open where byte(t) == 0x5B || byte(t) == 0x28:
      // A pattern's brackets (`${x%% (*}`, `${x//[a-z]/}`): counted, never closing what's outside.
      top.depth += 1
      i += 1
    case .close:
      if top.depth > 0 { top.depth -= 1 }
      i += 1
    case .interpolationOpen:
      push(.substitution, atCommand: true)
      i += 1
    case .interpolationClose:
      close([.substitution, .backtick])
      i += 1
    default:
      i += 1
    }
  }

  mutating func arithmetic(_ t: Int) {
    let token = unit.tokens[t]
    i = t + 1
    switch token.kind {
    case .identifier, .keyword:
      guard isName(t) else { return }
      // `x = …` (not `==`): an assignment; `16#ff` is a number.
      if top.kind == .arithmetic, t + 1 < count, unit.tokens[t + 1].kind == .punctuation, unit.isToken(t + 1, "=") {
        defineVariable(t, statement: t, local: false)
      } else if !(t > 0 && touches(t) && unit.tokens[t - 1].kind == .punctuation && unit.source.text[unit.tokens[t - 1].end - 1] == 0x23) {
        useVariable(t)
      }
    case .punctuation:
      if isPunct(t, "$") { dollar(t) }
    case .open:
      if byte(t) == 0x5B {
        push(.index, atCommand: false)
      } else {
        top.depth += 1
      }
    case .close:
      if byte(t) == 0x5D {
        if top.kind == .index { close([.index]) }
      } else if top.depth > 0 {
        top.depth -= 1
      } else if top.kind == .arithmetic {
        let closers = top.closers
        close([.arithmetic])
        if closers == 2, isClose(i, 0x29) { i += 1 }
      } else {
        // A subscript left open.
        close([.index])
        i = t
      }
    case .interpolationOpen:
      push(unit.isToken(t, "`") ? .backtick : .substitution, atCommand: true)
    case .interpolationClose:
      close([.substitution, .backtick])
    default:
      break
    }
  }

  // MARK: Brackets

  mutating func open(_ t: Int) {
    let b = byte(t)
    if top.cases.last == true, top.kind != .test {
      // `(a|b)`: a pattern's optional opening.
      i += 1
      return
    }
    if b == 0x28 {
      // `x=(…)`: an array's words. `((…))`: arithmetic. `<(…)`: a command.
      if t > 0, touches(t), isPunct(t - 1, "=") || isPunct(t - 1, "+=") {
        push(.array, atCommand: false)
        frames[frames.count - 1].mode = .words
        i += 1
        return
      }
      if top.atCommand, isOpen(t + 1, 0x28), touches(t + 1) {
        top.atCommand = false
        top.commandSeen = true
        pushArithmetic(closers: 2)
        i += 2
        return
      }
      push(.subshell, atCommand: true)
      i += 1
      return
    }
    if b == 0x7B {
      if top.atCommand {
        push(.group, atCommand: true)
      } else {
        // `{a,b}`, `{}`: a word.
        push(.array, atCommand: false)
      }
      i += 1
      return
    }
    if b == 0x5B {
      if top.atCommand, top.kind != .array {
        // `[[ … ]]` or `[ … ]`.
        let double = isOpen(t + 1, 0x5B) && touches(t + 1)
        top.atCommand = false
        top.commandSeen = true
        push(double ? .test : .singleTest, atCommand: false)
        i += double ? 2 : 1
        return
      }
      if t > 0, touches(t), isName(t - 1) {
        // `arr[i]=…`, `$arr[i]` (zsh): a subscript.
        push(unit.hash(t - 1).isAssociative(associative) ? .array : .index, atCommand: false)
        i += 1
        return
      }
      push(.array, atCommand: false)
      i += 1
      return
    }
    i += 1
  }

  mutating func closeToken(_ t: Int) {
    let b = byte(t)
    if let open = top.cases.last, open, top.kind != .test, b == 0x29 {
      // The pattern ends: commands follow.
      top.cases[top.cases.count - 1] = false
      commit()
      top.atCommand = true
      i += 1
      return
    }
    switch b {
    case 0x29:
      close([.subshell, .substitution, .array, .function])
    case 0x7D:
      close([.group, .expansion, .array, .function])
    case 0x5D:
      if top.kind == .test, isClose(t + 1, 0x5D), touches(t + 1) {
        close([.test])
        i += 2
        return
      }
      close([.singleTest, .index, .array])
    default:
      break
    }
    i += 1
  }

  // MARK: Words

  mutating func word(_ t: Int) {
    if top.awaitingIn, unit.isToken(t, "in") {
      top.awaitingIn = false
      top.cases.append(true)
      i = t + 1
      return
    }
    if top.cases.last == true, top.kind != .test {
      if unit.isToken(t, "esac") {
        compounds = max(0, compounds - 1)
        top.cases.removeLast()
        top.atCommand = false
        top.commandSeen = true
      }
      i += 1
      return
    }
    switch top.kind {
    case .test, .singleTest:
      testWord(t)
      return
    case .array:
      i += 1
      return
    default:
      break
    }
    if top.atCommand {
      commandWord(t)
    } else {
      argument(t)
    }
  }

  mutating func testWord(_ t: Int) {
    // `-v name`: a variable's name.
    if unit.isToken(t, "-v"), isName(t + 1) {
      useVariable(t + 1)
      i = t + 2
      return
    }
    i += 1
  }

  /// A word where a command's name goes.
  mutating func commandWord(_ t: Int) {
    let token = unit.tokens[t]
    // Written right after a word's piece (`$HOME/lib`, `"a"b`): the same word, no command's name.
    if continuesWord(t) {
      i = t + 1
      return
    }
    // `x=…`, `x+=…`, `x[i]=…`: an assignment.
    if isName(t), t + 1 < count, touches(t + 1) {
      if isPunct(t + 1, "=") || isPunct(t + 1, "+=") {
        let valueStart = t + 2
        let valueEnd = wordEnd(from: valueStart, after: t + 1)
        top.pending.append((Int32(t), (Int32(valueStart), Int32(valueEnd))))
        i = t + 2
        return
      }
      if isOpen(t + 1, 0x5B), let close = subscriptClose(t + 1), close + 1 < count, touches(close + 1), isPunct(close + 1, "=") || isPunct(close + 1, "+=") {
        top.pending.append((Int32(t), (Int32(close + 2), Int32(wordEnd(from: close + 2, after: close + 1)))))
        i = t + 1
        top.atCommand = true
        // The subscript is read as arithmetic.
        push(unit.hash(t).isAssociative(associative) ? .array : .index, atCommand: false)
        i = t + 2
        return
      }
    }
    if token.kind == .keyword || token.kind == .declarationKeyword {
      if keyword(t) { return }
    }
    // `name () { … }`: a function.
    if isOpen(t + 1, 0x28), isClose(t + 2, 0x29) {
      defineFunction(name: t, statement: t, after: t + 3)
      return
    }
    // The command's name.
    useCommand(t)
    top.commandToken = Int32(t)
    top.atCommand = false
    top.commandSeen = true
    i = t + 1
    switch text(t) {
    case "local":
      // At the top level too: a function's own file (zsh's autoloaded functions) has them.
      top.mode = .declare(isLocal: true, functions: false)
    case "declare", "typeset", "integer", "float", "private":
      top.mode = .declare(isLocal: function >= 0, functions: false)
    case "export":
      top.mode = .declare(isLocal: false, functions: false)
    case "readonly":
      // zsh's `readonly` is `typeset -r`: local in a function; bash's makes it the script's.
      top.mode = .declare(isLocal: file.isZsh && function >= 0, functions: false)
    case "unset": top.mode = .unset(functions: false)
    case "read": top.mode = .read
    case "getopts": top.mode = .getopts(seen: 0)
    case "mapfile", "readarray": top.mode = .mapfile
    case "printf": top.mode = .printf(nameNext: false)
    case "alias": top.mode = .alias
    case "unalias": top.mode = .unalias
    case "autoload": top.mode = .autoload
    case "source": top.mode = .source
    case "trap": top.mode = .trap(seen: 0)
    case "let": top.mode = .letWords
    case "exit" where frames.count == 1 && compounds == 0 && opensLine(t), "exec" where frames.count == 1 && compounds == 0 && opensLine(t):
      stopsAtLine = true
      if text(t) == "exec" {
        top.atCommand = true
        top.commandSeen = false
      }
    case "command", "builtin", "exec", "noglob", "nocorrect", "time", "nohup":
      top.atCommand = true
      top.commandSeen = false
    default:
      break
    }
  }

  /// Whether the token is written right after another piece of the same word (not after a separator or an opening).
  func continuesWord(_ t: Int) -> Bool {
    guard t > 0, touches(t) else { return false }
    let previous = unit.tokens[t - 1]
    switch previous.kind {
    case .open, .interpolationOpen: return false
    case .punctuation: return !isSeparator(t - 1) && !unit.isToken(t - 1, "`") && !unit.isToken(t - 1, "!")
    default: return true
    }
  }

  /// Whether the word before the one at `t` is an option ending in one of these letters (`-d`, `-rp`): `t` is its value.
  func followsOption(_ t: Int, takingValue letters: String) -> Bool {
    var k = t - 1
    while k > Int(top.commandToken), continuesWord(k) { k -= 1 }
    guard k > Int(top.commandToken), k < t, byte(k) == 0x2D, unit.tokens[k].kind == .identifier, let last = text(k).last else { return false }
    return letters.contains(last)
  }

  /// Which word after the command's name the token starts (1 the first), or 0 when it's inside a word.
  func argumentNumber(_ t: Int) -> Int {
    let name = Int(top.commandToken)
    guard name >= 0, name < t, !continuesWord(t) else { return 0 }
    var words = 0
    var depth = 0
    for k in (name + 1)...t {
      let kind = unit.tokens[k].kind
      if depth == 0, !continuesWord(k) { words += 1 }
      if kind == .open || kind == .interpolationOpen { depth += 1 }
      if kind == .close || kind == .interpolationClose { depth = max(0, depth - 1) }
    }
    return words
  }

  /// The end of a word starting at `from` (exclusive), what it's written next to included: `"a"$b`, `$(…)x`.
  func wordEnd(from: Int, after: Int) -> Int {
    var k = from
    guard k < count, unit.tokens[k].start == unit.tokens[after].end else { return from }
    var depth = 0
    while k < count {
      let token = unit.tokens[k]
      if depth == 0, k > from, token.start != unit.tokens[k - 1].end { break }
      if token.kind == .open || token.kind == .interpolationOpen { depth += 1 }
      if token.kind == .close || token.kind == .interpolationClose {
        depth -= 1
        if depth < 0 { break }
      }
      if depth == 0, isSeparator(k) { break }
      k += 1
    }
    return k
  }

  func subscriptClose(_ open: Int) -> Int? {
    var depth = 0
    var k = open
    while k < count, k < open + 200 {
      if isOpen(k, 0x5B) { depth += 1 } else if isClose(k, 0x5D) {
        depth -= 1
        if depth == 0 { return k }
      }
      k += 1
    }
    return nil
  }

  /// A keyword where a command's name goes. Returns whether it was read as one.
  mutating func keyword(_ t: Int) -> Bool {
    switch text(t) {
    case "if", "then", "else", "elif", "while", "until", "do", "!", "time", "coproc":
      if text(t) == "if" || text(t) == "while" || text(t) == "until" { compounds += 1 }
      commit()
      top.atCommand = true
      i = t + 1
      return true
    case "fi", "done", "esac":
      compounds = max(0, compounds - 1)
      commit()
      if text(t) == "esac", !top.cases.isEmpty { top.cases.removeLast() }
      top.atCommand = false
      top.commandSeen = true
      i = t + 1
      return true
    case "in":
      i = t + 1
      return true
    case "for", "select", "foreach":
      compounds += 1
      commit()
      // `for ((…))` or `for x in …`.
      if isOpen(t + 1, 0x28), isOpen(t + 2, 0x28) {
        top.atCommand = false
        top.commandSeen = true
        pushArithmetic(closers: 2)
        i = t + 3
        return true
      }
      if isName(t + 1) {
        defineVariable(t + 1, statement: t, local: false)
        i = t + 2
      } else {
        i = t + 1
      }
      top.atCommand = false
      top.commandSeen = true
      top.mode = .words
      return true
    case "case":
      compounds += 1
      commit()
      top.atCommand = false
      top.commandSeen = true
      top.mode = .words
      // The word, read as any (`case "$(f "$x")" in`), then `in`: patterns from there.
      top.awaitingIn = true
      i = t + 1
      return true
    case "function":
      // `function name [()] body`; zsh's `function a b { … }` names several.
      var k = t + 1
      var names: [Int] = []
      while isWord(k), !isOpen(k, 0x7B), !unit.startsLine(k) || names.isEmpty {
        names.append(k)
        k += 1
        if unit.startsLine(k) { break }
      }
      guard let first = names.first else {
        i = t + 1
        return true
      }
      if isOpen(k, 0x28), isClose(k + 1, 0x29) { k += 2 }
      for extra in names.dropFirst() { declare(.function, extra, statement: t) }
      defineFunction(name: first, statement: t, after: k)
      return true
    case "{":
      return false
    default:
      return false
    }
  }

  /// A function's name at `name`, its body from `after` (past line breaks): `{ … }` or `( … )`.
  mutating func defineFunction(name: Int, statement: Int, after: Int) {
    commit()
    let index = declare(.function, name, statement: statement)
    var k = after
    while k < count, unit.tokens[k].kind == .punctuation, isPunct(k, ";") { k += 1 }
    unit.decls[Int(index)].bodyOpen = Int32(k)
    guard k < count, unit.tokens[k].kind == .open, byte(k) == 0x7B || byte(k) == 0x28 else {
      // A body that is one command (`f() [[ … ]]`): read as the top's.
      i = k
      top.atCommand = true
      return
    }
    var frame = Frame(kind: byte(k) == 0x7B ? .function : .subshell, function: index)
    frame.body = index
    if byte(k) == 0x28 { frame.kind = .function }
    frames.append(frame)
    i = k + 1
  }

  /// A word after a command's name.
  mutating func argument(_ t: Int) {
    let mode = top.mode
    let isOption = unit.tokens[t].length > 1 && (byte(t) == 0x2D || byte(t) == 0x2B) && unit.tokens[t].start == unit.tokens[t].end - unit.tokens[t].length
    i = t + 1
    // A piece written after another (`d:o:`'s `o`, `$x-y`'s `-y`) starts no argument.
    if continuesWord(t), mode != .arguments { return }
    switch mode {
    case .arguments, .words, .forName:
      break
    case .letWords:
      guard isName(t) else { return }
      if t + 1 < count, touches(t + 1), isPunct(t + 1, "=") {
        defineVariable(t, statement: commandStart(before: t), local: false)
      } else {
        useVariable(t)
      }
    case .declare(let isLocal, let functions):
      if isOption {
        let flags = text(t)
        if flags.contains("f") || flags.contains("F") { top.mode = .declare(isLocal: isLocal, functions: true) }
        if flags.hasPrefix("-"), flags.contains("g") { top.mode = .declare(isLocal: false, functions: functions) }
        if flags.contains("A") { pendingAssociative = true }
        return
      }
      if functions {
        useCommand(t, functionsOnly: true)
        return
      }
      guard isName(t) else { return }
      if pendingAssociative { associative.insert(unit.hash(t)) }
      var value: (Int32, Int32)?
      if t + 1 < count, touches(t + 1), isPunct(t + 1, "=") || isPunct(t + 1, "+=") {
        value = (Int32(t + 2), Int32(wordEnd(from: t + 2, after: t + 1)))
      }
      // `export x` without a value: a use of it (its attribute changes).
      let isExportOnly = value == nil && commandName(before: t) == "export"
      if isExportOnly {
        useVariable(t)
      } else {
        defineVariable(t, statement: commandStart(before: t), local: isLocal, value: value)
      }
    case .unset(let functions):
      if isOption {
        if text(t).contains("f") { top.mode = .unset(functions: true) }
        return
      }
      if functions { useCommand(t, functionsOnly: true) } else { useVariable(t) }
    case .read:
      // `read -r -d '' -p "…" name`: an option's value (`-d`, `-p`, …) is no name; `-a`'s is.
      if isOption || followsOption(t, takingValue: "dinNptuk") { return }
      defineVariable(t, statement: commandStart(before: t), local: false)
    case .getopts:
      // `getopts optstring name`: the second word.
      if argumentNumber(t) == 2 { defineVariable(t, statement: commandStart(before: t), local: false) }
    case .mapfile:
      if isOption || followsOption(t, takingValue: "dnOsuCc") { return }
      top.mode = .arguments
      defineVariable(t, statement: commandStart(before: t), local: false)
    case .printf(let nameNext):
      if nameNext {
        top.mode = .arguments
        defineVariable(t, statement: commandStart(before: t), local: false)
        return
      }
      if text(t) == "-v" { top.mode = .printf(nameNext: true) } else { top.mode = .arguments }
    case .alias:
      if isOption { return }
      if t + 1 < count, touches(t + 1), isPunct(t + 1, "=") {
        declare(.typeAlias, t, statement: commandStart(before: t), value: (Int32(t + 2), Int32(wordEnd(from: t + 2, after: t + 1))))
      }
    case .unalias:
      if !isOption { useCommand(t) }
    case .autoload:
      if !isOption { useCommand(t, functionsOnly: true) }
    case .source:
      break
    case .trap(let seen):
      top.mode = .trap(seen: seen + 1)
      if seen == 0, isOption { top.mode = .trap(seen: 0) }
      if seen == 0, !isOption, unit.tokens[t].kind == .identifier, !(t + 1 < count && touches(t + 1)) { useCommand(t, functionsOnly: false) }
    }
  }

  var pendingAssociative = false
  var stopsAtLine = false
  /// `if`, loops and `case` open (they push no frame).
  var compounds = 0

  /// Whether a token can start a path's word: a name, a string, `$…`, `./`, `/`, `~`.
  func startsPath(_ t: Int) -> Bool {
    switch unit.tokens[t].kind {
    case .identifier, .keyword, .declarationKeyword, .string, .number: return true
    case .punctuation: return [0x24, 0x2E, 0x2F, 0x7E].contains(byte(t))
    default: return false
    }
  }

  /// Whether a command's name is the first of its line (no `&&`, `||` or `|` before it, no `if`).
  func opensLine(_ t: Int) -> Bool { t == 0 || startsCommandLine(t) }

  /// The command's name before an argument, as text.
  func commandName(before t: Int) -> String {
    var k = t - 1
    while k > 0, !startsCommandLine(k), !isSeparator(k - 1) { k -= 1 }
    return k >= 0 && k < count ? text(k) : ""
  }

  func commandStart(before t: Int) -> Int {
    var k = t - 1
    while k > 0, !startsCommandLine(k), !isSeparator(k - 1), !(unit.tokens[k - 1].kind == .open) { k -= 1 }
    return max(0, k)
  }

  // MARK: Files

  /// `source path` / `. path`: the path word from `t`.
  mutating func noteSource(from t: Int) {
    let end = wordEnd(from: t, after: t - 1 >= 0 && touches(t) ? t - 1 : t)
    let last = max(t, (unit.tokens[t].start == unit.tokens[max(0, t - 1)].end && t > 0 ? end : wordEndAlone(t)) - 1)
    let pattern = Self.pathPattern(unit.source.string(from: unit.tokens[t].start, to: unit.tokens[last].end), dialect: .shell)
    let index = Int32(file.sources.count)
    file.sources.append(ScriptSource(kind: .source, first: Int32(t), last: Int32(last), pattern: pattern, function: function))
    for k in t...last where unit.tokens[k].kind == .identifier || unit.tokens[k].kind == .string {
      if file.uses[Int32(k)] == nil { file.uses[Int32(k)] = .path(index) }
    }
  }

  /// The tokens of a word starting at `t`, written together.
  func wordEndAlone(_ t: Int) -> Int {
    var k = t + 1
    var depth = 0
    while k < count {
      let token = unit.tokens[k]
      if depth == 0, token.start != unit.tokens[k - 1].end { break }
      if token.kind == .open || token.kind == .interpolationOpen { depth += 1 }
      if token.kind == .close || token.kind == .interpolationClose {
        depth -= 1
        if depth < 0 { break }
      }
      if depth == 0, isSeparator(k) { break }
      k += 1
    }
    return k
  }

  /// `fpath=(dir $fpath)`, `fpath+=dir`: each folder named is one of autoloaded functions.
  mutating func noteFunctionFolders(_ value: (Int32, Int32)) {
    var k = Int(value.0)
    let end = Int(value.1)
    if isOpen(k, 0x28) { k += 1 }
    while k < end, k < count {
      if isClose(k, 0x29) { break }
      let wordEnd = wordEndAlone(k)
      let text = unit.source.string(from: unit.tokens[k].start, to: unit.tokens[min(wordEnd, count) - 1].end)
      if !text.contains("fpath"), let pattern = Self.pathPattern(text, dialect: .shell) {
        file.sources.append(ScriptSource(kind: .functionFolder, first: Int32(k), last: Int32(wordEnd - 1), pattern: pattern, function: function))
      }
      k = max(wordEnd, k + 1)
    }
  }

  /// A path as written, its expansions read (see `ScriptSource.pattern`), or nil when part of it can't be told.
  static func pathPattern(_ written: String, dialect: ScriptDialect) -> String? {
    var result = ""
    let chars = Array(written.unicodeScalars)
    var k = 0
    var quote: Unicode.Scalar?
    func matching(_ open: Int, _ openChar: Unicode.Scalar, _ closeChar: Unicode.Scalar) -> Int? {
      var depth = 0
      var j = open
      while j < chars.count {
        if chars[j] == openChar { depth += 1 } else if chars[j] == closeChar {
          depth -= 1
          if depth == 0 { return j }
        }
        j += 1
      }
      return nil
    }
    while k < chars.count {
      let c = chars[k]
      if c == "\"" || c == "'" {
        if quote == nil { quote = c } else if quote == c { quote = nil } else { result.unicodeScalars.append(c) }
        k += 1
        continue
      }
      if c == "\\", dialect == .shell, quote != "'" {
        k += 1
        if k < chars.count { result.unicodeScalars.append(chars[k]) }
        k += 1
        continue
      }
      if c == "\\", dialect == .powerShell {
        result += "/"
        k += 1
        continue
      }
      if c == "~", k == 0, quote == nil {
        result += "\u{2}"
        k += 1
        continue
      }
      if c == "$" || c == "`" {
        if c == "`" {
          guard dialect == .shell, let close = chars[(k + 1)...].firstIndex(of: "`") else { return nil }
          guard let folder = scriptFolder(String(String.UnicodeScalarView(chars[(k + 1)..<close]))) else { return nil }
          result += folder
          k = close + 1
          continue
        }
        let next = k + 1 < chars.count ? chars[k + 1] : " "
        if next == "(" {
          guard let close = matching(k + 1, "(", ")"), let folder = scriptFolder(String(String.UnicodeScalarView(chars[(k + 2)..<close]))) else { return nil }
          result += folder
          k = close + 1
          continue
        }
        if next == "{" {
          guard let close = matching(k + 1, "{", "}") else { return nil }
          let inner = String(String.UnicodeScalarView(chars[(k + 2)..<close]))
          if let folder = scriptFolder(inner) {
            result += folder
          } else if inner.unicodeScalars.allSatisfy({ ($0.isASCII && ScriptTokens.isNameByte(UInt8($0.value))) || $0 == ":" }) {
            result += variable(inner)
          } else {
            return nil
          }
          k = close + 1
          continue
        }
        var end = k + 1
        while end < chars.count, chars[end].isASCII, ScriptTokens.isNameByte(UInt8(chars[end].value)) || (dialect == .powerShell && chars[end] == ":") { end += 1 }
        let name = String(String.UnicodeScalarView(chars[(k + 1)..<end]))
        guard !name.isEmpty, let first = name.unicodeScalars.first, first.isASCII, ScriptTokens.isNameStart(UInt8(first.value)) else { return nil }
        if let folder = scriptFolder(name) {
          result += folder
        } else {
          result += variable(name)
        }
        k = end
        continue
      }
      if c == "*" || c == "?" || (c == "[" && dialect == .shell) { return nil }
      result.unicodeScalars.append(c)
      k += 1
    }
    return result.isEmpty ? nil : result
  }

  static func variable(_ name: String) -> String {
    let plain = name.lowercased().hasPrefix("env:") ? String(name.dropFirst(4)) : name
    if plain == "HOME" { return "\u{2}" }
    return "\u{3}" + plain + "\u{3}"
  }

  /// The script's own folder written as an expansion: `$(dirname "$0")`, `${BASH_SOURCE%/*}`, `${0:A:h}`,
  /// `$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)` (its parent), PowerShell's `$PSScriptRoot`.
  static func scriptFolder(_ inner: String) -> String? {
    let compact = inner.replacingOccurrences(of: " ", with: "")
    let lower = compact.lowercased()
    if lower == "psscriptroot" || lower.hasPrefix("split-path") && lower.contains("myinvocation.mycommand") { return "\u{1}" }
    if lower.contains("split-path") && lower.contains("pscommandpath") { return "\u{1}" }
    let names0 = compact.contains("$0") || compact.contains("${0") || compact.contains("BASH_SOURCE") || compact.contains("%x") || compact.contains("%N")
    if ["0%/*", "BASH_SOURCE%/*", "BASH_SOURCE[0]%/*", "0:A:h", "0:a:h", "0:h", "0:A:h:h", "BASH_SOURCE:h"].contains(compact) {
      return compact.hasSuffix(":h:h") ? "\u{1}/.." : "\u{1}"
    }
    if compact.hasPrefix("${(%):-%x}") || compact.hasPrefix("${(%):-%N}") { return nil }
    if compact.contains("dirname"), names0 {
      // `cd "$(dirname "$0")/.." && pwd`: the folder above.
      var folder = "\u{1}"
      if let at = compact.range(of: "dirname") {
        let after = compact[at.upperBound...]
        var rest = Substring(after)
        while let up = rest.range(of: "/..") {
          folder += "/.."
          rest = rest[up.upperBound...]
        }
      }
      return folder
    }
    if (compact.hasPrefix("${") || compact.hasPrefix("$")) && compact.contains(":A:h") && names0 { return "\u{1}" }
    return nil
  }

  // MARK: Shape

  func shape() -> UInt64 {
    var hash: UInt64 = 1469598103934665603
    func mix(_ value: UInt64) { hash = (hash ^ value) &* 1099511628211 }
    for decl in unit.decls {
      mix(decl.name)
      mix(UInt64(decl.kind.rawValue) << 1 | (decl.isLocal ? 1 : 0))
    }
    for source in file.sources { mix(hashName(source.pattern ?? "?")) }
    return hash
  }
}

extension Name {
  func isAssociative(_ set: Set<Name>) -> Bool { set.contains(self) }
}

/// Whether a file's first line runs zsh.
private func firstLineNamesZsh(_ unit: Unit) -> Bool {
  let bytes = unit.source.bytes
  guard bytes.count > 2, bytes[0] == 0x23, bytes[1] == 0x21 else { return false }
  var end = 0
  while end < bytes.count, end < 200, bytes[end] != 0x0A { end += 1 }
  return ModelLanguage.interpreter(ofFirstLine: String(decoding: UnsafeBufferPointer(rebasing: bytes[0..<end]), as: UTF8.self)) == "zsh"
}
