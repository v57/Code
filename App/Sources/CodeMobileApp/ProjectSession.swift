import CodeActions
import Foundation
import Observation
import SSHKit
import VaultKit

/// One open project: a copy of its manifests from one of the devices that have it (`ProjectMirror`), and the
/// toolbar's model over that copy (`ActionController`), whose destinations are those devices. Build, Test and Clean
/// run on the destination picked, in the project's folder there.
@MainActor @Observable final class ProjectSession {
  enum Phase: Equatable {
    case loading(String)
    case ready
    case failed(String)
  }

  let project: RemoteProject
  /// The window's account's vault: the project's hosts, their signing and known keys.
  let vault: Vault
  private(set) var phase: Phase = .loading(String(localized: "Connecting"))
  private(set) var controller: ActionController?
  /// The device the copy came from, and the folder there.
  private(set) var source: SSHExecutor.Target?
  /// What the server wouldn't let this user read in the project (paths there): skipped, so its schemes may be missing.
  private(set) var unreadable: [String] = []
  @ObservationIgnored private var files: SFTPClient?
  /// The first `open()`, outside any view's task, so leaving the screen for Files doesn't cancel it.
  @ObservationIgnored private var opening: Task<Void, Never>?

  init(project: RemoteProject, vault: Vault) {
    self.project = project
    self.vault = vault
  }

  /// Opens the project the first time it's shown; coming back from Files or a file finds it open (the same
  /// connection, log and issues, and a build still running).
  func openOnce() async {
    if opening == nil { opening = Task { await open() } }
    await opening?.value
  }

  /// Copies the project's manifests from the first device that answers, then finds its schemes.
  func open() async {
    var failures: [String] = []
    for target in project.targets {
      phase = .loading(String(localized: "Connecting to \(target.name)"))
      do {
        let client = try await SFTPClient.connect(server: try login(for: target), timeout: 15)
        phase = .loading(String(localized: "Reading the project on \(target.name)"))
        let copy = try await ProjectMirror.fetch(target.directory, projectID: project.id, client: client)
        files = client
        source = target
        unreadable = copy.unreadable
        start(root: copy.root, preferring: target)
        return
      } catch {
        failures.append("\(target.name): \(Self.describe(error))")
      }
    }
    phase = .failed(failures.joined(separator: "\n"))
  }

  /// The SFTP connection the copy was made over, for browsing the folder there; reconnects when it closed.
  func fileClient() async throws -> SFTPClient {
    if let files, files.isAlive { return files }
    guard let source else { throw SSHTunnelError.closed }
    let client = try await SFTPClient.connect(server: try login(for: source), timeout: 15)
    files = client
    return client
  }

  /// Ends the project: stops what runs and closes the connection. Called once the project's screen is gone for good
  /// (another project, back to the list), never when Files or a file is pushed over it.
  func close() {
    opening?.cancel()
    controller?.stop()
    files?.close()
    files = nil
  }

  private func start(root: URL, preferring target: SSHExecutor.Target) {
    let controller = ActionController(root: root)
    controller.remoteLogin = { [vault] target in try RemoteProjects.login(for: target, vault: vault) }
    controller.remoteLoginPassword = { [vault] target in RemoteProjects.loginPassword(for: target, vault: vault) }
    controller.remoteTargets = project.targets
    #if DEBUG
      if let signing = DebugLaunch.signing {
        controller.remoteTargets = project.targets.map { var target = $0; target.signing = signing; return target }
      }
    #endif
    if controller.selectedDestinationID == nil { controller.selectedDestinationID = "ssh:" + target.id }
    controller.scan()
    self.controller = controller
    phase = .ready
    #if DEBUG
      DebugLaunch.attach(to: controller)
    #endif
  }

  // MARK: Signing

  /// Builds on the target sign this way from now on, on every device (the vault keeps it for the host).
  func setSigning(_ signing: RemoteSigning, for target: SSHExecutor.Target) {
    RemoteProjects.setSigning(signing, for: target, vault: vault)
    guard let controller else { return }
    controller.remoteTargets = controller.remoteTargets.map {
      var other = $0
      if other.id == target.id { other.signing = signing }
      return other
    }
  }

  func hasLoginPassword(for target: SSHExecutor.Target) -> Bool {
    RemoteProjects.loginPassword(for: target, vault: vault) != nil
  }

  /// The login for a target, as the executor makes it (its address, its signed host key pinned).
  private func login(for target: SSHExecutor.Target) throws -> SSHServer {
    let login = try RemoteProjects.login(for: target, vault: vault)
    return SSHExecutor(target: target, localRoot: URL(fileURLWithPath: "/"), login: login).server(from: login)
  }

  /// A path on the device as the project sees it: "Sources/Atlas" (the project's own folder is its name).
  func relativePath(of path: String) -> String {
    guard let root = source?.directory else { return path }
    let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
    if path == trimmed { return project.name }
    return path.hasPrefix(trimmed + "/") ? String(path.dropFirst(trimmed.count + 1)) : path
  }

  static func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}

/// Holds a project's session for as long as its screen's state lives, and closes it after: on iPhone when the project is
/// popped off the stack, on iPad when another project replaces it. Pushing Files or a file over the screen keeps the
/// state (and the session) alive, where `onDisappear` fired and closed it, losing the log and stopping a build.
nonisolated final class ProjectSessionLifetime: Sendable {
  let session: ProjectSession

  @MainActor init(project: RemoteProject, vault: Vault) {
    session = ProjectSession(project: project, vault: vault)
  }

  deinit {
    let session = session
    Task { @MainActor in session.close() }
  }
}
