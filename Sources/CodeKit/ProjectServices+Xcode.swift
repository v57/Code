#if os(macOS) || os(Windows) || os(Linux)
  import CodeActions
  import CodeLSP
  import Foundation
  import Observation

  /// SourceKit-LSP for files of Xcode targets: it reads SwiftPM packages but
  /// not Xcode projects, so the selected Xcode scheme's compiler arguments
  /// go to it as a compilation database, an extra workspace folder in
  /// Caches. Written again when the scheme or destination changes and after
  /// each build.
  extension ProjectServices {
    static let sourceKitID = "sourcekit-lsp"

    /// The folder of this project's compilation database.
    var compilationDatabaseFolder: URL {
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      let hash = XcodeCompilationDatabase.fnv1a(workspace.root.path)
      return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "CodeKit")
        .appendingPathComponent("CompilationDatabases")
        .appendingPathComponent(workspace.root.lastPathComponent + "-" + String(hash, radix: 16))
    }

    /// Gives SourceKit-LSP the database written in an earlier session.
    func useCompilationDatabaseIfWritten() {
      let folder = compilationDatabaseFolder
      guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("compile_commands.json").path)
      else { return }
      languageServers.setExtraWorkspaceFolders([folder], forServer: Self.sourceKitID)
    }

    /// Follows the selected scheme and destination.
    func observeSchemeSelection() {
      withObservationTracking {
        _ = actions.selectedScheme?.id
        _ = actions.selectedDestination?.id
      } onChange: { [weak self] in
        Task { @MainActor in
          self?.updateCompilationDatabase()
          self?.observeSchemeSelection()
        }
      }
    }

    /// Writes the selected Xcode scheme's compilation database (unless it
    /// was written for the same scheme and destination, or `force`) and
    /// hands it to SourceKit-LSP.
    func updateCompilationDatabase(force: Bool = false) {
      guard isReady, settings.languageServersEnabled,
        !settings.disabledLanguageServers.contains(Self.sourceKitID),
        let scheme = actions.selectedScheme, scheme.toolchain == .xcode
      else { return }
      let destination = actions.selectedDestination
      let key = scheme.id + "|" + (destination?.id ?? "")
      guard force || key != databaseKey else { return }
      let folder = compilationDatabaseFolder
      let environment = languageServers.environment
      #if os(macOS)
      databaseTask?.cancel()
      databaseTask = Task {
        // Scanning picks a scheme, then a destination: write once.
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        let changed = await Task.detached(priority: .utility) {
          XcodeCompilationDatabase.write(
            scheme: scheme, destination: destination, to: folder, environment: environment)
        }.value
          guard !Task.isCancelled, let changed else { return }
        databaseKey = key
        languageServers.setExtraWorkspaceFolders([folder], forServer: Self.sourceKitID)
        if changed {
          languageServers.filesChanged(
            [folder.appendingPathComponent("compile_commands.json")], forServer: Self.sourceKitID)
        }
      }
      #else
        // Xcode projects build only on the Mac.
        _ = (key, folder, environment, destination)
      #endif
    }
  }
#endif

