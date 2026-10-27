import Foundation
import SSHKit
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

    @Test func remoteBuildsSignAsTheTargetSays() throws {
      let scheme = ActionScheme(
        name: "Atlas", toolchain: .xcode, directory: URL(fileURLWithPath: "/tmp/Atlas"), commands: [:], platforms: [.mac],
        xcodeContainer: "Atlas.xcodeproj")
      let remote = RunDestination(id: "ssh:studio", name: "Mac Studio", kind: .remote)
      #expect(ActionPlanner.steps(for: .test, scheme: scheme, destination: remote, signing: .loginKeychain).map(\.title) == ["Test"])
      #expect(RemoteSigning.unsigned.xcodebuild("-project Atlas.xcodeproj", "build")
        == "xcodebuild -project Atlas.xcodeproj CODE_SIGNING_ALLOWED=NO build")
      let login = RemoteSigning.loginKeychain.xcodebuild("-project Atlas.xcodeproj", "test")
      #expect(login.contains("security unlock-keychain -p \"$CODE_LOGIN_PASSWORD\""))
      #expect(login.hasSuffix("exec xcodebuild -project Atlas.xcodeproj test"))
      #expect(RemoteSigning.desktopSession.step("Build", "-project Atlas.xcodeproj", "build").title == "Build")
      let job = DesktopJob(id: "abc", command: "xcodebuild -project Atlas.xcodeproj build")
      #expect(job.startScript.contains("launchctl bootstrap \"gui/$(id -u)\""))
      #expect(job.followScript(from: 42).contains("tail -n +42 -f"))
    }

    /// The login password reaches `security` there as a shell variable, never in the command the log shows; a
    /// build with none saved stops with why.
    @Test func theLoginPasswordStaysOutOfTheLog() async throws {
      let bin = FileManager.default.temporaryDirectory.appendingPathComponent("fake-bin-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: bin) }
      for tool in ["security", "xcodebuild"] {
        let file = bin.appendingPathComponent(tool)
        try Data("#!/bin/sh\necho \"\(tool) $*\"\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
      }
      let command = RemoteSigning.loginKeychain.xcodebuild("-scheme Atlas", "build")
      func run(_ secrets: [String: String]) async -> (lines: [String], failed: Bool) {
        let executor = SSHExecutor(
          target: .init(id: "studio", name: "Mac Studio", host: "h", directory: "/tmp", signing: .loginKeychain),
          localRoot: URL(fileURLWithPath: "/project"), secrets: secrets)
        let script = "PATH=\(bin.path):$PATH; " + executor.remoteScript(command, directory: URL(fileURLWithPath: "/project"))
        let lines = LineBox()
        let context = ActionContext(directory: URL(fileURLWithPath: "/tmp"), environment: [:], executor: LocalExecutor()) {
          lines.append($0.text)
        }
        let failed = (try? await context.run("/bin/zsh -c \(shellQuote(script))", title: "Build")) == nil
        return (lines.all, failed)
      }
      let saved = await run([RemoteSigning.passwordVariable: "it's s3cret"])
      #expect(saved.lines.contains("security unlock-keychain -p it's s3cret \(NSHomeDirectory())/Library/Keychains/login.keychain-db"))
      #expect(saved.lines.contains("xcodebuild -scheme Atlas build"))
      #expect(!saved.failed)
      // The step's command, which the log shows, doesn't have it (here the log also shows the test's own wrapper).
      #expect(!command.contains("s3cret"))
      #expect(saved.lines.filter { $0.contains("s3cret") && !$0.hasPrefix("$ ") }.count == 1)
      let missing = await run([:])
      #expect(missing.failed)
      #expect(missing.lines.contains("error: No login password is saved for this Mac to unlock its keychain."))
    }

    /// The desktop session's job (`DesktopJob`) on this Mac's own `gui/<uid>` domain: its output once each though
    /// the first connection drops halfway, and its exit status. Starts real launchd jobs, so it runs only with
    /// `CODE_DESKTOP_JOB_TEST=1`, logged in on this Mac.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODE_DESKTOP_JOB_TEST"] != nil))
    func desktopJobsOutliveTheirConnection() async throws {
      let job = DesktopJob(command: "for i in 1 2 3 4 5 6; do echo line-$i; sleep 1; done; exit 3")
      let lines = LineBox()
      let context = ActionContext(
        directory: URL(fileURLWithPath: NSTemporaryDirectory()), environment: ProcessInfo.processInfo.environment,
        executor: DroppingExecutor(after: 2.5)
      ) { lines.append($0.text) }
      await #expect(throws: ActionError.self) { try await job.step("Build").work(context) }
      let output = lines.all.filter { $0.hasPrefix("line-") }
      #expect(output == (1...6).map { "line-\($0)" })
      #expect(lines.all.contains("Reconnecting: the build goes on on the Mac."))
      #expect(!lines.all.contains { $0.contains(DesktopJob.exitMarker) })
      #expect(lines.all.first == "$ " + job.command)
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

#endif

@Suite struct InProcessSSHTests {
  @Test func outputSplitsIntoLinesAsOnATerminal() {
    var splitter = ActionLineSplitter()
    var lines: [ActionLine] = []
    splitter.add(Data("one\r\ntw".utf8)) { lines.append($0) }
    splitter.add(Data("o\n\u{1B}[1mbold\u{1B}[0m\n10%\r20%\r".utf8)) { lines.append($0) }
    splitter.add(Data("30%\rdone".utf8)) { lines.append($0) }
    splitter.finish { lines.append($0) }
    #expect(lines.map(\.text) == ["one", "two", "bold", "30%", "done"])
    #expect(lines.map(\.isTransient) == [false, false, false, true, false])
  }

  @Test func theLoginGoesToTheTargetWithItsSignedKeyPinned() throws {
    let target = SSHExecutor.Target(
      id: "studio", name: "Mac Studio", host: "100.96.0.4", port: 2222, user: "me",
      hostKey: "ecdsa-sha2-nistp256 AAAAE2VjZHNh comment", directory: "/Users/me/Code/Atlas")
    let executor = SSHExecutor(
      target: target, localRoot: URL(fileURLWithPath: "/tmp/Atlas"),
      login: SSHServer(host: "", user: "fallback", password: "x", knownFingerprint: "SHA256:old"))
    let server = executor.server(from: try #require(executor.login))
    #expect(server.host == "100.96.0.4" && server.port == 2222 && server.user == "me")
    // SHA-256 of the key blob ("AAAAE2VjZHNh" decodes to it), unpadded base64, as libssh2 reports it.
    #expect(server.knownFingerprint == SSHExecutor.fingerprint(ofHostKey: "ecdsa-sha2-nistp256 AAAAE2VjZHNh"))
    #expect(server.knownFingerprint?.hasPrefix("SHA256:") == true && server.knownFingerprint != "SHA256:old")
    var unsigned = target
    unsigned.hostKey = nil
    unsigned.user = ""
    let other = SSHExecutor(target: unsigned, localRoot: executor.localRoot, login: executor.login).server(from: executor.login!)
    #expect(other.knownFingerprint == "SHA256:old" && other.user == "fallback")
  }

  /// A real run over SSHKit's client, when a server is given: `CODE_SSH_TEST_HOST`, `CODE_SSH_TEST_PORT`,
  /// `CODE_SSH_TEST_USER` and `CODE_SSH_TEST_KEY` (a private key file it accepts).
  @Test(.enabled(if: ProcessInfo.processInfo.environment["CODE_SSH_TEST_KEY"] != nil))
  func runsInProcess() async throws {
    let environment = ProcessInfo.processInfo.environment
    let key = try SSHKey(importing: String(contentsOfFile: environment["CODE_SSH_TEST_KEY"]!, encoding: .utf8))
    let remote = FileManager.default.temporaryDirectory.appendingPathComponent("remote-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: remote.appendingPathComponent("Sub"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: remote) }
    let met = LineBox()
    let executor = SSHExecutor(
      target: .init(
        id: "test", name: "test", host: environment["CODE_SSH_TEST_HOST"] ?? "127.0.0.1",
        port: Int(environment["CODE_SSH_TEST_PORT"] ?? "22") ?? 22, directory: remote.path),
      localRoot: URL(fileURLWithPath: "/nonexistent/project"),
      login: SSHServer(host: "", user: environment["CODE_SSH_TEST_USER"] ?? NSUserName(), key: key)
    ) { met.append($0) }
    let lines = LineBox()
    let context = ActionContext(
      directory: URL(fileURLWithPath: "/nonexistent/project/Sub"), environment: [:], executor: executor
    ) { lines.append($0.text) }
    try await context.run("pwd; printf 'a\\rb\\n'; echo out-$((40 + 2))", title: "Echo")
    #expect(lines.all.contains { $0.hasSuffix("/Sub") && $0.contains("remote-") })
    #expect(lines.all.contains("b"))
    #expect(lines.all.contains("out-42"))
    #expect(met.all.first?.hasPrefix("SHA256:") == true)
    await #expect(throws: ActionError.failed(status: 3, step: "Fail")) { try await context.run("exit 3", title: "Fail") }

    // Stop hangs the command up there.
    let stopping = ActionContext(
      directory: URL(fileURLWithPath: "/nonexistent/project"), environment: [:], executor: executor
    ) { lines.append($0.text) }
    let started = Date()
    async let finished: Void = { _ = try? await stopping.run("echo started; sleep 30", title: "Sleep") }()
    try await Task.sleep(for: .seconds(2))
    stopping.cancel()
    await finished
    #expect(Date().timeIntervalSince(started) < 10)

    // A wrong host key is refused, with the reason in the log.
    var pinned = executor
    pinned.target.hostKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNh"
    let refused = LineBox()
    let refusing = ActionContext(
      directory: URL(fileURLWithPath: "/nonexistent/project"), environment: [:], executor: pinned
    ) { refused.append($0.text) }
    await #expect(throws: ActionError.failed(status: 255, step: "Echo")) { try await refusing.run("true", title: "Echo") }
    #expect(refused.all.contains { $0.contains("identity changed") })
  }
}

/// Runs commands here, cutting the first one off after `after` seconds, as a dropped SSH connection does.
final class DroppingExecutor: ActionExecutor, @unchecked Sendable {
  let after: TimeInterval
  private let lock = NSLock()
  private var dropped = false

  init(after: TimeInterval) { self.after = after }

  func start(_ command: String, directory: URL, environment: [String: String]) throws -> any ActionCommand {
    let process = try LocalExecutor().start(command, directory: directory, environment: environment)
    let drop = lock.withLock { () -> Bool in
      defer { dropped = true }
      return !dropped
    }
    if drop {
      let after = after
      Task {
        try? await Task.sleep(for: .seconds(after))
        process.stop()
      }
    }
    return process
  }
}

final class LineBox: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []
  func append(_ line: String) { lock.withLock { lines.append(line) } }
  var all: [String] { lock.withLock { lines } }
}
