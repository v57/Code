import CodeModel
import CodeScan
import Foundation

/// Which of the two languages a model reads: their files, interpreters and lexer, and the stub of their builtins.
public enum ScriptDialect: Sendable {
  /// sh, bash and zsh (and ksh, dash), read with one grammar: what differs between them is in which builtins exist.
  case shell
  case powerShell

  var extensions: Set<String> {
    switch self {
    case .shell: return ["sh", "bash", "zsh", "ksh", "command"]
    case .powerShell: return ["ps1", "psm1", "psd1"]
    }
  }

  /// The shells' startup files.
  var fileNames: Set<String> {
    switch self {
    case .shell:
      return [
        ".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".bash_aliases", ".profile", ".zshrc", ".zshenv", ".zprofile", ".zlogin",
        ".zlogout", ".kshrc", ".envrc", "PKGBUILD",
      ]
    case .powerShell: return []
    }
  }

  var interpreters: Set<String> {
    switch self {
    case .shell: return ["sh", "bash", "zsh", "ksh", "dash", "ash", "mksh"]
    case .powerShell: return ["pwsh", "powershell"]
    }
  }

  var lexerLanguage: String { self == .shell ? "shell" : "powershell" }
  /// The stub's module name, and how its places are written (`builtin:echo`, `ps:Get-ChildItem`).
  var stubModule: String { self == .shell ? "sh-builtins" : "ps-builtins" }
  var stubFile: String { self == .shell ? "builtins.sh" : "builtins.ps1" }
}

/// A folder of scripts: every file of the dialect under the root (by extension, a shell's startup file, or a `#!` line
/// naming the shell), hidden folders, `node_modules` and build folders left out. Each file is its own module named by
/// its path: what a script sees is what it defines, what it sources (`source`, `.`, PowerShell's dot-sourcing and
/// `Import-Module`) and, for a sourced file, what its sourcing scripts define. Files outside the root are read when a
/// script sources them; the dialect's builtins come from a stub written to `$TMPDIR/code-script-std/`.
final class ScriptLayout: ProjectLayout {
  let dialect: ScriptDialect
  let syntax: any LanguageSyntax
  let implicitModules: [String] = []
  var interfaceExtension: String { dialect == .shell ? ".sh" : ".ps1" }
  let root: String
  static let skipped: Set<String> = ["node_modules", "Pods", "DerivedData", "Carthage", "vendor"]
  static let stdDirectory = NSTemporaryDirectory() + "code-script-std"

  init(root: String, dialect: ScriptDialect) {
    self.root = root
    self.dialect = dialect
    syntax = dialect == .shell ? ShellSyntax() as any LanguageSyntax : PowerShellSyntax()
  }

  static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  static func isFile(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
  }

  /// Whether a file is one of the dialect's scripts.
  func isScript(_ path: String, name: String) -> Bool {
    if let dot = name.lastIndex(of: "."), dot != name.startIndex {
      return dialect.extensions.contains(name[name.index(after: dot)...].lowercased())
    }
    if dialect.fileNames.contains(name) { return true }
    guard !name.contains("."), let program = ModelLanguage.interpreter(ofFile: path) else { return false }
    return dialect.interpreters.contains(program)
  }

  // MARK: Files

  func sourceFiles(in directory: String) -> [String] {
    var result: [String] = []
    walk(directory) { path, name in if isScript(path, name: name) { result.append(path) } }
    return result.sorted()
  }

  private func walk(_ directory: String, depth: Int = 0, _ visit: (String, String) -> Void) {
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
        visit(path, entry)
      }
    }
  }

  func moduleName(ofRelative path: String) -> String { path }

  /// The stub, or a file outside the project by its absolute path (a sourced script, an autoloaded function).
  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module? {
    if display == dialect.stubModule {
      let path = Self.stdDirectory + "/" + dialect.stubFile
      let source = dialect == .shell ? ShellStd.source : PowerShellStd.source
      if (try? String(contentsOfFile: path, encoding: .utf8)) != source {
        try? FileManager.default.createDirectory(atPath: Self.stdDirectory, withIntermediateDirectories: true)
        try? source.write(toFile: path, atomically: true, encoding: .utf8)
      }
      let unit = Unit(path: path, source: SourceFile(source, profile: syntax.profile), syntax: syntax, isInterface: true)
      return project.register(display, [unit], isSDK: true)
    }
    guard display.hasPrefix("/"), Self.isFile(display) else { return nil }
    // Big files aren't scripts anyone sources (a binary, a log).
    if let size = (try? FileManager.default.attributesOfItem(atPath: display))?[.size] as? Int, size > 4_000_000 { return nil }
    let units = project.parse([display], isInterface: false)
    guard !units.isEmpty else { return nil }
    return project.register(display, units, isSDK: false)
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
