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
  @AppStorage("welcome.collapsedGroups") private var collapsedGroups = KitIDSet()
  /// The projects and groups removed from Code's lists (vault ids).
  @AppStorage(RemovedProjects.key) private var removed = KitIDSet()
  @State private var confirmsRemoveAll = false

  /// The vault's projects whose folders are on this Mac.
  private func tree(_ vault: Vault) -> VaultProjectTree { vault.codeProjectTree(removed: removed.ids) }

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
        KitOutline(
          tree.roots, children: { $0.group == nil ? nil : $0.children },
          collapsed: $collapsedGroups.animation(.kit).ids
        ) { node in
          switch node {
          case .group(let group, _): groupRow(group, projects: node.projects.count)
          case .project(let project): projectRow(project)
          }
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
    .kitHelp(project.name, meta: project.localPath)
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

  /// A group, laid out like Git's: the outline's disclosure, a folder tile, the name over its note or project count;
  /// a click opens or closes it.
  private func groupRow(_ group: VaultProjectGroup, projects count: Int) -> some View {
    let isCollapsed = collapsedGroups.contains(group.id)
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
    .kitHelp(group.name, meta: group.localPath)
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
