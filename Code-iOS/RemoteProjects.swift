import CodeActions
import Foundation
import SSHKit
import VaultKit

/// A project Code can act on from here: one the vault knows, with a folder on the user's other devices that Code can
/// reach: through one of the user's Hubs, or straight to a Mac that lets the user's devices in (the Vault app's SSH
/// from your devices). Its Build, Test and Clean run on one of them over SSH, in the project's folder there
/// (`path.<device>`), signed in with this device's key and the host key the device signed or published. The vault is always the window's account's.
struct RemoteProject: Identifiable, Hashable {
  var id: String
  var name: String
  var icon: Data?
  var targets: [SSHExecutor.Target]
}

/// The hosts and the host keys they trust are Personal's (`Vault.personalVault`), whichever account the project is in.
@MainActor enum RemoteProjects {
  /// The vault's projects that have a folder on a device Code can reach, by name.
  static func all(vault: Vault) -> [RemoteProject] {
    var projects = vault.projects.compactMap { project -> RemoteProject? in
      let targets = targets(for: project, vault: vault)
      guard !targets.isEmpty else { return nil }
      return RemoteProject(id: project.id, name: project.name, icon: project.icon, targets: targets)
    }
    #if DEBUG
      projects += DebugLaunch.projects
    #endif
    return projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// The devices that have the project and a way there (`Vault.otherPlaces`): via Hub at their Hub Network address
  /// (the hosts the Vault app keeps from the Hubs' device directories), else at the address the Mac published, in
  /// the project's folder there.
  static func targets(for project: VaultProject, vault: Vault) -> [SSHExecutor.Target] {
    vault.otherPlaces(of: project).compactMap { place in
      guard let host = place.host else { return nil }
      return SSHExecutor.Target(
        id: host.id, name: host.displayName, host: host.hostname, port: host.port, user: host.user,
        hostKey: host.hub?.hostKey ?? host.device?.hostKey, directory: place.path,
        detail: host.isViaHub ? "via Hub" : "SSH", signing: signing(of: host))
    }
  }

  /// How Xcode builds on a host sign, as the vault keeps it for the host (every v57 device sees the same).
  static func signing(of host: VaultHost) -> RemoteSigning? {
    guard let signing = host.buildSigning else { return nil }
    switch signing {
    case VaultHost.BuildSigning.none: return .unsigned
    case .loginKeychain: return .loginKeychain
    case .desktopSession: return .desktopSession
    }
  }

  static func setSigning(_ signing: RemoteSigning, for target: SSHExecutor.Target, vault: Vault) {
    guard var host = vault.personalVault.host(id: target.id) else { return }
    switch signing {
    case .unsigned: host.buildSigning = VaultHost.BuildSigning.none
    case .loginKeychain: host.buildSigning = .loginKeychain
    case .desktopSession: host.buildSigning = .desktopSession
    }
    vault.personalVault.save(host)
  }

  /// The host's login password, which unlocks its login keychain for signing (and signs in, for a password host).
  static func loginPassword(for target: SSHExecutor.Target, vault: Vault) -> String? {
    vault.personalVault.host(id: target.id)?.password
  }

  static func setLoginPassword(_ password: String, for target: SSHExecutor.Target) throws {
    try VaultSecrets.setPassword(password, for: target.id)
  }

  /// How Code signs in to a target: its host's user, this device's key (the Secure Enclave key every v57 app shares)
  /// or the host's saved password, and the host key the vault trusts for it.
  static func login(for target: SSHExecutor.Target, vault: Vault) throws -> SSHServer {
    #if DEBUG
      if let login = DebugLaunch.login(for: target) { return login }
    #endif
    guard let host = vault.personalVault.host(id: target.id) else { throw LoginError.unknownHost }
    guard !host.user.isEmpty else { throw LoginError.noUser(host.displayName) }
    let known = try? vault.personalVault.store?.knownFingerprint(host: host.hostname, port: host.port)
    switch host.auth {
    case .password:
      return SSHServer(
        host: host.hostname, port: host.port, user: host.user, password: VaultSecrets.password(for: host.id),
        knownFingerprint: known)
    case .deviceKey:
      return SSHServer(host: host.hostname, port: host.port, user: host.user, key: try deviceKey(), knownFingerprint: known)
    case .importedKey:
      throw LoginError.importedKey(host.displayName)
    }
  }

  /// Remembers a host's key after the first login to it (trust on first use, as Shell and Database do).
  static func trust(_ fingerprint: String, for target: SSHExecutor.Target, vault: Vault) {
    guard let host = vault.personalVault.host(id: target.id) else { return }
    try? vault.personalVault.store?.trust(fingerprint: fingerprint, host: host.hostname, port: host.port)
  }

  /// This device's SSH key (Secure Enclave, shared by the v57 apps).
  private static func deviceKey() throws -> SSHKey {
    let key = try VaultIdentity.key()
    let blob = VaultIdentity.publicKeyBlob(key)
    return SSHKey(kind: .ecdsaP256, publicKeyBlob: Array(blob), comment: VaultDevice.name) { data in
      Array(try VaultIdentity.sshSignature(Data(data), key: key))
    }
  }

  enum LoginError: LocalizedError {
    case unknownHost
    case noUser(String)
    case importedKey(String)

    var errorDescription: String? {
      switch self {
      case .unknownHost: "The device isn't in the vault anymore."
      case .noUser(let name): "\(name) has no user name to sign in as. Set one in the Vault app."
      case .importedKey(let name): "\(name) signs in with a key another app imported. Use this device's key instead."
      }
    }
  }
}
