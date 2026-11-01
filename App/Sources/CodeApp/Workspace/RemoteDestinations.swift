import CodeKit
import Foundation
import SSHKit
import VaultKit

/// Where else this project's Build, Test and Clean can run: the user's other devices that have this project
/// (`Vault.otherPlaces`), reached over SSH through one of the user's Hubs at their Hub Network address, or straight to
/// a Mac that lets the user's devices in (Settings ▸ Remote), in the project's folder there (`path.<device>`), with the
/// host key the device signed or published, trying the device's other addresses when one doesn't answer. The vault is
/// the window's account's; the hosts are Personal's.
enum RemoteDestinations {
  @MainActor static func targets(for root: URL, vault: Vault) -> [SSHExecutor.Target] {
    let here = root.standardizedFileURL.path
    guard
      let project = vault.projects.first(where: {
        $0.paths[vault.deviceID].map { URL(fileURLWithPath: $0).standardizedFileURL.path } == here
      })
    else { return [] }
    return vault.otherPlaces(of: project).compactMap { place in
      guard let host = place.host else { return nil }
      return SSHExecutor.Target(
        id: host.id, name: host.displayName, host: host.hostname, fallbackHosts: place.fallbackAddresses, port: host.port,
        user: host.user,
        hostKey: host.hub?.hostKey ?? host.device?.hostKey, directory: place.path,
        detail: host.isViaHub ? "via Hub" : "SSH", signing: signing(of: host))
    }
  }

  /// How Code signs in to a Mac that lets the user's devices in: this device's key (the one Settings ▸ Remote allows
  /// there) and the host key the vault trusts for it. Nil for a host via Hub, which the system's `ssh` reaches as
  /// before.
  @MainActor static func login(for target: SSHExecutor.Target, vault: Vault) throws -> SSHServer? {
    guard let host = vault.personalVault.host(id: target.id), host.isDevice else { return nil }
    let known = try? vault.personalVault.store?.knownFingerprint(host: host.hostname, port: host.port)
    let user = host.user.isEmpty ? NSUserName() : host.user
    return SSHServer(host: host.hostname, port: host.port, user: user, key: try deviceKey(), knownFingerprint: known)
  }

  /// Remembers a host's key after the first login to it (trust on first use, as Shell and Database do).
  @MainActor static func trust(_ fingerprint: String, for target: SSHExecutor.Target, vault: Vault) {
    guard let host = vault.personalVault.host(id: target.id) else { return }
    try? vault.personalVault.store?.trust(fingerprint: fingerprint, host: host.hostname, port: host.port)
  }

  /// The host's login password, which unlocks its login keychain for signing.
  @MainActor static func loginPassword(for target: SSHExecutor.Target, vault: Vault) -> String? {
    vault.personalVault.host(id: target.id)?.password
  }

  /// How Xcode builds on the host sign, as picked in Code on any of the user's devices.
  static func signing(of host: VaultHost) -> RemoteSigning? {
    guard let signing = host.buildSigning else { return nil }
    switch signing {
    case VaultHost.BuildSigning.none: return .unsigned
    case .loginKeychain: return .loginKeychain
    case .desktopSession: return .desktopSession
    }
  }

  /// This device's SSH key (Secure Enclave, shared by the v57 apps).
  private static func deviceKey() throws -> SSHKey {
    let key = try VaultIdentity.key()
    let blob = VaultIdentity.publicKeyBlob(key)
    return SSHKey(kind: .ecdsaP256, publicKeyBlob: Array(blob), comment: VaultDevice.name) { data in
      Array(try VaultIdentity.sshSignature(Data(data), key: key))
    }
  }
}
