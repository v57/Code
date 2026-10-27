import Foundation

/// An Xcode project or workspace: one scheme per Xcode scheme of its own,
/// from `xcodebuild -list -json` (not its packages'). Runs on this Mac, iOS simulators and devices,
/// depending on the platforms its target builds for (the project's when the
/// target doesn't set them). A scheme gets the
/// actions its product has: an app all of them, a command-line tool Run but
/// no distribution, a library or framework Build, Test and Clean, and a
/// test bundle Test and Clean.
public struct XcodeDetector: ProjectDetector {
  public init() {}

  /// What a scheme builds; a larger one wins when two places name a scheme.
  enum Product: Int, Comparable {
    case library, tests, tool, app

    static func < (lhs: Product, rhs: Product) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    // A workspace wins over the project it contains.
    guard
      let container = folder.first(withSuffix: ".xcworkspace")
        ?? folder.first(withSuffix: ".xcodeproj")
    else { return [] }
    let url = folder.url.appendingPathComponent(container)
    guard let listed = Self.schemeNames(url, in: folder), !listed.isEmpty else { return [] }
    let names = Self.own(listed, in: folder)
    let platforms = Self.platforms(of: folder)
    let schemePlatforms = Self.schemePlatforms(in: folder)
    let products = Self.products(in: folder)
    let flag = container.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
    return Self.ranked(names, in: folder).map { name in
      let base = "xcodebuild \(flag) \(shellQuote(container)) -scheme \(shellQuote(name))"
      // A scheme found nowhere is a remote package's, a library; so is a
      // package's that has a project scheme's name.
      let plain = Self.plainName(name)
      let product = plain.package ? .library : products[plain.name] ?? .library
      let builtFor = product == .tool ? [.mac] : (plain.package ? nil : schemePlatforms[plain.name]) ?? platforms
      var commands: [ActionKind: String] = [.test: base + " test", .clean: base + " clean"]
      if product != .tests { commands[.build] = base + " build" }
      if product >= .tool { commands[.run] = base + " build" }
      if product == .app {
        commands.merge(Self.distributionCommands(base, scheme: plain.name, mac: builtFor.contains(.mac))) { $1 }
      }
      return ActionScheme(
        name: name, toolchain: .xcode, directory: folder.url, commands: commands,
        platforms: builtFor, xcodeContainer: container)
    }
  }

  /// The products of the schemes Xcode lists for the folder: its projects'
  /// scheme files and targets, the projects and packages its workspace
  /// lists, and the local packages its projects use (their executables and
  /// test targets; their other schemes build libraries).
  static func products(in folder: ProjectFolder) -> [String: Product] {
    var products: [String: Product] = [:]
    var visited = Set<String>()
    func add(_ found: [(String, Product)]) {
      for (name, product) in found { products[name] = max(products[name] ?? product, product) }
    }
    func addPackage(_ url: URL) {
      guard visited.insert(url.standardizedFileURL.path).inserted,
        let manifest = try? String(contentsOf: url.appendingPathComponent("Package.swift"), encoding: .utf8)
      else { return }
      add(SwiftPackageDetector.executableTargets(in: manifest).map { ($0, .tool) })
      add(matches(of: #"\.testTarget\s*\(\s*name:\s*"([^"]+)""#, in: manifest).map { ($0[0], .tests) })
      add(schemeFiles(in: url.appendingPathComponent(".swiftpm/xcode")))
    }
    func addProject(_ url: URL) {
      guard visited.insert(url.standardizedFileURL.path).inserted else { return }
      add(schemeFiles(in: url))
      let pbxproj = (try? String(contentsOf: url.appendingPathComponent("project.pbxproj"), encoding: .utf8)) ?? ""
      add(targets(in: pbxproj))
      let packages = matches(
        of: #"isa = XCLocalSwiftPackageReference;[^}]*?relativePath = "?([^";]+)"?;"#, in: pbxproj)
      for groups in packages { addPackage(url.deletingLastPathComponent().appendingPathComponent(groups[0])) }
    }
    addPackage(folder.url)
    for entry in folder.entries {
      let url = folder.url.appendingPathComponent(entry.name)
      if entry.name.hasSuffix(".xcodeproj") { addProject(url) }
      guard entry.name.hasSuffix(".xcworkspace") else { continue }
      add(schemeFiles(in: url))
      let contents = folder.read(entry.name + "/contents.xcworkspacedata") ?? ""
      for groups in matches(of: #"location = "(group|container|absolute):([^"]+)""#, in: contents) {
        let referenced =
          groups[0] == "absolute"
          ? URL(fileURLWithPath: groups[1]) : folder.url.appendingPathComponent(groups[1])
        if referenced.pathExtension == "xcodeproj" { addProject(referenced) } else { addPackage(referenced) }
      }
    }
    return products
  }

  /// The name a scheme has in its project or package, and whether it's a
  /// package's: `xcodebuild -list` tells two schemes of the same name apart
  /// as "Name (Project project)" and "Name (Package)".
  static func plainName(_ name: String) -> (name: String, package: Bool) {
    guard let groups = matches(of: #"^(.+) \(([^()]+)\)$"#, in: name).first else { return (name, false) }
    return (groups[0], !groups[1].hasSuffix(" project"))
  }

  /// `names` without the schemes of the folder's dependencies, which
  /// `xcodebuild -list` reports for a project or workspace that uses
  /// packages; all of them when none is the folder's own.
  static func own(_ names: [String], in folder: ProjectFolder) -> [String] {
    let own = ownSchemes(in: folder)
    let kept = names.filter { own.contains($0) || own.contains(plainName($0).name) }
    return kept.isEmpty ? names : kept
  }

  /// The schemes that come from inside the folder: the scheme files and
  /// targets of its projects and workspaces, and the products, targets and
  /// scheme files of its packages (its own `Package.swift`, and the local
  /// packages its projects and workspaces use that live in it). Packages
  /// elsewhere and remote ones are dependencies.
  static func ownSchemes(in folder: ProjectFolder) -> Set<String> {
    var own = Set<String>()
    var visited = Set<String>()
    let root = folder.url.standardizedFileURL.path
    func inside(_ url: URL) -> Bool {
      let path = url.standardizedFileURL.path
      return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
    func addPackage(_ url: URL) {
      guard inside(url), visited.insert(url.standardizedFileURL.path).inserted,
        let manifest = try? String(contentsOf: url.appendingPathComponent("Package.swift"), encoding: .utf8)
      else { return }
      // With several products Xcode adds a scheme for the whole package.
      for groups in matches(of: #"Package\s*\(\s*name:\s*"([^"]+)""#, in: manifest) {
        own.formUnion([groups[0], groups[0] + "-Package"])
      }
      let declared = matches(
        of: #"\.(?:library|executable|plugin|target|executableTarget|testTarget|macro)\s*\(\s*name:\s*"([^"]+)""#,
        in: manifest)
      own.formUnion(declared.map { $0[0] })
      own.formUnion(schemeFiles(in: url.appendingPathComponent(".swiftpm/xcode")).map(\.0))
    }
    func addProject(_ url: URL) {
      guard inside(url), visited.insert(url.standardizedFileURL.path).inserted else { return }
      own.formUnion(schemeFiles(in: url).map(\.0))
      let pbxproj = (try? String(contentsOf: url.appendingPathComponent("project.pbxproj"), encoding: .utf8)) ?? ""
      own.formUnion(targets(in: pbxproj).map(\.0))
      let packages = matches(
        of: #"isa = XCLocalSwiftPackageReference;[^}]*?relativePath = "?([^";]+)"?;"#, in: pbxproj)
      for groups in packages { addPackage(url.deletingLastPathComponent().appendingPathComponent(groups[0])) }
    }
    addPackage(folder.url)
    for entry in folder.entries {
      let url = folder.url.appendingPathComponent(entry.name)
      if entry.name.hasSuffix(".xcodeproj") { addProject(url) }
      guard entry.name.hasSuffix(".xcworkspace") else { continue }
      own.formUnion(schemeFiles(in: url).map(\.0))
      let contents = folder.read(entry.name + "/contents.xcworkspacedata") ?? ""
      for groups in matches(of: #"location = "(group|container|absolute):([^"]+)""#, in: contents) {
        let referenced =
          groups[0] == "absolute"
          ? URL(fileURLWithPath: groups[1]) : folder.url.appendingPathComponent(groups[1])
        if referenced.pathExtension == "xcodeproj" { addProject(referenced) } else { addPackage(referenced) }
      }
    }
    return own
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
    // Replaces the copy in ~/Applications when there is one, else installs
    // into /Applications.
    let app = shellQuote("\(scheme).app")
    let chooseInstalled =
      "installed=\"$HOME\"/Applications/\(app); if [ ! -e \"$installed\" ]; then installed=/Applications/\(app); fi"
    let installed = "\"$installed\""
    let archived = shellQuote("\(folder)/\(scheme).xcarchive/Products/Applications/\(scheme).app")
    // Stamped with the commit count as its build number, as releases are.
    commands[.install] =
      "\(chooseInstalled); \(archiveMac) \(AppInstall.buildNumber) && if \(hasDeveloperID); then \(exportDeveloperID) && rm -rf \(installed) && ditto \(developerIDApp) \(installed); else rm -rf \(installed) && ditto \(archived) \(installed); fi"
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
    return platforms(inSettings: text) ?? [.mac]
  }

  /// The platforms build settings name (macosx, iphoneos), nil when they
  /// name neither.
  static func platforms(inSettings text: String) -> [Platform]? {
    var platforms: [Platform] = []
    if text.contains("macosx") { platforms.append(.mac) }
    if text.contains("iphoneos") { platforms.append(.iOS) }
    return platforms.isEmpty ? nil : platforms
  }

  /// Each scheme's platforms, from the target it builds (a scheme file's
  /// runnable, else its first target; a scheme without a file is named after
  /// its target), when that target's own configurations set them: an iOS
  /// app in a project with a Mac app runs only on iOS.
  static func schemePlatforms(in folder: ProjectFolder) -> [String: [Platform]] {
    var targets: [String: [Platform]] = [:]
    for entry in folder.entries where entry.name.hasSuffix(".xcodeproj") {
      targets.merge(targetPlatforms(in: folder.read(entry.name + "/project.pbxproj") ?? "")) { first, _ in first }
    }
    var schemes = targets
    for entry in folder.entries
    where entry.name.hasSuffix(".xcodeproj") || entry.name.hasSuffix(".xcworkspace") {
      for (scheme, text) in schemeTexts(in: folder.url.appendingPathComponent(entry.name)) {
        if let target = target(ofScheme: text), let platforms = targets[target] { schemes[scheme] = platforms }
      }
    }
    return schemes
  }

  /// The platforms of each native target in a `project.pbxproj` whose own
  /// build configurations set SDKROOT or SUPPORTED_PLATFORMS, by name.
  static func targetPlatforms(in pbxproj: String) -> [String: [Platform]] {
    var platforms: [String: [Platform]] = [:]
    let targets = matches(
      of: #"isa = PBXNativeTarget;[^}]*?buildConfigurationList = (\w+)[^}]*?\bname = "?([^";]+)"?;"#, in: pbxproj)
    for groups in targets {
      let list = NSRegularExpression.escapedPattern(for: groups[0])
      guard
        let configurations = matches(
          of: #"\b\#(list)\b[^=\n]*= \{\s*isa = XCConfigurationList;\s*buildConfigurations = \(([^)]*)\)"#,
          in: pbxproj
        ).first?[0]
      else { continue }
      var settings = ""
      for id in matches(of: #"(\w+)\s*(?:/\*[^*]*\*/)?\s*,"#, in: configurations) {
        let configuration = NSRegularExpression.escapedPattern(for: id[0])
        settings += matches(
          of: #"\b\#(configuration)\b[^=\n]*= \{\s*isa = XCBuildConfiguration;(.*?)\n\s*name = "#, in: pbxproj,
          options: .dotMatchesLineSeparators
        ).first?[0] ?? ""
      }
      let set = matches(of: #"\b(?:SDKROOT|SUPPORTED_PLATFORMS) = ("[^"]*"|[^;]*);"#, in: settings)
      if let found = Self.platforms(inSettings: set.map { $0[0] }.joined(separator: " ")) {
        platforms[groups[1]] = found
      }
    }
    return platforms
  }

  /// The target a scheme file builds: its runnable's, else its first.
  static func target(ofScheme text: String) -> String? {
    let runnable = text.range(of: #"<(BuildableProductRunnable|RemoteRunnable)\b"#, options: .regularExpression)
    let from = runnable.map { String(text[$0.lowerBound...]) } ?? text
    return matches(of: #"BlueprintName = "([^"]+)""#, in: from).first?[0]
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
      // Without scheme files, Xcode makes one per target, named after it.
      let targets = Self.targets(in: folder.read(entry.name + "/project.pbxproj") ?? "")
      for (name, product) in schemeFiles(in: container) + targets {
        own.insert(name)
        if product == .app { apps.insert(name) }
      }
    }
    func rank(_ name: String) -> Int {
      let plain = plainName(name)
      if plain.package { return own.contains(name) ? 1 : 2 }
      return apps.contains(plain.name) ? 0 : own.contains(plain.name) ? 1 : 2
    }
    return names.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
      .map(\.element)
  }

  /// The shared and user `.xcscheme` files of a project, workspace or
  /// package (its `.swiftpm/xcode`), with what each builds.
  static func schemeFiles(in container: URL) -> [(String, Product)] {
    schemeTexts(in: container).map { ($0.0, product(ofScheme: $0.1)) }
  }

  /// The shared and user `.xcscheme` files of a container, by name, with
  /// their contents.
  static func schemeTexts(in container: URL) -> [(String, String)] {
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
          return (String(file.dropLast(".xcscheme".count)), text)
        }
    }
  }

  /// What a scheme file builds: what its Run action launches (an app, or a
  /// tool without an extension), else a library when it builds for running
  /// or only tests when it has testables.
  static func product(ofScheme text: String) -> Product {
    func section(_ tag: String) -> String {
      guard let start = text.range(of: "<" + tag + "\\b", options: .regularExpression) else { return "" }
      let rest = text[start.lowerBound...]
      // `<LaunchAction ... />` has nothing inside.
      if let close = rest.firstIndex(of: ">"), rest[..<close].hasSuffix("/") { return "" }
      return String(rest.range(of: "</" + tag + ">").map { rest[..<$0.lowerBound] } ?? rest)
    }
    let launch = section("LaunchAction")
    if let runnable = launch.range(of: #"<(BuildableProductRunnable|RemoteRunnable)\b"#, options: .regularExpression),
      let name = matches(of: #"BuildableName = "([^"]+)""#, in: String(launch[runnable.lowerBound...])).first?[0]
    {
      switch URL(fileURLWithPath: name).pathExtension {
      case "app": return .app
      case "": return .tool
      default: return .library
      }
    }
    if section("BuildAction").contains(#"buildForRunning = "YES""#) { return .library }
    return section("TestAction").contains("<TestableReference") ? .tests : .library
  }

  /// The native targets in a `project.pbxproj`, with what each builds.
  static func targets(in pbxproj: String) -> [(String, Product)] {
    matches(
      of: #"isa = PBXNativeTarget;[^}]*?\bname = "?([^";]+)"?;[^}]*?productType = "([^"]+)""#,
      in: pbxproj
    ).map { groups in
      let type = groups[1]
      if type.hasPrefix("com.apple.product-type.application") { return (groups[0], .app) }
      if type == "com.apple.product-type.tool" { return (groups[0], .tool) }
      if type.contains(".unit-test") || type.contains(".ui-testing") { return (groups[0], .tests) }
      return (groups[0], .library)
    }
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

  /// The container's schemes from `xcodebuild -list`; where there's no xcodebuild (iPhone and iPad, looking at a
  /// copy of a project on a Mac) from its scheme files, then the targets Xcode makes schemes for.
  static func schemeNames(_ container: URL, in folder: ProjectFolder) -> [String]? {
    #if os(iOS)
      var names: [String] = []
      for entry in folder.entries
      where entry.name.hasSuffix(".xcodeproj") || entry.name.hasSuffix(".xcworkspace") {
        let schemes = schemeFiles(in: folder.url.appendingPathComponent(entry.name)).map(\.0)
        let targets = Self.targets(in: folder.read(entry.name + "/project.pbxproj") ?? "").map(\.0)
        for name in schemes + targets where !names.contains(name) { names.append(name) }
      }
      return names
    #else
      return Self.list(container).flatMap(Self.parseSchemes)
    #endif
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
