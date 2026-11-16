import CodeKit
import ComponentKit
import RemoteKit
import RemoteUI
import SwiftUI

/// The app on another device: the window it runs in, streamed by Remote with the pointer and keyboard, in the
/// preview's card. It is a real window, so the card's borders resize the window on that device and nothing is
/// scaled (only a window larger than the editor allows is shown smaller). The card asks the device once; one that
/// doesn't answer gets the guide to set Remote up there (`RemoteGuide`), with Check Again. Nothing is installed
/// from here.
struct RemotePreview: View {
  let machine: SSHExecutor.Target
  let system: String?
  /// The app to look for among the host's windows (the scheme).
  let appName: String
  let placement: PreviewPlacement
  @Environment(WindowModel.self) private var model
  @State private var sessions = SessionStore()
  @State private var session: ViewerSession?
  /// The device didn't answer in time, or refused the connection: Remote isn't running there.
  @State private var isMissing = false
  @State private var attempt = 0
  @State private var guide: RemoteGuide = .mac
  @State private var selectedWindow = false
  /// The window's size when a border drag began, and the size the drag asks for (the device's points).
  @State private var dragStart: CGSize?
  @State private var asked: CGSize?

  /// How long a device gets to answer before the guide shows (a connection to nothing fails only after QUIC's own
  /// 15 seconds).
  static let answerTimeout: Duration = .seconds(6)
  /// The smallest window a border drag asks for.
  static let minimumWindow = CGSize(width: 240, height: 160)

  var body: some View {
    let state = session?.state
    let preview = model.preview
    Group {
      if preview.isMinimized, !placement.isWindow {
        KitPreviewPill(
          title(state), status: meta(state), systemImage: symbol, hue: hue(state), work: status(state)
        ) {
          withKitAnimation { preview.isMinimized = false }
        }
      } else {
        KitPreviewCard(
          title(state), meta: meta(state), systemImage: symbol, hue: hue(state), status: status(state),
          scale: fitText(state), isDetached: placement.isWindow, onScale: nil,
          onMinimize: { withKitAnimation { preview.isMinimized = true } },
          onDetach: { placement.isWindow ? model.attachPreview() : model.detachPreview() }
        ) {
          Button("Close Preview", systemImage: "xmark") { model.togglePreview() }
            .kitHelp("Close Preview", shortcut: "⌥⌘P")
        } content: {
          stage(state)
        }
        .kitPreviewResize(readout: readout(state)) { growth in
          guard !placement.isWindow, case .streaming(let info) = state else { return }
          let start = dragStart ?? CGSize(width: Int(info.sourceWidth), height: Int(info.sourceHeight))
          dragStart = start
          // The drag is in this display's points; the window is shown at `fit` of its own.
          let fit = fitScale(source: start)
          asked = CGSize(
            width: max(start.width + growth.width / fit, Self.minimumWindow.width).rounded(),
            height: max(start.height + growth.height / fit, Self.minimumWindow.height).rounded())
        } onEnded: {
          dragStart = nil
          if let asked { session?.resizeWindow(width: Int(asked.width), height: Int(asked.height)) }
        }
      }
    }
    .onAppear { guide = RemoteGuide(system: system) }
    .task(id: attempt) { await connect() }
    .onChange(of: session?.isStreaming) { _, isStreaming in
      if isStreaming == true { session?.requestWindows() }
    }
    .onChange(of: session?.windows) { _, windows in pickWindow(windows ?? []) }
    // The window came back at its new size (or the host kept the old one): the picture is the stream's again.
    .onChange(of: sourceSize(state)) { _, _ in asked = nil }
    .task(id: asked) {
      guard asked != nil, dragStart == nil else { return }
      try? await Task.sleep(for: .seconds(3))
      if !Task.isCancelled, dragStart == nil { asked = nil }
    }
    .onDisappear { close() }
  }

  @ViewBuilder
  private func stage(_ state: RemoteViewer.State?) -> some View {
    if isMissing {
      RemoteGuideView(machine: machine.name, guide: $guide) { attempt += 1 }
        .frame(width: 340)
        .frame(maxHeight: placement.isWindow ? .infinity : min(placement.pictureRoom.height, 600))
    } else if let session {
      if case .streaming(let info) = session.state {
        let source = CGSize(width: Int(info.sourceWidth), height: Int(info.sourceHeight))
        let picture = KitPreviewScreen(aspect: asked ?? source, cornerFraction: 0.02) {
          SessionPicture(session: session)
        }
        if placement.isWindow {
          picture.frame(minWidth: 200, maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
        } else {
          // While a border is dragged the frame is the size asked for; the window fills it once it has resized.
          let shown = asked ?? source
          let fit = fitScale(source: shown)
          picture.frame(width: (shown.width * fit).rounded(), height: (shown.height * fit).rounded())
        }
      } else {
        SessionPicture(session: session).frame(width: 300, height: 240)
      }
    }
  }

  /// A window is shown as large as it is; one larger than the editor allows is shown smaller, to fit.
  private func fitScale(source: CGSize) -> CGFloat {
    guard !placement.isWindow, source.width > 0, source.height > 0 else { return 1 }
    let room = placement.pictureRoom
    return min(1, room.width / source.width, room.height / source.height)
  }

  private func sourceSize(_ state: RemoteViewer.State?) -> CGSize? {
    guard case .streaming(let info) = state else { return nil }
    return CGSize(width: Int(info.sourceWidth), height: Int(info.sourceHeight))
  }

  /// "Fit" in the bar while the window is shown smaller than it is.
  private func fitText(_ state: RemoteViewer.State?) -> String? {
    guard let source = sourceSize(state), fitScale(source: source) < 0.995 else { return nil }
    return String(localized: "Fit")
  }

  private func readout(_ state: RemoteViewer.State?) -> String? {
    guard let size = asked ?? sourceSize(state), !placement.isWindow else { return nil }
    return String(localized: "\(appName.isEmpty ? machine.name : appName) on \(machine.name)")
      + " · \(Int(size.width)) × \(Int(size.height))"
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

  private func meta(_ state: RemoteViewer.State?) -> String {
    if isMissing { return String(localized: "Remote isn’t installed") }
    switch state {
    case .streaming: return appName.isEmpty ? String(localized: "through Remote") : machine.name
    case .pairing: return String(localized: "Waiting for approval")
    case .closed: return String(localized: "Disconnected")
    default: return String(localized: "Connecting…")
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
}

/// The guide in the card: the steps for the system picked, and Check Again.
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
