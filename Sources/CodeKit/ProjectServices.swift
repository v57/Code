#if os(macOS) || os(Windows) || os(Linux)
  #if os(macOS)
    import AppKit
  #elseif os(Windows)
    import WinSDK
  #endif
  import Foundation
  import CodeActions
  import CodeEditor
  import CodeFormatting
  import CodeLSP
  import CodeWorkspace
  import Observation

  /// Which services run, from the app's settings. Each can be turned off.
  public struct ServiceSettings: Equatable, Sendable {
    /// The toolbar's schemes, Run, Build, Test and Stop.
    public var actionsEnabled = true
    public var languageServersEnabled = true
    public var disabledLanguageServers: Set<String> = []
    public var formatOnSave = true
    public var disabledFormatters: Set<String> = []
    /// "Only with a config file", where changed from a formatter's default.
    public var formatterRequiresConfig: [String: Bool] = [:]
    /// Formatter commands to use instead of the PATH's (a custom build).
    public var formatterCommands: [String: String] = [:]
    public var showsMinimap = true
    /// Issues in the editor: line tints and message banners.
    public var showsInlineIssues = true
    public var showsIssueMessages = true
    public var breakpointsEnabled = true
    /// The completion list opens while typing (else only with Esc and
    /// ⌃Space).
    public var suggestsCompletions = true

    public init() {}
  }

  /// An error, warning or note anywhere in the project, from the last build
  /// or a language server.
  public struct ProjectIssue: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable { case build, languageServer }

    public var url: URL?
    /// From 1.
    public var line: Int?
    public var column: Int?
    public var severity: LineAnnotation.Severity
    public var message: String
    public var source: Source

    public var id: String {
      "\(source.rawValue)|\(url?.path ?? "")|\(line ?? 0)|\(column ?? 0)|\(message)"
    }
  }

  /// What connects the libraries for one project window: its schemes and
  /// actions, language servers, formatters, issues, breakpoints and
  /// navigation between definitions.
  @MainActor @Observable public final class ProjectServices {
    /// Folders never searched for schemes (build output, dependencies).
    static let unscannedFolders: Set<String> = [
      ".git", ".svn", ".hg", ".build", ".swiftpm", "DerivedData", "node_modules", "xcuserdata",
    ]

    public let workspace: Workspace
    public let actions: ActionController
    public let languageServers: LanguageServerManager
    public let installer = ToolInstaller()
    public private(set) var formatting = FormattingService()
    public var settings: ServiceSettings {
      didSet { if settings != oldValue { applySettings(previous: oldValue) } }
    }
    /// The login shell's environment has been read (servers and actions
    /// need its PATH).
    public private(set) var isReady = false
    /// A short message for the status bar (no definition found, a formatter
    /// failed), cleared after a while.
    public private(set) var statusMessage: String?

    /// Breakpoints by file, lines from 0.
    public private(set) var breakpoints: [URL: Set<Int>] = [:]
    /// Deactivated breakpoints are kept but don't stop (Xcode's ⌘Y).
    public var breakpointsActive = true {
      didSet { defaults.set(!breakpointsActive, forKey: key("breakpointsInactive")) }
    }
    /// Where the debugger is stopped, lines from 0.
    public internal(set) var executionLocation: (url: URL, line: Int)?
    /// The debugger session, while one runs.
    public internal(set) var debugger: DebugSession?

    @ObservationIgnored private var shown: [URL: WeakTextView] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var resolvedPaths: [URL: URL] = [:]
    /// Where the editor was, for Go Back and Go Forward: before each jump
    /// and each switch to another file. Observed for the back buttons.
    private var back: [EditorPosition] = []
    private var forward: [EditorPosition] = []
    /// Going back or forward selects a tab without adding to the history.
    @ObservationIgnored private var isNavigatingHistory = false
    /// Writing the compilation database of the selected Xcode scheme, and
    /// the scheme and destination it was last written for.
    @ObservationIgnored var databaseTask: Task<Void, Never>?
    @ObservationIgnored var databaseKey: String?

    public init(workspace: Workspace, settings: ServiceSettings = ServiceSettings()) {
      self.workspace = workspace
      self.settings = settings
      actions = ActionController(root: workspace.root)
      languageServers = LanguageServerManager(workspace: workspace.root)
      actions.excludedNames = Self.unscannedFolders
      breakpointsActive = !defaults.bool(forKey: key("breakpointsInactive"))
      loadBreakpoints()
      applySettings(previous: nil)
      workspace.onCloseDocuments = { [weak self] documents in
        for document in documents { self?.documentClosed(document) }
      }
      workspace.onSelectionChange = { [weak self] previous in
        self?.selectionChanged(from: previous)
      }
      actions.willPerform = { [weak workspace] in workspace?.flushAll() }
      actions.stepsOverride = { [weak self] kind, scheme, destination in
        self?.debugSteps(kind, scheme, destination)
      }
      actions.addFinishHandler { [weak self] kind, _ in
        // A build may follow files added to the project.
        if kind != .clean { self?.updateCompilationDatabase(force: true) }
      }
      observeSchemeSelection()
      Task {
        // Reading the login shell's environment takes a moment; do it once,
        // off the main thread.
        let environment = await Task.detached(priority: .userInitiated) {
          ShellEnvironment.shared.variables
        }.value
        languageServers.environment = environment
        formatting.environment = environment
        isReady = true
        // The database from the last session, until the scheme's is read.
        useCompilationDatabaseIfWritten()
        if settings.actionsEnabled { actions.scan() }
        for (url, box) in shown {
          if let textView = box.textView { languageServers.didOpen(url, text: textView.string) }
        }
      }
    }

    private func key(_ name: String) -> String { "CodeKit.\(name):" + workspace.root.path }

    private func applySettings(previous: ServiceSettings?) {
      languageServers.isEnabled = settings.languageServersEnabled
      languageServers.disabledServerIDs = settings.disabledLanguageServers
      formatting.disabledIDs = settings.disabledFormatters
      formatting.requiresConfig = settings.formatterRequiresConfig
      formatting.customCommands = settings.formatterCommands
      guard let previous, isReady else { return }
      if settings.actionsEnabled && !previous.actionsEnabled { actions.scan() }
      if !settings.actionsEnabled && previous.actionsEnabled { actions.stop() }
      // Servers turned back on: open the shown files again.
      if settings.languageServersEnabled != previous.languageServersEnabled
        || settings.disabledLanguageServers != previous.disabledLanguageServers
      {
        reopenShownDocuments()
      }
    }

    /// Shows `message` in the status bar for a few seconds.
    public func showStatus(_ message: String) {
      statusMessage = message
      statusTask?.cancel()
      statusTask = Task {
        try? await Task.sleep(for: .seconds(5))
        if !Task.isCancelled { statusMessage = nil }
      }
    }

    // MARK: - Documents

    /// An editor started showing a document: its language server opens it.
    func documentShown(_ document: TextDocument, textView: any CodeTextEditing) {
      shown[document.url.standardizedFileURL] = WeakTextView(textView: textView)
      guard isReady else { return }
      languageServers.didOpen(document.url, text: textView.string)
    }

    func documentEdited(_ document: TextDocument, edit: TextEdit, textView: any CodeTextEditing) {
      let url = document.url
      guard languageServers.isOpen(url) else { return }
      let change = LSPTextChange(
        range: LSPRange(
          start: LSPPosition(line: edit.startLine, character: edit.startColumn),
          end: LSPPosition(line: edit.endLine, character: edit.endColumn)),
        text: edit.text)
      languageServers.didChange(url, changes: [change]) { [weak textView] in textView?.string ?? "" }
    }

    func documentSaved(_ document: TextDocument, text: String) {
      languageServers.didSave(document.url, text: text)
    }

    private func documentClosed(_ document: TextDocument) {
      shown[document.url.standardizedFileURL] = nil
      languageServers.didClose(document.url)
    }

    /// Opens the shown files with their servers again (after an install or
    /// a settings change).
    public func reopenShownDocuments() {
      guard isReady else { return }
      for (url, box) in shown {
        guard let textView = box.textView else { continue }
        languageServers.didClose(url)
        languageServers.didOpen(url, text: textView.string)
      }
    }

    // MARK: - Formatting

    /// Formats a document's text in its editor before an explicit save.
    func formatBeforeSave(_ document: TextDocument, textView: any CodeTextEditing) async {
      guard settings.formatOnSave else { return }
      let text = textView.string
      do {
        guard let formatted = try await formatting.format(text, url: document.url),
          formatted != text, textView.string == text
        else { return }
        textView.applyFormattedText(formatted)
      } catch {
        showStatus((error as? LocalizedError)?.errorDescription ?? "\(error)")
      }
    }

    // MARK: - Issues

    /// Issues for the editor of `url`.
    public func annotations(for url: URL) -> [LineAnnotation] {
      guard settings.showsInlineIssues else { return [] }
      let url = url.standardizedFileURL
      var seen = Set<String>()
      var result: [LineAnnotation] = []
      func add(_ annotation: LineAnnotation) {
        // A build and a language server often report the same error.
        if seen.insert("\(annotation.line)|\(annotation.message.lowercased())").inserted {
          result.append(annotation)
        }
      }
      for issue in actions.issues where issue.line != nil && resolve(issue.url) == url {
        add(
          LineAnnotation(
            line: issue.line! - 1, column: issue.column.map { $0 - 1 },
            severity: Self.severity(issue.severity), message: issue.message))
      }
      for diagnostic in languageServers.diagnostics[url] ?? [] {
        guard let severity = Self.severity(diagnostic.severity) else { continue }
        add(
          LineAnnotation(
            line: diagnostic.range.start.line, column: diagnostic.range.start.character,
            severity: severity, message: diagnostic.message))
      }
      return result
    }

    /// Every issue in the project, errors first.
    public var issues: [ProjectIssue] {
      var result: [ProjectIssue] = actions.issues.map { issue in
        ProjectIssue(
          url: resolve(issue.url), line: issue.line, column: issue.column,
          severity: Self.severity(issue.severity), message: issue.message, source: .build)
      }
      for (url, diagnostics) in languageServers.diagnostics {
        for diagnostic in diagnostics {
          guard let severity = Self.severity(diagnostic.severity) else { continue }
          result.append(
            ProjectIssue(
              url: url, line: diagnostic.range.start.line + 1,
              column: diagnostic.range.start.character + 1, severity: severity,
              message: diagnostic.message, source: .languageServer))
        }
      }
      // The same error from the build and the language server counts once.
      var seen = Set<String>()
      result = result.filter {
        seen.insert("\($0.url?.path ?? "")|\($0.line ?? 0)|\($0.message.lowercased())").inserted
      }
      return result.sorted {
        ($0.severity, $0.url?.path ?? "", $0.line ?? 0) < ($1.severity, $1.url?.path ?? "", $1.line ?? 0)
      }
    }

    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
    public var warningCount: Int { issues.filter { $0.severity == .warning }.count }

    static func severity(_ severity: BuildIssue.Severity) -> LineAnnotation.Severity {
      switch severity {
      case .error: return .error
      case .warning: return .warning
      case .note: return .note
      }
    }

    static func severity(_ severity: LSPDiagnostic.Severity) -> LineAnnotation.Severity? {
      switch severity {
      case .error: return .error
      case .warning: return .warning
      case .information: return .note
      case .hint: return nil
      }
    }

    /// A build log's path as a file in the project: tools sometimes print a
    /// bare file name (Swift Testing) or a path relative to another folder.
    func resolve(_ url: URL?) -> URL? {
      guard let url else { return nil }
      if let resolved = resolvedPaths[url] { return resolved }
      var resolved = url.standardizedFileURL
      if !FileManager.default.fileExists(atPath: resolved.path) {
        let name = "/" + url.lastPathComponent
        if let path = workspace.index.paths.first(where: { $0.hasSuffix(name) || $0 == url.lastPathComponent }) {
          resolved = workspace.root.appendingPathComponent(path).standardizedFileURL
        }
      }
      resolvedPaths[url] = resolved
      return resolved
    }

    // MARK: - Breakpoints

    public func breakpoints(for url: URL) -> Set<Int> {
      breakpoints[url.standardizedFileURL] ?? []
    }

    public func setBreakpoints(_ lines: Set<Int>, for url: URL) {
      let url = url.standardizedFileURL
      guard breakpoints[url] ?? [] != lines else { return }
      breakpoints[url] = lines.isEmpty ? nil : lines
      saveBreakpoints()
      debugger?.breakpointsChanged(breakpoints)
    }

    public func removeAllBreakpoints() {
      breakpoints = [:]
      saveBreakpoints()
      debugger?.breakpointsChanged(breakpoints)
    }

    public var hasBreakpoints: Bool { breakpoints.values.contains { !$0.isEmpty } }

    private func loadBreakpoints() {
      guard let stored = defaults.dictionary(forKey: key("breakpoints")) as? [String: [Int]] else { return }
      for (path, lines) in stored {
        breakpoints[workspace.root.appendingPathComponent(path).standardizedFileURL] = Set(lines)
      }
    }

    private func saveBreakpoints() {
      var stored: [String: [Int]] = [:]
      for (url, lines) in breakpoints where !lines.isEmpty {
        stored[workspace.tree.relativePath(of: url)] = lines.sorted()
      }
      defaults.set(stored, forKey: key("breakpoints"))
    }

    // MARK: - Navigation

    /// Jumps to the definition of the symbol at `location` (⌘-click, ⌃⌘J).
    public func jumpToDefinition(in document: TextDocument, at location: Int) {
      guard let textView = document.textView else { return }
      let position = textView.position(of: location)
      guard languageServers.isOpen(document.url) else {
        showStatus(languageServerHint(for: document.url))
        return
      }
      Task {
        let locations = await languageServers.locations(
          url: document.url, position: LSPPosition(line: position.line, character: position.column))
        guard let target = locations.first else {
          beep()
          showStatus("No definition found")
          return
        }
        open(target.url, line: target.range.start.line + 1, column: target.range.start.character + 1)
      }
    }

    /// Why there is no language server for a file, for the status bar.
    func languageServerHint(for url: URL) -> String {
      guard settings.languageServersEnabled else { return "Language servers are off in Settings." }
      guard let configuration = LanguageServerCatalog.configuration(for: url) else {
        return "No language server for this kind of file."
      }
      if settings.disabledLanguageServers.contains(configuration.id) {
        return "\(configuration.name) is off in Settings."
      }
      switch languageServers.states[configuration.id] {
      case .notInstalled?:
        return "\(configuration.name) isn’t installed. Install it in Settings › Languages."
      case .failed(let message)?: return "\(configuration.name) failed: \(message)"
      default: return "\(configuration.name) is starting…"
      }
    }

    /// Quick Help for the symbol at `location` (⌥-click).
    public func showQuickHelp(in document: TextDocument, at location: Int) {
      guard let textView = document.textView else { return }
      let position = textView.position(of: location)
      guard languageServers.isOpen(document.url) else {
        showStatus(languageServerHint(for: document.url))
        return
      }
      Task {
        guard
          let text = await languageServers.hover(
            url: document.url, position: LSPPosition(line: position.line, character: position.column)),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          showStatus("No Quick Help")
          return
        }
        textView.showQuickHelp(text, at: textView.identifierRange(at: location) ?? NSRange(location: location, length: 0))
      }
    }

    /// Opens a file at a line and column (from 1), selecting `length`
    /// characters, and remembers where the editor was for Go Back.
    public func open(_ url: URL, line: Int, column: Int = 1, length: Int = 0, remember: Bool = true) {
      // A jump to another file is remembered when its tab is selected.
      if remember, workspace.selectedDocument?.url == url.standardizedFileURL,
        let current = position(of: workspace.selectedDocument)
      {
        record(current)
      }
      let document = workspace.open(url)
      if document.content == .text, document.textView != nil {
        document.goTo(line: line, column: column, length: length)
      } else {
        document.pendingSelection = (line, column, length)
      }
    }

    /// Where the caret is in `document` (its first line when it has no
    /// text view, such as an image).
    private func position(of document: TextDocument?) -> EditorPosition? {
      guard let document else { return nil }
      guard let textView = document.textView else { return EditorPosition(url: document.url, line: 1, column: 1) }
      let selection = textView.currentSelection
      return EditorPosition(url: document.url, line: selection.line, column: selection.column)
    }

    private func record(_ position: EditorPosition) {
      guard back.last != position else { return }
      back.append(position)
      if back.count > 100 { back.removeFirst() }
      forward = []
    }

    private func selectionChanged(from previous: TextDocument?) {
      guard !isNavigatingHistory, let position = position(of: previous) else { return }
      record(position)
    }

    public var canGoBack: Bool { !back.isEmpty }
    public var canGoForward: Bool { !forward.isEmpty }

    /// Forgets where the editor was, as in a project just opened.
    public func clearHistory() {
      back = []
      forward = []
    }

    /// Back to where the editor was before the last jump or file switch
    /// (⌃⌘←).
    public func goBack() {
      guard let target = back.popLast() else { return beep() }
      if let current = position(of: workspace.selectedDocument) { forward.append(current) }
      go(to: target)
    }

    public func goForward() {
      guard let target = forward.popLast() else { return beep() }
      if let current = position(of: workspace.selectedDocument) { back.append(current) }
      go(to: target)
    }

    private func go(to target: EditorPosition) {
      isNavigatingHistory = true
      defer { isNavigatingHistory = false }
      open(target.url, line: target.line, column: target.column, remember: false)
    }

    /// Opens an issue's file at its line.
    public func open(_ issue: ProjectIssue) {
      guard let url = issue.url else { return }
      open(url, line: issue.line ?? 1, column: issue.column ?? 1)
    }

    // MARK: - Installing tools

    /// Installs a language server, then starts it for the shown files.
    public func install(_ configuration: LanguageServerConfiguration) async {
      guard let command = configuration.install.command else { return }
      let succeeded = await installer.install(
        id: configuration.id, command: command, environment: formatting.environment)
      if succeeded {
        languageServers.retry(configuration.id)
        reopenShownDocuments()
      } else {
        showStatus("Installing \(configuration.name) failed. See Settings › Languages.")
      }
    }

    public func install(_ formatter: FormatterConfiguration) async {
      guard let command = formatter.installCommand else { return }
      let succeeded = await installer.install(
        id: formatter.id, command: command, environment: formatting.environment)
      if !succeeded { showStatus("Installing \(formatter.name) failed.") }
    }

    /// Stops servers and running actions (the window is closing).
    public func shutDown() {
      actions.stop()
      debugger?.stop()
      languageServers.stopAll()
    }
  }

  private struct WeakTextView {
    weak var textView: (any CodeTextEditing)?
  }

  /// The system's alert sound (nothing to go back to, no definition).
  @MainActor func beep() {
    #if os(macOS)
      NSSound.beep()
    #elseif os(Windows)
      MessageBeep(UINT(MB_OK))
    #endif
  }

  /// Runs install commands (brew install …) and keeps their output.
  @MainActor @Observable public final class ToolInstaller {
    /// Installs running now, by tool ID, with their last line of output.
    public private(set) var running: [String: String] = [:]
    /// The output of each tool's last install.
    public private(set) var logs: [String: String] = [:]

    public init() {}

    public func install(id: String, command: String, environment: [String: String]) async -> Bool {
      guard running[id] == nil else { return false }
      running[id] = command
      logs[id] = "$ \(command)\n"
      defer { running[id] = nil }
      do {
        let process = try PTYProcess(
          command: command, directory: FileManager.default.homeDirectoryForCurrentUser,
          environment: environment)
        let status = await process.run { [weak self] line in
          guard !line.isTransient else { return }
          Task { @MainActor in
            self?.logs[id, default: ""] += line.text + "\n"
            if self?.running[id] != nil { self?.running[id] = line.text }
          }
        }
        return status == 0
      } catch {
        logs[id, default: ""] += error.localizedDescription
        return false
      }
    }
  }

  /// A place in a file, from 1, for Go Back and Go Forward.
  struct EditorPosition: Equatable {
    var url: URL
    var line: Int
    var column: Int
  }
#endif
