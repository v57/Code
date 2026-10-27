import CodeActions
import Foundation
import Observation
import SSHKit

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
  private(set) var phase: Phase = .loading("Connecting")
  private(set) var controller: ActionController?
  /// The device the copy came from, and the folder there.
  private(set) var source: SSHExecutor.Target?
  @ObservationIgnored private var files: SFTPClient?

  init(project: RemoteProject) {
    self.project = project
  }

  /// Copies the project's manifests from the first device that answers, then finds its schemes.
  func open() async {
    var failures: [String] = []
    for target in project.targets {
      phase = .loading("Connecting to \(target.name)")
      do {
        let client = try await SFTPClient.connect(server: try login(for: target), timeout: 15)
        remember(client.hostKeyFingerprint, for: target)
        phase = .loading("Reading the project on \(target.name)")
        let root = try await ProjectMirror.fetch(target.directory, projectID: project.id, client: client)
        files = client
        source = target
        start(root: root, preferring: target)
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

  func close() {
    controller?.stop()
    files?.close()
    files = nil
  }

  private func start(root: URL, preferring target: SSHExecutor.Target) {
    let controller = ActionController(root: root)
    controller.remoteLogin = { target in try RemoteProjects.login(for: target) }
    controller.didMeetHostKey = { target, fingerprint in RemoteProjects.trust(fingerprint, for: target) }
    controller.remoteLoginPassword = { target in RemoteProjects.loginPassword(for: target) }
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
    RemoteProjects.setSigning(signing, for: target)
    guard let controller else { return }
    controller.remoteTargets = controller.remoteTargets.map {
      var other = $0
      if other.id == target.id { other.signing = signing }
      return other
    }
  }

  func hasLoginPassword(for target: SSHExecutor.Target) -> Bool {
    RemoteProjects.loginPassword(for: target) != nil
  }

  /// Puts the signing keychain's setup script on the target (`RemoteSigning.setupScript`), for the user to run in
  /// Terminal there: copying the signing identities out of the login keychain needs the Mac's screen.
  func placeSigningSetup(on target: SSHExecutor.Target) async throws {
    let client: SFTPClient
    if target.id == source?.id {
      client = try await fileClient()
    } else {
      client = try await SFTPClient.connect(server: try login(for: target), timeout: 15)
    }
    defer { if client !== files { client.close() } }
    let home = try await client.realPath(".")
    try await client.write(
      Data(RemoteSigning.setupScript.utf8), to: home + "/" + RemoteSigning.setupPath, createParents: true,
      permissions: 0o700)
  }

  /// The login for a target, as the executor makes it (its address, its signed host key pinned).
  private func login(for target: SSHExecutor.Target) throws -> SSHServer {
    let login = try RemoteProjects.login(for: target)
    return SSHExecutor(target: target, localRoot: URL(fileURLWithPath: "/"), login: login).server(from: login)
  }

  private func remember(_ fingerprint: String, for target: SSHExecutor.Target) {
    guard target.hostKey == nil, (try? RemoteProjects.login(for: target).knownFingerprint) == nil else { return }
    RemoteProjects.trust(fingerprint, for: target)
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
