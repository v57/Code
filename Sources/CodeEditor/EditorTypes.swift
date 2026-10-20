import Foundation

/// An issue shown on a line: an error, warning or note from a build or a
/// language server.
public struct LineAnnotation: Equatable, Sendable {
  public enum Severity: Int, Comparable, Sendable {
    case error, warning, note

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  /// From 0.
  public var line: Int
  /// UTF-16 column from 0, when known.
  public var column: Int?
  public var severity: Severity
  public var message: String

  public init(line: Int, column: Int? = nil, severity: Severity, message: String) {
    self.line = line
    self.column = column
    self.severity = severity
    self.message = message
  }
}

/// An edit as language servers take it: the replaced range in the text
/// before the edit (lines and UTF-16 columns from 0) and the new text.
public struct TextEdit: Equatable, Sendable {
  public var startLine: Int
  public var startColumn: Int
  public var endLine: Int
  public var endColumn: Int
  public var text: String

  public init(startLine: Int, startColumn: Int, endLine: Int, endColumn: Int, text: String) {
    self.startLine = startLine
    self.startColumn = startColumn
    self.endLine = endLine
    self.endColumn = endColumn
    self.text = text
  }
}

/// What project services need from a document's editor, whichever platform's it is (CodeTextView on the Mac):
/// its text and caret, positions in it, and edits made from outside it.
@MainActor public protocol CodeTextEditing: AnyObject {
  /// The text as the editor shows it.
  var string: String { get }
  /// Lines in the text (an empty text has one).
  var lineCount: Int { get }
  var currentSelection: EditorSelection { get }
  /// The caret's character location (the selection's start), in UTF-16 units.
  var caretLocation: Int { get }
  /// The selected characters, in UTF-16 units.
  var selectionRange: NSRange { get }
  /// The editor has keyboard focus.
  var isFocused: Bool { get }
  /// The line and UTF-16 column (from 0) of a character location.
  func position(of location: Int) -> (line: Int, column: Int)
  /// The identifier around `location` (letters, digits, "_", "$").
  func identifierRange(at location: Int) -> NSRange?
  /// Replaces the text with a formatted version as one undoable edit.
  func applyFormattedText(_ newText: String)
  /// Moves the caret to `line` and `column` (from 1), selecting `length` characters.
  func goTo(line: Int, column: Int, length: Int)
  /// Adds or removes a breakpoint on `line` (from 0).
  func toggleBreakpoint(atLine line: Int)
  /// Shows Quick Help for the symbol at `range` (⌥-click).
  func showQuickHelp(_ text: String, at range: NSRange)
}

extension CodeTextEditing {
  /// The identifier around `location`, by the text alone.
  public func identifierRange(in text: NSString, at location: Int) -> NSRange? {
    guard text.length > 0 else { return nil }
    func isIdentifier(_ c: unichar) -> Bool {
      guard let scalar = Unicode.Scalar(c) else { return false }
      return CharacterSet.alphanumerics.contains(scalar) || c == 0x5F || c == 0x24
    }
    var start = min(location, text.length)
    var end = start
    while start > 0, isIdentifier(text.character(at: start - 1)) { start -= 1 }
    while end < text.length, isIdentifier(text.character(at: end)) { end += 1 }
    return end > start ? NSRange(location: start, length: end - start) : nil
  }
}
