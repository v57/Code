import CodeActionsUI
import CodeKit
import ComponentKit
import SwiftUI
import VaultKit

/// One of the Projects list's quick actions: an action with the project's own toolbar choices, or a saved preset.
enum ProjectQuickAction {
  case action(ActionKind)
  case preset(RunPresets.Item)
}

/// The quick actions at the top of a project's menu in the sidebar's Projects list: Run, Install, Export… and Upload to
/// App Store with the project's toolbar choices, then its run presets (`.dev/actions.json` and the vault's), so a
/// project runs without switching to it (`AppState.perform(_:in:…)`).
///
/// A project a window shows (or one running in the background) lists what its toolbar can do now; one no window has
/// loaded lists Run, the distribution actions when it is an Xcode project, and its presets as saved, and says why when
/// it turns out it can't.
struct ProjectQuickActions: View {
  let project: VaultProject
  let folder: URL
  /// The window whose list it is (it asks Upload's and Export's questions for a project no window shows).
  let host: WindowModel
  let vault: Vault?
  let showToast: ShowToastAction

  /// The distribution actions, in the Product menu's order.
  private static let shipping: [ActionKind] = [.install, .export, .upload]

  var body: some View {
    let live = AppState.shared.liveModel(for: folder)
    let actions = live?.services.actions
    let isXcode = Self.isXcode(project, folder: folder)
    Button("Run", systemImage: ActionKind.run.symbolName) { perform(.action(.run)) }
      .kitMenuPreview(preview(.run, actions: actions))
    ForEach(Self.shipping, id: \.self) { kind in
      if actions.map({ $0.canPerform(kind) }) ?? isXcode {
        Button(Self.title(kind), systemImage: kind.symbolName) { perform(.action(kind)) }
          .kitMenuPreview(preview(kind, actions: actions))
      }
    }
    let presets = live?.presets.items ?? RunPresets.items(in: folder, vault: vault)
    if !presets.isEmpty {
      KitMenuSection("Presets") {
        ForEach(presets) { item in
          let reason = live?.presets.state(of: item).reason
          Button(item.preset.name, systemImage: RunPresetCard.symbol(item.preset.action)) { perform(.preset(item)) }
            .disabled(reason != nil)
            .kitMenuPreview(reason ?? "\(item.preset.action.title)s \(item.preset.parts).")
        }
      }
    }
  }

  private func perform(_ action: ProjectQuickAction) {
    AppState.shared.perform(action, in: folder, name: project.name, host: host) {
      showToast($0, systemImage: "exclamationmark.triangle")
    }
  }

  /// "Export…" asks for a notary profile first when there's none; Upload always asks for its build number.
  private static func title(_ kind: ActionKind) -> String {
    switch kind {
    case .export: return String(localized: "Export…")
    case .upload: return String(localized: "Upload to App Store…")
    default: return kind.title
    }
  }

  /// What the action does to this project, with the scheme and device when they're known.
  private func preview(_ kind: ActionKind, actions: ActionController?) -> String {
    let scheme = actions?.selectedScheme?.name
    let target = scheme ?? project.name
    let place = folder.standardizedFileURL == host.workspace.root.standardizedFileURL ? "" : " Without switching to it."
    switch kind {
    case .run:
      let device = actions?.selectedDestination.map { " on \($0.name)" } ?? ""
      return "Builds and runs \(target)\(device) with its toolbar’s choices.\(place)"
    case .install: return "Archives \(target) and installs it in Applications.\(place)"
    case .export: return "Archives \(target), notarizes it and zips it for other Macs.\(place)"
    case .upload: return "Archives \(target) and uploads it to App Store Connect.\(place)"
    default: return "\(kind.title)s \(target).\(place)"
    }
  }

  /// An Xcode project, as the vault last saw it, else as the folder holds now.
  private static func isXcode(_ project: VaultProject, folder: URL) -> Bool {
    if !project.kinds.isEmpty { return project.kinds.contains(.xcode) }
    return VaultProject.Kind.detect(in: folder)?.contains(.xcode) ?? false
  }
}
