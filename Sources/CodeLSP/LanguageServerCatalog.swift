import Foundation

/// How to install a language server from its official source. None is
/// bundled with the app: each is a separate download the user starts.
public enum ServerInstall: Equatable, Sendable {
  /// Comes with Xcode or its command-line tools.
  case xcode
  /// A Homebrew formula.
  case brew(String)
  /// An npm package installed globally.
  case npm(String)
  /// A Ruby gem.
  case gem(String)
  /// A .NET global tool.
  case dotnetTool(String)
  /// Comes with the language's own SDK (Dart).
  case sdk(String)

  /// The shell command that installs it, or nil when it comes with
  /// something else.
  public var command: String? {
    switch self {
    case .xcode, .sdk: return nil
    case .brew(let formula): return "brew install \(formula)"
    case .npm(let package): return "npm install -g \(package)"
    case .gem(let gem): return "gem install \(gem)"
    case .dotnetTool(let tool): return "dotnet tool install --global \(tool)"
    }
  }

  public var summary: String {
    switch self {
    case .xcode: return "Included with Xcode"
    case .brew(let formula): return "Homebrew: \(formula)"
    case .npm(let package): return "npm: \(package)"
    case .gem(let gem): return "RubyGems: \(gem)"
    case .dotnetTool(let tool): return ".NET tool: \(tool)"
    case .sdk(let sdk): return "Included with the \(sdk) SDK"
    }
  }
}

/// A language server: the command that starts it, the files it serves and
/// the files that mark a project root for it.
public struct LanguageServerConfiguration: Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  /// The languages, for settings ("Swift", "C, C++, Objective-C").
  public let languages: String
  /// File extensions (lowercase, no dot) and their LSP language IDs.
  public let languageIDs: [String: String]
  public let command: String
  public let arguments: [String]
  /// Files or folders whose presence marks a project root, nearest first.
  public let rootMarkers: [String]
  /// Use the outermost folder with a marker (Cargo and Go workspaces).
  public let prefersOutermostRoot: Bool
  public let install: ServerInstall
  public let initializationOptions: JSONValue

  public init(
    id: String, name: String, languages: String, languageIDs: [String: String], command: String,
    arguments: [String] = [], rootMarkers: [String], prefersOutermostRoot: Bool = false,
    install: ServerInstall, initializationOptions: JSONValue = .null
  ) {
    self.id = id
    self.name = name
    self.languages = languages
    self.languageIDs = languageIDs
    self.command = command
    self.arguments = arguments
    self.rootMarkers = rootMarkers
    self.prefersOutermostRoot = prefersOutermostRoot
    self.install = install
    self.initializationOptions = initializationOptions
  }

  public func languageID(for url: URL) -> String? {
    languageIDs[url.pathExtension.lowercased()]
  }
}

/// The language servers Code knows, one per language.
public enum LanguageServerCatalog {
  public static let all: [LanguageServerConfiguration] = [
    LanguageServerConfiguration(
      id: "sourcekit-lsp", name: "SourceKit-LSP", languages: "Swift",
      languageIDs: ["swift": "swift"], command: "sourcekit-lsp",
      rootMarkers: ["Package.swift", "buildServer.json", ".xcodeproj", ".xcworkspace", "compile_commands.json"],
      install: .xcode),
    LanguageServerConfiguration(
      id: "clangd", name: "clangd", languages: "C, C++, Objective-C",
      languageIDs: [
        "c": "c", "h": "c", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
        "hxx": "cpp", "m": "objective-c", "mm": "objective-cpp",
      ],
      command: "clangd", arguments: ["--background-index", "--header-insertion=never"],
      rootMarkers: ["compile_commands.json", "compile_flags.txt", "CMakeLists.txt", "Makefile", ".clangd"],
      install: .xcode),
    LanguageServerConfiguration(
      id: "gopls", name: "gopls", languages: "Go", languageIDs: ["go": "go"], command: "gopls",
      rootMarkers: ["go.work", "go.mod"], prefersOutermostRoot: false, install: .brew("gopls")),
    LanguageServerConfiguration(
      id: "rust-analyzer", name: "rust-analyzer", languages: "Rust", languageIDs: ["rs": "rust"],
      command: "rust-analyzer", rootMarkers: ["Cargo.toml"], prefersOutermostRoot: true,
      install: .brew("rust-analyzer")),
    LanguageServerConfiguration(
      id: "typescript-language-server", name: "TypeScript Language Server",
      languages: "TypeScript, JavaScript",
      languageIDs: [
        "ts": "typescript", "tsx": "typescriptreact", "mts": "typescript", "cts": "typescript",
        "js": "javascript", "jsx": "javascriptreact", "mjs": "javascript", "cjs": "javascript",
      ],
      command: "typescript-language-server", arguments: ["--stdio"],
      rootMarkers: ["tsconfig.json", "jsconfig.json", "package.json"],
      install: .brew("typescript-language-server")),
    LanguageServerConfiguration(
      id: "pyright", name: "Pyright", languages: "Python", languageIDs: ["py": "python", "pyi": "python"],
      command: "pyright-langserver", arguments: ["--stdio"],
      rootMarkers: ["pyrightconfig.json", "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt"],
      install: .brew("pyright")),
    LanguageServerConfiguration(
      id: "kotlin-language-server", name: "Kotlin Language Server", languages: "Kotlin",
      languageIDs: ["kt": "kotlin", "kts": "kotlin"], command: "kotlin-language-server",
      rootMarkers: ["settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle", "pom.xml"],
      prefersOutermostRoot: true, install: .brew("kotlin-language-server")),
    LanguageServerConfiguration(
      id: "jdtls", name: "Eclipse JDT Language Server", languages: "Java",
      languageIDs: ["java": "java"], command: "jdtls",
      rootMarkers: ["settings.gradle.kts", "settings.gradle", "pom.xml", "build.gradle.kts", "build.gradle"],
      prefersOutermostRoot: true, install: .brew("jdtls")),
    LanguageServerConfiguration(
      id: "dart", name: "Dart Analysis Server", languages: "Dart", languageIDs: ["dart": "dart"],
      command: "dart", arguments: ["language-server", "--protocol=lsp"],
      rootMarkers: ["pubspec.yaml"], install: .sdk("Dart")),
    LanguageServerConfiguration(
      id: "zls", name: "ZLS", languages: "Zig", languageIDs: ["zig": "zig", "zon": "zig"],
      command: "zls", rootMarkers: ["build.zig"], install: .brew("zls")),
    LanguageServerConfiguration(
      id: "elixir-ls", name: "ElixirLS", languages: "Elixir",
      languageIDs: ["ex": "elixir", "exs": "elixir"], command: "elixir-ls",
      rootMarkers: ["mix.exs"], prefersOutermostRoot: true, install: .brew("elixir-ls")),
    LanguageServerConfiguration(
      id: "ruby-lsp", name: "Ruby LSP", languages: "Ruby", languageIDs: ["rb": "ruby"],
      command: "ruby-lsp", rootMarkers: ["Gemfile"], install: .gem("ruby-lsp")),
    LanguageServerConfiguration(
      id: "intelephense", name: "Intelephense", languages: "PHP", languageIDs: ["php": "php"],
      command: "intelephense", arguments: ["--stdio"], rootMarkers: ["composer.json"],
      install: .npm("intelephense")),
    LanguageServerConfiguration(
      id: "csharp-ls", name: "csharp-ls", languages: "C#", languageIDs: ["cs": "csharp"],
      command: "csharp-ls", rootMarkers: [".sln", ".slnx", ".csproj"], prefersOutermostRoot: true,
      install: .dotnetTool("csharp-ls")),
    LanguageServerConfiguration(
      id: "lua-language-server", name: "Lua Language Server", languages: "Lua",
      languageIDs: ["lua": "lua"], command: "lua-language-server", rootMarkers: [".luarc.json"],
      install: .brew("lua-language-server")),
    LanguageServerConfiguration(
      id: "bash-language-server", name: "Bash Language Server", languages: "Shell",
      languageIDs: ["sh": "shellscript", "bash": "shellscript", "zsh": "shellscript"],
      command: "bash-language-server", arguments: ["start"], rootMarkers: [],
      install: .brew("bash-language-server")),
    LanguageServerConfiguration(
      id: "yaml-language-server", name: "YAML Language Server", languages: "YAML",
      languageIDs: ["yaml": "yaml", "yml": "yaml"], command: "yaml-language-server",
      arguments: ["--stdio"], rootMarkers: [], install: .brew("yaml-language-server")),
  ]

  /// Options for starting a server in a project: the TypeScript server
  /// needs a TypeScript install, and a project without its own gets a
  /// global one (npm's, Bun's or Homebrew's).
  public static func initializationOptions(
    for configuration: LanguageServerConfiguration, root: URL, environment: [String: String]
  ) -> JSONValue {
    guard configuration.id == "typescript-language-server" else {
      return configuration.initializationOptions
    }
    let fm = FileManager.default
    var folder = root
    while folder.path.count > 1 {
      if fm.fileExists(atPath: folder.appendingPathComponent("node_modules/typescript/lib/tsserver.js").path) {
        return configuration.initializationOptions
      }
      folder = folder.deletingLastPathComponent()
    }
    let home = fm.homeDirectoryForCurrentUser.path
    let globals = [
      home + "/.local/lib/node_modules", "/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules",
      home + "/.bun/install/global/node_modules", "/opt/homebrew/opt/typescript/libexec/lib/node_modules",
    ] + (environment["NPM_CONFIG_PREFIX"].map { [$0 + "/lib/node_modules"] } ?? [])
    for global in globals {
      let server = global + "/typescript/lib/tsserver.js"
      if fm.fileExists(atPath: server) { return ["tsserver": ["path": .string(server)]] }
    }
    return configuration.initializationOptions
  }

  /// The server for a file, by its extension.
  public static func configuration(for url: URL, in configurations: [LanguageServerConfiguration] = all)
    -> LanguageServerConfiguration?
  {
    configurations.first { $0.languageID(for: url) != nil }
  }

  /// The project root for a file: the nearest (or outermost) folder up to
  /// `workspace` holding one of the server's markers; the workspace folder
  /// when none does.
  public static func root(
    for file: URL, configuration: LanguageServerConfiguration, workspace: URL
  ) -> URL {
    let workspacePath = workspace.standardizedFileURL.path
    var folder = file.standardizedFileURL.deletingLastPathComponent()
    var found: URL?
    while folder.path.hasPrefix(workspacePath) {
      if hasMarker(folder, configuration.rootMarkers) {
        found = folder
        if !configuration.prefersOutermostRoot { break }
      }
      if folder.path == workspacePath { break }
      folder = folder.deletingLastPathComponent()
    }
    return found ?? workspace.standardizedFileURL
  }

  static func hasMarker(_ folder: URL, _ markers: [String]) -> Bool {
    guard !markers.isEmpty else { return false }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return markers.contains { marker in
      // ".xcodeproj" matches any project bundle.
      marker.hasPrefix(".") && marker.count > 1 && !marker.dropFirst().contains(".")
        && ["xcodeproj", "xcworkspace", "sln", "slnx", "csproj"].contains(String(marker.dropFirst()))
        ? names.contains { $0.hasSuffix(marker) }
        : names.contains(marker)
    }
  }
}
