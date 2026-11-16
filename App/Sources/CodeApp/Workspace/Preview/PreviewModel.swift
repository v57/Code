import CodeKit
import CodeSimulator
import Foundation
import Observation

/// What the preview pane shows, from what the toolbar has picked.
enum PreviewTarget: Equatable {
  /// An iOS Simulator on this Mac, read straight from it (CodeSimulator).
  case simulator(RunDestination)
  /// The app runs on another device: a window of it through Remote.
  case machine(SSHExecutor.Target, system: String?)
  /// An iOS Simulator is picked, but this computer has none to read; the text says why.
  case noSimulators(String)
  /// Nothing that has a picture to show here (an app on this computer opens its own window).
  case none

  @MainActor static func current(_ actions: ActionController) -> PreviewTarget {
    let source = actions.selectedBuildSource
    if let machine = source.machine { return .machine(machine, system: actions.selectedBuildCapabilities.system) }
    guard source.isLocal, let destination = actions.selectedDestination, destination.kind == .iOSSimulator else {
      return .none
    }
    if let reason = SimulatorScreen.unavailableReason { return .noSimulators(reason) }
    return .simulator(destination)
  }
}

/// The window's preview pane: whether it shows, and the simulator it follows while it does.
@MainActor @Observable final class PreviewModel {
  /// The pane beside the editor (⌥⌘P, the toolbar's Preview button).
  private(set) var isVisible = false
  #if os(macOS)
    /// The simulator the pane follows, kept while the pane shows it.
    private(set) var screen: SimulatorScreen?
  #endif

  func setVisible(_ isVisible: Bool) {
    self.isVisible = isVisible
    if !isVisible { follow(nil) }
  }

  /// Follows the simulator with this identifier (nil: none), dropping the one before.
  func follow(_ udid: String?) {
    #if os(macOS)
      guard screen?.udid != udid else { return }
      screen?.stop()
      screen = udid.map { SimulatorScreen(udid: $0) }
      screen?.start()
    #endif
  }

  /// A line for Debug automation's dump.
  var debugDescription: String {
    guard isVisible else { return "hidden" }
    #if os(macOS)
      if let screen {
        return "simulator \(screen.name) \(screen.state) \(Int(screen.pixelSize.width))x\(Int(screen.pixelSize.height)) \(screen.framesPerSecond) fps"
      }
    #endif
    return "visible"
  }
}
