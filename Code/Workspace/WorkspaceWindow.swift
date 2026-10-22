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
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var model: WindowModel?
  @State private var window = WindowReference()

  var body: some View {
    Group {
      if let model {
        WorkspaceView()
          .environment(model)
          .environment(model.workspace)
          // Another project is a new view: the old one's disappearing saves and closes its project.
          .id(model.workspace.root)
      } else {
        WelcomeScreen { open($0) }
      }
    }
    .frame(minWidth: 640, minHeight: 400)
    .background(WindowReader(reference: window, isWelcome: model == nil))
    .onAppear {
      AppState.shared.openWindow = openWindow
      #if DEBUG
        // The screenshot demo's scenes, in the first window.
        ScreenshotDemo.attach { root = $0 }
      #endif
    }
    .onChange(of: root, initial: true) { _, root in makeModel(root) }
    .onOpenURL { open($0) }
    .onDisappear { if let workspace = model?.workspace { AppState.shared.unregister(workspace) } }
    .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
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

  /// Shows another project in this window (the Projects card), or brings forward the window it is open in.
  private func switchProject(to folder: URL) {
    let folder = folder.standardizedFileURL
    guard folder != model?.workspace.root, !AppState.shared.focus(folder) else { return }
    root = folder
  }

  private func makeModel(_ root: URL?) {
    guard let root else {
      // Back to Welcome: the project's window is gone.
      if let workspace = model?.workspace { AppState.shared.unregister(workspace) }
      model = nil
      return
    }
    guard model?.workspace.root != root.standardizedFileURL else { return }
    // A folder that is gone shows Welcome instead.
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      self.root = nil
      return
    }
    // One window per folder: a second window that gets an open folder
    // focuses the first and closes.
    if AppState.shared.workspace(for: root) != nil {
      AppState.shared.focus(root)
      #if os(macOS)
        DispatchQueue.main.async { [window] in window.window?.close() }
      #else
        DispatchQueue.main.async { [dismissWindow] in dismissWindow() }
      #endif
      return
    }
    // The project this window showed until now (the Projects card switched it).
    if let previous = model?.workspace { AppState.shared.unregister(previous) }
    let workspace = Workspace(
      root: root, hidesIgnoredFiles: EditorSettings.storedHidesIgnoredFiles,
      defaults: ScreenshotDemo.isOn ? ScreenshotDemo.defaults : .standard)
    let model = WindowModel(workspace: workspace)
    model.switchProject = { [self] in switchProject(to: $0) }
    AppState.shared.register(model, window: window)
    AppState.shared.recents.add(root)
    for file in AppState.shared.takePendingFiles(for: root) {
      workspace.tree.reveal(file)
      workspace.open(file)
    }
    self.model = model
  }
}

/// The window a view is in, filled in by `WindowReader` (the NSWindow on the Mac).
@MainActor final class WindowReference {
  #if os(macOS)
    weak var window: NSWindow?
  #endif

  /// Brings the window to the front.
  func bringToFront() {
    #if os(macOS)
      window?.makeKeyAndOrderFront(nil)
    #endif
  }

  /// Closes the window (off the Mac a detached editor closes itself once its document is gone).
  func close() {
    #if os(macOS)
      window?.close()
    #endif
  }
}

#if !os(macOS)
  /// Off the Mac the scene's style is the window's (no restyling between Welcome and a project).
  private struct WindowReader: View {
    let reference: WindowReference
    let isWelcome: Bool

    var body: some View { Color.clear }
  }
#else

/// Records its window in a `WindowReference`, keeps the window out of
/// state restoration (Code launches to the Welcome screen, never reopening
/// the projects of the last session), and styles it for what it shows:
/// Welcome runs its ground under a clear title bar (it has no toolbar); a
/// project gets the title bar back.
private struct WindowReader: NSViewRepresentable {
  let reference: WindowReference
  let isWelcome: Bool

  func makeNSView(context: Context) -> NSView { ReaderView(reference: reference, isWelcome: isWelcome) }

  func updateNSView(_ view: NSView, context: Context) {
    guard let view = view as? ReaderView, view.isWelcome != isWelcome else { return }
    view.isWelcome = isWelcome
    view.applyStyle()
  }

  private final class ReaderView: NSView {
    let reference: WindowReference
    var isWelcome: Bool
    /// The style applied to the window, once it has one.
    private var appliedWelcome: Bool?
    /// SwiftUI's own style for the window, for a project.
    private var projectStyle: (mask: NSWindow.StyleMask, transparentTitlebar: Bool)?

    init(reference: WindowReference, isWelcome: Bool) {
      self.reference = reference
      self.isWelcome = isWelcome
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      reference.window = window
      window?.isRestorable = false
      applyStyle()
    }

    func applyStyle() {
      guard let window, appliedWelcome != isWelcome else { return }
      appliedWelcome = isWelcome
      let projectStyle = projectStyle ?? (window.styleMask, window.titlebarAppearsTransparent)
      self.projectStyle = projectStyle
      window.titlebarAppearsTransparent = isWelcome || projectStyle.transparentTitlebar
      // The toolbar's rich title names the project; Welcome has none.
      window.titleVisibility = .hidden
      window.titlebarSeparatorStyle = isWelcome ? .none : .automatic
      window.toolbar?.isVisible = !isWelcome
      if isWelcome {
        window.styleMask.insert(.fullSizeContentView)
      } else {
        window.styleMask = projectStyle.mask
      }
    }
  }
}
#endif
