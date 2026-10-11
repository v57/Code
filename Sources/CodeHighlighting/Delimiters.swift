import Foundation

/// Bracket matching that ignores brackets inside strings and comments (as
/// the highlighter sees them). Editors use it to flash the matching bracket,
/// select a bracketed block, indent a typed closer and decide whether a
/// brace still needs closing.
public enum Delimiters {
  /// Opening → closing code delimiters: ( [ {.
  public static let pairs: [unichar: unichar] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]
  /// Closing → opening.
  public static let openers: [unichar: unichar] = [0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B]

  /// How far a match is searched, in UTF-16 units.
  public static let searchLimit = 500_000

  /// The index of the delimiter matching the one at `location`, or nil when
  /// there is none (or the character isn't a delimiter, or sits in a string
  /// or comment).
  public static func match(
    at location: Int, in text: NSString, lines: LineIndex, highlighter: SyntaxHighlighter?
  ) -> Int? {
    guard location >= 0, location < text.length else { return nil }
    let c = text.character(at: location)
    guard !isLiteral(at: location, lines: lines, highlighter: highlighter) else { return nil }
    if let close = pairs[c] {
      return scan(from: location + 1, forward: true, open: c, close: close, text: text,
        lines: lines, highlighter: highlighter)
    }
    if let open = openers[c] {
      return scan(from: location - 1, forward: false, open: open, close: c, text: text,
        lines: lines, highlighter: highlighter)
    }
    return nil
  }

  /// The unmatched opener a `closer` typed at `location` would close.
  public static func opener(
    for closer: unichar, before location: Int, in text: NSString, lines: LineIndex,
    highlighter: SyntaxHighlighter?
  ) -> Int? {
    guard let open = openers[closer] else { return nil }
    return scan(from: location - 1, forward: false, open: open, close: closer, text: text,
      lines: lines, highlighter: highlighter)
  }

  /// Openers minus closers of the `open` kind across the text (outside
  /// strings and comments): above 0, some opener is still unclosed.
  public static func balance(
    of open: unichar, in text: NSString, lines: LineIndex, highlighter: SyntaxHighlighter?
  ) -> Int {
    guard let close = pairs[open], text.length <= searchLimit else { return 0 }
    var balance = 0
    forEachCodeCharacter(from: 0, forward: true, text: text, lines: lines,
      highlighter: highlighter) { _, c in
      if c == open { balance += 1 } else if c == close { balance -= 1 }
      return false
    }
    return balance
  }

  /// Whether `location` is inside a string, comment or doc comment.
  public static func isLiteral(at location: Int, lines: LineIndex, highlighter: SyntaxHighlighter?)
    -> Bool
  {
    guard let highlighter, matches(highlighter, lines) else { return false }
    let line = lines.line(containing: location)
    return highlighter.tokens(ofLine: line).contains {
      isLiteralKind($0.kind) && NSLocationInRange(location, $0.range)
    }
  }

  /// Whether the highlighter is up to date with `lines` (cheap check: an
  /// editor keeps both in step, or the highlighter is still scanning).
  private static func matches(_ highlighter: SyntaxHighlighter, _ lines: LineIndex) -> Bool {
    highlighter.lines.length == lines.length && highlighter.lines.count == lines.count
  }

  static func isLiteralKind(_ kind: SyntaxKind) -> Bool {
    kind == .string || kind == .comment || kind == .prose
  }

  private static func scan(
    from start: Int, forward: Bool, open: unichar, close: unichar, text: NSString,
    lines: LineIndex, highlighter: SyntaxHighlighter?
  ) -> Int? {
    var depth = 1
    var found: Int?
    forEachCodeCharacter(from: start, forward: forward, text: text, lines: lines,
      highlighter: highlighter) { index, c in
      if c == (forward ? open : close) {
        depth += 1
      } else if c == (forward ? close : open) {
        depth -= 1
        if depth == 0 {
          found = index
          return true
        }
      }
      return false
    }
    return found
  }

  /// Visits the characters from `start` outward that are code (not in a
  /// literal), line by line, until `body` returns true or the search limit.
  private static func forEachCodeCharacter(
    from start: Int, forward: Bool, text: NSString, lines: LineIndex,
    highlighter: SyntaxHighlighter?, _ body: (Int, unichar) -> Bool
  ) {
    guard start >= 0, start < text.length else { return }
    let tokens = highlighter.flatMap { matches($0, lines) ? $0 : nil }
    var line = lines.line(containing: start)
    var visited = 0
    while line >= 0 && line < lines.count {
      let range = lines.range(ofLine: line)
      let literals = tokens?.tokens(ofLine: line).filter { isLiteralKind($0.kind) }.map(\.range) ?? []
      let indices: StrideThrough<Int> =
        forward
        ? stride(from: max(start, range.location), through: NSMaxRange(range) - 1, by: 1)
        : stride(from: min(start, NSMaxRange(range) - 1), through: range.location, by: -1)
      for index in indices {
        visited += 1
        if visited > searchLimit { return }
        if literals.contains(where: { NSLocationInRange(index, $0) }) { continue }
        if body(index, text.character(at: index)) { return }
      }
      line += forward ? 1 : -1
    }
  }
}
