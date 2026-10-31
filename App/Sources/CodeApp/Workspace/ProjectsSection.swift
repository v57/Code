import CodeKit
import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

/// The projects the v57 apps share (added in Git and the others, through the vault) that are on this Mac, in the
/// vault's groups, as Git's sidebar lists its repositories: the open project is the current row, a group opens and
/// closes from its row (which are closed is Code's own, shared with Welcome). Picking a project shows it in this
/// window, or brings forward the window it is open in, and the card closes again; closed, its header counts them.
/// They are the window's account's, named in the header when it isn't Personal.
struct ProjectsSection: View {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  @Environment(\.vault) private var vault
  @AppStorage("sidebar.projectsExpanded") private var isExpanded = false
  @AppStorage("welcome.collapsedGroups") private var collapsedGroups = CollapsedGroups()
  /// The projects and groups removed from Code's lists (vault ids).
  @AppStorage(RemovedProjects.key) private var removed = CollapsedGroups()
  @State private var confirmsRemoveAll = false

  /// A row: a group or a project, and how many groups it is in.
  private struct Row: Identifiable {
    let node: VaultProjectTree.Node
    let depth: Int
    var id: String { node.id }
  }

  /// The vault's projects whose folders are on this Mac.
  private func tree(_ vault: Vault) -> VaultProjectTree { vault.codeProjectTree(removed: removed.ids) }

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
    if let vault { section(vault) }
  }

  @ViewBuilder private func section(_ vault: Vault) -> some View {
    let tree = tree(vault)
    let count = tree.roots.flatMap(\.projects).count
    let account = vault.isPersonal ? nil : Vaults.shared.account(id: vault.accountID)?.name
    if count > 0 {
      KitSection(
        "Projects", meta: [count == 1 ? "1 project" : "\(count) projects", account].compactMap { $0 },
        systemImage: "square.stack.3d.up",
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
      .headerMenu {
        Button("Remove All Projects from List", systemImage: "minus.circle") { confirmsRemoveAll = true }
      }
      // Opened with many projects, its title stays in view while they scroll past.
      .kitSticky()
      .kitConfirmation(
        count == 1 ? "Remove 1 project from the list?" : "Remove all \(count) projects from the list?", isPresented: $confirmsRemoveAll,
        message: "They stay in Git and the other apps, and on disk. Opening one brings it back.",
        systemImage: "minus.circle", confirm: "Remove All"
      ) {
        withAnimation(.kit) { removed.ids.formUnion(tree.projects().map(\.id)) }
      }
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
        Divider()
      }
      Button("Remove from List", systemImage: "minus.circle") {
        withAnimation(.kit) { _ = removed.ids.insert(project.id) }
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
        Divider()
      }
      Button("Remove Group from List", systemImage: "minus.circle") {
        withAnimation(.kit) { _ = removed.ids.insert(group.id) }
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
