#if os(macOS)
  import Foundation
  import Observation

  /// The output of the last action, for the console. Lines arrive in
  /// batches; `revision` changes after each batch.
  @MainActor @Observable public final class ActionLog {
    public struct Entry: Sendable {
      public enum Kind: Sendable { case output, command, status, failure }
      public var text: String
      public var kind: Kind
    }

    /// Lines kept; older ones are dropped.
    public nonisolated static let limit = 50_000

    @ObservationIgnored public private(set) var entries: [Entry] = []
    /// Entries dropped from the front since the last `clear()`.
    @ObservationIgnored public private(set) var droppedCount = 0
    public private(set) var revision = 0
    /// Called with each batch of new entries (the console appends them).
    @ObservationIgnored public var onAppend: (([Entry]) -> Void)?
    @ObservationIgnored public var onClear: (() -> Void)?

    public init() {}

    func append(_ batch: [Entry]) {
      guard !batch.isEmpty else { return }
      entries += batch
      if entries.count > Self.limit {
        let extra = entries.count - Self.limit
        entries.removeFirst(extra)
        droppedCount += extra
      }
      revision += 1
      onAppend?(batch)
    }

    public func clear() {
      entries = []
      droppedCount = 0
      revision += 1
      onClear?()
    }

    public var text: String { entries.map(\.text).joined(separator: "\n") }
  }

  /// The toolbar's model for one project folder, like Xcode's: the schemes
  /// found in the folder, the run destinations of the selected scheme, and
  /// the action running now with its progress, log and issues.
  @MainActor @Observable public final class ActionController {
    public enum State: Equatable, Sendable {
      case idle
      case running(ActionKind)
      case succeeded(ActionKind, Date)
      case failed(ActionKind, Date, String)
      case stopped(ActionKind, Date)
    }

    public let root: URL
    public private(set) var schemes: [ActionScheme] = []
    public private(set) var isScanning = false
    public var selectedSchemeID: String? {
      didSet {
        guard selectedSchemeID != oldValue else { return }
        defaults.set(selectedSchemeID, forKey: key("scheme"))
        refreshDestinations()
      }
    }
    public private(set) var destinations: [RunDestination] = []
    public private(set) var isLoadingDestinations = false
    public var selectedDestinationID: String? {
      didSet { defaults.set(selectedDestinationID, forKey: key("destination")) }
    }
    public private(set) var state: State = .idle
    public private(set) var progress: ActionProgress?
    /// The step running now ("Build", "Install", "Run").
    public private(set) var stepTitle: String?
    /// Issues from the last action's log.
    public private(set) var issues: [BuildIssue] = []
    public let log = ActionLog()

    /// Runs before an action starts (the app saves open files).
    @ObservationIgnored public var willPerform: (@MainActor () async -> Void)?
    /// Called when an action finishes, with whether it succeeded.
    @ObservationIgnored public var didFinish: (@MainActor (ActionKind, Bool) -> Void)?
    /// Folder names never searched for projects.
    @ObservationIgnored public var excludedNames: Set<String> = []
    /// Runs the action instead of the planned steps when it returns some
    /// (the debugger replaces Run when there are breakpoints).
    @ObservationIgnored public var stepsOverride:
      (@MainActor (ActionKind, ActionScheme, RunDestination?) -> [ActionStep]?)?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var context: ActionContext?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var destinationsTask: Task<Void, Never>?

    public init(root: URL) {
      self.root = root
      selectedSchemeID = defaults.string(forKey: key("scheme"))
      selectedDestinationID = defaults.string(forKey: key("destination"))
    }

    private func key(_ name: String) -> String { "CodeActions.\(name):" + root.path }

    public var selectedScheme: ActionScheme? {
      schemes.first { $0.id == selectedSchemeID } ?? schemes.first
    }

    public var selectedDestination: RunDestination? {
      // A connected device before starting a virtual one.
      destinations.first { $0.id == selectedDestinationID }
        ?? destinations.first { $0.isAvailable && $0.kind != .androidVirtualDevice }
        ?? destinations.first { $0.isAvailable }
    }

    public var isRunning: Bool {
      if case .running = state { return true }
      return false
    }

    public var runningKind: ActionKind? {
      if case .running(let kind) = state { return kind }
      return nil
    }

    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
    public var warningCount: Int { issues.filter { $0.severity == .warning }.count }

    // MARK: - Schemes and destinations

    /// Finds the folder's schemes again (at open, and when project files
    /// change).
    public func scan() {
      guard !isScanning else { return }
      isScanning = true
      let root = root
      let excluded = excludedNames
      Task {
        // Read the login shell's environment off the main thread first.
        let schemes = await Task.detached(priority: .userInitiated) {
          _ = ShellEnvironment.shared
          return ProjectScanner.scan(root: root, excluded: excluded)
        }.value
        self.schemes = schemes
        self.isScanning = false
        if self.selectedSchemeID == nil || !schemes.contains(where: { $0.id == self.selectedSchemeID }) {
          self.selectedSchemeID = schemes.first?.id
        }
        self.refreshDestinations()
      }
    }

    /// Lists the destinations for the selected scheme's platforms again.
    public func refreshDestinations() {
      let platforms = Set(selectedScheme?.platforms ?? [.mac])
      destinationsTask?.cancel()
      isLoadingDestinations = true
      destinationsTask = Task {
        let destinations = await DestinationProvider.load(platforms: platforms)
        guard !Task.isCancelled else { return }
        self.destinations = destinations
        self.isLoadingDestinations = false
      }
    }

    // MARK: - Running

    public func canPerform(_ kind: ActionKind) -> Bool {
      guard let scheme = selectedScheme else { return false }
      return scheme.supports(kind)
    }

    /// Runs an action on the selected scheme and destination, stopping the
    /// one running now.
    public func perform(_ kind: ActionKind) {
      guard let scheme = selectedScheme else { return }
      let destination = selectedDestination
      let previous = task
      if isRunning { stop() }
      log.clear()
      issues = []
      progress = ActionProgress(message: "Preparing")
      stepTitle = nil
      state = .running(kind)
      let steps =
        stepsOverride?(kind, scheme, destination)
        ?? ActionPlanner.steps(for: kind, scheme: scheme, destination: destination)

      let sink = OutputSink(directory: scheme.directory) { [weak self] batch, events in
        self?.receive(batch, events)
      }
      let context = ActionContext(
        directory: scheme.directory, environment: ShellEnvironment.shared.variables
      ) { line in sink.add(line) }
      self.context = context

      task = Task {
        await previous?.value
        await willPerform?()
        var failure: Error?
        for step in steps {
          if context.isCancelled { break }
          stepTitle = step.title
          progress = step.title == "Run" && kind == .run ? nil : ActionProgress(message: step.title)
          do {
            try await step.work(context)
          } catch {
            failure = error
            break
          }
        }
        sink.flush()
        await Task.yield()
        finish(kind, failure: failure, context: context)
      }
    }

    private func finish(_ kind: ActionKind, failure: Error?, context: ActionContext) {
      // A newer action replaced this one.
      guard self.context === context else { return }
      let cancelled = context.isCancelled
      self.context = nil
      progress = nil
      stepTitle = nil
      let date = Date()
      if cancelled {
        state = .stopped(kind, date)
        appendStatus("Stopped", kind: .status)
        didFinish?(kind, false)
      } else if let failure {
        let message = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
        // The activity view says what failed in few words: the errors, or
        // the exit code when the log had none it could read.
        var summary = message
        if case .failed(let status, _)? = failure as? ActionError {
          summary = errorCount > 0 ? "\(errorCount) error\(errorCount == 1 ? "" : "s")" : "Exit code \(status)"
        }
        state = .failed(kind, date, summary)
        appendStatus(message, kind: .failure)
        didFinish?(kind, false)
      } else if kind != .run && errorCount > 0 {
        state = .failed(kind, date, "\(errorCount) error\(errorCount == 1 ? "" : "s")")
        didFinish?(kind, false)
      } else {
        state = .succeeded(kind, date)
        appendStatus("\(kind.title) \(kind == .run ? "finished" : "succeeded")", kind: .status)
        didFinish?(kind, true)
      }
    }

    private func appendStatus(_ text: String, kind: ActionLog.Entry.Kind) {
      log.append([ActionLog.Entry(text: text, kind: kind)])
    }

    /// Stops the running action (Xcode's ⌘.).
    public func stop() {
      guard isRunning, let context else { return }
      context.cancel()
    }

    private func receive(_ batch: [ActionLog.Entry], _ events: [BuildLogParser.Event]) {
      log.append(batch)
      var known = Set(issues.map(\.id))
      for event in events {
        switch event {
        case .issue(let issue):
          if known.insert(issue.id).inserted { issues.append(issue) }
        case .progress(let progress):
          // A running program's output isn't build progress.
          if isRunning, !(runningKind == .run && stepTitle == "Run") { self.progress = progress }
        }
      }
    }
  }

  /// Collects output from the terminal's queue and hands it to the main
  /// actor in batches, parsed.
  final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: BuildLogParser
    private var entries: [ActionLog.Entry] = []
    private var events: [BuildLogParser.Event] = []
    private var isScheduled = false
    private let deliver: @MainActor ([ActionLog.Entry], [BuildLogParser.Event]) -> Void

    init(
      directory: URL,
      deliver: @escaping @MainActor ([ActionLog.Entry], [BuildLogParser.Event]) -> Void
    ) {
      parser = BuildLogParser(directory: directory)
      self.deliver = deliver
    }

    func add(_ line: PTYProcess.Line) {
      lock.withLock {
        events += parser.consume(line.text)
        if !line.isTransient {
          let kind: ActionLog.Entry.Kind = line.text.hasPrefix("$ ") ? .command : .output
          entries.append(ActionLog.Entry(text: line.text, kind: kind))
        }
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.flush() }
      }
    }

    func flush() {
      let (entries, events) = lock.withLock {
        defer {
          self.entries = []
          self.events = []
          isScheduled = false
        }
        return (self.entries, self.events)
      }
      guard !entries.isEmpty || !events.isEmpty else { return }
      MainActor.assumeIsolated { deliver(entries, events) }
    }
  }
#endif
