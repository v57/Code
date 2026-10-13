import Foundation

// The direct dependencies of projects in other languages: their manifests
// say what the project asks for, their lockfiles which version it got, and
// each package manager's cache (or the project's install folder) has the
// sources.

extension DependencyScanner {
  // MARK: - npm, Yarn, pnpm

  /// package.json's dependencies and devDependencies, with the version
  /// installed in node_modules.
  static func nodePackages(_ folder: DependencyFolder) -> [PackageDependency] {
    guard let text = folder.read("package.json"),
      let manifest = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { return [] }
    var found: [PackageDependency] = []
    for key in ["dependencies", "devDependencies", "optionalDependencies"] {
      for (name, spec) in (manifest[key] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }) {
        let installed = folder.url("node_modules/" + name)
        let version = DependencyFolder.read(installed.appendingPathComponent("package.json"))
          .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["version"] as? String
        let localPrefixes = ["file:", "link:", "workspace:", "portal:"]
        let local = localPrefixes.first { spec.hasPrefix($0) }
        var location = folder.folder(installed)
        if let local, location == nil, local != "workspace:" {
          location = folder.folder(folder.resolve(String(spec.dropFirst(local.count))))
        }
        found.append(
          PackageDependency(
            name: name, version: version ?? spec, isLocal: local != nil, ecosystem: .node, location: location,
            source: spec))
      }
    }
    return found
  }

  // MARK: - Cargo

  /// Cargo.toml's dependency tables (a workspace's and its members'), with
  /// versions from Cargo.lock; sources in Cargo's registry cache, or the
  /// path of a path dependency.
  static func rustCrates(_ folder: DependencyFolder) -> [PackageDependency] {
    guard let manifest = folder.read("Cargo.toml") else { return [] }
    let locked = cargoLockVersions(folder.read("Cargo.lock") ?? "")
    let cargoHome = folder.environmentPath("CARGO_HOME") ?? folder.home.appendingPathComponent(".cargo")
    let registries = folder.glob(cargoHome, ["registry", "src", "*"])
    // A workspace's members are the project, not dependencies.
    let members = cargoMembers(manifest).flatMap { member in
      folder.glob(folder.root, member.split(separator: "/").map(String.init))
    }
    var manifests = [(text: manifest, folder: folder.root)]
    for member in members {
      if let text = DependencyFolder.read(member.appendingPathComponent("Cargo.toml")) {
        manifests.append((text, member))
      }
    }
    let memberPaths = Set(members.map(\.standardizedFileURL.path))
    var seen = Set<String>()
    var found: [PackageDependency] = []
    for manifest in manifests {
      for dependency in cargoDependencies(manifest.text) where seen.insert(dependency.name).inserted {
        let path = dependency.path.map { manifest.folder.appendingPathComponent($0).standardizedFileURL }
        if let path, memberPaths.contains(path.path) { continue }
        let version = locked[dependency.name] ?? dependency.version
        var location: URL?
        if let path {
          location = folder.folder(path)
        } else if let version {
          location = registries.lazy.map { $0.appendingPathComponent(dependency.name + "-" + version) }
            .first(where: folder.isDirectory)
        }
        found.append(
          PackageDependency(
            name: dependency.name, version: version, isLocal: path != nil, ecosystem: .rust,
            location: location, source: dependency.path))
      }
    }
    return found
  }

  /// `members = ["crates/*", …]` of a `[workspace]` table.
  static func cargoMembers(_ manifest: String) -> [String] {
    guard let workspace = tomlTable(manifest, "workspace"),
      let list = workspace.firstMatch(#"(?s)members\s*=\s*\[(.*?)\]"#)
    else { return [] }
    return list.matches(#""([^"]+)""#).map { $0[0] }
  }

  struct ManifestEntry: Equatable {
    var name: String
    var version: String?
    var path: String?
  }

  /// The entries of `[dependencies]`, `[dev-dependencies]`,
  /// `[build-dependencies]`, `[workspace.dependencies]` and target tables,
  /// inline (`a = "1"`, `a = { version = "1", path = "../a" }`) or as
  /// their own table (`[dependencies.a]`).
  static func cargoDependencies(_ manifest: String) -> [ManifestEntry] {
    var entries: [ManifestEntry] = []
    var table = ""
    var current: ManifestEntry?
    func isDependencyTable(_ name: String) -> Bool {
      name.hasSuffix("dependencies")
    }
    for raw in manifest.split(whereSeparator: \.isNewline) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("#") || line.isEmpty { continue }
      if line.hasPrefix("[") {
        if let entry = current { entries.append(entry) }
        current = nil
        table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        // [dependencies.serde]
        if let dot = table.lastIndex(of: "."), isDependencyTable(String(table[..<dot])) {
          current = ManifestEntry(name: String(table[table.index(after: dot)...]).unquoted)
        }
        continue
      }
      guard let equals = line.firstIndex(of: "=") else { continue }
      let key = line[..<equals].trimmingCharacters(in: .whitespaces).unquoted
      let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
      if var entry = current {
        if key == "version" { entry.version = value.unquoted }
        if key == "path" { entry.path = value.unquoted }
        current = entry
      } else if isDependencyTable(table) {
        if value.hasPrefix("{") {
          entries.append(
            ManifestEntry(
              name: key, version: value.firstMatch(#"version\s*=\s*"([^"]+)""#),
              path: value.firstMatch(#"path\s*=\s*"([^"]+)""#)))
        } else {
          entries.append(ManifestEntry(name: key, version: value.unquoted))
        }
      }
    }
    if let entry = current { entries.append(entry) }
    var seen = Set<String>()
    return entries.filter { seen.insert($0.name).inserted }
  }

  /// Package names and versions in Cargo.lock (the first of each name).
  static func cargoLockVersions(_ lock: String) -> [String: String] {
    var versions: [String: String] = [:]
    for match in lock.matches(#"\[\[package\]\]\s*name\s*=\s*"([^"]+)"\s*version\s*=\s*"([^"]+)""#)
    where versions[match[0]] == nil {
      versions[match[0]] = match[1]
    }
    return versions
  }

  // MARK: - Go

  /// go.mod's requirements (not the indirect ones) and replacements with
  /// local folders; sources in the module cache.
  static func goModules(_ folder: DependencyFolder) -> [PackageDependency] {
    guard let text = folder.read("go.mod") else { return [] }
    let cache =
      folder.environmentPath("GOMODCACHE")
      ?? (folder.environmentPath("GOPATH") ?? folder.home.appendingPathComponent("go"))
      .appendingPathComponent("pkg/mod")
    let replacements = Dictionary(
      text.matches(#"(?m)^\s*(?:replace\s+)?(\S+)(?:\s+\S+)?\s+=>\s+(\.{1,2}/\S*|/\S+)\s*$"#).map { ($0[0], $0[1]) },
      uniquingKeysWith: { first, _ in first })
    return goRequirements(text).map { requirement in
      if let path = replacements[requirement.path] {
        return PackageDependency(
          name: requirement.path, isLocal: true, ecosystem: .go, location: folder.folder(folder.resolve(path)),
          source: path)
      }
      let location = cache.appendingPathComponent(goEscaped(requirement.path) + "@" + requirement.version)
      return PackageDependency(
        name: requirement.path, version: requirement.version, ecosystem: .go, location: folder.folder(location),
        source: requirement.path)
    }
  }

  /// `require` lines and blocks, without `// indirect` ones.
  static func goRequirements(_ text: String) -> [(path: String, version: String)] {
    var result: [(String, String)] = []
    var inBlock = false
    for raw in text.split(whereSeparator: \.isNewline) {
      var line = raw.trimmingCharacters(in: .whitespaces)
      if inBlock {
        if line.hasPrefix(")") {
          inBlock = false
          continue
        }
      } else if line.hasPrefix("require (") || line == "require(" {
        inBlock = true
        continue
      } else if line.hasPrefix("require ") {
        line = String(line.dropFirst("require ".count))
      } else {
        continue
      }
      guard !line.contains("// indirect") else { continue }
      let parts = line.split(separator: " ").map(String.init)
      if parts.count >= 2, !parts[0].hasPrefix("//") { result.append((parts[0], parts[1])) }
    }
    return result
  }

  /// A module path as the module cache names it: capitals become "!" and
  /// the lowercase letter.
  static func goEscaped(_ path: String) -> String {
    var escaped = ""
    for character in path {
      if character.isUppercase {
        escaped += "!" + character.lowercased()
      } else {
        escaped.append(character)
      }
    }
    return escaped
  }

  // MARK: - Python

  /// pyproject.toml's dependencies (PEP 621 and Poetry) or
  /// requirements.txt, with the version and package folder installed in
  /// the project's virtual environment.
  static func pythonPackages(_ folder: DependencyFolder) -> [PackageDependency] {
    var names: [String] = []
    if let text = folder.read("pyproject.toml") { names += pyprojectDependencies(text) }
    if names.isEmpty, let text = folder.read("requirements.txt") { names += requirements(text) }
    guard !names.isEmpty else { return [] }
    let sitePackages = [".venv", "venv", "env", ".env"].flatMap {
      folder.glob(folder.url($0), ["lib", "*", "site-packages"])
    }
    var seen = Set<String>()
    return names.filter { seen.insert(normalizedPythonName($0)).inserted }.map { name in
      let key = normalizedPythonName(name)
      for site in sitePackages {
        for entry in folder.children(site) where entry.hasSuffix(".dist-info") {
          let base = String(entry.dropLast(".dist-info".count))
          guard let dash = base.lastIndex(of: "-"), normalizedPythonName(String(base[..<dash])) == key else {
            continue
          }
          let version = String(base[base.index(after: dash)...])
          let topLevel = DependencyFolder.read(site.appendingPathComponent(entry + "/top_level.txt"))?
            .split(whereSeparator: \.isNewline).first.map(String.init)
          let location = [topLevel, key, name].compactMap { $0 }.lazy
            .map { site.appendingPathComponent($0) }.first(where: folder.isDirectory)
          return PackageDependency(name: name, version: version, ecosystem: .python, location: location)
        }
      }
      return PackageDependency(name: name, ecosystem: .python)
    }
  }

  /// PEP 503 normalization, with "_" as a folder name has it.
  static func normalizedPythonName(_ name: String) -> String {
    name.lowercased().replacingOccurrences(of: #"[-_.]+"#, with: "_", options: .regularExpression)
  }

  /// The name at the start of a requirement ("orjson>=3.10; …").
  static func requirementName(_ text: String) -> String? {
    text.unquoted.firstMatch(#"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)"#)
  }

  static func pyprojectDependencies(_ text: String) -> [String] {
    var names: [String] = []
    // [project] dependencies = [ … ] and optional-dependencies groups.
    if let project = tomlTable(text, "project"),
      let list = project.firstMatch(#"(?ms)^\s*dependencies\s*=\s*\[(.*?)\]"#)
    {
      names += list.matches(#"["']([^"']+)["']"#).compactMap { requirementName($0[0]) }
    }
    if let optional = tomlTable(text, "project.optional-dependencies") {
      for list in optional.matches(#"(?ms)=\s*\[(.*?)\]"#) {
        names += list[0].matches(#"["']([^"']+)["']"#).compactMap { requirementName($0[0]) }
      }
    }
    for table in ["tool.poetry.dependencies", "tool.poetry.dev-dependencies", "tool.poetry.group.dev.dependencies"] {
      guard let body = tomlTable(text, table) else { continue }
      names += body.matches(#"(?m)^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*="#).map { $0[0] }.filter { $0 != "python" }
    }
    return names
  }

  /// The body of a `[name]` table, up to the next table.
  static func tomlTable(_ text: String, _ name: String) -> String? {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    return text.firstMatch(#"(?ms)^\[\#(escaped)\]\s*$(.*?)(?=^\[|\z)"#)
  }

  static func requirements(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline).compactMap { line in
      let line = line.trimmingCharacters(in: .whitespaces)
      guard !line.hasPrefix("#"), !line.hasPrefix("-") else { return nil }
      return requirementName(line)
    }
  }

  // MARK: - RubyGems

  /// Gemfile.lock's DEPENDENCIES with the versions in its specs; sources in
  /// the project's vendor/bundle or a gem home.
  static func rubyGems(_ folder: DependencyFolder) -> [PackageDependency] {
    guard let lock = folder.read("Gemfile.lock") else { return [] }
    let parsed = gemfileLock(lock)
    let gemFolders =
      folder.glob(folder.url("vendor/bundle/ruby"), ["*", "gems"])
      + folder.glob(folder.home, [".gem", "ruby", "*", "gems"])
      + folder.glob(folder.home, [".local", "share", "gem", "ruby", "*", "gems"])
      + folder.glob(folder.home, [".rbenv", "versions", "*", "lib", "ruby", "gems", "*", "gems"])
      + folder.glob(URL(fileURLWithPath: "/opt/homebrew/lib/ruby/gems"), ["*", "gems"])
      + folder.glob(URL(fileURLWithPath: "/Library/Ruby/Gems"), ["*", "gems"])
    return parsed.dependencies.map { name in
      if let path = parsed.paths[name] {
        return PackageDependency(
          name: name, version: parsed.versions[name], isLocal: true, ecosystem: .ruby,
          location: folder.folder(folder.resolve(path)), source: path)
      }
      let version = parsed.versions[name]
      let location = version.flatMap { version in
        gemFolders.lazy.map { $0.appendingPathComponent(name + "-" + version) }.first(where: folder.isDirectory)
      }
      return PackageDependency(name: name, version: version, ecosystem: .ruby, location: location)
    }
  }

  static func gemfileLock(_ lock: String) -> (
    dependencies: [String], versions: [String: String], paths: [String: String]
  ) {
    var dependencies: [String] = []
    var versions: [String: String] = [:]
    var paths: [String: String] = [:]
    var section = ""
    var remote: String?
    for raw in lock.split(whereSeparator: \.isNewline) {
      let line = String(raw)
      if !line.hasPrefix(" ") {
        section = line.trimmingCharacters(in: .whitespaces)
        remote = nil
        continue
      }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("remote:") { remote = trimmed.dropFirst("remote:".count).trimmingCharacters(in: .whitespaces) }
      // Gems in specs are indented four spaces; their dependencies six.
      if line.hasPrefix("    "), !line.hasPrefix("     "),
        let match = trimmed.matches(#"^([^\s(]+) \(([^)]+)\)"#).first
      {
        versions[match[0]] = versions[match[0]] ?? match[1].split(separator: "-").first.map(String.init)
        if section == "PATH", let remote { paths[match[0]] = remote }
      }
      if section == "DEPENDENCIES", line.hasPrefix("  "), !line.hasPrefix("   "),
        let name = trimmed.split(separator: " ").first
      {
        dependencies.append(String(name).trimmingCharacters(in: CharacterSet(charactersIn: "!")))
      }
    }
    return (dependencies, versions, paths)
  }

  // MARK: - Composer

  /// composer.json's require and require-dev (not PHP or its extensions),
  /// with composer.lock's versions; sources in vendor/.
  static func composerPackages(_ folder: DependencyFolder) -> [PackageDependency] {
    guard let text = folder.read("composer.json"),
      let manifest = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    else { return [] }
    var locked: [String: [String: Any]] = [:]
    if let lockText = folder.read("composer.lock"),
      let lock = try? JSONSerialization.jsonObject(with: Data(lockText.utf8)) as? [String: Any]
    {
      for package in (lock["packages"] as? [[String: Any]] ?? []) + (lock["packages-dev"] as? [[String: Any]] ?? []) {
        if let name = package["name"] as? String { locked[name] = package }
      }
    }
    var found: [PackageDependency] = []
    for key in ["require", "require-dev"] {
      for (name, spec) in (manifest[key] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key })
      where name.contains("/") {
        let package = locked[name]
        let dist = package?["dist"] as? [String: Any]
        let isLocal = dist?["type"] as? String == "path"
        found.append(
          PackageDependency(
            name: name, version: (package?["version"] as? String) ?? spec, isLocal: isLocal, ecosystem: .php,
            location: folder.folder(folder.url("vendor/" + name)), source: dist?["url"] as? String))
      }
    }
    return found
  }

  // MARK: - pub (Dart, Flutter)

  /// pubspec.lock's direct dependencies; sources in the pub cache, or the
  /// path of a path dependency.
  static func dartPackages(_ folder: DependencyFolder) -> [PackageDependency] {
    guard let lock = folder.read("pubspec.lock") else { return [] }
    let cache = folder.environmentPath("PUB_CACHE") ?? folder.home.appendingPathComponent(".pub-cache")
    return pubspecLock(lock).filter { $0.dependency.hasPrefix("direct") }.map { package in
      if package.source == "path", let path = package.path {
        return PackageDependency(
          name: package.name, version: package.version, isLocal: true, ecosystem: .dart,
          location: folder.folder(folder.resolve(path)), source: path)
      }
      let location = package.version.flatMap { version in
        folder.glob(cache, ["hosted", "*"]).lazy.map { $0.appendingPathComponent(package.name + "-" + version) }
          .first(where: folder.isDirectory)
      }
      return PackageDependency(name: package.name, version: package.version, ecosystem: .dart, location: location)
    }
  }

  struct PubPackage: Equatable {
    var name: String
    var dependency = ""
    var source = ""
    var version: String?
    var path: String?
  }

  /// The packages of a pubspec.lock: names indented two spaces, their keys
  /// four, the description's six.
  static func pubspecLock(_ lock: String) -> [PubPackage] {
    var packages: [PubPackage] = []
    var inPackages = false
    for raw in lock.split(whereSeparator: \.isNewline) {
      let line = String(raw)
      if !line.hasPrefix(" ") {
        inPackages = line.hasPrefix("packages:")
        continue
      }
      guard inPackages else { continue }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let colon = trimmed.firstIndex(of: ":") else { continue }
      let key = String(trimmed[..<colon])
      let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces).unquoted
      if line.hasPrefix("  "), !line.hasPrefix("   ") {
        packages.append(PubPackage(name: key))
      } else if !packages.isEmpty {
        switch key {
        case "dependency": packages[packages.count - 1].dependency = value
        case "source": packages[packages.count - 1].source = value
        case "version": packages[packages.count - 1].version = value
        case "path": packages[packages.count - 1].path = value
        default: break
        }
      }
    }
    return packages
  }

  // MARK: - CocoaPods

  /// Podfile.lock's DEPENDENCIES with the versions under PODS; sources in
  /// Pods/, or the path of a development pod.
  static func cocoaPods(_ folder: DependencyFolder) -> [PackageDependency] {
    guard let lock = folder.read("Podfile.lock") else { return [] }
    var versions: [String: String] = [:]
    var dependencies: [(name: String, path: String?)] = []
    var section = ""
    for raw in lock.split(whereSeparator: \.isNewline) {
      let line = String(raw)
      if !line.hasPrefix(" ") {
        section = line
        continue
      }
      guard line.hasPrefix("  - "), let match = line.matches(#"^  - "?([^\s"(:]+)"?(?: \(([^)]*)\))?"#).first else {
        continue
      }
      let name = String(match[0].split(separator: "/").first ?? Substring(match[0]))
      if section.hasPrefix("PODS"), !match[1].isEmpty {
        versions[name] = versions[name] ?? match[1]
      } else if section.hasPrefix("DEPENDENCIES"), !dependencies.contains(where: { $0.name == name }) {
        dependencies.append((name, match[1].firstMatch(#"from `([^`]+)`"#)))
      }
    }
    return dependencies.map { dependency in
      let location = dependency.path.map(folder.resolve) ?? folder.url("Pods/" + dependency.name)
      return PackageDependency(
        name: dependency.name, version: versions[dependency.name], isLocal: dependency.path != nil,
        ecosystem: .cocoaPods, location: folder.folder(location), source: dependency.path)
    }
  }

  // MARK: - Hex (Elixir)

  /// mix.exs's deps with mix.lock's versions; sources in deps/.
  static func elixirPackages(_ folder: DependencyFolder) -> [PackageDependency] {
    guard let mix = folder.read("mix.exs") else { return [] }
    let lock = folder.read("mix.lock") ?? ""
    var versions: [String: String] = [:]
    for match in lock.matches(#""([^"]+)":\s*\{:(?:hex|git),\s*:?[^,]*,\s*"([^"]+)""#) {
      versions[match[0]] = match[1]
    }
    let body = mix.firstMatch(#"(?s)defp?\s+deps(?:\(\))?\s+do(.*?)\n\s*end"#) ?? ""
    var seen = Set<String>()
    return body.matches(#"\{\s*:([a-z_][a-z0-9_]*)\s*,([^}]*)\}"#).filter { seen.insert($0[0]).inserted }.map { match in
      let path = match[1].firstMatch(#"path:\s*"([^"]+)""#)
      let location = path.map(folder.resolve) ?? folder.url("deps/" + match[0])
      return PackageDependency(
        name: match[0], version: versions[match[0]], isLocal: path != nil, ecosystem: .elixir,
        location: folder.folder(location), source: path)
    }
  }

  // MARK: - NuGet (.NET)

  /// The PackageReferences of the project files at the root (versions from
  /// Directory.Packages.props when central) and ProjectReferences as
  /// local packages; sources in the NuGet cache.
  static func nugetPackages(_ folder: DependencyFolder) -> [PackageDependency] {
    let projects = folder.children(folder.root).filter { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") }
    guard !projects.isEmpty else { return [] }
    let cache = folder.environmentPath("NUGET_PACKAGES") ?? folder.home.appendingPathComponent(".nuget/packages")
    var central: [String: String] = [:]
    for match in (folder.read("Directory.Packages.props") ?? "").matches(
      #"<PackageVersion\s+Include="([^"]+)"\s+Version="([^"]+)""#)
    {
      central[match[0]] = match[1]
    }
    var found: [PackageDependency] = []
    for project in projects {
      guard let text = folder.read(project) else { continue }
      for match in text.matches(#"(?s)<PackageReference\s+Include="([^"]+)"([^>]*?)(?:/>|>(.*?)</PackageReference>)"#) {
        let version =
          match[1].firstMatch(#"Version="([^"]+)""#) ?? match[2].firstMatch(#"<Version>([^<]+)</Version>"#)
          ?? central[match[0]]
        let location = version.map { cache.appendingPathComponent(match[0].lowercased() + "/" + $0.lowercased()) }
        found.append(
          PackageDependency(
            name: match[0], version: version, ecosystem: .dotnet, location: location.flatMap(folder.folder)))
      }
      for match in text.matches(#"<ProjectReference\s+Include="([^"]+)""#) {
        let file = folder.resolve(match[0])
        found.append(
          PackageDependency(
            name: file.deletingPathExtension().lastPathComponent, isLocal: true, ecosystem: .dotnet,
            location: folder.folder(file.deletingLastPathComponent()), source: match[0]))
      }
    }
    return found
  }

  // MARK: - Gradle, Maven

  /// Coordinates in the Gradle version catalog and build scripts, or
  /// pom.xml; files in Gradle's or Maven's cache.
  static func javaPackages(_ folder: DependencyFolder) -> [PackageDependency] {
    var coordinates: [(group: String, artifact: String, version: String?)] = []
    if let catalog = folder.read("gradle/libs.versions.toml") { coordinates += versionCatalog(catalog) }
    for script in ["build.gradle", "build.gradle.kts", "app/build.gradle", "app/build.gradle.kts"] {
      guard let text = folder.read(script) else { continue }
      for match in text.matches(
        #"(?:implementation|api|compileOnly|runtimeOnly|testImplementation|androidTestImplementation|kapt|ksp|annotationProcessor)\s*\(?\s*["']([\w.\-]+):([\w.\-]+):([^"'$]+)["']"#)
      {
        coordinates.append((match[0], match[1], match[2]))
      }
    }
    if let pom = folder.read("pom.xml") {
      for block in pom.matches(#"(?s)<dependency>(.*?)</dependency>"#) {
        guard let group = block[0].firstMatch(#"<groupId>([^<]+)</groupId>"#),
          let artifact = block[0].firstMatch(#"<artifactId>([^<]+)</artifactId>"#)
        else { continue }
        let version = block[0].firstMatch(#"<version>([^<$]+)</version>"#)
        coordinates.append((group, artifact, version))
      }
    }
    var seen = Set<String>()
    let gradle = (folder.environmentPath("GRADLE_USER_HOME") ?? folder.home.appendingPathComponent(".gradle"))
      .appendingPathComponent("caches/modules-2/files-2.1")
    let maven = folder.home.appendingPathComponent(".m2/repository")
    return coordinates.filter { seen.insert($0.group + ":" + $0.artifact).inserted }.map { coordinate in
      let location = coordinate.version.flatMap { version in
        [
          gradle.appendingPathComponent("\(coordinate.group)/\(coordinate.artifact)/\(version)"),
          maven.appendingPathComponent(
            coordinate.group.replacingOccurrences(of: ".", with: "/") + "/\(coordinate.artifact)/\(version)"),
        ].first(where: folder.isDirectory)
      }
      return PackageDependency(
        name: coordinate.artifact, version: coordinate.version, ecosystem: .java, location: location,
        source: coordinate.group + ":" + coordinate.artifact)
    }
  }

  /// The libraries of a Gradle version catalog, versions resolved from
  /// its [versions] table.
  static func versionCatalog(_ text: String) -> [(group: String, artifact: String, version: String?)] {
    var versions: [String: String] = [:]
    for match in (tomlTable(text, "versions") ?? "").matches(#"(?m)^\s*([\w.\-]+)\s*=\s*"([^"]+)""#) {
      versions[match[0]] = match[1]
    }
    var result: [(String, String, String?)] = []
    for line in (tomlTable(text, "libraries") ?? "").split(whereSeparator: \.isNewline) {
      let line = String(line)
      if let module = line.firstMatch(#"module\s*=\s*"([^"]+)""#) {
        let parts = module.split(separator: ":").map(String.init)
        guard parts.count == 2 else { continue }
        let version =
          line.firstMatch(#"version\.ref\s*=\s*"([^"]+)""#).flatMap { versions[$0] }
          ?? line.firstMatch(#"version\s*=\s*"([^"]+)""#)
        result.append((parts[0], parts[1], version))
      } else if let group = line.firstMatch(#"group\s*=\s*"([^"]+)""#),
        let name = line.firstMatch(#"name\s*=\s*"([^"]+)""#)
      {
        let version =
          line.firstMatch(#"version\.ref\s*=\s*"([^"]+)""#).flatMap { versions[$0] }
          ?? line.firstMatch(#"version\s*=\s*"([^"]+)""#)
        result.append((group, name, version))
      } else if let coordinate = line.firstMatch(#"=\s*"([^"]+:[^"]+:[^"]+)""#) {
        let parts = coordinate.split(separator: ":").map(String.init)
        result.append((parts[0], parts[1], parts[2]))
      }
    }
    return result
  }
}
