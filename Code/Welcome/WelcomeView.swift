import SwiftUI
import UniformTypeIdentifiers

/// Shown in a window without a project: open a folder or a recent project,
/// or drop a folder on the window.
struct WelcomeView: View {
  let open: (URL) -> Void
  @State private var isDropTargeted = false
  private var recents: RecentProjects { AppState.shared.recents }

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 14) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 96, height: 96)
        Text("Code")
          .font(.largeTitle.weight(.semibold))
        Text("Open a folder to start editing.")
          .foregroundStyle(.secondary)
        Button {
          chooseFolder()
        } label: {
          Label("Open Folder…", systemImage: "folder")
            .frame(minWidth: 160)
        }
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .padding(.top, 8)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if !recents.existing.isEmpty {
        Divider()
        recentList
          .frame(width: 300)
      }
    }
    .navigationTitle("Welcome to Code")
    .overlay {
      if isDropTargeted {
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(Color.accentColor, lineWidth: 3)
          .padding(6)
          .allowsHitTesting(false)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard let url = urls.first(where: \.isFileURL) else { return false }
      open(url)
      return true
    } isTargeted: { isDropTargeted = $0 }
  }

  private var recentList: some View {
    List {
      Section("Recent") {
        ForEach(recents.existing, id: \.self) { folder in
          Button {
            open(folder)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(folder.lastPathComponent)
              Text(folder.deletingLastPathComponent().abbreviatedPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            Button("Remove from Recents") { recents.remove(folder) }
          }
        }
      }
    }
    .listStyle(.sidebar)
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Open"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    open(url)
  }
}
