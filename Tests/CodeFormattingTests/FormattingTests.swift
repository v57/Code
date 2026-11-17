import Foundation
import Testing

@testable import CodeFormatting

@Suite struct FormattingTests {
  /// The login PATH plus the usual tool folders, as the app uses.
  var environment: [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    environment["PATH"] = [home + "/.local/bin", "/opt/homebrew/bin", environment["PATH"] ?? ""]
      .joined(separator: ":")
    return environment
  }

  func folder(_ files: [String: String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Fmt-\(UUID().uuidString)")
    for (path, text) in files {
      let file = url.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: file, atomically: true, encoding: .utf8)
    }
    return url
  }

  @Test func swiftFormatUsesTheProjectConfig() async throws {
    let service = FormattingService(environment: environment)
    guard let formatter = FormatterCatalog.formatter(for: URL(fileURLWithPath: "/a.swift")),
      service.executable(for: formatter) != nil
    else { return }
    let url = try folder([".swift-format": #"{"version": 1, "indentation": {"spaces": 3}}"#])
    defer { try? FileManager.default.removeItem(at: url) }
    let file = url.appendingPathComponent("Sources/A.swift")
    let formatted = try await service.format("func a( ){\nlet  x=1\n}\n", url: file)
    #expect(formatted == "func a() {\n   let x = 1\n}\n")
  }

  @Test func gofmtAndConfigRequirement() async throws {
    let service = FormattingService(environment: environment)
    let url = try folder(["go.mod": "module x\n"])
    defer { try? FileManager.default.removeItem(at: url) }
    if service.executable(for: FormatterCatalog.all.first { $0.id == "gofmt" }!) != nil {
      let formatted = try await service.format(
        "package main\nfunc main(){\nx:=1\n_=x}\n", url: url.appendingPathComponent("main.go"))
      #expect(formatted == "package main\n\nfunc main() {\n\tx := 1\n\t_ = x\n}\n")
    }
    // Prettier waits for a config file by default.
    #expect(service.formatter(for: url.appendingPathComponent("a.ts")) == nil)
  }

  @Test func prettierWithItsConfig() async throws {
    let service = FormattingService(environment: environment)
    guard service.executable(for: FormatterCatalog.all.first { $0.id == "prettier" }!) != nil else { return }
    let url = try folder([".prettierrc": #"{"semi": false, "singleQuote": true}"#])
    defer { try? FileManager.default.removeItem(at: url) }
    let formatted = try await service.format(
      "const a = {b:\"c\"};\n", url: url.appendingPathComponent("a.ts"))
    #expect(formatted == "const a = { b: 'c' }\n")
  }

  @Test func failuresDontReturnText() async throws {
    let service = FormattingService(environment: environment)
    let url = try folder(["go.mod": "module x\n"])
    defer { try? FileManager.default.removeItem(at: url) }
    guard service.executable(for: FormatterCatalog.all.first { $0.id == "gofmt" }!) != nil else { return }
    await #expect(throws: FormattingService.Failure.self) {
      _ = try await service.format("package main\nfunc {", url: url.appendingPathComponent("main.go"))
    }
  }

  /// Security audit H2: in a folder that isn't trusted, the repository's own `node_modules/.bin/prettier` never runs,
  /// nor a formatter whose config is code.
  @Test func untrustedFolderIgnoresLocalPrettier() throws {
    let url = try folder([".prettierrc": #"{"semi": false}"#, "src/a.js": "let a = 1\n"])
    defer { try? FileManager.default.removeItem(at: url) }
    let local = url.appendingPathComponent("node_modules/.bin/prettier")
    try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\ntouch \"$(dirname \"$0\")/ran\"\ncat\n".utf8).write(to: local)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: local.path)
    let file = url.appendingPathComponent("src/a.js")
    let prettier = FormatterCatalog.all.first { $0.id == "prettier" }!

    var service = FormattingService(environment: environment)
    #expect(service.executable(for: prettier, file: file) != local.path)
    #expect(service.formatter(for: file)?.executable != local.path)
    service.usesProjectCode = true
    #expect(service.executable(for: prettier, file: file) == local.path)

    // Configs that are code: a JavaScript one, one naming plugins, package.json's "prettier" key, `.formatter.exs`.
    #expect(!FormattingService.runsProjectCode(prettier, config: url.appendingPathComponent(".prettierrc"), file: file))
    try #"{"plugins": ["./evil.js"]}"#.write(to: url.appendingPathComponent(".prettierrc"), atomically: true, encoding: .utf8)
    #expect(FormattingService.runsProjectCode(prettier, config: url.appendingPathComponent(".prettierrc"), file: file))
    try #"{"semi": false}"#.write(to: url.appendingPathComponent(".prettierrc"), atomically: true, encoding: .utf8)
    try #"{"devDependencies": {"prettier": "^3"}}"#.write(to: url.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    #expect(!FormattingService.runsProjectCode(prettier, config: nil, file: file))
    try #"{"prettier": "@company/prettier-config"}"#.write(to: url.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    #expect(FormattingService.runsProjectCode(prettier, config: nil, file: file))
    #expect(FormattingService.runsProjectCode(prettier, config: url.appendingPathComponent("prettier.config.js"), file: file))
    let mix = FormatterCatalog.all.first { $0.id == "mix-format" }!
    #expect(FormattingService.runsProjectCode(mix, config: nil, file: url.appendingPathComponent("a.ex")))
    #expect(!FileManager.default.fileExists(atPath: local.deletingLastPathComponent().appendingPathComponent("ran").path))
  }

  /// The entries added on 2026-11-18, one or two per language.
  static let addedIDs = [
    "google-java-format", "csharpier", "dart-format", "pint", "php-cs-fixer", "standardrb", "rubocop", "scalafmt",
    "stylua", "fourmolu", "ormolu", "invoke-formatter", "taplo", "sqlfluff",
  ]

  /// An executable script in `folder`, standing in for a formatter.
  func stub(_ name: String, in folder: URL, _ script: String) throws -> String {
    let url = folder.appendingPathComponent("bin/\(name)")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n\(script)\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
  }

  /// A service where every formatter is "installed" as `cat`, so choosing one doesn't depend on this Mac.
  func everyFormatterInstalled() -> FormattingService {
    var service = FormattingService(environment: ["PATH": "/nonexistent"])
    for formatter in FormatterCatalog.all { service.customCommands[formatter.id] = "/bin/cat" }
    return service
  }

  @Test func addedEntriesAreComplete() throws {
    for id in Self.addedIDs {
      let formatter = try #require(FormatterCatalog.all.first { $0.id == id }, "\(id)")
      #expect(!formatter.extensions.isEmpty, "\(id)")
      #expect(!formatter.command.isEmpty, "\(id)")
      #expect(!formatter.arguments("/tmp/project/a.\(formatter.extensions.sorted()[0])").isEmpty, "\(id)")
      #expect(!formatter.languages.isEmpty, "\(id)")
      #expect(formatter.installCommand?.isEmpty == false, "\(id)")
      #expect(formatter.extensions.allSatisfy { $0 == $0.lowercased() && !$0.hasPrefix(".") }, "\(id)")
      if formatter.requiresConfigByDefault { #expect(!formatter.configFiles.isEmpty, "\(id)") }
    }
    #expect(Set(FormatterCatalog.all.map(\.id)).count == FormatterCatalog.all.count)
  }

  /// Two formatters share an extension only as one language's alternatives, picked by the project's config.
  @Test func extensionsClashOnlyWithinALanguage() {
    var owners: [String: [String]] = [:]
    for formatter in FormatterCatalog.all {
      for ext in formatter.extensions { owners[ext, default: []].append(formatter.id) }
    }
    let shared = owners.filter { $0.value.count > 1 }
    #expect(shared == ["php": ["pint", "php-cs-fixer"], "hs": ["fourmolu", "ormolu"]]
      .merging(RubyFiles.extensions.map { ($0, ["standardrb", "rubocop"]) }) { $1 })
    #expect(owners["kts"] == ["ktlint"])
  }

  /// Without any config file, each language's file gets its formatter (or none where one is needed).
  @Test func eachLanguagePicksItsFormatter() throws {
    let url = try folder(["README": ""])
    defer { try? FileManager.default.removeItem(at: url) }
    let service = everyFormatterInstalled()
    let expected: [String: String] = [
      "Main.java": "google-java-format", "Program.cs": "csharpier", "lib/main.dart": "dart-format",
      "src/Model.php": "php-cs-fixer", "app/user.rb": "standardrb", "Rakefile.rake": "standardrb",
      "x.gemspec": "standardrb", "Main.scala": "nil", "build.sbt": "nil", "init.lua": "stylua",
      "src/Lib.hs": "ormolu", "build.ps1": "invoke-formatter", "Module.psm1": "invoke-formatter",
      "Cargo.toml": "taplo", "query.sql": "nil", "build.gradle.kts": "ktlint", "a.kt": "ktlint",
    ]
    for (path, id) in expected {
      let chosen = service.formatter(for: url.appendingPathComponent(path))?.configuration.id ?? "nil"
      #expect(chosen == id, "\(path)")
    }
  }

  /// The project's config decides between a language's formatters: the nearest one wins, the catalog's order breaks
  /// a tie, and a folder that isn't trusted skips one whose config is code instead of falling back to another.
  @Test func configDecidesBetweenFormatters() throws {
    let url = try folder([
      "laravel/pint.json": "{}", "laravel/app/User.php": "",
      "symfony/.php-cs-fixer.dist.php": "<?php return 1;", "symfony/src/Kernel.php": "",
      "both/.standard.yml": "", "both/.rubocop.yml": "", "both/a.rb": "",
      "std/.standard.yml": "", "std/engine/.rubocop.yml": "", "std/engine/b.rb": "", "std/c.rb": "",
      "hs/fourmolu.yaml": "indentation: 2", "hs/src/A.hs": "",
      "scala/.scalafmt.conf": "version = 3.8.3", "scala/src/A.scala": "",
      "sql/.sqlfluff": "[sqlfluff]\ndialect = postgres", "sql/q.sql": "",
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    var service = everyFormatterInstalled()
    func chosen(_ path: String) -> String? { service.formatter(for: url.appendingPathComponent(path))?.configuration.id }

    service.usesProjectCode = true
    #expect(chosen("laravel/app/User.php") == "pint")
    #expect(chosen("symfony/src/Kernel.php") == "php-cs-fixer")
    #expect(chosen("both/a.rb") == "standardrb")
    #expect(chosen("std/engine/b.rb") == "rubocop")
    #expect(chosen("std/c.rb") == "standardrb")
    #expect(chosen("hs/src/A.hs") == "fourmolu")
    #expect(chosen("scala/src/A.scala") == "scalafmt")
    #expect(chosen("sql/q.sql") == "sqlfluff")

    service.usesProjectCode = false
    #expect(chosen("laravel/app/User.php") == "pint")  // pint.json is data
    #expect(chosen("symfony/src/Kernel.php") == nil)  // PHP
    #expect(chosen("std/engine/b.rb") == nil)  // .rubocop.yml can require Ruby; Standard doesn't stand in
    #expect(chosen("hs/src/A.hs") == "fourmolu")
    #expect(chosen("scala/src/A.scala") == nil)  // downloads and runs the version it names
    #expect(chosen("sql/q.sql") == nil)  // templates the file

    // Turned off, the next formatter for the language takes over.
    service.usesProjectCode = true
    service.disabledIDs = ["pint"]
    #expect(chosen("laravel/app/User.php") == "php-cs-fixer")
  }

  @Test func argumentsFindConfigsAboveTheFile() throws {
    let url = try folder([
      "p/.php-cs-fixer.php": "", "p/pint.json": "", "p/.scalafmt.conf": "", "p/PSScriptAnalyzerSettings.psd1": "@{}",
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    func arguments(_ id: String, _ path: String) -> [String] {
      FormatterCatalog.all.first { $0.id == id }!.arguments(url.appendingPathComponent(path).path)
    }
    let root = url.appendingPathComponent("p").standardizedFileURL.path
    #expect(arguments("php-cs-fixer", "p/src/A.php").contains("--config=\(root)/.php-cs-fixer.php"))
    #expect(arguments("pint", "p/app/A.php").contains("--config=\(root)/pint.json"))
    #expect(arguments("pint", "p/app/A.php").prefix(1) == ["-"])
    let scala = arguments("scalafmt", "p/src/A.scala")
    #expect(scala.firstIndex(of: "--config").map { scala[$0 + 1] } == "\(root)/.scalafmt.conf")
    #expect(!arguments("php-cs-fixer", "elsewhere/A.php").contains { $0.hasPrefix("--config") })
    #expect(arguments("invoke-formatter", "p/build.ps1").last?.contains("-Settings '\(root)/PSScriptAnalyzerSettings.psd1'") == true)
    #expect(PowerShellFormatter.script(settings: "/a/it's.psd1").contains("-Settings '/a/it''s.psd1'"))
    #expect(!PowerShellFormatter.script(settings: nil).contains("-Settings"))
  }

  /// PHP-CS-Fixer can't answer on standard output: it fixes a copy with the file's name, read back.
  @Test func temporaryCopyIsFormattedInPlace() async throws {
    #if os(macOS) || os(Linux)
      let url = try folder(["src/Model.php": "<?php echo 1;"])
      defer { try? FileManager.default.removeItem(at: url) }
      var service = FormattingService(environment: ["PATH": "/nonexistent"])
      service.customCommands["php-cs-fixer"] = try stub(
        "php-cs-fixer", in: url, #"for last; do :; done; printf '%s fixed\n' "${last##*/}" > "$last""#)
      let formatted = try await service.format("<?php echo 1;", url: url.appendingPathComponent("src/Model.php"))
      #expect(formatted == "Model.php fixed\n")
      #expect(service.formatter(for: url.appendingPathComponent("src/Model.php"))?.configuration.input == .temporaryCopy)
    #endif
  }

  /// SQLFluff's exit 1 still carries the formatted text; 2 is a failure.
  @Test func successExitCodes() async throws {
    #if os(macOS) || os(Linux)
      let url = try folder([".sqlfluff": "[sqlfluff]\ndialect = ansi"])
      defer { try? FileManager.default.removeItem(at: url) }
      var service = FormattingService(environment: ["PATH": "/nonexistent"])
      service.usesProjectCode = true
      service.customCommands["sqlfluff"] = try stub("sqlfluff", in: url, "echo 'SELECT 1'; exit 1")
      #expect(try await service.format("select 1", url: url.appendingPathComponent("q.sql")) == "SELECT 1\n")
      service.customCommands["sqlfluff"] = try stub("sqlfluff2", in: url, "echo 'no dialect' >&2; exit 2")
      await #expect(throws: FormattingService.Failure.self) {
        _ = try await service.format("select 1", url: url.appendingPathComponent("q.sql"))
      }
    #endif
  }
}
