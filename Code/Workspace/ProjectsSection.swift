import CodeKit
import ComponentKit
import SwiftUI
import VaultKit

/// The projects the v57 apps share (added in Git and the others, through the vault) that are on this Mac, in the
/// vault's groups, as Git's sidebar lists its repositories: the open project is the current row, a group opens and
/// closes from its row (which are closed is Code's own, shared with Welcome). Picking a project shows it in this
/// window, or brings forward the window it is open in, and the card closes again; closed, its header counts them.
struct ProjectsSection: View {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  @AppStorage("sidebar.projectsExpanded") private var isExpanded = false
  @AppStorage("welcome.collapsedGroups") private var collapsedGroups = CollapsedGroups()

  /// A row: a group or a project, and how many groups it is in.
  private struct Row: Identifiable {
    let node: VaultProjectTree.Node
    let depth: Int
    var id: String { node.id }
  }

  /// The vault's projects whose folders are on this Mac.
  private var tree: VaultProjectTree {
    Vault.shared.localProjectTree.filter { project in
      project.localPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }
  }

  /// The tree top to bottom, without what closed groups hold.
  private func rows(_ tree: VaultProjectTree) -> [Row] {
    func rows(_ nodes: [VaultProjectTree.Node], depth: Int) -> [Row] {
      nodes.flatMap { node in
        let isOpen = node.group != nil && !collapsedGroups.ids.contains(node.id)
        return [Row(node: node, depth: depth)] + (isOpen ? rows(node.children, depth: depth + 1) : [])
      }
    }
    return rows(tree.roots, depth: 0)
  }

  var body: some View {
    let tree = tree
    let count = tree.roots.flatMap(\.projects).count
    if count > 0 {
      KitSection(
        "Projects", meta: [count == 1 ? "1 project" : "\(count) projects"], systemImage: "square.stack.3d.up",
        hue: .indigo, isExpanded: $isExpanded
      ) {
        ForEach(rows(tree)) { row in
          Group {
            switch row.node {
            case .group(let group, _): groupRow(group, projects: row.node.projects.count)
            case .project(let project): projectRow(project)
            }
          }
          .kitRowIndent(row.depth)
        }
      }
      // Opened with many projects, its title stays in view while they scroll past.
      .kitSticky()
    }
  }

  // MARK: - Rows

  private func projectRow(_ project: VaultProject) -> some View {
    let folder = project.localURL?.standardizedFileURL
    return SidebarRow(project.name) {
      if let icon = project.icon.flatMap(Image.init(data:)) {
        Avatar(name: project.name, image: icon, kind: .thing, size: 18)
      } else {
        Avatar(name: project.name, kind: .thing, size: 18)
      }
    } trailing: {
      EmptyView()
    }
    .isCurrent(folder == workspace.root)
    .action { if let folder { open(folder) } }
    .help(project.localPath ?? project.name)
    .kitContextMenu {
      if let folder {
        Button("Open in New Window", systemImage: "macwindow.badge.plus") { AppState.shared.open(folder) }
          .disabled(folder == workspace.root)
        Button("Show in \(KitDesktop.fileManagerName)", systemImage: "folder") { KitDesktop.reveal([folder]) }
      }
    }
  }

  /// A group, laid out like Git's: the kit's disclosure, a folder tile, the name over its note or project count.
  private func groupRow(_ group: VaultProjectGroup, projects count: Int) -> some View {
    let isCollapsed = collapsedGroups.ids.contains(group.id)
    let toggle = {
      withAnimation(.kit) {
        if isCollapsed { collapsedGroups.ids.remove(group.id) } else { collapsedGroups.ids.insert(group.id) }
      }
    }
    return SidebarRow(
      group.name,
      subtitle: group.note.flatMap { $0.isEmpty ? nil : $0 } ?? (count == 1 ? "1 project" : "\(count) projects")
    ) {
      Avatar(
        name: group.name, kind: .thing, systemImage: isCollapsed ? "folder" : "folder.fill",
        hue: StableHue.pick(group.name), size: 18)
    } trailing: {
      EmptyView()
    }
    .disclosure(isExpanded: .init(get: { !isCollapsed }, set: { if $0 == isCollapsed { toggle() } }))
    .action(toggle)
    .help(group.localPath ?? group.name)
    .kitContextMenu {
      if let folder = group.localURL {
        Button("Show in \(KitDesktop.fileManagerName)", systemImage: "folder") { KitDesktop.reveal([folder]) }
      }
    }
  }

  /// Shows `folder` here and closes the card again.
  private func open(_ folder: URL) {
    withKitAnimation { isExpanded = false }
    guard folder != workspace.root else { return }
    model.switchProject(folder)
  }
}
