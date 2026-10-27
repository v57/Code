import CryptoKit
import Foundation
import SSHKit

/// One piece of a command's output: a line, or a transient status line that a later one replaces (text ending in a
/// carriage return, like a progress bar).
public struct ActionLine: Sendable {
  public var text: String
  public var isTransient: Bool

  public init(text: String, isTransient: Bool) {
    self.text = text
    self.isTransient = isTransient
  }
}

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
  func run(onLine: @escaping @Sendable (ActionLine) -> Void) async -> Int32
  func stop()
}

#if os(macOS) || os(Windows) || os(Linux)
  extension PTYProcess: ActionCommand {}

  /// Commands on this computer, on a pseudo-terminal (`PTYProcess`).
  public struct LocalExecutor: ActionExecutor {
    public init() {}

    public func start(_ command: String, directory: URL, environment: [String: String]) throws -> any ActionCommand {
      try PTYProcess(command: command, directory: directory, environment: environment)
    }
  }
#else
  /// iPhone and iPad run no commands themselves: their actions run on another machine (`SSHExecutor`).
  public struct LocalExecutor: ActionExecutor {
    public init() {}

    public func start(_ command: String, directory: URL, environment: [String: String]) throws -> any ActionCommand {
      throw ActionError.missing("Actions run on another machine here: pick one of your devices as the destination.")
    }
  }
#endif

/// An executor that couldn't be set up (no key to sign in with): every command fails with why.
struct UnavailableExecutor: ActionExecutor {
  var reason: String

  func start(_ command: String, directory: URL, environment: [String: String]) throws -> any ActionCommand {
    throw ActionError.launchFailed(reason)
  }
}

/// Commands on another machine over SSH: the project's folder there, its login shell's environment, the output
/// streamed back, and Stop closing the connection (the remote session gets a hangup).
///
/// Two clients run them. Given a `login` (this device's key and the host key the vault trusts), SSHKit's in-process
/// client does, as on iPhone and iPad, which have no `ssh`. Without one, the system's `ssh` client runs on a
/// pseudo-terminal here (macOS, Windows), so it signs in with the user's SSH keys and agent. Either way a host key
/// the machine signed (a device on the user's Hub) is pinned for the connection; any other host is trusted on first
/// use (through the user's `known_hosts`, or the login's known key), never silently when its key changed.
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
    /// How Xcode builds there sign; nil doesn't sign.
    public var signing: RemoteSigning?

    public init(
      id: String, name: String, host: String, port: Int = 22, user: String = "", hostKey: String? = nil,
      directory: String, detail: String? = nil, signing: RemoteSigning? = nil
    ) {
      self.id = id
      self.name = name
      self.host = host
      self.port = port
      self.user = user
      self.hostKey = hostKey
      self.directory = directory
      self.detail = detail
      self.signing = signing
    }
  }

  public var target: Target
  /// The project's folder here, which `target.directory` stands for there.
  public var localRoot: URL
  /// How the in-process client signs in (user, key or password, the host key known for the host); nil runs the
  /// system's `ssh` client.
  public var login: SSHServer?
  /// Called with the host's key after a first login to a host whose key wasn't known, for the app to remember.
  public var onNewHostKey: (@Sendable (String) -> Void)?
  /// Shell variables set there before each command (the login password `RemoteSigning` unlocks the keychain with),
  /// kept out of the command line the log shows.
  public var secrets: [String: String]

  public init(
    target: Target, localRoot: URL, login: SSHServer? = nil, secrets: [String: String] = [:],
    onNewHostKey: (@Sendable (String) -> Void)? = nil
  ) {
    self.target = target
    self.localRoot = localRoot
    self.login = login
    self.secrets = secrets
    self.onNewHostKey = onNewHostKey
  }

  public func start(_ command: String, directory: URL, environment: [String: String]) throws -> any ActionCommand {
    let remote = remoteCommand(command, directory: directory)
    if let login { return SSHActionCommand(server: server(from: login), command: remote, onNewHostKey: onNewHostKey) }
    #if os(macOS) || os(Windows) || os(Linux)
      let arguments = try sshArguments(remote)
      // Locally only the `ssh` client runs (from the home folder: the project needn't exist here); the remote side
      // gets its own login environment.
      return try PTYProcess(
        command: arguments.map(shellQuote).joined(separator: " "), directory: URL(fileURLWithPath: NSHomeDirectory()),
        environment: environment)
    #else
      throw ActionError.launchFailed("there's no key to sign in to \(target.name) with")
    #endif
  }

  /// The in-process client's login: the target's address, with its signed host key pinned when there is one.
  public func server(from login: SSHServer) -> SSHServer {
    var server = login
    server.host = target.host
    server.port = target.port
    if !target.user.isEmpty { server.user = target.user }
    if let hostKey = target.hostKey, let fingerprint = Self.fingerprint(ofHostKey: hostKey) {
      server.knownFingerprint = fingerprint
    }
    return server
  }

  /// `SHA256:…` for an OpenSSH host key line ("ecdsa-sha2-nistp256 AAAA… comment"), as libssh2 reports it.
  static func fingerprint(ofHostKey line: String) -> String? {
    let fields = line.split(separator: " ")
    guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
    let digest = Data(SHA256.hash(data: blob))
    return "SHA256:" + digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
  }

  /// `cd <folder there> && <command>` in the remote user's login shell, with paths into the project here
  /// rewritten to the folder there, and the secrets set first as plain (unexported) shell variables.
  func remoteCommand(_ command: String, directory: URL) -> String {
    "exec \"$SHELL\" -lc \(shellQuote(remoteScript(command, directory: directory)))"
  }

  /// What the login shell there runs.
  func remoteScript(_ command: String, directory: URL) -> String {
    let remoteDirectory = remotePath(directory.path)
    let command = command.replacingOccurrences(of: localRoot.path, with: target.directory)
    let variables = secrets.keys.sorted().map { "\($0)=\(shellQuote(secrets[$0]!)); " }.joined()
    return "\(variables)cd \(shellQuote(remoteDirectory)) && \(command)"
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

/// A command over SSHKit's in-process client (`SSHCommand`): on a pseudo-terminal there, its output split into lines
/// as `PTYProcess` splits a local one's, and Stop hanging it up.
final class SSHActionCommand: ActionCommand, @unchecked Sendable {
  private let command: SSHCommand
  private let onNewHostKey: (@Sendable (String) -> Void)?

  init(server: SSHServer, command: String, onNewHostKey: (@Sendable (String) -> Void)?) {
    self.command = SSHCommand(server: server, command: command)
    self.onNewHostKey = onNewHostKey
  }

  func run(onLine: @escaping @Sendable (ActionLine) -> Void) async -> Int32 {
    let lines = LineBuffer(onLine: onLine)
    do {
      let status = try await command.run { lines.add($0) }
      lines.finish()
      if command.server.knownFingerprint == nil, !command.hostKeyFingerprint.isEmpty {
        onNewHostKey?(command.hostKeyFingerprint)
      }
      // No status: Stop hung it up, or a signal ended it (as a shell reports SIGHUP).
      return status ?? 129
    } catch {
      lines.finish()
      let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      onLine(ActionLine(text: message, isTransient: false))
      // What `ssh` exits with when it can't connect or sign in.
      return 255
    }
  }

  func stop() { command.stop() }

  /// Output chunks from the command's thread, as lines.
  private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var splitter = ActionLineSplitter()
    private let onLine: @Sendable (ActionLine) -> Void

    init(onLine: @escaping @Sendable (ActionLine) -> Void) { self.onLine = onLine }

    func add(_ data: Data) { lock.withLock { splitter.add(data, onLine: onLine) } }
    func finish() { lock.withLock { splitter.finish(onLine: onLine) } }
  }
}

/// Splits terminal output into lines: "\r\n" ends a line like "\n", text redrawn after a carriage return replaces
/// what was there (reported as transient while the line is still being drawn), and escape sequences go.
struct ActionLineSplitter {
  private var pending = Data()

  mutating func add(_ data: Data, onLine: (ActionLine) -> Void) {
    pending.append(data)
    while let newline = pending.firstIndex(of: 0x0A) {
      let chunk = pending[pending.startIndex..<newline]
      pending.removeSubrange(pending.startIndex...newline)
      emit(chunk, onLine: onLine)
    }
    if let carriage = pending.lastIndex(of: 0x0D), carriage != pending.index(before: pending.endIndex) {
      // A status line being redrawn: report its latest state.
      let chunk = pending[pending.startIndex..<carriage]
      pending.removeSubrange(pending.startIndex...carriage)
      if let last = chunk.split(separator: 0x0D).last {
        let text = ANSI.strip(String(decoding: last, as: UTF8.self))
        if !text.trimmingCharacters(in: .whitespaces).isEmpty { onLine(ActionLine(text: text, isTransient: true)) }
      }
    }
  }

  mutating func finish(onLine: (ActionLine) -> Void) {
    if !pending.isEmpty { emit(pending[...], onLine: onLine) }
    pending.removeAll()
  }

  private func emit(_ chunk: Data.SubSequence, onLine: (ActionLine) -> Void) {
    var chunk = chunk
    if chunk.last == 0x0D { chunk = chunk.dropLast() }
    // "a\rb" shows as "b": keep what was drawn last.
    let parts = chunk.split(separator: 0x0D, omittingEmptySubsequences: false)
    for (index, part) in parts.enumerated() where index == parts.count - 1 || !part.isEmpty {
      let text = ANSI.strip(String(decoding: part, as: UTF8.self))
      if index == parts.count - 1 {
        onLine(ActionLine(text: text, isTransient: false))
      } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
        onLine(ActionLine(text: text, isTransient: true))
      }
    }
  }
}
