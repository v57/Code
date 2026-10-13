import Foundation

/// A package a project depends on, for the navigator's Package Dependencies
/// (as in Xcode): its name, version, and where its sources are on disk.
public struct PackageDependency: Identifiable, Hashable, Sendable {
  public enum Ecosystem: String, Sendable, CaseIterable {
    case swift, node, rust, go, python, ruby, php, dart, cocoaPods, elixir, dotnet, java

    public var displayName: String {
      switch self {
      case .swift: return "Swift Package"
      case .node: return "npm"
      case .rust: return "Cargo"
      case .go: return "Go module"
      case .python: return "Python"
      case .ruby: return "RubyGems"
      case .php: return "Composer"
      case .dart: return "pub"
      case .cocoaPods: return "CocoaPods"
      case .elixir: return "Hex"
      case .dotnet: return "NuGet"
      case .java: return "Maven"
      }
    }
  }

  public var name: String
  /// The resolved version (or branch or revision); nil when unknown.
  public var version: String?
  /// A package in a folder next to the project rather than a download.
  public var isLocal: Bool
  public var ecosystem: Ecosystem
  /// The package's folder, when its sources are on disk.
  public var location: URL?
  /// Where it comes from: a repository URL, a path, Maven coordinates.
  public var source: String?

  public init(
    name: String, version: String? = nil, isLocal: Bool = false, ecosystem: Ecosystem,
    location: URL? = nil, source: String? = nil
  ) {
    self.name = name
    self.version = version
    self.isLocal = isLocal
    self.ecosystem = ecosystem
    self.location = location
    self.source = source
  }

  public var id: String { location?.standardizedFileURL.path ?? ecosystem.rawValue + ":" + name }

  /// What the navigator shows after the name: "local" or the version.
  public var detail: String { isLocal ? "local" : version ?? "" }
}

/// Finds a project's package dependencies from its manifests and lockfiles,
/// and their sources where package managers keep them. Reads files only;
/// nothing is resolved or downloaded.
public enum DependencyScanner {
  /// Files whose changes can change the dependencies.
  public static let manifestNames: Set<String> = [
    "Package.swift", "Package.resolved", "project.pbxproj", "package.json", "package-lock.json",
    "yarn.lock", "pnpm-lock.yaml", "Cargo.toml", "Cargo.lock", "go.mod", "pyproject.toml",
    "requirements.txt", "poetry.lock", "uv.lock", "Gemfile", "Gemfile.lock", "composer.json",
    "composer.lock", "pubspec.yaml", "pubspec.lock", "Podfile", "Podfile.lock", "mix.exs", "mix.lock",
    "Directory.Packages.props", "build.gradle", "build.gradle.kts", "libs.versions.toml", "pom.xml",
  ]

  public static func isManifest(_ name: String) -> Bool {
    manifestNames.contains(name) || name.hasSuffix(".csproj") || name.hasSuffix(".fsproj")
  }

  /// The dependencies of the project at `root`, sorted by name.
  public static func scan(
    _ root: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory()),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [PackageDependency] {
    let folder = DependencyFolder(root: root.standardizedFileURL, home: home, environment: environment)
    var found: [PackageDependency] = []
    found += swiftPackages(folder)
    found += nodePackages(folder)
    found += rustCrates(folder)
    found += goModules(folder)
    found += pythonPackages(folder)
    found += rubyGems(folder)
    found += composerPackages(folder)
    found += dartPackages(folder)
    found += cocoaPods(folder)
    found += elixirPackages(folder)
    found += nugetPackages(folder)
    found += javaPackages(folder)
    // The same package from two manifests (Package.swift and an Xcode
    // project) counts once.
    var seen = Set<String>()
    return found.filter { seen.insert($0.id).inserted }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
}

/// A project folder and the places package managers keep downloads.
struct DependencyFolder {
  let root: URL
  let home: URL
  let environment: [String: String]

  func url(_ path: String) -> URL { root.appendingPathComponent(path) }

  func read(_ path: String) -> String? { Self.read(url(path)) }

  static func read(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  func children(_ url: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
  }

  /// `url` when it is a folder.
  func folder(_ url: URL) -> URL? { isDirectory(url) ? url : nil }

  /// Folders matching `components` under `base`, where "*" matches any
  /// name.
  func glob(_ base: URL, _ components: [String]) -> [URL] {
    var urls = [base]
    for component in components {
      urls = urls.flatMap { url -> [URL] in
        if component == "*" {
          return children(url).map { url.appendingPathComponent($0) }.filter(isDirectory)
        }
        let next = url.appendingPathComponent(component)
        return isDirectory(next) ? [next] : []
      }
    }
    return urls
  }

  /// A path from a manifest, relative to the project (or absolute, or
  /// under the home folder).
  func resolve(_ path: String) -> URL {
    let path = path.replacingOccurrences(of: "\\", with: "/")
    if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
    if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL }
    return root.appendingPathComponent(path).standardizedFileURL
  }

  func environmentPath(_ name: String) -> URL? {
    environment[name].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
  }
}

// MARK: - Text helpers

extension String {
  /// The capture groups of every match of `pattern`.
  func matches(_ pattern: String, options: NSRegularExpression.Options = []) -> [[String]] {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
    let text = self as NSString
    return expression.matches(in: self, range: NSRange(location: 0, length: text.length)).map { match in
      (1..<match.numberOfRanges).map { index in
        let range = match.range(at: index)
        return range.location == NSNotFound ? "" : text.substring(with: range)
      }
    }
  }

  /// The first capture group of the first match of `pattern`.
  func firstMatch(_ pattern: String, options: NSRegularExpression.Options = []) -> String? {
    matches(pattern, options: options).first?.first
  }

  var unquoted: String {
    var text = trimmingCharacters(in: .whitespaces)
    if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
      text = String(text.dropFirst().dropLast())
    }
    return text
  }
}
