# CodeFormatting

## Purpose

CodeFormatting runs a code formatter on a file's text before an explicit save: the text goes to the formatter's
standard input and comes back formatted on standard output, so the file is written once, already formatted. It knows
swift-format, Prettier, gofmt, rustfmt, Ruff, ClangFormat, zig fmt, mix format, ktlint and shfmt, where each finds its
own configuration, and whether a formatter runs only in projects that have its config file.

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
  message:)`, `timedOut(formatter:)`). An empty answer for a non-empty file is a failure.
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
  configurations that are data only; a project's `node_modules/.bin/prettier`, a config that is code
  (`prettier.config.js`, plugins, `.formatter.exs`) are left alone. Set it from [CodeFolders](CodeFolders.md)' trust.
- `FormattingService.findUpward(_:from:)`: the nearest of some file names from a file's folder up to the home folder.

### The catalog

```swift
if let formatter = FormatterCatalog.formatter(for: file) {
  print(formatter.name, formatter.configFiles, formatter.installCommand ?? "")
}
```

- `FormatterCatalog.all` and `FormatterCatalog.formatter(for:in:)`: the formatters and the one for a file's extension.
- `FormatterConfiguration`: `id`, `name`, `languages`, `extensions`, `command`, `arguments` (for a file path),
  `configFiles`, `requiresConfigByDefault`, `installCommand`.

## Testing

```bash
swift test --filter CodeFormattingTests
```

The tests run swift-format, gofmt and Prettier when they are installed and skip those cases otherwise. They cover a
project's config, the "only with a config file" rule, failures that must not return text, and an untrusted folder's
own Prettier being ignored, on temporary folders.

See also the user guide's [Languages and Formatting](Languages-and-Formatting.md#formatting-on-save).

## Related

- [CodeKit](CodeKit.md): runs the formatter before a save and applies the result to the editor.
- [CodeFolders](CodeFolders.md): `FolderTrust`, for `usesProjectCode`.
- [CodeScan](CodeScan.md#codepretty): CodePretty, the built-in formatter for files no installed formatter applies to.
- [CodeLSP](CodeLSP.md): `ToolUninstall`, which also plans removing a formatter.
