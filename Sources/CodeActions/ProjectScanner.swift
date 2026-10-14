import CryptoKit
import Foundation

/// A folder being looked at for projects: its top-level entries, listed
/// once and shared by every detector, which read only the one or two files
/// they need.
public struct ProjectFolder: Sendable {
  public struct Entry: Hashable, Sendable {
    public let name: String
    public let isDirectory: Bool
  }

  public let url: URL
  public let entries: [Entry]

  public init(url: URL, entries: [Entry]) {
    self.url = url
    self.entries = entries
  }

  /// Lists `url`'s entries, without hidden ones.
  public init(listing url: URL) {
    let keys: [URLResourceKey] = [.isDirectoryKey]
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
    self.init(
      url: url,
      entries: urls.map {
        Entry(
          name: $0.lastPathComponent,
          isDirectory: (try? $0.resourceValues(forKeys: Set(keys)).isDirectory) ?? false)
      }.sorted { $0.name < $1.name })
  }

  public var name: String { url.lastPathComponent }

  public func hasFile(_ name: String) -> Bool {
    entries.contains { $0.name == name && !$0.isDirectory }
  }

  public func hasDirectory(_ name: String) -> Bool {
    entries.contains { $0.name == name && $0.isDirectory }
  }

  public func first(withSuffix suffix: String) -> String? {
    entries.first { $0.name.hasSuffix(suffix) }?.name
  }

  public func read(_ name: String) -> String? {
    try? String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
  }

  public func subfolder(_ name: String) -> ProjectFolder {
    ProjectFolder(listing: url.appendingPathComponent(name))
  }
}

/// Finds the schemes of one kind of project in a folder.
public protocol ProjectDetector: Sendable {
  /// The schemes for `folder`; empty when it isn't this kind of project.
  func schemes(in folder: ProjectFolder) -> [ActionScheme]
}

/// Finds every project in a workspace folder: the folder itself and its
/// subfolders a few levels down (a folder of several projects, like a
/// repository with one implementation per language), skipping build output
/// and dependencies.
public enum ProjectScanner {
  public static let detectors: [any ProjectDetector] = [
    XcodeDetector(), SwiftPackageDetector(), CargoDetector(), GoDetector(), GradleDetector(),
    MavenDetector(), NodeDetector(), PythonDetector(), CMakeDetector(), ZigDetector(),
    DartDetector(), DotnetDetector(), ElixirDetector(), RubyDetector(), PHPDetector(),
    DockerComposeDetector(),
  ]

  /// Bumped whenever a detector finds different schemes or commands, so
  /// scans cached under `fingerprint(of:)` are redone.
  public static let revision = 1

  /// Folders never searched: build products, dependencies, caches.
  public static let skippedFolders: Set<String> = [
    "node_modules", "build", "target", "vendor", "deps", "_build", "coverage", "cover",
    "DerivedData", "Pods", "Carthage", "dist", "out", "bin", "obj", "venv", "__pycache__",
    "Tests", "tests", "test", "docs", "documentation", "scripts", "Sources", "src", "lib",
    "static", "assets", "Resources",
  ]

  /// Schemes of every project under `root`, the root's first.
  public static func scan(root: URL, depth: Int = 2, excluded: Set<String> = []) -> [ActionScheme] {
    var schemes: [ActionScheme] = []
    var queue: [(URL, Int)] = [(root, 0)]
    while !queue.isEmpty {
      let (url, level) = queue.removeFirst()
      let folder = ProjectFolder(listing: url)
      let found = Self.schemes(in: folder)
      schemes += found
      // Modules of a multi-module build are part of its schemes already.
      let isMultiModule = found.contains {
        [.gradle, .android, .maven, .cargo, .dotnet].contains($0.toolchain)
      }
      guard level < depth, !isMultiModule else { continue }
      for entry in folder.entries where entry.isDirectory {
        let name = entry.name
        guard !skippedFolders.contains(name), !excluded.contains(name), !name.hasPrefix("build"),
          !name.hasSuffix(".xcodeproj"), !name.hasSuffix(".xcworkspace"),
          !name.hasSuffix(".app"), !name.hasSuffix(".xcassets"), !name.hasSuffix(".lproj")
        else { continue }
        queue.append((url.appendingPathComponent(name), level + 1))
      }
    }
    return schemes
  }

  /// The schemes of the projects in `folder` itself, without its subfolders.
  public static func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    var found: [ActionScheme] = []
    for detector in detectors { found += detector.schemes(in: folder) }
    // A Makefile is a project of its own only when nothing else is.
    if found.isEmpty { found = MakeDetector().schemes(in: folder) }
    return found
  }

  /// Identifies what `schemes(in:)` finds in `folder`: its entries' names and
  /// kinds, and the detectors' `revision`. A cached scan of the folder is
  /// current while this is unchanged (edits inside a manifest aren't seen).
  public static func fingerprint(of folder: ProjectFolder) -> String {
    let entries = folder.entries.map { ($0.isDirectory ? "d:" : "f:") + $0.name }.sorted()
    let digest = SHA256.hash(data: Data(([String(revision)] + entries).joined(separator: "\n").utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

/// Shell quoting for paths and names put into commands.
public func shellQuote(_ text: String) -> String {
  let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@%+,"))
  if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
  return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The first match of `pattern`'s capture groups in `text`, for each match.
func matches(of pattern: String, in text: String, options: NSRegularExpression.Options = [])
  -> [[String]]
{
  guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  return regex.matches(in: text, range: range).map { match in
    (1..<max(1, match.numberOfRanges)).map { index in
      Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }
  }
}
