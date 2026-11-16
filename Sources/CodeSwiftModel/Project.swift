import CodeModel
import CodeScan
import Foundation

/// Swift's projects: a package's targets from its manifest, sibling packages, the SDK's `.swiftinterface` files, and
/// Clang modules read as Swift when a lookup misses.
final class SwiftLayout: ProjectLayout {
  var syntax: any LanguageSyntax { SwiftSyntax.shared }
  let implicitModules = ["Swift", "_Concurrency", "_StringProcessing"]
  let interfaceExtension = ".swiftinterface"
  let sdkInterfaces: [Name: (name: String, path: String)]
  let clang: ClangImporter?
  /// Modules whose headers haven't been read. A lookup that misses reads them: most questions never need to.
  var pendingClang: Set<Name> = []
  /// The manifest's target folders relative to the root, deepest first, with their module names.
  private var targetFolders: [(path: String, name: String)] = []
  /// How long reading the manifest took, 0 without one.
  private(set) var manifestMilliseconds = 0.0

  init(root: String, useSDK: Bool, useClang: Bool, runsManifest: Bool) {
    if useSDK {
      let found = SwiftLayout.findSDKInterfaces()
      sdkInterfaces = found.interfaces
      clang = useClang && !found.sdk.isEmpty ? ClangImporter(sdk: found.sdk, frameworks: found.frameworks) : nil
    } else {
      sdkInterfaces = [:]
      clang = nil
    }
    if runsManifest { readManifest(root: root) }
  }

  static func findSDKInterfaces() -> (interfaces: [Name: (name: String, path: String)], frameworks: [String: String], sdk: String) {
    #if !(os(macOS) || os(Linux) || os(Windows))
      return ([:], [:], "")
    #else
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--show-sdk-path"]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return ([:], [:], "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let sdk = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    var found: [Name: (name: String, path: String)] = [:]
    var frameworkPaths: [String: String] = [:]
    let manager = FileManager.default
    func add(moduleDirectory: String) {
      let moduleName = String(URL(fileURLWithPath: moduleDirectory).deletingPathExtension().lastPathComponent)
      // This Mac's interface: Apple silicon's, else Intel's.
      for triple in ["arm64e-apple-macos", "arm64-apple-macos", "x86_64-apple-macos"] {
        let path = moduleDirectory + "/\(triple).swiftinterface"
        if manager.fileExists(atPath: path) {
          found[name(moduleName)] = (moduleName, path)
          return
        }
      }
    }
    func frameworks(_ directory: String) {
      for entry in (try? manager.contentsOfDirectory(atPath: directory)) ?? [] where entry.hasSuffix(".framework") {
        let framework = directory + "/" + entry
        frameworkPaths[String(entry.dropLast(".framework".count))] = framework
        let modules = framework + "/Modules"
        for module in (try? manager.contentsOfDirectory(atPath: modules)) ?? [] where module.hasSuffix(".swiftmodule") {
          add(moduleDirectory: modules + "/" + module)
        }
        frameworks(framework + "/Frameworks")
      }
    }
    for directory in ["/usr/lib/swift"] {
      for entry in (try? manager.contentsOfDirectory(atPath: sdk + directory)) ?? [] where entry.hasSuffix(".swiftmodule") {
        add(moduleDirectory: sdk + directory + "/" + entry)
      }
    }
    frameworks(sdk + "/System/Library/Frameworks")
    // Testing and XCTest sit beside the SDK, PackageDescription with the toolchain.
    let developer = URL(fileURLWithPath: sdk).deletingLastPathComponent().deletingLastPathComponent().path
    frameworks(developer + "/Library/Frameworks")
    let xcode = URL(fileURLWithPath: developer).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    add(moduleDirectory: xcode + "/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule")
    frameworks(sdk + "/System/Library/SubFrameworks")
    return (found, frameworkPaths, sdk)
    #endif
  }

  func sourceFiles(in directory: String) -> [String] {
    guard
      let walker = FileManager.default.enumerator(
        at: URL(fileURLWithPath: directory), includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    var paths: [String] = []
    for case let url as URL in walker {
      let last = url.lastPathComponent
      if last == ".build" || last == "build" || last == "node_modules" { walker.skipDescendants(); continue }
      if last.hasSuffix(".swift") { paths.append(url.standardizedFileURL.path) }
    }
    return paths.sorted()
  }

  /// The targets of the root's `Package.swift`, as SwiftPM evaluates it (`swift package dump-package`, which runs the
  /// manifest without resolving anything): a manifest is code, so its folders can't be read from its text.
  private func readManifest(root: String) {
    guard FileManager.default.fileExists(atPath: root + "/Package.swift") else { return }
    let start = DispatchTime.now()
    defer { manifestMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000 }
    #if os(macOS) || os(Linux) || os(Windows)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", "package", "dump-package"]
    process.currentDirectoryURL = URL(fileURLWithPath: root)
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let targets = json["targets"] as? [[String: Any]]
    else { return }
    for target in targets {
      guard let name = target["name"] as? String else { continue }
      let kind = target["type"] as? String ?? "regular"
      guard kind != "binary", kind != "plugin" else { continue }
      var path = (target["path"] as? String) ?? ((kind == "test" ? "Tests/" : "Sources/") + name)
      while path.hasSuffix("/") { path.removeLast() }
      if path.hasPrefix("./") { path.removeFirst(2) }
      targetFolders.append((path == "." ? "" : path, name))
    }
    targetFolders.sort { $0.path.count > $1.path.count }
    #endif
  }


  /// A file's module: the manifest's target whose folder holds it, else from where it is (`Sources/<Module>/…` or
  /// `Tests/<Module>/…`), anything else on its own.
  func moduleName(ofRelative path: String) -> String {
    for folder in targetFolders where folder.path.isEmpty || path.hasPrefix(folder.path + "/") { return folder.name }
    let parts = path.split(separator: "/").map(String.init)
    for (index, part) in parts.enumerated() where part == "Sources" || part == "Tests" {
      if index + 2 < parts.count { return parts[index + 1] }
    }
    return "<" + path + ">"
  }

  /// A sibling package's target, or the SDK's: a Swift interface, its Clang half, or both. The headers wait until a
  /// lookup misses.
  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    if let directory = siblingDirectory(of: display, root: project.root) {
      return project.register(display, project.parse(sourceFiles(in: directory), isInterface: false), isSDK: false)
    }
    let interfaceUnit = sdkInterfaces[moduleName].flatMap { project.parse([$0.path], isInterface: true).first }
    let clangName = sdkInterfaces[moduleName]?.name ?? display
    let hasHeaders = clang?.hasHeaders(clangName) == true
    guard interfaceUnit != nil || hasHeaders else { return nil }
    let module = project.register(clangName, interfaceUnit.map { [$0] } ?? [], isSDK: true)
    if let interfaceUnit, let exported = SwiftLayout.exportName(interfaceUnit) { module.publishedName = exported }
    if hasHeaders { pendingClang.insert(module.name) }
    return module
  }

  private func siblingDirectory(of moduleName: String, root: String) -> String? {
    let parent = URL(fileURLWithPath: root).deletingLastPathComponent().path
    let manager = FileManager.default
    let entries = (try? manager.contentsOfDirectory(atPath: parent)) ?? []
    for entry in entries.sorted() where !entry.hasPrefix(".") {
      let sibling = parent + "/" + entry
      let direct = sibling + "/Sources/" + moduleName
      if manager.fileExists(atPath: direct) { return direct }
      for inner in ((try? manager.contentsOfDirectory(atPath: sibling)) ?? []).sorted() where !inner.hasPrefix(".") {
        let nested = sibling + "/" + inner + "/Sources/" + moduleName
        if manager.fileExists(atPath: nested) { return nested }
      }
    }
    return nil
  }

  static func exportName(_ unit: Unit) -> String? {
    let head = String(decoding: UnsafeBufferPointer(start: unit.source.text, count: min(unit.source.count, 4096)), as: UTF8.self)
    guard let flag = head.range(of: "-export-as ") ?? head.range(of: "-module-abi-name ") else { return nil }
    return head[flag.upperBound...].prefix { !$0.isWhitespace }.description
  }

}

extension Project {
  /// - Parameter runsManifest: whether `Package.swift` may be evaluated (`dump-package` runs it): only in a folder the
  ///   person trusts (security audit H1). Without it the targets are the usual folders.
  public convenience init(root: String, useSDK: Bool = true, useClang: Bool = true, runsManifest: Bool = true) {
    let root = URL(fileURLWithPath: root).standardizedFileURL.path
    self.init(root: root, layout: SwiftLayout(root: root, useSDK: useSDK, useClang: useClang, runsManifest: runsManifest))
  }

  var swift: SwiftLayout { unsafeDowncast(layout as AnyObject, to: SwiftLayout.self) }

  /// How long reading the manifest took, 0 without one.
  public var manifestMilliseconds: Double { swift.manifestMilliseconds }

  /// The generated Swift of a Clang module, for looking at.
  public func generatedInterface(of moduleName: String) -> String? {
    guard let module = ensureModule(name(moduleName), display: moduleName) else { return nil }
    loadClang(module.name)
    for index in module.units where !units[Int(index)].headerLines.isEmpty { return String(decoding: units[Int(index)].source.bytes, as: UTF8.self) }
    return nil
  }

  /// Reads the headers of what these files see, and of Foundation, where a name no import declares is looked for.
  /// Returns whether anything new came, in which case everything built so far is stale.
  func loadClang(visibleFrom askers: Set<Int32>) -> Bool {
    guard !swift.pendingClang.isEmpty else { return false }
    var names: [Name] = askers.flatMap { visibleModules(of: $0) }
    if ensureModule(name("Foundation"), display: "Foundation") != nil { names.append(name("Foundation")) }
    var loaded = false
    for moduleName in names where loadClang(moduleName) { loaded = true }
    guard loaded else { return false }
    visibleCache.removeAll()
    for unit in units { unit.dropBodyAnswers() }
    return true
  }

  @discardableResult
  private func loadClang(_ moduleName: Name) -> Bool {
    guard swift.pendingClang.remove(moduleName) != nil, let clang = swift.clang, let module = modules[moduleName] else { return false }
    // Dependencies first: they rename what this module's headers mention.
    for dependency in clang.exports(of: module.displayName) {
      ensureModule(name(dependency), display: dependency)
      loadClang(name(dependency))
    }
    guard let generated = clang.generate(module.displayName) else { return true }
    let unit = Unit(path: "<clang:\(module.displayName)>", source: SourceFile(generated.text, profile: syntax.profile), isInterface: true)
    unit.headerLines = generated.lines
    unit.headerFiles = generated.headers
    // Ahead of the overlay, which extends it.
    prepend(unit, to: module)
    return true
  }

  /// A name no import in sight declares. Apple's frameworks re-export each other in their Clang modules, which the
  /// Swift interfaces don't show, so an SDK import may still bring it: Foundation, then whatever SDK module is loaded.
  func implicitlyExported(_ typeName: Name) -> [DeclRef] {
    if let foundation = ensureModule(name("Foundation"), display: "Foundation"), let list = foundation.top[typeName] { return list }
    for module in modules.values where module.isSDK {
      if let list = module.top[typeName] { return list }
    }
    return []
  }

  /// What Clang re-exports: empty for a module without headers.
  func clangExports(of moduleName: String) -> [String] { swift.clang?.exports(of: moduleName) ?? [] }

  /// Every module an `import` could name, with whether it's the SDK's.
  func moduleNames() -> [(String, Bool)] {
    var found = modules.values.map { ($0.displayName, $0.isSDK) }
    let loaded = Set(found.map(\.0))
    for entry in swift.sdkInterfaces.values where !loaded.contains(entry.name) { found.append((entry.name, true)) }
    return found.filter { !$0.0.hasPrefix("<") }
  }
}
