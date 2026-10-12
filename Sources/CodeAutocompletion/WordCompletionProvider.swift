import CodeHighlighting
import Foundation

/// Completions without a language server: the words of the file and the
/// language's keywords.
@MainActor public final class WordCompletionProvider: CompletionProvider {
  /// Words shorter than this aren't offered.
  public var minimumWordLength = 3
  /// Larger texts are only partly read (the part around the caret).
  public var scanLimit = 1_000_000

  public init() {}

  public var triggerCharacters: Set<String> { [] }

  public func completions(for context: CompletionContext) async -> CompletionList? {
    // Nothing after a "." or for an empty word: every word would match.
    guard context.wordRange.length > 0 else { return CompletionList(items: []) }
    let items = Self.items(
      in: context.text, around: context.location, excluding: context.wordRange,
      language: context.language, minimumLength: minimumWordLength, limit: scanLimit)
    return CompletionList(items: items)
  }

  /// The identifiers in `text` (each once, nearest the caret first in sort
  /// order) and the language's keywords, without the word being typed.
  public static func items(
    in text: NSString, around location: Int, excluding word: NSRange, language: LanguageSpec?,
    minimumLength: Int = 3, limit: Int = 1_000_000
  ) -> [CompletionItem] {
    let length = text.length
    let start = max(0, min(location - limit / 2, length - limit))
    let end = min(length, start + limit)
    var distances: [String: Int] = [:]
    var i = start
    while i < end {
      guard Identifier.contains(text.character(at: i)) else {
        i += 1
        continue
      }
      let wordStart = i
      while i < end, Identifier.contains(text.character(at: i)) { i += 1 }
      let range = NSRange(location: wordStart, length: i - wordStart)
      guard range.length >= minimumLength, !Identifier.isDigit(text.character(at: wordStart)),
        range.location != word.location
      else { continue }
      let name = text.substring(with: range)
      let distance = abs(wordStart - location)
      if distance < distances[name] ?? .max { distances[name] = distance }
    }
    let keywords = language?.keywords ?? []
    var items: [CompletionItem] = distances.compactMap { name, distance in
      guard !keywords.contains(name) else { return nil }
      return CompletionItem(
        label: name, kind: .text, sortText: String(format: "1%09d", min(distance, 999_999_999)))
    }
    let typed = text.substring(with: word)
    for keyword in keywords where keyword != typed && keyword.utf16.count > 1 {
      items.append(CompletionItem(label: keyword, kind: .keyword, sortText: "2" + keyword))
    }
    return items
  }
}
