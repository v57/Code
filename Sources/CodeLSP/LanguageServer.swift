#if os(macOS)
  import Foundation

  /// A position in a document: line and UTF-16 character offset, from 0.
  public struct LSPPosition: Equatable, Hashable, Sendable {
    public var line: Int
    public var character: Int

    public init(line: Int, character: Int) {
      self.line = line
      self.character = character
    }

    var json: JSONValue { ["line": .number(Double(line)), "character": .number(Double(character))] }

    init?(_ json: JSONValue) {
      guard let line = json["line"].int, let character = json["character"].int else { return nil }
      self.init(line: line, character: character)
    }
  }

  public struct LSPRange: Equatable, Hashable, Sendable {
    public var start: LSPPosition
    public var end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
      self.start = start
      self.end = end
    }

    var json: JSONValue { ["start": start.json, "end": end.json] }

    init?(_ json: JSONValue) {
      guard let start = LSPPosition(json["start"]), let end = LSPPosition(json["end"]) else { return nil }
      self.init(start: start, end: end)
    }
  }

  public struct LSPLocation: Equatable, Hashable, Sendable {
    public var url: URL
    public var range: LSPRange

    public init(url: URL, range: LSPRange) {
      self.url = url
      self.range = range
    }

    /// A `Location` or a `LocationLink`.
    init?(_ json: JSONValue) {
      let uri = json["uri"].string ?? json["targetUri"].string
      let range = LSPRange(json["targetSelectionRange"]) ?? LSPRange(json["range"])
        ?? LSPRange(json["targetRange"])
      guard let uri, let url = URL(string: uri), let range else { return nil }
      self.init(url: url.standardizedFileURL, range: range)
    }
  }

  public struct LSPDiagnostic: Equatable, Hashable, Sendable {
    public enum Severity: Int, Sendable {
      case error = 1, warning, information, hint
    }

    public var range: LSPRange
    public var severity: Severity
    public var message: String
    public var source: String?

    public init(range: LSPRange, severity: Severity, message: String, source: String? = nil) {
      self.range = range
      self.severity = severity
      self.message = message
      self.source = source
    }
  }

  /// An edit to a document: `range` in the text before it (nil replaces
  /// everything).
  public struct LSPTextChange: Equatable, Sendable {
    public var range: LSPRange?
    public var text: String

    public init(range: LSPRange?, text: String) {
      self.range = range
      self.text = text
    }
  }

  /// One running language server for one project root.
  @MainActor public final class LanguageServer {
    public enum Status: Equatable, Sendable {
      case starting
      case running
      case failed(String)
      case stopped
    }

    public let configuration: LanguageServerConfiguration
    public let root: URL
    public private(set) var status: Status = .starting
    /// What the server reports it is doing ("Indexing 40%"), if anything.
    public private(set) var activity: String?
    /// The end of what the server wrote to standard error.
    public private(set) var log = ""

    public var onDiagnostics: ((URL, [LSPDiagnostic]) -> Void)?
    public var onStatusChange: (() -> Void)?

    private let connection: LSPConnection
    /// 1: full text on each change; 2: incremental.
    private var syncKind = 1
    private var capabilities: JSONValue = .null
    private var queued: [() -> Void] = []
    private var progress: [String: String] = [:]

    init(
      configuration: LanguageServerConfiguration, root: URL, executable: String,
      environment: [String: String]
    ) {
      self.configuration = configuration
      self.root = root
      connection = LSPConnection(
        executable: executable, arguments: configuration.arguments, directory: root,
        environment: environment)
      connection.onNotification = { [weak self] method, params in self?.notification(method, params) }
      connection.onExit = { [weak self] status in self?.exited(status) }
      connection.onLog = { [weak self] text in self?.appendLog(text) }
    }

    func start() async {
      do {
        try connection.start()
        let result = try await connection.request("initialize", initializeParams, timeout: 60)
        capabilities = result["capabilities"]
        let sync = capabilities["textDocumentSync"]
        syncKind = sync.int ?? sync["change"].int ?? 1
        connection.notify("initialized", [:])
        setStatus(.running)
        let work = queued
        queued = []
        for item in work { item() }
      } catch {
        setStatus(.failed((error as? LocalizedError)?.errorDescription ?? "\(error)"))
        queued = []
      }
    }

    private var initializeParams: JSONValue {
      let rootURI = JSONValue.string(root.absoluteString)
      return [
        "processId": .number(Double(ProcessInfo.processInfo.processIdentifier)),
        "clientInfo": ["name": "Code"],
        "rootUri": rootURI,
        "rootPath": .string(root.path),
        "workspaceFolders": [["uri": rootURI, "name": .string(root.lastPathComponent)]],
        "initializationOptions": configuration.initializationOptions,
        "capabilities": [
          "general": ["positionEncodings": ["utf-16"]],
          "workspace": ["configuration": true, "workspaceFolders": true],
          "window": ["workDoneProgress": true],
          "textDocument": [
            "synchronization": ["didSave": true, "dynamicRegistration": false],
            "definition": ["linkSupport": true],
            "declaration": ["linkSupport": true],
            "typeDefinition": ["linkSupport": true],
            "implementation": ["linkSupport": true],
            "references": [:],
            "hover": ["contentFormat": ["plaintext", "markdown"]],
            "publishDiagnostics": ["relatedInformation": false, "versionSupport": false],
            "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
          ],
        ],
      ]
    }

    /// Runs `work` now when the server is running, or once it is.
    private func whenRunning(_ work: @escaping () -> Void) {
      switch status {
      case .running: work()
      case .starting: queued.append(work)
      case .failed, .stopped: break
      }
    }

    // MARK: - Documents

    func open(_ url: URL, languageID: String, version: Int, text: String) {
      whenRunning { [connection] in
        connection.notify(
          "textDocument/didOpen",
          [
            "textDocument": [
              "uri": .string(url.absoluteString), "languageId": .string(languageID),
              "version": .number(Double(version)), "text": .string(text),
            ]
          ])
      }
    }

    /// Sends edits, or the whole text when the server takes only that.
    func change(_ url: URL, version: Int, changes: [LSPTextChange], text: () -> String) {
      let contentChanges: [JSONValue]
      if syncKind == 2, !changes.isEmpty {
        contentChanges = changes.map { change in
          var item: [String: JSONValue] = ["text": .string(change.text)]
          if let range = change.range { item["range"] = range.json }
          return .object(item)
        }
      } else {
        contentChanges = [["text": .string(text())]]
      }
      whenRunning { [connection] in
        connection.notify(
          "textDocument/didChange",
          [
            "textDocument": ["uri": .string(url.absoluteString), "version": .number(Double(version))],
            "contentChanges": .array(contentChanges),
          ])
      }
    }

    /// Whether changes must carry the whole text (so the caller can batch).
    var wantsFullText: Bool { syncKind != 2 }

    func save(_ url: URL, text: String) {
      whenRunning { [connection] in
        connection.notify(
          "textDocument/didSave", ["textDocument": ["uri": .string(url.absoluteString)], "text": .string(text)])
      }
    }

    func close(_ url: URL) {
      whenRunning { [connection] in
        connection.notify("textDocument/didClose", ["textDocument": ["uri": .string(url.absoluteString)]])
      }
    }

    // MARK: - Requests

    private func positionParams(_ url: URL, _ position: LSPPosition) -> JSONValue {
      ["textDocument": ["uri": .string(url.absoluteString)], "position": position.json]
    }

    /// Locations from a definition-like request ("textDocument/definition").
    func locations(_ method: String, url: URL, position: LSPPosition) async throws -> [LSPLocation] {
      guard status == .running else { return [] }
      var params = positionParams(url, position)
      if method == "textDocument/references", case .object(var object) = params {
        object["context"] = ["includeDeclaration": true]
        params = .object(object)
      }
      let result = try await connection.request(method, params, timeout: 20)
      if let array = result.array { return array.compactMap(LSPLocation.init) }
      return LSPLocation(result).map { [$0] } ?? []
    }

    /// Hover text (Markdown or plain), if any.
    func hover(url: URL, position: LSPPosition) async throws -> String? {
      guard status == .running else { return nil }
      let result = try await connection.request(
        "textDocument/hover", positionParams(url, position), timeout: 10)
      let contents = result["contents"]
      if let text = contents.string { return text }
      if let value = contents["value"].string { return value }
      if let array = contents.array {
        return array.compactMap { $0.string ?? $0["value"].string }.joined(separator: "\n\n")
      }
      return nil
    }

    func stop() async {
      guard status == .running || status == .starting else { return }
      setStatus(.stopped)
      await connection.stop()
    }

    // MARK: - From the server

    private func notification(_ method: String, _ params: JSONValue) {
      switch method {
      case "textDocument/publishDiagnostics":
        guard let uri = params["uri"].string, let url = URL(string: uri) else { return }
        let diagnostics = (params["diagnostics"].array ?? []).compactMap { item -> LSPDiagnostic? in
          guard let range = LSPRange(item["range"]), let message = item["message"].string else {
            return nil
          }
          return LSPDiagnostic(
            range: range, severity: LSPDiagnostic.Severity(rawValue: item["severity"].int ?? 1) ?? .error,
            message: message, source: item["source"].string)
        }
        onDiagnostics?(url.standardizedFileURL, diagnostics)
      case "$/progress":
        let token = params["token"].string ?? params["token"].int.map(String.init) ?? ""
        let value = params["value"]
        switch value["kind"].string {
        case "begin", "report":
          var text = value["title"].string ?? progress[token] ?? configuration.name
          if value["kind"].string == "report", let title = progress[token]?.split(separator: "—").first {
            text = String(title).trimmingCharacters(in: .whitespaces)
          }
          if let message = value["message"].string, !message.isEmpty { text += " — " + message }
          if let percentage = value["percentage"].int { text += " \(percentage)%" }
          progress[token] = text
        default:
          progress[token] = nil
        }
        let newActivity = progress.values.sorted().first
        if newActivity != activity {
          activity = newActivity
          onStatusChange?()
        }
      default:
        break
      }
    }

    private func exited(_ code: Int32) {
      if status != .stopped {
        let detail = log.split(separator: "\n").last.map(String.init) ?? ""
        setStatus(.failed("Exited with status \(code). \(detail)"))
      }
      activity = nil
      onStatusChange?()
    }

    private func appendLog(_ text: String) {
      log += text
      if log.count > 20_000 { log = String(log.suffix(10_000)) }
    }

    private func setStatus(_ status: Status) {
      guard status != self.status else { return }
      self.status = status
      onStatusChange?()
    }
  }
#endif
