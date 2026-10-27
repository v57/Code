import CodeKit
import ComponentKit
import SwiftUI

/// App-wide state: recent projects and the open workspaces.
@MainActor @Observable final class AppState {
  static let shared = AppState()
  #if DEBUG
    /// The window the last debug automation command acts on.
    @ObservationIgnored weak var debugModel: WindowModel?
    /// Every window's model, for `window:<name>`.
    @ObservationIgnored var debugModels: [WeakWindowModel] = []
    @ObservationIgnored var debugOpenSettings: (() -> Void)?
  #endif

  let recents = RecentProjects(defaults: ScreenshotDemo.isOn ? ScreenshotDemo.defaults : .standard)
  /// Captured from the windows; opens project windows from menus outside a
  /// window's view tree (the Dock menu).
  @ObservationIgnored var openWindow: OpenWindowAction?
  /// The account the next new window shows (the account picker's Open in a New Window).
  @ObservationIgnored var pendingWindowAccount: String?
  /// Files to open once their folder's window is up, by folder.
  @ObservationIgnored private var pendingFiles: [URL: [URL]] = [:]
  @ObservationIgnored private var workspaces: [ObjectIdentifier: WeakWorkspace] = [:]
  /// The windows of documents opened in their own window, by document.
  @ObservationIgnored private var detachedWindows: [UUID: WindowReference] = [:]

  private struct WeakWorkspace {
    weak var model: WindowModel?
    let window: WindowReference
    var workspace: Workspace? { model?.workspace }
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
    entry.window.bringToFront()
    return true
  }

  /// Shows an Open panel and opens the chosen folders and files, each in
  /// its project's window.
  func chooseFolder() {
    #if os(macOS)
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = true
      panel.allowsMultipleSelection = true
      panel.prompt = "Open"
      panel.message = "Choose a folder to open as a project."
      guard panel.runModal() == .OK else { return }
      for url in panel.urls { open(url) }
    #else
      Task {
        let urls = await KitDesktop.chooseFolders(
          prompt: "Open", message: "Choose a folder to open as a project.", allowsMultipleSelection: true)
        for url in urls { open(url) }
      }
    #endif
  }

  func takePendingFiles(for folder: URL) -> [URL] {
    pendingFiles.removeValue(forKey: folder.standardizedFileURL) ?? []
  }

  func addPendingFile(_ file: URL, in folder: URL) {
    pendingFiles[folder.standardizedFileURL, default: []].append(file)
  }

  func register(_ model: WindowModel, window: WindowReference) {
    workspaces = workspaces.filter { $0.value.workspace != nil }
    workspaces[ObjectIdentifier(model.workspace)] = WeakWorkspace(model: model, window: window)
  }

  func unregister(_ workspace: Workspace) {
    workspaces.removeValue(forKey: ObjectIdentifier(workspace))
  }

  func workspace(for folder: URL) -> Workspace? {
    entry(for: folder)?.workspace
  }

  /// The model of the window showing `folder`.
  func model(for folder: URL) -> WindowModel? {
    entry(for: folder)?.model
  }

  /// Some window shows a project.
  var hasProjects: Bool { workspaces.values.contains { $0.workspace != nil } }

  /// The project window model whose workspace shows `document` in its own
  /// window.
  func model(detaching document: UUID) -> WindowModel? {
    workspaces.values.lazy.compactMap(\.model).first {
      $0.workspace.detachedDocuments.contains { $0.id == document }
    }
  }

  func registerDetachedWindow(_ window: WindowReference, for document: UUID) {
    detachedWindows[document] = window
  }

  func unregisterDetachedWindow(for document: UUID) {
    detachedWindows.removeValue(forKey: document)
  }

  /// Brings a document's own window to the front.
  func focusDetachedWindow(for document: UUID) {
    detachedWindows[document]?.bringToFront()
  }

  /// Closes the own windows of a closing project's documents.
  func closeDetachedWindows(of workspace: Workspace) {
    for document in workspace.detachedDocuments {
      detachedWindows[document.id]?.close()
    }
  }

  private func entry(for folder: URL) -> WeakWorkspace? {
    let folder = folder.standardizedFileURL
    return workspaces.values.first { $0.workspace?.root == folder }
  }

  /// Saves every open document and project session (quit, deactivation).
  func flushAll() {
    for case let workspace? in workspaces.values.map(\.workspace) {
      workspace.flushAll()
      workspace.saveSession()
    }
  }
}

#if DEBUG
  struct WeakWindowModel {
    weak var model: WindowModel?
  }
#endif
