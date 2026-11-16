import Foundation

/// Completion's answer: what could be typed at a position, ranked. The front end decides what's listed; the matching
/// of what's typed is the same for every language.
public enum ModelCompletionContext: String {
  /// After `a.`: what `a` has.
  case member
  /// After a lone `.`: what the surroundings ask for has.
  case implicitMember
  /// A name on its own: locals, the enclosing types' members, what the file's imports declare.
  case scope
  /// Where only a type goes.
  case type
  case moduleName
  case attribute
  case directive
  /// In a comment or string, or where a new name is being declared.
  case none
}

/// The values are the Language Server Protocol's `CompletionItemKind`s.
public enum ModelCompletionItemKind: Int {
  case method = 2, function, constructor, field, variable, classType, interface, module, property
  case enumeration = 13, keyword, enumMember = 20, structure = 22, typeParameter = 25
}

public struct ModelCompletionEntry {
  /// The name alone: what's matched against what's typed.
  public var name: String
  /// `name(label: Type)`.
  public var label: String
  /// A return or value type, as written.
  public var detail: String
  /// The module it's declared in, empty for a local or keyword.
  public var module: String
  public var kind: ModelCompletionItemKind
  /// Plain, or with LSP placeholders when `isSnippet`.
  public var insertText: String
  public var isSnippet: Bool
  public var isDeprecated: Bool
  /// On an optional receiver: accepting this has to write `?.`.
  public var needsUnwrap: Bool
  /// One of the overloads a call could mean, right after its `(`: `insertText` is its arguments alone.
  public var isArguments = false

  package init(
    name: String, label: String, detail: String, module: String, kind: ModelCompletionItemKind, insertText: String, isSnippet: Bool,
    isDeprecated: Bool, needsUnwrap: Bool, isArguments: Bool = false
  ) {
    self.name = name
    self.label = label
    self.detail = detail
    self.module = module
    self.kind = kind
    self.insertText = insertText
    self.isSnippet = isSnippet
    self.isDeprecated = isDeprecated
    self.needsUnwrap = needsUnwrap
    self.isArguments = isArguments
  }
}

public struct ModelCompletionList {
  public var context: ModelCompletionContext
  /// How much is known about what's listed: `exact` when the receiver or scope is, `unknown` when these are names only.
  public var state: AnswerState
  public var prefix: String
  /// Where the text being replaced starts, in UTF-8 bytes.
  public var replaceStart: Int
  public var items: [ModelCompletionEntry]
  /// More matched than `limit`.
  public var isIncomplete: Bool

  package init(context: ModelCompletionContext, state: AnswerState, prefix: String, replaceStart: Int, items: [ModelCompletionEntry], isIncomplete: Bool) {
    self.context = context
    self.state = state
    self.prefix = prefix
    self.replaceStart = replaceStart
    self.items = items
    self.isIncomplete = isIncomplete
  }
}

/// How well typed text fits a name, best first; nil when it doesn't. Case matters only for telling them apart.
@inlinable package func matchClass(_ typed: [UInt8], _ candidate: Substring.UTF8View) -> Int32? {
  if typed.isEmpty { return 0 }
  var exact = true
  var i = 0
  var isPrefix = true
  for byte in candidate {
    if i == typed.count { break }
    let a = byte
    let b = typed[i]
    if a != b { exact = false }
    if a | 0x20 != b | 0x20 {
      isPrefix = false
      break
    }
    i += 1
  }
  if isPrefix, i == typed.count { return exact ? 0 : 1 }
  // In order, each typed byte at a word's start: `tV` fits `tableView`.
  var at = 0
  var previous: UInt8 = 0x5F
  var onlyBoundaries = true
  var first = true
  for byte in candidate {
    guard at < typed.count else { break }
    if byte | 0x20 == typed[at] | 0x20 {
      let isBoundary = first || previous == 0x5F || (byte >= 0x41 && byte <= 0x5A && !(previous >= 0x41 && previous <= 0x5A))
      if !isBoundary { onlyBoundaries = false }
      at += 1
    }
    previous = byte
    first = false
  }
  guard at == typed.count else { return nil }
  return onlyBoundaries ? 2 : 3
}
