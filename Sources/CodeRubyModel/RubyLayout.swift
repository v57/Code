import CodeModel
import CodeScan
import Foundation

/// Ruby's projects: every `.rb`, `.rake`, `.gemspec` and `.ru` file under the root and the files Ruby names without an
/// extension (`Rakefile`, `Gemfile`), each its own module named by its path (`vendor`, `node_modules`, `tmp`, `log`,
/// `coverage` and hidden folders left out). Constants are global in Ruby, so names are found across every file read
/// (the model's table). Files outside the project are read when a `require` reaches them, through Ruby's load path as
/// a run would see it: the project's `lib` (and `test`, `spec`) folders, the folders a file adds to `$LOAD_PATH`, the
/// gems `Gemfile.lock` names (found where Bundler installs them: `.bundle/config`'s `BUNDLE_PATH`, `vendor/bundle`,
/// `GEM_HOME`, the user's and the system's gem folders; read in place, never installed), then the standard library of
/// the newest Ruby on disk (`CODE_RUBY_STDLIB` overrides). Ruby's core classes, written in C, come from `RubyStd`, a
/// stub generated from the rbs gem's core signatures (module `ruby`), written to `$TMPDIR/code-ruby-std/` when opened.
final class RubyLayout: ProjectLayout {
  let syntax: any LanguageSyntax = RubySyntax()
  let implicitModules: [String] = []
  let interfaceExtension = ".rb"
  let root: String
  /// Folders `require` searches, in order (the project's, then the gems'), without the standard library.
  private(set) var loadPaths: [String] = []
  /// The gems `Gemfile.lock` names, by name: their folder.
  private(set) var gems: [String: String] = [:]
  let standardLibrary: String?
  private var resolved: [String: String?] = [:]
  private var installedGems: [String: String]?
  static let skipped: Set<String> = ["vendor", "node_modules", "tmp", "log", "coverage", "pkg"]
  static let extensions: Set<String> = ["rb", "rake", "gemspec", "ru"]
  static let namedFiles: Set<String> = ["Rakefile", "Gemfile", "Guardfile", "Capfile", "Podfile", "Fastfile", "Brewfile", "Vagrantfile", "Dangerfile"]
  static let stdModule = "ruby"
  static let stdDirectory = NSTemporaryDirectory() + "code-ruby-std"

  init(root: String) {
    self.root = root
    standardLibrary = Self.findStandardLibrary()
    for folder in ["lib", "test", "spec"] where Self.isDirectory(root + "/" + folder) { loadPaths.append(root + "/" + folder) }
    readGems()
  }

  static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  // MARK: Files

  static func isRubyFile(_ path: String) -> Bool {
    let file = path.split(separator: "/").last.map(String.init) ?? path
    if namedFiles.contains(file) { return true }
    guard let dot = file.lastIndex(of: ".") else { return false }
    return extensions.contains(file[file.index(after: dot)...].lowercased())
  }

  func sourceFiles(in directory: String) -> [String] {
    var result: [String] = []
    walk(directory) { if Self.isRubyFile($0) { result.append($0) } }
    return result.sorted()
  }

  private func walk(_ directory: String, depth: Int = 0, _ visit: (String) -> Void) {
    guard depth < 40, let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
    for entry in entries.sorted() {
      let path = directory + "/" + entry
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
      if isDirectory.boolValue {
        if entry.hasPrefix(".") || Self.skipped.contains(entry) { continue }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeSymbolicLink { continue }
        walk(path, depth: depth + 1, visit)
      } else {
        visit(path)
      }
    }
  }

  func moduleName(ofRelative path: String) -> String { path }

  /// A file outside the project by its absolute path, or the stub.
  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    if display == Self.stdModule {
      let path = Self.stdDirectory + "/core.rb"
      if (try? String(contentsOfFile: path, encoding: .utf8)) != RubyStd.source {
        try? FileManager.default.createDirectory(atPath: Self.stdDirectory, withIntermediateDirectories: true)
        try? RubyStd.source.write(toFile: path, atomically: true, encoding: .utf8)
      }
      let unit = Unit(path: path, source: SourceFile(RubyStd.source, profile: syntax.profile), syntax: syntax, isInterface: true)
      return project.register(display, [unit], isSDK: true)
    }
    guard display.hasPrefix("/"), FileManager.default.fileExists(atPath: display) else { return nil }
    let units = project.parse([display], isInterface: false)
    guard !units.isEmpty else { return nil }
    return project.register(display, units, isSDK: standardLibrary.map { display.hasPrefix($0 + "/") } ?? false)
  }

  // MARK: Load path

  /// A folder a project file adds to `$LOAD_PATH`, ahead of the rest.
  func addLoadPath(_ path: String) {
    let standardized = Self.standardize(path)
    guard !loadPaths.contains(standardized), Self.isDirectory(standardized) else { return }
    loadPaths.insert(standardized, at: 0)
    resolved.removeAll()
  }

  /// The file `require 'feature'` loads: the load path, the gems, the standard library, any installed gem of the
  /// feature's first part; nil when none is on disk (a C extension's `.so` counts as none).
  func resolve(feature: String) -> String? {
    if let known = resolved[feature] { return known }
    let found = findFeature(feature)
    resolved[feature] = found
    return found
  }

  private func findFeature(_ feature: String) -> String? {
    let file = feature.hasSuffix(".rb") ? feature : feature + ".rb"
    if feature.hasPrefix("/") { return FileManager.default.fileExists(atPath: file) ? file : nil }
    for folder in loadPaths {
      let path = folder + "/" + file
      if FileManager.default.fileExists(atPath: path) { return path }
    }
    for (_, folder) in gems.sorted(by: { $0.key < $1.key }) {
      for lib in Self.requirePaths(gem: folder) {
        let path = lib + "/" + file
        if FileManager.default.fileExists(atPath: path) { return path }
      }
    }
    if let standardLibrary {
      let path = standardLibrary + "/" + file
      if FileManager.default.fileExists(atPath: path) { return path }
    }
    // RubyGems finds any installed gem's file: one named like the feature's first part.
    let head = String(feature.split(separator: "/").first ?? "")
    for candidate in [head, head.replacingOccurrences(of: "_", with: "-")] {
      if let folder = installed()[candidate] {
        for lib in Self.requirePaths(gem: folder) {
          let path = lib + "/" + file
          if FileManager.default.fileExists(atPath: path) { return path }
        }
      }
    }
    return nil
  }

  /// A gem's `require_paths` from its specification, else `lib`.
  static func requirePaths(gem folder: String) -> [String] {
    let name = (folder as NSString).lastPathComponent
    let spec = ((folder as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent + "/specifications/" + name + ".gemspec"
    if let text = try? String(contentsOfFile: spec, encoding: .utf8), let line = text.split(separator: "\n").first(where: { $0.contains("require_paths =") }) {
      let parts = line.split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
      if !parts.isEmpty { return parts.map { folder + "/" + $0 } }
    }
    return [folder + "/lib"]
  }

  // MARK: Gems

  /// The folders gems are installed in, nearest first.
  private func gemFolders() -> [String] {
    var folders: [String] = []
    func addVersions(_ base: String, _ suffix: String = "/gems") {
      guard let versions = try? FileManager.default.contentsOfDirectory(atPath: base) else { return }
      for version in versions.sorted(by: >) where Self.isDirectory(base + "/" + version + suffix) { folders.append(base + "/" + version + suffix) }
    }
    var bundlePaths: [String] = []
    for config in [root + "/.bundle/config", NSHomeDirectory() + "/.bundle/config"] {
      guard let text = try? String(contentsOfFile: config, encoding: .utf8) else { continue }
      for line in text.split(separator: "\n") where line.hasPrefix("BUNDLE_PATH:") {
        var value = line.dropFirst("BUNDLE_PATH:".count).trimmingCharacters(in: .whitespaces)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        bundlePaths.append(value.hasPrefix("/") ? value : value.hasPrefix("~") ? NSHomeDirectory() + value.dropFirst() : root + "/" + value)
      }
    }
    bundlePaths.append(root + "/vendor/bundle")
    for path in bundlePaths { addVersions(path + "/ruby") }
    let environment = ProcessInfo.processInfo.environment
    for variable in ["GEM_HOME", "GEM_PATH"] {
      for path in (environment[variable] ?? "").split(separator: ":") where Self.isDirectory(path + "/gems") { folders.append(path + "/gems") }
    }
    let home = NSHomeDirectory()
    addVersions(home + "/.gem/ruby")
    addVersions(home + "/.local/share/gem/ruby")
    for manager in [home + "/.rbenv/versions", home + "/.rubies", home + "/.asdf/installs/ruby"] {
      guard let rubies = try? FileManager.default.contentsOfDirectory(atPath: manager) else { continue }
      for ruby in rubies.sorted(by: >) { addVersions(manager + "/" + ruby + "/lib/ruby/gems") }
    }
    for base in ["/opt/homebrew/lib/ruby/gems", "/usr/local/lib/ruby/gems", "/Library/Ruby/Gems", "/var/lib/gems", "/usr/lib/ruby/gems",
      "/System/Library/Frameworks/Ruby.framework/Versions/Current/usr/lib/ruby/gems"]
    {
      addVersions(base)
    }
    var seen: Set<String> = []
    return folders.filter { seen.insert(Self.standardize($0)).inserted }
  }

  /// `Gemfile.lock`'s gems (the root's or the nearest above it), each at its locked version where installed, else the
  /// newest installed.
  private func readGems() {
    var directory = root
    var lock: String?
    for _ in 0..<4 {
      if let text = try? String(contentsOfFile: directory + "/Gemfile.lock", encoding: .utf8) {
        lock = text
        break
      }
      let parent = (directory as NSString).deletingLastPathComponent
      if parent == directory { break }
      directory = parent
    }
    guard let lock else { return }
    var specs: [(String, String)] = []
    var inSpecs = false
    for line in lock.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("  specs:") {
        inSpecs = true
        continue
      }
      if !line.hasPrefix(" ") { inSpecs = false }
      guard inSpecs, line.hasPrefix("    "), !line.hasPrefix("     ") else { continue }
      let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
      guard parts.count == 2 else { continue }
      specs.append((String(parts[0]), parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))))
    }
    let folders = gemFolders()
    for (gem, version) in specs {
      var found: String?
      for folder in folders {
        let exact = folder + "/" + gem + "-" + version
        if Self.isDirectory(exact) {
          found = exact
          break
        }
        // A platform's build: `name-version-arm64-darwin`.
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: folder), let match = entries.first(where: { $0.hasPrefix(gem + "-" + version + "-") }) {
          found = folder + "/" + match
          break
        }
      }
      if let found = found ?? installed()[gem] { gems[gem] = found }
    }
  }

  /// Every installed gem by name, its newest version's folder.
  private func installed() -> [String: String] {
    if let installedGems { return installedGems }
    var map: [String: (version: [Int], path: String)] = [:]
    for folder in gemFolders() {
      for entry in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
        // `name-1.2.3`: the name is up to the last `-` before a digit.
        guard let dash = entry.indices.reversed().first(where: { entry[$0] == "-" && entry.index(after: $0) < entry.endIndex && entry[entry.index(after: $0)].isNumber }) else { continue }
        let gem = String(entry[..<dash])
        let version = entry[entry.index(after: dash)...].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if let known = map[gem], known.version.lexicographicallyPrecedes(version) == false { continue }
        map[gem] = (version, folder + "/" + entry)
      }
    }
    installedGems = map.mapValues(\.path)
    return installedGems!
  }

  // MARK: Standard library

  /// The newest Ruby's `lib/ruby/<version>` on disk.
  static func findStandardLibrary() -> String? {
    if let given = ProcessInfo.processInfo.environment["CODE_RUBY_STDLIB"], isDirectory(given) { return given }
    let home = NSHomeDirectory()
    var bases = ["/opt/homebrew/opt/ruby/lib/ruby", "/usr/local/opt/ruby/lib/ruby", "/usr/lib/ruby", "/usr/local/lib/ruby",
      "/System/Library/Frameworks/Ruby.framework/Versions/Current/usr/lib/ruby"]
    for manager in [home + "/.rbenv/versions", home + "/.rubies", home + "/.asdf/installs/ruby"] {
      for ruby in (try? FileManager.default.contentsOfDirectory(atPath: manager)) ?? [] { bases.append(manager + "/" + ruby + "/lib/ruby") }
    }
    var best: (version: [Int], path: String)?
    for base in bases {
      for entry in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] {
        let version = entry.split(separator: ".").compactMap { Int($0) }
        guard version.count == 3, FileManager.default.fileExists(atPath: base + "/" + entry + "/set.rb") else { continue }
        if let known = best, !known.version.lexicographicallyPrecedes(version) { continue }
        best = (version, base + "/" + entry)
      }
    }
    return best.map { standardize($0.path) }
  }

  static func standardize(_ path: String) -> String {
    var parts: [Substring] = []
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
      if part == "." { continue }
      if part == "..", !parts.isEmpty, parts.last != ".." {
        parts.removeLast()
        continue
      }
      parts.append(part)
    }
    return "/" + parts.joined(separator: "/")
  }
}
