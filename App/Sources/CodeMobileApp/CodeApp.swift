import CodeActions
import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

/// Code on iPhone and iPad: the projects on the user's other devices, and Build, Test and Clean run there over SSH
/// with the log and issues streamed back. Nothing builds here (there's no toolchain), and the folders stay there:
/// files are browsed and read over SFTP.
public struct CodeApp: App {
  public init() {
    // The devices and their projects sync on their own, and this device's key goes out, so a Mac can let it in (the
    // Vault app's SSH from your devices); devices are Personal's.
    Vault.shared.startSync()
    try? Vault.shared.store?.publishDeviceKey()
  }

  public var body: some Scene {
    WindowGroup {
      AccountWindow()
        .vaultHostKeyRequests()
        .componentKit()
    }
  }
}

/// A window shows one account's projects, as on the Mac: the account picker heads the projects list (drawn only with
/// more than one account), and New Account… opens from it. Renaming and deleting accounts is in the Vault app and in
/// the Mac apps' Settings ▸ Accounts.
struct AccountWindow: View {
  @SceneStorage("vault.account") private var accountID = VaultAccount.personal.id

  var body: some View {
    VaultAccountScope(selection: $accountID) { vault in
      ProjectsView(vault: vault)
    }
  }
}

/// The kit's split view on iPad: the projects in the sidebar, the picked one beside it. On iPhone the list is the root
/// of a stack and the picked project is pushed.
struct ProjectsView: View {
  /// The window's account's vault.
  let vault: Vault
  @State private var vaults = Vaults.shared
  @State private var selection: RemoteProject.ID?
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  @State private var compactColumn = NavigationSplitViewColumn.sidebar
  /// iPhone's stack: the open project, then its files.
  @State private var path = NavigationPath()
  /// The open project's session, for the sidebar's activity card and its Build, Test and Stop.
  @State private var shown = ShownProject()
  @Environment(\.kitIdiom) private var idiom

  private var projects: [RemoteProject] { RemoteProjects.all(vault: vault) }

  var body: some View {
    Group {
      // iPhone with nothing to list: the welcome is the first screen (unless there are accounts to pick from).
      if idiom == .phone, projects.isEmpty, vaults.accounts.isEmpty {
        // With no status bar under a sidebar, the welcome leads to Privacy: iCloud off is one reason for no projects.
        ProjectsWelcome(projects: [], selection: $selection, showsPrivacy: true)
      } else if idiom == .phone {
        stack
      } else {
        split
      }
    }
    .environment(shown)
    .task {
      #if DEBUG
        if let id = DebugLaunch.selected(in: projects) { selection = id }
      #endif
    }
  }

  private var sidebar: some View {
    ProjectsSidebar(projects: projects, selection: $selection, columnVisibility: $columnVisibility)
  }

  /// iPhone: one stack, the list at its root and the picked project pushed onto it, so back always closes the
  /// project. (A collapsed split view reports its sidebar column whenever the detail's own stack pops, and value
  /// links don't push under a destination pushed by `navigationDestination(item:)`.)
  private var stack: some View {
    NavigationStack(path: $path) {
      sidebar
        .navigationDestination(for: OpenProject.self) { open in
          if let project = projects.first(where: { $0.id == open.id }) {
            ProjectScreen(project: project, vault: vault).id(project.id)
          }
        }
    }
    .onChange(of: selection) { _, selection in
      guard let selection else { return }
      path = NavigationPath([OpenProject(id: selection)])
    }
    // Back on the root list: no row stays picked (tapping it again opens it again).
    .onChange(of: path.count) { _, count in
      if count == 0 { selection = nil }
    }
  }

  private var split: some View {
    NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
      sidebar
        .toolbar(removing: .sidebarToggle)
        .kitSidebarColumn()
    } detail: {
      NavigationStack {
        if let project = projects.first(where: { $0.id == selection }) {
          ProjectScreen(project: project, vault: vault).id(project.id)
        } else {
          ProjectsWelcome(projects: projects, selection: $selection)
        }
      }
      .kitSidebarToggle(columnVisibility: $columnVisibility)
    }
    .onChange(of: selection) { _, selection in
      if selection != nil { compactColumn = .detail }
    }
  }
}

/// The project iPhone's stack shows.
struct OpenProject: Hashable {
  let id: RemoteProject.ID
}

/// The main screen while no project is open: the kit's welcome, its list the projects on the user's devices (a tap
/// opens one), or how to get some while there are none.
struct ProjectsWelcome: View {
  let projects: [RemoteProject]
  @Binding var selection: RemoteProject.ID?
  /// The Privacy action (iCloud), for iPhone's first screen, which has no sidebar status bar to hold it.
  var showsPrivacy = false
  @State private var privacyShown = false

  var body: some View {
    KitWelcome(
      emptyTitle: "No Projects on Your Devices",
      emptyMessage:
        "Code runs Build, Test and Clean on your Macs. In the Vault app on a Mac, turn on SSH from your devices and allow this device, or connect the Mac to a Hub; then open a project in Code there: it shows up here."
    ) {
      if showsPrivacy {
        WelcomeAction("Privacy", detail: "iCloud on this device", systemImage: "hand.raised") {
          privacyShown = true
        }
      }
    } recents: {
      ForEach(projects) { project in
        RecentItem(
          project.name, subtitle: project.targets.map(\.name).joined(separator: ", "),
          // Its own id: the devices are the same for most projects, and the list opens by id.
          imageData: project.icon, id: project.id
        ) { selection = project.id }
      }
    }
    .listTitle("On Your Devices")
    .kitPane(.content)
    .modifier(PrivacySheet(isPresented: $privacyShown))
  }
}

/// Privacy: the vault's iCloud switch, in the kit's sheet.
struct PrivacySheet: ViewModifier {
  @Binding var isPresented: Bool

  func body(content: Content) -> some View {
    content.kitSheet(isPresented: $isPresented) {
      KitSheet(title: "Privacy", systemImage: "hand.raised", hue: .blue, onClose: { isPresented = false }) {
        VaultICloudCard()
      }
    }
  }
}

/// The projects as the kit's sidebar: one card of the vault's projects that have a folder on another device, each
/// on its icon (or initial) with the devices that have it; search filters them, and the bar says how many devices
/// Code can reach, through the user's Hubs or over SSH. With none, it says how to get some.
///
/// The last projects opened lead in a Recent card. Beside an open project (iPad, an unfolded iPhone), the activity
/// card says what it is doing on its device and the bottom bar has its Build, Test and Stop; iPhone's list shows
/// while no project is open, so it has neither.
struct ProjectsSidebar: View {
  let projects: [RemoteProject]
  @Binding var selection: RemoteProject.ID?
  @Binding var columnVisibility: NavigationSplitViewVisibility
  @State private var search = ""
  @State private var showsPrivacy = false
  /// The ids of the last projects opened here, newest first.
  @State private var recents = KitRecents(key: "recentProjects", limit: 3)
  @Environment(ShownProject.self) private var shownProject
  @Environment(\.kitIdiom) private var idiom

  private var shown: [RemoteProject] {
    search.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
  }

  /// The devices the projects are on.
  private var deviceCount: Int { Set(projects.flatMap { $0.targets.map(\.name) }).count }

  /// The last projects opened that are still on a device Code can reach.
  private var recent: [RemoteProject] {
    recents.ids.compactMap { id in projects.first { $0.id == id } }
  }

  /// The session of the project shown beside the sidebar.
  private var session: ProjectSession? {
    guard idiom != .phone, let session = shownProject.session, session.project.id == selection else { return nil }
    return session
  }

  var body: some View {
    Group {
      // iPhone's list has no project beside it to build: no buttons, and no empty card for them in the bar.
      if idiom == .phone {
        sidebar { EmptyView() }
      } else {
        sidebar { SidebarActionButtons(controller: session?.controller) }
      }
    }
    .onChange(of: selection) { _, id in
      if let id { recents.note(id) }
    }
    // A project that left the vault, or whose devices did, leaves Recent. Not while the list is empty: the vault may
    // not have loaded yet.
    .onChange(of: projects.map(\.id), initial: true) { _, ids in
      if !ids.isEmpty { recents.keep { ids.contains($0) } }
    }
  }

  private func row(_ project: RemoteProject) -> some View {
    // iPhone: a row pushes its project.
    SidebarRow(value: project.id, project.name, subtitle: project.targets.map(\.name).joined(separator: ", ")) {
      ProjectTile(project: project)
    }
    .pushes()
  }

  private func sidebar<BottomBar: View>(@ViewBuilder bottomBar: () -> BottomBar) -> some View {
    KitSidebar(
      selection: $selection, searchText: $search, searchPrompt: "Search Projects", columnVisibility: $columnVisibility
    ) {
      VaultAccountPicker(
        meta: String(localized: "\(projects.count) projects"))
      if search.isEmpty, !recent.isEmpty {
        KitSection("Recent", systemImage: "clock", hue: .gray) {
          ForEach(recent) { row($0) }
        }
      }
      KitSection(
        "Projects",
        meta: projects.isEmpty
          ? [String(localized: "None yet")]
          : [
            String(localized: "\(projects.count) projects"),
            String(localized: "on your devices"),
          ],
        systemImage: "folder", hue: .orange
      ) {
        ForEach(shown) { row($0) }
        // None yet (on iPad the welcome beside it says how to get some): the one step there is on this device, as
        // iCloud off is a reason for none.
        if projects.isEmpty {
          SectionEmptyActions("Projects on your other devices appear here.") {
            Button("Privacy: iCloud on This Device", systemImage: "hand.raised") { showsPrivacy = true }
          }
        }
      }
      // None matches the search.
      .emptyState("Nothing matches “\(search)”.", systemImage: "magnifyingglass")
      // Many projects: the card's title stays in view while they scroll past.
      .kitSticky()
    } bottomBar: {
      bottomBar()
    }
    // What the open project is doing on its device; a run's line shows its log or its issues.
    .activity(session?.sidebarActivity { shownProject.requestedPane = $0 } ?? [])
    .status {
      HStack(spacing: 6) {
        StatusDot(hue: deviceCount > 0 ? .green : .gray)
        Text(deviceCount == 0 ? "No devices" : "\(deviceCount) devices")
        Spacer(minLength: 0)
        // The kit's icon button: a kit button style sets its own label style, so `.labelStyle(.iconOnly)` around
        // `.kitPlain` still showed the title ("Priva…").
        Button("Privacy", systemImage: "hand.raised") { showsPrivacy = true }
          .buttonStyle(.kitIcon)
      }
    }
    .modifier(PrivacySheet(isPresented: $showsPrivacy))
    .navigationTitle("Code")
  }
}

/// A project's icon from the vault, or its initial on a tile in a colour picked from its name.
struct ProjectTile: View {
  let project: RemoteProject
  var size: CGFloat = 32

  var body: some View {
    Avatar(name: project.name, imageData: project.icon, kind: .thing, size: size)
  }
}
