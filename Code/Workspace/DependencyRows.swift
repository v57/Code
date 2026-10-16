import CodeKit
import ComponentKit
import SwiftUI

/// Xcode's Package Dependencies under the file tree, as a card: each package with its version (or "local"), its
/// sources browsable (the kit's outline) when they are on disk. A folder is read when it is first opened; dotfiles
/// are left out, as Xcode does.
struct PackageDependenciesSection: View {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  /// The folders read so far.
  @State private var entries: [URL: [DependencyItem.Entry]] = [:]

  var body: some View {
    @Bindable var model = model
    if !workspace.dependencies.isEmpty {
      let count = workspace.dependencies.count
      KitSection(
        "Package Dependencies", meta: count == 1 ? "1 package" : "\(count) packages", systemImage: "shippingbox",
        hue: .brown
      ) {
        KitOutline(items, children: \.children, expanded: $model.expandedDependencyFolders) { item in
          switch item.kind {
          case .package(let dependency): PackageDependencyRow(dependency: dependency)
          case .entry(let entry): DependencyEntryRow(url: entry.url, isDirectory: entry.isDirectory)
          }
        }
      }
      .task(id: model.expandedDependencyFolders) { await readOpenFolders() }
      .onChange(of: workspace.dependencies) { _, _ in entries = [:] }
    }
  }

  private var items: [DependencyItem] {
    workspace.dependencies.map { DependencyItem(kind: .package($0), entries: entries) }
  }

  private func readOpenFolders() async {
    for folder in model.expandedDependencyFolders where entries[folder] == nil {
      entries[folder] = await Task.detached(priority: .userInitiated) {
        FileTree.listDirectory(folder)
          .filter { !$0.url.lastPathComponent.hasPrefix(".") }
          .map { DependencyItem.Entry(url: $0.url, isDirectory: $0.isDirectory) }
      }.value
    }
  }
}

/// A package or one of the files and folders in its sources, for the outline: a folder's children are its entries
/// once read (none before), a package without sources on disk has none to show.
struct DependencyItem: Identifiable {
  struct Entry: Sendable {
    let url: URL
    let isDirectory: Bool
  }

  enum Kind {
    case package(PackageDependency)
    case entry(Entry)
  }

  let kind: Kind
  let entries: [URL: [Entry]]

  /// The folder's URL (what `expandedDependencyFolders` holds); a package without sources gets a placeholder.
  var id: URL {
    switch kind {
    case .package(let dependency): dependency.location ?? URL(string: "package:" + dependency.id)!
    case .entry(let entry): entry.url
    }
  }

  private var folder: URL? {
    switch kind {
    case .package(let dependency): dependency.location
    case .entry(let entry): entry.isDirectory ? entry.url : nil
    }
  }

  var children: [DependencyItem]? {
    guard let folder else { return nil }
    return (entries[folder] ?? []).map { DependencyItem(kind: .entry($0), entries: entries) }
  }
}

private struct PackageDependencyRow: View {
  let dependency: PackageDependency
  @Environment(WindowModel.self) private var model

  var body: some View {
    let icon = Image(systemName: "shippingbox.fill")
      .font(.system(size: 12))
      .foregroundStyle(Hue.brown.fill)
      .frame(width: 17, height: 14)
    let detail = Text(dependency.detail).lineLimit(1)
    if let location = dependency.location {
      SidebarRow(value: NavigatorItem.file(location), dependency.name, icon: { icon }, trailing: { detail })
        .onDoubleClick { model.dependencyFolderExpansion(location).wrappedValue.toggle() }
        .help(help)
        .contextMenu { FileMenu(url: location) }
    } else {
      SidebarRow(dependency.name, icon: { icon }, trailing: { detail })
        .help(help)
        .opacity(0.6)
    }
  }

  private var help: String {
    var lines = [dependency.ecosystem.displayName + ": " + dependency.name]
    if let source = dependency.source, source != dependency.name { lines.append(source) }
    lines.append(dependency.location?.abbreviatedPath ?? "Not downloaded yet")
    return lines.joined(separator: "\n")
  }
}

private struct DependencyEntryRow: View {
  let url: URL
  let isDirectory: Bool
  @Environment(WindowModel.self) private var model
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  var body: some View {
    SidebarRow(value: NavigatorItem.file(url), FileName.display(url, showExtensions: showExtensions)) {
      FileIconView(for: url, isDirectory: isDirectory, size: 14)
    }
    .onDoubleClick { model.activateNavigatorItem(url) }
    .id(url)
    .help(url.abbreviatedPath)
    .contextMenu { FileMenu(url: url) }
  }
}
