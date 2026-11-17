import CodeModel
import CodeScan
import Foundation

/// A value's type as far as source tells it. Tables are known by where they're made; a table nobody in the program
/// makes (a host's `game`, `vim`, a field never assigned one table) by its path from a global or a known table.
enum LuaType: Hashable {
  case unknown
  /// A table constructor: its unit and `{` token.
  case table(Int32, Int32)
  /// A field's value when no one table is assigned to it: its fields are its own, by the path.
  indirect case path(LuaType, Name)
  /// A global the program never assigns (a host's): its fields by the path.
  case global(Name)
  /// `setmetatable(base, metatable)`: the base's fields, then the metatable's `__index`. `ownedByMetatable`: the
  /// metatable is a class (a name, not a constructor written there), so what's assigned on an instance is the class's.
  indirect case instance(LuaType, LuaType, Bool)
  /// A function value: its unit and index in `LuaFile.functions`.
  case function(Int32, Int32)
  case string, number, boolean
  /// An annotation's class with no table behind it: only its `---@field`s.
  case named(String)
  case union([LuaType])

  var isKnown: Bool { self != .unknown }

  /// The table that owns what's assigned on a value of this type.
  var owner: LuaType? {
    switch self {
    case .table, .path, .global: return self
    case .instance(let base, let metatable, let ownedByMetatable): return ownedByMetatable ? metatable.owner ?? base.owner : base.owner
    case .union(let parts):
      let owners = Set(parts.compactMap(\.owner))
      return owners.count == 1 ? owners.first : nil
    default: return nil
    }
  }

  /// What `setmetatable` takes as its base: an instance's own table.
  var stripped: LuaType {
    if case .instance(let base, _, _) = self { return base.stripped }
    return self
  }

  static func union(of types: [LuaType]) -> LuaType {
    var parts: [LuaType] = []
    for type in types {
      if case .union(let inner) = type {
        for part in inner where !parts.contains(part) { parts.append(part) }
      } else if type.isKnown, !parts.contains(type) {
        parts.append(type)
      }
    }
    if parts.isEmpty { return .unknown }
    return parts.count == 1 ? parts[0] : .union(parts)
  }

  var parts: [LuaType] {
    if case .union(let inner) = self { return inner }
    return isKnown ? [self] : []
  }
}

/// What `---@` annotations above a statement say (LuaLS and EmmyLua's).
struct LuaAnnotations {
  var className: String?
  var parents: [String] = []
  var type: String?
  var parameters: [Name: String] = [:]
  var returns: [String] = []
  var fields: [(name: String, type: String, line: Int)] = []
  var isEmpty: Bool { className == nil && type == nil && parameters.isEmpty && returns.isEmpty && fields.isEmpty }
}

extension LuaModel {
  // MARK: Annotations

  /// The comment lines right above a statement's line: `---@…` annotations, and the description before them.
  func comments(above token: Int32, in unit: Unit) -> [String] {
    guard token >= 0, Int(token) < unit.tokens.count else { return [] }
    var line = unit.source.lines.line(of: unit.tokens[Int(token)].start) - 1
    var lines: [String] = []
    while line >= 0 {
      let text = unit.lineText(line)
      guard text.hasPrefix("--"), !text.hasPrefix("--[") else { break }
      lines.insert(text, at: 0)
      line -= 1
    }
    return lines
  }

  func annotations(_ unitIndex: Int32, _ statement: Int32) -> LuaAnnotations {
    if let known = annotationCache[unitIndex]?[statement] { return known }
    let found = Self.parseAnnotations(comments(above: statement, in: project.units[Int(unitIndex)]))
    annotationCache[unitIndex, default: [:]][statement] = found
    return found
  }

  static func parseAnnotations(_ lines: [String]) -> LuaAnnotations {
    var found = LuaAnnotations()
    for line in lines {
      guard line.hasPrefix("---@") else { continue }
      let body = line.dropFirst(4)
      let tag = body.prefix { $0.isLetter }
      let rest = body.dropFirst(tag.count).trimmingCharacters(in: .whitespaces)
      switch tag {
      case "class":
        let parts = rest.split(separator: ":", maxSplits: 1)
        let head = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        // `---@class (exact) Name`.
        found.className = head.split(separator: " ").last.map(String.init)
        if parts.count > 1 { found.parents = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
      case "type":
        found.type = Self.firstWord(rest)
      case "param":
        let words = rest.split(separator: " ", maxSplits: 1)
        if words.count == 2 { found.parameters[name(String(words[0]).trimmingCharacters(in: CharacterSet(charactersIn: "?")))] = Self.firstWord(String(words[1])) }
      case "return":
        found.returns.append(Self.firstWord(rest))
      case "field":
        var words = rest.split(separator: " ")
        if let first = words.first, ["public", "private", "protected", "package"].contains(String(first)) { words.removeFirst() }
        if words.count >= 2 { found.fields.append((String(words[0]).trimmingCharacters(in: CharacterSet(charactersIn: "?")), String(words[1]), 0)) }
      default:
        break
      }
    }
    return found
  }

  /// A type written in an annotation, up to its description: `Foo`, `Foo|nil`, `Foo?`, `fun(a: T): R`.
  static func firstWord(_ text: String) -> String {
    var depth = 0
    var result = ""
    for c in text {
      if c == "(" || c == "<" || c == "{" || c == "[" { depth += 1 }
      if c == ")" || c == ">" || c == "}" || c == "]" { depth -= 1 }
      if depth == 0, c == " " || c == "#" { break }
      result.append(c)
    }
    return result
  }

  /// An annotation's type: a class's table, `string`, a union of them; unknown for what has no members to find.
  func annotatedType(_ text: String) -> LuaType {
    var parts: [LuaType] = []
    for raw in text.split(separator: "|") {
      var part = raw.trimmingCharacters(in: .whitespaces)
      while part.hasSuffix("?") { part.removeLast() }
      if part.hasSuffix("[]") || part.hasPrefix("fun(") || part.contains("<") || part.hasPrefix("{") || part.hasPrefix("\"") || part.hasPrefix("'") { continue }
      switch part {
      case "string": parts.append(.string)
      case "number", "integer": parts.append(.number)
      case "boolean": parts.append(.boolean)
      case "", "nil", "any", "table", "function", "userdata", "thread", "unknown", "lightuserdata", "self": continue
      default:
        indexClasses()
        if let known = classes[part] {
          parts.append(classType(known))
        } else {
          parts.append(.named(part))
        }
      }
    }
    return LuaType.union(of: parts)
  }

  /// Every `---@class` in the program read so far: its name to the statement it's written above.
  func indexClasses() {
    while classesIndexed < project.units.count {
      let unitIndex = Int32(classesIndexed)
      classesIndexed += 1
      indexClasses(of: unitIndex)
    }
  }

  func indexClasses(of unitIndex: Int32) {
    let unit = project.units[Int(unitIndex)]
    guard let file = luaFile(unitIndex) else { return }
    let sourceTokens = unit.source.tokens
    var found: [LuaClass] = []
    for (position, token) in sourceTokens.enumerated() where (token.kind == .comment || token.kind == .docComment) && token.length > 10 {
      guard unit.source.string(token).hasPrefix("---@class") else { continue }
      // The comment lines from here to the next class or the code: a class with no statement right below it is
      // its `---@field`s alone.
      let first = unit.source.lines.line(of: token.start)
      var line = first
      var lines: [String] = []
      while lines.count < 400 {
        let text = unit.lineText(line)
        guard text.hasPrefix("--"), !text.hasPrefix("--["), lines.isEmpty || !text.hasPrefix("---@class") else { break }
        lines.append(text)
        line += 1
      }
      let parsed = Self.parseAnnotations(lines)
      guard let className = parsed.className else { continue }
      var next = position + 1
      while next < sourceTokens.count, sourceTokens[next].kind == .comment || sourceTokens[next].kind == .docComment { next += 1 }
      var statement: Int32 = -1
      if next < sourceTokens.count, unit.source.lines.line(of: sourceTokens[next].start) == line, let at = unit.token(at: sourceTokens[next].start),
        file.statementTargets[Int32(at)] != nil
      {
        statement = Int32(at)
      }
      found.append(
        LuaClass(
          name: className, unit: unitIndex, line: first, statement: statement, target: statement >= 0 ? file.statementTargets[statement] : nil,
          parents: parsed.parents, fields: parsed.fields))
    }
    guard !found.isEmpty else { return }
    classOwners = nil
    var names: [String] = []
    for known in found {
      if !names.contains(known.name) { names.append(known.name) }
      // After the earlier files' classes of that name, before the later files'.
      var list = classDefinitions[known.name] ?? []
      var at = list.count
      while at > 0, list[at - 1].unit > unitIndex { at -= 1 }
      list.insert(known, at: at)
      classDefinitions[known.name] = list
      classes[known.name] = list[0]
    }
    indexedClasses[unitIndex] = names
  }

  func unindexClasses(_ unitIndex: Int32) {
    guard let names = indexedClasses.removeValue(forKey: unitIndex) else { return }
    classOwners = nil
    for name in names {
      classDefinitions[name]?.removeAll { $0.unit == unitIndex }
      classes[name] = classDefinitions[name]?.first
      if classDefinitions[name]?.isEmpty == true { classDefinitions[name] = nil }
    }
  }

  /// The type a class's statement gives the name it declares.
  func classType(_ known: LuaClass) -> LuaType {
    guard let target = known.target else { return .named(known.name) }
    let type: LuaType
    if target >= 0 {
      type = localType(known.unit, target)
    } else {
      type = declValueType(DeclRef(unit: known.unit, decl: -1 - target))
    }
    return type.isKnown ? type : .named(known.name)
  }

  /// The class names a type's owner was declared as, for parents and `---@field`s.
  func classNames(of type: LuaType) -> [String] {
    indexClasses()
    if case .named(let className) = type { return [className] }
    guard let owner = type.owner, !buildingClassOwners else { return [] }
    if classOwners == nil {
      buildingClassOwners = true
      defer { buildingClassOwners = false }
      var map: [LuaType: [String]] = [:]
      for (className, known) in classes {
        if let found = classType(known).owner { map[found, default: []].append(className) }
      }
      classOwners = map.mapValues { $0.sorted() }
    }
    return classOwners?[owner] ?? []
  }

  // MARK: Types of expressions

  func type(_ expr: Int32, _ unitIndex: Int32) -> LuaType {
    guard expr >= 0, let file = luaFile(unitIndex), Int(expr) < file.exprs.count else { return .unknown }
    let key = Int64(unitIndex) << 32 | Int64(expr)
    if let known = exprTypes[key] { return known }
    guard resolving.insert(key).inserted else { return .unknown }
    depth += 1
    defer {
      depth -= 1
      resolving.remove(key)
    }
    guard depth < 60 else { return .unknown }
    let result = computeType(file.expr(expr), file, unitIndex)
    exprTypes[key] = result
    return result
  }

  private func computeType(_ expr: LuaExpr, _ file: LuaFile, _ unitIndex: Int32) -> LuaType {
    let unit = project.units[Int(unitIndex)]
    switch expr {
    case .name(let token):
      switch file.uses[token] {
      case .local(let def): return localType(unitIndex, def)
      case .selfParameter(let function): return selfType(unitIndex, function)
      case .global: return globalType(unit.hash(Int(token)))
      default: return .unknown
      }
    case .field(let base, let token):
      return fieldType(type(base, unitIndex), unit.hash(Int(token)))
    case .index(let base, let key):
      guard case .string(let token) = file.expr(key), let text = LuaParser.literal(unit, Int(token)) else { return .unknown }
      return fieldType(type(base, unitIndex), name(text))
    case .call(let callee, let first, let count):
      return callType(callee, first, count, file, unitIndex, valueIndex: 0)
    case .table(let open): return .table(unitIndex, open)
    case .function(let index): return .function(unitIndex, index)
    case .string: return .string
    case .number: return .number
    case .or(let left, let right): return LuaType.union(of: [type(left, unitIndex), type(right, unitIndex)])
    case .and(_, let right): return type(right, unitIndex)
    case .paren(let inner): return type(inner, unitIndex)
    case .literal, .vararg, .other: return .unknown
    }
  }

  /// A value with which of its values (a call's second…).
  func type(_ expr: Int32, _ unitIndex: Int32, valueIndex: Int32) -> LuaType {
    guard valueIndex > 0 else { return type(expr, unitIndex) }
    guard let file = luaFile(unitIndex), case .call(let callee, let first, let count) = file.expr(expr) else { return .unknown }
    return callType(callee, first, count, file, unitIndex, valueIndex: valueIndex)
  }

  func callType(_ callee: Int32, _ first: Int32, _ count: Int32, _ file: LuaFile, _ unitIndex: Int32, valueIndex: Int32) -> LuaType {
    let unit = project.units[Int(unitIndex)]
    if case .name(let token) = file.expr(callee), case .global = file.uses[token] ?? .local(0) {
      let word = unit.hash(Int(token))
      if word == LuaParser.requireName {
        guard valueIndex == 0, count >= 1, case .string(let stringToken) = file.expr(file.arguments[Int(first)]),
          let target = requiredUnit(unitIndex, stringToken), let targetFile = luaFile(target), targetFile.returned >= 0
        else { return .unknown }
        return type(targetFile.returned, target)
      }
      if word == LuaParser.setmetatableName {
        guard valueIndex == 0, count >= 2 else { return .unknown }
        let base = type(file.arguments[Int(first)], unitIndex).stripped
        let metatableExpr = file.arguments[Int(first) + 1]
        let metatable = type(metatableExpr, unitIndex)
        // An unknown metatable (`getmetatable(x)`) adds nothing to know.
        guard metatable.isKnown else { return base }
        return .instance(base, metatable, !isConstructor(metatableExpr, file))
      }
    }
    var results: [LuaType] = []
    for part in type(callee, unitIndex).parts {
      guard case .function(let functionUnit, let function) = part else { continue }
      results.append(returnType(functionUnit, function, valueIndex: valueIndex))
    }
    return LuaType.union(of: results)
  }

  func isConstructor(_ expr: Int32, _ file: LuaFile) -> Bool {
    if case .table = file.expr(expr) { return true }
    return false
  }

  func returnType(_ unitIndex: Int32, _ function: Int32, valueIndex: Int32) -> LuaType {
    guard let file = luaFile(unitIndex), Int(function) < file.functions.count else { return .unknown }
    let body = file.functions[Int(function)]
    let notes = annotations(unitIndex, body.statement)
    if !notes.returns.isEmpty {
      guard Int(valueIndex) < notes.returns.count else { return .unknown }
      return annotatedType(notes.returns[Int(valueIndex)])
    }
    guard valueIndex == 0 else { return .unknown }
    // A map or copy the function fills (`t[k] = v`) is a new table each call, not one to find fields on.
    return LuaType.union(of: body.returns.filter { !isFilledMap($0, file, unitIndex) }.map { type($0, unitIndex) })
  }

  private func isFilledMap(_ expr: Int32, _ file: LuaFile, _ unitIndex: Int32) -> Bool {
    switch file.expr(expr) {
    case .name(let token):
      guard case .local(let def) = file.uses[token] ?? .global else { return false }
      return file.computedKeys.contains(def)
    case .paren(let inner):
      return isFilledMap(inner, file, unitIndex)
    case .call(let callee, let first, let count):
      // `setmetatable(t, mt)`.
      guard count >= 1, case .name(let token) = file.expr(callee), case .global = file.uses[token] ?? .local(0),
        project.units[Int(unitIndex)].hash(Int(token)) == LuaParser.setmetatableName
      else { return false }
      return isFilledMap(file.arguments[Int(first)], file, unitIndex)
    default:
      return false
    }
  }

  /// A local's type: its annotation, else what it's declared with and assigned, behind its `setmetatable`s.
  func localType(_ unitIndex: Int32, _ def: Int32) -> LuaType {
    let key = Int64(unitIndex) << 32 | Int64(def)
    if let known = localTypes[key] { return known }
    guard resolvingLocals.insert(key).inserted, let file = luaFile(unitIndex), let local = file.locals[def] else { return .unknown }
    defer { resolvingLocals.remove(key) }
    let result = computeLocalType(unitIndex, def, local, file)
    localTypes[key] = result
    return result
  }

  private func computeLocalType(_ unitIndex: Int32, _ def: Int32, _ local: LuaLocal, _ file: LuaFile) -> LuaType {
    let unit = project.units[Int(unitIndex)]
    switch local.kind {
    case .parameter:
      let body = file.functions[Int(local.function)]
      let notes = annotations(unitIndex, body.statement)
      if let written = notes.parameters[unit.hash(Int(def))] {
        let found = annotatedType(written)
        if found.isKnown { return found }
      }
      // `function T.m(self)` and `T.m = function(self)`: self is T.
      if local.position == 0, unit.hash(Int(def)) == LuaParser.selfName, body.owner >= 0 { return type(body.owner, unitIndex) }
      return .unknown
    case .forVariable, .label:
      return .unknown
    case .local, .function:
      // What it's assigned; an annotation (`---@type`) only for a value that can't be told, so that what's
      // assigned on a table goes with the table.
      var values: [LuaType] = []
      if local.value >= 0 { values.append(type(local.value, unitIndex, valueIndex: local.valueIndex)) }
      for item in file.assignments[def] ?? [] where item.value >= 0 { values.append(type(item.value, unitIndex, valueIndex: item.index)) }
      var value = LuaType.union(of: values)
      if !value.isKnown, local.statement >= 0, file.statementTargets[local.statement] == def, let written = annotations(unitIndex, local.statement).type {
        value = annotatedType(written)
      }
      if let metatables = file.metatables[def], let last = metatables.last, case let metatable = type(last, unitIndex), metatable.isKnown {
        return .instance(value.stripped, metatable, !isConstructor(last, file))
      }
      return value
    }
  }

  func selfType(_ unitIndex: Int32, _ function: Int32) -> LuaType {
    guard let file = luaFile(unitIndex), Int(function) < file.functions.count else { return .unknown }
    let owner = file.functions[Int(function)].owner
    return owner >= 0 ? type(owner, unitIndex) : .unknown
  }

  /// A global's type: the program's assignments (the project's first, then the stub's), behind `setmetatable`.
  func globalType(_ word: Name) -> LuaType {
    if let known = globalTypes[word] { return known }
    guard resolvingGlobals.insert(word).inserted else { return .unknown }
    defer { resolvingGlobals.remove(word) }
    let sites = globalSites(word)
    var result: LuaType
    if sites.isEmpty {
      result = .global(word)
    } else {
      result = LuaType.union(of: sites.map(declValueType))
      // Assigned, but never a value that can be told: its fields by the path.
      if !result.isKnown { result = .global(word) }
      for site in sites {
        guard let file = luaFile(site.unit), let metatables = file.globalMetatables[word], let last = metatables.last,
          case let metatable = type(last, site.unit), metatable.isKnown
        else { continue }
        result = .instance(result.stripped, metatable, !isConstructor(last, file))
        break
      }
    }
    globalTypes[word] = result
    return result
  }

  /// What a declaration assigns: its annotation's type, else its value's.
  func declValueType(_ ref: DeclRef) -> LuaType {
    guard let file = luaFile(ref.unit), Int(ref.decl) < file.fields.count else { return .unknown }
    let field = file.fields[Int(ref.decl)]
    let value = field.value < 0 ? LuaType.unknown : type(field.value, ref.unit, valueIndex: field.valueIndex)
    if !value.isKnown, file.statementTargets[field.statement] == -1 - ref.decl, let written = annotations(ref.unit, field.statement).type {
      return annotatedType(written)
    }
    return value
  }

  // MARK: Fields

  /// The places a field of a value is assigned: its own table's, the metatable's class's, then along `__index`; a
  /// string's from the `string` table; an annotated class's parents' last.
  func fieldSites(_ type: LuaType, _ key: Name, depth: Int = 0) -> [DeclRef] {
    guard depth < 8 else { return [] }
    switch type {
    case .table, .path, .global:
      var found = writes(on: type, key)
      if case .path(let parent, let parentKey) = type {
        // The tables assigned to that field, where several are.
        for part in fieldValues(parent, parentKey) where part.owner != nil && part.owner != type {
          found += fieldSites(part, key, depth: depth + 1)
        }
      }
      if found.isEmpty { found = inheritedSites(type, key, depth: depth) }
      return found
    case .instance(let base, let metatable, let ownedByMetatable):
      var found = fieldSites(base, key, depth: depth + 1)
      if found.isEmpty, ownedByMetatable, let owner = metatable.owner { found = writes(on: owner, key) }
      if found.isEmpty {
        for index in fieldValues(metatable, LuaModel.indexName) where index.owner != nil {
          found += fieldSites(index, key, depth: depth + 1)
        }
      }
      return found
    case .union(let parts):
      var found: [DeclRef] = []
      for part in parts {
        for site in fieldSites(part, key, depth: depth + 1) where !found.contains(site) { found.append(site) }
      }
      return found
    case .string:
      return fieldSites(globalType(LuaModel.stringName), key, depth: depth + 1)
    case .named:
      return inheritedSites(type, key, depth: depth)
    default:
      return []
    }
  }

  /// A field from an annotated class's parents (`---@class Dog : Animal`).
  private func inheritedSites(_ type: LuaType, _ key: Name, depth: Int) -> [DeclRef] {
    for className in classNames(of: type) {
      for parent in classes[className]?.parents ?? [] {
        let parentType = annotatedType(parent)
        guard parentType.isKnown, parentType != type else { continue }
        let found = fieldSites(parentType, key, depth: depth + 1)
        if !found.isEmpty { return found }
      }
    }
    return []
  }

  /// The values assigned to a field, as types.
  func fieldValues(_ type: LuaType, _ key: Name) -> [LuaType] {
    LuaType.union(of: fieldSites(type, key).map(declValueType)).parts
  }

  /// A field's type: one value assigned to it, else the path (its fields its own), or a `---@field`'s type.
  func fieldType(_ base: LuaType, _ key: Name) -> LuaType {
    guard base.isKnown else { return .unknown }
    if case .union(let parts) = base { return LuaType.union(of: parts.map { fieldType($0, key) }) }
    let sites = fieldSites(base, key)
    let values = LuaType.union(of: sites.map(declValueType)).parts
    if values.count == 1 { return values[0] }
    if sites.isEmpty {
      for className in classNames(of: base) {
        if let field = classes[className]?.fields.first(where: { name($0.name) == key }) {
          let found = annotatedType(field.type)
          if found.isKnown { return found }
        }
      }
      if base == .string || base == .number || base == .boolean { return .unknown }
    }
    guard let owner = base.owner else { return .unknown }
    return .path(owner, key)
  }
}

/// A `---@class`: the statement it's written above and what it says.
struct LuaClass {
  var name: String
  var unit: Int32
  /// The `---@class` line, from 0.
  var line: Int
  /// The statement right below its comment, -1 for none.
  var statement: Int32
  /// What the statement declares: a local's token, or -1 - a declaration's index.
  var target: Int32?
  var parents: [String]
  var fields: [(name: String, type: String, line: Int)]
}
