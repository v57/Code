import CodeKit
import ComponentKit
import SwiftUI

/// What the navigator selects: a file or folder of the tree (or of a package), or a Find in Project result.
nonisolated enum NavigatorItem: Hashable, Sendable {
  case file(URL)
  case match(FindSelection)
}

/// The navigator: the kit's compact sidebar. The project's file tree is a card whose header names the project (the
/// kit's outline); a click opens a file in the preview tab, a double click (or Return) keeps it open, the kit's arrow
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

  var body: some View {
    @Bindable var find = model.find
    @Bindable var model = model
    ScrollViewReader { proxy in
      KitSidebar(
        selection: selection, searchText: $find.text, searchPrompt: "Find in Project",
        isSearching: $model.isFindLineOpen, columnVisibility: navigatorVisibility
      ) {
        switch model.navigator {
        case .project: projectContent
        case .find: FindNavigatorView(selection: $findSelection)
        }
      } bottomBar: {
        Button("Open Folder…", systemImage: "folder") { AppState.shared.chooseFolder() }
          .help("Open Folder… (⌘O)")
        Button(
          workspace.visibility.showsHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files",
          systemImage: workspace.visibility.showsHiddenFiles ? "eye.slash" : "eye"
        ) { workspace.visibility.showsHiddenFiles.toggle() }
        .help(workspace.visibility.showsHiddenFiles ? "Hide Hidden Files (⇧⌘.)" : "Show Hidden Files (⇧⌘.)")
      }
      .onReturn(activateSelection)
      .kitRowDensity(.compact)
      // Keep the selected file in view when it changes from outside the sidebar (a tab, Quick Open, a file opened
      // from Finder).
      .onChange(of: model.sidebarSelection) { _, url in
        if let url { DispatchQueue.main.async { withKitAnimation { proxy.scrollTo(url) } } }
      }
    }
    .onDeleteCommand {
      // Only the project's own files: not a package's.
      if let url = model.sidebarSelection, url != workspace.root, workspace.tree.node(for: url) != nil {
        model.trashCandidate = url
      }
    }
    .onChange(of: model.sidebarSelection) { _, url in
      guard let url, model.isFile(url) else { return }
      workspace.open(url, preview: true)
    }
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
    if model.isChoosingVisibleFiles { ChooseVisibleFilesCard() }
    KitSection(
      workspace.name, meta: projectMeta, systemImage: "folder", hue: .red, isExpanded: $isRootExpanded
    ) {
      KitOutline(treeItems, children: \.children, expanded: expandedFolders) { item in
        FileTreeRow(node: item.node)
      }
    } accessory: {
      Menu {
        FileMenu(url: nil)
      } label: {
        Label("Project", systemImage: "ellipsis")
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .labelStyle(.iconOnly)
      .fixedSize()
    }
    if !model.isChoosingVisibleFiles { PackageDependenciesSection() }
  }

  /// "Swift package · ~/Developer": the project's kind (from its scheme) and where it is.
  private var projectMeta: [String] {
    let kind = model.services.actions.selectedScheme?.toolchain.displayName
    return [kind, workspace.root.deletingLastPathComponent().abbreviatedPath].compactMap { $0 }
  }

  /// The project's top level, for the kit's outline (folders open from `workspace.tree.expanded`).
  private var treeItems: [TreeItem] {
    guard isRootExpanded else { return [] }
    let children = { (node: FileNode) in Self.visibleChildren(of: node, workspace: workspace, model: model) }
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

  // MARK: - Keyboard

  /// Return keeps the selected file open or folds and unfolds the selected folder (the kit's arrow keys move and fold).
  private func activateSelection() {
    guard model.navigator == .project, let url = model.sidebarSelection else { return }
    model.activateNavigatorItem(url)
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
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  var body: some View {
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
            .help("Matches .gitignore: \(line)")
        }
      } else if let reason = node.hiddenReason {
        Image(systemName: "eye.slash")
          .font(.system(size: 10))
          .foregroundStyle(.kitSecondary)
          .help(reason.description)
          .accessibilityLabel("Hidden")
      }
    }
    .onDoubleClick { model.activateNavigatorItem(node.url) }
    .opacity(isHidden ? 0.6 : 1)
    .id(node.url)
    .help(help)
    .contextMenu { FileMenu(url: node.url) }
    .draggable(node.url)
  }

  private var help: String {
    let path = workspace.tree.relativePath(of: node.url)
    if let reason = node.hiddenReason { return path + " — " + reason.description }
    if node.isInHiddenFolder { return path + " — In a hidden folder" }
    return path
  }

  private var isVisible: Binding<Bool> {
    Binding(
      get: { !node.isHidden },
      set: { workspace.setVisible(node.url, $0) })
  }
}

/// A file's, folder's or the project's menu (the row's context menu, the project card's "…").
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
    if model.isFile(url) {
      Button("Open in New Tab") { workspace.open(url) }
      Button("Open in New Window") { model.openInNewWindow(url) }
      Button("Open with Default App") { NSWorkspace.shared.open(url) }
    }
    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    Divider()
    Button("Copy Path") { copy(url.path) }
    Divider()
    Button("Refresh Package Dependencies") { workspace.reloadDependencies() }
  }

  @ViewBuilder private func projectMenu(node: FileNode?) -> some View {
    let folder = node.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() } ?? workspace.root
    Button("New File…") { model.ask(.newFile(in: folder)) }
    Button("New Folder…") { model.ask(.newFolder(in: folder)) }
    if let node {
      Divider()
      if !node.isDirectory {
        Button("Open in New Tab") { workspace.open(node.url) }
        Button("Open in New Window") { model.openInNewWindow(node.url) }
        Button("Open with Default App") { NSWorkspace.shared.open(node.url) }
      }
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
      Divider()
      Button("Copy Path") { copy(node.url.path) }
      Button("Copy Relative Path") { copy(workspace.tree.relativePath(of: node.url)) }
      Divider()
      Button("Rename…") { model.ask(.rename(node.url)) }
      Button("Move to Trash") { model.trashCandidate = node.url }
      Divider()
      if !node.isInHiddenFolder {
        if node.hiddenReason != nil {
          Button("Show in List") { workspace.setVisible(node.url, true) }
        } else {
          Button("Hide from List") { workspace.setVisible(node.url, false) }
        }
        if !isGitIgnored(node) {
          Button("Add to .gitignore") { workspace.addToGitIgnore(node.url) }
        }
      }
      editHiddenFilesButton
    } else {
      Divider()
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.root]) }
      Button("Copy Path") { copy(workspace.root.path) }
      Button("Reload") { workspace.tree.reloadAll() }
      Divider()
      editHiddenFilesButton
    }
  }

  /// Puts a checkbox on every item to choose what the project hides.
  @ViewBuilder private var editHiddenFilesButton: some View {
    if !model.isChoosingVisibleFiles {
      Button("Edit Hidden Files") { model.isChoosingVisibleFiles = true }
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
