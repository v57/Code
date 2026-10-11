import Foundation
import Testing

@testable import CodeHighlighting

/// A small deterministic generator, so a failing random edit sequence repeats.
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state >> 11
  }
}

/// Snippets that open and close cross-line constructs, so random edits keep
/// changing line states.
private let snippets = [
  "/*", "*/", "\"\"\"", "\"", "\n", "\r\n", "\r", "// note", "let x = 1", "func f() {", "}",
  "/// doc", "#if DEBUG", "'a'", "https://example.com", "  ", "é😀", "",
]

private let sample = """
  import Foundation

  /// A doc comment.
  struct Point { var x = 1.5 }
  /* block
     comment */ let s = \"\"\"
  multi
  \"\"\"
  func f() -> Int { return 42 } // tail

  """

private func randomEdit(_ text: NSString, _ rng: inout SeededGenerator) -> (NSRange, String) {
  let location = Int.random(in: 0...text.length, using: &rng)
  var length = Int.random(in: 0...min(6, text.length - location), using: &rng)
  // Never split a surrogate pair: edits come from a text view, which doesn't.
  var range = NSRange(location: location, length: length)
  range = text.rangeOfComposedCharacterSequences(for: range)
  length = range.length
  let insert = snippets.randomElement(using: &rng)!
  return (NSRange(location: range.location, length: length), insert)
}

@Suite struct IncrementalHighlightingTests {
  @Test func lineIndexMatchesFreshIndexAfterRandomEdits() {
    var rng = SeededGenerator(state: 7)
    let text = NSMutableString(string: sample)
    var index = LineIndex(text)
    for _ in 0..<2000 {
      let (range, insert) = randomEdit(text, &rng)
      text.replaceCharacters(in: range, with: insert)
      index.apply(edit: range, replacementLength: (insert as NSString).length, in: text)
      #expect(index == LineIndex(text), "after replacing \(range) with \(insert.debugDescription)")
      if index != LineIndex(text) { return }
    }
  }

  @Test func lineIndexLookups() {
    let index = LineIndex("ab\ncd\r\nef\rg\n")
    #expect(index.starts == [0, 3, 7, 10, 12])
    #expect(index.line(containing: 0) == 0)
    #expect(index.line(containing: 4) == 1)
    #expect(index.line(containing: 12) == 4)
    let text = "ab\ncd\r\nef\rg\n" as NSString
    #expect(index.contentRange(ofLine: 1, in: text) == NSRange(location: 3, length: 2))
    #expect(index.contentRange(ofLine: 4, in: text) == NSRange(location: 12, length: 0))
  }

  @Test(arguments: [nil, 1, 3] as [Int?])
  func incrementalMatchesFullScan(budget: Int?) {
    var rng = SeededGenerator(state: UInt64(budget ?? 99))
    let text = NSMutableString(string: sample)
    let spec = CodeHighlighter.spec(forLanguage: "swift")!
    var highlighter = SyntaxHighlighter(text: text, spec: spec)
    for _ in 0..<1500 {
      let (range, insert) = randomEdit(text, &rng)
      text.replaceCharacters(in: range, with: insert)
      highlighter.edit(
        range: range, replacementLength: (insert as NSString).length, in: text,
        budget: budget ?? .max)
      while highlighter.continuePending(in: text, budget: budget ?? .max) != nil {}
      let fresh = SyntaxHighlighter(text: text, spec: spec)
      let same =
        highlighter.allTokens == fresh.allTokens
        && (0..<fresh.lines.count).allSatisfy {
          highlighter.startState(ofLine: $0) == fresh.startState(ofLine: $0)
        }
      #expect(same, "after replacing \(range) with \(insert.debugDescription) in \(text.debugDescription)")
      if !same { return }
    }
  }

  @Test func typingRescansOneLine() {
    let text = NSMutableString(string: sample)
    var highlighter = SyntaxHighlighter(
      text: text, spec: CodeHighlighter.spec(forLanguage: "swift")!)
    let at = (text as NSString).range(of: "42").location
    text.replaceCharacters(in: NSRange(location: at, length: 0), with: "1")
    let rescanned = highlighter.edit(
      range: NSRange(location: at, length: 0), replacementLength: 1, in: text)
    #expect(rescanned.count == 1)
  }

  @Test func openingACommentStopsAtBudgetAndContinues() {
    let text = NSMutableString(string: String(repeating: "let a = 1\n", count: 100))
    var highlighter = SyntaxHighlighter(
      text: text, spec: CodeHighlighter.spec(forLanguage: "swift")!)
    text.replaceCharacters(in: NSRange(location: 0, length: 0), with: "/*")
    let first = highlighter.edit(
      range: NSRange(location: 0, length: 0), replacementLength: 2, in: text, budget: 10)
    #expect(first == 0..<11)
    #expect(highlighter.pending == [11])
    var total = first.count
    while let more = highlighter.continuePending(in: text, budget: 10) { total += more.count }
    #expect(total == 101)
    #expect(highlighter.tokens(ofLine: 99).first?.kind == .comment)
  }
}

@Suite struct DelimiterTests {
  @Test func matchingSkipsStringsAndComments() {
    let code = "f(a, \")\", [b]) // )" as NSString
    let spec = CodeHighlighter.spec(forLanguage: "swift")!
    let highlighter = SyntaxHighlighter(text: code, spec: spec)
    let lines = LineIndex(code)
    #expect(Delimiters.match(at: 1, in: code, lines: lines, highlighter: highlighter) == 13)
    #expect(Delimiters.match(at: 13, in: code, lines: lines, highlighter: highlighter) == 1)
    #expect(Delimiters.match(at: 10, in: code, lines: lines, highlighter: highlighter) == 12)
    #expect(Delimiters.match(at: 6, in: code, lines: lines, highlighter: highlighter) == nil)
    #expect(Delimiters.balance(of: 0x28, in: code, lines: lines, highlighter: highlighter) == 0)
    let open = "func f() {\n  if x {\n  }\n" as NSString
    #expect(
      Delimiters.balance(
        of: 0x7B, in: open, lines: LineIndex(open),
        highlighter: SyntaxHighlighter(text: open, spec: spec)) == 1)
  }
}
