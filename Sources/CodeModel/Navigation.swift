import CodeScan
import Foundation

/// Token navigation every front end needs beyond `Unit`'s own: finding a token, the bracket around it, a range's text.
extension Unit {
  /// The token at a byte offset: the first that ends after it, if it starts at or before it.
  package func token(at offset: Int) -> Int? {
    var low = 0
    var high = tokens.count - 1
    guard high >= 0 else { return nil }
    while low < high {
      let middle = (low + high) / 2
      if tokens[middle].end <= offset { low = middle + 1 } else { high = middle }
    }
    guard low < tokens.count, tokens[low].start <= offset else { return nil }
    return low
  }

  /// The bracket a token is directly inside, walking back.
  package func matchingOpenBefore(_ token: Int) -> Int? {
    var depth = 0
    var i = token - 1
    var budget = 4096
    while i >= 0, budget > 0 {
      budget -= 1
      switch tokens[i].kind {
      case .close: depth += 1
      case .open:
        if depth == 0 { return i }
        depth -= 1
      default: break
      }
      i -= 1
    }
    return nil
  }

  /// Whether a token's text starts with a byte.
  @inlinable package func startsWith(_ i: Int, _ byte: UInt8) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    return source.text[tokens[i].start] == byte
  }

  /// Whether a punctuation token is made only of these bytes: `>>` and `>` close type arguments, `<?` opens them.
  @inlinable package func punctuation(_ i: Int, madeOf allowed: StaticString) -> Bool {
    guard i >= 0, i < tokens.count, tokens[i].kind == .punctuation else { return false }
    let token = tokens[i]
    for k in 0..<token.length {
      let byte = source.text[token.start + k]
      var found = false
      for b in 0..<allowed.utf8CodeUnitCount where allowed.utf8Start[b] == byte { found = true }
      if !found { return false }
    }
    return true
  }

  /// Tokens' text as written, on one line.
  package func text(from start: Int, to end: Int) -> String {
    guard start >= 0, end > start, end <= tokens.count else { return "" }
    let from = tokens[start].start
    let to = tokens[end - 1].end
    return oneLine(String(decoding: UnsafeBufferPointer(start: source.text + from, count: to - from), as: UTF8.self))
  }

  /// A declaration's name as written.
  package func nameText(_ ref: DeclRef, in project: Project) -> String {
    let holder = project.units[Int(ref.unit)]
    let token = holder.decls[Int(ref.decl)].nameToken
    return token >= 0 ? holder.string(Int(token)) : ""
  }

  /// Whether an offset is inside a comment or a string (or right after an unterminated one), where completion offers
  /// nothing. Reads the source's own tokens, comments included.
  package func isInCommentOrString(_ offset: Int) -> Bool {
    let tokens = source.tokens
    var low = 0
    var high = tokens.count
    while low < high {
      let middle = (low + high) / 2
      if tokens[middle].end < offset { low = middle + 1 } else { high = middle }
    }
    guard low < tokens.count else { return false }
    let token = tokens[low]
    guard token.start < offset else { return false }
    switch token.kind {
    case .comment, .docComment:
      if offset < token.end { return true }
      return token.length >= 2 && source.text[token.start + 1] == 0x2F
    case .string:
      if offset < token.end { return true }
      let last = source.text[token.end - 1]
      return token.length < 2 || (last != 0x22 && last != 0x60 && last != 0x27)
    default:
      return false
    }
  }
}

extension Answer {
  /// Sites without repeats: exact when one is left, candidates when several.
  package init(summarizing sites: [Site]) {
    var unique: [Site] = []
    for site in sites where !unique.contains(site) { unique.append(site) }
    self.init(state: unique.count == 1 ? .exact : .candidates, sites: unique)
  }
}
