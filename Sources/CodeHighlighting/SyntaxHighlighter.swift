import Foundation

/// Incremental syntax highlighting for an editor buffer.
///
/// Keeps, for every line, the scanner state the line starts in and the line's
/// tokens. After an edit only the touched lines are rescanned, then following
/// lines until one ends in the state the next line already starts in. Typing
/// usually rescans one line; opening a block comment rescans until it closes.
///
/// Rescanning can stop early at a line budget (so a keystroke stays fast in a
/// long file): the first line that still needs a rescan goes to `pending`, and
/// `continuePending` picks it up later. Platform-neutral; the AppKit editor
/// turns the rescanned lines into colors.
public struct SyntaxHighlighter: Sendable {
  public let spec: LanguageSpec
  public private(set) var lines: LineIndex
  /// The state each line starts in; `startStates[0] == .normal`.
  private var startStates: [LineState]
  /// Each line's tokens, with ranges relative to the line start.
  private var lineTokens: [[CodeToken]]
  /// Lines whose start state changed but that were not rescanned yet.
  public private(set) var pending: [Int] = []
  private let scanner: CodeScanner

  /// Scans all of `text`.
  public init(text: NSString, spec: LanguageSpec) {
    self.spec = spec
    scanner = CodeScanner(spec: spec)
    lines = LineIndex(text)
    startStates = Array(repeating: .normal, count: lines.count)
    lineTokens = Array(repeating: [], count: lines.count)
    var state = LineState.normal
    for line in 0..<lines.count {
      startStates[line] = state
      state = scan(line, in: text)
    }
  }

  /// Tokens of `line`, with document offsets.
  public func tokens(ofLine line: Int) -> [CodeToken] {
    let start = lines.starts[line]
    return lineTokens[line].map {
      CodeToken(range: NSRange(location: start + $0.range.location, length: $0.range.length), kind: $0.kind)
    }
  }

  /// Every token, with document offsets.
  public var allTokens: [CodeToken] { (0..<lines.count).flatMap { tokens(ofLine: $0) } }

  public func startState(ofLine line: Int) -> LineState { startStates[line] }

  /// Updates the highlighting after the characters in `range` (old
  /// coordinates) were replaced with `replacementLength` characters; `text`
  /// is the new text. Rescans at most `budget` lines past the edited ones.
  /// Returns the rescanned lines, whose colors need to be re-applied.
  @discardableResult
  public mutating func edit(
    range: NSRange, replacementLength: Int, in text: NSString, budget: Int = .max
  ) -> Range<Int> {
    let oldCount = lines.count
    let changed = lines.apply(edit: range, replacementLength: replacementLength, in: text)
    let lineDelta = lines.count - oldCount
    let oldChangedEnd = changed.upperBound - lineDelta
    // The changed lines get placeholders; their first line keeps its start
    // state (nothing before it changed).
    let firstState = startStates[changed.lowerBound]
    startStates.replaceSubrange(
      changed.lowerBound..<oldChangedEnd, with: Array(repeating: .normal, count: changed.count))
    startStates[changed.lowerBound] = firstState
    lineTokens.replaceSubrange(
      changed.lowerBound..<oldChangedEnd, with: Array(repeating: [], count: changed.count))
    pending = pending.compactMap { line in
      if line < changed.lowerBound { return line }
      if line >= oldChangedEnd { return line + lineDelta }
      return nil
    }
    return rescan(from: changed.lowerBound, through: changed.upperBound - 1, in: text, budget: budget)
  }

  /// Rescans from the first pending line, at most `budget` lines. Returns the
  /// rescanned lines, or nil when nothing was pending.
  public mutating func continuePending(in text: NSString, budget: Int = .max) -> Range<Int>? {
    guard let first = pending.min() else { return nil }
    return rescan(from: first, through: first, in: text, budget: budget)
  }

  /// Rescans `first...last`, then on until a line ends in the state the next
  /// line starts in (and that line is not pending), or the budget runs out.
  private mutating func rescan(from first: Int, through last: Int, in text: NSString, budget: Int)
    -> Range<Int>
  {
    var line = first
    var scannedPastLast = 0
    while true {
      pending.removeAll { $0 == line }
      let end = scan(line, in: text)
      let next = line + 1
      if next >= lines.count { break }
      if next > last {
        if startStates[next] == end && !pending.contains(next) { break }
        if scannedPastLast >= budget {
          startStates[next] = end
          if !pending.contains(next) { pending.append(next) }
          break
        }
        scannedPastLast += 1
      }
      startStates[next] = end
      line = next
    }
    return first..<(line + 1)
  }

  /// Scans `line` from its stored start state; stores its tokens and returns
  /// its end state.
  private mutating func scan(_ line: Int, in text: NSString) -> LineState {
    let range = lines.contentRange(ofLine: line, in: text)
    let result = scanner.scanLine(
      text.substring(with: range) as NSString, at: 0, state: startStates[line])
    lineTokens[line] = result.tokens
    return result.end
  }
}
