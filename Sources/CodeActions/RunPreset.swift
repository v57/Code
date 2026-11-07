import Foundation

/// One click for a run done often: an action (Run, Test or Build) with the toolbar's four choices, From (the build
/// source), Project (the workspace, project or package), Scheme and Target (the destination). It runs with its own
/// choices and leaves the toolbar as it is (`ActionController.perform(preset:)`).
///
/// Kept on this Mac in the project's `.dev/actions.json` (`RunPresetFile`), or in the vault for the user's other
/// devices (the app's `VaultProjectPreset`). Every part is a name, so the file reads well and survives a clone:
/// `from` is "local" for whoever opens the project, else a machine as Hub or SSH calls it.
public struct RunPreset: Hashable, Codable, Sendable {
  public var name: String
  public var action: ActionKind
  /// "local", or a machine's name (`BuildSource.name`).
  public var from: String
  /// The container's file name ("Git-Local.xcworkspace", "Package.swift"); "" when the folder has none.
  public var project: String
  public var scheme: String
  /// The destination's name ("My Mac", "v57 iPhone").
  public var target: String

  public static let local = "local"
  /// The actions a preset can be: those of the Run button.
  public static let actions: [ActionKind] = [.run, .test, .build]

  public init(name: String, action: ActionKind, from: String, project: String, scheme: String, target: String) {
    self.name = name
    self.action = action
    self.from = from
    self.project = project
    self.scheme = scheme
    self.target = target
  }

  public var isLocal: Bool { from == Self.local || from.isEmpty }

  /// What the source is called in a sentence: "This Mac", or the machine.
  public var fromName: String { isLocal ? BuildSource.localName : from }

  /// The four parts as a tooltip says them: "This Mac › Git-Local › Git › v57 iPhone" (no project when it has none).
  public var parts: String {
    [fromName, (project as NSString).deletingPathExtension, scheme, target].filter { !$0.isEmpty }
      .joined(separator: " › ")
  }

  /// The name a preset gets until the user types one: the action and the scheme, then only what isn't usual: "on" the
  /// device ("for" one a build is for), "from" the machine, "in" the project when the folder has several and it isn't
  /// the one used by default. "Run Git", "Run Git on v57 iPhone", "Build Git for Any iOS Device",
  /// "Run Git from studio-mac", "Run Git in Git.xcodeproj".
  ///
  /// The usual target is this computer; one built on another machine runs there, so that machine isn't said twice.
  public static func autoName(
    action: ActionKind, scheme: String, from: String, target: String, project: String, defaultProject: String?
  ) -> String {
    var words = [action.title, scheme].filter { !$0.isEmpty }
    let local = from == Self.local || from.isEmpty
    if !target.isEmpty, target != RunDestination.localName, target != BuildSource.localName, target != from {
      words.append((action == .build ? "for " : "on ") + target)
    }
    if !local { words.append("from " + from) }
    if !project.isEmpty, let defaultProject, project != defaultProject { words.append("in " + project) }
    return words.joined(separator: " ")
  }
}

/// `.dev/actions.json` in a project: the presets kept on this Mac, a file that can be committed and edited by hand.
///
/// ```json
/// {
///   "version": 1,
///   "presets": [
///     { "name": "Run Git", "action": "run", "from": "local", "project": "Git-Local.xcworkspace", "scheme": "Git", "target": "My Mac" }
///   ]
/// }
/// ```
public enum RunPresetFile {
  public static let version = 1
  public static let folder = ".dev"
  public static let fileName = "actions.json"

  /// Where a project keeps it.
  public static func url(in root: URL) -> URL {
    root.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(fileName)
  }

  /// The project's file name as the Save Preset popover shows it: "Git/.dev/actions.json".
  public static func displayPath(in root: URL) -> String {
    "\(root.lastPathComponent)/\(folder)/\(fileName)"
  }

  public enum ReadError: Error, Equatable {
    /// Not JSON, or not this shape.
    case malformed(String)
    /// Written by a newer Code.
    case newerVersion(Int)
  }

  /// The presets in the file's text. A preset whose action this Code doesn't know is left out; a missing field is "".
  public static func decode(_ data: Data) throws -> [RunPreset] {
    guard let object = try? JSONSerialization.jsonObject(with: data), let top = object as? [String: Any] else {
      throw ReadError.malformed("It isn’t a JSON object.")
    }
    let version = (top["version"] as? NSNumber)?.intValue ?? version
    guard version <= Self.version else { throw ReadError.newerVersion(version) }
    guard let list = top["presets"] as? [Any] else { return [] }
    return list.compactMap { item -> RunPreset? in
      guard let fields = item as? [String: Any],
        let action = (fields["action"] as? String).flatMap({ ActionKind(rawValue: $0.lowercased()) })
      else { return nil }
      func text(_ key: String) -> String { (fields[key] as? String) ?? "" }
      let scheme = text("scheme")
      let from = text("from").isEmpty ? RunPreset.local : text("from")
      let name = text("name").isEmpty
        ? RunPreset.autoName(
          action: action, scheme: scheme, from: from, target: text("target"), project: text("project"), defaultProject: nil)
        : text("name")
      return RunPreset(
        name: name, action: action, from: from, project: text("project"), scheme: scheme, target: text("target"))
    }
  }

  /// The file's text: two-space indents and the fields in the order people read them (name, action, from, project,
  /// scheme, target), so a hand edit and a save look alike.
  public static func encode(_ presets: [RunPreset]) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    func quoted(_ text: String) -> String {
      (try? encoder.encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
    var lines = ["{", "  \"version\": \(version),"]
    if presets.isEmpty {
      lines.append("  \"presets\": []")
    } else {
      lines.append("  \"presets\": [")
      for (index, preset) in presets.enumerated() {
        let fields = [
          ("name", preset.name), ("action", preset.action.rawValue), ("from", preset.from),
          ("project", preset.project), ("scheme", preset.scheme), ("target", preset.target),
        ]
        lines.append("    {")
        lines.append(fields.map { "      \(quoted($0.0)): \(quoted($0.1))" }.joined(separator: ",\n"))
        lines.append("    }" + (index == presets.count - 1 ? "" : ","))
      }
      lines.append("  ]")
    }
    lines.append("}")
    return Data((lines.joined(separator: "\n") + "\n").utf8)
  }

  /// The project's presets; none when it has no file.
  public static func read(in root: URL) throws -> [RunPreset] {
    let url = url(in: root)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try decode(Data(contentsOf: url))
  }

  /// Writes the project's presets, making `.dev` when needed. With none left, the file goes, and `.dev` with it when
  /// it was all that folder held.
  public static func write(_ presets: [RunPreset], in root: URL) throws {
    let url = url(in: root)
    let folder = url.deletingLastPathComponent()
    if presets.isEmpty {
      try? FileManager.default.removeItem(at: url)
      if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
        try? FileManager.default.removeItem(at: folder)
      }
      return
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try encode(presets).write(to: url, options: .atomic)
  }
}
