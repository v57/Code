import CodeFolders
import Foundation

/// Whether a preset can run now, and why not.
public enum RunPresetState: Equatable, Sendable {
  case ready
  /// Its machine is asleep, its device gone, its scheme renamed: why, in a sentence.
  case unavailable(String)

  public var reason: String? {
    if case .unavailable(let reason) = self { return reason }
    return nil
  }
}

/// A preset's four choices found among the project's: what it runs with.
public struct ResolvedRunPreset: Sendable {
  public var source: BuildSource
  public var container: ProjectContainer?
  public var scheme: ActionScheme
  /// Nil for a source that isn't this computer: it runs where it builds.
  public var destination: RunDestination?
}

extension ActionController {
  // MARK: - Presets

  /// The preset the toolbar's choices make now, auto-named (`RunPreset.autoName`).
  public func presetFromToolbar(_ kind: ActionKind = .run) -> RunPreset {
    let source = selectedBuildSource
    let container = selectedContainer
    let scheme = selectedScheme?.name ?? ""
    let target = selectedDestination?.name ?? ""
    let from = source.isLocal ? RunPreset.local : source.name
    let project = container?.fileName ?? ""
    return RunPreset(
      name: RunPreset.autoName(
        action: kind, scheme: scheme, from: from, target: target, project: project,
        defaultProject: defaultContainer(for: container)?.fileName),
      action: kind, from: from, project: project, scheme: scheme, target: target)
  }

  /// The container a folder uses until one is picked, when it has several to choose from; nil with one or none.
  public func defaultContainer(for container: ProjectContainer?) -> ProjectContainer? {
    guard let container else { return nil }
    let all = containers(in: container.directory)
    return all.count > 1 ? all.first : nil
  }

  /// The auto name for a preset made of these parts, the project's default container known.
  public func autoName(for preset: RunPreset) -> String {
    let container = containers.first { $0.fileName == preset.project }
    return RunPreset.autoName(
      action: preset.action, scheme: preset.scheme, from: preset.from, target: preset.target, project: preset.project,
      defaultProject: defaultContainer(for: container)?.fileName)
  }

  /// The build source a preset names: this computer for "local", else the machine or runtime of that name.
  /// On iPhone and iPad the machines are the project's devices (its remote destinations), each building as this
  /// side's own source does.
  public func source(named from: String) -> BuildSource? {
    if from == RunPreset.local || from.isEmpty { return .local }
    #if os(iOS)
      return destinations.contains { $0.kind == .remote && $0.name == from } ? .local : nil
    #else
      return buildSources.first { $0.name == from }
    #endif
  }

  /// Whether a preset can run now, from what is known without asking anyone: its machine, its scheme (when its project
  /// is the one the toolbar lists), its device (`refreshPresetDestinations`).
  public func state(of preset: RunPreset) -> RunPresetState {
    guard let source = source(named: preset.from) else {
      #if os(iOS)
        return .unavailable("\(root.lastPathComponent) isn’t on \(preset.from), or it can’t be reached from here.")
      #else
        return didReceiveMachines ? .unavailable("\(preset.from) isn’t one of your machines now.") : .ready
      #endif
    }
    if case .unavailable(let reason)? = source.isLocal ? nil : buildSourceStatuses[source.id] {
      return .unavailable(reason)
    }
    if source.id == selectedBuildSourceID, !isScanning, !schemes.isEmpty, listsProject(preset.project) {
      guard let scheme = schemes.first(where: { $0.name == preset.scheme }) else {
        return .unavailable("\(preset.scheme) isn’t one of \(root.lastPathComponent)’s schemes now.")
      }
      if !scheme.supports(preset.action) {
        return .unavailable(Self.cannot(preset.action, scheme: scheme.name))
      }
    }
    #if !os(iOS)
      if source.isLocal, hasPresetDestinations, !preset.target.isEmpty {
        guard let destination = presetDestinations.first(where: { $0.name == preset.target }) else {
          return .unavailable("\(preset.target) isn’t connected.")
        }
        if !destination.isAvailable { return .unavailable("\(preset.target) can’t run apps now.") }
      }
    #endif
    return .ready
  }

  /// Whether the toolbar's schemes are `project`'s: it is picked (or the default) in its folder.
  private func listsProject(_ project: String) -> Bool {
    guard !project.isEmpty else { return true }
    return containers.contains { container in
      container.fileName == project
        && ProjectContainer.effective(picked: pickedContainers[container.directory.path], in: containers(in: container.directory))
          == container
    }
  }

  static func cannot(_ kind: ActionKind, scheme: String) -> String {
    switch kind {
    case .run: return "\(scheme) has nothing to run."
    case .test: return "\(scheme) has no tests."
    default: return "\(scheme) can’t \(kind.title.lowercased())."
    }
  }

  /// Lists every destination the presets' schemes can run on (their platforms, else the Mac's and iOS's), so the bar
  /// can tell which device is gone. On iPhone and iPad nothing runs here: their machines are the destinations.
  public func refreshPresetDestinations(for presets: [RunPreset]) {
    #if os(iOS)
      _ = presets
    #else
      let local = presets.filter(\.isLocal)
      guard !local.isEmpty else {
        presetDestinations = []
        hasPresetDestinations = false
        return
      }
      var platforms: Set<Platform> = []
      for preset in local {
        if let scheme = schemes.first(where: { $0.name == preset.scheme }) {
          platforms.formUnion(scheme.platforms)
        } else {
          platforms.formUnion([.mac, .iOS])
        }
      }
      presetDestinationsTask?.cancel()
      presetDestinationsTask = Task {
        let found = await DestinationProvider.load(platforms: platforms)
        guard !Task.isCancelled else { return }
        presetDestinations = found + remoteDestinations
        hasPresetDestinations = true
      }
    #endif
  }

  /// Finds a preset's choices among the project's now: its source, its project picked in its folder, its scheme by
  /// name and its device by name. Throws `ActionError.missing` with why one isn't there.
  public func resolve(_ preset: RunPreset) async throws -> ResolvedRunPreset {
    guard let source = source(named: preset.from) else {
      throw ActionError.missing("\(preset.from) isn’t one of your machines now.")
    }
    if !source.isLocal, case .unavailable(let reason)? = buildSourceStatuses[source.id] {
      throw ActionError.missing(reason)
    }
    let (scheme, container) = try await scheme(for: preset, source: source)
    guard scheme.supports(preset.action) else { throw ActionError.missing(Self.cannot(preset.action, scheme: scheme.name)) }
    var destination: RunDestination?
    #if os(iOS)
      // Built on a machine: the project's own (the session's pick) for "local", else the one named.
      destination =
        preset.isLocal ? selectedDestination : destinations.first { $0.kind == .remote && $0.name == preset.from }
      guard destination != nil else { throw ActionError.missing("\(preset.from) can’t be reached from here.") }
    #else
      if source.isLocal {
        let found = await DestinationProvider.load(platforms: Set(scheme.platforms)) + remoteDestinations
        if preset.target.isEmpty {
          destination = found.first { $0.isAvailable }
        } else {
          guard let named = found.first(where: { $0.name == preset.target }) else {
            throw ActionError.missing("\(preset.target) isn’t connected.")
          }
          guard named.isAvailable else { throw ActionError.missing("\(preset.target) can’t run apps now.") }
          destination = named
        }
      }
    #endif
    return ResolvedRunPreset(source: source, container: container, scheme: scheme, destination: destination)
  }

  /// The preset's scheme: from the toolbar's list when it builds from the same place with the same project, else from
  /// a scan of its own with its project picked (the toolbar's picks stay).
  private func scheme(for preset: RunPreset, source: BuildSource) async throws -> (ActionScheme, ProjectContainer?) {
    var picks =
      source.id == selectedBuildSourceID
      ? pickedContainers
      : defaults.dictionary(forKey: key(source.isLocal ? "containers" : "containers|\(source.id)")) as? [String: String] ?? [:]
    let named = containers.filter { $0.fileName == preset.project }
    for container in named { picks[container.directory.path] = container.fileName }
    func container(of scheme: ActionScheme, in all: [ProjectContainer]) -> ProjectContainer? {
      ProjectContainer.effective(
        picked: picks[scheme.directory.path], in: all.filter { $0.directory.path == scheme.directory.path })
    }
    func matches(_ scheme: ActionScheme, in all: [ProjectContainer]) -> Bool {
      guard scheme.name == preset.scheme else { return false }
      guard !preset.project.isEmpty, let container = container(of: scheme, in: all) else { return true }
      return container.fileName == preset.project
    }
    if source.id == selectedBuildSourceID, listsProject(preset.project),
      let scheme = schemes.first(where: { matches($0, in: containers) })
    {
      return (scheme, container(of: scheme, in: containers))
    }
    let capabilities = capabilities(of: source)
    let found = await Self.findSchemes(
      root: root, excluded: excludedNames, picks: picks, capabilities: capabilities,
      mirror: source.machine == nil ? nil : mirrorFolder(of: source.id))
    guard let scheme = found.schemes.first(where: { capabilities.canBuild($0) && matches($0, in: found.containers) })
    else {
      let place = preset.project.isEmpty ? root.lastPathComponent : preset.project
      throw ActionError.missing("\(preset.scheme) isn’t one of \(place)’s schemes now.")
    }
    return (scheme, container(of: scheme, in: found.containers))
  }

  /// Runs a preset with its own choices, leaving the toolbar's as they are. `tag` (the preset's id) is the action's
  /// `runningTag`. A choice that is gone ends it at once, saying why in the log.
  public func perform(preset: RunPreset, tag: String? = nil) {
    Task {
      do {
        let resolved = try await resolve(preset)
        perform(preset.action, scheme: resolved.scheme, destination: resolved.destination, source: resolved.source, tag: tag)
      } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        failToStart(preset.action, scheme: preset.scheme, message: "\(preset.name): \(message)", tag: tag)
      }
    }
  }

  /// Copies a preset's four choices into the toolbar (as far as they are there now).
  public func useInToolbar(_ preset: RunPreset) async {
    if let source = source(named: preset.from), source.id != selectedBuildSourceID { selectBuildSource(source) }
    let resolved = try? await resolve(preset)
    if let container = resolved?.container ?? containers.first(where: { $0.fileName == preset.project }) {
      selectContainer(container)
    }
    if let scheme = resolved?.scheme {
      selectedSchemeID = scheme.id
    } else if let scheme = schemes.first(where: { $0.name == preset.scheme }) {
      selectedSchemeID = scheme.id
    }
    if let destination = resolved?.destination {
      selectedDestinationID = destination.id
    } else if let destination = (presetDestinations + destinations).first(where: { $0.name == preset.target }) {
      selectedDestinationID = destination.id
    }
  }
}
