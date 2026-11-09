import Foundation

/// What can be asked of a scanned workspace: all from tokens and the declarations' scopes, no types. Where a compiler
/// would know the one answer, this ranks by scope, the receiver's declared type, kind and distance, and says so by
/// returning every answer that ties.
extension WorkspaceIndex {
  /// What a name at a place in a file refers to, best first.
  public struct Resolved: Sendable {
    public var path: String
    public var symbol: Symbol
    public var name: String
    public var score: Int
  }

  /// A name's use in a file: the bytes around it the ranking looks at.
  struct Use {
    var tokenIndex: Int
    var isMember = false
    var isCall = false
    var receiverType: String?
    var isCapitalized = false
    var enclosingType: String?
  }

  // MARK: - Definitions

  /// Resolves the name under `offset` in `source`.
  public func resolve(path: String, source: SourceFile, offset: Int, depth: Int = 0) -> [Resolved] {
    if let enclosing = enclosingDeclaration(ofSelfAt: offset, source: source) {
      return [Resolved(path: path, symbol: enclosing, name: source.symbols.name(enclosing), score: 900)]
    }
    guard let index = source.nameToken(at: offset) else { return [] }
    return resolve(path: path, source: source, tokenIndex: index, depth: depth)
  }

  /// `self`, `Self` and `this` are keywords that name something: the innermost type around them.
  private func enclosingDeclaration(ofSelfAt offset: Int, source: SourceFile) -> Symbol? {
    let index = source.tokenIndex(at: offset)
    guard index < source.tokens.count else { return nil }
    let token = source.tokens[index]
    guard token.kind == .keyword, token.start <= offset, offset <= token.end, token.length == 4 else { return nil }
    let word = source.string(from: token.start, to: token.end)
    guard word == "self" || word == "Self" || word == "this" else { return nil }
    var best: Symbol?
    for symbol in source.symbols.symbols where (symbol.kind.isType || symbol.kind == .extension) && !symbol.isLocal {
      guard Int(symbol.start) <= offset, offset <= Int(symbol.end) else { continue }
      if let current = best, current.start > symbol.start { continue }
      best = symbol
    }
    return best
  }

  func resolve(path: String, source: SourceFile, tokenIndex index: Int, depth: Int = 0) -> [Resolved] {
    let token = source.tokens[index]
    let t = source.text
    var nameStart = token.start
    var nameLength = token.length
    if token.kind == .attribute, nameLength > 1, t[nameStart] == 0x40 {
      nameStart += 1
      nameLength -= 1
    }
    let name = UnsafeBufferPointer(start: t + nameStart, count: nameLength)
    let symbols = source.symbols
    let nameText = String(decoding: name, as: UTF8.self)

    // On a declaration: itself, unless it extends a type declared elsewhere.
    var extendedType = false
    for (position, symbol) in symbols.symbols.enumerated() where Int(symbol.offset) == nameStart {
      _ = position
      if symbol.kind == .extension {
        extendedType = true
        break
      }
      return [Resolved(path: path, symbol: symbol, name: nameText, score: 1000)]
    }

    var use = describeUse(source: source, tokenIndex: index, depth: depth, path: path)
    if extendedType { use.isMember = false }

    // Locals and what's visible in the enclosing scopes, innermost first; a member access can't mean those.
    if !use.isMember {
      var best: Symbol?
      for symbol in symbols.symbols where symbol.isLocal && symbols.nameEquals(symbol, name) {
        guard Int(symbol.scopeStart) <= nameStart, nameStart <= Int(symbol.scopeEnd), Int(symbol.offset) <= nameStart else { continue }
        if let current = best, current.scopeStart > symbol.scopeStart { continue }
        if let current = best, current.scopeStart == symbol.scopeStart, current.offset > symbol.offset { continue }
        best = symbol
      }
      if let best { return [Resolved(path: path, symbol: best, name: nameText, score: 900)] }
    }

    // Everything of that name elsewhere, ranked.
    let hash = hashName(t + nameStart, nameLength)
    var ranked: [Resolved] = []
    let family = source.profile.family
    let directory = (path as NSString).deletingLastPathComponent
    for (fileIndex, symbolIndex) in declarations(named: name, hash: hash) {
      guard let file = files[fileIndex], file.family == family else { continue }
      let symbol = file.symbols.symbols[symbolIndex]
      var score = rank(symbol, in: file, use: use, samePath: file.path == path, directory: directory)
      if file.path == path, Int(symbol.offset) > nameStart, !symbol.kind.isType, symbol.parent < 0 { score -= 2 }
      ranked.append(Resolved(path: file.path, symbol: symbol, name: nameText, score: score))
    }
    if ranked.isEmpty {
      // The file isn't in the workspace's scan (a format, or outside the folder).
      for symbol in symbols.symbols where !symbol.isLocal && symbols.nameEquals(symbol, name) {
        ranked.append(Resolved(path: path, symbol: symbol, name: nameText, score: 500))
      }
    }
    ranked.sort { $0.score != $1.score ? $0.score > $1.score : ($0.path, $0.symbol.offset) < ($1.path, $1.symbol.offset) }
    guard let top = ranked.first?.score else { return [] }
    // Keep what ties and a few close behind; an editor shows a list for those.
    return Array(ranked.prefix { $0.score >= top - 5 }.prefix(12))
  }

  private func rank(_ symbol: Symbol, in file: IndexedFile, use: Use, samePath: Bool, directory: String) -> Int {
    var score = 100
    let kind = symbol.kind
    if use.isCapitalized {
      if kind == .extension { score -= 10 } else if kind.isType { score += 60 } else if kind == .constructor { score += 10 }
    } else if kind.isType {
      score -= 10
    }
    if use.isCall {
      if kind.isCallable { score += 30 } else if kind.isValue { score -= 15 }
    } else if kind.isCallable {
      // A function used as a value is rarer than a variable named the same.
      score -= 5
    }
    let parent = symbol.parent >= 0 ? file.symbols.symbols[Int(symbol.parent)] : nil
    let parentName = parent.map { file.symbols.name($0) }
    if use.isMember {
      if symbol.parent >= 0 { score += 25 } else { score -= 25 }
      if let receiver = use.receiverType {
        if parentName == receiver { score += 200 } else if parent != nil { score -= 20 }
      } else if kind == .enumMember {
        score += 5
      }
    } else {
      if let enclosing = use.enclosingType, parentName == enclosing { score += 150 }
      if symbol.parent < 0 { score += 15 } else if use.enclosingType == nil { score -= 15 } else { score -= 5 }
      if kind == .constructor { score -= 40 }
    }
    if samePath { score += 40 }
    let folder = (file.path as NSString).deletingLastPathComponent
    if folder == directory {
      score += 20
    } else {
      // Sharing a package: the longer the common path, the closer.
      score += min(15, commonPrefixComponents(folder, directory) * 2)
    }
    if file.path.contains("/Tests/") || file.path.contains("/test/"), !directory.contains("Tests"), !directory.contains("/test") {
      score -= 10
    }
    return score
  }

  private func commonPrefixComponents(_ a: String, _ b: String) -> Int {
    var count = 0
    var ai = a.utf8.makeIterator()
    var bi = b.utf8.makeIterator()
    while let x = ai.next(), let y = bi.next(), x == y {
      if x == 0x2F { count += 1 }
    }
    return count
  }

  private func describeUse(source: SourceFile, tokenIndex index: Int, depth: Int, path: String) -> Use {
    let t = source.text
    let tokens = source.tokens
    let token = tokens[index]
    var use = Use(tokenIndex: index)
    let first = t[token.kind == .attribute ? token.start + 1 : token.start]
    use.isCapitalized = first >= 0x41 && first <= 0x5A
    if index + 1 < tokens.count {
      let next = tokens[index + 1]
      use.isCall = next.kind == .open && t[next.start] == 0x28 && next.start == token.end
      // Trailing closures: `foo { ... }`.
      if next.kind == .open, t[next.start] == 0x7B, source.profile.rules.closureHead != nil { use.isCall = true }
    }
    // What's around it: the enclosing type answers a bare name, and a member's receiver answers `x.name`.
    use.enclosingType = enclosingTypeName(source: source, at: token.start)
    guard index > 0 else { return use }
    let previous = tokens[index - 1]
    guard previous.kind == .punctuation, isMemberOperator(previous, t, source.profile) else { return use }
    use.isMember = true
    guard index >= 2 else { return use }
    let receiver = tokens[index - 2]
    if receiver.kind == .identifier || receiver.kind == .keyword {
      let text = source.string(receiver)
      if text == "self" || text == "this" || text == "Self" {
        use.receiverType = use.enclosingType
      } else if text == "super" {
        use.receiverType = nil
      } else if let c = text.utf8.first, c >= 0x41, c <= 0x5A {
        use.receiverType = text
      } else if depth < 3 {
        // What the receiver is: its declaration's type, written or the constructor it's set from.
        if let found = resolve(path: path, source: source, tokenIndex: index - 2, depth: depth + 1).first {
          use.receiverType = declaredType(of: found)
        }
      }
    }
    return use
  }

  private func isMemberOperator(_ token: Token, _ t: UnsafePointer<UInt8>, _ profile: LexProfile) -> Bool {
    let last = t[token.end - 1]
    if last == 0x2E { return token.length == 1 || t[token.start] != 0x2E }  // `.`, `?.`, `!.`, not `..`.
    guard token.length == 2 else { return false }
    let text = String(decoding: UnsafeBufferPointer(start: t + token.start, count: 2), as: UTF8.self)
    return profile.rules.memberOperators.contains(text)
  }

  /// The innermost type around an offset.
  func enclosingTypeName(source: SourceFile, at offset: Int) -> String? {
    let symbols = source.symbols
    var best: Symbol?
    for symbol in symbols.symbols where symbol.kind.isType && symbol.kind != .module {
      guard Int(symbol.scopeStart) <= offset, offset < Int(symbol.scopeEnd), symbol.scopeEnd > symbol.scopeStart else { continue }
      if let current = best, current.scopeStart > symbol.scopeStart { continue }
      best = symbol
    }
    return best.map { symbols.name($0) }
  }

  /// `x: Foo`, `x = Foo(...)`, `Foo x`, `Foo *x`, read from the declaration.
  func declaredType(of found: Resolved) -> String? {
    guard !found.symbol.kind.isType else { return found.name }
    guard let source = source(path: found.path) else { return nil }
    let index = source.tokenIndex(at: Int(found.symbol.offset))
    let tokens = source.tokens
    guard index < tokens.count else { return nil }
    let t = source.text
    func isType(_ i: Int) -> Bool {
      guard i >= 0, i < tokens.count, tokens[i].kind == .identifier else { return false }
      let c = t[tokens[i].start]
      return c >= 0x41 && c <= 0x5A
    }
    if found.symbol.kind.isCallable {
      // What it returns: the name after `->` or `:`, past its parameters.
      var i = index + 1
      var depth = 0
      while i < tokens.count, i < index + 96 {
        let token = tokens[i]
        if token.kind == .open {
          if t[token.start] == 0x7B { return nil }
          depth += 1
        } else if token.kind == .close {
          depth -= 1
        } else if depth == 0, token.kind == .punctuation, token.length == 2 && t[token.start] == 0x2D && t[token.start + 1] == 0x3E || t[token.start] == 0x3A {
          return isType(i + 1) ? source.string(tokens[i + 1]) : nil
        }
        i += 1
      }
      return nil
    }
    var i = index + 1
    guard i < tokens.count else { return nil }
    if t[tokens[i].start] == 0x3A, tokens[i].length == 1 {
      i += 1
      // `x: [Foo]`, `x: Foo?`, `x: A.B`.
      while i < tokens.count, tokens[i].kind == .open, t[tokens[i].start] == 0x5B { i += 1 }
      while i + 2 < tokens.count, tokens[i + 1].length == 1, t[tokens[i + 1].start] == 0x2E, isType(i + 2) { i += 2 }
      return isType(i) ? source.string(tokens[i]) : nil
    }
    if t[tokens[i].start] == 0x3D, tokens[i].length == 1 {
      i += 1
      if i < tokens.count, tokens[i].kind == .keyword { i += 1 }  // `= new Foo(`, `= await Foo(`.
      if isType(i) { return source.string(tokens[i]) }
      return nil
    }
    // `Foo x`, `Foo *x`, `Foo<T> x`.
    var back = index - 1
    while back >= 0, tokens[back].kind == .punctuation, tokens[back].length == 1 { back -= 1 }
    if back >= 0, tokens[back].kind == .identifier { return source.string(tokens[back]) }
    return nil
  }

  // MARK: - References

  /// Every use of the name under `offset`: from the file alone for a local, otherwise from the files whose filter may
  /// hold it, each scanned and checked against the file's own scopes.
  public func references(path: String, source: SourceFile, offset: Int, includeDeclaration: Bool = true, scope: ReferenceScope = .workspace) -> [SourceLocation] {
    guard let index = source.nameToken(at: offset) else { return [] }
    let token = source.tokens[index]
    let name = UnsafeBufferPointer(start: source.text + token.start, count: token.length)
    let resolved = resolve(path: path, source: source, offset: offset)
    let top = resolved.first

    // A local stays inside its scope.
    if let top, top.symbol.isLocal, top.path == path {
      return occurrences(in: source, path: path, name: name, within: top.symbol, targets: nil, includeDeclaration: includeDeclaration)
    }
    let hash = hashName(source.text + token.start, token.length)
    var targets: Set<TargetKey>? = nil
    let distinct = declarations(named: name, hash: hash)
    // Several declarations: a use counts when it resolves to one of the same answers, or to nothing.
    if distinct.count > 1, !resolved.isEmpty {
      targets = Set(resolved.map { TargetKey(path: $0.path, offset: $0.symbol.offset) })
    }

    if case .file = scope {
      return occurrences(in: source, path: path, name: name, within: nil, targets: targets, includeDeclaration: includeDeclaration)
    }

    let family = source.profile.family
    var candidates: [String] = []
    for file in files {
      guard let file, file.family == family, documents[file.path] == nil, file.path != path else { continue }
      if file.filter.mayContain(hash: hash) { candidates.append(file.path) }
    }
    var results = occurrences(in: source, path: path, name: name, within: nil, targets: targets, includeDeclaration: includeDeclaration)
    for (other, document) in documents where other != path && document.profile.family == family {
      results += occurrences(in: document, path: other, name: name, within: nil, targets: targets, includeDeclaration: includeDeclaration)
    }

    // Other files in parallel. Each needs its own text and tokens only; resolving a use reads this index, which nothing
    // writes meanwhile.
    let nameBytes = Array(name)
    let parts = LockedResults()
    let order = candidates
    let isolated = UnsafeSendable(self)
    let filteredTargets = targets
    DispatchQueue.concurrentPerform(iterations: FileWalk.threadCount) { _ in
      while let next = parts.next(of: order.count) {
        let other = order[next]
        guard let bytes = FileWalk.read(other) else { continue }
        let profile = isolated.value.file(path: other)?.profile ?? source.profile
        let file = SourceFile(bytes: bytes, profile: profile)
        let found = nameBytes.withUnsafeBufferPointer {
          isolated.value.occurrences(in: file, path: other, name: $0, within: nil, targets: filteredTargets, includeDeclaration: includeDeclaration, parallel: true)
        }
        if !found.isEmpty { parts.add(found) }
      }
    }
    results += parts.all
    return results
  }

  public enum ReferenceScope: Sendable { case workspace, file }

  struct TargetKey: Hashable {
    var path: String
    var offset: UInt32
  }

  /// The uses of a name in one text.
  func occurrences(
    in source: SourceFile, path: String, name: UnsafeBufferPointer<UInt8>, within local: Symbol?, targets: Set<TargetKey>?,
    includeDeclaration: Bool, parallel: Bool = false
  ) -> [SourceLocation] {
    var found: [SourceLocation] = []
    let t = source.text
    let tokens = source.tokens
    let symbols = source.symbols
    let lower = local.map { Int($0.scopeStart) } ?? 0
    let upper = local.map { Int($0.scopeEnd) } ?? source.count
    var index = lower == 0 ? 0 : source.tokenIndex(at: lower)
    // Locals of this name here: inside their scopes the name means them, not the workspace's declaration.
    let shadows = local == nil ? symbols.symbols.filter { $0.isLocal && symbols.nameEquals($0, name) } : []
    while index < tokens.count {
      let token = tokens[index]
      if token.start > upper { break }
      if token.length == name.count, memcmp(t + token.start, name.baseAddress!, name.count) == 0 {
        switch token.kind {
        case .identifier, .keyword, .declarationKeyword:
          let isDeclaration = symbols.symbols.contains { Int($0.offset) == token.start && symbols.nameEquals($0, name) }
          var keep = includeDeclaration || !isDeclaration
          if keep, local == nil {
            for shadow in shadows where Int(shadow.scopeStart) <= token.start && token.start <= Int(shadow.scopeEnd) && Int(shadow.offset) <= token.start {
              keep = false
              break
            }
          }
          if keep, let targets, !isDeclaration || !targets.contains(TargetKey(path: path, offset: token.offset)) {
            // `isDeclaration` of another symbol of this name isn't one of ours.
            if isDeclaration {
              keep = false
            } else {
              let answers = parallel ? resolveReadOnly(path: path, source: source, tokenIndex: index) : resolve(path: path, source: source, tokenIndex: index)
              if !answers.isEmpty, !answers.contains(where: { targets.contains(TargetKey(path: $0.path, offset: $0.symbol.offset)) }) { keep = false }
            }
          }
          if keep { found.append(location(path: path, source: source, start: token.start, end: token.end)) }
        default: break
        }
      }
      index += 1
    }
    return found
  }

  /// `resolve` without following a receiver into another file's text: the recently read files' cache isn't for threads.
  private func resolveReadOnly(path: String, source: SourceFile, tokenIndex: Int) -> [Resolved] {
    resolve(path: path, source: source, tokenIndex: tokenIndex, depth: 3)
  }

  // MARK: - Lists

  /// Declarations whose name fuzzily matches a query, best first.
  public func workspaceSymbols(query: String, limit: Int = 200) -> [(name: String, kind: SymbolKind, path: String, offset: Int, container: String?)] {
    let needle = Array(query.lowercased().utf8)
    var scored: [(score: Int, file: Int, symbol: Int)] = []
    for (fileIndex, file) in files.enumerated() {
      guard let file else { continue }
      file.symbols.names.withUnsafeBufferPointer { names in
        for (symbolIndex, symbol) in file.symbols.symbols.enumerated() where !symbol.isLocal {
          let name = UnsafeBufferPointer(rebasing: names[Int(symbol.nameOffset)..<Int(symbol.nameOffset) + Int(symbol.nameLength)])
          let score = fuzzyScore(needle, name)
          guard score > 0 else { continue }
          let boost = symbol.kind.isType ? 3 : symbol.kind.isCallable ? 2 : symbol.parent < 0 ? 1 : 0
          scored.append((score * 4 + boost, fileIndex, symbolIndex))
        }
      }
    }
    scored.sort { $0.score > $1.score }
    return scored.prefix(limit).compactMap { item in
      guard let file = files[item.file] else { return nil }
      let symbol = file.symbols.symbols[item.symbol]
      let container = symbol.parent >= 0 ? file.symbols.name(file.symbols.symbols[Int(symbol.parent)]) : nil
      return (file.symbols.name(symbol), symbol.kind, file.path, Int(symbol.offset), container)
    }
  }

  /// A declaration Open Quickly found: its name, kind, where it is and the declarations it's inside.
  public struct SymbolMatch: Sendable {
    public var name: String
    public var kind: SymbolKind
    public var path: String
    /// Where the name is in the file, in bytes.
    public var offset: Int
    /// The declarations it's inside, outermost first (`Outer`, `Inner` for `Outer.Inner.value`).
    public var containers: [String]
    /// The part of the query matched against the name (after the last `.` or `::`), for highlighting.
    public var nameQuery: String
  }

  /// Declarations for Open Quickly, best first. The query is fuzzy like `workspaceSymbols`, and may be qualified:
  /// `Some.value` (or `Some::value`) finds members fuzzily named `value` whose container's name fuzzily matches `Some`
  /// (a type, or an extension of it), `A.B.c` the chain of containers outward, and `Some.` every member of `Some`.
  public func searchSymbols(_ query: String, limit: Int = 100) -> [SymbolMatch] {
    let parts = query.filter { !$0.isWhitespace }.replacingOccurrences(of: "::", with: ".")
      .split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard let last = parts.last else { return [] }
    let outer = parts.dropLast().filter { !$0.isEmpty }
    // Nothing to match ("" or "."), or a name with no container ("value", ".value").
    guard !last.isEmpty || !outer.isEmpty else { return [] }
    let needle = Array(last.lowercased().utf8)
    let containerNeedles = outer.reversed().map { Array($0.lowercased().utf8) }

    var scored: [(score: Int, file: Int, symbol: Int)] = []
    for (fileIndex, file) in files.enumerated() {
      guard let file else { continue }
      let symbols = file.symbols.symbols
      file.symbols.names.withUnsafeBufferPointer { names in
        func name(_ symbol: Symbol) -> UnsafeBufferPointer<UInt8> {
          UnsafeBufferPointer(rebasing: names[Int(symbol.nameOffset)..<Int(symbol.nameOffset) + Int(symbol.nameLength)])
        }
        for (symbolIndex, symbol) in symbols.enumerated() where !symbol.isLocal {
          var score = needle.isEmpty ? 1 : fuzzyScore(needle, name(symbol))
          guard score > 0 else { continue }
          // Each container from the innermost must match, one parent at a time.
          var parent = symbol.parent
          var matched = true
          for containerNeedle in containerNeedles {
            guard parent >= 0 else { matched = false; break }
            let container = symbols[Int(parent)]
            let containerScore = fuzzyScore(containerNeedle, name(container))
            guard containerScore > 0 else { matched = false; break }
            score += containerScore
            parent = container.parent
          }
          guard matched else { continue }
          let boost = containerNeedles.isEmpty
            ? (symbol.kind.isType ? 3 : symbol.kind.isCallable ? 2 : symbol.parent < 0 ? 1 : 0)
            : (symbol.kind == .extension ? 0 : 1)
          scored.append((score * 4 + boost, fileIndex, symbolIndex))
        }
      }
    }
    scored.sort { $0.score != $1.score ? $0.score > $1.score : ($0.file, $0.symbol) < ($1.file, $1.symbol) }
    return scored.prefix(limit).compactMap { item in
      guard let file = files[item.file] else { return nil }
      let symbols = file.symbols.symbols
      let symbol = symbols[item.symbol]
      var containers: [String] = []
      var parent = symbol.parent
      while parent >= 0 {
        containers.insert(file.symbols.name(symbols[Int(parent)]), at: 0)
        parent = symbols[Int(parent)].parent
      }
      return SymbolMatch(
        name: file.symbols.name(symbol), kind: symbol.kind, path: file.path, offset: Int(symbol.offset),
        containers: containers, nameQuery: last)
    }
  }

  /// A completion's candidates at an offset.
  public struct Completion: Sendable {
    public var label: String
    public var kind: SymbolKind?
    public var score: Int
    public var detail: String?
  }

  /// What can be written at `offset`: locals in scope, the file's and the receiver's members, the workspace's
  /// declarations and the language's keywords, by the prefix already typed.
  public func completions(path: String, source: SourceFile, offset: Int, limit: Int = 150) -> [Completion] {
    let t = source.text
    var start = offset
    let ident = source.profile.ident
    while start > 0, ident[Int(t[start - 1])] != 0 { start -= 1 }
    let prefix = Array(UnsafeBufferPointer(start: t + start, count: offset - start)).map { $0 | ($0 >= 0x41 && $0 <= 0x5A ? 0x20 : 0) }

    // Is it after `.`? Then only members, of the receiver's type when that's known.
    let tokens = source.tokens
    var before = source.tokenIndex(at: start)
    if before > 0 { before -= 1 }
    var receiverType: String?
    var isMember = false
    if before >= 0, before < tokens.count, tokens[before].end == start, tokens[before].kind == .punctuation, isMemberOperator(tokens[before], t, source.profile) {
      isMember = true
      if before >= 1 {
        let receiver = tokens[before - 1]
        if receiver.kind == .identifier || receiver.kind == .keyword {
          let text = source.string(receiver)
          if text == "self" || text == "this" {
            receiverType = enclosingTypeName(source: source, at: start)
          } else if let c = text.utf8.first, c >= 0x41, c <= 0x5A {
            receiverType = text
          } else if let found = resolve(path: path, source: source, tokenIndex: before - 1, depth: 1).first {
            receiverType = declaredType(of: found)
          }
        }
      }
    }

    var results: [String: Completion] = [:]
    func consider(_ name: UnsafeBufferPointer<UInt8>, kind: SymbolKind?, score: Int, detail: @autoclosure () -> String?) {
      let quality = prefixScore(prefix, name)
      guard quality > 0, name.count > prefix.count || !prefix.isEmpty else { return }
      let total = quality * 8 + score
      let label = String(decoding: name, as: UTF8.self)
      if let existing = results[label], existing.score >= total { return }
      results[label] = Completion(label: label, kind: kind, score: total, detail: detail())
    }

    let symbols = source.symbols
    symbols.names.withUnsafeBufferPointer { names in
      for symbol in symbols.symbols {
        let name = UnsafeBufferPointer(rebasing: names[Int(symbol.nameOffset)..<Int(symbol.nameOffset) + Int(symbol.nameLength)])
        if symbol.isLocal {
          guard !isMember, Int(symbol.scopeStart) <= start, start <= Int(symbol.scopeEnd), Int(symbol.offset) < start else { continue }
          consider(name, kind: symbol.kind, score: 60, detail: nil)
        } else if !isMember || symbol.parent >= 0 {
          consider(name, kind: symbol.kind, score: 30, detail: nil)
        }
      }
    }
    let family = source.profile.family
    for file in files {
      guard let file, file.family == family, file.path != path else { continue }
      file.symbols.names.withUnsafeBufferPointer { names in
        for symbol in file.symbols.symbols where !symbol.isLocal {
          let parent = symbol.parent >= 0 ? file.symbols.symbols[Int(symbol.parent)] : nil
          if isMember, parent == nil { continue }
          if !isMember, parent != nil, !symbol.kind.isType { continue }
          let name = UnsafeBufferPointer(rebasing: names[Int(symbol.nameOffset)..<Int(symbol.nameOffset) + Int(symbol.nameLength)])
          var score = 10
          if isMember, let receiverType, let parent, file.symbols.name(parent) == receiverType { score = 100 }
          consider(name, kind: symbol.kind, score: score, detail: nil)
        }
      }
    }
    if !isMember {
      for word in source.profile.spec.keywords {
        var bytes = Array(word.utf8)
        bytes.withUnsafeMutableBufferPointer { consider(UnsafeBufferPointer($0), kind: nil, score: 5, detail: nil) }
      }
    }
    var sorted = Array(results.values)
    if isMember, receiverType != nil, sorted.contains(where: { $0.score >= 100 }) {
      sorted = sorted.filter { $0.score >= 100 }
    }
    sorted.sort { $0.score != $1.score ? $0.score > $1.score : $0.label < $1.label }
    return Array(sorted.prefix(limit))
  }

  // MARK: - Hover and signatures

  /// A declaration's first line(s) and the documentation above it.
  public func describe(_ resolved: Resolved) -> String? {
    guard let source = source(path: resolved.path) else { return nil }
    let tokens = source.tokens
    let index = source.tokenIndex(at: Int(resolved.symbol.offset))
    let t = source.text
    // Its signature: from the declaration's start up to its body or the line's end, over brackets left open.
    var i = source.tokenIndex(at: Int(resolved.symbol.start))
    let first = i
    var depth = 0
    var end = Int(resolved.symbol.offset) + Int(resolved.symbol.nameLength)
    while i < tokens.count, i < index + 256 {
      let token = tokens[i]
      if token.kind == .open {
        if t[token.start] == 0x7B, i > index, !(resolved.symbol.kind.isValue) { break }
        depth += 1
      } else if token.kind == .close {
        depth -= 1
        if depth < 0 { break }
      }
      if depth == 0, i > index, i > first, source.lines.line(of: token.start) != source.lines.line(of: end) { break }
      if i >= index || depth >= 0 { end = max(end, token.end) }
      i += 1
    }
    let signature = source.string(from: Int(resolved.symbol.start), to: end)
      .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    // The comments right above it.
    var docs: [String] = []
    var above = first - 1
    var lineAbove = source.lines.line(of: Int(resolved.symbol.start)) - 1
    while above >= 0, tokens[above].kind == .comment || tokens[above].kind == .docComment || tokens[above].kind == .attribute {
      let token = tokens[above]
      if token.kind != .attribute {
        guard source.lines.line(of: token.end) >= lineAbove else { break }
        docs.insert(cleanComment(source.string(token)), at: 0)
      }
      lineAbove = source.lines.line(of: token.start) - 1
      above -= 1
    }
    var text = "```\(source.profile.spec.aliases.first ?? "")\n\(signature)\n```"
    if !docs.isEmpty { text += "\n\n" + docs.joined(separator: "\n") }
    return text
  }

  private func cleanComment(_ text: String) -> String {
    var lines: [String] = []
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
      var line = raw.trimmingCharacters(in: .whitespaces)
      for marker in ["///", "//!", "//", "/**", "/*", "*/", "#'", "#", "--", "*"] where line.hasPrefix(marker) {
        line.removeFirst(marker.count)
        break
      }
      if line.hasSuffix("*/") { line.removeLast(2) }
      lines.append(line.hasPrefix(" ") ? String(line.dropFirst()) : line)
    }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The call around `offset`: its declarations' signatures and which argument the cursor is in.
  public func signature(path: String, source: SourceFile, offset: Int) -> (labels: [String], parameter: Int)? {
    let tokens = source.tokens
    let t = source.text
    var index = min(source.tokenIndex(at: offset), tokens.count) - 1
    var depth = 0
    var commas = 0
    while index >= 0 {
      let token = tokens[index]
      if token.end <= offset || token.start < offset {
        if token.kind == .close { depth += 1 } else if token.kind == .open {
          if depth == 0 {
            guard t[token.start] == 0x28, index > 0, tokens[index - 1].kind == .identifier || tokens[index - 1].kind == .keyword else { return nil }
            let answers = resolve(path: path, source: source, tokenIndex: index - 1)
            let labels = answers.compactMap { describe($0) }.map { text -> String in
              // Only the signature line.
              let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
              return lines.count > 1 ? String(lines[1]) : text
            }
            return labels.isEmpty ? nil : (labels, commas)
          }
          depth -= 1
        } else if depth == 0, token.length == 1, t[token.start] == 0x2C {
          commas += 1
        } else if depth == 0, token.length == 1, t[token.start] == 0x3B {
          return nil
        }
      }
      index -= 1
    }
    return nil
  }

  // MARK: - Rename

  /// The new text for a rename, or nil when the name can't be told apart: only a local, or a name declared once, moves
  /// without a compiler's say.
  public func renameLocations(path: String, source: SourceFile, offset: Int) -> [SourceLocation]? {
    guard let index = source.nameToken(at: offset), source.tokens[index].kind == .identifier else { return nil }
    let token = source.tokens[index]
    let name = UnsafeBufferPointer(start: source.text + token.start, count: token.length)
    let resolved = resolve(path: path, source: source, offset: offset)
    guard let top = resolved.first else { return nil }
    if !top.symbol.isLocal {
      let distinct = declarations(named: name, hash: hashName(source.text + token.start, token.length))
      guard distinct.count == 1 else { return nil }
    }
    return references(path: path, source: source, offset: offset)
  }
}

/// Larger is better; 0 is no match.
private func fuzzyScore(_ needle: [UInt8], _ name: UnsafeBufferPointer<UInt8>) -> Int {
  if needle.isEmpty { return 1 }
  guard name.count >= needle.count else { return 0 }
  var score = 0
  var at = 0
  var previousMatched = false
  for (index, raw) in name.enumerated() {
    let c = raw >= 0x41 && raw <= 0x5A ? raw | 0x20 : raw
    if c == needle[at] {
      score += 1
      if index == 0 { score += 8 }
      if previousMatched { score += 3 }
      // A word start: `fooBar`'s B, `foo_bar`'s b.
      if index > 0, raw >= 0x41, raw <= 0x5A { score += 3 } else if index > 0, name[index - 1] == 0x5F { score += 3 }
      at += 1
      previousMatched = true
      if at == needle.count {
        if needle.count == name.count { score += 20 }
        return score
      }
    } else {
      previousMatched = false
    }
  }
  return 0
}

/// 4 for the exact case-insensitive prefix, 1 for letters in order; 0 for none.
private func prefixScore(_ prefix: [UInt8], _ name: UnsafeBufferPointer<UInt8>) -> Int {
  if prefix.isEmpty { return 1 }
  guard name.count >= prefix.count else { return 0 }
  var isPrefix = true
  for index in prefix.indices {
    let raw = name[index]
    if (raw >= 0x41 && raw <= 0x5A ? raw | 0x20 : raw) != prefix[index] {
      isPrefix = false
      break
    }
  }
  if isPrefix { return 4 }
  return fuzzyScore(prefix, name) > 0 ? 1 : 0
}

private final class LockedResults: @unchecked Sendable {
  private let lock = NSLock()
  private var cursor = 0
  private(set) var all: [SourceLocation] = []

  func next(of count: Int) -> Int? {
    lock.lock()
    defer { lock.unlock() }
    guard cursor < count else { return nil }
    cursor += 1
    return cursor - 1
  }

  func add(_ found: [SourceLocation]) {
    lock.lock()
    all += found
    lock.unlock()
  }
}

private struct UnsafeSendable<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}
