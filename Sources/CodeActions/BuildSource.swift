import Foundation

/// Where a project is built from, the first part of the toolbar's `Build From › Project/Target › Run On`: this
/// computer, another machine that has the project (`SSHExecutor`), or a container on a local runtime
/// (`ContainerExecutor`). It decides which schemes are on offer (`BuildCapabilities`) and which destinations.
public struct BuildSource: Identifiable, Hashable, Codable, Sendable {
  public enum Place: Hashable, Codable, Sendable {
    case local
    /// A machine over SSH. A `directory` of "" means the project still has to be found there.
    case machine(SSHExecutor.Target)
    case container(ContainerRuntime)
  }

  public var place: Place

  public init(place: Place) {
    self.place = place
  }

  public static let local = BuildSource(place: .local)

  public var id: String {
    switch place {
    case .local: return "local"
    case .machine(let target): return "ssh:" + target.id
    case .container(let runtime): return "container:" + runtime.id
    }
  }

  /// "This Mac", the machine's or the runtime's name.
  public var name: String {
    switch place {
    case .local: return Self.localName
    case .machine(let target): return target.name
    case .container(let runtime): return runtime.displayName
    }
  }

  #if os(Windows)
    public static let localName = "This PC"
  #elseif os(Linux)
    public static let localName = "This Computer"
  #else
    public static let localName = "This Mac"
  #endif

  /// "via Hub", "SSH", "Stopped": shown after the name.
  public var detail: String? {
    switch place {
    case .local: return nil
    case .machine(let target): return target.detail
    case .container(let runtime): return runtime.isRunning ? nil : "Stopped"
    }
  }

  public var symbolName: String {
    switch place {
    case .local: return RunDestination.mac.symbolName
    case .machine: return "point.3.connected.trianglepath.dotted"
    case .container: return "shippingbox"
    }
  }

  /// The menu section it's listed under.
  public var section: String {
    switch place {
    case .local: return Self.localName
    case .machine(let target): return target.directory.isEmpty ? "Find on Another Machine" : "Other Machines"
    case .container: return "Containers"
    }
  }

  public var isLocal: Bool { place == .local }

  public var machine: SSHExecutor.Target? {
    if case .machine(let target) = place { return target }
    return nil
  }

  public var container: ContainerRuntime? {
    if case .container(let runtime) = place { return runtime }
    return nil
  }

  /// A machine that may have the project, in a folder not known yet.
  public var needsFinding: Bool { machine?.directory.isEmpty ?? false }

  /// What it runs on: the destination `Run On` offers while building from here (nothing to pick for this computer,
  /// whose destinations are its simulators and devices).
  func destination(image: String?) -> RunDestination? {
    switch place {
    case .local: return nil
    case .machine(let target):
      return RunDestination(id: id, name: target.name, kind: .remote, detail: target.detail)
    case .container(let runtime):
      return RunDestination(id: id, name: image ?? "Container", kind: .container, detail: runtime.displayName)
    }
  }
}

/// What a build source was last seen doing.
public enum BuildSourceStatus: Hashable, Sendable {
  /// Not contacted since launch: nothing reaches another machine until the user asks.
  case unknown
  case checking
  case ready
  /// Offline, stopped, without the project: why, in a sentence. The user's choice stays.
  case unavailable(String)
}

/// What a build source can build, which filters the toolbar's schemes.
public struct BuildCapabilities: Hashable, Codable, Sendable {
  /// `uname -s` there ("Darwin", "Linux"), when known.
  public var system: String?
  /// The toolchains it has; nil until it was asked, when only what never runs there is left out.
  public var toolchains: Set<Toolchain>?

  public init(system: String? = nil, toolchains: Set<Toolchain>? = nil) {
    self.system = system
    self.toolchains = toolchains
  }

  /// Linux in a container: anything but what needs Apple's or Android's tools.
  public static let container = BuildCapabilities(
    system: "Linux", toolchains: Set(Toolchain.allCases).subtracting([.xcode, .android]))

  /// Whether a scheme builds there. iOS and Android products have no destination elsewhere yet, and Android actions
  /// run on this computer only (`ActionPlanner.remoteSteps`).
  public func canBuild(_ scheme: ActionScheme) -> Bool {
    guard scheme.toolchain != .android, scheme.platforms.contains(.mac) else { return false }
    return toolchains?.contains(scheme.toolchain) ?? true
  }

  /// Workspaces and projects are Xcode's, so only a source that has it lists them.
  public func canUse(_ container: ProjectContainer) -> Bool {
    container.kind == .package || (toolchains?.contains(.xcode) ?? true)
  }
}

/// What a click on another machine asks it: its system, its tools and where the project is, all in one command over
/// the action's own executor, so it signs in as the build will.
enum MachineProbe {
  static let marker = "CODE-PROBE "

  /// What the machine answered.
  struct Answer: Equatable {
    var capabilities = BuildCapabilities(toolchains: [])
    /// The project's folder there, when it was asked to look for it and found it.
    var folder: String?
    var didAnswer = false
  }

  /// The command each toolchain needs. Run by POSIX `sh`, whatever the login shell is (zsh aborts on a glob with no
  /// match).
  private static let tools: [(tool: String, toolchains: [Toolchain])] = [
    ("swift", [.swiftPM]), ("cargo", [.cargo]), ("go", [.go]), ("gradle", [.gradle]), ("java", [.gradle]),
    ("mvn", [.maven]), ("node", [.node]), ("python3", [.python]), ("cmake", [.cmake]), ("make", [.make]),
    ("zig", [.zig]), ("dart", [.dart]), ("dotnet", [.dotnet]), ("mix", [.elixir]), ("ruby", [.ruby]), ("php", [.php]),
    ("docker", [.docker]),
  ]

  /// The script. With `find`, also looks for the folder: first the same place relative to the home folder, then the
  /// usual ones; a folder whose Git origin isn't `origin` ("owner/repo") is another project of the same name.
  static func script(find: (name: String, relativePath: String?, origin: String?)?) -> String {
    var lines = [
      "echo \"\(marker)system $(uname -s)\"",
      // A stub without Xcode exists on every Mac; only a real one answers.
      "xcodebuild -version >/dev/null 2>&1 && echo \"\(marker)tool xcodebuild\"",
      "for t in \(tools.map(\.tool).joined(separator: " ")); do command -v \"$t\" >/dev/null 2>&1 && echo \"\(marker)tool $t\"; done",
    ]
    if let find {
      let name = shellQuote(find.name)
      var places = ["\"$HOME\"/\(name)"]
      for parent in ["Developer", "Projects", "src", "code", "workspace"] {
        places += ["\"$HOME\"/\(parent)/\(name)", "\"$HOME\"/\(parent)/*/\(name)"]
      }
      if let relative = find.relativePath { places.insert("\"$HOME\"/\(shellQuote(relative))", at: 0) }
      lines.append("origin=\(shellQuote(find.origin ?? ""))")
      lines.append(
        """
        for d in \(places.joined(separator: " ")); do
          [ -d "$d" ] || continue
          o=$(git -C "$d" remote get-url origin 2>/dev/null)
          if [ -n "$origin" ] && [ -n "$o" ]; then
            case "$o" in *"$origin"|*"$origin".git) ;; *) continue ;; esac
          fi
          echo "\(marker)folder $d"; break
        done
        """)
    }
    lines.append("exit 0")
    return "sh -c " + shellQuote(lines.joined(separator: "\n"))
  }

  static func parse(_ lines: [String]) -> Answer {
    var answer = Answer()
    var found: Set<String> = []
    for line in lines {
      guard let range = line.range(of: marker) else { continue }
      let fields = line[range.upperBound...].split(separator: " ", maxSplits: 1).map(String.init)
      guard fields.count == 2 else { continue }
      answer.didAnswer = true
      switch fields[0] {
      case "system": answer.capabilities.system = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
      case "tool": found.insert(fields[1].trimmingCharacters(in: .whitespacesAndNewlines))
      case "folder": answer.folder = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
      default: break
      }
    }
    var toolchains = Set(tools.filter { found.contains($0.tool) }.flatMap(\.toolchains))
    if found.contains("xcodebuild") { toolchains.insert(.xcode) }
    answer.capabilities.toolchains = toolchains
    return answer
  }

  /// "owner/repo" from a Git remote's URL (`git@github.com:owner/repo.git`, `https://github.com/owner/repo`).
  static func originPath(_ url: String) -> String? {
    var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasSuffix(".git") { text.removeLast(4) }
    let parts = text.split(whereSeparator: { $0 == "/" || $0 == ":" }).map(String.init)
    guard parts.count >= 2 else { return nil }
    return parts.suffix(2).joined(separator: "/")
  }
}
