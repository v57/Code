import CodeActions
import ComponentKit

/// An action's log cut into the kit's run blocks (`RunBlock`), for the Mac's console and the iPhone and iPad log: a
/// new block at each command line (`$ …`), its output under it; the last block carries the action's state, the ones
/// before it passed. A long block shows its last `shownLines` lines.
///
/// ```swift
/// RunBlocks {
///   ForEach(ActionRuns.runs(from: actions)) { run in
///     RunBlock(run.name, command: run.command, id: run.id, systemImage: run.systemImage, status: run.status,
///              progress: run.progress, warnings: run.warnings, output: run.output)
///   }
/// }
/// ```
public enum ActionRuns {
  public struct Run: Identifiable {
    public var id: String
    public var name: String?
    public var command: String
    public var systemImage: String
    public var status: WorkStatus
    public var progress: String?
    public var warnings: String?
    public var output: String
  }

  /// Lines of output a block shows: the end of a long log.
  public static let shownLines = 400

  /// The blocks of `actions`' log; with a `filter`, only the output lines that contain it.
  @MainActor public static func runs(from actions: ActionController, filter: String = "") -> [Run] {
    _ = actions.log.revision
    let (kind, finalStatus) = state(of: actions)
    var blocks: [(command: String?, lines: [String])] = []
    for entry in actions.log.entries {
      if entry.kind == .command {
        blocks.append((String(entry.text.dropFirst(entry.text.hasPrefix("$ ") ? 2 : 0)), []))
        continue
      }
      if blocks.isEmpty { blocks.append((nil, [])) }
      if !filter.isEmpty, !entry.text.localizedCaseInsensitiveContains(filter) { continue }
      blocks[blocks.count - 1].lines.append(entry.text)
    }
    return blocks.enumerated().map { index, block in
      let isLast = index == blocks.count - 1
      let status = isLast ? finalStatus : .done
      var lines = block.lines
      let dropped = max(0, lines.count - shownLines)
      if dropped > 0 {
        lines.removeFirst(dropped)
        lines.insert("… \(dropped) earlier lines", at: 0)
      }
      let warnings = block.lines.filter { $0.contains("warning:") }.count
      return Run(
        id: "\(index)", name: kind?.title, command: block.command ?? kind?.title ?? "Output",
        systemImage: kind?.symbolName ?? "terminal", status: status,
        progress: isLast && status.isWorking ? actions.progress?.message : nil,
        warnings: warnings == 0 ? nil : warnings == 1 ? "1 warning" : "\(warnings) warnings",
        output: lines.joined(separator: "\n"))
    }
  }

  /// The action the log belongs to and how its last command stands.
  @MainActor private static func state(of actions: ActionController) -> (ActionKind?, WorkStatus) {
    switch actions.state {
    case .idle: return (nil, .done)
    case .running(let kind): return (kind, .working(progress: actions.progress?.fraction))
    case .succeeded(let kind, _): return (kind, .done)
    case .failed(let kind, _, let message): return (kind, .failed(message))
    case .stopped(let kind, _): return (kind, .paused())
    }
  }
}
