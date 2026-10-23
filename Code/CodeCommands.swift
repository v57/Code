#if os(macOS)
  import AppKit
#endif
import CodeKit
import SwiftUI

/// The menu bar: File (folders, files, tabs), Go, Editor, and View
/// additions. Window-specific commands act on the key window's workspace.
struct CodeCommands: Commands {
  @FocusedValue(\.windowModel) private var model
  @FocusedValue(\.detachedDocument) private var detachedDocument
  @Environment(\.openWindow) private var openWindow
  @AppStorage(EditorSettings.fontSize) private var fontSize = EditorSettings.defaultFontSize
  @AppStorage(EditorSettings.wrapLines) private var wrapLines = true
  @AppStorage(EditorSettings.showLineNumbers) private var showLineNumbers = true
  @AppStorage(EditorSettings.showsMinimap) private var showsMinimap = true
  @AppStorage(EditorSettings.actionsEnabled) private var actionsEnabled = true

  private var services: ProjectServices? { model?.services }
  private var actions: ActionController? { model?.services.actions }

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
      Button("Save") { (detachedDocument ?? workspace?.selectedDocument)?.save() }
        .keyboardShortcut("s")
        .disabled(detachedDocument == nil && workspace?.selectedDocument == nil)
      Button("Save All") { workspace?.saveAll() }
        .keyboardShortcut("s", modifiers: [.command, .option])
        .disabled(workspace == nil)
      Divider()
      Button("Open in New Window") {
        guard let model, let document = model.workspace.selectedDocument else { return }
        model.openInNewWindow(document)
      }
      .keyboardShortcut("d", modifiers: [.command, .shift])
      .disabled(workspace?.selectedDocument == nil)
      Button("Close Tab") { closeTab() }
        .keyboardShortcut("w")
      Button("Close Other Tabs") { workspace?.selectedDocument.map { workspace?.closeOthers($0) } }
        .keyboardShortcut("w", modifiers: [.command, .option])
        .disabled((workspace?.tabs.count ?? 0) < 2)
      Button("Close All Tabs") { workspace?.closeAll() }
        .disabled(workspace?.tabs.isEmpty != false)
      Button("Keep Tab Open") { workspace?.selectedDocument.map { workspace?.keep($0) } }
        .disabled(workspace?.selectedDocument.map { workspace?.isPreview($0) == true } != true)
      #if os(macOS)
        Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
          .keyboardShortcut("w", modifiers: [.command, .shift])
      #endif
    }

    CommandMenu("Go") {
      Button("Open Quickly…") {
        model?.quickOpenQuery = ""
        model?.isQuickOpenPresented = true
      }
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
      Divider()
      Button("Jump to Definition") {
        guard let services, let document = workspace?.selectedDocument,
          let textView = document.textView
        else { return }
        services.jumpToDefinition(in: document, at: textView.caretLocation)
      }
      .keyboardShortcut("j", modifiers: [.command, .control])
      .disabled(workspace?.selectedDocument?.textView == nil)
      Button("Show Quick Help") {
        guard let services, let document = workspace?.selectedDocument,
          let textView = document.textView
        else { return }
        services.showQuickHelp(in: document, at: textView.caretLocation)
      }
      .keyboardShortcut("/", modifiers: [.command, .control, .shift])
      .disabled(workspace?.selectedDocument?.textView == nil)
      Button("Go Back") { services?.goBack() }
        .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
        .disabled(services?.canGoBack != true)
      Button("Go Forward") { services?.goForward() }
        .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
        .disabled(services?.canGoForward != true)
    }

    CommandMenu("Product") {
      Button("Run") { model?.perform(.run) }
        .keyboardShortcut("r")
        .disabled(actions?.canPerform(.run) != true || !actionsEnabled)
      Button("Test") { model?.perform(.test) }
        .keyboardShortcut("u")
        .disabled(actions?.canPerform(.test) != true || !actionsEnabled)
      Button("Build") { model?.perform(.build) }
        .keyboardShortcut("b")
        .disabled(actions?.canPerform(.build) != true || !actionsEnabled)
      Button("Clean Build Folder") { model?.perform(.clean) }
        .keyboardShortcut("k", modifiers: [.command, .shift])
        .disabled(actions?.canPerform(.clean) != true || !actionsEnabled)
      Divider()
      Button("Install") { model?.perform(.install) }
        .disabled(actions?.canPerform(.install) != true || !actionsEnabled)
      Button("Export…") { model?.perform(.export) }
        .disabled(actions?.canPerform(.export) != true || !actionsEnabled)
      Button("Upload to App Store") { model?.perform(.upload) }
        .disabled(actions?.canPerform(.upload) != true || !actionsEnabled)
      Button("Notarization Settings…") { model?.notarizationSetup = NotarizationSetupRequest() }
        .disabled(model == nil || !actionsEnabled)
      Divider()
      Button("Stop") { actions?.stop() }
        .keyboardShortcut(".")
        .disabled(actions?.isRunning != true)
      Divider()
      Button("Refresh Schemes") { actions?.scan() }
        .disabled(actions == nil || !actionsEnabled)
      Button("Refresh Run Destinations") { actions?.refreshDestinations() }
        .disabled(actions == nil || !actionsEnabled)
    }

    CommandMenu("Debug") {
      let debugger = services?.debugger
      let isPaused: Bool = {
        if case .paused? = debugger?.state { return true }
        return false
      }()
      Button(isPaused ? "Continue" : "Pause") {
        isPaused ? debugger?.continueRunning() : debugger?.pause()
      }
      .keyboardShortcut("y", modifiers: [.command, .control])
      .disabled(debugger == nil)
      Button("Step Over") { debugger?.stepOver() }
        .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(Self.f6)!)), modifiers: [])
        .disabled(!isPaused)
      Button("Step Into") { debugger?.stepInto() }
        .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(Self.f7)!)), modifiers: [])
        .disabled(!isPaused)
      Button("Step Out") { debugger?.stepOut() }
        .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(Self.f8)!)), modifiers: [])
        .disabled(!isPaused)
      Divider()
      Button(services?.breakpointsActive == false ? "Activate Breakpoints" : "Deactivate Breakpoints") {
        services?.breakpointsActive.toggle()
      }
      .keyboardShortcut("y")
      .disabled(services == nil)
      Button("Add or Remove Breakpoint at Current Line") {
        guard let textView = workspace?.selectedDocument?.textView else { return }
        textView.toggleBreakpoint(atLine: textView.currentSelection.line - 1)
      }
      .keyboardShortcut("\\")
      .disabled(workspace?.selectedDocument?.textView == nil)
      Button("Delete All Breakpoints") { services?.removeAllBreakpoints() }
        .disabled(services?.hasBreakpoints != true)
    }

    #if os(macOS)
      CommandMenu("Editor") {
        Button("Toggle Comment") { send(#selector(CodeTextView.toggleComment(_:))) }
          .keyboardShortcut("/")
        Button("Indent") { send(#selector(CodeTextView.shiftRight(_:))) }
          .keyboardShortcut("]")
        Button("Outdent") { send(#selector(CodeTextView.shiftLeft(_:))) }
          .keyboardShortcut("[")
        Divider()
        Button("Show Completions") { send(#selector(NSTextView.complete(_:))) }
          .keyboardShortcut(.space, modifiers: [.control])
        Button("Select Next Placeholder") { send(#selector(CodeTextView.selectNextPlaceholder(_:))) }
          .keyboardShortcut("/", modifiers: [.control])
        Button("Select Previous Placeholder") { send(#selector(CodeTextView.selectPreviousPlaceholder(_:))) }
          .keyboardShortcut("/", modifiers: [.control, .shift])
      }
    #endif

    CommandGroup(after: .toolbar) {
      // Xcode's ⌘0 shows and hides the navigator.
      Button(model?.isNavigatorVisible == false ? "Show Navigator" : "Hide Navigator") {
        model.map { $0.setNavigatorVisible(!$0.isNavigatorVisible) }
      }
      .keyboardShortcut("0")
      .disabled(model == nil)
      // Xcode's navigator shortcuts: ⌘1 files, ⌘3 Find.
      Button("Show Project Navigator") {
        model?.setNavigatorVisible(true)
        model?.navigator = .project
      }
      .keyboardShortcut("1")
      .disabled(model == nil)
      Button("Show Find Navigator") {
        model?.setNavigatorVisible(true)
        model?.navigator = .find
        model?.isFindLineOpen = true
      }
      .keyboardShortcut("3")
      .disabled(model == nil)
      Menu("Hidden Files") {
        Button(hiddenFilesTitle) { model?.toggleHiddenFiles() }
          .keyboardShortcut(".", modifiers: [.command, .shift])
          .disabled(model == nil)
        Button("Edit Hidden Files") {
          model?.setNavigatorVisible(true)
          model?.navigator = .project
          model?.isChoosingVisibleFiles = true
        }
        .disabled(model == nil || model?.isChoosingVisibleFiles == true)
        Divider()
        Toggle("Hide Files Listed in .gitignore", isOn: hidesIgnoredFiles)
          .disabled(workspace == nil)
        Button("Restore Defaults") { workspace?.restoreDefaultVisibility() }
          .disabled(workspace?.visibility.isDefault != false)
      }
      Divider()
      Toggle("Wrap Lines", isOn: $wrapLines)
        .keyboardShortcut("z", modifiers: [.option])
      Toggle("Line Numbers", isOn: $showLineNumbers)
      Toggle("Minimap", isOn: $showsMinimap)
        .keyboardShortcut("m", modifiers: [.command, .control, .shift])
      Button(model?.isConsoleVisible == true ? "Hide Console" : "Show Console") {
        model?.toggleConsole()
      }
      .keyboardShortcut("y", modifiers: [.command, .shift])
      .disabled(model == nil)
      Button("Show Issues") { model?.isIssuesPresented = true }
        .keyboardShortcut("5", modifiers: [.command])
        .disabled(model == nil || !actionsEnabled)
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
    CommandGroup(after: .textEditing) {
      Button("Find in Project…") { model?.findInProject() }
        .keyboardShortcut("f", modifiers: [.command, .shift])
        .disabled(model == nil)
    }
    SidebarCommands()
  }

  /// ⇧⌘. acts on Open Quickly while it is open, else on the navigator.
  private var hiddenFilesTitle: String {
    guard let model else { return "Show Hidden Files" }
    if model.isQuickOpenPresented {
      return model.quickOpenIncludesHiddenFiles ? "Leave Out Hidden Files" : "Include Hidden Files"
    }
    return model.workspace.visibility.showsHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files"
  }

  /// The project's choice of whether .gitignore hides files.
  private var hidesIgnoredFiles: Binding<Bool> {
    Binding(
      get: { workspace?.tree.hidesIgnoredFiles ?? true },
      set: { workspace?.visibility.hidesIgnoredFiles = $0 })
  }

  /// ⌘W closes the current tab, or the window when no tab is open, as in
  /// VS Code and Zed.
  private func closeTab() {
    if let workspace, let document = workspace.selectedDocument {
      workspace.close(document)
    } else {
      #if os(macOS)
        NSApp.keyWindow?.performClose(nil)
      #endif
    }
  }

  private func zoom(by step: Double) {
    let range = EditorConfiguration.fontSizes
    fontSize = min(max(fontSize + step, Double(range.lowerBound)), Double(range.upperBound))
  }

  /// F6, F7 and F8 (AppKit's function-key characters, which WinUI's keys arrive as too).
  private static let f6 = 0xF709, f7 = 0xF70A, f8 = 0xF70B

  #if os(macOS)
    /// Sends an editor action to the focused text view.
    private func send(_ action: Selector) {
      NSApp.sendAction(action, to: nil, from: nil)
    }
  #endif
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
