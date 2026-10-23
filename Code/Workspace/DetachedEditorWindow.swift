import CodeKit
import ComponentKit
import SwiftUI

/// A document in a window of its own (Open in New Window), as Shell detaches
/// a session: only the editor, and a toolbar button that keeps the window
/// above other apps. The document stays part of its project (language
/// servers, autosave, reloads from disk); closing the window puts it back in
/// the project's tabs, and closing the project closes the window.
struct DetachedEditorWindow: View {
  static let id = "detached-editor"

  let documentID: UUID
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var window = WindowReference()
  /// Kept per window, so one window's always-on-top flag never leaks to
  /// another.
  @State private var isAlwaysOnTop = false

  var body: some View {
    let model = AppState.shared.model(detaching: documentID)
    let document = model.flatMap(detachedDocument(in:))
    Group {
      if let model, let document {
        EditorArea(detachedDocument: document)
          .kitPane(.content)
          .environment(model)
          .environment(model.workspace)
          .navigationTitle(document.name)
      } else {
        Color.clear
      }
    }
    .frame(minWidth: 320, minHeight: 200)
    .background(DetachedWindowReader(reference: window))
    #if os(macOS)
      .toolbar {
        ToolbarItem(placement: .primaryAction) { alwaysOnTopButton }
      }
    #endif
    .focusedSceneValue(\.detachedDocument, document)
    .onAppear { AppState.shared.registerDetachedWindow(window, for: documentID) }
    .onChange(of: document == nil, initial: true) { _, isGone in
      // Trashed, or its project closed.
      if isGone { dismissWindow() }
    }
    .onDisappear {
      AppState.shared.unregisterDetachedWindow(for: documentID)
      if let model = AppState.shared.model(detaching: documentID), let document = detachedDocument(in: model) {
        model.workspace.reattach(document)
      }
    }
  }

  private func detachedDocument(in model: WindowModel) -> TextDocument? {
    model.workspace.detachedDocuments.first { $0.id == documentID }
  }

  /// Toggles whether the window stays above other apps, shown in the accent
  /// color while on.
  private var alwaysOnTopButton: some View {
    Button {
      toggleAlwaysOnTop()
    } label: {
      Label("Always on Top", systemImage: "interface.window.on.rectangle.dashed")
        .foregroundStyle(isAlwaysOnTop ? AnyShapeStyle(Hue.accent.fill) : AnyShapeStyle(.kitLabel))
    }
    .help(isAlwaysOnTop ? "Keep window above other apps (on)" : "Keep window above other apps")
  }

  private func toggleAlwaysOnTop() {
    #if os(macOS)
      toggleWindowLevel()
    #endif
  }

  #if os(macOS)
  private func toggleWindowLevel() {
    guard let window = window.window else { return }
    isAlwaysOnTop.toggle()
    if isAlwaysOnTop {
      window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
      window.level = .floating
    } else {
      window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
      window.level = .normal
    }
  }
  #endif
}

#if !os(macOS)
  struct DetachedWindowReader: View {
    let reference: WindowReference

    var body: some View { Color.clear }
  }
#else
/// Records the window in a `WindowReference` and keeps it out of state
/// restoration, as project windows are.
struct DetachedWindowReader: NSViewRepresentable {
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

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      reference.window = window
      window?.isRestorable = false
    }
  }
}
#endif
