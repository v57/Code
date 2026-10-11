import Foundation

/// An Xcode project or workspace: one scheme per Xcode scheme, from
/// `xcodebuild -list -json`. Runs on this Mac, iOS simulators and devices,
/// depending on the platforms the project builds for.
public struct XcodeDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    // A workspace wins over the project it contains.
    guard
      let container = folder.first(withSuffix: ".xcworkspace")
        ?? folder.first(withSuffix: ".xcodeproj")
    else { return [] }
    let url = folder.url.appendingPathComponent(container)
    guard let json = Self.list(url), let names = Self.parseSchemes(json), !names.isEmpty else {
      return []
    }
    let platforms = Self.platforms(of: folder)
    let flag = container.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
    return names.map { name in
      let base = "xcodebuild \(flag) \(shellQuote(container)) -scheme \(shellQuote(name))"
      return ActionScheme(
        name: name, toolchain: .xcode, directory: folder.url,
        commands: [
          .build: base + " build", .test: base + " test", .run: base + " build",
          .clean: base + " clean",
        ],
        platforms: platforms, xcodeContainer: container)
    }
  }

  /// The platforms in the project's build settings (its SDKROOT and
  /// SUPPORTED_PLATFORMS values).
  static func platforms(of folder: ProjectFolder) -> [Platform] {
    var text = ""
    for entry in folder.entries where entry.name.hasSuffix(".xcodeproj") {
      text += folder.read(entry.name + "/project.pbxproj") ?? ""
    }
    var platforms: [Platform] = []
    if text.contains("macosx") || text.isEmpty { platforms.append(.mac) }
    if text.contains("iphoneos") { platforms.append(.iOS) }
    return platforms.isEmpty ? [.mac] : platforms
  }

  /// Schemes from `xcodebuild -list -json`: the workspace's or project's
  /// schemes, else the project's targets.
  static func parseSchemes(_ json: String) -> [String]? {
    struct Payload: Decodable {
      struct Container: Decodable {
        let schemes: [String]?
        let targets: [String]?
      }
      let workspace: Container?
      let project: Container?
    }
    guard let data = json.data(using: .utf8),
      let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else { return nil }
    if let schemes = payload.workspace?.schemes, !schemes.isEmpty { return schemes }
    if let schemes = payload.project?.schemes, !schemes.isEmpty { return schemes }
    return payload.project?.targets
  }

  static func list(_ container: URL) -> String? {
    let flag = container.pathExtension == "xcworkspace" ? "-workspace" : "-project"
    return SubprocessCapture.run(
      "/usr/bin/xcrun", ["xcodebuild", "-list", "-json", flag, container.path],
      directory: container.deletingLastPathComponent(), timeout: 30)
  }
}

/// A Swift package: a scheme per executable product, or one for the whole
/// package when it has none.
public struct SwiftPackageDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    guard folder.hasFile("Package.swift"), let manifest = folder.read("Package.swift") else {
      return []
    }
    let executables = Self.executableTargets(in: manifest)
    let common: [ActionKind: String] = [
      .build: "swift build", .test: "swift test", .clean: "swift package clean",
    ]
    if executables.isEmpty {
      return [ActionScheme(name: folder.name, toolchain: .swiftPM, directory: folder.url, commands: common)]
    }
    return executables.map { name in
      var commands = common
      commands[.build] = "swift build --product \(shellQuote(name))"
      commands[.run] = "swift run \(shellQuote(name))"
      return ActionScheme(
        name: name, toolchain: .swiftPM, directory: folder.url, commands: commands,
        executable: ".build/debug/\(name)")
    }
  }

  /// `.executableTarget(name: "x")` and `.executable(name: "x")` names.
  static func executableTargets(in manifest: String) -> [String] {
    var names: [String] = []
    for groups in matches(
      of: #"\.(?:executableTarget|executable)\s*\(\s*name:\s*"([^"]+)""#, in: manifest)
    where !names.contains(groups[0]) {
      names.append(groups[0])
    }
    return names
  }
}
