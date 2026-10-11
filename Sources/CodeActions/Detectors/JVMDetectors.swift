import Foundation

/// A Gradle build: a scheme per Android app module (run on Android devices
/// and emulators), else one for the build with `run` when it has an
/// application, plus one per `JavaExec` task.
public struct GradleDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    let buildFile = ["build.gradle.kts", "build.gradle"].first(where: folder.hasFile)
    let settingsFile = ["settings.gradle.kts", "settings.gradle"].first(where: folder.hasFile)
    guard buildFile != nil || settingsFile != nil else { return [] }
    let gradle = folder.hasFile("gradlew") ? "./gradlew" : "gradle"
    let plain = " --console=plain"

    // Android apps: the root project or an included module.
    var modules = [""]
    if let settingsFile, let settings = folder.read(settingsFile) {
      modules += Self.includedModules(settings)
    }
    var schemes: [ActionScheme] = []
    for module in modules {
      let path = module.replacingOccurrences(of: ":", with: "/")
      let moduleFolder = path.isEmpty ? folder.url : folder.url.appendingPathComponent(path)
      guard
        let script = ["build.gradle.kts", "build.gradle"].lazy.compactMap({
          try? String(contentsOf: moduleFolder.appendingPathComponent($0), encoding: .utf8)
        }).first,
        Self.isAndroidApp(script)
      else { continue }
      let task = module.isEmpty ? "" : ":\(module):"
      let applicationID =
        matches(of: #"applicationId\s*=?\s*"([^"]+)""#, in: script).first?[0]
        ?? matches(of: #"namespace\s*=?\s*"([^"]+)""#, in: script).first?[0]
      schemes.append(
        ActionScheme(
          name: module.isEmpty ? folder.name : module, toolchain: .android, directory: folder.url,
          commands: [
            .build: "\(gradle) \(task)assembleDebug" + plain,
            .run: "\(gradle) \(task)installDebug" + plain,
            .test: "\(gradle) \(task)testDebugUnitTest" + plain,
            .clean: "\(gradle) clean" + plain,
          ],
          platforms: [.android], androidApplicationID: applicationID,
          androidModule: module.isEmpty ? nil : module))
    }
    if !schemes.isEmpty { return schemes }

    let script = buildFile.flatMap(folder.read) ?? ""
    var commands: [ActionKind: String] = [
      .build: "\(gradle) build -x test" + plain, .test: "\(gradle) test" + plain,
      .clean: "\(gradle) clean" + plain,
    ]
    if script.contains("application") || script.contains("mainClass") {
      if script.range(of: #"\bapplication\b"#, options: .regularExpression) != nil {
        commands[.run] = "\(gradle) run" + plain
      }
    }
    schemes.append(
      ActionScheme(name: folder.name, toolchain: .gradle, directory: folder.url, commands: commands))
    // Tasks that run a main class: `tasks.register<JavaExec>("name")`.
    for groups in matches(
      of: #"(?:tasks\.register<JavaExec>|task)\s*\(\s*"([A-Za-z0-9_-]+)""#, in: script)
    {
      var taskCommands = commands
      taskCommands[.run] = "\(gradle) \(groups[0])" + plain
      schemes.append(
        ActionScheme(
          name: groups[0], toolchain: .gradle, directory: folder.url, commands: taskCommands))
    }
    return schemes
  }

  /// Module paths from `include(":app", ":lib")` / `include ':app'`.
  static func includedModules(_ settings: String) -> [String] {
    var modules: [String] = []
    for line in settings.split(separator: "\n") where line.contains("include") {
      for groups in matches(of: #"["']:?([A-Za-z0-9_:\-]+)["']"#, in: String(line)) {
        modules.append(groups[0])
      }
    }
    return modules
  }

  static func isAndroidApp(_ script: String) -> Bool {
    script.contains("com.android.application") || script.contains("android.application")
      || script.contains("applicationId")
  }
}

/// A Maven project.
public struct MavenDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    guard folder.hasFile("pom.xml") else { return [] }
    let mvn = folder.hasFile("mvnw") ? "./mvnw" : "mvn"
    let pom = folder.read("pom.xml") ?? ""
    var commands: [ActionKind: String] = [
      .build: "\(mvn) -q compile", .test: "\(mvn) test", .clean: "\(mvn) clean",
    ]
    if pom.contains("exec-maven-plugin") || pom.contains("mainClass") {
      commands[.run] = "\(mvn) -q compile exec:java"
    }
    let name = matches(of: #"<artifactId>([^<]+)</artifactId>"#, in: pom).first?[0] ?? folder.name
    return [ActionScheme(name: name, toolchain: .maven, directory: folder.url, commands: commands)]
  }
}
