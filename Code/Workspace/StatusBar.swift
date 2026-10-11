import CodeKit
import SwiftUI

/// Xcode's editor bottom bar: a failed save or file operation on the left,
/// the caret position on the right.
struct StatusBar: View {
  /// Shared with the sidebar's bottom bar so the two line up, as in Xcode.
  static let height: CGFloat = 30

  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model

  var body: some View {
    HStack(spacing: 14) {
      leading
      Spacer(minLength: 8)
      if let document = workspace.selectedDocument, document.content == .text {
        Button(position) { model.isGoToLinePresented = true }
          .help("Go to Line (⌘L)")
      }
    }
    .buttonStyle(.plain)
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .padding(.horizontal, 14)
    .frame(height: StatusBar.height)
    .background(.bar)
  }

  @ViewBuilder private var leading: some View {
    if let message = workspace.statusMessage {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .onTapGesture { workspace.statusMessage = nil }
    } else if let document = workspace.selectedDocument {
      switch document.saveState {
      case .saved, .unsaved: EmptyView()
      case .failed(let message):
        Label("Couldn’t save: \(message)", systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }
    }
    if workspace.index.isIndexing {
      ProgressView().controlSize(.mini)
    }
  }

  private var position: String {
    let selection = model.selection
    var text = "Line: \(selection.line)  Col: \(selection.column)"
    if selection.length > 0 {
      text += selection.lineCount > 1
        ? "  (\(selection.length) characters, \(selection.lineCount) lines)"
        : "  (\(selection.length) characters)"
    }
    return text
  }
}
