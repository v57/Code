import CodeKit
import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

extension View {
  /// Xcode's toolbar as the kit's bar: Run and Stop in a tool group before the project's rich title (its live icon
  /// carries the running action, its meta line says what the project is doing), and the issue counts and
  /// scheme › destination at the end, which go icon-only when the window narrows. Without actions (Settings ›
  /// Tools), the project's name alone.
  func projectToolbar(model: WindowModel, actionsEnabled: Bool) -> some View {
    kitToolbar(model.workspace.name) {
      HStack(spacing: KitMetrics.gutter) {
        if actionsEnabled { RunTools(model: model) }
        ProjectTitle(model: model, showsStatus: actionsEnabled)
      }
    } tools: {
      if actionsEnabled { SchemeTools(model: model) }
    }
  }
}

/// ▶ (Run; its context menu has Test, Build and Clean) and ■ (Stop).
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
        Button("Run") { model.perform(.run) }
          .disabled(!actions.canPerform(.run))
        Button("Test") { model.perform(.test) }
          .disabled(!actions.canPerform(.test))
        Button("Build") { model.perform(.build) }
          .disabled(!actions.canPerform(.build))
        Divider()
        Button("Clean") { model.perform(.clean) }
          .disabled(!actions.canPerform(.clean))
      }
      Button("Stop", systemImage: "stop.fill") { actions.stop() }
        .kitHelp("Stop", shortcut: "⌘.")
        .disabled(!actions.isRunning)
    }
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
    let scheme = actions.selectedScheme?.name ?? ""
    let destination = actions.selectedDestination?.name ?? RunDestination.localName
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

/// The issue counts (they open the issue list), then "Scheme › Destination": two of the kit's menus in one tool group.
private struct SchemeTools: View {
  let model: WindowModel
  /// The window's account's vault, whose Hub devices are the remote destinations.
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
          .kitHelp("Show Issues", shortcut: "⌘5")
          .kitMenu(isPresented: $model.isIssuesPresented) { IssuesMenu(services: services) }
        }
      }
      ToolGroup {
        Button {
          model.openMenu = .scheme
        } label: {
          Label(
            actions.selectedScheme?.name ?? (actions.isScanning ? "Finding Schemes…" : "No Scheme"),
            systemImage: actions.selectedScheme?.toolchain.symbolName ?? "square.dashed")
        }
        .kitMenu(isPresented: model.isPresented(.scheme)) { schemeItems }
        .kitHelp("Choose a scheme")
        Image(systemName: "chevron.right")
          .kitFont(.caption)
          .imageScale(.small)
          .fontWeight(.semibold)
          .foregroundStyle(.kitTertiary)
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
    // Other machines that have this project: the devices on the account's Hubs, kept current as the vault changes.
    .onChange(of: remoteTargets, initial: true) { _, targets in
      actions.remoteTargets = targets
      actions.remoteLoginPassword = { [vault] target in
        vault.flatMap { RemoteDestinations.loginPassword(for: target, vault: $0) }
      }
    }
  }

  @ViewBuilder private var schemeItems: some View {
    let actions = model.services.actions
    let projects = Dictionary(grouping: actions.schemes, by: \.directory)
    let folders = projects.keys.sorted { $0.path < $1.path }
    ForEach(folders, id: \.self) { folder in
      if folders.count > 1 {
        if folder != folders.first { Divider() }
        KitMenuSection(folder.lastPathComponent) { schemeRows(projects[folder] ?? [], projectCount: projects.count) }
      } else {
        schemeRows(projects[folder] ?? [], projectCount: projects.count)
      }
    }
    Divider()
    Button("Refresh Schemes") { actions.scan() }
  }

  private func schemeRows(_ schemes: [ActionScheme], projectCount: Int) -> some View {
    let actions = model.services.actions
    return ForEach(schemes) { scheme in
      Button {
        actions.selectedSchemeID = scheme.id
      } label: {
        Label(
          projectCount > 1 || scheme.toolchain != .xcode
            ? "\(scheme.name) — \(scheme.toolchain.displayName)" : scheme.name,
          systemImage: actions.selectedScheme?.id == scheme.id ? "checkmark" : scheme.toolchain.symbolName)
      }
    }
  }

  @ViewBuilder private var destinationItems: some View {
    let actions = model.services.actions
    let sections = Dictionary(grouping: actions.destinations, by: \.section)
    let order = [
      RunDestination.localName, "Other Machines", "iOS Devices", "iOS Simulators", "Android Devices", "Android Emulators",
    ]
    let shown = order.filter { sections[$0] != nil }
    ForEach(shown, id: \.self) { section in
      if section != shown.first { Divider() }
      KitMenuSection(section) {
        ForEach(sections[section] ?? []) { destination in
          Button {
            actions.selectedDestinationID = destination.id
          } label: {
            Label(
              destination.detail.map { "\(destination.name) (\($0))" } ?? destination.name,
              systemImage: actions.selectedDestination?.id == destination.id
                ? "checkmark" : destination.symbolName)
          }
          .disabled(!destination.isAvailable)
        }
      }
    }
    if actions.destinations.isEmpty {
      KitMenuSection(actions.isLoadingDestinations ? "Loading…" : "No Destinations") {}
    }
    Divider()
    Button("Refresh Devices") { actions.refreshDestinations() }
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
          .help(issue.message)
        }
      }
    }
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
