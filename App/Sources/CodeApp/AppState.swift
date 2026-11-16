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
    /// The toasts the debug automation's quick actions showed.
    @ObservationIgnored var debugToasts: [String] = []
    /// The projects kept without a window, for `dump`.
    var debugBackgroundSummary: String {
      func list(_ models: [URL: WindowModel]) -> String {
        models.values.map { model in
          "\(model.workspace.name) [" + model.services.actions.runs.map { "\($0.title) \($0.phase)" }.joined(separator: "; ") + "]"
        }.joined(separator: ", ")
      }
      return "running \(list(backgroundProjects)) loading \(list(loadingProjects)) failed \(list(failedProjects))"
    }
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
  /// The first window's launch project was decided.
  @ObservationIgnored private var hasOpenedLaunchProject = false
  /// A folder or file was opened from outside (Finder, the Dock, the command line): it wins over the last project.
  @ObservationIgnored var didOpenFolder = false
  /// Projects no window shows that still run something, by folder.
  private var backgroundProjects: [URL: WindowModel] = [:]
  /// Projects no window shows whose last action failed, kept for its log until shown or dismissed, by folder.
  private var failedProjects: [URL: WindowModel] = [:]
  /// What each of those failed with.
  @ObservationIgnored private var failures: [URL: String] = [:]
  /// Projects no window shows that read their schemes for a quick action of the Projects list, by folder.
  private var loadingProjects: [URL: WindowModel] = [:]
  /// The quick actions waiting for those projects, in the order they were picked.
  @ObservationIgnored private var queuedActions: [URL: [ProjectQuickAction]] = [:]
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

  /// The project the first window opens at launch: the last one opened that still exists, unless the app was launched
  /// to open something else (`didOpenFolder`) or this has been asked before. Nil shows the Welcome window.
  func takeLaunchProject() -> URL? {
    defer { hasOpenedLaunchProject = true }
    guard !hasOpenedLaunchProject, !didOpenFolder, !ScreenshotDemo.isOn else { return nil }
    return recents.existing.first
  }

  /// Opens a folder in its window, focusing the window when the folder is
  /// already open. A file opens its folder, then the file.
  func open(_ url: URL) {
    guard let (folder, file) = Self.target(of: url) else { return }
    didOpenFolder = true
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
    if !focus(folder) {
      ProjectsList.fold()
      openWindow?(id: WorkspaceWindow.id, value: folder)
    }
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
    Task {
      #if os(macOS)
        let urls = await KitDesktop.chooseFiles(
          prompt: String(localized: "Open"), message: String(localized: "Choose a folder to open as a project."),
          canChooseFolders: true,
          allowsMultipleSelection: true)
      #else
        // Off the Mac it asks for folders only.
        let urls = await KitDesktop.chooseFolders(
          prompt: String(localized: "Open"), message: String(localized: "Choose a folder to open as a project."),
          allowsMultipleSelection: true)
      #endif
      for url in urls { open(url) }
    }
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

  // MARK: - Projects running in the background

  /// Keeps a project alive after its window switched to another one while an action runs: its process, log and
  /// language servers go on until the action ends or a window shows the project again (`takeBackgroundProject`).
  func keepInBackground(_ model: WindowModel) {
    model.isInBackground = true
    backgroundProjects[model.workspace.root] = model
  }

  /// A kept project (running, or its last action failed), for the window about to show its folder.
  func takeBackgroundProject(_ folder: URL) -> WindowModel? {
    let folder = folder.standardizedFileURL
    let failed = failedProjects.removeValue(forKey: folder)
    // Its language servers stopped while it waited: the files it shows open in them again.
    failed?.services.reopenShownDocuments()
    let model = backgroundProjects.removeValue(forKey: folder) ?? failed
    model?.isInBackground = false
    model?.keepsRunsInBackground = false
    model?.sheetHost = nil
    return model
  }

  /// The kept project's actions ended with no window showing it: nothing is left to keep it for, unless the last one
  /// failed, whose log waits for the project to be shown (the Projects list marks it).
  func backgroundProjectFinished(_ model: WindowModel) {
    let root = model.workspace.root
    backgroundProjects.removeValue(forKey: root)
    model.isInBackground = false
    if let failure = Self.failure(of: model) {
      model.services.languageServers.stopAll()
      failedProjects[root] = model
      failures[root] = failure
    } else {
      model.services.shutDown()
    }
  }

  /// What the newest finished run of `model` failed with, nil when it succeeded or was stopped.
  private static func failure(of model: WindowModel) -> String? {
    let run = model.services.actions.runs.filter { $0.finished != nil }.max { $0.finished! < $1.finished! }
    guard let run, case .failed(let summary) = run.phase else { return nil }
    return "\(run.kind.title) \(run.scheme.name) failed: \(summary)"
  }

  /// Whether `folder` runs something with no window showing it, or loads to run it (the Projects card marks it).
  func isRunningInBackground(_ folder: URL) -> Bool {
    let folder = folder.standardizedFileURL
    return backgroundProjects[folder] != nil || loadingProjects[folder] != nil
  }

  /// Why the action `folder` ran with no window showing it failed, until the project is shown.
  func backgroundFailure(_ folder: URL) -> String? {
    let folder = folder.standardizedFileURL
    return failedProjects[folder] == nil ? nil : failures[folder]
  }

  /// Forgets a background action's failure (the Projects list's Dismiss).
  func dismissBackgroundFailure(_ folder: URL) {
    failedProjects.removeValue(forKey: folder.standardizedFileURL)?.services.shutDown()
  }

  /// Stops what `folder` runs in the background (the Projects card's menu); its project then leaves.
  func stopBackgroundProject(_ folder: URL) {
    let folder = folder.standardizedFileURL
    loadingProjects.removeValue(forKey: folder)?.services.shutDown()
    queuedActions.removeValue(forKey: folder)
    backgroundProjects[folder]?.services.actions.stopAll()
  }

  /// Quitting: nothing outlives the app.
  func stopBackgroundProjects() {
    for model in backgroundProjects.values { model.services.shutDown() }
    for model in loadingProjects.values { model.services.shutDown() }
    for model in failedProjects.values { model.services.shutDown() }
    backgroundProjects = [:]
    loadingProjects = [:]
    failedProjects = [:]
  }

  // MARK: - Quick actions of the Projects list

  /// The model that runs `folder`'s actions now without loading it: its window's, else the background one.
  func liveModel(for folder: URL) -> WindowModel? {
    let folder = folder.standardizedFileURL
    return model(for: folder) ?? backgroundProjects[folder]
  }

  /// Runs a quick action of the Projects list's menu on `folder`, named `name`, from the window `host`: in the window
  /// that shows the project, else in the background as a project switched away from (its row shows it running, its
  /// menu stops it), after reading its schemes and devices as a window would. Upload's build number and Export's
  /// notarization ask in the window showing it, else in `host`. One that can't run says why through `toast`.
  func perform(
    _ action: ProjectQuickAction, in folder: URL, name: String, host: WindowModel, say toast: @escaping (String) -> Void
  ) {
    let folder = folder.standardizedFileURL
    dismissBackgroundFailure(folder)
    if let shown = model(for: folder) {
      perform(action, on: shown, name: name, toast: toast)
      if shown.appStoreUpload != nil || shown.notarizationSetup != nil { focus(folder) }
      return
    }
    if let kept = backgroundProjects[folder] {
      kept.sheetHost = host
      perform(action, on: kept, name: name, toast: toast)
      return
    }
    // Picked again while it loads: it runs once the project has read its schemes, after the first.
    if loadingProjects[folder] != nil {
      queuedActions[folder, default: []].append(action)
      return
    }
    let model = WindowModel(
      workspace: Workspace(
        root: folder, hidesIgnoredFiles: EditorSettings.storedHidesIgnoredFiles,
        defaults: ScreenshotDemo.isOn ? ScreenshotDemo.defaults : .standard))
    model.keepsRunsInBackground = true
    model.sheetHost = host
    loadingProjects[folder] = model
    queuedActions[folder] = [action]
    Task {
      await Self.waitForSchemes(of: model)
      // Stopped while loading (a new load may have started since), or a window showed the project meanwhile (it
      // runs there).
      guard loadingProjects[folder] === model else { return }
      loadingProjects.removeValue(forKey: folder)
      let queued = queuedActions.removeValue(forKey: folder) ?? []
      let target = self.model(for: folder) ?? model
      for action in queued { perform(action, on: target, name: name, toast: toast) }
      // Nothing started: it couldn't, or a sheet asks first (the sheet's request keeps the project until then).
      let asks = [host.appStoreUpload?.target, host.notarizationSetup?.target].contains { $0 === model }
      if target !== model || (!model.isInBackground && !asks) { model.services.shutDown() }
    }
  }

  private func perform(_ action: ProjectQuickAction, on model: WindowModel, name: String, toast: (String) -> Void) {
    let actions = model.services.actions
    guard model.services.settings.actionsEnabled else {
      toast(String(localized: "Actions are off in Settings."))
      return
    }
    switch action {
    case .action(let kind):
      if let reason = Self.reason(kind, cannotRunIn: actions, name: name) {
        toast(reason)
        return
      }
      model.perform(kind)
    case .preset(let item):
      model.run(item)
    }
  }

  /// Why `kind` can't run with the project's toolbar choices; nil when it can.
  private static func reason(_ kind: ActionKind, cannotRunIn actions: ActionController, name: String) -> String? {
    guard !actions.canPerform(kind) else { return nil }
    guard let scheme = actions.selectedScheme else { return "\(name) has no scheme Code can run." }
    guard scheme.supports(kind) else {
      switch kind {
      case .run: return "\(scheme.name) has nothing to run."
      case .install, .export: return "\(scheme.name) isn’t a Mac app."
      case .upload: return "\(scheme.name) isn’t an app for the App Store."
      default: return "\(scheme.name) can’t \(kind.title.lowercased())."
      }
    }
    return "\(name) builds on \(actions.selectedBuildSource.name): \(kind.title) runs from this Mac."
  }

  /// Waits until a project loaded without a window has read its schemes and devices (at most a minute).
  private static func waitForSchemes(of model: WindowModel) async {
    let services = model.services
    let deadline = Date.now.addingTimeInterval(60)
    while Date.now < deadline {
      if services.isReady, !services.actions.isScanning, !services.actions.isLoadingDestinations { return }
      try? await Task.sleep(for: .milliseconds(100))
    }
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
