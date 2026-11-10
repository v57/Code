import CodeKit
import ComponentKit
import SwiftUI

/// What the navigator selects: a file or folder of the tree (or of a package), or a Find in Project result.
nonisolated enum NavigatorItem: Hashable, Sendable {
  case file(URL)
  case match(FindSelection)
}

/// The navigator: the kit's compact sidebar. The projects the v57 apps share lead in a card that stays closed until
/// it's wanted; the project's file tree is a card whose header names the project (the kit's outline); a click opens a file in the preview tab, a double click (or Return) keeps it open, the kit's arrow
/// keys move and fold. The bottom bar's search button opens the search line (⇧⌘F, ⌘3), which searches the project
/// (Find in Project): while it has text, the sidebar lists the results instead of the tree.
///
/// Hidden files (`.gitignore` matches, `.git`, items the user hid) are left out unless Show Hidden Files (⇧⌘.) is on,
/// which lists them dimmed. Choose Visible Files puts a checkbox on every item to change what the project hides.
struct SidebarView: View {
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace
  @State private var isRootExpanded = true
  @State private var findSelection: FindSelection?
  /// Read here once for every row: an `@AppStorage` in each row never compares equal, so every row was built again
  /// each time the tree was.
  @KitStorage(EditorSettings.showExtensions) private var showExtensions = false

  var body: some View {
    NavigatorSidebar(findSelection: $findSelection) {
      switch model.navigator {
      case .project: projectContent
      case .find: FindNavigatorView(selection: $findSelection)
      }
    } bottomBar: {
      Button("Open Folder…", systemImage: "folder") { AppState.shared.chooseFolder() }
        .kitHelp("Open Folder…", shortcut: "⇧⌘O")
      Button(
        workspace.visibility.showsHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files",
        systemImage: workspace.visibility.showsHiddenFiles ? "eye.slash" : "eye"
      ) { workspace.visibility.showsHiddenFiles.toggle() }
      .kitHelp(workspace.visibility.showsHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files", shortcut: "⇧⌘.")
    }
    .background { SidebarSelectionFollower() }
    .onDeleteCommand {
      // Only the project's own files: not a package's.
      if let url = model.sidebarSelection, url != workspace.root, workspace.tree.node(for: url) != nil {
        model.trashCandidate = url
      }
    }
    .environment(\.showsFileExtensions, showExtensions)
    .dropDestination(for: URL.self) { urls, _ in
      // A folder dropped from Finder opens as a project.
      for url in urls where url.isFileURL && !url.path.hasPrefix(workspace.root.path + "/") {
        AppState.shared.open(url)
      }
      return true
    }
  }

  // MARK: - Project

  @ViewBuilder private var projectContent: some View {
    if model.isChoosingVisibleFiles {
      ChooseVisibleFilesCard()
      treeSection
    } else {
      // The shared projects list, the open project's tree in its section (folded away until it's wanted); a folder
      // that isn't a vault project keeps its own section under the list.
      ProjectsSection(meta: projectMeta) {
        fileTree
      } accessory: {
        projectMenuButton
      } fallback: {
        treeSection
      }
      PackageDependenciesSection()
    }
  }

  /// The project's tree on a card of its own, named after the project: a folder outside the vault's projects, or
  /// while choosing visible files.
  private var treeSection: some View {
    KitSection(
      workspace.name, meta: projectMeta, systemImage: "folder", hue: .red, isExpanded: $isRootExpanded
    ) {
      fileTree
    } accessory: {
      projectMenuButton
    }
    // A long tree keeps the project's title in view while its rows scroll past.
    .kitSticky()
  }

  private var fileTree: some View {
    FileTreeOutline(isRootExpanded: isRootExpanded)
  }

  private var projectMenuButton: some View {
    Button("Project", systemImage: "ellipsis") { model.openMenu = .project }
      .labelStyle(.iconOnly)
      .buttonStyle(.kitIcon)
      .controlSize(.small)
      .kitMenu(isPresented: model.isPresented(.project)) { FileMenu(url: nil) }
      .kitHelp("Project")
  }

  /// "Swift package · ~/Developer": the project's kind (from its scheme) and where it is.
  private var projectMeta: [String] {
    let kind = model.services.actions.selectedScheme?.toolchain.displayName
    return [kind, workspace.root.deletingLastPathComponent().abbreviatedPath].compactMap { $0 }
  }
}

/// The kit's sidebar around the navigator's content, with the bindings it takes. A view of its own: making a
/// `Binding(get:set:)` reads its value at once, so in `SidebarView`'s body the selection's made that body (and the
/// tree's sections, given new closures) run again on every tab switch. Here the content comes in built, and stays the
/// same value when only the selection changes.
private struct NavigatorSidebar<Content: View, BottomBar: View>: View {
  @Binding var findSelection: FindSelection?
  let content: Content
  let bottomBar: BottomBar
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace

  init(
    findSelection: Binding<FindSelection?>, @ViewBuilder content: () -> Content,
    @ViewBuilder bottomBar: () -> BottomBar
  ) {
    _findSelection = findSelection
    self.content = content()
    self.bottomBar = bottomBar()
  }

  var body: some View {
    @Bindable var find = model.find
    @Bindable var model = model
    KitSidebar(
      selection: selection, searchText: $find.text, searchPrompt: "Find in Project",
      isSearching: $model.isFindLineOpen, columnVisibility: navigatorVisibility
    ) {
      content
    } bottomBar: {
      bottomBar
    }
    .onReturn(activateSelection)
    // The selection stays in view when a tab, Quick Open or Finder changes it (no `ScrollViewReader` here: it built
    // the whole tree again whenever the rows it could scroll to changed, on every tab switch).
    .revealsSelection()
    .kitRowDensity(.compact)
    .onChange(of: find.text) { _, text in
      // Typing in the search line searches the project; closing it goes back to the tree.
      model.navigator = text.isEmpty ? .project : .find
      if text.isEmpty { findSelection = nil }
    }
    .onChange(of: model.isFindLineOpen) { _, isOpen in
      // ⇧⌘F and ⌘3 open the line on the Find navigator; closing it goes back to the tree.
      if isOpen { model.navigator = .find } else if find.text.isEmpty { model.navigator = .project }
    }
    .task(id: find.text) {
      guard !find.text.isEmpty else {
        find.clear()
        return
      }
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      find.search(in: workspace)
    }
  }

  private var selection: Binding<NavigatorItem?> {
    Binding(
      get: {
        switch model.navigator {
        case .project: model.sidebarSelection.map(NavigatorItem.file)
        case .find: findSelection.map(NavigatorItem.match)
        }
      },
      set: { item in
        switch item {
        case .file(let url)?: model.sidebarSelection = url
        case .match(let match)?: findSelection = match
        case nil: break
        }
      })
  }

  private var navigatorVisibility: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: { model.isNavigatorVisible ? .all : .detailOnly },
      set: { model.isNavigatorVisible = $0 != .detailOnly })
  }

  /// Return keeps the selected file open or folds and unfolds the selected folder (the kit's arrow keys move and fold).
  private func activateSelection() {
    guard model.navigator == .project, let url = model.sidebarSelection else { return }
    model.activateNavigatorItem(url)
  }
}

/// Opens a file selected in the navigator in the preview tab. A view of its own, so a new selection updates only it:
/// read in the sidebar's body (or a modifier on it) it built the whole tree again on every tab switch.
private struct SidebarSelectionFollower: View {
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace

  var body: some View {
    Color.clear
      .onChange(of: model.sidebarSelection) { _, url in
        guard let url, model.isFile(url) else { return }
        workspace.open(url, preview: true)
      }
  }
}

/// The project's files as the kit's outline. A view of its own, so the sidebar's body running again (a new selection)
/// doesn't make new items: the outline compared them unequal (they hold a closure) and built every row again.
private struct FileTreeOutline: View {
  let isRootExpanded: Bool
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace

  var body: some View {
    KitOutline(treeItems, children: \.children, expanded: expandedFolders) { item in
      FileTreeRow(node: item.node)
    }
  }

  /// The project's top level, for the kit's outline (folders open from `workspace.tree.expanded`).
  private var treeItems: [TreeItem] {
    guard isRootExpanded else { return [] }
    let children = { (node: FileNode) in SidebarView.visibleChildren(of: node, workspace: workspace, model: model) }
    return children(workspace.tree.root).map { TreeItem(node: $0, visibleChildren: children) }
  }

  /// The open folders: opening one reads it first; the session keeps them.
  private var expandedFolders: Binding<Set<URL>> {
    Binding(
      get: { workspace.tree.expanded },
      set: { expanded in
        let tree = workspace.tree
        for url in expanded.subtracting(tree.expanded) {
          if let node = tree.node(for: url) { tree.setExpanded(node, true) }
        }
        for url in tree.expanded.subtracting(expanded) {
          if let node = tree.node(for: url) { tree.setExpanded(node, false) }
        }
        workspace.saveSession()
      })
  }
}

/// A file or folder of the tree as the kit's outline sees it: a folder's children are the ones the navigator shows
/// (none until it's read), a file has none.
struct TreeItem: Identifiable {
  let node: FileNode
  let visibleChildren: (FileNode) -> [FileNode]
  var id: URL { node.url }

  var children: [TreeItem]? {
    guard node.isDirectory else { return nil }
    return visibleChildren(node).map { TreeItem(node: $0, visibleChildren: visibleChildren) }
  }
}

extension SidebarView {
  /// `node`'s children, without hidden ones unless the navigator shows them or the user is choosing what to show.
  static func visibleChildren(of node: FileNode, workspace: Workspace, model: WindowModel) -> [FileNode] {
    let children = node.children ?? []
    if workspace.visibility.showsHiddenFiles || model.isChoosingVisibleFiles { return children }
    return children.filter { !$0.isHidden }
  }
}

extension WindowModel {
  /// A file in the tree, or in a package under Package Dependencies.
  func isFile(_ url: URL) -> Bool {
    if let node = workspace.tree.node(for: url) { return !node.isDirectory }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
  }

  /// Double click or Return: keep a file open, fold or unfold a folder.
  func activateNavigatorItem(_ url: URL) {
    guard let node = workspace.tree.node(for: url) else {
      // A package's file or folder.
      if isFile(url) {
        workspace.open(url, preview: false)
      } else {
        dependencyFolderExpansion(url).wrappedValue.toggle()
      }
      return
    }
    if node.isDirectory {
      withKitAnimation { workspace.tree.setExpanded(node, !workspace.tree.expanded.contains(url)) }
      workspace.saveSession()
    } else {
      workspace.open(url, preview: false)
    }
  }
}

// MARK: - Rows

/// A file or folder of the tree: its icon and name (the outline adds the disclosure and indent), dimmed while hidden;
/// a checkbox while choosing visible files.
struct FileTreeRow: View {
  let node: FileNode
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  @Environment(\.showsFileExtensions) private var showExtensions

  var body: some View {
    @Bindable var model = model
    let isHidden = node.isHidden
    SidebarRow(value: NavigatorItem.file(node.url), FileName.display(node.url, showExtensions: showExtensions)) {
      HStack(spacing: 2) {
        if model.isChoosingVisibleFiles {
          Toggle("Show \(node.name)", isOn: isVisible)
            .toggleStyle(.kitCheckbox)
            .kitLabelsHidden()
            .disabled(node.isInHiddenFolder)
        }
        FileIconView(for: node.url, isDirectory: node.isDirectory, size: 14)
          .opacity(isHidden ? 0.45 : 1)
      }
    } trailing: {
      if model.isChoosingVisibleFiles {
        if case .gitIgnore(let line) = workspace.tree.ruleReason(for: node) {
          Chip(".gitignore")
            .controlSize(.small)
            .kitHelp("Matches .gitignore", meta: line)
        }
      } else if let reason = node.hiddenReason {
        Image(systemName: "eye.slash")
          .kitFont(.caption)
          .imageScale(.small)
          .kitHelp("Hidden", meta: reason.description)
          .accessibilityLabel("Hidden")
      }
    }
    .onDoubleClick { model.activateNavigatorItem(node.url) }
    .opacity(isHidden ? 0.6 : 1)
    .id(node.url)
    .kitHelp(help)
    .kitRename(isRenaming: isRenaming, text: $model.renameText) { model.commitRename(node.url) }
    .kitContextMenu { FileMenu(url: node.url) }
    .draggable(node.url)
  }

  private var help: String {
    let path = workspace.tree.relativePath(of: node.url)
    if let reason = node.hiddenReason { return path + " — " + reason.description }
    if node.isInHiddenFolder { return String(localized: "\(path) — In a hidden folder") }
    return path
  }

  private var isRenaming: Binding<Bool> {
    Binding(
      get: { model.renaming == node.url },
      set: { if !$0, model.renaming == node.url { model.renaming = nil } })
  }

  private var isVisible: Binding<Bool> {
    Binding(
      get: { !node.isHidden },
      set: { workspace.setVisible(node.url, $0) })
  }
}

/// A file's, folder's or the project's menu, drawn by the kit (the row's context menu, the project card's "…").
struct FileMenu: View {
  /// nil: the project itself.
  let url: URL?
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model

  var body: some View {
    let node = url.flatMap { workspace.tree.node(for: $0) }
    if let url, node == nil, url != workspace.root {
      dependencyMenu(for: url)
    } else {
      projectMenu(node: url == workspace.root ? nil : node)
    }
  }

  /// A package's file or folder: open, reveal and copy, nothing that changes it.
  @ViewBuilder private func dependencyMenu(for url: URL) -> some View {
    let isFile = model.isFile(url)
    if isFile {
      Button("Open in New Tab") { workspace.open(url) }
        .kitMenuPreview("Opens \(url.lastPathComponent) in a tab that stays.")
      Button("Open in New Window") { model.openInNewWindow(url) }
        .kitMenuPreview("Opens \(url.lastPathComponent) in a window of its own.")
    }
    KitOpenWithRow(OpenWithApps.item(url, project: nil, defaultApp: isFile))
    Divider()
    Button("Copy Path") { copy(url.path) }
      .kitMenuPreview(url.path)
    Divider()
    Button("Refresh Package Dependencies") { workspace.reloadDependencies() }
      .kitMenuPreview("Reads the project’s package dependencies again.")
  }

  @ViewBuilder private func projectMenu(node: FileNode?) -> some View {
    let folder = node.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() } ?? workspace.root
    let container = model.services.actions.selectedContainer
    let place = folder == workspace.root ? workspace.name : workspace.tree.relativePath(of: folder)
    Button("New File…") { model.ask(.newFile(in: folder)) }
      .kitMenuPreview("Asks for a name, then makes an empty file in \(place).")
    Button("New Folder…") { model.ask(.newFolder(in: folder)) }
      .kitMenuPreview("Asks for a name, then makes a folder in \(place).")
    if let node {
      Divider()
      if !node.isDirectory {
        Button("Open in New Tab") { workspace.open(node.url) }
          .kitMenuPreview("Opens \(node.name) in a tab that stays.")
        Button("Open in New Window") { model.openInNewWindow(node.url) }
          .kitMenuPreview("Opens \(node.name) in a window of its own.")
      }
      KitOpenWithRow(
        OpenWithApps.item(node.url, project: workspace.root, container: container, defaultApp: !node.isDirectory))
      Divider()
      Button("Copy Path") { copy(node.url.path) }
        .kitMenuPreview(node.url.path)
      Button("Copy Relative Path") { copy(workspace.tree.relativePath(of: node.url)) }
        .kitMenuPreview(workspace.tree.relativePath(of: node.url))
      Divider()
      Button("Rename") { model.rename(node.url) }
        .kitMenuPreview("Edits \(node.name)’s name in the list. Open tabs follow it.")
      Button("Move to Trash", role: .destructive) { model.trashCandidate = node.url }
        .kitMenuPreview("Asks, then moves \(node.name) to the Trash. You can put it back from there.")
      Divider()
      if !node.isInHiddenFolder {
        if node.hiddenReason != nil {
          Button("Show in List") { workspace.setVisible(node.url, true) }
            .kitMenuPreview("Shows \(node.name) in the navigator and Open Quickly again.")
        } else {
          Button("Hide from List") { workspace.setVisible(node.url, false) }
            .kitMenuPreview(
              "Keeps \(node.name) out of the navigator and Open Quickly in this project. It stays on disk.")
        }
        if !isGitIgnored(node) {
          Button("Add to .gitignore") { workspace.addToGitIgnore(node.url) }
            .kitMenuPreview(
              "Adds /\(workspace.tree.relativePath(of: node.url))\(node.isDirectory ? "/" : "") to the project’s .gitignore, which hides it.")
        }
      }
      editHiddenFilesButton
    } else {
      Divider()
      KitOpenWithRow(OpenWithApps.project(workspace.root, container: container))
      Button("Copy Path") { copy(workspace.root.path) }
        .kitMenuPreview(workspace.root.path)
      Button("Reload") { workspace.tree.reloadAll() }
        .kitMenuPreview("Reads \(workspace.name)’s files from disk again.")
      Divider()
      editHiddenFilesButton
    }
  }

  /// Puts a checkbox on every item to choose what the project hides.
  @ViewBuilder private var editHiddenFilesButton: some View {
    if !model.isChoosingVisibleFiles {
      Button("Edit Hidden Files") { model.isChoosingVisibleFiles = true }
        .kitMenuPreview("Puts a checkbox on every file and folder to choose what this project hides.")
    }
  }

  private func isGitIgnored(_ node: FileNode) -> Bool {
    if case .gitIgnore = workspace.tree.ruleReason(for: node) { return true }
    return false
  }

  private func copy(_ string: String) { KitPasteboard.copy(string) }
}

/// Above the tree while choosing visible files: what the checkboxes do, the project's `.gitignore` switch, Restore
/// Defaults and Done.
private struct ChooseVisibleFilesCard: View {
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      RichHeader(
        "Hidden Files", meta: "Uncheck what this project shouldn’t show", systemImage: "eye.slash", hue: .gray)
      Text("Hidden files stay out of the navigator and Open Quickly.")
        .kitFont(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
      Toggle("Hide files listed in .gitignore", isOn: hidesIgnoredFiles)
        .toggleStyle(.kitCheckbox)
        .padding(.horizontal, 6)
      HStack(spacing: 6) {
        Spacer(minLength: 0)
        Button("Restore Defaults") { workspace.restoreDefaultVisibility() }
          .buttonStyle(.kit)
          .disabled(workspace.visibility.isDefault)
        Button("Done") { model.isChoosingVisibleFiles = false }
          .buttonStyle(.kitPrimary)
      }
      .controlSize(.small)
    }
    .kitCard()
  }

  /// The project's choice; following the app's setting until changed.
  private var hidesIgnoredFiles: Binding<Bool> {
    Binding(
      get: { workspace.tree.hidesIgnoredFiles },
      set: { workspace.visibility.hidesIgnoredFiles = $0 })
  }
}
