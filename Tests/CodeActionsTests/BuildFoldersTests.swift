import Foundation
import Testing

@testable import CodeActions

@Suite struct BuildFoldersTests {
  let developer: URL
  let folders: BuildFolders

  init() throws {
    developer = FileManager.default.temporaryDirectory
      .appendingPathComponent("BuildFoldersTests-\(UUID().uuidString)/Developer").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
    folders = BuildFolders(developer: developer, leases: developer.appendingPathComponent("leases"))
  }

  func folder(_ path: String, git: String? = nil) throws -> URL {
    let url = developer.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    if let git { try git.write(to: url.appendingPathComponent(".git"), atomically: true, encoding: .utf8) }
    return url
  }

  @Test func noBuildsFolderLeavesSchemesAlone() throws {
    let app = try folder("v57/App")
    let scheme = ActionScheme(name: "tool", toolchain: .swiftPM, directory: app, commands: [.build: "swift build"])
    #expect(folders.instance(.swiftpm, for: app) == nil)
    #expect(scheme.inBuildFolders(folders) == scheme)
  }

  @Test func worktreesShareTheMainCheckoutsInstances() throws {
    try FileManager.default.createDirectory(at: folders.root, withIntermediateDirectories: true)
    let main = try folder("v57/Shell")
    try FileManager.default.createDirectory(
      at: main.appendingPathComponent(".git/worktrees/feature"), withIntermediateDirectories: true)
    try "../..\n".write(
      to: main.appendingPathComponent(".git/worktrees/feature/commondir"), atomically: true, encoding: .utf8)
    let worktree = try folder(
      "v57/Shell/.claude/worktrees/feature", git: "gitdir: \(main.path)/.git/worktrees/feature\n")
    let package = try folder("v57/Shell/.claude/worktrees/feature/Tools/Lint")

    #expect(folders.projectName(worktree, .xcode) == "v57/Shell")
    #expect(folders.projectName(package, .swiftpm) == "v57/Shell/Tools/Lint")
    #expect(folders.projectName(package, .xcode) == "v57/Shell")
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("Elsewhere-\(UUID().uuidString)")
    #expect(folders.projectName(outside, .cargo) == "other/" + outside.lastPathComponent)

    let first = try #require(folders.instance(.xcode, for: worktree))
    #expect(first.path == folders.root.path + "/xcode/v57/Shell/1")
    #expect(folders.instance(.xcode, for: main)?.path == first.path)
  }

  @Test func skipsInstancesAnAgentHolds() throws {
    let app = try folder("v57/App", git: nil)
    try FileManager.default.createDirectory(at: app.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let one = folders.root.appendingPathComponent("swiftpm/v57/App/1")
    try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folders.leases, withIntermediateDirectories: true)
    let lease: [String: Any] = [
      "pid": Int(ProcessInfo.processInfo.processIdentifier), "last_used": Date().timeIntervalSince1970,
    ]
    try JSONSerialization.data(withJSONObject: lease)
      .write(to: folders.leases.appendingPathComponent("swiftpm__v57__App__1.json"))

    let scheme = ActionScheme(
      name: "tool", toolchain: .swiftPM, directory: app,
      commands: [.build: "swift build --product tool", .run: "swift run tool", .clean: "swift package clean"],
      executable: ".build/debug/tool")
    let shared = scheme.inBuildFolders(folders)
    let two = folders.root.appendingPathComponent("swiftpm/v57/App/2").path
    #expect(shared.commands[.build] == "swift build --scratch-path \(two) --product tool")
    #expect(shared.commands[.run] == "swift run --scratch-path \(two) tool")
    #expect(shared.commands[.clean] == "swift package clean --scratch-path \(two)")
    #expect(shared.executableURL?.path == two + "/debug/tool")
    let meta = BuildFolders.readMeta(URL(fileURLWithPath: two))
    #expect(meta["last_dir"] as? String == app.path)

    // A stale lease (its process gone) frees the instance.
    try JSONSerialization.data(withJSONObject: ["pid": 999_999, "last_used": Date().timeIntervalSince1970])
      .write(to: folders.leases.appendingPathComponent("swiftpm__v57__App__1.json"))
    #expect(!folders.isLeased(one, now: Date()))
  }

  @Test func xcodeAndCargoCommands() throws {
    try FileManager.default.createDirectory(at: folders.root, withIntermediateDirectories: true)
    let app = try folder("v57/App")
    let xcode = ActionScheme(
      name: "App", toolchain: .xcode, directory: app,
      commands: [
        .build: "xcodebuild -project App.xcodeproj -scheme App build",
        .export: "xcodebuild -project App.xcodeproj -scheme App archive && xcodebuild -exportArchive -archivePath x",
      ],
      xcodeContainer: "App.xcodeproj"
    ).inBuildFolders(folders)
    let derived = folders.root.path + "/xcode/v57/App/1"
    #expect(xcode.derivedDataPath == derived)
    #expect(xcode.commands[.build] == "xcodebuild -derivedDataPath \(derived) -project App.xcodeproj -scheme App build")
    #expect(
      xcode.commands[.export]
        == "xcodebuild -derivedDataPath \(derived) -project App.xcodeproj -scheme App archive && xcodebuild -exportArchive -archivePath x"
    )
    #expect(xcode.xcodeArguments == "-derivedDataPath \(derived) -project App.xcodeproj -scheme App")

    let cargo = ActionScheme(
      name: "cli", toolchain: .cargo, directory: app,
      commands: [.build: "cargo build -p cli --bin cli", .lint: "cargo clippy"], executable: "target/debug/cli"
    ).inBuildFolders(folders)
    let target = folders.root.path + "/cargo/v57/App/1"
    #expect(cargo.commands[.build] == "cargo build --target-dir \(target) -p cli --bin cli")
    #expect(cargo.commands[.lint] == "cargo clippy --target-dir \(target)")
    #expect(cargo.executable == target + "/debug/cli")
  }
}
