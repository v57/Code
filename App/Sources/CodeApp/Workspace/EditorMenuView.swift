#if os(macOS)
import CodeKit
import ComponentKit
import SwiftUI

/// The editor's own menu (the canvas's `code-13` and `code-14` boards): a right click on the text opens the kit's
/// menu at the pointer in place of the system's text menu, with what is under the pointer first (an issue, a symbol,
/// a link), then the clipboard, Find, the lines and the breakpoint. CodeKit's `EditorMenuContent` decides the rows;
/// Rename… asks for the new name in a popover under the symbol (`RenameField`).
enum EditorMenuHooks {
  /// What the menu's rows need from the window: Find in Project for a text, and Issues.
  static func install(on model: WindowModel) {
    model.services.findInProject = { [weak model] text in
      guard let model else { return }
      model.findInProject()
      model.find.text = text
      model.find.search(in: model.workspace)
    }
    model.services.showIssues = { [weak model] in model?.isIssuesPresented = true }
  }
}

extension View {
  /// The editor's menu and its Rename field, over the editor of `document`.
  func editorMenu(for document: TextDocument, services: ProjectServices) -> some View {
    modifier(EditorMenuPresenter(document: document, services: services))
  }
}

private struct EditorMenuPresenter: ViewModifier {
  let document: TextDocument
  let services: ProjectServices
  /// The menu last shown: its rows stay while it closes.
  @State private var shown: EditorMenu?

  func body(content: Content) -> some View {
    let menu = services.editorMenu.flatMap { $0.document == document.id ? $0 : nil }
    content
      .kitMenu(
        isPresented: Binding(get: { menu != nil }, set: { if !$0 { services.hideEditorMenu() } }),
        at: (menu ?? shown)?.point ?? .zero
      ) {
        if let menu = menu ?? shown { EditorMenuRows(menu: menu) }
      }
      .onChange(of: menu?.id) { if let menu { shown = menu } }
      .overlay(alignment: .topLeading) {
        if let request = services.renameRequest, request.document == document.id {
          // The symbol's place: the popover hangs under it.
          Color.clear
            .frame(width: max(request.anchor.width, 1), height: max(request.anchor.height, 1))
            .kitPopover(
              isPresented: Binding(
                get: { services.renameRequest === request }, set: { if !$0, services.renameRequest === request { services.cancelRename() } })
            ) {
              RenameField(request: request, services: services)
            }
            .offset(x: request.anchor.minX, y: request.anchor.minY)
            .allowsHitTesting(false)
        }
      }
  }
}

/// The menu's rows: each part under its title, a line between parts.
struct EditorMenuRows: View {
  let menu: EditorMenu

  var body: some View {
    ForEach(Array(menu.content.parts.enumerated()), id: \.element.id) { index, part in
      if index > 0 { Divider() }
      if let title = part.title {
        KitMenuSection(title) { rows(part) }
      } else {
        rows(part)
      }
    }
  }

  private func rows(_ part: EditorMenuContent.Part) -> some View {
    ForEach(part.rows) { row in
      Button(row.title, systemImage: Self.symbol(row.icon)) { menu.pick(row) }
        .kitMenuHint(row.hint)
        .kitMenuPreview(row.preview)
        .disabled(!row.isEnabled)
    }
  }

  static func symbol(_ icon: EditorMenuContent.Icon) -> String {
    switch icon {
    case .jump: "arrow.right"
    case .type: "t.square"
    case .help: "questionmark.circle"
    case .references: "magnifyingglass"
    case .rename: "pencil"
    case .copy: "doc.on.doc"
    case .issues: "list.bullet"
    case .link: "link"
    case .cut: "scissors"
    case .paste: "doc.on.clipboard"
    case .reference: "number"
    case .find: "text.magnifyingglass"
    case .comment: "text.bubble"
    case .indent: "increase.indent"
    case .outdent: "decrease.indent"
    case .breakpoint: "tag"
    }
  }
}

/// Rename's popover: the new name, how many places change, Rename.
struct RenameField: View {
  @Bindable var request: RenameRequest
  let services: ProjectServices

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Rename \(request.name)")
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.middle)
      TextField("New name", text: $request.newName)
        .kitField(status: request.problem == nil ? .none : .error, mono: true)
        .onSubmit { services.commitRename(request) }
        .disabled(request.isRenaming)
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        if request.places == nil, request.failure == nil { ProgressView().controlSize(.mini) }
        Text(request.status)
          .font(.system(size: 12))
          .foregroundStyle(request.failure == nil ? AnyShapeStyle(.kitSecondary) : AnyShapeStyle(.kitLabel))
          .lineLimit(nil)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        Button("Cancel") { services.cancelRename() }
          .buttonStyle(.kit)
          .keyboardShortcut(.cancelAction)
        Button("Rename") { services.commitRename(request) }
          .buttonStyle(.kitPrimary)
          .keyboardShortcut(.defaultAction)
          .disabled(!request.canRename)
      }
    }
    .padding(14)
    .frame(width: 320)
  }
}
#else
import CodeKit
import SwiftUI

/// The editor's menu (CodeKit's `EditorMenu`) is macOS-only so far.
enum EditorMenuHooks {
  static func install(on model: WindowModel) {}
}

extension View {
  func editorMenu(for document: TextDocument, services: ProjectServices) -> some View { self }
}
#endif
