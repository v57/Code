import CodeKit
import SwiftUI

/// One window: a project folder's workspace, or the Welcome screen while the
/// window has no folder.
///
/// Folders and files opened from Finder or the Dock arrive here through
/// `onOpenURL`, as in the Markdown app: every window accepts them, so SwiftUI
/// hands them to an existing window instead of making a new one each. A
/// Welcome window takes the folder itself; a project window opens files of
/// its own folder and passes anything else on to that folder's window.
struct WorkspaceWindow: View {
  static let id = "workspace"

  @Binding var root: URL?
  @Environment(\.openWindow) private var openWindow
  @State private var model: WindowModel?
  @State private var window = WindowReference()

  var body: some View {
    Group {
      if let model {
        WorkspaceView()
          .environment(model)
          .environment(model.workspace)
      } else {
        WelcomeView { open($0) }
      }
    }
    .background(WindowReader(reference: window))
    .onAppear {
      AppState.shared.openWindow = openWindow
      restoreProjects()
    }
    .onChange(of: root, initial: true) { _, root in makeModel(root) }
    .onOpenURL { open($0) }
    .onDisappear { if let workspace = model?.workspace { AppState.shared.unregister(workspace) } }
    .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
  }

  /// At launch, the first window reopens the projects open at the last quit:
  /// it takes the first one itself (when it has no folder yet) and opens
  /// windows for the rest.
  private func restoreProjects() {
    var folders = AppState.shared.takeProjectsToRestore()
    if root == nil, !folders.isEmpty { root = folders.removeFirst() }
    for folder in folders { openWindow(id: Self.id, value: folder) }
  }

  /// Opens a folder or file from Finder, the Dock, the Welcome screen or a
  /// drop.
  private func open(_ url: URL) {
    guard url.isFileURL, let (folder, file) = AppState.target(of: url) else { return }
    // The folder this window shows, or is about to (`root` is set before the
    // workspace exists).
    if let current = model?.workspace.root ?? root?.standardizedFileURL {
      guard folder == current || folder.path.hasPrefix(current.path + "/") else {
        AppState.shared.open(url)  // another project: its own window
        return
      }
      guard let file else { return }
      if let workspace = model?.workspace {
        workspace.tree.reveal(file)
        workspace.open(file)
      } else {
        AppState.shared.addPendingFile(file, in: current)
      }
      return
    }
    // A Welcome window becomes the folder's window, unless another window
    // already shows that folder.
    if AppState.shared.workspace(for: folder) != nil {
      AppState.shared.open(url)
      return
    }
    if let file { AppState.shared.addPendingFile(file, in: folder) }
    AppState.shared.recents.add(folder)
    root = folder
  }

  private func makeModel(_ root: URL?) {
    guard let root else {
      model = nil
      return
    }
    guard model?.workspace.root != root.standardizedFileURL else { return }
    // A restored window whose folder is gone shows Welcome instead.
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      self.root = nil
      return
    }
    // One window per folder. At launch a restored window and the window
    // SwiftUI makes for a folder opened from Finder can both get it; the
    // later one focuses the first and closes.
    if AppState.shared.workspace(for: root) != nil {
      AppState.shared.focus(root)
      DispatchQueue.main.async { [window] in window.window?.close() }
      return
    }
    let workspace = Workspace(root: root, excludedNames: EditorSettings.storedExcludedNames)
    AppState.shared.register(workspace, window: window)
    AppState.shared.recents.add(root)
    for file in AppState.shared.takePendingFiles(for: root) {
      workspace.tree.reveal(file)
      workspace.open(file)
    }
    model = WindowModel(workspace: workspace)
  }
}

/// The NSWindow a view is in, filled in by `WindowReader`.
@MainActor final class WindowReference {
  weak var window: NSWindow?
}

/// Records its window in a `WindowReference`.
private struct WindowReader: NSViewRepresentable {
  let reference: WindowReference

  func makeNSView(context: Context) -> NSView { ReaderView(reference: reference) }
  func updateNSView(_ view: NSView, context: Context) {}

  private final class ReaderView: NSView {
    let reference: WindowReference
    init(reference: WindowReference) {
      self.reference = reference
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      reference.window = window
    }
  }
}
