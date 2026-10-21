import CodeActions
import SwiftUI

/// A project's toolbar and console: where it runs (the devices that have it), its scheme, Build, Test, Clean and
/// Stop, the progress, then the log or the issues; the files there are a push away.
struct ProjectScreen: View {
  let project: RemoteProject
  @State private var session: ProjectSession
  @State private var pane = Pane.log

  enum Pane: String, CaseIterable, Identifiable {
    case log = "Log"
    case issues = "Issues"
    var id: Self { self }
  }

  init(project: RemoteProject) {
    self.project = project
    _session = State(initialValue: ProjectSession(project: project))
  }

  var body: some View {
    Group {
      switch session.phase {
      case .loading(let message):
        ProgressView(message).frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        ContentUnavailableView {
          Label("Couldn’t Open \(project.name)", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          Button("Try Again") { Task { await session.open() } }
        }
      case .ready:
        if let controller = session.controller { content(controller) }
      }
    }
    .navigationTitle(project.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if let source = session.source {
        NavigationLink {
          RemoteFolderView(session: session, path: source.directory, title: project.name)
        } label: {
          Label("Files on \(source.name)", systemImage: "folder")
        }
      }
    }
    .task { await session.open() }
    .onDisappear { session.close() }
  }

  @ViewBuilder private func content(_ controller: ActionController) -> some View {
    VStack(spacing: 0) {
      ActionBar(controller: controller)
      Picker("Show", selection: $pane) {
        ForEach(Pane.allCases) { pane in
          if pane == .issues, !controller.issues.isEmpty {
            Text("Issues (\(controller.issues.count))").tag(pane)
          } else {
            Text(pane.rawValue).tag(pane)
          }
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.bottom, 8)
      Divider()
      switch pane {
      case .log: LogView(log: controller.log)
      case .issues: IssuesView(issues: controller.issues)
      }
    }
  }
}

/// Destination, scheme, the actions and their progress.
struct ActionBar: View {
  let controller: ActionController

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Menu {
          Picker("Scheme", selection: schemeBinding) {
            ForEach(controller.schemes) { Text($0.name).tag(Optional($0.id)) }
          }
        } label: {
          Label(controller.selectedScheme?.name ?? (controller.isScanning ? "Finding schemes…" : "No schemes"),
            systemImage: "hammer")
        }
        .disabled(controller.schemes.isEmpty)
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        Menu {
          Picker("Run On", selection: destinationBinding) {
            ForEach(controller.destinations) { destination in
              Text(destination.name + (destination.detail.map { " (\($0))" } ?? "")).tag(Optional(destination.id))
            }
          }
        } label: {
          Label(controller.selectedDestination?.name ?? "No device", systemImage: "desktopcomputer")
        }
        .disabled(controller.destinations.isEmpty)
        Spacer()
      }
      .lineLimit(1)
      HStack(spacing: 10) {
        ForEach([ActionKind.build, .test, .clean], id: \.self) { kind in
          Button(kind.title) { controller.perform(kind) }
            .buttonStyle(.bordered)
            .disabled(!controller.canPerform(kind) || controller.selectedDestination == nil)
        }
        Spacer()
        if controller.isRunning {
          Button(role: .destructive) { controller.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            .buttonStyle(.borderedProminent)
        }
      }
      StatusLine(controller: controller)
    }
    .padding()
  }

  private var schemeBinding: Binding<String?> {
    Binding { controller.selectedScheme?.id } set: { controller.selectedSchemeID = $0 }
  }

  private var destinationBinding: Binding<String?> {
    Binding { controller.selectedDestination?.id } set: { controller.selectedDestinationID = $0 }
  }
}

struct StatusLine: View {
  let controller: ActionController

  var body: some View {
    switch controller.state {
    case .idle:
      Text(controller.isScanning ? "Reading the project…" : "Ready").foregroundStyle(.secondary).font(.callout)
    case .running(let kind):
      VStack(alignment: .leading, spacing: 4) {
        if let fraction = controller.progress?.fraction {
          ProgressView(value: fraction)
        } else {
          ProgressView().progressViewStyle(.linear)
        }
        Text("\(kind.progressTitle) — \(controller.progress?.message ?? controller.stepTitle ?? "")")
          .font(.callout).foregroundStyle(.secondary).lineLimit(1)
      }
    case .succeeded(let kind, _):
      Label("\(kind.title) succeeded", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
    case .failed(let kind, _, let summary):
      Label("\(kind.title) failed: \(summary)", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
    case .stopped(let kind, _):
      Label("\(kind.title) stopped", systemImage: "stop.circle").foregroundStyle(.secondary).font(.callout)
    }
  }
}

/// The action's output as it arrives, following the end.
struct LogView: View {
  let log: ActionLog

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView([.vertical, .horizontal]) {
        LazyVStack(alignment: .leading, spacing: 1) {
          let entries = log.entries
          ForEach(entries.indices, id: \.self) { index in
            let entry = entries[index]
            Text(entry.text.isEmpty ? " " : entry.text)
              .foregroundStyle(color(entry.kind))
              .fontWeight(entry.kind == .command ? .semibold : .regular)
              .id(index)
          }
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .padding()
      }
      .onChange(of: log.revision) { _, _ in
        if let last = log.entries.indices.last { proxy.scrollTo(last, anchor: .bottomLeading) }
      }
    }
  }

  private func color(_ kind: ActionLog.Entry.Kind) -> Color {
    switch kind {
    case .output: .primary
    case .command: .accentColor
    case .status: .secondary
    case .failure: .red
    }
  }
}

struct IssuesView: View {
  let issues: [BuildIssue]

  var body: some View {
    if issues.isEmpty {
      ContentUnavailableView("No Issues", systemImage: "checkmark.circle")
    } else {
      List(issues) { issue in
        VStack(alignment: .leading, spacing: 4) {
          Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(issue.severity == .error ? .red : .orange)
          if let url = issue.url {
            Text(url.lastPathComponent + (issue.line.map { ":\($0)" } ?? ""))
              .font(.caption.monospaced()).foregroundStyle(.secondary)
          }
        }
      }
      .listStyle(.plain)
    }
  }
}
