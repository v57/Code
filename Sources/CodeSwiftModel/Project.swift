import CodeScan
import Foundation

/// Layer 2: which files make which module, what each file can see, and everything else only when an import asks.
public struct DeclRef: Hashable {
  var unit: Int32
  var decl: Int32
}

public enum Site: Hashable {
  case decl(DeclRef)
  case local(unit: Int32, token: Int32)
  case generic(unit: Int32, token: Int32)
  case module(Name)
}

final class Module {
  let name: Name
  let displayName: String
  let isSDK: Bool
  var units: [Int32] = []
  var top: [Name: [DeclRef]] = [:]
  /// The name it's published as (`-export-as`): SwiftUICore's declarations are SwiftUI's to anyone reading them.
  var publishedName: String
  init(name: Name, displayName: String, isSDK: Bool) {
    self.name = name
    self.displayName = displayName
    self.isSDK = isSDK
    publishedName = displayName
  }
}

private let swiftProfile = LexProfile.profile(forLanguage: "swift")!

public final class Project {
  public let root: String
  public internal(set) var units: [Unit] = []
  var modules: [Name: Module] = [:]
  var unitByPath: [String: Int32] = [:]
  /// Extensions by the last name of what they extend, whichever module they're in.
  var extensions: [Name: [DeclRef]] = [:]
  public internal(set) var projectUnits = 0
  public internal(set) var loadedBytes = 0
  private var visibleCache: [Int32: [Name]] = [:]
  private var missing: Set<Name> = []
  private let sdkInterfaces: [Name: (name: String, path: String)]
  private var clang: ClangImporter?
  /// Modules whose headers haven't been read. A lookup that misses reads them: most questions never need to.
  private var pendingClang: Set<Name> = []
  private var focused: Int32?
  /// The manifest's target folders relative to the root, deepest first, with their module names.
  private var targetFolders: [(path: String, name: String)] = []
  /// How long reading the manifest took, 0 without one.
  public private(set) var manifestMilliseconds = 0.0
  /// Called when any declaration changed: a table built from them is stale.
  var onShapeChange: () -> Void = {}

  public init(root: String, useSDK: Bool = true, useClang: Bool = true) {
    self.root = URL(fileURLWithPath: root).standardizedFileURL.path
    if useSDK {
      let found = Project.findSDKInterfaces()
      sdkInterfaces = found.interfaces
      if useClang, !found.sdk.isEmpty { clang = ClangImporter(sdk: found.sdk, frameworks: found.frameworks) }
    } else {
      sdkInterfaces = [:]
    }
    readManifest()
    loadProject()
  }

  private static func findSDKInterfaces() -> (interfaces: [Name: (name: String, path: String)], frameworks: [String: String], sdk: String) {
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

  /// The generated Swift of a Clang module, for looking at.
  public func generatedInterface(of moduleName: String) -> String? {
    guard let module = ensureModule(name(moduleName), display: moduleName) else { return nil }
    loadClang(module.name)
    for index in module.units where !units[Int(index)].headerLines.isEmpty { return String(decoding: units[Int(index)].source.bytes, as: UTF8.self) }
    return nil
  }

  private static func swiftFiles(in directory: String) -> [String] {
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
  private func readManifest() {
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
  private func moduleName(ofRelative path: String) -> String {
    for folder in targetFolders where folder.path.isEmpty || path.hasPrefix(folder.path + "/") { return folder.name }
    let parts = path.split(separator: "/").map(String.init)
    for (index, part) in parts.enumerated() where part == "Sources" || part == "Tests" {
      if index + 2 < parts.count { return parts[index + 1] }
    }
    return "<" + path + ">"
  }

  private func parse(_ paths: [String], isInterface: Bool) -> [Unit] {
    var parsed = [Unit?](repeating: nil, count: paths.count)
    parsed.withUnsafeMutableBufferPointer { buffer in
      nonisolated(unsafe) let slots = buffer
      DispatchQueue.concurrentPerform(iterations: paths.count) { index in
        guard let data = FileManager.default.contents(atPath: paths[index]) else { return }
        slots[index] = Unit(path: paths[index], source: SourceFile(bytes: data, profile: swiftProfile), isInterface: isInterface)
      }
    }
    return parsed.compactMap { $0 }
  }

  private func loadProject() {
    let paths = Project.swiftFiles(in: root)
    let prefix = root + "/"
    var groups: [String: [Unit]] = [:]
    for unit in parse(paths, isInterface: false) {
      let relative = unit.path.hasPrefix(prefix) ? String(unit.path.dropFirst(prefix.count)) : unit.path
      groups[moduleName(ofRelative: relative), default: []].append(unit)
    }
    for (moduleName, members) in groups.sorted(by: { $0.key < $1.key }) {
      register(moduleName, members, isSDK: false)
    }
    projectUnits = units.count
  }

  @discardableResult
  private func register(_ displayName: String, _ members: [Unit], isSDK: Bool) -> Module {
    let module = Module(name: name(displayName), displayName: displayName, isSDK: isSDK)
    modules[module.name] = module
    for unit in members {
      let index = Int32(units.count)
      unit.moduleName = module.name
      units.append(unit)
      unitByPath[unit.path] = index
      module.units.append(index)
      loadedBytes += unit.source.count
      addToIndex(unit, index, into: module)
    }
    return module
  }

  private func addToIndex(_ unit: Unit, _ index: Int32, into module: Module) {
    for (position, decl) in unit.decls.enumerated() where decl.parent < 0 && !decl.isLocal {
      let ref = DeclRef(unit: index, decl: Int32(position))
      if decl.kind == .extensionDecl {
        extensions[decl.name, default: []].append(ref)
      } else {
        module.top[decl.name, default: []].append(ref)
      }
    }
  }

  /// Finds a module an import names: in this project, next to it, or in the SDK, then what it re-exports.
  @discardableResult
  func ensureModule(_ moduleName: Name, display: String) -> Module? {
    if let module = modules[moduleName] { return module }
    if missing.contains(moduleName) { return nil }
    var loaded: Module?
    if let directory = siblingDirectory(of: display) {
      let members = parse(Project.swiftFiles(in: directory), isInterface: false)
      loaded = register(display, members, isSDK: false)
    } else {
      // A Swift interface, its Clang half, or both. The headers wait until a lookup misses.
      let interfaceUnit = sdkInterfaces[moduleName].flatMap { parse([$0.path], isInterface: true).first }
      let clangName = sdkInterfaces[moduleName]?.name ?? display
      let hasHeaders = clang?.hasHeaders(clangName) == true
      if interfaceUnit != nil || hasHeaders {
        let module = register(clangName, interfaceUnit.map { [$0] } ?? [], isSDK: true)
        if let interfaceUnit, let exported = Project.exportName(interfaceUnit) { module.publishedName = exported }
        if hasHeaders { pendingClang.insert(module.name) }
        loaded = module
      }
    }
    guard let loaded else {
      missing.insert(moduleName)
      return nil
    }
    for unitIndex in loaded.units {
      for item in units[Int(unitIndex)].imports where item.isExported { ensureModule(item.module, display: item.moduleName) }
    }
    return loaded
  }

  /// Reads the headers of what these files see, and of Foundation, where a name no import declares is looked for.
  /// Returns whether anything new came, in which case everything built so far is stale.
  func loadClang(visibleFrom askers: Set<Int32>) -> Bool {
    guard !pendingClang.isEmpty else { return false }
    var names: [Name] = askers.flatMap { visibleModules(of: $0) }
    if ensureModule(name("Foundation"), display: "Foundation") != nil { names.append(name("Foundation")) }
    var loaded = false
    for moduleName in names where loadClang(moduleName) { loaded = true }
    guard loaded else { return false }
    visibleCache.removeAll()
    for unit in units {
      unit.chains.removeAll()
      unit.scans.values.forEach { $0.types.removeAll() }
    }
    return true
  }

  @discardableResult
  private func loadClang(_ moduleName: Name) -> Bool {
    guard pendingClang.remove(moduleName) != nil, let clang, let module = modules[moduleName] else { return false }
    // Dependencies first: they rename what this module's headers mention.
    for dependency in clang.exports(of: module.displayName) {
      ensureModule(name(dependency), display: dependency)
      loadClang(name(dependency))
    }
    guard let generated = clang.generate(module.displayName) else { return true }
    let unit = Unit(path: "<clang:\(module.displayName)>", source: SourceFile(generated.text, profile: swiftProfile), isInterface: true)
    unit.headerLines = generated.lines
    unit.headerFiles = generated.headers
    unit.moduleName = module.name
    let index = Int32(units.count)
    units.append(unit)
    unitByPath[unit.path] = index
    module.units.insert(index, at: 0)
    loadedBytes += unit.source.count
    // Ahead of the overlay, which extends it.
    var top: [Name: [DeclRef]] = [:]
    var extended: [Name: [DeclRef]] = [:]
    for (position, decl) in unit.decls.enumerated() where decl.parent < 0 && !decl.isLocal {
      let ref = DeclRef(unit: index, decl: Int32(position))
      if decl.kind == .extensionDecl { extended[decl.name, default: []].append(ref) } else { top[decl.name, default: []].append(ref) }
    }
    for (declName, list) in top { module.top[declName] = list + (module.top[declName] ?? []) }
    for (declName, list) in extended { extensions[declName] = list + (extensions[declName] ?? []) }
    return true
  }

  private static func exportName(_ unit: Unit) -> String? {
    let head = String(decoding: UnsafeBufferPointer(start: unit.source.text, count: min(unit.source.count, 4096)), as: UTF8.self)
    guard let flag = head.range(of: "-export-as ") ?? head.range(of: "-module-abi-name ") else { return nil }
    return head[flag.upperBound...].prefix { !$0.isWhitespace }.description
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
  func clangExports(of moduleName: String) -> [String] { clang?.exports(of: moduleName) ?? [] }

  /// Every module an `import` could name, with whether it's the SDK's.
  func moduleNames() -> [(String, Bool)] {
    var found = modules.values.map { ($0.displayName, $0.isSDK) }
    let loaded = Set(found.map(\.0))
    for entry in sdkInterfaces.values where !loaded.contains(entry.name) { found.append((entry.name, true)) }
    return found.filter { !$0.0.hasPrefix("<") }
  }

  private func siblingDirectory(of moduleName: String) -> String? {
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

  /// A file's modules in the order names resolve: its own, then its imports with what they re-export, then the implicit ones.
  func visibleModules(of unitIndex: Int32) -> [Name] {
    if let cached = visibleCache[unitIndex] { return cached }
    let unit = units[Int(unitIndex)]
    var order: [Name] = [unit.moduleName]
    var seen: Set<Name> = [unit.moduleName]
    func visit(_ moduleName: Name, _ display: String) {
      guard seen.insert(moduleName).inserted, let module = ensureModule(moduleName, display: display) else { return }
      order.append(moduleName)
      for member in module.units {
        for item in units[Int(member)].imports where item.isExported { visit(item.module, item.moduleName) }
      }
    }
    for item in unit.imports { visit(item.module, item.moduleName) }
    // `@_exported import` in one file of a module reaches every file of that module.
    if let own = modules[unit.moduleName] {
      for member in own.units {
        for item in units[Int(member)].imports where item.isExported { visit(item.module, item.moduleName) }
      }
    }
    for implicit in ["Swift", "_Concurrency", "_StringProcessing"] { visit(name(implicit), implicit) }
    visibleCache[unitIndex] = order
    return order
  }

  func isTestable(_ moduleName: Name, from unit: Unit) -> Bool {
    unit.imports.contains { $0.isTestable && $0.module == moduleName }
  }

  /// Takes a file's new text. Returns whether what others see held, so that only its own body answers go.
  @discardableResult
  public func update(path: String, text: String) -> Bool {
    guard let index = unitByPath[path] else { return false }
    let old = units[Int(index)]
    return install(Unit(path: path, source: SourceFile(text, profile: swiftProfile), focusOffset: old.focusOffset), at: index, replacing: old)
  }

  /// A question inside code `#if` leaves out reads that branch; one outside what's being worked on goes back.
  func focus(unitIndex: Int32, offset: Int) {
    let old = units[Int(unitIndex)]
    guard !old.isInterface else { return }
    // One file at a time: another's left-out branch shouldn't answer for this question.
    if let earlier = focused, earlier != unitIndex {
      focused = nil
      let other = units[Int(earlier)]
      install(Unit(path: other.path, source: other.source), at: earlier, replacing: other)
    }
    if old.focusOffset == nil, !old.isLeftOut(offset: offset) { return }
    // Without a focus, is this in what's left out?
    let plain = old.focusOffset == nil ? old : Unit(path: old.path, source: old.source)
    let wanted = plain.isLeftOut(offset: offset) ? offset : nil
    if wanted == old.focusOffset { return }
    // Two offsets in the same branch read the same: the check on shape below keeps what's built.
    focused = wanted == nil ? nil : unitIndex
    install(Unit(path: old.path, source: old.source, focusOffset: wanted), at: unitIndex, replacing: old)
  }

  @discardableResult
  private func install(_ new: Unit, at index: Int32, replacing old: Unit) -> Bool {
    new.moduleName = old.moduleName
    units[Int(index)] = new
    if new.shape == old.shape { return true }
    visibleCache.removeAll()
    if let module = modules[old.moduleName] {
      module.top = module.top.mapValues { $0.filter { $0.unit != index } }.filter { !$0.value.isEmpty }
      extensions = extensions.mapValues { $0.filter { $0.unit != index } }.filter { !$0.value.isEmpty }
      addToIndex(new, index, into: module)
    }
    for unit in units {
      unit.chains.removeAll()
      unit.scans.values.forEach { $0.types.removeAll() }
    }
    onShapeChange()
    return false
  }
}
