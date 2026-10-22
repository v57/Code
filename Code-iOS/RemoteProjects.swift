import CodeActions
import Foundation
import SSHKit
import VaultKit

/// A project Code can act on from here: one the vault knows, with a folder on other devices of the user's Hub.
/// Its Build, Test and Clean run on one of them over SSH, in the project's folder there (`path.<device>`), signed
/// in with this device's key and the host key the device signed.
struct RemoteProject: Identifiable, Hashable {
  var id: String
  var name: String
  var icon: Data?
  var targets: [SSHExecutor.Target]
}

@MainActor enum RemoteProjects {
  /// The vault's projects that have a folder on a device reachable through the user's Hubs, by name.
  static func all(vault: Vault = .shared) -> [RemoteProject] {
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

  /// The devices on the user's Hubs (the hosts the Vault app keeps from their device directories) that have the
  /// project, reached over SSH at their Hub Network address, in the project's folder there.
  static func targets(for project: VaultProject, vault: Vault) -> [SSHExecutor.Target] {
    vault.otherPlaces(of: project).compactMap { place in
      guard let host = place.host else { return nil }
      return SSHExecutor.Target(
        id: host.id, name: host.displayName, host: host.hostname, port: host.port, user: host.user,
        hostKey: host.hub?.hostKey, directory: place.path, detail: "via Hub")
    }
  }

  /// How Code signs in to a target: its host's user, this device's key (the Secure Enclave key every v57 app shares)
  /// or the host's saved password, and the host key the vault trusts for it.
  static func login(for target: SSHExecutor.Target, vault: Vault = .shared) throws -> SSHServer {
    #if DEBUG
      if let login = DebugLaunch.login(for: target) { return login }
    #endif
    guard let host = vault.host(id: target.id) else { throw LoginError.unknownHost }
    guard !host.user.isEmpty else { throw LoginError.noUser(host.displayName) }
    let known = try? vault.store?.knownFingerprint(host: host.hostname, port: host.port)
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
  static func trust(_ fingerprint: String, for target: SSHExecutor.Target, vault: Vault = .shared) {
    guard let host = vault.host(id: target.id) else { return }
    try? vault.store?.trust(fingerprint: fingerprint, host: host.hostname, port: host.port)
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
