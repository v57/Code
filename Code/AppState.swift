import CodeKit
import SwiftUI

/// App-wide state: recent projects and the open workspaces.
@MainActor @Observable final class AppState {
  static let shared = AppState()
  #if DEBUG
    /// The window the last debug automation command acts on.
    @ObservationIgnored weak var debugModel: WindowModel?
  #endif

  let recents = RecentProjects()
  /// Captured from the windows; opens project windows from menus outside a
  /// window's view tree (the Dock menu).
  @ObservationIgnored var openWindow: OpenWindowAction?
  /// Files to open once their folder's window is up, by folder.
  @ObservationIgnored private var pendingFiles: [URL: [URL]] = [:]
  @ObservationIgnored private var workspaces: [ObjectIdentifier: WeakWorkspace] = [:]

  private struct WeakWorkspace {
    weak var workspace: Workspace?
    let window: WindowReference
  }

  /// What opening `url` means: the project folder, and the file to show in
  /// it (nil for a folder). Nil when `url` doesn't exist.
  static func target(of url: URL) -> (folder: URL, file: URL?)? {
    let url = url.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return nil
    }
    return isDirectory.boolValue ? (url, nil) : (url.deletingLastPathComponent(), url)
  }

  /// Opens a folder in its window, focusing the window when the folder is
  /// already open. A file opens its folder, then the file.
  func open(_ url: URL) {
    guard let (folder, file) = Self.target(of: url) else { return }
    if let file {
      if let workspace = workspace(for: folder) {
        workspace.tree.reveal(file)
        workspace.open(file)
      } else {
        pendingFiles[folder, default: []].append(file)
      }
    }
    recents.add(folder)
    // The registry decides whether the folder has a window: SwiftUI only
    // knows the folders windows were opened with, not the ones a Welcome
    // window adopted.
    if !focus(folder) { openWindow?(id: WorkspaceWindow.id, value: folder) }
  }

  /// Brings the window showing `folder` to the front. False when no window
  /// shows it.
  @discardableResult
  func focus(_ folder: URL) -> Bool {
    guard let entry = entry(for: folder) else { return false }
    entry.window.window?.makeKeyAndOrderFront(nil)
    return true
  }

  /// Shows an Open panel and opens the chosen folders and files, each in
  /// its project's window.
  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.prompt = "Open"
    panel.message = "Choose a folder to open as a project."
    guard panel.runModal() == .OK else { return }
    for url in panel.urls { open(url) }
  }

  func takePendingFiles(for folder: URL) -> [URL] {
    pendingFiles.removeValue(forKey: folder.standardizedFileURL) ?? []
  }

  func addPendingFile(_ file: URL, in folder: URL) {
    pendingFiles[folder.standardizedFileURL, default: []].append(file)
  }

  func register(_ workspace: Workspace, window: WindowReference) {
    workspaces = workspaces.filter { $0.value.workspace != nil }
    workspaces[ObjectIdentifier(workspace)] = WeakWorkspace(workspace: workspace, window: window)
  }

  func unregister(_ workspace: Workspace) {
    workspaces.removeValue(forKey: ObjectIdentifier(workspace))
  }

  func workspace(for folder: URL) -> Workspace? {
    entry(for: folder)?.workspace
  }

  private func entry(for folder: URL) -> WeakWorkspace? {
    let folder = folder.standardizedFileURL
    return workspaces.values.first { $0.workspace?.root == folder }
  }

  // MARK: - Reopening projects at launch

  private static let openProjectsKey = "openProjects"
  @ObservationIgnored private var hasRestoredProjects = false

  /// Remembers the open project folders at quit, so the next launch reopens
  /// them (as VS Code and Zed do) whatever the system's window restoration
  /// setting is.
  func saveOpenProjects() {
    let roots = workspaces.values.compactMap { $0.workspace?.root.path }
    UserDefaults.standard.set(roots, forKey: Self.openProjectsKey)
  }

  /// The folders to reopen, once per launch: the first window to appear
  /// takes them.
  func takeProjectsToRestore() -> [URL] {
    guard !hasRestoredProjects else { return [] }
    hasRestoredProjects = true
    let paths = UserDefaults.standard.stringArray(forKey: Self.openProjectsKey) ?? []
    return paths.map { URL(fileURLWithPath: $0) }.filter {
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
        && isDirectory.boolValue && workspace(for: $0) == nil
    }
  }

  /// Saves every open document and project session (quit, deactivation).
  func flushAll() {
    for case let workspace? in workspaces.values.map(\.workspace) {
      workspace.flushAll()
      workspace.saveSession()
    }
  }
}
