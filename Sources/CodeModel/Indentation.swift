import CodeScan
import Foundation

/// The statements and blocks of a language that marks blocks by indentation (Python; any layout-sensitive syntax): its
/// logical lines (a line break outside brackets ends one, unless a continuation byte outside comments ends the physical
/// line; the syntax leaves that byte out of its code tokens) and how far each is indented. A block is the lines after a
/// header that are indented further than it. Brackets left open while code is typed close at a line that starts with
/// one of `statementWords` at or left of where the open line starts, so one missing `)` doesn't make the rest of the
/// file one line.
package struct LogicalLines {
  /// Each logical line's first token, in order.
  package private(set) var starts: [Int32] = []
  /// Each logical line's indentation, in columns (a tab to the next multiple of 8).
  package private(set) var indents: [Int32] = []
  package let tokenCount: Int

  package init(_ unit: Unit, continuation: UInt8? = 0x5C, statementWords: Set<Name> = []) {
    let tokens = unit.tokens
    let text = unit.source.text
    tokenCount = tokens.count
    starts.reserveCapacity(tokens.count / 6 + 1)
    indents.reserveCapacity(tokens.count / 6 + 1)
    var depth = 0
    var openIndent: Int32 = 0
    for i in tokens.indices {
      let token = tokens[i]
      var starts = i == 0
      if i > 0 {
        let from = tokens[i - 1].end
        let to = token.start
        if to > from, let newline = memchr(text + from, 0x0A, to - from) {
          let at = UnsafePointer<UInt8>(newline.assumingMemoryBound(to: UInt8.self)) - text
          var before = at - 1
          if before >= from, text[before] == 0x0D { before -= 1 }
          let continued = continuation.map { before >= from && text[before] == $0 && !unit.isInCommentOrString(before) } ?? false
          if !continued {
            if depth == 0 {
              starts = true
            } else if token.kind == .keyword || token.kind == .declarationKeyword, statementWords.contains(unit.hash(i)), column(of: token.start, in: text) <= openIndent {
              // A bracket left open: this line is a new statement.
              depth = 0
              starts = true
            }
          }
        }
      }
      if starts {
        self.starts.append(Int32(i))
        let indent = column(of: token.start, in: text)
        indents.append(indent)
        openIndent = indent
      }
      switch token.kind {
      case .open, .interpolationOpen: depth += 1
      case .close, .interpolationClose: depth = max(0, depth - 1)
      default: break
      }
    }
  }

  /// The column a byte starts at on its line.
  private func column(of offset: Int, in text: UnsafePointer<UInt8>) -> Int32 {
    var start = offset
    while start > 0, text[start - 1] != 0x0A { start -= 1 }
    var column: Int32 = 0
    for k in start..<offset {
      switch text[k] {
      case 0x09: column = (column / 8 + 1) * 8
      case 0x20, 0x0C: column += 1
      default: return column
      }
    }
    return column
  }

  package var count: Int { starts.count }

  /// The logical line a token is on.
  package func line(of token: Int) -> Int {
    var low = 0
    var high = starts.count
    while low < high {
      let middle = (low + high) / 2
      if Int(starts[middle]) <= token { low = middle + 1 } else { high = middle }
    }
    return max(0, low - 1)
  }

  /// The token after a line's last.
  package func end(of line: Int) -> Int { line + 1 < starts.count ? Int(starts[line + 1]) : tokenCount }

  /// The first line after `header` that isn't indented further than it: where the header's block ends.
  package func blockEnd(after header: Int) -> Int {
    let indent = indents[header]
    var line = header + 1
    while line < starts.count, indents[line] > indent { line += 1 }
    return line
  }
}
