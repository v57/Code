import CodeActions
import ComponentKit

/// The actions' logs cut into the kit's run blocks (`RunBlock`), for the Mac's console and the iPhone and iPad log:
/// each run's blocks in the order they started, a new block at each command line (`$ …`), its output under it; a run's
/// last block carries its state, the ones before it passed. A long block shows its last `shownLines` lines.
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
    /// The action run the block belongs to; nil for the notes (a container runtime starting).
    public var runID: ActionRun.ID?
  }

  /// Lines of output a block shows: the end of a long log.
  public static let shownLines = 400

  /// The blocks of every run `actions` keeps, oldest first, after the notes; with a `filter`, only the output lines
  /// that contain it.
  @MainActor public static func runs(from actions: ActionController, filter: String = "") -> [Run] {
    var result = blocks(
      of: actions.notes, id: "notes", name: nil, systemImage: "terminal", status: .done, progress: nil,
      filter: filter)
    for run in actions.runs {
      result += blocks(
        of: run.log, id: run.id.uuidString, name: run.title, systemImage: run.kind.symbolName,
        status: status(of: run), progress: run.isRunningApp ? nil : run.progress?.message, filter: filter
      ).map {
        var block = $0
        block.runID = run.id
        return block
      }
    }
    return result
  }

  /// The blocks of one run: a new block at each command line, the last one carrying the run's status.
  @MainActor public static func runs(of run: ActionRun, filter: String = "") -> [Run] {
    blocks(
      of: run.log, id: run.id.uuidString, name: run.title, systemImage: run.kind.symbolName,
      status: status(of: run), progress: run.isRunningApp ? nil : run.progress?.message, filter: filter)
  }

  @MainActor private static func blocks(
    of log: ActionLog, id: String, name: String?, systemImage: String, status finalStatus: WorkStatus,
    progress: String?, filter: String
  ) -> [Run] {
    _ = log.revision
    var blocks: [(command: String?, lines: [String])] = []
    for entry in log.entries {
      if entry.kind == .command {
        blocks.append((String(entry.text.dropFirst(entry.text.hasPrefix("$ ") ? 2 : 0)), []))
        continue
      }
      if blocks.isEmpty { blocks.append((nil, [])) }
      if !filter.isEmpty, !entry.text.localizedCaseInsensitiveContains(filter) { continue }
      blocks[blocks.count - 1].lines.append(entry.text)
    }
    // A run that hasn't printed yet (waiting for another's build) still shows; the notes only when they say something.
    if blocks.isEmpty, name != nil { blocks.append((nil, [])) }
    return blocks.enumerated().map { index, block in
      let isLast = index == blocks.count - 1
      let status = isLast ? finalStatus : .done
      var lines = block.lines
      let dropped = max(0, lines.count - shownLines)
      if dropped > 0 {
        lines.removeFirst(dropped)
        lines.insert(String(localized: "… \(dropped) earlier lines"), at: 0)
      }
      let warnings = block.lines.filter { $0.contains("warning:") }.count
      return Run(
        id: "\(id)-\(index)", name: name, command: block.command ?? name ?? String(localized: "Output"),
        systemImage: systemImage, status: status,
        progress: isLast && status.isWorking ? progress : nil,
        warnings: warnings == 0
          ? nil : warnings == 1 ? String(localized: "1 warning") : String(localized: "\(warnings) warnings"),
        output: lines.joined(separator: "\n"))
    }
  }

  /// How a run stands, for its live icon.
  @MainActor public static func status(of run: ActionRun) -> WorkStatus {
    switch run.phase {
    case .waiting: return .paused()
    case .running: return .working(progress: run.isRunningApp ? nil : run.progress?.fraction)
    case .succeeded: return .done
    case .failed(let message): return .failed(message)
    case .stopped: return .paused()
    }
  }
}
