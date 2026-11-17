# CodeFormatting

## Purpose

CodeFormatting runs a code formatter on a file's text before an explicit save: the text goes to the formatter's
standard input and comes back formatted on standard output, so the file is written once, already formatted. It knows
swift-format, Prettier, gofmt, rustfmt, Ruff, ClangFormat, zig fmt, mix format, ktlint, shfmt, google-java-format,
CSharpier, dart format, Pint, PHP-CS-Fixer, Standard Ruby, RuboCop, scalafmt, StyLua, Fourmolu, Ormolu, Invoke-Formatter
(PowerShell's PSScriptAnalyzer through `pwsh`), Taplo and SQLFluff. It knows where each finds its own configuration,
whether a formatter runs only in projects that have its config file, and which formatter a project's config picks
when a language has two.

It is not a formatter itself, and none is bundled: each is found on the PATH or given as a custom command. It doesn't
apply the result to an editor: [CodeKit](CodeKit.md) runs it from `TextDocument.preSave` and applies the result as one
undoable edit. For a formatter that needs no install, see CodePretty on the [CodeScan](CodeScan.md#codepretty) page.

## Platforms

<!-- platforms: macos ios=partial linux windows=partial -->

- **macOS**: formatters run as a `Process`.
- **Linux**: formatters run through v57/SwiftUI's `ChildProcess` (Foundation's `Process` there can hang when children
  run side by side); part of Code's early Linux build.
- **Windows, iOS (iPadOS)**: builds, but no formatter runs: `format(_:url:timeout:)` gives the text back unchanged.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeFormatting", package: "Code"),
```

```swift
import CodeFormatting
import Foundation

func formatted(_ text: String, at file: URL, environment: [String: String]) async throws -> String {
  var service = FormattingService(environment: environment)  // the login shell's, for its PATH
  service.disabledIDs = ["prettier"]
  return try await service.format(text, url: file) ?? text  // nil: no formatter applies
}
```

## Main API

### Formatting a file

`FormattingService(environment:)` formats texts with the configured formatters; the environment defaults to the
process's.

```swift
do {
  if let result = try await service.format(text, url: file, timeout: 5) { text = result }
} catch let failure as FormattingService.Failure {
  print(failure.localizedDescription)  // the text stays as it was
}
```

- `format(_:url:timeout:)`: the formatted text, nil when no formatter applies; throws `Failure` (`failed(formatter:
  message:)`, `timedOut(formatter:)`). An empty answer for a non-empty file is a failure, and so is an exit code
  other than the formatter's `successExitCodes` (SQLFluff's 1 still carries the text).
- A formatter whose `input` is `.temporaryCopy` (PHP-CS-Fixer, which can't write standard input's result anywhere)
  gets a copy of the text in a temporary folder of its own. The copy has the file's name, its path follows the
  arguments, and it is read back after the formatter rewrites it.
- `formatter(for:)` (the configuration and its executable) and `executable(for:file:)`: which one would run and from
  where.

### Choosing formatters

```swift
service.requiresConfig["gofmt"] = true  // only in projects with its config file
service.customCommands["swift-format"] = "/path/to/.build/release/swift-format"
service.usesProjectCode = FolderTrust.isTrusted(projectFolder)  // CodeFolders
```

- `disabledIDs`, `requiresConfig` (per formatter: only with a config file), `requiresConfigFile(_:)`,
  `customCommands` (a command instead of the PATH's, such as a local build), `formatters`, `environment`.
- `usesProjectCode`: whether the project's own code may run, false by default. Off, the PATH's formatter runs with
  configurations that are data only. A project's `node_modules/.bin/prettier` and a formatter that would run its code
  are left alone: `projectCode` `.always` (`mix format`, SQLFluff, which templates the file) or `.config` when its
  config file is found (`.php-cs-fixer.php`, `.rubocop.yml` and `.standard.yml`, which can load Ruby, and
  `.scalafmt.conf`, whose version scalafmt downloads and runs), plus Prettier's JavaScript configs and plugins. Set it
  from [CodeFolders](CodeFolders.md)' trust.

When several formatters take a file's extension, `formatter(for:)` keeps those that are on, installed and not waiting
for a config file. The one whose config file is nearest the file wins, and the catalog's order breaks a tie. Without
any config file, the first one wins. PHP has Pint (waits for `pint.json`), then PHP-CS-Fixer. Ruby has Standard Ruby,
then RuboCop (waits for `.rubocop.yml`). Haskell has Fourmolu (waits for `fourmolu.yaml`), then Ormolu. In a folder
that isn't trusted, a choice that would run project code gives no formatter. Another one doesn't stand in, since the
project chose that one's style.
- `FormattingService.findUpward(_:from:)`: the nearest of some file names from a file's folder up to the home folder.

### The catalog

```swift
if let formatter = FormatterCatalog.formatter(for: file) {
  print(formatter.name, formatter.configFiles, formatter.installCommand ?? "")
}
```

- `FormatterCatalog.all`, `FormatterCatalog.formatters(for:in:)` (every formatter for a file's extension, in order)
  and `formatter(for:in:)` (the first of them).
- `FormatterConfiguration`: `id`, `name`, `languages`, `extensions`, `command`, `arguments` (for a file path),
  `configFiles`, `requiresConfigByDefault`, `projectCode`, `input`, `successExitCodes`, `installCommand`.

Some formatters only look in the working folder (the file's) for their config when they read standard input, so their
arguments pass the nearest config above the file: PHP-CS-Fixer's and Pint's `--config=`, scalafmt's `--config`, and
Invoke-Formatter's `-Settings` with `PSScriptAnalyzerSettings.psd1`. Pint reads standard input from version 1.26.
Install commands are Homebrew's where it has the tool. The others use their ecosystem's own installer:
`dotnet tool install --global csharpier`, `composer global require laravel/pint`, `gem install standard`, Coursier's
`cs install scalafmt`, and `Install-Module PSScriptAnalyzer` after `brew install powershell`.

## Testing

```bash
swift test --filter CodeFormattingTests
```

The tests run swift-format, gofmt and Prettier when they are installed and skip those cases otherwise. They cover a
project's config, the "only with a config file" rule, failures that must not return text, and an untrusted folder's
own Prettier being ignored, on temporary folders. Every entry is checked for extensions, a command, arguments and an
install command. File-to-formatter choice is checked per language, with stand-in commands so it doesn't depend on
what's installed: config files picking between two formatters, nearest first, and untrusted folders. The tests also
cover the configs passed on the command line, a temporary copy formatted in place, and SQLFluff's exit codes.

See also the user guide's [Languages and Formatting](Languages-and-Formatting.md#formatting-on-save).

## Related

- [CodeKit](CodeKit.md): runs the formatter before a save and applies the result to the editor.
- [CodeFolders](CodeFolders.md): `FolderTrust`, for `usesProjectCode`.
- [CodeScan](CodeScan.md#codepretty): CodePretty, the built-in formatter for files no installed formatter applies to.
- [CodeLSP](CodeLSP.md): `ToolUninstall`, which also plans removing a formatter.
