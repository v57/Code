import Foundation
import Testing

@testable import CodeActions

#if os(macOS)
  @Suite struct SSHExecutorTests {
    let executor = SSHExecutor(
      target: .init(
        id: "studio", name: "Mac Studio", host: "100.96.0.4", port: 2222, user: "me",
        hostKey: "ecdsa-sha2-nistp256 AAAAE2VjZHNh comment", directory: "/Users/me/Code/Atlas"),
      localRoot: URL(fileURLWithPath: "/Users/other/Developer/Atlas"))

    @Test func foldersMapToTheOtherMachine() {
      #expect(executor.remotePath("/Users/other/Developer/Atlas") == "/Users/me/Code/Atlas")
      #expect(executor.remotePath("/Users/other/Developer/Atlas/App") == "/Users/me/Code/Atlas/App")
      // Outside the project (or a sibling with the same prefix): the project's folder.
      #expect(executor.remotePath("/Users/other/Developer/AtlasOld") == "/Users/me/Code/Atlas")
      let command = executor.remoteCommand(
        "xcodebuild -project '/Users/other/Developer/Atlas/Atlas.xcodeproj' build",
        directory: URL(fileURLWithPath: "/Users/other/Developer/Atlas/App"))
      #expect(command.hasPrefix("exec \"$SHELL\" -lc "))
      #expect(command.contains("cd /Users/me/Code/Atlas/App && xcodebuild -project '\\''/Users/me/Code/Atlas/Atlas.xcodeproj'\\'' build"))
    }

    @Test func pinnedHostKeysAreTheOnlyOnesTrusted() throws {
      let arguments = try executor.sshArguments("true")
      #expect(arguments.first == "/usr/bin/ssh")
      #expect(arguments.contains("BatchMode=yes"))
      #expect(arguments.contains("StrictHostKeyChecking=yes"))
      #expect(arguments.suffix(3) == ["me@100.96.0.4", "--", "true"])
      let option = try #require(arguments.first { $0.hasPrefix("UserKnownHostsFile=") })
      let file = String(option.dropFirst("UserKnownHostsFile=".count))
      #expect(try String(contentsOfFile: file, encoding: .utf8) == "[100.96.0.4]:2222 ecdsa-sha2-nistp256 AAAAE2VjZHNh\n")
    }

    @Test func unknownHostsAreTrustedOnFirstUseOnly() throws {
      var target = executor.target
      target.hostKey = nil
      target.user = ""
      let arguments = try SSHExecutor(target: target, localRoot: executor.localRoot).sshArguments("true")
      #expect(arguments.contains("StrictHostKeyChecking=accept-new"))
      #expect(!arguments.contains { $0.hasPrefix("UserKnownHostsFile=") })
      #expect(arguments.suffix(3) == ["100.96.0.4", "--", "true"])
    }

    @Test func remoteDestinationsPlanTheirOwnSteps() {
      let scheme = ActionScheme(
        name: "Atlas", toolchain: .xcode, directory: URL(fileURLWithPath: "/tmp/Atlas"), commands: [:], platforms: [.mac, .iOS],
        xcodeContainer: "Atlas.xcodeproj")
      let remote = RunDestination(id: "ssh:studio", name: "Mac Studio", kind: .remote)
      let build = ActionPlanner.steps(for: .build, scheme: scheme, destination: remote)
      #expect(build.map(\.title) == ["Build"])
      #expect(ActionPlanner.steps(for: .run, scheme: scheme, destination: remote).map(\.title) == ["Run"])
    }

    /// A real run over SSH, when a server is given: `CODE_SSH_TEST_HOST`, `CODE_SSH_TEST_PORT`, `CODE_SSH_TEST_USER`
    /// and `CODE_SSH_TEST_HOST_KEY` (an OpenSSH public key line), with the user's keys authorized there.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODE_SSH_TEST_HOST"] != nil))
    func runsOverSSH() async throws {
      let environment = ProcessInfo.processInfo.environment
      let remote = FileManager.default.temporaryDirectory.appendingPathComponent("remote-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: remote.appendingPathComponent("Sub"), withIntermediateDirectories: true)
      let executor = SSHExecutor(
        target: .init(
          id: "test", name: "test", host: environment["CODE_SSH_TEST_HOST"]!,
          port: Int(environment["CODE_SSH_TEST_PORT"] ?? "22") ?? 22, user: environment["CODE_SSH_TEST_USER"] ?? "",
          hostKey: environment["CODE_SSH_TEST_HOST_KEY"], directory: remote.path),
        localRoot: URL(fileURLWithPath: "/nonexistent/project"))
      let lines = LineBox()
      let context = ActionContext(
        directory: URL(fileURLWithPath: "/nonexistent/project/Sub"), environment: ProcessInfo.processInfo.environment,
        executor: executor
      ) { lines.append($0.text) }
      try await context.run("pwd; echo out-$((40 + 2))", title: "Echo")
      #expect(lines.all.contains { $0.hasSuffix("/Sub") && $0.contains("remote-") })
      #expect(lines.all.contains("out-42"))
      await #expect(throws: ActionError.self) { try await context.run("exit 3", title: "Fail") }

      // Stop closes the connection, and the command there ends with it.
      let stopping = ActionContext(
        directory: URL(fileURLWithPath: "/nonexistent/project"), environment: ProcessInfo.processInfo.environment,
        executor: executor
      ) { lines.append($0.text) }
      let started = Date()
      async let finished: Void = { _ = try? await stopping.run("echo started; sleep 30", title: "Sleep") }()
      try await Task.sleep(for: .seconds(2))
      stopping.cancel()
      await finished
      #expect(Date().timeIntervalSince(started) < 10)
    }
  }

  final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
  }
#endif
