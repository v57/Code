import CodeKit
import SwiftUI

/// The project's file tree. A click opens a file in the preview tab; a
/// double click (or Return) keeps it open.
///
/// Hidden files (`.gitignore` matches, `.git`, items the user hid) are left
/// out unless Show Hidden Files (⇧⌘.) is on, which lists them dimmed. Choose
/// Visible Files puts a checkbox on every item to change what the project
/// hides.
struct SidebarView: View {
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace
  @State private var isRootExpanded = true

  var body: some View {
    @Bindable var model = model
    VStack(spacing: 0) {
      NavigatorBar()
      Divider()
      switch model.navigator {
      case .project:
        if model.isChoosingVisibleFiles { ChooseVisibleFilesHeader() }
        tree
      case .find:
        FindNavigatorView()
        Divider()
        FindSummary()
          .padding(.horizontal, 10)
          .frame(height: StatusBar.height)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      // A folder dropped from Finder opens as a project.
      for url in urls where url.isFileURL && !url.path.hasPrefix(workspace.root.path + "/") {
        AppState.shared.open(url)
      }
      return true
    }
  }

  private var tree: some View {
    @Bindable var model = model
    return ScrollViewReader { proxy in
      // The project is the top row, expanded, as in Xcode's navigator.
      List(selection: $model.sidebarSelection) {
        DisclosureGroup(isExpanded: $isRootExpanded) {
          ForEach(visibleChildren(of: workspace.tree.root)) { node in
            FileTreeRow(node: node)
          }
        } label: {
          Label {
            Text(workspace.name)
          } icon: {
            Image(nsImage: NSWorkspace.shared.icon(forFile: workspace.root.path))
              .resizable()
              .frame(width: 16, height: 16)
          }
          .help(workspace.root.abbreviatedPath)
        }
        if !model.isChoosingVisibleFiles { PackageDependenciesSection() }
      }
      .listStyle(.sidebar)
      .environment(\.sidebarRowSize, .small)
      // Keep the selected file in view when it changes from outside the
      // sidebar (a tab, Quick Open, a file opened from Finder).
      .onChange(of: model.sidebarSelection) { _, url in
        if let url { DispatchQueue.main.async { proxy.scrollTo(url) } }
      }
    }
    .contextMenu(forSelectionType: URL.self) { urls in
      menu(for: urls.first)
    } primaryAction: { urls in
      for url in urls { activate(url) }
    }
    .onChange(of: model.sidebarSelection) { _, url in
      guard let url, isFile(url) else { return }
      workspace.open(url, preview: true)
    }
    .onDeleteCommand {
      // Only the project's own files: not a package's.
      if let url = model.sidebarSelection, url != workspace.root, workspace.tree.node(for: url) != nil {
        model.trashCandidate = url
      }
    }
  }

  /// A file in the tree, or in a package under Package Dependencies.
  private func isFile(_ url: URL) -> Bool {
    if let node = workspace.tree.node(for: url) { return !node.isDirectory }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
  }

  /// Double click or Return: keep a file open, toggle a folder.
  private func activate(_ url: URL) {
    guard let node = workspace.tree.node(for: url) else {
      // A package's file or folder.
      if isFile(url) {
        workspace.open(url, preview: false)
      } else {
        model.dependencyFolderExpansion(url).wrappedValue.toggle()
      }
      return
    }
    if node.isDirectory {
      workspace.tree.setExpanded(node, !workspace.tree.expanded.contains(url))
    } else {
      workspace.open(url, preview: false)
    }
  }

  @ViewBuilder private func menu(for url: URL?) -> some View {
    let node = url.flatMap { workspace.tree.node(for: $0) }
    if let url, node == nil {
      dependencyMenu(for: url)
    } else {
      projectMenu(for: url, node: node)
    }
  }

  /// A package's file or folder: open, reveal and copy, nothing that
  /// changes it.
  @ViewBuilder private func dependencyMenu(for url: URL) -> some View {
    if isFile(url) {
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

  @ViewBuilder private func projectMenu(for url: URL?, node: FileNode?) -> some View {
    let folder =
      node.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() } ?? workspace.root
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

  private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }
}

/// Xcode's navigator bar: the file tree or Find in Project.
private struct NavigatorBar: View {
  @Environment(WindowModel.self) private var model

  var body: some View {
    HStack(spacing: 2) {
      item(.project, symbol: "folder", help: "Project Navigator (⌘1)")
      item(.find, symbol: "magnifyingglass", help: "Find Navigator (⌘3)")
    }
    .frame(maxWidth: .infinity)
    .frame(height: 28)
  }

  private func item(_ navigator: WindowModel.Navigator, symbol: String, help: String) -> some View {
    let isOn = model.navigator == navigator
    return Button {
      model.navigator = navigator
      if navigator == .find { model.find.focus() }
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: isOn ? .semibold : .regular))
        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        .frame(width: 30, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }
}

/// Above the tree while choosing visible files: what the checkboxes do,
/// the project's `.gitignore` switch, Restore Defaults and Done.
private struct ChooseVisibleFilesHeader: View {
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Hidden Files").fontWeight(.semibold)
        Spacer()
        Button("Restore Defaults") { workspace.restoreDefaultVisibility() }
          .controlSize(.small)
          .disabled(workspace.visibility.isDefault)
        Button("Done") { model.isChoosingVisibleFiles = false }
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
      }
      Text("Uncheck what this project shouldn’t show. Hidden files stay out of the navigator and Open Quickly.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
      Toggle("Hide files listed in .gitignore", isOn: hidesIgnoredFiles)
        .toggleStyle(.checkbox)
        .font(.callout)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .bottom) { Divider() }
  }

  /// The project's choice; following the app's setting until changed.
  private var hidesIgnoredFiles: Binding<Bool> {
    Binding(
      get: { workspace.tree.hidesIgnoredFiles },
      set: { workspace.visibility.hidesIgnoredFiles = $0 })
  }
}

/// A file, or a folder with its children when expanded.
struct FileTreeRow: View {
  let node: FileNode
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  var body: some View {
    if node.isDirectory {
      DisclosureGroup(isExpanded: isExpanded) {
        ForEach(visibleChildren(of: node)) { child in
          FileTreeRow(node: child)
        }
      } label: {
        label
      }
      .tag(node.url)
    } else {
      label
        .tag(node.url)
        .id(node.url)
    }
  }

  private var label: some View {
    let isHidden = node.isHidden
    return HStack(spacing: 6) {
      if model.isChoosingVisibleFiles {
        Toggle("Show \(node.name)", isOn: isVisible)
          .toggleStyle(.checkbox)
          .labelsHidden()
          .disabled(node.isInHiddenFolder)
      }
      Label {
        Text(FileIcon.displayName(node.url, showExtensions: showExtensions))
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(isHidden ? .secondary : .primary)
      } icon: {
        Image(systemName: FileIcon.symbol(for: node.url, isDirectory: node.isDirectory))
          .foregroundStyle(FileIcon.tint(for: node.url, isDirectory: node.isDirectory))
          .opacity(isHidden ? 0.45 : 1)
      }
      Spacer(minLength: 0)
      if model.isChoosingVisibleFiles {
        if case .gitIgnore(let line) = workspace.tree.ruleReason(for: node) {
          Text(".gitignore")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)))
            .help("Matches .gitignore: \(line)")
        }
      } else if let reason = node.hiddenReason {
        Image(systemName: "eye.slash")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .help(reason.description)
          .accessibilityLabel("Hidden")
      }
    }
    .help(help)
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

  private var isExpanded: Binding<Bool> {
    Binding(
      get: { workspace.tree.expanded.contains(node.url) },
      set: { expanded in
        workspace.tree.setExpanded(node, expanded)
        workspace.saveSession()
      })
  }

  private func visibleChildren(of node: FileNode) -> [FileNode] {
    SidebarView.visibleChildren(of: node, workspace: workspace, model: model)
  }
}

extension SidebarView {
  /// `node`'s children, without hidden ones unless the navigator shows them
  /// or the user is choosing what to show.
  fileprivate func visibleChildren(of node: FileNode) -> [FileNode] {
    Self.visibleChildren(of: node, workspace: workspace, model: model)
  }

  fileprivate static func visibleChildren(
    of node: FileNode, workspace: Workspace, model: WindowModel
  ) -> [FileNode] {
    let children = node.children ?? []
    if workspace.visibility.showsHiddenFiles || model.isChoosingVisibleFiles { return children }
    return children.filter { !$0.isHidden }
  }
}
