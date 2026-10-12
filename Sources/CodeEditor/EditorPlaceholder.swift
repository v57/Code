import Foundation

/// Xcode's placeholders: "<#name#>" in the text, drawn as a token with the
/// markers hidden, selected whole, and visited with Tab. Completions insert
/// them for a call's arguments.
public enum EditorPlaceholder {
  public static let open = "<#"
  public static let close = "#>"

  /// Placeholder ranges (markers included) in `range` of `text`: "<#" and
  /// "#>" on one line with something between them.
  public static func ranges(in text: NSString, range: NSRange) -> [NSRange] {
    var result: [NSRange] = []
    var searchStart = range.location
    let end = NSMaxRange(range)
    while searchStart < end {
      let opening = text.range(
        of: open, range: NSRange(location: searchStart, length: end - searchStart))
      guard opening.location != NSNotFound else { break }
      var i = NSMaxRange(opening)
      var closing = NSNotFound
      while i + 1 < text.length {
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
