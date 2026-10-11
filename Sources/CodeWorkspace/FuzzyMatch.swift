import Foundation

/// Fuzzy matching for Quick Open: every query character must appear in the
/// candidate in order. Matches score higher at word starts (after "/", "_",
/// "-", ".", a space, or a lower-to-upper case change), in runs of
/// consecutive characters, and in the file name rather than the folders.
public enum FuzzyMatch {
  public struct Result: Sendable {
    public let score: Int
    /// UTF-16 offsets of the matched characters, for highlighting.
    public let positions: [Int]
  }

  /// Matches `query` (whitespace ignored, case-insensitive) against a
  /// relative path. Nil when it does not match.
  public static func match(_ query: String, in path: String) -> Result? {
    let needle = Array(query.lowercased().utf16.filter { $0 != 0x20 })
    let original = Array(path.utf16)
    let haystack = Array(path.lowercased().utf16)
    guard !needle.isEmpty else { return Result(score: 0, positions: []) }
    guard needle.count <= haystack.count, haystack.count == original.count else { return nil }
    let nameStart = (original.lastIndex(of: 0x2F) ?? -1) + 1

    // Matching inside the file name usually reads best ("wsw" → the W, s, W
    // of "WorkspaceWindow.swift", not the folders above it), so try that
    // first and keep whichever placement scores higher.
    var best: Result?
    for start in Set([0, nameStart]) {
      guard var positions = greedy(needle, in: haystack, from: start) else { continue }
      positions = tighten(positions, needle: needle, haystack: haystack, original: original)
      let score = score(positions, in: original, nameStart: nameStart)
      if best.map({ score > $0.score }) ?? true { best = Result(score: score, positions: positions) }
    }
    return best
  }

  /// The first in-order match of every needle character from `start`.
  private static func greedy(_ needle: [UInt16], in haystack: [UInt16], from start: Int) -> [Int]? {
    var positions: [Int] = []
    var qi = 0
    var i = start
    while i < haystack.count && qi < needle.count {
      if haystack[i] == needle[qi] {
        positions.append(i)
        qi += 1
      }
      i += 1
    }
    return qi == needle.count ? positions : nil
  }

  private static func score(_ positions: [Int], in original: [UInt16], nameStart: Int) -> Int {
    // The extension ("swift" in "App.swift") is shared by most files, so
    // matching it says little.
    let extensionStart = original.lastIndex(of: 0x2E).flatMap { $0 > nameStart ? $0 : nil }
      ?? original.count
    var score = 0
    for (n, p) in positions.enumerated() {
      score += 1
      let inExtension = p >= extensionStart
      if isWordStart(original, p) { score += inExtension ? 2 : 8 }
      if n > 0 && positions[n - 1] == p - 1 { score += 5 }
      if p >= nameStart && !inExtension { score += 3 }
    }
    // Prefer shorter paths and matches that start the file name.
    score -= original.count / 8
    if positions.first == nameStart { score += 6 }
    return score
  }

  /// Moves each match to a later word start when one exists before the next
  /// match ("ws" in "workspace/WorkspaceWindow" lands on "W…W" not "w…s").
  private static func tighten(
    _ positions: [Int], needle: [UInt16], haystack: [UInt16], original: [UInt16]
  ) -> [Int] {
    var result = positions
    for n in stride(from: result.count - 1, through: 0, by: -1) {
      let limit = n + 1 < result.count ? result[n + 1] : haystack.count
      if isWordStart(original, result[n]) { continue }
      var j = result[n] + 1
      while j < limit {
        if haystack[j] == needle[n] && isWordStart(original, j) {
          result[n] = j
          break
        }
        j += 1
      }
    }
    return result
  }

  private static func isWordStart(_ s: [UInt16], _ i: Int) -> Bool {
    guard i > 0 else { return true }
    let prev = s[i - 1]
    if [0x2F, 0x5F, 0x2D, 0x2E, 0x20].contains(prev) { return true }
    let isLower = { (c: UInt16) in c >= 0x61 && c <= 0x7A }
    let isUpper = { (c: UInt16) in c >= 0x41 && c <= 0x5A }
    return isLower(prev) && isUpper(s[i])
  }
}
