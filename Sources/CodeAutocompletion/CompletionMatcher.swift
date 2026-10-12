import Foundation

/// Fuzzy matching of typed text against completions, as Xcode does it:
/// the typed characters in order, case-insensitively, preferring the start
/// of the name and of each word in it ("tAI" and "tai" both find
/// "tableViewAutomaticInsets"… and rank "tableAutoInsert" higher), and runs
/// of consecutive characters.
public enum CompletionMatcher {
  public struct Match: Equatable, Sendable {
    public var score: Int
    /// The matched characters' UTF-16 offsets in the candidate.
    public var positions: [Int]
  }

  /// How `query` matches `candidate`, or nil when it doesn't. An empty
  /// query matches everything with score 0. A one-character query must
  /// match at a word start.
  public static func match(_ query: String, in candidate: String) -> Match? {
    let q = Array(query.utf16)
    let c = Array(candidate.utf16)
    return match(q, c)
  }

  static func match(_ q: [UInt16], _ c: [UInt16]) -> Match? {
    let m = q.count
    let n = c.count
    if m == 0 { return Match(score: 0, positions: []) }
    guard m <= n else { return nil }
    // Quick reject: the query must be a subsequence.
    var k = 0
    for ch in c where k < m && fold(ch) == fold(q[k]) { k += 1 }
    guard k == m else { return nil }

    var boundary = [Bool](repeating: false, count: n)
    for j in 0..<n { boundary[j] = isBoundary(c, j) }

    let none = Int.min / 4
    // best[i][j]: the best score with q[i] matched at c[j]; from[i][j]: where
    // q[i-1] was matched.
    var best = [[Int]](repeating: [Int](repeating: none, count: n), count: m)
    var from = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)
    for i in 0..<m {
      // The best of best[i-1][k] + k for k < j - 1, and where (a linear gap
      // penalty of one per skipped character, applied as - (j - 1)).
      var runningBest = none
      var runningFrom = -1
      for j in i..<n {
        if i > 0, j >= 2, best[i - 1][j - 2] > none, best[i - 1][j - 2] + (j - 2) > runningBest {
          runningBest = best[i - 1][j - 2] + (j - 2)
          runningFrom = j - 2
        }
        guard fold(c[j]) == fold(q[i]) else { continue }
        var score = 1
        if boundary[j] { score += j == 0 ? 12 : 8 }
        if c[j] == q[i] { score += 1 }
        if i == 0 {
          if m == 1 && !boundary[j] { continue }
          // Characters skipped before the first match cost a little, up to 3.
          best[i][j] = score - min(j, 3)
          continue
        }
        var candidate = none
        var origin = -1
        if runningBest > none {
          candidate = runningBest - (j - 1) + score
          origin = runningFrom
        }
        if j >= 1, best[i - 1][j - 1] > none {
          let consecutive = best[i - 1][j - 1] + score + 6
          if consecutive >= candidate {
            candidate = consecutive
            origin = j - 1
          }
        }
        if origin >= 0 {
          best[i][j] = candidate
          from[i][j] = origin
        }
      }
    }
    var end = -1
    var score = none
    for j in 0..<n where best[m - 1][j] > score {
      score = best[m - 1][j]
      end = j
    }
    guard end >= 0 else { return nil }
    var positions = [Int](repeating: 0, count: m)
    var j = end
    for i in stride(from: m - 1, through: 0, by: -1) {
      positions[i] = j
      j = from[i][j]
    }
    // Typed exactly as the name starts, or is.
    if positions.last == m - 1 {
      score += 10
      if zip(q, c).allSatisfy({ $0 == $1 }) { score += 5 }
      if m == n { score += 10 }
    }
    // Shorter names first among equals.
    score -= (n - m) / 6
    return Match(score: score, positions: positions)
  }

  /// ASCII letters folded to lowercase.
  @inline(__always) static func fold(_ c: UInt16) -> UInt16 {
    c >= 0x41 && c <= 0x5A ? c + 0x20 : c
  }

  /// A word starts at `j`: the name's start, after "_" or another
  /// separator, an uppercase letter after a lowercase one, or a digit run.
  static func isBoundary(_ c: [UInt16], _ j: Int) -> Bool {
    if j == 0 { return true }
    let previous = c[j - 1]
    let current = c[j]
    let isLetterOrDigit: (UInt16) -> Bool = {
      ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39)
        || $0 >= 0x80
    }
    if !isLetterOrDigit(previous) { return isLetterOrDigit(current) }
    let isUpper: (UInt16) -> Bool = { $0 >= 0x41 && $0 <= 0x5A }
    let isLower: (UInt16) -> Bool = { $0 >= 0x61 && $0 <= 0x7A }
    let isDigit: (UInt16) -> Bool = { $0 >= 0x30 && $0 <= 0x39 }
    if isUpper(current) && isLower(previous) { return true }
    // "URLSession": the "S" starts a word.
    if isUpper(previous) && isUpper(current), j + 1 < c.count, isLower(c[j + 1]) { return true }
    return isDigit(current) && !isDigit(previous)
  }

  /// Items filtered by `query` and ranked: best match first, then the
  /// provider's order (sort text), then shorter labels. With an empty query
  /// every item stays, in the provider's order with its preselected item
  /// first. `query` gives each item's typed text (an item replacing a range
  /// that starts before the word matches against more text).
  public static func rank(_ items: [CompletionItem], query: (CompletionItem) -> String) -> [(
    index: Int, match: Match
  )] {
    var results: [(index: Int, match: Match, sort: String)] = []
    results.reserveCapacity(items.count)
    var queries: [String: [UInt16]] = [:]
    for (index, item) in items.enumerated() {
      let text = query(item)
      let q = queries[text] ?? Array(text.utf16)
      queries[text] = q
      let filter = Array((item.filterText ?? item.label).utf16)
      guard var match = Self.match(q, filter) else { continue }
      // Highlight the label's characters (the filter text may differ).
      if item.filterText != nil, item.filterText != item.label {
        match.positions = Self.match(q, Array(item.label.utf16))?.positions ?? []
      }
      if q.isEmpty, item.isPreselected { match.score += 1 }
      results.append((index, match, item.sortText ?? item.label))
    }
    results.sort { a, b in
      if a.match.score != b.match.score { return a.match.score > b.match.score }
      if a.sort != b.sort { return a.sort < b.sort }
      let la = items[a.index].label
      let lb = items[b.index].label
      if la.utf16.count != lb.utf16.count { return la.utf16.count < lb.utf16.count }
      return la < lb
    }
    return results.map { ($0.index, $0.match) }
  }
}
