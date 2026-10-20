import CodeKit
import DevScreenshots
import Foundation
#if os(Windows)
  import WinSDK
#endif

/// Debug builds: `--screenshot-demo` runs Code on demo projects for the screenshots (`.dev/screenshots.json`), never
/// the user's. A debug build shares the installed app's defaults and the vault, so in this mode recent projects and
/// project sessions are the demo's own and the vault opens a fresh store of its own.
///
///   --screenshot-demo        the demo
///   --open <folder>          opens a project in the first window (without one, the window shows Welcome)
///   --recent <folder>        a recent project for the Welcome window (repeatable)
///   --do <command>           a DebugAutomation command once the project is up (repeatable, in order):
///                            `open:<path>:<line>`, `quickopen:<query>`, `find:<query>`, `console:on`, …
///
/// `dev-screenshots` takes every scene in one launch: the first window shows the launch's scene, then each next one
/// it sends, from that scene's arguments, after undoing what the scene before left open.
enum ScreenshotDemo {
  static let isOn: Bool = {
    #if DEBUG
      CommandLine.arguments.contains("--screenshot-demo")
    #else
      false
    #endif
  }()

  static func values(_ option: String, in arguments: [String] = CommandLine.arguments) -> [String] {
    arguments.indices.dropLast().filter { arguments[$0] == option }.map { arguments[$0 + 1] }
  }

  /// Recent projects and project sessions of the demo, apart from the user's.
  static let defaults: UserDefaults = {
    let name = "dev.v57.code.screenshot-demo"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    defaults.set(values("--recent"), forKey: "recentProjects")
    return defaults
  }()

  /// Before anything opens the vault: a fresh, empty store of the demo's own. Then the screenshot capture, which
  /// waits for each scene to load.
  @MainActor static func prepare() {
    let vault = FileManager.default.temporaryDirectory.appendingPathComponent("CodeScreenshotDemo/Vault")
    try? FileManager.default.removeItem(at: vault)
    try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    #if os(Windows)
      _ = "VAULT_DIRECTORY".withCString(encodedAs: UTF16.self) { name in
        vault.path.withCString(encodedAs: UTF16.self) { SetEnvironmentVariableW(name, $0) }
      }
    #else
      setenv("VAULT_DIRECTORY", vault.path, 1)
    #endif
    #if DEBUG
      Screenshots.prepare(waitsForReady: true) { scene in await show(scene.arguments) }
    #endif
  }

  #if DEBUG
    /// What a scene shows.
    private struct Scene: Equatable {
      var folder: URL?
      var commands: [String]
      var recents: [String]

      init(_ arguments: [String]) {
        folder = ScreenshotDemo.values("--open", in: arguments).first.map {
          URL(fileURLWithPath: $0).standardizedFileURL
        }
        commands = ScreenshotDemo.values("--do", in: arguments)
        recents = ScreenshotDemo.values("--recent", in: arguments)
      }
    }

    /// Sets the first window's folder (nil: Welcome).
    @MainActor private static var showFolder: ((URL?) -> Void)?
    @MainActor private static var shown: Scene?

    /// The first window shows the scenes: the launch's, then the ones `dev-screenshots` sends.
    @MainActor static func attach(_ show: @escaping (URL?) -> Void) {
      guard isOn, showFolder == nil else { return }
      showFolder = show
      Task {
        await self.show(CommandLine.arguments)
        Screenshots.ready()
      }
    }

    /// Shows a scene once it has loaded. The same scene again (the next appearance) is already showing.
    @MainActor private static func show(_ arguments: [String]) async {
      let scene = Scene(arguments)
      guard let showFolder, scene != shown else { return }
      shown = scene
      AppState.shared.recents.replace(with: scene.recents.map { URL(fileURLWithPath: $0) })
      guard let folder = scene.folder else {
        showFolder(nil)
        await waitUntil(timeout: .seconds(5)) { !AppState.shared.hasProjects }
        return
      }
      if AppState.shared.model(for: folder) == nil {
        // Another project first goes back to Welcome, so the window's model is replaced, not left registered.
        if AppState.shared.hasProjects {
          showFolder(nil)
          await waitUntil(timeout: .seconds(5)) { !AppState.shared.hasProjects }
        }
        showFolder(folder)
      }
      await waitUntil(timeout: .seconds(10)) { AppState.shared.model(for: folder) != nil }
      guard let model = AppState.shared.model(for: folder) else { return }
      AppState.shared.debugModel = model
      reset(model)
      // The project's index, schemes and language server, before anything searches or opens.
      await waitUntil { isSettled(model) }
      #if os(macOS)
        for command in scene.commands {
          DebugAutomation.run(command)
          await waitUntil(timeout: .seconds(10)) { isSettled(model) }
          if command.hasPrefix("open:") { DebugAutomation.run("focus") }
        }
      #endif
      await waitUntil { isSettled(model) }
    }

    /// Undoes what an earlier scene left in the project window: its overlays, the Find navigator, the tabs and
    /// where the editor was.
    @MainActor private static func reset(_ model: WindowModel) {
      model.isQuickOpenPresented = false
      model.quickOpenQuery = ""
      model.isGoToLinePresented = false
      model.isIssuesPresented = false
      model.isConsoleVisible = false
      model.navigator = .project
      model.find.clear()
      model.sidebarSelection = nil
      for document in model.workspace.tabs { model.workspace.close(document) }
      model.services.clearHistory()
    }

    /// Nothing is loading: the file index, the toolbar's schemes and destinations, the language server, the shown
    /// file, a search.
    @MainActor private static func isSettled(_ model: WindowModel) -> Bool {
      let services = model.services
      let workspace = model.workspace
      guard services.isReady, !services.actions.isScanning, !services.actions.isLoadingDestinations,
        !workspace.index.isIndexing, !model.find.isSearching, services.languageServers.activity == nil,
        !services.languageServers.states.values.contains(.starting)
      else { return false }
      guard let document = workspace.selectedDocument else { return true }
      #if os(macOS)
        return document.content != .loading && DebugAutomation.isShown(document)
      #else
        return document.content != .loading
      #endif
    }

    /// Until `condition` has held for a moment (a loaded file is drawn, a search shows its results), or `timeout`.
    @MainActor private static func waitUntil(
      timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool
    ) async {
      let clock = ContinuousClock()
      let deadline = clock.now + timeout
      var heldSince: ContinuousClock.Instant?
      while clock.now < deadline {
        if condition() {
          let since = heldSince ?? clock.now
          heldSince = since
          if clock.now - since >= .milliseconds(300) { return }
        } else {
          heldSince = nil
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  #endif
}
