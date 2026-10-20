#if os(macOS) || os(Windows)
  import Foundation

  /// A JSON-RPC connection to a language server over its standard input and
  /// output, with the protocol's `Content-Length` framing.
  ///
  /// Requests the server sends (configuration, progress tokens, capability
  /// registration) get a neutral answer; notifications go to
  /// `onNotification`. Callbacks run on the main queue.
  public final class LSPConnection: @unchecked Sendable {
    public enum Failure: Error, LocalizedError, Equatable {
      case notRunning
      case serverError(code: Int, message: String)
      case launchFailed(String)
      case timedOut

      public var errorDescription: String? {
        switch self {
        case .notRunning: return "The language server isn’t running."
        case .serverError(_, let message): return message
        case .launchFailed(let message): return message
        case .timedOut: return "The language server didn’t answer in time."
        }
      }
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let queue = DispatchQueue(label: "CodeLSP.connection")
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    /// Requests cancelled before they were sent.
    private var cancelled: Set<Int> = []
    private var isClosed = false

    /// Called with each notification's method and params.
    public var onNotification: (@MainActor (String, JSONValue) -> Void)?
    /// Called when the server exits, with its exit status.
    public var onExit: (@MainActor (Int32) -> Void)?
    /// Called with what the server writes to standard error.
    public var onLog: (@MainActor (String) -> Void)?

    public init(executable: String, arguments: [String], directory: URL, environment: [String: String]) {
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      process.currentDirectoryURL = directory
      process.environment = environment
      process.standardInput = input
      process.standardOutput = output
      process.standardError = errors
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    public func start() throws {
      output.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        guard let self else { return }
        self.queue.async { self.receive(data) }
      }
      errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.onLog?(text) } }
      }
      process.terminationHandler = { [weak self] process in
        let status = process.terminationStatus
        guard let self else { return }
        self.queue.async { self.closed() }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onExit?(status) } }
      }
      do {
        try process.run()
      } catch {
        throw Failure.launchFailed(error.localizedDescription)
      }
    }

    /// Sends a request and waits for its result, or `timeout` seconds.
    /// Cancelling the task cancels the request (`$/cancelRequest`).
    public func request(_ method: String, _ params: JSONValue, timeout: Double? = nil) async throws
      -> JSONValue
    {
      let id = queue.sync {
        let id = nextID
        nextID += 1
        return id
      }
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          queue.async {
            guard !self.isClosed else {
              continuation.resume(throwing: Failure.notRunning)
              return
            }
            if self.cancelled.remove(id) != nil {
              continuation.resume(throwing: CancellationError())
              return
            }
            self.pending[id] = continuation
            if let timeout {
              self.queue.asyncAfter(deadline: .now() + timeout) {
                self.pending.removeValue(forKey: id)?.resume(throwing: Failure.timedOut)
              }
            }
            self.write(
              ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
          }
        }
      } onCancel: {
        queue.async {
          if let continuation = self.pending.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
            self.write(["jsonrpc": "2.0", "method": "$/cancelRequest", "params": ["id": .number(Double(id))]])
          } else {
            // Not sent yet: don't.
            self.cancelled.insert(id)
          }
        }
      }
    }

    public func notify(_ method: String, _ params: JSONValue) {
      queue.async {
        guard !self.isClosed else { return }
        self.write(["jsonrpc": "2.0", "method": .string(method), "params": params])
      }
    }

    /// Ends the server: `shutdown`, `exit`, then a terminate if it lingers.
    public func stop() async {
      _ = try? await request("shutdown", .null, timeout: 2)
      notify("exit", .null)
      let process = process
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        if process.isRunning { process.terminate() }
      }
    }

    // MARK: - Framing

    private func write(_ message: JSONValue) {
      guard let body = try? message.encoded() else { return }
      var data = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
      data.append(body)
      do {
        try input.fileHandleForWriting.write(contentsOf: data)
      } catch {
        closed()
      }
    }

    private func receive(_ data: Data) {
      guard !data.isEmpty else {
        closed()
        return
      }
      buffer.append(data)
      while let message = nextMessage() {
        handle(message)
      }
    }

    /// The next complete message in the buffer, removed from it.
    private func nextMessage() -> JSONValue? {
      let separator = Data("\r\n\r\n".utf8)
      guard let headerEnd = buffer.range(of: separator) else { return nil }
      let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
      var length: Int?
      for line in header.split(separator: "\r\n") {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2, parts[0].lowercased() == "content-length" {
          length = Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
      }
      guard let length else {
        // Not a header: drop it and resynchronize.
        buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
        return nil
      }
      guard buffer.count - (headerEnd.upperBound - buffer.startIndex) >= length else { return nil }
      let bodyStart = headerEnd.upperBound
      let body = buffer[bodyStart..<(bodyStart + length)]
      buffer.removeSubrange(buffer.startIndex..<(bodyStart + length))
      buffer = Data(buffer)
      return try? JSONValue.decode(Data(body))
    }

    private func handle(_ message: JSONValue) {
      let method = message["method"].string
      let id = message["id"]
      if let method {
        if !id.isNull {
          respond(to: id, method: method, params: message["params"])
        } else {
          let params = message["params"]
          DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onNotification?(method, params) }
          }
        }
        return
      }
      guard let number = id.int, let continuation = pending.removeValue(forKey: number) else { return }
      if !message["error"].isNull {
        continuation.resume(
          throwing: Failure.serverError(
            code: message["error"]["code"].int ?? 0,
            message: message["error"]["message"].string ?? "Request failed"))
      } else {
        continuation.resume(returning: message["result"])
      }
    }

    /// Answers a request from the server.
    private func respond(to id: JSONValue, method: String, params: JSONValue) {
      var result: JSONValue = .null
      switch method {
      case "workspace/configuration":
        result = .array((params["items"].array ?? []).map { _ in .null })
      case "workspace/workspaceFolders":
        result = .null
      case "workspace/applyEdit":
        result = ["applied": false]
      default:
        // window/workDoneProgress/create, client/registerCapability, …
        result = .null
      }
      write(["jsonrpc": "2.0", "id": id, "result": result])
      if method == "window/workDoneProgress/create" || method == "window/showMessageRequest" {
        DispatchQueue.main.async {
          MainActor.assumeIsolated { self.onNotification?(method, params) }
        }
      }
    }

    private func closed() {
      guard !isClosed else { return }
      isClosed = true
      output.fileHandleForReading.readabilityHandler = nil
      errors.fileHandleForReading.readabilityHandler = nil
      let waiting = pending
      pending = [:]
      for continuation in waiting.values { continuation.resume(throwing: Failure.notRunning) }
    }
  }

#endif
