import CodeKit
import Foundation
import SSHKit
import VaultKit
import VaultUI

/// Where else this project can be built from (Build From in the toolbar): the user's other devices that have this project
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

  /// The machines to offer: `targets`, then the user's other devices without this project and their saved SSH hosts,
  /// with no folder yet: picking one looks for the project there (`ActionController.selectBuildSource`). Reads the
  /// vault only.
  @MainActor static func machines(for root: URL, vault: Vault) -> [SSHExecutor.Target] {
    let found = targets(for: root, vault: vault)
    let personal = vault.personalVault
    let here = URL(fileURLWithPath: root.path).standardizedFileURL.path
    let places = vault.projects.first { $0.paths[vault.deviceID].map { URL(fileURLWithPath: $0).standardizedFileURL.path } == here }
      .map { vault.otherPlaces(of: $0).map(\.device) } ?? []
    var seen = Set(found.map(\.id))
    var others: [SSHExecutor.Target] = []
    for host in vault.otherDeviceHosts + (vault.hosts + personal.hosts).filter({ !$0.isDevice && !$0.isViaHub }) {
      guard seen.insert(host.id).inserted, !vault.isThisDevice(host),
        !(vault.vaultDevice(of: host).map(places.contains) ?? false)
      else { continue }
      others.append(
        SSHExecutor.Target(
          id: host.id, name: host.displayName, host: host.hostname, fallbackHosts: personal.fallbackAddresses(of: host),
          port: host.port, user: host.user, hostKey: host.hub?.hostKey ?? host.device?.hostKey, directory: "",
          detail: host.isViaHub ? "via Hub" : "SSH", signing: signing(of: host)))
    }
    return found + others
  }

  private static func host(of target: SSHExecutor.Target, vault: Vault) -> VaultHost? {
    vault.personalVault.host(id: target.id) ?? vault.host(id: target.id)
  }

  /// How Code signs in: to a Mac that lets the user's devices in, or a saved host set to it, with this device's key
  /// (the one Settings ▸ Remote allows there); to a saved host with a saved password, with that; in both cases with
  /// the host key the vault trusts for it. Nil for the rest, which the system's `ssh` reaches with the user's own
  /// keys: hosts via Hub, as before, and hosts with a key another app imported.
  @MainActor static func login(for target: SSHExecutor.Target, vault: Vault) throws -> SSHServer? {
    guard let host = host(of: target, vault: vault), !host.isViaHub else { return nil }
    let trust = SSHHostTrust.known(
      vault.knownHost(for: host)?.fingerprint,
      otherwise: .ask { key in
        await VaultHostKeyRequest.shared.approve(key.fingerprint, keyType: key.type, for: host, in: vault)
      })
    let user = host.user.isEmpty ? NSUserName() : host.user
    if host.isDevice || host.auth == .deviceKey {
      return SSHServer(host: host.hostname, port: host.port, user: user, key: try deviceKey(), trust: trust)
    }
    guard host.auth == .password, let password = host.password else { return nil }
    return SSHServer(host: host.hostname, port: host.port, user: user, password: password, trust: trust)
  }

  /// The host's login password, which unlocks its login keychain for signing.
  @MainActor static func loginPassword(for target: SSHExecutor.Target, vault: Vault) -> String? {
    host(of: target, vault: vault)?.password
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
    return SSHKey(kind: .ecdsaP256, publicKeyBlob: Array(blob), comment: VaultDevice.name, prepare: VaultIdentity.presencePrompt()) { data in
      Array(try VaultIdentity.sshSignature(Data(data), key: key))
    }
  }
}
