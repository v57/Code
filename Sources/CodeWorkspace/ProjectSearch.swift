import Foundation

/// What Find in Project looks for.
public struct SearchQuery: Equatable, Sendable {
  public enum Mode: String, CaseIterable, Sendable {
    /// The text anywhere.
    case containing
    /// The text as a whole word (not inside a longer identifier).
    case matchingWord
    case regularExpression
  }

  public var text: String
  public var mode: Mode
  public var isCaseSensitive: Bool

  public init(_ text: String, mode: Mode = .containing, isCaseSensitive: Bool = false) {
    self.text = text
    self.mode = mode
    self.isCaseSensitive = isCaseSensitive
  }

  /// The query as a regular expression; nil for an empty query or an
  /// invalid pattern.
  public var expression: NSRegularExpression? {
    guard !text.isEmpty else { return nil }
    var pattern: String
    switch mode {
    case .containing: pattern = NSRegularExpression.escapedPattern(for: text)
    case .matchingWord:
      // \b only works next to word characters; elsewhere ("+=") the text
      // stands alone already.
      pattern = NSRegularExpression.escapedPattern(for: text)
      if text.first.map(Self.isWordCharacter) == true { pattern = "\\b" + pattern }
      if text.last.map(Self.isWordCharacter) == true { pattern += "\\b" }
    case .regularExpression: pattern = text
    }
    var options: NSRegularExpression.Options = [.anchorsMatchLines]
    if !isCaseSensitive { options.insert(.caseInsensitive) }
    return try? NSRegularExpression(pattern: pattern, options: options)
  }

  static func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
  }
}

/// A match on a line of a file.
public struct SearchMatch: Hashable, Sendable {
  /// From 1.
  public var line: Int
  /// The match in `preview`.
  public var range: Range<String.Index>
  /// The line, trimmed of leading whitespace and shortened around the match
  /// when long.
  public var preview: String
  /// Where the match starts on its line (UTF-16 units from 0) and its
  /// length, for selecting it in the editor.
  public var column: Int
  public var length: Int
}

/// The matches in one file.
public struct FileSearchResult: Identifiable, Hashable, Sendable {
  /// Relative to the project.
  public var path: String
  public var matches: [SearchMatch]

  public var id: String { path }
  public var name: String { (path as NSString).lastPathComponent }
  /// The folder, relative to the project ("" at its top).
  public var folder: String { (path as NSString).deletingLastPathComponent }
}

/// Find in Project: searches a project's files line by line. Binary files
/// and files over `maximumFileSize` are skipped.
public enum ProjectSearch {
  public static let maximumFileSize = 8 << 20
  /// More matches than this stops the search (a one-letter query).
  public static let matchLimit = 10_000
  /// Longest line preview, in characters.
  static let previewLength = 160

  /// Searches `paths` (relative to `root`) in order, calling `progress`
  /// with each batch of files that matched. `texts` holds the newest text
  /// of open documents by relative path, edits not saved yet included.
  /// Returns whether the search stopped at `matchLimit`. Checks for
  /// cancellation between files.
  @discardableResult
  public static func search(
    _ query: SearchQuery, root: URL, paths: [String], texts: [String: String] = [:],
    progress: ([FileSearchResult]) -> Void
  ) -> Bool {
    guard let expression = query.expression else { return false }
    var batch: [FileSearchResult] = []
    var count = 0
    var lastReport = Date()
    for path in paths {
      if Task.isCancelled { break }
      guard let text = texts[path] ?? read(root.appendingPathComponent(path)) else { continue }
      let matches = search(text, expression: expression, limit: matchLimit - count)
      if !matches.isEmpty {
        batch.append(FileSearchResult(path: path, matches: matches))
        count += matches.count
      }
      // Results appear while a big project is still being searched.
      if !batch.isEmpty, Date().timeIntervalSince(lastReport) > 0.1 {
        progress(batch)
        batch = []
        lastReport = Date()
      }
      if count >= matchLimit { break }
    }
    if !batch.isEmpty { progress(batch) }
    return count >= matchLimit
  }

  /// The matches in `text`, at most `limit`. A match running over several
  /// lines (a regular expression with `\n`) is shown on its first line.
  public static func search(_ text: String, expression: NSRegularExpression, limit: Int = .max)
    -> [SearchMatch]
  {
    let string = text as NSString
    var matches: [SearchMatch] = []
    var lineStart = 0
    var lineNumber = 1
    var scanned = 0
    expression.enumerateMatches(in: text, range: NSRange(location: 0, length: string.length)) {
      result, _, stop in
      guard let range = result?.range, range.length > 0 else { return }
      // Count the lines between the previous match and this one.
      while scanned < range.location {
        let newline = string.range(
          of: "\n", range: NSRange(location: scanned, length: range.location - scanned))
        guard newline.location != NSNotFound else { break }
        lineNumber += 1
        lineStart = newline.location + 1
        scanned = lineStart
      }
      scanned = max(scanned, range.location)
      let lineEnd = string.range(
        of: "\n", range: NSRange(location: range.location, length: string.length - range.location))
      let end = lineEnd.location == NSNotFound ? string.length : lineEnd.location
      let line = string.substring(with: NSRange(location: lineStart, length: end - lineStart))
      let column = range.location - lineStart
      let length = min(range.length, end - range.location)
      matches.append(preview(of: line, line: lineNumber, column: column, length: max(length, 0)))
      if matches.count >= limit { stop.pointee = true }
    }
    return matches
  }

  /// A match on its line, with the line trimmed for display: no leading
  /// whitespace, and "…" where a long line is cut around the match.
  static func preview(of line: String, line number: Int, column: Int, length: Int) -> SearchMatch {
    let units = Array(line.utf16)
    var start = 0
    while start < column, units[start] == 0x20 || units[start] == 0x09 { start += 1 }
    var prefix = ""
    if column - start > previewLength / 2 {
      start = column - 30
      prefix = "…"
    }
    var end = units.count
    if end > 0, units[end - 1] == 0x0D { end -= 1 }
    var suffix = ""
    let limit = max(column + length, start + previewLength)
    if end > limit {
      end = limit
      suffix = "…"
    }
    // Never split a surrogate pair.
    if start > 0, UTF16.isTrailSurrogate(units[start]) { start -= 1 }
    if end < units.count, UTF16.isTrailSurrogate(units[end]) { end += 1 }
    let preview = prefix + String(decoding: units[start..<end], as: UTF16.self) + suffix
    let lower = prefix.utf16.count + column - start
    let upper = min(lower + length, preview.utf16.count - suffix.utf16.count)
    let range =
      String.Index(utf16Offset: lower, in: preview)..<String.Index(utf16Offset: max(lower, upper), in: preview)
    return SearchMatch(line: number, range: range, preview: preview, column: column, length: length)
  }

  /// A file's text, or nil for a binary, unreadable or very large file.
  static func read(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: maximumFileSize + 1), data.count <= maximumFileSize else {
      return nil
    }
    // A NUL byte near the start: a binary file.
    if data.prefix(8000).contains(0) { return nil }
    return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
  }
}
