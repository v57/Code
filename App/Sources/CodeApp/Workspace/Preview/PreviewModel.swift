import CodeKit
import CodeSimulator
import ComponentKit
import Foundation
import Observation

/// What the preview shows, from what the toolbar has picked.
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

  /// Whether there is a running app to picture: the preview then shows by itself when Run starts.
  var hasPicture: Bool {
    switch self {
    case .simulator, .machine: true
    case .noSimulators, .none: false
    }
  }
}

/// The window's preview: the running app floating over the editor's corner (`PreviewOverlay`), as a card, a capsule
/// when minimized, or in a window of its own. Where it sits and how large it is are the user's, kept between
/// launches.
@MainActor @Observable final class PreviewModel {
  /// The preview shows (⌥⌘P, the toolbar's Preview button), in whichever form.
  private(set) var isVisible = false
  /// Folded into a capsule in its corner.
  var isMinimized = false
  /// In a window of its own (`PreviewWindow`) instead of over the editor.
  private(set) var isDetached = false
  /// That window, while it is open.
  @ObservationIgnored var window: WindowReference?
  /// The window opens at the device's real size (real size was asked for where the editor is too short for it).
  @ObservationIgnored var opensAtRealSize = false

  /// The editor's corner the card sits in.
  var corner: KitPreviewCorner = KitPreviewCorner(rawValue: UserDefaults.standard.string(forKey: Keys.corner) ?? "")
    ?? .bottomTrailing
  {
    didSet { UserDefaults.standard.set(corner.rawValue, forKey: Keys.corner) }
  }
  /// A simulator's picture: its width in this display's points (its height follows its shape).
  var width: CGFloat = {
    let saved = UserDefaults.standard.double(forKey: Keys.width)
    return saved >= PreviewModel.minimumWidth ? saved : PreviewModel.defaultWidth
  }()
  {
    didSet { UserDefaults.standard.set(Double(width), forKey: Keys.width) }
  }
  /// The width real size came from, to go back to.
  var widthBeforeRealSize: CGFloat?

  static let defaultWidth: CGFloat = 221
  static let minimumWidth: CGFloat = 120

  private enum Keys {
    static let corner = "preview.corner"
    static let width = "preview.width"
  }

  #if os(macOS)
    /// The simulator the preview follows, kept while it shows.
    private(set) var screen: SimulatorScreen?
  #endif

  func setVisible(_ isVisible: Bool) {
    self.isVisible = isVisible
    if !isVisible {
      follow(nil)
      window?.close()
    }
  }

  func windowDidOpen(_ window: WindowReference) {
    self.window = window
    isDetached = true
  }

  func windowDidClose() {
    window = nil
    isDetached = false
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
    var parts = [isDetached ? "window" : isMinimized ? "minimized" : "card", corner.rawValue, "width \(Int(width))"]
    #if os(macOS)
      if let screen {
        parts.append(
          "simulator \(screen.name) \(screen.state) \(Int(screen.pixelSize.width))x\(Int(screen.pixelSize.height)) @\(Int(screen.pixelsPerPoint))x \(screen.framesPerSecond) fps"
        )
      }
    #endif
    return parts.joined(separator: " ")
  }
}
