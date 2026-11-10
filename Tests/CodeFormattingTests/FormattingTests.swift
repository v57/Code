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
}
