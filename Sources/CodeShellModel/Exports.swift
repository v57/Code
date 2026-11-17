/// The core every language's model shares: what CodeShellModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// Shell scripts (sh, bash, zsh): `.sh`, `.bash`, `.zsh`, `.ksh`, `.command`, the shells' dotfiles and files without an
  /// extension whose `#!` line names a shell. No manifest: a script's files are found by what it sources.
  public static let shell = ModelLanguage(
    name: "Shell", extensions: ["sh", "bash", "zsh", "ksh", "command"], manifests: [], fileNames: ScriptDialect.shell.fileNames,
    interpreters: ScriptDialect.shell.interpreters
  ) { root, _ in ScriptModel(root: root, dialect: .shell) }

  /// PowerShell: `.ps1` scripts, `.psm1` modules and `.psd1` manifests (a manifest change reads the project again), and
  /// files without an extension whose `#!` line names `pwsh`.
  public static let powerShell = ModelLanguage(
    name: "PowerShell", extensions: ["ps1", "psm1", "psd1"], manifests: ["*.psd1"], fileNames: [],
    interpreters: ScriptDialect.powerShell.interpreters
  ) { root, _ in ScriptModel(root: root, dialect: .powerShell) }
}
