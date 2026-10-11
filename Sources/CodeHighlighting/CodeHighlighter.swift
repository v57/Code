import Foundation

/// Entry point for code syntax highlighting: language resolution from fence info
/// strings ("Swift", "py", "c++", "objective-c") and token production.
public enum CodeHighlighter {
  public static let all = LanguageCatalog.all

  private static let byAlias: [String: LanguageSpec] = {
    var map: [String: LanguageSpec] = [:]
    for spec in all {
      map[spec.name.lowercased()] = spec
      for alias in spec.aliases { map[alias.lowercased()] = spec }
    }
    return map
  }()

  /// Resolves a fence info string to a language spec, or nil when unsupported.
  /// Takes the first whitespace-separated word ("swift linenums" → "swift")
  /// and tolerates a "language-" prefix ("language-swift" → swift).
  public static func spec(forLanguage info: String) -> LanguageSpec? {
    let trimmed = info.trimmingCharacters(in: .whitespacesAndNewlines)
    let first = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
    let lowered = first.lowercased()
    if let spec = byAlias[lowered] { return spec }
    if lowered.hasPrefix("language-"), let spec = byAlias[String(lowered.dropFirst(9))] {
      return spec
    }
    return nil
  }

  /// Lexes `code` as `language`, returning UTF-16 tokens relative to `code`.
  public static func tokens(in code: String, language: String) -> [CodeToken] {
    guard let spec = spec(forLanguage: language) else { return [] }
    var scanner = CodeScanner(code: code, spec: spec)
    return scanner.scan()
  }
}
