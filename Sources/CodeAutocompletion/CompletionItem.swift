import CodeHighlighting
import Foundation

/// What a completion is, for its badge in the list. The raw values are the
/// Language Server Protocol's `CompletionItemKind`s.
public enum CompletionKind: Int, Sendable, CaseIterable {
  case text = 1
  case method, function, constructor, field, variable, `class`, interface, module, property, unit,
    value, `enum`, keyword, snippet, color, file, reference, folder, enumMember, constant, `struct`,
    event, `operator`, typeParameter
}

/// An edit besides the completion itself (an import a server adds), as a
/// range in the text when completions were requested.
public struct CompletionEdit: Equatable, Sendable {
  public var range: NSRange
  public var text: String

  public init(range: NSRange, text: String) {
    self.range = range
    self.text = text
  }
}

/// One completion: what the list shows and what accepting it inserts.
public struct CompletionItem: Sendable {
  public var label: String
  /// Shown dimmed right after the label: a signature ("(x: Int)").
  public var labelDetail: String?
  /// Shown at the right: a type, or where the symbol comes from.
  public var detail: String?
  /// Markdown, shown under the list for the selected item.
  public var documentation: String?
  public var kind: CompletionKind
  /// What typing is matched against; the label when nil.
  public var filterText: String?
  /// How the provider orders items that match equally well; the label when
  /// nil.
  public var sortText: String?
  /// The text accepting inserts: plain, or an LSP snippet ("foo(${1:x})")
  /// when `isSnippet`.
  public var insertText: String
  public var isSnippet: Bool
  /// The text the completion replaces, in the text when completions were
  /// requested. Nil replaces the word before the caret.
  public var range: NSRange?
  public var additionalEdits: [CompletionEdit]
  public var isDeprecated: Bool
  /// The provider's pick for the first selection.
  public var isPreselected: Bool
  /// The provider can fill in documentation and edits later
  /// (`CompletionProvider.resolve`).
  public var needsResolve: Bool
  /// The provider's own data for resolving the item.
  public var payload: (any Sendable)?

  public init(
    label: String, labelDetail: String? = nil, detail: String? = nil, documentation: String? = nil,
    kind: CompletionKind = .text, filterText: String? = nil, sortText: String? = nil,
    insertText: String? = nil, isSnippet: Bool = false, range: NSRange? = nil,
    additionalEdits: [CompletionEdit] = [], isDeprecated: Bool = false, isPreselected: Bool = false,
    needsResolve: Bool = false, payload: (any Sendable)? = nil
  ) {
    self.label = label
    self.labelDetail = labelDetail
    self.detail = detail
    self.documentation = documentation
    self.kind = kind
    self.filterText = filterText
    self.sortText = sortText
    self.insertText = insertText ?? label
    self.isSnippet = isSnippet
    self.range = range
    self.additionalEdits = additionalEdits
    self.isDeprecated = isDeprecated
    self.isPreselected = isPreselected
    self.needsResolve = needsResolve
    self.payload = payload
  }

  /// The text with the snippet's tab stops as Xcode placeholders
  /// (`<#name#>`), and where the caret goes when it has no placeholder.
  public var expansion: Snippet.Expansion {
    isSnippet ? Snippet.expand(insertText) : Snippet.Expansion(text: insertText, caret: nil)
  }
}

/// A provider's answer.
public struct CompletionList: Sendable {
  public var items: [CompletionItem]
  /// More typing can bring other items: ask again instead of only filtering.
  public var isIncomplete: Bool

  public init(items: [CompletionItem], isIncomplete: Bool = false) {
    self.items = items
    self.isIncomplete = isIncomplete
  }
}

/// What completions are asked for.
@MainActor public struct CompletionContext {
  public enum Trigger: Equatable, Sendable {
    /// Esc or ⌃Space.
    case invoked
    /// An identifier character typed.
    case typing
    /// One of the provider's trigger characters typed (".").
    case character(String)
    /// More typing after an incomplete list.
    case incomplete
  }

  /// The editor's text (read it before suspending; it changes with typing).
  public var text: NSString
  /// The caret.
  public var location: Int
  /// The identifier before the caret (empty right after a ".").
  public var wordRange: NSRange
  public var trigger: Trigger
  public var language: LanguageSpec?

  public init(
    text: NSString, location: Int, wordRange: NSRange, trigger: Trigger, language: LanguageSpec?
  ) {
    self.text = text
    self.location = location
    self.wordRange = wordRange
    self.trigger = trigger
    self.language = language
  }

  public var word: String { text.substring(with: wordRange) }
}

/// Where completions come from: a language server, the words in the file, …
@MainActor public protocol CompletionProvider: AnyObject {
  /// Characters that open the list when typed (".", "->"'s ">"), besides
  /// identifier characters.
  var triggerCharacters: Set<String> { get }
  /// The completions at the caret; nil when the provider has none to offer
  /// (another provider may answer).
  func completions(for context: CompletionContext) async -> CompletionList?
  /// The item with its documentation and edits filled in.
  func resolve(_ item: CompletionItem) async -> CompletionItem?
}

extension CompletionProvider {
  public var triggerCharacters: Set<String> { ["."] }
  public func resolve(_ item: CompletionItem) async -> CompletionItem? { nil }
}

/// Identifier characters for completion: letters, digits, "_" and "$".
public enum Identifier {
  public static func contains(_ c: unichar) -> Bool {
    if (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F
      || c == 0x24
    {
      return true
    }
    guard c >= 0x80, let scalar = Unicode.Scalar(c) else { return false }
    return CharacterSet.alphanumerics.contains(scalar)
  }

  public static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

  /// The identifier that ends at `location`.
  public static func range(endingAt location: Int, in text: NSString) -> NSRange {
    var start = min(location, text.length)
    while start > 0, contains(text.character(at: start - 1)) { start -= 1 }
    return NSRange(location: start, length: location - start)
  }
}
