#if DEBUG
  import CodeActions
  import Foundation
  import SSHKit

  /// Debug builds take a project on another machine from the launch environment, for trying remote actions in the
  /// simulator (which has no Secure Enclave key and no Hub) without clicking:
  ///
  /// - `CODE_DEBUG_REMOTE`: `{"name", "host", "port", "user", "directory", "key"}`, `key` a private key file the
  ///   server accepts (or `keyText`, its contents). Listed first and opened at launch.
  ///   An array lists several (`device` names the device, `devices` adds unreachable ones to the list).
  /// - `CODE_DEBUG_SELECT`: the project opened at launch (its name), or `none` for the root list.
  /// - `CODE_DEBUG_SHOW`: `issues`, `files` or `file:<path in the project>`, shown once the project is open.
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
      /// The device's name in the app ("studio-mac"), in place of the host.
      var device: String?
      /// More devices said to have the project (listed, not reachable).
      var devices: [String]?
    }

    /// `CODE_DEBUG_REMOTE`: one project, or an array of them (the root list's demo).
    static let remotes: [Remote] = ProcessInfo.processInfo.environment["CODE_DEBUG_REMOTE"].flatMap { json in
      let data = Data(json.utf8)
      return (try? JSONDecoder().decode([Remote].self, from: data))
        ?? (try? JSONDecoder().decode(Remote.self, from: data)).map { [$0] }
    } ?? []

    static var projects: [RemoteProject] {
      remotes.enumerated().map { index, remote in
        let target = SSHExecutor.Target(
          id: "debug-\(index)", name: remote.device ?? remote.host, host: remote.host, port: remote.port ?? 22,
          user: remote.user, directory: remote.directory, detail: remote.device == nil ? "debug" : "via Hub")
        let others = (remote.devices ?? []).map {
          SSHExecutor.Target(id: "debug-\(index)-\($0)", name: $0, host: $0, user: remote.user, directory: remote.directory, detail: "via Hub")
        }
        return RemoteProject(id: "debug-" + remote.name, name: remote.name, targets: [target] + others)
      }
    }

    /// `CODE_DEBUG_SHOW`: what the opened project shows once it's ready (`issues`, `files`, `file:<path>`).
    static let show = ProcessInfo.processInfo.environment["CODE_DEBUG_SHOW"]

    /// The project opened at launch: `CODE_DEBUG_SELECT` (a name, or `none` for the root list), else the first.
    static var selected: RemoteProject.ID? {
      let select = ProcessInfo.processInfo.environment["CODE_DEBUG_SELECT"]
      if select == "none" { return nil }
      return projects.first { select == nil || $0.name == select }?.id
    }

    static func login(for target: SSHExecutor.Target) -> SSHServer? {
      guard target.id.hasPrefix("debug-"), let index = Int(target.id.dropFirst(6).prefix { $0.isNumber }),
        remotes.indices.contains(index)
      else { return nil }
      let remote = remotes[index]
      let text = remote.keyText ?? remote.key.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
      return SSHServer(
        host: target.host, port: target.port, user: remote.user, key: try? SSHKey(importing: text))
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
