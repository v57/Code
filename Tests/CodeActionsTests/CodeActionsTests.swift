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

  let xcodebuildLog = [
    "note: Target dependency graph (2 targets)",
    "SwiftCompile normal arm64 Compiling\\ A.swift /tmp/project/A.swift (in target 'Kit' from project 'P')",
    "    cd /tmp/project",
    "WriteAuxiliaryFile /tmp/x.json (in target 'Kit' from project 'P' at path '/tmp/project/P.xcodeproj')",
    "Ld /tmp/build/App normal (in target 'App' from project 'P')",
    "Test Case '-[KitTests.ATests testAdds]' passed (0.001 seconds).",
    "Test case 'BTests/subtracts()' failed on 'My Mac - App (1)' (0.002 seconds)",
    "✔ Test \"Adds numbers\" passed after 0.001 seconds.",
    "✔ Test run with 3 tests in 1 suite passed after 0.003 seconds.",
  ]

  @Test func countsXcodebuildTasksAndTests() {
    var parser = BuildLogParser(directory: directory)
    let events = xcodebuildLog.flatMap { parser.consume($0) }
    let units = events.compactMap { if case .unit(let unit) = $0 { return unit } else { return nil } }
    #expect(units == [.task, .task, .task, .test, .test, .test])
    let messages = events.compactMap { if case .progress(let progress) = $0 { return progress.message } else { return nil } }
    #expect(messages == [
      "Compiling A.swift", "Building Kit", "Linking App",
      "Testing testAdds", "Testing BTests/subtracts()", "Testing \"Adds numbers\"",
    ])
  }

  @Test func countsSwiftPMSteps() {
    var parser = BuildLogParser(directory: directory)
    #expect(
      parser.consume("[12/40] Compiling CodeKit A.swift")
        == [.count(done: 12, total: 40), .progress(ActionProgress(message: "Compiling CodeKit A.swift"))])
    #expect(parser.consume("[23\u{2009}/\u{2009}31] ProgTest") == [
      .count(done: 23, total: 31), .progress(ActionProgress(message: "Building ProgTest")),
    ])
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

  @Test func dockerComposeAndLint() throws {
    let url = try folder([
      "compose/compose.yaml": "services: {}\n",
      "rs/Cargo.toml": "[package]\nname = \"rs\"\n",
      "go/go.mod": "module example.com/go\n",
      "web/package.json": #"{"name": "web", "scripts": {"lint": "eslint ."}}"#,
      "web/package-lock.json": "{}",
      "rb/Gemfile": "gem 'rubocop'\n",
      "py/pyproject.toml": "[project]\nname = \"py\"\n[tool.ruff]\n",
      "py/uv.lock": "",
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    let schemes = ProjectScanner.scan(root: url)
    let byFolder = Dictionary(schemes.map { ($0.directory.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
    #expect(byFolder["compose"]?.toolchain == .docker)
    #expect(byFolder["compose"]?.commands[.run] == "docker compose up")
    #expect(byFolder["compose"]?.commands[.clean] == "docker compose down")
    #expect(byFolder["rs"]?.commands[.lint] == "cargo clippy")
    #expect(byFolder["go"]?.commands[.lint] == "go vet ./...")
    #expect(byFolder["web"]?.commands[.lint] == "npm run lint")
    #expect(byFolder["rb"]?.commands[.lint] == "bundle exec rubocop")
    #expect(byFolder["py"]?.commands[.lint] == "uv run ruff check")
  }

  @Test func xcodeDistribution() {
    let base = "xcodebuild -project App.xcodeproj -scheme App"
    let mac = XcodeDetector.distributionCommands(base, scheme: "App", mac: true)
    #expect(Set(mac.keys) == [.install, .export, .upload])
    #expect(mac[.install]?.contains("-destination 'generic/platform=macOS'") == true)
    #expect(mac[.install]?.hasPrefix("installed=\"$HOME\"/Applications/App.app; if [ ! -e \"$installed\" ]; then installed=/Applications/App.app; fi; ") == true)
    #expect(mac[.install]?.contains("ditto build/App/DeveloperID/App.app \"$installed\"") == true)
    #expect(mac[.export]?.contains("--keychain-profile \"${NOTARY_PROFILE:-notary}\"") == true)
    #expect(mac[.upload]?.contains(#"{"method":"app-store-connect"}"#) == true)
    #expect(Set(XcodeDetector.distributionCommands(base, scheme: "App", mac: false).keys) == [.upload])
    #expect(ActionKind.allCases.filter(\.isDistribution) == [.install, .export, .upload])
    #expect(ActionKind.allCases.filter(\.needsNotarization) == [.export])
  }

  @Test func xcodeMainSchemeFirst() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let schemes = root.appendingPathComponent("App.xcodeproj/xcshareddata/xcschemes")
    try FileManager.default.createDirectory(at: schemes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("App-Local.xcworkspace"), withIntermediateDirectories: true)
    let launch =
      #"<LaunchAction><BuildableProductRunnable><BuildableReference BuildableName = "App.app"/></BuildableProductRunnable></LaunchAction>"#
    try "<TestAction/>\(launch)".write(
      to: schemes.appendingPathComponent("App.xcscheme"), atomically: true, encoding: .utf8)
    // A test scheme's launch action names the app it runs in, but runs nothing.
    try #"""
      <TestAction><Testables><TestableReference><BuildableReference BuildableName = "AppTests.xctest"/></TestableReference></Testables></TestAction>
      <LaunchAction><MacroExpansion><BuildableReference BuildableName = "App.app"/></MacroExpansion></LaunchAction>
      """#.write(to: schemes.appendingPathComponent("AppTests.xcscheme"), atomically: true, encoding: .utf8)
    try """
      1 /* Helper */ = {
        isa = PBXNativeTarget;
        name = Helper;
        productType = "com.apple.product-type.application";
      };
      2 /* AppKitExtras */ = {
        isa = PBXNativeTarget;
        name = AppKitExtras;
        productType = "com.apple.product-type.framework";
      };
      """.write(
        to: root.appendingPathComponent("App.xcodeproj/project.pbxproj"), atomically: true,
        encoding: .utf8)
    let folder = ProjectFolder(listing: root)
    #expect(
      XcodeDetector.ranked(["AppKitExtras", "AppTests", "BSONTests", "Helper", "App"], in: folder)
        == ["Helper", "App", "AppKitExtras", "AppTests", "BSONTests"])
  }

  @Test func xcodeProducts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = FileManager.default
    let app = root.appendingPathComponent("App")
    try files.createDirectory(at: app.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
    try files.createDirectory(at: app.appendingPathComponent("App-Local.xcworkspace"), withIntermediateDirectories: true)
    try """
      1 /* App */ = {
        isa = PBXNativeTarget;
        name = App;
        productType = "com.apple.product-type.application";
      };
      2 /* tool */ = {
        isa = PBXNativeTarget;
        name = tool;
        productType = "com.apple.product-type.tool";
      };
      3 /* AppUITests */ = {
        isa = PBXNativeTarget;
        name = AppUITests;
        productType = "com.apple.product-type.bundle.ui-testing";
      };
      4 /* XCLocalSwiftPackageReference "." */ = {
        isa = XCLocalSwiftPackageReference;
        relativePath = .;
      };
      """.write(to: app.appendingPathComponent("App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
    try """
      .executableTarget(name: "app-cli"),
      .testTarget(name: "AppKitTests"),
      """.write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    // A sibling package the workspace lists, with an executable product.
    let kit = root.appendingPathComponent("Kit")
    try files.createDirectory(at: kit, withIntermediateDirectories: true)
    try #"products: [.executable(name: "kit-tool", targets: ["KitTool"]), .library(name: "Kit", targets: ["Kit"])], .testTarget(name: "KitTests")"#
      .write(to: kit.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    try #"<Workspace><FileRef location = "group:App.xcodeproj"></FileRef><FileRef location = "group:../Kit"></FileRef></Workspace>"#
      .write(
        to: app.appendingPathComponent("App-Local.xcworkspace/contents.xcworkspacedata"), atomically: true,
        encoding: .utf8)
    let products = XcodeDetector.products(in: ProjectFolder(listing: app))
    #expect(products["App"] == .app)
    #expect(products["tool"] == .tool)
    #expect(products["app-cli"] == .tool)
    #expect(products["kit-tool"] == .tool)
    #expect(products["AppUITests"] == .tests)
    #expect(products["AppKitTests"] == .tests)
    #expect(products["KitTests"] == .tests)
    #expect(products["Kit"] == nil)

    let library = #"<BuildAction><BuildActionEntry buildForRunning = "YES"><BuildableReference BuildableName = "Kit"/></BuildActionEntry></BuildAction><TestAction></TestAction><LaunchAction/>"#
    #expect(XcodeDetector.product(ofScheme: library) == .library)
    let tool = #"<LaunchAction><BuildableProductRunnable><BuildableReference BuildableName = "kit-tool"/></BuildableProductRunnable></LaunchAction>"#
    #expect(XcodeDetector.product(ofScheme: tool) == .tool)
    let tests = #"<BuildAction><BuildActionEntry buildForRunning = "NO"/></BuildAction><TestAction><Testables><TestableReference/></Testables></TestAction>"#
    #expect(XcodeDetector.product(ofScheme: tests) == .tests)
  }

  @Test func xcodeDropsDependencySchemes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = FileManager.default
    let app = root.appendingPathComponent("App")
    let schemes = app.appendingPathComponent("App.xcodeproj/xcshareddata/xcschemes")
    try files.createDirectory(at: schemes, withIntermediateDirectories: true)
    try "<LaunchAction/>".write(
      to: schemes.appendingPathComponent("App Release.xcscheme"), atomically: true, encoding: .utf8)
    try files.createDirectory(at: app.appendingPathComponent("App-Local.xcworkspace"), withIntermediateDirectories: true)
    try """
      1 /* App */ = {
        isa = PBXNativeTarget;
        name = App;
        productType = "com.apple.product-type.application";
      };
      2 /* XCLocalSwiftPackageReference "Packages/AppCore" */ = {
        isa = XCLocalSwiftPackageReference;
        relativePath = Packages/AppCore;
      };
      3 /* XCLocalSwiftPackageReference "../Kit" */ = {
        isa = XCLocalSwiftPackageReference;
        relativePath = ../Kit;
      };
      """.write(to: app.appendingPathComponent("App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
    // The folder's own package, and a local package inside it.
    try #"let package = Package(name: "App", products: [.library(name: "AppKit", targets: ["AppKit"])], targets: [.target(name: "AppKit"), .testTarget(name: "AppKitTests")])"#
      .write(to: app.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    let core = app.appendingPathComponent("Packages/AppCore")
    try files.createDirectory(at: core, withIntermediateDirectories: true)
    try #"let package = Package(name: "AppCore", products: [.library(name: "AppCore", targets: ["AppCore"])])"#
      .write(to: core.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    // Sibling packages the project and workspace use: dependencies.
    for (name, product) in [("Kit", "Kit"), ("Store", "StoreKitPlus")] {
      let package = root.appendingPathComponent(name)
      try files.createDirectory(
        at: package.appendingPathComponent(".swiftpm/xcode/xcshareddata/xcschemes"), withIntermediateDirectories: true)
      try #"let package = Package(name: "\#(name)", products: [.library(name: "\#(product)", targets: ["\#(product)"])], targets: [.testTarget(name: "\#(name)Tests")])"#
        .write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
      try "<LaunchAction/>".write(
        to: package.appendingPathComponent(".swiftpm/xcode/xcshareddata/xcschemes/\(name)Wire.xcscheme"),
        atomically: true, encoding: .utf8)
    }
    try #"<Workspace><FileRef location = "group:App.xcodeproj"></FileRef><FileRef location = "group:../Kit"></FileRef><FileRef location = "group:../Store"></FileRef></Workspace>"#
      .write(
        to: app.appendingPathComponent("App-Local.xcworkspace/contents.xcworkspacedata"), atomically: true,
        encoding: .utf8)
    let folder = ProjectFolder(listing: app)
    // As `xcodebuild -list` reports them; Remote is a remote package's.
    let listed = [
      "App", "App Release", "App-Package", "AppCore", "AppKit", "Kit", "KitTests", "KitWire", "Remote",
      "StoreKitPlus", "StoreWire",
    ]
    #expect(
      XcodeDetector.own(listed, in: folder) == ["App", "App Release", "App-Package", "AppCore", "AppKit"])
    // With nothing of its own found, it keeps them all.
    #expect(XcodeDetector.own(["Kit", "Remote"], in: folder) == ["Kit", "Remote"])
  }

  @Test func terminalCommands() {
    let directory = URL(fileURLWithPath: "/tmp/App")
    let mac = ActionScheme(
      name: "App", toolchain: .xcode, directory: directory,
      commands: [.build: "xcodebuild -project App.xcodeproj -scheme App build", .run: "build"],
      platforms: [.mac, .iOS], xcodeContainer: "App.xcodeproj")
    #expect(mac.terminalCommand(for: .build) == mac.commands[.build])
    let run = mac.terminalCommand(for: .run) ?? ""
    #expect(
      run.hasPrefix(
        "xcodebuild -project App.xcodeproj -scheme App -destination 'platform=macOS' -derivedDataPath build build && "))
    #expect(run.contains("app=build/Build/Products/Debug/App.app;"))
    var phone = mac
    phone.platforms = [.iOS]
    #expect(phone.terminalCommand(for: .run) == nil)
    var library = mac
    library.commands[.run] = nil
    #expect(library.terminalCommand(for: .run) == nil)
    let android = ActionScheme(
      name: "app", toolchain: .android, directory: directory,
      commands: [.run: "./gradlew installDebug --console=plain"], platforms: [.android],
      androidApplicationID: "com.example.app")
    #expect(
      android.terminalCommand(for: .run)
        == "./gradlew installDebug --console=plain && adb shell monkey -p com.example.app -c android.intent.category.LAUNCHER 1 >/dev/null"
    )
    let tool = ActionScheme(
      name: "tool", toolchain: .swiftPM, directory: directory, commands: [.run: "swift run tool"])
    #expect(tool.terminalCommand(for: .run) == "swift run tool")
    #expect(tool.terminalCommand(for: .test) == nil)
  }

  @Test func folderSchemesAndFingerprint() throws {
    let url = try folder(["go.mod": "module example.com/x\n", "sub/Cargo.toml": "[package]\nname = \"sub\"\n"])
    defer { try? FileManager.default.removeItem(at: url) }
    let folder = ProjectFolder(listing: url)
    #expect(ProjectScanner.schemes(in: folder).map(\.toolchain) == [.go])
    let fingerprint = ProjectScanner.fingerprint(of: folder)
    let reordered = ProjectFolder(url: url, entries: folder.entries.reversed())
    #expect(ProjectScanner.fingerprint(of: reordered) == fingerprint)
    try "".write(to: url.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
    #expect(ProjectScanner.fingerprint(of: ProjectFolder(listing: url)) != fingerprint)
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
