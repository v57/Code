import Foundation
import Testing

@testable import CodeActions

@MainActor @Suite(.serialized) struct BuildSourceTests {
  private func project(_ name: String = UUID().uuidString) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("build-source-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.resolvingSymlinksInPath()
  }

  private func forget(_ root: URL) {
    for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("CodeActions.") && key.contains(root.path) {
      UserDefaults.standard.removeObject(forKey: key)
    }
    try? FileManager.default.removeItem(at: root)
  }

  private func scheme(_ name: String, _ toolchain: Toolchain, platforms: [Platform] = [.mac]) -> ActionScheme {
    ActionScheme(
      name: name, toolchain: toolchain, directory: URL(fileURLWithPath: "/p"), commands: [.build: "true"],
      platforms: platforms)
  }

  private let colima = ContainerRuntime(
    kind: .colima, name: "default", endpoint: "unix:///nonexistent/docker.sock", isRunning: false)
  private let machine = SSHExecutor.Target(id: "m1", name: "mini", host: "10.0.0.2", directory: "/Users/me/p", detail: "SSH")

  // MARK: What each source builds

  /// An iOS app's only destinations are this computer's simulators and devices: it's listed here, and only here.
  @Test func thisComputerBuildsEveryScheme() throws {
    let can = BuildCapabilities.local
    #expect(can.canBuild(scheme("Phone only", .xcode, platforms: [.iOS])))
    #expect(can.canBuild(scheme("Phone", .android, platforms: [.android])))
    #expect(can.canBuild(scheme("tool", .swiftPM)))
    #expect(can.canUse(ProjectContainer(directory: URL(fileURLWithPath: "/p"), fileName: "App.xcodeproj")))

    let root = try project()
    defer { forget(root) }
    #expect(ActionController(root: root).selectedBuildCapabilities.canBuild(scheme("Phone only", .xcode, platforms: [.iOS])))

    // What a machine answered is kept encoded, without ever counting as this computer.
    let saved = try JSONDecoder().decode(BuildCapabilities.self, from: JSONEncoder().encode(BuildCapabilities.local))
    #expect(!saved.canBuild(scheme("Phone only", .xcode, platforms: [.iOS])))
  }

  @Test func containersBuildNeitherXcodeNorAndroid() {
    let can = BuildCapabilities.container
    #expect(!can.canBuild(scheme("App", .xcode)))
    #expect(!can.canBuild(scheme("Phone", .android, platforms: [.android])))
    #expect(can.canBuild(scheme("tool", .swiftPM)))
    #expect(can.canBuild(scheme("server", .go)))
    #expect(can.canUse(ProjectContainer(directory: URL(fileURLWithPath: "/p"), fileName: "Package.swift")))
    #expect(!can.canUse(ProjectContainer(directory: URL(fileURLWithPath: "/p"), fileName: "App.xcodeproj")))
    #expect(!can.canUse(ProjectContainer(directory: URL(fileURLWithPath: "/p"), fileName: "App.xcworkspace")))
  }

  @Test func aMachineBuildsWhatItHasTheToolsFor() {
    let linux = MachineProbe.parse([
      "motd line", "CODE-PROBE system Linux", "CODE-PROBE tool go", "CODE-PROBE tool java\r",
    ])
    #expect(linux.didAnswer)
    #expect(linux.capabilities.system == "Linux")
    #expect(linux.capabilities.canBuild(scheme("server", .go)))
    #expect(linux.capabilities.canBuild(scheme("jvm", .gradle)))
    #expect(!linux.capabilities.canBuild(scheme("App", .xcode)))
    #expect(!linux.capabilities.canBuild(scheme("tool", .swiftPM)))

    let mac = MachineProbe.parse(["CODE-PROBE system Darwin", "CODE-PROBE tool xcodebuild", "CODE-PROBE folder /Users/me/my p"])
    #expect(mac.capabilities.canBuild(scheme("App", .xcode)))
    #expect(!mac.capabilities.canBuild(scheme("Phone only", .xcode, platforms: [.iOS])))
    #expect(mac.folder == "/Users/me/my p")

    // Not asked yet: everything but what never runs elsewhere.
    let unknown = BuildCapabilities()
    #expect(unknown.canBuild(scheme("App", .xcode)))
    #expect(!unknown.canBuild(scheme("Phone", .android)))
    #expect(!MachineProbe.parse(["ssh: connect to host mini port 22: Connection refused"]).didAnswer)
  }

  /// The script runs on the machine it's written for: POSIX sh, finding a folder, refusing another project's.
  @Test func theProbeFindsTheProjectAndNotAnotherOfTheSameName() throws {
    let home = try project()
    defer { try? FileManager.default.removeItem(at: home) }
    let other = home.appendingPathComponent("Developer/group/App")
    let wrong = home.appendingPathComponent("Developer/App")
    for folder in [other, wrong] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    func git(_ folder: URL, _ url: String) {
      _ = SubprocessCapture.run("/usr/bin/git", ["-C", folder.path, "init", "-q"], timeout: 10)
      _ = SubprocessCapture.run("/usr/bin/git", ["-C", folder.path, "remote", "add", "origin", url], timeout: 10)
    }
    git(wrong, "git@github.com:someone/App.git")
    git(other, "https://github.com/me/App.git")
    func run(_ find: (name: String, relativePath: String?, origin: String?)?) -> MachineProbe.Answer {
      let output = SubprocessCapture.run(
        "/bin/zsh", ["-c", MachineProbe.script(find: find)],
        environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], timeout: 30) ?? ""
      return MachineProbe.parse(output.split(separator: "\n").map(String.init))
    }
    #expect(run(("App", nil, "me/App")).folder?.hasSuffix("/Developer/group/App") == true)
    #expect(run(("App", nil, nil)).folder?.hasSuffix("/Developer/App") == true)
    #expect(run(("App", nil, "me/Elsewhere")).folder == nil)
    #expect(run(("Missing", nil, nil)).folder == nil)
    #expect(run(("App", "Developer/group/App", nil)).folder?.hasSuffix("/Developer/group/App") == true)
    #expect(run(nil).capabilities.system != nil)
    #expect(MachineProbe.originPath("git@github.com:me/App.git\n") == "me/App")
    #expect(MachineProbe.originPath("https://github.com/me/App") == "me/App")
  }

  // MARK: Finding runtimes

  @Test func colimaIsListedByProfileRunningOrNot() {
    let list = """
      {"name":"default","status":"Stopped","arch":"aarch64","runtime":"docker"}
      {"name":"work","status":"Running","runtime":"docker"}
      {"name":"kube","status":"Running","runtime":"containerd"}
      """
    let found = ContainerRuntimes.parseColima(list, home: "/h/.colima") { $0.contains("/work/") }
    #expect(found.map(\.id) == ["colima:default", "colima:work"])
    #expect(found[0].endpoint == "unix:///h/.colima/default/docker.sock")
    #expect(!found[0].isRunning)
    #expect(found[1].isRunning)
    #expect(found[0].displayName == "Colima")
    #expect(found[1].displayName == "Colima (work)")
    #expect(found[0].startCommand == "colima start")
    #expect(found[1].startCommand == "colima start --profile work")
  }

  @Test func colimaAStoppedDaemonAndOtherMachinesAreNotDockerRuntimes() {
    let list = """
      {"Current":false,"Name":"colima","DockerEndpoint":"unix:///h/.colima/default/docker.sock"}
      {"Current":true,"Name":"default","DockerEndpoint":"unix:///var/run/docker.sock"}
      {"Current":false,"Name":"desktop-linux","DockerEndpoint":"unix:///h/.docker/run/docker.sock"}
      {"Current":false,"Name":"server","DockerEndpoint":"ssh://me@server"}
      """
    #expect(ContainerRuntimes.parseContexts(list, isOpen: { _ in false }, hasDesktop: false).isEmpty)
    let installed = ContainerRuntimes.parseContexts(list, isOpen: { _ in false }, hasDesktop: true)
    #expect(installed.map(\.displayName) == ["Docker Desktop"])
    #expect(installed[0].isRunning == false)
    let running = ContainerRuntimes.parseContexts(list, isOpen: { $0.contains("var/run") }, hasDesktop: false)
    #expect(running.map(\.displayName) == ["Docker"])
    #expect(running[0].isRunning)
  }

  // MARK: Images and commands

  @Test func theProjectsDevcontainerImageWins() throws {
    let root = try project()
    defer { try? FileManager.default.removeItem(at: root) }
    let swift = ActionScheme(name: "tool", toolchain: .swiftPM, directory: root, commands: [:])
    #expect(ContainerImages.image(for: swift, root: root) == "swift:latest")
    let zig = ActionScheme(name: "z", toolchain: .zig, directory: root, commands: [:])
    #expect(ContainerImages.image(for: zig, root: root) == nil)
    let folder = root.appendingPathComponent(".devcontainer")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try """
    {
      // our toolchain
      "image": "swift:6.1-noble",
      "features": { "x": { "image": "not this one" } }
    }
    """.write(to: folder.appendingPathComponent("devcontainer.json"), atomically: true, encoding: .utf8)
    #expect(ContainerImages.image(for: swift, root: root) == "swift:6.1-noble")
    #expect(ContainerImages.image(for: zig, root: root) == "swift:6.1-noble")
  }

  @Test func buildsGoToTheVolumeRatherThanTheFolder() {
    let swift = ActionScheme(
      name: "tool", toolchain: .swiftPM, directory: URL(fileURLWithPath: "/p"),
      commands: [.build: "swift build --product tool", .run: "swift run tool", .clean: "swift package clean"]
    ).inContainer()
    #expect(swift.commands[.build] == "swift build --scratch-path /build/swift --product tool")
    #expect(swift.commands[.run] == "swift run --scratch-path /build/swift tool")
    let cargo = ActionScheme(
      name: "cli", toolchain: .cargo, directory: URL(fileURLWithPath: "/p"), commands: [.build: "cargo build -p cli"]
    ).inContainer()
    #expect(cargo.commands[.build] == "cargo build --target-dir /build/cargo -p cli")
    let cmake = ActionScheme(
      name: "c", toolchain: .cmake, directory: URL(fileURLWithPath: "/p"),
      commands: [.test: "cmake -S . -B build && cmake --build build && ctest --test-dir build"]
    ).inContainer()
    #expect(cmake.commands[.test] == "cmake -S . -B /build/cmake && cmake --build /build/cmake && ctest --test-dir /build/cmake")
  }

  @Test func theContainerCommandMountsTheProjectAndNamesTheRuntime() {
    let root = URL(fileURLWithPath: "/Users/me/My App")
    let executor = ContainerExecutor(runtime: colima, image: "golang:latest", toolchain: .go, localRoot: root)
    let arguments = executor.runArguments("go build", directory: root.appendingPathComponent("cmd"), name: "code-1")
    #expect(arguments.starts(with: ["docker", "--host", "unix:///nonexistent/docker.sock", "run", "--rm", "--tty"]))
    #expect(arguments.contains("/Users/me/My App:/workspace"))
    #expect(arguments.contains(executor.volume + ":/build"))
    #expect(arguments[arguments.firstIndex(of: "--workdir")! + 1] == "/workspace/cmd")
    #expect(arguments.contains("GOCACHE=/build/go/cache"))
    #expect(arguments.contains("host"))
    #expect(arguments.suffix(4).first == "golang:latest")
    #expect(arguments.last?.hasSuffix("go build") == true)
    #expect(executor.script("/Users/me/My App/bin/x").hasSuffix("/workspace/bin/x"))
    #expect(executor.volume == ContainerExecutor(runtime: colima, image: "x", toolchain: .node, localRoot: root).volume)
  }

  /// A stopped runtime fails at once with what to do, instead of `docker` waiting and failing obscurely.
  @Test func aStoppedRuntimeSaysSo() {
    let executor = ContainerExecutor(runtime: colima, image: "x", toolchain: .go, localRoot: URL(fileURLWithPath: "/p"))
    #expect(throws: ActionError.missing("Colima isn’t running. Start it from Build From.")) {
      _ = try executor.start("true", directory: URL(fileURLWithPath: "/p"), environment: [:])
    }
  }

  // MARK: The controller

  private func swiftPackage(_ root: URL) throws {
    try """
    // swift-tools-version: 5.9
    import PackageDescription
    let package = Package(name: "Tool", targets: [.executableTarget(name: "tool")])
    """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
    try """
    // !$*UTF8*$!
    { objects = { 1 = { isa = PBXNativeTarget; name = App; productType = "com.apple.product-type.application"; }; }; }
    """.write(to: root.appendingPathComponent("App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
  }

  private func waitForScan(_ controller: ActionController, until: () -> Bool = { true }) async throws {
    for _ in 0..<600 {
      if !controller.isScanning, until() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("the scan didn't finish")
  }

  @Test func aProjectWithNothingElseShowsNoBuildFrom() throws {
    let root = try project()
    defer { forget(root) }
    let controller = ActionController(root: root)
    #expect(!controller.hasOtherBuildSources)
    #expect(controller.selectedBuildSource == .local)
    #expect(controller.selectedBuildSourceStatus == .ready)
    controller.machineTargets = [machine]
    #expect(controller.hasOtherBuildSources)
    #expect(controller.buildSources.map(\.id) == ["local", "ssh:m1"])
    #expect(controller.buildSources[1].section == "Other Machines")
    #expect(BuildSource(place: .machine(.init(id: "h", name: "h", host: "h", directory: ""))).section == "Find on Another Machine")
  }

  @Test func changingTheSourceFiltersSchemesAndRemembersEachOnesPicks() async throws {
    let root = try project()
    defer { forget(root) }
    try swiftPackage(root)
    let controller = ActionController(root: root)
    controller.machineTargets = [machine]
    controller.selectedSchemeID = "\(root.path)#xcode#App"
    controller.scan()
    try await waitForScan(controller) { !controller.schemes.isEmpty }
    #expect(controller.containers.map(\.fileName).contains("App.xcodeproj"))

    // Listing a machine and selecting this computer again contacted nothing, so no status yet.
    #expect(controller.buildSourceStatuses.isEmpty)

    // A container: Xcode's containers and schemes go, whichever was picked in this folder.
    let container = BuildSource(place: .container(colima))
    controller.selectBuildSource(container)
    #expect(!controller.schemes.contains { $0.toolchain == .xcode })
    try await waitForScan(controller) { controller.schemes.contains { $0.name == "tool" } }
    #expect(controller.schemes.map(\.name) == ["tool"])
    #expect(controller.containers.map(\.fileName) == ["Package.swift"])
    #expect(controller.selectedDestination?.kind == .container)
    #expect(controller.selectedDestination?.name == "swift:latest")
    #expect(!controller.canPerform(.install))

    // It's remembered per project, also by a new controller, stopped or not.
    let again = ActionController(root: root)
    #expect(again.selectedBuildSourceID == container.id)
    #expect(again.selectedBuildSource.name == "Colima")
    again.selectBuildSource(.local)
    let other = ActionController(root: root)
    #expect(other.selectedBuildSource.isLocal)
    #expect(other.selectedSchemeID == "\(root.path)#xcode#App")
  }

  @Test func aSourceThatWentAwayStaysPickedAndSaysSo() async throws {
    let root = try project()
    defer { forget(root) }
    let controller = ActionController(root: root)
    controller.machineTargets = [machine]
    let source = controller.buildSources[1]
    UserDefaults.standard.set(source.id, forKey: "CodeActions.buildSource:" + root.path)
    UserDefaults.standard.set(try JSONEncoder().encode(source), forKey: "CodeActions.buildSourceInfo:" + root.path)

    let later = ActionController(root: root)
    later.machineTargets = []
    #expect(later.selectedBuildSourceID == "ssh:m1")
    #expect(later.selectedBuildSource.name == "mini")
    #expect(later.hasOtherBuildSources)
    guard case .unavailable(let reason) = later.selectedBuildSourceStatus else {
      Issue.record("no reason")
      return
    }
    #expect(reason.contains("mini"))
    // Back again: picked as before, and nothing has contacted it.
    later.machineTargets = [machine]
    #expect(later.selectedBuildSourceStatus == .unknown)
  }

  @Test func aMachineChosenUnderRunOnBecomesTheSource() throws {
    let root = try project()
    defer { forget(root) }
    UserDefaults.standard.set("ssh:m1", forKey: "CodeActions.destination:" + root.path)
    let controller = ActionController(root: root)
    controller.machineTargets = [machine]
    #expect(controller.selectedBuildSourceID == "ssh:m1")
    #expect(controller.selectedDestination?.id == "ssh:m1")
  }

  @Test func aMachineOutOfReachIsMarkedAndTheChoiceStays() async throws {
    let root = try project()
    defer { forget(root) }
    let controller = ActionController(root: root)
    // Nothing listens on port 9 of this machine: ssh fails at once, as with a device that's off.
    let target = SSHExecutor.Target(id: "off", name: "gone", host: "127.0.0.1", port: 9, directory: root.path, detail: "SSH")
    controller.machineTargets = [target]
    controller.selectBuildSource(controller.buildSources[1])
    #expect(controller.selectedBuildSourceStatus == .checking)
    for _ in 0..<400 where controller.selectedBuildSourceStatus == .checking {
      try await Task.sleep(for: .milliseconds(50))
    }
    guard case .unavailable(let reason) = controller.selectedBuildSourceStatus else {
      Issue.record("\(controller.selectedBuildSourceStatus)")
      return
    }
    #expect(reason.hasPrefix("Couldn’t reach gone"))
    #expect(controller.selectedBuildSourceID == "ssh:off")
    #expect(controller.selectedDestination?.id == "ssh:off")
  }

  @Test func theBuildLogsPathsPointAtTheProjectHere() {
    let box = IssueBox()
    let sink = OutputSink(directory: URL(fileURLWithPath: "/here/App"), pathsThere: ("/workspace", "/here/App")) { _, events in
      for case .issue(let issue) in events { box.urls.append(issue.url?.path ?? "") }
    }
    sink.add(ActionLine(text: "/workspace/Sources/a.swift:3:1: error: nope", isTransient: false))
    sink.flush()
    #expect(box.urls == ["/here/App/Sources/a.swift"])
  }

  final class IssueBox: @unchecked Sendable {
    var urls: [String] = []
  }
}

/// A real run in a container, when asked to: needs a running runtime and pulls a small image. Removes what it makes.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CODE_CONTAINER_TEST"] != nil))
struct ContainerExecutorIntegrationTests {
  static let image = "alpine:3"

  private func runtime() throws -> ContainerRuntime {
    try #require(ContainerRuntimes.detect().first { $0.isRunning }, "no runtime running")
  }

  private func docker(_ runtime: ContainerRuntime, _ arguments: [String]) -> String? {
    SubprocessCapture.run(
      ShellEnvironment.shared.which("docker") ?? "docker", ["--host", runtime.endpoint] + arguments,
      environment: ShellEnvironment.shared.variables, timeout: 60)
  }

  private func folder() throws -> URL {
    // Under the home folder: what Colima shares with its VM.
    let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".code-container-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Sub"), withIntermediateDirectories: true)
    try "hello\n".write(to: root.appendingPathComponent("Sub/file.txt"), atomically: true, encoding: .utf8)
    return root
  }

  @Test func runsSeesTheProjectKeepsTheVolumeAndStops() async throws {
    let runtime = try runtime()
    let root = try folder()
    let executor = ContainerExecutor(runtime: runtime, image: Self.image, toolchain: .make, localRoot: root)
    defer {
      try? FileManager.default.removeItem(at: root)
      _ = docker(runtime, ["volume", "rm", "-f", executor.volume])
    }
    let lines = Lines()
    let context = ActionContext(
      directory: root.appendingPathComponent("Sub"), environment: ShellEnvironment.shared.variables, executor: executor
    ) { lines.add($0.text) }

    // The folder, relative and absolute paths, and what goes into the volume survive the container.
    try await context.run(
      "pwd; cat file.txt; cat \(root.path)/Sub/file.txt; echo built > /build/product; printf 'made\\n' > made.txt", title: "Build")
    #expect(lines.all.contains("/workspace/Sub"))
    #expect(lines.all.filter { $0 == "hello" }.count == 2)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sub/made.txt").path))
    try await context.run("cat /build/product", title: "Again")
    #expect(lines.all.contains("built"))

    // A failing command's status comes back.
    await #expect(throws: ActionError.failed(status: 3, step: "Fail")) { try await context.run("exit 3", title: "Fail") }

    // Stop ends the container, which is removed.
    let stopping = ActionContext(
      directory: root, environment: ShellEnvironment.shared.variables, executor: executor
    ) { lines.add($0.text) }
    let started = Date()
    async let finished: Void = { _ = try? await stopping.run("echo sleeping; sleep 120", title: "Sleep") }()
    for _ in 0..<100 where !lines.all.contains("sleeping") { try await Task.sleep(for: .milliseconds(200)) }
    #expect(lines.all.contains("sleeping"))
    stopping.cancel()
    await finished
    #expect(Date().timeIntervalSince(started) < 60)
    #expect(stopping.isCancelled)
    try await Task.sleep(for: .seconds(2))
    let left = docker(runtime, ["ps", "-a", "--filter", "label=dev.v57.code=build", "--format", "{{.Names}}"]) ?? "?"
    #expect(!left.contains(ContainerExecutor.digest(root.path)))
  }

  final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
  }
}
