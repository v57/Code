import CodeKit
import SwiftUI

/// The project's file tree. A click opens a file in the preview tab; a
/// double click (or Return) keeps it open.
struct SidebarView: View {
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace
  @State private var isRootExpanded = true

  var body: some View {
    @Bindable var model = model
    ScrollViewReader { proxy in
      // The project is the top row, expanded, as in Xcode's navigator.
      List(selection: $model.sidebarSelection) {
        DisclosureGroup(isExpanded: $isRootExpanded) {
          ForEach(workspace.tree.root.children ?? []) { node in
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
    .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    .dropDestination(for: URL.self) { urls, _ in
      // A folder dropped from Finder opens as a project.
      for url in urls where url.isFileURL && !url.path.hasPrefix(workspace.root.path + "/") {
        AppState.shared.open(url)
      }
      return true
    }
  }

  /// Xcode's navigator footer: the "+" menu for new files and folders.
  private var bottomBar: some View {
    HStack {
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

/// A file, or a folder with its children when expanded.
struct FileTreeRow: View {
  let node: FileNode
  @Environment(Workspace.self) private var workspace
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  var body: some View {
    if node.isDirectory {
      DisclosureGroup(isExpanded: isExpanded) {
        ForEach(node.children ?? []) { child in
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
    Label {
      Text(FileIcon.displayName(node.url, showExtensions: showExtensions))
        .lineLimit(1)
        .truncationMode(.middle)
    } icon: {
      Image(systemName: FileIcon.symbol(for: node.url, isDirectory: node.isDirectory))
        .foregroundStyle(FileIcon.tint(for: node.url, isDirectory: node.isDirectory))
    }
    .help(workspace.tree.relativePath(of: node.url))
    .draggable(node.url)
  }

  private var isExpanded: Binding<Bool> {
    Binding(
      get: { workspace.tree.expanded.contains(node.url) },
      set: { expanded in
        workspace.tree.setExpanded(node, expanded)
        workspace.saveSession()
      })
  }
}
