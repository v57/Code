import Foundation

/// The UTF-16 start offset of every line in a text, kept in step with edits.
///
/// "\n", "\r\n" and "\r" end a line. A text always has at least one line, and
/// a text ending in a terminator has an empty last line (as editors show it).
public struct LineIndex: Equatable, Sendable {
  /// Sorted line starts; `starts[0] == 0`.
  public private(set) var starts: [Int]
  /// UTF-16 length of the indexed text.
  public private(set) var length: Int

  public init(_ text: NSString) {
    starts = [0]
    length = text.length
    starts += Self.lineStarts(in: text, range: NSRange(location: 0, length: text.length))
  }

  public init(_ text: String) { self.init(text as NSString) }

  public var count: Int { starts.count }

  /// The line containing UTF-16 offset `location` (clamped to the text).
  public func line(containing location: Int) -> Int {
    var lo = 0
    var hi = starts.count - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if starts[mid] <= location { lo = mid } else { hi = mid - 1 }
    }
    return lo
  }

  /// The range of `line` including its terminator.
  public func range(ofLine line: Int) -> NSRange {
    let start = starts[line]
    let end = line + 1 < starts.count ? starts[line + 1] : length
    return NSRange(location: start, length: end - start)
  }

  /// The range of `line` without its terminator.
  public func contentRange(ofLine line: Int, in text: NSString) -> NSRange {
    var range = self.range(ofLine: line)
    if range.length > 0, text.character(at: NSMaxRange(range) - 1) == 0x0A {
      range.length -= 1
      if range.length > 0, text.character(at: NSMaxRange(range) - 1) == 0x0D { range.length -= 1 }
    } else if range.length > 0, text.character(at: NSMaxRange(range) - 1) == 0x0D {
      range.length -= 1
    }
    return range
  }

  /// Updates the index after the characters in `range` (old coordinates) were
  /// replaced with `replacementLength` characters; `text` is the new text.
  /// Returns the lines whose content may have changed, in new line numbers.
  ///
  /// Only the touched lines are re-split; later starts shift by the length
  /// change. The characters from the end of the edit to the end of its line
  /// are unchanged, so that line's terminator, and with it the start of the
  /// next line, survives the edit.
  @discardableResult
  public mutating func apply(edit range: NSRange, replacementLength: Int, in text: NSString)
    -> Range<Int>
  {
    let delta = replacementLength - range.length
    var firstLine = line(containing: range.location)
    // An edit at a line start may join a "\r" ending the previous line with
    // an inserted "\n" (or split one), so re-split that line too.
    if firstLine > 0, starts[firstLine] == range.location { firstLine -= 1 }
    let lastOldLine = line(containing: NSMaxRange(range))
    let isLast = lastOldLine == starts.count - 1
    let newEnd = isLast ? text.length : starts[lastOldLine + 1] + delta
    let scanStart = starts[firstLine]
    let newStarts = Self.lineStarts(
      in: text, range: NSRange(location: scanStart, length: newEnd - scanStart))
    let tail = isLast ? [] : starts[(lastOldLine + 2)...].map { $0 + delta }
    starts.replaceSubrange((firstLine + 1)..., with: newStarts + tail)
    length = text.length
    let changedEnd = firstLine + newStarts.count + (isLast ? 1 : 0)
    return firstLine..<min(changedEnd, starts.count)
  }

  /// Starts of the lines that begin inside `range` (after a terminator in it).
  private static func lineStarts(in text: NSString, range: NSRange) -> [Int] {
    var result: [Int] = []
    var i = range.location
    let end = NSMaxRange(range)
    while i < end {
      let c = text.character(at: i)
      if c == 0x0A {
        result.append(i + 1)
      } else if c == 0x0D {
        if i + 1 < text.length, text.character(at: i + 1) == 0x0A {
          result.append(i + 2)
          i += 1
        } else {
          result.append(i + 1)
        }
      }
      i += 1
    }
    return result
  }
}
