import CodeKit
import ComponentKit
import SwiftUI

/// The console, on the panel ground: the debug tools while debugging, and the last action's output as the kit's run
/// blocks, one per command it ran (the build, the install, the program), each with its live icon, exit chip and output;
/// a passed command folds to its header. LLDB's prompt sits under them while debugging. It floats under the toolbar's
/// title (`ConsoleOverlay`), or fills a window of its own (`ConsoleWindow`).
struct ConsoleView: View {
  enum Placement { case overlay, window }

  var placement = Placement.overlay
  @Environment(WindowModel.self) private var model
  @State private var command = ""
  @State private var filter = ""
  @State private var selectedRun: String?

  var body: some View {
    let services = model.services
    VStack(spacing: 0) {
      bar
      let runs = ConsoleRuns.runs(from: services.actions, filter: filter)
      if runs.isEmpty {
        EmptyState(
          systemImage: "terminal", title: "No Output",
          message: "Run, build or test a scheme to see what it prints here.")
      } else {
        ScrollView {
          RunBlocks(selection: $selectedRun) {
            ForEach(runs) { run in
              RunBlock(
                run.name, command: run.command, id: run.id, systemImage: run.systemImage, status: run.status,
                progress: run.progress, warnings: run.warnings, output: run.output,
                stop: run.status.isWorking ? { services.actions.stop() } : nil)
            }
          }
          .padding(KitMetrics.gutter)
        }
        .defaultScrollAnchor(.bottom)
      }
      if let debugger = services.debugger {
        HStack(spacing: 6) {
          Text("(lldb)")
            .kitFont(.monoSmall)
            .foregroundStyle(.kitSecondary)
          TextField("Command", text: $command)
            .kitField(mono: true)
            .onSubmit {
              guard !command.isEmpty else { return }
              debugger.sendCommand(command)
              command = ""
            }
        }
        .padding([.horizontal, .bottom], KitMetrics.gutter)
      }
    }
  }

  private var bar: some View {
    let services = model.services
    return HStack(spacing: KitMetrics.gutter) {
      if let debugger = services.debugger {
        DebugTools(debugger: debugger)
      }
      Spacer(minLength: 0)
      KitSearchField(text: $filter, prompt: "Filter")
        .frame(width: 180)
      ToolGroup(iconOnly: true) {
        Button("Copy Log", systemImage: "doc.on.doc") { KitPasteboard.copy(services.actions.log.text) }
        .help("Copy Log")
        Button("Clear Console", systemImage: "trash") { services.actions.log.clear() }
          .help("Clear Console")
        switch placement {
        case .overlay:
          Button("Open in Window", systemImage: "pip.exit") { model.detachConsole() }
            .help("Open in Window")
          Button("Close", systemImage: "xmark") { model.hideConsole() }
            .help("Close (\(Keycaps.label("⇧⌘Y")))")
        case .window:
          Button("Show Under Title", systemImage: "pip.enter") { model.attachConsole() }
            .help("Show under the toolbar's title")
        }
      }
    }
    .padding([.horizontal, .top], KitMetrics.gutter)
  }
}

/// Continue/Pause, Step Over, Step Into, Step Out, and the stopped frame.
private struct DebugTools: View {
  let debugger: DebugSession

  var body: some View {
    let isPaused: Bool = {
      if case .paused = debugger.state { return true }
      return false
    }()
    ToolGroup(iconOnly: true) {
      Button(isPaused ? "Continue" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill") {
        isPaused ? debugger.continueRunning() : debugger.pause()
      }
      .help(isPaused ? "Continue (⌃⌘Y)" : "Pause (⌃⌘Y)")
      Button("Step Over", systemImage: "arrow.turn.down.right", action: debugger.stepOver)
        .help("Step Over (F6)")
        .disabled(!isPaused)
      Button("Step Into", systemImage: "arrow.down.to.line", action: debugger.stepInto)
        .help("Step Into (F7)")
        .disabled(!isPaused)
      Button("Step Out", systemImage: "arrow.up.to.line", action: debugger.stepOut)
        .help("Step Out (F8)")
        .disabled(!isPaused)
    }
    if let frame = debugger.frame {
      Text(frame)
        .kitFont(.monoSmall)
        .foregroundStyle(.kitSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

/// The action log cut into run blocks: a new block at each command line (`$ …`), its output under it.
enum ConsoleRuns {
  struct Run: Identifiable {
    var id: String
    var name: String?
    var command: String
    var systemImage: String
    var status: WorkStatus
    var progress: String?
    var warnings: String?
    var output: String
  }

  /// Lines of output a block shows: the end of a long log (Copy Log has all of it).
  static let shownLines = 400

  @MainActor static func runs(from actions: ActionController, filter: String) -> [Run] {
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
      var dropped = 0
      if lines.count > shownLines {
        dropped = lines.count - shownLines
        lines.removeFirst(dropped)
      }
      if dropped > 0 { lines.insert("… \(dropped) earlier lines", at: 0) }
      let warnings = block.lines.filter { $0.contains("warning:") }.count
      return Run(
        id: "\(index)", name: kind?.title, command: block.command ?? kind?.title ?? "Output",
        systemImage: symbol(kind), status: status,
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

  private static func symbol(_ kind: ActionKind?) -> String {
    switch kind {
    case .run: "play.fill"
    case .build: "hammer"
    case .test: "testtube.2"
    case .clean: "trash"
    case .lint: "checklist"
    case .install: "arrow.down.app"
    case .export: "square.and.arrow.up"
    case .upload: "icloud.and.arrow.up"
    default: "terminal"
    }
  }
}
