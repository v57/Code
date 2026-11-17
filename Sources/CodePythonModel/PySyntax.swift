import CodeModel
import CodeScan
import Foundation

/// Python's reading of a file into the core's tables and its own scopes:
///
/// - Logical lines and blocks by indentation (the core's `LogicalLines`); a header's block is the lines indented
///   further, or the rest of its line.
/// - `class` is a `classType` (each base expression an inherited range, keywords like `metaclass=` left out), `def`
///   and `async def` a `function` with its parameters and return annotation. Names bound at a module's or a class's top
///   (assignments, annotations, `for`, `with` and `except` targets, walrus) are `variable`s, one per binding;
///   `self.x = …` in a method is a `variable` of its class (an instance attribute).
/// - Every scope (module, class body, function, lambda, comprehension) and every binding in it is in `PyFile`, with the
///   scope each token is read in: a default value, an annotation, a decorator or a comprehension's first iterable is
///   the enclosing scope's.
/// - Imports are the core's `Import`s, one per name they bind (`member` what `from m import` takes, `alias` the bound
///   name), with the module resolved to a key by `PyLayout.resolve`; `from m import *` is an import of member `*`.
///
/// Declarations other files see come first in the table; those in function bodies after them, so an edit to a body
/// keeps every other declaration's index.
final class PySyntax: LanguageSyntax {
  let profile = LexProfile.profile(forLanguage: "python")!
  let parametersHaveLabels = false
  /// A dotted module name (with its relative level) from a file, to its key (`PyLayout`'s): safe from any thread.
  let resolve: (_ dotted: String, _ level: Int, _ from: String) -> String

  init(resolve: @escaping (String, Int, String) -> String) { self.resolve = resolve }

  func parse(_ unit: Unit) -> UInt64 {
    let file = PyFile(path: unit.path)
    unit.scans[PyFile.key] = file
    var parser = PyParser(unit: unit, file: file, resolve: resolve)
    parser.parseFile()
    return parser.shapeHash()
  }

  /// Without comments and without the `\` that continues a line: it's part of the layout, not of a statement.
  func codeTokens(_ source: SourceFile) -> [Token] {
    var kept = [Token]()
    kept.reserveCapacity(source.tokens.count)
    for token in source.tokens where token.kind != .comment && token.kind != .docComment {
      if token.kind == .punctuation, token.length == 1, source.text[token.start] == 0x5C { continue }
      kept.append(token)
    }
    return kept
  }

  func evaluateCondition(_ unit: Unit, _ i: inout Int) -> Bool {
    i += 1
    return true
  }
}

enum PyScopeKind: UInt8 { case module, classBody, function, lambda, comprehension }

struct PyScope {
  var kind: PyScopeKind
  var parent: Int32
  /// The `def` or `class` it's the body of, -1 otherwise.
  var decl: Int32
  /// A method's first parameter (`self`, `cls`): 0 for a static method or a function outside a class.
  var selfName: Name = 0
  var globals: Set<Name> = []
  var nonlocals: Set<Name> = []
}

enum PyBindingKind: UInt8 {
  case assign, annotation, augmented, forTarget, withTarget, exceptTarget, parameter, function, classDecl
  case importModule, importMember, walrus, comprehension
}

/// Where a name is bound, and what gives it its value.
struct PyBinding {
  var name: Name
  var token: Int32
  var scope: Int32
  var kind: PyBindingKind
  /// The declaration it is, at a module's or a class's top (or a `def`/`class` anywhere); -1 for a local.
  var decl: Int32 = -1
  var importIndex: Int32 = -1
  /// The value (an assignment's right side, what `for` iterates, `with`'s context, `except`'s type, a default).
  var valueStart: Int32 = -1
  var valueEnd: Int32 = -1
  var annotationStart: Int32 = -1
  var annotationEnd: Int32 = -1
  /// Which of an unpacked value's items, from 1; 0 for the whole value, -1 for a starred or nested target. A
  /// parameter's index.
  var position: Int32 = 0
}

struct PyDecorations: OptionSet {
  let rawValue: UInt16
  static let property = PyDecorations(rawValue: 1), staticMethod = PyDecorations(rawValue: 2), classMethod = PyDecorations(rawValue: 4)
  static let setter = PyDecorations(rawValue: 8), dataclass = PyDecorations(rawValue: 16), overload = PyDecorations(rawValue: 32)
  static let isAsync = PyDecorations(rawValue: 64), deprecated = PyDecorations(rawValue: 128)
}

struct ScopeName: Hashable {
  var scope: Int32
  var name: Name
}

/// What a file has beyond the core's tables, read with its declarations.
final class PyFile: BodyFacts {
  static let key: Int32 = -1

  let path: String
  let isStub: Bool
  var lines: LogicalLines!
  var scopes: [PyScope] = []
  /// The scope each token is read in.
  var tokenScope: [Int32] = []
  var bindings: [PyBinding] = []
  var byName: [ScopeName: [Int32]] = [:]
  /// Bindings by their token.
  var byToken: [Int32: Int32] = [:]
  var decorations: [Int32: PyDecorations] = [:]
  var bindingOfDecl: [Int32: Int32] = [:]
  /// `from m import *`, by scope: the imports' indexes.
  var stars: [Int32: [Int32]] = [:]
  /// `__all__ = [...]` at the top, when it's a plain list of strings.
  var dunderAll: [String]?
  /// A module path's name in an import (`a.b` in `import a.b.c`): the dotted prefix up to it and its level.
  var modulePaths: [Int32: (dotted: String, level: Int32)] = [:]
  /// A `def`'s or `class`'s docstring token, by declaration (-1 for the module).
  var docstrings: [Int32: Int32] = [:]
  /// What a function's `return` statements return, by declaration: the expressions' tokens.
  var returns: [Int32: [(Int32, Int32)]] = [:]
  /// Function declarations with a `yield`: their calls give generators.
  var generators: Set<Int32> = []
  /// Types read in this file's bodies, dropped when any declaration changes.
  var types: [Int64: Ty] = [:]
  var resolving: Set<Int64> = []

  init(path: String) {
    self.path = path
    isStub = path.hasSuffix(".pyi")
  }

  func dropTypes() { types.removeAll() }

  /// The scope a token is read in.
  func scope(at token: Int) -> Int32 { token >= 0 && token < tokenScope.count ? tokenScope[token] : 0 }
}

enum PyWord {
  static let selfWord = name("self"), cls = name("cls"), all = name("__all__"), star = name("*"), initName = name("__init__")
  static let property = name("property"), staticmethod = name("staticmethod"), classmethod = name("classmethod"), setter = name("setter")
  static let getter = name("getter"), deleter = name("deleter"), dataclass = name("dataclass"), overload = name("overload")
  static let cachedProperty = name("cached_property"), deprecated = name("deprecated"), superWord = name("super")
  static let object = name("object"), type = name("type"), noneWord = name("None"), trueWord = name("True"), falseWord = name("False")
  static let generic = name("Generic"), protocolWord = name("Protocol"), builtins = name("builtins"), lambda = name("lambda")
  static let new = name("__new__"), enter = name("__enter__"), aenter = name("__aenter__"), iter = name("__iter__"), next = name("__next__")
  static let getitem = name("__getitem__"), call = name("__call__"), await = name("await"), anext = name("__anext__"), aiter = name("__aiter__")
  /// Words that only start a statement: a bracket left open before one, at or left of its line, is closed there.
  static let statementWords: Set<Name> = Set(
    ["def", "class", "return", "import", "from", "pass", "break", "continue", "raise", "try", "except", "finally", "with", "while", "del", "global",
     "nonlocal", "assert", "elif", "async"].map { name($0) })
}

/// Reads a file's statements into declarations, scopes and bindings.
struct PyParser {
  let unit: Unit
  let file: PyFile
  let resolve: (String, Int, String) -> String
  private var count: Int { unit.tokens.count }
  private var lines: LogicalLines { file.lines }
  /// Declarations in function bodies: moved after the rest at the end.
  private var local: [Bool] = []
  /// Self-attribute statements: their tokens count in the shape although they're in bodies.
  private var shapeRanges: [(Int32, Int32)] = []

  init(unit: Unit, file: PyFile, resolve: @escaping (String, Int, String) -> String) {
    self.unit = unit
    self.file = file
    self.resolve = resolve
  }

  mutating func parseFile() {
    file.lines = LogicalLines(unit, continuation: 0x5C, statementWords: PyWord.statementWords)
    file.tokenScope = [Int32](repeating: 0, count: count)
    file.scopes = [PyScope(kind: .module, parent: -1, decl: -1)]
    if count > 0, unit.tokens[0].kind == .string { file.docstrings[-1] = 0 }
    block(from: 0, to: lines.count, scope: 0)
    reorder()
  }

  // MARK: Shape

  /// Every token outside function bodies, and a method's `self.x = …` statements: what other files can see.
  func shapeHash() -> UInt64 {
    var bodies: [Int32: Int32] = [:]
    for decl in unit.decls where decl.kind == .function && decl.bodyOpen >= 0 && !decl.isLocal { bodies[decl.bodyOpen + 1] = decl.bodyClose }
    var kept: [Int32: Int32] = [:]
    for range in shapeRanges { kept[range.0] = range.1 }
    var shape: UInt64 = 14_695_981_039_346_656_037
    var i = 0
    while i < count {
      if let close = bodies[Int32(i)] {
        // Inside a body, only the statements that declare instance attributes.
        var k = i
        while k < Int(close) {
          if let end = kept[Int32(k)] {
            for j in k..<Int(end) { shape = (shape ^ unit.hash(j)) &* 1_099_511_628_211 }
            k = Int(end)
          } else {
            k += 1
          }
        }
        i = max(Int(close), i + 1)
        continue
      }
      shape = (shape ^ unit.hash(i)) &* 1_099_511_628_211
      i += 1
    }
    for item in unit.imports { shape = (shape ^ item.module) &* 1_099_511_628_211 }
    return shape
  }

  /// Declarations other files see first, then the bodies' own, every index into the table moved to match.
  private mutating func reorder() {
    guard local.contains(true) else { return }
    var order: [Int32] = []
    for index in unit.decls.indices where !local[index] { order.append(Int32(index)) }
    for index in unit.decls.indices where local[index] { order.append(Int32(index)) }
    var moved = [Int32](repeating: -1, count: order.count)
    for (new, old) in order.enumerated() { moved[Int(old)] = Int32(new) }
    func map(_ index: Int32) -> Int32 { index >= 0 ? moved[Int(index)] : index }
    var decls = order.map { unit.decls[Int($0)] }
    for k in decls.indices { decls[k].parent = map(decls[k].parent) }
    unit.decls = decls
    for k in file.scopes.indices { file.scopes[k].decl = map(file.scopes[k].decl) }
    for k in file.bindings.indices { file.bindings[k].decl = map(file.bindings[k].decl) }
    file.decorations = Dictionary(uniqueKeysWithValues: file.decorations.map { (map($0.key), $0.value) })
    file.bindingOfDecl = Dictionary(uniqueKeysWithValues: file.bindingOfDecl.map { (map($0.key), $0.value) })
    file.docstrings = Dictionary(uniqueKeysWithValues: file.docstrings.map { ($0.key >= 0 ? map($0.key) : $0.key, $0.value) })
    file.returns = Dictionary(uniqueKeysWithValues: file.returns.map { (map($0.key), $0.value) })
    file.generators = Set(file.generators.map(map))
  }

  // MARK: Statements

  private mutating func block(from: Int, to: Int, scope: Int32) {
    var line = from
    while line < to { line = statement(line, scope: scope, limit: to) }
  }

  /// One logical line's statement and its block: the next line to read.
  private mutating func statement(_ line: Int, scope: Int32, limit: Int) -> Int {
    let start = Int(lines.starts[line])
    let end = lines.end(of: line)
    fill(start, end, scope)
    // An indented line with no header above it (code being moved): read as part of this block.
    var i = start
    var decorators: [(Int, Int)] = []
    var next = line
    while unit.isByte(i, 0x40), next < limit {
      fill(i, lines.end(of: next), scope)
      decorators.append((i + 1, lines.end(of: next)))
      expression(i + 1, lines.end(of: next), scope: scope)
      next += 1
      guard next < limit else { return next }
      i = Int(lines.starts[next])
    }
    let lineEnd = lines.end(of: next)
    if next != line { fill(i, lineEnd, scope) }
    var isAsync = false
    if unit.isToken(i, "async") {
      isAsync = true
      i += 1
    }
    if unit.isToken(i, "def") {
      return function(first: decorators.first.map { $0.0 - 1 } ?? start, at: i, line: next, end: lineEnd, scope: scope, decorators: decorators, isAsync: isAsync)
    }
    if unit.isToken(i, "class") {
      return classDef(first: decorators.first.map { $0.0 - 1 } ?? start, at: i, line: next, end: lineEnd, scope: scope, decorators: decorators)
    }
    if unit.tokens[i].kind == .keyword || unit.tokens[i].kind == .identifier {
      switch unit.string(i) {
      case "if", "elif", "while":
        let colon = headerColon(i + 1, lineEnd)
        expression(i + 1, colon, scope: scope)
        return suite(line: next, colon: colon, end: lineEnd, scope: scope)
      case "else", "try", "finally":
        return suite(line: next, colon: headerColon(i + 1, lineEnd), end: lineEnd, scope: scope)
      case "for":
        let colon = headerColon(i + 1, lineEnd)
        if let inToken = topLevel("in", from: i + 1, to: colon) {
          expression(inToken + 1, colon, scope: scope)
          targets(i + 1, inToken, scope: scope, kind: .forTarget, value: (Int32(inToken + 1), Int32(colon)), statement: (i, colon))
        }
        return suite(line: next, colon: colon, end: lineEnd, scope: scope)
      case "with":
        let colon = headerColon(i + 1, lineEnd)
        withItems(i + 1, colon, scope: scope)
        return suite(line: next, colon: colon, end: lineEnd, scope: scope)
      case "except":
        let colon = headerColon(i + 1, lineEnd)
        var from = i + 1
        if unit.isByte(from, 0x2A) { from += 1 }
        if let asToken = topLevel("as", from: from, to: colon), asToken + 1 < colon, unit.tokens[asToken + 1].kind == .identifier {
          expression(from, asToken, scope: scope)
          bind(asToken + 1, scope: scope, kind: .exceptTarget, value: (Int32(from), Int32(asToken)), statement: (i, colon))
        } else {
          expression(from, colon, scope: scope)
        }
        return suite(line: next, colon: colon, end: lineEnd, scope: scope)
      default:
        break
      }
    }
    simple(i, lineEnd, scope: scope)
    // A block under a line that opens none (a stray indent): its statements are still this scope's.
    let blockEnd = lines.blockEnd(after: next)
    if blockEnd > next + 1 { block(from: next + 1, to: min(blockEnd, limit), scope: scope) }
    return max(next + 1, min(blockEnd, limit))
  }

  /// Sets the scope tokens are read in.
  private func fill(_ from: Int, _ to: Int, _ scope: Int32) {
    var k = max(0, from)
    let end = min(to, count)
    while k < end {
      file.tokenScope[k] = scope
      k += 1
    }
  }

  /// A compound statement's `:`: the first outside brackets that isn't a lambda's.
  private func headerColon(_ from: Int, _ end: Int) -> Int {
    var depth = 0
    var lambdas = 0
    var k = from
    while k < end {
      switch unit.tokens[k].kind {
      case .open, .interpolationOpen: depth += 1
      case .close, .interpolationClose: depth = max(0, depth - 1)
      case .keyword where depth == 0 && unit.isToken(k, "lambda"): lambdas += 1
      case .punctuation where depth == 0 && unit.isByte(k, 0x3A):
        if !unit.isWalrus(k) {
          if lambdas == 0 { return k }
          lambdas -= 1
        }
      default: break
      }
      k += 1
    }
    return end
  }

  /// A header's block: the rest of its line, or the lines indented under it.
  private mutating func suite(line: Int, colon: Int, end: Int, scope: Int32) -> Int {
    if colon + 1 < end {
      simple(colon + 1, end, scope: scope)
      let blockEnd = lines.blockEnd(after: line)
      if blockEnd > line + 1 { block(from: line + 1, to: blockEnd, scope: scope) }
      return blockEnd
    }
    let blockEnd = lines.blockEnd(after: line)
    block(from: line + 1, to: blockEnd, scope: scope)
    return blockEnd
  }

  /// The first `word` outside brackets in a range.
  private func topLevel(_ word: StaticString, from: Int, to: Int) -> Int? {
    var depth = 0
    var k = from
    while k < to {
      switch unit.tokens[k].kind {
      case .open, .interpolationOpen: depth += 1
      case .close, .interpolationClose: depth -= 1
      default: if depth == 0, unit.isToken(k, word) { return k }
      }
      k += 1
    }
    return nil
  }

  /// Splits a range at commas outside brackets.
  private func items(_ from: Int, _ to: Int) -> [(Int, Int)] {
    var result: [(Int, Int)] = []
    var depth = 0
    var start = from
    var k = from
    while k < to {
      switch unit.tokens[k].kind {
      case .open, .interpolationOpen: depth += 1
      case .close, .interpolationClose: depth -= 1
      case .punctuation where depth == 0 && unit.isByte(k, 0x2C):
        result.append((start, k))
        start = k + 1
      default: break
      }
      k += 1
    }
    if start < to { result.append((start, to)) }
    return result
  }

  // MARK: def and class

  private mutating func function(first: Int, at def: Int, line: Int, end: Int, scope: Int32, decorators: [(Int, Int)], isAsync: Bool) -> Int {
    let nameToken = def + 1
    guard nameToken < end, unit.tokens[nameToken].kind == .identifier || unit.tokens[nameToken].kind == .keyword else {
      return suite(line: line, colon: headerColon(def + 1, end), end: end, scope: scope)
    }
    let holder = file.scopes[Int(scope)]
    let parentDecl = holder.kind == .module ? -1 : holder.decl
    var decl = Decl(kind: .function, name: unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(first), parent: parentDecl)
    decl.isLocal = holder.kind != .module && holder.kind != .classBody
    var flags = decorations(decorators)
    if isAsync { flags.insert(.isAsync) }
    var open = nameToken + 1
    // `def f[T](…)` (3.12): type parameters.
    if unit.isByte(open, 0x5B) { open = unit.skipBalanced(open) }
    var close = open
    if unit.isByte(open, 0x28) { close = max(open, unit.skipBalanced(open) - 1) }
    let colon = headerColon(close + 1, end)
    if unit.isToken(close + 1, "->"), close + 2 < colon {
      decl.typeStart = Int32(close + 2)
      decl.typeEnd = Int32(colon)
      expression(close + 2, colon, scope: scope)
    }
    let declIndex = Int32(unit.decls.count)
    let inner = Int32(file.scopes.count)
    var newScope = PyScope(kind: .function, parent: scope, decl: declIndex)
    decl.bodyOpen = Int32(colon)
    // Parameters.
    decl.paramStart = Int32(unit.params.count)
    var parameterBindings: [(token: Int, index: Int, annotation: (Int32, Int32), value: (Int32, Int32))] = []
    if unit.isByte(open, 0x28) {
      for (index, item) in parameterItems(open + 1, close).enumerated() {
        unit.params.append(
          Param(label: item.name, local: item.name, nameToken: Int32(item.token), typeStart: item.annotation.0, typeEnd: item.annotation.1, hasDefault: item.value.0 >= 0,
                variadic: item.variadic))
        if item.annotation.0 >= 0 { expression(Int(item.annotation.0), Int(item.annotation.1), scope: scope) }
        if item.value.0 >= 0 { expression(Int(item.value.0), Int(item.value.1), scope: scope) }
        parameterBindings.append((item.token, index, item.annotation, item.value))
      }
    }
    decl.paramCount = Int32(unit.params.count) - decl.paramStart
    if holder.kind == .classBody, !flags.contains(.staticMethod), let firstParam = parameterBindings.first, !unit.isByte(firstParam.token - 1, 0x2A) {
      newScope.selfName = unit.hash(firstParam.token)
    }
    file.scopes.append(newScope)
    unit.decls.append(decl)
    local.append(decl.isLocal)
    if !flags.isEmpty { file.decorations[declIndex] = flags }
    bind(nameToken, scope: scope, kind: .function, decl: declIndex)
    for parameter in parameterBindings {
      file.tokenScope[parameter.token] = inner
      var binding = PyBinding(name: unit.hash(parameter.token), token: Int32(parameter.token), scope: inner, kind: .parameter)
      binding.annotationStart = parameter.annotation.0
      binding.annotationEnd = parameter.annotation.1
      binding.valueStart = parameter.value.0
      binding.valueEnd = parameter.value.1
      binding.position = Int32(parameter.index)
      add(binding)
    }
    // The body.
    let next: Int
    if colon + 1 < end {
      fill(colon + 1, end, inner)
      simple(colon + 1, end, scope: inner)
      next = line + 1
      unit.decls[Int(declIndex)].bodyClose = Int32(end)
    } else {
      let blockEnd = lines.blockEnd(after: line)
      let bodyEnd = lines.end(of: blockEnd - 1)
      if blockEnd > line + 1 {
        fill(colon + 1, bodyEnd, inner)
        let firstToken = Int(lines.starts[line + 1])
        if unit.tokens[firstToken].kind == .string { file.docstrings[declIndex] = Int32(firstToken) }
        block(from: line + 1, to: blockEnd, scope: inner)
      }
      next = blockEnd
      unit.decls[Int(declIndex)].bodyClose = Int32(max(colon + 1, bodyEnd))
    }
    unit.decls[Int(declIndex)].end = unit.decls[Int(declIndex)].bodyClose
    return next
  }

  /// A parameter list's names, annotations and defaults; `*` and `/` alone are markers.
  private func parameterItems(_ from: Int, _ to: Int) -> [(token: Int, name: Name, annotation: (Int32, Int32), value: (Int32, Int32), variadic: Bool)] {
    var result: [(token: Int, name: Name, annotation: (Int32, Int32), value: (Int32, Int32), variadic: Bool)] = []
    for (start, end) in items(from, to) {
      var k = start
      var variadic = false
      if unit.isByte(k, 0x2A) || unit.isToken(k, "**") {
        variadic = true
        k += 1
      }
      guard k < end, unit.tokens[k].kind == .identifier || unit.tokens[k].kind == .keyword && !unit.isToken(k, "lambda") else { continue }
      var annotation: (Int32, Int32) = (-1, -1)
      var value: (Int32, Int32) = (-1, -1)
      var j = k + 1
      if j < end, unit.isByte(j, 0x3A) {
        let annotationEnd = (j + 1..<end).first { unit.isByte($0, 0x3D) || unit.startsWithAssign($0) } ?? end
        annotation = (Int32(j + 1), Int32(annotationEnd))
        j = annotationEnd
      }
      if j < end, unit.isByte(j, 0x3D) || unit.startsWithAssign(j) {
        value = (Int32(unit.isByte(j, 0x3D) ? j + 1 : j), Int32(end))
      }
      result.append((k, unit.hash(k), annotation, value, variadic))
    }
    return result
  }

  private func decorations(_ decorators: [(Int, Int)]) -> PyDecorations {
    var flags: PyDecorations = []
    for (start, end) in decorators where start < end {
      // The decorator's last name before its arguments: `property`, `x.setter`, `functools.cached_property`.
      var last = start
      var k = start
      while k < end, unit.tokens[k].kind == .identifier || unit.isByte(k, 0x2E) {
        if unit.tokens[k].kind == .identifier { last = k }
        k += 1
      }
      switch unit.hash(last) {
      case PyWord.property, PyWord.cachedProperty, PyWord.getter: flags.insert(.property)
      case PyWord.staticmethod: flags.insert(.staticMethod)
      case PyWord.classmethod: flags.insert(.classMethod)
      case PyWord.setter, PyWord.deleter: flags.insert(.setter)
      case PyWord.dataclass: flags.insert(.dataclass)
      case PyWord.overload: flags.insert(.overload)
      case PyWord.deprecated: flags.insert(.deprecated)
      default: break
      }
    }
    return flags
  }

  private mutating func classDef(first: Int, at keyword: Int, line: Int, end: Int, scope: Int32, decorators: [(Int, Int)]) -> Int {
    let nameToken = keyword + 1
    guard nameToken < end, unit.tokens[nameToken].kind == .identifier || unit.tokens[nameToken].kind == .keyword else {
      return suite(line: line, colon: headerColon(keyword + 1, end), end: end, scope: scope)
    }
    let holder = file.scopes[Int(scope)]
    var decl = Decl(kind: .classType, name: unit.hash(nameToken), nameToken: Int32(nameToken), first: Int32(first), parent: holder.kind == .module ? -1 : holder.decl)
    decl.isLocal = holder.kind != .module && holder.kind != .classBody
    var open = nameToken + 1
    if unit.isByte(open, 0x5B) { open = unit.skipBalanced(open) }
    let colon = headerColon(open, end)
    decl.inheritStart = Int32(unit.ranges.count)
    if unit.isByte(open, 0x28) {
      let close = max(open, unit.skipBalanced(open) - 1)
      for (start, itemEnd) in items(open + 1, close) {
        expression(start, itemEnd, scope: scope)
        // `metaclass=M`, `total=False`: keywords, not bases.
        if unit.tokens[start].kind == .identifier, start + 1 < itemEnd, unit.isByte(start + 1, 0x3D) || unit.startsWithAssign(start + 1) { continue }
        if unit.isByte(start, 0x2A) || unit.isToken(start, "**") { continue }
        unit.ranges.append((Int32(start), Int32(itemEnd)))
      }
    }
    decl.inheritCount = Int32(unit.ranges.count) - decl.inheritStart
    decl.bodyOpen = Int32(colon)
    let declIndex = Int32(unit.decls.count)
    unit.decls.append(decl)
    local.append(decl.isLocal)
    let flags = decorations(decorators)
    if !flags.isEmpty { file.decorations[declIndex] = flags }
    bind(nameToken, scope: scope, kind: .classDecl, decl: declIndex)
    let inner = Int32(file.scopes.count)
    file.scopes.append(PyScope(kind: .classBody, parent: scope, decl: declIndex))
    let next: Int
    if colon + 1 < end {
      fill(colon + 1, end, inner)
      simple(colon + 1, end, scope: inner)
      unit.decls[Int(declIndex)].bodyClose = Int32(end)
      next = line + 1
    } else {
      let blockEnd = lines.blockEnd(after: line)
      let bodyEnd = lines.end(of: blockEnd - 1)
      if blockEnd > line + 1 {
        fill(colon + 1, bodyEnd, inner)
        let firstToken = Int(lines.starts[line + 1])
        if unit.tokens[firstToken].kind == .string { file.docstrings[declIndex] = Int32(firstToken) }
        block(from: line + 1, to: blockEnd, scope: inner)
      }
      unit.decls[Int(declIndex)].bodyClose = Int32(max(colon + 1, bodyEnd))
      next = blockEnd
    }
    unit.decls[Int(declIndex)].end = unit.decls[Int(declIndex)].bodyClose
    return next
  }

  // MARK: Simple statements

  /// Statements on one line, split at `;`.
  private mutating func simple(_ from: Int, _ to: Int, scope: Int32) {
    var start = from
    var depth = 0
    var k = from
    while k <= to {
      if k == to || depth == 0 && unit.isByte(k, 0x3B) {
        if start < k { small(start, k, scope: scope) }
        start = k + 1
      } else {
        switch unit.tokens[k].kind {
        case .open, .interpolationOpen: depth += 1
        case .close, .interpolationClose: depth -= 1
        default: break
        }
      }
      k += 1
    }
  }

  private mutating func small(_ start: Int, _ end: Int, scope: Int32) {
    let kind = unit.tokens[start].kind
    if kind == .keyword {
      switch unit.string(start) {
      case "import":
        importNames(start + 1, end, scope: scope)
        return
      case "from":
        fromImport(start + 1, end, scope: scope)
        return
      case "global", "nonlocal":
        let isGlobal = unit.isToken(start, "global")
        for k in start + 1..<end where unit.tokens[k].kind == .identifier {
          if isGlobal { file.scopes[Int(scope)].globals.insert(unit.hash(k)) } else { file.scopes[Int(scope)].nonlocals.insert(unit.hash(k)) }
        }
        return
      case "return":
        if start + 1 < end {
          expression(start + 1, end, scope: scope)
          if let function = enclosingFunction(scope) {
            file.returns[function, default: []].append((Int32(start + 1), Int32(end)))
            // What an unannotated function returns is what other files see of it.
            if !local[Int(function)], unit.decls[Int(function)].typeStart < 0 { shapeRanges.append((Int32(start), Int32(end))) }
          }
        }
        return
      case "del", "pass", "break", "continue", "raise", "assert", "await", "yield":
        if unit.isToken(start, "yield"), let function = enclosingFunction(scope) { file.generators.insert(function) }
        expression(start + 1, end, scope: scope)
        return
      default:
        break
      }
    }
    // Assignments: `a = b = value`, `x: T = value`, `x += 1`.
    var depth = 0
    var equals: [Int] = []
    var colon = -1
    var augmented = -1
    var lambdas = 0
    for k in start..<end {
      switch unit.tokens[k].kind {
      case .open, .interpolationOpen: depth += 1
      case .close, .interpolationClose: depth -= 1
      case .keyword where depth == 0 && unit.isToken(k, "lambda"): lambdas += 1
      case .keyword where depth == 0 && unit.isToken(k, "yield"):
        if let function = enclosingFunction(scope) { file.generators.insert(function) }
      case .punctuation where depth == 0:
        if unit.isByte(k, 0x3A), !unit.isWalrus(k) {
          if lambdas > 0 { lambdas -= 1 } else if colon < 0, equals.isEmpty { colon = k }
        } else if unit.isByte(k, 0x3D) || unit.startsWithAssign(k) {
          if lambdas == 0, !unit.isWalrus(k - 1) { equals.append(k) }
        } else if equals.isEmpty, augmented < 0, unit.isAugmented(k) {
          augmented = k
        }
      default: break
      }
    }
    if augmented >= 0 {
      expression(augmented + 1, end, scope: scope)
      targets(start, augmented, scope: scope, kind: .augmented, value: (Int32(augmented + 1), Int32(end)), statement: (start, end))
      return
    }
    if colon >= 0 {
      // `x: T` or `x: T = v`.
      let annotationEnd = equals.first ?? end
      expression(colon + 1, annotationEnd, scope: scope)
      var value: (Int32, Int32) = (-1, -1)
      if let first = equals.first {
        let valueStart = unit.isByte(first, 0x3D) ? first + 1 : first
        expression(valueStart, end, scope: scope)
        value = (Int32(valueStart), Int32(end))
      }
      targets(start, colon, scope: scope, kind: value.0 >= 0 ? .assign : .annotation, value: value, annotation: (Int32(colon + 1), Int32(annotationEnd)), statement: (start, end))
      return
    }
    guard let last = equals.last else {
      expression(start, end, scope: scope)
      return
    }
    let valueStart = unit.isByte(last, 0x3D) ? last + 1 : last
    expression(valueStart, end, scope: scope)
    var targetStart = start
    for equal in equals {
      targets(targetStart, equal, scope: scope, kind: .assign, value: (Int32(valueStart), Int32(end)), statement: (start, end))
      targetStart = equal + 1
    }
    if file.scopes[Int(scope)].kind == .module, equals.count == 1, end - start >= 3, unit.hash(start) == PyWord.all, unit.isByte(start + 1, 0x3D) {
      readAll(valueStart, end)
    }
  }

  private mutating func readAll(_ from: Int, _ to: Int) {
    guard unit.isByte(from, 0x5B) || unit.isByte(from, 0x28) else { return }
    var names: [String] = []
    for k in from + 1..<to - 1 {
      if unit.tokens[k].kind == .string { names.append(unit.pyStringValue(k)) } else if !unit.isByte(k, 0x2C) { return }
    }
    file.dunderAll = names
  }

  /// The function a scope is the body of, or is inside (lambdas and comprehensions are in their function).
  private func enclosingFunction(_ scope: Int32) -> Int32? {
    var at = scope
    while at >= 0 {
      let item = file.scopes[Int(at)]
      if item.kind == .function { return item.decl }
      if item.kind != .lambda && item.kind != .comprehension { return nil }
      at = item.parent
    }
    return nil
  }

  /// `with a as x, b as (y, z):`.
  private mutating func withItems(_ from: Int, _ to: Int, scope: Int32) {
    var from = from
    var to = to
    // `with (a as x, b as y):`.
    if unit.isByte(from, 0x28), unit.skipBalanced(from) == to, topLevel("as", from: from + 1, to: to - 1) != nil || items(from + 1, to - 1).count > 1 {
      from += 1
      to -= 1
    }
    for (start, end) in items(from, to) {
      if let asToken = topLevel("as", from: start, to: end) {
        expression(start, asToken, scope: scope)
        targets(asToken + 1, end, scope: scope, kind: .withTarget, value: (Int32(start), Int32(asToken)), statement: (start, end))
      } else {
        expression(start, end, scope: scope)
      }
    }
  }

  // MARK: Targets and bindings

  /// The names a target list binds: `a`, `a, b`, `(a, [b, *c])`, `self.x`; others (subscripts, attributes of other
  /// values) are read as expressions.
  private mutating func targets(
    _ from: Int, _ to: Int, scope: Int32, kind: PyBindingKind, value: (Int32, Int32), annotation: (Int32, Int32) = (-1, -1), statement: (Int, Int)
  ) {
    var from = from
    var to = to
    while from < to, unit.isByte(from, 0x28) || unit.isByte(from, 0x5B), unit.skipBalanced(from) == to {
      from += 1
      to -= 1
    }
    let parts = items(from, to)
    if parts.count > 1 || parts.count == 1 && to < count && unit.isByte(to - 1, 0x2C) {
      for (index, part) in parts.enumerated() { target(part.0, part.1, scope: scope, kind: kind, value: value, annotation: annotation, position: Int32(index + 1), statement: statement) }
    } else if let part = parts.first {
      target(part.0, part.1, scope: scope, kind: kind, value: value, annotation: annotation, position: 0, statement: statement)
    }
  }

  private mutating func target(
    _ from: Int, _ to: Int, scope: Int32, kind: PyBindingKind, value: (Int32, Int32), annotation: (Int32, Int32), position: Int32, statement: (Int, Int)
  ) {
    guard from < to else { return }
    if to - from == 1, unit.tokens[from].kind == .identifier {
      bind(from, scope: scope, kind: kind, value: value, annotation: annotation, position: position, statement: statement)
      return
    }
    if unit.isByte(from, 0x2A), to - from == 2, unit.tokens[from + 1].kind == .identifier {
      bind(from + 1, scope: scope, kind: kind, value: value, annotation: annotation, position: -1, statement: statement)
      return
    }
    if unit.isByte(from, 0x28) || unit.isByte(from, 0x5B), unit.skipBalanced(from) == to {
      for part in items(from + 1, to - 1) { target(part.0, part.1, scope: scope, kind: kind, value: value, annotation: (-1, -1), position: -1, statement: statement) }
      return
    }
    // `self.x = …` in a method: an instance attribute of its class.
    let holder = file.scopes[Int(scope)]
    if to - from == 3, holder.selfName != 0, unit.hash(from) == holder.selfName, unit.isByte(from + 1, 0x2E), unit.tokens[from + 2].kind == .identifier || unit.tokens[from + 2].kind == .keyword,
      let method = Optional(holder.decl), method >= 0, case let classDecl = unit.decls[Int(method)].parent, classDecl >= 0
    {
      var decl = Decl(kind: .variable, name: unit.hash(from + 2), nameToken: Int32(from + 2), first: Int32(from), parent: classDecl)
      decl.end = Int32(statement.1)
      decl.initStart = value.0
      decl.initEnd = value.1
      decl.typeStart = annotation.0
      decl.typeEnd = annotation.1
      decl.valueIndex = max(0, position)
      let declIndex = Int32(unit.decls.count)
      unit.decls.append(decl)
      local.append(false)
      var binding = PyBinding(name: decl.name, token: Int32(from + 2), scope: scope, kind: kind)
      binding.decl = declIndex
      binding.valueStart = value.0
      binding.valueEnd = value.1
      binding.annotationStart = annotation.0
      binding.annotationEnd = annotation.1
      binding.position = position
      // Not in the scope's names: it's an attribute, found through its class.
      let index = Int32(file.bindings.count)
      file.bindings.append(binding)
      file.byToken[binding.token] = index
      file.bindingOfDecl[declIndex] = index
      shapeRanges.append((Int32(statement.0), Int32(statement.1)))
      return
    }
    expression(from, to, scope: scope)
  }

  /// A name bound in a scope: a declaration at a module's or a class's top, a local elsewhere.
  @discardableResult
  private mutating func bind(
    _ token: Int, scope: Int32, kind: PyBindingKind, decl declIndex: Int32 = -1, value: (Int32, Int32) = (-1, -1), annotation: (Int32, Int32) = (-1, -1),
    position: Int32 = 0, statement: (Int, Int) = (0, 0), importIndex: Int32 = -1
  ) -> Int32 {
    var binding = PyBinding(name: unit.hash(token), token: Int32(token), scope: target(of: unit.hash(token), in: scope), kind: kind)
    binding.valueStart = value.0
    binding.valueEnd = value.1
    binding.annotationStart = annotation.0
    binding.annotationEnd = annotation.1
    binding.position = position
    binding.importIndex = importIndex
    binding.decl = declIndex
    let holder = file.scopes[Int(scope)]
    if declIndex < 0, importIndex < 0, binding.scope == scope, holder.kind == .module || holder.kind == .classBody {
      var decl = Decl(kind: .variable, name: binding.name, nameToken: Int32(token), first: Int32(statement.0), parent: holder.kind == .module ? -1 : holder.decl)
      decl.end = Int32(max(statement.1, token + 1))
      if kind == .assign || kind == .annotation || kind == .walrus {
        decl.initStart = value.0
        decl.initEnd = value.1
      }
      decl.typeStart = annotation.0
      decl.typeEnd = annotation.1
      decl.valueIndex = max(0, position)
      binding.decl = Int32(unit.decls.count)
      unit.decls.append(decl)
      local.append(false)
    }
    return add(binding)
  }

  /// The scope a name bound in `scope` belongs to: the module's after `global`, the nearest enclosing function's that
  /// binds it after `nonlocal`.
  private func target(of word: Name, in scope: Int32) -> Int32 {
    let item = file.scopes[Int(scope)]
    if item.globals.contains(word) { return 0 }
    guard item.nonlocals.contains(word) else { return scope }
    var outer = item.parent
    var nearest: Int32 = -1
    while outer > 0 {
      let enclosing = file.scopes[Int(outer)]
      if enclosing.kind == .function {
        if nearest < 0 { nearest = outer }
        if file.byName[ScopeName(scope: outer, name: word)] != nil, !enclosing.nonlocals.contains(word) { return outer }
      }
      outer = enclosing.parent
    }
    return nearest >= 0 ? nearest : scope
  }

  @discardableResult
  private mutating func add(_ binding: PyBinding) -> Int32 {
    let index = Int32(file.bindings.count)
    file.bindings.append(binding)
    file.byName[ScopeName(scope: binding.scope, name: binding.name), default: []].append(index)
    if file.byToken[binding.token] == nil { file.byToken[binding.token] = index }
    if binding.decl >= 0 { file.bindingOfDecl[binding.decl] = index }
    return index
  }

  // MARK: Imports

  /// `import a.b.c, d as e`.
  private mutating func importNames(_ from: Int, _ end: Int, scope: Int32) {
    for (start, itemEnd) in items(from, end) {
      var k = start
      var dotted = ""
      var first = -1
      var last = -1
      while k < itemEnd, unit.tokens[k].kind == .identifier || unit.tokens[k].kind == .keyword && !unit.isToken(k, "as") {
        if first < 0 { first = k }
        dotted += (dotted.isEmpty ? "" : ".") + unit.string(k)
        file.modulePaths[Int32(k)] = (dotted, 0)
        last = k
        k += 1
        guard unit.isByte(k, 0x2E) else { break }
        k += 1
      }
      guard first >= 0 else { continue }
      fill(start, itemEnd, scope)
      if unit.isToken(k, "as"), k + 1 < itemEnd {
        let key = resolve(dotted, 0, unit.path)
        var item = Import(module: name(key), moduleName: key, isExported: false, isTestable: false)
        item.alias = unit.hash(k + 1)
        item.aliasToken = Int32(k + 1)
        item.token = Int32(last)
        let index = Int32(unit.imports.count)
        unit.imports.append(item)
        bind(k + 1, scope: scope, kind: .importModule, importIndex: index)
      } else {
        // `import a.b.c` binds `a`, the top package.
        let top = unit.string(first)
        let key = resolve(top, 0, unit.path)
        var item = Import(module: name(key), moduleName: key, isExported: false, isTestable: false)
        item.alias = unit.hash(first)
        item.aliasToken = Int32(first)
        item.token = Int32(last)
        let index = Int32(unit.imports.count)
        unit.imports.append(item)
        bind(first, scope: scope, kind: .importModule, importIndex: index)
      }
    }
  }

  /// `from .a.b import c as d, e`, `from m import (x, y)`, `from m import *`.
  private mutating func fromImport(_ from: Int, _ end: Int, scope: Int32) {
    var k = from
    var level = 0
    while k < end, unit.tokens[k].kind == .punctuation, unit.isAllDots(k) {
      level += unit.tokens[k].length
      k += 1
    }
    var dotted = ""
    var last = -1
    while k < end, unit.tokens[k].kind == .identifier || unit.tokens[k].kind == .keyword && !unit.isToken(k, "import") {
      dotted += (dotted.isEmpty ? "" : ".") + unit.string(k)
      file.modulePaths[Int32(k)] = (dotted, Int32(level))
      last = k
      k += 1
      guard unit.isByte(k, 0x2E) else { break }
      k += 1
    }
    fill(from, end, scope)
    guard unit.isToken(k, "import") else { return }
    let key = resolve(dotted, level, unit.path)
    var listStart = k + 1
    var listEnd = end
    if unit.isByte(listStart, 0x28) {
      listEnd = min(end, unit.skipBalanced(listStart) - 1)
      listStart += 1
    }
    for (start, itemEnd) in items(listStart, listEnd) {
      if unit.isByte(start, 0x2A) {
        var item = Import(module: name(key), moduleName: key, isExported: false, isTestable: false)
        item.member = PyWord.star
        item.token = Int32(max(last, start))
        file.stars[scope, default: []].append(Int32(unit.imports.count))
        unit.imports.append(item)
        continue
      }
      guard unit.tokens[start].kind == .identifier || unit.tokens[start].kind == .keyword else { continue }
      var item = Import(module: name(key), moduleName: key, isExported: false, isTestable: false)
      item.member = unit.hash(start)
      item.memberToken = Int32(start)
      item.token = Int32(last >= 0 ? last : start)
      var bound = start
      if unit.isToken(start + 1, "as"), start + 2 < itemEnd { bound = start + 2 }
      item.alias = unit.hash(bound)
      item.aliasToken = Int32(bound)
      let index = Int32(unit.imports.count)
      unit.imports.append(item)
      bind(bound, scope: scope, kind: .importMember, importIndex: index)
    }
  }

  // MARK: Expressions

  /// Reads an expression's nested scopes (lambdas, comprehensions) and walrus bindings.
  private mutating func expression(_ from: Int, _ to: Int, scope: Int32) {
    var k = from
    while k < to {
      let token = unit.tokens[k]
      switch token.kind {
      case .keyword where unit.isToken(k, "lambda"):
        k = lambda(k, limit: to, scope: scope)
        continue
      case .open:
        let close = min(unit.skipBalanced(k), to)
        if let forToken = comprehensionFor(k + 1, close - 1) {
          comprehension(k, forToken, close - 1, scope: scope)
        } else {
          expression(k + 1, close - 1, scope: scope)
        }
        k = max(close, k + 1)
        continue
      case .identifier where unit.isWalrus(k + 1):
        var holder = scope
        while holder > 0, file.scopes[Int(holder)].kind == .comprehension { holder = file.scopes[Int(holder)].parent }
        // The value runs to the end of the bracket or item.
        var end = k + 3
        var depth = 0
        while end < to {
          if unit.tokens[end].kind == .open { depth += 1 } else if unit.tokens[end].kind == .close {
            if depth == 0 { break }
            depth -= 1
          } else if depth == 0, unit.isByte(end, 0x2C) {
            break
          }
          end += 1
        }
        bind(k, scope: holder, kind: .walrus, value: (Int32(k + 3), Int32(end)), statement: (k, end))
        k += 2
        continue
      default:
        break
      }
      k += 1
    }
  }

  /// The `for` of a comprehension directly inside a bracket.
  private func comprehensionFor(_ from: Int, _ to: Int) -> Int? {
    guard from < to else { return nil }
    var depth = 0
    var k = from
    while k < to {
      switch unit.tokens[k].kind {
      case .open, .interpolationOpen: depth += 1
      case .close, .interpolationClose: depth -= 1
      case .keyword where depth == 0 && unit.isToken(k, "for"): return k
      default: break
      }
      k += 1
    }
    return nil
  }

  /// `[elt for a in xs if c for b in a]`: a scope over the bracket, its first iterable read outside.
  private mutating func comprehension(_ open: Int, _ firstFor: Int, _ close: Int, scope: Int32) {
    let inner = Int32(file.scopes.count)
    file.scopes.append(PyScope(kind: .comprehension, parent: scope, decl: -1))
    fill(open + 1, close, inner)
    // Clauses: `for targets in iterable`, `if condition`.
    var clauses: [Int] = []
    var depth = 0
    for k in firstFor..<close {
      switch unit.tokens[k].kind {
      case .open, .interpolationOpen: depth += 1
      case .close, .interpolationClose: depth -= 1
      case .keyword where depth == 0 && (unit.isToken(k, "for") || unit.isToken(k, "if")):
        if unit.isToken(k, "if"), isConditionalExpression(k, from: firstFor) { continue }
        clauses.append(k)
      default: break
      }
    }
    clauses.append(close)
    expression(open + 1, unit.isToken(firstFor - 1, "async") ? firstFor - 1 : firstFor, scope: inner)
    for (n, clause) in clauses.dropLast().enumerated() {
      let next = clauses[n + 1]
      if unit.isToken(clause, "for") {
        guard let inToken = topLevel("in", from: clause + 1, to: next) else { continue }
        let iterableEnd = unit.isToken(next - 1, "async") ? next - 1 : next
        if n == 0 {
          fill(inToken + 1, iterableEnd, scope)
          expression(inToken + 1, iterableEnd, scope: scope)
        } else {
          expression(inToken + 1, iterableEnd, scope: inner)
        }
        targets(clause + 1, inToken, scope: inner, kind: .comprehension, value: (Int32(inToken + 1), Int32(iterableEnd)), statement: (clause, iterableEnd))
      } else {
        expression(clause + 1, next, scope: inner)
      }
    }
  }

  /// An `if` that's part of `a if c else b` in a comprehension's clause, not a filter: an `else` follows it.
  private func isConditionalExpression(_ k: Int, from: Int) -> Bool {
    var depth = 0
    var j = k + 1
    while j < count {
      switch unit.tokens[j].kind {
      case .open: depth += 1
      case .close:
        if depth == 0 { return false }
        depth -= 1
      default:
        if depth == 0 {
          if unit.isToken(j, "else") { return true }
          if unit.isToken(j, "for") || unit.isToken(j, "if") { return false }
        }
      }
      j += 1
    }
    return false
  }

  /// `lambda a, b=d: body`: a scope for its parameters and body. Returns where it ends.
  private mutating func lambda(_ at: Int, limit: Int, scope: Int32) -> Int {
    let inner = Int32(file.scopes.count)
    file.scopes.append(PyScope(kind: .lambda, parent: scope, decl: -1))
    var colon = at + 1
    var depth = 0
    while colon < limit {
      if unit.tokens[colon].kind == .open { depth += 1 } else if unit.tokens[colon].kind == .close { depth -= 1 } else if depth == 0, unit.isByte(colon, 0x3A) { break }
      colon += 1
    }
    for (index, item) in parameterItems(at + 1, colon).enumerated() {
      if item.value.0 >= 0 { expression(Int(item.value.0), Int(item.value.1), scope: scope) }
      file.tokenScope[item.token] = inner
      var binding = PyBinding(name: item.name, token: Int32(item.token), scope: inner, kind: .parameter)
      binding.position = Int32(index)
      binding.valueStart = item.value.0
      binding.valueEnd = item.value.1
      add(binding)
    }
    // The body: to a comma or close outside its own brackets, or the end.
    var end = colon + 1
    depth = 0
    var lambdas = 0
    while end < limit {
      let kind = unit.tokens[end].kind
      if kind == .open || kind == .interpolationOpen {
        depth += 1
      } else if kind == .close || kind == .interpolationClose {
        if depth == 0 { break }
        depth -= 1
      } else if depth == 0 {
        if unit.isByte(end, 0x2C) { break }
        if unit.isToken(end, "lambda") { lambdas += 1 }
        if unit.isByte(end, 0x3A), !unit.isWalrus(end) {
          if lambdas == 0 { break }
          lambdas -= 1
        }
        if unit.isToken(end, "for"), lambdas == 0 { break }
      }
      end += 1
    }
    fill(colon + 1, end, inner)
    expression(colon + 1, end, scope: inner)
    return end
  }
}

extension Unit {
  /// `4.` at a line's end: the lexer leaves the dot to itself, but it's the number's.
  func isNumberDot(_ k: Int) -> Bool {
    k >= 1 && isByte(k, 0x2E) && tokens[k].length == 1 && tokens[k - 1].kind == .number && tokens[k - 1].end == tokens[k].start
      && (k + 1 >= tokens.count || tokens[k + 1].kind != .identifier || tokens[k + 1].start > tokens[k].end)
  }

  /// `:` right before `=`: the walrus `:=`.
  func isWalrus(_ k: Int) -> Bool {
    guard k >= 0, k + 1 < tokens.count, isByte(k, 0x3A), tokens[k].end == tokens[k + 1].start else { return false }
    return tokens[k + 1].kind == .punctuation && source.text[tokens[k + 1].start] == 0x3D && !(tokens[k + 1].length > 1 && source.text[tokens[k + 1].start + 1] == 0x3D)
  }

  /// An operator run that starts with an assignment's `=` (`=-1` lexes as one run), not `==`.
  func startsWithAssign(_ k: Int) -> Bool {
    guard k >= 0, k < tokens.count, tokens[k].kind == .punctuation, tokens[k].length > 1 else { return false }
    let text = source.text + tokens[k].start
    return text[0] == 0x3D && text[1] != 0x3D
  }

  /// `+=`, `//=`, `**=`, `>>=`…, possibly with a unary sign run into it.
  func isAugmented(_ k: Int) -> Bool {
    guard k >= 0, k < tokens.count, tokens[k].kind == .punctuation, tokens[k].length >= 2 else { return false }
    let text = source.text + tokens[k].start
    let length = tokens[k].length
    for op in Self.augmentedOperators where op.count <= length {
      if op.utf8.enumerated().allSatisfy({ text[$0.offset] == $0.element }) {
        // `<=`, `>=`, `!=` and `==` aren't assignments.
        return true
      }
    }
    return false
  }

  private static let augmentedOperators = ["**=", "//=", ">>=", "<<=", "+=", "-=", "*=", "/=", "%=", "@=", "&=", "|=", "^="]

  /// A token of dots only (`.`, `..`, `...`).
  func isAllDots(_ k: Int) -> Bool {
    let token = tokens[k]
    for b in 0..<token.length where source.text[token.start + b] != 0x2E { return false }
    return true
  }

  /// A string token's text without its prefix and quotes.
  func pyStringValue(_ k: Int) -> String {
    var text = string(k)
    while let first = text.first, first != "\"", first != "'" { text.removeFirst() }
    for quote in ["\"\"\"", "'''", "\"", "'"] where text.hasPrefix(quote) && text.hasSuffix(quote) && text.count >= 2 * quote.count {
      return String(text.dropFirst(quote.count).dropLast(quote.count))
    }
    return text
  }
}
