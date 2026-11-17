import CodeModel
import CodeScan
import Foundation

/// Lua's syntax for the core: a file is read whole by `LuaParser` (Lua 5.1-5.4 and LuaJIT; Luau's type syntax is not
/// read), which resolves every name as Lua's scoping does and keeps what it found in `LuaFile`. The file's
/// declarations are the places it defines something others can see: a global's assignment (`x = …`, `function x()`)
/// and a field's (`a.b = …`, `function a.b()`, `function a:b()`, `a["b"] = …`, `{b = …}`).
final class LuaSyntax: LanguageSyntax {
  let profile = LexProfile.profile(forLanguage: "lua")!
  let parametersHaveLabels = false
  /// Files read, for the model to know its answers about a file's tokens went stale.
  let parses = LuaCounter()

  func parse(_ unit: CodeModel.Unit) -> UInt64 {
    parses.increment()
    var parser = LuaParser(unit: unit)
    parser.parseChunk()
    unit.scans[LuaFile.key] = parser.file
    return parser.shape()
  }

  func evaluateCondition(_ unit: CodeModel.Unit, _ i: inout Int) -> Bool { true }

  func conditional(_ unit: CodeModel.Unit, _ i: Int) -> ConditionalDirective { .none }
}

/// An expression as the model needs it: names, fields, calls, tables, functions and the values `or` and `and` pass on;
/// everything else (arithmetic, comparisons) is `other`.
enum LuaExpr {
  case name(Int32)
  /// `base.name` or `base:name`: the base expression and the name's token.
  case field(Int32, Int32)
  /// `base[key]`: the base and the key's expression.
  case index(Int32, Int32)
  /// A call: the callee, the first argument in `LuaFile.arguments` and how many.
  case call(Int32, Int32, Int32)
  /// A table constructor, by its `{` token.
  case table(Int32)
  /// A function, by its index in `LuaFile.functions`.
  case function(Int32)
  case string(Int32)
  case number, literal, vararg, other
  case or(Int32, Int32)
  case and(Int32, Int32)
  case paren(Int32)
}

/// What a name token is.
enum LuaUse {
  /// A local's use or declaration: its declaring token.
  case local(Int32)
  /// A free name: a global.
  case global
  /// The name in `a.name`, `a:name`, `function a.name()`: the `.field` expression.
  case field(Int32)
  /// A key in a table constructor (`{name = …}`): the `{` token.
  case key(Int32)
  /// `self` in a method (`function a:m()`), which declares it without a token: the function.
  case selfParameter(Int32)
  /// A label (`::name::`) or a `goto`'s name: the label's token.
  case label(Int32)
}

struct LuaLocal {
  enum Kind: UInt8 { case local, function, parameter, forVariable, label }
  var kind: Kind
  /// The statement's first token (`local`, `for`, a function's `function`), for its doc comment.
  var statement: Int32
  /// The value it's declared with, and which of that expression's values (a call's second, third…).
  var value: Int32 = -1
  var valueIndex: Int32 = 0
  /// A parameter's function and position.
  var function: Int32 = -1
  var position: Int32 = 0
  /// Where it can be seen: from the token after its statement (a `local function`'s name and parameters from their
  /// own token) to the end of its block.
  var visibleFrom: Int32
  var scopeEnd: Int32
}

struct LuaFunction {
  /// `function`, the statement's first token, the name token of a named function (-1 for a value).
  var keyword: Int32
  var statement: Int32
  var nameToken: Int32 = -1
  /// `(`, and the `end` that closes the body.
  var open: Int32
  var close: Int32 = -1
  var parameters: [Int32] = []
  var hasVararg = false
  /// `function a.b:c()`: `self` is declared.
  var isMethod = false
  /// The receiver of a named function's last name (`a.b` in `function a.b:c()`), -1 for none.
  var owner: Int32 = -1
  /// The first expression of each `return` in the body (not in nested functions).
  var returns: [Int32] = []
  var parent: Int32 = -1
}

/// What a declaration in `Unit.decls` assigns, parallel to it.
struct LuaField {
  /// The receiver (`a` in `a.b = …`), -1 for a global or a constructor's key.
  var owner: Int32 = -1
  /// A constructor key's `{` token, -1 otherwise.
  var table: Int32 = -1
  /// The value, and which of its values.
  var value: Int32 = -1
  var valueIndex: Int32 = 0
  var statement: Int32
}

/// A file as the parser read it: every name's meaning, expressions, functions and locals. Kept in `Unit.scans`.
final class LuaFile: BodyFacts {
  static let key = Int32.min + 1
  var exprs: [LuaExpr] = []
  var arguments: [Int32] = []
  var uses: [Int32: LuaUse] = [:]
  var locals: [Int32: LuaLocal] = [:]
  /// Locals in the order they're declared.
  var localOrder: [Int32] = []
  var functions: [LuaFunction] = []
  var fields: [LuaField] = []
  /// Assignments to a local after its declaration: the value and which of its values.
  var assignments: [Int32: [(value: Int32, index: Int32)]] = [:]
  /// `setmetatable(x, mt)` as a statement, by the local or global it names: the metatables' expressions.
  var metatables: [Int32: [Int32]] = [:]
  var globalMetatables: [Name: [Int32]] = [:]
  /// The chunk's `return` value, -1 when it returns nothing.
  var returned: Int32 = -1
  /// The outermost expression ending at a token: what a `.` after it reaches into.
  var endsAt: [Int32: Int32] = [:]
  /// What a statement starting at a token declares (a local's token, or -1 - a declaration's index): for `---@class`.
  var statementTargets: [Int32: Int32] = [:]
  /// Which expression a call's argument is, and the call: for `require "x"` answering the file.
  var requireStrings: [Int32: String] = [:]
  /// Locals written with computed keys (`t[k] = v`): maps and copies, whose table a function's every call makes anew.
  var computedKeys: Set<Int32> = []

  func dropTypes() {}

  @inline(__always) func expr(_ index: Int32) -> LuaExpr { exprs[Int(index)] }
}

/// A recursive descent parser over CodeScan's tokens, forgiving: what it can't read it steps over, so code being
/// typed still has its names resolved.
struct LuaParser {
  let unit: Unit
  let count: Int
  var i = 0
  let file = LuaFile()
  /// Names in scope, innermost last; a declaring token, or -2 - function for a method's `self`.
  private var visible: [(name: Name, def: Int32)] = []
  private var blockMarks: [(visible: Int, locals: Int)] = []
  private var blockLocals: [Int32] = []
  /// Blocks: each one's parent and function, for labels.
  private var blocks: [(parent: Int32, function: Int32)] = []
  private var block: Int32 = -1
  private var labels: [(block: Int32, name: Name, token: Int32)] = []
  private var gotos: [(block: Int32, name: Name, token: Int32, function: Int32)] = []
  private var function: Int32 = -1
  private var depth = 0
  /// Tokens were stepped over that no statement starts with (a fragment that isn't Lua, a line being typed): the next
  /// statement declares nothing, as its start can't be told.
  private var skipped = false
  private var afterSkip = false
  private var outerBodies: [(Int32, Int32)] = []
  static let selfName = name("self")
  static let setmetatableName = name("setmetatable")
  static let requireName = name("require")

  init(unit: Unit) {
    self.unit = unit
    count = unit.tokens.count
  }

  // MARK: Tokens

  @inline(__always) func isWord(_ at: Int, _ text: StaticString) -> Bool {
    guard at < count else { return false }
    let kind = unit.tokens[at].kind
    return (kind == .keyword || kind == .declarationKeyword) && unit.isToken(at, text)
  }

  @inline(__always) func isPunct(_ at: Int, _ text: StaticString) -> Bool {
    guard at < count, unit.tokens[at].kind == .punctuation else { return false }
    return unit.isToken(at, text)
  }

  @inline(__always) func isOpen(_ at: Int, _ byte: UInt8) -> Bool {
    at < count && unit.tokens[at].kind == .open && unit.source.text[unit.tokens[at].start] == byte
  }

  @inline(__always) func isClose(_ at: Int, _ byte: UInt8) -> Bool {
    at < count && unit.tokens[at].kind == .close && unit.source.text[unit.tokens[at].start] == byte
  }

  @inline(__always) func isName(_ at: Int) -> Bool { at < count && unit.tokens[at].kind == .identifier }

  private mutating func expect(_ text: StaticString) {
    if isPunct(i, text) || isWord(i, text) { i += 1 }
  }

  private mutating func closeBracket(_ byte: UInt8) {
    if isClose(i, byte) { i += 1 }
  }

  func blockEnds(_ at: Int) -> Bool {
    at >= count || isWord(at, "end") || isWord(at, "else") || isWord(at, "elseif") || isWord(at, "until")
  }

  // MARK: Scopes

  private mutating func openBlock() {
    blockMarks.append((visible.count, blockLocals.count))
    blocks.append((block, function))
    block = Int32(blocks.count - 1)
  }

  private mutating func closeBlock() {
    let mark = blockMarks.removeLast()
    let end = Int32(min(i, count))
    for def in blockLocals[mark.locals...] { file.locals[def]?.scopeEnd = end }
    blockLocals.removeSubrange(mark.locals...)
    visible.removeSubrange(mark.visible...)
    block = blocks[Int(block)].parent
  }

  @discardableResult
  private mutating func declare(_ token: Int, _ local: LuaLocal) -> Int32 {
    let def = Int32(token)
    file.locals[def] = local
    file.localOrder.append(def)
    file.uses[def] = .local(def)
    visible.append((unit.hash(token), def))
    blockLocals.append(def)
    return def
  }

  /// A name read as a value: a local, a method's `self`, or a global.
  private mutating func use(_ token: Int) -> LuaUse {
    let word = unit.hash(token)
    var k = visible.count - 1
    while k >= 0 {
      if visible[k].name == word {
        let def = visible[k].def
        let found: LuaUse = def <= -2 ? .selfParameter(-2 - def) : .local(def)
        file.uses[Int32(token)] = found
        return found
      }
      k -= 1
    }
    file.uses[Int32(token)] = .global
    return .global
  }

  // MARK: Chunk

  mutating func parseChunk() {
    openBlock()
    while i < count {
      parseBlock(top: true)
      // A stray `end`, `else` or `until` at the top: stepped over.
      if i < count {
        i += 1
        skipped = true
      }
    }
    closeBlock()
    resolveGotos(of: -1)
  }

  private mutating func resolveGotos(of owner: Int32) {
    var kept: [(block: Int32, name: Name, token: Int32, function: Int32)] = []
    for item in gotos {
      guard item.function == owner else {
        kept.append(item)
        continue
      }
      var at = item.block
      search: while at >= 0, blocks[Int(at)].function == owner {
        for label in labels where label.block == at && label.name == item.name {
          file.uses[item.token] = .label(label.token)
          break search
        }
        at = blocks[Int(at)].parent
      }
    }
    gotos = kept
  }

  private mutating func parseBlock(top: Bool = false) {
    while i < count, !blockEnds(i) {
      let before = i
      if isWord(i, "return") {
        returnStatement(top: top)
      } else {
        statement()
      }
      if i == before {
        i += 1
        skipped = true
      }
    }
  }

  private mutating func returnStatement(top: Bool) {
    i += 1
    if i < count, !blockEnds(i), !isPunct(i, ";") {
      let values = expressionList()
      if let first = values.first {
        if function >= 0 {
          file.functions[Int(function)].returns.append(first)
        } else if top {
          file.returned = first
        }
      }
    }
    if isPunct(i, ";") { i += 1 }
  }

  // MARK: Statements

  private mutating func statement() {
    let start = i
    afterSkip = skipped
    skipped = false
    let token = unit.tokens[i]
    if token.kind == .punctuation {
      if isPunct(i, ";") {
        i += 1
        return
      }
      if isPunct(i, "::") {
        i += 1
        guard isName(i) else { return }
        let label = Int32(i)
        labels.append((block, unit.hash(i), label))
        file.uses[label] = .label(label)
        i += 1
        expect("::")
        return
      }
    }
    if token.kind == .keyword || token.kind == .declarationKeyword {
      if isWord(i, "local") {
        i += 1
        if isWord(i, "function") {
          localFunction(start: start)
        } else {
          localStatement(start: start)
        }
        return
      }
      if isWord(i, "function") {
        functionStatement(start: start)
        return
      }
      if isWord(i, "if") {
        i += 1
        _ = expression()
        expect("then")
        scopedBlock()
        while isWord(i, "elseif") {
          i += 1
          _ = expression()
          expect("then")
          scopedBlock()
        }
        if isWord(i, "else") {
          i += 1
          scopedBlock()
        }
        expect("end")
        return
      }
      if isWord(i, "for") {
        forStatement(start: start)
        return
      }
      if isWord(i, "while") {
        i += 1
        _ = expression()
        expect("do")
        scopedBlock()
        expect("end")
        return
      }
      if isWord(i, "do") {
        i += 1
        scopedBlock()
        expect("end")
        return
      }
      if isWord(i, "repeat") {
        i += 1
        openBlock()
        parseBlock()
        expect("until")
        _ = expression()
        closeBlock()
        return
      }
      if isWord(i, "break") {
        i += 1
        return
      }
      if isWord(i, "goto") {
        i += 1
        if isName(i) {
          gotos.append((block, unit.hash(i), Int32(i), function))
          i += 1
        }
        return
      }
      // `nil`, `true`, `not` … can't start a statement.
      return
    }
    expressionStatement(start: start)
  }

  private mutating func scopedBlock() {
    openBlock()
    parseBlock()
    closeBlock()
  }

  private mutating func forStatement(start: Int) {
    i += 1
    var names: [Int] = []
    while isName(i) {
      names.append(i)
      i += 1
      if isPunct(i, ",") { i += 1 } else { break }
    }
    if isPunct(i, "=") {
      i += 1
      _ = expressionList()
    } else {
      expect("in")
      _ = expressionList()
    }
    expect("do")
    openBlock()
    for name in names {
      declare(name, LuaLocal(kind: .forVariable, statement: Int32(start), visibleFrom: Int32(i), scopeEnd: Int32(count)))
    }
    parseBlock()
    closeBlock()
    expect("end")
  }

  private mutating func localFunction(start: Int) {
    i += 1
    guard isName(i) else { return }
    let nameToken = i
    let def = declare(nameToken, LuaLocal(kind: .function, statement: Int32(start), visibleFrom: Int32(nameToken), scopeEnd: Int32(count)))
    i += 1
    let index = functionBody(keyword: Int32(start + 1), statement: Int32(start), name: Int32(nameToken), isMethod: false, owner: -1)
    file.locals[def]?.value = add(.function(index))
    file.statementTargets[Int32(start)] = def
  }

  private mutating func localStatement(start: Int) {
    var names: [Int] = []
    while isName(i) {
      names.append(i)
      i += 1
      // `<const>`, `<close>`.
      if isPunct(i, "<"), isName(i + 1), isPunct(i + 2, ">") { i += 3 }
      if isPunct(i, ",") { i += 1 } else { break }
    }
    var values: [Int32] = []
    if isPunct(i, "=") {
      i += 1
      values = expressionList()
    }
    let visibleFrom = Int32(i)
    for (k, name) in names.enumerated() {
      var local = LuaLocal(kind: .local, statement: Int32(start), visibleFrom: visibleFrom, scopeEnd: Int32(count))
      if k < values.count {
        local.value = values[k]
      } else if let last = values.last, case .call = file.expr(last) {
        local.value = last
        local.valueIndex = Int32(k - values.count + 1)
      }
      let def = declare(name, local)
      if k == 0 { file.statementTargets[Int32(start)] = def }
    }
  }

  /// `function a.b:c() … end`, `function a() … end`.
  private mutating func functionStatement(start: Int) {
    i += 1
    guard isName(i) else { return }
    let first = i
    let firstUse = use(first)
    var receiver = add(.name(Int32(first)))
    file.endsAt[Int32(first)] = receiver
    i += 1
    var owner: Int32 = -1
    var nameToken = first
    var isMethod = false
    while (isPunct(i, ".") || isPunct(i, ":")), isName(i + 1) {
      isMethod = isPunct(i, ":")
      owner = receiver
      nameToken = i + 1
      receiver = add(.field(owner, Int32(nameToken)))
      file.uses[Int32(nameToken)] = .field(receiver)
      file.endsAt[Int32(nameToken)] = receiver
      i += 2
      if isMethod { break }
    }
    var declIndex: Int32 = -1
    if owner >= 0 {
      declIndex = addDecl(kind: .function, nameToken: nameToken, start: start, field: LuaField(owner: owner, statement: Int32(start)))
    } else if case .global = firstUse {
      declIndex = addDecl(kind: .function, nameToken: first, start: start, field: LuaField(statement: Int32(start)))
    }
    let index = functionBody(keyword: Int32(start), statement: Int32(start), name: Int32(nameToken), isMethod: isMethod, owner: owner)
    let value = add(.function(index))
    if declIndex >= 0 {
      file.fields[Int(declIndex)].value = value
      finishFunctionDecl(declIndex, index)
      file.statementTargets[Int32(start)] = -1 - declIndex
    } else if case .local(let def) = firstUse {
      file.assignments[def, default: []].append((value, 0))
      file.statementTargets[Int32(start)] = def
    }
  }

  private mutating func expressionStatement(start: Int) {
    let target = suffixedExpression()
    guard target >= 0 else {
      // Not an expression: step over it.
      if i == start {
        i += 1
        skipped = true
      }
      return
    }
    if isPunct(i, "=") || isPunct(i, ",") {
      var targets = [target]
      while isPunct(i, ",") {
        i += 1
        let next = suffixedExpression()
        if next >= 0 { targets.append(next) }
      }
      guard isPunct(i, "=") else { return }
      i += 1
      let values = expressionList()
      for (k, item) in targets.enumerated() {
        var value: Int32 = -1
        var valueIndex: Int32 = 0
        if k < values.count {
          value = values[k]
        } else if let last = values.last, case .call = file.expr(last) {
          value = last
          valueIndex = Int32(k - values.count + 1)
        }
        assign(item, value: value, valueIndex: valueIndex, start: start, first: k == 0)
      }
      return
    }
    // An expression that isn't a call can't be a statement.
    guard case .call = file.expr(target) else {
      skipped = true
      return
    }
    // `setmetatable(x, mt)` on its own: `x`'s metatable from here on.
    if case .call(let callee, let firstArgument, let argumentCount) = file.expr(target), argumentCount >= 2,
      case .name(let calleeToken) = file.expr(callee), unit.hash(Int(calleeToken)) == Self.setmetatableName,
      case .global = file.uses[calleeToken] ?? .global,
      case .name(let objectToken) = file.expr(file.arguments[Int(firstArgument)])
    {
      let metatable = file.arguments[Int(firstArgument) + 1]
      switch file.uses[objectToken] {
      case .local(let def): file.metatables[def, default: []].append(metatable)
      case .global: file.globalMetatables[unit.hash(Int(objectToken)), default: []].append(metatable)
      default: break
      }
    }
  }

  private mutating func assign(_ target: Int32, value: Int32, valueIndex: Int32, start: Int, first: Bool) {
    // Unless it starts its line: a statement typed below one that isn't finished yet.
    if afterSkip, !unit.startsLine(start) { return }
    switch file.expr(target) {
    case .name(let token):
      switch file.uses[token] {
      case .local(let def):
        file.assignments[def, default: []].append((value, valueIndex))
        if first { file.statementTargets[Int32(start)] = def }
      case .global:
        let index = addDecl(kind: isFunction(value) ? .function : .variable, nameToken: Int(token), start: start,
          field: LuaField(value: value, valueIndex: valueIndex, statement: Int32(start)))
        if value >= 0, case .function(let function) = file.expr(value) { finishFunctionDecl(index, function) }
        if first { file.statementTargets[Int32(start)] = -1 - index }
      default:
        break
      }
    case .field(let base, let token):
      let index = addDecl(kind: isFunction(value) ? .function : .variable, nameToken: Int(token), start: start,
        field: LuaField(owner: base, value: value, valueIndex: valueIndex, statement: Int32(start)))
      if value >= 0, case .function(let function) = file.expr(value) { finishFunctionDecl(index, function) }
      if first { file.statementTargets[Int32(start)] = -1 - index }
    case .index(let base, let key):
      if case .name(let token) = file.expr(base), case .local(let def) = file.uses[token] ?? .global {
        switch file.expr(key) {
        case .string, .number: break
        default: file.computedKeys.insert(def)
        }
      }
      // `t["name"] = …`: a field too.
      guard case .string(let token) = file.expr(key), let text = LuaParser.literal(unit, Int(token)), LuaParser.isIdentifier(text) else { return }
      let index = addDecl(kind: isFunction(value) ? .function : .variable, nameToken: Int(token), start: start,
        field: LuaField(owner: base, value: value, valueIndex: valueIndex, statement: Int32(start)), name: name(text))
      if first { file.statementTargets[Int32(start)] = -1 - index }
    default:
      break
    }
  }

  private func isFunction(_ value: Int32) -> Bool {
    guard value >= 0, case .function = file.expr(value) else { return false }
    return true
  }

  @discardableResult
  private mutating func addDecl(kind: DeclKind, nameToken: Int, start: Int, field: LuaField, name declared: Name? = nil) -> Int32 {
    var decl = Decl(kind: kind, name: declared ?? unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(start), parent: -1)
    decl.end = Int32(nameToken + 1)
    decl.access = .isPublic
    unit.decls.append(decl)
    file.fields.append(field)
    return Int32(unit.decls.count - 1)
  }

  /// A declaration whose value is a function: its body and parameters, for details and completion.
  private mutating func finishFunctionDecl(_ index: Int32, _ function: Int32) {
    let body = file.functions[Int(function)]
    var decl = unit.decls[Int(index)]
    decl.bodyOpen = body.open
    decl.bodyClose = body.close
    decl.end = max(decl.end, body.close + 1)
    decl.paramStart = Int32(unit.params.count)
    decl.paramCount = Int32(body.parameters.count)
    for parameter in body.parameters {
      let word = unit.hash(Int(parameter))
      unit.params.append(Param(label: word, local: word, nameToken: parameter, typeStart: -1, typeEnd: -1, hasDefault: false, variadic: false))
    }
    if body.hasVararg {
      decl.paramCount += 1
      unit.params.append(Param(label: 0, local: 0, nameToken: -1, typeStart: -1, typeEnd: -1, hasDefault: false, variadic: true))
    }
    unit.decls[Int(index)] = decl
  }

  /// `(params) block end`: a function's index in `functions`.
  private mutating func functionBody(keyword: Int32, statement: Int32, name: Int32, isMethod: Bool, owner: Int32) -> Int32 {
    let index = Int32(file.functions.count)
    var body = LuaFunction(keyword: keyword, statement: statement, open: Int32(i))
    body.nameToken = name
    body.isMethod = isMethod
    body.owner = owner
    body.parent = function
    file.functions.append(body)
    let outer = function
    function = index
    openBlock()
    if isMethod { visible.append((Self.selfName, -2 - index)) }
    if isOpen(i, 0x28) {
      i += 1
      var position: Int32 = isMethod ? 1 : 0
      while i < count, !isClose(i, 0x29) {
        if isName(i) {
          declare(i, LuaLocal(kind: .parameter, statement: statement, function: index, position: position, visibleFrom: Int32(i), scopeEnd: Int32(count)))
          file.functions[Int(index)].parameters.append(Int32(i))
          position += 1
          i += 1
        } else if isPunct(i, "...") {
          file.functions[Int(index)].hasVararg = true
          i += 1
        } else if isPunct(i, ",") {
          i += 1
        } else {
          break
        }
      }
      closeBracket(0x29)
    }
    parseBlock()
    file.functions[Int(index)].close = Int32(min(i, count - 1))
    closeBlock()
    expect("end")
    resolveGotos(of: index)
    function = outer
    if outer < 0 { outerBodies.append((Int32(file.functions[Int(index)].open), Int32(i))) }
    return index
  }

  // MARK: Expressions

  @discardableResult
  private mutating func add(_ expr: LuaExpr) -> Int32 {
    file.exprs.append(expr)
    return Int32(file.exprs.count - 1)
  }

  private mutating func expressionList() -> [Int32] {
    var values = [expression()]
    while isPunct(i, ",") {
      i += 1
      values.append(expression())
    }
    return values
  }

  /// A binary operator at a token: its precedence and its right side's.
  private func binary(_ at: Int) -> (Int, Int)? {
    guard at < count else { return nil }
    let token = unit.tokens[at]
    if token.kind == .keyword {
      if unit.isToken(at, "or") { return (1, 1) }
      if unit.isToken(at, "and") { return (2, 2) }
      return nil
    }
    guard token.kind == .punctuation else { return nil }
    let text = unit.source.text + token.start
    switch token.length {
    case 1:
      switch text[0] {
      case 0x3C, 0x3E: return (3, 3)  // < >
      case 0x7C: return (4, 4)  // |
      case 0x7E: return (5, 5)  // ~
      case 0x26: return (6, 6)  // &
      case 0x2B, 0x2D: return (10, 10)  // + -
      case 0x2A, 0x2F, 0x25: return (11, 11)  // * / %
      case 0x5E: return (14, 13)  // ^ (right)
      default: return nil
      }
    case 2:
      if unit.isToken(at, "..") { return (9, 8) }
      if unit.isToken(at, "==") || unit.isToken(at, "~=") || unit.isToken(at, "<=") || unit.isToken(at, ">=") { return (3, 3) }
      if unit.isToken(at, "<<") || unit.isToken(at, ">>") { return (7, 7) }
      if unit.isToken(at, "//") { return (11, 11) }
      return nil
    default:
      return nil
    }
  }

  private func isUnary(_ at: Int) -> Bool {
    isWord(at, "not") || isPunct(at, "-") || isPunct(at, "#") || isPunct(at, "~")
  }

  private mutating func expression(_ limit: Int = 0) -> Int32 {
    depth += 1
    defer { depth -= 1 }
    guard depth < 200 else { return add(.other) }
    var left: Int32
    if isUnary(i) {
      i += 1
      _ = expression(12)
      left = add(.other)
    } else {
      left = simpleExpression()
    }
    while let (precedence, right) = binary(i), precedence > limit {
      let isOr = isWord(i, "or")
      let isAnd = isWord(i, "and")
      i += 1
      let other = expression(right)
      left = add(isOr ? .or(left, other) : isAnd ? .and(left, other) : .other)
    }
    return left
  }

  private mutating func simpleExpression() -> Int32 {
    guard i < count else { return add(.other) }
    let token = unit.tokens[i]
    switch token.kind {
    case .number:
      i += 1
      return add(.number)
    case .string:
      i += 1
      return add(.string(Int32(i - 1)))
    case .keyword, .declarationKeyword:
      if isWord(i, "nil") || isWord(i, "true") || isWord(i, "false") {
        i += 1
        return add(.literal)
      }
      if isWord(i, "function") {
        let keyword = i
        i += 1
        return add(.function(functionBody(keyword: Int32(keyword), statement: Int32(keyword), name: -1, isMethod: false, owner: -1)))
      }
      return add(.other)
    case .punctuation:
      if isPunct(i, "...") {
        i += 1
        return add(.vararg)
      }
      // `.5`.
      if isPunct(i, "."), i + 1 < count, unit.tokens[i + 1].kind == .number, unit.touchesPrevious(i + 1) {
        i += 2
        return add(.number)
      }
      return add(.other)
    case .open where isOpen(i, 0x7B):
      return constructor()
    default:
      let found = suffixedExpression()
      return found >= 0 ? found : add(.other)
    }
  }

  /// A name or a parenthesized expression, then fields, indexes and calls; -1 when none starts here.
  private mutating func suffixedExpression() -> Int32 {
    depth += 1
    defer { depth -= 1 }
    guard depth < 200, i < count else { return -1 }
    var current: Int32
    if isName(i) {
      _ = use(i)
      current = add(.name(Int32(i)))
      i += 1
    } else if isOpen(i, 0x28) {
      i += 1
      let inner = expression()
      closeBracket(0x29)
      current = add(.paren(inner))
    } else {
      return -1
    }
    if isName(i - 1) || isClose(i - 1, 0x29) { file.endsAt[Int32(i - 1)] = current }
    while i < count {
      if isPunct(i, "."), isName(i + 1) {
        let token = Int32(i + 1)
        current = add(.field(current, token))
        file.uses[token] = .field(current)
        i += 2
      } else if isPunct(i, ":"), isName(i + 1) {
        let token = Int32(i + 1)
        current = add(.field(current, token))
        file.uses[token] = .field(current)
        i += 2
        file.endsAt[Int32(i - 1)] = current
        current = call(current, method: true)
      } else if isOpen(i, 0x5B) {
        i += 1
        let key = expression()
        closeBracket(0x5D)
        current = add(.index(current, key))
      } else if isOpen(i, 0x28) || isOpen(i, 0x7B) || unit.tokens[i].kind == .string {
        current = call(current, method: false)
      } else {
        break
      }
      // A call or index left open (`f(a.` being typed) doesn't end at the name before the cursor.
      if endsHere(i - 1, current) { file.endsAt[Int32(i - 1)] = current }
    }
    return current
  }

  /// Whether the expression just read ends at a token: a call's or index's own bracket, a field's name.
  private func endsHere(_ last: Int, _ expr: Int32) -> Bool {
    switch file.expr(expr) {
    case .field(_, let name): return Int(name) == last
    case .index: return isClose(last, 0x5D)
    case .call(_, let first, let count):
      if isClose(last, 0x29) { return true }
      // `f{…}`, `f"…"`: the argument's own end.
      guard count == 1 else { return false }
      switch file.expr(file.arguments[Int(first)]) {
      case .string(let token): return Int(token) == last
      case .table: return isClose(last, 0x7D)
      default: return false
      }
    default: return true
    }
  }

  private mutating func call(_ callee: Int32, method: Bool) -> Int32 {
    var values: [Int32] = []
    if i < count, unit.tokens[i].kind == .string {
      values = [add(.string(Int32(i)))]
      i += 1
    } else if isOpen(i, 0x7B) {
      values = [constructor()]
    } else if isOpen(i, 0x28) {
      i += 1
      if !isClose(i, 0x29) { values = expressionList() }
      closeBracket(0x29)
    }
    let first = Int32(file.arguments.count)
    file.arguments.append(contentsOf: values)
    // `require "a.b"`: the string names a file.
    if !method, case .name(let token) = file.expr(callee), unit.hash(Int(token)) == Self.requireName, let argument = values.first,
      case .string(let stringToken) = file.expr(argument), let text = LuaParser.literal(unit, Int(stringToken))
    {
      file.requireStrings[stringToken] = text
      var item = Import(module: name(text), moduleName: text, isExported: false, isTestable: false)
      item.token = stringToken
      unit.imports.append(item)
    }
    return add(.call(callee, first, Int32(values.count)))
  }

  private mutating func constructor() -> Int32 {
    let open = Int32(i)
    i += 1
    let table = add(.table(open))
    while i < count, !isClose(i, 0x7D) {
      let before = i
      if isOpen(i, 0x5B) {
        i += 1
        let key = expression()
        closeBracket(0x5D)
        expect("=")
        let value = expression()
        // `["name"] = …`: a field like `name = …`.
        if case .string(let token) = file.expr(key), let text = LuaParser.literal(unit, Int(token)), LuaParser.isIdentifier(text) {
          addDecl(kind: isFunction(value) ? .function : .variable, nameToken: Int(token), start: Int(token),
            field: LuaField(table: open, value: value, statement: token), name: name(text))
        }
      } else if isName(i), isPunct(i + 1, "=") {
        let key = i
        i += 2
        let value = expression()
        file.uses[Int32(key)] = .key(open)
        let index = addDecl(kind: isFunction(value) ? .function : .variable, nameToken: key, start: key,
          field: LuaField(table: open, value: value, statement: Int32(key)))
        if case .function(let function) = file.expr(value) { finishFunctionDecl(index, function) }
      } else {
        _ = expression()
      }
      if isPunct(i, ",") || isPunct(i, ";") {
        i += 1
      } else if i == before {
        // Something that isn't a field: past it, unless it ends the table.
        if isClose(i, 0x7D) || blockEnds(i) { break }
        i += 1
      } else if !isClose(i, 0x7D) {
        break
      }
    }
    closeBracket(0x7D)
    if isClose(i - 1, 0x7D) { file.endsAt[Int32(i - 1)] = table }
    return table
  }

  // MARK: Literals

  /// A string token's text without its quotes or long brackets, escapes left as written; nil for an odd one.
  static func literal(_ unit: Unit, _ token: Int) -> String? {
    let text = unit.string(token)
    guard let first = text.first else { return nil }
    if first == "\"" || first == "'" {
      guard text.count >= 2, text.last == first else { return nil }
      return String(text.dropFirst().dropLast())
    }
    if first == "[" {
      var level = 0
      var index = text.index(after: text.startIndex)
      while index < text.endIndex, text[index] == "=" {
        level += 1
        index = text.index(after: index)
      }
      let open = level + 2
      let close = level + 2
      guard text.count >= open + close else { return nil }
      var body = String(text.dropFirst(open).dropLast(close))
      if body.hasPrefix("\n") { body.removeFirst() }
      return body
    }
    return nil
  }

  static func isIdentifier(_ text: String) -> Bool {
    guard let first = text.utf8.first, first == 0x5F || (first | 0x20 >= 0x61 && first | 0x20 <= 0x7A) else { return false }
    return text.utf8.allSatisfy { $0 == 0x5F || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) }
  }

  // MARK: Shape

  /// What other files can see changed: every token outside the outermost function bodies, and the declarations.
  func shape() -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    var b = 0
    let bodies = outerBodies.sorted { $0.0 < $1.0 }
    var k = 0
    while k < count {
      while b < bodies.count, Int(bodies[b].1) <= k { b += 1 }
      if b < bodies.count, Int(bodies[b].0) <= k {
        k = Int(bodies[b].1)
        continue
      }
      hash = (hash ^ unit.hash(k)) &* 1_099_511_628_211
      k += 1
    }
    for decl in unit.decls { hash = (hash ^ decl.name ^ UInt64(decl.kind.rawValue)) &* 1_099_511_628_211 }
    return hash
  }
}
