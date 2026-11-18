# CodeScan, CodePretty and CodeServer

## Purpose

Three libraries that work from tokens alone, in every language [CodeHighlighting](CodeHighlighting.md) knows, with no
compiler and no types:

- **CodeScan**: a byte-level scanner, each file's declarations and scopes, and a workspace index that answers
  definitions, references, symbols and completions.
- **CodePretty**: a formatter on CodeScan's tokens that refuses any result whose tokens changed.
- **CodeServer**: a language server (LSP over standard input and output) on both, shipped as the `code-lsp` tool and
  inside Code's own binary.

They are lexical, and that is the line between them and real language servers: an answer is a ranked guess, never a
resolved type. For Swift, Go and TypeScript, [CodeSwiftModel](CodeSwiftModel.md), [CodeGoModel](CodeGoModel.md) and
[CodeTypeScriptModel](CodeTypeScriptModel.md) answer with
types read from source; for every language, a real server through [CodeLSP](CodeLSP.md) has the compiler's answer.

## Platforms

<!-- platforms: macos ios linux windows -->

- **macOS, Linux, Windows**: all three libraries and the `code-lsp` and `code-pretty` tools. `FileWalk` and the
  server's reads have a Windows branch.
- **iOS (iPadOS)**: CodeScan and CodePretty run; CodeServer builds, but nothing starts a server process there.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target, any of:
.product(name: "CodeScan", package: "Code"),
.product(name: "CodePretty", package: "Code"),
.product(name: "CodeServer", package: "Code"),
```

CodeScan depends on CodeHighlighting (its languages), CodePretty on CodeScan, and CodeServer on both and on CodeLSP
(`JSONValue`).

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

## Main API

### Indexing a workspace

`WorkspaceIndex(roots:)` holds every file of the roots as its declarations and a small filter of its names; what a
query needs beyond that is scanned from the files that may hold the name. It is not thread-safe: one caller at a time
(it fans out to threads itself).

```swift
index.setDocument(SourceFile(editorText, profile: source.profile), path: path)  // wins over the disk
index.fileChanged(path: "/path/to/project/Sources/App/Other.swift")
index.refreshIfStale(olderThan: 2)
print(index.fileCount, index.symbolCount, index.memoryUse)
```

- `refresh()`, `refreshIfStale(olderThan:)`, `fileChanged(path:)`, `setDocument(_:path:)` and `closeDocument(path:)`
  (an open document wins over the disk), `source(path:)`, `file(path:)` (an `IndexedFile`), `clearCache()`, `roots`,
  `fileCount`, `symbolCount`, `memoryUse`, `encoding` (`LineMap.Encoding`: UTF-16 or UTF-8 positions).
- `location(path:source:start:end:)` and `range(in:start:end:)` turn byte offsets into a `SourceLocation` or
  `TextRange`.

### Asking questions

```swift
let uses = index.references(path: path, source: source, offset: offset, includeDeclaration: false)
let matches = index.searchSymbols("Model.load")  // Open Quickly: fuzzy, may be qualified
let items = index.completions(path: path, source: source, offset: offset, limit: 50)
```

- `resolve(path:source:offset:depth:)`: `Resolved` values (`path`, `symbol`, `name`, `score`), best first.
- `references(path:source:offset:includeDeclaration:scope:)` (`ReferenceScope`: `workspace`, `file`) and
  `renameLocations(path:source:offset:)`.
- `workspaceSymbols(query:limit:)` and `searchSymbols(_:limit:)` (`SymbolMatch`: `name`, `kind`, `path`, `offset`,
  `containers`, `nameQuery`).
- `completions(path:source:offset:limit:)`: `Completion` values (`label`, `kind`, `score`, `detail`): locals in
  scope, the file's and the receiver's members, the workspace's declarations and the language's keywords.
- `describe(_:)`, `details(_:)` (`Details`: `signature`, `documentation`, `parents`) and
  `signature(path:source:offset:)` (argument labels and the active parameter).

### Scanning a file

```swift
if let swift = LexProfile.profile(forLanguage: "swift") {
  let file = SourceFile("struct Point { var x = 0 }", profile: swift)
  for symbol in file.symbols.symbols { print(file.symbols.name(symbol), symbol.kind) }
  print(file.tokens.map { file.string($0) })
}
```

- `SourceFile(_:profile:)` or `SourceFile(bytes:profile:)`: one file's `tokens` (`Token`: `kind`, `start`, `end`,
  `length`), `lines` (`LineMap`: `line(of:)`, `position(of:in:encoding:)`, `offset(line:character:in:encoding:)`) and
  `symbols` (`FileSymbols`: `symbols`, `name(_:)`, `blocks` for folding, `problems` for unbalanced brackets);
  `string(_:)`, `string(from:to:)`, `tokenIndex(at:)`, `nameToken(at:)`.
- `Symbol` (`kind` as a `SymbolKind`, `isLocal`, `parent`, `offset`, the declaration's and its scope's ranges),
  `TokenKind`.
- `LexProfile.profile(forLanguage:)`, `profile(for:)` (a `LanguageSpec`), `profile(forPath:firstLine:)`,
  `LexProfile.plainText`.
- Lower level: `scan(_:_:profile:into:)` and `extractSymbols(text:length:tokens:profile:)` over a padded buffer (`scanPadding` zero bytes).

### Language rules and walking folders

- `LanguageRules`: what a language needs beyond its `LanguageSpec`: blocks, declarations (`SymbolKind`), parameters,
  layout, interpolations, extra strings, lexing switches (regex literals, here-documents, Kotlin's backtick
  identifiers), and formatting preferences CodePretty reads. Plain data, one table row per
  language (`LanguageRules.rules(for:)` by the spec's name); a language without a row gets the defaults and still
  scans.
- `FileWalk.walk(roots:threads:skipped:wants:isUnchanged:visit:)`: a multi-threaded folder walk that skips dependency
  and build folders (`defaultSkippedFolders`), what `.gitignore` files ignore (those on the way down, and those above
  a root up to its repository's root with `.git/info/exclude`, read with [CodeFolders](CodeFolders.md)' `GitIgnore`
  rules, the matcher Quick Open's file list uses) and files over `largestFile` (8 MB); `FileWalk.read(_:)`.
- `TextPosition`, `TextRange`, `SourceLocation`.

## CodePretty

```swift
import CodePretty

let tidy = Pretty.format("let numbers = [1,2 ,3]\n", language: "swift")  // nil for an unknown language
```

It only moves whitespace, adds a trailing comma where a list breaks and swaps quotes where nothing needs escaping.
The result is scanned again and must give the same tokens, and a second pass must agree; otherwise the input comes
back unchanged. Whitespace inside an interpolation is left as written. How much of the layout it decides depends on
what whitespace means in the language. In Code it is off by default and runs only for a file no installed formatter
applies to.

### Levels

`LanguageRules.layout` says how much of the layout is CodePretty's:

- **`.full`**: indentation, spacing and blank lines. Swift, Go, TypeScript and JavaScript, C, C++, Objective-C,
  C#, Java, Kotlin, Scala, Rust, Dart, Zig (as zig fmt does: four spaces, a `switch`'s prongs as its content, a
  list's columns kept), JSON, CSS and TOML by their brackets; Shell, Ruby and Lua by their block words
  too (`LanguageRules.blockWords`: `then` … `fi`, `do` … `end`, `function` … `end`), PHP and PowerShell by braces.
  Two kinds of file drop to `.spacing` on their own: Scala 3 written without braces (`optionalBraces`: indentation is
  its blocks) and PHP with markup around its `<?php` (`inlineMarkup`: the lines are the template's, and the markup's
  bytes stay as they are).
- **`.spacing`**: spaces inside lines, the author's indentation. Python and Haskell (indentation is meaning; after
  Haskell's `do`, `where`, `let` and `of` the gap before the next word sets a block's column and stays, `layoutWords`),
  Elixir (its line breaks end expressions), SQL and CQL (no one indentation style to follow).
- **`.lines`**: only trailing spaces and blank lines at the end. YAML, Markdown, HTML, Makefile, Redis and every
  language without a row.

Where spaces separate a command's words (Shell, PowerShell, Haskell), `wordGaps` says where one may be added; a gap
is otherwise kept as one space and none is made. Shell and PowerShell lines start commands (`linesStartCommands`), so
only `|` (and a shell's `&&`) at a line's start goes on the line before. In C, C++ and Objective-C the file's own
`switch`/`case`, namespace and access-specifier style wins (`followsFileStyle`), and goto labels and `public:` sit a
level out (`outdentsLabels`).

### Formatting text

```swift
let output = Pretty.format(source, path: path, options: PrettyOptions.resolve(path: path, source: source))
if output.refused { print("left alone at line", output.refusedLine ?? -1) }
```

- `Pretty.format(_:language:path:options:)`: text in, text out.
- `Pretty.format(_:path:options:)` on a `SourceFile`: an `Output` with `text` (bytes), `refused` and `refusedLine`.
- `Pretty.sameTokens(_:_:)`: whether two texts are the same code.
- `Pretty.edits(from:to:)`: the changes between two texts as `LineEdit`s (`startLine`, `endLine`, `text`), so an
  editor keeps its cursor and undo steps.

### Options

`PrettyOptions`: `indentWidth`, `useTabs`, `printWidth` (0 keeps line lengths), `maxBlankLines`, `quote`,
`trailingCommas`, `continuationIndent` (how far a statement's next line goes in; 0 is one level), `indentsCaseLabels`,
`indentsNamespaces` and `accessModifierOffset` (nil: the file's own). `PrettyOptions.resolve(path:source:)` reads them
from the nearest `.editorconfig`, `.prettierrc` (also `.json`, `.yaml`, `.yml`), `.swift-format`, `rustfmt.toml` or
`.clang-format` (`BasedOnStyle`, `ColumnLimit`, `IndentWidth`, `ContinuationIndentWidth`, `IndentCaseLabels`,
`NamespaceIndentation`, `AccessModifierOffset`; `PrettyOptions.configFileNames`, which the server also checks before
letting the editor's tab size win), the language's usual style (C, C++, Objective-C and Dart go on a statement by 4,
Java by two levels; Dart indents by 2, as `dart format` does) and the file's own indentation (by its braces, and by its
block words where a language has them).

```swift
var options = PrettyOptions()
options.indentWidth = 4
options.printWidth = 120
```

### The code-pretty tool

```bash
swift run code-pretty --check Sources            # also --write, --report
swift run code-pretty --stdin-filepath Sources/App/main.swift < Sources/App/main.swift
```

## CodeServer

`LanguageServerLoop(input:output:)` and `run()`, or `LanguageServerLoop.runOnStandardStreams()`, serve LSP on file
descriptors. It answers on one thread, so a query never sees a half-applied edit; the first scan of the workspace
runs before the first request is read. It handles `initialize`, document sync, `definition` (also `declaration`,
`implementation` and `typeDefinition`), `references`, `documentHighlight`, `documentSymbol`, `workspace/symbol`,
`hover`, `signatureHelp`, `completion`, `rename` and `prepareRename`, `foldingRange`, `selectionRange`,
`semanticTokens/full`, `formatting` and `rangeFormatting` (through CodePretty), and workspace folder, configuration
and watched-file changes.

```swift
import CodeServer

if CommandLine.arguments.dropFirst().first == "--language-server" {
  LanguageServerLoop.runOnStandardStreams()  // never returns
}
```

```bash
swift run code-lsp                               # serves on standard input and output
```

An app can serve from its own binary instead of shipping `code-lsp`: Code calls
`LanguageServerLoop.runOnStandardStreams()` when started with `--language-server`, and points
`LanguageServerManager.builtInExecutable` at itself. CodeLSP's catalog lists it last, so it runs only for a language
with no other server installed or with the others turned off.

## Testing

```bash
swift test --filter CodeScanTests
swift test --filter CodePrettyTests
swift test --filter CodeServerTests
```

`CodeScanTests` lex every language in the catalog, so run them after changing a `LanguageSpec` or `LanguageRules`.
The formatter's tests cover its layout rules (indentation, spacing, strings and comments, chains, preprocessor
lines) and each language's level (`LevelTests`: a sample per language, formatted, with its tokens kept and a second
pass changing nothing). Check a formatter change with each language's own parser over real code too, since tokens
can't see every place where whitespace is content: `bash -n` and `zsh -n`, Ruby's compiled instructions, Python's
`ast`, `swiftc -parse`, `gofmt -e`, `clang -fsyntax-only`, JavaScriptCore's `checkSyntax`, SQLite for SQL and
`cargo metadata` for TOML, on a formatted copy of `../Demos/CodeModelBench`'s corpora (never `--write` on them).
`CodeServerTests` talk to a `LanguageServerLoop` over pipes.

## Related

- [CodeHighlighting](CodeHighlighting.md): the languages (`LanguageSpec`, `LanguageCatalog`) the scanner's tables are
  compiled from.
- [CodeSwiftModel](CodeSwiftModel.md) and [CodeGoModel](CodeGoModel.md): code models on CodeScan's tokens, with types.
- [CodeLSP](CodeLSP.md): the client whose catalog lists the built-in server last.
- [CodeFormatting](CodeFormatting.md): the external formatters, tried before CodePretty.
- [CodeKit](CodeKit.md): the definition tiers, where the scanner answers first.
