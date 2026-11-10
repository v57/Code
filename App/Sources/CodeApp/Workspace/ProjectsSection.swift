import CodeKit
import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

/// The projects the v57 apps share (added in Git and the others, through the vault) that are on this Mac, in the
/// vault's groups: VaultUI's projects section, folded away by default once a project is open (the tree needs the
/// room), the open project's tree in its section under it. Picking a project shows it in this window, or brings
/// forward the window it is open in. Which groups are closed is Code's own, shared with Welcome. A folder that isn't
/// one of the vault's projects keeps its tree in a section of its own (`fallback`) under the list.
struct ProjectsSection<FileTree: View, Accessory: View, Fallback: View>: View {
  let meta: [String]
  @ViewBuilder let fileTree: () -> FileTree
  @ViewBuilder let accessory: () -> Accessory
  @ViewBuilder let fallback: () -> Fallback
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  @Environment(\.vault) private var vault
  @KitStorage("welcome.collapsedGroups") private var collapsedGroups = KitIDSet()
  /// The projects and groups removed from Code's lists (vault ids).
  @KitStorage(RemovedProjects.key) private var removed = KitIDSet()

  var body: some View {
    if let vault, case let tree = vault.codeProjectTree(removed: removed.ids), !tree.isEmpty {
      section(vault, tree)
    } else {
      fallback()
    }
  }

  @ViewBuilder private func section(_ vault: Vault, _ tree: VaultProjectTree) -> some View {
    let root = workspace.root.standardizedFileURL
    let current = tree.projects().first { $0.localURL?.standardizedFileURL == root }
    let account = vault.isPersonal ? nil : Vaults.shared.account(id: vault.accountID)?.name
    VaultProjectsSection(
      tree,
      selection: Binding(
        get: { current?.id },
        set: { id in
          if let folder = id.flatMap({ tree.node(id: $0)?.project?.localURL }) { open(folder) }
        }),
      layout: .folding, key: "sidebar.projects", collapsedGroups: $collapsedGroups.ids
    ) { _ in
      fileTree()
    } menu: {
      EmptyView()
    }
    .title(String(localized: "Projects"), meta: [account].compactMap { $0 })
    .projectHeader(meta: { _ in meta }, accessory: { _ in accessory() })
    .trailing { project in
      if let folder = project.localURL, AppState.shared.isRunningInBackground(folder) {
        Image(systemName: "play.fill")
          .font(.caption2)
          .foregroundStyle(Hue.green.fill)
          .kitHelp("Running", meta: "Show the project to see or stop it")
      }
    }
    .rowMenu { project in
      if let folder = project.localURL, AppState.shared.isRunningInBackground(folder) {
        Button("Stop", systemImage: "stop.fill") { AppState.shared.stopBackgroundProject(folder) }
          .kitMenuPreview("Stops what’s running in \(project.name).")
      }
      if let folder = project.localURL {
        Button("Open in New Window", systemImage: "macwindow.badge.plus") { AppState.shared.open(folder) }
          .disabled(folder.standardizedFileURL == root)
          .kitMenuPreview(
            folder.standardizedFileURL == root
              ? "\(project.name) is open in this window."
              : "Opens \(project.name) in a window of its own and keeps this one.")
      }
    }
    // Xcode and Git join the section's own Finder and Terminal (Code leaves itself out).
    .openWith { project in project.localURL.map { OpenWithApps.project($0) } ?? [] }
    .removable { ids in removed.ids.formUnion(ids) }
    if current == nil { fallback() }
  }

  /// Shows `folder` here (or brings forward the window it's open in).
  private func open(_ folder: URL) {
    guard folder.standardizedFileURL != workspace.root.standardizedFileURL else { return }
    model.switchProject(folder)
  }
}
