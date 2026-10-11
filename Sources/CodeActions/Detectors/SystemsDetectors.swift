import Foundation

/// A Cargo package or workspace: a scheme per binary (`[[bin]]`, or the
/// package itself when it has `src/main.rs`), else one for building and
/// testing everything.
public struct CargoDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    guard folder.hasFile("Cargo.toml"), let manifest = folder.read("Cargo.toml") else { return [] }
    let common: [ActionKind: String] = [
      .build: "cargo build", .test: "cargo test", .clean: "cargo clean",
    ]
    var schemes: [ActionScheme] = []
    let root = Self.parse(manifest)
    var packages: [(manifest: Manifest, folder: ProjectFolder)] = []
    if root.packageName != nil { packages.append((root, folder)) }
    for member in Self.expand(root.members, in: folder.url) {
      let memberFolder = ProjectFolder(listing: member)
      if let text = memberFolder.read("Cargo.toml") { packages.append((Self.parse(text), memberFolder)) }
    }
    for (package, packageFolder) in packages {
      guard let packageName = package.packageName else { continue }
      var bins = package.binNames
      if bins.isEmpty, FileManager.default.fileExists(
        atPath: packageFolder.url.appendingPathComponent("src/main.rs").path)
      {
        bins = [packageName]
      }
      for bin in bins {
        var commands = common
        commands[.build] = "cargo build -p \(shellQuote(packageName)) --bin \(shellQuote(bin))"
        commands[.run] = "cargo run -p \(shellQuote(packageName)) --bin \(shellQuote(bin))"
        schemes.append(
          ActionScheme(
            name: bin, toolchain: .cargo, directory: folder.url, commands: commands,
            executable: "target/debug/\(bin)"))
      }
    }
    if schemes.isEmpty {
      schemes.append(
        ActionScheme(
          name: root.packageName ?? folder.name, toolchain: .cargo, directory: folder.url,
          commands: common))
    }
    return schemes
  }

  struct Manifest {
    var packageName: String?
    var binNames: [String] = []
    var members: [String] = []
  }

  /// The `[package]` name, `[[bin]]` names and `[workspace]` members.
  static func parse(_ source: String) -> Manifest {
    var manifest = Manifest()
    var section = ""
    var inMembers = false
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if inMembers {
        manifest.members += quoted(in: trimmed)
        if trimmed.contains("]") { inMembers = false }
        continue
      }
      if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]") {
        section = String(trimmed.dropFirst(2).dropLast(2))
        continue
      }
      if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        section = String(trimmed.dropFirst().dropLast())
        continue
      }
      guard let eq = trimmed.firstIndex(of: "=") else { continue }
      let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
      let value = String(trimmed[trimmed.index(after: eq)...])
      switch (section, key) {
      case ("package", "name"):
        if manifest.packageName == nil { manifest.packageName = quoted(in: value).first }
      case ("bin", "name"):
        if let name = quoted(in: value).first, !manifest.binNames.contains(name) {
          manifest.binNames.append(name)
        }
      case ("workspace", "members"):
        manifest.members += quoted(in: value)
        inMembers = !value.contains("]")
      default: break
      }
    }
    return manifest
  }

  /// Workspace member paths, with a trailing `/*` expanded.
  static func expand(_ members: [String], in root: URL) -> [URL] {
    members.flatMap { member -> [URL] in
      guard member.hasSuffix("/*") else { return [root.appendingPathComponent(member)] }
      let parent = root.appendingPathComponent(String(member.dropLast(2)))
      let children = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
      return children.sorted().map { parent.appendingPathComponent($0) }
    }
  }

  static func quoted(in text: String) -> [String] {
    matches(of: #""([^"]*)""#, in: text).map { $0[0] }
  }
}

/// A Go module: a scheme for the module's main package and one per
/// `cmd/<name>` command.
public struct GoDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    guard folder.hasFile("go.mod") else { return [] }
    let common: [ActionKind: String] = [
      .build: "go build ./...", .test: "go test ./...", .clean: "go clean ./...",
    ]
    var schemes: [ActionScheme] = []
    let module =
      folder.read("go.mod").flatMap { matches(of: #"(?m)^module\s+(\S+)"#, in: $0).first?[0] }
      .map { String($0.split(separator: "/").last ?? "") } ?? folder.name
    if Self.isMainPackage(folder) {
      var commands = common
      commands[.run] = "go run ."
      schemes.append(
        ActionScheme(
          name: module, toolchain: .go, directory: folder.url, commands: commands,
          executable: nil))
    }
    if folder.hasDirectory("cmd") {
      for entry in folder.subfolder("cmd").entries where entry.isDirectory {
        var commands = common
        commands[.run] = "go run ./cmd/\(shellQuote(entry.name))"
        schemes.append(
          ActionScheme(name: entry.name, toolchain: .go, directory: folder.url, commands: commands))
      }
    }
    if schemes.isEmpty {
      schemes.append(ActionScheme(name: module, toolchain: .go, directory: folder.url, commands: common))
    }
    return schemes
  }

  static func isMainPackage(_ folder: ProjectFolder) -> Bool {
    folder.entries.contains { entry in
      guard entry.name.hasSuffix(".go"), !entry.name.hasSuffix("_test.go"),
        let text = folder.read(entry.name)
      else { return false }
      return text.range(of: #"(?m)^package\s+main\b"#, options: .regularExpression) != nil
    }
  }
}

/// A Zig project built with `zig build`.
public struct ZigDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    guard folder.hasFile("build.zig") else { return [] }
    let build = folder.read("build.zig") ?? ""
    var commands: [ActionKind: String] = [.build: "zig build", .test: "zig build test"]
    if build.contains("\"run\"") { commands[.run] = "zig build run" }
    return [ActionScheme(name: folder.name, toolchain: .zig, directory: folder.url, commands: commands)]
  }
}

/// A CMake project: a scheme per `add_executable`, built into `build/`.
public struct CMakeDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    guard folder.hasFile("CMakeLists.txt"), let source = folder.read("CMakeLists.txt") else {
      return []
    }
    let configure = "cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
    let common: [ActionKind: String] = [
      .build: "\(configure) && cmake --build build",
      .test: "\(configure) && cmake --build build && ctest --test-dir build --output-on-failure",
      .clean: "cmake --build build --target clean",
    ]
    let executables = matches(
      of: #"add_executable\s*\(\s*([A-Za-z0-9_.+-]+)(\s+(?:ALIAS|IMPORTED))?"#, in: source
    ).filter { $0.count < 2 || $0[1].isEmpty }.map { $0[0] }
    if executables.isEmpty {
      return [ActionScheme(name: folder.name, toolchain: .cmake, directory: folder.url, commands: common)]
    }
    var seen = Set<String>()
    return executables.filter { seen.insert($0).inserted }.map { name in
      var commands = common
      commands[.build] = "\(configure) && cmake --build build --target \(shellQuote(name))"
      commands[.run] = commands[.build]! + " && ./build/\(shellQuote(name))"
      return ActionScheme(
        name: name, toolchain: .cmake, directory: folder.url, commands: commands,
        executable: "build/\(name)")
    }
  }
}

/// A Makefile, when the folder is no other kind of project: its `build`,
/// `test`, `run` and `clean` targets.
public struct MakeDetector: ProjectDetector {
  public init() {}

  public func schemes(in folder: ProjectFolder) -> [ActionScheme] {
    guard let name = ["Makefile", "makefile", "GNUmakefile"].first(where: folder.hasFile),
      let text = folder.read(name)
    else { return [] }
    let targets = Set(matches(of: #"(?m)^([A-Za-z0-9_.-]+)\s*:(?!=)"#, in: text).map { $0[0] })
    var commands: [ActionKind: String] = [.build: targets.contains("build") ? "make build" : "make"]
    if targets.contains("test") { commands[.test] = "make test" }
    if targets.contains("run") { commands[.run] = "make run" }
    if targets.contains("clean") { commands[.clean] = "make clean" }
    return [ActionScheme(name: folder.name, toolchain: .make, directory: folder.url, commands: commands)]
  }
}
