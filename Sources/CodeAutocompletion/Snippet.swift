import CodeEditor
import Foundation

/// Language Server Protocol snippets ("foo(${1:x: Int}, ${2:y})$0") turned
/// into text with Xcode's placeholders ("foo(<#x: Int#>, <#y#>)"), which the
/// editor shows as tokens and Tab moves between.
///
/// Placeholders nested in another become its plain text; a choice becomes a
/// placeholder of its first option; variables become their default text.
/// Empty tab stops leave no mark, but the first one (or `$0`) is where the
/// caret goes when there is no placeholder.
public enum Snippet {
  public struct Expansion: Equatable, Sendable {
    public var text: String
    /// Where the caret goes (a UTF-16 offset in `text`) when the text has
    /// no placeholder to select; nil puts it at the end.
    public var caret: Int?

    public init(text: String, caret: Int?) {
      self.text = text
      self.caret = caret
    }
  }

  public static func expand(_ snippet: String) -> Expansion {
    var parser = Parser(characters: Array(snippet))
    parser.parse(until: nil, depth: 0)
    let tabStop = parser.tabStops.filter { $0.key > 0 }.min { $0.key < $1.key }?.value
    let caret = parser.hasPlaceholder ? nil : tabStop ?? parser.tabStops[0]
    return Expansion(text: parser.output, caret: caret)
  }

  private struct Parser {
    let characters: [Character]
    var index = 0
    var output = ""
    var outputLength = 0
    /// Empty tab stops by number, at their UTF-16 offset.
    var tabStops: [Int: Int] = [:]
    var hasPlaceholder = false

    init(characters: [Character]) { self.characters = characters }

    var current: Character? { index < characters.count ? characters[index] : nil }

    func peek(_ offset: Int) -> Character? {
      index + offset < characters.count ? characters[index + offset] : nil
    }

    mutating func append(_ text: String) {
      output += text
      outputLength += text.utf16.count
    }

    /// Parses up to `terminator` (a "}" closing a placeholder), leaving it.
    mutating func parse(until terminator: Character?, depth: Int) {
      while let c = current {
        if c == terminator { return }
        if c == "\\", let next = peek(1), next == "$" || next == "}" || next == "\\" {
          append(String(next))
          index += 2
        } else if c == "$" {
          dollar(depth: depth)
        } else {
          append(String(c))
          index += 1
        }
      }
    }

    mutating func number() -> Int? {
      var digits = ""
      while let c = current, c.isASCII, c.isNumber {
        digits.append(c)
        index += 1
      }
      return Int(digits)
    }

    mutating func name() -> String {
      var name = ""
      while let c = current, c.isASCII, c.isLetter || c.isNumber || c == "_" {
        name.append(c)
        index += 1
      }
      return name
    }

    mutating func dollar(depth: Int) {
      let start = index
      index += 1
      guard let c = current else {
        append("$")
        return
      }
      if c.isASCII, c.isNumber {
        let n = number() ?? 0
        if tabStops[n] == nil { tabStops[n] = outputLength }
        return
      }
      if c.isASCII, c.isLetter || c == "_" {
        // A variable without a default: nothing (no editor state to offer).
        _ = name()
        return
      }
      guard c == "{" else {
        append("$")
        return
      }
      index += 1
      if let c = current, c.isASCII, c.isNumber {
        let n = number() ?? 0
        switch current {
        case "}":
          index += 1
          if tabStops[n] == nil { tabStops[n] = outputLength }
        case ":":
          index += 1
          placeholder(depth: depth, number: n)
        case "|":
          index += 1
          choice(depth: depth)
        default: literal(from: start)
        }
        return
      }
      _ = name()
      switch current {
      case "}": index += 1
      case ":":
        // A variable's default text.
        index += 1
        parse(until: "}", depth: depth)
        if current == "}" { index += 1 }
      case "/":
        // A transform of a variable: skip it.
        var slashes = 0
        while let c = current, slashes < 3 {
          if c == "\\" { index += 1 } else if c == "/" { slashes += 1 }
          index += 1
        }
        while let c = current, c != "}" { index += 1 }
        if current == "}" { index += 1 }
      default: literal(from: start)
      }
    }

    /// Not a snippet construct after all: the text as written.
    mutating func literal(from start: Int) {
      index = start + 1
      append("$")
    }

    mutating func placeholder(depth: Int, number: Int) {
      let startLength = outputLength
      let startOutput = output
      parse(until: "}", depth: depth + 1)
      if current == "}" { index += 1 }
      let inner = String(output.dropFirst(startOutput.count))
      guard depth == 0 else { return }
      if inner.isEmpty {
        if tabStops[number] == nil { tabStops[number] = startLength }
        return
      }
      // Placeholder text can't hold the closing marker.
      let clean = inner.replacingOccurrences(of: EditorPlaceholder.close, with: "# >")
      output = startOutput
      outputLength = startLength
      append(EditorPlaceholder.open + clean + EditorPlaceholder.close)
      hasPlaceholder = true
    }

    mutating func choice(depth: Int) {
      var options: [String] = []
      var option = ""
      while let c = current {
        if c == "\\", let next = peek(1) {
          option.append(next)
          index += 2
          continue
        }
        index += 1
        if c == "," {
          options.append(option)
          option = ""
        } else if c == "|" {
          options.append(option)
          break
        } else {
          option.append(c)
        }
      }
      if current == "}" { index += 1 }
      let first = options.first ?? ""
      if depth > 0 || first.isEmpty {
        append(first)
      } else {
        append(EditorPlaceholder.open + first + EditorPlaceholder.close)
        hasPlaceholder = true
      }
    }
  }
}
