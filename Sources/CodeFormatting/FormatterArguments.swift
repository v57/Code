import Foundation

/// A config file a formatter can't find by itself when it reads standard input (it looks in the working folder
/// only), passed on its command line.
enum ToolConfig {
  /// `[option, path]` (or `[option + path]`) for the nearest of `names` above the file, or nothing.
  static func option(_ option: String, _ names: [String], for path: String, separate: Bool = false) -> [String] {
    guard let config = FormattingService.findUpward(names, from: URL(fileURLWithPath: path)) else { return [] }
    return separate ? [option, config.path] : [option + config.path]
  }
}

enum PHPCSFixer {
  /// The project's own config before the shared `.dist` one, as PHP-CS-Fixer reads them. Both are PHP.
  static let configFiles = [".php-cs-fixer.php", ".php-cs-fixer.dist.php"]
}

enum RubyFiles {
  /// Ruby files by extension (a Gemfile or Rakefile has none, so no formatter is chosen for it).
  static let extensions: Set<String> = ["rb", "rake", "gemspec", "podspec", "ru"]
}

/// PSScriptAnalyzer's `Invoke-Formatter`, run by `pwsh` on the text from standard input.
enum PowerShellFormatter {
  /// The settings file PSScriptAnalyzer's editors read from a project (data: a PowerShell hashtable).
  static let settingsFile = "PSScriptAnalyzerSettings.psd1"
  static let installModule =
    "pwsh -NoLogo -NoProfile -Command 'Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force'"

  static func arguments(for path: String) -> [String] {
    let settings = FormattingService.findUpward([settingsFile], from: URL(fileURLWithPath: path))
    return ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script(settings: settings?.path)]
  }

  static func script(settings: String?) -> String {
    let settingsOption = settings.map { " -Settings '\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? ""
    return """
      $ErrorActionPreference = 'Stop'
      if (-not (Get-Command Invoke-Formatter -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine('PSScriptAnalyzer isn''t installed: Install-Module -Name PSScriptAnalyzer')
        exit 2
      }
      $text = [Console]::In.ReadToEnd()
      if ($text.Length -eq 0) { exit 0 }
      [Console]::Out.Write((Invoke-Formatter -ScriptDefinition $text\(settingsOption)))
      """
  }
}
