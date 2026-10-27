import CodeActions
import CodeIcons
import ComponentKit
import SSHKit
import SwiftUI

/// A project under the kit's bar: its live title says what it is doing; Build, Test, Clean and Stop, its scheme and
/// the device it runs on (one of those that have it), and its files there a push away. Under it, the log as run
/// blocks or the issues. On iPad the actions lead the bar as on the Mac; on iPhone they sit in the bottom bar and the
/// scheme › device under the title.
struct ProjectScreen: View {
  let project: RemoteProject
  @State private var session: ProjectSession
  @State private var pane = Pane.log
  @State private var showsFiles = false
  /// A file pushed straight from here (Debug: `CODE_DEBUG_SHOW=file:<path>`).
  @State private var shownFile: SFTPFileInfo?
  @Environment(\.kitIdiom) private var idiom

  enum Pane: Hashable {
    case log, issues
  }

  init(project: RemoteProject) {
    self.project = project
    _session = State(initialValue: ProjectSession(project: project))
  }

  var body: some View {
    Group {
      switch session.phase {
      case .loading(let message):
        EmptyState(systemImage: "chevron.left.forwardslash.chevron.right", title: message, status: .working)
      case .failed(let message):
        EmptyState(
          systemImage: "exclamationmark.triangle", title: "Couldn’t Open \(project.name)", message: message,
          status: .failed(nil)
        ) {
          Button("Try Again", systemImage: "arrow.clockwise") { Task { await session.open() } }
            .buttonStyle(.kit)
        }
      case .ready:
        if let controller = session.controller { content(controller) }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.kitWindow)
    .kitPane(.content)
    .kitToolbar(project.name, title: {
      HStack(spacing: KitMetrics.gutter) {
        if idiom != .phone, let controller = session.controller { ActionTools(controller: controller) }
        ProjectTitle(project: project, session: session, showsDevice: idiom != .phone)
      }
    }) {
      if idiom != .phone, let controller = session.controller { SchemeTools(controller: controller, session: session) }
      if let source = session.source {
        ToolGroup(iconOnly: true) {
          Button("Files on \(source.name)", systemImage: "folder") { showsFiles = true }
        }
      }
    }
    .modifier(PhoneActionBar(controller: idiom == .phone ? session.controller : nil))
    .navigationBarBackButtonHidden(true)
    .navigationDestination(isPresented: $showsFiles) {
      if let source = session.source {
        RemoteFolderView(session: session, path: source.directory, title: project.name, isRoot: true)
      }
    }
    .navigationDestination(item: $shownFile) { entry in RemoteFileView(session: session, entry: entry) }
    .task {
      await session.open()
      #if DEBUG
        await debugShow()
      #endif
    }
    .onDisappear { session.close() }
  }

  #if DEBUG
    /// `CODE_DEBUG_SHOW`: `issues`, `files`, or `file:<path in the project>`.
    private func debugShow() async {
      guard let show = DebugLaunch.show, let source = session.source else { return }
      if show == "issues" { pane = .issues }
      if show == "files" { showsFiles = true }
      if show.hasPrefix("file:") {
        let path = source.directory + "/" + show.dropFirst(5)
        shownFile = try? await session.fileClient().stat(path)
      }
    }
  #endif

  @ViewBuilder private func content(_ controller: ActionController) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      if idiom == .phone { SchemeTools(controller: controller, session: session) }
      KitSegmented(
        selection: $pane,
        segments: [
          KitSegment("Log", value: .log),
          KitSegment("Issues", value: .issues, count: controller.issues.isEmpty ? nil : controller.issues.count),
        ]
      )
      .kitSegmentedStyle(idiom == .phone ? .wide : .automatic)
      switch pane {
      case .log: LogView(controller: controller)
      case .issues: IssuesView(controller: controller, device: session.source?.name)
      }
    }
    .padding(.horizontal, KitMetrics.gutter + 4)
    .padding(.top, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

/// The project's name over what it is doing ("Testing: Compiling AtlasTests…", "Test failed: 2 errors"), the
/// action's state in the live icon, and the kit's success or failure effect as it ends.
struct ProjectTitle: View {
  let project: RemoteProject
  let session: ProjectSession
  /// iPad adds the device to a finished action's line ("on studio-mac").
  var showsDevice: Bool

  var body: some View {
    KitTitle(
      project.name, meta: meta, systemImage: "chevron.left.forwardslash.chevron.right", hue: .orange, status: status)
      .status(status)
  }

  private var status: WorkStatus {
    switch session.phase {
    case .loading: return .working
    case .failed: return .failed(nil)
    case .ready: break
    }
    guard let controller = session.controller else { return .idle }
    switch controller.state {
    case .idle: return controller.isScanning ? .working : .idle
    case .running: return .working(progress: controller.progress?.fraction)
    case .succeeded: return .done
    case .failed(_, _, let message): return .failed(message)
    case .stopped: return .paused()
    }
  }

  private var meta: [String] {
    switch session.phase {
    case .loading(let message): return [message]
    case .failed: return ["Couldn’t open"]
    case .ready: break
    }
    guard let controller = session.controller else { return [] }
    let device = showsDevice ? controller.selectedDestination.map { "on \($0.name)" } : nil
    switch controller.state {
    case .idle:
      if controller.isScanning { return ["Reading the project…"] }
      return [controller.schemes.isEmpty ? "No schemes" : "Ready"]
    case .running(let kind):
      let detail = controller.progress?.message ?? controller.stepTitle
      return [detail.map { $0.isEmpty ? kind.progressTitle : "\(kind.progressTitle): \($0)" } ?? kind.progressTitle]
    case .succeeded(let kind, _):
      return ["\(kind.title) succeeded"] + [device].compactMap { $0 }
    case .failed(let kind, _, let summary):
      return ["\(kind.title) failed: \(summary)"] + [device].compactMap { $0 }
    case .stopped(let kind, _):
      return ["\(kind.title) stopped"]
    }
  }
}

/// Build, Test and Clean, then Stop (red) while one runs: icons in one tool group, as the Mac's ▶ ■.
struct ActionTools: View {
  let controller: ActionController

  var body: some View {
    ToolGroup(iconOnly: true) {
      ForEach([ActionKind.build, .test, .clean], id: \.self) { kind in
        Button(kind.title, systemImage: ActionTools.symbol(kind)) { controller.perform(kind) }
          .disabled(!controller.canPerform(kind) || controller.selectedDestination == nil || controller.isRunning)
      }
      if controller.isRunning { StopButton(controller: controller) }
    }
  }

  static func symbol(_ kind: ActionKind) -> String {
    switch kind {
    case .build: "hammer"
    case .test: "testtube.2"
    case .clean: "trash"
    default: "terminal"
    }
  }
}

/// Stop, its square in red.
struct StopButton: View {
  let controller: ActionController

  var body: some View {
    Button {
      controller.stop()
    } label: {
      Label {
        Text("Stop")
      } icon: {
        Image(systemName: "stop.fill").foregroundStyle(Hue.red.fill)
      }
    }
  }
}

/// iPhone: Build, Test and Clean in the bottom bar, and Stop while one runs.
private struct PhoneActionBar: ViewModifier {
  let controller: ActionController?

  func body(content: Content) -> some View {
    if let controller {
      content.kitBottomBar(searchText: nil) {
        ForEach([ActionKind.build, .test, .clean], id: \.self) { kind in
          Button(kind.title, systemImage: ActionTools.symbol(kind)) { controller.perform(kind) }
            .disabled(!controller.canPerform(kind) || controller.selectedDestination == nil || controller.isRunning)
        }
        if controller.isRunning { StopButton(controller: controller).labelStyle(.iconOnly) }
      }
    } else {
      content
    }
  }
}

/// "Scheme › Device": two of the kit's menus in one tool group. The devices are the user's others that have the
/// project.
struct SchemeTools: View {
  let controller: ActionController
  let session: ProjectSession
  @State private var showsSchemes = false
  @State private var showsDevices = false
  /// The Mac whose login password Login Keychain asks for, having none saved.
  @State private var passwordTarget: SSHExecutor.Target?
  /// The Mac Signing Keychain was just picked for: how to set it up there.
  @State private var setupTarget: SSHExecutor.Target?

  var body: some View {
    ToolGroup {
      Button {
        showsSchemes = true
      } label: {
        Label(
          controller.selectedScheme?.name ?? (controller.isScanning ? "Finding Schemes…" : "No Scheme"),
          systemImage: controller.selectedScheme?.toolchain.symbolName ?? "square.dashed")
      }
      .disabled(controller.schemes.isEmpty)
      .kitMenu(isPresented: $showsSchemes) {
        ForEach(controller.schemes) { scheme in
          Button {
            controller.selectedSchemeID = scheme.id
          } label: {
            Label(
              scheme.name,
              systemImage: controller.selectedScheme?.id == scheme.id ? "checkmark" : scheme.toolchain.symbolName)
          }
        }
      }
      Image(systemName: "chevron.right")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.kitTertiary)
      Button {
        showsDevices = true
      } label: {
        Label(
          controller.selectedDestination?.name ?? "No Device",
          systemImage: controller.selectedDestination?.symbolName ?? "questionmark.app.dashed")
      }
      .disabled(controller.destinations.isEmpty)
      .kitMenu(isPresented: $showsDevices) {
        KitMenuSection("Other Machines") {
          ForEach(controller.destinations) { destination in
            Button {
              controller.selectedDestinationID = destination.id
            } label: {
              Label(
                destination.detail.map { "\(destination.name) (\($0))" } ?? destination.name,
                systemImage: controller.selectedDestination?.id == destination.id ? "checkmark" : destination.symbolName)
            }
            .disabled(!destination.isAvailable)
          }
        }
        if let target = controller.remoteTarget(for: controller.selectedDestination),
          controller.selectedScheme?.toolchain == .xcode
        {
          KitMenuSection("Signing") {
            ForEach(RemoteSigning.allCases, id: \.self) { signing in
              Button {
                pick(signing, for: target)
              } label: {
                Label(
                  signing.title,
                  systemImage: (target.signing ?? .unsigned) == signing ? "checkmark" : signing.symbolName)
              }
            }
          }
        }
      }
    }
    .lineLimit(1)
    .kitSheet(item: $passwordTarget) { target in
      LoginPasswordSheet(target: target) { password in
        try RemoteProjects.setLoginPassword(password, for: target)
        session.setSigning(.loginKeychain, for: target)
      }
    }
    .kitSheet(item: $setupTarget) { target in SigningSetupSheet(target: target, session: session) }
  }

  private func pick(_ signing: RemoteSigning, for target: SSHExecutor.Target) {
    switch signing {
    case .unsigned:
      session.setSigning(signing, for: target)
    case .loginKeychain:
      if session.hasLoginPassword(for: target) {
        session.setSigning(signing, for: target)
      } else {
        passwordTarget = target
      }
    case .signingKeychain:
      session.setSigning(signing, for: target)
      setupTarget = target
    }
  }
}

/// Login Keychain's password: the Mac user's own, saved in the vault (iCloud Keychain) for the host, which Code
/// sends to unlock the login keychain before each signed build there.
struct LoginPasswordSheet: View {
  let target: SSHExecutor.Target
  let save: (String) throws -> Void
  @State private var password = ""
  @State private var error: String?
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    KitSheet(
      title: "Login Keychain", meta: target.name, systemImage: RemoteSigning.loginKeychain.symbolName, hue: .indigo
    ) {
      FormCard(
        footer:
          "An SSH session can’t use the login keychain until it’s unlocked. Code unlocks it with this password before each build, and keeps it in iCloud Keychain."
      ) {
        FormRow(
          "Password", help: target.user.isEmpty ? nil : "\(target.user) on \(target.name)",
          systemImage: "ellipsis.rectangle", hue: .indigo,
          field: SecureField("Mac password", text: $password).textContentType(.password))
      }
    } footer: {
      if let error { SheetStatus(error, systemImage: "exclamationmark.triangle", hue: .red) }
      Button("Cancel") { dismiss() }
        .keyboardShortcut(.cancelAction)
      Button("Save") {
        do {
          try save(password)
          dismiss()
        } catch {
          self.error = ProjectSession.describe(error)
        }
      }
      .buttonStyle(.kitPrimary)
      .keyboardShortcut(.defaultAction)
      .disabled(password.isEmpty)
    }
  }
}

/// Signing Keychain's setup: the script goes onto the Mac, and the user runs it in Terminal there once (macOS asks
/// to allow copying each signing key out of the login keychain, which needs the Mac's screen).
struct SigningSetupSheet: View {
  let target: SSHExecutor.Target
  let session: ProjectSession
  @State private var placing = true
  @State private var problem: String?
  @State private var copied = false
  @Environment(\.kitDismiss) private var dismiss

  var body: some View {
    KitSheet(
      title: "Signing Keychain", meta: target.name, systemImage: RemoteSigning.signingKeychain.symbolName, hue: .indigo
    ) {
      FormCard(
        footer:
          "It makes a keychain holding only this Mac’s signing identities, with a password kept on the Mac, and macOS asks to allow copying each one. Run it again after renewing a certificate."
      ) {
        FormRow("In Terminal on \(target.name)", systemImage: "terminal", hue: .indigo) {
          Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
            UIPasteboard.general.string = RemoteSigning.setupCommand
            copied = true
          }
          .buttonStyle(.kit)
        }
        Text(RemoteSigning.setupCommand)
          .font(.system(.footnote, design: .monospaced))
          .textSelection(.enabled)
      }
    } footer: {
      if let problem {
        SheetStatus(problem, systemImage: "exclamationmark.triangle", hue: .red)
      } else if placing {
        SheetStatus("Putting the script on \(target.name)…", systemImage: "arrow.up.doc", hue: .gray)
      }
      Button("Done") { dismiss() }
        .buttonStyle(.kitPrimary)
        .keyboardShortcut(.defaultAction)
    }
    .task {
      do {
        try await session.placeSigningSetup(on: target)
      } catch {
        problem = "Couldn’t put the script on \(target.name): \(ProjectSession.describe(error))"
      }
      placing = false
    }
  }
}

/// The action's output as the kit's run blocks, one per command it ran, following the end.
struct LogView: View {
  let controller: ActionController

  var body: some View {
    let runs = RunLog.runs(from: controller)
    if runs.isEmpty {
      EmptyState(
        systemImage: "terminal", title: "No Output",
        message: "Build, test or clean the project to see what it prints here.")
    } else {
      ScrollView {
        RunBlocks {
          ForEach(runs) { run in
            RunBlock(
              run.name, command: run.command, id: run.id, systemImage: run.systemImage, status: run.status,
              progress: run.progress, warnings: run.warnings, output: run.output,
              stop: run.status.isWorking ? { controller.stop() } : nil)
          }
        }
        .padding(.bottom, KitMetrics.gutter)
      }
      .modifier(FollowsEnd())
    }
  }
}

/// A short log starts at the top; a long one shows its end, and keeps to it as lines arrive.
private struct FollowsEnd: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 18, *) {
      content
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    } else {
      content.defaultScrollAnchor(.bottom)
    }
  }
}

/// The issues the last action found, in one card: the counts and the device in its header, each issue its
/// severity, message and file:line.
struct IssuesView: View {
  let controller: ActionController
  let device: String?

  var body: some View {
    let issues = controller.issues
    if issues.isEmpty {
      EmptyState(systemImage: "checkmark.circle", title: "No Issues")
    } else {
      let errors = issues.filter { $0.severity == .error }.count
      let warnings = issues.filter { $0.severity == .warning }.count
      ScrollView {
        KitSection(
          "Issues",
          meta: [
            errors == 0 ? "" : errors == 1 ? "1 error" : "\(errors) errors",
            warnings == 0 ? "" : warnings == 1 ? "1 warning" : "\(warnings) warnings",
            device.map { "from \($0)" } ?? "",
          ],
          systemImage: errors > 0 ? "xmark.octagon" : "exclamationmark.triangle", hue: errors > 0 ? .red : .orange
        ) {
          ForEach(issues) { issue in IssueRow(issue: issue) }
        }
        .padding(.bottom, KitMetrics.gutter)
      }
    }
  }
}

struct IssueRow: View {
  let issue: BuildIssue
  @Environment(\.kitIdiom) private var idiom

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Image(systemName: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
        .font(.system(size: idiom.isTouch ? 15 : 13, weight: .medium))
        .foregroundStyle(issue.severity == .error ? Hue.red.fill : Hue.orange.fill)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(issue.message)
          .kitFont(.body)
          .fixedSize(horizontal: false, vertical: true)
        if let url = issue.url {
          Text(url.lastPathComponent + (issue.line.map { ":\($0)" } ?? ""))
            .kitFont(.monoSmall)
            .foregroundStyle(.kitSecondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .textSelection(.enabled)
    .accessibilityElement(children: .combine)
  }
}
