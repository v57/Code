import CodeKit
import CodeSimulator
import ComponentKit
import SwiftUI

/// Where the preview is drawn: over the editor's corner with this much room, or filling a window of its own.
enum PreviewPlacement: Equatable {
  case floating(room: CGSize)
  case window

  var isWindow: Bool { self == .window }

  /// The most a picture may take: the room less the card's bar and its insets.
  var pictureRoom: CGSize {
    switch self {
    case .floating(let room): CGSize(width: max(room.width - 16, 80), height: max(room.height - 42, 80))
    case .window: CGSize(width: CGFloat.infinity, height: CGFloat.infinity)
    }
  }
}

extension View {
  /// The running app floating over this view's corner (the canvas's Code page, "Preview" boards): a card, or a
  /// capsule when minimized; nothing while the preview is hidden or in a window of its own. Put it on the editor
  /// with its status bar, so the card sits over the bar.
  func previewOverlay(model: WindowModel) -> some View {
    overlay {
      GeometryReader { room in
        let preview = model.preview
        if preview.isVisible, !preview.isDetached {
          @Bindable var preview = preview
          KitPreviewFloat(
            corner: $preview.corner, insets: EdgeInsets(top: 8, leading: 8, bottom: PreviewContent.statusBarRoom, trailing: 8)
          ) {
            PreviewContent(
              model: model,
              placement: .floating(
                room: CGSize(
                  width: room.size.width - 16, height: room.size.height - 8 - PreviewContent.statusBarRoom))
            )
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: preview.corner.alignment.unitPoint)))
          }
        }
      }
    }
  }
}

extension Alignment {
  fileprivate var unitPoint: UnitPoint {
    switch self {
    case .bottomLeading: .bottomLeading
    case .topTrailing: .topTrailing
    case .topLeading: .topLeading
    default: .bottomTrailing
    }
  }
}

/// The preview's card for what the toolbar picked: an iOS Simulator on this Mac read from the simulator itself, or
/// a window of the device the project builds on, through Remote.
struct PreviewContent: View {
  /// The room the status bar's card takes under the floating preview.
  static let statusBarRoom: CGFloat = 46

  let model: WindowModel
  let placement: PreviewPlacement

  var body: some View {
    let actions = model.services.actions
    let target = PreviewTarget.current(actions)
    Group {
      switch target {
      case .simulator(let destination):
        #if os(macOS)
          SimulatorPreview(model: model, destination: destination, placement: placement)
        #else
          note(title: "Nothing to show here", message: "Simulators run on a Mac with Xcode.")
        #endif
      case .machine(let machine, let system):
        RemotePreview(
          machine: machine, system: system, appName: actions.selectedScheme?.name ?? "", placement: placement
        )
        .id(machine.id)
      case .noSimulators(let reason):
        note(
          title: "Simulators come with Xcode",
          message: "\(reason) Or pick a Mac that has Xcode under Build From: its simulator shows here through Remote.")
      case .none:
        note(
          title: "Nothing to show here",
          message: "Pick an iOS Simulator as the destination, or build from another device, and the running app shows here.")
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

  /// A card with words in place of a picture.
  private func note(title: String, message: String) -> some View {
    KitPreviewCard(
      "Preview", systemImage: "rectangle.inset.bottomright.filled", hue: .gray, isDetached: placement.isWindow,
      onMinimize: nil, onDetach: placement.isWindow ? { model.attachPreview() } : nil
    ) {
      Button("Close Preview", systemImage: "xmark") { model.togglePreview() }
        .kitHelp("Close Preview", shortcut: "⌥⌘P")
    } content: {
      EmptyState(systemImage: "iphone", title: title, message: message) {}
        .frame(width: 260, height: 200)
    }
  }
}

#if os(macOS)
  /// A simulator on this Mac: its screen live in the card, scaled by the card's borders, real size a click away.
  private struct SimulatorPreview: View {
    let model: WindowModel
    let destination: RunDestination
    let placement: PreviewPlacement
    @State private var isDark = false
    @State private var showsMenu = false
    /// The width a border drag began at.
    @State private var dragStart: CGFloat?
    /// The picture's width in a window of its own, which the window decides.
    @State private var windowWidth: CGFloat = 0

    /// How near real size a dragged border has to come to catch on it.
    private static let snap: CGFloat = 8

    var body: some View {
      let preview = model.preview
      let actions = model.services.actions
      let screen = preview.screen
      let isLive = screen?.state == .live
      let points = isLive ? (screen?.pointSize ?? Self.fallbackPoints) : Self.fallbackPoints
      let aspect = points.width / max(points.height, 1)
      let room = placement.pictureRoom
      let limit = max(min(room.width, room.height * aspect), PreviewModel.minimumWidth)
      let width = placement.isWindow ? windowWidth : min(max(preview.width, PreviewModel.minimumWidth), limit)
      let scale = width / max(points.width, 1)
      let isRealSize = abs(width - points.width) < 0.5
      let scheme = actions.selectedScheme?.name
      if preview.isMinimized, !placement.isWindow {
        pill(screen: screen, isLive: isLive, aspect: aspect, scheme: scheme, isStarting: actions.isRunning)
      } else {
        KitPreviewCard(
          destination.name, meta: isLive ? scheme : Self.stateText(screen), systemImage: destination.symbolName,
          hue: isLive ? .accent : .gray, status: Self.status(screen, isStarting: actions.isRunning),
          scale: isLive && width > 0 ? "\(Int((scale * 100).rounded()))%" : nil, isRealSize: isRealSize,
          isDetached: placement.isWindow,
          onScale: { toggleRealSize(points: points, limit: limit, isRealSize: isRealSize) },
          onMinimize: { withKitAnimation { preview.isMinimized = true } },
          onDetach: { placement.isWindow ? model.attachPreview() : model.detachPreview() }
        ) {
          Button("More", systemImage: "ellipsis") { showsMenu = true }
            .kitMenu(isPresented: $showsMenu) { menu(screen: isLive ? screen : nil, points: points, limit: limit) }
            .kitHelp("More")
        } content: {
          if let screen, isLive {
            picture(screen, points: points, width: width)
          } else {
            waiting(screen, scheme: scheme, isRunning: actions.isRunning)
          }
        }
        .kitPreviewResize(
          readout: isLive && !placement.isWindow
            ? (isRealSize ? String(localized: "Real size") : "\(Int((scale * 100).rounded()))%")
              + " · \(Int(width.rounded())) × \(Int((width / aspect).rounded()))" : nil,
          isSnapped: isRealSize
        ) { growth in
          guard isLive, !placement.isWindow else { return }
          let start = dragStart ?? width
          dragStart = start
          // Whichever border moved further decides; the picture keeps its shape.
          var next = start + (abs(growth.width) >= abs(growth.height * aspect) ? growth.width : growth.height * aspect)
          if abs(next - points.width) < Self.snap, points.width <= limit { next = points.width }
          preview.width = min(max(next, PreviewModel.minimumWidth), limit)
          preview.widthBeforeRealSize = nil
        } onEnded: {
          dragStart = nil
        }
        .task(id: isLive ? screen?.udid : nil) {
          guard let screen, isLive else { return }
          isDark = await SimulatorScreen.isDark(udid: screen.udid) ?? false
        }
      }
    }

    @ViewBuilder
    private func picture(_ screen: SimulatorScreen, points: CGSize, width: CGFloat) -> some View {
      let aspect = points.width / max(points.height, 1)
      let view = KitPreviewScreen(aspect: points, cornerFraction: Self.cornerFraction(points)) {
        SimulatorScreenView(screen: screen)
      }
      if placement.isWindow {
        // The window decides the size; the picture fits it, and the scale reads what it came to.
        GeometryReader { room in
          view
            .onChange(of: room.size, initial: true) { _, size in
              windowWidth = min(size.width, size.height * aspect)
            }
        }
        .frame(minWidth: 160, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        .onAppear {
          if model.preview.opensAtRealSize {
            model.preview.opensAtRealSize = false
            setWindow(points: points)
          }
        }
      } else {
        view.frame(width: width, height: (width / aspect).rounded())
      }
    }

    private func waiting(_ screen: SimulatorScreen?, scheme: String?, isRunning: Bool) -> some View {
      Group {
        if case .unavailable(let reason)? = screen?.state {
          EmptyState(systemImage: "exclamationmark.triangle", title: "Can’t read this simulator", message: "\(reason)") {}
        } else {
          EmptyState(
            systemImage: destination.symbolName,
            title: scheme.map { "Run \($0) to see it here" } ?? "Run to see it here",
            message: "The app shows here while it runs on \(destination.name).",
            status: isRunning ? .working : .idle
          ) {
            if !isRunning {
              Button("Run", systemImage: "play.fill") { model.perform(.run) }.buttonStyle(.kitPrimary)
            }
          }
        }
      }
      .frame(width: 240, height: 220)
    }

    @ViewBuilder
    private func pill(screen: SimulatorScreen?, isLive: Bool, aspect: CGFloat, scheme: String?, isStarting: Bool)
      -> some View
    {
      let restore = { withKitAnimation { model.preview.isMinimized = false } }
      if let screen, isLive {
        KitPreviewPill(
          destination.name, status: scheme.map { String(localized: "\($0) · running") },
          systemImage: destination.symbolName, action: restore
        ) {
          SimulatorScreenView(screen: screen).frame(width: 30 * aspect, height: 30)
        }
      } else {
        KitPreviewPill(
          destination.name, status: Self.stateText(screen), systemImage: destination.symbolName,
          hue: isStarting ? .accent : .gray, work: Self.status(screen, isStarting: isStarting), action: restore)
      }
    }

    @ViewBuilder
    private func menu(screen: SimulatorScreen?, points: CGSize, limit: CGFloat) -> some View {
      if let screen {
        Button("Home", systemImage: "house") { screen.press(.home) }
        Button("Lock", systemImage: "lock") { screen.press(.lock) }
        Button(isDark ? "Light Appearance" : "Dark Appearance", systemImage: isDark ? "sun.max" : "moon") {
          let next = !isDark
          isDark = next
          Task { await SimulatorScreen.setDark(next, udid: screen.udid) }
        }
        Button("Save Screenshot", systemImage: "camera") { saveScreenshot(screen) }
        Divider()
        Button("Real Size", systemImage: "1.square") {
          toggleRealSize(points: points, limit: limit, isRealSize: false)
        }
        if !placement.isWindow {
          Button("Fit the Editor", systemImage: "arrow.up.left.and.arrow.down.right") {
            withKitAnimation { model.preview.width = limit }
          }
        }
        Divider()
      }
      Button("Close Preview", systemImage: "xmark") { model.togglePreview() }
    }

    /// The scale button: real size, and back to the size before. Where the editor is too short for real size, the
    /// preview opens in its own window at that size.
    private func toggleRealSize(points: CGSize, limit: CGFloat, isRealSize: Bool) {
      let preview = model.preview
      if placement.isWindow {
        setWindow(points: points)
      } else if isRealSize {
        withKitAnimation { preview.width = preview.widthBeforeRealSize ?? PreviewModel.defaultWidth }
        preview.widthBeforeRealSize = nil
      } else if points.width <= limit {
        let before = preview.width
        withKitAnimation { preview.width = points.width }
        preview.widthBeforeRealSize = before
      } else {
        preview.opensAtRealSize = true
        model.detachPreview()
      }
    }

    /// Sizes the preview's window so the picture is at real size: the picture, the card's bar and its insets.
    private func setWindow(points: CGSize) {
      model.preview.window?.setContentSize(CGSize(width: points.width + 16, height: points.height + 42))
    }

    private static let fallbackPoints = CGSize(width: 402, height: 874)

    private static func stateText(_ screen: SimulatorScreen?) -> String {
      switch screen?.state {
      case .waiting(let state) where !state.isEmpty && state != "Shutdown": state
      default: String(localized: "Not running")
      }
    }

    private static func status(_ screen: SimulatorScreen?, isStarting: Bool) -> WorkStatus {
      if screen?.state == .live { return .idle }
      if case .waiting(let state)? = screen?.state, state == "Booting" { return .working }
      return isStarting ? .working : .idle
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

/// The preview in a window of its own (the card's Open in Its Own Window): the same card as the window's content,
/// resized by the window's borders; its arrow puts it back over the editor, and closing the window does too.
struct PreviewWindow: View {
  static let id = "preview"

  let root: URL
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var window = WindowReference()

  var body: some View {
    let model = AppState.shared.model(for: root)
    Group {
      if let model {
        PreviewContent(model: model, placement: .window)
          .environment(model)
          .navigationTitle("\(model.workspace.name) — Preview")
      } else {
        Color.clear
      }
    }
    .frame(minWidth: 200, minHeight: 260)
    .background(DetachedWindowReader(reference: window))
    .onAppear {
      if let model { model.preview.windowDidOpen(window) } else { dismissWindow() }
    }
    .onDisappear { model?.preview.windowDidClose() }
  }
}
