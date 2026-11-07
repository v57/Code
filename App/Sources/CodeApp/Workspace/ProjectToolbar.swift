import CodeKit
import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

extension View {
  /// Xcode's toolbar as the kit's bar: Go Back and Go Forward (as in Markdown), Run and Stop in tool groups before the project's rich title (its live icon
  /// carries the running action, its meta line says what the project is doing), and the issue counts and
  /// scheme › destination at the end, which go icon-only when the window narrows. Without actions (Settings ›
  /// Tools), the project's name alone.
  func projectToolbar(model: WindowModel, actionsEnabled: Bool) -> some View {
    kitToolbar(model.workspace.name) {
      NavigationTools(model: model)
    } title: {
      HStack(spacing: KitMetrics.gutter) {
        if actionsEnabled { RunTools(model: model) }
        ProjectTitle(model: model, showsStatus: actionsEnabled)
      }
    } tools: {
      if actionsEnabled { SchemeTools(model: model) }
    }
  }
}

/// Go Back and Go Forward.
private struct NavigationTools: View {
  let model: WindowModel

  var body: some View {
    let services = model.services
    ToolGroup(iconOnly: true) {
      Button("Go Back", systemImage: "chevron.left") { services.goBack() }
        .kitHelp("Go Back", shortcut: "⌃⌘←")
        .disabled(!services.canGoBack)
      Button("Go Forward", systemImage: "chevron.right") { services.goForward() }
        .kitHelp("Go Forward", shortcut: "⌃⌘→")
        .disabled(!services.canGoForward)
    }
  }
}

/// ▶ (Run; its context menu has Test, Build, Clean and Save Preset…, whose popover hangs under it) and ■ (Stop).
private struct RunTools: View {
  let model: WindowModel

  var body: some View {
    let actions = model.services.actions
    ToolGroup(iconOnly: true) {
      Button(actions.canPerform(.run) ? "Run" : "Build", systemImage: "play.fill") {
        model.perform(actions.canPerform(.run) ? .run : .build)
      }
      .kitHelp(actions.canPerform(.run) ? "Run" : "Build", shortcut: actions.canPerform(.run) ? "⌘R" : "⌘B")
      .disabled(actions.selectedScheme == nil)
      .kitContextMenu {
        let scheme = actions.selectedScheme?.name ?? "the scheme"
        Button("Run") { model.perform(.run) }
          .disabled(!actions.canPerform(.run))
          .kitMenuPreview(
            actions.canPerform(.run)
              ? "Builds \(scheme), then runs it on \(actions.selectedDestination?.name ?? "the destination")."
              : "\(scheme) has nothing to run.")
        Button("Test") { model.perform(.test) }
          .disabled(!actions.canPerform(.test))
          .kitMenuPreview(
            actions.canPerform(.test) ? "Builds \(scheme) and runs its tests." : "\(scheme) has no tests.")
        Button("Build") { model.perform(.build) }
          .disabled(!actions.canPerform(.build))
          .kitMenuPreview("Builds \(scheme) without running it.")
        Divider()
        Button("Clean") { model.perform(.clean) }
          .disabled(!actions.canPerform(.clean))
          .kitMenuPreview(
            "Deletes \(actions.selectedScheme.map { "\($0.name)’s" } ?? "the scheme’s") build products. The next build starts over.")
        Divider()
        let preset = actions.presetFromToolbar(.run)
        Button("Save Preset…", systemImage: "bookmark") { model.savePreset() }
          .disabled(actions.selectedScheme == nil)
          .kitMenuPreview(
            "Puts “\(preset.name)” under the title bar: \(Self.list(preset)). Next you can rename it and keep it in the Vault.")
      }
      .kitPopover(isPresented: savingPreset) {
        if let draft = model.presetDraft { SavePresetView(draft: draft) }
      }
      Button("Stop", systemImage: "stop.fill") { actions.stop() }
        .kitHelp("Stop", shortcut: "⌘.")
        .disabled(!actions.isRunning)
    }
  }

  /// The popover of a new preset (an edited one hangs under its card).
  private var savingPreset: Binding<Bool> {
    Binding(
      get: { model.presetDraft != nil && model.presetDraft?.editing == nil },
      set: { if !$0, model.presetDraft?.editing == nil { model.presetDraft = nil } })
  }

  /// "studio-mac, Git-Local, Git and iPad Pro": the preset's four parts in a sentence.
  static func list(_ preset: RunPreset) -> String {
    let parts = [preset.fromName, (preset.project as NSString).deletingPathExtension, preset.scheme, preset.target]
      .filter { !$0.isEmpty }
    guard parts.count > 1 else { return parts.first ?? "" }
    return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
  }
}

/// The project's name over what it is doing ("Building — Compiling 31 of 48", "Build Failed · 2 errors"), the
/// action's state in the live icon, and the kit's success or failure effect as it ends. A click shows or hides the
/// console, which hangs under it.
private struct ProjectTitle: View {
  let model: WindowModel
  let showsStatus: Bool

  var body: some View {
    Button {
      model.toggleConsole()
    } label: {
      KitTitle(
        model.workspace.name, meta: showsStatus ? [status] : [],
        systemImage: "chevron.left.forwardslash.chevron.right", hue: .orange, status: showsStatus ? workStatus : .idle
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.kitPlain)
    .accessibilityHint(model.isConsoleVisible ? "Hides the console" : "Shows the console")
    .consoleAnchor()
    .frame(minWidth: 120, idealWidth: 280, maxWidth: 420, alignment: .leading)
    // A finished build, test or run plays the kit's success or failure.
    .status(showsStatus ? workStatus : .idle)
    .kitHelp(model.workspace.name, shortcut: "⇧⌘Y", meta: showsStatus ? status : nil)
  }

  private var workStatus: WorkStatus {
    let actions = model.services.actions
    switch actions.state {
    case .running:
      if case .paused? = model.services.debugger?.state { return .paused() }
      if actions.runningKind == .run && actions.stepTitle == "Run" { return .working(progress: nil) }
      return .working(progress: actions.progress?.fraction)
    case .succeeded: return .done
    case .failed(_, _, let message): return .failed(message)
    case .stopped: return .paused()
    case .idle: return model.services.languageServers.activity != nil || actions.isScanning ? .working : .idle
    }
  }

  private var status: String {
    let actions = model.services.actions
    // What runs, or ran: a preset's own choices, else the toolbar's.
    let scheme = (actions.isRunning ? actions.runningScheme : nil)?.name ?? actions.selectedScheme?.name ?? ""
    let destination =
      (actions.isRunning ? actions.runningDestination : nil)?.name ?? actions.selectedDestination?.name
      ?? RunDestination.localName
    switch actions.state {
    case .running(let kind):
      if model.services.debugger != nil {
        if case .paused(let reason)? = model.services.debugger?.state {
          return reason.isEmpty ? "Paused" : "Paused: \(reason)"
        }
        return "Debugging \(scheme) on \(destination)"
      }
      if kind == .run && actions.stepTitle == "Run" { return "Running \(scheme) on \(destination)" }
      let step = actions.stepTitle.map { $0 == kind.title ? "" : " — \($0)" } ?? ""
      let detail = actions.progress?.message.isEmpty == false ? ": \(actions.progress!.message)" : ""
      return "\(kind.progressTitle)\(step)\(detail)"
    case .succeeded(let kind, let date):
      let what = kind == .run ? "Finished running \(scheme)" : "\(kind.title) Succeeded"
      return "\(what) · \(Self.time(date))"
    case .failed(let kind, let date, let message):
      return "\(kind.title) Failed · \(message) · \(Self.time(date))"
    case .stopped(_, let date):
      return "Stopped · \(Self.time(date))"
    case .idle:
      if let activity = model.services.languageServers.activity { return activity }
      if actions.isScanning { return "Finding schemes…" }
      return actions.schemes.isEmpty ? "No schemes in this folder" : "Ready"
    }
  }

  static func time(_ date: Date) -> String {
    "Today at " + date.formatted(date: .omitted, time: .shortened)
  }
}

/// The issue counts (they open the issue list), then "Container › Scheme › Destination": the kit's menus in one tool
/// group, the container only when a folder has several to choose from (`ProjectContainer`).
private struct SchemeTools: View {
  let model: WindowModel
  /// The window's account's vault, whose projects on the user's other devices are the remote destinations.
  @Environment(\.vault) private var vault

  private var remoteTargets: [SSHExecutor.Target] {
    vault.map { RemoteDestinations.targets(for: model.workspace.root, vault: $0) } ?? []
  }

  var body: some View {
    @Bindable var model = model
    let services = model.services
    let actions = services.actions
    HStack(spacing: KitMetrics.gutter) {
      if services.errorCount > 0 || services.warningCount > 0 {
        ToolGroup {
          Button {
            model.isIssuesPresented.toggle()
          } label: {
            HStack(spacing: 8) {
              if services.errorCount > 0 {
                HStack(spacing: 3) {
                  Image(systemName: "xmark.octagon.fill").foregroundStyle(Hue.red.fill)
                  Count(services.errorCount, .failed)
                }
              }
              if services.warningCount > 0 {
                HStack(spacing: 3) {
                  Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Hue.yellow.fill)
                  Count(services.warningCount, .attention)
                }
              }
            }
          }
          .kitHelp("Show Issues", shortcut: "⌥⌘5")
          .kitMenu(isPresented: $model.isIssuesPresented) { IssuesMenu(services: services) }
        }
      }
      ToolGroup {
        if !choosableFolders.isEmpty, let container = actions.selectedContainer {
          Button {
            model.openMenu = .container
          } label: {
            Label(container.name, systemImage: container.kind.symbolName)
          }
          .kitMenu(isPresented: model.isPresented(.container)) { containerItems }
          .kitHelp("Choose what to build from", meta: container.fileName)
          ToolSeparator()
        }
        Button {
          model.openMenu = .scheme
        } label: {
          Label(
            actions.selectedScheme?.name ?? (actions.isScanning ? "Finding Schemes…" : "No Scheme"),
            systemImage: actions.selectedScheme?.toolchain.symbolName ?? "square.dashed")
        }
        .kitMenu(isPresented: model.isPresented(.scheme)) { schemeItems }
        .kitHelp("Choose a scheme")
        ToolSeparator()
        Button {
          model.openMenu = .destination
        } label: {
          Label(
            actions.selectedDestination?.name ?? (actions.isLoadingDestinations ? "Loading…" : "No Destination"),
            systemImage: actions.selectedDestination?.symbolName ?? "questionmark.app.dashed")
        }
        .kitMenu(isPresented: model.isPresented(.destination)) { destinationItems }
        .kitHelp("Choose where to run")
      }
    }
    // Other machines that have this project: the user's devices via Hub or that let them in, kept current as the vault
    // changes.
    .onChange(of: remoteTargets, initial: true) { _, targets in
      actions.remoteTargets = targets
      actions.remoteLoginPassword = { [vault] target in
        vault.flatMap { RemoteDestinations.loginPassword(for: target, vault: $0) }
      }
      actions.remoteLogin = { [vault] target in
        try vault.flatMap { try RemoteDestinations.login(for: target, vault: $0) }
      }
    }
  }

  /// The folders with more than one container, the root's first.
  private var choosableFolders: [URL] {
    let actions = model.services.actions
    var folders: [URL] = []
    for container in actions.containers where !folders.contains(container.directory) {
      if actions.containers(in: container.directory).count > 1 { folders.append(container.directory) }
    }
    return folders
  }

  /// A folder's workspaces, projects and package, each saying what it is; the one it builds from is checked. With
  /// several folders to choose in, each folder is a fold that says what it builds from.
  @ViewBuilder private var containerItems: some View {
    let actions = model.services.actions
    let folders = choosableFolders
    if folders.count > 1 {
      ForEach(folders, id: \.self) { folder in
        let current = ProjectContainer.effective(
          picked: actions.pickedContainer(in: folder), in: actions.containers(in: folder))
        KitSubmenu(folder.lastPathComponent, value: current?.kind.title) { containerRows(in: folder) }
          .kitMenuPreview(current.map { "Builds \(folder.lastPathComponent) from \($0.fileName)." })
      }
    } else if let folder = folders.first {
      containerRows(in: folder)
    }
  }

  private func containerRows(in folder: URL) -> some View {
    let actions = model.services.actions
    let containers = actions.containers(in: folder)
    let current = ProjectContainer.effective(picked: actions.pickedContainer(in: folder), in: containers)
    return ForEach(containers) { container in
      MenuPick(container.name, isOn: container == current) { actions.selectContainer(container) }
        .kitMenuHint(container.kind.title)
        .kitMenuPreview(Self.containerSentence(container))
    }
  }

  /// What picking a container changes: the schemes the toolbar lists.
  private static func containerSentence(_ container: ProjectContainer) -> String {
    switch container.kind {
    case .workspace: return "Lists \(container.fileName)’s schemes, from the projects and packages in it."
    case .project: return "Lists \(container.fileName)’s own schemes and packages."
    case .package: return "Lists the products of \(container.directory.lastPathComponent)’s Package.swift."
    }
  }

  @ViewBuilder private var schemeItems: some View {
    SchemeMenu(actions: model.services.actions, root: model.workspace.root)
  }

  @ViewBuilder private var destinationItems: some View {
    DestinationMenu(actions: model.services.actions)
  }
}

/// A row that picks one of several: the check at its end on the picked one; picking it again runs its action too.
private struct MenuPick: View {
  let title: String
  let isOn: Bool
  let action: () -> Void

  init(_ title: String, isOn: Bool, action: @escaping () -> Void) {
    self.title = title
    self.isOn = isOn
    self.action = action
  }

  var body: some View {
    Toggle(title, isOn: Binding(get: { isOn }, set: { _ in action() }))
  }
}

/// The scheme menu as a long list: over 10 schemes a filter heads it. Schemes are sorted by what they are (apps, tools,
/// then the libraries and test bundles, folded with their count in a long list), and say their toolchain only where
/// it differs from the rest's. With several project folders the selected scheme's folder is listed, the others fold
/// with their counts (a folder of one scheme stays in the list).
private struct SchemeMenu: View {
  let actions: ActionController
  let root: URL

  enum Kind: Int, CaseIterable {
    case app, tool, library, test

    init(_ scheme: ActionScheme) {
      if scheme.toolchain == .android || ActionKind.allCases.contains(where: { $0.isDistribution && scheme.supports($0) }) {
        self = .app
      } else if scheme.supports(.run) {
        self = scheme.platforms.contains(.iOS) ? .app : .tool
      } else if scheme.supports(.build) || !scheme.supports(.test) {
        self = .library
      } else {
        self = .test
      }
    }

    var section: String {
      switch self {
      case .app: return "Apps"
      case .tool: return "Tools"
      case .library: return "Libraries"
      case .test: return "Tests"
      }
    }

    /// What a row says it is while filtering.
    var word: String {
      switch self {
      case .app: return "App"
      case .tool: return "Tool"
      case .library: return "Library"
      case .test: return "Test"
      }
    }
  }

  var body: some View {
    let schemes = actions.schemes
    let isLong = schemes.count > 10
    let byFolder = Dictionary(grouping: schemes) { Self.key($0.directory) }
    let folders = byFolder.keys.sorted()
    let main =
      actions.selectedScheme.map { Self.key($0.directory) }
      ?? (byFolder[Self.key(root)] != nil ? Self.key(root) : folders.first)
    // In a long list another folder of several schemes folds; one of a single scheme stays in the list.
    let folded = isLong ? folders.filter { $0 != main && (byFolder[$0]?.count ?? 0) > 1 } : []
    let listed = schemes.filter { !folded.contains(Self.key($0.directory)) }
    if isLong {
      KitMenuFilter("Filter \(schemes.count) schemes", total: schemes.count) { "No scheme has “\($0)” in its name." }
    }
    if folded.isEmpty {
      rows(listed, main: main, headers: true, folds: isLong)
    } else {
      KitMenuSection(main.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Schemes") {
        rows(listed, main: main, headers: false, folds: true)
      }
      KitMenuSection("Other Folders") {
        ForEach(folded, id: \.self) { folder in
          let inside = byFolder[folder] ?? []
          KitSubmenu(URL(fileURLWithPath: folder).lastPathComponent, value: "\(inside.count)") {
            rows(inside, main: folder, headers: true, folds: false)
          }
        }
      }
    }
    Divider()
    Button("Refresh Schemes") { actions.scan() }
      .kitMenuPreview("Looks through \(root.lastPathComponent)’s projects and packages for schemes again.")
  }

  /// The schemes by kind: apps and tools as rows, libraries and tests folded when `folds`, the picked one above its
  /// fold so its check shows.
  @ViewBuilder private func rows(_ schemes: [ActionScheme], main: String?, headers: Bool, folds: Bool) -> some View {
    let toolchains = Dictionary(grouping: schemes, by: \.toolchain)
    let usual = toolchains.max { $0.value.count < $1.value.count }?.key
    ForEach(Kind.allCases, id: \.self) { kind in
      // The usual toolchain's first (Xcode's schemes, then the package's executables).
      let ofKind = schemes.filter { Kind($0) == kind }.enumerated()
        .sorted { ($0.element.toolchain != usual ? 1 : 0, $0.offset) < ($1.element.toolchain != usual ? 1 : 0, $1.offset) }
        .map(\.element)
      if ofKind.isEmpty {
        EmptyView()
      } else if folds, kind == .library || kind == .test, ofKind.count > 1 {
        if let picked = ofKind.first(where: { $0.id == actions.selectedScheme?.id }) {
          KitMenuSection(kind.section) {
            // Its twin in the fold is the one a filter finds.
            row(picked, kind: kind, usual: usual, main: main, filterable: false)
          }
          KitSubmenu("All \(kind.section)", value: "\(ofKind.count)") {
            ForEach(ofKind) { row($0, kind: kind, usual: usual, main: main) }
          }
        } else {
          if headers { Divider() }
          KitSubmenu(kind.section, value: "\(ofKind.count)") {
            ForEach(ofKind) { row($0, kind: kind, usual: usual, main: main) }
          }
        }
      } else if headers {
        KitMenuSection(kind.section) { ForEach(ofKind) { row($0, kind: kind, usual: usual, main: main) } }
      } else {
        ForEach(ofKind) { row($0, kind: kind, usual: usual, main: main) }
      }
    }
  }

  /// A scheme by its name; at its end its toolchain where it isn't the usual one, else its folder when that isn't
  /// the list's.
  private func row(
    _ scheme: ActionScheme, kind: Kind, usual: Toolchain?, main: String?, filterable: Bool = true
  ) -> some View {
    let word =
      scheme.toolchain != usual
      ? scheme.toolchain.displayName : Self.key(scheme.directory) != main ? scheme.projectName : nil
    return MenuPick(scheme.name, isOn: actions.selectedScheme?.id == scheme.id) { actions.selectedSchemeID = scheme.id }
      .kitMenuHint(word)
      .kitMenuPreview(Self.sentence(scheme))
      // No words never match: hidden while filtering.
      .kitMenuFilter(filterable ? scheme.name : "", kind: kind.word)
  }

  private static func key(_ folder: URL) -> String { folder.standardizedFileURL.path }

  /// What a scheme does, with what, from where: "Runs, tests and builds with Xcode, from Code.xcodeproj."
  static func sentence(_ scheme: ActionScheme) -> String {
    let verbs: [(ActionKind, String)] = [(.run, "runs"), (.test, "tests"), (.build, "builds")]
    let does = verbs.filter { scheme.supports($0.0) }.map(\.1)
    let list =
      does.count > 1 ? does.dropLast().joined(separator: ", ") + " and " + does.last! : does.first ?? "has no actions"
    let place = scheme.xcodeContainer.map { URL(fileURLWithPath: $0).lastPathComponent } ?? scheme.projectName
    return list.prefix(1).uppercased() + list.dropFirst() + " with \(scheme.toolchain.displayName), from \(place)."
  }
}

/// Where to run: this computer, other machines and containers as rows; iPhones and iPads as tiles, three across,
/// under a heading per family that says the iOS version they share (a tile says only what differs: its chip, another
/// runtime, Booted); Android's as rows. Over 10 destinations a filter heads it.
private struct DestinationMenu: View {
  let actions: ActionController

  /// A group of the menu: rows, or tiles of one family.
  struct Family: Identifiable {
    var title: String?
    var destinations: [RunDestination]
    var tiles = false
    /// The family's name, which its tiles leave out ("iPhone").
    var prefix: String?
    var kind: String
    var id: String { title ?? kind }
  }

  var body: some View {
    let destinations = actions.destinations
    let selected = actions.selectedDestination?.id
    let groups = Self.families(destinations)
    if destinations.count > 10 {
      KitMenuFilter("Filter \(destinations.count) devices", total: destinations.count) {
        "No device has “\($0)” in its name."
      }
    }
    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
      // Rows are divided; one family's tiles follow another's under its heading.
      if index > 0, !(group.tiles && groups[index - 1].tiles) { Divider() }
      if group.tiles {
        tiles(group, selected: selected)
      } else if let title = group.title {
        KitMenuSection(title) { rows(group, selected: selected) }
      } else {
        rows(group, selected: selected)
      }
    }
    if destinations.isEmpty {
      KitMenuSection(actions.isLoadingDestinations ? "Loading…" : "No Destinations") {}
    }
    Divider()
    Button("Refresh Devices") { actions.refreshDestinations() }
      .kitMenuPreview("Lists the simulators, connected devices and machines again.")
  }

  private func rows(_ group: Family, selected: String?) -> some View {
    ForEach(group.destinations) { destination in
      MenuPick(destination.name, isOn: destination.id == selected) { actions.selectedDestinationID = destination.id }
        .kitMenuHint(destination.detail)
        .kitMenuFilter(destination.name, kind: group.kind)
        .kitMenuPreview(Self.sentence(destination))
        .disabled(!destination.isAvailable)
    }
  }

  private func tiles(_ group: Family, selected: String?) -> some View {
    let shared = Self.mostCommon(group.destinations.compactMap(Self.version))
    return KitMenuSection(group.title ?? "", value: shared) {
      KitMenuGrid {
        ForEach(group.destinations) { destination in
          let version = Self.version(destination)
          let name = Self.tileName(destination.name, family: group.prefix)
          let detail = [
            name.chip,
            version != shared ? version?.replacingOccurrences(of: "iOS ", with: "") : nil,
            version == nil ? destination.detail : nil,
            Self.isBooted(destination) ? "Booted" : nil,
          ]
          .compactMap { $0 }.joined(separator: " · ")
          KitMenuTile(
            name.title, systemImage: destination.symbolName, detail: detail.isEmpty ? nil : detail,
            isOn: destination.id == selected
          ) { actions.selectedDestinationID = destination.id }
          .kitMenuFilter(destination.name, kind: group.kind)
          .kitMenuPreview(Self.sentence(destination))
          .disabled(!destination.isAvailable)
        }
      }
    }
  }

  /// Where Run puts the app, for the menu's panel.
  static func sentence(_ destination: RunDestination) -> String {
    let name = [destination.name, destination.detail].compactMap { $0 }.joined(separator: ", ")
    guard destination.isAvailable else { return "\(name) can’t run apps now." }
    switch destination.kind {
    case .mac: return "Runs on this Mac."
    case .iOSSimulator: return "Runs in the \(name) simulator\(isBooted(destination) ? "" : ", starting it first")."
    case .iOSDevice, .androidDevice: return "Installs on \(name) and runs it there."
    case .androidEmulator, .androidVirtualDevice: return "Runs on the \(name) emulator."
    case .remote: return "Runs on \(name)."
    case .container: return "Runs in a container on \(name)."
    }
  }

  /// The groups in menu order, those with nothing left out.
  static func families(_ destinations: [RunDestination]) -> [Family] {
    func of(_ kinds: Set<RunDestination.Kind>) -> [RunDestination] { destinations.filter { kinds.contains($0.kind) } }
    let simulators = of([.iOSSimulator])
    let groups = [
      Family(destinations: of([.mac]), kind: "Computer"),
      Family(title: "Other Machines", destinations: of([.remote]), kind: "Machine"),
      Family(title: "Containers", destinations: of([.container]), kind: "Container"),
      Family(title: "Devices", destinations: of([.iOSDevice]), tiles: true, kind: "Device"),
      Family(
        title: "iPhone Simulators", destinations: simulators.filter { !$0.name.contains("iPad") }, tiles: true,
        prefix: "iPhone", kind: "iPhone Simulator"),
      Family(
        title: "iPad Simulators", destinations: simulators.filter { $0.name.contains("iPad") }, tiles: true,
        prefix: "iPad", kind: "iPad Simulator"),
      Family(title: "Android Devices", destinations: of([.androidDevice]), kind: "Android Device"),
      Family(
        title: "Android Emulators", destinations: of([.androidEmulator, .androidVirtualDevice]), kind: "Android Emulator"),
    ]
    return groups.filter { !$0.destinations.isEmpty }
  }

  /// "iOS 27.2" from a simulator's or a device's detail; nil when it says something else (Unavailable).
  static func version(_ destination: RunDestination) -> String? {
    guard let detail = destination.detail?.replacingOccurrences(of: " (Booted)", with: ""), detail.hasPrefix("iOS ")
    else { return nil }
    return detail
  }

  static func isBooted(_ destination: RunDestination) -> Bool {
    destination.detail?.hasSuffix("(Booted)") ?? false
  }

  /// The most common value, the first of a tie (the newest runtime: simulators are listed newest first).
  static func mostCommon(_ values: [String]) -> String? {
    var counts: [String: Int] = [:]
    for value in values { counts[value, default: 0] += 1 }
    // `max` keeps the first of equal ones.
    return values.max { counts[$0, default: 0] < counts[$1, default: 0] }
  }

  /// A tile's name without its family ("18 Pro" for "iPhone 18 Pro"; "iPad" itself stays) and the chip in its
  /// parentheses ("iPad Air 11-inch (M4)": "Air 11-inch", "M4").
  static func tileName(_ name: String, family: String?) -> (title: String, chip: String?) {
    var title = name
    var chip: String?
    if title.hasSuffix(")"), let open = title.lastIndex(of: "("), open > title.startIndex {
      chip = String(title[title.index(after: open)..<title.index(before: title.endIndex)])
      title = title[..<open].trimmingCharacters(in: .whitespaces)
    }
    if let family, title.hasPrefix(family + " ") { title = String(title.dropFirst(family.count + 1)) }
    return (title, chip)
  }
}

/// The project's issues as the kit's menu: a section per file, each issue a row with its severity and its line;
/// picking one opens the line.
struct IssuesMenu: View {
  let services: ProjectServices

  var body: some View {
    let groups = Dictionary(grouping: services.issues) { $0.url }
    let files = groups.keys.sorted { ($0?.path ?? "") < ($1?.path ?? "") }
    ForEach(files, id: \.self) { file in
      if file != files.first { Divider() }
      KitMenuSection(file.map { services.workspace.tree.relativePath(of: $0) } ?? "Other") {
        ForEach(groups[file] ?? []) { issue in
          Button {
            services.open(issue)
          } label: {
            Label {
              // Long messages end in "…" (the tooltip has all of it) rather than widening the menu.
              Text(issue.message)
                .truncationMode(.tail)
                .frame(maxWidth: 420, alignment: .leading)
            } icon: {
              Image(systemName: Self.symbol(issue.severity))
                .foregroundStyle(Self.hue(issue.severity).fill)
            }
          }
          .kitMenuHint(issue.line.map { "Line \($0)\(issue.source == .languageServer ? "" : " · Build")" })
          .kitMenuPreview(Self.sentence(issue.message, line: issue.line))
          .help(issue.message)
        }
      }
    }
  }

  /// The issue in full, then where picking it goes: "Value of type ‘Trip’ has no member ‘title’. Goes to line 88."
  static func sentence(_ message: String, line: Int?) -> String {
    let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let stop = message.last.map { ".!?".contains($0) } == true ? "" : "."
    return message + stop + (line.map { " Goes to line \($0)." } ?? "")
  }

  static func symbol(_ severity: LineAnnotation.Severity) -> String {
    switch severity {
    case .error: return "xmark.octagon.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .note: return "info.circle.fill"
    }
  }

  static func hue(_ severity: LineAnnotation.Severity) -> Hue {
    switch severity {
    case .error: return .red
    case .warning: return .yellow
    case .note: return .gray
    }
  }
}
