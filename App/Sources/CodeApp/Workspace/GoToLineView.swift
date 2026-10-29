import CodeKit
import ComponentKit
import SwiftUI

/// ⌘L: jump to "line" or "line:column" in the current file, in the kit's palette.
struct GoToLineView: View {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  @State private var text = ""

  var body: some View {
    KitPalette(
      query: $text, prompt: "Line number, optionally followed by :column",
      hints: [PaletteHint(["↩"], "Go"), PaletteHint(["esc"], "Close")],
      dismiss: { model.isGoToLinePresented = false }
    ) {
      PaletteGroup(
        workspace.selectedDocument?.name ?? "Go to Line", meta: ["\(lineCount) lines"],
        systemImage: "arrow.right.to.line"
      ) {
        if let target {
          PaletteItem(
            target.column > 1 ? "Line \(target.line), column \(target.column)" : "Line \(target.line)",
            id: "go", systemImage: "arrow.right.to.line", returnLabel: "Go", action: go)
        }
      }
    }
  }

  private var lineCount: Int { workspace.selectedDocument?.textView?.lineCount ?? 1 }

  private var target: (line: Int, column: Int)? {
    let parts = text.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard let line = parts.first else { return nil }
    return (min(max(line, 1), lineCount), parts.count > 1 ? max(parts[1], 1) : 1)
  }

  private func go() {
    model.isGoToLinePresented = false
    guard let target, let document = workspace.selectedDocument else { return }
    document.goTo(line: target.line, column: target.column)
  }
}
