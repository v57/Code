import CodeKit
import ComponentKit
import SwiftUI

/// The state of one project window around its workspace: overlays, prompts,
/// the sidebar selection and the caret position for the status bar.
@MainActor @Observable final class WindowModel {
  /// New File and New Folder: the name they ask for, in a folder.
  enum Prompt {
    case newFile(in: URL)
    case newFolder(in: URL)
  }

  let workspace: Workspace
  /// Schemes and actions, language servers, formatting, issues, breakpoints.
  let services: ProjectServices
  var isQuickOpenPresented = false
  /// Open Quickly's search text, cleared when it opens.
  var quickOpenQuery = ""
  /// Open Quickly also lists hidden files (its Hidden Files button, ⇧⌘.).
  var quickOpenIncludesHiddenFiles = UserDefaults.standard.bool(forKey: "quickOpen.includesHiddenFiles") {
    didSet { UserDefaults.standard.set(quickOpenIncludesHiddenFiles, forKey: "quickOpen.includesHiddenFiles") }
  }
  /// The navigator shows a checkbox per item to choose what the project hides.
  var isChoosingVisibleFiles = false
  /// The console, floating under the toolbar's title (⇧⌘Y, or a click on the title).
  var isConsoleVisible = false
  /// The console is in a window of its own (its Open in Window button) instead of under the title.
  private(set) var isConsoleDetached = false
  /// That window, while it is open.
  @ObservationIgnored private var consoleWindow: WindowReference?
  var isIssuesPresented = false
  /// The kit menu open in the window's chrome (the toolbar's scheme and destination, the project card's "…").
  var openMenu: ChromeMenu?
  /// The Notarization sheet: Export opens it until a profile is set up.
  var notarizationSetup: NotarizationSetupRequest?
  @ObservationIgnored private var installObserver: NSObjectProtocol?
  var isGoToLinePresented = false
  /// The last prompt asked, kept while its sheet closes.
  private(set) var prompt: Prompt?
  var isPromptPresented = false
  /// The text field of the current prompt.
  var promptText = ""
  /// The navigator row whose name is a field (Rename), and that field's text.
  var renaming: URL?
  var renameText = ""
  var trashCandidate: URL?
  /// Shows another project folder in this window (the sidebar's Projects card), or brings forward the window it is
  /// open in. Set by the window.
  @ObservationIgnored var switchProject: (URL) -> Void = { AppState.shared.open($0) }
  var sidebarSelection: URL?
  /// The navigator (sidebar) column, toggled with ⌘0.
  var isNavigatorVisible = true

  /// Shows or hides the navigator, sliding as the sidebar's own button does (a bare change snaps it).
  func setNavigatorVisible(_ isVisible: Bool) {
    guard isVisible != isNavigatorVisible else { return }
    withKitAnimation(.kitSlow) { isNavigatorVisible = isVisible }
  }
  /// What the navigator shows, as Xcode's navigator bar picks.
  enum Navigator: Hashable { case project, find }
  var navigator = Navigator.project
  /// The navigator's search line (Find in Project) is open: ⇧⌘F and ⌘3 open it.
  var isFindLineOpen = false
  /// Find in Project, shown in the Find navigator.
  let find = ProjectFind()
  /// Expanded packages and folders under Package Dependencies.
  var expandedDependencyFolders: Set<URL> = []

  func dependencyFolderExpansion(_ url: URL) -> Binding<Bool> {
    Binding(
      get: { self.expandedDependencyFolders.contains(url) },
      set: { expanded in
        if expanded {
          self.expandedDependencyFolders.insert(url)
        } else {
          self.expandedDependencyFolders.remove(url)
        }
      })
  }
  var selection = EditorSelection()

  init(workspace: Workspace) {
    self.workspace = workspace
    services = ProjectServices(workspace: workspace, settings: EditorSettings.storedServiceSettings)
    workspace.onOpenDetached = { AppState.shared.focusDetachedWindow(for: $0.id) }
    installObserver = NotificationCenter.default.addObserver(
      forName: .codeToolInstalled, object: nil, queue: .main
    ) { [weak self] note in
      guard let id = note.object as? String else { return }
      MainActor.assumeIsolated {
        self?.services.languageServers.retry(id)
        self?.services.reopenShownDocuments()
      }
    }
    services.actions.didFinish = { [weak self] kind, succeeded in
      // A failed action without issues to show shows its log instead.
      if !succeeded, kind != .run, self?.services.actions.issues.isEmpty == true {
        self?.showConsole()
      }
    }
  }

  // MARK: - Console

  /// The toolbar title's click and ⇧⌘Y: shows or hides the console under the title, or brings its own window
  /// forward.
  func toggleConsole() {
    if isConsoleDetached {
      consoleWindow?.bringToFront()
    } else {
      withKitAnimation(.kitFast) { isConsoleVisible.toggle() }
    }
  }

  /// Shows the console under the title, unless it has a window of its own.
  func showConsole() {
    guard !isConsoleDetached, !isConsoleVisible else { return }
    withKitAnimation(.kitFast) { isConsoleVisible = true }
  }

  func hideConsole() {
    withKitAnimation(.kitFast) { isConsoleVisible = false }
  }

  /// Moves the console into a window of its own (`ConsoleWindow`).
  func detachConsole() {
    isConsoleVisible = false
    if isConsoleDetached {
      consoleWindow?.bringToFront()
    } else {
      AppState.shared.openWindow?(id: ConsoleWindow.id, value: workspace.root)
    }
  }

  /// Puts the console back under the title, closing its window.
  func attachConsole() {
    consoleWindow?.close()
    showConsole()
  }

  func consoleWindowDidOpen(_ window: WindowReference) {
    consoleWindow = window
    isConsoleDetached = true
  }

  func consoleWindowDidClose() {
    consoleWindow = nil
    isConsoleDetached = false
  }

  func closeConsoleWindow() {
    consoleWindow?.close()
  }

  /// Runs an action. The console stays shut while it builds: it opens once a Run's program starts (see
  /// `WorkspaceView`), or when an action fails without issues to list. Export first asks for a notary profile when
  /// none is set up.
  func perform(_ kind: ActionKind) {
    guard services.settings.actionsEnabled else { return }
    var environment: [String: String] = [:]
    if kind.needsNotarization {
      guard let profile = NotarySettings.profile else {
        notarizationSetup = NotarizationSetupRequest(exportsWhenDone: true)
        return
      }
      environment["NOTARY_PROFILE"] = profile
    }
    services.actions.perform(kind, environment: environment)
  }

  /// Open in New Window: shows a file in a window of its own with only its
  /// editor, as Shell detaches a session. It leaves the tabs until that
  /// window closes.
  func openInNewWindow(_ url: URL) {
    let selected = workspace.selectedTabID
    let document = workspace.open(url)
    openInNewWindow(document)
    // Opening it selected its tab for a moment; keep the tab that was.
    if let selected, workspace.tabs.contains(where: { $0.id == selected }) {
      workspace.selectedTabID = selected
    }
  }

  func openInNewWindow(_ document: TextDocument) {
    // Already in its own window: `open` brought that forward.
    guard workspace.tabs.contains(where: { $0.id == document.id }) else { return }
    workspace.detach(document)
    AppState.shared.openWindow?(id: DetachedEditorWindow.id, value: document.id)
  }

  /// ⇧⌘., as in Finder: in Open Quickly, includes or leaves out hidden
  /// files; elsewhere, shows or hides them in the navigator.
  func toggleHiddenFiles() {
    if isQuickOpenPresented {
      quickOpenIncludesHiddenFiles.toggle()
    } else {
      workspace.visibility.showsHiddenFiles.toggle()
    }
  }

  /// ⇧⌘F: the Find navigator. A selection on one line becomes the query
  /// and is searched for.
  func findInProject() {
    setNavigatorVisible(true)
    navigator = .find
    isFindLineOpen = true
    if let textView = workspace.selectedDocument?.textView, textView.isFocused {
      let range = textView.selectionRange
      let selected = (textView.string as NSString).substring(with: range)
      if range.length > 0, range.length < 500, !selected.contains("\n") {
        find.text = selected
        find.search(in: workspace)
      }
    }
  }

  /// The folder new items go into: the selected folder, the selected file's
  /// folder, or the project root.
  var targetFolder: URL {
    guard let selected = sidebarSelection ?? workspace.selectedDocument?.url else {
      return workspace.root
    }
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory)
    return isDirectory.boolValue ? selected : selected.deletingLastPathComponent()
  }

  func ask(_ prompt: Prompt) {
    promptText = ""
    self.prompt = prompt
    isPromptPresented = true
  }

  /// Runs the current prompt with `name`.
  func commitPrompt(_ name: String) {
    guard let prompt, !name.isEmpty else { return }
    switch prompt {
    case .newFile(let folder):
      if let url = workspace.createFile(named: name, in: folder) { sidebarSelection = url }
    case .newFolder(let folder):
      if let url = workspace.createFolder(named: name, in: folder) { sidebarSelection = url }
    }
  }

  /// Turns the navigator row of `url` into a field holding its name (with its extension).
  func rename(_ url: URL) {
    renameText = url.lastPathComponent
    renaming = url
  }

  /// Renames `url` to what its row's field holds.
  func commitRename(_ url: URL) {
    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != url.lastPathComponent else { return }
    if let newURL = workspace.rename(url, to: name), sidebarSelection == url {
      sidebarSelection = newURL
    }
  }

  func confirmTrash() {
    guard let url = trashCandidate else { return }
    trashCandidate = nil
    workspace.trash(url)
    if sidebarSelection == url { sidebarSelection = nil }
  }
}

extension FocusedValues {
  @Entry var windowModel: WindowModel?
  /// The document of a key window of its own (Open in New Window).
  @Entry var detachedDocument: TextDocument?
}

/// The menus of a project window's chrome that open from a button.
enum ChromeMenu: String {
  case project
  case scheme
  case destination
}

extension WindowModel {
  /// Whether `menu` is the open one, for `.kitMenu(isPresented:)`.
  func isPresented(_ menu: ChromeMenu) -> Binding<Bool> {
    Binding(
      get: { self.openMenu == menu },
      set: { isOpen in
        if isOpen { self.openMenu = menu } else if self.openMenu == menu { self.openMenu = nil }
      })
  }
}
