import Foundation

/// Where an answer about code comes from, fastest first: Code's scanner (tokens, in microseconds, never sure), the
/// Swift model (types from source, in milliseconds, exact or candidates), the language server (the compiler's answer,
/// slowest).
public enum DefinitionTier: Int, Sendable, Comparable, CaseIterable {
  case scanner, model, server

  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// When to ask the language server where something is defined.
public enum ServerDefinitions: String, Sendable, CaseIterable {
  /// Never: the scanner and the Swift model answer alone.
  case off
  /// When the Swift model isn't sure (always, for a language without one).
  case whenUnsure
  /// Every time: its answer is the one jumped to, the faster ones show while it works.
  case always
}

/// A place a symbol may be defined.
public struct DefinitionPlace: Hashable, Sendable {
  public var url: URL
  /// From 0.
  public var line: Int
  /// From 0, in UTF-16 units.
  public var column: Int
  /// What's declared there.
  public var name: String
  /// The line's text, trimmed, for the menu.
  public var preview: String?

  public init(url: URL, line: Int, column: Int, name: String, preview: String? = nil) {
    self.url = url.standardizedFileURL
    self.line = line
    self.column = column
    self.name = name
    self.preview = preview
  }

  /// Two tiers name the same place when they name the same line.
  var key: String { url.path + ":\(line)" }
}

/// One tier's answer.
public struct DefinitionAnswer: Sendable {
  public var tier: DefinitionTier
  /// The Swift model's exact answer, or the language server's: worth jumping to on its own.
  public var isSure: Bool
  public var places: [DefinitionPlace]

  public init(tier: DefinitionTier, isSure: Bool, places: [DefinitionPlace]) {
    self.tier = tier
    self.isSure = isSure
    self.places = places
  }
}

/// What one ⌘-click does with the tiers' answers as they arrive: jump when an answer is sure and alone, show a menu
/// when the answers are guesses or several or late, update it as better ones come, never reordering what the user
/// moved past.
///
/// - The scanner never jumps on its own while a better tier was asked: its places show only once `deadline()` passed
///   with nothing sure.
/// - A sure answer with one place jumps, unless a menu is up already, or the server was asked to have the last word
///   (`ServerDefinitions.always`) and hasn't answered.
/// - Places from several tiers are one row each; sure ones first, then by tier, best first.
public struct DefinitionChoices: Sendable {
  public enum Step: Equatable, Sendable {
    /// Nothing to do yet.
    case wait
    case jump(DefinitionPlace)
    /// Show the menu with these rows, selecting one.
    case show([Row], selecting: Int)
    /// The menu's rows changed.
    case update([Row], selecting: Int)
    /// Every tier answered, with nothing.
    case notFound
    /// Done: nothing changes.
    case none
  }

  public struct Row: Hashable, Sendable {
    public var place: DefinitionPlace
    public var tier: DefinitionTier
    public var isSure: Bool
  }

  /// The tiers still to answer.
  public private(set) var pending: Set<DefinitionTier>
  /// Every tier asked.
  public private(set) var asked: Set<DefinitionTier>
  /// The tier whose answer is waited for before jumping (the server, with `always`).
  public let decidingTier: DefinitionTier?
  public private(set) var rows: [Row] = []
  public private(set) var isShown = false
  public private(set) var isFinished = false
  private var answers: [DefinitionTier: DefinitionAnswer] = [:]
  private var deadlinePassed = false

  public init(asking tiers: Set<DefinitionTier>, decidingTier: DefinitionTier? = nil) {
    pending = tiers
    asked = tiers
    self.decidingTier = decidingTier
  }

  /// Another tier will be asked (the server, once the model wasn't sure).
  public mutating func ask(_ tier: DefinitionTier) {
    guard !asked.contains(tier) else { return }
    pending.insert(tier)
    asked.insert(tier)
  }

  /// A tier answered; nil when it had nothing to say (not running, failed).
  public mutating func receive(_ answer: DefinitionAnswer?, from tier: DefinitionTier, selectionMoved: Bool = false, selected: Int = 0)
    -> Step
  {
    pending.remove(tier)
    if let answer, !answer.places.isEmpty { answers[tier] = answer }
    return decide(selectionMoved: selectionMoved, selected: selected)
  }

  /// The time to wait for a sure answer passed: show what there is.
  public mutating func deadline(selectionMoved: Bool = false, selected: Int = 0) -> Step {
    deadlinePassed = true
    return decide(selectionMoved: selectionMoved, selected: selected)
  }

  private mutating func decide(selectionMoved: Bool, selected: Int) -> Step {
    guard !isFinished else { return .none }
    let merged = Self.merge(answers.values)
    if isShown {
      let previous = rows
      rows = Self.keep(previous, moved: selectionMoved, selected: selected, merged: merged)
      if pending.isEmpty { isFinished = true }
      guard rows != previous else { return .none }
      let selection = selectionMoved ? min(selected, rows.count - 1) : 0
      return .update(rows, selecting: selection)
    }
    // A sure answer with one place.
    if let sure = answers.values.filter(\.isSure).max(by: { $0.tier < $1.tier }), sure.places.count == 1 {
      let decided = decidingTier.map { !pending.contains($0) } ?? true
      if decided || sure.tier == decidingTier {
        isFinished = true
        return .jump(sure.places[0])
      }
    }
    if pending.isEmpty {
      isFinished = true
      if merged.isEmpty { return .notFound }
      // One place, and sure, or from the only tier asked (the scanner, for a language with nothing better).
      if merged.count == 1, merged[0].isSure || asked == [merged[0].tier] {
        return .jump(merged[0].place)
      }
      rows = merged
      isShown = true
      return .show(rows, selecting: 0)
    }
    // Guesses, several places, or a sure place the deciding tier hasn't confirmed: shown once the wait is over.
    guard deadlinePassed, !merged.isEmpty else { return .wait }
    rows = merged
    isShown = true
    return .show(rows, selecting: 0)
  }

  /// Every answer's places, one row per line: sure first, then the better tier, each tier's own order kept.
  static func merge(_ answers: some Collection<DefinitionAnswer>) -> [Row] {
    let ordered = answers.sorted { ($0.isSure ? 1 : 0, $0.tier) > ($1.isSure ? 1 : 0, $1.tier) }
    var seen = Set<String>()
    var rows: [Row] = []
    for answer in ordered {
      for place in answer.places where seen.insert(place.key).inserted {
        rows.append(Row(place: place, tier: answer.tier, isSure: answer.isSure))
      }
    }
    return rows
  }

  /// The new rows; when the user moved the selection, the rows down to it stay where they were.
  static func keep(_ previous: [Row], moved: Bool, selected: Int, merged: [Row]) -> [Row] {
    guard moved, !previous.isEmpty else { return merged }
    let kept = Array(previous.prefix(min(selected, previous.count - 1) + 1))
    let keys = Set(kept.map(\.place.key))
    // A kept row takes the better tier's word for it.
    let better = Dictionary(merged.map { ($0.place.key, $0) }, uniquingKeysWith: { first, _ in first })
    return kept.map { better[$0.place.key] ?? $0 } + merged.filter { !keys.contains($0.place.key) }
  }
}
