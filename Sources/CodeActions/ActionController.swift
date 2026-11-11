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
  /// the actions run (`runs`, several at once), each with its progress, log and issues.
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
    /// The workspaces, projects and packages found under the root (`ProjectContainer`), the root's first.
    public private(set) var containers: [ProjectContainer] = []
    /// The container picked in each folder that has several, by folder path, remembered per project.
    public private(set) var pickedContainers: [String: String] = [:]
    /// Called after `selectContainer`, once the choice is saved (the dependency list follows the root's).
    @ObservationIgnored public var didSelectContainer: (@MainActor (ProjectContainer) -> Void)?
    /// A scan is running that doesn't know the last pick: another follows it.
    @ObservationIgnored private var needsRescan = false
    /// The scheme the user picked; nil uses the main one (`schemes.first`).
    public var selectedSchemeID: String? {
      didSet {
        guard selectedSchemeID != oldValue else { return }
        defaults.set(selectedSchemeID, forKey: sourceKey("pickedScheme"))
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
    /// How the in-process SSH client signs in to a remote target (this device's key, what to do about its host key).
    /// Nil, or a nil result, runs the system's `ssh` client (macOS, Windows); iPhone and iPad need it.
    @ObservationIgnored public var remoteLogin: (@MainActor (SSHExecutor.Target) throws -> SSHServer?)?
    /// The login password of a remote target whose builds unlock the login keychain (`RemoteSigning.loginKeychain`).
    @ObservationIgnored public var remoteLoginPassword: (@MainActor (SSHExecutor.Target) -> String?)?
    public var selectedDestinationID: String? {
      didSet { defaults.set(selectedDestinationID, forKey: sourceKey("destination")) }
    }

    // MARK: Build From

    /// The other machines to offer under Build From (the app gives the user's devices that have this project, and with
    /// a `directory` of "" those where it may be found). Listing them contacts nothing.
    public var machineTargets: [SSHExecutor.Target] = [] {
      didSet {
        didReceiveMachines = true
        guard machineTargets != oldValue else { return }
        adoptSavedRemoteDestination()
        rememberSelectedBuildSource()
        if !selectedBuildSource.isLocal { refreshDestinations() }
      }
    }
    /// The container runtimes found here (`refreshBuildSources`).
    public private(set) var containerRuntimes: [ContainerRuntime] = []
    /// What each source was last seen doing, by id; unknown until something asked.
    public private(set) var buildSourceStatuses: [String: BuildSourceStatus] = [:]
    public private(set) var selectedBuildSourceID = BuildSource.local.id
    /// The folders found or given per machine, by target id, remembered per project. One given wins over the vault's.
    @ObservationIgnored private var foundFolders: [String: String] = [:]
    /// The source picked, as last seen, so a choice that went away still shows.
    @ObservationIgnored private var savedBuildSource: BuildSource?
    @ObservationIgnored private(set) var didReceiveMachines = false
    @ObservationIgnored private(set) var didDetectRuntimes = false
    /// The runtime being started: finding runtimes meanwhile doesn't call it stopped.
    @ObservationIgnored private var startingRuntime: String?
    @ObservationIgnored private var detectTask: Task<Void, Never>?
    /// The actions run, newest last: every one still going (several run at once) and the last ones finished
    /// (`keptRuns` in all).
    public private(set) var runs: [ActionRun] = []
    /// Output that belongs to no run (starting a container runtime).
    public let notes = ActionLog()
    /// Tests each test operation ran the last time, for "31 / 48 tests".
    @ObservationIgnored private var testCounts: [String: Int] = [:]

    /// The newest run: the one `state`, `progress`, `stepTitle`, `issues` and `log` tell of.
    public var current: ActionRun? { runs.last }

    public var state: State {
      guard let run = current else { return .idle }
      let date = run.finished ?? run.started
      switch run.phase {
      case .waiting, .running: return .running(run.kind)
      case .succeeded: return .succeeded(run.kind, date)
      case .failed(let message): return .failed(run.kind, date, message)
      case .stopped: return .stopped(run.kind, date)
      }
    }

    public var progress: ActionProgress? { current?.progress }
    /// The step the newest run is on ("Build", "Install", "Run").
    public var stepTitle: String? { current?.stepTitle }
    /// Issues from the newest run's log.
    public var issues: [BuildIssue] { current?.issues ?? [] }
    /// The newest run's output, else the notes.
    public var log: ActionLog { current?.log ?? notes }
    /// The scheme, destination and tag (a preset's id) of the newest run still going, else of the newest run:
    /// a preset's, not the toolbar's, when one ran.
    public var runningScheme: ActionScheme? { newestRun?.scheme }
    public var runningDestination: RunDestination? { newestRun?.destination }
    public var runningTag: String? { newestRun?.tag }
    private var newestRun: ActionRun? { runs.last(where: \.isWorking) ?? runs.last }
    /// Whether a run started with `tag` (a preset's id) is still going.
    public func isRunning(tag: String) -> Bool { runs.contains { $0.isWorking && $0.tag == tag } }
    /// The newest run started with `tag` still going.
    public func run(tag: String) -> ActionRun? { runs.last { $0.isWorking && $0.tag == tag } }
    /// Every destination of the platforms the presets need, to tell which can run now (`refreshPresetDestinations`).
    public internal(set) var presetDestinations: [RunDestination] = []
    public internal(set) var hasPresetDestinations = false
    @ObservationIgnored var presetDestinationsTask: Task<Void, Never>?

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
    @ObservationIgnored let defaults = UserDefaults.standard
    @ObservationIgnored private var destinationsTask: Task<Void, Never>?

    public init(root: URL) {
      self.root = root
      // "scheme" also saved automatic picks (a package's test scheme).
      defaults.removeObject(forKey: key("scheme"))
      selectedBuildSourceID = defaults.string(forKey: key("buildSource")) ?? BuildSource.local.id
      savedBuildSource = defaults.data(forKey: key("buildSourceInfo"))
        .flatMap { try? JSONDecoder().decode(BuildSource.self, from: $0) }
      foundFolders = defaults.dictionary(forKey: key("buildFolders")) as? [String: String] ?? [:]
      selectedSchemeID = defaults.string(forKey: sourceKey("pickedScheme"))
      pickedContainers = defaults.dictionary(forKey: sourceKey("containers")) as? [String: String] ?? [:]
      selectedDestinationID = defaults.string(forKey: sourceKey("destination"))
      testCounts = defaults.dictionary(forKey: key("testCounts")) as? [String: Int] ?? [:]
    }

    func key(_ name: String) -> String { "CodeActions.\(name):" + root.path }

    /// A key for what each build source remembers on its own: this computer's are the keys it always had.
    private func sourceKey(_ name: String) -> String {
      selectedBuildSourceID == BuildSource.local.id ? key(name) : key("\(name)|\(selectedBuildSourceID)")
    }

    public var selectedScheme: ActionScheme? {
      schemes.first { $0.id == selectedSchemeID } ?? schemes.first
    }

    /// The container the selected scheme comes from: its folder's pick, else that folder's first; the root's without
    /// a scheme.
    public var selectedContainer: ProjectContainer? {
      let folder = selectedScheme?.directory ?? root
      return ProjectContainer.effective(picked: pickedContainers[folder.path], in: containers(in: folder))
        ?? containers.first
    }

    /// The containers of one folder, the default first.
    public func containers(in folder: URL) -> [ProjectContainer] {
      containers.filter { $0.directory.path == folder.path }
    }

    /// The container picked in `folder`, nil while it uses the default.
    public func pickedContainer(in folder: URL) -> String? {
      pickedContainers[folder.path]
    }

    /// Uses `container` for its folder from now on: its schemes replace the folder's. (`Build From` in the toolbar.)
    public func selectContainer(_ container: ProjectContainer) {
      guard pickedContainers[container.directory.path] != container.fileName else { return }
      pickedContainers[container.directory.path] = container.fileName
      defaults.set(pickedContainers, forKey: sourceKey("containers"))
      didSelectContainer?(container)
      scan()
    }

    public var selectedDestination: RunDestination? {
      // A connected device before starting a virtual one.
      destinations.first { $0.id == selectedDestinationID }
        ?? destinations.first { $0.isAvailable && $0.kind != .androidVirtualDevice }
        ?? destinations.first { $0.isAvailable }
    }

    /// Some run is going (or waiting to).
    public var isRunning: Bool { runs.contains { $0.isWorking } }

    /// The newest run's action while it's going.
    public var runningKind: ActionKind? {
      guard let run = current, run.isWorking else { return nil }
      return run.kind
    }

    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
    public var warningCount: Int { issues.filter { $0.severity == .warning }.count }

    // MARK: - Schemes and destinations

    /// Finds the folder's schemes again (at open, and when project files
    /// change).
    public func scan() {
      guard !isScanning else {
        needsRescan = true
        return
      }
      isScanning = true
      let root = root
      let excluded = excludedNames
      let picks = pickedContainers
      let capabilities = selectedBuildCapabilities
      // The copy of the project on the machine it's built from, when there is one; else this folder's schemes.
      let mirror = selectedBuildSource.machine == nil ? nil : mirrorFolder(of: selectedBuildSourceID)
      Task {
        let found = await Self.findSchemes(
          root: root, excluded: excluded, picks: picks, capabilities: capabilities, mirror: mirror)
        let schemes = found.schemes.filter { capabilities.canBuild($0) }
        self.schemes = schemes
        self.containers = found.containers
        self.isScanning = false
        if self.needsRescan {
          self.needsRescan = false
          self.scan()
          return
        }
        if let id = self.selectedSchemeID, !schemes.contains(where: { $0.id == id }) {
          self.selectedSchemeID = nil
        }
        self.refreshDestinations()
      }
    }

    /// The schemes and containers of the project, or of its copy from a machine (`mirror`), with `picks` as the
    /// containers picked per folder and what `capabilities` can use; off the main thread.
    nonisolated static func findSchemes(
      root: URL, excluded: Set<String>, picks: [String: String], capabilities: BuildCapabilities, mirror: URL?
    ) async -> ProjectScanner.Scan {
      // Read the login shell's environment off the main thread first.
      await Task.detached(priority: .userInitiated) {
        _ = ShellEnvironment.shared
        guard let mirror, FileManager.default.fileExists(atPath: mirror.path) else {
          return ProjectScanner.scanProjects(
            root: root, excluded: excluded, picks: picks, allowing: { capabilities.canUse($0) })
        }
        let there = Dictionary(uniqueKeysWithValues: picks.map { (Self.rebased($0.key, from: root.path, to: mirror.path), $0.value) })
        var scan = ProjectScanner.scanProjects(
          root: mirror, excluded: excluded, picks: there, allowing: { capabilities.canUse($0) }, isMirror: true)
        // The schemes stand for the project's own folders, which `SSHExecutor` maps to the ones there.
        scan.schemes = scan.schemes.map { scheme in
          var scheme = scheme
          scheme.directory = URL(fileURLWithPath: Self.rebased(scheme.directory.path, from: mirror.path, to: root.path), isDirectory: true)
          return scheme
        }
        scan.containers = scan.containers.map { container in
          var container = container
          container.directory = URL(fileURLWithPath: Self.rebased(container.directory.path, from: mirror.path, to: root.path), isDirectory: true)
          return container
        }
        return scan
      }.value
    }

    /// Lists the destinations for the selected scheme's platforms again.
    public func refreshDestinations() {
      // Built elsewhere, it runs there.
      let source = selectedBuildSource
      if !source.isLocal {
        destinationsTask?.cancel()
        isLoadingDestinations = false
        destinations = source.destination(image: selectedScheme.flatMap { ContainerImages.image(for: $0, root: root) })
          .map { [$0] } ?? []
        return
      }
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
    var remoteDestinations: [RunDestination] {
      guard selectedScheme?.platforms.contains(.mac) ?? true else { return [] }
      return remoteTargets.map {
        RunDestination(id: Self.remotePrefix + $0.id, name: $0.name, kind: .remote, detail: $0.detail)
      }
    }

    static let remotePrefix = "ssh:"

    /// The remote target a destination stands for.
    public func remoteTarget(for destination: RunDestination?) -> SSHExecutor.Target? {
      guard let destination, destination.kind == .remote else { return nil }
      if let machine = selectedBuildSource.machine, selectedBuildSource.id == destination.id { return machine }
      return remoteTargets.first { Self.remotePrefix + $0.id == destination.id }
    }

    /// Where the commands run: in the source's container, on its machine or the destination's over SSH, else here.
    private func executor(for destination: RunDestination?, scheme: ActionScheme, source: BuildSource) -> any ActionExecutor {
      if let runtime = source.container {
        guard let image = ContainerImages.image(for: scheme, root: root) else {
          return UnavailableExecutor(
            reason: "There’s no standard image for \(scheme.toolchain.displayName): add one to .devcontainer/devcontainer.json.")
        }
        return ContainerExecutor(runtime: runtime, image: image, toolchain: scheme.toolchain, localRoot: root)
      }
      if source.needsFinding {
        return UnavailableExecutor(reason: "\(root.lastPathComponent) wasn’t found on \(source.name).")
      }
      guard let target = source.machine ?? remoteTarget(for: destination) else { return localExecutor }
      return machineExecutor(target)
    }

    /// Commands on another machine, signed in as the app says.
    private func machineExecutor(_ target: SSHExecutor.Target) -> any ActionExecutor {
      let login: SSHServer?
      do {
        login = try remoteLogin?(target)
      } catch {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return UnavailableExecutor(reason: "couldn't sign in to \(target.name): \(reason)")
      }
      var secrets: [String: String] = [:]
      if target.signing == .loginKeychain, let password = remoteLoginPassword?(target) {
        secrets[RemoteSigning.passwordVariable] = password
      }
      let system = capabilities(of: BuildSource(place: .machine(target))).system
      return SSHExecutor(target: target, localRoot: root, login: login, secrets: secrets, system: system)
    }

    // MARK: - Build From

    /// This computer, then the other machines and the containers found here.
    public var buildSources: [BuildSource] {
      [.local]
        + machineTargets.map { target in
          var target = target
          if let folder = foundFolders[target.id] { target.directory = folder }
          return BuildSource(place: .machine(target))
        }
        + containerRuntimes.map { BuildSource(place: .container($0)) }
    }

    /// Whether there's anything to choose: without another place, Build From isn't shown.
    public var hasOtherBuildSources: Bool {
      buildSources.count > 1 || selectedBuildSourceID != BuildSource.local.id
    }

    /// The source picked, also when it went away: the choice stays until the user changes it.
    public var selectedBuildSource: BuildSource {
      buildSources.first { $0.id == selectedBuildSourceID } ?? savedBuildSource ?? .local
    }

    /// Why the source picked can't be used now, or that nothing is known yet.
    public var selectedBuildSourceStatus: BuildSourceStatus {
      let source = selectedBuildSource
      guard !source.isLocal else { return .ready }
      let isKnown = source.machine != nil ? didReceiveMachines : didDetectRuntimes
      if isKnown, !buildSources.contains(where: { $0.id == source.id }) {
        return .unavailable(
          source.machine != nil
            ? "\(source.name) isn’t one of your machines any more." : "\(source.name) isn’t on this computer any more.")
      }
      return buildSourceStatuses[source.id] ?? .unknown
    }

    /// What the source picked can build, as far as is known.
    public var selectedBuildCapabilities: BuildCapabilities {
      capabilities(of: selectedBuildSource)
    }

    func capabilities(of source: BuildSource) -> BuildCapabilities {
      switch source.place {
      case .local: return .local
      case .container: return .container
      case .machine:
        return defaults.data(forKey: key("buildCapabilities|\(source.id)"))
          .flatMap { try? JSONDecoder().decode(BuildCapabilities.self, from: $0) } ?? BuildCapabilities()
      }
    }

    /// Builds from `source` from now on: its schemes and destinations replace the others, with what was last picked
    /// for it. The click is what lets Code contact a machine.
    public func selectBuildSource(_ source: BuildSource) {
      guard source.id != selectedBuildSourceID else {
        checkSelectedBuildSource()
        return
      }
      selectedBuildSourceID = source.id
      defaults.set(source.id, forKey: key("buildSource"))
      savedBuildSource = source
      defaults.set(try? JSONEncoder().encode(source), forKey: key("buildSourceInfo"))
      pickedContainers = defaults.dictionary(forKey: sourceKey("containers")) as? [String: String] ?? [:]
      selectedSchemeID = defaults.string(forKey: sourceKey("pickedScheme"))
      selectedDestinationID = defaults.string(forKey: sourceKey("destination"))
      // What it can't build goes at once; the scan brings the rest.
      let capabilities = capabilities(of: source)
      schemes = schemes.filter { capabilities.canBuild($0) }
      refreshDestinations()
      scan()
      checkSelectedBuildSource()
    }

    /// Says where the project is on a machine it wasn't found on.
    public func setBuildFolder(_ folder: String, for source: BuildSource) {
      guard let target = source.machine else { return }
      foundFolders[target.id] = folder
      defaults.set(foundFolders, forKey: key("buildFolders"))
      rememberSelectedBuildSource()
      if source.id == selectedBuildSourceID {
        refreshDestinations()
        checkSelectedBuildSource()
      }
    }

    /// Finds the container runtimes again: at open and when the menu opens. Starts nothing, and contacts no machine.
    public func refreshBuildSources() {
      detectTask?.cancel()
      detectTask = Task {
        let runtimes = await Task.detached(priority: .utility) { ContainerRuntimes.detect() }.value
        guard !Task.isCancelled else { return }
        containerRuntimes = runtimes
        didDetectRuntimes = true
        for runtime in runtimes where runtime.id != startingRuntime {
          buildSourceStatuses["container:" + runtime.id] =
            runtime.isRunning ? .ready : .unavailable("\(runtime.displayName) isn’t running.")
        }
        rememberSelectedBuildSource()
        if selectedBuildSource.container != nil { refreshDestinations() }
      }
    }

    /// Asks the source picked whether it can be used: a machine, for its tools, the project's folder and files. Only
    /// from a click (picking it, Refresh), never on its own.
    public func checkSelectedBuildSource() {
      let source = selectedBuildSource
      if source.container != nil { refreshBuildSources() }
      if let target = source.machine { checkMachine(target, source: source) }
    }

    /// Starts a stopped runtime, at the user's click, showing its output in the log.
    public func startRuntime(_ runtime: ContainerRuntime) {
      guard let command = runtime.startCommand, startingRuntime == nil else { return }
      startingRuntime = runtime.id
      let id = "container:" + runtime.id
      buildSourceStatuses[id] = .checking
      notes.clear()
      appendStatus("Starting \(runtime.displayName)", kind: .status, to: notes)
      let sink = OutputSink(directory: root) { [weak self] batch, _ in self?.notes.append(batch) }
      let executor = localExecutor
      Task {
        var failure: String?
        do {
          let process = try executor.start(
            command, directory: URL(fileURLWithPath: NSHomeDirectory()), environment: ShellEnvironment.shared.variables)
          let status = await process.run { sink.add($0) }
          sink.flush()
          if status != 0 { failure = "\(runtime.displayName) didn’t start (exit code \(status))." }
        } catch {
          failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        // Docker Desktop's command returns before its engine is up.
        for _ in 0..<60 where failure == nil && !ContainerRuntimes.isOpen(runtime.endpoint) {
          try? await Task.sleep(for: .seconds(2))
        }
        startingRuntime = nil
        if let failure {
          buildSourceStatuses[id] = .unavailable(failure)
          appendStatus(failure, kind: .failure, to: notes)
        }
        refreshBuildSources()
      }
    }

    /// Runs the probe on a machine (`MachineProbe`), finds the project there when its folder isn't known, and copies
    /// its manifests when the in-process client can (`ProjectMirror`), so the schemes are the machine's own.
    private func checkMachine(_ target: SSHExecutor.Target, source: BuildSource) {
      let id = source.id
      buildSourceStatuses[id] = .checking
      let root = root
      Task {
        do {
          let login = try remoteLogin?(target)
          var probing = target
          if probing.directory.isEmpty { probing.directory = "/" }
          var executor = SSHExecutor(target: probing, localRoot: root, login: login)
          let find = target.directory.isEmpty ? await Self.search(for: root) : nil
          // POSIX first, then PowerShell for a machine that signed in but has no `sh` (Windows: cmd or PowerShell as
          // sshd's shell); a machine known to be Windows the other way round.
          var systems: [String?] = [nil, BuildCapabilities.windows]
          if capabilities(of: source).system == BuildCapabilities.windows { systems.reverse() }
          var answer: MachineProbe.Answer?
          var failure: (reason: String, connected: Bool)?
          for system in systems where failure?.connected ?? true {
            executor.system = system
            let script = system == nil ? MachineProbe.script(find: find) : MachineProbe.windowsScript(find: find)
            do {
              answer = try await Self.ask(executor, script: script, name: target.name, root: root)
              break
            } catch ProbeError.unanswered(let reason, let connected) {
              if failure == nil || !connected { failure = (reason, connected) }
            }
          }
          guard let answer else {
            throw ActionError.missing("Couldn’t reach \(target.name): \(failure?.reason ?? "no answer")")
          }
          defaults.set(
            try? JSONEncoder().encode(answer.capabilities), forKey: key("buildCapabilities|\(id)"))
          var folder = target.directory
          if folder.isEmpty {
            guard let found = answer.folder else {
              throw ActionError.missing("\(root.lastPathComponent) wasn’t found on \(target.name).")
            }
            folder = found
            foundFolders[target.id] = found
            defaults.set(foundFolders, forKey: key("buildFolders"))
            rememberSelectedBuildSource()
          }
          if let login {
            // Without SFTP there, the schemes stay this folder's.
            let server = executor.server(from: login)
            if let client = try? await SFTPClient.connect(server: server, timeout: 15) {
              try? await ProjectMirror.fetch(folder, into: mirrorFolder(of: id), client: client)
              client.close()
            }
          }
          buildSourceStatuses[id] = .ready
        } catch {
          buildSourceStatuses[id] = .unavailable((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        if selectedBuildSourceID == id {
          refreshDestinations()
          scan()
        }
      }
    }

    /// What to look for on a machine: the folder's name, where it is under the home folder here, its Git origin.
    private static func search(for root: URL) async -> (name: String, relativePath: String?, origin: String?) {
      let home = NSHomeDirectory() + "/"
      let origin = await Task.detached(priority: .utility) { () -> String? in
        #if os(iOS)
          return nil
        #else
          guard let git = ShellEnvironment.shared.which("git") else { return nil }
          return SubprocessCapture.run(git, ["-C", root.path, "remote", "get-url", "origin"], timeout: 5)
        #endif
      }.value
      return (
        root.lastPathComponent, root.path.hasPrefix(home) ? String(root.path.dropFirst(home.count)) : nil,
        origin.flatMap(MachineProbe.originPath)
      )
    }

    /// Runs the probe; a machine that doesn't answer in 25 seconds is hung up on (60 for Windows, whose PowerShell
    /// can take a while to start).
    private nonisolated static func ask(
      _ executor: SSHExecutor, script: String, name: String, root: URL
    ) async throws -> MachineProbe.Answer {
      let lines = ActionPlanner.LineCollector()
      let command = try executor.start(script, directory: root, environment: ShellEnvironment.shared.variables)
      let watchdog = Task {
        try await Task.sleep(for: .seconds(executor.isWindows ? 60 : 25))
        command.stop()
      }
      let status = await command.run { line in
        if !line.isTransient { lines.add(line.text) }
      }
      watchdog.cancel()
      let answer = MachineProbe.parse(lines.all)
      guard answer.didAnswer else {
        let reason = lines.all.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "exit code \(status)"
        // 255: `ssh` (or the in-process client) couldn't connect or sign in; anything else came from a shell there.
        throw ProbeError.unanswered(reason, connected: status != 255 && status != 129)
      }
      return answer
    }

    /// A probe that got no answer: why, and whether a shell there ran it (one that isn't POSIX's).
    private enum ProbeError: Error {
      case unanswered(String, connected: Bool)
    }

    /// Where the copy of the project on a machine is kept.
    func mirrorFolder(of id: String) -> URL {
      let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        ?? FileManager.default.temporaryDirectory
      return caches.appendingPathComponent("dev.v57.code/BuildFrom", isDirectory: true)
        .appendingPathComponent(ContainerExecutor.digest(root.path + "|" + id), isDirectory: true)
        .appendingPathComponent(root.lastPathComponent, isDirectory: true)
    }

    nonisolated static func rebased(_ path: String, from: String, to: String) -> String {
      path == from ? to : path.hasPrefix(from + "/") ? to + path.dropFirst(from.count) : path
    }

    /// Keeps what the source picked looks like, for when it goes away.
    private func rememberSelectedBuildSource() {
      guard let source = buildSources.first(where: { $0.id == selectedBuildSourceID }) else { return }
      savedBuildSource = source
      defaults.set(try? JSONEncoder().encode(source), forKey: key("buildSourceInfo"))
    }

    /// A machine picked under Run On before Build From existed becomes the source it now is.
    private func adoptSavedRemoteDestination() {
      guard defaults.object(forKey: key("buildSource")) == nil, selectedBuildSourceID == BuildSource.local.id,
        let id = selectedDestinationID, id.hasPrefix(Self.remotePrefix),
        let source = buildSources.first(where: { $0.id == id }), !source.needsFinding
      else { return }
      selectedDestinationID = nil
      selectedBuildSourceID = source.id
      defaults.set(source.id, forKey: key("buildSource"))
      selectedSchemeID = defaults.string(forKey: sourceKey("pickedScheme"))
      scan()
    }

    /// The line an action on another source starts its log with.
    private static func note(_ kind: ActionKind, source: BuildSource, destination: RunDestination?) -> String? {
      switch source.place {
      case .local: return nil
      case .machine(let target):
        return "\(kind.title) on \(target.name), in \(target.directory): it uses the files there, not this folder’s."
      case .container(let runtime):
        return "\(kind.title) in \(destination?.name ?? "a container") on \(runtime.displayName)."
      }
    }

    /// The path this project has where the source builds it, and here: what the build log's issues are mapped back by.
    private func pathsThere(_ source: BuildSource) -> (there: String, here: String)? {
      switch source.place {
      case .local: return nil
      case .machine(let target): return target.directory.isEmpty ? nil : (target.directory, root.path)
      case .container: return (ContainerExecutor.workspace, root.path)
      }
    }

    /// What an action's end says of its source. Returns why it failed when the source was out of reach: `ssh` and the
    /// in-process client exit with 255 when they can't connect or sign in.
    private func noteOutcome(of failure: Error?, cancelled: Bool, source: BuildSource) -> String? {
      guard !source.isLocal, !cancelled else { return nil }
      if source.container != nil {
        guard failure != nil else { return nil }
        refreshBuildSources()
        // What `docker run` exits with when it can't start the container (a full disk, an image it can't fetch).
        if case .failed(125, _)? = failure as? ActionError { return "\(source.name) couldn’t start the container: see the log" }
        return nil
      }
      if case .failed(255, _)? = failure as? ActionError {
        let reason = "Couldn’t reach \(source.name)."
        buildSourceStatuses[source.id] = .unavailable(reason)
        return reason
      }
      if failure == nil { buildSourceStatuses[source.id] = .ready }
      return nil
    }

    // MARK: - Running

    public func canPerform(_ kind: ActionKind) -> Bool {
      guard let scheme = selectedScheme else { return false }
      // Shipping an app happens where it's signed: from this computer, or a machine's own commands.
      if kind.isDistribution, !selectedBuildSource.isLocal,
        selectedBuildSource.container != nil || scheme.toolchain == .xcode
      {
        return false
      }
      return scheme.supports(kind)
    }

    /// Runs an action on the selected scheme and destination, alongside the runs going now (one of the same action
    /// and scheme stops first). `environment` adds variables for its commands (Export's `NOTARY_PROFILE`).
    public func perform(_ kind: ActionKind, environment: [String: String] = [:]) {
      guard let scheme = selectedScheme else { return }
      perform(kind, scheme: scheme, destination: selectedDestination, environment: environment)
    }

    /// Runs an action on `scheme` and `destination` rather than the selected ones (an app's queued installs). A run
    /// of the same action and scheme that is still going stops first; the other runs keep going, and a run of a
    /// project another run is building waits for that build (they share its build folder).
    /// `source` builds from another place than the toolbar's, and `tag` marks the run (a preset's id).
    public func perform(
      _ kind: ActionKind, scheme: ActionScheme, destination: RunDestination?, environment: [String: String] = [:],
      source: BuildSource? = nil, tag: String? = nil
    ) {
      start(
        kind, scheme: scheme, destination: destination, source: source ?? selectedBuildSource,
        environment: environment, tag: tag)
    }

    /// Runs `run`'s action again where it ran (the process stack's Restart): it replaces `run` if still going.
    public func restart(_ run: ActionRun) {
      start(
        run.kind, scheme: run.scheme, destination: run.destination, source: run.source, environment: run.environment,
        tag: run.tag)
    }

    private func start(
      _ kind: ActionKind, scheme: ActionScheme, destination: RunDestination?, source: BuildSource,
      environment: [String: String], tag: String?
    ) {
      let replaced = runs.filter { $0.isWorking && $0.kind == kind && $0.scheme.id == scheme.id }
      for run in replaced { stop(run) }
      // The new run takes the place of the last one's result on the editor (the console keeps it).
      for run in runs where !run.isWorking && run.kind == kind && run.scheme.id == scheme.id { run.isDismissed = true }
      // The debugger (the override) runs here, never on another machine. Builds here go to ~/Developer/Builds
      // when it exists (`BuildFolders`), a container's to its volume; another machine builds where its tools do.
      let destination = destination ?? source.destination(image: ContainerImages.image(for: scheme, root: root))
      let remote = !source.isLocal || destination?.kind == .remote
      let building =
        source.container != nil ? scheme.inContainer() : remote ? scheme : scheme.inBuildFolders()
      let steps =
        (remote ? nil : stepsOverride?(kind, building, destination))
        ?? ActionPlanner.steps(
          for: kind, scheme: building, destination: destination, signing: remoteTarget(for: destination)?.signing)

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
      let run = ActionRun(
        kind: kind, scheme: scheme, destination: destination, source: source, environment: environment,
        testsExpected: kind == .test ? testCounts[operation] : nil, tag: tag)
      run.operation = operation
      // What it waits for: the runs it replaces, and the earlier ones that may still build the same project there.
      let earlier = runs.filter { other in
        other.isBuilding
          && (replaced.contains { $0 === other }
            || (other.scheme.directory == scheme.directory && other.source.id == source.id))
      }
      runs.append(run)
      trimRuns()
      if let note = Self.note(kind, source: source, destination: destination) {
        appendStatus(note, kind: .status, to: run.log)
      }
      run.progress = ActionProgress(message: "Preparing")
      run.progressMessage = "Preparing"
      let tracker = ProgressTracker(
        operation: operation, stages: progressHistory.plan(for: operation) ?? planned,
        history: progressHistory)
      run.tracker = tracker

      let sink = OutputSink(directory: scheme.directory, pathsThere: pathsThere(source)) {
        [weak self, weak run] batch, events in
        guard let self, let run else { return }
        self.receive(batch, events, for: run)
      }
      let context = ActionContext(
        directory: scheme.directory,
        environment: ShellEnvironment.shared.variables.merging(environment) { $1 },
        executor: executor(for: destination, scheme: scheme, source: source),
        confirm: confirm.map { confirm in { @Sendable question in await confirm(question) } }
      ) { line in sink.add(line) }
      run.context = context

      run.task = Task {
        for other in earlier {
          if !replaced.contains(where: { $0 === other }), other.isBuilding {
            run.phase = .waiting(other.title)
            run.progress = ActionProgress(message: "Waiting for \(other.title)")
          }
          while other.isBuilding && !context.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
          }
        }
        var failure: Error?
        if !context.isCancelled {
          run.phase = .running
          run.progress = ActionProgress(message: "Preparing")
          startProgressTimer(for: run)
          await willPerform?()
        }
        for (step, stage) in zip(steps, stages) {
          if context.isCancelled { break }
          sink.flush()
          run.stepTitle = step.title
          if step.title == "Run" && kind == .run {
            // The build is done; the app runs as long as it likes.
            tracker.complete()
            run.progress = nil
            run.isBuilding = false
          } else {
            tracker.begin(stage)
            run.progressMessage = step.title
            updateProgress(of: run)
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
        finish(run, failure: failure)
      }
    }

    private func finish(_ run: ActionRun, failure: Error?) {
      guard let context = run.context else { return }
      let kind = run.kind
      let cancelled = context.isCancelled
      run.context = nil
      run.tracker = nil
      run.progressTimer?.cancel()
      run.progressTimer = nil
      run.progress = nil
      run.stepTitle = nil
      run.isBuilding = false
      run.finished = Date()
      let unreachable = noteOutcome(of: failure, cancelled: cancelled, source: run.source)
      if cancelled {
        run.phase = .stopped
        appendStatus("Stopped", kind: .status, to: run.log)
        finished(kind, succeeded: false)
        return
      }
      if kind == .test, run.testsRun > 0 {
        testCounts[run.operation] = run.testsRun
        defaults.set(testCounts, forKey: key("testCounts"))
      }
      if let failure {
        let message = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
        // The activity view says what failed in few words: the errors, or
        // the exit code when the log had none it could read.
        var summary = message
        if case .failed(let status, _)? = failure as? ActionError {
          let errors = run.errorCount
          summary = errors > 0 ? Self.errors(errors, kind, tests: run.testsRun) : "Exit code \(status)"
        }
        if let unreachable { summary = unreachable }
        run.phase = .failed(summary)
        appendStatus(message, kind: .failure, to: run.log)
        finished(kind, succeeded: false)
      } else if kind != .run && run.errorCount > 0 {
        run.phase = .failed(Self.errors(run.errorCount, kind, tests: run.testsRun))
        finished(kind, succeeded: false)
      } else {
        run.phase = .succeeded
        appendStatus("\(kind.title) \(kind == .run ? "finished" : "succeeded")", kind: .status, to: run.log)
        finished(kind, succeeded: true)
      }
    }

    /// "2 errors"; a test's errors are its failed tests ("2 failed", "2 of 40 failed").
    private static func errors(_ count: Int, _ kind: ActionKind, tests: Int = 0) -> String {
      guard kind == .test else { return "\(count) error\(count == 1 ? "" : "s")" }
      return tests >= count ? "\(count) of \(tests) failed" : "\(count) failed"
    }

    /// Keeps the runs still going and the newest finished ones, `keptRuns` in all.
    private func trimRuns() {
      while runs.count > Self.keptRuns, let index = runs.firstIndex(where: { !$0.isWorking }) {
        runs.remove(at: index)
      }
    }

    /// Runs kept for the console and the stack, counting those still going.
    public nonisolated static let keptRuns = 12

    /// Adds a callback for finished actions, called after `didFinish`.
    public func addFinishHandler(_ handler: @escaping @MainActor (ActionKind, Bool) -> Void) {
      finishHandlers.append(handler)
    }

    private func finished(_ kind: ActionKind, succeeded: Bool) {
      didFinish?(kind, succeeded)
      for handler in finishHandlers { handler(kind, succeeded) }
    }

    /// Ends an action that couldn't start (a preset whose device is gone) as a failed run of `scheme` (the preset's
    /// scheme name) with `message` in its log.
    func failToStart(_ kind: ActionKind, scheme name: String, message: String, tag: String?) {
      let scheme = ActionScheme(name: name, toolchain: .make, directory: root, commands: [:])
      for run in runs where !run.isWorking && run.kind == kind && run.scheme.name == name { run.isDismissed = true }
      let run = ActionRun(
        kind: kind, scheme: scheme, destination: nil, source: selectedBuildSource, environment: [:],
        testsExpected: nil, tag: tag)
      run.isBuilding = false
      run.finished = Date()
      run.phase = .failed(message)
      appendStatus(message, kind: .failure, to: run.log)
      runs.append(run)
      trimRuns()
      finished(kind, succeeded: false)
    }

    func appendStatus(_ text: String, kind: ActionLog.Entry.Kind, to log: ActionLog) {
      log.append([ActionLog.Entry(text: text, kind: kind)])
    }

    /// Stops the newest run still going (Xcode's ⌘.).
    public func stop() {
      guard let run = runs.last(where: \.isWorking) else { return }
      stop(run)
    }

    /// Stops `run` if it's still going (or waiting to).
    public func stop(_ run: ActionRun) {
      guard run.isWorking else { return }
      run.context?.cancel()
    }

    /// Stops every run still going.
    public func stopAll() {
      for run in runs where run.isWorking { stop(run) }
    }

    /// Takes `run` off the editor's stack; the console keeps it.
    public func dismiss(_ run: ActionRun) {
      run.isDismissed = true
    }

    /// Takes every finished run off the editor's stack.
    public func hideFinished() {
      for run in runs where !run.isWorking { run.isDismissed = true }
    }

    /// Forgets the finished runs and the notes (the console's Clear).
    public func clearFinished() {
      runs.removeAll { !$0.isWorking }
      notes.clear()
    }

    private func receive(_ batch: [ActionLog.Entry], _ events: [BuildLogParser.Event], for run: ActionRun) {
      run.log.append(batch)
      var known = Set(run.issues.map(\.id))
      // A running program's output isn't build progress.
      let measured = run.phase == .running && !run.isRunningApp
      for event in events {
        switch event {
        case .issue(let issue):
          if known.insert(issue.id).inserted { run.issues.append(issue) }
        case .progress(let progress) where measured:
          if !progress.message.isEmpty { run.progressMessage = progress.message }
          if let fraction = progress.fraction { run.tracker?.report(fraction: fraction) }
        case .count(let done, let total) where measured:
          run.tracker?.update(units: Double(done), of: Double(total))
        case .unit(let unit) where measured:
          if unit == .test { run.testsRun += 1 }
          guard let tracker = run.tracker else { break }
          // Tests follow the build in the same command: a stage of their own.
          if unit == .test, let stage = tracker.snapshot().stage, !stage.id.hasSuffix("|tests") {
            tracker.begin(Self.testsStage(after: stage))
          }
          tracker.advance()
        default: break
        }
      }
      if measured { updateProgress(of: run) }
    }

    /// The tests a test command runs once it has built them.
    static func testsStage(after build: ProgressStage) -> ProgressStage {
      ProgressStage(id: build.id + "|tests", title: "Tests", resource: .cpu, timing: .static)
    }

    /// The tracker's estimate under the log's last message.
    private func updateProgress(of run: ActionRun) {
      guard let tracker = run.tracker, run.phase == .running, !run.isRunningApp else { return }
      let snapshot = tracker.snapshot()
      let next = ActionProgress(
        fraction: snapshot.fraction, message: run.progressMessage, remaining: snapshot.remaining)
      if next != run.progress { run.progress = next }
    }
    /// Moves the estimate with time between log lines.
    private func startProgressTimer(for run: ActionRun) {
      run.progressTimer?.cancel()
      run.progressTimer = Task { [weak self, weak run] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(250))
          guard let self, let run else { return }
          self.updateProgress(of: run)
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
    /// The project's folder where it's built and here: issues point at the files here. The log shows what was said.
    private let pathsThere: (there: String, here: String)?

    init(
      directory: URL, pathsThere: (there: String, here: String)? = nil,
      deliver: @escaping @MainActor ([ActionLog.Entry], [BuildLogParser.Event]) -> Void
    ) {
      parser = BuildLogParser(directory: directory)
      self.pathsThere = pathsThere
      self.deliver = deliver
    }

    func add(_ line: ActionLine) {
      lock.withLock {
        let parsed = pathsThere.map { line.text.replacingOccurrences(of: $0.there + "/", with: $0.here + "/") } ?? line.text
        events += parser.consume(parsed)
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
