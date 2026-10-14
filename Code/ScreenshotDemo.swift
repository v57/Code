import Foundation

/// Debug builds: `--screenshot-demo` runs Code on demo projects for the screenshots (`.dev/screenshots.json`), never
/// the user's. A debug build shares the installed app's defaults and the vault, so in this mode recent projects are
/// the demo's own and the vault opens a fresh store of its own.
///
///   --screenshot-demo        the demo
///   --open <folder>          opens a project in the first window
///   --recent <folder>        a recent project for the Welcome window (repeatable)
///   --do <command>           a DebugAutomation command once the project is up (repeatable, in order):
///                            `open:<path>:<line>`, `quickopen:<query>`, `find:<query>`, `console:on`, …
enum ScreenshotDemo {
  static let isOn: Bool = {
    #if DEBUG
      CommandLine.arguments.contains("--screenshot-demo")
    #else
      false
    #endif
  }()

  static func values(_ option: String) -> [String] {
    let arguments = CommandLine.arguments
    return arguments.indices.dropLast().filter { arguments[$0] == option }.map { arguments[$0 + 1] }
  }

  static var folder: URL? { isOn ? values("--open").first.map { URL(fileURLWithPath: $0) } : nil }

  /// Recent projects of the demo, apart from the user's.
  static let defaults: UserDefaults = {
    let name = "dev.v57.code.screenshot-demo"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    defaults.set(values("--recent"), forKey: "recentProjects")
    return defaults
  }()

  /// Before anything opens the vault: a fresh, empty store of the demo's own.
  static func prepare() {
    let vault = FileManager.default.temporaryDirectory.appendingPathComponent("CodeScreenshotDemo/Vault")
    try? FileManager.default.removeItem(at: vault)
    try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    setenv("VAULT_DIRECTORY", vault.path, 1)
  }

  #if DEBUG
    private static var ran = false

    /// The `--do` commands, once, a moment apart so each one's UI settles.
    @MainActor static func runCommands() {
      guard isOn, !ran else { return }
      ran = true
      let commands = values("--do")
      Task { @MainActor in
        for command in commands {
          try? await Task.sleep(for: .milliseconds(800))
          DebugAutomation.run(command)
        }
      }
    }
  #endif
}
