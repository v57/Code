import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

/// What a window without a project shows: the kit's welcome as the window's content. The app's icon, name and
/// version, Open…, and the recent projects (click selects, double-click or Return opens) or the projects the v57 apps
/// share (added in Git and the others, through the vault) in the vault's groups, live as they change. A group opens
/// and closes from its chevron, a double click or Return; which are closed is Code's own. A folder can also be
/// dropped on the window. The account picker heads the actions (with more than one account): the Projects list is
/// the window's account's.
struct WelcomeScreen: View {
  /// The window's account's vault.
  let vault: Vault
  let open: (URL) -> Void
  /// Recent or Projects, kept for the next time Welcome shows.
  @AppStorage("welcome.source") private var source = WelcomeSource.recent
  private var recents: RecentProjects { AppState.shared.recents }

  /// The groups closed in the Projects list (vault group ids).
  @AppStorage("welcome.collapsedGroups") private var collapsedGroups = CollapsedGroups()

  /// The projects the vault shares that are on this Mac, in their groups.
  private var projectTree: VaultProjectTree {
    vault.localProjectTree.filter { project in
      project.localPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }
  }

  /// A row of the Projects list: a group or a project, and how many groups it is in.
  private struct ProjectRow: Identifiable {
    let node: VaultProjectTree.Node
    let depth: Int
    var id: String { node.id }
  }

  /// The tree top to bottom, without what closed groups hold.
  private var projectRows: [ProjectRow] {
    func rows(_ nodes: [VaultProjectTree.Node], depth: Int) -> [ProjectRow] {
      nodes.flatMap { node in
        let isOpen = node.group != nil && !collapsedGroups.ids.contains(node.id)
        return [ProjectRow(node: node, depth: depth)] + (isOpen ? rows(node.children, depth: depth + 1) : [])
      }
    }
    return rows(projectTree.roots, depth: 0)
  }

  var body: some View {
    let projectCount = projectTree.roots.flatMap(\.projects).count
    KitWelcome(
      emptyTitle: "No Recent Projects", emptyMessage: "Projects you open appear here.", source: $source,
      onDrop: { urls in
        guard let url = urls.first else { return false }
        open(url)
        return true
      }
    ) {
      VaultAccountPicker(meta: projectCount == 1 ? "1 project" : "\(projectCount) projects")
      WelcomeAction("Open…", detail: "Choose a folder, or drop one on this window", systemImage: "folder") {
        AppState.shared.chooseFolder()
      }
    } recents: {
      ForEach(recents.existing, id: \.self) { folder in
        item(folder, isRecent: true)
      }
    } projects: {
      ForEach(projectRows) { row in
        Group {
          switch row.node {
          case .group(let group, _): groupItem(group, projects: row.node.projects.count)
          case .project(let project):
            if let folder = project.localURL { item(folder, isRecent: false) }
          }
        }
        .padding(.leading, CGFloat(row.depth) * 20)
      }
    }
    .kitPane(.content)
    .navigationTitle("Code")
  }

  private func item(_ folder: URL, isRecent: Bool) -> some View {
    let path = folder.standardizedFileURL.path
    let icon = vault.localProjects.first { $0.localPath == path }?.icon.flatMap(Image.init(data:))
    return RecentItem(folder.lastPathComponent, subtitle: folder.abbreviatedPath, image: icon) { open(folder) }
      .kitContextMenu {
        Button("Show in \(KitDesktop.fileManagerName)") { KitDesktop.reveal([folder]) }
        if isRecent {
          Button("Remove from Recents") { recents.remove(folder) }
        }
      }
  }

  /// A group: its name and how many projects it holds, a chevron that opens or closes it. Return and a double click
  /// open or close it too, as they open a project.
  private func groupItem(_ group: VaultProjectGroup, projects count: Int) -> some View {
    let isOpen = !collapsedGroups.ids.contains(group.id)
    let toggle = {
      withAnimation(.kit) {
        if isOpen { collapsedGroups.ids.insert(group.id) } else { collapsedGroups.ids.remove(group.id) }
      }
    }
    return RecentItem(
      group.name, subtitle: group.note.flatMap { $0.isEmpty ? nil : $0 } ?? (count == 1 ? "1 project" : "\(count) projects"),
      systemImage: isOpen ? "folder.fill" : "folder", id: "group:\(group.id)", action: toggle
    )
    .overlay(alignment: .trailing) {
      Button(action: toggle) {
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.kitSecondary)
          .rotationEffect(.degrees(isOpen ? 90 : 0))
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.trailing, 8)
      .accessibilityLabel(isOpen ? "Collapse \(group.name)" : "Expand \(group.name)")
    }
    .kitContextMenu {
      if let folder = group.localURL {
        Button("Show in \(KitDesktop.fileManagerName)") { KitDesktop.reveal([folder]) }
      }
    }
  }
}

/// The ids of the closed groups, kept in one defaults string.
struct CollapsedGroups: RawRepresentable {
  var ids: Set<String>

  init() { ids = [] }

  init(rawValue: String) {
    ids = Set(rawValue.split(separator: "\n").map(String.init))
  }

  var rawValue: String { ids.sorted().joined(separator: "\n") }
}
