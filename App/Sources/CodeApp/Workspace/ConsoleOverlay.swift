import CodeKit
import ComponentKit
import SwiftUI

/// Where the toolbar's title is, for the console to hang under it.
struct ConsoleAnchorKey: PreferenceKey {
  static let defaultValue: Anchor<CGRect>? = nil

  static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
    value = value ?? nextValue()
  }
}

extension View {
  /// Marks the view the console hangs from (the toolbar's title).
  func consoleAnchor() -> some View {
    anchorPreference(key: ConsoleAnchorKey.self, value: .bounds) { $0 }
  }

  /// The console as a floating card hanging under the toolbar's title, as a tooltip hangs under its item: it opens
  /// and closes from the title (and ⇧⌘Y), Escape inside it closes it, and Open in Window moves it into a window of
  /// its own. Put it on the view the toolbar is on.
  func consoleOverlay(model: WindowModel) -> some View {
    overlayPreferenceValue(ConsoleAnchorKey.self) { anchor in
      GeometryReader { proxy in
        if model.isConsoleVisible, let anchor {
          let title = proxy[anchor]
          let gutter = KitMetrics.gutter
          let width = min(ConsoleOverlay.width, proxy.size.width - 2 * gutter)
          let x = min(max(gutter, title.minX), proxy.size.width - width - gutter)
          let y = title.maxY + 6
          let height = min(ConsoleOverlay.height, max(160, proxy.size.height - y - gutter))
          ConsoleOverlay()
            .frame(width: width, height: height)
            .offset(x: x, y: y)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        }
      }
    }
  }
}

/// The console on the kit overlays' card (the panel ground, its hairline and float shadow).
private struct ConsoleOverlay: View {
  static let width: CGFloat = 720
  static let height: CGFloat = 420

  @Environment(WindowModel.self) private var model

  var body: some View {
    ConsoleView(placement: .overlay)
      .kitOverlayCard()
      .onExitCommand { model.hideConsole() }
  }
}

/// The console in a window of its own (the overlay's Open in Window): the project's console for as long as the
/// window is open; closing it puts the console back under the toolbar's title, and closing the project closes it.
struct ConsoleWindow: View {
  static let id = "console"

  let root: URL
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var window = WindowReference()

  var body: some View {
    let model = AppState.shared.model(for: root)
    Group {
      if let model {
        ConsoleView(placement: .window)
          .kitPane(.secondary)
          .environment(model)
          .navigationTitle("\(model.workspace.name) — Console")
      } else {
        Color.clear
      }
    }
    .frame(minWidth: 420, minHeight: 240)
    .background(DetachedWindowReader(reference: window))
    .onAppear {
      if let model { model.consoleWindowDidOpen(window) } else { dismissWindow() }
    }
    .onDisappear { model?.consoleWindowDidClose() }
  }
}
