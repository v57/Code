import CodeKit
import SwiftUI

/// The selected file's path under the tabs, as in Xcode's jump bar: back and
/// forward, then the project, its folders and the file, each with its icon.
/// A click on a segment shows it in the sidebar.
struct JumpBar: View {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  static let height: CGFloat = 36

  var body: some View {
    HStack(spacing: 4) {
      historyButtons
      if let document = workspace.selectedDocument {
        ForEach(Array(segments(for: document.url).enumerated()), id: \.offset) { index, url in
          if index > 0 {
            Image(systemName: "chevron.compact.right")
              .font(.system(size: 13, weight: .semibold))
              .foregroundStyle(.tertiary)
          }
          segment(url, isProject: index == 0, isFile: url == document.url)
        }
        if document.isMissing {
          Text("(deleted)").foregroundStyle(.tertiary)
        }
      }
      Spacer(minLength: 0)
    }
    .font(.system(size: 13))
    .lineLimit(1)
    .padding(.horizontal, 14)
    .frame(height: Self.height)
  }

  private var historyButtons: some View {
    let services = model.services
    return HStack(spacing: 2) {
      Button { services.goBack() } label: {
        Image(systemName: "chevron.left").frame(width: 20, height: 20)
      }
      .help("Go Back (⌃⌘←)")
      .disabled(!services.canGoBack)
      Button { services.goForward() } label: {
        Image(systemName: "chevron.right").frame(width: 20, height: 20)
      }
      .help("Go Forward (⌃⌘→)")
      .disabled(!services.canGoForward)
    }
    .buttonStyle(.borderless)
    .font(.system(size: 13, weight: .medium))
    .padding(.trailing, 6)
  }

  /// The root, each folder down to the file, and the file.
  private func segments(for file: URL) -> [URL] {
    var urls = [workspace.root]
    var url = workspace.root
    for component in workspace.tree.relativePath(of: file).split(separator: "/") {
      url = url.appendingPathComponent(String(component))
      urls.append(url)
    }
    return urls
  }

  private func segment(_ url: URL, isProject: Bool, isFile: Bool) -> some View {
    Button {
      if !isProject {
        workspace.tree.reveal(url)
        model.sidebarSelection = url
      }
    } label: {
      HStack(spacing: 4) {
        if isProject {
          Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .frame(width: 16, height: 16)
        } else {
          FileIconView(for: url, isDirectory: !isFile, size: 14)
        }
        Text(isProject ? workspace.name : FileName.display(url, showExtensions: showExtensions))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
  }
}
