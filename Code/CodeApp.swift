import CodeKit
import SwiftUI
import UpdateKit

/// Code: a folder-based code editor. Each window shows one project folder;
/// a window without one shows the Welcome screen.
@main struct CodeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  /// Updates from GitHub Releases (Code.zip): checked daily, installed in place with a relaunch.
  private let updater = AppUpdater(github: "v57/Code", assetName: "Code.zip")

  init() { updater.start() }

  var body: some Scene {
    WindowGroup(id: WorkspaceWindow.id, for: URL.self) { $root in
      WorkspaceWindow(root: $root)
    }
    .defaultSize(width: 1200, height: 800)
    .commands {
      CodeCommands()
      UpdaterCommands(updater: updater)
    }

    Settings {
      SettingsView()
    }
  }
}
