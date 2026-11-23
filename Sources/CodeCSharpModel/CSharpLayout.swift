import CodeModel
import CodeScan
import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

/// A C# project (a `.csproj`): what its files are read with and what they see.
struct CSharpProject {
  var name: String
  var directory: String
  /// The `.csproj` file, empty for the loose project.
  var file = ""
  var properties: [String: String] = [:]
  /// `<ProjectReference>`s, as full paths of `.csproj` files.
  var references: [String] = []
  /// `<Using Include="…" Alias="…" Static="true"/>`, and `Remove`.
  var usings: [(name: String, alias: String?, isStatic: Bool, remove: Bool)] = []
  var compile: [(include: String?, remove: String?)] = []
  var isWeb = false

  func property(_ key: String) -> String {
    properties.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value ?? ""
  }

  /// The first target framework: `net10.0`, `netstandard2.0`, `net48`.
  var targetFramework: String {
    var tfm = property("TargetFramework")
    if tfm.isEmpty { tfm = property("TargetFrameworks").split(separator: ";").first.map(String.init) ?? "" }
    if tfm.isEmpty, !property("TargetFrameworkVersion").isEmpty {
      tfm = "net" + property("TargetFrameworkVersion").trimmingCharacters(in: CharacterSet(charactersIn: "v")).replacingOccurrences(of: ".", with: "")
    }
    return tfm.isEmpty ? "net10.0" : tfm.trimmingCharacters(in: .whitespaces).lowercased()
  }

  /// The preprocessor symbols the SDK defines in Debug for its target framework, then `DefineConstants`.
  var symbols: Set<String> {
    var result: Set<String> = ["DEBUG", "TRACE"]
    var tfm = targetFramework
    var platform = ""
    if let dash = tfm.firstIndex(of: "-") {
      platform = String(tfm[tfm.index(after: dash)...])
      tfm = String(tfm[..<dash])
    }
    func numbers(_ text: Substring) -> [Int]? {
      let parts = text.split(separator: ".")
      let values = parts.compactMap { Int($0) }
      return values.count == parts.count && !values.isEmpty ? values : nil
    }
    if tfm.hasPrefix("netstandard"), let version = numbers(tfm.dropFirst("netstandard".count)), version.count == 2 {
      result.formUnion(["NETSTANDARD", "NETSTANDARD\(version[0])_\(version[1])"])
      for (a, b) in [(1, 0), (1, 1), (1, 2), (1, 3), (1, 4), (1, 5), (1, 6), (2, 0), (2, 1)] where a < version[0] || a == version[0] && b <= version[1] {
        result.insert("NETSTANDARD\(a)_\(b)_OR_GREATER")
      }
    } else if tfm.hasPrefix("net"), tfm.contains("."), let version = numbers(tfm.dropFirst(3)), version.count == 2 {
      result.formUnion(["NET", "NET\(version[0])_\(version[1])", "NETCOREAPP"])
      if version[0] >= 5 { for v in 5...version[0] { result.insert("NET\(v)_0_OR_GREATER") } }
      for v in ["1_0", "1_1", "2_0", "2_1", "2_2", "3_0", "3_1"] { result.insert("NETCOREAPP\(v)_OR_GREATER") }
    } else if tfm.hasPrefix("net"), tfm.count >= 4, tfm.count <= 6, tfm.dropFirst(3).allSatisfy(\.isNumber) {
      let digits = String(tfm.dropFirst(3))
      result.formUnion(["NETFRAMEWORK", "NET" + digits])
      let padded = digits.padding(toLength: 3, withPad: "0", startingAt: 0)
      for v in ["20", "30", "35", "40", "45", "451", "452", "46", "461", "462", "47", "471", "472", "48", "481"]
      where v.padding(toLength: 3, withPad: "0", startingAt: 0) <= padded {
        result.insert("NET\(v)_OR_GREATER")
      }
    }
    let os = platform.prefix { $0.isLetter }.uppercased()
    if !os.isEmpty { result.insert(os) }
    for item in property("DefineConstants").split(whereSeparator: { $0 == ";" || $0 == "," }) {
      let symbol = item.trimmingCharacters(in: .whitespaces)
      if !symbol.isEmpty, !symbol.hasPrefix("$(") { result.insert(symbol) }
    }
    return result
  }

  static let implicitBase = ["System", "System.Collections.Generic", "System.IO", "System.Linq", "System.Net.Http", "System.Threading", "System.Threading.Tasks"]
  static let implicitWeb = [
    "System.Net.Http.Json", "Microsoft.AspNetCore.Builder", "Microsoft.AspNetCore.Hosting", "Microsoft.AspNetCore.Http", "Microsoft.AspNetCore.Routing",
    "Microsoft.Extensions.Configuration", "Microsoft.Extensions.DependencyInjection", "Microsoft.Extensions.Hosting", "Microsoft.Extensions.Logging",
  ]

  /// The SDK's generated global usings: the implicit ones when `ImplicitUsings` is on, then `<Using>` items.
  var globalUsings: [(name: String, alias: String?, isStatic: Bool)] {
    var result: [(name: String, alias: String?, isStatic: Bool)] = []
    let implicit = property("ImplicitUsings").lowercased()
    if implicit == "enable" || implicit == "true" {
      for name in Self.implicitBase { result.append((name, nil, false)) }
      if isWeb { for name in Self.implicitWeb { result.append((name, nil, false)) } }
    }
    for item in usings {
      if item.remove { result.removeAll { $0.name == item.name } } else { result.append((item.name, item.alias, item.isStatic)) }
    }
    return result
  }
}

/// C#'s projects: every `.cs` file under the root (bin, obj, node_modules, packages and hidden folders left out) in the
/// deepest folder with a `.csproj` above it (its `<Compile Include/Remove>` followed), files in none in one loose project
/// with implicit usings. A project is the core's module, named as its `.csproj`; namespaces are the model's business,
/// whatever the folders. Each project's properties come from its `Directory.Build.props` files and its own file (the
/// Debug configuration's), for its preprocessor symbols and global usings. The .NET library is `CSharpStd`'s generated
/// stub, one module per namespace (`net:System.Linq`), read when a name first needs it.
final class CSharpLayout: ProjectLayout {
  let syntax: any LanguageSyntax
  let implicitModules: [String] = []
  let interfaceExtension = ".cs"
  let root: String
  /// Projects by module name.
  private(set) var projects: [String: CSharpProject] = [:]
  /// Each file's module name, by full path.
  private var owners: [String: String] = [:]
  private var files: [String] = []
  static let looseName = "<loose>"
  static let libraryPrefix = "net:"
  static let skipped: Set<String> = ["bin", "obj", "node_modules", "packages", ".git", ".vs", ".idea", ".build"]
  /// Where the stub's files are written when one is opened.
  static let stdDirectory = NSTemporaryDirectory() + "code-csharp-std"
  /// The stub's namespaces, and every namespace above them.
  let libraryNamespaces: Set<String>
  let libraryPrefixes: Set<String>
  private let symbolTable: SymbolTable

  final class SymbolTable: @unchecked Sendable {
    var byPath: [String: Set<String>] = [:]
    var fallback: Set<String> = CSharpWord.defaultSymbols
  }

  init(root: String) {
    self.root = root
    let table = SymbolTable()
    symbolTable = table
    syntax = CSharpSyntax(symbols: { path in table.byPath[path] ?? table.fallback })
    var namespaces: Set<String> = []
    var prefixes: Set<String> = []
    for key in CSharpStd.files.keys { namespaces.insert(String(key.dropLast(3))) }
    // Namespaces whose types the stub leaves out still name namespaces (`using Microsoft.AspNetCore.Http;`).
    for namespace in namespaces.union(CSharpStd.namespaces) {
      var current = namespace
      while prefixes.insert(current).inserted, let dot = current.lastIndex(of: ".") { current = String(current[..<dot]) }
    }
    libraryNamespaces = namespaces
    libraryPrefixes = prefixes
    readProjects()
  }

  // MARK: Projects

  private func readProjects() {
    var sources: [String] = []
    var projectFiles: [String] = []
    walk(root) { path in
      if path.hasSuffix(".cs") { sources.append(path) } else if path.hasSuffix(".csproj") { projectFiles.append(path) }
    }
    sources.sort()
    var read: [(file: String, project: CSharpProject)] = projectFiles.sorted().map { ($0, readProject($0)) }
    // Unique module names: a second `App.csproj` is named by its folder too.
    var taken: [String: Int] = [:]
    for index in read.indices {
      let base = read[index].project.name
      taken[base, default: 0] += 1
      if taken[base]! > 1 { read[index].project.name = base + " (" + relative(read[index].project.directory) + ")" }
    }
    let byDepth = read.indices.sorted { read[$0].project.directory.count > read[$1].project.directory.count }
    var claimed: [String: String] = [:]
    var members: [Int: [String]] = [:]
    for file in sources {
      guard let owner = byDepth.first(where: { file.hasPrefix(read[$0].project.directory + "/") }) else { continue }
      if read[owner].project.property("EnableDefaultCompileItems").lowercased() == "false" { continue }
      members[owner, default: []].append(file)
    }
    for index in read.indices {
      var list = members[index] ?? []
      for item in read[index].project.compile {
        if let include = item.include {
          for file in glob(read[index].project.directory, include) where !list.contains(file) { list.append(file) }
        }
        if let remove = item.remove {
          let removed = Set(glob(read[index].project.directory, remove))
          list.removeAll { removed.contains($0) }
        }
      }
      for file in list { claimed[file] = read[index].project.name }
      projects[read[index].project.name] = read[index].project
    }
    let loose = sources.filter { claimed[$0] == nil }
    if !loose.isEmpty {
      var project = CSharpProject(name: Self.looseName, directory: root)
      project.properties["ImplicitUsings"] = "enable"
      projects[Self.looseName] = project
      for file in loose { claimed[file] = Self.looseName }
    }
    owners = claimed
    files = claimed.keys.sorted()
    var symbolsByProject: [String: Set<String>] = [:]
    for (name, project) in projects { symbolsByProject[name] = project.symbols }
    for (file, owner) in claimed { symbolTable.byPath[file] = symbolsByProject[owner] }
    if let first = projects.values.first { symbolTable.fallback = first.symbols }
  }

  private func walk(_ directory: String, _ visit: (String) -> Void) {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
    for entry in entries.sorted() {
      let path = directory + "/" + entry
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
      if isDirectory.boolValue {
        if entry.hasPrefix(".") || Self.skipped.contains(entry) { continue }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeSymbolicLink { continue }
        walk(path, visit)
      } else {
        visit(path)
      }
    }
  }

  private func relative(_ path: String) -> String {
    path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path == root ? "." : path
  }

  /// A project's properties: `Directory.Build.props` from the outermost down (no higher than the root's parent), then
  /// its own file.
  private func readProject(_ file: String) -> CSharpProject {
    let directory = (file as NSString).deletingLastPathComponent
    var project = CSharpProject(name: ((file as NSString).lastPathComponent as NSString).deletingPathExtension, directory: directory, file: file)
    var props: [String] = []
    var current = directory
    let stop = (root as NSString).deletingLastPathComponent
    while current.count >= stop.count {
      let candidate = current + "/Directory.Build.props"
      if FileManager.default.fileExists(atPath: candidate) { props.insert(candidate, at: 0) }
      let parent = (current as NSString).deletingLastPathComponent
      if parent == current { break }
      current = parent
    }
    for path in props + [file] { CSharpProjectReader.read(path, into: &project) }
    return project
  }

  /// Files a `<Compile>` pattern names: `a/b.cs`, `**/*.cs`, `../Shared/*.cs`.
  private func glob(_ directory: String, _ pattern: String) -> [String] {
    var result: [String] = []
    for part in pattern.split(separator: ";") {
      let full = URL(fileURLWithPath: directory + "/" + part.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")).standardizedFileURL.path
      guard let star = full.firstIndex(of: "*") else {
        if FileManager.default.fileExists(atPath: full) { result.append(full) }
        continue
      }
      guard let slash = full[..<star].lastIndex(of: "/") else { continue }
      let base = String(full[..<slash])
      var expression = "^" + NSRegularExpression.escapedPattern(for: full)
      expression = expression.replacingOccurrences(of: "\\*\\*/", with: "(.*/)?").replacingOccurrences(of: "\\*\\*", with: ".*").replacingOccurrences(of: "\\*", with: "[^/]*") + "$"
      guard let regex = try? NSRegularExpression(pattern: expression) else { continue }
      walk(base) { path in
        guard path.hasSuffix(".cs") else { return }
        if regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil { result.append(path) }
      }
    }
    return result
  }

  // MARK: ProjectLayout

  func sourceFiles(in directory: String) -> [String] { files }

  func moduleName(ofRelative path: String) -> String {
    owners[path.hasPrefix("/") ? path : root + "/" + path] ?? Self.looseName
  }

  /// The stub's namespace a module name names: `net:System.Linq`.
  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    guard display.hasPrefix(Self.libraryPrefix) else { return nil }
    let namespace = String(display.dropFirst(Self.libraryPrefix.count))
    let file = namespace + ".cs"
    guard let text = CSharpStd.files[file] else { return nil }
    let unit = Unit(path: Self.stdDirectory + "/" + file, source: SourceFile(text, profile: syntax.profile), syntax: syntax)
    return project.register(display, [unit], isSDK: true)
  }

  /// Writes a stub file where its unit says it is, if it isn't there yet.
  func materialize(_ path: String) {
    guard path.hasPrefix(Self.stdDirectory + "/"), !FileManager.default.fileExists(atPath: path) else { return }
    let file = String(path.dropFirst(Self.stdDirectory.count + 1))
    guard let text = CSharpStd.files[file] else { return }
    try? FileManager.default.createDirectory(atPath: Self.stdDirectory, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
  }

  // MARK: What a project sees

  /// The projects a module's files see: itself, then what it references, transitively.
  func visibleProjects(of moduleName: String) -> [String] {
    var result: [String] = [moduleName]
    var index = 0
    while index < result.count {
      guard let project = projects[result[index]] else {
        index += 1
        continue
      }
      for reference in project.references {
        guard let target = projects.values.first(where: { $0.file == reference }), !result.contains(target.name)
        else { continue }
        result.append(target.name)
      }
      index += 1
    }
    return result
  }

  func globalUsings(of moduleName: String) -> [(name: String, alias: String?, isStatic: Bool)] {
    projects[moduleName]?.globalUsings ?? []
  }
}

/// Reads a project file's properties and items into a project, as MSBuild would in Debug: a condition naming Release
/// isn't taken, one naming Debug or no configuration is.
enum CSharpProjectReader {
  static func read(_ path: String, into project: inout CSharpProject) {
    guard let data = FileManager.default.contents(atPath: path) else { return }
    let reader = XMLProjectParser(directory: (path as NSString).deletingLastPathComponent)
    let parser = XMLParser(data: data)
    parser.delegate = reader
    guard parser.parse() else { return }
    if reader.sdk.contains("Microsoft.NET.Sdk.Web") || reader.isWeb { project.isWeb = true }
    for (key, value) in reader.properties {
      let old = project.properties[key] ?? ""
      project.properties[key] = value.replacingOccurrences(of: "$(" + key + ")", with: old)
    }
    project.references += reader.references
    project.usings += reader.usings
    project.compile += reader.compile
  }
}

final class XMLProjectParser: NSObject, XMLParserDelegate {
  let directory: String
  var sdk = ""
  var properties: [(String, String)] = []
  var references: [String] = []
  var usings: [(name: String, alias: String?, isStatic: Bool, remove: Bool)] = []
  var compile: [(include: String?, remove: String?)] = []
  var isWeb = false
  private var stack: [(name: String, taken: Bool)] = []
  private var text = ""

  init(directory: String) { self.directory = directory }

  private func taken(_ attributes: [String: String]) -> Bool {
    guard let condition = attributes["Condition"] else { return true }
    if condition.contains("Release") { return false }
    return condition.contains("Debug") || !condition.contains("Configuration")
  }

  func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
    let isTaken = (stack.last?.taken ?? true) && taken(attributes)
    if stack.isEmpty, let value = attributes["Sdk"] { sdk = value }
    text = ""
    if isTaken, stack.count >= 1, stack.last?.name == "ItemGroup" {
      let include = attributes["Include"]
      let remove = attributes["Remove"]
      switch element {
      case "ProjectReference":
        if let include {
          references.append(URL(fileURLWithPath: directory + "/" + include.replacingOccurrences(of: "\\", with: "/")).standardizedFileURL.path)
        }
      case "Using":
        if let include { usings.append((include, attributes["Alias"], attributes["Static"]?.lowercased() == "true", false)) }
        if let remove { usings.append((remove, nil, false, true)) }
      case "Compile":
        compile.append((include?.replacingOccurrences(of: "\\", with: "/"), remove?.replacingOccurrences(of: "\\", with: "/")))
      case "FrameworkReference":
        if include == "Microsoft.AspNetCore.App" { isWeb = true }
      default: break
      }
    }
    stack.append((element, isTaken))
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

  func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
    guard let last = stack.popLast() else { return }
    if last.taken, stack.count == 2, stack.last?.name == "PropertyGroup" {
      properties.append((element, text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    text = ""
  }
}
