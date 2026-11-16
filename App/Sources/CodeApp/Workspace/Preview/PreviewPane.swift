import CodeKit
import CodeSimulator
import ComponentKit
import SwiftUI

/// The running app beside the editor (the canvas's Code page, "Preview" boards): an iOS Simulator on this Mac read
/// from the simulator itself, or a window of the device the project builds on, through Remote.
struct PreviewPane: View {
  let model: WindowModel

  var body: some View {
    let actions = model.services.actions
    let target = PreviewTarget.current(actions)
    Group {
      switch target {
      case .simulator(let destination):
        #if os(macOS)
          SimulatorPreview(model: model, destination: destination)
        #else
          nothing
        #endif
      case .machine(let machine, let system):
        RemotePreview(machine: machine, system: system, appName: actions.selectedScheme?.name ?? "")
          .id(machine.id)
      case .noSimulators(let reason):
        KitPreviewPane("iOS Simulator", meta: [String(localized: "Needs Xcode")], systemImage: "iphone", hue: .gray) {
          closeButton
        } stage: {
          EmptyState(
            systemImage: "arrow.down.circle", title: "Simulators come with Xcode",
            message: "\(reason) Or pick a Mac that has Xcode under Build From: its simulator shows here through Remote."
          ) {}
        }
      case .none:
        nothing
      }
    }
    .onChange(of: target, initial: true) { _, target in
      if case .simulator(let destination) = target {
        model.preview.follow(destination.id)
      } else {
        model.preview.follow(nil)
      }
    }
  }

  private var nothing: some View {
    KitPreviewPane("Preview", systemImage: "rectangle.righthalf.inset.filled", hue: .gray) {
      closeButton
    } stage: {
      EmptyState(
        systemImage: "iphone", title: "Nothing to show here",
        message: "Pick an iOS Simulator as the destination, or build from another device, and the running app shows in this pane."
      ) {}
    }
  }

  private var closeButton: some View {
    Button("Close Preview", systemImage: "xmark") { model.togglePreview() }
      .kitHelp("Close Preview", shortcut: "⌥⌘P")
  }
}

#if os(macOS)
  /// A simulator on this Mac: its screen live, with the device's buttons in the bar.
  private struct SimulatorPreview: View {
    let model: WindowModel
    let destination: RunDestination
    @State private var isDark = false

    var body: some View {
      let actions = model.services.actions
      let screen = model.preview.screen
      let isLive = screen?.state == .live
      let scheme = actions.selectedScheme?.name ?? ""
      KitPreviewPane(
        destination.name, meta: meta(screen), systemImage: destination.symbolName, hue: isLive ? .accent : .gray,
        status: status(screen, isStarting: actions.isRunning), source: isLive ? String(localized: "Simulator on this Mac") : nil,
        stats: Self.stats(screen)
      ) {
        if isLive, let screen {
          Button("Home", systemImage: "house") { screen.press(.home) }
            .kitHelp("Home")
          Button("Lock", systemImage: "lock") { screen.press(.lock) }
            .kitHelp("Lock")
          Button(isDark ? "Light Appearance" : "Dark Appearance", systemImage: isDark ? "sun.max" : "moon") {
            let next = !isDark
            isDark = next
            Task { await SimulatorScreen.setDark(next, udid: screen.udid) }
          }
          .kitHelp(isDark ? "Light Appearance" : "Dark Appearance")
          Button("Save Screenshot", systemImage: "camera") { saveScreenshot(screen) }
            .kitHelp("Save Screenshot", meta: "To the Desktop")
        }
        Button("Close Preview", systemImage: "xmark") { model.togglePreview() }
          .kitHelp("Close Preview", shortcut: "⌥⌘P")
      } stage: {
        if let screen, isLive {
          let turned = screen.quarterTurns % 2 == 1
          let size = screen.pixelSize
          KitPreviewScreen(
            aspect: turned ? CGSize(width: size.height, height: size.width) : size,
            cornerFraction: Self.cornerFraction(size)
          ) {
            SimulatorScreenView(screen: screen)
          }
        } else if case .unavailable(let reason)? = screen?.state {
          EmptyState(systemImage: "exclamationmark.triangle", title: "Can’t read this simulator", message: "\(reason)") {}
        } else {
          EmptyState(
            systemImage: destination.symbolName,
            title: scheme.isEmpty ? "Run to see it here" : "Run \(scheme) to see it here",
            message: "The app shows in this pane while it runs on \(destination.name).",
            status: actions.isRunning ? .working : .idle
          ) {
            if !actions.isRunning {
              Button("Run", systemImage: "play.fill") { model.perform(.run) }.buttonStyle(.kitPrimary)
            }
          }
        }
      }
      .task(id: screen?.state == .live ? screen?.udid : nil) {
        guard let screen, screen.state == .live else { return }
        isDark = await SimulatorScreen.isDark(udid: screen.udid) ?? false
      }
    }

    private func meta(_ screen: SimulatorScreen?) -> [String] {
      switch screen?.state {
      case .live: [(destination.detail ?? "").replacingOccurrences(of: " (Booted)", with: "")].filter { !$0.isEmpty }
      case .waiting(let state) where !state.isEmpty && state != "Shutdown": [state]
      default: [String(localized: "Not running")]
      }
    }

    private func status(_ screen: SimulatorScreen?, isStarting: Bool) -> WorkStatus {
      if screen?.state == .live { return .idle }
      if case .waiting(let state)? = screen?.state, state == "Booting" { return .working }
      return isStarting ? .working : .idle
    }

    /// Frames a second while the picture moves; nothing while it is still (a simulator draws only what changes).
    static func stats(_ screen: SimulatorScreen?) -> String? {
      guard let screen, screen.state == .live, screen.framesPerSecond > 0 else { return nil }
      return "\(screen.framesPerSecond) fps"
    }

    /// The screen's corners as a part of its width: a phone's are rounder than a tablet's.
    static func cornerFraction(_ size: CGSize) -> CGFloat {
      guard size.width > 0, size.height > 0 else { return 0.13 }
      return min(size.width, size.height) / max(size.width, size.height) < 0.6 ? 0.13 : 0.04
    }

    private func saveScreenshot(_ screen: SimulatorScreen) {
      let name = "\(screen.name) \(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))) \(Date.now.formatted(date: .omitted, time: .standard).replacingOccurrences(of: ":", with: "."))"
      let url = URL.desktopDirectory.appendingPathComponent(name).appendingPathExtension("png")
      if screen.writePNG(to: url) { KitDesktop.reveal([url]) }
    }
  }
#endif
