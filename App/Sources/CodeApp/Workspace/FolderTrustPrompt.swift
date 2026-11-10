import CodeKit
import ComponentKit
import SwiftUI
import VaultKit

/// "Trust this folder?" (security audit H1, H2, L10): CodeFolders' `FolderTrust`, kept in Code's keychain item on
/// this Mac. Until a folder is trusted, it gets `code-lsp` only, PATH formatters with data-only configs, and nothing
/// reads the project through xcodebuild or SwiftPM (which resolve its packages and run `Package.swift`).
nonisolated enum CodeFolderTrust {
  static let keychain = VaultKeychain(service: "dev.v57.code.trust")
  static let account = "folders"

  /// Makes trust apply in this process. The screenshot demo's folders are Code's own, and trusted.
  @MainActor static func install() {
    guard !ScreenshotDemo.isOn else { return }
    let keychain = keychain
    let options = VaultKeychain.Options(synchronizable: false, label: "Code: trusted folders")
    FolderTrust.use(FolderTrust.Store(
      load: {
        guard let data = (try? keychain.read(account, options: options)) ?? nil,
          let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(paths)
      },
      save: { paths in
        guard let data = try? JSONEncoder().encode(paths.sorted()) else { return }
        try? keychain.write(data, account: account, options: options)
      }))
  }
}

extension View {
  /// Asks whether to trust the window's folder the first time it opens.
  func folderTrustPrompt(_ services: ProjectServices) -> some View {
    modifier(FolderTrustPrompt(services: services))
  }
}

private struct FolderTrustPrompt: ViewModifier {
  let services: ProjectServices
  private var name: String { services.workspace.root.lastPathComponent }

  func body(content: Content) -> some View {
    // Declined, the status bar says Restricted Mode and asks again when clicked (`codeStatusBar`). Read here, so the
    // body follows it: the binding's getter alone isn't observed.
    let asks = services.asksForTrust
    content
      .kitConfirmation(
        "Trust the authors of “\(name)”?",
        isPresented: Binding(get: { asks }, set: { if !$0 { services.declineTrust() } }),
        message: "Trusting it lets the folder’s own code run: language servers read its build settings, its formatters run on save, and Xcode and Swift read the project and fetch its packages. Until then, Code uses its built-in language server and the formatters on your PATH.",
        systemImage: "lock.shield", hue: .orange,
        buttons: [
          KitConfirmationButton("Don’t Trust") { services.declineTrust() },
          KitConfirmationButton("Trust Folder", isDefault: true) { services.trustFolder() },
        ])
  }
}
