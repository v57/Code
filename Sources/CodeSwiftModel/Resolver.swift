import CodeScan
import Foundation

/// Words the lexer calls keywords that Swift lets anything be named.
let contextualWords: Set<Name> = Set(
  [
    "prefix", "postfix", "infix", "open", "set", "get", "left", "right", "none", "some", "any", "final", "lazy", "weak", "unowned", "required",
    "optional", "override", "dynamic", "mutating", "nonmutating", "indirect", "convenience", "async", "await", "actor", "package", "default",
    "precedence", "associativity", "assignment", "didSet", "willSet", "of", "macro", "consuming", "borrowing", "each", "isolated",
  ].map(hashName))

public enum AnswerState: String { case exact, candidates, unknown }

public struct Answer {
  public var state: AnswerState
  public var sites: [Site]
  /// Candidates only because they have the right name, as the receiver's type couldn't be told.
  public var byNameOnly = false
}

/// A step of a chain: what's named, then what happens to its value.
enum Head {
  case name, implicit, member
  case tupleIndex(Int)
  case number, string, bool, nothing
  case paren(close: Int32), array(close: Int32), closure
}

enum Op {
  case call(open: Int32, trailing: Int32)
  case index(open: Int32)
  case unwrap
}

struct Step {
  var head: Head
  var token: Int32
  var genericArgs: (Int32, Int32)? = nil
  var ops: [Op] = []
}

/// One possibility at a step. `prev` is the one in the step before that it came from.
struct Cand {
  var site: Site?
  var extra: Site? = nil
  var ty: Ty
  var receiver: Ty? = nil
  var prev: Int32 = -1
  var keep = true
}

final class ChainResult {
  var steps: [Step] = []
  var sets: [[Cand]] = []
  var end: Int32 = 0
  var ty: Ty = .unknown
}

struct ClauseKey: Hashable {
  var clause: DeclRef
  var receiver: Ty
}

public final class Model {
  public let project: Project
  var typeMemo: [DeclRef: Ty] = [:]
  var tables: [DeclRef: [Name: [DeclRef]]] = [:]
  var inheritedTypes: [DeclRef: [Ty]] = [:]
  var extensionTargets: [DeclRef: DeclRef] = [:]
  /// Inherited members that came through a conditional conformance, by holder: the extensions whose `where` lets them.
  var conditions: [DeclRef: [DeclRef: [DeclRef]]] = [:]
  var clauseMemo: [ClauseKey: Bool] = [:]
  var phantoms: [Name: DeclRef] = [:]
  var building: Set<DeclRef> = []
  var resolving: Set<DeclRef> = []
  private var inProgress: [UInt64: Int] = [:]
  /// The outermost evaluation a cycle ran into: anything deeper saw that one unfinished, so it isn't kept.
  private var cycleBase = Int.max
  private var noBinding = 0
  private var depth = 0
  private var byName: [Name: [DeclRef]]?
  public internal(set) var checkedAccesses = 0
  /// How many times a question had headers read for it.
  public internal(set) var clangLoads = 0
  var topCache: [Name: [TopEntry]] = [:]
  var completionToken: Int32 = 0
  var tupleLabels: [Name: String]?
  /// What the last expected type could also have been, when overloads disagree: completion offers them all.
  var expectedAlternatives: [Ty] = []
  var projectCounts: [Name: Int32]?
  var dynamicDepth = 0

  public init(project: Project) {
    self.project = project
    project.onShapeChange = { [weak self] in self?.dropTables() }
  }

  private func dropTables() {
    typeMemo.removeAll()
    tables.removeAll()
    inheritedTypes.removeAll()
    extensionTargets.removeAll()
    conditions.removeAll()
    clauseMemo.removeAll()
    phantoms.removeAll()
    byName = nil
    topCache.removeAll()
  }

  /// After headers came in: what was built without them is stale.
  func resetAfterClang() {
    dropTables()
  }

  // MARK: Asking

  public func answer(path: String, line: Int, character: Int) -> Answer {
    guard let unitIndex = project.unitByPath[path] else { return Answer(state: .unknown, sites: []) }
    var unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    project.focus(unitIndex: unitIndex, offset: offset)
    unit = project.units[Int(unitIndex)]
    // The first token ending after the offset, in the list without comments.
    var low = 0
    var high = unit.tokens.count - 1
    while low < high {
      let middle = (low + high) / 2
      if unit.tokens[middle].end <= offset { low = middle + 1 } else { high = middle }
    }
    guard low < unit.tokens.count, unit.tokens[low].start <= offset else { return Answer(state: .unknown, sites: []) }
    return answer(unitIndex: unitIndex, token: low)
  }

  /// Files whose lookups missed since headers were last read. Kept after an answer that didn't need them: what missed may
  /// be memoized by now, and a later question would hit that with nothing telling it why.
  private var misses: Set<Int32> = []

  func noteMiss(_ unitIndex: Int32) { misses.insert(unitIndex) }
  /// A class answered from a protocol it conforms to, with headers still to read that may give it the member itself.
  var protocolOverHeaders = false

  /// Answers from what's loaded. Only an answer that isn't exact, after a miss, is worth reading headers for.
  func answer(unitIndex: Int32, token: Int) -> Answer {
    protocolOverHeaders = false
    var found = answerFromLoaded(unitIndex: unitIndex, token: token)
    while found.state != .exact || protocolOverHeaders, !misses.isEmpty {
      let loaded = project.loadClang(visibleFrom: misses)
      misses.removeAll()
      guard loaded else { break }
      clangLoads += 1
      dropTables()
      protocolOverHeaders = false
      found = answerFromLoaded(unitIndex: unitIndex, token: token)
    }
    return found
  }

  private func answerFromLoaded(unitIndex: Int32, token: Int) -> Answer {
    let unit = project.units[Int(unitIndex)]
    if let site = unit.declaredSite(at: token, unitIndex: unitIndex) { return Answer(state: .exact, sites: [site]) }
    let kind = unit.tokens[token].kind
    if kind == .attribute {
      let text = unit.string(token).dropFirst()
      let scope = chain(at: Int32(token), unitIndex: unitIndex)
      let ty = lookupType(hashName(String(text)), unitIndex: unitIndex, token: Int32(token), scope: scope, args: [])
      if case .nominal(let ref, _) = ty { return Answer(state: .exact, sites: [.decl(ref)]) }
      // `@Test` is a macro, not a type.
      for moduleName in project.visibleModules(of: unitIndex) {
        if let found = project.modules[moduleName]?.top[hashName(String(text))]?.filter({ accessible($0, from: unitIndex) }), !found.isEmpty {
          return Answer(state: found.count == 1 ? .exact : .candidates, sites: found.map { .decl($0) })
        }
      }
      return Answer(state: .unknown, sites: [])
    }
    let afterDot = token > 0 && isDot(unit, token - 1)
    if kind == .directive {
      // `#expect`, `#require`: macros by name.
      let macro = hashName(String(unit.string(token).dropFirst()))
      for moduleName in project.visibleModules(of: unitIndex) {
        if let found = project.modules[moduleName]?.top[macro]?.filter({ accessible($0, from: unitIndex) }), !found.isEmpty {
          return Answer(state: found.count == 1 ? .exact : .candidates, sites: found.map { .decl($0) })
        }
      }
      return Answer(state: .unknown, sites: [])
    }
    if kind == .keyword || kind == .declarationKeyword, !afterDot {
      let word = unit.hash(token)
      guard word == Word.selfValue || word == Word.selfType || word == Word.superValue || word == Word.initName || contextualWords.contains(word) else {
        return Answer(state: .unknown, sites: [])
      }
    }
    guard kind == .identifier || kind == .keyword || kind == .declarationKeyword else { return Answer(state: .unknown, sites: []) }
    prepareScans(unitIndex: unitIndex, token: Int32(token))
    if let site = localDeclared(unitIndex: unitIndex, token: Int32(token)) { return Answer(state: .exact, sites: [site]) }
    // A local type's own declaration, parsed by the scan just now.
    if let site = unit.declaredSiteFresh(at: token, unitIndex: unitIndex) { return Answer(state: .exact, sites: [site]) }
    // An argument label belongs to the call.
    if unit.isByte(token + 1, 0x3A), token > 0, unit.isByte(token - 1, 0x28) || unit.isByte(token - 1, 0x2C) {
      if let open = enclosingOpen(unit, token), unit.isByte(open, 0x28), isCallOpen(unit, open) {
        let found = calleeCandidates(unitIndex: unitIndex, open: open)
        if !found.isEmpty { return summarize(found, token: token, unitIndex: unitIndex, isMember: false) }
      }
    }
    let start = chainStart(unit, token)
    let result = evaluate(unitIndex: unitIndex, start: Int32(start))
    guard let at = result.steps.firstIndex(where: { $0.token == Int32(token) }) else { return Answer(state: .unknown, sites: []) }
    var isMember = false
    if case .member = result.steps[at].head { isMember = true }
    if case .implicit = result.steps[at].head { isMember = true }
    return summarize(result.sets[at], token: token, unitIndex: unitIndex, isMember: isMember)
  }

  private func summarize(_ set: [Cand], token: Int, unitIndex: Int32, isMember: Bool) -> Answer {
    var sites: [Site] = []
    var mains = 0
    var hasUnknown = false
    for cand in set {
      if let site = cand.site {
        if !sites.contains(site) {
          sites.append(site)
          mains += 1
        }
        if let extra = cand.extra, !sites.contains(extra) { sites.append(extra) }
      } else {
        hasUnknown = true
      }
    }
    if sites.isEmpty {
      guard isMember else { return Answer(state: .unknown, sites: []) }
      // A member of what couldn't be told: the project's members of that name, said to be candidates.
      let found = membersNamed(project.units[Int(unitIndex)].hash(token), from: unitIndex)
      guard !found.isEmpty else { return Answer(state: .unknown, sites: []) }
      return Answer(state: .candidates, sites: found.prefix(12).map { .decl($0) }, byNameOnly: true)
    }
    // Known only by its extensions, the type itself is elsewhere: that's a lead, not an answer.
    var isLead = false
    if case .decl(let ref) = sites[0], decl(ref).kind == .extensionDecl { isLead = true }
    return Answer(state: mains == 1 && !hasUnknown && !isLead ? .exact : .candidates, sites: sites)
  }

  private func membersNamed(_ member: Name, from unitIndex: Int32) -> [DeclRef] {
    if byName == nil {
      var map: [Name: [DeclRef]] = [:]
      for u in 0..<project.projectUnits {
        let unit = project.units[u]
        for (index, decl) in unit.decls.enumerated() where decl.parent >= 0 && !decl.isLocal && decl.kind != .extensionDecl {
          map[decl.name, default: []].append(DeclRef(unit: Int32(u), decl: Int32(index)))
        }
      }
      byName = map
    }
    return (byName?[member] ?? []).filter { accessible($0, from: unitIndex) }
  }

  // MARK: Scans

  func scan(unitIndex: Int32, owner: Int32) -> BodyScan {
    let unit = project.units[Int(unitIndex)]
    if let known = unit.scans[owner] { return known }
    let scan = BodyScan(unit: unit, owner: owner)
    unit.scans[owner] = scan
    return scan
  }

  /// Every scan a token sits in, the outermost first, as a scan may add local types and functions the next can be inside.
  func prepareScans(unitIndex: Int32, token: Int32) {
    let unit = project.units[Int(unitIndex)]
    var known = 0
    while true {
      let list = chain(at: token, unitIndex: unitIndex)
      if list.isEmpty {
        _ = scan(unitIndex: unitIndex, owner: -1)
        return
      }
      for index in list where !unit.decls[Int(index)].kind.hasMembers { _ = scan(unitIndex: unitIndex, owner: index) }
      if list.count == known { return }
      known = list.count
    }
  }

  func scans(unitIndex: Int32, token: Int32) -> [BodyScan] {
    prepareScans(unitIndex: unitIndex, token: token)
    let unit = project.units[Int(unitIndex)]
    let list = chain(at: token, unitIndex: unitIndex)
    if list.isEmpty { return [scan(unitIndex: unitIndex, owner: -1)] }
    var result: [BodyScan] = []
    for index in list.reversed() where !unit.decls[Int(index)].kind.hasMembers { result.append(scan(unitIndex: unitIndex, owner: index)) }
    return result
  }

  private func localDeclared(unitIndex: Int32, token: Int32) -> Site? {
    for scan in scans(unitIndex: unitIndex, token: token) {
      if let index = scan.byToken[token] {
        if case .declaration(let decl) = scan.locals[Int(index)].kind { return .decl(DeclRef(unit: unitIndex, decl: decl)) }
        return .local(unit: unitIndex, token: token)
      }
    }
    return nil
  }

  // MARK: Reading chains

  private func isDot(_ unit: Unit, _ i: Int) -> Bool {
    unit.isByte(i, 0x2E) || unit.isToken(i, "?.") || unit.isToken(i, "!.")
  }

  private func isSugar(_ unit: Unit, _ i: Int) -> Bool { unit.isByte(i, 0x3F) || unit.isByte(i, 0x21) }

  func isCallOpen(_ unit: Unit, _ open: Int) -> Bool {
    guard open > 0 else { return false }
    let before = unit.tokens[open - 1]
    if before.end != unit.tokens[open].start { return false }
    switch before.kind {
    case .identifier, .close: return true
    case .keyword: return unit.isToken(open - 1, "init") || unit.isToken(open - 1, "self") || unit.isToken(open - 1, "super") || (open > 1 && isDot(unit, open - 2))
    case .declarationKeyword: return unit.isToken(open - 1, "init") || (open > 1 && isDot(unit, open - 2))
    case .punctuation: return unit.isByte(open - 1, 0x3E) || isSugar(unit, open - 1)
    default: return false
    }
  }

  /// Walks back from a token to where the chain it's in starts.
  func chainStart(_ unit: Unit, _ token: Int) -> Int {
    var i = token
    if i > 0, unit.isByte(i - 1, 0x60) { i -= 1 }
    while true {
      guard i > 0, isDot(unit, i - 1) else { return i }
      var j = i - 2
      guard j >= 0 else { return i - 1 }
      while true {
        guard j >= 0 else { return i - 1 }
        let previous = unit.tokens[j]
        switch previous.kind {
        case .close:
          guard let open = unit.matchingOpen(j) else { return i }
          if unit.isByte(open, 0x7B) {
            // `} label: {`: one of several trailing closures.
            if open >= 3, unit.isByte(open - 1, 0x3A), unit.tokens[open - 2].kind == .identifier || unit.tokens[open - 2].kind == .keyword, unit.isByte(open - 3, 0x7D) {
              j = open - 3
              continue
            }
            // A trailing closure, or a closure called right away.
            if open > 0, unit.tokens[open - 1].kind == .identifier || unit.tokens[open - 1].kind == .close {
              j = open - 1
              continue
            }
            return open
          }
          if isCallOpen(unit, open) {
            j = open - 1
            continue
          }
          return open
        case .identifier:
          i = j
        case .keyword, .declarationKeyword:
          let word = unit.hash(j)
          if word == Word.selfValue || word == Word.selfType || word == Word.superValue || word == Word.initName || (j > 0 && isDot(unit, j - 1)) {
            i = j
          } else if unit.isToken(j, "true") || unit.isToken(j, "false") {
            return j
          } else {
            // After `return`, `case` and the like, the dot starts an implicit member.
            return i - 1
          }
        case .number, .directive:
          return j
        case .string, .interpolationClose:
          var k = j
          while k > 0, unit.tokens[k].kind == .string || unit.tokens[k].kind == .interpolationClose {
            if unit.tokens[k].kind == .interpolationClose {
              guard let open = unit.matchingOpen(k) else { return k }
              k = open - 1
            } else if k > 0, unit.tokens[k - 1].kind == .interpolationClose {
              k -= 1
            } else {
              break
            }
          }
          return k
        case .punctuation:
          // `a?.b`. With a space, `a ? .b`, it's a ternary and the dot starts an implicit member.
          if isSugar(unit, j), unit.touchesPrevious(j) {
            j -= 1
            continue
          }
          if unit.isByte(j, 0x60), j >= 2 {
            i = j - 2
            break
          }
          if unit.isByte(j, 0x3E) {
            var level = 0
            var k = j
            while k >= 0, j - k < 64 {
              if unit.isByte(k, 0x3E) { level += 1 }
              if unit.isToken(k, "<") {
                level -= 1
                if level == 0 { break }
              }
              k -= 1
            }
            if k > 0, level == 0, unit.tokens[k - 1].kind == .identifier {
              j = k - 1
              i = j
              break
            }
          }
          return i - 1
        default:
          return i - 1
        }
        break
      }
    }
  }

  /// Reads a chain forward from where it starts.
  func parseChain(unitIndex: Int32, start: Int, limit: Int? = nil) -> (steps: [Step], end: Int) {
    let unit = project.units[Int(unitIndex)]
    var steps: [Step] = []
    var i = start
    let count = limit.map { min($0, unit.tokens.count) } ?? unit.tokens.count
    guard i < count else { return ([], i) }
    let token = unit.tokens[i]
    switch token.kind {
    case .number:
      steps.append(Step(head: .number, token: Int32(i)))
      i += 1
    case .string, .interpolationOpen:
      steps.append(Step(head: .string, token: Int32(i)))
      while i < count {
        if unit.tokens[i].kind == .interpolationOpen {
          i = unit.skipBalanced(i)
        } else if unit.tokens[i].kind == .string {
          i += 1
        } else {
          break
        }
      }
    case .open:
      let close = unit.skipBalanced(i) - 1
      if unit.isByte(i, 0x28) {
        steps.append(Step(head: .paren(close: Int32(close)), token: Int32(i)))
      } else if unit.isByte(i, 0x5B) {
        steps.append(Step(head: .array(close: Int32(close)), token: Int32(i)))
      } else {
        steps.append(Step(head: .closure, token: Int32(i)))
      }
      i = close + 1
    case .punctuation:
      if unit.isByte(i, 0x2E), i + 1 < count {
        let at = unit.isByte(i + 1, 0x60) ? i + 2 : i + 1
        steps.append(Step(head: .implicit, token: Int32(at)))
        i = unit.isByte(i + 1, 0x60) ? i + 4 : i + 2
      } else if unit.isByte(i, 0x60), i + 2 < count {
        steps.append(Step(head: .name, token: Int32(i + 1)))
        i += 3
      } else {
        return ([], i)
      }
    case .directive:
      // `#require(x)`: a macro called, as an expression. `#if` and the like aren't.
      guard unit.isByte(i + 1, 0x28), !unit.isToken(i, "#if"), !unit.isToken(i, "#elseif"), !unit.isToken(i, "#available"), !unit.isToken(i, "#unavailable") else { return ([], i) }
      steps.append(Step(head: .name, token: Int32(i)))
      i += 1
    case .identifier, .keyword, .declarationKeyword:
      if unit.isToken(i, "true") || unit.isToken(i, "false") {
        steps.append(Step(head: .bool, token: Int32(i)))
      } else if unit.isToken(i, "nil") {
        steps.append(Step(head: .nothing, token: Int32(i)))
      } else {
        steps.append(Step(head: .name, token: Int32(i)))
      }
      i += 1
    default:
      return ([], i)
    }
    postfix(unitIndex: unitIndex, &steps, &i, count: count)
    return (steps, i)
  }

  private func postfix(unitIndex: Int32, _ steps: inout [Step], _ i: inout Int, count: Int) {
    let unit = project.units[Int(unitIndex)]
    while i < count, !steps.isEmpty {
      let token = unit.tokens[i]
      let last = steps.count - 1
      let adjacent = i > 0 && unit.tokens[i - 1].end == token.start
      if unit.isToken(i, "<"), adjacent, steps[last].ops.isEmpty, let close = genericClose(unit, i) {
        steps[last].genericArgs = (Int32(i), Int32(close))
        i = close + 1
        continue
      }
      if isDot(unit, i), i + 1 < count {
        if !unit.isByte(i, 0x2E) { steps[last].ops.append(.unwrap) }
        var at = i + 1
        var after = i + 2
        if unit.isByte(at, 0x60) {
          at += 1
          after = at + 2
        }
        let member = unit.tokens[at]
        if member.kind == .number {
          let text = unit.string(at)
          steps.append(Step(head: .tupleIndex(Int(text) ?? -1), token: Int32(at)))
        } else if member.kind == .identifier || member.kind == .keyword || member.kind == .declarationKeyword {
          steps.append(Step(head: .member, token: Int32(at)))
        } else {
          return
        }
        i = after
        continue
      }
      if token.kind == .open {
        if unit.isByte(i, 0x28), adjacent {
          let close = unit.skipBalanced(i)
          var trailing: Int32 = -1
          if unit.isByte(close, 0x7B), isClosure(unitIndex: unitIndex, open: close) { trailing = Int32(close) }
          steps[last].ops.append(.call(open: Int32(i), trailing: trailing))
          i = trailing >= 0 ? skipLabeledClosures(unit, unit.skipBalanced(close), count: count) : close
          continue
        }
        if unit.isByte(i, 0x5B), adjacent {
          steps[last].ops.append(.index(open: Int32(i)))
          i = unit.skipBalanced(i)
          continue
        }
        // `-> URL {`: a local function's body, not a closure given to a type.
        if unit.isByte(i, 0x7B), !unit.isToken(Int(steps[0].token) - 1, "->"), isClosure(unitIndex: unitIndex, open: i) {
          steps[last].ops.append(.call(open: -1, trailing: Int32(i)))
          i = skipLabeledClosures(unit, unit.skipBalanced(i), count: count)
          continue
        }
        return
      }
      if adjacent, isSugar(unit, i) {
        steps[last].ops.append(.unwrap)
        i += 1
        continue
      }
      return
    }
  }

  /// `} label: {`: what a call's first trailing closure is followed by.
  private func skipLabeledClosures(_ unit: Unit, _ from: Int, count: Int) -> Int {
    var i = from
    while i + 2 < count, unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword, unit.isByte(i + 1, 0x3A), unit.isByte(i + 2, 0x7B) {
      i = unit.skipBalanced(i + 2)
    }
    return i
  }

  private func isClosure(unitIndex: Int32, open: Int) -> Bool {
    for scan in scans(unitIndex: unitIndex, token: Int32(open)) where scan.closureOpens.contains(Int32(open)) { return true }
    return false
  }

  /// The `>` of generic arguments right after a name, when what's between reads as types and a call or dot follows.
  private func genericClose(_ unit: Unit, _ open: Int) -> Int? {
    var level = 0
    var i = open
    while i < unit.tokens.count, i - open < 64 {
      let token = unit.tokens[i]
      if token.kind == .open, !unit.isByte(i, 0x5B), !unit.isByte(i, 0x28) { return nil }
      if token.kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if token.kind == .close { return nil }
      if token.kind == .punctuation {
        if unit.isToken(i, "<") {
          level += 1
        } else if !unit.isToken(i, "->") {
          for k in 0..<token.length where unit.source.text[token.start + k] == 0x3E { level -= 1 }
          if level <= 0 {
            let next = i + 1
            if unit.isByte(next, 0x28) || unit.isByte(next, 0x2E) || unit.isByte(next, 0x7B) || unit.isByte(next, 0x29) || unit.isByte(next, 0x3F) { return i }
            return nil
          }
        }
      }
      i += 1
    }
    return nil
  }

  func enclosingOpen(_ unit: Unit, _ token: Int) -> Int? {
    var level = 0
    var i = token - 1
    var budget = 2048
    while i >= 0, budget > 0 {
      budget -= 1
      let kind = unit.tokens[i].kind
      if kind == .close || kind == .interpolationClose {
        level += 1
      } else if kind == .open || kind == .interpolationOpen {
        if level == 0 { return i }
        level -= 1
      }
      i -= 1
    }
    return nil
  }

  // MARK: Evaluating chains

  private func key(_ unitIndex: Int32, _ start: Int32) -> UInt64 { UInt64(UInt32(bitPattern: unitIndex)) << 32 | UInt64(UInt32(bitPattern: start)) }

  /// Forward with sets of possibilities, then backward: a possibility that nothing after it could follow goes.
  /// With a limit, only what comes before it: code being typed, where what follows isn't part of the chain. That isn't kept.
  func evaluate(unitIndex: Int32, start: Int32, limit: Int32? = nil) -> ChainResult {
    let unit = project.units[Int(unitIndex)]
    if limit == nil, let known = unit.chains[start] { return known }
    let id = key(unitIndex, start) ^ (limit.map { UInt64(UInt32(bitPattern: $0)) << 1 | 1 } ?? 0)
    let result = ChainResult()
    if depth >= 48 { cycleBase = 0 }
    if let running = inProgress[id] { cycleBase = min(cycleBase, running) }
    guard depth < 48, inProgress[id] == nil else {
      let parsed = parseChain(unitIndex: unitIndex, start: Int(start), limit: limit.map(Int.init))
      result.steps = parsed.steps
      result.end = Int32(parsed.end)
      result.sets = parsed.steps.map { _ in [] }
      return result
    }
    let level = depth
    inProgress[id] = level
    depth += 1
    defer {
      depth -= 1
      inProgress[id] = nil
      if cycleBase >= level { cycleBase = Int.max }
    }
    let parsed = parseChain(unitIndex: unitIndex, start: Int(start), limit: limit.map(Int.init))
    result.steps = parsed.steps
    result.end = Int32(parsed.end)
    var sets: [[Cand]] = []
    for (index, step) in parsed.steps.enumerated() {
      let previous = index > 0 ? sets[index - 1] : []
      var set = cands(for: step, previous: previous, unitIndex: unitIndex, isLast: limit == nil && index == parsed.steps.count - 1, start: start)
      if index > 0, set.isEmpty { set = [Cand(site: nil, ty: .unknown, prev: 0)] }
      sets.append(set)
    }
    // Backward: if anything after is known, what led only to unknowns goes.
    if sets.count > 1 {
      for index in stride(from: sets.count - 1, to: 0, by: -1) {
        let hasKnown = sets[index].contains { $0.keep && $0.site != nil }
        var used = Set<Int32>()
        for cand in sets[index] where cand.keep && (!hasKnown || cand.site != nil) { used.insert(cand.prev) }
        guard !used.isEmpty else { continue }
        for at in sets[index - 1].indices where !used.contains(Int32(at)) { sets[index - 1][at].keep = false }
      }
    }
    let kept = sets.map { set -> [Cand] in
      let list = set.filter(\.keep)
      return list.isEmpty ? set : list
    }
    result.sets = kept
    if let last = kept.last {
      let types = last.map(\.ty)
      if let first = types.first, types.allSatisfy({ $0 == first }) { result.ty = first }
    }
    if limit == nil, noBinding == 0, cycleBase >= level { unit.chains[start] = result }
    return result
  }

  private func cands(for step: Step, previous: [Cand], unitIndex: Int32, isLast: Bool, start: Int32) -> [Cand] {
    let unit = project.units[Int(unitIndex)]
    var result: [Cand]
    switch step.head {
    case .number:
      let text = unit.string(Int(step.token))
      let isFloat = text.contains(".") && !text.hasPrefix("0x")
      result = [Cand(site: nil, ty: standard(isFloat ? Word.double : Word.int, []))]
    case .string:
      result = [Cand(site: nil, ty: standard(Word.string, []))]
    case .bool:
      result = [Cand(site: nil, ty: standard(Word.bool, []))]
    case .nothing, .closure:
      result = [Cand(site: nil, ty: .unknown)]
    case .paren(let close):
      let items = splitArguments(unit, open: Int(step.token), close: Int(close))
      if items.count == 1, items[0].label == 0 {
        result = [Cand(site: nil, ty: evaluateExpression(unitIndex: unitIndex, start: items[0].start, end: items[0].end))]
      } else {
        let types = items.map { evaluateExpression(unitIndex: unitIndex, start: $0.start, end: $0.end) }
        result = [Cand(site: nil, ty: .tuple(types, items.map(\.label)))]
      }
    case .array(let close):
      result = [Cand(site: nil, ty: arrayLiteral(unitIndex: unitIndex, open: Int(step.token), close: Int(close)))]
    case .tupleIndex(let slot):
      result = []
      for (index, cand) in previous.enumerated() {
        var ty = cand.ty
        if case .optional(let wrapped) = ty { ty = wrapped }
        if case .tuple(let items, _) = ty, slot >= 0, slot < items.count {
          result.append(Cand(site: nil, ty: items[slot], prev: Int32(index)))
        } else {
          result.append(Cand(site: nil, ty: .unknown, prev: Int32(index)))
        }
      }
      return applyPostOps(result, step: step, unitIndex: unitIndex, tierOnly: true)
    case .name:
      let tiers = headCandidates(unitIndex: unitIndex, step: step)
      var chosen: [Cand] = []
      for tier in tiers {
        let applied = applyCall(tier, step: step, unitIndex: unitIndex, strict: true)
        if !applied.isEmpty {
          chosen = applied
          break
        }
      }
      if chosen.isEmpty, let first = tiers.first(where: { !$0.isEmpty }) { chosen = applyCall(first, step: step, unitIndex: unitIndex, strict: false) }
      result = chosen
      return finishStep(result, step: step, unitIndex: unitIndex, isLast: isLast, start: start)
    case .implicit:
      var set: [Cand] = []
      if let wanted = expectedType(unitIndex: unitIndex, start: start) {
        var base = wanted
        while case .optional(let wrapped) = base { base = wrapped }
        set = memberCandidates(of: .meta(base), name: unit.hash(Int(step.token)), from: unitIndex, prev: -1)
      }
      let applied = applyCall(set, step: step, unitIndex: unitIndex, strict: false)
      return finishStep(applied, step: step, unitIndex: unitIndex, isLast: isLast, start: start)
    case .member:
      var set: [Cand] = []
      let member = unit.hash(Int(step.token))
      for (index, cand) in previous.enumerated() {
        let found = memberCandidates(of: cand.ty, name: member, from: unitIndex, prev: Int32(index))
        if found.isEmpty {
          set.append(Cand(site: nil, ty: .unknown, prev: Int32(index)))
        } else {
          set.append(contentsOf: found)
        }
      }
      let strict = applyCall(set, step: step, unitIndex: unitIndex, strict: true)
      let applied = strict.isEmpty ? applyCall(set, step: step, unitIndex: unitIndex, strict: false) : strict
      return finishStep(applied, step: step, unitIndex: unitIndex, isLast: isLast, start: start)
    }
    return applyPostOps(result, step: step, unitIndex: unitIndex, tierOnly: true)
  }

  /// With several left at the end of a chain, what the context asks for decides: this is how a return type picks an overload.
  private func finishStep(_ set: [Cand], step: Step, unitIndex: Int32, isLast: Bool, start: Int32) -> [Cand] {
    var result = set
    if isLast, Set(result.compactMap(\.site)).count > 1, let wanted = expectedType(unitIndex: unitIndex, start: start) {
      let filtered = result.filter { isCompatible($0.ty, with: wanted) != false }
      if !filtered.isEmpty { result = filtered }
    }
    return result
  }

  private func arrayLiteral(unitIndex: Int32, open: Int, close: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    guard close > open + 1 else { return standard(Word.array, [.unknown]) }
    // `[:]` and `[k: v]` make dictionaries.
    var i = open + 1
    let items = splitArguments(unit, open: open, close: close)
    guard let first = items.first else { return standard(Word.array, [.unknown]) }
    while i < close {
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.isByte(i, 0x2C) { break }
      if unit.isByte(i, 0x3A) {
        if close == open + 2 { return standard(Word.dictionary, [.unknown, .unknown]) }
        let key = evaluateExpression(unitIndex: unitIndex, start: first.start, end: i)
        var end = i + 1
        while end < close, !unit.isByte(end, 0x2C) {
          if unit.tokens[end].kind == .open { end = unit.skipBalanced(end) } else { end += 1 }
        }
        return standard(Word.dictionary, [key, evaluateExpression(unitIndex: unitIndex, start: i + 1, end: end)])
      }
      i += 1
    }
    return standard(Word.array, [evaluateExpression(unitIndex: unitIndex, start: first.start, end: first.end)])
  }

  /// Names at a chain's head, in tiers: the first tier with a match shadows those after it.
  private func headCandidates(unitIndex: Int32, step: Step) -> [[Cand]] {
    // `\.index` names a member of a root this model doesn't infer, never anything in scope.
    let keyPathUnit = project.units[Int(unitIndex)]
    if step.token > 0, keyPathUnit.tokens[Int(step.token) - 1].kind != .interpolationOpen, keyPathUnit.string(Int(step.token) - 1).hasPrefix("\\") {
      // Unless what it's given to says the root: `[KeyPath<A, B>]`, `map(\.name)`.
      guard let roots = keyPathRoots(unitIndex: unitIndex, slash: step.token - 1) else { return [] }
      let found = roots.flatMap { memberCandidates(of: $0, name: keyPathUnit.hash(Int(step.token)), from: unitIndex, prev: -1) }
      return found.isEmpty ? [] : [found]
    }
    let unit = project.units[Int(unitIndex)]
    let token = step.token
    var nameHash = unit.hash(Int(token))
    if unit.tokens[Int(token)].kind == .directive {
      let macro = hashName(String(unit.string(Int(token)).dropFirst()))
      var found: [Cand] = []
      for moduleName in project.visibleModules(of: unitIndex) {
        // `@_documentation(visibility: private)`: overloads there to catch mistakes, not to be chosen.
        found.append(contentsOf: (project.modules[moduleName]?.top[macro] ?? []).filter { accessible($0, from: unitIndex) && !isDocumentationHidden($0) }.map { Cand(site: .decl($0), ty: valueType(of: $0, receiver: nil)) })
      }
      return found.isEmpty ? [] : [found]
    }
    let scopes = chain(at: token, unitIndex: unitIndex)
    if nameHash == Word.selfValue || nameHash == Word.selfType {
      guard let own = selfType(unitIndex: unitIndex, scope: scopes) else { return [[Cand(site: nil, ty: .unknown)]] }
      // `self` is the method's implicit parameter, `Self` the type.
      if nameHash == Word.selfType, case .nominal(let ref, _) = own { return [[Cand(site: .decl(ref), ty: .meta(own))]] }
      if let method = scopes.last(where: { !unit.decls[Int($0)].kind.hasMembers }) {
        return [[Cand(site: .decl(DeclRef(unit: unitIndex, decl: method)), ty: own)]]
      }
      return [[Cand(site: nil, ty: own)]]
    }
    if nameHash == Word.superValue {
      if let own = selfType(unitIndex: unitIndex, scope: scopes), case .nominal(let ref, _) = own {
        _ = memberTable(of: ref)
        for base in inheritedTypes[ref] ?? [] {
          if case .nominal(let up, _) = base, decl(up).kind == .classType { return [[Cand(site: nil, ty: base, receiver: own, prev: -1)]] }
        }
      }
      return [[Cand(site: nil, ty: .unknown)]]
    }
    if nameHash == Word.initName {
      guard let own = selfType(unitIndex: unitIndex, scope: scopes) else { return [[]] }
      return [memberCandidates(of: .meta(own), name: Word.initName, from: unitIndex, prev: -1)]
    }
    var isProjection = false
    // `$0`: the closure around it, a position at a time.
    let text = unit.tokens[Int(token)].length > 1 && unit.source.text[unit.tokens[Int(token)].start] == 0x24 ? unit.string(Int(token)) : ""
    if !text.isEmpty {
      let digits = text.dropFirst()
      if let slot = Int(digits) {
        for scan in scans(unitIndex: unitIndex, token: token) {
          if let closure = scan.innermostClosure(at: token, needsUnnamed: true) {
            let ty = closureParameter(unitIndex: unitIndex, open: closure.open, index: Int32(slot))
            return [[Cand(site: nil, ty: ty)]]
          }
        }
        return [[Cand(site: nil, ty: .unknown)]]
      }
      // A property wrapper's projection: the property it's from.
      nameHash = hashName(String(digits))
      isProjection = true
    }
    let tiers = namedTiers(unitIndex: unitIndex, step: step, nameHash: nameHash, text: text, scopes: scopes)
    guard isProjection else { return tiers }
    // What a site says stays the property; what it gives is the wrapper's `projectedValue`.
    return tiers.map { tier in
      tier.map { cand in
        var projected: Ty?
        switch cand.site {
        case .decl(let ref)?: projected = projectedType(of: ref, receiver: cand.receiver)
        case .local(let owner, let at)?: projected = projectedType(ofLocal: at, unitIndex: owner, value: cand.ty)
        default: break
        }
        guard let projected else { return cand }
        var next = cand
        next.ty = projected
        return next
      }
    }
  }

  /// The roots a key path at this token could have, from what's asked of it there.
  func keyPathRoots(unitIndex: Int32, slash: Int32) -> [Ty]? {
    expectedAlternatives = []
    let single = expectedType(unitIndex: unitIndex, start: slash)
    var roots: [Ty] = []
    for wanted in single.map({ [$0] }) ?? expectedAlternatives {
      var base = wanted
      while case .optional(let inner) = base { base = inner }
      switch base {
      case .nominal(_, let args) where !args.isEmpty && args[0] != .unknown:
        if case .nominal(let ref, _) = base, unit(ref).isInterface, unit(ref).string(Int(decl(ref).nameToken)).hasSuffix("KeyPath") { roots.append(args[0]) }
      case .function(let params, _) where !params.isEmpty && params[0] != .unknown:
        roots.append(params[0])
      default:
        break
      }
    }
    return roots.isEmpty ? nil : roots
  }

  private func namedTiers(unitIndex: Int32, step: Step, nameHash: Name, text: String, scopes: [Int32]) -> [[Cand]] {
    let unit = project.units[Int(unitIndex)]
    let token = step.token
    var tiers: [[Cand]] = []
    for scan in scans(unitIndex: unitIndex, token: token) {
      if let index = scan.local(named: nameHash, at: token) {
        let local = scan.locals[Int(index)]
        if case .declaration(let declIndex) = local.kind {
          let ref = DeclRef(unit: unitIndex, decl: declIndex)
          return [[Cand(site: .decl(ref), ty: valueType(of: ref, receiver: nil))]]
        }
        let ty = localType(scan: scan, index: index, unitIndex: unitIndex)
        return [[Cand(site: local.hasSite ? .local(unit: unitIndex, token: local.token) : nil, ty: ty)]]
      }
    }
    for index in scopes.reversed() {
      let owner = unit.decls[Int(index)]
      let ref = DeclRef(unit: unitIndex, decl: index)
      for g in 0..<Int(owner.genericCount) where unit.generics[Int(owner.genericStart) + g].name == nameHash {
        tiers.append([Cand(site: .generic(unit: unitIndex, token: unit.generics[Int(owner.genericStart) + g].token), ty: .meta(.param(nameHash, ref)))])
      }
      guard owner.kind.hasMembers, let target = nominal(forMembersOf: ref) else { continue }
      let item = decl(target)
      let holder = self.unit(target)
      for g in 0..<Int(item.genericCount) where holder.generics[Int(item.genericStart) + g].name == nameHash {
        tiers.append([Cand(site: .generic(unit: target.unit, token: holder.generics[Int(item.genericStart) + g].token), ty: .meta(.param(nameHash, target)))])
      }
      let own = selfNominal(target)
      var tier: [Cand] = []
      for member in memberTable(of: target)[nameHash] ?? [] where accessible(member, from: unitIndex) {
        tier.append(Cand(site: .decl(member), ty: valueType(of: member, receiver: own), receiver: own))
      }
      if !tier.isEmpty { tiers.append(tier) }
    }
    let visible = project.visibleModules(of: unitIndex)
    var imported: [Cand] = []
    for (position, moduleName) in visible.enumerated() {
      guard let module = project.modules[moduleName], let list = module.top[nameHash] else { continue }
      let tier = list.filter { accessible($0, from: unitIndex) }.map { Cand(site: .decl($0), ty: valueType(of: $0, receiver: nil)) }
      if position == 0 {
        if !tier.isEmpty { tiers.append(tier) }
      } else {
        imported.append(contentsOf: tier)
      }
    }
    if !imported.isEmpty { tiers.append(imported) }
    if let module = project.modules[nameHash] { tiers.append([Cand(site: .module(module.name), ty: .module(module.name))]) }
    if tiers.isEmpty {
      let hidden = project.implicitlyExported(nameHash).filter { accessible($0, from: unitIndex) }
      if !hidden.isEmpty { tiers.append(hidden.map { Cand(site: .decl($0), ty: valueType(of: $0, receiver: nil)) }) }
    }
    if let ghost = phantom(for: nameHash) { tiers.append([Cand(site: .decl(ghost), ty: .meta(.nominal(ghost, [])))]) }
    if tiers.isEmpty || phantoms[nameHash] != nil { noteMiss(unitIndex) }
    if tiers.isEmpty, text.isEmpty, unit.tokens[Int(token)].length > 1, unit.source.text[unit.tokens[Int(token)].start] == 0x5F {
      // `_x` is the storage of a wrapped `x`.
      return headCandidatesStripped(unitIndex: unitIndex, step: step)
    }
    return tiers
  }

  /// `@_disfavoredOverload`: chosen only when nothing else fits.
  func isDisfavored(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    let owner = unit(ref)
    guard owner.isInterface else { return false }
    var i = Int(item.first)
    while i < Int(item.nameToken) {
      if owner.isToken(i, "@_disfavoredOverload") { return true }
      i += 1
    }
    return false
  }

  private func isDocumentationHidden(_ ref: DeclRef) -> Bool {
    let item = decl(ref)
    let owner = unit(ref)
    var i = Int(item.first)
    while i < Int(item.nameToken) {
      if owner.isToken(i, "@_documentation") { return true }
      i += 1
    }
    return false
  }

  /// The property wrapper written on a property, as its type: `@Binding var a: T` gives `Binding<T>`.
  private func wrapperType(of ref: DeclRef, receiver: Ty?) -> Ty? {
    let item = decl(ref)
    guard item.kind == .variable else { return nil }
    let owner = unit(ref)
    var i = Int(item.first)
    var scope = parents(of: ref)
    scope.append(ref.decl)
    while i < Int(item.nameToken) {
      defer { i += 1 }
      guard owner.tokens[i].kind == .attribute else { continue }
      let text = String(owner.string(i).dropFirst())
      let wrapper = lookupType(hashName(text), unitIndex: ref.unit, token: Int32(i), scope: scope, args: [])
      guard case .nominal(let found, _) = wrapper, memberTable(of: found)[hashName("wrappedValue")] != nil else { continue }
      // Its first parameter is the property's type.
      let written = substitute(variableType(ref), receiver: receiver)
      return .nominal(found, genericNames(of: found).isEmpty ? [] : [written])
    }
    return nil
  }

  private func projectedType(of ref: DeclRef, receiver: Ty?) -> Ty? {
    guard let wrapper = wrapperType(of: ref, receiver: receiver) else { return nil }
    return projectedValue(of: wrapper)
  }

  private func projectedValue(of wrapper: Ty) -> Ty? {
    guard case .nominal(let found, _) = wrapper, let projected = memberTable(of: found)[hashName("projectedValue")]?.first else { return nil }
    return valueType(of: projected, receiver: wrapper)
  }

  /// `@Bindable var model = model` in a body: the attributes just before its `var`, the first that's a wrapper.
  private func projectedType(ofLocal token: Int32, unitIndex: Int32, value: Ty) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    var k = Int(token) - 1
    guard k > 0, unit.isToken(k, "var") || unit.isToken(k, "let") else { return nil }
    k -= 1
    let scope = chain(at: token, unitIndex: unitIndex)
    while k >= 0 {
      // `@State(initialValue: 1)`: its arguments, back to the attribute.
      if unit.tokens[k].kind == .close {
        var open = k - 1
        while open >= 0, !(unit.tokens[open].kind == .open && unit.skipBalanced(open) == k + 1) { open -= 1 }
        k = open - 1
        continue
      }
      guard unit.tokens[k].kind == .attribute else { return nil }
      let wrapper = lookupType(hashName(String(unit.string(k).dropFirst())), unitIndex: unitIndex, token: Int32(k), scope: scope, args: [])
      if case .nominal(let found, _) = wrapper, memberTable(of: found)[hashName("wrappedValue")] != nil {
        return projectedValue(of: .nominal(found, genericNames(of: found).isEmpty ? [] : [value]))
      }
      k -= 1
    }
    return nil
  }

  /// A struct's stored properties when it declares no initializer: its memberwise one's parameters.
  func memberwiseProperties(of ref: DeclRef) -> [DeclRef]? {
    let item = decl(ref)
    guard item.kind == .structure else { return nil }
    let owner = unit(ref)
    var found: [DeclRef] = []
    for child in owner.children(of: ref.decl) {
      let entry = owner.decls[Int(child)]
      if entry.kind == .initializer { return nil }
      guard entry.kind == .variable, !entry.isStatic, !entry.isLocal else { continue }
      // With a getter it's computed; observers leave it stored.
      if entry.bodyOpen >= 0, !owner.isToken(Int(entry.bodyOpen) + 1, "didSet"), !owner.isToken(Int(entry.bodyOpen) + 1, "willSet") { continue }
      if isConstantWithValue(owner, entry) { continue }
      found.append(DeclRef(unit: ref.unit, decl: child))
    }
    return found
  }

  /// `let a = 1` isn't a parameter of the memberwise initializer.
  private func isConstantWithValue(_ owner: Unit, _ entry: Decl) -> Bool {
    guard entry.initStart >= 0 else { return false }
    var i = Int(entry.nameToken) - 1
    while i >= Int(entry.first) {
      if owner.isToken(i, "let") { return true }
      if owner.isToken(i, "var") { return false }
      i -= 1
    }
    return false
  }

  private func headCandidatesStripped(unitIndex: Int32, step: Step) -> [[Cand]] {
    let unit = project.units[Int(unitIndex)]
    let stripped = hashName(String(unit.string(Int(step.token)).dropFirst()))
    let scopes = chain(at: step.token, unitIndex: unitIndex)
    for index in scopes.reversed() {
      let ref = DeclRef(unit: unitIndex, decl: index)
      guard unit.decls[Int(index)].kind.hasMembers, let target = nominal(forMembersOf: ref) else { continue }
      let found = (memberTable(of: target)[stripped] ?? []).filter { decl($0).kind == .variable }
      if !found.isEmpty { return [found.map { Cand(site: .decl($0), ty: .unknown) }] }
    }
    return []
  }

  private func selfType(unitIndex: Int32, scope: [Int32]) -> Ty? {
    for index in scope.reversed() {
      let ref = DeclRef(unit: unitIndex, decl: index)
      guard project.units[Int(unitIndex)].decls[Int(index)].kind.hasMembers, let target = nominal(forMembersOf: ref) else { continue }
      return selfNominal(target)
    }
    return nil
  }

  /// A declaration as a value: a variable's type, a function's signature, a type's metatype.
  func valueType(of ref: DeclRef, receiver: Ty?) -> Ty {
    let item = decl(ref)
    switch item.kind {
    case .variable:
      return substitute(variableType(ref), receiver: receiver)
    case .function, .macro:
      var scope = parents(of: ref)
      scope.append(ref.decl)
      let owner = unit(ref)
      let params = (0..<Int(item.paramCount)).map { p -> Ty in
        let param = owner.params[Int(item.paramStart) + p]
        return parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: scope)
      }
      return substitute(.function(params, returnType(ref)), receiver: receiver)
    case .enumCase:
      guard let instance = receiver else { return .unknown }
      var base = instance
      if case .meta(let inner) = base { base = inner }
      if item.paramCount == 0 { return base }
      return .function([], base)
    case .structure, .classType, .actor, .enumeration, .protocolType, .typeAlias, .associatedType, .extensionDecl:
      return .meta(substitute(typeOfTypeDecl(ref, args: []), receiver: receiver))
    default:
      return .unknown
    }
  }

  func returnType(_ ref: DeclRef) -> Ty {
    let item = decl(ref)
    guard item.typeStart >= 0 else { return .tuple([], []) }
    var scope = parents(of: ref)
    scope.append(ref.decl)
    return parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: scope)
  }

  /// A property's type: as written, or what its initializer gives, once, with a cycle meaning unknown.
  func variableType(_ ref: DeclRef) -> Ty {
    if let known = typeMemo[ref] { return known }
    guard resolving.insert(ref).inserted else { return .unknown }
    defer { resolving.remove(ref) }
    let item = decl(ref)
    var ty = Ty.unknown
    if item.typeStart >= 0 {
      var scope = parents(of: ref)
      scope.append(ref.decl)
      ty = parseType(unitIndex: ref.unit, start: item.typeStart, end: item.typeEnd, scope: scope)
    } else if item.initStart >= 0 {
      ty = evaluateExpression(unitIndex: ref.unit, start: Int(item.initStart), end: Int(item.initEnd))
    } else if let told = typeFromWrapperArgument(ref) {
      ty = told
    }
    if cycleBase >= depth { typeMemo[ref] = ty }
    return ty
  }

  /// `@Environment(Workspace.self) var a` and `@Environment(\\.dismiss) var b`: the wrapper's argument says the type.
  private func typeFromWrapperArgument(_ ref: DeclRef) -> Ty? {
    let item = decl(ref)
    guard item.kind == .variable else { return nil }
    let owner = unit(ref)
    var scope = parents(of: ref)
    scope.append(ref.decl)
    var i = Int(item.first)
    while i < Int(item.nameToken) {
      defer { i += 1 }
      guard owner.tokens[i].kind == .attribute, owner.isByte(i + 1, 0x28) else { continue }
      let close = owner.skipBalanced(i + 1) - 1
      guard close > i + 2 else { continue }
      if owner.isToken(close - 1, "self"), owner.isByte(close - 2, 0x2E) {
        return parseType(unitIndex: ref.unit, start: Int32(i + 2), end: Int32(close - 2), scope: scope)
      }
      // A key path's root is the wrapper's own: only these two take one without saying.
      guard owner.string(i + 2).hasPrefix("\\") else { continue }
      // `\.name` is one token or two, then the name.
      var nameAt = i + 3
      if owner.isByte(nameAt, 0x2E) { nameAt += 1 }
      guard nameAt < close else { continue }
      let wrapper = owner.string(i)
      let isFocused = wrapper == "@FocusedValue" || wrapper == "@FocusedBinding"
      guard isFocused || wrapper == "@Environment" else { continue }
      let root = lookupType(hashName(isFocused ? "FocusedValues" : "EnvironmentValues"), unitIndex: ref.unit, token: Int32(i), scope: scope, args: [])
      guard case .nominal = root, let found = memberCandidates(of: root, name: owner.hash(nameAt), from: ref.unit, prev: -1).first else { continue }
      if isFocused, case .optional = found.ty { return found.ty }
      return isFocused ? .optional(found.ty) : found.ty
    }
    return nil
  }

  func localType(scan: BodyScan, index: Int32, unitIndex: Int32) -> Ty {
    if let known = scan.types[index] { return known }
    guard scan.resolving.insert(index).inserted else { return .unknown }
    defer { scan.resolving.remove(index) }
    let local = scan.locals[Int(index)]
    let unit = project.units[Int(unitIndex)]
    var ty = Ty.unknown
    switch local.kind {
    case .written(let start, let end):
      ty = parseType(unitIndex: unitIndex, start: start, end: end, scope: chain(at: max(local.token, start), unitIndex: unitIndex))
    case .initializer(let start, let end, let unwrap):
      ty = evaluateExpression(unitIndex: unitIndex, start: Int(start), end: Int(end))
      if unwrap, case .optional(let wrapped) = ty { ty = wrapped }
    case .forIn(let start, let end, let slot):
      let sequence = evaluateExpression(unitIndex: unitIndex, start: Int(start), end: Int(end))
      ty = elementType(of: sequence)
      if slot >= 0 {
        if case .tuple(let items, _) = ty, Int(slot) < items.count { ty = items[Int(slot)] } else { ty = .unknown }
      }
    case .tupleSlot(let start, let end, let slot):
      if case .tuple(let items, _) = evaluateExpression(unitIndex: unitIndex, start: Int(start), end: Int(end)), Int(slot) < items.count {
        ty = items[Int(slot)]
      }
    case .closureParam(let open, let slot):
      ty = closureParameter(unitIndex: unitIndex, open: open, index: slot)
    case .pattern(let caseToken, let slot, let start, let end):
      guard start >= 0 else { break }
      var subject = evaluateExpression(unitIndex: unitIndex, start: Int(start), end: Int(end))
      if case .optional(let wrapped) = subject { subject = wrapped }
      let found = memberCandidates(of: .meta(subject), name: unit.hash(Int(caseToken)), from: unitIndex, prev: -1)
      if found.count == 1, case .decl(let ref)? = found[0].site, decl(ref).kind == .enumCase, Int(slot) < Int(decl(ref).paramCount) {
        let holder = self.unit(ref)
        let param = holder.params[Int(decl(ref).paramStart) + Int(slot)]
        var scope = parents(of: ref)
        scope.append(ref.decl)
        ty = substitute(parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: scope), receiver: subject)
      }
    case .declaration(let declIndex):
      ty = valueType(of: DeclRef(unit: unitIndex, decl: declIndex), receiver: nil)
    case .unknown:
      break
    }
    if cycleBase >= depth { scan.types[index] = ty }
    return ty
  }

  private func elementType(of sequence: Ty) -> Ty {
    switch sequence {
    case .nominal(let ref, let args):
      let names = genericNames(of: ref)
      for (g, arg) in zip(names, args) where g == Word.element { return arg }
      if let alias = memberTable(of: ref)[Word.element]?.first(where: { decl($0).kind == .typeAlias }) {
        return substitute(typeOfTypeDecl(alias, args: []), receiver: sequence)
      }
      return .unknown
    case .optional(let wrapped):
      return elementType(of: wrapped)
    default:
      return .unknown
    }
  }

  /// Members of a type by name, with static and instance kept apart.
  func memberCandidates(of ty: Ty, name member: Name, from unitIndex: Int32, prev: Int32) -> [Cand] {
    var isStaticSide = false
    var base = ty
    if case .meta(let inner) = base {
      isStaticSide = true
      base = inner
    }
    switch base {
    case .module(let moduleName):
      guard let module = project.modules[moduleName] else { return [] }
      var list = module.top[member] ?? []
      if list.isEmpty {
        for unit in module.units {
          for item in project.units[Int(unit)].imports where item.isExported {
            list.append(contentsOf: project.ensureModule(item.module, display: item.moduleName)?.top[member] ?? [])
          }
        }
      }
      var found = list.filter { accessible($0, from: unitIndex) }.map { Cand(site: .decl($0), ty: valueType(of: $0, receiver: nil), prev: prev) }
      if found.isEmpty {
        noteMiss(unitIndex)
        if let ghost = phantom(for: member) { found = [Cand(site: .decl(ghost), ty: .meta(.nominal(ghost, [])), prev: prev)] }
      }
      return found
    case .optional(let wrapped):
      var found: [Cand] = []
      if let ref = standardRef(Word.optional) {
        found = memberCandidates(of: isStaticSide ? .meta(.nominal(ref, [wrapped])) : .nominal(ref, [wrapped]), name: member, from: unitIndex, prev: prev)
      }
      if found.isEmpty { found = memberCandidates(of: isStaticSide ? .meta(wrapped) : wrapped, name: member, from: unitIndex, prev: prev) }
      return found
    case .tuple(let items, let labels):
      // `a.name` of a tuple: it has no declaration to go to, but what follows has a type.
      for (item, label) in zip(items, labels) where label == member && label != 0 { return [Cand(site: nil, ty: item, prev: prev)] }
      return []
    case .existential(let items):
      return items.flatMap { memberCandidates(of: isStaticSide ? .meta($0) : $0, name: member, from: unitIndex, prev: prev) }
    case .param(let paramName, let owner):
      guard let owner else { return [] }
      return constraints(of: paramName, owner: owner).flatMap { memberCandidates(of: isStaticSide ? .meta($0) : $0, name: member, from: unitIndex, prev: prev) }
    case .nominal(let ref, _):
      let list = (memberTable(of: ref)[member] ?? []).filter { accessible($0, from: unitIndex) }
      // `binding.count` of a `Binding<String>`: String's `count`, through `subscript(dynamicMember:)`.
      if list.isEmpty, !isStaticSide {
        let dynamic = dynamicCandidates(of: base, name: member, from: unitIndex, prev: prev)
        if !dynamic.isEmpty { return dynamic }
      }
      // A project type's parents were asked for when its table was built; an SDK type may have more in its headers.
      if list.isEmpty, unit(ref).isInterface { noteMiss(unitIndex) }
      // `string` of a text view: a protocol's requirement answers only until AppKit's headers give the class its own.
      if !list.isEmpty, decl(ref).kind == .classType, hasUnreadParent(ref), list.allSatisfy({ isFromProtocol($0) }) {
        noteMiss(unitIndex)
        protocolOverHeaders = true
      }
      let side = list.filter { item in
        let entry = decl(item)
        if isStaticSide { return entry.isStatic || entry.kind == .initializer || entry.kind.isType || entry.kind == .enumCase }
        return !entry.isStatic && !entry.kind.isType && entry.kind != .enumCase
      }
      var chosen = side.isEmpty && isStaticSide ? list : side
      // `map` of an array isn't the one for `Self: Iterable`: what this receiver can't have goes, unless that's all of it.
      if chosen.count > 1 {
        let holding = chosen.filter { requirementsHold($0, holder: ref, receiver: base) }
        if !holding.isEmpty { chosen = holding }
      }
      return chosen.map { Cand(site: .decl($0), ty: valueType(of: $0, receiver: base), receiver: base, prev: prev) }
    default:
      return []
    }
  }

  private func dynamicCandidates(of ty: Ty, name member: Name, from unitIndex: Int32, prev: Int32) -> [Cand] {
    guard dynamicDepth < 3 else { return [] }
    dynamicDepth += 1
    defer { dynamicDepth -= 1 }
    var found: [Cand] = []
    for lookup in dynamicLookups(of: ty) {
      for cand in memberCandidates(of: lookup.root, name: member, from: unitIndex, prev: prev) {
        // A key path names a property or a subscript, never a method.
        if case .decl(let ref) = cand.site, decl(ref).kind != .variable { continue }
        var through = cand
        through.ty = dynamicResult(lookup, memberType: cand.ty)
        found.append(through)
      }
    }
    return found
  }

  private func isFromProtocol(_ member: DeclRef) -> Bool {
    let parent = decl(member).parent
    guard parent >= 0, let holder = nominal(forMembersOf: DeclRef(unit: member.unit, decl: parent)) else { return false }
    return decl(holder).kind == .protocolType
  }

  /// A class whose parents are unknown so far, or known only from a Swift interface or by extensions.
  private func hasUnreadParent(_ ref: DeclRef, depth: Int = 0) -> Bool {
    guard depth < 16 else { return false }
    _ = memberTable(of: ref)
    for base in inheritedTypes[ref] ?? [] {
      switch base {
      case .unknown:
        return true
      case .nominal(let parent, _):
        let kind = decl(parent).kind
        if kind == .extensionDecl || (kind == .classType && unit(parent).isInterface) { return true }
        if kind == .classType, hasUnreadParent(parent, depth: depth + 1) { return true }
      default:
        break
      }
    }
    return false
  }

  func constraints(of paramName: Name, owner: DeclRef) -> [Ty] {
    let item = decl(owner)
    let holder = unit(owner)
    var scope = parents(of: owner)
    scope.append(owner.decl)
    for g in 0..<Int(item.genericCount) where holder.generics[Int(item.genericStart) + g].name == paramName {
      let at = Int(holder.generics[Int(item.genericStart) + g].token)
      guard holder.isByte(at + 1, 0x3A) else { return [] }
      let end = DeclParser(unit: holder).skipType(at + 2)
      return [parseType(unitIndex: owner.unit, start: Int32(at + 2), end: Int32(end), scope: scope)]
    }
    return []
  }

  // MARK: Calls

  struct Argument {
    var label: Name
    var start: Int
    var end: Int
  }

  func splitArguments(_ unit: Unit, open: Int, close: Int) -> [Argument] {
    var result: [Argument] = []
    var i = open + 1
    while i < close {
      var label: Name = 0
      var start = i
      if unit.isByte(i + 1, 0x3A), unit.tokens[i].kind == .identifier || unit.tokens[i].kind == .keyword || unit.tokens[i].kind == .declarationKeyword {
        label = unit.hash(i)
        start = i + 2
      }
      var j = start
      while j < close, !unit.isByte(j, 0x2C) {
        if unit.tokens[j].kind == .open || unit.tokens[j].kind == .interpolationOpen { j = unit.skipBalanced(j) } else { j += 1 }
      }
      result.append(Argument(label: label, start: start, end: j))
      i = j + 1
    }
    return result
  }

  private func matches(_ ref: DeclRef, arguments: [Argument], trailing: Int) -> Bool {
    let item = decl(ref)
    let holder = unit(ref)
    var p = 0
    let count = Int(item.paramCount)
    for argument in arguments {
      var taken = false
      while p < count {
        let param = holder.params[Int(item.paramStart) + p]
        let label = param.label == Word.underscore ? 0 : param.label
        if label == argument.label {
          taken = true
          if !param.variadic { p += 1 }
          break
        }
        if param.hasDefault || param.variadic {
          p += 1
          continue
        }
        return false
      }
      if !taken { return false }
    }
    var left = 0
    while p < count {
      let param = holder.params[Int(item.paramStart) + p]
      if !param.hasDefault, !param.variadic { left += 1 }
      p += 1
    }
    return left <= trailing
  }

  /// Applies a step's first call to a set: an overload whose labels and arguments can't fit goes.
  private func applyCall(_ set: [Cand], step: Step, unitIndex: Int32, strict: Bool) -> [Cand] {
    let unit = project.units[Int(unitIndex)]
    guard let opIndex = step.ops.firstIndex(where: { if case .call = $0 { return true } else { return false } }), opIndex == 0 else {
      // Not called: `count` is the property, not `count(where:)`.
      let values = set.filter {
        guard case .decl(let ref)? = $0.site else { return true }
        return !decl(ref).kind.isCallable
      }
      return applyPostOps(values.isEmpty ? set : values, step: step, unitIndex: unitIndex, tierOnly: false)
    }
    guard case .call(let open, let trailing) = step.ops[0] else { return set }
    var arguments: [Argument] = []
    if open >= 0 { arguments = splitArguments(unit, open: Int(open), close: unit.skipBalanced(Int(open)) - 1) }
    let trailingCount = trailing >= 0 ? 1 : 0
    var result: [Cand] = []
    for cand in set {
      guard case .decl(let ref)? = cand.site else {
        var next = cand
        next.ty = resultOfCalling(cand.ty, unitIndex: unitIndex)
        result.append(next)
        continue
      }
      let item = decl(ref)
      if item.kind.isCallable {
        if matches(ref, arguments: arguments, trailing: trailingCount + 4 * (trailingCount > 0 ? 1 : 0)) || !strict {
          var next = cand
          next.ty = callResult(ref, receiver: cand.receiver, arguments: arguments, trailing: trailing, unitIndex: unitIndex)
          result.append(next)
        }
      } else if item.kind == .enumCase {
        if matches(ref, arguments: arguments, trailing: trailingCount) || !strict {
          var next = cand
          var instance = cand.receiver ?? .unknown
          if case .meta(let inner) = instance { instance = inner }
          next.ty = instance
          result.append(next)
        }
      } else if case .meta(let instance) = cand.ty {
        // A type being called: its initializers, then itself for the memberwise one.
        let inits = memberCandidates(of: .meta(instance), name: Word.initName, from: unitIndex, prev: cand.prev)
        let fitting = inits.filter { found in
          guard case .decl(let initRef)? = found.site else { return false }
          return matches(initRef, arguments: arguments, trailing: trailingCount)
        }
        let narrowed = narrowByArguments(fitting, arguments: arguments, unitIndex: unitIndex)
        if narrowed.isEmpty {
          var next = cand
          next.ty = instance
          result.append(next)
        } else {
          for found in narrowed {
            var next = found
            next.extra = cand.site
            var failable = false
            if case .decl(let initRef)? = found.site { failable = decl(initRef).isFailable }
            next.ty = failable ? .optional(instance) : instance
            result.append(next)
          }
        }
      } else {
        var next = cand
        next.ty = resultOfCalling(cand.ty, unitIndex: unitIndex)
        result.append(next)
      }
    }
    if strict, !result.isEmpty { result = narrowByArguments(result, arguments: arguments, unitIndex: unitIndex) }
    // `flatMap` returning a `String?` is deprecated for `compactMap`: what's still current is what's meant.
    if result.count > 1 {
      // `selectedRange()` where a class has both the property and the method.
      let callable = result.filter { cand in
        guard case .decl(let ref)? = cand.site, decl(ref).kind == .variable else { return true }
        return cand.ty != .unknown
      }
      if !callable.isEmpty { result = callable }
      let current = result.filter { cand in
        guard case .decl(let ref)? = cand.site else { return true }
        return !isDeprecated(ref)
      }
      if !current.isEmpty { result = current }
      let favored = result.filter { cand in
        guard case .decl(let ref)? = cand.site else { return true }
        return !isDisfavored(ref)
      }
      if !favored.isEmpty { result = favored }
    }
    if trailing >= 0, result.count > 1 { result = narrowByTrailingClosure(result) }
    var rest = step
    rest.ops.removeFirst()
    return applyPostOps(result, step: rest, unitIndex: unitIndex, tierOnly: false)
  }

  /// Overloads with the same labels: an argument whose type can't go in that parameter rules one out.
  private func narrowByArguments(_ set: [Cand], arguments: [Argument], unitIndex: Int32) -> [Cand] {
    guard set.count > 1, !arguments.isEmpty else { return set }
    let types = arguments.map { evaluateExpression(unitIndex: unitIndex, start: $0.start, end: $0.end) }
    var takesItself: [Int] = []
    let filtered = set.enumerated().filter { index, cand in
      guard case .decl(let ref)? = cand.site else { return true }
      let item = decl(ref)
      guard item.kind.isCallable else { return true }
      let holder = unit(ref)
      var scope = parents(of: ref)
      scope.append(ref.decl)
      var p = 0
      var all = true
      for (argument, ty) in zip(arguments, types) {
        while p < Int(item.paramCount) {
          let param = holder.params[Int(item.paramStart) + p]
          let label = param.label == Word.underscore ? 0 : param.label
          if label == argument.label {
            // Only the standard library can name the compiler's own types.
            if holder.isToken(Int(param.typeStart), "Builtin") { return false }
            let wanted = substitute(parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: scope), receiver: cand.receiver)
            let fits = isCompatible(ty, with: wanted)
            if fits == false { return false }
            if fits != true { all = false }
            if case .param(let name, let owner) = wanted, owner == ref, fitsConstraint(ty, generic: name, of: ref, scope: scope) == false { return false }
            if !param.variadic { p += 1 }
            break
          }
          p += 1
        }
      }
      if all { takesItself.append(index) }
      return true
    }.map(\.element)
    // Swift ranks an overload that takes the type itself above a generic one.
    if !takesItself.isEmpty, takesItself.count < filtered.count {
      let best = takesItself.map { set[$0] }
      // A member of the type itself ranks above any protocol's.
      if best.allSatisfy(isProtocolMember), !filtered.allSatisfy(isProtocolMember) { return filtered }
      return best
    }
    return filtered.isEmpty ? set : filtered
  }

  private func isProtocolMember(_ cand: Cand) -> Bool {
    guard case .decl(let ref)? = cand.site, decl(ref).parent >= 0 else { return false }
    let owner = DeclRef(unit: ref.unit, decl: decl(ref).parent)
    return decl(nominal(forMembersOf: owner) ?? owner).kind == .protocolType
  }

  /// A value against what a function's own generic parameter asks for: `<S: StringProtocol>` or `where S : StringProtocol`.
  private func fitsConstraint(_ value: Ty, generic name: Name, of ref: DeclRef, scope: [Int32]) -> Bool? {
    let item = decl(ref)
    let holder = unit(ref)
    var i = Int(item.nameToken) + 1
    let end = Int(item.bodyOpen >= 0 ? item.bodyOpen : item.end)
    while i < end {
      if holder.tokens[i].kind == .identifier, holder.hash(i) == name, holder.isByte(i + 1, 0x3A) {
        var stop = i + 2
        while stop < end, !holder.isByte(stop, 0x2C), !holder.isToken(stop, "where"), holder.tokens[stop].kind != .open,
          holder.tokens[stop].kind != .close, !holder.isByte(stop, 0x3E), !holder.isToken(stop, "<") { stop += 1 }
        // A generic constraint (`Collection<Int>`) is more than this needs to look at.
        guard stop > i + 2, !holder.isToken(stop, "<") else { return nil }
        let constraint = parseType(unitIndex: ref.unit, start: Int32(i + 2), end: Int32(stop), scope: scope)
        if isCompatible(value, with: constraint) == false { return false }
      }
      if holder.tokens[i].kind == .open, holder.isByte(i, 0x28) { i = holder.skipBalanced(i) } else { i += 1 }
    }
    return nil
  }

  /// A trailing closure goes in a parameter of function type: `filter(_: Predicate<Element>)` can't take one.
  private func narrowByTrailingClosure(_ set: [Cand]) -> [Cand] {
    let filtered = set.filter { cand in
      guard case .decl(let ref)? = cand.site, decl(ref).kind.isCallable, decl(ref).paramCount > 0 else { return true }
      let item = decl(ref)
      let holder = unit(ref)
      let param = holder.params[Int(item.paramStart + item.paramCount) - 1]
      var scope = parents(of: ref)
      scope.append(ref.decl)
      var ty = parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: scope)
      if case .optional(let inner) = ty { ty = inner }
      if case .nominal = ty { return false }
      return true
    }
    return filtered.isEmpty ? set : filtered
  }

  private func resultOfCalling(_ ty: Ty, unitIndex: Int32) -> Ty {
    switch ty {
    case .function(_, let result): return result
    case .meta(let instance): return instance
    case .optional(.function(_, let result)): return .optional(result)
    default: return .unknown
    }
  }

  /// What a call gives, with its own generic parameters bound from its arguments where they can be read.
  private func callResult(_ ref: DeclRef, receiver: Ty?, arguments: [Argument], trailing: Int32, unitIndex: Int32) -> Ty {
    let item = decl(ref)
    if item.kind == .initializer {
      var instance = receiver ?? .unknown
      if case .meta(let inner) = instance { instance = inner }
      return item.isFailable ? .optional(instance) : instance
    }
    let raw = returnType(ref)
    let result = substitute(raw, receiver: receiver)
    guard item.genericCount > 0, noBinding == 0, mentionsParam(result) else { return result }
    let holder = unit(ref)
    var scope = parents(of: ref)
    scope.append(ref.decl)
    var bound: [Name: Ty] = [:]
    let unit = project.units[Int(unitIndex)]
    var p = 0
    func parameterType(_ at: Int) -> Ty {
      let param = holder.params[Int(item.paramStart) + at]
      return substitute(parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: scope), receiver: receiver)
    }
    for argument in arguments {
      while p < Int(item.paramCount) {
        let param = holder.params[Int(item.paramStart) + p]
        let label = param.label == Word.underscore ? 0 : param.label
        if label == argument.label { break }
        p += 1
      }
      guard p < Int(item.paramCount) else { break }
      let wanted = parameterType(p)
      if unit.isByte(argument.start, 0x7B) {
        bindClosure(wanted, open: argument.start, unitIndex: unitIndex, into: &bound)
      } else {
        var value = evaluateExpression(unitIndex: unitIndex, start: argument.start, end: argument.end)
        // `map(String.init)`: a type's initializer standing for a function that makes it.
        if case .function(_, let result) = wanted, mentionsParam(result), argument.end - argument.start >= 3, unit.isToken(argument.end - 1, "init"), unit.isByte(argument.end - 2, 0x2E) {
          let made = evaluate(unitIndex: unitIndex, start: Int32(argument.start), limit: Int32(argument.end - 2))
          if case .meta(let instance) = made.ty { bind(result, to: instance, into: &bound) }
          value = .unknown
        }
        bind(wanted, to: value, into: &bound)
      }
      p += 1
    }
    if trailing >= 0, item.paramCount > 0 {
      for at in stride(from: Int(item.paramCount) - 1, through: 0, by: -1) {
        let wanted = parameterType(at)
        if case .function = wanted {
          bindClosure(wanted, open: Int(trailing), unitIndex: unitIndex, into: &bound)
          break
        }
      }
    }
    var map: [Name: Ty] = [:]
    for g in 0..<Int(item.genericCount) {
      let generic = holder.generics[Int(item.genericStart) + g].name
      map[generic] = bound[generic] ?? .unknown
    }
    return substitute(result, map: map, receiver: nil)
  }

  private func mentionsParam(_ ty: Ty) -> Bool {
    switch ty {
    case .param: return true
    case .nominal(_, let args): return args.contains(where: mentionsParam)
    case .optional(let inner), .meta(let inner): return mentionsParam(inner)
    case .dependent: return true
    case .tuple(let items, _), .existential(let items): return items.contains(where: mentionsParam)
    case .function(let params, let result): return mentionsParam(result) || params.contains(where: mentionsParam)
    default: return false
    }
  }

  private func bind(_ wanted: Ty, to value: Ty, into bound: inout [Name: Ty]) {
    switch (wanted, value) {
    case (_, .unknown): return
    case (.param(let paramName, _), _):
      if bound[paramName] == nil { bound[paramName] = value }
    case (.dependent, _): return
    case (.optional(let a), .optional(let b)): bind(a, to: b, into: &bound)
    case (.optional(let a), _): bind(a, to: value, into: &bound)
    case (.nominal(let a, let left), .nominal(let b, let right)) where a == b:
      for (x, y) in zip(left, right) { bind(x, to: y, into: &bound) }
    case (.tuple(let left, _), .tuple(let right, _)):
      for (x, y) in zip(left, right) { bind(x, to: y, into: &bound) }
    default: return
    }
  }

  /// `{ $0.name }`: a closure of one expression gives the type its parameter's result stands for.
  private func bindClosure(_ wanted: Ty, open: Int, unitIndex: Int32, into bound: inout [Name: Ty]) {
    guard case .function(_, let result) = wanted, mentionsParam(result) else { return }
    let unit = project.units[Int(unitIndex)]
    let close = unit.skipBalanced(open) - 1
    var start = open + 1
    var scanOwner: BodyScan?
    for scan in scans(unitIndex: unitIndex, token: Int32(open)) where scan.closureOpens.contains(Int32(open)) { scanOwner = scan }
    if let info = scanOwner?.closures.first(where: { $0.open == Int32(open) }), info.hasNames {
      var i = start
      while i < close, !unit.isToken(i, "in") {
        if unit.tokens[i].kind == .open { i = unit.skipBalanced(i) } else { i += 1 }
      }
      start = i + 1
    }
    guard start < close else { return }
    let end = DeclParser(unit: unit).skipExpression(start)
    guard end >= close else { return }
    noBinding += 1
    let value = evaluateExpression(unitIndex: unitIndex, start: start, end: close)
    noBinding -= 1
    bind(result, to: value, into: &bound)
  }

  private func applyPostOps(_ set: [Cand], step: Step, unitIndex: Int32, tierOnly: Bool) -> [Cand] {
    guard !step.ops.isEmpty else { return set }
    let unit = project.units[Int(unitIndex)]
    var result: [Cand] = []
    for cand in set {
      var ty = cand.ty
      var alternatives: [Ty] = []
      for op in step.ops {
        switch op {
        case .unwrap:
          if case .optional(let wrapped) = ty { ty = wrapped }
        case .call:
          ty = resultOfCalling(ty, unitIndex: unitIndex)
        case .index(let open):
          let found = memberCandidates(of: ty, name: Word.subscriptName, from: unitIndex, prev: -1)
          let arguments = splitArguments(unit, open: Int(open), close: unit.skipBalanced(Int(open)) - 1)
          let labelled = found.filter {
            guard case .decl(let ref)? = $0.site else { return false }
            return matches(ref, arguments: arguments, trailing: 0)
          }
          let fitting = narrowByArguments(labelled.isEmpty ? found : labelled, arguments: arguments, unitIndex: unitIndex)
          let types = fitting.compactMap { found -> Ty? in
            guard case .decl(let ref)? = found.site else { return nil }
            return substitute(returnType(ref), receiver: found.receiver)
          }
          if let first = types.first, types.allSatisfy({ $0 == first }) {
            ty = first
          } else if types.count > 1 {
            alternatives = Array(Set(types.map(describe))).sorted().compactMap { text in types.first { describe($0) == text } }
            ty = alternatives[0]
          } else {
            ty = .unknown
          }
        }
      }
      var next = cand
      next.ty = ty
      result.append(next)
      // Overloads a subscript's argument can't choose between each go on: what follows may.
      for other in alternatives.dropFirst() {
        var more = cand
        more.ty = other
        result.append(more)
      }
    }
    return result
  }

  // MARK: Context

  /// The callee of a call by its open paren.
  func calleeCandidates(unitIndex: Int32, open: Int) -> [Cand] {
    let unit = project.units[Int(unitIndex)]
    guard open > 0 else { return [] }
    var end = open - 1
    if unit.isByte(end, 0x3E) {
      var level = 0
      while end >= 0 {
        if unit.isByte(end, 0x3E) { level += 1 }
        if unit.isToken(end, "<") {
          level -= 1
          if level == 0 { break }
        }
        end -= 1
      }
      end -= 1
    }
    guard end >= 0 else { return [] }
    let start = chainStart(unit, end)
    let result = evaluate(unitIndex: unitIndex, start: Int32(start))
    guard let at = result.steps.firstIndex(where: { $0.token == Int32(end) }) else { return [] }
    return result.sets[at]
  }

  /// Where a closure is passed: the closure's parameter types come from the function that takes it.
  private func closureParameter(unitIndex: Int32, open: Int32, index: Int32) -> Ty {
    let found = closureTypes(unitIndex: unitIndex, open: open).compactMap { ty -> Ty? in
      if case .function(let params, _) = ty, Int(index) < params.count { return params[Int(index)] }
      return nil
    }
    // An overload that leaves its parameter generic (`init<V>(_: Data, content: (V) -> Content)`) says nothing against those that know.
    let told = found.filter { $0 != .unknown && !mentionsParam($0) }
    if let first = told.first { return told.allSatisfy({ $0 == first }) ? first : .unknown }
    guard let first = found.first, found.allSatisfy({ $0 == first }) else { return .unknown }
    return first
  }

  /// The function types a closure is wanted as: its callee's parameter, or what's written for it.
  private func closureTypes(unitIndex: Int32, open: Int32) -> [Ty] {
    let unit = project.units[Int(unitIndex)]
    let at = Int(open)
    guard at > 0 else { return [] }
    var callee: [Cand] = []
    var wantedLabel: Name? = nil
    var position = -1
    var callOpen: Int?
    noBinding += 1
    defer { noBinding -= 1 }
    if unit.isByte(at - 1, 0x29), let call = unit.matchingOpen(at - 1), isCallOpen(unit, call) {
      callee = calleeCandidates(unitIndex: unitIndex, open: call)
      callOpen = call
    } else if unit.tokens[at - 1].kind == .identifier || unit.tokens[at - 1].kind == .keyword || unit.isByte(at - 1, 0x3E) {
      let start = chainStart(unit, at - 1)
      let result = evaluate(unitIndex: unitIndex, start: Int32(start))
      if let step = result.steps.firstIndex(where: { $0.token == Int32(at - 1) }) { callee = result.sets[step] }
    } else if let call = enclosingOpen(unit, at), unit.isByte(call, 0x28), isCallOpen(unit, call) {
      callee = calleeCandidates(unitIndex: unitIndex, open: call)
      let arguments = splitArguments(unit, open: call, close: unit.skipBalanced(call) - 1)
      position = arguments.firstIndex { $0.start == at } ?? -1
      if position >= 0 { wantedLabel = arguments[position].label }
      callOpen = call
    } else {
      // `let a: (B) -> C = { b in`
      var wanted = expectedType(unitIndex: unitIndex, start: open)
      if case .optional(let inner)? = wanted { wanted = inner }
      if case .function? = wanted { return [wanted!] }
      return []
    }
    var found: [Ty] = []
    for cand in callee {
      guard case .decl(let ref)? = cand.site else { continue }
      let item = decl(ref)
      guard item.kind.isCallable || item.kind == .initializer else { continue }
      let holder = self.unit(ref)
      var scope = parents(of: ref)
      scope.append(ref.decl)
      var chosen: Ty?
      for p in stride(from: Int(item.paramCount) - 1, through: 0, by: -1) {
        let param = holder.params[Int(item.paramStart) + p]
        if let wantedLabel {
          let label = param.label == Word.underscore ? 0 : param.label
          if label != wantedLabel { continue }
        }
        var ty = parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: scope)
        ty = substitute(ty, receiver: cand.receiver)
        if case .optional(let inner) = ty { ty = inner }
        if case .function = ty {
          chosen = ty
          break
        }
      }
      // `ForEach(kinds) { kind in`: what the other arguments say its generics are.
      if let call = callOpen, let function = chosen, mentionsParam(function) {
        var bound: [Name: Ty] = [:]
        for argument in splitArguments(unit, open: call, close: unit.skipBalanced(call) - 1) where argument.start != at && !unit.isByte(argument.start, 0x7B) {
          let label = argument.label
          for p in 0..<Int(item.paramCount) {
            let param = holder.params[Int(item.paramStart) + p]
            guard (param.label == Word.underscore ? 0 : param.label) == label else { continue }
            let wanted = substitute(parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: scope), receiver: cand.receiver)
            bind(wanted, to: evaluateExpression(unitIndex: unitIndex, start: argument.start, end: argument.end), into: &bound)
            break
          }
        }
        if !bound.isEmpty { chosen = substitute(function, map: bound, receiver: nil) }
      }
      if let chosen { found.append(chosen) }
    }
    return found
  }

  /// What a position's surroundings ask of it: an annotation, a return type, a parameter, a switch's subject.
  /// `[` that opens a literal, not a subscript: nothing that could be subscripted stands before it.
  private func isListLiteral(_ unit: Unit, _ open: Int) -> Bool {
    guard open > 0 else { return true }
    let before = open - 1
    if unit.isByte(before, 0x29) || unit.isByte(before, 0x5D) || (unit.isByte(before, 0x3F) && unit.touchesPrevious(before)) || unit.isByte(before, 0x21) || unit.isByte(before, 0x7D) { return false }
    if unit.isToken(before, "return") || unit.isToken(before, "try") || unit.isToken(before, "await") || unit.isToken(before, "in") { return true }
    return unit.tokens[before].kind != .identifier
  }

  func expectedType(unitIndex: Int32, start: Int32) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    var before = Int(start) - 1
    while before >= 0, unit.isToken(before, "try") || unit.isToken(before, "await") || (isSugar(unit, before) && unit.isToken(before - 1, "try")) { before -= 1 }
    guard before >= 0 else { return nil }
    let scopes = chain(at: start, unitIndex: unitIndex)
    // `a ? .b : .c` wants what the whole of it is wanted as; failing that, what its other side is.
    if let (whole, question) = ternaryAround(unit, before: before) {
      if let ty = expectedType(unitIndex: unitIndex, start: Int32(whole)) { return ty }
      if before != question {
        let first = evaluateExpression(unitIndex: unitIndex, start: question + 1, end: before)
        if first != .unknown { return first }
      }
      return nil
    }
    if unit.isByte(before, 0x3D) {
      for scan in scans(unitIndex: unitIndex, token: start) {
        for local in scan.locals where local.token < start {
          if case .written(let a, let b) = local.kind, Int(b) == before {
            return parseType(unitIndex: unitIndex, start: a, end: b, scope: scopes)
          }
        }
      }
      if let last = scopes.last {
        let item = unit.decls[Int(last)]
        if item.kind == .variable, item.typeEnd == Int32(before) {
          return parseType(unitIndex: unitIndex, start: item.typeStart, end: item.typeEnd, scope: scopes)
        }
      }
      if unit.isToken(before - 1, "]") || before > 0 {
        let left = chainStart(unit, before - 1)
        let result = evaluate(unitIndex: unitIndex, start: Int32(left))
        return result.ty == .unknown ? nil : result.ty
      }
    }
    if unit.isToken(before, "??") {
      let left = chainStart(unit, before - 1)
      var ty = evaluate(unitIndex: unitIndex, start: Int32(left)).ty
      if case .optional(let wrapped) = ty { ty = wrapped }
      return ty == .unknown ? nil : ty
    }
    if unit.isToken(before, "==") || unit.isToken(before, "!=") || unit.isToken(before, "<") || unit.isToken(before, ">") || unit.isToken(before, "<=") || unit.isToken(before, ">=") {
      let left = chainStart(unit, before - 1)
      let result = evaluate(unitIndex: unitIndex, start: Int32(left))
      return result.ty == .unknown ? nil : result.ty
    }
    let isReturn = unit.isToken(before, "return")
    if isReturn || unit.isByte(before, 0x7B) {
      for scan in scans(unitIndex: unitIndex, token: start) {
        guard let closure = scan.innermostClosure(at: start) else { continue }
        // What the closure is wanted to give.
        guard isReturn || closure.open == Int32(before) else { return nil }
        var results: [Ty] = []
        for case .function(_, let result) in closureTypes(unitIndex: unitIndex, open: closure.open) where !mentionsParam(result) && !results.contains(result) { results.append(result) }
        expectedAlternatives = results
        return results.count == 1 ? results[0] : nil
      }
      if !isReturn, let last = scopes.last, unit.decls[Int(last)].bodyOpen != Int32(before) { return nil }
      guard let last = scopes.last else { return nil }
      let item = unit.decls[Int(last)]
      guard item.typeStart >= 0, item.kind == .function || item.kind == .variable || item.kind == .subscriptDecl else { return nil }
      return parseType(unitIndex: unitIndex, start: item.typeStart, end: item.typeEnd, scope: scopes)
    }
    // In a list: an array's or set's element, a dictionary's key or value, or an option set, written as a list of itself.
    if unit.isByte(before, 0x5B) || unit.isByte(before, 0x2C) || unit.isByte(before, 0x3A), let open = enclosingOpen(unit, Int(start)), unit.isByte(open, 0x5B) {
      if !isListLiteral(unit, open) { return subscriptIndex(unitIndex: unitIndex, open: open) }
      guard var outer = expectedType(unitIndex: unitIndex, start: Int32(open)) else { return nil }
      if case .optional(let wrapped) = outer { outer = wrapped }
      guard case .nominal(let ref, let arguments) = outer else { return nil }
      if arguments.isEmpty { return outer }
      let holder = decl(ref).name
      if holder == Word.dictionary, arguments.count == 2 { return arguments[unit.isByte(before, 0x3A) ? 1 : 0] }
      return holder == Word.array || holder == name("Set") ? arguments[0] : nil
    }
    if unit.isToken(before, "case") || unit.isByte(before, 0x2C) {
      for scan in scans(unitIndex: unitIndex, token: start) {
        var best: SwitchInfo?
        for info in scan.switches where info.open < start && start < info.close { best = info }
        if let best, unit.isToken(before, "case") || isInCaseList(unit, before, best) {
          let ty = evaluateExpression(unitIndex: unitIndex, start: Int(best.subjectStart), end: Int(best.subjectEnd))
          return ty == .unknown ? nil : ty
        }
      }
    }
    if unit.isByte(before, 0x28) || unit.isByte(before, 0x2C) || unit.isByte(before, 0x3A) {
      guard let open = enclosingOpen(unit, Int(start)), unit.isByte(open, 0x28), isCallOpen(unit, open) else { return nil }
      let arguments = splitArguments(unit, open: open, close: unit.skipBalanced(open) - 1)
      guard let argument = arguments.first(where: { $0.start <= Int(start) && Int(start) < max($0.end, $0.start + 1) }) else { return nil }
      var found: [Ty] = []
      noBinding += 1
      defer { noBinding -= 1 }
      for cand in calleeCandidates(unitIndex: unitIndex, open: open) {
        guard case .decl(let ref)? = cand.site else { continue }
        let item = decl(ref)
        let holder = self.unit(ref)
        var scope = parents(of: ref)
        scope.append(ref.decl)
        if let properties = memberwiseProperties(of: ref) {
          if let property = properties.first(where: { decl($0).name == argument.label }) { found.append(variableType(property)) }
          continue
        }
        for p in 0..<Int(item.paramCount) {
          let param = holder.params[Int(item.paramStart) + p]
          let label = param.label == Word.underscore ? 0 : param.label
          if label == argument.label {
            found.append(substitute(parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: scope), receiver: cand.receiver))
            break
          }
        }
      }
      // Code being typed has arguments still missing, which rules out every overload: what's left is all of them.
      if found.isEmpty {
        for (ref, receiver) in allCallees(unitIndex: unitIndex, open: open) {
          if let properties = memberwiseProperties(of: ref) {
            if let property = properties.first(where: { decl($0).name == argument.label }) { found.append(variableType(property)) }
            continue
          }
          let item = decl(ref)
          let holder = self.unit(ref)
          var scope = parents(of: ref)
          scope.append(ref.decl)
          for p in 0..<Int(item.paramCount) {
            let param = holder.params[Int(item.paramStart) + p]
            if (param.label == Word.underscore ? 0 : param.label) == argument.label {
              found.append(substitute(parseType(unitIndex: ref.unit, start: param.typeStart, end: param.typeEnd, scope: scope), receiver: receiver))
              break
            }
          }
        }
      }
      // A generic overload (`transition<T>(_: T)`) says nothing against one that names a type.
      let told = found.filter { !mentionsParam($0) }
      if !told.isEmpty { found = told }
      if let first = found.first {
        var distinct: [Ty] = []
        for ty in found where !distinct.contains(ty) { distinct.append(ty) }
        expectedAlternatives = distinct
        if distinct.count == 1 { return first }
      }
    }
    return nil
  }

  /// `a ? .b` or `a ? b : .c` around the token before a position: where the whole of it starts, and its `?`.
  private func ternaryAround(_ unit: Unit, before: Int) -> (start: Int, question: Int)? {
    guard unit.isByte(before, 0x3F) || unit.isByte(before, 0x3A) else { return nil }
    var question = unit.isByte(before, 0x3F) ? before : -1
    var i = before - 1
    var budget = 128
    while i >= 0, budget > 0 {
      budget -= 1
      let kind = unit.tokens[i].kind
      if kind == .close {
        guard let open = unit.matchingOpen(i) else { return nil }
        i = open - 1
        continue
      }
      if kind == .open || unit.isByte(i, 0x2C) || unit.isByte(i, 0x3D) || unit.isByte(i, 0x3A) || unit.isToken(i, "return") || unit.isToken(i, "if") || unit.isToken(i, "guard") || unit.isToken(i, "while") || unit.isToken(i, "case") { break }
      if question < 0, unit.isByte(i, 0x3F), !(i > 0 && unit.isToken(i - 1, "try")) { question = i }
      i -= 1
    }
    guard question >= 0, i + 1 < question, budget > 0 else { return nil }
    return (i + 1, question)
  }

  /// `a[.`: what the subscripts of `a` take.
  private func subscriptIndex(unitIndex: Int32, open: Int) -> Ty? {
    let unit = project.units[Int(unitIndex)]
    guard open > 0 else { return nil }
    let result = evaluate(unitIndex: unitIndex, start: Int32(chainStart(unit, open - 1)), limit: Int32(open))
    var base = result.ty
    while case .optional(let wrapped) = base { base = wrapped }
    guard case .nominal(let ref, let arguments) = base else { return nil }
    if decl(ref).name == Word.dictionary, arguments.count == 2 { return arguments[0] }
    var found: [Ty] = []
    for member in memberTable(of: ref)[Word.subscriptName] ?? [] {
      let item = decl(member)
      guard item.kind == .subscriptDecl, item.paramCount > 0, accessible(member, from: unitIndex) else { continue }
      var scope = parents(of: member)
      scope.append(member.decl)
      let param = self.unit(member).params[Int(item.paramStart)]
      let ty = substitute(parseType(unitIndex: member.unit, start: param.typeStart, end: param.typeEnd, scope: scope), receiver: base)
      if !found.contains(ty) { found.append(ty) }
    }
    expectedAlternatives = found
    return found.count == 1 ? found[0] : nil
  }

  /// Every declaration a call could mean, by its callee alone: not narrowed by what's been written of its arguments.
  func allCallees(unitIndex: Int32, open: Int) -> [(ref: DeclRef, receiver: Ty?)] {
    let unit = project.units[Int(unitIndex)]
    var end = open - 1
    if unit.isByte(end, 0x3E) {
      var level = 0
      while end >= 0 {
        if unit.isByte(end, 0x3E) { level += 1 }
        if unit.isToken(end, "<") {
          level -= 1
          if level == 0 { break }
        }
        end -= 1
      }
      end -= 1
    }
    guard end >= 0 else { return [] }
    let start = chainStart(unit, end)
    let result = evaluate(unitIndex: unitIndex, start: Int32(start), limit: Int32(open))
    var found: [(DeclRef, Ty?)] = []
    for cand in result.sets.last ?? [] {
      if case .meta(let instance) = cand.ty {
        if case .nominal(let ref, _) = instance, memberwiseProperties(of: ref) != nil { found.append((ref, instance)) }
        for item in memberCandidates(of: cand.ty, name: Word.initName, from: unitIndex, prev: -1) {
          if case .decl(let ref)? = item.site { found.append((ref, item.receiver)) }
        }
        continue
      }
      guard case .decl(let ref)? = cand.site else { continue }
      if decl(ref).kind.isCallable || decl(ref).kind == .enumCase { found.append((ref, cand.receiver)) }
    }
    return found
  }

  private func isInCaseList(_ unit: Unit, _ comma: Int, _ info: SwitchInfo) -> Bool {
    var i = comma
    var budget = 256
    while i > Int(info.open), budget > 0 {
      if unit.isToken(i, "case") { return true }
      if unit.isByte(i, 0x3A) || unit.isByte(i, 0x7B) { return false }
      i -= 1
      budget -= 1
    }
    return false
  }

  /// An expression's type: prefixes off, its first chain, and what follows when that's a cast or `??`.
  func evaluateExpression(unitIndex: Int32, start: Int, end: Int) -> Ty {
    let unit = project.units[Int(unitIndex)]
    var i = start
    while i < end {
      if unit.isToken(i, "try") || unit.isToken(i, "await") || unit.isByte(i, 0x26) || unit.isByte(i, 0x21) || unit.isByte(i, 0x2D) {
        i += 1
        if i < end, isSugar(unit, i), unit.isToken(i - 1, "try") { i += 1 }
        continue
      }
      break
    }
    guard i < end else { return .unknown }
    if let (colon, question) = ternary(unit, from: i, to: end) {
      let first = evaluateExpression(unitIndex: unitIndex, start: question + 1, end: colon)
      return first != .unknown ? first : evaluateExpression(unitIndex: unitIndex, start: colon + 1, end: end)
    }
    // `[UInt8]()`, `[String: Int](minimumCapacity: 4)`: a type written as a literal, then called.
    if unit.isByte(i, 0x5B) {
      let close = unit.skipBalanced(i)
      if unit.isByte(close, 0x28), unit.skipBalanced(close) >= end {
        return parseType(unitIndex: unitIndex, start: Int32(i), end: Int32(close), scope: chain(at: Int32(i), unitIndex: unitIndex))
      }
    }
    let result = evaluate(unitIndex: unitIndex, start: Int32(i))
    var ty = result.ty
    let after = Int(result.end)
    if after >= end { return ty }
    // `for a in b where c`: the sequence ends there.
    if unit.isToken(after, "where") { return ty }
    if unit.isToken(after, "as") {
      var at = after + 1
      var optional = false
      if unit.isByte(at, 0x3F) {
        optional = true
        at += 1
      } else if unit.isByte(at, 0x21) {
        at += 1
      }
      let parsed = parseType(unitIndex: unitIndex, start: Int32(at), end: Int32(end), scope: chain(at: Int32(at), unitIndex: unitIndex))
      return optional ? .optional(parsed) : parsed
    }
    if unit.isToken(after, "is") { return standard(Word.bool, []) }
    if unit.isToken(after, "..<") || unit.isToken(after, "...") {
      return standard(hashName(unit.isToken(after, "..<") ? "Range" : "ClosedRange"), [ty])
    }
    if unit.isToken(after, "??") {
      if case .optional(let wrapped) = ty { ty = wrapped }
      if ty != .unknown { return ty }
      return evaluateExpression(unitIndex: unitIndex, start: after + 1, end: end)
    }
    if unit.isToken(after, "==") || unit.isToken(after, "!=") || unit.isToken(after, "<") || unit.isToken(after, ">") || unit.isToken(after, "<=") || unit.isToken(after, ">=")
      || unit.isToken(after, "&&") || unit.isToken(after, "||")
    {
      return standard(Word.bool, [])
    }
    if unit.isByte(after, 0x2B) || unit.isByte(after, 0x2D) || unit.isByte(after, 0x2A) || unit.isByte(after, 0x2F) || unit.isByte(after, 0x25) { return ty }
    return .unknown
  }

  /// A `?` that stands alone at this level, with its `:`. Written against what's before it, `?` is an optional's.
  private func ternary(_ unit: Unit, from: Int, to end: Int) -> (colon: Int, question: Int)? {
    var i = from
    var question = -1
    var nested = 0
    while i < end {
      let token = unit.tokens[i]
      if token.kind == .open || token.kind == .interpolationOpen {
        i = unit.skipBalanced(i)
        continue
      }
      if token.kind == .close { return nil }
      if unit.isByte(i, 0x3F), i > from, unit.tokens[i - 1].end != token.start {
        if question < 0 { question = i } else { nested += 1 }
      } else if unit.isByte(i, 0x3A), question >= 0 {
        if nested == 0 { return (i, question) }
        nested -= 1
      }
      i += 1
    }
    return nil
  }

  // MARK: Output and references

  /// What a position's chain looks like step by step: for reading a miss.
  public func explain(path: String, line: Int, character: Int) -> String {
    guard let unitIndex = project.unitByPath[path] else { return "no such file" }
    let unit = project.units[Int(unitIndex)]
    let offset = unit.source.lines.offset(line: line, character: character, in: unit.source.text)
    guard let token = unit.tokens.firstIndex(where: { $0.end > offset }) else { return "no token" }
    prepareScans(unitIndex: unitIndex, token: Int32(token))
    let start = chainStart(unit, token)
    let result = evaluate(unitIndex: unitIndex, start: Int32(start))
    var text = "token [\(unit.string(token))] \(token) chain from [\(unit.string(start))]\n"
    let owners = chain(at: Int32(token), unitIndex: unitIndex)
    text += "  owners: " + owners.map { "\(unit.decls[Int($0)].kind) [\(unit.string(Int(unit.decls[Int($0)].nameToken)))] \(unit.decls[Int($0)].first)..<\(unit.decls[Int($0)].end)" }.joined(separator: " > ") + "\n"
    for scan in scans(unitIndex: unitIndex, token: Int32(token)) {
      text += "  all locals: " + scan.locals.filter { $0.token >= 0 }.map { unit.string(Int($0.token)) + "@\($0.token)" }.joined(separator: " ") + "\n"
      for index in scan.byName[unit.hash(token)] ?? [] {
        let local = scan.locals[Int(index)]
        text += "  local at \(local.token): scope \(local.scopeStart)..<\(local.scopeEnd) \(local.kind)\n"
      }
    }
    for (index, step) in result.steps.enumerated() {
      text += "  \(step.head) [\(unit.string(Int(step.token)))] ops \(step.ops.count):"
      for cand in result.sets[index] {
        var place = "-"
        if let site = cand.site, let found = self.place(of: site) { place = "\(found.path):\(found.line)" }
        text += " {\(place) : \(describe(cand.ty))}"
      }
      text += "\n"
    }
    return text
  }

  /// A declaration's place: `path` relative to the root, or `sdk:<module>.swiftinterface`.
  public func place(of site: Site) -> (path: String, line: Int)? {
    switch site {
    case .decl(let ref):
      let holder = unit(ref)
      return placeOf(holder, token: Int(decl(ref).nameToken))
    case .local(let unit, let token), .generic(let unit, let token):
      return placeOf(project.units[Int(unit)], token: Int(token))
    case .module(let moduleName):
      return ("sdk:" + (project.modules[moduleName]?.publishedName ?? "?") + ".swiftinterface", 1)
    }
  }

  /// Where a site is on disk, for an editor to open: a file in the project, a `.swiftinterface` in the SDK, or the header
  /// a Clang declaration was read from. Line and character from 0, the character in UTF-16 units; `name` is what's
  /// declared there. Nil for a module.
  public func location(of site: Site) -> (path: String, line: Int, character: Int, name: String, preview: String)? {
    let holder: Unit
    let token: Int
    switch site {
    case .decl(let ref):
      holder = unit(ref)
      token = Int(decl(ref).nameToken)
    case .local(let unitIndex, let index), .generic(let unitIndex, let index):
      holder = project.units[Int(unitIndex)]
      token = Int(index)
    case .module:
      return nil
    }
    guard token >= 0, token < holder.tokens.count else { return nil }
    let start = holder.tokens[token].start
    let end = holder.tokens[token].end
    let bytes = holder.source.bytes
    let name = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
    let line = holder.source.lines.line(of: start)
    let lineStart = holder.source.lines.offset(line: line, character: 0, in: holder.source.text)
    var lineEnd = lineStart
    while lineEnd < bytes.count, bytes[lineEnd] != 10 { lineEnd += 1 }
    // The declaration's line as Swift, also for a header's (its generated Swift reads better than the C).
    let preview = String(
      String(decoding: UnsafeBufferPointer(rebasing: bytes[lineStart..<lineEnd]), as: UTF8.self)
        .trimmingCharacters(in: .whitespaces).prefix(160))
    if !holder.headerLines.isEmpty {
      guard line < holder.headerLines.count else { return nil }
      let entry = holder.headerLines[line]
      return (holder.headerFiles[Int(entry.header)], max(0, Int(entry.line) - 1), 0, name, preview)
    }
    let character = String(decoding: UnsafeBufferPointer(rebasing: bytes[lineStart..<start]), as: UTF8.self).utf16.count
    return (holder.path, line, character, name, preview)
  }

  private func placeOf(_ unit: Unit, token: Int) -> (path: String, line: Int)? {
    guard token >= 0, token < unit.tokens.count else { return nil }
    let line = unit.source.lines.line(of: unit.tokens[token].start) + 1
    if !unit.headerLines.isEmpty, line - 1 < unit.headerLines.count {
      // The real header's line, named with its module first as the scorer reads it.
      let entry = unit.headerLines[line - 1]
      let moduleName = project.modules[unit.moduleName]?.publishedName ?? "?"
      let file = URL(fileURLWithPath: unit.headerFiles[Int(entry.header)]).lastPathComponent
      return ("sdk:" + moduleName + "." + file, Int(entry.line))
    }
    if unit.isInterface {
      let moduleName = project.modules[unit.moduleName]?.publishedName ?? "?"
      return ("sdk:" + moduleName + ".swiftinterface", line)
    }
    let root = project.root
    if unit.path.hasPrefix(root + "/") { return (String(unit.path.dropFirst(root.count + 1)), line) }
    // Outside the root, as the reference writes it.
    return ("sdk:" + URL(fileURLWithPath: unit.path).lastPathComponent, line)
  }

  /// A name filter over the project's files, then each hit resolved: a reference is only what lands on the target.
  public func references(of answer: Answer) -> [(path: String, line: Int)] {
    guard answer.state != .unknown, !answer.byNameOnly, let first = answer.sites.first else { return [] }
    let targets = Set(answer.sites)
    var searched: Name?
    var restrict: Int32?
    switch first {
    case .decl(let ref):
      searched = decl(ref).name
    case .local(let unit, let token), .generic(let unit, let token):
      searched = project.units[Int(unit)].hash(Int(token))
      // `oldValue` is reached through its accessor's token, which has another name.
      for scan in project.units[Int(unit)].scans.values {
        if let index = scan.byToken[token] { searched = scan.locals[Int(index)].name }
      }
      restrict = unit
    case .module:
      return []
    }
    guard let searched else { return [] }
    var seen = Set<String>()
    var result: [(String, Int)] = []
    // `Foo()` is a reference to Foo, and to its init: an init is searched by the type's name too.
    var names: Set<Name> = [searched]
    for target in targets {
      if case .decl(let ref) = target {
        names.insert(decl(ref).name)
        if decl(ref).kind.isNominal { names.insert(Word.initName) }
      }
    }
    for u in 0..<project.projectUnits {
      if let restrict, restrict != Int32(u) { continue }
      let unit = project.units[u]
      for (index, token) in unit.tokens.enumerated() {
        switch token.kind {
        case .identifier, .keyword, .declarationKeyword:
          guard names.contains(hashName(unit.source.text + token.start, token.length)) else { continue }
        case .attribute, .directive:
          // `@Test`, `#expect`: the name past its sign.
          guard token.length > 1, names.contains(hashName(unit.source.text + token.start + 1, token.length - 1)) else { continue }
        default:
          continue
        }
        let found = self.answer(unitIndex: Int32(u), token: index)
        guard found.state != .unknown, !found.byNameOnly, found.sites.contains(where: targets.contains) else { continue }
        guard let place = placeOf(unit, token: index) else { continue }
        if seen.insert("\(place.path):\(place.line)").inserted { result.append((place.path, place.line)) }
      }
    }
    return result
  }
}

// MARK: Errors

public struct Finding {
  public var path: String
  public var line: Int
  public var word: String
  public var message: String
}

extension Model {
  /// A nominal whose every member is known: all its parents read, and nothing that makes members up.
  private func isClosed(_ ref: DeclRef, seen: inout Set<DeclRef>) -> Bool {
    guard seen.insert(ref).inserted else { return true }
    let item = decl(ref)
    guard item.kind != .extensionDecl else { return false }
    let holder = unit(ref)
    // An SDK type can be extended by a module that's not loaded here, in a Clang header or an import elsewhere.
    if holder.isInterface { return false }
    // A macro or a dynamic-lookup attribute adds members no scan can see.
    var i = Int(item.first)
    while i < Int(item.nameToken) {
      if holder.tokens[i].kind == .attribute { return false }
      i += 1
    }
    for candidate in project.extensions[item.name] ?? [] where nominal(forMembersOf: candidate) == ref {
      let owner = unit(candidate)
      var k = Int(decl(candidate).first)
      while k < Int(decl(candidate).nameToken) {
        if owner.tokens[k].kind == .attribute { return false }
        k += 1
      }
    }
    _ = memberTable(of: ref)
    for base in inheritedTypes[ref] ?? [] {
      switch base {
      case .nominal(let parent, _):
        if !isClosed(parent, seen: &seen) { return false }
      default:
        return false
      }
    }
    return true
  }

  /// What can be said for sure in a file: a member that a fully known type doesn't have, or can't show from here.
  public func findings(path: String) -> [Finding] {
    guard let unitIndex = project.unitByPath[path] else { return [] }
    let unit = project.units[Int(unitIndex)]
    var found: [Finding] = []
    var done: Set<Int32> = []
    for (index, token) in unit.tokens.enumerated() where token.kind == .identifier || token.kind == .keyword || token.kind == .declarationKeyword {
      guard index > 0, unit.isByte(index - 1, 0x2E) || unit.isToken(index - 1, "?.") else { continue }
      let start = Int32(chainStart(unit, index))
      guard done.insert(start).inserted else { continue }
      prepareScansForFindings(unitIndex: unitIndex, token: start)
      let result = evaluate(unitIndex: unitIndex, start: start)
      for at in result.steps.indices where at > 0 {
        guard case .member = result.steps[at].head else { continue }
        let previous = result.sets[at - 1]
        guard !previous.isEmpty else { continue }
        let member = unit.hash(Int(result.steps[at].token))
        var refs: [DeclRef] = []
        var allClosed = true
        var isStaticSide = false
        for cand in previous {
          var ty = cand.ty
          if case .meta(let inner) = ty {
            ty = inner
            isStaticSide = true
          }
          guard case .nominal(let ref, _) = ty else {
            allClosed = false
            break
          }
          var seen: Set<DeclRef> = []
          if !isClosed(ref, seen: &seen) { allClosed = false }
          refs.append(ref)
        }
        guard allClosed, !refs.isEmpty else { continue }
        checkedAccesses += 1
        let text = unit.string(Int(result.steps[at].token))
        // `.self`, `.Type` and `.init` aren't members a table holds.
        if text == "self" || text == "Type" || text == "init" || text == "Protocol" { continue }
        let tables = refs.map { memberTable(of: $0)[member] ?? [] }
        let line = unit.source.lines.line(of: unit.tokens[Int(result.steps[at].token)].start) + 1
        if tables.allSatisfy(\.isEmpty) {
          if !isStaticSide, refs.contains(where: { genericNames(of: $0).contains(member) }) { continue }
          found.append(Finding(path: path, line: line, word: text, message: "no member '\(text)'"))
        } else if tables.allSatisfy({ $0.allSatisfy { !accessible($0, from: unitIndex) } }) {
          found.append(Finding(path: path, line: line, word: text, message: "'\(text)' is inaccessible from here"))
        }
      }
    }
    return found
  }

  func prepareScansForFindings(unitIndex: Int32, token: Int32) { _ = answerFromLoaded(unitIndex: unitIndex, token: Int(token)) }

  public func allFindings() -> [Finding] {
    var all: [Finding] = []
    for index in 0..<project.projectUnits { all.append(contentsOf: findings(path: project.units[index].path)) }
    return all
  }
}

extension Unit {
  /// Local declarations join `decls` as bodies get scanned, so the site map can go stale for them.
  func declaredSiteFresh(at token: Int, unitIndex: Int32) -> Site? {
    for index in decls.indices.reversed() {
      if !decls[index].isLocal, decls[index].parent < 0 { break }
      if decls[index].nameToken == Int32(token), decls[index].kind != .extensionDecl {
        return .decl(DeclRef(unit: unitIndex, decl: Int32(index)))
      }
    }
    return nil
  }
}
