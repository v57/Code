import CodeFolders
import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

/// What a window without a project shows, and an open project with no file open (`EditorArea`, where a project opens in
/// its window as the Projects card does): the kit's welcome. The app's icon, name and
/// version, Open…, and the recent projects (click selects, double-click or Return opens) or the projects the v57 apps
/// share (added in Git and the others, through the vault) in the vault's groups, live as they change. A group opens
/// and closes from its chevron, a double click or Return; which are closed is Code's own. A folder can also be
/// dropped on the window: a project opens, a folder of repositories (`~/Developer`) offers them as projects instead,
/// with its databases and other folders (VaultUI's `VaultImportSheet`), or opens as one project from the sheet. The
/// account picker heads the actions (with more than one account): both lists are the window's account's.
struct WelcomeScreen: View {
  /// The window's account's vault.
  let vault: Vault
  /// The project this window has open: left out of the lists. Nil in a window without a project.
  var current: URL?
  let open: (URL) -> Void
  /// Recent or Projects, kept for the next time Welcome shows.
  @AppStorage("welcome.source") private var source = WelcomeSource.recent
  private var recents: RecentProjects { AppState.shared.recents }

  /// The groups closed in the Projects list (vault group ids).
  @AppStorage("welcome.collapsedGroups") private var collapsedGroups = KitIDSet()
  /// The projects and groups removed from Code's lists (vault ids).
  @AppStorage(RemovedProjects.key) private var removed = KitIDSet()
  /// What a dropped folder of repositories holds that the vault doesn't have, and the folder.
  @State private var importOffer: VaultImportOffer?
  @State private var dropped: URL?

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
        Task { await drop(url) }
        return true
      }
    ) {
      VaultAccountPicker(meta: projectCount == 1 ? "1 project" : "\(projectCount) projects")
      WelcomeAction("Open…", detail: "Choose a folder, or drop one on this window", systemImage: "folder") {
        AppState.shared.chooseFolder()
      }
    } recents: {
      // The window's account's: its own folders (and on Personal, those no other account has).
      ForEach(ProjectAccounts.recents(recents.existing, for: vault).filter { $0 != current }, id: \.self) { folder in
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
          if let folder = project.localURL, folder.standardizedFileURL != current {
            item(folder, isRecent: false, project: project.id)
          }
        }
      }
    }
    #if DEBUG && os(macOS)
      .task {
        for await note in NotificationCenter.default.notifications(named: DebugAutomation.welcomeDrop) {
          if let url = note.object as? URL { await drop(url) }
        }
      }
    #endif
    .kitSheet(item: $importOffer) { offer in
      VaultImportSheet(
        offer, vault: vault, app: "Code",
        alternative: dropped.map { folder in .init("Open as One Project") { open(folder) } }
      ) { _ in
        // The new projects are in the Projects list, in the groups the drop made.
        withAnimation(.kit) { source = .projects }
      }
    }
  }

  /// Opens a dropped project; a folder that holds repositories without being one is offered as projects instead
  /// (and opens when there is nothing to offer).
  private func drop(_ url: URL) async {
    // Looking for repositories would walk Desktop, Documents and the rest of the home folder.
    guard !FolderScope.isBroad(url) else { return open(url) }
    guard let found = await VaultProjectDiscovery.scan([url]).first else { return }
    let holdsRepositories = !found.repositories.isEmpty && found.repositories != [found.root]
    guard holdsRepositories, let offer = VaultImportOffer([found], store: vault.store) else { return open(url) }
    dropped = url
    importOffer = offer
  }

  private func item(_ folder: URL, isRecent: Bool, project: String? = nil) -> some View {
    let path = folder.standardizedFileURL.path
    let icon = vault.localProjects.first { $0.localPath == path }?.icon
    return RecentItem(folder.lastPathComponent, subtitle: folder.abbreviatedPath, imageData: icon) { open(folder) }
      .kitContextMenu {
        KitOpenWithRow(OpenWithApps.project(folder, git: false))
        Button("Open in New Window") { AppState.shared.open(folder) }
        Button("Copy Path") { KitPasteboard.copy(folder.path) }
        Divider()
        if isRecent {
          Button("Remove from Recents") { recents.remove(folder) }
            .kitMenuPreview("Takes \(folder.lastPathComponent) off the recent list. It stays on disk.")
          Button("Clear Recents") { recents.clear() }
            .kitMenuPreview("Empties the recent list. Projects stay on disk.")
        }
        if let project {
          Button("Remove from List") { withAnimation(.kit) { _ = removed.ids.insert(project) } }
            .kitMenuPreview("Takes \(folder.lastPathComponent) off Code’s lists. It stays on disk.")
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
      Button(isOpen ? "Close Group" : "Open Group") { withAnimation(.kit) { collapsedGroups.toggle(group.id) } }
      Divider()
      if let folder = group.localURL {
        KitOpenWithRow(OpenWithApps.project(folder, xcode: false, git: false))
        Button("Copy Path") { KitPasteboard.copy(folder.path) }
        Divider()
      }
      Button("Remove Group from List") { withAnimation(.kit) { _ = removed.ids.insert(group.id) } }
        .kitMenuPreview("Takes \(group.name) off Code’s lists. Its projects stay on disk.")
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
