import CodeKit
import SwiftUI

/// Code: a folder-based code editor. Each window shows one project folder;
/// a window without one shows the Welcome screen.
@main struct CodeApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup(id: WorkspaceWindow.id, for: URL.self) { $root in
      WorkspaceWindow(root: $root)
    }
    .defaultSize(width: 1200, height: 800)
    .commands { CodeCommands() }

    Settings {
      SettingsView()
    }
  }
}
