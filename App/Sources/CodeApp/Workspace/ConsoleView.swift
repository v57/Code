import CodeActionsUI
import CodeKit
import ComponentKit
import SwiftUI

/// The console, on the panel ground: the debug tools while debugging, and the runs' output (every run still going and
/// the last ones finished, in the order they started) as the kit's run blocks, one per command a run ran (the build,
/// the install, the program), each with its live icon, exit chip and output; a passed command folds to its header. A
/// process card's Open in Console scrolls it to that run (`WindowModel.consoleFocus`). LLDB's prompt sits under them while debugging. It floats under the toolbar's
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
      // Over the log, for its tools' tooltips.
      bar.zIndex(1)
      let runs = ActionRuns.runs(from: services.actions, filter: filter)
      if runs.isEmpty {
        EmptyState(
          systemImage: "terminal", title: "No Output",
          message: "Run, build or test a scheme to see what it prints here.")
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            RunBlocks(selection: $selectedRun) {
              ForEach(runs) { run in
                RunBlock(
                  run.name, command: run.command, id: run.id, systemImage: run.systemImage, status: run.status,
                  progress: run.progress, warnings: run.warnings, output: run.output,
                  stop: run.status.isWorking ? { stop(run.runID) } : nil)
                .id(run.id)
              }
            }
            .padding(KitMetrics.gutter)
          }
          .defaultScrollAnchor(.bottom)
          .onAppear { scroll(to: model.consoleFocus, in: runs, proxy: proxy) }
          .onChange(of: model.consoleFocus) { _, focus in scroll(to: focus, in: runs, proxy: proxy) }
        }
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

  private func stop(_ id: ActionRun.ID?) {
    let actions = model.services.actions
    if let run = actions.runs.first(where: { $0.id == id }) { actions.stop(run) }
  }

  /// Selects the asked-for run's last block and scrolls to it.
  private func scroll(to focus: ConsoleFocus?, in runs: [ActionRuns.Run], proxy: ScrollViewProxy) {
    guard let focus, let block = runs.last(where: { $0.runID == focus.run }) else { return }
    selectedRun = block.id
    // After the console has laid out its blocks.
    Task { @MainActor in
      withKitAnimation { proxy.scrollTo(block.id, anchor: .top) }
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
        Button("Copy Log", systemImage: "doc.on.doc") {
          KitPasteboard.copy(services.actions.runs.map(\.log.text).joined(separator: "\n"))
        }
          .kitHelp("Copy Log")
        Button("Clear Console", systemImage: "trash") { services.actions.clearFinished() }
          .kitHelp("Clear Console")
        switch placement {
        case .overlay:
          Button("Open in Window", systemImage: "pip.exit") { model.detachConsole() }
            .kitHelp("Open in Window")
          Button("Close", systemImage: "xmark") { model.hideConsole() }
            .kitHelp("Close", shortcut: "⇧⌘Y")
        case .window:
          Button("Show Under Title", systemImage: "pip.enter") { model.attachConsole() }
            .kitHelp("Show under the toolbar’s title")
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
      .kitHelp(isPaused ? "Continue" : "Pause", shortcut: "⌃⌘Y")
      Button("Step Over", systemImage: "arrow.turn.down.right", action: debugger.stepOver)
        .kitHelp("Step Over", shortcut: "F6")
        .disabled(!isPaused)
      Button("Step Into", systemImage: "arrow.down.to.line", action: debugger.stepInto)
        .kitHelp("Step Into", shortcut: "F7")
        .disabled(!isPaused)
      Button("Step Out", systemImage: "arrow.up.to.line", action: debugger.stepOut)
        .kitHelp("Step Out", shortcut: "F8")
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
