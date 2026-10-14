import Foundation

extension DependencyScanner {
  /// Swift packages, as Xcode lists them: local packages a Package.swift
  /// or an Xcode project refers to, and every package in the
  /// Package.resolved files (dependencies of dependencies too). Checkouts
  /// are in `.build/checkouts` (SwiftPM) or in the project's DerivedData
  /// (Xcode).
  static func swiftPackages(_ folder: DependencyFolder) -> [PackageDependency] {
    let entries = folder.children(folder.root)
    let projects = entries.filter { $0.hasSuffix(".xcodeproj") }
    let workspaces = entries.filter { $0.hasSuffix(".xcworkspace") }
    let hasManifest = entries.contains("Package.swift")
    guard hasManifest || !projects.isEmpty || !workspaces.isEmpty else { return [] }

    var found: [PackageDependency] = []
    var localPaths: [String] = []
    if hasManifest, let manifest = folder.read("Package.swift") {
      localPaths += localPackagePaths(inManifest: manifest)
    }
    var resolvedFiles: [URL] = []
    if hasManifest { resolvedFiles.append(folder.url("Package.resolved")) }
    for project in projects {
      if let text = folder.read(project + "/project.pbxproj") {
        localPaths += localPackagePaths(inProject: text)
      }
      resolvedFiles.append(folder.url(project + "/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
    }
    for workspace in workspaces {
      resolvedFiles.append(folder.url(workspace + "/xcshareddata/swiftpm/Package.resolved"))
    }

    for path in localPaths {
      let location = folder.resolve(path)
      let manifest = DependencyFolder.read(location.appendingPathComponent("Package.swift"))
      let name = manifest.flatMap(packageName(inManifest:)) ?? location.lastPathComponent
      found.append(
        PackageDependency(
          name: name, isLocal: true, ecosystem: .swift, location: folder.folder(location), source: path))
    }

    let checkouts =
      [folder.url(".build/checkouts")]
      + derivedDataFolders(
        folder, for: [folder.root] + (projects + workspaces).map(folder.url)
      ).map { $0.appendingPathComponent("SourcePackages/checkouts") }
    for file in resolvedFiles {
      guard let text = DependencyFolder.read(file) else { continue }
      for pin in resolvedPins(text) {
        let directory = checkoutName(pin.location)
        let location = checkouts.lazy.map { $0.appendingPathComponent(directory) }.first(where: folder.isDirectory)
        found.append(
          PackageDependency(
            name: directory, version: pin.version, ecosystem: .swift, location: location, source: pin.location))
      }
    }
    return found
  }

  /// `.package(path: "../X")` and `.package(name: "X", path: "../X")`,
  /// without interpolated paths (`"../\(name)"` in a manifest's helper),
  /// which only running the manifest would tell.
  static func localPackagePaths(inManifest manifest: String) -> [String] {
    manifest.matches(#"\.package\s*\((?:\s*name\s*:\s*"[^"]*"\s*,)?\s*path\s*:\s*"([^"]+)""#).map { $0[0] }
      .filter { !$0.contains("\\(") }
  }

  /// The `relativePath` of each XCLocalSwiftPackageReference.
  static func localPackagePaths(inProject text: String) -> [String] {
    text.matches(#"isa = XCLocalSwiftPackageReference;\s*relativePath = ("[^"]*"|[^;]+);"#).map { $0[0].unquoted }
  }

  /// The package's own name in its Package.swift.
  static func packageName(inManifest manifest: String) -> String? {
    manifest.firstMatch(#"Package\s*\(\s*name\s*:\s*"([^"]+)""#)
  }

  struct Pin: Equatable {
    var location: String
    var version: String?
  }

  /// The pins of a Package.resolved, versions 1 to 3: a version, else a
  /// branch, else a short revision.
  static func resolvedPins(_ text: String) -> [Pin] {
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
      return []
    }
    let pins =
      (object["pins"] as? [[String: Any]]) ?? ((object["object"] as? [String: Any])?["pins"] as? [[String: Any]])
      ?? []
    return pins.compactMap { pin in
      guard let location = (pin["location"] ?? pin["repositoryURL"]) as? String else { return nil }
      let state = pin["state"] as? [String: Any] ?? [:]
      let version =
        (state["version"] as? String) ?? (state["branch"] as? String)
        ?? (state["revision"] as? String).map { String($0.prefix(7)) }
      return Pin(location: location, version: version)
    }
  }

  /// The checkout folder's name: the repository's last path component
  /// without ".git".
  static func checkoutName(_ location: String) -> String {
    var name = location.split(separator: "/").last.map(String.init) ?? location
    if name.hasSuffix(".git") { name.removeLast(4) }
    return name
  }

  /// Xcode's DerivedData folders for any of `workspaces` (an
  /// .xcodeproj, .xcworkspace or package folder), newest first: each has
  /// an info.plist naming the workspace it builds.
  static func derivedDataFolders(_ folder: DependencyFolder, for workspaces: [URL]) -> [URL] {
    let paths = Set(workspaces.map { $0.standardizedFileURL.path })
    let derivedData = folder.home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
    var found: [(url: URL, date: Date)] = []
    for name in folder.children(derivedData) {
      let url = derivedData.appendingPathComponent(name)
      guard let data = try? Data(contentsOf: url.appendingPathComponent("info.plist")),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        let path = plist["WorkspacePath"] as? String,
        paths.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
      else { continue }
      found.append((url, plist["LastAccessedDate"] as? Date ?? .distantPast))
    }
    return found.sorted { $0.date > $1.date }.map(\.url)
  }
}
