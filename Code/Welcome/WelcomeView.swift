import ComponentKit
import SwiftUI
import VaultKit

/// Shown in a window without a project: the kit's welcome window. A close button instead of the title bar, the
/// app's icon, name and version, Open…, and the recent projects (click selects, double-click or Return opens) or the
/// projects the v57 apps share (added in Git and the others, through the vault), live as they change. A folder can
/// also be dropped on the window.
struct WelcomeView: View {
  static let size = CGSize(width: 480, height: 660)

  let open: (URL) -> Void
  @Environment(\.dismissWindow) private var dismissWindow
  private var recents: RecentProjects { AppState.shared.recents }
  private var vault: Vault { Vault.shared }

  /// The projects the vault shares that are on this Mac.
  private var projects: [URL] {
    vault.localProjects.compactMap(\.localURL)
      .filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  var body: some View {
    KitWelcome(
      emptyTitle: "No Recent Projects", emptyMessage: "Projects you open appear here.",
      close: { dismissWindow() },
      onDrop: { urls in
        guard let url = urls.first else { return false }
        open(url)
        return true
      }
    ) {
      WelcomeAction("Open…", detail: "Choose a folder, or drop one on this window", systemImage: "folder") {
        AppState.shared.chooseFolder()
      }
    } recents: {
      ForEach(recents.existing, id: \.self) { folder in
        item(folder, isRecent: true)
      }
    } projects: {
      ForEach(projects, id: \.self) { folder in
        item(folder, isRecent: false)
      }
    }
    .frame(maxHeight: .infinity)
    .ignoresSafeArea()
    .navigationTitle("Welcome to Code")
    .modifier(HiddenTitleBar())
  }

  private func item(_ folder: URL, isRecent: Bool) -> some View {
    RecentItem(folder.lastPathComponent, subtitle: folder.abbreviatedPath) { open(folder) }
      .contextMenu {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
        if isRecent {
          Button("Remove from Recents") { recents.remove(folder) }
        }
      }
  }
}

/// No title or title bar background: the content runs to the window's top edge (the window hides its buttons, see
/// `WindowReader`).
private struct HiddenTitleBar: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    } else {
      content
    }
  }
}
