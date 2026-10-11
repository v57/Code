import CodeKit
import SwiftUI

/// Xcode's toolbar: Run and Stop, the scheme and run destination, and the
/// activity view with progress and issue counts.
struct ProjectToolbar: ToolbarContent {
  let model: WindowModel

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      RunButtons(model: model)
    }
    ToolbarItem(placement: .principal) {
      HStack(spacing: 8) {
        SchemePicker(actions: model.services.actions)
          .frame(maxWidth: 300)
        ActivityView(model: model)
      }
      .fixedSize()
    }
  }
}

/// ▶ (Run; hold for Test, Build, Clean) and ■ (Stop).
private struct RunButtons: View {
  let model: WindowModel

  var body: some View {
    let actions = model.services.actions
    Menu {
      Button("Run") { model.perform(.run) }
        .disabled(!actions.canPerform(.run))
      Button("Test") { model.perform(.test) }
        .disabled(!actions.canPerform(.test))
      Button("Build") { model.perform(.build) }
        .disabled(!actions.canPerform(.build))
      Divider()
      Button("Clean") { model.perform(.clean) }
        .disabled(!actions.canPerform(.clean))
    } label: {
      Label("Run", systemImage: "play.fill")
    } primaryAction: {
      model.perform(actions.canPerform(.run) ? .run : .build)
    }
    .menuIndicator(.hidden)
    .help(actions.canPerform(.run) ? "Run (⌘R)" : "Build (⌘B)")
    .disabled(actions.selectedScheme == nil)

    Button {
      actions.stop()
    } label: {
      Label("Stop", systemImage: "stop.fill")
    }
    .help("Stop (⌘.)")
    .disabled(!actions.isRunning)
  }
}

/// "Scheme › Destination": two menus in one capsule.
private struct SchemePicker: View {
  let actions: ActionController

  var body: some View {
    HStack(spacing: 2) {
      Menu {
        schemeItems
      } label: {
        HStack(spacing: 5) {
          Image(systemName: actions.selectedScheme?.toolchain.symbolName ?? "square.dashed")
          Text(actions.selectedScheme?.name ?? (actions.isScanning ? "Finding Schemes…" : "No Scheme"))
            .lineLimit(1)
        }
      }
      .help("Choose a scheme")
      Image(systemName: "chevron.compact.right")
        .foregroundStyle(.tertiary)
      Menu {
        destinationItems
      } label: {
        HStack(spacing: 5) {
          Image(systemName: actions.selectedDestination?.symbolName ?? "questionmark.app.dashed")
          Text(actions.selectedDestination?.name ?? (actions.isLoadingDestinations ? "Loading…" : "No Destination"))
            .lineLimit(1)
        }
      }
      .help("Choose where to run")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .font(.system(size: 12))
    .fixedSize()
    .padding(.horizontal, 8)
    .frame(height: 24)
  }

  @ViewBuilder private var schemeItems: some View {
    let projects = Dictionary(grouping: actions.schemes, by: \.directory)
    let folders = projects.keys.sorted { $0.path < $1.path }
    ForEach(folders, id: \.self) { folder in
      Section(folders.count > 1 ? folder.lastPathComponent : "") {
        ForEach(projects[folder] ?? []) { scheme in
          Button {
            actions.selectedSchemeID = scheme.id
          } label: {
            Label(
              projects.count > 1 || scheme.toolchain != .xcode
                ? "\(scheme.name) — \(scheme.toolchain.displayName)" : scheme.name,
              systemImage: actions.selectedScheme?.id == scheme.id ? "checkmark" : scheme.toolchain.symbolName)
          }
        }
      }
    }
    Divider()
    Button("Refresh Schemes") { actions.scan() }
  }

  @ViewBuilder private var destinationItems: some View {
    let sections = Dictionary(grouping: actions.destinations, by: \.section)
    let order = ["My Mac", "iOS Devices", "iOS Simulators", "Android Devices", "Android Emulators"]
    ForEach(order.filter { sections[$0] != nil }, id: \.self) { section in
      Section(section) {
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
      Text(actions.isLoadingDestinations ? "Loading…" : "No Destinations")
    }
    Divider()
    Button("Refresh Devices") { actions.refreshDestinations() }
  }
}

/// The activity view: what the project is doing, with a progress bar while
/// an action runs, and the issue counts, which open the issue list.
private struct ActivityView: View {
  let model: WindowModel

  var body: some View {
    @Bindable var model = model
    let services = model.services
    let actions = services.actions
    HStack(spacing: 8) {
      if let scheme = actions.selectedScheme {
        Text(scheme.name)
          .fontWeight(.medium)
          .lineLimit(1)
          .layoutPriority(1)
        Rectangle()
          .fill(.separator)
          .frame(width: 1, height: 12)
      }
      Text(status)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      IssueCounts(errors: services.errorCount, warnings: services.warningCount) {
        model.isIssuesPresented.toggle()
      }
      .popover(isPresented: $model.isIssuesPresented, arrowEdge: .bottom) {
        IssuesList(services: services) { model.isIssuesPresented = false }
      }
    }
    .font(.system(size: 12))
    .padding(.horizontal, 10)
    .frame(width: 420, height: 24)
    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
    .overlay(alignment: .bottom) {
      if actions.isRunning {
        Group {
          if let fraction = actions.progress?.fraction {
            ProgressView(value: fraction)
          } else {
            ProgressView()
          }
        }
        .progressViewStyle(.linear)
        .controlSize(.mini)
        .tint(.accentColor)
        .padding(.horizontal, 4)
        .offset(y: 4)
        .frame(height: 3)
        .clipped()
      }
    }
    .help(status)
  }

  private var status: String {
    let actions = model.services.actions
    let scheme = actions.selectedScheme?.name ?? ""
    let destination = actions.selectedDestination?.name ?? "My Mac"
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
      return "\(what) | \(Self.time(date))"
    case .failed(let kind, let date, let message):
      return "\(kind.title) Failed | \(message) | \(Self.time(date))"
    case .stopped(_, let date):
      return "Stopped | \(Self.time(date))"
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

private struct IssueCounts: View {
  let errors: Int
  let warnings: Int
  let action: () -> Void

  var body: some View {
    if errors > 0 || warnings > 0 {
      Button(action: action) {
        HStack(spacing: 6) {
          if errors > 0 {
            Label("\(errors)", systemImage: "xmark.octagon.fill")
              .foregroundStyle(.red)
          }
          if warnings > 0 {
            Label("\(warnings)", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.yellow)
          }
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 11, weight: .medium).monospacedDigit())
      }
      .buttonStyle(.plain)
      .help("Show issues")
    }
  }
}

/// The project's issues by file; a click opens the line.
struct IssuesList: View {
  let services: ProjectServices
  let dismiss: () -> Void

  var body: some View {
    let issues = services.issues
    let groups = Dictionary(grouping: issues) { $0.url }
    let files = groups.keys.sorted { ($0?.path ?? "") < ($1?.path ?? "") }
    List {
      ForEach(files, id: \.self) { file in
        Section(file.map { services.workspace.tree.relativePath(of: $0) } ?? "Other") {
          ForEach(groups[file] ?? []) { issue in
            Button {
              services.open(issue)
              dismiss()
            } label: {
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: Self.symbol(issue.severity))
                  .foregroundStyle(Self.color(issue.severity))
                VStack(alignment: .leading, spacing: 2) {
                  Text(issue.message)
                    .lineLimit(3)
                  if let line = issue.line {
                    Text("Line \(line)\(issue.source == .languageServer ? "" : " · Build")")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .frame(width: 460, height: min(480, CGFloat(issues.count) * 44 + CGFloat(files.count) * 28 + 20))
  }

  static func symbol(_ severity: LineAnnotation.Severity) -> String {
    switch severity {
    case .error: return "xmark.octagon.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .note: return "info.circle.fill"
    }
  }

  static func color(_ severity: LineAnnotation.Severity) -> Color {
    switch severity {
    case .error: return .red
    case .warning: return .yellow
    case .note: return .secondary
    }
  }
}
