import CodeKit
import ComponentKit
import SwiftUI

/// Xcode's Package Dependencies under the file tree, as a card: each package with its version (or "local"), its
/// sources browsable when they are on disk.
struct PackageDependenciesSection: View {
  @Environment(Workspace.self) private var workspace

  var body: some View {
    if !workspace.dependencies.isEmpty {
      let count = workspace.dependencies.count
      KitSection(
        "Package Dependencies", meta: count == 1 ? "1 package" : "\(count) packages", systemImage: "shippingbox",
        hue: .brown
      ) {
        ForEach(workspace.dependencies) { dependency in
          PackageDependencyRow(dependency: dependency)
        }
      }
    }
  }
}

private struct PackageDependencyRow: View {
  let dependency: PackageDependency
  @Environment(WindowModel.self) private var model

  var body: some View {
    if let location = dependency.location {
      let isExpanded = model.dependencyFolderExpansion(location)
      row(value: NavigatorItem.file(location), isExpanded: isExpanded)
        .contextMenu { FileMenu(url: location) }
      if isExpanded.wrappedValue {
        DependencyFolderContents(folder: location, depth: 1)
      }
    } else {
      row(value: nil, isExpanded: .constant(false))
        .opacity(0.6)
    }
  }

  @ViewBuilder private func row(value: NavigatorItem?, isExpanded: Binding<Bool>) -> some View {
    let icon = HStack(spacing: 2) {
      Disclosure(isDirectory: dependency.location != nil, isExpanded: isExpanded)
      Image(systemName: "shippingbox.fill")
        .font(.system(size: 12))
        .foregroundStyle(Hue.brown.fill)
        .frame(width: 17, height: 14)
    }
    let detail = Text(dependency.detail).lineLimit(1)
    Group {
      if let value {
        SidebarRow(value: value, dependency.name, icon: { icon }, trailing: { detail })
      } else {
        SidebarRow(dependency.name, icon: { icon }, trailing: { detail })
      }
    }
    .help(help)
    .simultaneousGesture(TapGesture(count: 2).onEnded { isExpanded.wrappedValue.toggle() })
  }

  private var help: String {
    var lines = [dependency.ecosystem.displayName + ": " + dependency.name]
    if let source = dependency.source, source != dependency.name { lines.append(source) }
    lines.append(dependency.location?.abbreviatedPath ?? "Not downloaded yet")
    return lines.joined(separator: "\n")
  }
}

/// A dependency's folder, read when it is first expanded. Dotfiles are left out, as Xcode does.
private struct DependencyFolderContents: View {
  let folder: URL
  let depth: Int
  @State private var entries: [(url: URL, isDirectory: Bool)]?

  var body: some View {
    Group {
      if let entries {
        ForEach(entries, id: \.url) { entry in
          DependencyEntryRow(url: entry.url, isDirectory: entry.isDirectory, depth: depth)
        }
      } else {
        SidebarRow("Loading…") { Color.clear.frame(width: 1, height: 14) }
          .kitRowIndent(depth)
          .opacity(0.6)
      }
    }
    .task(id: folder) {
      let folder = folder
      entries = await Task.detached(priority: .userInitiated) {
        FileTree.listDirectory(folder).filter { !$0.url.lastPathComponent.hasPrefix(".") }
      }.value
    }
  }
}

private struct DependencyEntryRow: View {
  let url: URL
  let isDirectory: Bool
  let depth: Int
  @Environment(WindowModel.self) private var model
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  var body: some View {
    let isExpanded = model.dependencyFolderExpansion(url)
    SidebarRow(value: NavigatorItem.file(url), FileName.display(url, showExtensions: showExtensions)) {
      HStack(spacing: 2) {
        Disclosure(isDirectory: isDirectory, isExpanded: isExpanded)
        FileIconView(for: url, isDirectory: isDirectory, size: 14)
      }
    }
    .kitRowIndent(depth)
    .id(url)
    .help(url.abbreviatedPath)
    .simultaneousGesture(TapGesture(count: 2).onEnded { model.activateNavigatorItem(url) })
    .contextMenu { FileMenu(url: url) }
    if isDirectory, isExpanded.wrappedValue {
      DependencyFolderContents(folder: url, depth: depth + 1)
    }
  }
}
