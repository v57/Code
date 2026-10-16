import CodeKit
import ComponentKit
import SwiftUI

/// Open files as the kit's tab strip: the selected tab raised, a close button on the selected and hovered tab, a dot
/// on one whose edits are still being saved. A double click keeps the preview tab open; the tab actions (Close
/// Others, Keep Open…) are in the File menu.
struct TabBar: View {
  @Environment(Workspace.self) private var workspace
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  var body: some View {
    KitTabStrip(
      tabs: workspace.tabs.map(tab), selection: selection,
      onClose: { id in
        if let document = workspace.tabs.first(where: { $0.id == id }) { workspace.close(document) }
      })
  }

  private func tab(_ document: TextDocument) -> KitTab<TextDocument.ID> {
    let icon = FileIcon(for: document.url)
    return KitTab(
      id: document.id, title: title(for: document), systemImage: icon.kitSymbol, hue: icon.kitHue,
      isEdited: document.saveState != .saved)
  }

  /// Selects a tab; a second click on it (a double click) keeps a preview tab open.
  private var selection: Binding<TextDocument.ID?> {
    Binding(
      get: { workspace.selectedTabID },
      set: { id in
        workspace.selectedTabID = id
        if NSApp.currentEvent?.clickCount == 2, let document = workspace.tabs.first(where: { $0.id == id }) {
          workspace.keep(document)
        }
      })
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
