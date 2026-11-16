# CodeHighlighting

## Purpose

CodeHighlighting turns source text into colored tokens. It holds the language catalog (31 languages and formats:
the 20 most-used programming languages plus JSON, YAML, TOML, HTML, CSS, SQL, CQL, Redis, Markdown, Makefile and
Dockerfile), detects a file's language from its name, extension or `#!` line, scans text into tokens of Xcode's
syntax categories, keeps an incremental highlighter for an editor buffer, matches brackets, and maps tokens to colors
with color schemes and editor themes.

CodeHighlighting is not a parser. Tokens come from comment, string and keyword rules, so a type name is "a
capitalized identifier", not a resolved type. For declarations and definitions, see [CodeScan](CodeScan.md) and
[CodeSwiftModel](CodeSwiftModel.md). It has no dependencies and no UI; for an editor view, see
[CodeEditor](CodeEditor.md).

v57's Git colors its diffs with it, Markdown its fenced code blocks, and Database its query editors.

## Platforms

<!-- platforms: macos ios linux windows -->

Plain Foundation code that builds everywhere the package does; Code's Linux and Windows builds use it. Only
`CodeColorScheme.systemAware` (the property without arguments) reads the appearance through AppKit or UIKit; on Linux
and Windows it returns the light scheme, so pass `isDark` with `systemAware(isDark:)` there. Android: not yet (the
package has no Android setup).

## Getting started

```swift
// Package.swift (the manifest needs Swift tools 6.4)
dependencies: [
  .package(url: "https://github.com/v57/Code.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "CodeHighlighting", package: "Code")]),
]
```

Inside the v57 folder, apps build against the checkout next to them through their `<App>-Local.xcworkspace`, and
`V57_LOCAL=1` makes this package take its own v57 dependencies from sibling checkouts.

One-shot tokens, for a code block:

```swift
import CodeHighlighting

let tokens = CodeHighlighter.tokens(in: "let answer = 42 // why", language: "swift")
let colors = CodeColorScheme.systemAware(isDark: false)
for token in tokens {
  print(token.range, token.kind, String(colors.color(for: token.kind), radix: 16))
}
```

## Main API

### Find a language

- `LanguageCatalog.all` (also `CodeHighlighter.all`): every `LanguageSpec`, programming languages first, then formats.
- `CodeHighlighter.spec(forLanguage:)`: a spec by name or alias, as a fence info string gives it ("swift",
  "c++", "swift linenums", "language-swift"); nil when unsupported.
- `Language.detect(url:firstLine:)` and `Language.detect(shebang:)`: a file's language from its name, extension or
  `#!` line (`#!/usr/bin/env python3`); nil for plain text.
- `LanguageSpec`: one language's rules: `name`, `aliases`, `lineComments`, `blockComments`, `strings` (`StringDelim`),
  `keywords`, `declKeywords` (the kind the following name gets), directives and attributes, `lineRules` and
  `inlineRules` (`SyntaxRule`, regular expressions for formats such as Markdown headings or YAML keys).

```swift
let spec = Language.detect(url: URL(fileURLWithPath: "deploy"), firstLine: "#!/bin/zsh")  // Shell
let sql = CodeHighlighter.spec(forLanguage: "sql")?.keywords
```

### Scan text

- `CodeHighlighter.tokens(in:language:)`: all tokens of a text, UTF-16 ranges; empty for an unknown language.
- `CodeScanner(code:spec:)` with `scan()`, or `CodeScanner(spec:)` with `scanLine(_:at:state:)`, which scans one line
  from a `LineState` (`normal`, inside a `blockComment`, or a `multilineString`) and returns its tokens and the state
  the next line starts in.
- `CodeToken`: a `range` and a `kind`.
- `SyntaxKind`: Xcode's theme categories (`plainText`, `comment`, `prose`, `keyword`, `string`, `number`, `link`,
  `preprocessor`, `attribute`, `typeDeclaration`, `memberDeclaration`, `projectType`, `projectMember`, `otherType`,
  `otherMember`). The scanner never emits the `project…` kinds; they need project knowledge.

```swift
if let swift = CodeHighlighter.spec(forLanguage: "swift") {
  let line = CodeScanner(spec: swift).scanLine("/* open", at: 0, state: .normal)
  print(line.end)  // .blockComment(…): the next line starts inside the comment
}
```

### Highlight an editor buffer

- `SyntaxHighlighter(text:spec:)`: scans a whole buffer and keeps each line's start state and tokens.
  `init(text:spec:scanningLines:)` scans only the first lines; the rest is `pending`.
- `edit(range:replacementLength:in:budget:)`: after an edit, rescans the touched lines and the following lines until
  one starts in the state it had. Returns the rescanned lines. With a `budget`, it stops early and leaves the rest in
  `pending`; `continuePending(in:budget:)` picks it up later.
- `tokens(ofLine:)`, `allTokens`, `startState(ofLine:)`, `lines` (a `LineIndex`), `spec`.
- `LineIndex`: line starts of a text, with `count`, `line(containing:)`, `range(ofLine:)`,
  `contentRange(ofLine:in:)` and `apply(edit:replacementLength:in:)`.

```swift
import CodeHighlighting
import Foundation

let text = NSMutableString(string: "let a = 1\nlet b = 2\n")
if let spec = Language.detect(url: URL(fileURLWithPath: "main.swift")) {
  var highlighter = SyntaxHighlighter(text: text, spec: spec)

  // The user typed "/*" at the start: replace, then tell the highlighter what changed.
  text.replaceCharacters(in: NSRange(location: 0, length: 0), with: "/*")
  let rescanned = highlighter.edit(range: NSRange(location: 0, length: 0), replacementLength: 2, in: text)
  for line in rescanned { _ = highlighter.tokens(ofLine: line) }  // re-color these lines
}
```

### Match brackets

`Delimiters.match(at:in:lines:highlighter:)`, `opener(for:before:in:lines:highlighter:)` and
`balance(of:in:lines:highlighter:)` match `()`, `[]` and `{}`, skipping strings and comments when given a highlighter;
`isLiteral(at:lines:highlighter:)`, `Delimiters.pairs`, `openers` and `searchLimit` (500,000 UTF-16 units).

```swift
let source = "f(a, [b])" as NSString
let close = Delimiters.match(at: 1, in: source, lines: LineIndex(source), highlighter: nil)  // 8
```

### Colors and themes

- `CodeColorScheme`: one `0xRRGGBB` value per kind; `color(for:)`. `githubLight`, `githubDark`, and
  `systemAware(isDark:)` (GitHub Dark or GitHub Light). The scheme stays platform-neutral; convert to `NSColor` or
  `UIColor` where you draw.
- `EditorTheme`: a scheme (`syntax`) plus `background`, `currentLine`, `gutterText`, `gutterCurrentText`, `selection`
  and `cursor` colors, per-kind `fonts` and `lineSpacing`. `xcodeLight`, `xcodeDark`, `githubLight`, `githubDark`,
  `all`, `families` (`xcode`, `github`), `resolve(_:isDark:)` (a theme or family id under an appearance; unknown ids
  fall back to Xcode's) and `systemAware(isDark:)` (Xcode's themes).

```swift
let theme = EditorTheme.resolve("github", isDark: true)  // githubDark
let keywordColor = theme.syntax.color(for: .keyword)
```

## Adding a language

1. Add a `static let` `LanguageSpec` to `Sources/CodeHighlighting/LanguageCatalog.swift` (a programming language) or
   `LanguageCatalog+Formats.swift` (a data, markup or build format), and add it to the `all` list or to `formats`.
   Every alias is lowercased; a file extension that is also an alias (`rs`, `py`) needs nothing else.
2. If the extension, a whole file name or an interpreter in a `#!` line doesn't match an alias, add it to the tables
   in `Language.swift` (`byExtension`, `byFileName`, `byInterpreter`).
3. Update `CodeHighlightingTests`: it checks the number of languages (`CodeHighlighter.all.count`) and that names are
   unique. Add token tests for the new rules (`FormatsTests` holds the formats').
4. CodeScan compiles its scanner tables from this catalog. A language without a `LanguageRules` row scans with the
   defaults; add a row keyed by the spec's `name` in `Sources/CodeScan/LanguageRules.swift` to describe its blocks and
   declarations. Run `swift test --filter CodeScanTests` after any spec change.
5. Optional, elsewhere: a language server in CodeLSP's catalog (its extensions in `languageIDs` also route the file to
   the built-in server; see [CodeLSP](CodeLSP.md)), a formatter in CodeFormatting's `FormatterCatalog`, and a file icon
   in CodeIcons (`FileIcon.catalog` and `FileIcon+Lookup.swift`).

Changing `Language`, `SyntaxHighlighter`, `CodeHighlighter`, `CodeColorScheme`, `EditorTheme` or `SyntaxKind` affects
v57's Git, Markdown and Database, which build against this API.

## Testing

```bash
swift test --filter CodeHighlightingTests
swift test --filter CodeScanTests      # after changing a language's spec
```

The tests cover every language's tokens, the formats, and incremental edits against a full rescan. The library offers
no fakes; `SyntaxHighlighter` and `CodeHighlighter` are pure values you can call in your own tests.

## Related

- [CodeEditor](CodeEditor.md): the Mac editor view that draws these tokens.
- [CodeScan](CodeScan.md): a faster scanner compiled from this catalog, with declarations and an index.
- [CodeMinimap](CodeMinimap.md) and [CodeWorkspace](CodeWorkspace.md): use `SyntaxKind`, `EditorTheme` and
  `Language.detect`.
- [CodeIcons](CodeIcons.md): file icons for the same languages.
