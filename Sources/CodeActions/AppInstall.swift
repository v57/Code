import Foundation

#if os(macOS)
  import AppKit
#endif

/// Installing an Xcode scheme's Mac app on this Mac, as steps: Archive (Release, stamped with the repository's
/// commit count as its build number, as releases are, and exported with Developer ID when the keychain has that
/// identity), Quit (the running copy of the installed app, asking first when the context can ask), Install
/// (replacing the copy in ~/Applications when there is one, else in /Applications) and Open (in the background,
/// only when it was running before).
public enum AppInstall {
  /// The folder the archive and its export go to, relative to the scheme's folder.
  static func folder(_ scheme: ActionScheme) -> String { "build/\(XcodeDetector.plainName(scheme.name).name)" }

  /// What `CURRENT_PROJECT_VERSION` is set to: the commit count, 1 outside Git.
  static let buildNumber = "CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD 2>/dev/null || echo 1)"

  static func steps(_ scheme: ActionScheme) -> [ActionStep] {
    #if os(macOS)
      guard let container = scheme.xcodeContainer else { return [] }
      let name = XcodeDetector.plainName(scheme.name).name
      let flag = container.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
      let base = "xcodebuild \(flag) \(shellQuote(container)) -scheme \(shellQuote(scheme.name))"
      let folder = folder(scheme)
      let archive = "\(folder)/\(name).xcarchive"
      let developerID = "\(folder)/DeveloperID"
      let hasDeveloperID =
        "security find-identity -v -p codesigning | grep -q \"Developer ID Application: .*($(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:Team' \(shellQuote("\(archive)/Info.plist"))))\""
      let export =
        "echo '{\"method\":\"developer-id\"}' | plutil -convert xml1 -o \(shellQuote("\(folder)/DeveloperID.plist")) - && xcodebuild -exportArchive -archivePath \(shellQuote(archive)) -exportOptionsPlist \(shellQuote("\(folder)/DeveloperID.plist")) -exportPath \(shellQuote(developerID)) -allowProvisioningUpdates"
      let archiveCommand =
        "rm -rf \(shellQuote(developerID)) && \(base) -destination 'generic/platform=macOS' -archivePath \(shellQuote(archive)) archive \(buildNumber) && if \(hasDeveloperID); then \(export); fi"
      let plan = Plan(directory: scheme.directory, archive: archive, developerID: developerID)
      return [
        .shell("Archive", archiveCommand),
        ActionStep("Quit", timing: .static) { context in try await plan.quit(context) },
        ActionStep("Install", resource: .disk, timing: .static) { context in
          let (app, destination) = try plan.paths()
          try await context.run(
            "rm -rf \(shellQuote(destination.path)) && ditto \(shellQuote(app.path)) \(shellQuote(destination.path))",
            title: "Install")
        },
        ActionStep("Open", timing: .static) { context in
          guard plan.wasRunning, let destination = try? plan.paths().1 else { return }
          try await context.run("open -g \(shellQuote(destination.path))", title: "Open")
        },
      ]
    #else
      return []
    #endif
  }

  /// Where the app named `appName` ("Shell.app") is installed: the copy in ~/Applications when there is one, else
  /// /Applications (where a first install goes).
  public static func destination(appName: String) -> URL {
    let home = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent("Applications").appendingPathComponent(appName)
    if FileManager.default.fileExists(atPath: home.path) { return home }
    return URL(fileURLWithPath: "/Applications").appendingPathComponent(appName)
  }

  /// Where `scheme`'s app is installed, or would be: named as the app in its last archive, else after the scheme.
  public static func destination(of scheme: ActionScheme) -> URL {
    let name = XcodeDetector.plainName(scheme.name).name
    let archived = scheme.directory.appendingPathComponent("\(folder(scheme))/\(name).xcarchive/Products/Applications")
    let app = (try? FileManager.default.contentsOfDirectory(atPath: archived.path))?.sorted()
      .first { $0.hasSuffix(".app") }
    return destination(appName: app ?? name + ".app")
  }

  #if os(macOS)
    /// What the steps share: the archive's paths, and whether the app was running.
    final class Plan: @unchecked Sendable {
      let directory: URL
      let archive: String
      let developerID: String
      private let lock = NSLock()
      private var running = false

      init(directory: URL, archive: String, developerID: String) {
        self.directory = directory
        self.archive = archive
        self.developerID = developerID
      }

      var wasRunning: Bool { lock.withLock { running } }

      /// The app to install (the Developer ID export when there is one, else the archived app) and where it goes.
      func paths() throws -> (URL, URL) {
        let archived = directory.appendingPathComponent(archive).appendingPathComponent("Products/Applications")
        guard
          let name = (try? FileManager.default.contentsOfDirectory(atPath: archived.path))?
            .sorted().first(where: { $0.hasSuffix(".app") })
        else { throw ActionError.missing("The archive has no app in Products/Applications.") }
        let exported = directory.appendingPathComponent(developerID).appendingPathComponent(name)
        let app = FileManager.default.fileExists(atPath: exported.path) ? exported : archived.appendingPathComponent(name)
        return (app, AppInstall.destination(appName: name))
      }

      /// Quits the copy running from the destination (asking first when the context can ask), waiting for it.
      func quit(_ context: ActionContext) async throws {
        let destination = try paths().1.standardizedFileURL
        let copies = await MainActor.run { AppInstall.running(at: destination) }
        guard !copies.isEmpty else { return }
        let name = destination.deletingPathExtension().lastPathComponent
        if copies.contains(where: { $0 == ProcessInfo.processInfo.processIdentifier }) {
          throw ActionError.missing("\(name) can’t replace itself while it runs: install it from another app.")
        }
        if let confirm = context.confirm, !(await confirm("Quit \(name) to install the new build?")) {
          throw ActionError.cancelled
        }
        lock.withLock { running = true }
        context.log("Quitting \(name)")
        await MainActor.run { AppInstall.terminate(at: destination) }
        // An app may ask to save first: give it a minute.
        for _ in 0..<240 {
          if context.isCancelled { throw ActionError.cancelled }
          if await MainActor.run(body: { AppInstall.running(at: destination).isEmpty }) { return }
          try? await Task.sleep(for: .milliseconds(250))
        }
        throw ActionError.missing("\(name) didn’t quit, so it wasn’t replaced.")
      }
    }

    /// The processes of the app at `url` (not other copies of it, a debug build elsewhere).
    @MainActor static func running(at url: URL) -> [pid_t] {
      NSWorkspace.shared.runningApplications
        .filter { !$0.isTerminated && $0.bundleURL?.standardizedFileURL == url }
        .map(\.processIdentifier)
    }

    /// Asks the app at `url` to quit, as Quit in its menu does.
    @MainActor static func terminate(at url: URL) {
      for app in NSWorkspace.shared.runningApplications where app.bundleURL?.standardizedFileURL == url {
        app.terminate()
      }
    }
  #endif
}

/// An installed app as it was when it was looked at: an install that replaces it (here, or by anything else)
/// changes its `stamp`.
public struct InstalledApp: Codable, Hashable, Sendable {
  public var url: URL
  public var identifier: String?
  /// `CFBundleVersion`: the commit count for v57 builds.
  public var build: String?
  /// The Info.plist's file number and date: a new copy has another.
  public var stamp: String

  public init(url: URL, identifier: String?, build: String?, stamp: String) {
    self.url = url
    self.identifier = identifier
    self.build = build
    self.stamp = stamp
  }

  /// The app at `url`, nil when there's none.
  public init?(at url: URL) {
    let info = url.appendingPathComponent("Contents/Info.plist")
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: info.path),
      let data = try? Data(contentsOf: info),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }
    let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    self.init(
      url: url, identifier: plist["CFBundleIdentifier"] as? String, build: plist["CFBundleVersion"] as? String,
      stamp: "\(number):\(date)")
  }
}

/// What an install left: the source it was built from and the app it put in place.
public struct InstallRecord: Codable, Hashable, Sendable {
  public var fingerprint: String
  public var app: InstalledApp
  public var date: Date

  public init(fingerprint: String, app: InstalledApp, date: Date = Date()) {
    self.fingerprint = fingerprint
    self.app = app
    self.date = date
  }
}

/// Whether the installed app is the current source's.
public enum InstallStatus: Hashable, Sendable {
  /// There's no app to replace.
  case notInstalled
  case current
  /// The source changed since, or it can't be told it didn't.
  case outdated

  /// The status of `installed` for the source at `sourceBuild` (its commit count): an older build number says so at
  /// once, without the fingerprint. Otherwise the record of the install that put this very copy there decides (the
  /// fingerprint then and now); without one (another app installed it), the build number does, unless the source has
  /// uncommitted changes.
  public static func evaluate(
    installed: InstalledApp?, record: InstallRecord?, sourceBuild: Int?, fingerprint: () -> SourceFingerprint
  ) -> InstallStatus {
    guard let installed else { return .notInstalled }
    let build = installed.build.flatMap(Int.init)
    if let build, let sourceBuild, build < sourceBuild { return .outdated }
    let source = fingerprint()
    if let record, record.app.url.standardizedFileURL == installed.url.standardizedFileURL,
      record.app.stamp == installed.stamp
    {
      return record.fingerprint == source.value ? .current : .outdated
    }
    guard let build, let sourceBuild, build == sourceBuild, !source.isDirty else { return .outdated }
    return .current
  }
}

/// Runs another executor's commands at low priority, inherited by everything they start: a QoS clamp (`taskpolicy
/// -c`, utility by default) and `nice`, so a long build in the background leaves the Mac responsive.
public struct LowPriorityExecutor: ActionExecutor {
  public var base: any ActionExecutor
  /// "utility", "background" (efficiency cores only, much slower) or "maintenance".
  public var clamp: String
  public var niceness: Int

  public init(base: any ActionExecutor = LocalExecutor(), clamp: String = "utility", niceness: Int = 10) {
    self.base = base
    self.clamp = clamp
    self.niceness = niceness
  }

  public func start(_ command: String, directory: URL, environment: [String: String]) throws -> any ActionCommand {
    try base.start(wrapped(command), directory: directory, environment: environment)
  }

  func wrapped(_ command: String) -> String {
    #if os(macOS)
      return "exec /usr/sbin/taskpolicy -c \(clamp) /usr/bin/nice -n \(niceness) /bin/zsh -c \(shellQuote(command))"
    #else
      return command
    #endif
  }
}
