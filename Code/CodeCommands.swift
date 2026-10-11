import AppKit
import CodeKit
import SwiftUI

/// The menu bar: File (folders, files, tabs), Go, Editor, and View
/// additions. Window-specific commands act on the key window's workspace.
struct CodeCommands: Commands {
  @FocusedValue(\.windowModel) private var model
  @Environment(\.openWindow) private var openWindow
  @AppStorage(EditorSettings.fontSize) private var fontSize = EditorSettings.defaultFontSize
  @AppStorage(EditorSettings.wrapLines) private var wrapLines = true
  @AppStorage(EditorSettings.showLineNumbers) private var showLineNumbers = true

  private var workspace: Workspace? { model?.workspace }

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New File…") { model.map { $0.ask(.newFile(in: $0.targetFolder)) } }
        .keyboardShortcut("n")
        .disabled(model == nil)
      Button("New Folder…") { model.map { $0.ask(.newFolder(in: $0.targetFolder)) } }
        .disabled(model == nil)
      Button("New Window") { openWindow(id: WorkspaceWindow.id) }
        .keyboardShortcut("n", modifiers: [.command, .shift])
      Divider()
      Button("Open Folder…") { AppState.shared.chooseFolder() }
        .keyboardShortcut("o")
      RecentMenu()
    }

    CommandGroup(replacing: .saveItem) {
      Button("Save") { workspace?.selectedDocument?.save() }
        .keyboardShortcut("s")
        .disabled(workspace?.selectedDocument == nil)
      Button("Save All") { workspace?.saveAll() }
        .keyboardShortcut("s", modifiers: [.command, .option])
        .disabled(workspace == nil)
      Divider()
      Button("Close Tab") { closeTab() }
        .keyboardShortcut("w")
      Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
        .keyboardShortcut("w", modifiers: [.command, .shift])
    }

    CommandMenu("Go") {
      Button("Open Quickly…") { model?.isQuickOpenPresented = true }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(model == nil)
      Button("Go to Line…") { model?.isGoToLinePresented = true }
        .keyboardShortcut("l")
        .disabled(workspace?.selectedDocument?.content != .text)
      Divider()
      Button("Next Tab") { workspace?.selectNextTab(offset: 1) }
        .keyboardShortcut("]", modifiers: [.command, .shift])
        .disabled((workspace?.tabs.count ?? 0) < 2)
      Button("Previous Tab") { workspace?.selectNextTab(offset: -1) }
        .keyboardShortcut("[", modifiers: [.command, .shift])
        .disabled((workspace?.tabs.count ?? 0) < 2)
      Divider()
      Button("Reveal in Sidebar") {
        guard let model, let url = model.workspace.selectedDocument?.url else { return }
        model.workspace.tree.reveal(url)
        model.sidebarSelection = url
      }
      .keyboardShortcut("j", modifiers: [.command, .shift])
      .disabled(workspace?.selectedDocument == nil)
    }

    CommandMenu("Editor") {
      Button("Toggle Comment") { send(#selector(CodeTextView.toggleComment(_:))) }
        .keyboardShortcut("/")
      Button("Indent") { send(#selector(CodeTextView.shiftRight(_:))) }
        .keyboardShortcut("]")
      Button("Outdent") { send(#selector(CodeTextView.shiftLeft(_:))) }
        .keyboardShortcut("[")
    }

    CommandGroup(after: .toolbar) {
      // Xcode's ⌘0 shows and hides the navigator.
      Button(model?.isNavigatorVisible == false ? "Show Navigator" : "Hide Navigator") {
        model?.isNavigatorVisible.toggle()
      }
      .keyboardShortcut("0")
      .disabled(model == nil)
      Divider()
      Toggle("Wrap Lines", isOn: $wrapLines)
        .keyboardShortcut("z", modifiers: [.option])
      Toggle("Line Numbers", isOn: $showLineNumbers)
      Divider()
      Button("Zoom In") { zoom(by: 1) }
        .keyboardShortcut("+")
      Button("Zoom Out") { zoom(by: -1) }
        .keyboardShortcut("-")
      Button("Actual Size") { fontSize = EditorSettings.defaultFontSize }
        .keyboardShortcut("0", modifiers: [.command, .control])
      Divider()
    }

    TextEditingCommands()
    SidebarCommands()
  }

  /// ⌘W closes the current tab, or the window when no tab is open, as in
  /// VS Code and Zed.
  private func closeTab() {
    if let workspace, let document = workspace.selectedDocument {
      workspace.close(document)
    } else {
      NSApp.keyWindow?.performClose(nil)
    }
  }

  private func zoom(by step: Double) {
    let range = EditorConfiguration.fontSizes
    fontSize = min(max(fontSize + step, Double(range.lowerBound)), Double(range.upperBound))
  }

  /// Sends an editor action to the focused text view.
  private func send(_ action: Selector) {
    NSApp.sendAction(action, to: nil, from: nil)
  }
}

private struct RecentMenu: View {
  var body: some View {
    let recents = AppState.shared.recents
    Menu("Open Recent") {
      ForEach(recents.existing, id: \.self) { folder in
        Button(folder.abbreviatedPath) { AppState.shared.open(folder) }
      }
      Divider()
      Button("Clear Menu") { recents.clear() }
        .disabled(recents.folders.isEmpty)
    }
  }
}
