import Foundation

#if os(Linux)
  import SwiftUIPortability
#endif

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
  /// Whether it runs the project's own code, which a folder that isn't trusted never allows.
  public let projectCode: ProjectCode
  /// How the text reaches it.
  public let input: Input
  /// Exit codes that still mean formatted text (SQLFluff exits 1 when a rule it can't fix is still broken).
  public let successExitCodes: Set<Int32>

  /// How a formatter is given the text.
  public enum Input: Sendable {
    /// On standard input; the formatted text comes back on standard output.
    case standardInput
    /// In a copy with the file's name in a temporary folder, whose path follows the arguments; the formatter
    /// rewrites it in place (PHP-CS-Fixer can't write the result of standard input anywhere).
    case temporaryCopy
  }

  /// When a formatter runs code the project chose.
  public enum ProjectCode: Sendable {
    /// Its configuration is data.
    case none
    /// Its config file, when the project has one, is code or loads code (`.php-cs-fixer.php`, `.rubocop.yml`'s
    /// `require`).
    case config
    /// Always (`mix format` evaluates `.formatter.exs`; SQLFluff templates the file itself).
    case always
  }

  public init(
    id: String, name: String, languages: String, extensions: Set<String>, command: String,
    arguments: @escaping @Sendable (String) -> [String], configFiles: [String] = [],
    requiresConfigByDefault: Bool = false, projectCode: ProjectCode = .none, input: Input = .standardInput,
    successExitCodes: Set<Int32> = [0], installCommand: String?
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
    self.projectCode = projectCode
    self.input = input
    self.successExitCodes = successExitCodes
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
      configFiles: [".formatter.exs"], requiresConfigByDefault: true, projectCode: .always,
      installCommand: "brew install elixir"),
    FormatterConfiguration(
      id: "ktlint", name: "ktlint", languages: "Kotlin", extensions: ["kt", "kts"], command: "ktlint",
      arguments: { _ in ["--format", "--stdin", "--log-level=error"] },
      configFiles: [".editorconfig"], installCommand: "brew install ktlint"),
    FormatterConfiguration(
      id: "shfmt", name: "shfmt", languages: "Shell", extensions: ["sh", "bash"], command: "shfmt",
      arguments: { ["-filename", $0] }, installCommand: "brew install shfmt"),
    FormatterConfiguration(
      id: "google-java-format", name: "google-java-format", languages: "Java", extensions: ["java"],
      command: "google-java-format", arguments: { _ in ["-"] }, installCommand: "brew install google-java-format"),
    FormatterConfiguration(
      id: "csharpier", name: "CSharpier", languages: "C#", extensions: ["cs"], command: "csharpier",
      // Warnings go to standard output with the code, so only errors are logged.
      arguments: { ["format", "--stdin-path", $0, "--log-level", "Error"] },
      configFiles: [".csharpierrc", ".csharpierrc.json", ".csharpierrc.yaml", ".editorconfig"],
      installCommand: "dotnet tool install --global csharpier"),
    FormatterConfiguration(
      id: "dart-format", name: "dart format", languages: "Dart", extensions: ["dart"], command: "dart",
      arguments: { ["format", "--stdin-name", $0] }, configFiles: ["analysis_options.yaml"],
      installCommand: "brew install dart-sdk"),
    // PHP: Pint where the project has pint.json, PHP-CS-Fixer otherwise (FormattingService picks the nearest config).
    FormatterConfiguration(
      id: "pint", name: "Pint", languages: "PHP (Laravel)", extensions: ["php"], command: "pint",
      // Pint 1.26 or later reads standard input; it looks for pint.json in the working folder only.
      arguments: { path in ["-", "--stdin-filename=\(path)"] + ToolConfig.option("--config=", ["pint.json"], for: path) },
      configFiles: ["pint.json"], requiresConfigByDefault: true,
      installCommand: "composer global require laravel/pint"),
    FormatterConfiguration(
      id: "php-cs-fixer", name: "PHP-CS-Fixer", languages: "PHP", extensions: ["php"], command: "php-cs-fixer",
      arguments: { path in
        ["fix", "--quiet", "--show-progress=none", "--using-cache=no", "--path-mode=override"]
          + ToolConfig.option("--config=", PHPCSFixer.configFiles, for: path)
      },
      configFiles: PHPCSFixer.configFiles, projectCode: .config, input: .temporaryCopy,
      installCommand: "brew install php-cs-fixer"),
    // Ruby: Standard where the project has .standard.yml or no config, RuboCop where it has .rubocop.yml.
    FormatterConfiguration(
      id: "standardrb", name: "Standard Ruby", languages: "Ruby", extensions: RubyFiles.extensions,
      command: "standardrb", arguments: { ["--stdin", $0, "--fix", "--stderr", "--fail-level", "error"] },
      configFiles: [".standard.yml"], projectCode: .config, installCommand: "gem install standard"),
    FormatterConfiguration(
      id: "rubocop", name: "RuboCop", languages: "Ruby", extensions: RubyFiles.extensions, command: "rubocop",
      // The report goes to standard error; an offense it can't correct fails only from `error` up (a syntax error).
      arguments: { ["--stdin", $0, "--autocorrect", "--stderr", "--fail-level", "error", "--format", "quiet"] },
      configFiles: [".rubocop.yml"], requiresConfigByDefault: true, projectCode: .config,
      installCommand: "brew install rubocop"),
    FormatterConfiguration(
      id: "scalafmt", name: "scalafmt", languages: "Scala", extensions: ["scala", "sc", "sbt"], command: "scalafmt",
      arguments: { path in
        ["--stdin", "--non-interactive", "--quiet", "--assume-filename", path]
          + ToolConfig.option("--config", [".scalafmt.conf"], for: path, separate: true)
      },
      configFiles: [".scalafmt.conf"], requiresConfigByDefault: true, projectCode: .config,
      installCommand: "cs install scalafmt"),
    FormatterConfiguration(
      id: "stylua", name: "StyLua", languages: "Lua", extensions: ["lua"], command: "stylua",
      arguments: { ["--search-parent-directories", "--stdin-filepath", $0, "-"] },
      configFiles: ["stylua.toml", ".stylua.toml", ".editorconfig"], installCommand: "brew install stylua"),
    // Haskell: Fourmolu where the project has fourmolu.yaml, Ormolu otherwise.
    FormatterConfiguration(
      id: "fourmolu", name: "Fourmolu", languages: "Haskell", extensions: ["hs"], command: "fourmolu",
      arguments: { ["--stdin-input-file", $0] }, configFiles: ["fourmolu.yaml"], requiresConfigByDefault: true,
      installCommand: "brew install fourmolu"),
    FormatterConfiguration(
      id: "ormolu", name: "Ormolu", languages: "Haskell", extensions: ["hs"], command: "ormolu",
      arguments: { ["--stdin-input-file", $0] }, configFiles: [".ormolu"], installCommand: "brew install ormolu"),
    FormatterConfiguration(
      id: "invoke-formatter", name: "Invoke-Formatter", languages: "PowerShell", extensions: ["ps1", "psm1", "psd1"],
      command: "pwsh", arguments: { PowerShellFormatter.arguments(for: $0) },
      configFiles: [PowerShellFormatter.settingsFile],
      installCommand: "brew install powershell && \(PowerShellFormatter.installModule)"),
    FormatterConfiguration(
      id: "taplo", name: "Taplo", languages: "TOML", extensions: ["toml"], command: "taplo",
      arguments: { ["fmt", "--stdin-filepath", $0, "-"] }, configFiles: [".taplo.toml", "taplo.toml"],
      installCommand: "brew install taplo"),
    FormatterConfiguration(
      id: "sqlfluff", name: "SQLFluff", languages: "SQL", extensions: ["sql"], command: "sqlfluff",
      // It needs the project's dialect, from its config. Exit 1: a rule it can't fix (the rest is fixed) or SQL it
      // can't parse (the text comes back as it was).
      arguments: { ["format", "--stdin-filename", $0, "-"] }, configFiles: [".sqlfluff"],
      requiresConfigByDefault: true, projectCode: .always, successExitCodes: [0, 1],
      installCommand: "brew install sqlfluff"),
  ]

  /// The first formatter for a file's extension (its language's default when several can format it).
  public static func formatter(for url: URL, in formatters: [FormatterConfiguration] = all)
    -> FormatterConfiguration?
  {
    self.formatters(for: url, in: formatters).first
  }

  /// Every formatter for a file's extension, in the catalog's order: PHP's Pint and PHP-CS-Fixer, Ruby's Standard and
  /// RuboCop, Haskell's Fourmolu and Ormolu. `FormattingService.formatter(for:)` picks one by the project's config.
  public static func formatters(for url: URL, in formatters: [FormatterConfiguration] = all)
    -> [FormatterConfiguration]
  {
    let ext = url.pathExtension.lowercased()
    return formatters.filter { $0.extensions.contains(ext) }
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
  /// Whether the project's own code may run (a trusted folder, CodeFolders' `FolderTrust`): its
  /// `node_modules/.bin/prettier`, a config that is code (`prettier.config.js`, plugins, `.formatter.exs`). Off, the
  /// PATH's formatter runs with data-only configs, and the others are left alone (security audit H2).
  public var usesProjectCode = false

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
    if usesProjectCode, let file, formatter.id == "prettier",
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
  ///
  /// Of the formatters for the file's extension that are on, installed and not waiting for a config file, the one
  /// whose config file is nearest the file wins (the catalog's order breaks a tie), else the first without one: a
  /// project with `pint.json` gets Pint and one with `.php-cs-fixer.php` PHP-CS-Fixer. In a folder that isn't trusted,
  /// the chosen one is skipped when it would run the project's code; another doesn't stand in for it, since the
  /// project chose that one's style.
  public func formatter(for url: URL) -> (configuration: FormatterConfiguration, executable: String)? {
    typealias Candidate = (formatter: FormatterConfiguration, executable: String, config: URL?)
    var candidates: [Candidate] = []
    for formatter in FormatterCatalog.formatters(for: url, in: formatters) where !disabledIDs.contains(formatter.id) {
      guard let executable = executable(for: formatter, file: url) else { continue }
      let config = Self.findUpward(formatter.configFiles, from: url)
      if requiresConfigFile(formatter), config == nil { continue }
      candidates.append((formatter, executable, config))
    }
    // The nearest config's folder is the longest path; `>` keeps the earlier of a tie.
    func depth(_ candidate: Candidate) -> Int { candidate.config?.deletingLastPathComponent().path.count ?? -1 }
    let configured = candidates.filter { $0.config != nil }
    let chosen = configured.dropFirst().reduce(configured.first) { best, next in
      depth(next) > depth(best!) ? next : best
    } ?? candidates.first
    guard let chosen else { return nil }
    if !usesProjectCode, Self.runsProjectCode(chosen.formatter, config: chosen.config, file: url) { return nil }
    return (chosen.formatter, chosen.executable)
  }

  /// Whether the formatter would run code from the project: `mix format` evaluates `.formatter.exs` (and compiles
  /// plugins), SQLFluff templates the file (and its config can load Python), PHP-CS-Fixer's config is PHP, RuboCop's
  /// and Standard's can `require` Ruby, scalafmt's names a version to download and run, and prettier loads a
  /// JavaScript config, a `package.json` one (which may name a module) and plugins.
  static func runsProjectCode(_ formatter: FormatterConfiguration, config: URL?, file: URL) -> Bool {
    switch formatter.projectCode {
    case .always: return true
    case .config where config != nil: return true
    default: break
    }
    let codeExtensions: Set<String> = ["js", "cjs", "mjs", "ts", "cts", "mts", "exs"]
    if let config, codeExtensions.contains(config.pathExtension.lowercased()) { return true }
    guard formatter.id == "prettier" else { return false }
    // Prettier takes the nearest of several names, package.json's "prettier" key among them: any of them that is
    // code, on the way up, counts.
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
    var folder = file.standardizedFileURL.deletingLastPathComponent()
    while folder.path.count > 1 {
      for name in formatter.configFiles + ["package.json", ".prettierrc.ts", ".prettierrc.cts", ".prettierrc.mts"] {
        let candidate = folder.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
        if codeExtensions.contains(candidate.pathExtension.lowercased()) { return true }
        if name == "package.json" {
          // Its top-level "prettier" key: a config, or the name of a module that is one.
          let json = (try? Data(contentsOf: candidate)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
          if (json as? [String: Any])?["prettier"] != nil { return true }
          continue
        }
        if ((try? String(contentsOf: candidate, encoding: .utf8)) ?? "").contains("plugin") { return true }
      }
      if folder.path == home { break }
      folder = folder.deletingLastPathComponent()
    }
    return false
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
      switch formatter.input {
      case .standardInput:
        return try Self.run(
          executable, arguments, input: text, directory: directory, environment: environment, timeout: timeout,
          name: formatter.name, successExitCodes: formatter.successExitCodes)
      case .temporaryCopy:
        return try Self.formatCopy(
          text, named: url.lastPathComponent, executable: executable, arguments: arguments, directory: directory,
          environment: environment, timeout: timeout, formatter: formatter)
      }
    }.value
  }

  /// Formats a copy of the text in a temporary folder of its own, by the file's name (rules can depend on it), and
  /// reads it back.
  static func formatCopy(
    _ text: String, named name: String, executable: String, arguments: [String], directory: URL,
    environment: [String: String], timeout: TimeInterval, formatter: FormatterConfiguration
  ) throws -> String {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("code-format-\(UUID().uuidString)")
    let copy = folder.appendingPathComponent(name)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data(text.utf8).write(to: copy)
    } catch {
      throw Failure.failed(formatter: formatter.name, message: error.localizedDescription)
    }
    defer { try? FileManager.default.removeItem(at: folder) }
    _ = try run(
      executable, arguments + [copy.path], input: "", directory: directory, environment: environment,
      timeout: timeout, name: formatter.name, successExitCodes: formatter.successExitCodes)
    guard let data = try? Data(contentsOf: copy) else {
      throw Failure.failed(formatter: formatter.name, message: "no output")
    }
    let formatted = String(decoding: data, as: UTF8.self)
    if formatted.isEmpty && !text.isEmpty {
      throw Failure.failed(formatter: formatter.name, message: "no output")
    }
    return formatted
  }

  /// The first of `names` in the file's folder or a folder above it (up
  /// to the home folder).
  public static func findUpward(_ names: [String], from file: URL) -> URL? {
    guard !names.isEmpty else { return nil }
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
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
    environment: [String: String], timeout: TimeInterval, name: String, successExitCodes: Set<Int32> = [0]
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
      guard successExitCodes.contains(process.terminationStatus) else {
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
    #elseif os(Linux)
      // SwiftUIPortability's ChildProcess: Foundation's Process there can hang when children run side by side.
      let child: ChildProcess
      do {
        child = try ChildProcess(
          executable: URL(fileURLWithPath: executable), arguments: arguments, directory: directory,
          environment: environment, input: true)
      } catch {
        throw Failure.failed(formatter: name, message: error.localizedDescription)
      }
      nonisolated(unsafe) var output = Data()
      nonisolated(unsafe) var errors = Data()
      let reads = DispatchGroup()
      reads.enter()
      DispatchQueue.global().async {
        child.read(.output) { output.append($0) }
        reads.leave()
      }
      reads.enter()
      DispatchQueue.global().async {
        child.read(.error) { errors.append($0) }
        reads.leave()
      }
      DispatchQueue.global().async {
        child.write(Data(input.utf8))
        child.closeInput()
      }
      let done = DispatchSemaphore(value: 0)
      nonisolated(unsafe) var status: Int32 = 0
      DispatchQueue.global().async {
        status = child.waitUntilExit()
        done.signal()
      }
      if done.wait(timeout: .now() + timeout) == .timedOut {
        child.terminate()
        throw Failure.timedOut(formatter: name)
      }
      _ = reads.wait(timeout: .now() + 2)
      guard successExitCodes.contains(status) else {
        let message = String(decoding: errors, as: UTF8.self)
          .split(separator: "\n").filter { !$0.contains("deprecated") }.prefix(3)
          .joined(separator: " ")
        throw Failure.failed(formatter: name, message: message.isEmpty ? "exit code \(status)" : message)
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
