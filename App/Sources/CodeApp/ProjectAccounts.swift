import CodeKit
import Foundation
import VaultKit

/// Which account a project belongs to, and the project icons each account's vault keeps.
@MainActor enum ProjectAccounts {
  /// The account a project window opens in: `current` when its vault has the folder as a project here, else the
  /// first account whose vault has it (an organization's before Personal), else `current`.
  static func account(of folder: URL, preferring current: String) -> String {
    let vaults = Vaults.shared
    let path = folder.standardizedFileURL.path
    func holds(_ account: VaultAccount) -> Bool {
      vaults.vault(for: account)?.localProjects.contains {
        $0.localPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == path
      } == true
    }
    if let account = vaults.account(id: current), holds(account) { return current }
    return (vaults.accounts + [.personal]).first(where: holds)?.id ?? current
  }

  /// The recent folders a window on `vault`'s account lists: those its vault has as projects here, and on Personal
  /// also those no other account has, so one client's folders never show in another account's window. The
  /// accounts' vaults are open from launch (`findIcons`), so this only reads them.
  static func recents(_ folders: [URL], for vault: Vault) -> [URL] {
    func paths(_ vault: Vault) -> Set<String> {
      Set(vault.localProjects.compactMap { $0.localPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path } })
    }
    let own = paths(vault)
    let vaults = Vaults.shared
    let others = vault.isPersonal
      ? vaults.accounts.compactMap { vaults.vault(for: $0) }.reduce(into: Set<String>()) { $0.formUnion(paths($1)) }
      : []
    return folders.filter { folder in
      let path = folder.standardizedFileURL.path
      return own.contains(path) || (vault.isPersonal && !others.contains(path))
    }
  }

  /// Keeps the icons of the vault's projects on this Mac current, for this app's lists and the other v57 apps'.
  /// Looking again at a vault that already looks is free.
  static func findIcons(in vault: Vault) {
    guard !ScreenshotDemo.isOn else { return }
    vault.findProjectIcons(with: { ProjectIcon.find(in: $0) }) { ProjectIcon.thumbnail(of: $0) }
  }
}
