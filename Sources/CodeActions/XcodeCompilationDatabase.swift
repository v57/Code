import Foundation

/// The compiler arguments of an Xcode scheme's Swift files, as a compilation
/// database (`compile_commands.json`) for SourceKit-LSP.
///
/// SourceKit-LSP reads SwiftPM packages, compilation databases and build
/// servers, not Xcode projects: a file of an Xcode target gets fallback
/// arguments without its target's other files or the modules it imports, so
/// jumping to a definition finds nothing. Xcode's own index arguments
/// (`xcodebuild -showBuildSettingsForIndex`) fill that in. Each target's
/// arguments go in a response file, as they list every file of the target
/// and would otherwise repeat for each of them.
public enum XcodeCompilationDatabase {
  /// The `-destination` to read index arguments for: the selected
  /// simulator, else a generic one of the scheme's first platform (a
  /// device's arguments match its generic platform).
  static func destination(for scheme: ActionScheme, _ destination: RunDestination?) -> String {
    switch destination?.kind {
    case .iOSSimulator?: return "id=" + destination!.id
    case .iOSDevice?: return "generic/platform=iOS"
    case .mac?: return "generic/platform=macOS"
    default: return scheme.platforms.first == .iOS ? "generic/platform=iOS Simulator" : "generic/platform=macOS"
    }
  }

  /// The architecture a Debug build makes for a destination: devices are
  /// arm64, this Mac and its simulators are this Mac's.
  static func architecture(for destination: RunDestination?) -> String {
    if destination?.kind == .iOSDevice { return "arm64" }
    #if arch(arm64)
      return "arm64"
    #else
      return "x86_64"
    #endif
  }

  /// The database and response files from `-showBuildSettingsForIndex
  /// -json` output: target → file → settings. Response files are named by
  /// target and contents and live in `directory`; the compiler runs in
  /// `workingDirectory` (the project's folder). With `architecture`,
  /// arguments for another one are rewritten for it.
  public static func make(
    fromIndexSettings json: Data, directory: URL, workingDirectory: URL, architecture: String? = nil
  ) -> (
    database: Data, responseFiles: [String: String]
  )? {
    guard let targets = try? JSONSerialization.jsonObject(with: json) as? [String: [String: Any]] else {
      return nil
    }
    var entries: [[String: Any]] = []
    var responseFiles: [String: String] = [:]
    for (target, files) in targets.sorted(by: { $0.key < $1.key }) {
      let target = target.map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce(into: "") { $0.append($1) }
      var responseFile: String?
      for (file, settings) in files.sorted(by: { $0.key < $1.key }) {
        guard file.hasSuffix(".swift"), let settings = settings as? [String: Any],
          let arguments = settings["swiftASTCommandArguments"] as? [String], !arguments.isEmpty
        else { continue }
        // A target's files share its arguments. The file is named by its
        // contents, so the database changes when they do: SourceKit-LSP
        // keeps a file's arguments while its database entry stays the same.
        if responseFile == nil {
          let arguments = architecture.map { retarget(arguments, to: $0) } ?? arguments
          let text = arguments.map(quoted).joined(separator: "\n") + "\n"
          let name = target + "-" + String(fnv1a(text), radix: 16) + ".resp"
          responseFiles[name] = text
          responseFile = directory.appendingPathComponent(name).path
        }
        entries.append([
          "directory": workingDirectory.path, "file": file, "arguments": ["swiftc", "@" + responseFile!],
        ])
      }
    }
    guard !entries.isEmpty,
      let database = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
    else { return nil }
    return (database, responseFiles)
  }

  /// Arguments for `architecture`: the target triple's and the per-arch
  /// folders' (`Objects-normal/x86_64`). xcodebuild names either of a
  /// Mac's architectures at random, whatever `ARCHS` says, and Debug builds
  /// make only the active one's modules.
  static func retarget(_ arguments: [String], to architecture: String) -> [String] {
    guard let index = arguments.firstIndex(of: "-target"), index + 1 < arguments.count,
      let current = arguments[index + 1].split(separator: "-").first.map(String.init),
      current != architecture
    else { return arguments }
    return arguments.enumerated().map { offset, argument in
      if offset == index + 1 { return architecture + argument.dropFirst(current.count) }
      guard argument.contains("/" + current) else { return argument }
      return argument.split(separator: "/", omittingEmptySubsequences: false)
        .map { $0 == current ? architecture : String($0) }.joined(separator: "/")
    }
  }

  /// FNV-1a: a hash that stays the same across launches.
  public static func fnv1a(_ text: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
    return hash
  }

  /// An argument for a response file, quoted when it has spaces or quotes.
  static func quoted(_ argument: String) -> String {
    guard argument.isEmpty || argument.contains(where: { " \t\n\"'\\".contains($0) }) else { return argument }
    let escaped = argument.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"" + escaped + "\""
  }

  #if os(macOS)
    /// Writes the database for an Xcode scheme into `directory`, replacing
    /// what was there. Returns whether the files changed, or nil when
    /// xcodebuild failed. Takes a few seconds: call it off the main thread.
    public static func write(
      scheme: ActionScheme, destination: RunDestination?, to directory: URL, environment: [String: String]
    ) -> Bool? {
      guard scheme.toolchain == .xcode, let container = scheme.xcodeContainer else { return nil }
      let flag = container.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
      guard
        let output = SubprocessCapture.run(
          "/usr/bin/xcodebuild",
          [
            "-showBuildSettingsForIndex", flag, container, "-scheme", scheme.name,
            "-destination", self.destination(for: scheme, destination), "-json",
          ],
          directory: scheme.directory, environment: environment, timeout: 120),
        let made = make(
          fromIndexSettings: Data(output.utf8), directory: directory, workingDirectory: scheme.directory,
          architecture: architecture(for: destination))
      else { return nil }
      let manager = FileManager.default
      try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
      var changed = false
      func write(_ data: Data, to name: String) {
        let url = directory.appendingPathComponent(name)
        guard (try? Data(contentsOf: url)) != data else { return }
        try? data.write(to: url, options: .atomic)
        changed = true
      }
      for (name, text) in made.responseFiles { write(Data(text.utf8), to: name) }
      write(made.database, to: "compile_commands.json")
      // Response files of targets no longer in the scheme.
      let current = Set(made.responseFiles.keys)
      for name in (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
      where name.hasSuffix(".resp") && !current.contains(name) {
        try? manager.removeItem(at: directory.appendingPathComponent(name))
        changed = true
      }
      return changed
    }
  #endif
}
