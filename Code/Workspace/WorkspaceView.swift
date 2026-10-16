import CodeKit
import ComponentKit
import SwiftUI

/// A project window on the kit: the navigator, the tab strip and path bar, the editor and the status bar card, with
/// Open Quickly and Go to Line floating over the editor as the kit's palette.
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
        .navigationSplitViewColumnWidth(min: 200, ideal: KitMetrics.sidebarWidth, max: 420)
        .toolbar(removing: .sidebarToggle)
    } detail: {
      VStack(spacing: 0) {
        // The tabs on the panel ground, the path bar on the editor's.
        if !workspace.tabs.isEmpty {
          TabBar()
          JumpBar()
        }
        EditorArea()
        if model.isConsoleVisible {
          ConsoleDivider(height: $consoleHeight)
          ConsoleView()
            .frame(height: consoleHeight)
        }
      }
      .kitPane(.content)
      .codeStatusBar()
      .toolbar {
        if serviceSettings.settings.actionsEnabled {
          ProjectToolbar(model: model)
        }
      }
      .overlay(alignment: .top) {
        if model.isQuickOpenPresented {
          QuickOpenView()
        } else if model.isGoToLinePresented {
          GoToLineView()
        }
      }
    }
    .navigationTitle(workspace.name)
    .modifier(HiddenWindowTitle())
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
    .sheet(item: $model.prompt) { prompt in
      PromptSheet(prompt: prompt)
        .environment(model)
        .environment(workspace)
    }
    .sheet(item: $model.notarizationSetup) { request in
      NotarizationSetupView(request: request)
    }
    .kitConfirmation(
      "Move “\(model.trashCandidate?.lastPathComponent ?? "")” to the Trash?",
      isPresented: Binding(
        get: { model.trashCandidate != nil }, set: { if !$0 { model.trashCandidate = nil } }),
      message: "You can restore it from the Trash.", systemImage: "trash", confirm: "Move to Trash"
    ) {
      model.confirmTrash()
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
}

/// New File, New Folder and Rename as a kit sheet: the name in a form row, Cancel and the action.
private struct PromptSheet: View {
  let prompt: WindowModel.Prompt
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace

  var body: some View {
    @Bindable var model = model
    KitSheet(title: title, meta: message, systemImage: systemImage) {
      FormCard {
        FormRow(
          "Name", help: "Use “/” to create folders along the way.", systemImage: "character.cursor.ibeam",
          field: TextField("Name", text: $model.promptText).onSubmit { model.commitPrompt() })
      }
    } footer: {
      Button("Cancel") { model.prompt = nil }
        .keyboardShortcut(.cancelAction)
      Button(action) { model.commitPrompt() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(model.promptText.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    .componentKit()
  }

  private var title: String {
    switch prompt {
    case .newFile: return "New File"
    case .newFolder: return "New Folder"
    case .rename(let url): return "Rename “\(url.lastPathComponent)”"
    }
  }

  private var systemImage: String {
    switch prompt {
    case .newFile: return "doc.badge.plus"
    case .newFolder: return "folder.badge.plus"
    case .rename: return "pencil"
    }
  }

  private var action: String {
    if case .rename = prompt { return "Rename" }
    return "Create"
  }

  private var message: String? {
    switch prompt {
    case .newFile(let folder), .newFolder(let folder):
      let location = folder == workspace.root ? workspace.name : workspace.tree.relativePath(of: folder)
      return "In \(location)."
    case .rename(let url):
      return "In \(url.deletingLastPathComponent() == workspace.root ? workspace.name : workspace.tree.relativePath(of: url.deletingLastPathComponent()))."
    }
  }
}

/// No system title: the toolbar's rich title names the project.
private struct HiddenWindowTitle: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.toolbar(removing: .title)
    } else {
      content
    }
  }
}

/// Where the editor meets the console (the change of ground is the edge); drag to resize.
private struct ConsoleDivider: View {
  @Binding var height: Double
  @State private var start: Double?

  var body: some View {
    Color.clear
      .frame(height: 0)
      .zIndex(1)
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
