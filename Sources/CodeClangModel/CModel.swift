import CodeModel
import CodeScan
import Foundation

/// The model of a C, C++ or Objective-C project: definitions, references, completion and details from source, on
/// CodeModel's core, answered the way clangd answers them. Each file is a translation unit's start: what it sees is
/// what its `#include`s reach (`closure`), a name resolves through locals, the class or container around it, its
/// namespaces and then the file scope of that closure, and the place an answer gives is clangd's: a use goes to the
/// entity's definition (in any file of the project) or else its first declaration in the unit, and a definition goes
/// to that first declaration.
public final class CModel: LanguageModel {
  public let project: Project
  let layout: CLayout
  /// A unit's includes, transitively, in the order a translation unit reads them: each header before its includer.
  var closures: [Int32: [Int32]] = [:]
  var closureSets: [Int32: Set<Int32>] = [:]
  /// Every loaded declaration that can be redeclared, by its entity (`entityKey`).
  var entities: [UInt64: [DeclRef]] = [:]
  var entityOf: [DeclRef: UInt64] = [:]
  var indexedUnits = 0
  /// Declarations in a named scope (a namespace or class, by its key), from every loaded unit.
  var scoped: [UInt64: [DeclRef]] = [:]
  /// Macros' `#define`s by name over the project's files, for a header read without its includer.
  var projectMacros: [Name: [DeclRef]]?
  var valueTypes: [DeclRef: Ty] = [:]
  var resolving: Set<DeclRef> = []
  var depth = 0
  /// Set by an answer that is only the project's members of the name, as the receiver's type couldn't be told.
  var byNameOnly = false

  public init(project: Project) {
    self.project = project
    layout = project.layout as! CLayout
    project.onShapeChange = { [weak self] in self?.reset() }
  }

  /// A C, C++ or Objective-C project under `root`: its files, its compile commands when it has them, the SDK.
  public convenience init(root: String) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    self.init(project: Project(root: root, layout: CLayout(root: root)))
  }

  func reset() {
    closures.removeAll()
    closureSets.removeAll()
    entities.removeAll()
    entityOf.removeAll()
    scoped.removeAll()
    indexedUnits = 0
    projectMacros = nil
    valueTypes.removeAll()
  }

  func unit(_ ref: DeclRef) -> Unit { project.units[Int(ref.unit)] }
  func decl(_ ref: DeclRef) -> Decl { project.units[Int(ref.unit)].decls[Int(ref.decl)] }
  func file(_ ref: DeclRef) -> CFile { unit(ref).cFile }
  func file(_ unitIndex: Int32) -> CFile { project.units[Int(unitIndex)].cFile }

  // MARK: Includes

  /// The units a translation unit starting at `unitIndex` reads, headers first (each once, as include guards make it).
  func closure(_ unitIndex: Int32) -> [Int32] {
    if let known = closures[unitIndex] { return known }
    var order: [Int32] = []
    var seen: Set<Int32> = []
    var stack: [(unit: Int32, next: Int)] = [(unitIndex, 0)]
    seen.insert(unitIndex)
    while !stack.isEmpty {
      let (current, next) = stack[stack.count - 1]
      let imports = project.units[Int(current)].imports
      if next < imports.count {
        stack[stack.count - 1].next += 1
        let item = imports[next]
        guard let module = project.ensureModule(item.module, display: item.moduleName), let first = module.units.first else { continue }
        if seen.insert(first).inserted { stack.append((first, 0)) }
        continue
      }
      order.append(current)
      stack.removeLast()
    }
    closures[unitIndex] = order
    closureSets[unitIndex] = Set(order)
    return order
  }

  func sees(_ unitIndex: Int32, _ other: Int32) -> Bool {
    if closureSets[unitIndex] == nil { _ = closure(unitIndex) }
    return closureSets[unitIndex]?.contains(other) == true
  }

  // MARK: Entities

  static func mix(_ a: UInt64, _ b: UInt64) -> UInt64 { (a ^ b) &* 1_099_511_628_211 &+ 0x9E37_79B9 }

  /// The scope a declaration is in, as a key: its namespaces, classes and (for an out-of-line definition) what its
  /// qualifier names, outermost first; 0 at file scope, nil inside a function.
  func scopeKey(_ unit: Unit, _ index: Int32) -> UInt64? {
    var names: [Name] = []
    var p = unit.decls[Int(index)].parent
    let file = unit.cFile
    if unit.decls[Int(index)].kind == .enumCase, p >= 0, !file.has(p, .scoped) { p = unit.decls[Int(p)].parent }
    while p >= 0 {
      let holder = unit.decls[Int(p)]
      switch holder.kind {
      case .namespace:
        if holder.name != 0, !file.has(p, .inline) { names.append(holder.name) }
      case .extensionDecl:
        if file.has(p, .implementation) || holder.typeStart < 0 {
          names.append(holder.name)
        } else {
          for word in qualifierWords(unit, Int(holder.typeStart), Int(holder.typeEnd)).reversed() { names.append(word) }
        }
      case .structure, .classType, .enumeration, .protocolType:
        if holder.name != 0 {
          names.append(holder.name)
        } else if holder.kind != .enumeration || file.has(p, .scoped) {
          // An anonymous struct's members are its own: two `typedef struct { int n; } a, b;` don't share `n`.
          names.append(CModel.mix(UInt64(bitPattern: Int64(unit.path.hashValue)), UInt64(p) &+ 0x5A17))
        }
      default:
        return nil
      }
      p = holder.parent
    }
    var key: UInt64 = 0
    for word in names.reversed() { key = CModel.mix(key, word) }
    return key
  }

  /// `ns::A<T>::` → [ns, A].
  func qualifierWords(_ unit: Unit, _ start: Int, _ end: Int) -> [Name] {
    var words: [Name] = []
    var i = start
    while i < end {
      if unit.startsWith(i, 0x3C) {
        var depth = 0
        while i < end {
          if unit.startsWith(i, 0x3C) { depth += 1 }
          if unit.tokens[i].kind == .punctuation, unit.source.text[unit.tokens[i].end - 1] == 0x3E { depth -= 1 }
          i += 1
          if depth <= 0 { break }
        }
        continue
      }
      if unit.tokens[i].kind == .identifier { words.append(unit.hash(i)) }
      i += 1
    }
    return words
  }

  enum Family: UInt64 { case value = 1, type, alias, constant, namespace, objcClass, method, protocolType }

  func family(_ unit: Unit, _ index: Int32) -> Family? {
    let decl = unit.decls[Int(index)]
    let file = unit.cFile
    switch decl.kind {
    case .function, .initializer, .deinitializer:
      if decl.parent >= 0, isObjCContainer(unit, decl.parent) { return .method }
      return .value
    case .variable: return .value
    case .structure, .enumeration: return .type
    case .classType:
      return decl.parent < 0 && isObjC(unit, index) ? .objcClass : .type
    case .extensionDecl: return file.has(index, .implementation) ? .objcClass : nil
    case .typeAlias: return .alias
    case .enumCase: return .constant
    case .namespace: return file.has(index, .alias) ? .alias : .namespace
    case .protocolType: return .protocolType
    default: return nil
    }
  }

  func isObjC(_ unit: Unit, _ index: Int32) -> Bool {
    let first = Int(unit.decls[Int(index)].first)
    return first >= 0 && first < unit.tokens.count && unit.tokens[first].kind == .attribute
  }

  func isObjCContainer(_ unit: Unit, _ index: Int32) -> Bool {
    let decl = unit.decls[Int(index)]
    return (decl.kind == .classType || decl.kind == .extensionDecl || decl.kind == .protocolType) && isObjC(unit, index)
  }

  /// What makes two declarations the same entity: scope, name, family, the file for internal linkage, and for C++
  /// functions the parameter count (overloads apart).
  func entityKey(_ ref: DeclRef) -> UInt64? {
    if let known = entityOf[ref] { return known }
    let holder = unit(ref)
    let item = decl(ref)
    guard item.name != 0, !item.isLocal, let family = family(holder, ref.decl) else { return nil }
    var scope: UInt64
    if family == .method || family == .objcClass {
      // A method of a class, its categories and its @implementation; a class and its @implementation.
      scope = family == .method ? CModel.mix(holder.decls[Int(item.parent)].name, item.isStatic ? 2 : 1) : 0
    } else {
      guard let key = scopeKey(holder, ref.decl) else { return nil }
      scope = key
    }
    var key = CModel.mix(CModel.mix(scope, item.name), family.rawValue)
    let file = holder.cFile
    if family == .value, item.parent < 0, item.isStatic || isInAnonymousNamespace(holder, ref.decl) { key = CModel.mix(key, UInt64(ref.unit) &+ 77) }
    if family == .value, item.parent >= 0, isInAnonymousNamespace(holder, ref.decl) { key = CModel.mix(key, UInt64(ref.unit) &+ 77) }
    if family == .value, item.kind != .variable, item.kind != .typeAlias, file.dialect.contains(.cpp), item.paramCount > 0 || item.kind == .function {
      key = CModel.mix(key, UInt64(item.paramCount) &+ 1000)
    }
    return key
  }

  func isInAnonymousNamespace(_ unit: Unit, _ index: Int32) -> Bool {
    var p = unit.decls[Int(index)].parent
    while p >= 0 {
      if unit.decls[Int(p)].kind == .namespace, unit.decls[Int(p)].name == 0 { return true }
      p = unit.decls[Int(p)].parent
    }
    return false
  }

  /// Indexes the units loaded since last asked.
  func indexEntities() {
    let count = project.units.count
    guard indexedUnits < count else { return }
    for u in indexedUnits..<count {
      let holder = project.units[u]
      for index in holder.decls.indices where !holder.decls[index].isLocal {
        let ref = DeclRef(unit: Int32(u), decl: Int32(index))
        if let key = entityKey(ref) {
          entityOf[ref] = key
          entities[key, default: []].append(ref)
        }
        if holder.decls[index].name != 0, holder.decls[index].kind != .extensionDecl, holder.decls[index].kind != .macro,
          let scope = scopeKey(holder, Int32(index)), scope != 0
        {
          scoped[scope, default: []].append(ref)
        }
      }
    }
    indexedUnits = count
  }

  func redeclarations(_ ref: DeclRef) -> [DeclRef] {
    indexEntities()
    guard let key = entityOf[ref] ?? entityKey(ref) else { return [ref] }
    return entities[key] ?? [ref]
  }

  func isDefinition(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    let holder = unit(ref)
    switch item.kind {
    case .function, .initializer, .deinitializer: return item.bodyOpen >= 0
    case .variable:
      if holder.cFile.has(ref.decl, .extern), item.initStart < 0 { return false }
      // A class's static member is declared in the class, defined outside it.
      if item.isStatic, item.parent >= 0, holder.decls[Int(item.parent)].kind.isNominal, item.initStart < 0 { return false }
      return true
    case .structure, .classType, .enumeration:
      if isObjC(holder, ref.decl) { return false }
      return item.bodyOpen >= 0
    case .extensionDecl: return holder.cFile.has(ref.decl, .implementation)
    case .enumCase, .typeAlias: return true
    default: return false
    }
  }

  /// Where clangd goes from a declaration of an entity seen from a unit: the definition (an @implementation for an
  /// Objective-C class), else the first declaration in the unit's closure; from the definition itself, that first
  /// declaration. Several definitions none of the unit sees: all of them.
  func target(of found: DeclRef, from unitIndex: Int32, at token: Int? = nil) -> [Site] {
    if guessing, let token, isDefinition(found), Int(decl(found).nameToken) == token, found.unit == unitIndex { return [.decl(found)] }
    let all = redeclarations(found)
    if all.count == 1 { return [.decl(found)] }
    var definitions = all.filter(isDefinition)
    // A type the SDK and clang's own headers both define (`size_t`): clangd's index keeps one definition per name for
    // the whole project, clang's when some file reads it, whichever file the question is in.
    if definitions.count > 1, decl(found).kind == .typeAlias, !layout.resourceInclude.isEmpty,
      definitions.allSatisfy({ Int($0.unit) >= project.projectUnits }),
      let builtIn = definitions.first(where: { unit($0).path.hasPrefix(layout.resourceInclude + "/") })
    {
      return [.decl(builtIn)]
    }
    if definitions.count > 1 {
      let seen = definitions.filter { sees(unitIndex, $0.unit) || $0.unit == unitIndex }
      if !seen.isEmpty { definitions = seen }
    }
    if definitions.count > 1 {
      // In the project before the SDK.
      let own = definitions.filter { Int($0.unit) < project.projectUnits }
      if !own.isEmpty { definitions = own }
    }
    let canonical = firstDeclaration(all, from: unitIndex)
    if let token, !guessing, definitions.contains(where: { $0.unit == unitIndex && Int(decl($0).nameToken) == token }) {
      return [.decl(canonical ?? found)]
    }
    if !definitions.isEmpty { return definitions.prefix(8).map { .decl($0) } }
    return [.decl(canonical ?? found)]
  }

  /// The first of some declarations a unit reads.
  func firstDeclaration(_ refs: [DeclRef], from unitIndex: Int32) -> DeclRef? {
    let order = closure(unitIndex)
    var best: (position: Int, token: Int32, ref: DeclRef)?
    var positions: [Int32: Int] = [:]
    for (position, u) in order.enumerated() { positions[u] = position }
    for ref in refs {
      guard let position = positions[ref.unit] else { continue }
      let first = decl(ref).first
      if best == nil || position < best!.position || (position == best!.position && first < best!.token) { best = (position, first, ref) }
    }
    if let best { return best.ref }
    // Not read from here: the project's first.
    return refs.min { ($0.unit, decl($0).first) < ($1.unit, decl($1).first) }
  }

  // MARK: Asking

  public func answer(path: String, line: Int, character: Int) -> Answer {
    guard let unitIndex = project.unitByPath[path] else { return Answer(state: .unknown, sites: []) }
    var unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    // In code the build leaves out, clangd has no declarations: a macro's name, else its guess from the nearest same
    // word in the code. Only when it has neither is the left-out branch read as if it were taken.
    project.focus(unitIndex: unitIndex, offset: 0)
    unit = project.units[Int(unitIndex)]
    guard isLeftOut(unit, offset) else {
      guard let token = unit.token(at: offset) else { return Answer(state: .unknown, sites: []) }
      return answer(unitIndex: unitIndex, token: token)
    }
    if let token = unit.token(at: offset), unit.tokens[token].kind == .identifier, directive(containing: token, in: unit) == nil {
      byNameOnly = false
      if let macro = macro(named: unit.hash(token), unitIndex: unitIndex, token: token, needsCall: true) { return Answer(summarizing: [.decl(macro)]) }
      if let nearby = nearbyWord(unitIndex: unitIndex, token: token, nearestOnly: true) {
        guessing = true
        let found = sites(unitIndex: unitIndex, token: nearby)
        guessing = false
        if !found.isEmpty { return byNameOnly ? Answer(state: .candidates, sites: found, byNameOnly: true) : Answer(summarizing: found) }
      }
      // Else clangd searches its index by name: a guess, and none when that finds three or more.
      let found = textual(unit.hash(token), unitIndex: unitIndex)
      return found.isEmpty ? Answer(state: .unknown, sites: []) : Answer(state: .candidates, sites: found, byNameOnly: true)
    }
    project.focus(unitIndex: unitIndex, offset: offset)
    unit = project.units[Int(unitIndex)]
    guard let token = unit.token(at: offset) else { return Answer(state: .unknown, sites: []) }
    return answer(unitIndex: unitIndex, token: token)
  }

  /// Answering a word near the one asked about (`nearbyWord`).
  var guessing = false

  func answer(unitIndex: Int32, token: Int) -> Answer {
    byNameOnly = false
    let found = sites(unitIndex: unitIndex, token: token)
    if found.isEmpty { return Answer(state: .unknown, sites: []) }
    if byNameOnly {
      byNameOnly = false
      return Answer(state: .candidates, sites: found, byNameOnly: true)
    }
    return Answer(summarizing: found)
  }

  static let stdWord = name("std"), libcxxBeginStd = name("_LIBCPP_BEGIN_NAMESPACE_STD")

  static let unanswered: Set<Name> = Set(
    ["this", "self", "super", "true", "false", "nullptr", "NULL", "nil", "Nil", "YES", "NO", "id", "instancetype", "SEL", "Class", "BOOL", "_cmd"].map { name($0) })

  func sites(unitIndex: Int32, token: Int) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    let kind = unit.tokens[token].kind
    guard kind == .identifier || (kind == .keyword && isDeclaredKeyword(unit, token)) else { return [] }
    let word = unit.hash(token)
    let file = unit.cFile
    // The preprocessor's lines.
    if let directive = directive(containing: token, in: unit) {
      return directiveSites(unitIndex: unitIndex, token: token, directive: directive)
    }
    if let site = unit.declaredSite(at: token, unitIndex: unitIndex) {
      if case .decl(let ref) = site {
        if decl(ref).kind == .macro { return [site] }
        return target(of: ref, from: unitIndex, at: token)
      }
      return [site]
    }
    if file.pointerParameters.contains(Int32(token)) { return [.local(unit: unitIndex, token: Int32(token))] }
    if let method = selectorOwner(unit, token) { return target(of: DeclRef(unit: unitIndex, decl: method), from: unitIndex, at: Int(unit.decls[Int(method)].nameToken)) }
    if CModel.unanswered.contains(word), unit.tokens[token].kind == .identifier, !isDeclaredAnywhere(word, unitIndex) { return [] }
    // A macro's use: the preprocessor's before anything else.
    if let macro = macro(named: word, unitIndex: unitIndex, token: token, needsCall: true) { return [.decl(macro)] }
    // `x.y`, `x->y`, `A::y`, `[x y:…]`.
    if token > 0, unit.isByte(token - 1, 0x2E) || unit.isToken(token - 1, "->") {
      let found = memberAccess(unitIndex: unitIndex, token: token)
      return found
    }
    if token > 0, unit.isToken(token - 1, "::") {
      return qualified(unitIndex: unitIndex, token: token)
    }
    if let body = body(unitIndex: unitIndex, token: Int32(token)), let local = body.local(named: word, at: Int32(token)) {
      if local.decl >= 0 { return [.decl(DeclRef(unit: unitIndex, decl: local.decl))] }
      return [.local(unit: unitIndex, token: local.token)]
    }
    if unit.isByte(token + 1, 0x3A), !unit.isToken(token + 1, "::"), let body = body(unitIndex: unitIndex, token: Int32(token)), body.labels[word] == Int32(token) {
      return [.local(unit: unitIndex, token: Int32(token))]
    }
    if token > 0, unit.isToken(token - 1, "goto") || (unit.isToken(token - 1, "&&") && unit.touchesNext(token - 1)) {
      if let body = body(unitIndex: unitIndex, token: Int32(token)), let label = body.labels[word] { return [.local(unit: unitIndex, token: label)] }
      return []
    }
    if let message = messageSelector(unit, token) {
      return messageSites(unitIndex: unitIndex, token: token, message: message)
    }
    // `.field = 1` in a designated initializer: the field of the initializer's type.
    if token > 0, unit.isByte(token - 1, 0x2E) { return [] }
    let isTag = token > 0 && (unit.isToken(token - 1, "struct") || unit.isToken(token - 1, "union") || unit.isToken(token - 1, "enum"))
      || (token > 0 && unit.isToken(token - 1, "class") && file.dialect.contains(.cpp))
    // libc++ opens `std` with a macro first: clangd's first declaration of it is that macro's line.
    if word == CModel.stdWord, file.dialect.contains(.cpp), let begin = macro(named: CModel.libcxxBeginStd, unitIndex: unitIndex, token: unit.tokens.count, needsCall: false) {
      // `namespace … std {` in the macro it expands.
      let holder = self.unit(begin)
      let item = decl(begin)
      if item.initStart >= 0 {
        for t in Int(item.initStart)..<Int(item.initEnd) where holder.tokens[t].kind == .identifier && holder.hash(t) != CModel.libcxxBeginStd {
          if let inner = macro(named: holder.hash(t), unitIndex: begin.unit, token: holder.tokens.count, needsCall: false), self.decl(inner).initStart >= 0 {
            let innerUnit = self.unit(inner)
            for k in Int(self.decl(inner).initStart)..<Int(self.decl(inner).initEnd) where innerUnit.hash(k) == CModel.stdWord && innerUnit.isToken(k - 1, "_LIBCPP_NAMESPACE_VISIBILITY") || (innerUnit.hash(k) == CModel.stdWord && innerUnit.isByte(k + 1, 0x7B)) {
              return [.local(unit: inner.unit, token: Int32(k))]
            }
          }
        }
      }
      return [.decl(begin)]
    }
    var found = lookup(word, unitIndex: unitIndex, token: token, tag: isTag)
    if found.isEmpty, isTag { found = lookup(word, unitIndex: unitIndex, token: token, tag: false) }
    // `name::`: a namespace, class or alias.
    if unit.isToken(token + 1, "::"), !found.isEmpty {
      let scopes = found.filter { guard $0.decl >= 0 else { return true }; let kind = decl($0).kind; return kind == .namespace || kind.isNominal || kind == .typeAlias || kind == .extensionDecl }
      if scopes.isEmpty { found = scopeLookup(word, unitIndex: unitIndex) } else { found = scopes }
      if found.isEmpty { return [] }
    }
    if found.isEmpty { return fallback(word, unitIndex: unitIndex) }
    return resolveFound(found, unitIndex: unitIndex, token: token)
  }

  /// `int`, `bool` and other keywords are no declaration; a few keywords in the lexer's lists are names in some dialects.
  func isDeclaredKeyword(_ unit: Unit, _ token: Int) -> Bool {
    // Words the C family lexer counts as keywords that headers declare (Objective-C's `in`/`out` as qualifiers aside).
    false
  }

  func isDeclaredAnywhere(_ word: Name, _ unitIndex: Int32) -> Bool {
    for u in closure(unitIndex) where project.units[Int(u)].cFile.ordinary[word] != nil || project.units[Int(u)].cFile.macroEvents[word] != nil { return true }
    return false
  }

  /// Found declarations, as places: each entity's target; C++ overloads narrowed by the call's argument count.
  func resolveFound(_ found: [DeclRef], unitIndex: Int32, token: Int) -> [Site] {
    var refs = found
    let unit = project.units[Int(unitIndex)]
    if refs.count > 1, refs.allSatisfy({ $0.decl >= 0 && (decl($0).kind == .function || decl($0).kind == .initializer) }), unit.isByte(token + 1, 0x28) {
      let arguments = argumentCount(unit, open: token + 1)
      let fitting = refs.filter { accepts($0, arguments) }
      if !fitting.isEmpty { refs = fitting }
    }
    var keys: [UInt64] = []
    var result: [Site] = []
    for ref in refs {
      if ref.decl < 0 {
        // A template parameter.
        let site = Site.generic(unit: ref.unit, token: project.units[Int(ref.unit)].generics[Int(-1 - ref.decl)].token)
        if !result.contains(site) { result.append(site) }
        continue
      }
      let key = entityOf[ref] ?? entityKey(ref) ?? UInt64(ref.unit) << 32 | UInt64(UInt32(bitPattern: ref.decl))
      if keys.contains(key) { continue }
      keys.append(key)
      for site in target(of: ref, from: unitIndex) where !result.contains(site) { result.append(site) }
    }
    return result
  }

  func argumentCount(_ unit: Unit, open: Int) -> Int {
    guard unit.isByte(open, 0x28) else { return -1 }
    let close = unit.skipBalanced(open) - 1
    if close <= open + 1 { return 0 }
    var count = 1
    var i = open + 1
    while i < close {
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.isByte(i, 0x2C) { count += 1 }
      i += 1
    }
    return count
  }

  func accepts(_ ref: DeclRef, _ arguments: Int) -> Bool {
    guard arguments >= 0 else { return true }
    let holder = unit(ref)
    let item = decl(ref)
    var required = 0
    var variadic = false
    for p in 0..<Int(item.paramCount) {
      let param = holder.params[Int(item.paramStart) + p]
      if param.variadic { variadic = true } else if !param.hasDefault { required += 1 }
    }
    return arguments >= required && (variadic || arguments <= Int(item.paramCount))
  }

  /// A name no scope finds: the project's declarations of it, as clangd's search by name does where the code isn't
  /// parsed (a header read without what its includer includes, a branch `#if` leaves out).
  func fallback(_ word: Name, unitIndex: Int32) -> [Site] {
    indexEntities()
    var found: [DeclRef] = []
    for u in 0..<project.projectUnits {
      let holder = project.units[u]
      for index in holder.cFile.ordinary[word] ?? [] {
        // A struct's field is never a name on its own.
        let parent = holder.decls[Int(index)].parent
        if parent >= 0, holder.decls[Int(parent)].kind == .structure || holder.decls[Int(parent)].kind == .classType, holder.decls[Int(index)].kind == .variable { continue }
        found.append(DeclRef(unit: Int32(u), decl: index))
      }
    }
    if found.isEmpty {
      if let macros = projectMacrosNamed(word), !macros.isEmpty { return macros.count <= 3 ? macros.map { .decl($0) } : [] }
      return []
    }
    var keys = Set<UInt64>()
    for ref in found { keys.insert(entityOf[ref] ?? entityKey(ref) ?? 0) }
    guard keys.count <= 3 else { return [] }
    return resolveFound(found, unitIndex: unitIndex, token: -1)
  }

  // MARK: Preprocessor

  /// The directive whose line holds a token.
  func directive(containing token: Int, in unit: Unit) -> Int? {
    var i = token
    while i > 0 {
      if unit.tokens[i].kind == .directive { break }
      if unit.startsLine(i) {
        // A line continued by `\` is still the directive's.
        let from = unit.tokens[i - 1].end
        let to = unit.tokens[i].start
        var back = to - 1
        var continued = false
        while back >= from {
          let c = unit.source.text[back]
          if c == 0x0A {
            var k = back - 1
            while k >= from, unit.source.text[k] == 0x20 || unit.source.text[k] == 0x09 || unit.source.text[k] == 0x0D { k -= 1 }
            continued = k >= from && unit.source.text[k] == 0x5C
            break
          }
          back -= 1
        }
        if !continued { return nil }
      }
      i -= 1
    }
    guard unit.tokens[i].kind == .directive, let end = unit.cFile.ends[Int32(i)], token < Int(end) else { return nil }
    return i
  }

  private func directiveSites(unitIndex: Int32, token: Int, directive: Int) -> [Site] {
    let unit = project.units[Int(unitIndex)]
    let word = unit.hash(token)
    let name = layout.csyntax.directiveName(unit, directive)
    if let site = unit.declaredSite(at: token, unitIndex: unitIndex) {
      // A `#define` in a branch the build leaves out: clangd's macro is the one the build defines, when there is one.
      if unit.focusOffset != nil, case .decl(let ref) = site, decl(ref).kind == .macro {
        project.focus(unitIndex: unitIndex, offset: 0)
        let plain = project.units[Int(unitIndex)]
        if let active = macro(named: word, unitIndex: unitIndex, token: plain.tokens.count, needsCall: false) { return [.decl(active)] }
        return []
      }
      return [site]
    }
    switch name {
    case "include", "import", "include_next", "pragma", "error", "warning", "line": return []
    case "define":
      // A macro's parameter, else a name the expansion will find.
      if let index = unit.decls.lastIndex(where: { $0.kind == .macro && $0.first == Int32(directive) }) {
        let item = unit.decls[index]
        for p in 0..<Int(item.paramCount) where unit.params[Int(item.paramStart) + p].local == word {
          let param = unit.params[Int(item.paramStart) + p]
          return param.nameToken >= 0 ? [.local(unit: unitIndex, token: param.nameToken)] : []
        }
      }
      if let macro = macro(named: word, unitIndex: unitIndex, token: token, needsCall: false) { return [.decl(macro)] }
      if token > 0, unit.isToken(token - 1, "##") || unit.isToken(token - 1, "#") { return [] }
      // A name in the body is no declaration's until it's expanded: clangd answers what the nearest same word in the
      // code answers.
      if let nearby = nearbyWord(unitIndex: unitIndex, token: token) {
        // The toggle is from where the question was asked: a definition found nearby is the answer.
        guessing = true
        let found = sites(unitIndex: unitIndex, token: nearby)
        guessing = false
        if !found.isEmpty { return found }
      }
      if token > 0, unit.isByte(token - 1, 0x2E) || unit.isToken(token - 1, "->") {
        // A member in a macro's body: what a search by name finds, when that's a few.
        let found = project.membersNamed(word).filter { decl($0).kind == .variable || decl($0).kind == .function }
        var keys = Set<UInt64>()
        for ref in found { keys.insert(entityOf[ref] ?? entityKey(ref) ?? 0) }
        return !found.isEmpty && keys.count <= 3 ? resolveFound(found, unitIndex: unitIndex, token: token) : []
      }
      let found = lookup(word, unitIndex: unitIndex, token: unit.tokens.count, tag: false)
      if found.isEmpty { return fallback(word, unitIndex: unitIndex) }
      return resolveFound(found, unitIndex: unitIndex, token: token)
    default:
      // `#if`, `#ifdef`, `#undef`: macros only.
      if word == CodeModel.name("defined") { return [] }
      if let macro = macro(named: word, unitIndex: unitIndex, token: token, needsCall: false) { return [.decl(macro)] }
      // `#ifndef MIN` before `#define MIN`: the definition that follows.
      if let next = unit.cFile.macroEvents[word]?.first(where: { Int($0.token) > token }), next.decl >= 0 { return [.decl(DeclRef(unit: unitIndex, decl: next.decl))] }
      return []
    }
  }

  /// Whether an offset is in a branch the build leaves out (`Unit.isLeftOut`, kept as ranges per file).
  func isLeftOut(_ unit: Unit, _ offset: Int) -> Bool {
    let file = unit.cFile
    if file.leftOut == nil {
      var ranges: [Range<Int>] = []
      var i = 0
      while i < unit.tokens.count {
        guard unit.tokens[i].kind == .directive else {
          i += 1
          continue
        }
        let next = unit.takeDirective(i)
        let lineEnd = Int(file.ends[Int32(i)] ?? Int32(i + 1))
        if next > lineEnd {
          ranges.append(unit.tokens[i].end..<(next < unit.tokens.count ? unit.tokens[next].start : Int.max))
        }
        i = max(next, i + 1)
      }
      file.leftOut = ranges
    }
    return file.leftOut!.contains { $0.contains(offset) }
  }

  /// clangd's guess for a word no expansion reads (`findNearbyIdentifier`): the same word on the nearest line of code
  /// outside directives and left-out branches, a line before costing two after, within 2^length lines after and
  /// 2^(length-1) before.
  /// With `nearestOnly`, the nearest same word wherever it is, nil when that one is in a directive or left-out code
  /// (clangd has no answer for it there).
  func nearbyWord(unitIndex: Int32, token: Int, nearestOnly: Bool = false) -> Int? {
    let unit = project.units[Int(unitIndex)]
    let word = unit.hash(token)
    let lines = unit.source.lines
    let line = lines.line(of: unit.tokens[token].start)
    let length = min(unit.tokens[token].length, 30)
    let after = 1 << length
    let before = 1 << (length - 1)
    var best: (cost: Int, token: Int)?
    func consider(_ i: Int) -> Bool {
      let other = lines.line(of: unit.tokens[i].start)
      let cost = other >= line ? other - line : 2 * (line - other)
      if other > line + after || other < line - before { return true }
      if let best, cost >= best.cost { return true }
      guard unit.tokens[i].kind == .identifier, unit.hash(i) == word else { return false }
      guard nearestOnly || directive(containing: i, in: unit) == nil && !isLeftOut(unit, unit.tokens[i].start) else { return false }
      best = (cost, i)
      return false
    }
    var i = token + 1
    while i < unit.tokens.count, !consider(i) { i += 1 }
    i = token - 1
    while i >= 0, !consider(i) { i -= 1 }
    if nearestOnly, let found = best?.token, directive(containing: found, in: unit) != nil || isLeftOut(unit, unit.tokens[found].start) { return nil }
    return best?.token
  }

  /// What clangd's index finds by name: the declarations named so in every file read (fields too, not locals) and the
  /// project's macros; none when that's three or more.
  func textual(_ word: Name, unitIndex: Int32) -> [Site] {
    indexEntities()
    var found: [DeclRef] = []
    for u in 0..<project.units.count {
      let file = project.units[u].cFile
      for index in (file.ordinary[word] ?? []) + (file.tags[word] ?? []) { found.append(DeclRef(unit: Int32(u), decl: index)) }
    }
    found += project.membersNamed(word).filter { !found.contains($0) }
    var keys = Set<UInt64>()
    for ref in found { keys.insert(entityOf[ref] ?? entityKey(ref) ?? 0) }
    let macros = projectMacrosNamed(word) ?? []
    if !macros.isEmpty { keys.insert(0x4D41_4352_4F00) }
    guard !keys.isEmpty, keys.count <= 2 else { return [] }
    if found.isEmpty { return macros.prefix(2).map { .decl($0) } }
    return resolveFound(found, unitIndex: unitIndex, token: -1)
  }

  /// A namespace or type named `word` that the unit's closure declares at file scope or in a namespace, when lookup
  /// found only something else.
  func scopeLookup(_ word: Name, unitIndex: Int32) -> [DeclRef] {
    var found: [DeclRef] = []
    for u in closure(unitIndex) {
      let holder = project.units[Int(u)]
      for (index, item) in holder.decls.enumerated() where item.name == word && (item.kind == .namespace || item.kind.isNominal || item.kind == .typeAlias) {
        if item.parent < 0 || holder.decls[Int(item.parent)].kind == .namespace { found.append(DeclRef(unit: u, decl: Int32(index))) }
      }
    }
    return found
  }

  /// The `#define` a name stands for at a token: the file's own last before it, else the last its closure reads.
  func macro(named word: Name, unitIndex: Int32, token: Int, needsCall: Bool) -> DeclRef? {
    let unit = project.units[Int(unitIndex)]
    var found: DeclRef?
    var undefined = false
    if let events = unit.cFile.macroEvents[word], let last = events.last(where: { Int($0.token) < token }) {
      if last.decl < 0 { undefined = true } else { found = DeclRef(unit: unitIndex, decl: last.decl) }
    }
    if found == nil, !undefined {
      for u in closure(unitIndex).reversed() where u != unitIndex {
        guard let events = project.units[Int(u)].cFile.macroEvents[word], let last = events.last else { continue }
        if last.decl >= 0 { found = DeclRef(unit: u, decl: last.decl) }
        break
      }
    }
    if found == nil, !undefined, isHeader(unit), let macros = projectMacrosNamed(word), macros.count == 1 { found = macros[0] }
    guard let found else { return nil }
    if needsCall, unit.cFile.has(found.decl, .functionMacro) == false, file(found).has(found.decl, .functionMacro), !unit.isByte(token + 1, 0x28) { return nil }
    return found
  }

  func isHeader(_ unit: Unit) -> Bool { CDialect.of(path: unit.path) == nil || unit.path.hasSuffix(".hpp") || unit.path.hasSuffix(".hh") }

  func projectMacrosNamed(_ word: Name) -> [DeclRef]? {
    if projectMacros == nil {
      var map: [Name: [DeclRef]] = [:]
      for u in 0..<project.projectUnits {
        for (key, events) in project.units[u].cFile.macroEvents {
          for event in events where event.decl >= 0 { map[key, default: []].append(DeclRef(unit: Int32(u), decl: event.decl)) }
        }
      }
      projectMacros = map
    }
    return projectMacros?[word]
  }

  // MARK: Bodies

  /// The function whose body holds a token (the outermost), and its parameters' and locals' scan.
  func owner(unitIndex: Int32, token: Int32) -> Int32? {
    let unit = project.units[Int(unitIndex)]
    for index in unit.chain(at: token) {
      let item = unit.decls[Int(index)]
      if item.kind == .function || item.kind == .initializer || item.kind == .deinitializer, item.bodyOpen >= 0 { return index }
    }
    return nil
  }

  func body(unitIndex: Int32, token: Int32) -> CBody? {
    guard let owner = owner(unitIndex: unitIndex, token: token) else { return nil }
    let unit = project.units[Int(unitIndex)]
    if let known = unit.scans[owner] { return unsafeDowncast(known, to: CBody.self) }
    let scan = CBody(unit: unit, owner: owner, isType: { [unowned self] word, at in self.isTypeName(word, unitIndex: unitIndex, token: at) })
    unit.scans[owner] = scan
    return scan
  }

  // MARK: Names

  /// A name on its own at a token: the class or container around it, its namespaces and `using`s, the file scope of the
  /// unit's closure. `tag`: after `struct`, `union` or `enum` (C's tag names).
  func lookup(_ word: Name, unitIndex: Int32, token: Int, tag: Bool) -> [DeclRef] {
    let unit = project.units[Int(unitIndex)]
    let file = unit.cFile
    let chain = token < unit.tokens.count ? unit.chain(at: Int32(token)) : []
    // Template parameters and members of what's around it, innermost first.
    for index in chain.reversed() {
      let item = unit.decls[Int(index)]
      for g in 0..<Int(item.genericCount) where unit.generics[Int(item.genericStart) + g].name == word {
        return [DeclRef(unit: unitIndex, decl: -1 - Int32(item.genericStart) - Int32(g))]
      }
      // An out-of-line definition's qualifier is read outside its class.
      if item.kind == .extensionDecl, item.typeStart >= 0, Int32(token) >= item.typeStart, Int32(token) < item.typeEnd { continue }
      // A class's head (its bases) is read outside it.
      if item.kind.isNominal, item.bodyOpen >= 0, Int32(token) < item.bodyOpen { continue }
      if !tag || file.dialect.contains(.cpp), let type = enclosingType(unitIndex: unitIndex, holder: index) {
        var found = members(of: type, named: word, from: unitIndex, includeStatic: true)
        // The class's own name inside it is the class (its constructors only where it's called).
        if token < unit.tokens.count, !unit.isByte(token + 1, 0x28), !unit.isByte(token + 1, 0x7B) {
          found = found.filter { decl($0).kind != .initializer && decl($0).kind != .deinitializer }
        }
        if !found.isEmpty { return found }
        if case .nominal(let ref, _) = type, isObjC(self.unit(ref), ref.decl) || self.decl(ref).kind == .extensionDecl {
          // `_name`: a property's ivar.
          let text = unit.string(token < unit.tokens.count ? token : 0)
          if text.hasPrefix("_"), token < unit.tokens.count {
            let property = members(of: type, named: CodeModel.name(String(text.dropFirst())), from: unitIndex, includeStatic: false)
              .filter { self.file($0).has($0.decl, .property) }
            if !property.isEmpty { return property }
          }
        }
      }
    }
    // Namespaces around it, then the file's `using`s.
    if file.dialect.contains(.cpp) {
      var scopes: [UInt64] = []
      var key: UInt64 = 0
      var names: [Name] = []
      for index in chain {
        let item = unit.decls[Int(index)]
        if item.kind == .namespace, item.name != 0, !file.has(index, .inline) { names.append(item.name) }
        if item.kind == .extensionDecl, item.typeStart >= 0 { names += qualifierWords(unit, Int(item.typeStart), Int(item.typeEnd)) }
      }
      for word in names {
        key = CModel.mix(key, word)
        scopes.append(key)
      }
      indexEntities()
      for scope in scopes.reversed() {
        let found = (scoped[scope] ?? []).filter { decl($0).name == word && visible($0, from: unitIndex) }
        if !found.isEmpty { return preferOrdinary(found, tag: tag) }
      }
      for using in file.usings where using.token < Int32(token) && (using.scope < 0 || chain.contains(using.scope)) {
        let words = qualifierWords(unit, Int(using.start), Int(using.end))
        if using.isNamespace {
          var scope: UInt64 = 0
          for w in words { scope = CModel.mix(scope, w) }
          let found = (scoped[scope] ?? []).filter { decl($0).name == word && visible($0, from: unitIndex) }
          if !found.isEmpty { return preferOrdinary(found, tag: tag) }
        } else if words.last == word, words.count >= 2 {
          var scope: UInt64 = 0
          for w in words.dropLast() { scope = CModel.mix(scope, w) }
          let found = (scoped[scope] ?? []).filter { decl($0).name == word }
          if !found.isEmpty { return found }
        }
      }
    }
    return fileScope(word, unitIndex: unitIndex, tag: tag)
  }

  func visible(_ ref: DeclRef, from unitIndex: Int32) -> Bool { ref.unit == unitIndex || sees(unitIndex, ref.unit) }

  /// Non-tag declarations hide a tag of the same name (`stat` the function over `struct stat`), unless after its keyword.
  func preferOrdinary(_ found: [DeclRef], tag: Bool) -> [DeclRef] {
    let tags = found.filter { [.structure, .classType, .enumeration].contains(decl($0).kind) && !isObjC(unit($0), $0.decl) }
    if tag { return tags.isEmpty ? found : tags }
    let others = found.filter { !tags.contains($0) }
    return others.isEmpty ? found : others
  }

  /// The file scope of a unit's closure.
  func fileScope(_ word: Name, unitIndex: Int32, tag: Bool) -> [DeclRef] {
    var found: [DeclRef] = []
    for u in closure(unitIndex) {
      let unitFile = project.units[Int(u)].cFile
      let list = tag ? unitFile.tags[word] : unitFile.ordinary[word]
      for index in list ?? [] { found.append(DeclRef(unit: u, decl: index)) }
      if !tag, unitFile.dialect.contains(.cpp) == false, let tags = unitFile.tags[word] {
        // C: a tag is only seen after its keyword.
        _ = tags
      }
    }
    if found.isEmpty, !tag, project.units[Int(unitIndex)].cFile.dialect.contains(.cpp) {
      for u in closure(unitIndex) {
        for index in project.units[Int(u)].cFile.tags[word] ?? [] { found.append(DeclRef(unit: u, decl: index)) }
      }
    }
    return preferOrdinary(found, tag: tag)
  }

  /// Whether a word names a type at a token (a typedef, a class, a template parameter), as a body's scan asks.
  func isTypeName(_ word: Name, unitIndex: Int32, token: Int) -> Bool {
    for ref in lookup(word, unitIndex: unitIndex, token: token, tag: false) {
      if ref.decl < 0 { return true }
      let kind = decl(ref).kind
      if kind == .typeAlias || kind == .structure || kind == .classType || kind == .enumeration || kind == .protocolType { return true }
      if kind == .namespace { return false }
    }
    return false
  }

  // MARK: Objective-C selectors

  /// A piece of a method's selector other than its first (`style` in `initWithFrame:style:`) declares the method.
  func selectorOwner(_ unit: Unit, _ token: Int) -> Int32? {
    guard unit.isByte(token + 1, 0x3A) else { return nil }
    for (method, pieces) in unit.cFile.selectors where pieces.dropFirst().contains(Int32(token)) { return method }
    return nil
  }

  /// `[receiver piece:arg piece:arg]` around a token that's one of its pieces: the `[`, the receiver's end, the
  /// selector.
  func messageSelector(_ unit: Unit, _ token: Int) -> (open: Int, receiverEnd: Int, selector: Name)? {
    guard unit.cFile.dialect.contains(.objc), let open = unit.matchingOpenBefore(token), unit.isByte(open, 0x5B) else { return nil }
    let close = unit.skipBalanced(open) - 1
    // The receiver: one expression from after `[`.
    var i = open + 1
    var receiverEnd = -1
    while i < close {
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        receiverEnd = i - 1
        continue
      }
      if unit.isWord(i), receiverEnd >= 0, unit.isWord(receiverEnd) || unit.tokens[receiverEnd].kind == .close { break }
      if unit.isWord(i) || unit.tokens[i].kind == .punctuation {
        receiverEnd = i
        i += 1
        continue
      }
      receiverEnd = i
      i += 1
    }
    guard receiverEnd >= open + 1, i < close, i <= token else { return nil }
    var selector = ""
    var isPiece = false
    var j = i
    while j < close {
      if unit.isWord(j), unit.isByte(j + 1, 0x3A) {
        selector += unit.string(j) + ":"
        if j == token { isPiece = true }
        j += 2
        // Past the argument.
        while j < close {
          if unit.tokens[j].kind == .open {
            j = unit.skipBalanced(j)
            continue
          }
          if unit.isWord(j), unit.isByte(j + 1, 0x3A), j > 0, !unit.isByte(j - 1, 0x3F), unit.tokens[j - 1].kind != .punctuation || unit.isByte(j - 1, 0x29) || unit.tokens[j - 1].kind == .close {
            break
          }
          if unit.isWord(j), unit.isByte(j + 1, 0x3A), unit.tokens[j - 1].kind == .identifier || unit.tokens[j - 1].kind == .close || unit.tokens[j - 1].kind == .number || unit.tokens[j - 1].kind == .string {
            break
          }
          j += 1
        }
        continue
      }
      if j == i, unit.isWord(j), j + 1 == close {
        selector = unit.string(j)
        if j == token { isPiece = true }
      }
      break
    }
    guard isPiece, !selector.isEmpty else { return nil }
    return (open, receiverEnd, CodeModel.name(selector))
  }

  // MARK: References

  public func references(of answer: Answer) -> [(path: String, line: Int)] {
    guard answer.state != .unknown, !answer.byNameOnly, let first = answer.sites.first else { return [] }
    var targets = Set(answer.sites)
    var names: Set<Name> = []
    var restrict: Int32?
    switch first {
    case .decl(let ref):
      names.insert(referenceName(ref))
    case .local(let unitIndex, let token), .generic(let unitIndex, let token):
      names.insert(project.units[Int(unitIndex)].hash(Int(token)))
      restrict = unitIndex
    case .module:
      return []
    }
    for target in answer.sites {
      guard case .decl(let ref) = target else { continue }
      for other in redeclarations(ref) {
        targets.insert(.decl(other))
        names.insert(referenceName(other))
      }
    }
    return project.references(named: names, in: restrict, landingOn: targets) { unitIndex, token in
      self.byNameOnly = false
      let found = self.sites(unitIndex: unitIndex, token: token)
      if found.isEmpty || self.byNameOnly { return Answer(state: .unknown, sites: []) }
      // A use lands on any declaration of the entity it names.
      var expanded = found
      for site in found { if case .decl(let ref) = site { expanded += self.redeclarations(ref).map { .decl($0) } } }
      return Answer(state: .candidates, sites: expanded)
    }
  }

  /// The word a declaration is written with: a method's first selector piece.
  func referenceName(_ ref: DeclRef) -> Name {
    let item = decl(ref)
    if item.nameToken >= 0 { return unit(ref).hash(Int(item.nameToken)) }
    return item.name
  }

  // MARK: Places

  public func place(of site: Site) -> (path: String, line: Int)? {
    let holder: Unit
    let token: Int
    switch site {
    case .decl(let ref):
      guard ref.decl >= 0 else {
        // A template parameter.
        let generic = unit(ref).generics[Int(-1 - ref.decl)]
        return placeOf(unit(ref), Int(generic.token))
      }
      holder = unit(ref)
      token = Int(decl(ref).nameToken)
    case .local(let unitIndex, let index), .generic(let unitIndex, let index):
      holder = project.units[Int(unitIndex)]
      token = Int(index)
    case .module:
      return nil
    }
    return placeOf(holder, token)
  }

  func placeOf(_ unit: Unit, _ token: Int) -> (path: String, line: Int)? {
    guard token >= 0, token < unit.tokens.count else { return nil }
    let line = unit.source.lines.line(of: unit.tokens[token].start) + 1
    if unit.path.hasPrefix(project.root + "/") { return (String(unit.path.dropFirst(project.root.count + 1)), line) }
    return (layout.outsidePlace(unit.path), line)
  }
}

extension Unit {
  /// No space between this token and the one after.
  func touchesNext(_ i: Int) -> Bool { i + 1 < tokens.count && tokens[i].end == tokens[i + 1].start }
}
