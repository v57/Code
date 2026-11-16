import CodeScan
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

/// A completion candidate before it's rendered: rendering reads tokens, and only what's returned gets that.
package struct ModelCompletionHit {
  package var name: String
  /// `matchClass` of what's typed against the name.
  package var match: Int32
  /// Where it's from, lower is nearer: a tier times 100, give or take.
  package var score: Int32
  package var ref: DeclRef?
  package var localToken: Int32 = -1
  package var kind: ModelCompletionItemKind?
  package var insert: String? = nil
  package var detail: String? = nil
  package var receiver: Ty? = nil
  package var needsUnwrap = false
  /// An overload of the call the cursor opens: rendered as its arguments, the `(` already written.
  package var isArguments = false

  package init(
    name: String, match: Int32, score: Int32, ref: DeclRef?, localToken: Int32 = -1, kind: ModelCompletionItemKind? = nil, insert: String? = nil,
    detail: String? = nil, receiver: Ty? = nil, needsUnwrap: Bool = false, isArguments: Bool = false
  ) {
    self.name = name
    self.match = match
    self.score = score
    self.ref = ref
    self.localToken = localToken
    self.kind = kind
    self.insert = insert
    self.detail = detail
    self.receiver = receiver
    self.needsUnwrap = needsUnwrap
    self.isArguments = isArguments
  }
}

extension Project {
  /// Times each name is used across the project's files, read once: what's common here is more likely next.
  package var projectNameCounts: [Name: Int32] {
    if let known = cachedProjectCounts { return known }
    var counts: [Name: Int32] = [:]
    for u in 0..<projectUnits {
      for (key, value) in units[u].nameCounts { counts[key, default: 0] += value }
    }
    cachedProjectCounts = counts
    return counts
  }

  /// Completion's ranking, the same for every language: one entry per signature (`signature` keeps overloads apart),
  /// then how well it matches, where it's from and how much the file and the project use the name.
  package func rankCompletions(
    _ hits: [ModelCompletionHit], context: ModelCompletionContext, state: AnswerState, prefix: String, replaceStart: Int, limit: Int, in unit: Unit,
    signature: (DeclRef, String) -> UInt64, render: (ModelCompletionHit) -> ModelCompletionEntry
  ) -> ModelCompletionList {
    let inFile = unit.nameCounts
    let inProject = projectNameCounts
    var seen: Set<UInt64> = []
    var ranked: [(score: Int64, hit: ModelCompletionHit)] = []
    ranked.reserveCapacity(hits.count)
    for hit in hits {
      var key = hashName(hit.name)
      if let ref = hit.ref { key = signature(ref, hit.name) }
      if hit.ref == nil, hit.kind == .keyword { key &+= 1 }
      guard seen.insert(key).inserted else {
        if let at = ranked.firstIndex(where: { $0.hit.name == hit.name && $0.score > Int64(hit.score) && (hit.ref.map { signature($0, hit.name) } ?? 0) == ($0.hit.ref.map { signature($0, hit.name) } ?? 0) }) {
          ranked[at] = (Int64(hit.score), hit)
        }
        continue
      }
      ranked.append((Int64(hit.score), hit))
    }
    for index in ranked.indices {
      let hit = ranked[index].hit
      let hash = hashName(hit.name)
      let here = Int64(min(inFile[hash] ?? 0, 16))
      let there = Int64(min(inProject[hash] ?? 0, 4096))
      // Each doubling of use is worth less than one tier of where it's from.
      var lift = Int64(0)
      if here > 0 { lift += 40 + 8 * Int64(log2(Double(here))) }
      if there > 0 { lift += 6 * Int64(log2(Double(there + 1))) }
      if hit.kind == .keyword { lift = min(lift, 20) }
      ranked[index].score = Int64(hit.match) * 100_000 + (Int64(hit.score) - lift) * 16 + Int64(min(hit.name.utf8.count, 15))
    }
    let isIncomplete = ranked.count > limit
    ranked.sort {
      if $0.score != $1.score { return $0.score < $1.score }
      return $0.hit.name < $1.hit.name
    }
    let items = ranked.prefix(limit).map { render($0.hit) }
    return ModelCompletionList(context: context, state: state, prefix: prefix, replaceStart: replaceStart, items: items, isIncomplete: isIncomplete)
  }
}
