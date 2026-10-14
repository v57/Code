import Foundation

/// A Node/Bun package: a scheme for the package (`dev` or `start`, else its
/// entry file) and one per other runnable script. The package manager is the
/// one its lockfile names.
public struct NodeDetector: ProjectDetector {
  public init() {}

  /// Scripts that aren't schemes of their own: lifecycle, checks, builds.
  static let ignoredScripts: [String] = [
    "prepare", "install", "postinstall", "build", "test", "lint", "format", "check", "preview",
    "typecheck", "clean", "docs", "release", "publish", "dev", "start", "coverage", "bench",
  ]

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    guard folder.hasFile("package.json"), let data = folder.read("package.json")?.data(using: .utf8),
      let package = try? JSONDecoder().decode(Package.self, from: data)
    else { return [] }
    let manager = Self.manager(folder)
    let run = manager == "npm" ? "npm run" : "\(manager) run"
    let scripts = package.scripts ?? [:]
    let typeScript = folder.hasFile("tsconfig.json")
    var commands: [ActionKind: String] = [:]
    if scripts["build"] != nil {
      commands[.build] = "\(run) build"
    } else if typeScript {
      commands[.build] = manager == "bun" ? "bunx tsc --noEmit -p ." : "npx tsc --noEmit -p ."
    } else {
      commands[.build] = "\(manager) install"
    }
    if scripts["test"] != nil {
      commands[.test] = "\(run) test"
    } else if manager == "bun" {
      commands[.test] = "bun test"
    }
    if scripts["lint"] != nil { commands[.lint] = "\(run) lint" }
    if scripts["dev"] != nil {
      commands[.run] = "\(run) dev"
    } else if scripts["start"] != nil {
      commands[.run] = "\(run) start"
    } else if let entry = package.module ?? package.main {
      commands[.run] = (manager == "bun" ? "bun " : "node ") + shellQuote(entry)
    }
    var schemes = [
      ActionScheme(
        name: package.name ?? folder.name, toolchain: .node, directory: folder.url,
        commands: commands)
    ]
    // Other scripts become schemes of their own, unless there are many
    // (a benchmark matrix): then they stay out of the scheme menu.
    let extra = scripts.keys.sorted().filter { name in
      !Self.ignoredScripts.contains { name == $0 || name.hasPrefix($0 + ":") || name.hasPrefix($0 + "-") }
    }
    for name in extra where extra.count <= 6 {
      var scriptCommands = commands
      scriptCommands[.run] = "\(run) \(shellQuote(name))"
      schemes.append(
        ActionScheme(
          name: "\(package.name ?? folder.name) › \(name)", toolchain: .node,
          directory: folder.url, commands: scriptCommands))
    }
    return schemes
  }

  struct Package: Decodable {
    let name: String?
    let main: String?
    let module: String?
    let scripts: [String: String]?
  }

  static func manager(_ folder: ProjectFolder) -> String {
    if folder.hasFile("bun.lock") || folder.hasFile("bun.lockb") { return "bun" }
    if folder.hasFile("pnpm-lock.yaml") { return "pnpm" }
    if folder.hasFile("yarn.lock") { return "yarn" }
    if folder.hasFile("package-lock.json") { return "npm" }
    return ShellEnvironment.shared.which("bun") != nil ? "bun" : "npm"
  }
}

/// A Python project (`pyproject.toml` or `requirements.txt`): a scheme per
/// `[project.scripts]` entry, or for its main module.
public struct PythonDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    guard folder.hasFile("pyproject.toml") || folder.hasFile("requirements.txt") else { return [] }
    let manifest = folder.read("pyproject.toml") ?? ""
    let prefix: String
    if folder.hasFile("uv.lock") || (!manifest.isEmpty && ShellEnvironment.shared.which("uv") != nil) {
      prefix = "uv run "
    } else if folder.hasFile("poetry.lock") {
      prefix = "poetry run "
    } else {
      prefix = ""
    }
    let python = prefix.isEmpty ? "python3" : prefix + "python"
    var common: [ActionKind: String] = [
      .build: "\(python) -m compileall -q -x '/(\\.venv|node_modules|build)/' .",
      .test: "\(python) -m pytest",
    ]
    // Ruff, when the project uses it or it's installed.
    if manifest.contains("ruff") {
      common[.lint] = prefix + "ruff check"
    } else if ShellEnvironment.shared.which("ruff") != nil {
      common[.lint] = "ruff check"
    }
    let parsed = Self.parse(manifest)
    var schemes: [ActionScheme] = []
    for script in parsed.scripts {
      var commands = common
      commands[.run] = prefix.isEmpty ? script : prefix + script
      schemes.append(
        ActionScheme(name: script, toolchain: .python, directory: folder.url, commands: commands))
    }
    if schemes.isEmpty {
      var commands = common
      if let main = ["main.py", "app.py", "manage.py", "__main__.py"].first(where: folder.hasFile) {
        commands[.run] = "\(python) \(main)"
      } else if let name = parsed.name?.replacingOccurrences(of: "-", with: "_"),
        FileManager.default.fileExists(
          atPath: folder.url.appendingPathComponent("src/\(name)/__main__.py").path)
      {
        commands[.run] = "\(python) -m \(name)"
      }
      schemes.append(
        ActionScheme(
          name: parsed.name ?? folder.name, toolchain: .python, directory: folder.url,
          commands: commands))
    }
    return schemes
  }

  static func parse(_ source: String) -> (name: String?, scripts: [String]) {
    var name: String?
    var scripts: [String] = []
    var section = ""
    for line in source.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        section = String(trimmed.dropFirst().dropLast())
        continue
      }
      guard let eq = trimmed.firstIndex(of: "=") else { continue }
      let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
      switch section {
      case "project", "tool.poetry":
        if key == "name", name == nil {
          name = matches(of: #""([^"]+)""#, in: String(trimmed[eq...])).first?[0]
        }
      case "project.scripts", "tool.poetry.scripts":
        let script = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if !script.isEmpty, !scripts.contains(script) { scripts.append(script) }
      default: break
      }
    }
    return (name, scripts)
  }
}

/// A Dart or Flutter package.
public struct DartDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    guard folder.hasFile("pubspec.yaml"), let pubspec = folder.read("pubspec.yaml") else { return [] }
    let name = matches(of: #"(?m)^name:\s*(\S+)"#, in: pubspec).first?[0] ?? folder.name
    var commands: [ActionKind: String]
    if pubspec.contains("sdk: flutter") {
      commands = [
        .build: "flutter analyze", .test: "flutter test", .run: "flutter run -d macos",
        .clean: "flutter clean",
      ]
    } else {
      commands = [.build: "dart analyze", .test: "dart test"]
      if folder.hasDirectory("bin") { commands[.run] = "dart run" }
    }
    return [ActionScheme(name: name, toolchain: .dart, directory: folder.url, commands: commands)]
  }
}

/// A .NET solution or project: a scheme per executable project.
public struct DotnetDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    let solution =
      folder.first(withSuffix: ".slnx") ?? folder.first(withSuffix: ".sln")
      ?? folder.first(withSuffix: ".csproj") ?? folder.first(withSuffix: ".fsproj")
    guard let solution else { return [] }
    let common: [ActionKind: String] = [
      .build: "dotnet build \(shellQuote(solution))", .test: "dotnet test \(shellQuote(solution))",
      .clean: "dotnet clean \(shellQuote(solution))",
    ]
    var schemes: [ActionScheme] = []
    for project in Self.projects(in: folder.url) {
      guard let text = try? String(contentsOf: project, encoding: .utf8),
        text.contains("<OutputType>Exe</OutputType>")
      else { continue }
      let relative = String(project.path.dropFirst(folder.url.path.count + 1))
      var commands = common
      commands[.run] = "dotnet run --project \(shellQuote(relative))"
      schemes.append(
        ActionScheme(
          name: project.deletingPathExtension().lastPathComponent, toolchain: .dotnet,
          directory: folder.url, commands: commands))
    }
    if schemes.isEmpty {
      schemes.append(
        ActionScheme(
          name: (solution as NSString).deletingPathExtension, toolchain: .dotnet,
          directory: folder.url, commands: common))
    }
    return schemes
  }

  /// Project files up to three levels down.
  static func projects(in root: URL) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }
    var projects: [URL] = []
    for case let url as URL in enumerator {
      if enumerator.level > 3 || ["bin", "obj", "node_modules"].contains(url.lastPathComponent) {
        enumerator.skipDescendants()
        continue
      }
      if url.pathExtension == "csproj" || url.pathExtension == "fsproj" { projects.append(url) }
    }
    return projects.sorted { $0.path < $1.path }
  }
}

/// An Elixir Mix project.
public struct ElixirDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    guard folder.hasFile("mix.exs"), let mix = folder.read("mix.exs") else { return [] }
    var commands: [ActionKind: String] = [
      .build: "mix compile", .test: "mix test", .clean: "mix clean",
    ]
    if mix.contains("mod:") { commands[.run] = "mix run --no-halt" }
    let name = matches(of: #"app:\s*:([A-Za-z0-9_]+)"#, in: mix).first?[0] ?? folder.name
    return [ActionScheme(name: name, toolchain: .elixir, directory: folder.url, commands: commands)]
  }
}

/// A Ruby project with a Gemfile.
public struct RubyDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    guard folder.hasFile("Gemfile") else { return [] }
    var commands: [ActionKind: String] = [.build: "bundle install"]
    if folder.read("Gemfile")?.contains("rubocop") == true { commands[.lint] = "bundle exec rubocop" }
    if folder.hasDirectory("spec") {
      commands[.test] = "bundle exec rspec"
    } else if folder.hasDirectory("test") {
      commands[.test] = "bundle exec rake test"
    }
    if let main = ["main.rb", "app.rb", "config.ru"].first(where: folder.hasFile) {
      commands[.run] = main == "config.ru" ? "bundle exec rackup" : "bundle exec ruby \(main)"
    }
    return [ActionScheme(name: folder.name, toolchain: .ruby, directory: folder.url, commands: commands)]
  }
}

/// A PHP Composer project.
public struct PHPDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    guard folder.hasFile("composer.json") else { return [] }
    let composer = folder.read("composer.json") ?? ""
    var commands: [ActionKind: String] = [.build: "composer install"]
    if composer.contains("\"test\"") {
      commands[.test] = "composer test"
    } else if folder.hasFile("phpunit.xml") || folder.hasFile("phpunit.xml.dist") {
      commands[.test] = "vendor/bin/phpunit"
    }
    if FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("public/index.php").path) {
      commands[.run] = "php -S localhost:8000 -t public"
    }
    return [ActionScheme(name: folder.name, toolchain: .php, directory: folder.url, commands: commands)]
  }
}
