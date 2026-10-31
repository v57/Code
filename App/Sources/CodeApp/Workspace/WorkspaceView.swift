import CodeKit
import ComponentKit
import SwiftUI

/// A project window on the kit: the navigator, Back and Forward with the tab strip, the editor and the status bar
/// card, with Open Quickly and Go to Line floating over the editor as the kit's palette, and the console hanging
/// under the toolbar's title.
struct WorkspaceView: View {
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace
  @AppStorage(EditorSettings.hidesIgnoredFiles) private var hidesIgnoredFiles = true
  private let serviceSettings = ServiceSettingsReader()
  #if DEBUG
    @Environment(\.openSettings) private var openSettings
  #endif

  var body: some View {
    @Bindable var model = model
    NavigationSplitView(columnVisibility: navigatorVisibility) {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 200, ideal: KitMetrics.sidebarWidth, max: 420)
        .toolbar(removing: .sidebarToggle)
    } detail: {
      EditorArea()
      // The tabs float over the editor, as the toolbar does above them and the status bar under it: the editor runs
      // on under all of them. A single tab isn't shown, so with nothing to go back or forward to there is no line.
      .safeAreaInset(edge: .top, spacing: 0) {
        if workspace.tabs.count > 1 || model.services.canGoBack || model.services.canGoForward { TabBar() }
      }
      .kitPane(.content)
      .codeStatusBar()
      .projectToolbar(model: model, actionsEnabled: serviceSettings.settings.actionsEnabled)
      .consoleOverlay(model: model)
      .kitSidebarToggle(columnVisibility: navigatorVisibility)
      .kitPaletteOverlay(isPresented: $model.isQuickOpenPresented) { QuickOpenView() }
      .kitPaletteOverlay(isPresented: $model.isGoToLinePresented) { GoToLineView() }
    }
    .onChange(of: serviceSettings.settings, initial: true) { _, settings in
      model.services.settings = settings
    }
    #if DEBUG
      .onAppear {
        AppState.shared.debugModel = model
        AppState.shared.debugModels.append(WeakWindowModel(model: model))
        AppState.shared.debugOpenSettings = { openSettings() }
      }
    #endif
    .focusedSceneValue(\.windowModel, model)
    .kitPrompt(
      promptTitle, isPresented: $model.isPromptPresented, text: $model.promptText, message: promptMessage,
      systemImage: promptSymbol, field: KitPromptField(help: "Use “/” to create folders along the way."),
      confirm: "Create"
    ) { model.commitPrompt($0) }
    .kitSheet(item: $model.notarizationSetup) { request in
      NotarizationSheet(request: request)
    }
    .kitConfirmation(
      "Move “\(model.trashCandidate?.lastPathComponent ?? "")” to the Trash?",
      isPresented: Binding(
        get: { model.trashCandidate != nil }, set: { if !$0 { model.trashCandidate = nil } }),
      message: "You can restore it from the Trash.", systemImage: "trash", confirm: "Move to Trash"
    ) {
      model.confirmTrash()
    }
    .onChange(of: isRunningProgram) { _, isRunning in
      // The console opens once a Run's build is done and its program starts, never while it builds.
      if isRunning { model.showConsole() }
    }
    .onChange(of: hidesIgnoredFiles) { _, hides in
      workspace.hidesIgnoredFilesByDefault = hides
    }
    .onChange(of: workspace.selectedTabID, initial: true) { _, _ in
      // Follow the selected tab in the sidebar.
      if let url = workspace.selectedDocument?.url, model.sidebarSelection != url {
        workspace.tree.reveal(url)
        model.sidebarSelection = url
      }
    }
    .onDisappear {
      AppState.shared.closeDetachedWindows(of: workspace)
      model.closeConsoleWindow()
      workspace.flushAll()
      workspace.saveSession()
      model.services.shutDown()
    }
  }

  private var navigatorVisibility: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: { model.isNavigatorVisible ? .all : .detailOnly },
      set: { model.isNavigatorVisible = $0 != .detailOnly })
  }

  /// A Run is past its build: its program is running.
  private var isRunningProgram: Bool {
    let actions = model.services.actions
    return actions.runningKind == .run && actions.stepTitle == "Run"
  }

  // MARK: - New File and New Folder

  private var promptTitle: String {
    if case .newFolder? = model.prompt { return "New Folder" }
    return "New File"
  }

  private var promptSymbol: String {
    if case .newFolder? = model.prompt { return "folder.badge.plus" }
    return "doc.badge.plus"
  }

  /// "In Sources/App."
  private var promptMessage: String? {
    switch model.prompt {
    case .newFile(let folder)?, .newFolder(let folder)?:
      return "In \(folder == workspace.root ? workspace.name : workspace.tree.relativePath(of: folder))."
    case nil: return nil
    }
  }
}
