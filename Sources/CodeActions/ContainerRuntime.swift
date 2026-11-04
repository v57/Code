import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// A container runtime on this computer that `docker` reaches through a socket: a Colima profile, or a Docker context
/// (Docker Desktop, a plain Docker daemon).
public struct ContainerRuntime: Identifiable, Hashable, Codable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case colima, docker
  }

  public var kind: Kind
  /// The Colima profile or Docker context.
  public var name: String
  /// Its Docker socket ("unix:///Users/me/.colima/default/docker.sock"), passed to every `docker` command, so neither
  /// the user's current context nor one that goes away when Colima stops decides where a build runs.
  public var endpoint: String
  public var isRunning: Bool

  public init(kind: Kind, name: String, endpoint: String, isRunning: Bool) {
    self.kind = kind
    self.name = name
    self.endpoint = endpoint
    self.isRunning = isRunning
  }

  public var id: String { kind.rawValue + ":" + name }

  public var displayName: String {
    switch kind {
    case .colima: return name == "default" ? "Colima" : "Colima (\(name))"
    case .docker:
      if name == ContainerRuntimes.desktopContext { return "Docker Desktop" }
      return name == "default" ? "Docker" : "Docker (\(name))"
    }
  }

  /// The command that starts it, when one does (always at the user's click: finding a runtime never starts it). A
  /// daemon under systemd needs root, so Code leaves it to the user.
  public var startCommand: String? {
    switch kind {
    case .colima: return name == "default" ? "colima start" : "colima start --profile \(shellQuote(name))"
    case .docker:
      #if os(macOS)
        return name == ContainerRuntimes.desktopContext ? "open -g -a Docker" : nil
      #else
        return nil
      #endif
    }
  }
}

/// Finds the container runtimes here from their own lists and sockets: `colima list` and `docker context ls` read
/// files, and a socket is only connected to and closed, so none of this starts a VM or a container runtime.
public enum ContainerRuntimes {
  static let desktopContext = "desktop-linux"

  /// The runtimes the `docker` command can use, running or not.
  public static func detect(environment: ShellEnvironment = .shared) -> [ContainerRuntime] {
    #if os(iOS)
      return []
    #else
      #if DEBUG
        // A computer without any, to see the toolbar as it is there.
        if ProcessInfo.processInfo.environment["CODE_NO_CONTAINER_RUNTIMES"] != nil { return [] }
      #endif
      guard let docker = environment.which("docker") else { return [] }
      var runtimes: [ContainerRuntime] = []
      if let colima = environment.which("colima"),
        let list = SubprocessCapture.run(colima, ["list", "--json"], environment: environment.variables, timeout: 10)
      {
        let home = environment.variables["COLIMA_HOME"] ?? NSHomeDirectory() + "/.colima"
        runtimes += parseColima(list, home: home, isOpen: isOpen)
      }
      if let list = SubprocessCapture.run(
        docker, ["context", "ls", "--format", "json"], environment: environment.variables, timeout: 10)
      {
        runtimes += parseContexts(list, isOpen: isOpen, hasDesktop: hasDockerDesktop)
      }
      return runtimes
    #endif
  }

  private static var hasDockerDesktop: Bool {
    #if os(macOS)
      return FileManager.default.fileExists(atPath: "/Applications/Docker.app")
    #else
      return false
    #endif
  }

  /// `colima list --json`: an object per line. Only Docker's runtime has the `docker` socket builds use.
  static func parseColima(_ text: String, home: String, isOpen: (String) -> Bool) -> [ContainerRuntime] {
    struct Profile: Decodable {
      let name: String
      let status: String
      let runtime: String?
    }
    return text.split(separator: "\n").compactMap { line in
      guard let profile = try? JSONDecoder().decode(Profile.self, from: Data(line.utf8)),
        profile.runtime == nil || profile.runtime == "docker"
      else { return nil }
      let endpoint = "unix://\(home)/\(profile.name)/docker.sock"
      return ContainerRuntime(
        kind: .colima, name: profile.name, endpoint: endpoint,
        isRunning: profile.status == "Running" && isOpen(endpoint))
    }
  }

  /// `docker context ls --format json`: an object per line. Contexts for another machine (`ssh://`, `tcp://`) aren't
  /// this computer's, and Colima's are listed as Colima. A context whose socket is gone is nothing here, except
  /// Docker Desktop's while the app is installed, which is stopped.
  static func parseContexts(_ text: String, isOpen: (String) -> Bool, hasDesktop: Bool) -> [ContainerRuntime] {
    struct Context: Decodable {
      let Name: String
      let DockerEndpoint: String
    }
    var seen = Set<String>()
    return text.split(separator: "\n").compactMap { line in
      guard let context = try? JSONDecoder().decode(Context.self, from: Data(line.utf8)) else { return nil }
      let endpoint = context.DockerEndpoint
      guard endpoint.hasPrefix("unix://") || endpoint.hasPrefix("npipe://"), !endpoint.contains("/.colima/"),
        !context.Name.hasPrefix("colima")
      else { return nil }
      let running = isOpen(endpoint)
      guard running || (context.Name == desktopContext && hasDesktop) else { return nil }
      // The default context is often a link to Docker Desktop's socket.
      guard seen.insert(realPath(endpoint)).inserted else { return nil }
      return ContainerRuntime(kind: .docker, name: context.Name, endpoint: endpoint, isRunning: running)
    }
  }

  private static func realPath(_ endpoint: String) -> String {
    guard endpoint.hasPrefix("unix://") else { return endpoint }
    return URL(fileURLWithPath: String(endpoint.dropFirst("unix://".count))).resolvingSymlinksInPath().path
  }

  /// Whether something answers on a Docker socket. Connects and closes, without a request, so a runtime that sleeps
  /// isn't woken.
  public static func isOpen(_ endpoint: String) -> Bool {
    #if os(Windows)
      return endpoint.hasPrefix("npipe://")
        && FileManager.default.fileExists(atPath: endpoint.dropFirst("npipe:".count).replacingOccurrences(of: "/", with: "\\"))
    #else
      guard endpoint.hasPrefix("unix://") else { return false }
      let path = String(endpoint.dropFirst("unix://".count))
      #if canImport(Darwin)
        let kind = SOCK_STREAM
      #else
        let kind = Int32(SOCK_STREAM.rawValue)
      #endif
      let handle = socket(AF_UNIX, kind, 0)
      guard handle >= 0 else { return false }
      defer { close(handle) }
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      let capacity = MemoryLayout.size(ofValue: address.sun_path)
      guard path.utf8.count < capacity else { return false }
      withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.copyBytes(from: Array(path.utf8) + [0])
      }
      let size = socklen_t(MemoryLayout<sockaddr_un>.size)
      return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, size) == 0 }
      }
    #endif
  }
}

/// What a scheme builds in when it's built in a container: the project's own `.devcontainer` image when it has one,
/// else the toolchain's official image.
public enum ContainerImages {
  public static func image(for scheme: ActionScheme, root: URL) -> String? {
    devcontainerImage(in: scheme.directory) ?? devcontainerImage(in: root) ?? standard(for: scheme.toolchain)
  }

  /// The image of `.devcontainer/devcontainer.json` or `.devcontainer.json`; one that builds from a Dockerfile has
  /// none to read here.
  static func devcontainerImage(in folder: URL) -> String? {
    for name in [".devcontainer/devcontainer.json", ".devcontainer.json"] {
      guard let text = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { continue }
      // JSON with comments, so a pattern rather than a parser.
      if let image = matches(of: #"(?m)^[ \t]*"image"[ \t]*:[ \t]*"([^"]+)""#, in: text).first?.first {
        return image
      }
    }
    return nil
  }

  /// Nil for what has no official image (Zig), and for what doesn't build in one.
  static func standard(for toolchain: Toolchain) -> String? {
    switch toolchain {
    case .swiftPM: return "swift:latest"
    case .cargo: return "rust:latest"
    case .go: return "golang:latest"
    case .gradle: return "gradle:jdk21"
    case .maven: return "maven:3-eclipse-temurin-21"
    case .node: return "node:lts"
    case .python: return "python:3"
    case .cmake, .make: return "gcc:latest"
    case .dart: return "dart:stable"
    case .dotnet: return "mcr.microsoft.com/dotnet/sdk:latest"
    case .elixir: return "elixir:latest"
    case .ruby: return "ruby:latest"
    case .php: return "composer:latest"
    // Compose runs on this computer, against the runtime (`ContainerExecutor.runsHere`).
    case .docker: return "Docker Compose"
    case .xcode, .android, .zig: return nil
    }
  }

  /// What a command needs first that the toolchain's image lacks.
  static func setup(for toolchain: Toolchain) -> String? {
    toolchain == .cmake
      ? "command -v cmake >/dev/null || { apt-get update -qq && apt-get install -y -qq cmake; } || exit 1" : nil
  }
}
