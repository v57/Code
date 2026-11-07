import CodeActionsUI
import CodeKit
import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

/// What the Save Preset popover starts from: the toolbar's choices (Save Preset…), or a preset to edit (Edit…).
struct PresetDraft: Identifiable {
  var preset: RunPreset
  /// The bar's item being edited; nil for a new preset.
  var editing: RunPresets.Item?
  var id: String { editing?.id ?? "new" }
}

extension View {
  /// The presets bar under the toolbar, on the editor's ground: the editor scrolls under it, as under the tabs.
  func presetBar() -> some View {
    safeAreaInset(edge: .top, spacing: 0) { PresetBar() }
  }
}

/// The window's run presets as small cards in one line under the title bar's groups (`RunPresetCard`): a click runs
/// one with its own choices, its tooltip says its four parts and its ⌘ number, its menu edits, moves and removes it,
/// and a drag reorders it. It never wraps: the last card says how many more there are and opens them as a menu.
struct PresetBar: View {
  @Environment(WindowModel.self) private var model
  @Environment(\.vault) private var vault
  @Environment(Workspace.self) private var workspace
  @KitStorage(EditorSettings.showsMinimap) private var showsMinimap = true
  /// Each card's width, measured off screen, and the bar's.
  @State private var widths: [String: CGFloat] = [:]
  @State private var moreWidth: CGFloat = 70
  @State private var available: CGFloat = 0
  @State private var showsMore = false
  @State private var renaming: RunPresets.Item?
  @State private var renameText = ""
  @State private var isRenaming = false
  @State private var dropTarget: String?

  private static let spacing: CGFloat = 6

  var body: some View {
    let presets = model.presets
    let items = model.services.settings.actionsEnabled ? presets.items : []
    ZStack(alignment: .topLeading) {
      if items.isEmpty {
        Color.clear.frame(height: 0)
      } else {
        bar(items)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: vault.map(ObjectIdentifier.init), initial: true) { _, _ in presets.vault = vault }
    .onChange(of: items.map(\.preset)) { _, _ in presets.refresh() }
    .kitPrompt(
      "Rename Preset", isPresented: $isRenaming, text: $renameText, message: renaming?.preset.name,
      systemImage: "pencil", confirm: "Rename"
    ) { name in
      let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let item = renaming, !name.isEmpty else { return }
      var preset = item.preset
      preset.name = name
      presets.update(item, with: preset)
    }
  }

  private func bar(_ items: [RunPresets.Item]) -> some View {
    let shown = fit(items)
    let hidden = Array(items.dropFirst(shown))
    return HStack(spacing: Self.spacing) {
      ForEach(Array(items.prefix(shown).enumerated()), id: \.element.id) { index, item in
        card(item, number: index + 1)
      }
      if !hidden.isEmpty {
        Button { showsMore = true } label: { RunPresetMoreCard(count: hidden.count) }
          .buttonStyle(KitRowButtonStyle(cornerRadius: 9))
          .kitHelp("\(hidden.count) More Presets")
          .kitMenu(isPresented: $showsMore) {
            ForEach(Array(hidden.enumerated()), id: \.element.id) { offset, item in
              Button(item.preset.name, systemImage: RunPresetCard.symbol(item.preset.action)) { model.presets.run(item) }
                .kitMenuHint(Self.shortcut(shown + offset + 1))
                .kitMenuPreview(sentence(item))
            }
          }
      }
    }
    .padding(.leading, KitMetrics.gutter + 4)
    .padding(.trailing, trailingInset)
    .padding(.top, 2)
    .padding(.bottom, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 - KitMetrics.gutter - 4 - trailingInset }
    .background(alignment: .topLeading) {
      // Every card at its own width, for `fit`.
      ZStack(alignment: .topLeading) {
        ForEach(items) { item in
          RunPresetCard(item.preset, inVault: item.isInVault, status: .working(progress: 0.5))
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths[item.id] = $0 }
        }
        RunPresetMoreCard(count: items.count)
          .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { moreWidth = $0 }
      }
      .hidden()
      .accessibilityHidden(true)
    }
  }

  /// The editor's minimap column stays clear, as the boards leave it.
  private var trailingInset: CGFloat {
    (showsMinimap && workspace.selectedDocument != nil ? MinimapView.defaultWidth : 0) + KitMetrics.gutter + 4
  }

  /// How many cards fit in one line, the "N more" card's room kept when some don't.
  private func fit(_ items: [RunPresets.Item]) -> Int {
    guard available > 0 else { return items.count }
    let width = { (item: RunPresets.Item) in widths[item.id] ?? 140 }
    let all = items.map(width).reduce(0, +) + Self.spacing * CGFloat(max(items.count - 1, 0))
    if all <= available { return items.count }
    var used: CGFloat = 0
    for (index, item) in items.enumerated() {
      let next = used + (index > 0 ? Self.spacing : 0) + width(item)
      if next + Self.spacing + moreWidth > available { return index }
      used = next
    }
    return items.count
  }

  static func shortcut(_ number: Int) -> String? { number <= 9 ? "⌘\(number)" : nil }

  private func card(_ item: RunPresets.Item, number: Int) -> some View {
    let presets = model.presets
    let actions = model.services.actions
    let run = actions.run(tag: item.id)
    let state = presets.state(of: item)
    let status: WorkStatus =
      run.map { $0.isRunningApp ? .working(progress: nil) : .working(progress: $0.progress?.fraction) } ?? .idle
    let meta = state.reason ?? "\(item.preset.parts). \(presets.placeDescription(item))"
    return Button {
      if KitDesktop.modifierKeys.contains(.option) {
        Task { await actions.useInToolbar(item.preset) }
      } else {
        presets.run(item)
      }
    } label: {
      RunPresetCard(item.preset, inVault: item.isInVault, status: status, isAvailable: state == .ready)
    }
    .buttonStyle(KitRowButtonStyle(cornerRadius: 9))
    .kitHelp(
      item.preset.name, shortcut: Self.shortcut(number), meta: meta,
      systemImage: RunPresetCard.symbol(item.preset.action), status: status)
    .kitContextMenu { menu(item) }
    .kitPopover(isPresented: editing(item)) {
      if let draft = model.presetDraft { SavePresetView(draft: draft) }
    }
    .draggable(item.id)
    .dropDestination(for: String.self) { ids, _ in
      guard let id = ids.first, let dragged = presets.items.first(where: { $0.id == id }) else { return false }
      withKitAnimation(.kitFast) { presets.move(dragged, before: item) }
      return true
    } isTargeted: { dropTarget = $0 ? item.id : (dropTarget == item.id ? nil : dropTarget) }
    .overlay(alignment: .leading) {
      if dropTarget == item.id {
        Capsule().fill(Hue.accent.fill).frame(width: 2, height: 18).offset(x: -4)
      }
    }
  }

  private func editing(_ item: RunPresets.Item) -> Binding<Bool> {
    Binding(
      get: { model.presetDraft?.editing?.id == item.id },
      set: { if !$0, model.presetDraft?.editing?.id == item.id { model.presetDraft = nil } })
  }

  /// "Runs Git on v57 iPhone: This Mac › Git-Local › Git › v57 iPhone."
  private func sentence(_ item: RunPresets.Item) -> String {
    if let reason = model.presets.state(of: item).reason { return reason }
    return "\(item.preset.parts). \(model.presets.placeDescription(item))"
  }

  @ViewBuilder private func menu(_ item: RunPresets.Item) -> some View {
    let presets = model.presets
    let preset = item.preset
    Button("Run", systemImage: "play") { presets.run(item) }
      .kitMenuPreview(
        presets.state(of: item).reason
          ?? "\(preset.action.title)s with its own choices, \(preset.parts). The toolbar stays as it is.")
    Button("Edit…", systemImage: "pencil") { model.presetDraft = PresetDraft(preset: preset, editing: item) }
      .kitMenuPreview("Changes its action, its four choices, its name or where it’s kept.")
    Button("Rename") {
      renaming = item
      renameText = preset.name
      isRenaming = true
    }
    .kitMenuPreview("Gives it a name of your own. The bar shows it as you type it.")
    Button("Use in Toolbar") { Task { await model.services.actions.useInToolbar(preset) } }
      .kitMenuPreview("Copies \(preset.parts) into the toolbar. Option-click the preset does the same.")
    Divider()
    Toggle(isOn: Binding(get: { item.isInVault }, set: { _ in presets.toggleVault(item) })) {
      Label("Keep in Vault", systemImage: RunPresetCard.vaultSymbol)
    }
    .kitMenuPreview(
      item.isInVault
        ? "Kept in the Vault: \(model.workspace.name) on your other Macs and your iPad shows it. Choosing it again moves it to \(RunPresetFile.folder)/\(RunPresetFile.fileName) in the project."
        : "Moves it from \(RunPresetFile.folder)/\(RunPresetFile.fileName) to the Vault: \(model.workspace.name) on your other Macs and your iPad shows it.")
    .disabled(vault == nil)
    Divider()
    Button("Remove", systemImage: "trash", role: .destructive) { withKitAnimation(.kitFast) { presets.remove(item) } }
      .kitMenuPreview(
        item.isInVault
          ? "Takes it out of the Vault, on every device." : "Takes it out of \(RunPresetFile.folder)/\(RunPresetFile.fileName).",
        isDanger: true)
  }
}

/// Save Preset: the action and the toolbar's four choices, each changeable, the name (following the choices until
/// one is typed) and where it's kept, This Mac (`.dev/actions.json`, shown) or the Vault. Edit… opens it on a preset.
struct SavePresetView: View {
  @Environment(WindowModel.self) private var model
  @Environment(\.vault) private var vault
  @Environment(\.kitDismiss) private var dismiss
  @State private var preset: RunPreset
  /// The name was typed: the choices no longer change it.
  @State private var isNameEdited: Bool
  @State private var keepsInVault: Bool
  private let editing: RunPresets.Item?

  init(draft: PresetDraft) {
    _preset = State(initialValue: draft.preset)
    editing = draft.editing
    _keepsInVault = State(initialValue: draft.editing?.isInVault ?? false)
    // An edited preset keeps a name of the user's own; an auto-named one follows.
    _isNameEdited = State(initialValue: draft.editing.map { _ in true } ?? false)
  }

  private var actions: ActionController { model.services.actions }

  var body: some View {
    KitSheet(
      title: editing == nil ? "Save Preset" : "Edit Preset",
      meta: editing == nil ? "From the toolbar’s choices now. Change any of them here." : preset.parts,
      systemImage: "bookmark", width: 420
    ) {
      FormCard {
        GroupRow("Action") {
          KitSegmented(
            selection: binding(\.action),
            segments: RunPreset.actions.map { KitSegment($0.title, value: $0) })
        }
        GroupRow("From") { KitPicker("From", selection: binding(\.from), segments: sources).kitPickerMaxWidth(220) }
        if !projects.isEmpty {
          GroupRow("Project") {
            KitPicker("Project", selection: binding(\.project), segments: projects).kitPickerMaxWidth(220)
          }
        }
        GroupRow("Scheme") { KitPicker("Scheme", selection: binding(\.scheme), segments: schemes).kitPickerMaxWidth(220) }
        GroupRow("Target") { KitPicker("Target", selection: binding(\.target), segments: targets).kitPickerMaxWidth(220) }
      }
      FormCard {
        GroupRow("Name") {
          TextField("Name", text: nameBinding)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 220)
        }
        GroupRow("Keep in") {
          KitSegmented(
            selection: $keepsInVault,
            segments: [
              KitSegment("This Mac", value: false),
              KitSegment("Vault", value: true, systemImage: RunPresetCard.vaultSymbol, isEnabled: vault != nil),
            ])
        }
        if !keepsInVault {
          GroupRow("File") {
            Label(RunPresetFile.displayPath(in: model.workspace.root), systemImage: "folder")
              .kitFont(.monoSmall)
              .foregroundStyle(.kitSecondary)
              .lineLimit(1)
              .truncationMode(.middle)
              .fixedSize()
          }
        }
      }
      Text(
        "The name says only what differs from the usual: “on” the device, “from” the machine. This Mac writes it to \(RunPresetFile.folder)/\(RunPresetFile.fileName) in the project, a file you can commit; the Vault syncs it to your other Macs and your iPad."
      )
      .kitFont(.caption)
      .foregroundStyle(.kitSecondary)
      .lineLimit(nil)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
    } footer: {
      Button("Cancel") { close() }
        .keyboardShortcut(.cancelAction)
      Button(editing == nil ? "Save" : "Done") { save() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
        .disabled(preset.scheme.isEmpty || preset.name.trimmingCharacters(in: .whitespaces).isEmpty)
    }
  }

  private func close() {
    model.presetDraft = nil
    dismiss()
  }

  private func save() {
    var preset = preset
    preset.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let editing {
      model.presets.update(editing, with: preset, inVault: keepsInVault)
    } else {
      withKitAnimation(.kitFast) { model.presets.add(preset, inVault: keepsInVault) }
    }
    close()
  }

  /// A part of the preset; changing one renames it while the name is the auto one.
  private func binding<Value>(_ keyPath: WritableKeyPath<RunPreset, Value>) -> Binding<Value> {
    Binding(
      get: { preset[keyPath: keyPath] },
      set: { value in
        preset[keyPath: keyPath] = value
        if !isNameEdited { preset.name = actions.autoName(for: preset) }
      })
  }

  private var nameBinding: Binding<String> {
    Binding(
      get: { preset.name },
      set: { name in
        preset.name = name
        isNameEdited = !name.isEmpty && name != actions.autoName(for: preset)
      })
  }

  // MARK: - Choices

  /// The choices, the preset's own first when it isn't among them any more.
  private func keeping(_ value: String, in segments: [KitSegment<String>], systemImage: String?) -> [KitSegment<String>] {
    guard !value.isEmpty, !segments.contains(where: { $0.value == value }) else { return segments }
    return [KitSegment(value, value: value, systemImage: systemImage)] + segments
  }

  private var sources: [KitSegment<String>] {
    let list = actions.buildSources.map { source in
      KitSegment(source.name, value: source.isLocal ? RunPreset.local : source.name, systemImage: source.symbolName)
    }
    return keeping(preset.from, in: list, systemImage: BuildSource.local.symbolName)
  }

  private var projects: [KitSegment<String>] {
    var seen: Set<String> = []
    let list = actions.containers.filter { seen.insert($0.fileName).inserted }.map {
      KitSegment($0.name, value: $0.fileName, systemImage: $0.kind.symbolName)
    }
    return keeping(preset.project, in: list, systemImage: "square.stack.3d.up")
  }

  private var schemes: [KitSegment<String>] {
    var seen: Set<String> = []
    let list = actions.schemes.filter { seen.insert($0.name).inserted }.map {
      KitSegment($0.name, value: $0.name, systemImage: $0.toolchain.symbolName)
    }
    return keeping(preset.scheme, in: list, systemImage: "square.dashed")
  }

  /// This computer's devices for the scheme's platforms; a machine or a container runs where it builds.
  private var targets: [KitSegment<String>] {
    let source = actions.source(named: preset.from)
    var list: [RunDestination]
    if let source, !source.isLocal {
      list = actions.destinations.filter { $0.kind == .remote || $0.kind == .container }
      if list.isEmpty { list = [RunDestination(id: source.id, name: source.name, kind: .remote)] }
    } else {
      let platforms = Set(actions.schemes.first { $0.name == preset.scheme }?.platforms ?? [.mac, .iOS])
      let pool = actions.hasPresetDestinations ? actions.presetDestinations : actions.destinations
      list = pool.filter { platforms.contains($0.platform) || $0.kind == .remote }
    }
    var seen: Set<String> = []
    let segments = list.filter { seen.insert($0.name).inserted }.map {
      KitSegment($0.name, value: $0.name, systemImage: $0.symbolName, isEnabled: $0.isAvailable)
    }
    return keeping(preset.target, in: segments, systemImage: "questionmark.app.dashed")
  }
}
