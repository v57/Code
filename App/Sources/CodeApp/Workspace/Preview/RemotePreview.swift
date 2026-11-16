import CodeKit
import ComponentKit
import RemoteKit
import RemoteUI
import SwiftUI

/// The app on another device: the window it runs in, streamed by Remote with the pointer and keyboard. The pane
/// asks the device once; one that doesn't answer gets the guide to set Remote up there (`RemoteGuide`), with Check
/// Again. Nothing is installed from here.
struct RemotePreview: View {
  let machine: SSHExecutor.Target
  let system: String?
  /// The app to look for among the host's windows (the scheme).
  let appName: String
  @Environment(WindowModel.self) private var model
  @State private var sessions = SessionStore()
  @State private var session: ViewerSession?
  /// The device didn't answer in time, or refused the connection: Remote isn't running there.
  @State private var isMissing = false
  @State private var attempt = 0
  @State private var guide: RemoteGuide = .mac
  @State private var selectedWindow = false

  /// How long a device gets to answer before the guide shows (a connection to nothing fails only after QUIC's own
  /// 15 seconds).
  static let answerTimeout: Duration = .seconds(6)

  var body: some View {
    let state = session?.state
    KitPreviewPane(
      title(state), meta: meta(state), systemImage: symbol, hue: hue(state), status: status(state),
      source: isStreaming(state) ? String(localized: "\(machine.name) through Remote") : nil,
      sourceImage: "rectangle.on.rectangle", stats: stats(state)
    ) {
      Button("Close Preview", systemImage: "xmark") { model.togglePreview() }
        .kitHelp("Close Preview", shortcut: "⌥⌘P")
    } stage: {
      if isMissing {
        RemoteGuideView(machine: machine.name, guide: $guide) { attempt += 1 }
      } else if let session {
        if case .streaming(let info) = session.state {
          KitPreviewScreen(aspect: CGSize(width: Int(info.width), height: Int(info.height)), cornerFraction: 0.03) {
            SessionPicture(session: session)
          }
        } else {
          SessionPicture(session: session)
        }
      }
    }
    .onAppear { guide = RemoteGuide(system: system) }
    .task(id: attempt) { await connect() }
    .onChange(of: session?.isStreaming) { _, isStreaming in
      if isStreaming == true { session?.requestWindows() }
    }
    .onChange(of: session?.windows) { _, windows in pickWindow(windows ?? []) }
    .onDisappear { close() }
  }

  /// Asks the device: opens a session and gives it `answerTimeout` to get past connecting.
  private func connect() async {
    close()
    isMissing = false
    selectedWindow = false
    // Named as the machine, so the pairing question asks about it and not its address.
    var host = DiscoveredHost.address(machine.host, port: RemoteGuide.port)
    host.name = machine.name
    let session = sessions.open(host)
    self.session = session
    try? await Task.sleep(for: Self.answerTimeout)
    guard !Task.isCancelled else { return }
    switch session.state {
    case .connecting: isMissing = true
    case .closed(let reason) where reason?.hasPrefix("connection failed") == true: isMissing = true
    default: break
    }
    if isMissing { close() }
  }

  private func close() {
    if let session { sessions.close(session.id) }
    session = nil
  }

  /// The host lists its windows when it shares any of them: the app's, by its name or its window's title; for an
  /// iOS app, the simulator it runs in.
  private func pickWindow(_ windows: [WindowInfo]) {
    guard !selectedWindow, !appName.isEmpty else { return }
    let match =
      windows.first { $0.app.caseInsensitiveCompare(appName) == .orderedSame }
      ?? windows.first { $0.title.hasPrefix(appName) } ?? windows.first { $0.app == "Simulator" }
    guard let match else { return }
    selectedWindow = true
    session?.selectWindow(match.id)
  }

  private var symbol: String {
    switch system {
    case "Windows", "Linux": "pc"
    default: "desktopcomputer"
    }
  }

  private func isStreaming(_ state: RemoteViewer.State?) -> Bool {
    if case .streaming = state { true } else { false }
  }

  private func title(_ state: RemoteViewer.State?) -> String {
    isStreaming(state) && !appName.isEmpty ? appName : machine.name
  }

  private func meta(_ state: RemoteViewer.State?) -> [String] {
    if isMissing { return [String(localized: "Remote isn’t installed")] }
    switch state {
    case .streaming: return [String(localized: "Window on \(machine.name)")] + (system.map { [$0] } ?? [])
    case .pairing: return [String(localized: "Waiting for approval")]
    case .closed: return [String(localized: "Disconnected")]
    default: return [String(localized: "Connecting…")]
    }
  }

  private func hue(_ state: RemoteViewer.State?) -> Hue {
    isStreaming(state) ? .blue : .gray
  }

  private func status(_ state: RemoteViewer.State?) -> WorkStatus {
    if isMissing { return .idle }
    switch state {
    case .connecting, .waitingForStream, .pairing: return .working
    default: return .idle
    }
  }

  private func stats(_ state: RemoteViewer.State?) -> String? {
    guard isStreaming(state), let stats = session?.stats else { return nil }
    // A still window sends no frames: only the delay then.
    let parts = [
      stats.framesPerSecond > 0 ? "\(stats.framesPerSecond) fps" : nil,
      stats.roundTrip.map { String(format: "%.0f ms", $0) },
    ]
    let text = parts.compactMap { $0 }.joined(separator: " · ")
    return text.isEmpty ? nil : text
  }
}

/// The guide in the pane's stage: the steps for the system picked, and Check Again.
private struct RemoteGuideView: View {
  let machine: String
  @Binding var guide: RemoteGuide
  let check: () -> Void

  private static let systems: [(String, RemoteGuide)] = RemoteGuide.allCases.map { ($0.rawValue, $0) }

  var body: some View {
    let title = String(localized: "Remote isn’t on \(machine)")
    let message: String = guide.message(machine: machine)
    let steps: [KitGuideStep] = guide.steps(machine: machine)
    KitGuide(title, message: message, steps: steps) {
      KitSegmented(selection: $guide, options: Self.systems)
    } actions: {
      Button("Check Again", action: check).buttonStyle(.kitPrimary)
    }
  }
}
