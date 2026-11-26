import CodeKit
import ComponentKit
import SwiftUI

extension AppState {
  /// What the navigator's activity card says in `window` (`KitSidebar.activity`): every action still going, in this
  /// project first, then in the others (open in another window, or running with none); a project's last action when
  /// it failed, until it runs again or the run is dismissed; and where this project builds when that isn't this
  /// computer, or can't be reached. A tap shows the run's output in the console, in the window showing its project.
  ///
  /// All of it is what the action model already holds (`ActionController.runs`, the build source's status): nothing
  /// is asked of another machine for it.
  func navigatorActivity(in window: WindowModel) -> [SidebarActivity] {
    guard window.services.settings.actionsEnabled else { return [] }
    var models = projectModels.filter { $0 !== window }
    models.insert(window, at: 0)
    var items: [SidebarActivity] = []
    for owner in models { items += runActivity(of: owner) }
    return items + buildSourceActivity(of: window)
  }

  /// The runs going in `owner`'s project, else its newest finished run when that failed.
  private func runActivity(of owner: WindowModel) -> [SidebarActivity] {
    let actions = owner.services.actions
    let name = owner.workspace.name
    let working = actions.runs.filter(\.isWorking)
    if !working.isEmpty {
      return working.map { run in
        let status: WorkStatus
        var waitingFor: String?
        switch run.phase {
        case .waiting(let other):
          status = .waiting
          waitingFor = String(localized: "Waiting for \(other)")
        default:
          // A running app goes on as long as it likes: no amount to show.
          status = .working(progress: run.isRunningApp ? nil : run.progress?.fraction)
        }
        return SidebarActivity(
          id: run.id.uuidString, "\(run.kind.progressTitle) \(name)",
          detail: Self.detail([waitingFor ?? Self.step(of: run), Self.place(of: run)]),
          systemImage: run.kind.symbolName, hue: .orange, status: status
        ) { AppState.shared.show(run, of: owner) }
      }
    }
    let finished = actions.runs.filter { $0.finished != nil }.max { $0.finished! < $1.finished! }
    guard let run = finished, !run.isDismissed, case .failed(let summary) = run.phase else { return [] }
    return [
      SidebarActivity(
        id: run.id.uuidString, String(localized: "\(name): \(run.kind.title) failed"),
        detail: Self.failure(of: run, summary: summary), systemImage: run.kind.symbolName, hue: .red, status: .failed()
      ) { AppState.shared.show(run, of: owner) }
    ]
  }

  /// Where `window`'s project builds: a line while that place is being checked or is out of reach, and its name while
  /// it's another machine or a container. Building on this computer says nothing.
  private func buildSourceActivity(of window: WindowModel) -> [SidebarActivity] {
    let actions = window.services.actions
    let source = actions.selectedBuildSource
    switch actions.selectedBuildSourceStatus {
    case .unavailable(let reason):
      return [
        SidebarActivity(
          id: "buildSource", String(localized: "Can’t build on \(source.name)"), detail: reason,
          systemImage: source.symbolName, hue: .red, status: .failed())
      ]
    case .checking:
      return [
        SidebarActivity(
          id: "buildSource", String(localized: "Checking \(source.name)…"), systemImage: source.symbolName,
          hue: .gray, status: .working)
      ]
    case .unknown, .ready:
      guard !source.isLocal else { return [] }
      return [
        SidebarActivity(
          id: "buildSource", String(localized: "Builds on \(source.name)"), detail: window.workspace.name,
          systemImage: source.symbolName, hue: .gray)
      ]
    }
  }

  /// "Compiling 31 of 48", else the step when it says more than the action's own name.
  private static func step(of run: ActionRun) -> String? {
    if let message = run.progress?.message, !message.isEmpty { return message }
    guard let step = run.stepTitle, step != run.kind.title else { return nil }
    return step
  }

  /// "Atlas on iPhone 17 Pro": the scheme and the device it runs on, when one is chosen.
  private static func place(of run: ActionRun) -> String {
    guard let destination = run.destination else { return run.scheme.name }
    return String(localized: "\(run.scheme.name) on \(destination.name)")
  }

  /// The first error, led by the counts when there are more ("3 errors, 1 warning · Cannot find 'trip' in scope");
  /// the run's own summary ("Exit code 1") when the log named none.
  private static func failure(of run: ActionRun, summary: String) -> String {
    guard let first = run.issues.first(where: { $0.severity == .error }) else { return summary }
    let errors = run.errorCount
    let warnings = run.warningCount
    if errors == 1, warnings == 0 { return first.message }
    var counts = [String(localized: "\(errors) errors")]
    if warnings > 0 { counts.append(String(localized: "\(warnings) warnings")) }
    return counts.joined(separator: ", ") + " · " + first.message
  }

  private static func detail(_ parts: [String?]) -> String? {
    let parts = parts.compactMap { $0 }.filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

/// Build, Test and Stop in the navigator's bottom bar, on the toolbar's scheme and destination (the Product menu's
/// ⌘B, ⌘U and ⌘.); Stop only while something runs. A view of its own, so a run starting or ending updates the
/// buttons, not the navigator's tree.
struct NavigatorActionButtons: View {
  @Environment(WindowModel.self) private var model

  var body: some View {
    let actions = model.services.actions
    if model.services.settings.actionsEnabled {
      Button("Build", systemImage: ActionKind.build.symbolName) { model.perform(.build) }
        .kitHelp("Build", shortcut: "⌘B")
        .disabled(!actions.canPerform(.build))
      Button("Test", systemImage: ActionKind.test.symbolName) { model.perform(.test) }
        .kitHelp("Test", shortcut: "⌘U")
        .disabled(!actions.canPerform(.test))
      if actions.isRunning {
        Button("Stop", systemImage: "stop.fill") { actions.stop() }
          .kitHelp("Stop", shortcut: "⌘.")
      }
    }
  }
}
