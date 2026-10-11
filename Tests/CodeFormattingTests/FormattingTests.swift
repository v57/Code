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

  @Test func failuresDontReturnText() async throws {
    let service = FormattingService(environment: environment)
    let url = try folder(["go.mod": "module x\n"])
    defer { try? FileManager.default.removeItem(at: url) }
    guard service.executable(for: FormatterCatalog.all.first { $0.id == "gofmt" }!) != nil else { return }
    await #expect(throws: FormattingService.Failure.self) {
      _ = try await service.format("package main\nfunc {", url: url.appendingPathComponent("main.go"))
    }
  }
}
