import CodeKit
import ComponentKit
import SwiftUI

/// The selected file's path under the tabs, as in Xcode's jump bar: back and forward, then the kit's path bar of the
/// project, its folders and the file, each with its icon, on a card as wide as they are. A click on a folder shows it
/// in the sidebar.
struct JumpBar: View {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  var body: some View {
    let services = model.services
    HStack(spacing: 2) {
      Button("Go Back", systemImage: "chevron.left") { services.goBack() }
        .help("Go Back (⌃⌘←)")
        .disabled(!services.canGoBack)
      Button("Go Forward", systemImage: "chevron.right") { services.goForward() }
        .help("Go Forward (⌃⌘→)")
        .disabled(!services.canGoForward)
      if let document = workspace.selectedDocument {
        KitPathBar(components: segments(for: document.url))
          .padding(.leading, 4)
      }
    }
    .buttonStyle(.kitIcon)
    .padding(.horizontal, 4)
    .frame(height: 32)
    .kitSurface(.card)
    .kitBar()
    .frame(maxWidth: .infinity, alignment: .leading)
    // The tab strip above keeps the gutter under itself.
    .padding(.horizontal, KitMetrics.gutter)
    .padding(.bottom, KitMetrics.gutter / 2)
  }

  /// The project, each folder down to the file, and the file.
  private func segments(for file: URL) -> [KitPathItem] {
    var items = [KitPathItem(workspace.name, systemImage: "folder", hue: .red)]
    var url = workspace.root
    let components = workspace.tree.relativePath(of: file).split(separator: "/")
    for (index, component) in components.enumerated() {
      url = url.appendingPathComponent(String(component))
      let isFile = index == components.count - 1
      let target = url
      items.append(
        KitPathItem(
          FileName.display(url, showExtensions: showExtensions),
          icon: { FileIconView(for: target, isDirectory: !isFile, size: 14) },
          action: isFile
            ? nil
            : {
              workspace.tree.reveal(target)
              model.sidebarSelection = target
            }))
    }
    return items
  }
}
