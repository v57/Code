import Foundation
import Testing

@testable import CodeActions

#if os(macOS)
  /// A folder of fixture projects, removed afterwards.
  final class Fixtures {
    let root: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("AppInstallTests-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func url(_ path: String) -> URL { root.appendingPathComponent(path).standardizedFileURL }

    func write(_ path: String, _ text: String) throws {
      let url = url(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }

    @discardableResult
    func git(_ folder: String, _ arguments: String...) throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
      process.arguments =
        ["-C", url(folder).path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"]
        + arguments
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    func repository(_ folder: String, files: [String: String]) throws {
      for (path, text) in files { try write("\(folder)/\(path)", text) }
      try git(folder, "init", "-q")
      try git(folder, "add", "-A")
      try git(folder, "commit", "-q", "-m", "First")
    }
  }

  @Suite struct LocalDependenciesTests {
    /// App's Local workspace lists its project and two siblings; the project uses a package inside App; Kit's
    /// manifest uses Base by path and a remote package by URL.
    func makeWorkspace(_ fixtures: Fixtures) throws {
      try fixtures.write(
        "App/App-Local.xcworkspace/contents.xcworkspacedata",
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
           <FileRef location = "group:App.xcodeproj"></FileRef>
           <FileRef location = "group:../Kit"></FileRef>
           <FileRef location = "group:../Docs"></FileRef>
        </Workspace>
        """)
      try fixtures.write(
        "App/App.xcodeproj/project.pbxproj",
        """
        AA /* XCLocalSwiftPackageReference "Packages/Local" */ = {
          isa = XCLocalSwiftPackageReference;
          relativePath = Packages/Local;
        };
        BB /* XCLocalSwiftPackageReference "../Tools" */ = {
          isa = XCLocalSwiftPackageReference;
          relativePath = "../Tools";
        };
        """)
      try fixtures.write("App/Packages/Local/Package.swift", "let package = Package(name: \"Local\")")
      try fixtures.write("Tools/Package.swift", "let package = Package(name: \"Tools\")")
      try fixtures.write(
        "Kit/Package.swift",
        """
        let package = Package(
          name: "Kit",
          dependencies: [
            .package(path: "../Base"),
            .package(url: "https://github.com/example/Remote.git", branch: "main"),
          ])
        """)
      try fixtures.write("Base/Package.swift", "let package = Package(name: \"Base\", dependencies: [.package(path: \"../Kit\")])")
      // Listed, but not a package: nothing builds from it.
      try fixtures.write("Docs/README.md", "Docs")
    }

    @Test func aWorkspaceBringsItsPackagesAndTheirLocalDependencies() throws {
      let fixtures = try Fixtures()
      try makeWorkspace(fixtures)
      let folders = LocalDependencies.folders(root: fixtures.url("App"), container: "App-Local.xcworkspace")
      #expect(folders == [fixtures.url("App"), fixtures.url("Tools"), fixtures.url("Kit"), fixtures.url("Base")])
    }

    @Test func aProjectAloneBringsOnlyItsLocalPackages() throws {
      let fixtures = try Fixtures()
      try makeWorkspace(fixtures)
      let folders = LocalDependencies.folders(root: fixtures.url("App"), container: "App.xcodeproj")
      #expect(folders == [fixtures.url("App"), fixtures.url("Tools")])
    }

    @Test func nestedFoldersAreCoveredByTheOuterOne() {
      let urls = ["/a", "/a/b", "/ab", "/c/d", "/c"].map { URL(fileURLWithPath: $0) }
      #expect(LocalDependencies.outermost(urls).map(\.path) == ["/a", "/ab", "/c"])
    }
  }

  @Suite struct SourceFingerprintTests {
    @Test func changesInTheProjectOrADependencyChangeIt() throws {
      let fixtures = try Fixtures()
      try fixtures.repository("App", files: ["main.swift": "print(1)\n", "README.md": "App\n"])
      try fixtures.repository("Kit", files: ["Kit.swift": "let kit = 1\n"])
      let folders = [fixtures.url("App"), fixtures.url("Kit")]
      let clean = SourceFingerprint.of(folders: folders)
      #expect(!clean.isDirty)
      #expect(SourceFingerprint.of(folders: folders) == clean)

      // A touched file that didn't change.
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: fixtures.url("Kit/Kit.swift").path)
      #expect(SourceFingerprint.of(folders: folders) == clean)

      // An edit in the dependency.
      try fixtures.write("Kit/Kit.swift", "let kit = 2\n")
      let edited = SourceFingerprint.of(folders: folders)
      #expect(edited.isDirty)
      #expect(edited.value != clean.value)
      // A second edit of the same file.
      try fixtures.write("Kit/Kit.swift", "let kit = 3\n")
      #expect(SourceFingerprint.of(folders: folders).value != edited.value)

      // Undone, it's the source that was installed again.
      try fixtures.write("Kit/Kit.swift", "let kit = 1\n")
      #expect(SourceFingerprint.of(folders: folders) == clean)

      // A new file in the project.
      try fixtures.write("App/New.swift", "")
      #expect(SourceFingerprint.of(folders: folders).value != clean.value)
    }

    @Test func commitsCountByContent() throws {
      let fixtures = try Fixtures()
      try fixtures.repository("App", files: ["main.swift": "print(1)\n"])
      let folders = [fixtures.url("App")]
      let first = SourceFingerprint.of(folders: folders)
      // A commit that changes nothing keeps it; the commit count still goes up.
      try fixtures.git("App", "commit", "-q", "--allow-empty", "-m", "Nothing")
      #expect(SourceFingerprint.of(folders: folders) == first)
      #expect(SourceFingerprint.commitCount(in: fixtures.url("App")) == 2)
      // A change is one until it's undone, committed or not.
      try fixtures.write("App/main.swift", "print(2)\n")
      let changed = SourceFingerprint.of(folders: folders)
      #expect(changed.isDirty)
      #expect(changed.value != first.value)
      try fixtures.git("App", "commit", "-q", "-am", "Two")
      let committed = SourceFingerprint.of(folders: folders)
      #expect(!committed.isDirty)
      #expect(committed.value == changed.value)
      // A rename too.
      try fixtures.git("App", "mv", "main.swift", "App.swift")
      #expect(SourceFingerprint.of(folders: folders).value != committed.value)
      try fixtures.git("App", "commit", "-q", "-m", "Renamed")
      try fixtures.git("App", "mv", "App.swift", "main.swift")
      #expect(SourceFingerprint.of(folders: folders).value == committed.value)
    }

    @Test func blobIDsAreGits() throws {
      let fixtures = try Fixtures()
      try fixtures.repository("App", files: ["a.txt": "hello\n"])
      let id = try fixtures.git("App", "hash-object", "a.txt").trimmingCharacters(in: .whitespacesAndNewlines)
      #expect(SourceFingerprint.blobID(fixtures.url("App/a.txt")) == id)
      #expect(SourceFingerprint.blobID(fixtures.url("App/missing")) == nil)
    }

    @Test func aFolderInARepositoryIsOnlyItsOwnFiles() throws {
      let fixtures = try Fixtures()
      try fixtures.repository("Repo", files: ["Kit/Kit.swift": "1\n", "Other/Other.swift": "1\n"])
      let kit = [fixtures.url("Repo/Kit")]
      let before = SourceFingerprint.of(folders: kit)
      try fixtures.write("Repo/Other/Other.swift", "2\n")
      try fixtures.git("Repo", "commit", "-q", "-am", "Other")
      #expect(SourceFingerprint.of(folders: kit) == before)
      try fixtures.write("Repo/Kit/Kit.swift", "2\n")
      #expect(SourceFingerprint.of(folders: kit) != before)
    }

    @Test func aFolderOutsideGitIsItsFilesDates() throws {
      let fixtures = try Fixtures()
      try fixtures.write("Plain/a.swift", "1")
      let before = SourceFingerprint.of(folders: [fixtures.url("Plain")])
      #expect(before.isDirty)
      try fixtures.write("Plain/b.swift", "1")
      #expect(SourceFingerprint.of(folders: [fixtures.url("Plain")]) != before)
    }

    @Test func knownPartsCombineAsTheWhole() throws {
      let fixtures = try Fixtures()
      try fixtures.repository("App", files: ["main.swift": "1"])
      try fixtures.repository("Kit", files: ["Kit.swift": "1"])
      let folders = [fixtures.url("App"), fixtures.url("Kit")]
      let parts = folders.map { ($0, SourceFingerprint.folder($0)) }
      #expect(SourceFingerprint.combine(parts, salt: "App") == SourceFingerprint.of(folders: folders, salt: "App"))
    }

    @Test func theSchemeIsPartOfIt() throws {
      let fixtures = try Fixtures()
      try fixtures.repository("App", files: ["main.swift": ""])
      let folders = [fixtures.url("App")]
      #expect(SourceFingerprint.of(folders: folders, salt: "A") != SourceFingerprint.of(folders: folders, salt: "B"))
    }
  }

  @Suite struct InstallStatusTests {
    let app = InstalledApp(
      url: URL(fileURLWithPath: "/Applications/App.app"), identifier: "dev.app", build: "40", stamp: "1:2")
    let source = SourceFingerprint(value: "abc", isDirty: false)

    @Test func anOlderBuildNumberIsOutdatedWithoutTheFingerprint() {
      var computed = false
      let status = InstallStatus.evaluate(installed: app, record: nil, sourceBuild: 41) {
        computed = true
        return source
      }
      #expect(status == .outdated)
      #expect(!computed)
    }

    @Test func theRecordOfThisCopyDecides() {
      let record = InstallRecord(fingerprint: "abc", app: app)
      #expect(InstallStatus.evaluate(installed: app, record: record, sourceBuild: 40) { source } == .current)
      // What was installed, committed since.
      #expect(InstallStatus.evaluate(installed: app, record: record, sourceBuild: 41) { source } == .current)
      let changed = SourceFingerprint(value: "def", isDirty: true)
      #expect(InstallStatus.evaluate(installed: app, record: record, sourceBuild: 40) { changed } == .outdated)
      // Another copy put there since: the record is about the old one.
      var replaced = app
      replaced.stamp = "3:4"
      let dirty = SourceFingerprint(value: "abc", isDirty: true)
      #expect(InstallStatus.evaluate(installed: replaced, record: record, sourceBuild: 40) { dirty } == .outdated)
    }

    @Test func withoutARecordTheBuildNumberDecides() {
      #expect(InstallStatus.evaluate(installed: app, record: nil, sourceBuild: 40) { source } == .current)
      let dirty = SourceFingerprint(value: "abc", isDirty: true)
      #expect(InstallStatus.evaluate(installed: app, record: nil, sourceBuild: 40) { dirty } == .outdated)
      var unnumbered = app
      unnumbered.build = "1.0"
      #expect(InstallStatus.evaluate(installed: unnumbered, record: nil, sourceBuild: 40) { source } == .outdated)
      #expect(InstallStatus.evaluate(installed: nil, record: nil, sourceBuild: 40) { source } == .notInstalled)
    }

    @Test func anInstalledAppIsReadFromItsBundle() throws {
      let fixtures = try Fixtures()
      let plist = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": "dev.app", "CFBundleVersion": "12"], format: .xml, options: 0)
      try fixtures.write("App.app/Contents/Info.plist", String(decoding: plist, as: UTF8.self))
      let installed = try #require(InstalledApp(at: fixtures.url("App.app")))
      #expect(installed.identifier == "dev.app")
      #expect(installed.build == "12")
      #expect(InstalledApp(at: fixtures.url("Missing.app")) == nil)
      // A new copy is another app, even with the same build.
      try FileManager.default.removeItem(at: fixtures.url("App.app"))
      try fixtures.write("App.app/Contents/Info.plist", String(decoding: plist, as: UTF8.self))
      #expect(InstalledApp(at: fixtures.url("App.app"))?.stamp != installed.stamp)
    }
  }

  @Suite struct AppInstallTests {
    let scheme = ActionScheme(
      name: "App", toolchain: .xcode, directory: URL(fileURLWithPath: "/tmp/App"),
      commands: [.install: "true", .build: "true"], xcodeContainer: "App-Local.xcworkspace")

    @Test func installArchivesQuitsReplacesAndOpens() {
      let steps = ActionPlanner.steps(for: .install, scheme: scheme, destination: nil)
      #expect(steps.map(\.title) == ["Archive", "Quit", "Install", "Open"])
    }

    @Test func theBuildIsStampedWithTheCommitCount() {
      let mac = XcodeDetector.distributionCommands("xcodebuild -project App.xcodeproj -scheme App", scheme: "App", mac: true)
      #expect(mac[.install]?.contains("archive CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD 2>/dev/null || echo 1) &&") == true)
    }

    @Test func theExportIsInstalledWhenThereIsOne() throws {
      let fixtures = try Fixtures()
      try fixtures.write("App/build/App/App.xcarchive/Products/Applications/App.app/Contents/Info.plist", "")
      let plan = AppInstall.Plan(
        directory: fixtures.url("App"), archive: "build/App/App.xcarchive", developerID: "build/App/DeveloperID")
      #expect(try plan.paths().0 == fixtures.url("App/build/App/App.xcarchive/Products/Applications/App.app"))
      try fixtures.write("App/build/App/DeveloperID/App.app/Contents/Info.plist", "")
      let (app, destination) = try plan.paths()
      #expect(app == fixtures.url("App/build/App/DeveloperID/App.app"))
      #expect(destination.lastPathComponent == "App.app")
    }

    @Test func lowPriorityCommandsRunClamped() {
      let executor = LowPriorityExecutor()
      #expect(
        executor.wrapped("make && echo 'done'")
          == "exec /usr/sbin/taskpolicy -c utility /usr/bin/nice -n 10 /bin/zsh -c 'make && echo '\\''done'\\'''")
    }

    @Test func lowPriorityCommandsRunAndReportTheirStatus() async throws {
      let command = try LowPriorityExecutor().start(
        "echo $(( $(ps -o nice= -p $$) )); exit 3", directory: URL(fileURLWithPath: "/tmp"), environment: [:])
      let lines = LinesBox()
      let status = await command.run { lines.add($0.text) }
      #expect(status == 3)
      #expect(lines.all.contains("10"), "\(lines.all)")
    }
  }

  final class LinesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
  }
#endif
