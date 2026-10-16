import CodeKit
import ComponentKit
import SwiftUI

extension View {
  /// The editor's status bar, the kit's card under the editor: a failed save or file operation, indexing and the
  /// language server's work lead (in the live icon), the caret position trails and opens Go to Line.
  func codeStatusBar() -> some View {
    modifier(CodeStatusBar())
  }
}

private struct CodeStatusBar: ViewModifier {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model

  func body(content: Content) -> some View {
    content.kitStatusBar(systemImage: icon.systemImage, hue: icon.hue, status: icon.status) {
      leading
      Spacer(minLength: 8)
      if let document = workspace.selectedDocument, document.isSaving {
        Text("Formatting…")
      }
      if let document = workspace.selectedDocument, document.content == .text {
        Button(position) { model.isGoToLinePresented = true }
          .buttonStyle(.plain)
          .help("Go to Line (⌘L)")
      }
    }
  }

  /// What the status bar's message is about; no icon while there is none.
  private var icon: (systemImage: String?, hue: Hue, status: WorkStatus) {
    if model.services.statusMessage != nil { return ("info", .accent, .idle) }
    if workspace.statusMessage != nil { return ("exclamationmark.triangle", .orange, .idle) }
    if case .failed? = workspace.selectedDocument?.saveState { return ("square.and.arrow.down", .red, .failed) }
    if model.services.languageServers.activity != nil { return ("curlybraces", .accent, .working) }
    if workspace.index.isIndexing { return ("doc.text.magnifyingglass", .accent, .working) }
    return (nil, .accent, .idle)
  }

  @ViewBuilder private var leading: some View {
    if let message = model.services.statusMessage {
      Text(message)
    } else if let message = workspace.statusMessage {
      Text(message)
        .foregroundStyle(Hue.orange.text)
        .onTapGesture { workspace.statusMessage = nil }
    } else if let document = workspace.selectedDocument, case .failed(let message) = document.saveState {
      Text("Couldn’t save: \(message)")
        .foregroundStyle(Hue.red.text)
    } else if let activity = model.services.languageServers.activity {
      Text(activity).truncationMode(.middle).help(activity)
    } else if workspace.index.isIndexing {
      Text("Indexing…")
    }
  }

  private var position: String {
    let selection = model.selection
    var text = "Line: \(selection.line)  Col: \(selection.column)"
    if selection.length > 0 {
      text +=
        selection.lineCount > 1
        ? "  (\(selection.length) characters, \(selection.lineCount) lines)"
        : "  (\(selection.length) characters)"
    }
    return text
  }
}
