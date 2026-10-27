import CodeProgress
import Foundation

/// One step of an action ("Build", "Install", "Launch"), run in order.
public struct ActionStep: Sendable {
  public var title: String
  /// What bounds its speed and whether it takes about as long each time,
  /// for the action's progress estimate.
  public var resource: ProgressResource
  public var timing: ProgressStage.Timing
  public var work: @Sendable (ActionContext) async throws -> Void

  public init(
    _ title: String, resource: ProgressResource = .cpu, timing: ProgressStage.Timing = .dynamic,
    work: @escaping @Sendable (ActionContext) async throws -> Void
  ) {
    self.title = title
    self.resource = resource
    self.timing = timing
    self.work = work
  }

  /// A step that runs a shell command in the scheme's folder.
  public static func shell(
    _ title: String, _ command: String, environment: [String: String] = [:],
    resource: ProgressResource = .cpu, timing: ProgressStage.Timing = .dynamic
  ) -> ActionStep {
    ActionStep(title, resource: resource, timing: timing) { context in
      try await context.run(command, title: title, environment: environment)
    }
  }
}

  /// What steps share while an action runs: the folder, the environment, the
  /// output, the running command (to stop it) and cleanups for Stop.
  public final class ActionContext: @unchecked Sendable {
    public let directory: URL
    public let environment: [String: String]
    /// Where `run` runs commands: this computer, or another machine (`SSHExecutor`).
    public let executor: any ActionExecutor
    private let output: @Sendable (ActionLine) -> Void
    private let lock = NSLock()
    private var current: (any ActionCommand)?
    private var stopHandlers: [@Sendable () -> Void] = []
    private var cancelled = false

    public init(
      directory: URL, environment: [String: String], executor: any ActionExecutor = LocalExecutor(),
      output: @escaping @Sendable (ActionLine) -> Void
    ) {
      self.directory = directory
      self.environment = environment
      self.executor = executor
      self.output = output
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Writes a line to the log.
    public func log(_ text: String) {
      output(ActionLine(text: text, isTransient: false))
    }

    /// Runs a shell command on a terminal, streaming its output; throws when
    /// it fails (unless `allowFailure`) or Stop was pressed.
    @discardableResult
    public func run(
      _ command: String, title: String, in directory: URL? = nil,
      environment extra: [String: String] = [:], allowFailure: Bool = false
    ) async throws -> Int32 {
      if isCancelled { throw ActionError.cancelled }
      var environment = environment
      for (key, value) in extra { environment[key] = value }
      let process = try executor.start(command, directory: directory ?? self.directory, environment: environment)
      lock.withLock { current = process }
      log("$ " + command)
      let status = await process.run(onLine: output)
      lock.withLock { current = nil }
      if isCancelled { throw ActionError.cancelled }
      if status != 0 && !allowFailure { throw ActionError.failed(status: status, step: title) }
      return status
    }

    /// Runs a command quietly and returns its output (nil when it fails).
    public func capture(_ command: String, in directory: URL? = nil, timeout: TimeInterval = 120)
      async -> String?
    {
      let directory = directory ?? self.directory
      let environment = environment
      return await Task.detached {
        SubprocessCapture.run(
          SubprocessCapture.shellPath, SubprocessCapture.shellArguments(command), directory: directory,
          environment: environment, timeout: timeout)
      }.value
    }

    /// Runs `handler` when Stop is pressed (terminating an app on a device).
    public func onStop(_ handler: @escaping @Sendable () -> Void) {
      lock.withLock { stopHandlers.append(handler) }
    }

    /// Stops the running command and runs the Stop handlers.
    public func cancel() {
      let (process, handlers) = lock.withLock { () -> ((any ActionCommand)?, [@Sendable () -> Void]) in
        cancelled = true
        defer { stopHandlers = [] }
        return (current, stopHandlers)
      }
      process?.stop()
      for handler in handlers { handler() }
    }
  }

  /// The steps of an action for a scheme and destination: plain commands for
  /// most toolchains; build, install and launch for apps on simulators,
  /// devices and Android.
  public enum ActionPlanner {
    public static func steps(
      for kind: ActionKind, scheme: ActionScheme, destination: RunDestination?, signing: RemoteSigning? = nil
    ) -> [ActionStep] {
      if destination?.kind == .remote { return remoteSteps(kind, scheme, signing: signing ?? .unsigned) }
      switch scheme.toolchain {
      case .xcode: return xcodeSteps(kind, scheme, destination)
      case .android: return androidSteps(kind, scheme, destination)
      default:
        guard let command = scheme.commands[kind] else { return [] }
        return [.shell(kind.title, command)]
      }
    }

    // MARK: - Another machine

    /// The steps on another machine (`SSHExecutor`): the scheme's own commands, and xcodebuild for the Mac there,
    /// signed as `signing` says. Running an Xcode app there and installing to devices it reaches come later.
    static func remoteSteps(_ kind: ActionKind, _ scheme: ActionScheme, signing: RemoteSigning) -> [ActionStep] {
      switch scheme.toolchain {
      case .xcode:
        let arguments = xcodeArguments(scheme, .mac)
        switch kind {
        case .build: return [.shell("Build", signing.xcodebuild(arguments, "build"))]
        case .test: return [.shell("Test", signing.xcodebuild(arguments, "test"))]
        case .clean: return [.shell("Clean", "xcodebuild \(arguments) clean", resource: .disk)]
        default:
          return [
            ActionStep(kind.title) { _ in
              throw ActionError.missing("\(kind.title) runs on this Mac for now; Build, Test and Clean run on the other one.")
            }
          ]
        }
      case .android:
        return [
          ActionStep(kind.title) { _ in throw ActionError.missing("Android actions run on this Mac for now.") }
        ]
      default:
        guard let command = scheme.commands[kind] else { return [] }
        return [.shell(kind.title, command)]
      }
    }

    // MARK: - Xcode

    static func xcodeArguments(_ scheme: ActionScheme, _ destination: RunDestination?) -> String {
      let container = scheme.xcodeContainer ?? ""
      let flag = container.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
      var arguments = "\(flag) \(shellQuote(container)) -scheme \(shellQuote(scheme.name))"
      switch destination?.kind {
      case .mac?: arguments += " -destination 'platform=macOS'"
      case .iOSSimulator?: arguments += " -destination \(shellQuote("id=" + destination!.id))"
      case .iOSDevice?:
        arguments += " -destination \(shellQuote("id=" + destination!.id)) -allowProvisioningUpdates"
      default: break
      }
      return arguments
    }

    static func xcodeSteps(
      _ kind: ActionKind, _ scheme: ActionScheme, _ destination: RunDestination?
    ) -> [ActionStep] {
      let arguments = xcodeArguments(scheme, destination)
      switch kind {
      case .build: return [.shell("Build", "xcodebuild \(arguments) build")]
      case .test: return [.shell("Test", "xcodebuild \(arguments) test")]
      case .clean: return [.shell("Clean", "xcodebuild \(arguments) clean", resource: .disk)]
      case .lint, .install, .export, .upload:
        return scheme.commands[kind].map { [.shell(kind.title, $0)] } ?? []
      case .run: break
      }
      var steps: [ActionStep] = [.shell("Build", "xcodebuild \(arguments) build")]
      steps.append(
        ActionStep("Run") { context in
          guard
            let json = await context.capture("xcodebuild \(arguments) -showBuildSettings -json"),
            let product = XcodeProduct.parse(json, scheme: scheme.name)
          else { throw ActionError.missing("Couldn’t read the build settings of “\(scheme.name)”.") }
          try await launch(product, on: destination ?? .mac, context: context)
        })
      return steps
    }

    static func launch(_ product: XcodeProduct, on destination: RunDestination, context: ActionContext)
      async throws
    {
      switch destination.kind {
      case .iOSSimulator:
        let udid = shellQuote(destination.id)
        try await context.run("xcrun simctl boot \(udid)", title: "Boot", allowFailure: true)
        try await context.run(
          // Simulator.app, or DeviceHub in Xcodes that replaced it.
          "open -b com.apple.iphonesimulator --args -CurrentDeviceUDID \(udid) 2>/dev/null || open -b com.apple.dt.Devices",
          title: "Open Simulator",
          allowFailure: true)
        try await context.run(
          "xcrun simctl install \(udid) \(shellQuote(product.wrapperPath))", title: "Install")
        guard let bundleID = product.bundleIdentifier else {
          throw ActionError.missing("The app has no bundle identifier.")
        }
        let environment = context.environment
        context.onStop {
          _ = SubprocessCapture.run(
            "/usr/bin/xcrun", ["simctl", "terminate", destination.id, bundleID],
            environment: environment, timeout: 10)
        }
        try await context.run(
          "xcrun simctl launch --console-pty --terminate-running-process \(udid) \(shellQuote(bundleID))",
          title: "Run", allowFailure: true)
      case .iOSDevice:
        let udid = shellQuote(destination.id)
        try await context.run(
          "xcrun devicectl device install app --device \(udid) \(shellQuote(product.wrapperPath))",
          title: "Install")
        guard let bundleID = product.bundleIdentifier else {
          throw ActionError.missing("The app has no bundle identifier.")
        }
        try await context.run(
          "xcrun devicectl device process launch --device \(udid) --terminate-existing --console \(shellQuote(bundleID))",
          title: "Run", allowFailure: true)
      default:
        // Run the executable itself (not `open`), so its output shows and
        // Stop ends it, as in Xcode.
        try await context.run(
          shellQuote(product.executablePath), title: "Run", in: product.buildDirectory,
          allowFailure: true)
      }
    }

    // MARK: - Android

    static func androidSteps(
      _ kind: ActionKind, _ scheme: ActionScheme, _ destination: RunDestination?
    ) -> [ActionStep] {
      let environment: [String: String] =
        ShellEnvironment.shared.androidSDK.map { ["ANDROID_HOME": $0.path] } ?? [:]
      guard kind == .run else {
        return scheme.commands[kind].map {
          [.shell(kind.title, $0, environment: environment)]
        } ?? []
      }
      guard let destination, destination.platform == .android else {
        return [
          ActionStep("Run") { _ in
            throw ActionError.missing("Choose an Android device or emulator to run on.")
          }
        ]
      }
      guard let adb = ShellEnvironment.shared.adb else {
        return [
          ActionStep("Run") { _ in
            throw ActionError.missing(
              "adb wasn’t found. Install the Android SDK platform tools (brew install android-platform-tools).")
          }
        ]
      }
      let install = scheme.commands[.run] ?? "./gradlew installDebug --console=plain"
      // The device's serial, found (or the emulator started) once.
      let device = SerialBox()
      return [
        ActionStep("Install") { context in
          let serial = try await androidSerial(for: destination, adb: adb, context: context)
          device.serial = serial
          var installEnvironment = environment
          installEnvironment["ANDROID_SERIAL"] = serial
          try await context.run(install, title: "Install", environment: installEnvironment)
        },
        ActionStep("Run") { context in
          guard let serial = device.serial else { return }
          guard let applicationID = scheme.androidApplicationID else {
            throw ActionError.missing("Couldn’t find the app’s applicationId in its Gradle build.")
          }
          let adbDevice = "\(shellQuote(adb)) -s \(shellQuote(serial))"
          let app = shellQuote(applicationID)
          let shellEnvironment = context.environment
          context.onStop {
            _ = SubprocessCapture.run(
              adb, ["-s", serial, "shell", "am", "force-stop", applicationID],
              environment: shellEnvironment, timeout: 10)
          }
          try await context.run(
            "\(adbDevice) shell am force-stop \(app); \(adbDevice) shell monkey -p \(app) -c android.intent.category.LAUNCHER 1 >/dev/null",
            title: "Launch")
          // The app's log, while it runs.
          try await context.run(
            "for i in {1..20}; do pid=$(\(adbDevice) shell pidof -s \(app) | tr -d '\\r'); [ -n \"$pid\" ] && break; sleep 0.5; done; [ -n \"$pid\" ] && exec \(adbDevice) logcat -v brief --pid=$pid",
            title: "Run", allowFailure: true)
        },
      ]
    }

    final class SerialBox: @unchecked Sendable {
      var serial: String?
    }

    /// The adb serial of a destination; starts a virtual device and waits for
    /// it to boot.
    static func androidSerial(for destination: RunDestination, adb: String, context: ActionContext)
      async throws -> String
    {
      guard destination.kind == .androidVirtualDevice else { return destination.id }
      guard let emulator = ShellEnvironment.shared.androidEmulator else {
        throw ActionError.missing("The Android emulator wasn’t found in the Android SDK.")
      }
      let name = String(destination.id.dropFirst("avd:".count))
      context.log("Starting the emulator “\(name)”…")
      try await context.run(
        "nohup \(shellQuote(emulator)) -avd \(shellQuote(name)) >/dev/null 2>&1 &",
        title: "Start Emulator")
      for _ in 0..<180 {
        if context.isCancelled { throw ActionError.cancelled }
        try await Task.sleep(for: .seconds(1))
        guard let list = await context.capture("\(shellQuote(adb)) devices") else { continue }
        for line in list.split(separator: "\n") where line.hasPrefix("emulator-") && line.hasSuffix("device") {
          let serial = String(line.split(separator: "\t").first ?? "")
          let avd = await context.capture("\(shellQuote(adb)) -s \(serial) emu avd name")?
            .split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          let booted = await context.capture(
            "\(shellQuote(adb)) -s \(serial) shell getprop sys.boot_completed")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if avd == name, booted == "1" { return serial }
        }
      }
      throw ActionError.missing("The emulator “\(name)” didn’t finish starting.")
    }
  }

/// The built product of an Xcode scheme, from `-showBuildSettings -json`.
public struct XcodeProduct: Equatable, Sendable {
  public var buildDirectory: URL
  public var wrapperName: String
  public var executablePath: String
  public var bundleIdentifier: String?

  /// The .app (or the executable itself, for a command-line tool).
  public var wrapperPath: String { buildDirectory.appendingPathComponent(wrapperName).path }

  /// The scheme's runnable target: the app or tool named like the scheme,
  /// else the first app, else the first executable.
  public static func parse(_ json: String, scheme: String) -> XcodeProduct? {
    struct Entry: Decodable {
      let target: String
      let buildSettings: [String: String]
    }
    guard let data = json.data(using: .utf8),
      let entries = try? JSONDecoder().decode([Entry].self, from: data)
    else { return nil }
    func runnable(_ entry: Entry) -> Bool {
      let type = entry.buildSettings["PRODUCT_TYPE"] ?? ""
      return type.hasSuffix(".application") || type.hasSuffix(".tool")
    }
    let entry =
      entries.first { runnable($0) && $0.target == scheme }
      ?? entries.first { $0.buildSettings["PRODUCT_TYPE"]?.hasSuffix(".application") == true }
      ?? entries.first(where: runnable) ?? entries.first
    guard let settings = entry?.buildSettings, let directory = settings["TARGET_BUILD_DIR"],
      let wrapper = settings["FULL_PRODUCT_NAME"], let executable = settings["EXECUTABLE_PATH"]
    else { return nil }
    let buildDirectory = URL(fileURLWithPath: directory)
    return XcodeProduct(
      buildDirectory: buildDirectory, wrapperName: wrapper,
      executablePath: buildDirectory.appendingPathComponent(executable).path,
      bundleIdentifier: settings["PRODUCT_BUNDLE_IDENTIFIER"])
  }
}
