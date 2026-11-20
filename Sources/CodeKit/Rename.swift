import Foundation

// Rename (the editor menu's Rename…): the places a symbol is named, found by the file's language model (each place
// with the name is resolved, and counts only when it lands on the symbol), else by its language server; then one
// edit per place. Platform-neutral and without views.

/// One place to change, on one line.
public struct RenameSite: Hashable, Sendable {
  public var url: URL
  /// From 0.
  public var line: Int
  /// From 0, in UTF-16 units.
  public var column: Int
  public var length: Int
  /// What to put there; nil is the new name.
  public var text: String?

  public init(url: URL, line: Int, column: Int, length: Int, text: String? = nil) {
    self.url = url.standardizedFileURL
    self.line = line
    self.column = column
    self.length = length
    self.text = text
  }
}

/// Why a symbol can't be renamed, or the places it would change.
public enum RenameAnswer: Sendable, Equatable {
  case sites([RenameSite])
  /// The model can't tell which declaration the name is (a guess, several candidates).
  case unsure
  /// Declared outside the project (the SDK, a dependency).
  case outside
}

public enum Rename {
  /// Whether `name` can be an identifier: letters, digits, `_` and `$`, not starting with a digit.
  public static func isName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return false }
    return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" }
  }

  /// `text` with each site replaced by `new`, and how many were: a site counts only while it still reads `old` (the
  /// file changed since the places were found), except a server's own edits (`old` nil), which are taken as given.
  public static func replacing(_ sites: [RenameSite], in text: String, old: String?, with new: String) -> (text: String, count: Int) {
    let string = NSMutableString(string: text)
    var starts = [0]
    var searched = 0
    while searched < string.length {
      let newline = string.range(of: "\n", range: NSRange(location: searched, length: string.length - searched))
      guard newline.location != NSNotFound else { break }
      starts.append(NSMaxRange(newline))
      searched = NSMaxRange(newline)
    }
    var count = 0
    var done = Set<NSRange>()
    // From the end, so earlier places keep their offsets.
    for site in sites.sorted(by: { ($0.line, $0.column) > ($1.line, $1.column) }) {
      guard site.line >= 0, site.line < starts.count else { continue }
      let range = NSRange(location: starts[site.line] + site.column, length: site.length)
      guard NSMaxRange(range) <= string.length, done.insert(range).inserted else { continue }
      if let old, string.substring(with: range) != old { continue }
      string.replaceCharacters(in: range, with: site.text ?? new)
      count += 1
    }
    return (string as String, count)
  }

  /// Where `name` stands as a whole word on a line (UTF-16 columns).
  static func columns(of name: String, in line: NSString) -> [Int] {
    var found: [Int] = []
    let length = (name as NSString).length
    var from = 0
    func isWord(_ c: unichar) -> Bool {
      guard let scalar = Unicode.Scalar(c) else { return true }
      return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
    }
    while from < line.length {
      let range = line.range(of: name, range: NSRange(location: from, length: line.length - from))
      guard range.location != NSNotFound else { break }
      let before = range.location > 0 && isWord(line.character(at: range.location - 1))
      let after = NSMaxRange(range) < line.length && isWord(line.character(at: NSMaxRange(range)))
      if !before, !after { found.append(range.location) }
      from = range.location + max(length, 1)
    }
    return found
  }

  /// What the status bar says once it's done.
  public static func summary(old: String, new: String, places: Int, files: Int) -> String {
    let placeText = String(localized: "\(places) places")
    let fileText = String(localized: "\(files) files")
    return String(localized: "Renamed \(old) to \(new) in \(placeText), \(fileText)")
  }
}
