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
      if model.isChoosingVisibleFiles { ChooseVisibleFilesHeader() }
      tree
      Divider()
      bottomBar
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
      guard let url, let node = workspace.tree.node(for: url), !node.isDirectory else { return }
      workspace.open(url, preview: true)
    }
    .onDeleteCommand {
      if let url = model.sidebarSelection { model.trashCandidate = url }
    }
  }

  /// Xcode's navigator footer: the "+" menu for new files and folders, and
  /// the hidden-file buttons. While choosing visible files: Restore Defaults.
  @ViewBuilder private var bottomBar: some View {
    HStack(spacing: 6) {
      if model.isChoosingVisibleFiles {
        Button("Restore Defaults") { workspace.restoreDefaultVisibility() }
          .controlSize(.small)
          .disabled(workspace.visibility.isDefault)
        Spacer()
      } else {
        Menu {
          Button("New File…") { model.ask(.newFile(in: model.targetFolder)) }
          Button("New Folder…") { model.ask(.newFolder(in: model.targetFolder)) }
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 13, weight: .medium))
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a file or folder")
        Spacer()
        let showsHidden = workspace.visibility.showsHiddenFiles
        FooterButton(
          symbol: showsHidden ? "eye" : "eye.slash", isOn: showsHidden,
          help: showsHidden ? "Hide Hidden Files (⇧⌘.)" : "Show Hidden Files (⇧⌘.)"
        ) {
          workspace.visibility.showsHiddenFiles.toggle()
        }
        FooterButton(symbol: "checklist", isOn: false, help: "Choose Visible Files") {
          model.isChoosingVisibleFiles = true
        }
      }
    }
    .padding(.horizontal, 10)
    .frame(height: StatusBar.height)
  }

  /// Double click or Return: keep a file open, toggle a folder.
  private func activate(_ url: URL) {
    guard let node = workspace.tree.node(for: url) else { return }
    if node.isDirectory {
      workspace.tree.setExpanded(node, !workspace.tree.expanded.contains(url))
    } else {
      workspace.open(url, preview: false)
    }
  }

  @ViewBuilder private func menu(for url: URL?) -> some View {
    let node = url.flatMap { workspace.tree.node(for: $0) }
    let folder =
      node.map { $0.isDirectory ? $0.url : $0.url.deletingLastPathComponent() } ?? workspace.root
    Button("New File…") { model.ask(.newFile(in: folder)) }
    Button("New Folder…") { model.ask(.newFolder(in: folder)) }
    if let node {
      Divider()
      if !node.isDirectory {
        Button("Open in New Tab") { workspace.open(node.url) }
        Button("Open with Default App") { NSWorkspace.shared.open(node.url) }
      }
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
      Divider()
      Button("Copy Path") { copy(node.url.path) }
      Button("Copy Relative Path") { copy(workspace.tree.relativePath(of: node.url)) }
      Divider()
      Button("Rename…") { model.ask(.rename(node.url)) }
      Button("Move to Trash") { model.trashCandidate = node.url }
      if !node.isInHiddenFolder {
        Divider()
        if node.hiddenReason != nil {
          Button("Show in Navigator") { workspace.setVisible(node.url, true) }
        } else {
          Button("Hide in Navigator") { workspace.setVisible(node.url, false) }
        }
      }
    } else {
      Divider()
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.root]) }
      Button("Reload") { workspace.tree.reloadAll() }
    }
  }

  private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }
}

/// A footer icon button, tinted while its option is on.
private struct FooterButton: View {
  let symbol: String
  let isOn: Bool
  let help: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 13))
        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        .frame(width: 24, height: 22)
        .background(
          RoundedRectangle(cornerRadius: 5).fill(isOn ? Color.accentColor.opacity(0.15) : .clear))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
  }
}

/// Above the tree while choosing visible files: what the checkboxes do,
/// the project's `.gitignore` switch and Done.
private struct ChooseVisibleFilesHeader: View {
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Visible Files").fontWeight(.semibold)
        Spacer()
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
