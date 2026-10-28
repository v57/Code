#if os(macOS) || os(Windows) || os(Linux)
  #if os(macOS)
    import AppKit
    import Darwin
  #else
    import SwiftUIPortability
  #endif
  import CodeActions
  import Foundation
  import Observation

  /// Runs a program under LLDB with the project's breakpoints, as Xcode does
  /// when breakpoints are on: the editor shows where it stopped, and the
  /// debug bar continues, steps and pauses. The program's output arrives on
  /// its own terminal, so it shows line by line.
  @MainActor @Observable public final class DebugSession {
    public enum State: Equatable {
      case starting
      case running
      case paused(reason: String)
      case ended
    }

    public private(set) var state: State = .starting
    /// The stopped frame's function, for the debug bar.
    public private(set) var frame: String?

    @ObservationIgnored private weak var services: ProjectServices?
    @ObservationIgnored private let executable: String
    @ObservationIgnored private let directory: URL
    #if os(macOS)
      @ObservationIgnored private let process = Process()
      @ObservationIgnored private let input = Pipe()
      @ObservationIgnored private let output = Pipe()
      @ObservationIgnored private var terminal: (master: Int32, slave: Int32, path: String)?
      @ObservationIgnored private var terminalSource: DispatchSourceRead?
    #else
      /// LLDB, its input a pipe; the program's output comes through LLDB's (Windows has no pseudo-terminal to
      /// give it).
      @ObservationIgnored private var lldb: ChildProcess?
    #endif
    @ObservationIgnored private var inferiorPID: Int32?
    @ObservationIgnored private var log: (@Sendable (String) -> Void)?
    @ObservationIgnored private var pending = ""
    @ObservationIgnored private var finished: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var stopLocation: (path: String, line: Int)?

    init(services: ProjectServices, executable: String, directory: URL) {
      self.services = services
      self.executable = executable
      self.directory = directory
    }

    /// Runs the program until it exits or Stop ends it.
    func run(context: ActionContext) async throws {
      log = { line in context.log(line) }
      guard FileManager.default.isExecutableFile(atPath: executable) else {
        throw ActionError.missing("The built program wasn’t found at \(executable).")
      }
      #if os(macOS)
        openTerminal()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["lldb", "--no-use-colors"]
        process.currentDirectoryURL = directory
        process.environment = context.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
          let data = handle.availableData
          guard !data.isEmpty else { return }
          let text = String(decoding: data, as: UTF8.self)
          Task { @MainActor in self?.receive(text) }
        }
        process.terminationHandler = { [weak self] _ in
          Task { @MainActor in self?.end() }
        }
        try process.run()
      #else
        try startLLDB(environment: context.environment)
      #endif
      context.onStop { [weak self] in Task { @MainActor in self?.stop() } }

      send("settings set auto-confirm true")
      send("settings set stop-disassembly-display no-debuginfo")
      send("target create \(quote(executable))")
      send("process handle SIGINT --pass false --stop true --notify true")
      for (url, lines) in services?.breakpoints ?? [:] where services?.breakpointsActive == true {
        for line in lines.sorted() { send("breakpoint set --file \(quote(FileTree.realPath(of: url))) --line \(line + 1)") }
      }
      #if os(macOS)
        let tty = terminal?.path ?? "/dev/null"
        send("process launch --working-dir \(quote(directory.path)) -i /dev/null -o \(tty) -e \(tty)")
      #elseif os(Windows)
        send("process launch --working-dir \(quote(directory.path)) -i NUL")
      #else
        send("process launch --working-dir \(quote(directory.path)) -i /dev/null")
      #endif
      state = .running
      await withCheckedContinuation { continuation in finished = continuation }
    }

    // MARK: - Commands

    public func continueRunning() { resume("process continue") }
    public func stepOver() { resume("thread step-over") }
    public func stepInto() { resume("thread step-in") }
    public func stepOut() { resume("thread step-out") }

    /// Pauses the running program (an interrupt LLDB catches).
    public func pause() {
      guard state == .running, let pid = inferiorPID else { return }
      #if os(macOS)
        kill(pid, SIGINT)
      #else
        _ = pid
        send("process interrupt")
      #endif
    }

    public func stop() {
      guard state != .ended else { return }
      #if os(macOS)
        if let pid = inferiorPID { kill(pid, SIGKILL) }
      #endif
      send("process kill")
      send("quit")
      #if os(macOS)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [process] in
          if process.isRunning { process.terminate() }
        }
      #else
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [lldb] in lldb?.terminate() }
      #endif
    }

    /// Sends a command typed in the console.
    public func sendCommand(_ command: String) {
      log?("(lldb) " + command)
      send(command)
    }

    /// Sets breakpoints again after they changed, while paused (LLDB takes
    /// commands only then).
    func breakpointsChanged(_ breakpoints: [URL: Set<Int>]) {
      guard case .paused = state else { return }
      send("breakpoint delete")
      for (url, lines) in breakpoints {
        for line in lines.sorted() { send("breakpoint set --file \(quote(FileTree.realPath(of: url))) --line \(line + 1)") }
      }
    }

    private func resume(_ command: String) {
      guard case .paused = state else { return }
      state = .running
      frame = nil
      services?.executionLocation = nil
      send(command)
    }

    private func send(_ command: String) {
      #if os(macOS)
        try? input.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
      #else
        lldb?.write(Data((command + "\n").utf8))
      #endif
    }

    private func quote(_ text: String) -> String {
      "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        + "\""
    }

    // MARK: - Output

    private func receive(_ text: String) {
      pending += text
      while let newline = pending.firstIndex(of: "\n") {
        let line = String(pending[..<newline])
        pending.removeSubrange(...newline)
        handle(line)
      }
    }

    private static let launched = try! NSRegularExpression(pattern: #"^Process (\d+) launched"#)
    private static let stopped = try! NSRegularExpression(pattern: #"^Process (\d+) stopped"#)
    private static let exited = try! NSRegularExpression(pattern: #"^Process (\d+) exited with status = (-?\d+)"#)
    private static let reason = try! NSRegularExpression(pattern: #"stop reason = (.*)$"#)
    /// The path is absolute (`/…`, or `C:\…` on Windows) or relative.
    private static let frameLine = try! NSRegularExpression(
      pattern: #"frame #0: .*?`(.*?) at ((?:[A-Za-z]:)?[/\\][^:]+|[^/\\:][^:]*):(\d+)(?::\d+)?"#)

    private func handle(_ line: String) {
      log?(line)
      let range = NSRange(line.startIndex..<line.endIndex, in: line)
      if let match = Self.launched.firstMatch(in: line, range: range),
        let pid = Range(match.range(at: 1), in: line).flatMap({ Int32(line[$0]) })
      {
        inferiorPID = pid
      } else if let match = Self.reason.firstMatch(in: line, range: range),
        let reason = Range(match.range(at: 1), in: line).map({ String(line[$0]) })
      {
        state = .paused(reason: reason)
      } else if let match = Self.frameLine.firstMatch(in: line, range: range),
        let function = Range(match.range(at: 1), in: line).map({ String(line[$0]) }),
        let path = Range(match.range(at: 2), in: line).map({ String(line[$0]) }),
        let number = Range(match.range(at: 3), in: line).flatMap({ Int(line[$0]) })
      {
        frame = function
        if case .running = state { state = .paused(reason: "") }
        showStop(path: path, line: number)
      } else if Self.exited.firstMatch(in: line, range: range) != nil {
        services?.executionLocation = nil
        send("quit")
      } else if line.contains("error: ") && state == .running && inferiorPID == nil {
        // Launching failed.
        send("quit")
      }
    }

    private func showStop(path: String, line: Int) {
      guard let services else { return }
      var url = URL(fileURLWithPath: path)
      let isAbsolute = path.hasPrefix("/") || path.dropFirst().hasPrefix(":")
      if !isAbsolute { url = services.resolve(URL(fileURLWithPath: path, relativeTo: directory)) ?? url }
      url = url.standardizedFileURL
      services.executionLocation = (url, line - 1)
      services.open(url, line: line, remember: false)
      #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
      #endif
      // Variables of the stopped frame, in the console.
      send("frame variable")
    }

    private func end() {
      guard state != .ended else { return }
      state = .ended
      frame = nil
      services?.executionLocation = nil
      #if os(macOS)
        output.fileHandleForReading.readabilityHandler = nil
        closeTerminal()
      #else
        lldb = nil
      #endif
      if services?.debugger === self { services?.debugger = nil }
      finished?.resume()
      finished = nil
    }

    #if os(Windows) || os(Linux)
      /// The toolchain's LLDB from the PATH, its output read on threads.
      private func startLLDB(environment: [String: String]) throws {
        #if os(Windows)
          let (separator, name): (Character, String) = (";", "lldb.exe")
        #else
          let (separator, name): (Character, String) = (":", "lldb")
        #endif
        let path = (environment["Path"] ?? environment["PATH"] ?? "").split(separator: separator)
          .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
          .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let path else { throw ActionError.missing("LLDB wasn’t found on the PATH (it comes with the Swift toolchain).") }
        let lldb = try ChildProcess(
          executable: path, arguments: ["--no-use-colors"], directory: directory, environment: environment, input: true)
        self.lldb = lldb
        let group = DispatchGroup()
        for stream in [ChildProcess.Stream.output, .error] {
          group.enter()
          Thread.detachNewThread { [weak self] in
            lldb.read(stream) { data in
              let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
              Task { @MainActor in self?.receive(text) }
            }
            group.leave()
          }
        }
        Thread.detachNewThread { [weak self] in
          _ = lldb.waitUntilExit()
          group.wait()
          Task { @MainActor in self?.end() }
        }
      }
    #endif

    #if os(macOS)
    // MARK: - The program's terminal

    private func openTerminal() {
      var master: Int32 = -1
      var slave: Int32 = -1
      var size = winsize(ws_row: 50, ws_col: 400, ws_xpixel: 0, ws_ypixel: 0)
      guard openpty(&master, &slave, nil, nil, &size) == 0, let name = ttyname(slave) else { return }
      var settings = termios()
      tcgetattr(slave, &settings)
      settings.c_oflag &= ~tcflag_t(OPOST)
      tcsetattr(slave, TCSANOW, &settings)
      terminal = (master, slave, String(cString: name))
      let source = Self.makeReader(master: master, slave: slave) { [weak self] lines in
        Task { @MainActor in for line in lines { self?.log?(line) } }
      }
      terminalSource = source
      source.resume()
    }

    /// Reads the program's terminal off the main thread and hands over
    /// whole lines.
    private nonisolated static func makeReader(
      master: Int32, slave: Int32, deliver: @escaping @Sendable ([String]) -> Void
    ) -> DispatchSourceRead {
      let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global())
      nonisolated(unsafe) var buffer = Data()
      source.setEventHandler {
        var bytes = [UInt8](repeating: 0, count: 16384)
        let count = read(master, &bytes, bytes.count)
        guard count > 0 else { return }
        buffer.append(contentsOf: bytes[0..<count])
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
          lines.append(ANSI.strip(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)))
          buffer.removeSubrange(buffer.startIndex...newline)
        }
        if !lines.isEmpty { deliver(lines) }
      }
      source.setCancelHandler {
        close(master)
        close(slave)
      }
      return source
    }

    private func closeTerminal() {
      terminalSource?.cancel()
      terminalSource = nil
      terminal = nil
    }
    #endif
  }

  extension ProjectServices {
    /// The steps of Run under the debugger: when breakpoints are set and
    /// active, for a program this Mac runs (a package's executable, a Cargo
    /// binary, a CMake executable or an Xcode macOS app).
    func debugSteps(_ kind: ActionKind, _ scheme: ActionScheme, _ destination: RunDestination?)
      -> [ActionStep]?
    {
      guard kind == .run, settings.breakpointsEnabled, breakpointsActive, hasBreakpoints,
        destination == nil || destination?.kind == .mac
      else { return nil }
      let directory = scheme.directory
      if scheme.toolchain == .xcode {
        let arguments = "\(scheme.xcodeArguments) -destination 'platform=macOS'"
        return [
          .shell("Build", "xcodebuild \(arguments) build"),
          ActionStep("Debug") { [weak self] context in
            guard let json = await context.capture("xcodebuild \(arguments) -showBuildSettings -json"),
              let product = XcodeProduct.parse(json, scheme: scheme.name)
            else { throw ActionError.missing("Couldn’t read the build settings of “\(scheme.name)”.") }
            try await self?.debug(product.executablePath, in: product.buildDirectory, context: context)
          },
        ]
      }
      guard let executable = scheme.executableURL, let build = scheme.commands[.build] else { return nil }
      return [
        .shell("Build", build),
        ActionStep("Debug") { [weak self] context in
          try await self?.debug(executable.path, in: directory, context: context)
        },
      ]
    }

    private func debug(_ executable: String, in directory: URL, context: ActionContext) async throws {
      let session = DebugSession(services: self, executable: executable, directory: directory)
      debugger = session
      defer { if debugger === session { debugger = nil } }
      try await session.run(context: context)
    }
  }
#endif
