# CodeFormatting

## Purpose

CodeFormatting runs a code formatter on a file's text before an explicit save: the text goes to the formatter's
standard input and comes back formatted on standard output, so the file is written once, already formatted. It knows
swift-format, Prettier, gofmt, rustfmt, Ruff, ClangFormat, zig fmt, mix format, ktlint and shfmt, where each finds its
own configuration, and whether a formatter runs only in projects that have its config file.

No formatter is bundled; each is found on the PATH or given as a custom command. It doesn't apply the result to an
editor: [CodeKit](CodeKit.md) runs it from `TextDocument.preSave` and applies the result as one undoable edit. For a
formatter that needs no install, see CodePretty on the [CodeScan](CodeScan.md#codepretty) page.

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

- `FormatterCatalog.all` and `FormatterCatalog.formatter(for:in:)`: the formatters and the one for a file's extension.
- `FormatterConfiguration`: `id`, `name`, `languages`, `extensions`, `command`, `arguments` (for a file path),
  `configFiles`, `requiresConfigByDefault`, `installCommand`.
- `FormattingService(environment:)`:
  - `format(_:url:timeout:)`: the formatted text, nil when no formatter applies; throws `Failure` (`failed`,
    `timedOut`).
  - `formatter(for:)` and `executable(for:file:)`: which one would run and from where.
  - `disabledIDs`, `requiresConfig` (per formatter: only with a config file), `requiresConfigFile(_:)`,
    `customCommands` (a command instead of the PATH's, such as a local build), `formatters`.
  - `usesProjectCode`: whether the project's own code may run, false by default. Off, the PATH's formatter runs with
    configurations that are data only; a project's `node_modules/.bin/prettier`, a config that is code
    (`prettier.config.js`, plugins, `.formatter.exs`) are left alone. Set it from [CodeFolders](CodeFolders.md)' trust.
- `FormattingService.findUpward(_:from:)`: the nearest of some file names from a file's folder up to the home folder.

## Platform notes

- **macOS**: supported.
- **Linux**: formatters run through v57/SwiftUI's portability layer; part of Code's early Linux build.
- **Windows**: builds, but no formatter runs yet: `format` gives the text back unchanged.
- **iOS (iPadOS)**: builds; no formatter runs.
- **Android**: not yet.

## Testing

```bash
swift test --filter CodeFormattingTests
```

The tests run swift-format, gofmt and Prettier when they are installed and skip those cases otherwise. They cover a
project's config, the "only with a config file" rule, failures that must not return text, and an untrusted folder's
own Prettier being ignored, on temporary folders.

See also the user guide's [Languages and Formatting](Languages-and-Formatting.md#formatting-on-save).
