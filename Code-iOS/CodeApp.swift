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
    }
  }
}

struct ProjectsView: View {
  @State private var vault = Vault.shared
  @State private var selection: RemoteProject.ID?

  private var projects: [RemoteProject] { RemoteProjects.all(vault: vault) }

  var body: some View {
    NavigationSplitView {
      List(projects, selection: $selection) { project in
        NavigationLink(value: project.id) { ProjectRow(project: project) }
      }
      .navigationTitle("Projects")
      .overlay {
        if projects.isEmpty {
          ContentUnavailableView {
            Label("No Projects on Your Devices", systemImage: "point.3.connected.trianglepath.dotted")
          } description: {
            Text(
              "Code runs Build, Test and Clean on your Macs. Connect them to a Hub in the Vault app, and open a project in Code on a Mac: it shows up here."
            )
          }
        }
      }
    } detail: {
      if let project = projects.first(where: { $0.id == selection }) {
        NavigationStack { ProjectScreen(project: project) }.id(project.id)
      } else {
        ContentUnavailableView("Choose a Project", systemImage: "folder")
      }
    }
    .task {
      #if DEBUG
        if let id = DebugLaunch.project?.id { selection = id }
      #endif
    }
  }
}

struct ProjectRow: View {
  var project: RemoteProject

  var body: some View {
    HStack(spacing: 12) {
      Group {
        if let icon = project.icon.flatMap(Image.init(data:)) {
          icon.resizable()
        } else {
          Image(systemName: "folder.fill").resizable().scaledToFit().padding(6).foregroundStyle(.secondary)
        }
      }
      .frame(width: 32, height: 32)
      .clipShape(RoundedRectangle(cornerRadius: 7))
      VStack(alignment: .leading, spacing: 2) {
        Text(project.name)
        Text(project.targets.map(\.name).joined(separator: ", "))
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
    }
  }
}
