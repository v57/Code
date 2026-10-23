import CodeKit
import ComponentKit
import SwiftUI
import UpdateKit
import VaultKit

/// Code: a folder-based code editor. Each window shows one project folder;
/// a window without one shows the Welcome screen.
@main struct CodeApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  #endif

  /// Updates from GitHub Releases (Code.zip): checked daily once the user turns on automatic
  /// checks (never before), installed in place with a relaunch.
  private let updater = AppUpdater(github: "v57/Code", assetName: "Code.zip")

  init() {
    updater.start()
    if ScreenshotDemo.isOn { ScreenshotDemo.prepare() }
    // The shared projects get their app icons, for this app's lists and the other v57 apps'.
    if !ScreenshotDemo.isOn {
      Vault.shared.findProjectIcons(with: { ProjectIcon.find(in: $0) }) { ProjectIcon.thumbnail(of: $0) }
    }
  }

  var body: some Scene {
    WindowGroup(id: WorkspaceWindow.id, for: URL.self) { $root in
      WorkspaceWindow(root: $root)
        // Screenshots show every row the window has room for, never one still on its way.
        .kitLazyLoading(!ScreenshotDemo.isOn)
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

    // A project's console in a window of its own (the console's Open in Window).
    WindowGroup(id: ConsoleWindow.id, for: URL.self) { $root in
      if let root { ConsoleWindow(root: root).componentKit() }
    }
    .defaultSize(width: 720, height: 480)
    .windowToolbarStyle(.unifiedCompact)

    Settings {
      SettingsView()
        .componentKit()
    }
    .windowStyle(.hiddenTitleBar)
  }
}
