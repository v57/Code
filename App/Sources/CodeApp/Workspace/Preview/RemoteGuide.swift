import ComponentKit
import Foundation

/// Setting Remote up on another device, per system: the steps the preview pane shows when the device doesn't answer.
/// Taken from Remote's own instructions (../Remote/CLAUDE.md, 2026-11-16). Remote has no installer or download yet,
/// so every system builds the host from source; when it ships one, the first steps become one download. The
/// canvas's copy is Ideas/ComponentKit/code-boards/guide.py: change both together.
enum RemoteGuide: String, CaseIterable, Identifiable {
  case windows = "Windows"
  case linux = "Linux"
  case mac = "Mac"

  var id: String { rawValue }

  static let repository = "https://github.com/v57/Remote.git"
  /// The port a Remote host listens on (QUIC over UDP).
  static let port: UInt16 = 47_990

  /// The guide for a machine's system as its probe answered ("Darwin", "Linux", "Windows"); the Mac's when unknown.
  init(system: String?) {
    switch system {
    case "Windows": self = .windows
    case "Linux": self = .linux
    default: self = .mac
    }
  }

  func message(machine: String) -> String {
    let why = String(localized: "The preview comes through Remote, which shares a window of \(machine) with this device.")
    switch self {
    case .windows: return why + " " + String(localized: "It has no installer yet, so it is built there once.")
    case .linux:
      return why + " "
        + String(localized: "It has no package yet, so it is built there once. It needs an Xorg session; Wayland isn’t supported yet.")
    case .mac: return why + " " + String(localized: "It has no download yet, so it is built there once.")
    }
  }

  func steps(machine: String) -> [KitGuideStep] {
    let approve = KitGuideStep(
      String(localized: "Allow this device"),
      note: String(localized: "The first time, compare the six-digit code and type y in its console."))
    switch self {
    case .windows:
      return [
        .init(String(localized: "Get Remote’s source (needs Git and Swift)"), command: "git clone \(Self.repository)"),
        .init(String(localized: "Build the host"), command: "swift build --product RemoteHostWindows"),
        .init(
          String(localized: "Let it through the firewall"),
          command: "netsh advfirewall firewall add rule name=\"Remote\" dir=in action=allow protocol=UDP localport=\(Self.port)",
          note: String(localized: "As an administrator.")),
        .init(
          String(localized: "Start it on \(machine)’s desktop, signed in"), command: "RemoteHostWindows --windows",
          note: String(localized: "Not over SSH: it captures the desktop session it starts in.")),
        approve,
      ]
    case .linux:
      return [
        .init(
          String(localized: "Install what it links"),
          command: "sudo apt install libmsquic libx264-dev libxtst-dev libxext-dev libssl-dev libavcodec-dev libswscale-dev libavahi-client-dev",
          note: String(localized: "libmsquic comes from packages.microsoft.com.")),
        .init(String(localized: "Get Remote’s source"), command: "git clone \(Self.repository)"),
        .init(String(localized: "Build the host"), command: "swift build --product RemoteHostLinux"),
        .init(
          String(localized: "Start it in the desktop session"), command: ".build/debug/RemoteHostLinux --windows",
          note: String(localized: "From a terminal on its desktop, so it has the session’s DISPLAY.")),
        approve,
      ]
    case .mac:
      return [
        .init(String(localized: "Get Remote’s source (needs Xcode)"), command: "git clone \(Self.repository)"),
        .init(String(localized: "Build the app"), command: "xcodebuild -project Remote.xcodeproj -scheme Remote build"),
        .init(
          String(localized: "Open Remote on \(machine) and share Any Window"),
          note: String(localized: "Host, then Any window, then Share.")),
        .init(
          String(localized: "Allow Screen Recording and Accessibility"),
          note: String(localized: "System Settings asks when sharing starts; input needs Accessibility.")),
        .init(
          String(localized: "Nothing to approve"),
          note: String(localized: "Macs in your vault know each other’s device keys, so there is no code.")),
      ]
    }
  }
}
