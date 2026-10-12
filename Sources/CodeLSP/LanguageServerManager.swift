#if os(macOS)
  import Foundation
  import Observation

  /// The language servers of one workspace folder: starts the right server
  /// for each opened file (one per server and project root, so a folder of
  /// several projects gets a server for each), keeps documents in sync, and
  /// collects diagnostics.
  @MainActor @Observable public final class LanguageServerManager {
    public enum ServerState: Equatable, Sendable {
      /// The server's command isn't installed.
      case notInstalled
      case starting
      case running
      case failed(String)
    }

    public let workspace: URL
    /// The environment servers run with (the login shell's, for its PATH).
    @ObservationIgnored public var environment: [String: String]
    /// Off: no servers run.
    public var isEnabled = true {
      didSet { if !isEnabled { stopAll() } }
    }
    /// Servers turned off in settings, by ID.
    public var disabledServerIDs: Set<String> = [] {
      didSet {
        for (key, server) in servers where disabledServerIDs.contains(server.configuration.id) {
          servers[key] = nil
          Task { await server.stop() }
        }
      }
    }
    @ObservationIgnored public var configurations = LanguageServerCatalog.all

    /// Diagnostics by file.
    public private(set) var diagnostics: [URL: [LSPDiagnostic]] = [:]
    /// The state of each server ID used in this workspace.
    public private(set) var states: [String: ServerState] = [:]
    /// What a server is busy with ("Indexing"), for the status bar.
    public private(set) var activity: String?

    @ObservationIgnored private var servers: [String: LanguageServer] = [:]
    @ObservationIgnored private var documents: [URL: (server: String, version: Int)] = [:]

    public init(workspace: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
      self.workspace = workspace.standardizedFileURL
      self.environment = environment
    }

    /// The full path of a server's command, or nil when it isn't installed.
    public func executable(for configuration: LanguageServerConfiguration) -> String? {
      Self.which(configuration.command, path: environment["PATH"] ?? "")
    }

    nonisolated static func which(_ command: String, path: String) -> String? {
      for directory in path.split(separator: ":") {
        let candidate = "\(directory)/\(command)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
      }
      return nil
    }

    /// The server configuration for a file, when servers are on and it is
    /// enabled.
    public func configuration(for url: URL) -> LanguageServerConfiguration? {
      guard isEnabled, let configuration = LanguageServerCatalog.configuration(for: url, in: configurations),
        !disabledServerIDs.contains(configuration.id)
      else { return nil }
      return configuration
    }

    /// The server for a file, started on first use; nil when there is none
    /// or it isn't installed.
    func server(for url: URL) -> LanguageServer? {
      guard let configuration = configuration(for: url) else { return nil }
      let root = LanguageServerCatalog.root(for: url, configuration: configuration, workspace: workspace)
      let key = configuration.id + "|" + root.path
      if let server = servers[key] {
        if case .failed = server.status { return nil }
        return server
      }
      guard let executable = executable(for: configuration) else {
        states[configuration.id] = .notInstalled
        return nil
      }
      let server = LanguageServer(
        configuration: configuration, root: root, executable: executable, environment: environment)
      server.onDiagnostics = { [weak self] url, diagnostics in
        self?.diagnostics[url] = diagnostics.isEmpty ? nil : diagnostics
      }
      server.onStatusChange = { [weak self] in self?.updateStates() }
      servers[key] = server
      states[configuration.id] = .starting
      Task { await server.start() }
      return server
    }

    private func updateStates() {
      var states: [String: ServerState] = [:]
      for server in servers.values {
        let state: ServerState
        switch server.status {
        case .starting: state = .starting
        case .running: state = .running
        case .failed(let message): state = .failed(message)
        case .stopped: continue
        }
        // A failure anywhere wins, then starting.
        if case .failed = states[server.configuration.id] { continue }
        if states[server.configuration.id] == .starting, state == .running { continue }
        states[server.configuration.id] = state
      }
      for (id, state) in self.states where state == .notInstalled && states[id] == nil {
        states[id] = .notInstalled
      }
      self.states = states
      activity = servers.values.compactMap { server in
        server.activity.map { "\(server.configuration.name): \($0)" }
      }.sorted().first
    }

    // MARK: - Documents

    public func didOpen(_ url: URL, text: String) {
      let url = url.standardizedFileURL
      guard documents[url] == nil, let server = server(for: url),
        let languageID = server.configuration.languageID(for: url)
      else { return }
      documents[url] = (server.configuration.id + "|" + server.root.path, 1)
      server.open(url, languageID: languageID, version: 1, text: text)
    }

    /// Sends an edit (or the whole text, for servers that take only that).
    public func didChange(_ url: URL, changes: [LSPTextChange], text: () -> String) {
      let url = url.standardizedFileURL
      guard let document = documents[url], let server = servers[document.server] else { return }
      let version = document.version + 1
      documents[url] = (document.server, version)
      server.change(url, version: version, changes: changes, text: text)
    }

    /// Whether the server for this open file takes whole texts.
    public func wantsFullText(_ url: URL) -> Bool {
      guard let document = documents[url.standardizedFileURL], let server = servers[document.server]
      else { return false }
      return server.wantsFullText
    }

    public func isOpen(_ url: URL) -> Bool { documents[url.standardizedFileURL] != nil }

    public func didSave(_ url: URL, text: String) {
      let url = url.standardizedFileURL
      guard let document = documents[url], let server = servers[document.server] else { return }
      server.save(url, text: text)
    }

    public func didClose(_ url: URL) {
      let url = url.standardizedFileURL
      guard let document = documents.removeValue(forKey: url), let server = servers[document.server]
      else { return }
      server.close(url)
    }

    // MARK: - Navigation

    /// Where the symbol at a position is defined (or declared, or its
    /// type, with another method).
    public func locations(
      _ method: String = "textDocument/definition", url: URL, position: LSPPosition
    ) async -> [LSPLocation] {
      let url = url.standardizedFileURL
      guard let document = documents[url], let server = servers[document.server] else { return [] }
      return (try? await server.locations(method, url: url, position: position)) ?? []
    }

    public func hover(url: URL, position: LSPPosition) async -> String? {
      let url = url.standardizedFileURL
      guard let document = documents[url], let server = servers[document.server] else { return nil }
      return try? await server.hover(url: url, position: position)
    }

    // MARK: - Completion

    /// Whether this open file's server completes code.
    public func supportsCompletion(_ url: URL) -> Bool {
      server(ofOpen: url)?.supportsCompletion ?? false
    }

    /// The characters that ask this file's server for completions.
    public func completionTriggerCharacters(_ url: URL) -> Set<String> {
      server(ofOpen: url)?.completionTriggerCharacters ?? []
    }

    /// Completions at a position; nil when the file has no server that
    /// completes code, or the request failed (or was cancelled).
    public func completions(url: URL, position: LSPPosition, trigger: LSPCompletionTrigger) async
      -> LSPCompletionList?
    {
      let url = url.standardizedFileURL
      guard let server = server(ofOpen: url), server.supportsCompletion else { return nil }
      return try? await server.completions(url: url, position: position, trigger: trigger)
    }

    public func resolve(_ item: LSPCompletionItem, url: URL) async -> LSPCompletionItem? {
      guard let server = server(ofOpen: url) else { return nil }
      return try? await server.resolve(item)
    }

    private func server(ofOpen url: URL) -> LanguageServer? {
      guard let document = documents[url.standardizedFileURL] else { return nil }
      return servers[document.server]
    }

    // MARK: - Lifecycle

    /// The last lines a server wrote to standard error, for settings.
    public func log(for id: String) -> String {
      servers.values.filter { $0.configuration.id == id }.map(\.log).joined(separator: "\n")
    }

    /// Stops every server; open documents reopen with the next `didOpen`.
    public func stopAll() {
      let running = servers.values
      servers = [:]
      documents = [:]
      diagnostics = [:]
      states = [:]
      activity = nil
      for server in running { Task { await server.stop() } }
    }

    /// Forgets that a server was missing or failed, so the next file opened
    /// tries it again (after installing it).
    public func retry(_ id: String) {
      states[id] = nil
      for (key, server) in servers where server.configuration.id == id {
        servers[key] = nil
        for (url, document) in documents where document.server == key { documents[url] = nil }
        Task { await server.stop() }
      }
    }
  }
#endif
