import Foundation

/// Whitespace runs with a line break in them become one space: a declaration written over several lines, on one.
package func oneLine(_ text: String) -> String {
  var result = ""
  var pendingSpace = false
  for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { continue }
    if pendingSpace, let last = result.last, last != "(", last != "[", !trimmed.hasPrefix(")"), !trimmed.hasPrefix("]") {
      result += " "
    }
    result += result.isEmpty ? trimmed : String(trimmed)
    pendingSpace = true
  }
  return result
}

extension Unit {
  /// The line's text (from 0), trimmed.
  package func lineText(_ line: Int) -> String {
    let start = source.lines.offset(line: line, character: 0, in: source.text)
    var end = start
    let bytes = source.bytes
    while end < bytes.count, bytes[end] != 10 { end += 1 }
    return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self).trimmingCharacters(in: .whitespaces)
  }

  /// The first paragraph of the doc comment on the lines right above a token's: lines starting with `linePrefix`
  /// (`///`, Go's `//`), or a block from `blockOpen` (`/**`, `/*`) to `*/`. A blank line or a list ends the paragraph.
  package func documentation(above token: Int, linePrefix: String, blockOpen: String) -> String? {
    guard token >= 0, token < tokens.count else { return nil }
    var line = source.lines.line(of: tokens[token].start) - 1
    var lines: [String] = []
    if line >= 0, lineText(line).hasSuffix("*/") {
      while line >= 0 {
        var current = lineText(line)
        let opens = current.hasPrefix(blockOpen)
        if current.hasSuffix("*/") { current.removeLast(2) }
        if opens { current.removeFirst(blockOpen.count) } else if current.hasPrefix("*") { current.removeFirst() }
        lines.insert(current.trimmingCharacters(in: .whitespaces), at: 0)
        if opens { break }
        line -= 1
      }
    } else {
      while line >= 0 {
        let current = lineText(line)
        guard current.hasPrefix(linePrefix) else { break }
        lines.insert(String(current.dropFirst(linePrefix.count)).trimmingCharacters(in: .whitespaces), at: 0)
        line -= 1
      }
    }
    var paragraph: [String] = []
    for line in lines {
      if line.isEmpty || line.hasPrefix("- ") {
        if paragraph.isEmpty { continue }
        break
      }
      paragraph.append(line)
    }
    return paragraph.isEmpty ? nil : paragraph.joined(separator: " ")
  }
}
