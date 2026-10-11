#if os(macOS)
  import Darwin
  import Foundation

  /// A shell command running on a pseudo-terminal, as Xcode runs products:
  /// programs see a terminal, so they flush output line by line (a Swift or
  /// Python program writing to a pipe would buffer it until exit) and show
  /// their progress. The command runs in its own session, so stopping it
  /// stops everything it started.
  public final class PTYProcess: @unchecked Sendable {
    /// One piece of output: a line, or a transient status line that a later
    /// one replaces (text ending in a carriage return, like a progress bar).
    public struct Line: Sendable {
      public var text: String
      public var isTransient: Bool
    }

    public let pid: pid_t
    private let master: Int32
    private let queue = DispatchQueue(label: "CodeActions.PTYProcess")
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var pending = Data()
    private var exitStatus: Int32?
    private var reachedEnd = false
    private var finished = false
    private var onLine: (@Sendable (Line) -> Void)?
    private var continuation: CheckedContinuation<Int32, Never>?

    /// Starts `/bin/zsh -c command` in `directory`.
    public init(command: String, directory: URL, environment: [String: String]) throws {
      var master: Int32 = -1
      var slave: Int32 = -1
      var size = winsize(ws_row: 50, ws_col: 400, ws_xpixel: 0, ws_ypixel: 0)
      guard openpty(&master, &slave, nil, nil, &size) == 0 else {
        throw ActionError.launchFailed(String(cString: strerror(errno)))
      }
      // No "\n" → "\r\n" translation: lines stay lines.
      var settings = termios()
      tcgetattr(slave, &settings)
      settings.c_oflag &= ~tcflag_t(OPOST)
      settings.c_lflag &= ~tcflag_t(ECHO)
      tcsetattr(slave, TCSANOW, &settings)

      var actions: posix_spawn_file_actions_t?
      posix_spawn_file_actions_init(&actions)
      defer { posix_spawn_file_actions_destroy(&actions) }
      posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
      posix_spawn_file_actions_adddup2(&actions, slave, 1)
      posix_spawn_file_actions_adddup2(&actions, slave, 2)
      posix_spawn_file_actions_addchdir_np(&actions, directory.path)

      var attributes: posix_spawnattr_t?
      posix_spawnattr_init(&attributes)
      defer { posix_spawnattr_destroy(&attributes) }
      // POSIX_SPAWN_SETSID (0x0400): a new session, so its process group is
      // this pid and stopping can signal the whole group.
      let flags = Int32(0x0400) | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
        | POSIX_SPAWN_SETSIGMASK
      posix_spawnattr_setflags(&attributes, Int16(flags))
      var noSignals = sigset_t()
      sigemptyset(&noSignals)
      posix_spawnattr_setsigmask(&attributes, &noSignals)
      var allSignals = sigset_t()
      sigfillset(&allSignals)
      posix_spawnattr_setsigdefault(&attributes, &allSignals)

      var env = environment
      env["TERM"] = "xterm-256color"
      env["COLUMNS"] = "400"
      env["PYTHONUNBUFFERED"] = "1"
      env["NSUnbufferedIO"] = "YES"
      env["CLICOLOR"] = "0"
      let arguments = ["/bin/zsh", "-c", command]
      let argv = arguments.map { strdup($0) } + [nil]
      let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
      defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
      }
      var pid: pid_t = 0
      let result = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv, envp)
      close(slave)
      guard result == 0 else {
        close(master)
        throw ActionError.launchFailed(String(cString: strerror(result)))
      }
      self.pid = pid
      self.master = master
    }

    deinit {
      readSource?.cancel()
      exitSource?.cancel()
    }

    /// Reads output until the command exits; returns its exit status (128 +
    /// the signal number when a signal ended it).
    public func run(onLine: @escaping @Sendable (Line) -> Void) async -> Int32 {
      await withCheckedContinuation { continuation in
        queue.async {
          self.onLine = onLine
          self.continuation = continuation
          self.startReading()
        }
      }
    }

    private func startReading() {
      let flags = fcntl(master, F_GETFL)
      _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
      let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
      source.setEventHandler { [weak self] in self?.readAvailable() }
      source.setCancelHandler { [master] in close(master) }
      readSource = source
      source.resume()

      let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
      exit.setEventHandler { [weak self] in self?.processExited() }
      exitSource = exit
      exit.resume()
      // It may have exited before the source was made.
      processExited()
    }

    private func readAvailable() {
      var buffer = [UInt8](repeating: 0, count: 65536)
      while true {
        let count = read(master, &buffer, buffer.count)
        if count > 0 {
          pending.append(contentsOf: buffer[0..<count])
          continue
        }
        if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
          // EIO: every writer closed the terminal.
          reachedEnd = true
          readSource?.cancel()
          readSource = nil
        }
        break
      }
      emitLines(final: reachedEnd)
      finishIfDone()
    }

    private func processExited() {
      guard exitStatus == nil else { return }
      var status: Int32 = 0
      let result = waitpid(pid, &status, WNOHANG)
      guard result == pid else { return }
      let signal = status & 0x7f
      exitStatus = signal == 0 ? (status >> 8) & 0xff : 128 + signal
      exitSource?.cancel()
      exitSource = nil
      // Programs it started in the background may hold the terminal open;
      // don't wait for them past a moment.
      queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
        guard let self, !self.finished else { return }
        if self.readSource != nil { self.readAvailable() }
        self.reachedEnd = true
        self.readSource?.cancel()
        self.readSource = nil
        self.emitLines(final: true)
        self.finishIfDone()
      }
      finishIfDone()
    }

    private func finishIfDone() {
      guard !finished, reachedEnd, let exitStatus else { return }
      finished = true
      continuation?.resume(returning: exitStatus)
      continuation = nil
      onLine = nil
    }

    private func emitLines(final: Bool) {
      guard let onLine else { return }
      while let newline = pending.firstIndex(of: 0x0A) {
        let chunk = pending[pending.startIndex..<newline]
        pending.removeSubrange(pending.startIndex...newline)
        emit(chunk, onLine: onLine)
      }
      if final, !pending.isEmpty {
        emit(pending[...], onLine: onLine)
        pending.removeAll()
      } else if let carriage = pending.lastIndex(of: 0x0D) {
        // A status line being redrawn: report its latest state.
        let chunk = pending[pending.startIndex..<carriage]
        pending.removeSubrange(pending.startIndex...carriage)
        if let last = chunk.split(separator: 0x0D).last {
          let text = ANSI.strip(String(decoding: last, as: UTF8.self))
          if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            onLine(Line(text: text, isTransient: true))
          }
        }
      }
    }

    private func emit(_ chunk: Data.SubSequence, onLine: (Line) -> Void) {
      var chunk = chunk
      // "\r\n" ends a line like "\n".
      if chunk.last == 0x0D { chunk = chunk.dropLast() }
      // "a\rb" shows as "b": keep what was drawn last.
      let parts = chunk.split(separator: 0x0D, omittingEmptySubsequences: false)
      for (index, part) in parts.enumerated() where index == parts.count - 1 || !part.isEmpty {
        let text = ANSI.strip(String(decoding: part, as: UTF8.self))
        let isLast = index == parts.count - 1
        if isLast {
          onLine(Line(text: text, isTransient: false))
        } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
          onLine(Line(text: text, isTransient: true))
        }
      }
    }

    /// Sends `signal` to the command and everything it started.
    public func signal(_ signal: Int32) {
      kill(-pid, signal)
      kill(pid, signal)
    }

    /// Stops the command like Xcode's Stop: an interrupt, then a terminate,
    /// then a kill for whatever is still running.
    public func stop() {
      signal(SIGINT)
      let pid = pid
      DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
        if kill(pid, 0) == 0 {
          kill(-pid, SIGTERM)
          kill(pid, SIGTERM)
        }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
        if kill(pid, 0) == 0 {
          kill(-pid, SIGKILL)
          kill(pid, SIGKILL)
        }
      }
    }
  }
#endif

/// Removes terminal escape sequences (colors, cursor movement) from output.
public enum ANSI {
  public static func strip(_ text: String) -> String {
    guard text.contains("\u{1B}") else { return text }
    var result = ""
    result.reserveCapacity(text.count)
    var scalars = text.unicodeScalars.makeIterator()
    while let scalar = scalars.next() {
      guard scalar == "\u{1B}" else {
        result.unicodeScalars.append(scalar)
        continue
      }
      guard let next = scalars.next() else { break }
      if next == "[" {
        // CSI: parameters, then a final byte in @...~.
        while let c = scalars.next(), !(0x40...0x7E).contains(c.value) {}
      } else if next == "]" {
        // OSC: up to BEL or ESC \.
        while let c = scalars.next(), c != "\u{07}", c != "\u{1B}" {}
      }
    }
    return result
  }
}

public enum ActionError: Error, LocalizedError, Equatable {
  case launchFailed(String)
  case failed(status: Int32, step: String)
  case missing(String)
  case cancelled

  public var errorDescription: String? {
    switch self {
    case .launchFailed(let message): return "Couldn’t start the command: \(message)"
    case .failed(let status, let step): return "\(step) failed (exit code \(status))"
    case .missing(let message): return message
    case .cancelled: return "Stopped"
    }
  }
}
