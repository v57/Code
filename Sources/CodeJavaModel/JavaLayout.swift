import CodeModel
import CodeScan
import Foundation

/// Java's projects: every `.java` file under the root, grouped by the package its `package` line names (a package is
/// the core's module). A package the project doesn't have is `<package>#lib`, loaded when a name first needs it from
/// the build's other source roots (`JVMWorkspace.externalRoots`), the platform's sources and dependencies'
/// `-sources.jar`s, in that order of preference (a package found in one isn't looked for further).
final class JavaLayout: ProjectLayout {
  var syntax: any LanguageSyntax { JavaSyntax.shared }
  let implicitModules: [String] = []
  let interfaceExtension = ".java"
  let workspace: JVMWorkspace
  let root: String
  /// Where a unit read from an archive came from: its source set and entry.
  var archived: [String: (set: JVMSourceSet, entry: String)] = [:]
  /// The packages the project's own files declare, and every package above them.
  private(set) var projectPrefixes: Set<String> = []

  init(root: String, findsPlatform: Bool = true) {
    self.root = root
    workspace = JVMWorkspace(root: root, extensions: ["java"])
    workspace.findsPlatform = findsPlatform
  }

  func sourceFiles(in directory: String) -> [String] { workspace.sourceFiles(in: directory) }

  func moduleName(ofRelative path: String) -> String {
    let package = JVMWorkspace.packageName(ofFile: path.hasPrefix("/") ? path : root + "/" + path)
    var current = package
    while !current.isEmpty, projectPrefixes.insert(current).inserted {
      guard let dot = current.lastIndex(of: ".") else { break }
      current = String(current[..<dot])
    }
    return package
  }

  static let librarySuffix = "#lib"

  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    guard display.hasSuffix(Self.librarySuffix) else { return nil }
    let package = String(display.dropLast(Self.librarySuffix.count))
    let external = workspace.externalFiles(ofPackage: package)
    if !external.isEmpty {
      return project.register(display, project.parse(external, isInterface: false), isSDK: false)
    }
    var sets: [JVMSourceSet] = []
    if let platform = workspace.platform { sets.append(platform) }
    // Dependencies only for packages the platform doesn't have.
    if workspace.platform?.packages[package] == nil { sets += workspace.dependencies }
    for set in sets {
      guard let entries = set.packages[package], !entries.isEmpty else { continue }
      var units: [Unit] = []
      let syntax = syntax
      for entry in entries where entry.hasSuffix(".java") {
        guard let bytes = set.contents(entry) else { continue }
        let path = set.diskPath(entry)
        archived[path] = (set, entry)
        units.append(Unit(path: path, source: SourceFile(bytes: Data(bytes), profile: syntax.profile), syntax: syntax))
      }
      if units.isEmpty { continue }
      return project.register(display, units, isSDK: true)
    }
    return nil
  }

  /// Whether a dotted name is a package, or a package's prefix, anywhere this project can see.
  func isPackage(_ package: String) -> Bool {
    if projectPrefixes.contains(package) { return true }
    if workspace.externalHasPackage(package) { return true }
    if let platform = workspace.platform, platform.prefixes.contains(package) { return true }
    return workspace.dependencies.contains { $0.prefixes.contains(package) }
  }
}
