import CodeScan
import Foundation

/// One file: its text, tokens without comments, and declarations.
public final class Unit {
  public let path: String
  public let source: SourceFile
  public package(set) var moduleName: Name = 0
  public package(set) var isInterface = false
  public package(set) var tokens: [Token] = []
  public package(set) var decls: [Decl] = []
  package var params: [Param] = []
  package var generics: [Generic] = []
  package var ranges: [(start: Int32, end: Int32)] = []
  public package(set) var imports: [Import] = []
  /// For a unit generated from headers (Clang modules read as Swift): where each of its lines came from.
  package var headerLines: [(header: Int32, line: Int32)] = []
  package var headerFiles: [String] = []
  /// A hash of everything but body text: when it holds, an edit can't have changed what other files see.
  public package(set) var shape: UInt64 = 0
  /// Layer 4, per body and only once asked for: what a position needs, dropped with the file. Kept by the front end.
  package var scans: [Int32: any BodyFacts] = [:]
  package var chains: [Int32: AnyObject] = [:]
  package var cachedNameCounts: [Name: Int32]?
  /// Where someone is working in a branch of `#if` that's not active here: that branch is read instead.
  package private(set) var focusOffset: Int?
  private var focusToken = -1
  private var childMap: [Int32: [Int32]] = [:]
  private var childCount = -1
  private var siteMap: [Int32: Site]?

  /// What reads its declarations and evaluates its conditions.
  package let syntax: any LanguageSyntax

  package init(path: String, source: SourceFile, syntax: any LanguageSyntax, isInterface: Bool = false, focusOffset: Int? = nil) {
    self.path = path
    self.syntax = syntax
    self.source = source
    self.isInterface = isInterface
    self.focusOffset = focusOffset
    var kept = [Token]()
    kept.reserveCapacity(source.tokens.count)
    for token in source.tokens where token.kind != .comment && token.kind != .docComment { kept.append(token) }
    tokens = kept
    if let focusOffset {
      var low = 0
      var high = tokens.count
      while low < high {
        let middle = (low + high) / 2
        if tokens[middle].end <= focusOffset { low = middle + 1 } else { high = middle }
      }
      focusToken = low
    }
    shape = syntax.parse(self)
  }

  package func children(of parent: Int32) -> [Int32] {
    if childCount != decls.count {
      childMap.removeAll(keepingCapacity: true)
      for index in decls.indices { childMap[decls[index].parent, default: []].append(Int32(index)) }
      childCount = decls.count
    }
    return childMap[parent] ?? []
  }

  /// The declarations around a token, outermost first, into local types and functions once a scan added them (other
  /// local declarations are a body's own business).
  package func chain(at token: Int32) -> [Int32] {
    var result: [Int32] = []
    var parent: Int32 = -1
    while true {
      var found: Int32?
      for child in children(of: parent) {
        let decl = decls[Int(child)]
        if decl.first <= token, token < decl.end {
          if decl.isLocal, !decl.kind.isNominal, decl.kind != .function { continue }
          found = child
          break
        }
      }
      guard let found else { return result }
      result.append(found)
      parent = found
    }
  }

  /// The tokens that declare something: a click there answers itself.
  package func declaredSite(at token: Int, unitIndex: Int32) -> Site? {
    if let siteMap { return siteMap[Int32(token)] }
    var map: [Int32: Site] = [:]
    for index in decls.indices {
      let decl = decls[index]
      if decl.kind != .extensionDecl { map[decl.nameToken] = .decl(DeclRef(unit: unitIndex, decl: Int32(index))) }
      for g in 0..<Int(decl.genericCount) {
        let generic = generics[Int(decl.genericStart) + g]
        map[generic.token] = .generic(unit: unitIndex, token: generic.token)
      }
      for p in 0..<Int(decl.paramCount) where decl.kind != .enumCase {
        let param = params[Int(decl.paramStart) + p]
        map[param.nameToken] = .local(unit: unitIndex, token: param.nameToken)
        // `_ name` and `label name`: the first word is the same parameter's.
        if syntax.parametersHaveLabels, param.nameToken > 0, param.typeStart > param.nameToken, tokens[Int(param.nameToken) - 1].kind == .identifier || tokens[Int(param.nameToken) - 1].kind == .keyword,
          !isByte(Int(param.nameToken) - 1, 0x3A)
        {
          map[param.nameToken - 1] = .local(unit: unitIndex, token: param.nameToken)
        }
      }
    }
    siteMap = map
    return map[Int32(token)]
  }

  /// No space between this token and the one before.
  @inlinable package func touchesPrevious(_ i: Int) -> Bool {
    guard i > 0, i < tokens.count else { return false }
    return tokens[i - 1].start + tokens[i - 1].length == tokens[i].start
  }

  @inlinable @inline(__always) package func hash(_ i: Int) -> Name {
    let token = tokens[i]
    return hashName(source.text + token.start, token.length)
  }

  @inlinable package func string(_ i: Int) -> String { source.string(tokens[i]) }

  @inlinable @inline(__always) package func isByte(_ i: Int, _ byte: UInt8) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    let token = tokens[i]
    return token.length == 1 && source.text[token.start] == byte
  }

  @inlinable @inline(__always) package func isToken(_ i: Int, _ text: StaticString) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    let token = tokens[i]
    return token.length == text.utf8CodeUnitCount && memcmp(source.text + token.start, text.utf8Start, token.length) == 0
  }

  /// Whether a line break separates a token from the one before it.
  @inlinable package func startsLine(_ i: Int) -> Bool {
    guard i > 0, i < tokens.count else { return true }
    let from = tokens[i - 1].end
    let to = tokens[i].start
    return to > from && memchr(source.text + from, 0x0A, to - from) != nil
  }

  /// The token after a bracket's match, `#if` regions not taken skipped, so that a split brace counts once. A `}` closes
  /// what's left open inside it, as code being typed has `foo(a: b.` with no `)`, and a `)` with no `(` to close is ignored.
  package func skipBalanced(_ open: Int) -> Int {
    // One bit per level, set for a brace: past 64 levels it's counting alone.
    var braces: UInt64 = 0
    var depth = 0
    var i = open
    let count = tokens.count
    while i < count {
      switch tokens[i].kind {
      case .open, .interpolationOpen:
        braces = braces << 1 | (source.text[tokens[i].start] == 0x7B ? 1 : 0)
        depth += 1
      case .close, .interpolationClose:
        if tokens[i].kind == .close, depth <= 64 {
          if source.text[tokens[i].start] == 0x7D {
            // A `}` over parentheses left open: they end here. When the first of them is what was asked about, the `}` isn't its.
            while depth > 0, braces & 1 == 0 {
              braces >>= 1
              depth -= 1
              if depth == 0 { return i }
            }
          } else if braces & 1 == 1 {
            // A `)` over a brace: the brace was left open if there's a `(` further out, or else the `)` is stray.
            let run = (~braces).trailingZeroBitCount
            if run >= depth {
              i += 1
              continue
            }
            braces >>= UInt64(run)
            depth -= run
          }
        }
        braces >>= 1
        depth -= 1
        if depth <= 0 { return i + 1 }
      case .directive:
        i = takeDirective(i)
        continue
      default:
        break
      }
      i += 1
    }
    return count
  }

  /// The open bracket of the close at `close`, walking back, with what's left open inside skipped as above.
  package func matchingOpen(_ close: Int) -> Int? {
    var braces: UInt64 = 0
    var depth = 0
    var i = close
    while i >= 0 {
      switch tokens[i].kind {
      case .close, .interpolationClose:
        braces = braces << 1 | (tokens[i].kind == .close && source.text[tokens[i].start] == 0x7D ? 1 : 0)
        depth += 1
      case .open, .interpolationOpen:
        // A `(` under a `}` was never closed.
        if tokens[i].kind == .open, depth <= 64, braces & 1 == 1, source.text[tokens[i].start] != 0x7B { break }
        braces >>= 1
        depth -= 1
        if depth == 0 { return i }
      default: break
      }
      i -= 1
    }
    return nil
  }

  /// Steps over a directive: into a branch that's taken, past those that aren't.
  package func takeDirective(_ at: Int) -> Int {
    takeDirective(at, focused: true)
  }

  private func takeDirective(_ at: Int, focused: Bool) -> Int {
    if isToken(at, "#if") || isToken(at, "#elseif") {
      if isToken(at, "#elseif") { return skipToEndif(at + 1) }
      if focused, focusToken > at, let branch = focusedBranch(at) { return branch }
      var i = at + 1
      let taken = evaluateCondition(&i)
      if taken { return i }
      return skipToBranch(i)
    }
    if isToken(at, "#else") { return skipToEndif(at + 1) }
    return at + 1
  }

  /// The start of the branch of the `#if` at `at` that the focus is in, if it's in one.
  private func focusedBranch(_ at: Int) -> Int? {
    var i = at + 1
    var depth = 0
    var branch = at
    while i < tokens.count, i <= focusToken {
      if tokens[i].kind == .directive {
        if isToken(i, "#if") {
          depth += 1
        } else if isToken(i, "#endif") {
          if depth == 0 { return nil }
          depth -= 1
        } else if depth == 0, isToken(i, "#else") || isToken(i, "#elseif") {
          branch = i
        }
      }
      i += 1
    }
    // It has to be inside, before its `#endif`.
    var end = i
    depth = 0
    var closed = false
    while end < tokens.count {
      if tokens[end].kind == .directive {
        if isToken(end, "#if") {
          depth += 1
        } else if isToken(end, "#endif") {
          if depth == 0 {
            closed = true
            break
          }
          depth -= 1
        }
      }
      end += 1
    }
    guard closed else { return nil }
    var start = branch + 1
    if !isToken(branch, "#else") { _ = evaluateCondition(&start) }
    return start
  }

  /// Whether an offset is in code `#if` leaves out here: it would have no declarations, and no answers.
  package func isLeftOut(offset: Int) -> Bool {
    var i = 0
    while i < tokens.count {
      if tokens[i].start >= offset { return false }
      guard tokens[i].kind == .directive else {
        i += 1
        continue
      }
      let next = takeDirective(i, focused: false)
      if next > i + 1, next >= tokens.count || offset < tokens[next].start {
        // In what was stepped over, unless that's the condition of a branch that's taken.
        var condition = i + 1
        if isToken(i, "#if") {
          let taken = evaluateCondition(&condition)
          if taken { return false }
        }
        return offset >= tokens[i].end
      }
      i = max(next, i + 1)
    }
    return false
  }

  /// From a branch not taken, to the next that may be.
  private func skipToBranch(_ from: Int) -> Int {
    var i = from
    var depth = 0
    while i < tokens.count {
      if tokens[i].kind == .directive {
        if isToken(i, "#if") {
          depth += 1
        } else if isToken(i, "#endif") {
          if depth == 0 { return i + 1 }
          depth -= 1
        } else if depth == 0, isToken(i, "#else") {
          return i + 1
        } else if depth == 0, isToken(i, "#elseif") {
          var j = i + 1
          if evaluateCondition(&j) { return j }
          i = j
          continue
        }
      }
      i += 1
    }
    return i
  }

  /// A taken branch ended: past its `#endif`.
  private func skipToEndif(_ from: Int) -> Int {
    var i = from
    var depth = 0
    while i < tokens.count {
      if tokens[i].kind == .directive {
        if isToken(i, "#if") {
          depth += 1
        } else if isToken(i, "#endif") {
          if depth == 0 { return i + 1 }
          depth -= 1
        }
      }
      i += 1
    }
    return i
  }

  /// A condition of conditional compilation, as the language reads it.
  package func evaluateCondition(_ i: inout Int) -> Bool { syntax.evaluateCondition(self, &i) }

  /// Answers read from bodies, after a declaration changed.
  package func dropBodyAnswers() {
    chains.removeAll()
    for scan in scans.values { scan.dropTypes() }
  }

  /// Local declarations join `decls` as bodies get scanned, so the site map can go stale for them.
  package func declaredSiteFresh(at token: Int, unitIndex: Int32) -> Site? {
    for index in decls.indices.reversed() {
      if !decls[index].isLocal, decls[index].parent < 0 { break }
      if decls[index].nameToken == Int32(token), decls[index].kind != .extensionDecl {
        return .decl(DeclRef(unit: unitIndex, decl: Int32(index)))
      }
    }
    return nil
  }

  /// Times each identifier is used in this file, read when completion first asks.
  package var nameCounts: [Name: Int32] {
    if let known = cachedNameCounts { return known }
    var counts: [Name: Int32] = [:]
    for i in tokens.indices where tokens[i].kind == .identifier { counts[hash(i), default: 0] += 1 }
    cachedNameCounts = counts
    return counts
  }
}
