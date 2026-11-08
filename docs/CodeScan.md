# CodeScan, CodePretty and CodeServer

Three libraries that work from tokens alone, in every language [CodeHighlighting](CodeHighlighting.md) knows, with no
compiler and no types:

- **CodeScan**: a byte-level scanner, each file's declarations and scopes, and a workspace index that answers
  definitions, references, symbols and completions.
- **CodePretty**: a formatter on CodeScan's tokens that refuses any result whose tokens changed.
- **CodeServer**: a language server (LSP over standard input and output) on both, shipped as the `code-lsp` tool and
  inside Code's own binary.

They are lexical, and that is the line between them and real language servers: an answer is a ranked guess, never a
resolved type. For Swift, [CodeSwiftModel](CodeSwiftModel.md) answers with types read from source; for every
language, a real server through [CodeLSP](CodeLSP.md) has the compiler's answer.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target, any of:
.product(name: "CodeScan", package: "Code"),
.product(name: "CodePretty", package: "Code"),
.product(name: "CodeServer", package: "Code"),
```

## CodeScan

```swift
import CodeScan

let index = WorkspaceIndex(roots: ["/path/to/project"])
index.refresh()  // the first call reads every file; later ones cost a stat per file

let path = "/path/to/project/Sources/App/Model.swift"
if let source = index.source(path: path) {
  let offset = source.lines.offset(line: 12, character: 8, in: source.text)  // from 0, UTF-16
  for found in index.resolve(path: path, source: source, offset: offset) {
    print(found.name, found.path, found.score)  // best first; ties are all returned
  }
}
```

Main API

- `WorkspaceIndex(roots:)`: every file of the roots as its declarations and a small filter of its names; what a query
  needs beyond that is scanned from the files that may hold the name. Not thread-safe: one caller at a time (it fans
  out to threads itself).
  - `refresh()`, `refreshIfStale(olderThan:)`, `fileChanged(path:)`, `setDocument(_:path:)` and
    `closeDocument(path:)` (an open document wins over the disk), `source(path:)`, `file(path:)`, `fileCount`,
    `symbolCount`, `memoryUse`, `encoding` (UTF-16 or UTF-8 positions).
  - Queries: `resolve(path:source:offset:depth:)` (`Resolved`: path, symbol, name, score),
    `references(path:source:offset:includeDeclaration:scope:)`, `workspaceSymbols(query:limit:)`,
    `completions(path:source:offset:limit:)`, `describe(_:)`, `signature(path:source:offset:)`,
    `renameLocations(path:source:offset:)`.
- `SourceFile(_:profile:)` or `SourceFile(bytes:profile:)`: one file's `tokens` (`Token`: `kind`, `start`, `end`,
  `length`), `lines` (`LineMap`) and `symbols` (`FileSymbols`: `symbols`, `name(_:)`, `blocks` for folding,
  `problems` for unbalanced brackets); `string(_:)`, `tokenIndex(at:)`, `nameToken(at:)`.
- `LexProfile.profile(forLanguage:)`, `profile(for:)` (a `LanguageSpec`), `profile(forPath:firstLine:)`,
  `LexProfile.plainText`.
- `LanguageRules`: what a language needs beyond its `LanguageSpec`: blocks, declarations (`SymbolKind`), parameters,
  layout, interpolations, extra strings, and formatting preferences CodePretty reads. Plain data, one table row per
  language (`LanguageRules.rules(for:)` by the spec's name); a language without a row gets the defaults and still
  scans.
- `TextPosition`, `TextRange`, `SourceLocation`; `FileWalk` (a multi-threaded folder walk that skips dependency and
  build folders).

## CodePretty

```swift
import CodePretty

let tidy = Pretty.format("let numbers = [1,2 ,3]\n", language: "swift")  // nil for an unknown language
```

It only moves whitespace, adds a trailing comma where a list breaks and swaps quotes where nothing needs escaping.
The result is scanned again and must give the same tokens, and a second pass must agree; otherwise the input comes
back unchanged. Whitespace inside an interpolation is left as written. How much of the layout it decides depends on
what whitespace means in the language.

- `Pretty.format(_:language:path:options:)`: text in, text out.
- `Pretty.format(_:path:options:)` on a `SourceFile`: an `Output` with `text`, `refused` and `refusedLine`.
- `PrettyOptions`: `indentWidth`, `useTabs`, `printWidth` (0 keeps line lengths), `maxBlankLines`, `quote`,
  `trailingCommas`. `PrettyOptions.resolve(path:source:)` reads them from the nearest `.editorconfig`, `.prettierrc`,
  `.swift-format`, `rustfmt.toml` or `.clang-format`, the language's usual style and the file's own indentation.
- `Pretty.sameTokens(_:_:)`.

In Code it is off by default and runs only for a file no installed formatter applies to.

The `code-pretty` tool formats files and folders:

```bash
swift run code-pretty --check Sources            # also --write, --report
swift run code-pretty --stdin-filepath Sources/App/main.swift < Sources/App/main.swift
```

## CodeServer

`LanguageServerLoop(input:output:)` and `run()`, or `LanguageServerLoop.runOnStandardStreams()`, serve LSP on file
descriptors. It answers on one thread, so a query never sees a half-applied edit; the first scan of the workspace
runs before the first request is read. It handles `initialize`, document sync, `definition`, `references`,
`documentHighlight`, `documentSymbol`, `workspace/symbol`, `hover`, `signatureHelp`, `completion`, `rename` and
`prepareRename`, `foldingRange`, `selectionRange`, `semanticTokens/full`, `formatting` and `rangeFormatting` (through
CodePretty), and workspace folder, configuration and watched-file changes.

```bash
swift run code-lsp                               # serves on standard input and output
```

An app can serve from its own binary instead of shipping `code-lsp`: Code calls
`LanguageServerLoop.runOnStandardStreams()` when started with `--language-server`, and points
`LanguageServerManager.builtInExecutable` at itself. CodeLSP's catalog lists it last, so it runs only for a language
with no other server installed or with the others turned off.

## Platform notes

- **macOS, Linux, Windows**: all three libraries and the tools.
- **iOS (iPadOS)**: CodeScan and CodePretty run; CodeServer builds, but nothing starts a server process there.
- **Android**: not yet.

## Testing

```bash
swift test --filter CodeScanTests
swift test --filter CodePrettyTests
swift test --filter CodeServerTests
```

`CodeScanTests` lex every language in the catalog, so run them after changing a `LanguageSpec` or `LanguageRules`.
The formatter's tests cover its layout rules (indentation, spacing, strings and comments, chains, preprocessor
lines). Check a formatter change with each language's own parser over real code too, since tokens can't see every
place where whitespace is content.
`CodeServerTests` talk to a `LanguageServerLoop` over pipes.
