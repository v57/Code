import CodeKit
import SwiftUI

/// The selected document's editor, or what to show instead (nothing open,
/// still loading, a binary or oversized file).
struct EditorArea: View {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  private let settings = EditorConfigurationReader()

  var body: some View {
    Group {
      if let document = workspace.selectedDocument {
        content(for: document)
      } else {
        emptyState
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder private func content(for document: TextDocument) -> some View {
    switch document.content {
    case .loading:
      ProgressView()
    case .text:
      CodeEditorView(
        document: document, revision: document.revision, configuration: settings.configuration
      ) { selection in
        model.selection = selection
      }
    case .binary:
      unavailable(
        "Binary File", systemImage: "doc.questionmark",
        description: "“\(document.name)” isn’t a text file.", document: document)
    case .tooLarge(let size):
      unavailable(
        "File Too Large", systemImage: "doc.badge.ellipsis",
        description:
          "“\(document.name)” is \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).",
        document: document)
    case .unreadable(let message):
      unavailable(
        "Can’t Open “\(document.name)”", systemImage: "exclamationmark.triangle",
        description: message, document: document)
    }
  }

  private func unavailable(
    _ title: String, systemImage: String, description: String, document: TextDocument
  ) -> some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      Text(description)
    } actions: {
      Button("Open with Default App") { NSWorkspace.shared.open(document.url) }
    }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label(workspace.name, systemImage: "chevron.left.forwardslash.chevron.right")
    } description: {
      VStack(spacing: 6) {
        Text("Select a file in the sidebar, or:")
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
          GridRow {
            Text("Open Quickly")
            Text("⇧⌘O").foregroundStyle(.secondary)
          }
          GridRow {
            Text("New File")
            Text("⌘N").foregroundStyle(.secondary)
          }
          GridRow {
            Text("Open Folder")
            Text("⌘O").foregroundStyle(.secondary)
          }
        }
        .font(.callout.monospacedDigit())
      }
    }
  }
}
