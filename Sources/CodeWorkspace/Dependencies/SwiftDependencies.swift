import CodeFolders
import Foundation

extension DependencyScanner {
  /// Swift packages of the folder's container, as Xcode lists them: the local packages it refers to, and every package
  /// in its Package.resolved (dependencies of dependencies too). A workspace's local packages override the remote ones
  /// of the same name its projects ask for, which is what a `-Local` workspace is for; it has no Package.resolved of its
  /// own until Xcode resolved it there, so its projects' stand in. Checkouts are in `.build/checkouts` (SwiftPM) or in the
  /// project's DerivedData (Xcode).
  static func swiftPackages(_ folder: DependencyFolder) -> [PackageDependency] {
    let containers = ProjectContainer.list(entries: folder.children(folder.root), in: folder.root)
    guard let container = ProjectContainer.effective(picked: folder.container, in: containers) else { return [] }
    let name = container.fileName

    var localPaths: [String] = []
    var resolvedFiles: [URL] = []
    func addProject(_ project: String) {
      if let text = folder.read(project + "/project.pbxproj") {
        let base = (project as NSString).deletingLastPathComponent
        localPaths += localPackagePaths(inProject: text).map { base.isEmpty ? $0 : base + "/" + $0 }
      }
      resolvedFiles.append(folder.url(project + "/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"))
    }
    switch container.kind {
    case .package:
      if let manifest = folder.read(name) { localPaths += localPackagePaths(inManifest: manifest) }
      resolvedFiles.append(folder.url("Package.resolved"))
    case .project:
      addProject(name)
    case .workspace:
      for reference in workspaceReferences(folder.read(name + "/contents.xcworkspacedata") ?? "") {
        if reference.hasSuffix(".xcodeproj") {
          addProject(reference)
        } else if DependencyFolder.read(folder.resolve(reference).appendingPathComponent("Package.swift")) != nil {
          localPaths.append(reference)
        }
      }
      let own = folder.url(name + "/xcshareddata/swiftpm/Package.resolved")
      if DependencyFolder.read(own) != nil { resolvedFiles = [own] }
    }

    var found: [PackageDependency] = []
    for path in localPaths {
      let location = folder.resolve(path)
      let manifest = DependencyFolder.read(location.appendingPathComponent("Package.swift"))
      let name = manifest.flatMap(packageName(inManifest:)) ?? location.lastPathComponent
      found.append(
        PackageDependency(
          name: name, isLocal: true, ecosystem: .swift, location: folder.folder(location), source: path))
    }
    let overridden = Set(found.flatMap { [$0.name, URL(fileURLWithPath: $0.source ?? "").lastPathComponent] }.map { $0.lowercased() })

    let checkouts =
      [folder.url(".build/checkouts")]
      + derivedDataFolders(
        folder, for: [folder.root, folder.url(name)]
      ).map { $0.appendingPathComponent("SourcePackages/checkouts") }
    for file in resolvedFiles {
      guard let text = DependencyFolder.read(file) else { continue }
      for pin in resolvedPins(text) {
        let directory = checkoutName(pin.location)
        guard !overridden.contains(directory.lowercased()) else { continue }
        let location = checkouts.lazy.map { $0.appendingPathComponent(directory) }.first(where: folder.isDirectory)
        found.append(
          PackageDependency(
            name: directory, version: pin.version, ecosystem: .swift, location: location, source: pin.location))
      }
    }
    return found
  }

  /// What a workspace lists, as paths from its folder (absolute ones stay absolute): its projects and packages.
  static func workspaceReferences(_ contents: String) -> [String] {
    contents.matches(#"location = "(group|container|absolute):([^"]*)""#).map { $0[1] }
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
