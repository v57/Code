#if os(macOS)
import AppKit

/// Saves on deactivation and quit, and serves the Dock menu of recent
/// projects. Folders and files opened from Finder or the Dock arrive through
/// `onOpenURL` in `WorkspaceWindow`.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Earlier versions saved the open projects here to reopen them.
    UserDefaults.standard.removeObject(forKey: "openProjects")
    #if DEBUG
      DebugAutomation.start()
    #endif
  }

  func applicationDidResignActive(_ notification: Notification) {
    AppState.shared.flushAll()
  }

  /// Runs before any window closes, so every project's session is saved.
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    AppState.shared.flushAll()
    return .terminateNow
  }

  func applicationWillTerminate(_ notification: Notification) {
    AppState.shared.flushAll()
  }

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    let menu = NSMenu()
    for folder in AppState.shared.recents.existing.prefix(10) {
      let item = NSMenuItem(
        title: folder.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = folder
      item.toolTip = folder.abbreviatedPath
      menu.addItem(item)
    }
    return menu
  }

  @objc private func openRecent(_ sender: NSMenuItem) {
    guard let folder = sender.representedObject as? URL else { return }
    AppState.shared.open(folder)
  }
}
#endif
