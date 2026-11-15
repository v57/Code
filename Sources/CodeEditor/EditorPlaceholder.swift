import Foundation

/// Xcode's placeholders: "<#name#>" in the text, drawn as a token with the
/// markers hidden, selected whole, and visited with Tab. Completions insert
/// them for a call's arguments.
public enum EditorPlaceholder {
  public static let open = "<#"
  public static let close = "#>"
  /// The longest placeholder looked for, markers included: a search stays
  /// near the range it's given instead of walking a minified file's one line.
  public static let maxLength = 1024

  /// The lines touching `range`, but at most `maxLength` characters either
  /// side of it: on a 5 MB line `lineRange(for:)` per glyph run hung Code.
  public static func scope(of range: NSRange, in text: NSString) -> NSRange {
    let length = text.length
    let start = min(max(range.location, 0), length)
    let end = min(max(NSMaxRange(range), start), length)
    let lower = max(0, start - maxLength)
    let before = text.rangeOfCharacter(
      from: .newlines, options: .backwards, range: NSRange(location: lower, length: start - lower))
    let lineStart = before.location == NSNotFound ? lower : NSMaxRange(before)
    let upper = min(length, end + maxLength)
    let after = text.rangeOfCharacter(
      from: .newlines, options: [], range: NSRange(location: end, length: upper - end))
    let lineEnd = after.location == NSNotFound ? upper : NSMaxRange(after)
    return NSRange(location: lineStart, length: lineEnd - lineStart)
  }

  /// Placeholder ranges (markers included) in `range` of `text`: "<#" and
  /// "#>" on one line with something between them.
  public static func ranges(in text: NSString, range: NSRange) -> [NSRange] {
    var result: [NSRange] = []
    var searchStart = range.location
    let end = NSMaxRange(range)
    while searchStart < end {
      let opening = text.range(
        of: open, options: .literal, range: NSRange(location: searchStart, length: end - searchStart))
      guard opening.location != NSNotFound else { break }
      var i = NSMaxRange(opening)
      var closing = NSNotFound
      let limit = min(text.length, opening.location + maxLength)
      while i + 1 < limit {
        let c = text.character(at: i)
        if c == 0x0A || c == 0x0D { break }
        if c == 0x23, text.character(at: i + 1) == 0x3E {  // "#>"
          closing = i
          break
        }
        if c == 0x3C, text.character(at: i + 1) == 0x23 { break }  // another "<#"
        i += 1
      }
      if closing != NSNotFound, closing > NSMaxRange(opening) {
        result.append(NSRange(location: opening.location, length: closing + 2 - opening.location))
        searchStart = closing + 2
      } else {
        searchStart = NSMaxRange(opening)
      }
    }
    return result
  }
}
