import CodeKit
import SwiftUI

/// The selected document's editor, or what to show instead (nothing open,
/// still loading, a binary or oversized file).
struct EditorArea: View {
  /// The document of a window of its own (Open in New Window), shown
  /// instead of the selected tab.
  var detachedDocument: TextDocument?
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  private let settings = EditorConfigurationReader()
  private let serviceSettings = ServiceSettingsReader()

  var body: some View {
    Group {
      if let document = detachedDocument ?? workspace.selectedDocument {
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
      let services = serviceSettings.settings
      CodeEditorView(
        document: document, revision: document.revision, configuration: settings.configuration,
        services: model.services, marks: marks(for: document),
        features: EditorFeatures(
          showsMinimap: services.showsMinimap, showsIssueMessages: services.showsIssueMessages,
          breakpointsEnabled: services.breakpointsEnabled,
          suggestsCompletions: services.suggestsCompletions)
      ) { selection in
        // The status bar shows the project window's editor.
        if detachedDocument == nil { model.selection = selection }
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

  /// Changes when the editor's issues, breakpoints or debugger line do.
  private func marks(for document: TextDocument) -> Int {
    var hasher = Hasher()
    let services = model.services
    for annotation in services.annotations(for: document.url) {
      hasher.combine(annotation.line)
      hasher.combine(annotation.message)
    }
    hasher.combine(services.breakpoints(for: document.url))
    hasher.combine(services.breakpointsActive)
    hasher.combine(services.executionLocation?.url)
    hasher.combine(services.executionLocation?.line)
    return hasher.finalize()
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
