#if DEBUG
  import CodeActions
  import Foundation
  import SSHKit

  /// Debug builds take a project on another machine from the launch environment, for trying remote actions in the
  /// simulator (which has no Secure Enclave key and no Hub) without clicking:
  ///
  /// - `CODE_DEBUG_REMOTE`: `{"name", "host", "port", "user", "directory", "key"}`, `key` a private key file the
  ///   server accepts (or `keyText`, its contents). Listed first and opened at launch.
  /// - `CODE_DEBUG_PERFORM`: `build`, `test` or `clean`, run once the schemes are found.
  ///
  /// The state goes to `Documents/code-debug-state.txt` in the app's container as it changes:
  ///
  ///     SIMCTL_CHILD_CODE_DEBUG_REMOTE='{…}' SIMCTL_CHILD_CODE_DEBUG_PERFORM=build xcrun simctl launch <udid> dev.v57.code
  @MainActor enum DebugLaunch {
    struct Remote: Decodable {
      var name: String
      var host: String
      var port: Int?
      var user: String
      var directory: String
      var key: String?
      var keyText: String?
    }

    static let remote: Remote? = ProcessInfo.processInfo.environment["CODE_DEBUG_REMOTE"].flatMap {
      try? JSONDecoder().decode(Remote.self, from: Data($0.utf8))
    }

    static var project: RemoteProject? {
      guard let remote else { return nil }
      let target = SSHExecutor.Target(
        id: "debug", name: remote.host, host: remote.host, port: remote.port ?? 22, user: remote.user,
        directory: remote.directory, detail: "debug")
      return RemoteProject(id: "debug-" + remote.name, name: remote.name, targets: [target])
    }

    static func login(for target: SSHExecutor.Target) -> SSHServer? {
      guard target.id == "debug", let remote else { return nil }
      let text = remote.keyText ?? remote.key.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
      return SSHServer(
        host: remote.host, port: remote.port ?? 22, user: remote.user, key: try? SSHKey(importing: text))
    }

    /// Runs `CODE_DEBUG_PERFORM` once the schemes are in, and writes the state as it changes.
    static func attach(to controller: ActionController) {
      var pending = ProcessInfo.processInfo.environment["CODE_DEBUG_PERFORM"].flatMap(ActionKind.init(rawValue:))
      Task { @MainActor [weak controller] in
        var written = ""
        while let controller {
          if let kind = pending, !controller.isScanning, controller.canPerform(kind) {
            pending = nil
            controller.perform(kind)
          }
          let state = describe(controller)
          if state != written {
            written = state
            write(state)
          }
          try? await Task.sleep(for: .milliseconds(300))
        }
      }
    }

    private static func describe(_ controller: ActionController) -> String {
      var lines = [
        "state: \(controller.state)",
        "scanning: \(controller.isScanning)",
        "schemes: \(controller.schemes.map(\.name).joined(separator: ", "))",
        "scheme: \(controller.selectedScheme?.name ?? "-")",
        "destinations: \(controller.destinations.map(\.name).joined(separator: ", "))",
        "destination: \(controller.selectedDestination?.id ?? "-")",
        "progress: \(controller.progress.map { "\($0.fraction ?? -1) \($0.message)" } ?? "-")",
        "issues: \(controller.issues.count)",
      ]
      lines += controller.issues.map { "  \($0.severity): \($0.message)" }
      lines.append("log:")
      lines += controller.log.entries.suffix(60).map { "  " + $0.text }
      return lines.joined(separator: "\n") + "\n"
    }

    private static func write(_ state: String) {
      guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
      try? Data(state.utf8).write(to: documents.appendingPathComponent("code-debug-state.txt"), options: .atomic)
    }
  }
#endif
