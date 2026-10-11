import CodeKit
import SwiftUI

/// ⌘L: jump to "line" or "line:column" in the current file.
struct GoToLineView: View {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  @State private var text = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    Palette {
      TextField(prompt, text: $text)
        .textFieldStyle(.plain)
        .font(.title3)
        .focused($isFocused)
        .padding(10)
        .onSubmit(go)
        .onKeyPress(.escape) {
          model.isGoToLinePresented = false
          return .handled
        }
    }
    .onAppear { isFocused = true }
  }

  private var prompt: String {
    let lines = workspace.selectedDocument?.textView?.lineIndex.count ?? 1
    return "Line number (1–\(lines)), optionally followed by :column"
  }

  private func go() {
    model.isGoToLinePresented = false
    let parts = text.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard let line = parts.first, let document = workspace.selectedDocument else { return }
    document.goTo(line: line, column: parts.count > 1 ? parts[1] : 1)
  }
}
