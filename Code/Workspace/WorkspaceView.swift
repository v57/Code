import CodeKit
import SwiftUI

/// A project window: the file tree, the tab bar, the editor and the status
/// bar, with Quick Open and Go to Line floating over the editor.
struct WorkspaceView: View {
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace
  @AppStorage(EditorSettings.hidesIgnoredFiles) private var hidesIgnoredFiles = true
  @AppStorage("console.height") private var consoleHeight = 220.0
  private let serviceSettings = ServiceSettingsReader()
  #if DEBUG
    @Environment(\.openSettings) private var openSettings
  #endif

  var body: some View {
    @Bindable var model = model
    NavigationSplitView(columnVisibility: navigatorVisibility) {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 180, ideal: 250, max: 420)
    } detail: {
      VStack(spacing: 0) {
        // Tabs and the path bar sit on the toolbar's background, as in Xcode.
        if !workspace.tabs.isEmpty {
          VStack(spacing: 0) {
            TabBar()
            JumpBar()
          }
          .background(.bar)
          Divider()
        }
        EditorArea()
        if model.isConsoleVisible {
          ConsoleDivider(height: $consoleHeight)
          ConsoleView()
            .frame(height: consoleHeight)
        }
        Divider()
        StatusBar()
      }
      .toolbar {
        if serviceSettings.settings.actionsEnabled {
          ProjectToolbar(model: model)
        }
      }
      .overlay(alignment: .top) {
        if model.isQuickOpenPresented {
          QuickOpenView()
            .padding(.top, 8)
        } else if model.isGoToLinePresented {
          GoToLineView()
            .padding(.top, 8)
        }
      }
    }
    .navigationTitle(workspace.name)
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
    .alert(promptTitle, isPresented: isPrompting) {
      TextField("Name", text: $model.promptText)
      Button(promptAction) { model.commitPrompt() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(promptMessage)
    }
    .confirmationDialog(
      "Move “\(model.trashCandidate?.lastPathComponent ?? "")” to the Trash?",
      isPresented: Binding(
        get: { model.trashCandidate != nil }, set: { if !$0 { model.trashCandidate = nil } })
    ) {
      Button("Move to Trash", role: .destructive) { model.confirmTrash() }
    } message: {
      Text("You can restore it from the Trash.")
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

  private var isPrompting: Binding<Bool> {
    Binding(get: { model.prompt != nil }, set: { if !$0 { model.prompt = nil } })
  }

  private var promptTitle: String {
    switch model.prompt {
    case .newFile: return "New File"
    case .newFolder: return "New Folder"
    case .rename(let url): return "Rename “\(url.lastPathComponent)”"
    case nil: return ""
    }
  }

  private var promptAction: String {
    if case .rename = model.prompt { return "Rename" }
    return "Create"
  }

  private var promptMessage: String {
    switch model.prompt {
    case .newFile(let folder), .newFolder(let folder):
      let path = workspace.tree.relativePath(of: folder)
      let location = folder == workspace.root ? workspace.name : path
      return "In \(location). Use “/” to create folders along the way."
    default:
      return ""
    }
  }
}

/// The bar between the editor and the console; drag to resize.
private struct ConsoleDivider: View {
  @Binding var height: Double
  @State private var start: Double?

  var body: some View {
    Divider()
      .overlay {
        Color.clear
          .frame(height: 7)
          .contentShape(Rectangle())
          .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
          }
          .gesture(
            DragGesture(coordinateSpace: .global)
              .onChanged { value in
                let base = start ?? height
                start = base
                height = min(max(base - value.translation.height, 80), 900)
              }
              .onEnded { _ in start = nil })
      }
  }
}
