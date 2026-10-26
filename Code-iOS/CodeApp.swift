import CodeActions
import ComponentKit
import SwiftUI
import VaultKit

/// Code on iPhone and iPad: the projects on the user's other devices, and Build, Test and Clean run there over SSH
/// with the log and issues streamed back. Nothing builds here (there's no toolchain), and the folders stay there:
/// files are browsed and read over SFTP.
@main
struct CodeApp: App {
  var body: some Scene {
    WindowGroup {
      ProjectsView()
        .componentKit()
    }
  }
}

/// The kit's split view: the projects in the sidebar (the root list on iPhone), the picked one beside it (pushed on
/// iPhone).
struct ProjectsView: View {
  @State private var vault = Vault.shared
  @State private var selection: RemoteProject.ID?
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @State private var compactColumn = NavigationSplitViewColumn.sidebar
  @Environment(\.kitIdiom) private var idiom

  private var projects: [RemoteProject] { RemoteProjects.all(vault: vault) }

  var body: some View {
    // iPhone with nothing to list: the welcome is the first screen.
    if idiom == .phone, projects.isEmpty {
      ProjectsWelcome(projects: [], selection: $selection)
    } else {
      split
    }
  }

  private var split: some View {
    NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
      ProjectsSidebar(projects: projects, selection: $selection, columnVisibility: $columnVisibility)
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
    } detail: {
      NavigationStack {
        if let project = projects.first(where: { $0.id == selection }) {
          ProjectScreen(project: project).id(project.id)
        } else {
          ProjectsWelcome(projects: projects, selection: $selection)
        }
      }
      .kitSidebarToggle(columnVisibility: $columnVisibility)
    }
    .onChange(of: selection) { _, selection in
      if selection != nil { compactColumn = .detail }
    }
    // iPhone: back on the root list, no row stays picked (tapping it again opens it again).
    .onChange(of: compactColumn) { _, column in
      if idiom == .phone, column == .sidebar { selection = nil }
    }
    .task {
      #if DEBUG
        if let id = DebugLaunch.selected(in: projects) { selection = id }
      #endif
    }
  }
}

/// The main screen while no project is open: the kit's welcome, its list the projects on the user's devices (a tap
/// opens one), or how to get some while there are none.
struct ProjectsWelcome: View {
  let projects: [RemoteProject]
  @Binding var selection: RemoteProject.ID?

  var body: some View {
    KitWelcome(
      emptyTitle: "No Projects on Your Devices",
      emptyMessage:
        "Code runs Build, Test and Clean on your Macs. Connect them to a Hub in the Vault app, and open a project in Code on a Mac: it shows up here."
    ) {
      EmptyView()
    } recents: {
      ForEach(projects) { project in
        RecentItem(
          project.name, subtitle: project.targets.map(\.name).joined(separator: ", "),
          image: project.icon.flatMap(Image.init(data:))
        ) { selection = project.id }
      }
    }
    .listTitle("On Your Devices")
    .kitPane(.content)
  }
}

/// The projects as the kit's sidebar: one card of the vault's projects that have a folder on another device, each
/// on its icon (or initial) with the devices that have it; search filters them, and the bar says how many devices
/// Code can reach through the user's Hubs. With none, it says how to get some.
struct ProjectsSidebar: View {
  let projects: [RemoteProject]
  @Binding var selection: RemoteProject.ID?
  @Binding var columnVisibility: NavigationSplitViewVisibility
  @State private var search = ""
  @Environment(\.kitIdiom) private var idiom

  private var shown: [RemoteProject] {
    search.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
  }

  /// The devices the projects are on.
  private var deviceCount: Int { Set(projects.flatMap { $0.targets.map(\.name) }).count }

  var body: some View {
    KitSidebar(
      selection: $selection, searchText: $search, searchPrompt: "Search Projects", columnVisibility: $columnVisibility
    ) {
      if projects.isEmpty {
        // iPad: the welcome beside it says how to get some.
        KitSection("Projects", meta: ["None yet"], systemImage: "folder", hue: .orange) {
          Text("Projects on your other devices appear here.")
            .kitFont(.caption).foregroundStyle(.kitSecondary).padding(10)
        }
      } else {
        KitSection(
          "Projects",
          meta: [projects.count == 1 ? "1 project" : "\(projects.count) projects", "on your devices"],
          systemImage: "folder", hue: .orange
        ) {
          ForEach(shown) { project in
            SidebarRow(value: project.id, project.name, subtitle: project.targets.map(\.name).joined(separator: ", ")) {
              ProjectTile(project: project)
            } trailing: {
              // iPhone: a row pushes its project.
              if idiom == .phone {
                Image(systemName: "chevron.right")
                  .font(.system(size: 12, weight: .semibold))
                  .foregroundStyle(.kitTertiary)
              }
            }
          }
          if shown.isEmpty {
            Text("Nothing matches “\(search)”.").kitFont(.caption).foregroundStyle(.kitSecondary).padding(10)
          }
        }
        // Many projects: the card's title stays in view while they scroll past.
        .kitSticky()
      }
    } bottomBar: {
      EmptyView()
    }
    .status {
      HStack(spacing: 6) {
        StatusDot(hue: deviceCount > 0 ? .green : .gray)
        Text(deviceCount == 0 ? "No devices" : deviceCount == 1 ? "1 device via Hub" : "\(deviceCount) devices via Hub")
      }
    }
    .navigationTitle("Code")
  }
}

/// A project's icon from the vault, or its initial on a tile in a colour picked from its name.
struct ProjectTile: View {
  let project: RemoteProject
  var size: CGFloat = 32

  var body: some View {
    if let icon = project.icon.flatMap(Image.init(data:)) {
      Avatar(name: project.name, image: icon, kind: .thing, size: size)
    } else {
      Avatar(name: project.name, kind: .thing, size: size)
    }
  }
}
