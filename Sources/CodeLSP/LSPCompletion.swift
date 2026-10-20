#if os(macOS) || os(Windows)
  import Foundation

  /// Why completions are asked for (the protocol's `CompletionTriggerKind`).
  public enum LSPCompletionTrigger: Equatable, Sendable {
    /// Typing an identifier, or Esc / ⌃Space.
    case invoked
    /// One of the server's trigger characters.
    case character(String)
    /// More typing after an incomplete list.
    case incomplete

    var json: JSONValue {
      switch self {
      case .invoked: return ["triggerKind": 1]
      case .character(let character):
        return ["triggerKind": 2, "triggerCharacter": .string(character)]
      case .incomplete: return ["triggerKind": 3]
      }
    }
  }

  /// A completion from a language server (`CompletionItem`), with the
  /// list's defaults applied.
  public struct LSPCompletionItem: Sendable {
    public var label: String
    /// `labelDetails.detail`: a signature right after the label.
    public var labelDetail: String?
    /// `labelDetails.description`: a type or module.
    public var labelDescription: String?
    /// `CompletionItemKind` (1…25).
    public var kind: Int?
    public var detail: String?
    /// Markdown or plain text.
    public var documentation: String?
    public var sortText: String?
    public var filterText: String?
    public var insertText: String
    /// `insertText` is a snippet ("foo(${1:x})").
    public var isSnippet: Bool
    /// The range the item replaces, in the document when it was asked for.
    public var range: LSPRange?
    public var additionalTextEdits: [LSPTextChange]
    public var isDeprecated: Bool
    public var isPreselected: Bool
    /// The item as the server sent it, for `completionItem/resolve`.
    var raw: JSONValue

    init?(_ json: JSONValue, defaults: JSONValue) {
      guard let label = json["label"].string else { return nil }
      self.label = label
      labelDetail = json["labelDetails"]["detail"].string
      labelDescription = json["labelDetails"]["description"].string
      kind = json["kind"].int
      detail = json["detail"].string
      documentation = Self.markup(json["documentation"])
      sortText = json["sortText"].string
      filterText = json["filterText"].string
      let edit = json["textEdit"]
      insertText = edit["newText"].string ?? json["insertText"].string ?? label
      let format = json["insertTextFormat"].int ?? defaults["insertTextFormat"].int ?? 1
      isSnippet = format == 2
      // A TextEdit's range, an InsertReplaceEdit's insert range, or the
      // list's default edit range.
      let editRange = defaults["editRange"]
      range =
        LSPRange(edit["range"]) ?? LSPRange(edit["insert"]) ?? LSPRange(editRange)
        ?? LSPRange(editRange["insert"])
      if edit.isNull, range != nil, let text = json["textEditText"].string { insertText = text }
      additionalTextEdits = (json["additionalTextEdits"].array ?? []).compactMap { edit in
        guard let range = LSPRange(edit["range"]), let text = edit["newText"].string else {
          return nil
        }
        return LSPTextChange(range: range, text: text)
      }
      isDeprecated = json["deprecated"].bool == true || (json["tags"].array ?? []).contains(1)
      isPreselected = json["preselect"].bool == true
      var raw = json
      if raw["data"].isNull, !defaults["data"].isNull, case .object(var object) = raw {
        object["data"] = defaults["data"]
        raw = .object(object)
      }
      self.raw = raw
    }

    /// A string or `MarkupContent`.
    static func markup(_ json: JSONValue) -> String? { json.string ?? json["value"].string }
  }

  public struct LSPCompletionList: Sendable {
    public var items: [LSPCompletionItem]
    public var isIncomplete: Bool

    /// A `CompletionList`, a bare array of items, or null.
    init(_ json: JSONValue) {
      let defaults = json["itemDefaults"]
      let items = json.array ?? json["items"].array ?? []
      self.items = items.compactMap { LSPCompletionItem($0, defaults: defaults) }
      isIncomplete = json["isIncomplete"].bool ?? false
    }
  }
#endif
