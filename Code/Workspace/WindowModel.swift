import CodeKit
import SwiftUI

/// The state of one project window around its workspace: overlays, prompts,
/// the sidebar selection and the caret position for the status bar.
@MainActor @Observable final class WindowModel {
  enum Prompt: Identifiable {
    case newFile(in: URL)
    case newFolder(in: URL)
    case rename(URL)

    var id: String {
      switch self {
      case .newFile(let url): return "file:" + url.path
      case .newFolder(let url): return "folder:" + url.path
      case .rename(let url): return "rename:" + url.path
      }
    }
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
  /// The console under the editor (Xcode's debug area, ⇧⌘Y).
  var isConsoleVisible = false
  var isIssuesPresented = false
  @ObservationIgnored private var installObserver: NSObjectProtocol?
  var isGoToLinePresented = false
  var prompt: Prompt?
  /// The text field of the current prompt.
  var promptText = ""
  var trashCandidate: URL?
  var sidebarSelection: URL?
  /// The navigator (sidebar) column, toggled with ⌘0.
  var isNavigatorVisible = true
  /// What the navigator shows, as Xcode's navigator bar picks.
  enum Navigator: Hashable { case project, find }
  var navigator = Navigator.project
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
      // A failed build shows its log, as Xcode shows the issues.
      if !succeeded, kind != .run, self?.services.actions.issues.isEmpty == true {
        self?.isConsoleVisible = true
      }
    }
  }

  /// Runs an action; Run and Test show the console, as Xcode shows the debug
  /// area.
  func perform(_ kind: ActionKind) {
    guard services.settings.actionsEnabled else { return }
    if kind == .run || kind == .test { isConsoleVisible = true }
    services.actions.perform(kind)
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

  /// ⇧⌘F: the Find navigator with the caret in its field. A selection on
  /// one line becomes the query and is searched for.
  func findInProject() {
    isNavigatorVisible = true
    navigator = .find
    if let textView = workspace.selectedDocument?.textView, textView.window?.firstResponder === textView {
      let range = textView.selectedRange()
      let selected = (textView.string as NSString).substring(with: range)
      if range.length > 0, range.length < 500, !selected.contains("\n") {
        find.text = selected
        find.search(in: workspace)
      }
    }
    find.focus()
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
    switch prompt {
    case .rename(let url): promptText = url.lastPathComponent
    default: promptText = ""
    }
    self.prompt = prompt
  }

  /// Runs the current prompt with `promptText`.
  func commitPrompt() {
    guard let prompt else { return }
    self.prompt = nil
    let name = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    switch prompt {
    case .newFile(let folder):
      if let url = workspace.createFile(named: name, in: folder) { sidebarSelection = url }
    case .newFolder(let folder):
      if let url = workspace.createFolder(named: name, in: folder) { sidebarSelection = url }
    case .rename(let url):
      if let newURL = workspace.rename(url, to: name), sidebarSelection == url {
        sidebarSelection = newURL
      }
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
