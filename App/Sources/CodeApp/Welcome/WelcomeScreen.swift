import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

/// What a window without a project shows: the kit's welcome as the window's content. The app's icon, name and
/// version, Open…, and the recent projects (click selects, double-click or Return opens) or the projects the v57 apps
/// share (added in Git and the others, through the vault) in the vault's groups, live as they change. A group opens
/// and closes from its chevron, a double click or Return; which are closed is Code's own. A folder can also be
/// dropped on the window. The account picker heads the actions (with more than one account): both lists are the
/// window's account's.
struct WelcomeScreen: View {
  /// The window's account's vault.
  let vault: Vault
  let open: (URL) -> Void
  /// Recent or Projects, kept for the next time Welcome shows.
  @AppStorage("welcome.source") private var source = WelcomeSource.recent
  private var recents: RecentProjects { AppState.shared.recents }

  /// The groups closed in the Projects list (vault group ids).
  @AppStorage("welcome.collapsedGroups") private var collapsedGroups = KitIDSet()
  /// The projects and groups removed from Code's lists (vault ids).
  @AppStorage(RemovedProjects.key) private var removed = KitIDSet()

  /// The projects the vault shares that are on this Mac, in their groups.
  private var projectTree: VaultProjectTree { vault.codeProjectTree(removed: removed.ids) }

  var body: some View {
    let projectCount = projectTree.roots.flatMap(\.projects).count
    KitWelcome(
      emptyTitle: source == .projects ? "No Projects" : "No Recent Projects",
      emptyMessage: source == .projects
        ? "Projects added in Code, Git or the other v57 apps appear here." : "Projects you open appear here.",
      source: $source,
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
      // The window's account's: its own folders (and on Personal, those no other account has).
      ForEach(ProjectAccounts.recents(recents.existing, for: vault), id: \.self) { folder in
        item(folder, isRecent: true)
      }
    } projects: {
      KitOutline(
        projectTree.roots, children: { $0.group == nil ? nil : $0.children },
        collapsed: $collapsedGroups.animation(.kit).ids
      ) { node in
        switch node {
        case .group(let group, _): groupItem(group, projects: node.projects.count)
        case .project(let project):
          if let folder = project.localURL { item(folder, isRecent: false, project: project.id) }
        }
      }
    }
    .kitPane(.content)
    .navigationTitle("Code")
  }

  private func item(_ folder: URL, isRecent: Bool, project: String? = nil) -> some View {
    let path = folder.standardizedFileURL.path
    let icon = vault.localProjects.first { $0.localPath == path }?.icon.flatMap(Image.init(data:))
    return RecentItem(folder.lastPathComponent, subtitle: folder.abbreviatedPath, image: icon) { open(folder) }
      .kitContextMenu {
        Button("Show in \(KitDesktop.fileManagerName)") { KitDesktop.reveal([folder]) }
        if isRecent {
          Button("Remove from Recents") { recents.remove(folder) }
        }
        if let project {
          Button("Remove from List") { withAnimation(.kit) { _ = removed.ids.insert(project) } }
        }
      }
  }

  /// A group: its name and how many projects it holds; the outline trails it with the chevron that opens or closes
  /// it. Return and a double click open or close it too, as they open a project.
  private func groupItem(_ group: VaultProjectGroup, projects count: Int) -> some View {
    let isOpen = !collapsedGroups.contains(group.id)
    return RecentItem(
      group.name, subtitle: group.note.flatMap { $0.isEmpty ? nil : $0 } ?? (count == 1 ? "1 project" : "\(count) projects"),
      systemImage: isOpen ? "folder.fill" : "folder", id: "group:\(group.id)"
    ) {
      withAnimation(.kit) { collapsedGroups.toggle(group.id) }
    }
    .kitContextMenu {
      if let folder = group.localURL {
        Button("Show in \(KitDesktop.fileManagerName)") { KitDesktop.reveal([folder]) }
      }
      Button("Remove Group from List") { withAnimation(.kit) { _ = removed.ids.insert(group.id) } }
    }
  }
}

/// The vault's projects and groups removed from Code's lists (Projects in the sidebar and on Welcome), kept as
/// a `KitIDSet` under `key`: Code's own, Git and the other apps keep them. A group's projects go with it, and
/// opening a removed project brings it back (`restore`).
enum RemovedProjects {
  static let key = "projects.removed"

  /// Brings back the project at `folder` and the groups it is in, in any account's vault, if they were removed.
  static func restore(_ folder: URL) {
    let defaults = UserDefaults.standard
    var removed = KitIDSet(rawValue: defaults.string(forKey: key) ?? "")
    guard !removed.ids.isEmpty else { return }
    let path = folder.standardizedFileURL.path
    let vaults = Vaults.shared
    for vault in (vaults.accounts + [.personal]).compactMap(vaults.vault(for:)) {
      guard let project = vault.localProjects.first(where: {
          $0.localPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path
        }) else { continue }
      removed.ids.subtract([project.id] + vault.localProjectTree.ancestors(of: project.id).map(\.id))
    }
    defaults.set(removed.rawValue, forKey: key)
  }
}

extension Vault {
  /// The projects the vault shares whose folders are on this Mac, in their groups, without those removed from Code's
  /// lists (`removed`: project and group ids, `RemovedProjects`).
  func codeProjectTree(removed: Set<String>) -> VaultProjectTree {
    let tree = localProjectTree
    return tree.filter { project in
      guard project.localPath.map({ FileManager.default.fileExists(atPath: $0) }) ?? false else { return false }
      return !removed.contains(project.id) && !tree.ancestors(of: project.id).contains { removed.contains($0.id) }
    }
  }
}
