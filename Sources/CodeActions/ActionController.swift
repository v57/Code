  import CodeProgress
  import Foundation
  import Observation
  import SSHKit

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
    /// The scheme the user picked; nil uses the main one (`schemes.first`).
    public var selectedSchemeID: String? {
      didSet {
        guard selectedSchemeID != oldValue else { return }
        defaults.set(selectedSchemeID, forKey: key("pickedScheme"))
        refreshDestinations()
      }
    }
    public private(set) var destinations: [RunDestination] = []
    public private(set) var isLoadingDestinations = false
    /// Other machines the actions can run on over SSH, listed with the destinations (the app gives the devices on
    /// the user's Hub that have this project).
    public var remoteTargets: [SSHExecutor.Target] = [] {
      didSet {
        guard remoteTargets != oldValue else { return }
        destinations = destinations.filter { $0.kind != .remote } + remoteDestinations
      }
    }
    /// How the in-process SSH client signs in to a remote target (this device's key, the host key known for it).
    /// Nil, or a nil result, runs the system's `ssh` client (macOS, Windows); iPhone and iPad need it.
    @ObservationIgnored public var remoteLogin: (@MainActor (SSHExecutor.Target) throws -> SSHServer?)?
    /// Called on the main actor with a remote target's host key after a first in-process login to it, to remember.
    @ObservationIgnored public var didMeetHostKey: (@MainActor (SSHExecutor.Target, String) -> Void)?
    /// The login password of a remote target whose builds unlock the login keychain (`RemoteSigning.loginKeychain`).
    @ObservationIgnored public var remoteLoginPassword: (@MainActor (SSHExecutor.Target) -> String?)?
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
    /// More callbacks for finished actions, for services that follow the
    /// builds (the language servers' compiler arguments).
    @ObservationIgnored private var finishHandlers: [@MainActor (ActionKind, Bool) -> Void] = []
    /// Where actions for this Mac run (`LowPriorityExecutor` for installs in the background).
    @ObservationIgnored public var localExecutor: any ActionExecutor = LocalExecutor()
    /// Asks the user before a step does something they may mind (Install quitting the running app); nil doesn't ask.
    @ObservationIgnored public var confirm: (@MainActor @Sendable (String) async -> Bool)?
    /// Folder names never searched for projects.
    @ObservationIgnored public var excludedNames: Set<String> = []
    /// Runs the action instead of the planned steps when it returns some
    /// (the debugger replaces Run when there are breakpoints).
    @ObservationIgnored public var stepsOverride:
      (@MainActor (ActionKind, ActionScheme, RunDestination?) -> [ActionStep]?)?

    /// Where the steps' durations are kept, for the progress estimate.
    @ObservationIgnored public var progressHistory: ProgressHistory = .standard
    @ObservationIgnored private var tracker: ProgressTracker?
    /// What the log said last, under the tracker's fraction.
    @ObservationIgnored private var progressMessage = ""
    @ObservationIgnored private var progressTimer: Task<Void, Never>?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var context: ActionContext?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var destinationsTask: Task<Void, Never>?

    public init(root: URL) {
      self.root = root
      // "scheme" also saved automatic picks (a package's test scheme).
      defaults.removeObject(forKey: key("scheme"))
      selectedSchemeID = defaults.string(forKey: key("pickedScheme"))
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
        if let id = self.selectedSchemeID, !schemes.contains(where: { $0.id == id }) {
          self.selectedSchemeID = nil
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
        #if os(iOS)
          // Nothing builds or runs here: only other machines.
          let destinations: [RunDestination] = []
          _ = platforms
        #else
          let destinations = await DestinationProvider.load(platforms: platforms)
        #endif
        guard !Task.isCancelled else { return }
        self.destinations = destinations + self.remoteDestinations
        self.isLoadingDestinations = false
      }
    }

    /// The remote targets as destinations, for schemes that build for the Mac (or any computer).
    private var remoteDestinations: [RunDestination] {
      guard selectedScheme?.platforms.contains(.mac) ?? true else { return [] }
      return remoteTargets.map {
        RunDestination(id: Self.remotePrefix + $0.id, name: $0.name, kind: .remote, detail: $0.detail)
      }
    }

    private static let remotePrefix = "ssh:"

    /// The remote target a destination stands for.
    public func remoteTarget(for destination: RunDestination?) -> SSHExecutor.Target? {
      guard let destination, destination.kind == .remote else { return nil }
      return remoteTargets.first { Self.remotePrefix + $0.id == destination.id }
    }

    /// Where the destination's commands run: over SSH for another machine, else here.
    private func executor(for destination: RunDestination?) -> any ActionExecutor {
      guard let target = remoteTarget(for: destination) else { return localExecutor }
      let login: SSHServer?
      do {
        login = try remoteLogin?(target)
      } catch {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return UnavailableExecutor(reason: "couldn't sign in to \(target.name): \(reason)")
      }
      let didMeetHostKey = didMeetHostKey
      var secrets: [String: String] = [:]
      if target.signing == .loginKeychain, let password = remoteLoginPassword?(target) {
        secrets[RemoteSigning.passwordVariable] = password
      }
      return SSHExecutor(target: target, localRoot: root, login: login, secrets: secrets) { fingerprint in
        Task { @MainActor in didMeetHostKey?(target, fingerprint) }
      }
    }

    // MARK: - Running

    public func canPerform(_ kind: ActionKind) -> Bool {
      guard let scheme = selectedScheme else { return false }
      return scheme.supports(kind)
    }

    /// Runs an action on the selected scheme and destination, stopping the
    /// one running now. `environment` adds variables for its commands
    /// (Export's `NOTARY_PROFILE`).
    public func perform(_ kind: ActionKind, environment: [String: String] = [:]) {
      guard let scheme = selectedScheme else { return }
      perform(kind, scheme: scheme, destination: selectedDestination, environment: environment)
    }

    /// Runs an action on `scheme` and `destination` rather than the selected ones (an app's queued installs).
    public func perform(
      _ kind: ActionKind, scheme: ActionScheme, destination: RunDestination?, environment: [String: String] = [:]
    ) {
      let previous = task
      if isRunning { stop() }
      log.clear()
      issues = []
      progress = ActionProgress(message: "Preparing")
      stepTitle = nil
      state = .running(kind)
      // The debugger (the override) runs here, never on another machine.
      let steps =
        (destination?.kind == .remote ? nil : stepsOverride?(kind, scheme, destination))
        ?? ActionPlanner.steps(
          for: kind, scheme: scheme, destination: destination, signing: remoteTarget(for: destination)?.signing)

      // Steps are stages, named so that Run's build and Build's share their
      // history. Run's last step runs the app, which has no end to estimate.
      let place = "\(scheme.id)|\(destination?.id ?? "")"
      let stages = steps.map {
        ProgressStage(
          id: "\(place)|\($0.title.lowercased())", title: $0.title, resource: $0.resource, timing: $0.timing)
      }
      var planned = kind == .run ? stages.filter { $0.title != "Run" } : stages
      // Tests run after the build in the same command (see `receive`).
      if kind == .test { planned = planned.flatMap { [$0, Self.testsStage(after: $0)] } }
      let operation = "\(place)|\(kind.rawValue)"
      let tracker = ProgressTracker(
        operation: operation, stages: progressHistory.plan(for: operation) ?? planned,
        history: progressHistory)
      self.tracker = tracker
      progressMessage = "Preparing"
      startProgressTimer()

      let sink = OutputSink(directory: scheme.directory) { [weak self] batch, events in
        self?.receive(batch, events)
      }
      let context = ActionContext(
        directory: scheme.directory,
        environment: ShellEnvironment.shared.variables.merging(environment) { $1 },
        executor: executor(for: destination),
        confirm: confirm.map { confirm in { @Sendable question in await confirm(question) } }
      ) { line in sink.add(line) }
      self.context = context

      task = Task {
        await previous?.value
        await willPerform?()
        var failure: Error?
        for (step, stage) in zip(steps, stages) {
          if context.isCancelled { break }
          sink.flush()
          stepTitle = step.title
          if step.title == "Run" && kind == .run {
            // The build is done; the app runs as long as it likes.
            tracker.complete()
            progress = nil
          } else {
            tracker.begin(stage)
            progressMessage = step.title
            updateProgress()
          }
          do {
            try await step.work(context)
          } catch {
            failure = error
            break
          }
        }
        sink.flush()
        await Task.yield()
        if failure == nil && !context.isCancelled { tracker.complete() } else { tracker.cancel() }
        finish(kind, failure: failure, context: context)
      }
    }

    private func finish(_ kind: ActionKind, failure: Error?, context: ActionContext) {
      // A newer action replaced this one.
      guard self.context === context else { return }
      let cancelled = context.isCancelled
      self.context = nil
      tracker = nil
      progressTimer?.cancel()
      progressTimer = nil
      progress = nil
      stepTitle = nil
      let date = Date()
      if cancelled {
        state = .stopped(kind, date)
        appendStatus("Stopped", kind: .status)
        finished(kind, succeeded: false)
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
        finished(kind, succeeded: false)
      } else if kind != .run && errorCount > 0 {
        state = .failed(kind, date, "\(errorCount) error\(errorCount == 1 ? "" : "s")")
        finished(kind, succeeded: false)
      } else {
        state = .succeeded(kind, date)
        appendStatus("\(kind.title) \(kind == .run ? "finished" : "succeeded")", kind: .status)
        finished(kind, succeeded: true)
      }
    }

    /// Adds a callback for finished actions, called after `didFinish`.
    public func addFinishHandler(_ handler: @escaping @MainActor (ActionKind, Bool) -> Void) {
      finishHandlers.append(handler)
    }

    private func finished(_ kind: ActionKind, succeeded: Bool) {
      didFinish?(kind, succeeded)
      for handler in finishHandlers { handler(kind, succeeded) }
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
      // A running program's output isn't build progress.
      let measured = isRunning && !(runningKind == .run && stepTitle == "Run")
      for event in events {
        switch event {
        case .issue(let issue):
          if known.insert(issue.id).inserted { issues.append(issue) }
        case .progress(let progress) where measured:
          if !progress.message.isEmpty { progressMessage = progress.message }
          if let fraction = progress.fraction { tracker?.report(fraction: fraction) }
        case .count(let done, let total) where measured:
          tracker?.update(units: Double(done), of: Double(total))
        case .unit(let unit) where measured:
          guard let tracker else { break }
          // Tests follow the build in the same command: a stage of their own.
          if unit == .test, let stage = tracker.snapshot().stage, !stage.id.hasSuffix("|tests") {
            tracker.begin(Self.testsStage(after: stage))
          }
          tracker.advance()
        default: break
        }
      }
      if measured { updateProgress() }
    }

    /// The tests a test command runs once it has built them.
    static func testsStage(after build: ProgressStage) -> ProgressStage {
      ProgressStage(id: build.id + "|tests", title: "Tests", resource: .cpu, timing: .static)
    }

    /// The tracker's estimate under the log's last message.
    private func updateProgress() {
      guard let tracker, isRunning, !(runningKind == .run && stepTitle == "Run") else { return }
      let snapshot = tracker.snapshot()
      let next = ActionProgress(
        fraction: snapshot.fraction, message: progressMessage, remaining: snapshot.remaining)
      if next != progress { progress = next }
    }

    /// Moves the estimate with time between log lines.
    private func startProgressTimer() {
      progressTimer?.cancel()
      progressTimer = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(250))
          self?.updateProgress()
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

    func add(_ line: ActionLine) {
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
