import Foundation
import Testing

@testable import CodeActions

@Suite struct BuildLogParserTests {
  let directory = URL(fileURLWithPath: "/tmp/project")

  func issues(_ lines: [String]) -> [BuildIssue] {
    var parser = BuildLogParser(directory: directory)
    return lines.flatMap { parser.consume($0) }.compactMap {
      if case .issue(let issue) = $0 { return issue }
      return nil
    }
  }

  @Test func swiftAndClangDiagnostics() {
    let found = issues([
      "/tmp/project/Sources/A.swift:12:5: error: cannot find 'x' in scope",
      "Sources/B.swift:3:1: warning: variable 'y' was never used",
      "/tmp/project/Tests/ATests.swift:7: error: -[ATests testA] : XCTAssertEqual failed",
    ])
    #expect(found.count == 3)
    #expect(found[0].severity == .error)
    #expect(found[0].url?.path == "/tmp/project/Sources/A.swift")
    #expect(found[0].line == 12 && found[0].column == 5)
    #expect(found[0].message == "cannot find 'x' in scope")
    #expect(found[1].severity == .warning && found[1].url?.path == "/tmp/project/Sources/B.swift")
    #expect(found[2].line == 7 && found[2].column == nil)
  }

  @Test func rustGoTypeScriptKotlinDart() {
    let found = issues([
      "error[E0425]: cannot find value `x` in this scope",
      "  --> src/main.rs:3:5",
      "./main.go:10:2: undefined: foo",
      "src/a.ts(4,7): error TS2322: Type 'string' is not assignable to type 'number'.",
      "src/b.ts:9:1 - error TS2304: Cannot find name 'q'.",
      "e: file:///tmp/project/src/Main.kt:5:9 Unresolved reference 'z'.",
      "w: file:///tmp/project/src/Main.kt:6:1 Variable 'a' is never used",
      "  error - lib/a.dart:2:3 - Undefined name 'b'. - undefined_identifier",
      "/tmp/project/Program.cs(8,13): error CS0103: The name 'c' does not exist [/tmp/project/p.csproj]",
    ])
    #expect(found.count == 8)
    #expect(found[0].url?.path == "/tmp/project/src/main.rs" && found[0].line == 3)
    #expect(found[0].message == "cannot find value `x` in this scope")
    #expect(found[1].url?.path == "/tmp/project/main.go" && found[1].message == "undefined: foo")
    #expect(found[2].line == 4 && found[2].column == 7 && found[2].severity == .error)
    #expect(found[3].url?.lastPathComponent == "b.ts")
    #expect(found[4].url?.path == "/tmp/project/src/Main.kt" && found[4].severity == .error)
    #expect(found[5].severity == .warning)
    #expect(found[6].url?.lastPathComponent == "a.dart" && found[6].message == "Undefined name 'b'.")
    #expect(found[7].message == "The name 'c' does not exist")
  }

  @Test func pythonTraceback() {
    let found = issues([
      "Traceback (most recent call last):",
      "  File \"/tmp/project/app.py\", line 4, in <module>",
      "    main()",
      "  File \"/usr/lib/python3/x.py\", line 9, in main",
      "ZeroDivisionError: division by zero",
    ])
    #expect(found.count == 1)
    #expect(found[0].url?.path == "/tmp/project/app.py" && found[0].line == 4)
    #expect(found[0].message == "ZeroDivisionError: division by zero")
  }

  @Test func progress() {
    #expect(
      BuildLogParser.progress(in: "[12/40] Compiling CodeKit A.swift")
        == ActionProgress(fraction: 0.3, message: "Compiling CodeKit A.swift"))
    #expect(BuildLogParser.progress(in: "    Building [=====>    ] 5/10: serde")?.fraction == 0.5)
    #expect(BuildLogParser.progress(in: "> Task :app:compileDebugKotlin")?.message == "Task :app:compileDebugKotlin")
    #expect(BuildLogParser.progress(in: "hello") == nil)
  }

  @Test func stripsEscapes() {
    #expect(ANSI.strip("\u{1B}[1;31merror:\u{1B}[0m x") == "error: x")
    #expect(ANSI.strip("\u{1B}]8;;https://x\u{1B}\\link") == "\\link")
  }
}

@Suite struct DetectorTests {
  func folder(_ files: [String: String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodeActions-\(UUID().uuidString)")
    for (path, text) in files {
      let file = url.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: file, atomically: true, encoding: .utf8)
    }
    return url
  }

  @Test func swiftPackageExecutables() throws {
    let url = try folder([
      "Package.swift": """
      let package = Package(name: "Tool", targets: [
        .executableTarget(name: "tool"), .target(name: "Core"), .testTarget(name: "CoreTests"),
      ])
      """
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    let schemes = ProjectScanner.scan(root: url)
    #expect(schemes.map(\.name) == ["tool"])
    #expect(schemes[0].commands[.run] == "swift run tool")
    #expect(schemes[0].executable == ".build/debug/tool")
  }

  @Test func nestedProjectsAndCargoWorkspace() throws {
    let url = try folder([
      "rs/Cargo.toml": "[workspace]\nmembers = [\n  \"crates/app\",\n  \"crates/lib\",\n]\n",
      "rs/crates/app/Cargo.toml": "[package]\nname = \"app\"\n",
      "rs/crates/app/src/main.rs": "fn main() {}",
      "rs/crates/lib/Cargo.toml": "[package]\nname = \"lib\"\n",
      "go/go.mod": "module example.com/x/server\n",
      "go/main.go": "package main\nfunc main() {}\n",
      "go/cmd/cli/main.go": "package main\n",
      "web/package.json": #"{"name": "web", "scripts": {"dev": "vite", "build": "vite build", "seed": "x"}}"#,
      "web/bun.lock": "",
      "kt/settings.gradle.kts": "include(\":app\")\n",
      "kt/gradlew": "",
      "kt/app/build.gradle.kts":
        "plugins { id(\"com.android.application\") }\nandroid { defaultConfig { applicationId = \"com.example.app\" } }",
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    let schemes = ProjectScanner.scan(root: url)
    let byName = Dictionary(schemes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    #expect(byName["app"]?.toolchain == .android || byName["app"]?.toolchain == .cargo)
    let cargo = schemes.first { $0.toolchain == .cargo }
    #expect(cargo?.commands[.run] == "cargo run -p app --bin app")
    #expect(byName["server"]?.commands[.run] == "go run .")
    #expect(byName["cli"]?.commands[.run] == "go run ./cmd/cli")
    #expect(byName["web"]?.commands[.run] == "bun run dev")
    #expect(byName["web"]?.commands[.build] == "bun run build")
    #expect(byName["web › seed"]?.commands[.run] == "bun run seed")
    let android = schemes.first { $0.toolchain == .android }
    #expect(android?.androidApplicationID == "com.example.app")
    #expect(android?.commands[.run] == "./gradlew :app:installDebug --console=plain")
    #expect(android?.platforms == [.android])
  }

  @Test func xcodeProductFromBuildSettings() {
    let json = """
      [{"target": "Code", "buildSettings": {"PRODUCT_TYPE": "com.apple.product-type.application",
        "TARGET_BUILD_DIR": "/b/Debug", "FULL_PRODUCT_NAME": "Code.app",
        "EXECUTABLE_PATH": "Code.app/Contents/MacOS/Code", "PRODUCT_BUNDLE_IDENTIFIER": "dev.code"}}]
      """
    let product = XcodeProduct.parse(json, scheme: "Code")
    #expect(product?.executablePath == "/b/Debug/Code.app/Contents/MacOS/Code")
    #expect(product?.wrapperPath == "/b/Debug/Code.app")
    #expect(product?.bundleIdentifier == "dev.code")
  }

  @Test func adbDevices() {
    let devices = DestinationProvider.parseADBDevices(
      """
      List of devices attached
      R5CX10ABC  device usb:1-1 product:x model:SM_X910 device:gts transport_id:2
      emulator-5554  offline transport_id:3

      """)
    #expect(devices.count == 2)
    #expect(devices[0].name == "SM X910" && devices[0].kind == .androidDevice)
    #expect(devices[1].kind == .androidEmulator && !devices[1].isAvailable)
  }
}

#if os(macOS)
  @Suite struct PTYProcessTests {
    @Test func streamsLinesAndExitStatus() async throws {
      let process = try PTYProcess(
        command: "echo one; printf 'two\\r\\n'; [ -t 1 ] && echo tty; exit 3",
        directory: FileManager.default.temporaryDirectory,
        environment: ProcessInfo.processInfo.environment)
      let lines = LockedLines()
      let status = await process.run { lines.add($0) }
      #expect(status == 3)
      #expect(lines.texts == ["one", "two", "tty"])
    }

    @Test func stopEndsTheProcessGroup() async throws {
      let process = try PTYProcess(
        command: "sleep 30 & sleep 30; echo never",
        directory: FileManager.default.temporaryDirectory,
        environment: ProcessInfo.processInfo.environment)
      Task {
        try? await Task.sleep(for: .milliseconds(200))
        process.stop()
      }
      let start = Date()
      let lines = LockedLines()
      let status = await process.run { lines.add($0) }
      #expect(status != 0)
      #expect(Date().timeIntervalSince(start) < 5)
      #expect(!lines.texts.contains("never"))
    }
  }

  final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: PTYProcess.Line) {
      if !line.isTransient { lock.withLock { lines.append(line.text) } }
    }
    var texts: [String] { lock.withLock { lines } }
  }
#endif

@Suite struct XcodeCompilationDatabaseTests {
  let settings = """
    {"App": {
      "/p/App/A.swift": {"swiftASTCommandArguments": ["-module-name", "App", "/p/App/A.swift", "/p/App/B c.swift",
        "-target", "x86_64-apple-macos14.0", "-I/d/Objects-normal/x86_64", "-D", "X86_64_ONLY"]},
      "/p/App/B c.swift": {"swiftASTCommandArguments": ["-module-name", "App"]},
      "/p/App/Assets.xcassets": {"LanguageDialect": "other"}
    }}
    """

  @Test func entriesShareATargetsResponseFile() throws {
    let made = try #require(
      XcodeCompilationDatabase.make(
        fromIndexSettings: Data(settings.utf8), directory: URL(fileURLWithPath: "/cache"),
        workingDirectory: URL(fileURLWithPath: "/p"), architecture: "arm64"))
    let entries = try #require(try JSONSerialization.jsonObject(with: made.database) as? [[String: Any]])
    #expect(entries.map { $0["file"] as? String } == ["/p/App/A.swift", "/p/App/B c.swift"])
    let name = try #require(made.responseFiles.keys.first)
    #expect(made.responseFiles.count == 1 && name.hasPrefix("App-") && name.hasSuffix(".resp"))
    #expect(entries.allSatisfy { $0["arguments"] as? [String] == ["swiftc", "@/cache/" + name] })
    #expect(entries.allSatisfy { $0["directory"] as? String == "/p" })
    let lines = try #require(made.responseFiles[name]).split(separator: "\n")
    #expect(lines.contains("\"/p/App/B c.swift\""))
    // The Debug build's architecture, not the one xcodebuild happened to name.
    #expect(lines.contains("arm64-apple-macos14.0"))
    #expect(lines.contains("-I/d/Objects-normal/arm64"))
    #expect(lines.contains("X86_64_ONLY"))
  }

  @Test func quoting() {
    #expect(XcodeCompilationDatabase.quoted("-Onone") == "-Onone")
    #expect(XcodeCompilationDatabase.quoted("a b") == "\"a b\"")
    #expect(XcodeCompilationDatabase.quoted("say \"hi\"\\") == "\"say \\\"hi\\\"\\\\\"")
  }
}
