import Foundation

/// A code formatter run on a file's text before an explicit save: the text
/// goes in on standard input and comes back formatted on standard output, so
/// the file is written once, already formatted.
public struct FormatterConfiguration: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  /// The languages, for settings.
  public let languages: String
  /// File extensions it formats (lowercase, no dot).
  public let extensions: Set<String>
  public let command: String
  /// Arguments for formatting standard input for a file at the given path.
  public let arguments: @Sendable (String) -> [String]
  /// Config file names looked up from the file's folder upward; the
  /// formatter reads them itself.
  public let configFiles: [String]
  /// Format only when one of `configFiles` is found (a project that uses
  /// the formatter), unless the user turns that off.
  public let requiresConfigByDefault: Bool
  /// The Homebrew formula (or other command) that installs it.
  public let installCommand: String?

  public init(
    id: String, name: String, languages: String, extensions: Set<String>, command: String,
    arguments: @escaping @Sendable (String) -> [String], configFiles: [String] = [],
    requiresConfigByDefault: Bool = false, installCommand: String?
  ) {
    self.id = id
    self.name = name
    self.languages = languages
    self.extensions = extensions
    self.command = command
    self.arguments = arguments
    self.configFiles = configFiles
    self.requiresConfigByDefault = requiresConfigByDefault
    self.installCommand = installCommand
  }

  public static func == (lhs: FormatterConfiguration, rhs: FormatterConfiguration) -> Bool {
    lhs.id == rhs.id
  }
}

public enum FormatterCatalog {
  public static let all: [FormatterConfiguration] = [
    FormatterConfiguration(
      id: "swift-format", name: "swift-format", languages: "Swift", extensions: ["swift"],
      command: "swift-format", arguments: { ["format", "--assume-filename", $0, "-"] },
      configFiles: [".swift-format"], installCommand: "brew install swift-format"),
    FormatterConfiguration(
      id: "prettier", name: "Prettier",
      languages: "JavaScript, TypeScript, JSON, CSS, HTML, Markdown, YAML",
      extensions: [
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "json", "jsonc", "css", "scss",
        "less", "html", "vue", "md", "markdown", "yaml", "yml", "graphql",
      ],
      command: "prettier", arguments: { ["--stdin-filepath", $0] },
      configFiles: [
        ".prettierrc", ".prettierrc.json", ".prettierrc.yaml", ".prettierrc.yml", ".prettierrc.json5",
        ".prettierrc.js", ".prettierrc.cjs", ".prettierrc.mjs", ".prettierrc.toml",
        "prettier.config.js", "prettier.config.cjs", "prettier.config.mjs", "prettier.config.ts",
      ],
      requiresConfigByDefault: true, installCommand: "brew install prettier"),
    FormatterConfiguration(
      id: "gofmt", name: "gofmt", languages: "Go", extensions: ["go"], command: "gofmt",
      arguments: { _ in [] }, installCommand: "brew install go"),
    FormatterConfiguration(
      id: "rustfmt", name: "rustfmt", languages: "Rust", extensions: ["rs"], command: "rustfmt",
      arguments: { path in ["--emit", "stdout", "--edition", RustEdition.edition(for: path)] },
      configFiles: ["rustfmt.toml", ".rustfmt.toml"], installCommand: "brew install rust"),
    FormatterConfiguration(
      id: "ruff", name: "Ruff", languages: "Python", extensions: ["py", "pyi"], command: "ruff",
      arguments: { ["format", "--stdin-filename", $0, "-"] },
      configFiles: ["ruff.toml", ".ruff.toml", "pyproject.toml"], installCommand: "brew install ruff"),
    FormatterConfiguration(
      id: "clang-format", name: "ClangFormat", languages: "C, C++, Objective-C",
      extensions: ["c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm"], command: "clang-format",
      arguments: { ["--assume-filename=\($0)"] }, configFiles: [".clang-format", "_clang-format"],
      requiresConfigByDefault: true, installCommand: "brew install clang-format"),
    FormatterConfiguration(
      id: "zig-fmt", name: "zig fmt", languages: "Zig", extensions: ["zig", "zon"], command: "zig",
      arguments: { _ in ["fmt", "--stdin"] }, installCommand: "brew install zig"),
    FormatterConfiguration(
      id: "mix-format", name: "mix format", languages: "Elixir", extensions: ["ex", "exs"],
      command: "mix", arguments: { ["format", "--stdin-filename", $0, "-"] },
      configFiles: [".formatter.exs"], requiresConfigByDefault: true,
      installCommand: "brew install elixir"),
    FormatterConfiguration(
      id: "ktlint", name: "ktlint", languages: "Kotlin", extensions: ["kt", "kts"], command: "ktlint",
      arguments: { _ in ["--format", "--stdin", "--log-level=error"] },
      configFiles: [".editorconfig"], installCommand: "brew install ktlint"),
    FormatterConfiguration(
      id: "shfmt", name: "shfmt", languages: "Shell", extensions: ["sh", "bash"], command: "shfmt",
      arguments: { ["-filename", $0] }, installCommand: "brew install shfmt"),
  ]

  public static func formatter(for url: URL, in formatters: [FormatterConfiguration] = all)
    -> FormatterConfiguration?
  {
    let ext = url.pathExtension.lowercased()
    return formatters.first { $0.extensions.contains(ext) }
  }
}

/// The Rust edition of a file's crate, from the nearest Cargo.toml that
/// names one (rustfmt reading standard input can't find it itself).
enum RustEdition {
  static func edition(for path: String) -> String {
    var folder = URL(fileURLWithPath: path).deletingLastPathComponent()
    while folder.path.count > 1 {
      if let text = try? String(contentsOf: folder.appendingPathComponent("Cargo.toml"), encoding: .utf8),
        let range = text.range(of: #"edition\s*=\s*"(\d{4})""#, options: .regularExpression)
      {
        return String(text[range].filter(\.isNumber).suffix(4))
      }
      folder = folder.deletingLastPathComponent()
    }
    return "2021"
  }
}

/// Formats texts with the configured formatters.
public struct FormattingService: Sendable {
  public enum Failure: Error, LocalizedError, Equatable {
    case failed(formatter: String, message: String)
    case timedOut(formatter: String)

    public var errorDescription: String? {
      switch self {
      case .failed(let formatter, let message):
        return "\(formatter) couldn’t format the file: \(message)"
      case .timedOut(let formatter): return "\(formatter) took too long."
      }
    }
  }

  /// The environment formatters run with (the login shell's, for PATH).
  public var environment: [String: String]
  public var formatters = FormatterCatalog.all
  /// Formatters turned off in settings.
  public var disabledIDs: Set<String> = []
  /// Formatters whose "only with a config file" was changed from its
  /// default, mapped to the chosen value.
  public var requiresConfig: [String: Bool] = [:]
  /// Commands to use instead of looking a formatter up on the PATH.
  public var customCommands: [String: String] = [:]

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  public func requiresConfigFile(_ formatter: FormatterConfiguration) -> Bool {
    requiresConfig[formatter.id] ?? formatter.requiresConfigByDefault
  }

  /// The formatter's command: a custom one, the project's own copy
  /// (node_modules/.bin), or the PATH's.
  public func executable(for formatter: FormatterConfiguration, file: URL? = nil) -> String? {
    if let custom = customCommands[formatter.id], !custom.isEmpty,
      FileManager.default.isExecutableFile(atPath: (custom as NSString).expandingTildeInPath)
    {
      return (custom as NSString).expandingTildeInPath
    }
    if let file, formatter.id == "prettier",
      let local = Self.findUpward(["node_modules/.bin/prettier"], from: file)
    {
      return local.path
    }
    for directory in (environment["PATH"] ?? "").split(separator: ":") {
      let candidate = "\(directory)/\(formatter.command)"
      if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }

  /// The formatter that would format `url` now, with its command.
  public func formatter(for url: URL) -> (configuration: FormatterConfiguration, executable: String)? {
    guard let formatter = FormatterCatalog.formatter(for: url, in: formatters),
      !disabledIDs.contains(formatter.id), let executable = executable(for: formatter, file: url)
    else { return nil }
    if requiresConfigFile(formatter), Self.findUpward(formatter.configFiles, from: url) == nil {
      return nil
    }
    return (formatter, executable)
  }

  /// The formatted text, or nil when no formatter applies.
  public func format(_ text: String, url: URL, timeout: TimeInterval = 10) async throws -> String? {
    guard let (formatter, executable) = formatter(for: url) else { return nil }
    let arguments = formatter.arguments(url.path)
    let environment = environment
    // The file's folder (or the nearest one that exists, for a new file).
    var directory = url.deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: directory.path), directory.path.count > 1 {
      directory = directory.deletingLastPathComponent()
    }
    return try await Task.detached(priority: .userInitiated) { [directory] in
      try Self.run(
        executable, arguments, input: text, directory: directory,
        environment: environment, timeout: timeout, name: formatter.name)
    }.value
  }

  /// The first of `names` in the file's folder or a folder above it (up
  /// to the home folder).
  public static func findUpward(_ names: [String], from file: URL) -> URL? {
    guard !names.isEmpty else { return nil }
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    var folder = file.standardizedFileURL.deletingLastPathComponent()
    while folder.path.count > 1 {
      for name in names {
        let candidate = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      }
      if folder.path == home { break }
      folder = folder.deletingLastPathComponent()
    }
    return nil
  }

  static func run(
    _ executable: String, _ arguments: [String], input: String, directory: URL,
    environment: [String: String], timeout: TimeInterval, name: String
  ) throws -> String {
    #if os(macOS)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      process.currentDirectoryURL = directory
      process.environment = environment
      let stdin = Pipe()
      let stdout = Pipe()
      let stderr = Pipe()
      process.standardInput = stdin
      process.standardOutput = stdout
      process.standardError = stderr
      let done = DispatchSemaphore(value: 0)
      process.terminationHandler = { _ in done.signal() }
      do {
        try process.run()
      } catch {
        throw Failure.failed(formatter: name, message: error.localizedDescription)
      }
      nonisolated(unsafe) var output = Data()
      nonisolated(unsafe) var errors = Data()
      let reads = DispatchGroup()
      reads.enter()
      DispatchQueue.global().async {
        output = stdout.fileHandleForReading.readDataToEndOfFile()
        reads.leave()
      }
      reads.enter()
      DispatchQueue.global().async {
        errors = stderr.fileHandleForReading.readDataToEndOfFile()
        reads.leave()
      }
      DispatchQueue.global().async {
        try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
      }
      if done.wait(timeout: .now() + timeout) == .timedOut {
        process.terminate()
        throw Failure.timedOut(formatter: name)
      }
      _ = reads.wait(timeout: .now() + 2)
      guard process.terminationStatus == 0 else {
        let message = String(decoding: errors, as: UTF8.self)
          .split(separator: "\n").filter { !$0.contains("deprecated") }.prefix(3)
          .joined(separator: " ")
        throw Failure.failed(
          formatter: name,
          message: message.isEmpty ? "exit code \(process.terminationStatus)" : message)
      }
      let formatted = String(decoding: output, as: UTF8.self)
      // An empty answer for a non-empty file is a failure, not a format.
      if formatted.isEmpty && !input.isEmpty {
        throw Failure.failed(formatter: name, message: "no output")
      }
      return formatted
    #else
      return input
    #endif
  }
}
