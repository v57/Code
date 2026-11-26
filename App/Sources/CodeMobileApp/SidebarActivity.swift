import CodeActions
import ComponentKit
import SwiftUI

/// The project a window shows now, for the projects sidebar beside it: its activity card says what the project is
/// doing on its device, and its bottom bar runs Build, Test and Stop there. The project's screen owns the session
/// (`ProjectSessionLifetime`) and names it here once it shows.
@MainActor @Observable final class ShownProject {
  var session: ProjectSession?
  /// The pane the sidebar's activity line asks the project's screen for (the log, the issues); the screen takes it.
  var requestedPane: ProjectScreen.Pane?
}

extension ProjectSession {
  /// The project's line in the sidebar's activity card (`KitSidebar.activity`), from what the session already knows:
  /// connecting to its device, the devices that couldn't be reached, the action running there with its step and
  /// progress, the last action when it failed, else the device it builds on. Nothing is asked of a device for it.
  ///
  /// - Parameter show: shows the log or the issues on the project's screen (a tap on a run's line).
  func sidebarActivity(show: @escaping @MainActor (ProjectScreen.Pane) -> Void) -> [SidebarActivity] {
    let name = project.name
    switch phase {
    case .loading(let message):
      return [SidebarActivity(id: "open", name, detail: message, systemImage: "desktopcomputer", hue: .gray, status: .working)]
    case .failed(let message):
      // One line per device tried ("studio-mac: No route to host"): the first leads.
      return [
        SidebarActivity(
          id: "open", String(localized: "Couldn’t Open \(name)"),
          detail: message.split(separator: "\n").first.map(String.init), systemImage: "desktopcomputer", hue: .red,
          status: .failed())
      ]
    case .ready: break
    }
    guard let controller else { return [] }
    let device = controller.selectedDestination
    let place = device.map { String(localized: "on \($0.name)") }
    switch controller.state {
    case .running(let kind):
      let step = controller.progress?.message ?? controller.stepTitle ?? ""
      return [
        SidebarActivity(
          id: "run", "\(kind.progressTitle) \(name)",
          detail: [step == kind.title ? "" : step, place ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
          systemImage: kind.symbolName, hue: .orange, status: .working(progress: controller.progress?.fraction)
        ) { show(.log) }
      ]
    case .failed(let kind, _, let summary):
      let hasIssues = !controller.issues.isEmpty
      return [
        SidebarActivity(
          id: "run", String(localized: "\(name): \(kind.title) failed"), detail: Self.failure(controller, summary: summary),
          systemImage: kind.symbolName, hue: .red, status: .failed()
        ) { show(hasIssues ? .issues : .log) }
      ]
    case .idle, .succeeded, .stopped:
      guard let device else { return [] }
      return [
        SidebarActivity(
          id: "device", String(localized: "Builds on \(device.name)"),
          detail: [name, device.detail ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
          systemImage: device.symbolName, hue: .gray)
      ]
    }
  }

  /// The first error, led by the counts when there are more ("3 errors, 1 warning · Cannot find 'trip' in scope");
  /// the action's own summary ("Exit code 1") when the log named none.
  private static func failure(_ controller: ActionController, summary: String) -> String {
    guard let first = controller.issues.first(where: { $0.severity == .error }) else { return summary }
    let errors = controller.errorCount
    let warnings = controller.warningCount
    if errors == 1, warnings == 0 { return first.message }
    var counts = [String(localized: "\(errors) errors")]
    if warnings > 0 { counts.append(String(localized: "\(warnings) warnings")) }
    return counts.joined(separator: ", ") + " · " + first.message
  }
}

/// Build, Test and Stop for the project beside the sidebar, in its bottom bar: the project's toolbar actions
/// (`ActionTools`) on its scheme and device; Stop only while one runs. Disabled while no project is open or it has
/// nothing to build yet.
struct SidebarActionButtons: View {
  /// The shown project's actions, nil while none is open (or it is still connecting).
  let controller: ActionController?

  var body: some View {
    // Only with a project to build: two disabled buttons took the bar's room from the devices' count (296pt beside
    // an unfolded iPhone Duo's page).
    if let controller {
      ForEach([ActionKind.build, .test], id: \.self) { kind in
        Button(kind.title, systemImage: kind.symbolName) { controller.perform(kind) }
          .disabled(!canPerform(kind))
      }
      if controller.isRunning { StopButton(controller: controller).labelStyle(.iconOnly) }
    }
  }

  private func canPerform(_ kind: ActionKind) -> Bool {
    guard let controller else { return false }
    return controller.canPerform(kind) && controller.selectedDestination != nil && !controller.isRunning
  }
}
