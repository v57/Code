import CodeModel
import CodeScan
import Foundation

/// A JVM project's layout, the same for Java and Kotlin (a Kotlin front end takes this with its own extensions): the
/// files under the root, the source roots of the build's other modules and included builds outside it (Gradle's
/// `settings.gradle(.kts)` `include` and `includeBuild`, `sourceSets` `srcDirs`, Maven's `<modules>`), Android's
/// conventions, the platform's sources (a JDK's `lib/src.zip`, or the Android SDK's `android-stubs-src.jar`, which
/// holds `java.*` as Android has it) and dependencies' `-sources.jar`s in Gradle's cache and `~/.m2`. Nothing is
/// fetched; what isn't on disk is left out. Packages are what names resolve by, so files are grouped by package, read
/// from each file's `package` line.
package final class JVMWorkspace {
  package let root: String
  /// Lowercased extensions of the sources this front end reads (`java`; Kotlin's `kt` and `java`).
  package let extensions: Set<String>
  /// Source roots of the build that aren't under the root: another module of a build the root is in, an included build.
  package private(set) var externalRoots: [String] = []
  /// An Android build (an Android Gradle plugin, an `android {` block, an `AndroidManifest.xml`): the platform is the
  /// Android SDK's, of `compileSdk` when it's installed.
  package private(set) var isAndroid = false
  package private(set) var compileSdk: Int?
  /// The Android SDK a `local.properties` names.
  private var localSDK: String?
  private var packageDirectoryCache: [String: [String]] = [:]

  /// Folders never read: build output, tools' caches, dependencies' installs.
  package static let skipped: Set<String> = ["build", "out", "target", ".gradle", ".git", ".idea", "node_modules", ".build", "bin", ".kotlin", ".cxx"]

  package init(root: String, extensions: Set<String>) {
    self.root = root
    self.extensions = extensions
    readBuild()
  }

  // MARK: Files

  /// The source files under a directory, sorted, build output left out.
  package func sourceFiles(in directory: String) -> [String] {
    var result: [String] = []
    let manager = FileManager.default
    var stack = [directory]
    while let current = stack.popLast() {
      guard let entries = try? manager.contentsOfDirectory(atPath: current) else { continue }
      for entry in entries {
        if entry.hasPrefix(".") || Self.skipped.contains(entry) { continue }
        let path = current + "/" + entry
        if let dot = entry.lastIndex(of: "."), extensions.contains(entry[entry.index(after: dot)...].lowercased()) {
          result.append(path)
          continue
        }
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { stack.append(path) }
      }
    }
    return result.sorted()
  }

  /// A file's package, from its `package` line (comments and annotations before it skipped); "" for the default package.
  package static func packageName(ofFile path: String) -> String {
    guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? handle.close() }
    return packageName(in: Array(handle.readData(ofLength: 16_384)))
  }

  package static func packageName(in bytes: [UInt8]) -> String {
    var i = 0
    let count = bytes.count
    func isWord(_ byte: UInt8) -> Bool { byte == 0x5F || byte == 0x24 || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A) || (byte >= 0x30 && byte <= 0x39) || byte >= 0x80 }
    while i < count {
      let byte = bytes[i]
      if byte == 0x2F, i + 1 < count, bytes[i + 1] == 0x2F {
        while i < count, bytes[i] != 0x0A { i += 1 }
      } else if byte == 0x2F, i + 1 < count, bytes[i + 1] == 0x2A {
        i += 2
        while i + 1 < count, !(bytes[i] == 0x2A && bytes[i + 1] == 0x2F) { i += 1 }
        i += 2
      } else if byte == 0x22 {
        // A string in an annotation's arguments.
        i += 1
        while i < count, bytes[i] != 0x22, bytes[i] != 0x0A { i += bytes[i] == 0x5C ? 2 : 1 }
        i += 1
      } else if isWord(byte) {
        let start = i
        while i < count, isWord(bytes[i]) { i += 1 }
        let word = String(decoding: bytes[start..<i], as: UTF8.self)
        guard word == "package" else {
          // Annotations' names and arguments come before it; anything else means there's no package line.
          if start > 0, bytes[start - 1] == 0x40 || bytes[start - 1] == 0x2E { continue }
          if word == "import" || word == "class" || word == "interface" || word == "enum" || word == "record" || word == "public" || word == "fun" || word == "object" {
            return ""
          }
          continue
        }
        var name: [UInt8] = []
        while i < count, bytes[i] != 0x3B, bytes[i] != 0x0A {
          let b = bytes[i]
          if isWord(b) || b == 0x2E { name.append(b) } else if b == 0x2F { break }
          i += 1
        }
        return String(decoding: name, as: UTF8.self)
      } else {
        i += 1
      }
    }
    return ""
  }

  /// The files of a package in the external source roots: each root's folder for it, as javac's source path finds them.
  package func externalFiles(ofPackage package: String) -> [String] {
    let relative = package.replacingOccurrences(of: ".", with: "/")
    var result: [String] = []
    for sourceRoot in externalRoots {
      let directory = relative.isEmpty ? sourceRoot : sourceRoot + "/" + relative
      guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
      for entry in entries.sorted() {
        if let dot = entry.lastIndex(of: "."), extensions.contains(entry[entry.index(after: dot)...].lowercased()) { result.append(directory + "/" + entry) }
      }
    }
    return result
  }

  /// Whether a package (or a package under it) has a folder in an external root.
  package func externalHasPackage(_ package: String) -> Bool {
    let relative = package.replacingOccurrences(of: ".", with: "/")
    for sourceRoot in externalRoots {
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: sourceRoot + "/" + relative, isDirectory: &isDirectory), isDirectory.boolValue { return true }
    }
    return false
  }

  // MARK: The build

  /// Reads the build files: the build the root is in (the nearest settings file or Maven parent above it), its
  /// modules and included builds, and whether it's Android's.
  private func readBuild() {
    var buildRoots: [String] = []
    // The nearest settings.gradle(.kts) at or above the root; else the outermost pom.xml with modules.
    var directory = root
    var steps = 0
    while steps < 6 {
      if Self.exists(directory + "/settings.gradle") || Self.exists(directory + "/settings.gradle.kts") {
        buildRoots.append(directory)
        break
      }
      let parent = (directory as NSString).deletingLastPathComponent
      if parent == directory || parent.isEmpty || parent == "/" { break }
      directory = parent
      steps += 1
    }
    if buildRoots.isEmpty {
      directory = root
      var outer: String?
      for _ in 0..<4 {
        if let text = Self.read(directory + "/pom.xml"), text.contains("<modules>") { outer = directory }
        let parent = (directory as NSString).deletingLastPathComponent
        if parent == directory || parent.isEmpty || parent == "/" { break }
        directory = parent
      }
      buildRoots.append(outer ?? root)
    }
    var seen = Set<String>()
    var moduleDirectories: [String] = []
    var queue = buildRoots
    while let buildRoot = queue.popLast() {
      guard seen.insert(buildRoot).inserted, seen.count < 32 else { continue }
      moduleDirectories.append(buildRoot)
      let settings = Self.read(buildRoot + "/settings.gradle.kts") ?? Self.read(buildRoot + "/settings.gradle") ?? ""
      for module in Self.gradleIncludes(settings) { moduleDirectories.append(Self.standardized(buildRoot + "/" + module)) }
      for included in Self.calls(["includeBuild"], in: settings) { queue.append(Self.standardized(buildRoot + "/" + included)) }
      if let pom = Self.read(buildRoot + "/pom.xml") {
        for module in Self.xmlValues("module", in: pom) { moduleDirectories.append(Self.standardized(buildRoot + "/" + module)) }
      }
      if let properties = Self.read(buildRoot + "/local.properties"), localSDK == nil {
        for line in properties.split(separator: "\n") where line.hasPrefix("sdk.dir=") {
          localSDK = String(line.dropFirst(8)).replacingOccurrences(of: "\\:", with: ":").replacingOccurrences(of: "\\\\", with: "\\")
        }
      }
    }
    var roots: [String] = []
    for module in moduleDirectories {
      let gradle = Self.read(module + "/build.gradle.kts") ?? Self.read(module + "/build.gradle") ?? ""
      if gradle.contains("com.android.application") || gradle.contains("com.android.library") || gradle.contains("android {")
        || gradle.contains("id(\"com.android") || Self.exists(module + "/src/main/AndroidManifest.xml")
      {
        isAndroid = true
        if compileSdk == nil, let found = Self.compileSdk(in: gradle) { compileSdk = found }
      }
      roots += Self.sourceRoots(ofModule: module, gradle: gradle, pom: Self.read(module + "/pom.xml"))
    }
    let inside = root + "/"
    var unique = Set<String>()
    externalRoots = roots.filter { !$0.hasPrefix(inside) && $0 != root && !root.hasPrefix($0 + "/") && unique.insert($0).inserted }
  }

  /// A module's source roots: every `src/<set>/java` and `src/<set>/kotlin`, the folders `sourceSets` and Maven name.
  private static func sourceRoots(ofModule module: String, gradle: String, pom: String?) -> [String] {
    var result: [String] = []
    let sets = (try? FileManager.default.contentsOfDirectory(atPath: module + "/src")) ?? []
    for set in sets.sorted() {
      for language in ["java", "kotlin"] where exists(module + "/src/" + set + "/" + language) { result.append(module + "/src/" + set + "/" + language) }
    }
    for folder in calls(["srcDir", "srcDirs"], in: gradle) { result.append(standardized(module + "/" + folder)) }
    if let pom {
      for key in ["sourceDirectory", "testSourceDirectory"] {
        for folder in xmlValues(key, in: pom) where !folder.contains("$") { result.append(standardized(module + "/" + folder)) }
      }
    }
    return result.filter(exists)
  }

  /// `include(":a", ":b:c")`, `include ':app', ':lib'`: the modules' folders, `:b:c` being `b/c`.
  private static func gradleIncludes(_ settings: String) -> [String] {
    calls(["include"], in: settings).map { name in
      var path = name.hasPrefix(":") ? String(name.dropFirst()) : name
      path = path.replacingOccurrences(of: ":", with: "/")
      return path
    }
  }

  /// The string literals in calls of these names: `name("a", "b")`, `name 'a', 'b'`, `name = ['a']`, `name += "a"`.
  static func calls(_ names: [String], in text: String) -> [String] {
    var result: [String] = []
    let bytes = Array(text.utf8)
    for name in names {
      let word = Array(name.utf8)
      var i = 0
      while i + word.count <= bytes.count {
        guard bytes[i..<(i + word.count)].elementsEqual(word), i == 0 || !isWordByte(bytes[i - 1]),
          i + word.count == bytes.count || !isWordByte(bytes[i + word.count])
        else {
          i += 1
          continue
        }
        // Comment lines don't count.
        var lineStart = i
        while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
        let line = String(decoding: bytes[lineStart..<i], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        i += word.count
        if line.hasPrefix("//") || line.hasPrefix("*") { continue }
        // The arguments: up to the line's end, or the closing bracket when one opens it.
        var depth = 0
        var j = i
        while j < bytes.count {
          let b = bytes[j]
          if b == 0x28 || b == 0x5B { depth += 1 } else if b == 0x29 || b == 0x5D {
            depth -= 1
            if depth <= 0 {
              j += 1
              break
            }
          } else if b == 0x0A, depth == 0 {
            break
          } else if b == 0x22 || b == 0x27 {
            var k = j + 1
            while k < bytes.count, bytes[k] != b, bytes[k] != 0x0A { k += bytes[k] == 0x5C ? 2 : 1 }
            if k < bytes.count, bytes[k] == b { result.append(String(decoding: bytes[(j + 1)..<k], as: UTF8.self)) }
            j = k
          } else if depth == 0, b != 0x20, b != 0x09, b != 0x3D, b != 0x2B, b != 0x2C {
            break
          }
          j += 1
        }
        i = j
      }
    }
    return result
  }

  private static func isWordByte(_ b: UInt8) -> Bool { b == 0x5F || (b | 0x20 >= 0x61 && b | 0x20 <= 0x7A) || (b >= 0x30 && b <= 0x39) }

  static func xmlValues(_ tag: String, in text: String) -> [String] {
    var result: [String] = []
    var rest = text[...]
    while let open = rest.range(of: "<" + tag + ">"), let close = rest[open.upperBound...].range(of: "</" + tag + ">") {
      result.append(rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines))
      rest = rest[close.upperBound...]
    }
    return result
  }

  private static func compileSdk(in gradle: String) -> Int? {
    for key in ["compileSdkVersion", "compileSdk"] {
      guard let range = gradle.range(of: key) else { continue }
      let digits = gradle[range.upperBound...].drop { !$0.isNumber && $0 != "\n" }.prefix { $0.isNumber }
      if let value = Int(digits) { return value }
    }
    return nil
  }

  static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
  static func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
  static func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

  // MARK: The platform and dependencies

  /// The platform's sources: `CODE_JAVA_SDK` (a zip, a jar or a folder), a JDK's `lib/src.zip` (JAVA_HOME, the
  /// system's JDKs), the Android SDK's `android-stubs-src.jar` (compileSdk's, else the newest), else the built-in stub
  /// (`JavaStd`). An Android build looks at the Android SDK first.
  package private(set) lazy var platform: JVMSourceSet? = {
    if findsPlatform {
      let environment = ProcessInfo.processInfo.environment
      if let given = environment["CODE_JAVA_SDK"], let found = JVMSourceSet(path: given, kind: .platform) { return found }
      let jdk = Self.jdkSources(environment)
      let android = androidStubs(environment)
      for candidate in isAndroid ? [android, jdk] : [jdk, android] {
        if let candidate, let found = JVMSourceSet(path: candidate, kind: .platform) { return found }
      }
    }
    // None on disk: the built-in stub of the classes code calls most.
    return JVMSourceSet(path: "code-java-std", files: JavaStd.files, kind: .platform)
  }()

  /// Whether the platform's sources are looked for on disk (else the built-in stub; tests).
  package var findsPlatform = true

  private static func jdkSources(_ environment: [String: String]) -> String? {
    var homes: [String] = []
    if let home = environment["JAVA_HOME"] { homes.append(home) }
    let user = NSHomeDirectory()
    for folder in ["/Library/Java/JavaVirtualMachines", user + "/Library/Java/JavaVirtualMachines"] {
      for entry in ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted().reversed() { homes.append(folder + "/" + entry + "/Contents/Home") }
    }
    for entry in ((try? FileManager.default.contentsOfDirectory(atPath: "/usr/lib/jvm")) ?? []).sorted().reversed() { homes.append("/usr/lib/jvm/" + entry) }
    for home in homes where exists(home + "/lib/src.zip") { return home + "/lib/src.zip" }
    return nil
  }

  /// The Android SDK's `platforms/android-<n>/android-stubs-src.jar`.
  private func androidStubs(_ environment: [String: String]) -> String? {
    var sdks: [String] = []
    if let given = localSDK { sdks.append(given) }
    for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] { if let value = environment[key] { sdks.append(value) } }
    sdks += [NSHomeDirectory() + "/Library/Android/sdk", NSHomeDirectory() + "/Android/Sdk", "/opt/android-sdk", "/usr/local/share/android-sdk", "/opt/homebrew/share/android-commandlinetools"]
    for sdk in sdks {
      let platforms = sdk + "/platforms"
      guard let entries = try? FileManager.default.contentsOfDirectory(atPath: platforms) else { continue }
      func level(_ entry: String) -> Double { Double(entry.dropFirst("android-".count).prefix { $0.isNumber || $0 == "." }) ?? 0 }
      var sorted = entries.filter { $0.hasPrefix("android-") && Self.exists(platforms + "/" + $0 + "/android-stubs-src.jar") }.sorted { level($0) > level($1) }
      if let wanted = compileSdk, let exact = sorted.first(where: { Int(level($0)) == wanted }) { sorted.insert(exact, at: 0) }
      if let best = sorted.first { return platforms + "/" + best + "/android-stubs-src.jar" }
    }
    return nil
  }

  /// Dependencies' sources: every `-sources.jar` in Gradle's cache (`GRADLE_USER_HOME` or `~/.gradle`) and `~/.m2`,
  /// indexed by package when a package is first missing elsewhere.
  package private(set) lazy var dependencies: [JVMSourceSet] = {
    let environment = ProcessInfo.processInfo.environment
    var folders = [(environment["GRADLE_USER_HOME"] ?? NSHomeDirectory() + "/.gradle") + "/caches/modules-2/files-2.1", NSHomeDirectory() + "/.m2/repository"]
    if let extra = environment["CODE_JAVA_SOURCES"] { folders.insert(extra, at: 0) }
    var jars: [String] = []
    for folder in folders {
      guard let walker = FileManager.default.enumerator(atPath: folder) else { continue }
      while let entry = walker.nextObject() as? String {
        if entry.hasSuffix("-sources.jar") { jars.append(folder + "/" + entry) }
      }
    }
    // The newest version of each artifact: its folder's path without the version and hash.
    return jars.sorted().reversed().compactMap { JVMSourceSet(path: $0, kind: .dependency) }
  }()
}

/// Sources read from a zip (`src.zip`, `-sources.jar`) or a folder, by package: the platform's or a dependency's.
package final class JVMSourceSet {
  package enum Kind { case platform, dependency }
  package let path: String
  package let kind: Kind
  private let archive: ZipArchive?
  /// Files held in memory (the built-in stub), by entry name.
  private var memory: [String: [UInt8]] = [:]
  /// Where files held in memory are written when opened, under the temporary folder.
  private var memoryFolder = "code-java-std"
  /// Each package's files: entry names in the archive, or paths in the folder.
  package private(set) var packages: [String: [String]] = [:]
  /// Every package and the packages above it (`java`, `java.util`): what a qualified name may walk through.
  package private(set) var prefixes: Set<String> = []

  /// Sources given as text: the built-in stub of the platform (`JavaStd`), its path a name for it.
  package init(path: String, files: [String: String], kind: Kind, folder: String = "code-java-std") {
    self.path = path
    self.kind = kind
    memoryFolder = folder
    archive = nil
    for (name, text) in files { memory[name] = Array(text.utf8) }
    index(names: Array(files.keys))
  }

  package init?(path: String, kind: Kind) {
    self.path = path
    self.kind = kind
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
    var names: [String] = []
    if isDirectory.boolValue {
      archive = nil
      if let walker = FileManager.default.enumerator(atPath: path) {
        while let entry = walker.nextObject() as? String {
          if entry.hasSuffix(".java") || entry.hasSuffix(".kt") { names.append(entry) }
        }
      }
    } else {
      guard let opened = ZipArchive(path: path) else { return nil }
      archive = opened
      names = opened.entries.keys.filter { $0.hasSuffix(".java") || $0.hasSuffix(".kt") }
    }
    index(names: names)
  }

  private func index(names: [String]) {
    // A JDK's src.zip puts each module's sources under its name: `java.base/java/util/List.java`.
    let modular = names.contains { $0.hasPrefix("java.base/") }
    for name in names.sorted() {
      var relative = name[...]
      if modular, let slash = relative.firstIndex(of: "/") { relative = relative[relative.index(after: slash)...] }
      if relative.hasPrefix("META-INF/") { continue }
      let folder = relative.lastIndex(of: "/").map { String(relative[..<$0]) } ?? ""
      let package = folder.replacingOccurrences(of: "/", with: ".")
      packages[package, default: []].append(name)
    }
    for package in packages.keys {
      var current = package
      while !current.isEmpty, prefixes.insert(current).inserted {
        guard let dot = current.lastIndex(of: ".") else { break }
        current = String(current[..<dot])
      }
    }
  }

  /// A file's bytes.
  package func contents(_ name: String) -> [UInt8]? {
    if let held = memory[name] { return held }
    if let archive { return archive.contents(name) }
    return FileManager.default.contents(atPath: path + "/" + name).map { Array($0) }
  }

  /// Where a file is on disk: in a folder, itself; in an archive, a copy made under the temporary folder the first
  /// time it's opened (`$TMPDIR/code-jvm-sources/<archive>/<entry>`).
  package func diskPath(_ name: String) -> String {
    if !memory.isEmpty { return NSTemporaryDirectory() + memoryFolder + "/" + name }
    guard archive != nil else { return path + "/" + name }
    let folder = (path as NSString).lastPathComponent + "-" + String(UInt32(truncatingIfNeeded: hashName(path)), radix: 16)
    return NSTemporaryDirectory() + "code-jvm-sources/" + folder + "/" + name
  }

  /// Writes an archive's file to its disk path, if it isn't there yet.
  package func materialize(_ name: String) -> String {
    let target = diskPath(name)
    guard archive != nil || !memory.isEmpty, !FileManager.default.fileExists(atPath: target), let bytes = contents(name) else { return target }
    try? FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: target, contents: Data(bytes))
    return target
  }
}
