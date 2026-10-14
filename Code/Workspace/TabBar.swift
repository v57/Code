import CodeKit
import SwiftUI

/// Open files as tabs, styled after Xcode's tab bar: a rounded track under
/// the toolbar with the selected tab raised in it. Tabs keep their width
/// (sized to the name) instead of stretching to fill the bar. The preview
/// tab's name is italic; on hover a tab shows its close button at the left,
/// where a dot marks edits waiting to be saved.
struct TabBar: View {
  @Environment(Workspace.self) private var workspace
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  /// Xcode's metrics: an 8 pt inset from the editor's sides, a 28 pt track.
  static let height: CGFloat = 28

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 2) {
          ForEach(workspace.tabs) { document in
            TabItem(document: document, title: title(for: document))
              .id(document.id)
          }
        }
        .padding(1)
      }
      .onChange(of: workspace.selectedTabID) { _, id in
        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
      }
    }
    .frame(height: Self.height)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Capsule().fill(Color.primary.opacity(0.07)))
    .clipShape(Capsule())
    .padding(.horizontal, 8)
    .padding(.top, 2)
  }

  /// The display name, plus its folder when another tab has the same name.
  private func title(for document: TextDocument) -> String {
    let name = FileName.display(document.url, showExtensions: showExtensions)
    let twins = workspace.tabs.filter {
      FileName.display($0.url, showExtensions: showExtensions) == name
    }
    guard twins.count > 1 else { return name }
    return name + " — " + document.url.deletingLastPathComponent().lastPathComponent
  }
}

private struct TabItem: View {
  let document: TextDocument
  let title: String
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  @State private var isHovering = false

  private var isSelected: Bool { workspace.selectedTabID == document.id }
  private var isUnsaved: Bool { document.saveState != .saved }

  var body: some View {
    HStack(spacing: 5) {
      FileIconView(for: document.url, size: 14)
      Text(title)
        .italic(workspace.isPreview(document))
        .strikethrough(document.isMissing)
        .lineLimit(1)
    }
    .font(.system(size: 13))
    .foregroundStyle(isSelected ? .primary : .secondary)
    .padding(.horizontal, 30)
    .frame(minWidth: 120)
    .frame(height: TabBar.height - 2)
    .overlay(alignment: .leading) { closeButton.padding(.leading, 6) }
    .background {
      if isSelected {
        Capsule()
          .fill(Color.primary.opacity(0.12))
          .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
      } else if isHovering {
        Capsule().fill(Color.primary.opacity(0.04))
      }
    }
    .contentShape(Capsule())
    .onHover { isHovering = $0 }
    // One gesture: a double-tap gesture next to it would hold every click
    // (and the close button's) until the double-click interval passed.
    .onTapGesture {
      workspace.selectedTabID = document.id
      if NSApp.currentEvent?.clickCount == 2 { workspace.keep(document) }
    }
    .help(workspace.tree.relativePath(of: document.url))
    .contextMenu {
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
      Button("Copy Path") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(document.url.path, forType: .string)
      }
    }
    .draggable(document.url.absoluteString)
    .dropDestination(for: String.self) { items, _ in
      guard let item = items.first, let url = URL(string: item),
        let dragged = workspace.document(for: url),
        let target = workspace.tabs.firstIndex(where: { $0.id == document.id })
      else { return false }
      workspace.move(dragged, to: target)
      return true
    }
  }

  @ViewBuilder private var closeButton: some View {
    if isHovering {
      Button {
        workspace.close(document)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .frame(width: 16, height: 16)
          .background(Circle().fill(Color.primary.opacity(0.1)))
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Close Tab (⌘W)")
    } else if isUnsaved {
      Circle()
        .fill(Color.secondary)
        .frame(width: 6, height: 6)
        .frame(width: 16, height: 16)
        .help("Saving…")
    }
  }
}
