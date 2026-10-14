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
    return Self.ranked(names, in: folder).map { name in
      let base = "xcodebuild \(flag) \(shellQuote(container)) -scheme \(shellQuote(name))"
      var commands: [ActionKind: String] = [
        .build: base + " build", .test: base + " test", .run: base + " build",
        .clean: base + " clean",
      ]
      commands.merge(Self.distributionCommands(base, scheme: name, mac: platforms.contains(.mac))) { $1 }
      return ActionScheme(
        name: name, toolchain: .xcode, directory: folder.url, commands: commands,
        platforms: platforms, xcodeContainer: container)
    }
  }

  /// Install, Export and Upload to App Store, each archiving into
  /// build/<scheme> first. Install and Export are for Mac apps and pin the
  /// macOS destination: a multiplatform target archives for iOS without it.
  /// They use the archive team's Developer ID Application identity when the
  /// keychain has one (checked when the action runs, so a new certificate
  /// needs no rescan): Install then installs that export, so other Macs open
  /// it, and Export notarizes it with the notarytool keychain profile in
  /// `NOTARY_PROFILE` ("notary" when unset), staples it and zips it into
  /// build/<scheme>/Export.
  static func distributionCommands(_ base: String, scheme: String, mac: Bool) -> [ActionKind: String] {
    let folder = "build/\(scheme)"
    let archive = shellQuote("\(folder)/\(scheme).xcarchive")
    var commands: [ActionKind: String] = [
      .upload:
        "\(base) -archivePath \(archive) archive -allowProvisioningUpdates && echo '{\"method\":\"app-store-connect\"}' | plutil -convert xml1 -o \(shellQuote("\(folder)/AppStore.plist")) - && xcodebuild -exportArchive -archivePath \(archive) -exportOptionsPlist \(shellQuote("\(folder)/AppStore.plist")) -exportPath \(shellQuote("\(folder)/Upload")) -allowProvisioningUpdates"
    ]
    guard mac else { return commands }
    let archiveMac = "\(base) -destination 'generic/platform=macOS' -archivePath \(archive) archive"
    let developerID = shellQuote("\(folder)/DeveloperID")
    let developerIDApp = shellQuote("\(folder)/DeveloperID/\(scheme).app")
    let hasDeveloperID =
      "security find-identity -v -p codesigning | grep -q \"Developer ID Application: .*($(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:Team' \(shellQuote("\(folder)/\(scheme).xcarchive/Info.plist"))))\""
    let exportDeveloperID =
      "echo '{\"method\":\"developer-id\"}' | plutil -convert xml1 -o \(shellQuote("\(folder)/DeveloperID.plist")) - && rm -rf \(developerID) && xcodebuild -exportArchive -archivePath \(archive) -exportOptionsPlist \(shellQuote("\(folder)/DeveloperID.plist")) -exportPath \(developerID) -allowProvisioningUpdates"
    let installed = shellQuote("/Applications/\(scheme).app")
    let archived = shellQuote("\(folder)/\(scheme).xcarchive/Products/Applications/\(scheme).app")
    commands[.install] =
      "\(archiveMac) && if \(hasDeveloperID); then \(exportDeveloperID) && rm -rf \(installed) && ditto \(developerIDApp) \(installed); else rm -rf \(installed) && ditto \(archived) \(installed); fi"
    let exportFolder = shellQuote("\(folder)/Export")
    let notarizeZip = shellQuote("\(folder)/Export/notarize.zip")
    let zip = shellQuote("\(folder)/Export/\(scheme).zip")
    let notarize =
      "rm -rf \(exportFolder) && mkdir -p \(exportFolder) && ditto -c -k --keepParent \(developerIDApp) \(notarizeZip) && xcrun notarytool submit \(notarizeZip) --keychain-profile \"${NOTARY_PROFILE:-\(Notarization.defaultProfile)}\" --wait && xcrun stapler staple \(developerIDApp) && rm \(notarizeZip) && ditto -c -k --keepParent \(developerIDApp) \(zip) && open -R \(zip)"
    commands[.export] =
      "\(archiveMac) && if \(hasDeveloperID); then \(exportDeveloperID) && \(notarize); else echo 'Export needs a Developer ID Application certificate for the archive team in the keychain.' && false; fi"
    return commands
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

  /// `names` with the folder's own app schemes first, then its other project
  /// schemes, then the rest (a workspace's package schemes), each group in
  /// `xcodebuild`'s order: the first is the main scheme, as Xcode picks it.
  static func ranked(_ names: [String], in folder: ProjectFolder) -> [String] {
    var apps = Set<String>()
    var own = Set<String>()
    for entry in folder.entries
    where entry.name.hasSuffix(".xcodeproj") || entry.name.hasSuffix(".xcworkspace") {
      let container = folder.url.appendingPathComponent(entry.name)
      for (name, buildsApp) in schemeFiles(in: container) {
        own.insert(name)
        if buildsApp { apps.insert(name) }
      }
      // Without scheme files, Xcode makes one per target, named after it.
      for (name, isApp) in targets(in: folder.read(entry.name + "/project.pbxproj") ?? "") {
        own.insert(name)
        if isApp { apps.insert(name) }
      }
    }
    func rank(_ name: String) -> Int { apps.contains(name) ? 0 : own.contains(name) ? 1 : 2 }
    return names.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
      .map(\.element)
  }

  /// The shared and user `.xcscheme` files of a project or workspace, with
  /// whether each builds an app.
  static func schemeFiles(in container: URL) -> [(String, Bool)] {
    let files = FileManager.default
    var folders = [container.appendingPathComponent("xcshareddata/xcschemes")]
    let users = container.appendingPathComponent("xcuserdata")
    for user in (try? files.contentsOfDirectory(atPath: users.path)) ?? [] {
      folders.append(users.appendingPathComponent(user).appendingPathComponent("xcschemes"))
    }
    return folders.flatMap { folder in
      ((try? files.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".xcscheme") }
        .map { file in
          let text = (try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)) ?? ""
          // Its Run action launches an app.
          let launch = text.range(of: "<LaunchAction").map { text[$0.lowerBound...] } ?? ""
          let runnable = launch.range(of: "</LaunchAction>").map { launch[..<$0.lowerBound] } ?? launch
          return (String(file.dropLast(".xcscheme".count)), runnable.contains(#".app""#))
        }
    }
  }

  /// The native targets in a `project.pbxproj`, with whether each is an app.
  static func targets(in pbxproj: String) -> [(String, Bool)] {
    matches(
      of: #"isa = PBXNativeTarget;[^}]*?\bname = "?([^";]+)"?;[^}]*?productType = "([^"]+)""#,
      in: pbxproj
    ).map { ($0[0], $0[1] == "com.apple.product-type.application") }
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
