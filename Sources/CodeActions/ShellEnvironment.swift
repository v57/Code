import Foundation

#if os(Windows) || os(Linux)
  import SwiftUIPortability
#endif

/// The environment of the user's login shell. An app opened from the Dock
/// gets launchd's minimal PATH, without Homebrew, ~/.local/bin, Bun, Cargo
/// or the Android SDK; commands run with this environment instead, so they
/// find the same tools as in Terminal.
public final class ShellEnvironment: @unchecked Sendable {
  public static let shared = ShellEnvironment()

  /// The variables commands run with.
  public let variables: [String: String]

  public init(variables: [String: String]) {
    self.variables = variables
  }

  private convenience init() {
    self.init(variables: Self.load())
  }

  public var path: [String] {
    #if os(Windows)
      // Windows names it Path, and separates folders with ";".
      let value = variables.first { $0.key.uppercased() == "PATH" }?.value ?? ""
      return value.split(separator: ";").map(String.init)
    #else
      return (variables["PATH"] ?? "").split(separator: ":").map(String.init)
    #endif
  }

  /// The full path of `tool` on the PATH, or nil.
  public func which(_ tool: String) -> String? {
    #if os(Windows)
      let fileManager = FileManager.default
      if tool.contains("\\") || tool.contains(":") { return fileManager.fileExists(atPath: tool) ? tool : nil }
      for directory in path {
        for suffix in ["", ".exe", ".cmd", ".bat"] {
          let candidate = URL(fileURLWithPath: directory).appendingPathComponent(tool + suffix).path
          var isDirectory: ObjCBool = false
          if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue {
            return candidate
          }
        }
      }
      return nil
    #else
      if tool.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: tool) ? tool : nil }
      for directory in path {
        let candidate = directory + "/" + tool
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
      }
      return nil
    #endif
  }

  /// The Android SDK: $ANDROID_HOME, $ANDROID_SDK_ROOT or Android Studio's
  /// default location.
  public var androidSDK: URL? {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let candidates = [variables["ANDROID_HOME"], variables["ANDROID_SDK_ROOT"]].compactMap { $0 }
      + [home.appendingPathComponent("Library/Android/sdk").path]
    return candidates.map { URL(fileURLWithPath: $0) }.first {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("platform-tools").path)
    }
  }

  /// `adb`, from the PATH or the Android SDK.
  public var adb: String? {
    which("adb") ?? androidSDK.map { $0.appendingPathComponent("platform-tools/adb").path }
  }

  /// The Android emulator, from the Android SDK.
  public var androidEmulator: String? {
    guard let path = androidSDK?.appendingPathComponent("emulator/emulator").path,
      FileManager.default.isExecutableFile(atPath: path)
    else { return which("emulator") }
    return path
  }

  /// Folders added after the login shell's PATH, where tools commonly live
  /// even when the shell profile doesn't list them.
  static func fallbackPaths(home: String) -> [String] {
    [
      "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", home + "/.local/bin",
      home + "/.bun/bin", home + "/.cargo/bin", home + "/go/bin",
      home + "/Library/Android/sdk/platform-tools", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
  }

  /// Runs the login shell once (interactive, so .zshrc counts too) and reads
  /// its environment; falls back to this process's environment.
  static func load() -> [String: String] {
    #if os(Windows)
      // An app started from the Start menu or Explorer has the user's environment already.
      return ProcessInfo.processInfo.environment
    #else
    var result = ProcessInfo.processInfo.environment
    let shell = result["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? SubprocessCapture.shellPath
    let marker = "__CODE_ENVIRONMENT__"
    if let output = SubprocessCapture.run(
      shell, ["-l", "-i", "-c", "printf '\\n\(marker)\\n'; /usr/bin/env -0"],
      directory: URL(fileURLWithPath: NSHomeDirectory()), timeout: 8,
      requireSuccess: false),
      let range = output.range(of: marker + "\n")
    {
      for entry in output[range.upperBound...].split(separator: "\0") {
        guard let eq = entry.firstIndex(of: "=") else { continue }
        let key = String(entry[..<eq])
        guard !key.isEmpty, key != "_", key != "SHLVL", key != "PWD", key != "OLDPWD" else { continue }
        result[key] = String(entry[entry.index(after: eq)...])
      }
    }
    let home = URL(fileURLWithPath: NSHomeDirectory()).path
    // Gradle wrappers need a JDK; without JAVA_HOME use Android Studio's or
    // Homebrew's, as Android Studio does.
    if result["JAVA_HOME"]?.isEmpty ?? true {
      let candidates = [
        "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
        "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home",
        "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home",
        "/opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home",
      ]
      if let java = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0 + "/bin/java") }) {
        result["JAVA_HOME"] = java
      }
    }
    var path = (result["PATH"] ?? "").split(separator: ":").map(String.init)
    for extra in fallbackPaths(home: home) where !path.contains(extra) { path.append(extra) }
    result["PATH"] = path.joined(separator: ":")
    return result
    #endif
  }
}

/// Runs a command to completion and returns its standard output, for
/// listings (`xcodebuild -list`, `simctl list`, `adb devices`).
public enum SubprocessCapture {
  /// Standard output, or nil when the command fails, can't start or runs
  /// past `timeout` seconds (it is then terminated).
  public static func run(
    _ executable: String, _ arguments: [String], directory: URL? = nil,
    environment: [String: String]? = nil, timeout: TimeInterval = 60, requireSuccess: Bool = true
  ) -> String? {
    #if os(macOS)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      if let directory { process.currentDirectoryURL = directory }
      if let environment { process.environment = environment }
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      process.standardInput = FileHandle.nullDevice
      let done = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in done.signal() }
      do { try process.run() } catch { return nil }
      // Read while it runs: a full pipe would block the command.
      nonisolated(unsafe) var data = Data()
      let reader = DispatchQueue.global(qos: .userInitiated)
      let readDone = DispatchSemaphore(value: 0)
      reader.async {
        data = output.fileHandleForReading.readDataToEndOfFile()
        readDone.signal()
      }
      if done.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        kill(process.processIdentifier, SIGKILL)
        _ = readDone.wait(timeout: .now() + 1)
        return nil
      }
      _ = readDone.wait(timeout: .now() + 2)
      if requireSuccess, process.terminationStatus != 0 { return nil }
      return String(decoding: data, as: UTF8.self)
    #elseif os(Windows) || os(Linux)
      guard
        let child = try? ChildProcess(
          executable: URL(fileURLWithPath: executable), arguments: arguments, directory: directory,
          environment: environment ?? ProcessInfo.processInfo.environment, verbatimArguments: executable == shellPath)
      else { return nil }
      nonisolated(unsafe) var data = Data()
      let readDone = DispatchSemaphore(value: 0)
      Thread.detachNewThread {
        child.read(.output) { data.append($0) }
        readDone.signal()
      }
      Thread.detachNewThread { child.read(.error) { _ in } }
      let exited = DispatchSemaphore(value: 0)
      nonisolated(unsafe) var status: Int32 = 0
      Thread.detachNewThread {
        status = child.waitUntilExit()
        exited.signal()
      }
      if exited.wait(timeout: .now() + timeout) == .timedOut {
        child.terminate()
        _ = readDone.wait(timeout: .now() + 1)
        return nil
      }
      _ = readDone.wait(timeout: .now() + 2)
      if requireSuccess, status != 0 { return nil }
      return String(decoding: data, as: UTF8.self)
    #else
      return nil
    #endif
  }

  /// The shell commands run in: zsh, cmd on Windows, bash on Linux (sh where there's none).
  #if os(Windows)
    public static let shellPath =
      ProcessInfo.processInfo.environment["ComSpec"] ?? ProcessInfo.processInfo.environment["COMSPEC"]
      ?? "C:\\Windows\\System32\\cmd.exe"
  #elseif os(Linux)
    public static let shellPath = FileManager.default.isExecutableFile(atPath: "/bin/bash") ? "/bin/bash" : "/bin/sh"
  #else
    public static let shellPath = "/bin/zsh"
  #endif

  /// The shell's arguments for running `command`.
  public static func shellArguments(_ command: String) -> [String] {
    #if os(Windows)
      // cmd takes the rest of its command line as is with /s: the command keeps its own quoting.
      ["/d", "/s", "/c", "\"" + command + "\""]
    #else
      ["-c", command]
    #endif
  }

  /// Runs a shell command line with the login shell's environment.
  public static func shell(
    _ command: String, directory: URL? = nil, timeout: TimeInterval = 60,
    requireSuccess: Bool = true
  ) -> String? {
    run(
      shellPath, shellArguments(command), directory: directory,
      environment: ShellEnvironment.shared.variables, timeout: timeout,
      requireSuccess: requireSuccess)
  }
}
