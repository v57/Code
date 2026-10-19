import CodeKit
import ComponentKit
import SwiftUI

/// Open files as the kit's tab strip, floating over the editor: each with its file icon, the selected tab raised, a
/// close button on the selected and hovered tab, a dot on one whose edits are still being saved, the preview tab's
/// name in italics. A double click keeps the preview tab open; tabs reorder by dragging; a tab's context menu has the tab actions (also
/// in the File menu).
struct TabBar: View {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  var body: some View {
    KitTabStrip(
      tabs: workspace.tabs.map(tab), selection: selectedTab,
      onClose: { id in
        if let document = document(id) { workspace.close(document) }
      },
      onMove: move
    )
    .onTabDoubleClick { id in
      if let document = document(id) { workspace.keep(document) }
    }
    .tabContextMenu { id in
      if let document = document(id) { menu(for: document) }
    }
  }

  private var selectedTab: Binding<TextDocument.ID?> {
    Binding(get: { workspace.selectedTabID }, set: { workspace.selectedTabID = $0 })
  }

  private func document(_ id: TextDocument.ID) -> TextDocument? {
    workspace.tabs.first { $0.id == id }
  }

  private func tab(_ document: TextDocument) -> KitTab<TextDocument.ID> {
    KitTab(
      id: document.id, title: title(for: document), isEdited: document.saveState != .saved,
      isPreview: workspace.isPreview(document)
    ) {
      FileIconView(for: document.url, size: 14)
    }
  }

  /// A drag between tabs (`.onMove`'s offsets: the destination counts the dragged tab still in place).
  private func move(_ offsets: IndexSet, _ destination: Int) {
    guard let from = offsets.first, workspace.tabs.indices.contains(from) else { return }
    workspace.move(workspace.tabs[from], to: destination > from ? destination - 1 : destination)
  }

  @ViewBuilder private func menu(for document: TextDocument) -> some View {
    Button("Close") { workspace.close(document) }
    Button("Close Others") { workspace.closeOthers(document) }
    Button("Close All") { workspace.closeAll() }
    if workspace.isPreview(document) {
      Button("Keep Open") { workspace.keep(document) }
    }
    Divider()
    Button("Open in New Window") { model.openInNewWindow(document) }
    Divider()
    Button("Reveal in Sidebar") {
      workspace.tree.reveal(document.url)
      model.sidebarSelection = document.url
    }
    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([document.url]) }
    Button("Copy Path") { KitPasteboard.copy(document.url.path) }
  }

  /// The display name, plus its folder when another tab has the same name.
  private func title(for document: TextDocument) -> String {
    let name = FileName.display(document.url, showExtensions: showExtensions)
    let twins = workspace.tabs.filter {
      FileName.display($0.url, showExtensions: showExtensions) == name
    }
    let title = twins.count > 1 ? name + " — " + document.url.deletingLastPathComponent().lastPathComponent : name
    return document.isMissing ? title + " (deleted)" : title
  }
}
