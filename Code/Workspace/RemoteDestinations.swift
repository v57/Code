import CodeKit
import Foundation
import VaultKit

/// Where else this project's Build, Test and Clean can run: the devices on the user's Hubs (the hosts the Vault app
/// keeps from their device directories) that run a v57 app and have this project, reached over SSH at their Hub
/// Network address, in the project's folder there (`path.<device>`), with the host key the device signed.
enum RemoteDestinations {
  @MainActor static func targets(for root: URL, vault: Vault = .shared) -> [SSHExecutor.Target] {
    let here = root.standardizedFileURL.path
    guard
      let project = vault.projects.first(where: {
        $0.paths[vault.deviceID].map { URL(fileURLWithPath: $0).standardizedFileURL.path } == here
      })
    else { return [] }
    return vault.hubHosts.compactMap { host in
      guard let device = vault.vaultDevice(of: host), device != vault.deviceID, let path = project.paths[device]
      else { return nil }
      return SSHExecutor.Target(
        id: host.id, name: host.displayName, host: host.hostname, port: host.port, user: host.user,
        hostKey: host.hub?.hostKey, directory: path, detail: "via Hub")
    }
  }
}
