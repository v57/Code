import CodeKit
import SwiftUI

/// Xcode's Package Dependencies under the file tree: each package with its
/// version (or "local"), its sources browsable when they are on disk.
struct PackageDependenciesSection: View {
  @Environment(Workspace.self) private var workspace

  var body: some View {
    if !workspace.dependencies.isEmpty {
      Section("Package Dependencies") {
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
      DisclosureGroup(isExpanded: model.dependencyFolderExpansion(location)) {
        DependencyFolderContents(folder: location)
      } label: {
        label
      }
      .tag(location)
    } else {
      label
        .foregroundStyle(.secondary)
    }
  }

  private var label: some View {
    HStack(spacing: 6) {
      Label {
        HStack(spacing: 5) {
          Text(dependency.name)
            .lineLimit(1)
            .truncationMode(.middle)
          Text(dependency.detail)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      } icon: {
        Image(systemName: "shippingbox.fill")
          .foregroundStyle(Color(red: 0.80, green: 0.62, blue: 0.42))
      }
      Spacer(minLength: 0)
    }
    .help(help)
  }

  private var help: String {
    var lines = [dependency.ecosystem.displayName + ": " + dependency.name]
    if let source = dependency.source, source != dependency.name { lines.append(source) }
    lines.append(dependency.location?.abbreviatedPath ?? "Not downloaded yet")
    return lines.joined(separator: "\n")
  }
}

/// A dependency's folder, read when it is first expanded. Dotfiles are
/// left out, as Xcode does.
private struct DependencyFolderContents: View {
  let folder: URL
  @State private var entries: [(url: URL, isDirectory: Bool)]?

  var body: some View {
    Group {
      if let entries {
        ForEach(entries, id: \.url) { entry in
          DependencyEntryRow(url: entry.url, isDirectory: entry.isDirectory)
        }
      } else {
        // Keeps the group expandable until the folder is read.
        Text("Loading…").foregroundStyle(.secondary)
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
  @Environment(WindowModel.self) private var model
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  var body: some View {
    if isDirectory {
      DisclosureGroup(isExpanded: model.dependencyFolderExpansion(url)) {
        DependencyFolderContents(folder: url)
      } label: {
        label
      }
      .tag(url)
    } else {
      label
        .tag(url)
        .id(url)
    }
  }

  private var label: some View {
    Label {
      Text(FileIcon.displayName(url, showExtensions: showExtensions))
        .lineLimit(1)
        .truncationMode(.middle)
    } icon: {
      Image(systemName: FileIcon.symbol(for: url, isDirectory: isDirectory))
        .foregroundStyle(FileIcon.tint(for: url, isDirectory: isDirectory))
    }
    .help(url.abbreviatedPath)
  }
}
