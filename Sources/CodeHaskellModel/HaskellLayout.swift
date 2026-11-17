import CodeModel
import CodeScan
import Foundation

/// Haskell's projects: every `.hs` and `.hs-boot` file under the root (hidden folders, `dist-newstyle`, `dist` and
/// `node_modules` left out), each its own core module named by its path; the model finds a file by the Haskell module
/// its `module` line names (`Main` without one), preferring the importing file's own package. Packages are the folders
/// with a `.cabal` file or hpack's `package.yaml`; their `default-extensions` count for every file under them (only
/// those that change what names mean are read: `OverloadedRecordDot`, `NoImplicitPrelude`). Modules no file declares
/// come from `HaskellStd`, a hand-written stub of base's and a few common packages' modules, written to
/// `$TMPDIR/code-haskell-std/` when opened. Package sources on disk (`~/.cabal/packages`' tarballs, a GHC
/// installation) aren't read.
final class HaskellLayout: ProjectLayout {
  let syntax: any LanguageSyntax
  let implicitModules: [String] = []
  let interfaceExtension = ".hs"
  let root: String
  /// Package folders (with a `.cabal` or `package.yaml`), longest first.
  private(set) var packages: [String] = []
  static let skipped: Set<String> = ["dist-newstyle", "dist", "node_modules"]
  static let stdDirectory = NSTemporaryDirectory() + "code-haskell-std"

  init(root: String) {
    self.root = root
    var extensions: [String: Set<String>] = [:]
    var found: [String] = []
    Self.walk(root) { path in
      let file = (path as NSString).lastPathComponent
      guard file.hasSuffix(".cabal") || file == "package.yaml", let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
      let folder = (path as NSString).deletingLastPathComponent
      if !found.contains(folder) { found.append(folder) }
      extensions[folder, default: []].formUnion(Self.defaultExtensions(text))
    }
    packages = found.sorted { $0.count > $1.count }
    syntax = HaskellSyntax(packageExtensions: extensions, packages: packages)
  }

  /// The words of `default-extensions:` (and the older `extensions:`), a cabal field or a YAML list.
  static func defaultExtensions(_ text: String) -> Set<String> {
    var result: Set<String> = []
    var inField = false
    var fieldIndent = 0
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
      let stripped = line.trimmingCharacters(in: .whitespaces)
      let indent = line.prefix { $0 == " " || $0 == "\t" }.count
      if stripped.hasPrefix("--") { continue }
      let lower = stripped.lowercased()
      if lower.hasPrefix("default-extensions:") || lower.hasPrefix("extensions:") {
        inField = true
        fieldIndent = indent
        let value = stripped[stripped.index(after: stripped.firstIndex(of: ":")!)...]
        for word in value.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "[" || $0 == "]" || $0 == "\t" }) { result.insert(String(word)) }
        continue
      }
      if inField {
        if stripped.isEmpty { continue }
        if indent <= fieldIndent, !stripped.hasPrefix("-") || indent < fieldIndent { inField = false; continue }
        if stripped.contains(":"), !stripped.hasPrefix("-") { inField = false; continue }
        for word in stripped.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "-" || $0 == "\t" }) { result.insert(String(word)) }
      }
    }
    return result
  }

  /// The package a file belongs to: the deepest package folder above it, or the root.
  func package(of path: String) -> String {
    packages.first { path.hasPrefix($0 + "/") } ?? root
  }

  // MARK: Files

  func sourceFiles(in directory: String) -> [String] {
    var result: [String] = []
    Self.walk(directory) { if $0.hasSuffix(".hs") || $0.hasSuffix(".hs-boot") { result.append($0) } }
    return result.sorted()
  }

  static func walk(_ directory: String, depth: Int = 0, _ visit: (String) -> Void) {
    guard depth < 40, let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
    for entry in entries.sorted() {
      let path = directory + "/" + entry
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
      if isDirectory.boolValue {
        if entry.hasPrefix(".") || skipped.contains(entry) { continue }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeSymbolicLink { continue }
        walk(path, depth: depth + 1, visit)
      } else {
        visit(path)
      }
    }
  }

  func moduleName(ofRelative path: String) -> String { path }

  /// A module of the stub, by its Haskell name.
  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    guard let source = HaskellStd.modules[display] else { return nil }
    let path = Self.stdDirectory + "/" + display + ".hs"
    if (try? String(contentsOfFile: path, encoding: .utf8)) != source {
      try? FileManager.default.createDirectory(atPath: Self.stdDirectory, withIntermediateDirectories: true)
      try? source.write(toFile: path, atomically: true, encoding: .utf8)
    }
    let unit = Unit(path: path, source: SourceFile(source, profile: syntax.profile), syntax: syntax, isInterface: true)
    return project.register(display, [unit], isSDK: true)
  }
}
