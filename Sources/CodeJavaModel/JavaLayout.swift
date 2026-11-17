import CodeModel
import CodeScan
import Foundation

/// Java's projects: every `.java` file under the root, grouped by the package its `package` line names (a package is
/// the core's module). A package the project doesn't have is `<package>#lib`, loaded when a name first needs it from
/// the build's other source roots (`JVMWorkspace.externalRoots`), the platform's sources and dependencies'
/// `-sources.jar`s, in that order of preference (a package found in one isn't looked for further). Kotlin's front end
/// takes it with its own extensions, a syntax that reads each file in its language and its standard library's sources
/// as `extraSets`, looked in before the platform's; Scala's also its own reading of a file's package
/// (`packageOfFile`: chained `package` clauses).
package final class JavaLayout: ProjectLayout {
  package let syntax: any LanguageSyntax
  /// Sources a front end adds, looked in before the platform's (Kotlin's standard library).
  package let extraSets: [JVMSourceSet]
  package let implicitModules: [String] = []
  package let interfaceExtension = ".java"
  package let workspace: JVMWorkspace
  let root: String
  /// Where a unit read from an archive came from: its source set and entry.
  package var archived: [String: (set: JVMSourceSet, entry: String)] = [:]
  /// The packages the project's own files declare, and every package above them.
  private(set) var projectPrefixes: Set<String> = []
  /// A file's package by its absolute path, when the front end reads it differently from Java's `package` line.
  let packageOfFile: ((String) -> String)?

  package init(
    root: String, findsPlatform: Bool = true, extensions: Set<String> = ["java"], syntax: any LanguageSyntax = JavaSyntax.shared, extraSets: [JVMSourceSet] = [],
    packageOfFile: ((String) -> String)? = nil
  ) {
    self.root = root
    self.syntax = syntax
    self.extraSets = extraSets
    self.packageOfFile = packageOfFile
    workspace = JVMWorkspace(root: root, extensions: extensions)
    workspace.findsPlatform = findsPlatform
  }

  package func sourceFiles(in directory: String) -> [String] { workspace.sourceFiles(in: directory) }

  package func moduleName(ofRelative path: String) -> String {
    let absolute = path.hasPrefix("/") ? path : root + "/" + path
    let package = packageOfFile?(absolute) ?? JVMWorkspace.packageName(ofFile: absolute)
    var current = package
    while !current.isEmpty, projectPrefixes.insert(current).inserted {
      guard let dot = current.lastIndex(of: ".") else { break }
      current = String(current[..<dot])
    }
    return package
  }

  package static let librarySuffix = "#lib"

  package func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    guard display.hasSuffix(Self.librarySuffix) else { return nil }
    let package = String(display.dropLast(Self.librarySuffix.count))
    let external = workspace.externalFiles(ofPackage: package)
    if !external.isEmpty {
      return project.register(display, project.parse(external, isInterface: false), isSDK: false)
    }
    var sets: [JVMSourceSet] = extraSets.filter { $0.packages[package] != nil }
    if let platform = workspace.platform { sets.append(platform) }
    // Dependencies only for packages the platform doesn't have.
    if workspace.platform?.packages[package] == nil { sets += workspace.dependencies }
    for set in sets {
      guard let entries = set.packages[package], !entries.isEmpty else { continue }
      var units: [Unit] = []
      let syntax = syntax
      for entry in entries {
        guard let dot = entry.lastIndex(of: "."), workspace.extensions.contains(String(entry[entry.index(after: dot)...])), let bytes = set.contents(entry) else { continue }
        let path = set.diskPath(entry)
        archived[path] = (set, entry)
        let reader = syntax.syntax(forPath: entry)
        units.append(Unit(path: path, source: SourceFile(bytes: Data(bytes), profile: reader.profile), syntax: reader))
      }
      if units.isEmpty { continue }
      return project.register(display, units, isSDK: true)
    }
    return nil
  }

  /// Whether a dotted name is a package, or a package's prefix, anywhere this project can see.
  package func isPackage(_ package: String) -> Bool {
    if projectPrefixes.contains(package) { return true }
    if extraSets.contains(where: { $0.prefixes.contains(package) }) { return true }
    if workspace.externalHasPackage(package) { return true }
    if let platform = workspace.platform, platform.prefixes.contains(package) { return true }
    return workspace.dependencies.contains { $0.prefixes.contains(package) }
  }
}
