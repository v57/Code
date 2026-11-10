import CryptoKit
import Foundation

/// Commands in a container on a local runtime (`ContainerRuntime`), through the `docker` command: a new container per
/// command, removed when it ends, with the project's folder here at `/workspace`, so it builds what the editor has,
/// and a volume of the project's at `/build` for what it produces (`ActionScheme.inContainer()`), so Linux products
/// don't mix with this computer's. Stop kills the container. Compose schemes run here instead,
/// against the runtime.
public struct ContainerExecutor: ActionExecutor {
  /// Where the project's folder is in the container.
  public static let workspace = "/workspace"
  /// Where builds go in the container, a volume that outlives it.
  public static let buildRoot = "/build"

  public var runtime: ContainerRuntime
  /// The image, unused when `runsHere`.
  public var image: String
  public var toolchain: Toolchain
  /// The project's folder here.
  public var localRoot: URL

  public init(runtime: ContainerRuntime, image: String, toolchain: Toolchain, localRoot: URL) {
    self.runtime = runtime
    self.image = image
    self.toolchain = toolchain
    self.localRoot = localRoot
  }

  /// `docker compose` is a client: it talks to the runtime from here.
  var runsHere: Bool { toolchain == .docker }

  public func start(_ command: String, directory: URL, environment: [String: String]) throws -> any ActionCommand {
    #if os(iOS)
      throw ActionError.missing("Containers run on a computer.")
    #else
      guard ContainerRuntimes.isOpen(runtime.endpoint) else {
        throw ActionError.missing("\(runtime.displayName) isn’t running. Start it from Build From.")
      }
      guard !runsHere else {
        var environment = environment
        environment["DOCKER_HOST"] = runtime.endpoint
        return try PTYProcess(command: command, directory: directory, environment: environment)
      }
      let name = "code-\(Self.digest(localRoot.path))-\(UUID().uuidString.lowercased().prefix(8))"
      let arguments = runArguments(command, directory: directory, name: name)
      let process = try PTYProcess(
        command: pullCommand + Self.then + arguments.map(shellQuote).joined(separator: " "),
        directory: URL(fileURLWithPath: NSHomeDirectory()), environment: environment)
      return ContainerCommand(process: process, name: name, endpoint: runtime.endpoint, environment: environment)
    #endif
  }

  #if os(Windows)
    private static let then = " & "
  #else
    private static let then = " ; "
  #endif

  /// Fetches the image first when it isn't here. `docker run` would too, but on a terminal it draws its progress by
  /// moving the cursor, which leaves the log blank for what can be minutes; through a pipe it prints lines.
  var pullCommand: String {
    let docker = "docker --host \(shellQuote(runtime.endpoint))"
    return "\(docker) image inspect \(shellQuote(image)) >/dev/null 2>&1 || \(docker) pull \(shellQuote(image)) | cat"
  }

  /// `docker run`'s arguments for a command. A terminal, so tools draw as they do here. On Colima the container
  /// shares the VM's network, whose listening ports Colima forwards here, so a server that runs can be reached; other
  /// runtimes isolate it.
  func runArguments(_ command: String, directory: URL, name: String) -> [String] {
    var arguments = [
      "docker", "--host", runtime.endpoint, "run", "--rm", "--tty", "--name", name, "--label", "dev.v57.code=build",
      "--volume", "\(localRoot.path):\(Self.workspace)", "--volume", "\(volume):\(Self.buildRoot)",
      "--workdir", containerPath(directory.path),
    ]
    if runtime.kind == .colima { arguments += ["--network", "host"] }
    for (key, value) in Self.toolchainEnvironment(toolchain) { arguments += ["--env", "\(key)=\(value)"] }
    arguments += [image, "sh", "-c", script(command)]
    return arguments
  }

  /// The project's build volume. Kept for the next build; `docker volume rm` frees it.
  var volume: String { "code-build-\(Self.digest(localRoot.path))" }

  /// What runs in the container, in `sh` without a login: a login's profile would reset the PATH the image set. A
  /// folder outside what the runtime shares with its VM arrives empty, which would look like a project with nothing
  /// in it.
  func script(_ command: String) -> String {
    let shared =
      "[ -n \"$(ls -A \(Self.workspace))\" ] || { echo \(shellQuote("error: \(runtime.displayName) doesn’t share \(localRoot.path) with its containers.")); exit 125; }"
    let setup = ContainerImages.setup(for: toolchain).map { $0 + "\n" } ?? ""
    return shared + "\n" + setup + command.replacingOccurrences(of: localRoot.path, with: Self.workspace)
  }

  /// The path in the container for a path in the project here.
  func containerPath(_ local: String) -> String {
    let root = localRoot.path
    guard local == root || local.hasPrefix(root + "/") else { return Self.workspace }
    return Self.workspace + local.dropFirst(root.count)
  }

  /// Keeps the caches each toolchain makes out of the project's folder, in the build volume.
  static func toolchainEnvironment(_ toolchain: Toolchain) -> [(String, String)] {
    switch toolchain {
    case .go: return [("GOCACHE", "\(buildRoot)/go/cache"), ("GOMODCACHE", "\(buildRoot)/go/mod")]
    case .cargo: return [("CARGO_HOME", "\(buildRoot)/cargo-home")]
    case .gradle: return [("GRADLE_USER_HOME", "\(buildRoot)/gradle")]
    case .maven: return [("MAVEN_OPTS", "-Dmaven.repo.local=\(buildRoot)/m2")]
    case .node: return [("npm_config_cache", "\(buildRoot)/npm")]
    case .python: return [("PIP_CACHE_DIR", "\(buildRoot)/pip"), ("PYTHONDONTWRITEBYTECODE", "1")]
    default: return []
    }
  }

  static func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
  }
}

#if !os(iOS)
  /// `docker run` on a terminal here. Stop kills the container itself: signals to the client alone can leave it running.
  final class ContainerCommand: ActionCommand, @unchecked Sendable {
    private let process: PTYProcess
    private let name: String
    private let endpoint: String
    private let environment: [String: String]

    init(process: PTYProcess, name: String, endpoint: String, environment: [String: String]) {
      self.process = process
      self.name = name
      self.endpoint = endpoint
      self.environment = environment
    }

    func run(onLine: @escaping @Sendable (ActionLine) -> Void) async -> Int32 {
      await process.run(onLine: onLine)
    }

    func stop() {
      let (name, endpoint, environment) = (name, endpoint, environment)
      Thread.detachNewThread {
        guard let docker = ShellEnvironment.shared.which("docker") else { return }
        _ = SubprocessCapture.run(docker, ["--host", endpoint, "kill", name], environment: environment, timeout: 15)
      }
      process.stop()
    }
  }
#endif

extension ActionScheme {
  /// The scheme with its builds in the container's build volume (`ContainerExecutor.buildRoot`) rather than the
  /// project's folder: SwiftPM's scratch path, Cargo's target folder, Go's binaries, CMake's build folder. Tools with
  /// no such option (Make, .NET, a project's own scripts) still write where they do.
  public func inContainer() -> ActionScheme {
    let root = ContainerExecutor.buildRoot
    var scheme = self
    switch toolchain {
    case .swiftPM: scheme.commands = commands.mapValues { Self.swiftCommand($0, scratchPath: root + "/swift") }
    case .cargo: scheme.commands = commands.mapValues { Self.cargoCommand($0, targetDirectory: root + "/cargo") }
    case .go:
      // With one main package `go build ./...` writes its binary to the folder.
      scheme.commands = commands.mapValues {
        $0.replacingOccurrences(of: "go build ./...", with: "go build -o \(root)/go/bin/ ./...")
      }
    case .cmake:
      let folder = root + "/cmake"
      scheme.commands = commands.mapValues {
        $0.replacingOccurrences(of: "-B build", with: "-B \(folder)")
          .replacingOccurrences(of: "--build build", with: "--build \(folder)")
          .replacingOccurrences(of: "--test-dir build", with: "--test-dir \(folder)")
      }
    default: return self
    }
    return scheme
  }

  /// A SwiftPM command building into `scratchPath`.
  static func swiftCommand(_ command: String, scratchPath: String) -> String {
    let subcommand = ["swift build", "swift test", "swift run", "swift package clean"]
      .first { command == $0 || command.hasPrefix($0 + " ") }
    guard let subcommand else { return command }
    return subcommand + " --scratch-path \(shellQuote(scratchPath))" + command.dropFirst(subcommand.count)
  }

  /// A Cargo command building into `targetDirectory`.
  static func cargoCommand(_ command: String, targetDirectory: String) -> String {
    let words = command.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
    guard words.count >= 2, words[0] == "cargo" else { return command }
    return "cargo \(words[1]) --target-dir \(shellQuote(targetDirectory))" + (words.count > 2 ? " " + words[2] : "")
  }
}
