import CodeKit
import ComponentKit
import SwiftUI
import UpdateKit

/// Code: a folder-based code editor. Each window shows one project folder;
/// a window without one shows the Welcome screen.
@main struct CodeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  /// Updates from GitHub Releases (Code.zip): checked daily once the user turns on automatic
  /// checks (never before), installed in place with a relaunch.
  private let updater = AppUpdater(github: "v57/Code", assetName: "Code.zip")

  init() {
    updater.start()
    if ScreenshotDemo.isOn { ScreenshotDemo.prepare() }
  }

  var body: some Scene {
    WindowGroup(id: WorkspaceWindow.id, for: URL.self) { $root in
      WorkspaceWindow(root: $root)
        .componentKit()
    }
    .defaultSize(width: 1200, height: 800)
    .commands {
      CodeCommands()
      UpdaterCommands(updater: updater)
    }

    // A document opened in a window of its own (Open in New Window).
    WindowGroup(id: DetachedEditorWindow.id, for: UUID.self) { $documentID in
      if let documentID { DetachedEditorWindow(documentID: documentID).componentKit() }
    }
    .defaultSize(width: 720, height: 560)
    .windowToolbarStyle(.unifiedCompact)

    Settings {
      SettingsView()
        .componentKit()
    }
    .windowStyle(.hiddenTitleBar)
  }
}
