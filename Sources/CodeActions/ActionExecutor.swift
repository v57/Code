import Foundation

#if os(macOS) || os(Windows)
  /// Where an action's commands run: this computer's terminal, or another machine over SSH (a Hub runner later).
  /// Detectors, the planner, log parsing, issues and progress work the same on every executor; only the place a
  /// command runs changes, picked like a destination.
  public protocol ActionExecutor: Sendable {
    /// Starts a shell command in `directory` (a folder of the project on this computer), streaming its output.
    func start(_ command: String, directory: URL, environment: [String: String]) throws -> any ActionCommand
  }

  /// A command an executor started: its output until it exits, and Stop.
  public protocol ActionCommand: AnyObject, Sendable {
    /// Reads output until the command exits; returns its exit status.
    func run(onLine: @escaping @Sendable (PTYProcess.Line) -> Void) async -> Int32
    func stop()
  }

  extension PTYProcess: ActionCommand {}

  /// Commands on this computer, on a pseudo-terminal (`PTYProcess`).
  public struct LocalExecutor: ActionExecutor {
    public init() {}

    public func start(_ command: String, directory: URL, environment: [String: String]) throws -> any ActionCommand {
      try PTYProcess(command: command, directory: directory, environment: environment)
    }
  }

  /// Commands on another machine over SSH: the project's folder there, its login shell's environment, the output
  /// streamed back, and Stop closing the connection (the remote session gets a hangup).
  ///
  /// It runs the system's `ssh` client on a pseudo-terminal here, so it signs in with the user's SSH keys and agent.
  /// A host key the machine signed (a device on the user's Hub) is pinned for the connection; any other host is
  /// trusted on first use through the user's `known_hosts`, never silently when its key changed.
  public struct SSHExecutor: ActionExecutor {
    public struct Target: Sendable, Hashable, Identifiable, Codable {
      /// The shared host's id.
      public var id: String
      public var name: String
      public var host: String
      public var port: Int
      public var user: String
      /// The OpenSSH host key line to pin ("ecdsa-sha2-nistp256 AAAA…"), when one is known for sure.
      public var hostKey: String?
      /// The project's folder on that machine.
      public var directory: String
      /// "via Hub", "SSH": shown after the name.
      public var detail: String?

      public init(
        id: String, name: String, host: String, port: Int = 22, user: String = "", hostKey: String? = nil,
        directory: String, detail: String? = nil
      ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.user = user
        self.hostKey = hostKey
        self.directory = directory
        self.detail = detail
      }
    }

    public var target: Target
    /// The project's folder here, which `target.directory` stands for there.
    public var localRoot: URL

    public init(target: Target, localRoot: URL) {
      self.target = target
      self.localRoot = localRoot
    }

    public func start(_ command: String, directory: URL, environment: [String: String]) throws -> any ActionCommand {
      let arguments = try sshArguments(remoteCommand(command, directory: directory))
      // Locally only the `ssh` client runs (from the home folder: the project needn't exist here); the remote side
      // gets its own login environment.
      return try PTYProcess(
        command: arguments.map(shellQuote).joined(separator: " "), directory: URL(fileURLWithPath: NSHomeDirectory()),
        environment: environment)
    }

    /// `cd <folder there> && <command>` in the remote user's login shell, with paths into the project here
    /// rewritten to the folder there.
    func remoteCommand(_ command: String, directory: URL) -> String {
      let remoteDirectory = remotePath(directory.path)
      let command = command.replacingOccurrences(of: localRoot.path, with: target.directory)
      let script = "cd \(shellQuote(remoteDirectory)) && \(command)"
      return "exec \"$SHELL\" -lc \(shellQuote(script))"
    }

    /// The path there for a path in the project here.
    func remotePath(_ local: String) -> String {
      let root = localRoot.path
      guard local == root || local.hasPrefix(root + "/") else { return target.directory }
      return target.directory + local.dropFirst(root.count)
    }

    /// `ssh -tt` with keepalives and no prompts (there's no one to answer them), pinning the host key when known.
    func sshArguments(_ remoteCommand: String) throws -> [String] {
      var arguments = [
        Self.sshPath, "-tt", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
        "-p", String(target.port),
      ]
      if let hostKey = target.hostKey {
        let file = try Self.knownHostsFile(host: target.host, port: target.port, key: hostKey)
        arguments += ["-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\(file.path)"]
      } else {
        arguments += ["-o", "StrictHostKeyChecking=accept-new"]
      }
      arguments.append(target.user.isEmpty ? target.host : "\(target.user)@\(target.host)")
      arguments += ["--", remoteCommand]
      return arguments
    }

    #if os(Windows)
      static let sshPath = "ssh"
    #else
      static let sshPath = "/usr/bin/ssh"
    #endif

    /// A known_hosts file holding only the pinned key, in a private temporary folder.
    static func knownHostsFile(host: String, port: Int, key: String) throws -> URL {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodeActions-known-hosts", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let name = port == 22 ? host : "[\(host)]:\(port)"
      let line = "\(name) \(key.split(separator: " ").prefix(2).joined(separator: " "))\n"
      let file = folder.appendingPathComponent("\(host)-\(port)")
      try Data(line.utf8).write(to: file, options: .atomic)
      return file
    }
  }
#endif
