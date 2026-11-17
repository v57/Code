import CodeModel
import CodeScan
import Foundation

/// A name a body declares: a parameter, a local variable (a `for`'s, a `catch`'s, a lambda's or block's parameter),
/// or a local `typedef`.
struct CLocal {
  var name: Name
  var token: Int32
  var scopeEnd: Int32
  /// The type's tokens: the specifiers, and the declarator from its first `*` to after its `[…]`.
  var typeStart: Int32
  var typeEnd: Int32
  var declaratorStart: Int32
  var declaratorEnd: Int32
  var initStart: Int32 = -1
  var initEnd: Int32 = -1
  /// `for (auto x : range)`, `for (T *x in collection)`: the initializer is what's iterated.
  var isRangeElement = false
  var isTypedef = false
  /// A declaration in the unit's table (none yet: locals are the body's).
  var decl: Int32 = -1
}

/// Layer 4 for the C family: what a function's body declares and where each is visible, and its labels, read once
/// when a position inside asks. A statement is a declaration when it starts with a type (a keyword, `struct x`, a
/// name that is a type here) or reads `Name name …`, `Name *name = …`.
final class CBody: BodyFacts {
  func dropTypes() { types.removeAll() }

  var locals: [CLocal] = []
  var byName: [Name: [Int32]] = [:]
  var labels: [Name: Int32] = [:]
  var types: [Int32: Ty] = [:]

  private let unit: Unit
  private let file: CFile
  private let isType: (Name, Int) -> Bool
  private var typeCache: [Name: Bool] = [:]
  private let isCpp: Bool
  private let isObjC: Bool

  init(unit: Unit, owner: Int32, isType: @escaping (Name, Int) -> Bool) {
    self.unit = unit
    file = unit.cFile
    self.isType = isType
    isCpp = file.dialect.contains(.cpp)
    isObjC = file.dialect.contains(.objc)
    let decl = unit.decls[Int(owner)]
    guard decl.bodyOpen >= 0 else { return }
    for p in 0..<Int(decl.paramCount) {
      let param = unit.params[Int(decl.paramStart) + p]
      guard param.nameToken >= 0 else { continue }
      add(
        CLocal(
          name: param.local, token: param.nameToken, scopeEnd: decl.bodyClose, typeStart: param.typeStart, typeEnd: param.typeEnd,
          declaratorStart: param.nameToken, declaratorEnd: param.nameToken + 1))
    }
    block(Int(decl.bodyOpen) + 1, Int(decl.bodyClose))
  }

  /// In `extern T name;`: the name is the file's, not a local.
  private var declaringExtern = false

  private func add(_ local: CLocal) {
    if declaringExtern { return }
    byName[local.name, default: []].append(Int32(locals.count))
    locals.append(local)
  }

  /// The local a name means at a token: the latest declared before it whose scope holds it.
  func local(named word: Name, at token: Int32) -> CLocal? {
    guard let list = byName[word] else { return nil }
    var best: CLocal?
    for index in list {
      let local = locals[Int(index)]
      guard local.token <= token, token <= local.scopeEnd else { continue }
      if best == nil || local.token > best!.token { best = local }
    }
    return best
  }

  /// Locals in scope at a token, for completion.
  func visible(at token: Int32) -> [CLocal] {
    var seen = Set<Name>()
    var result: [CLocal] = []
    for local in locals.reversed() where local.token < token && token <= local.scopeEnd {
      if seen.insert(local.name).inserted { result.append(local) }
    }
    return result
  }

  // MARK: Statements

  private func skipDirective(_ i: Int) -> Int {
    if layoutConditional(i) { return unit.takeDirective(i) }
    return Int(file.ends[Int32(i)] ?? Int32(i + 1))
  }

  private func layoutConditional(_ i: Int) -> Bool { unit.syntax.conditional(unit, i) != .none }

  /// Where the statement starting at `i` ends (its last token): a block's `}`, else its `;`.
  private func statementEnd(_ from: Int, _ limit: Int) -> Int {
    var i = from
    while i < limit, unit.tokens[i].kind == .directive { i = skipDirective(i) }
    guard i < limit else { return limit }
    if unit.isByte(i, 0x7B) { return unit.skipBalanced(i) - 1 }
    if unit.isToken(i, "if") || unit.isToken(i, "for") || unit.isToken(i, "while") || unit.isToken(i, "switch") {
      if unit.isByte(i + 1, 0x28) {
        var end = statementEnd(unit.skipBalanced(i + 1), limit)
        if unit.isToken(end + 1, "else") { end = statementEnd(end + 2, limit) }
        return end
      }
    }
    while i < limit {
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.isByte(i, 0x3B) { return i }
      i += 1
    }
    return limit
  }

  private func block(_ from: Int, _ to: Int) {
    var i = from
    var atStart = true
    while i < to {
      let token = unit.tokens[i]
      if token.kind == .directive {
        i = skipDirective(i)
        continue
      }
      if unit.isByte(i, 0x7B) {
        let close = min(unit.skipBalanced(i) - 1, to)
        block(i + 1, close)
        i = close + 1
        atStart = true
        continue
      }
      if atStart, unit.isWord(i) {
        if (unit.isToken(i, "for") || unit.isToken(i, "if") || unit.isToken(i, "while") || unit.isToken(i, "switch") || unit.isToken(i, "catch")
          || unit.isToken(i, "@catch")),
          unit.isByte(i + 1, 0x28)
        {
          let open = i + 1
          let close = unit.skipBalanced(open) - 1
          let scopeEnd = statementEnd(close + 1, to)
          // A declaration in the header, then what else is in it (lambdas, blocks).
          var j = open + 1
          if let end = declaration(j, close, scopeEnd: scopeEnd, inHeader: true) { j = end }
          expressions(j, close)
          i = close + 1
          atStart = true
          continue
        }
        if unit.isToken(i, "else") || unit.isToken(i, "do") || unit.isToken(i, "try") || unit.isToken(i, "@try") || unit.isToken(i, "@finally")
          || unit.isToken(i, "@autoreleasepool")
        {
          i += 1
          continue
        }
        if unit.isToken(i, "case") || unit.isToken(i, "default") {
          while i < to, !(unit.isByte(i, 0x3A) || unit.isToken(i, ":")) { i += 1 }
          i += 1
          continue
        }
        if unit.tokens[i].kind == .identifier, unit.isByte(i + 1, 0x3A) || (unit.isToken(i + 1, ":") && !unit.isToken(i + 1, "::")) {
          labels[unit.hash(i)] = Int32(i)
          i += 2
          continue
        }
        if let end = declaration(i, to, scopeEnd: to, inHeader: false) {
          i = end
          atStart = true
          continue
        }
      }
      if unit.isByte(i, 0x3B) || unit.isByte(i, 0x7D) {
        i += 1
        atStart = true
        continue
      }
      i = expression(i, to)
      atStart = false
    }
  }

  /// One token of an expression, or a lambda or block from it: returns where to go on.
  private func expression(_ i: Int, _ limit: Int) -> Int {
    // `[captures](params) … {body}`: a lambda; `[x y]` (a message) and `a[i]` (a subscript) aren't.
    if isCpp, unit.isByte(i, 0x5B), !(i > 0 && (unit.isWord(i - 1) || unit.tokens[i - 1].kind == .close || unit.isByte(i - 1, 0x5D))) {
      let close = unit.skipBalanced(i) - 1
      var j = close + 1
      if unit.isByte(j, 0x28) || unit.isByte(j, 0x7B) {
        var params: (Int, Int)?
        if unit.isByte(j, 0x28) {
          params = (j, unit.skipBalanced(j) - 1)
          j = params!.1 + 1
        }
        while j < limit, !unit.isByte(j, 0x7B), !unit.isByte(j, 0x3B) {
          j = unit.tokens[j].kind == .open ? unit.skipBalanced(j) : j + 1
        }
        if unit.isByte(j, 0x7B) {
          let bodyClose = unit.skipBalanced(j) - 1
          if let params { parameters(params.0, params.1, scopeEnd: bodyClose) }
          block(j + 1, bodyClose)
          return bodyClose + 1
        }
      }
    }
    // `^(int a) {…}`, `^ReturnType (int a) {…}`, `^{…}`: a block.
    if unit.isByte(i, 0x5E), !(i > 0 && (unit.isWord(i - 1) || unit.tokens[i - 1].kind == .close || unit.tokens[i - 1].kind == .number)) {
      var j = i + 1
      var params: (Int, Int)?
      while j < limit, j < i + 8, !unit.isByte(j, 0x7B) {
        if unit.isByte(j, 0x28) {
          params = (j, unit.skipBalanced(j) - 1)
          j = params!.1 + 1
          continue
        }
        guard unit.isWord(j) || unit.startsWith(j, 0x2A) else { break }
        j += 1
      }
      if unit.isByte(j, 0x7B) {
        let bodyClose = unit.skipBalanced(j) - 1
        if let params { parameters(params.0, params.1, scopeEnd: bodyClose) }
        block(j + 1, bodyClose)
        return bodyClose + 1
      }
    }
    // A statement expression `({ … })` and the braces of a lambda's body are blocks.
    if unit.isByte(i, 0x28), unit.isByte(i + 1, 0x7B) {
      let close = unit.skipBalanced(i + 1) - 1
      block(i + 2, close)
      return close + 1
    }
    return i + 1
  }

  private func expressions(_ from: Int, _ to: Int) {
    var i = from
    while i < to {
      if unit.tokens[i].kind == .directive {
        i = skipDirective(i)
        continue
      }
      i = expression(i, to)
    }
  }

  /// A parameter list's names as locals of a body.
  private func parameters(_ open: Int, _ close: Int, scopeEnd: Int) {
    var i = open + 1
    while i < close {
      var j = i
      while j < close, !unit.isByte(j, 0x2C) { j = unit.tokens[j].kind == .open ? unit.skipBalanced(j) : j + 1 }
      if let nameToken = parameterName(i, j), nameToken >= 0 {
        add(
          CLocal(
            name: unit.hash(nameToken), token: Int32(nameToken), scopeEnd: Int32(scopeEnd), typeStart: Int32(i), typeEnd: Int32(j),
            declaratorStart: Int32(nameToken), declaratorEnd: Int32(nameToken + 1)))
      }
      i = j + 1
    }
  }

  private func parameterName(_ start: Int, _ end: Int) -> Int? {
    var last: Int?
    var words = 0
    var sawType = false
    var i = start
    while i < end {
      if unit.isByte(i, 0x3D) { break }
      if unit.tokens[i].kind == .open {
        i = unit.skipBalanced(i)
        continue
      }
      if unit.isWord(i) {
        if CWord.typeKeywords.contains(unit.hash(i)) || unit.isToken(i, "struct") || unit.isToken(i, "enum") || unit.isToken(i, "union") {
          sawType = true
        } else if !CWord.qualifiers.contains(unit.hash(i)), !unit.isToken(i + 1, "::") {
          words += 1
          last = i
        }
      }
      i += 1
    }
    guard let last, words >= 2 || (sawType && words >= 1) else { return nil }
    if last > start, unit.isToken(last - 1, "struct") || unit.isToken(last - 1, "enum") || unit.isToken(last - 1, "union") { return nil }
    return last
  }

  // MARK: Declarations

  private func knownType(_ i: Int) -> Bool {
    let word = unit.hash(i)
    if let known = typeCache[word] { return known }
    let result = isType(word, i)
    typeCache[word] = result
    return result
  }

  /// A path's end: `A::B<int>::C` from A, past its last name (and template arguments).
  private func pathEnd(_ i: Int, _ limit: Int) -> Int {
    var j = i + 1
    while j < limit {
      if isCpp || isObjC, unit.startsWith(j, 0x3C), !unit.isToken(j, "<<"), !unit.isToken(j, "<="), let close = angleClose(j, limit) {
        j = close
        continue
      }
      if unit.isToken(j, "::"), unit.isWord(j + 1) {
        j += 2
        continue
      }
      break
    }
    return j
  }

  /// Past a template's arguments, when they close before anything that can't be in them.
  private func angleClose(_ open: Int, _ limit: Int) -> Int? {
    var depth = 0
    var i = open
    while i < limit {
      let token = unit.tokens[i]
      if token.kind == .open {
        if unit.isByte(i, 0x7B) { return nil }
        i = unit.skipBalanced(i)
        continue
      }
      if token.kind == .close || unit.isByte(i, 0x3B) || unit.isToken(i, "&&") || unit.isToken(i, "||") { return nil }
      if token.kind == .punctuation {
        let text = unit.source.text + token.start
        for k in 0..<token.length {
          if text[k] == 0x3C { depth += 1 }
          if text[k] == 0x3E, !(k > 0 && text[k - 1] == 0x2D) {
            depth -= 1
            if depth == 0 { return i + 1 }
          }
          if text[k] == 0x3D, k == 0, token.length == 1 { return nil }
        }
      }
      i += 1
    }
    return nil
  }

  /// A declaration statement from `start`, its locals added: where it ends, nil if it's no declaration.
  /// `&name =`, `&name;`, `&name :`, `&name{`: a reference's declarator from its `&`.
  private func referenceDeclarator(_ at: Int, _ limit: Int) -> Bool {
    var k = at
    while k < limit, unit.tokens[k].kind == .punctuation, unit.startsWith(k, 0x26) { k += 1 }
    guard k < limit, unit.tokens[k].kind == .identifier else { return false }
    let after = k + 1
    return unit.isAssign(after) || unit.isByte(after, 0x3B) || unit.isByte(after, 0x3A) || unit.isByte(after, 0x7B) || unit.isByte(after, 0x2C) || unit.isByte(after, 0x28)
  }

  private func declaration(_ start: Int, _ limit: Int, scopeEnd: Int, inHeader: Bool) -> Int? {
    declaringExtern = false
    defer { declaringExtern = false }
    var i = start
    var sawType = false
    var isTypedef = false
    var unknownName: Int?
    while i < limit {
      if unit.tokens[i].kind == .directive {
        i = skipDirective(i)
        continue
      }
      guard unit.isWord(i) else { break }
      let word = unit.hash(i)
      if word == CWord.typedefWord {
        isTypedef = true
        i += 1
        continue
      }
      if CWord.typeKeywords.contains(word) {
        sawType = true
        i += 1
        continue
      }
      if CWord.storage.contains(word) || CWord.qualifiers.contains(word) || unit.isToken(i, "__unused") || unit.isToken(i, "__auto_type") {
        if unit.isToken(i, "__auto_type") { sawType = true }
        if unit.isToken(i, "extern") { declaringExtern = true }
        i += 1
        continue
      }
      if CWord.attributes.contains(word) {
        i = unit.isByte(i + 1, 0x28) ? unit.skipBalanced(i + 1) : i + 1
        continue
      }
      if CWord.typeofWords.contains(word), unit.isByte(i + 1, 0x28) {
        sawType = true
        i = unit.skipBalanced(i + 1)
        continue
      }
      if word == CWord.structWord || word == CWord.unionWord || word == CWord.enumWord || (word == CWord.classWord && isCpp) {
        sawType = true
        i += 1
        if unit.isWord(i), !unit.isByte(i, 0x7B) { i = pathEnd(i, limit) }
        if unit.isByte(i, 0x7B) { i = unit.skipBalanced(i) }
        continue
      }
      if word == CWord.typenameWord {
        i += 1
        continue
      }
      guard unit.tokens[i].kind == .identifier, !sawType else { break }
      // A name: the type's, when another name or a declarator follows.
      let end = pathEnd(i, limit)
      if unit.isWord(end) || knownType(end - 1 < i ? i : lastWord(i, end)) && (unit.startsWith(end, 0x2A) || unit.startsWith(end, 0x26) || unit.startsWith(end, 0x5E)) {
        sawType = true
        i = end
        continue
      }
      if unit.startsWith(end, 0x2A) || (unit.startsWith(end, 0x26) && isCpp && referenceDeclarator(end, limit)) {
        // `Name *name =`: a declaration whatever Name is; `a * b` alone is no statement anyone writes. `Name &name`
        // only in C++ and followed by what ends a declarator: `a & b` is a condition's mask.
        unknownName = i
        sawType = true
        i = end
        continue
      }
      return nil
    }
    guard sawType else { return nil }
    let specifiersEnd = i
    var added = 0
    var j = i
    while j < limit {
      let declaratorStart = j
      while j < limit, unit.tokens[j].kind == .punctuation, unit.startsWith(j, 0x2A) || unit.startsWith(j, 0x26) || unit.startsWith(j, 0x5E) { j += 1 }
      while j < limit, unit.isWord(j), CWord.qualifiers.contains(unit.hash(j)) { j += 1 }
      var nameToken: Int?
      if unit.isByte(j, 0x28) {
        // `(*name)(…)`, `(^name)(…)`.
        let close = unit.skipBalanced(j) - 1
        var k = j + 1
        while k < close, !unit.isWord(k) || CWord.qualifiers.contains(unit.hash(k)) { k += 1 }
        guard k < close, unit.tokens[k].kind == .identifier, unit.startsWith(j + 1, 0x2A) || unit.startsWith(j + 1, 0x5E) else { break }
        nameToken = k
        j = close + 1
      } else if isCpp, unit.isByte(j, 0x5B), added == 0 {
        // `auto [a, b] = …`.
        let close = unit.skipBalanced(j) - 1
        var k = j + 1
        while k < close {
          if unit.tokens[k].kind == .identifier {
            add(
              CLocal(
                name: unit.hash(k), token: Int32(k), scopeEnd: Int32(scopeEnd), typeStart: Int32(start), typeEnd: Int32(specifiersEnd),
                declaratorStart: Int32(k), declaratorEnd: Int32(k + 1)))
          }
          k += 1
        }
        j = close + 1
        added += 1
        nameToken = nil
      } else if unit.tokens[j].kind == .identifier {
        nameToken = j
        j += 1
      } else {
        break
      }
      while unit.isByte(j, 0x5B) || unit.isByte(j, 0x28) {
        // Arrays, a function pointer's parameters, C++'s `T x(args)`.
        j = unit.skipBalanced(j)
      }
      while unit.isWord(j), unit.isMacroLike(j) || CWord.attributes.contains(unit.hash(j)) { j = unit.isByte(j + 1, 0x28) ? unit.skipBalanced(j + 1) : j + 1 }
      let declaratorEnd = j
      var local: CLocal?
      if let nameToken {
        local = CLocal(
          name: unit.hash(nameToken), token: Int32(nameToken), scopeEnd: Int32(scopeEnd), typeStart: Int32(start), typeEnd: Int32(specifiersEnd),
          declaratorStart: Int32(declaratorStart), declaratorEnd: Int32(declaratorEnd))
        local?.isTypedef = isTypedef
      }
      if unit.isAssign(j) || (isCpp && unit.isByte(j, 0x7B)) {
        let initStart = unit.isByte(j, 0x7B) ? j : j + 1
        var k = initStart
        while k < limit, !unit.isByte(k, 0x2C), !unit.isByte(k, 0x3B) {
          if unit.tokens[k].kind == .directive {
            k = skipDirective(k)
            continue
          }
          k = unit.tokens[k].kind == .open ? unit.skipBalanced(k) : k + 1
        }
        local?.initStart = Int32(initStart)
        local?.initEnd = Int32(k)
        // Lambdas and blocks in the initializer.
        if let local { add(local) }
        expressions(initStart, k)
        j = k
      } else if inHeader, unit.isByte(j, 0x3A) || unit.isToken(j, ":") || unit.isToken(j, "in") {
        local?.initStart = Int32(j + 1)
        local?.initEnd = Int32(limit)
        local?.isRangeElement = true
        if let local { add(local) }
        expressions(j + 1, limit)
        return limit
      } else if let local {
        // Without an initializer, a name of unknown type has to end the statement or be one of several.
        if unknownName != nil, added == 0, !(unit.isByte(j, 0x3B) || unit.isByte(j, 0x2C) || unit.isByte(j, 0x29) || j == limit) { return nil }
        add(local)
      }
      added += 1
      if unit.isByte(j, 0x2C) {
        j += 1
        continue
      }
      break
    }
    guard added > 0 else { return nil }
    if unit.isByte(j, 0x3B) { return j + 1 }
    return j
  }

  private func lastWord(_ start: Int, _ end: Int) -> Int {
    var k = end - 1
    while k > start, !unit.isWord(k) { k -= 1 }
    return k
  }
}
