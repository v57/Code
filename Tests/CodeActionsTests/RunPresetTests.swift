import Foundation
import Testing

@testable import CodeActions

@Suite struct RunPresetNameTests {
  private func name(
    _ action: ActionKind = .run, _ scheme: String = "Git", from: String = "local", target: String = "My Mac",
    project: String = "Git-Local.xcworkspace", defaultProject: String? = nil
  ) -> String {
    RunPreset.autoName(
      action: action, scheme: scheme, from: from, target: target, project: project, defaultProject: defaultProject)
  }

  @Test func usualPartsAreLeftOut() {
    #expect(name() == "Run Git")
    #expect(name(.test, "GitKit") == "Test GitKit")
    // The default project of a folder with several isn't said.
    #expect(name(defaultProject: "Git-Local.xcworkspace") == "Run Git")
  }

  @Test func saysOnlyWhatIsntUsual() {
    #expect(name(target: "v57 iPhone") == "Run Git on v57 iPhone")
    #expect(name(.build, target: "Any iOS Device") == "Build Git for Any iOS Device")
    #expect(name(from: "studio-mac", target: "studio-mac") == "Run Git from studio-mac")
    #expect(name(from: "studio-mac", target: "iPad Pro") == "Run Git on iPad Pro from studio-mac")
    #expect(
      name(project: "Git.xcodeproj", defaultProject: "Git-Local.xcworkspace") == "Run Git in Git.xcodeproj")
    #expect(
      name(.test, target: "iPhone 17", project: "Git.xcodeproj", defaultProject: "Git-Local.xcworkspace")
        == "Test Git on iPhone 17 in Git.xcodeproj")
  }

  @Test func noTargetOrScheme() {
    #expect(name(target: "") == "Run Git")
    #expect(name(.build, "", target: "") == "Build")
  }

  @Test func partsForTheTooltip() {
    let preset = RunPreset(
      name: "Run Git on v57 iPhone", action: .run, from: "local", project: "Git-Local.xcworkspace", scheme: "Git",
      target: "v57 iPhone")
    #expect(preset.parts == "\(BuildSource.localName) › Git-Local › Git › v57 iPhone")
    var remote = preset
    remote.from = "studio-mac"
    remote.project = ""
    #expect(remote.parts == "studio-mac › Git › v57 iPhone")
  }
}

@Suite struct RunPresetFileTests {
  static let presets = [
    RunPreset(name: "Run Git", action: .run, from: "local", project: "Git-Local.xcworkspace", scheme: "Git", target: "My Mac"),
    RunPreset(
      name: "Test GitKit", action: .test, from: "local", project: "Git-Local.xcworkspace", scheme: "GitKit",
      target: "My Mac"),
    RunPreset(
      name: "Run Git on iPad Pro from studio-mac", action: .run, from: "studio-mac", project: "Git-Local.xcworkspace",
      scheme: "Git", target: "iPad Pro"),
  ]

  @Test func writesTheBoardsShape() {
    let text = String(decoding: RunPresetFile.encode([Self.presets[0]]), as: UTF8.self)
    #expect(
      text == """
        {
          "version": 1,
          "presets": [
            {
              "name": "Run Git",
              "action": "run",
              "from": "local",
              "project": "Git-Local.xcworkspace",
              "scheme": "Git",
              "target": "My Mac"
            }
          ]
        }

        """)
  }

  @Test func roundTrips() throws {
    #expect(try RunPresetFile.decode(RunPresetFile.encode(Self.presets)) == Self.presets)
    #expect(try RunPresetFile.decode(RunPresetFile.encode([])) == [])
    // Quotes, slashes and non-ASCII survive.
    var odd = Self.presets[0]
    odd.name = "Run “Git” / \"quoted\" \\ é"
    #expect(try RunPresetFile.decode(RunPresetFile.encode([odd])) == [odd])
  }

  @Test func readsHandEdits() throws {
    let text = """
      {"presets": [
        {"action": "Test", "scheme": "GitKit", "target": "My Mac"},
        {"name": "Lint it", "action": "lint", "scheme": "Git"},
        {"name": "Future", "action": "deploy", "scheme": "Git"},
        "not a preset"
      ], "comment": "kept by hand"}
      """
    let presets = try RunPresetFile.decode(Data(text.utf8))
    #expect(presets.count == 2)
    // No name: the auto name; no from: this computer.
    #expect(presets[0].name == "Test GitKit")
    #expect(presets[0].action == .test)
    #expect(presets[0].from == RunPreset.local)
    #expect(presets[0].project == "")
    #expect(presets[1].name == "Lint it")
  }

  @Test func rejectsWhatItCantRead() {
    #expect(throws: RunPresetFile.ReadError.self) { try RunPresetFile.decode(Data("[1, 2]".utf8)) }
    #expect(throws: RunPresetFile.ReadError.newerVersion(2)) {
      try RunPresetFile.decode(Data(#"{"version": 2, "presets": []}"#.utf8))
    }
  }

  @Test func writesAndRemovesTheFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("presets-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try RunPresetFile.read(in: root) == [])
    try RunPresetFile.write(Self.presets, in: root)
    #expect(FileManager.default.fileExists(atPath: root.path + "/.dev/actions.json"))
    #expect(try RunPresetFile.read(in: root) == Self.presets)
    // The last one removed: the file goes, and .dev with it when nothing else is there.
    try RunPresetFile.write([], in: root)
    #expect(!FileManager.default.fileExists(atPath: root.path + "/.dev"))
    // .dev with other files stays.
    try RunPresetFile.write(Self.presets, in: root)
    try Data("{}".utf8).write(to: root.appendingPathComponent(".dev/screenshots.json"))
    try RunPresetFile.write([], in: root)
    #expect(FileManager.default.fileExists(atPath: root.path + "/.dev/screenshots.json"))
    #expect(!FileManager.default.fileExists(atPath: root.path + "/.dev/actions.json"))
  }
}
