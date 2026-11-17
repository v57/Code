import CodeModel
import CodeScan
import Foundation

/// A script's tokens read again in the shell's own terms, from CodeScan's (as C reads a directive's line again):
///
/// - a word of name bytes, `-`, `.` and `/` written together is one identifier (`my-func`, `./build.sh`, `--force`),
///   unless it follows a `$` or is in arithmetic (`$((a-b))`, `arr[i-1]`), where `-` is an operator;
/// - punctuation with a `$` in it splits there (`=$x` is `=`, `$`, `x`);
/// - an expanding string (`"…"`, a here-document whose word isn't quoted, PowerShell's `"…"` and `@"…"@`) has its
///   expansions as tokens: `$name` (PowerShell's `$scope:name` too) as `$` and the name, `${…}`, `$(…)` and `` `…` ``
///   lexed again as code; what's around them stays string.
struct ScriptTokens {
  let source: SourceFile
  let dialect: ScriptDialect
  var out: [Token] = []

  init(source: SourceFile, dialect: ScriptDialect) {
    self.source = source
    self.dialect = dialect
  }

  @inline(__always) func byte(_ offset: Int) -> UInt8 { offset < source.count ? source.text[offset] : 0 }

  static func isNameStart(_ b: UInt8) -> Bool { b == 0x5F || (b | 0x20 >= 0x61 && b | 0x20 <= 0x7A) }
  static func isNameByte(_ b: UInt8) -> Bool { isNameStart(b) || (b >= 0x30 && b <= 0x39) }

  /// Reads the source's tokens (comments dropped).
  static func read(_ source: SourceFile, dialect: ScriptDialect) -> [Token] {
    var reader = ScriptTokens(source: source, dialect: dialect)
    var kept: [Token] = []
    kept.reserveCapacity(source.tokens.count)
    for token in source.tokens where token.kind != .comment && token.kind != .docComment { kept.append(token) }
    reader.reread(kept, limit: source.count)
    return reader.out
  }

  /// Tokens lexed from a range of the source, as offsets into it.
  func lex(_ start: Int, _ end: Int) -> [Token] {
    guard end > start else { return [] }
    let slice = SourceFile(bytes: UnsafeBufferPointer(start: source.text + start, count: end - start), profile: source.profile)
    var result: [Token] = []
    for token in slice.tokens where token.kind != .comment && token.kind != .docComment {
      result.append(Token(kind: token.kind, start: token.start + start, end: token.end + start))
    }
    return result
  }

  // MARK: Reading again

  /// Tokens read again; `limit` is where their text ends (the file's end, or an expansion's inside a string).
  mutating func reread(_ tokens: [Token], limit: Int) {
    var arithmetic: [Int] = []  // paren depths where arithmetic opened
    var subscripts = 0
    var depth = 0
    var afterInterpolation = false
    var hereDocument: (expands: Bool, bodyStart: Int)?
    var i = 0
    while i < tokens.count {
      let token = tokens[i]
      let previous = i > 0 ? tokens[i - 1] : nil
      let touchesPrevious = previous.map { $0.end == token.start } ?? false
      switch token.kind {
      case .open:
        let b = byte(token.start)
        if b == 0x28 {
          depth += 1
          // `((` and `$((`: arithmetic to the matching `))`.
          if dialect == .shell, i + 1 < tokens.count, tokens[i + 1].kind == .open, byte(tokens[i + 1].start) == 0x28, tokens[i + 1].start == token.end {
            arithmetic.append(depth)
          }
        } else if b == 0x5B, touchesPrevious, let previous, previous.kind == .identifier || byte(previous.start) == 0x7B {
          subscripts += 1
        } else if b == 0x5B, subscripts > 0 {
          subscripts += 1
        }
        out.append(token)
      case .close:
        let b = byte(token.start)
        if b == 0x29 {
          if let last = arithmetic.last, last == depth { arithmetic.removeLast() }
          depth = max(0, depth - 1)
        } else if b == 0x5D, subscripts > 0 {
          subscripts -= 1
        }
        out.append(token)
      case .punctuation:
        if dialect == .shell, hereDocument == nil, token.length >= 3, byte(token.start) == 0x3C, byte(token.start + 1) == 0x3C {
          // `<<EOF`, `<<-EOF`, `<<'EOF'`: the body is the next string token at the next line's start.
          var quoted = false
          for k in token.start..<token.end where byte(k) == 0x27 || byte(k) == 0x22 || byte(k) == 0x5C { quoted = true }
          var lineEnd = token.end
          while lineEnd < source.count, byte(lineEnd) != 0x0A { lineEnd += 1 }
          hereDocument = (!quoted, lineEnd + 1)
          out.append(token)
        } else if dialect == .shell, touchesPrevious, let previous, previous.kind == .identifier, token.length > 1,
          byte(token.start) == 0x3D || (byte(token.start) == 0x2B && byte(token.start + 1) == 0x3D), token.length > (byte(token.start) == 0x3D ? 1 : 2)
        {
          // `x=/path`, `x+=.`: the assignment's `=` on its own, the value's first piece after it.
          let width = byte(token.start) == 0x3D ? 1 : 2
          out.append(Token(kind: .punctuation, start: token.start, end: token.start + width))
          let rest = Token(kind: .punctuation, start: token.start + width, end: token.end)
          if rest.length == 1 || byte(rest.start) == 0x24 || (rest.start..<rest.end).contains(where: { byte($0) == 0x24 }) {
            splitDollars(rest)
          } else {
            out.append(rest)
          }
        } else {
          splitDollars(token)
        }
      case .string:
        let first = byte(token.start)
        if let document = hereDocument, token.start == document.bodyStart {
          hereDocument = nil
          if document.expands { expandString(token.start, token.end) } else { out.append(token) }
        } else if dialect == .shell, first == 0x22 {
          // CodeScan ends the string at a quote inside `${…}` or `$(…)` (`"${x#"$y"}"`): it ends where the shell does.
          let end = max(token.end, stringEnd(token.start, limit: limit))
          while i + 1 < tokens.count, tokens[i + 1].start < end { i += 1 }
          expandString(token.start, end)
        } else if dialect == .shell, afterInterpolation, first != 0x27, first != 0x24 {
          expandString(token.start, token.end)
        } else if dialect == .powerShell, first == 0x22 || (first == 0x40 && byte(token.start + 1) == 0x22) || (afterInterpolation && first != 0x27 && first != 0x40) {
          expandString(token.start, token.end)
        } else {
          out.append(token)
        }
      case .identifier, .keyword, .declarationKeyword, .number:
        let afterDollar = touchesPrevious && previous.map { byte($0.end - 1) == 0x24 || ($0.kind == .open && byte($0.start) == 0x7B && $0.start > 0 && byte($0.start - 1) == 0x24) } == true
        if dialect == .powerShell {
          if afterDollar, token.kind == .identifier, let dash = (token.start..<token.end).first(where: { byte($0) == 0x2D }), dash > token.start {
            // `$a-1`: the name ends at the `-`.
            out.append(Token(kind: .identifier, start: token.start, end: dash))
            out.append(Token(kind: .punctuation, start: dash, end: dash + 1))
            if token.end > dash + 1 { out.append(Token(kind: .identifier, start: dash + 1, end: token.end)) }
          } else {
            out.append(token)
          }
        } else if !afterDollar, arithmetic.isEmpty, subscripts == 0 {
          i = mergeWord(tokens, from: i)
          continue
        } else {
          out.append(token)
        }
      default:
        out.append(token)
      }
      afterInterpolation = token.kind == .interpolationClose
      i += 1
    }
  }

  /// A punctuation token that only joins words: `-`, `--`, `.`, `/`, `./`, `~/`.
  func isWordJoiner(_ token: Token) -> Bool {
    guard token.kind == .punctuation else { return false }
    for k in token.start..<token.end {
      let b = byte(k)
      if b != 0x2D && b != 0x2E && b != 0x2F && b != 0x7E { return false }
    }
    return true
  }

  /// The word token `i` is part of: name tokens and joiners written together, one identifier when it has more than one
  /// token and a name in it. A word starts where no token touches it (joiners already written count: `./x`,
  /// `--force`); a name right after something else (`$x-y`, `"a"b`) stays as it is. Returns the index after it.
  mutating func mergeWord(_ tokens: [Token], from i: Int) -> Int {
    // Joiners already written right before it.
    var taken = 0
    var start = tokens[i].start
    while out.count > taken, out[out.count - 1 - taken].end == start, isWordJoiner(out[out.count - 1 - taken]) {
      start = out[out.count - 1 - taken].start
      taken += 1
    }
    let beforeWord = out.count > taken ? out[out.count - 1 - taken] : nil
    guard beforeWord.map({ $0.end != start }) ?? true else {
      out.append(tokens[i])
      return i + 1
    }
    var j = i
    var end = start
    var hasName = false
    while j < tokens.count {
      let token = tokens[j]
      if token.start != end, j > i { break }
      if token.kind == .identifier || token.kind == .keyword || token.kind == .declarationKeyword {
        hasName = true
      } else if token.kind == .number {
      } else if isWordJoiner(token), j + 1 < tokens.count, tokens[j + 1].start == token.end,
        [TokenKind.identifier, .keyword, .declarationKeyword, .number].contains(tokens[j + 1].kind)
      {
      } else {
        break
      }
      end = token.end
      j += 1
    }
    guard j - i + taken >= 2, hasName else {
      out.append(contentsOf: tokens[i..<max(j, i + 1)])
      return max(j, i + 1)
    }
    out.removeLast(taken)
    out.append(Token(kind: .identifier, start: start, end: end))
    return j
  }

  /// `=$`, `+$`, `$#`: a punctuation token split at each `$` (and at `@` before a `$` in PowerShell), so the `$` is its
  /// own token right before the name it expands.
  mutating func splitDollars(_ token: Token) {
    guard token.length > 1 else {
      out.append(token)
      return
    }
    var from = token.start
    for k in token.start..<token.end where byte(k) == 0x24 {
      if k > from { out.append(Token(kind: .punctuation, start: from, end: k)) }
      out.append(Token(kind: .punctuation, start: k, end: k + 1))
      from = k + 1
    }
    if from < token.end { out.append(Token(kind: .punctuation, start: from, end: token.end)) }
  }

  // MARK: Strings

  /// An expanding string's range: its expansions as tokens, the rest as string pieces.
  mutating func expandString(_ start: Int, _ end: Int) {
    var piece = start
    var k = start
    let escape: UInt8 = dialect == .shell ? 0x5C : 0x60
    func flush(_ to: Int, _ out: inout [Token]) {
      if to > piece { out.append(Token(kind: .string, start: piece, end: to)) }
    }
    while k < end {
      let b = byte(k)
      if b == escape {
        k += 2
        continue
      }
      if b == 0x60, dialect == .shell {
        // `` `cmd` ``: code.
        var close = k + 1
        while close < end, byte(close) != 0x60 {
          if byte(close) == 0x5C { close += 1 }
          close += 1
        }
        guard close < end else { break }
        flush(k, &out)
        out.append(Token(kind: .interpolationOpen, start: k, end: k + 1))
        reread(lex(k + 1, close), limit: close)
        out.append(Token(kind: .interpolationClose, start: close, end: close + 1))
        k = close + 1
        piece = k
        continue
      }
      guard b == 0x24, k + 1 < end else {
        k += 1
        continue
      }
      let next = byte(k + 1)
      if next == 0x7B || next == 0x28 {
        // `${…}`, `$(…)`, `$((…))`: lexed again as code, to the matching bracket.
        guard let close = matching(k + 1, end) else { break }
        flush(k, &out)
        reread(lex(k, close + 1), limit: close + 1)
        k = close + 1
        piece = k
        continue
      }
      if Self.isNameStart(next) {
        var nameEnd = k + 2
        while nameEnd < end, Self.isNameByte(byte(nameEnd)) { nameEnd += 1 }
        // PowerShell's `$script:x`, `$env:PATH`.
        var scopeEnd = -1
        if dialect == .powerShell, byte(nameEnd) == 0x3A, nameEnd + 1 < end, Self.isNameStart(byte(nameEnd + 1)) {
          scopeEnd = nameEnd
          nameEnd += 2
          while nameEnd < end, Self.isNameByte(byte(nameEnd)) { nameEnd += 1 }
        }
        flush(k, &out)
        out.append(Token(kind: .punctuation, start: k, end: k + 1))
        if scopeEnd > 0 {
          out.append(Token(kind: .identifier, start: k + 1, end: scopeEnd))
          out.append(Token(kind: .punctuation, start: scopeEnd, end: scopeEnd + 1))
          out.append(Token(kind: .identifier, start: scopeEnd + 1, end: nameEnd))
        } else {
          out.append(Token(kind: .identifier, start: k + 1, end: nameEnd))
        }
        k = nameEnd
        piece = k
        continue
      }
      k += 1
    }
    flush(end, &out)
  }

  /// Where a shell's `"…"` starting at `start` ends: after its closing quote, expansions and backticks skipped whole.
  func stringEnd(_ start: Int, limit: Int) -> Int {
    var k = start + 1
    while k < limit {
      let b = byte(k)
      if b == 0x5C {
        k += 2
        continue
      }
      if b == 0x22 { return k + 1 }
      if b == 0x24, k + 1 < limit, byte(k + 1) == 0x7B || byte(k + 1) == 0x28, let close = matching(k + 1, limit) {
        k = close + 1
        continue
      }
      if b == 0x60 {
        k += 1
        while k < limit, byte(k) != 0x60 { k += byte(k) == 0x5C ? 2 : 1 }
      }
      k += 1
    }
    return limit
  }

  /// The bracket closing the one at `open` (`{` or `(`), within `end`: quotes and escapes skipped, only brackets of its
  /// kind counted (`${x%% (*}`'s `(` is a pattern's).
  func matching(_ open: Int, _ end: Int) -> Int? {
    var depth = 0
    var k = open
    let escape: UInt8 = dialect == .shell ? 0x5C : 0x60
    let opener = byte(open)
    let closer: UInt8 = opener == 0x7B ? 0x7D : 0x29
    var quote: UInt8 = 0
    while k < end {
      let b = byte(k)
      if b == escape, quote != 0x27 {
        k += 2
        continue
      }
      if quote != 0 {
        if b == quote { quote = 0 }
      } else if b == 0x27 || (b == 0x22 && k > open) {
        quote = b
      } else if b == opener {
        depth += 1
      } else if b == closer {
        depth -= 1
        if depth == 0 { return k }
      }
      k += 1
    }
    return nil
  }
}
