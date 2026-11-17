# CodeSwiftModel

## Purpose

CodeSwiftModel is a model of a Swift project built from its source text and [CodeScan](CodeScan.md)'s tokens, without a
compiler or an index. It answers where a name is defined (exact, a few candidates, or unknown), what can be completed
at a position, where a definition is referenced, and what a symbol is, in milliseconds. It reads the SDK's Swift
interfaces and, when a lookup needs them, Clang modules' headers.

It is not a compiler: it doesn't type-check, it says when it isn't sure, and its answers are only as good as what it
can read. It is the middle of the three tiers Code asks when jumping to a definition or completing (CodeKit's
`DefinitionTier`):

1. `scanner`: CodeScan, for every language. Tokens only, in microseconds, never sure.
2. `model`: a language's model (this library for Swift, [CodeGoModel](CodeGoModel.md) for Go). Types read from
   source, in milliseconds, exact or candidates.
3. `server`: the language server (SourceKit-LSP), the compiler's answer, slowest. By default Code asks it only when the
   model isn't sure.

Inside, the model is built in layers, each only as far as a question needs (named so in the source):

- **Layer 1** (declarations, `Declarations.swift`): a file's declarations, read from its tokens. Types stay token
  ranges and bodies stay a pair of tokens until asked for. Nothing points outside the file.
- **Layer 2** (`Project.swift`): which files make which module, what each file can see, and everything else only when
  an import asks for it. Clang modules are read the way Swift sees them, as generated Swift declarations
  (`ClangImporter.swift`), only when a lookup misses.
- **Types** (`Types.swift`): read from their tokens when someone asks, then kept.
- **Layer 4** (`BodyScan.swift`): the names a body introduces and where each is visible, read once when a position
  inside it asks, and dropped with the file.

## Platforms

<!-- platforms: macos ios=partial linux=partial windows=partial -->

- **macOS**: everything. The SDK's interfaces and Clang modules come from `xcrun --show-sdk-path`, and the manifest
  from `swift package dump-package`.
- **Linux, Windows**: the project's own files. The SDK lookup runs `/usr/bin/xcrun`, a Mac tool, so there is no SDK.
  The manifest is read with `/usr/bin/env swift package dump-package`; where that can't run, the targets are the usual
  folders.
- **iOS (iPadOS)**: builds; reads only the project's files (no SDK, no manifest).
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeSwiftModel", package: "Code"),
```

CodeSwiftModel re-exports [CodeModel](#codemodel-the-core), whose types its API returns. The target builds in Swift 5
language mode: the model's tables are plain classes used from one thread at a time. Give it its own serial queue, as
Code does, and never touch it from two threads.

```swift
import CodeSwiftModel

let root = "/path/to/MyPackage"
let project = Project(root: root, runsManifest: false)  // true runs `swift package dump-package`
let model = Model(project: project)

let file = root + "/Sources/App/Model.swift"
let answer = model.answer(path: file, line: 12, character: 8)  // from 0, UTF-16
switch answer.state {
case .exact, .candidates:
  for site in answer.sites {
    if let place = model.location(of: site) { print(place.path, place.line, place.name) }
  }
case .unknown:
  break  // ask a language server
}

project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 12, character: 8)
print(list.context, list.items.map(\.label))
```

`editedText` stands for the editor's current text. Paths are absolute, under `root`.

## Main API

### Loading a project

`Project(root:useSDK:useClang:runsManifest:)` loads the project's Swift files. `useSDK` reads the SDK's Swift
interfaces, `useClang` lets lookups read Clang headers, `runsManifest` lets it evaluate `Package.swift` for the
targets (only in a folder the person trusts; without it, the targets are the usual folders). All three default to
true.

```swift
let project = Project(root: root, useSDK: false, useClang: false, runsManifest: false)  // the project's files only
let held = project.update(path: file, text: editedText)  // true: what other files see didn't change
print(project.projectUnits, project.loadedBytes, project.manifestMilliseconds)
print(project.generatedInterface(of: "Darwin") ?? "")  // a Clang module as the model reads it
```

- `update(path:text:)`: takes a file's new text; returns whether its shape held, so only its own body answers go.
- `units` (one `Unit` per file read, the SDK's included), `projectUnits`, `loadedBytes`, `manifestMilliseconds`,
  `root`.

### Definitions and references

`Model(project:)` answers questions; it is a `LanguageModel`.

```swift
let found = model.answer(path: file, line: 12, character: 8)
if found.state != .unknown, !found.byNameOnly {
  for use in model.references(of: found) { print(use.path, use.line) }  // 1-based, relative to the root
}
print(model.explain(path: file, line: 12, character: 8))  // the chain, step by step, for reading a miss
```

- `answer(path:line:character:)`: an `Answer` with `state` (`AnswerState`: `exact`, `candidates`, `unknown`),
  `sites` and `byNameOnly` (candidates only by name, as the receiver's type couldn't be told).
- `location(of:)` (path, line, character, name and a preview line) and `place(of:)`.
- `references(of:)` and `referenceCount(of:)` (nil when the answer is a guess).
- `explain(path:line:character:)`: the chain at a position, step by step.
- `clangLoads` (how many questions had headers read for them), `checkedAccesses`.

### Completion

```swift
let list = model.complete(path: file, line: 12, character: 8, limit: 50)
if list.context == .member {
  for item in list.items { print(item.label, item.detail, item.isSnippet ? item.insertText : item.name) }
}
```

`complete(path:line:character:limit:)` returns a `ModelCompletionList` with its `context` (`ModelCompletionContext`:
`member`, `implicitMember`, `scope`, `type`, `moduleName`, `attribute`, `directive`, `none`), `state`, `prefix`,
`replaceStart` (in UTF-8 bytes), `items` and `isIncomplete`. Each `ModelCompletionEntry` has `name`, `label`, `detail`,
`module`, `kind` (`ModelCompletionItemKind`, LSP's values), `insertText`, `isSnippet`, `isDeprecated`, `needsUnwrap`
and `isArguments`. The names start with `Model` so they don't clash with [CodeAutocompletion](CodeAutocompletion.md)'s.

### Symbol details and findings

```swift
let (_, details) = model.details(path: file, line: 12, character: 8)
for detail in details { print(detail.declaration, detail.documentation ?? "", detail.parents.map(\.name)) }
for finding in model.findings(path: file) { print(finding.line, finding.word, finding.message) }
```

- `details(path:line:character:)` and `details(of:)`: `SymbolDetails` (`symbol`, `declaration`, `documentation`,
  `parents`, `type`), each part a `SymbolPart` (`kind`, `name`, `keyword`, `path`, `line`, `character`, `module`,
  `isSDK`).
- `findings(path:)` and `allFindings()`: what can be said for sure is wrong (`Finding`: `path`, `line`, `word`,
  `message`): a member that a fully known type doesn't have, or can't show from where it's used.
- `ModelLanguage.swift`: `.swift` files, read again when a `Package.swift` changes; its `make` builds a `Model` and
  evaluates the manifest only in a trusted folder.

### The swift-model tool

`swift-model` measures the model on a real project (`--no-sdk`, `--no-clang` leave those out):

```bash
swift run swift-model bench --root ~/Projects/MyApp --at Sources/App/Model.swift:12:8
swift run swift-model query --root ~/Projects/MyApp --queries reference.json --out answers.json
swift run swift-model explain --root ~/Projects/MyApp --at Sources/App/Model.swift:12:8
```

It also has `check`, `complete`, `complete-bench` and `interface --module <name>`. `code-model` asks any language's
model the same way ([CodeGoModel](CodeGoModel.md)).

## CodeModel, the core

What isn't Swift lives in its own library, `CodeModel` (`.product(name: "CodeModel", package: "Code")`), which
CodeSwiftModel, CodeGoModel, CodeTypeScriptModel, CodeClangModel, CodePythonModel, CodeRustModel, CodeJavaModel, CodeKotlinModel, CodeCSharpModel, CodeDartModel, CodePHPModel, CodeRubyModel, CodeScalaModel and CodeLuaModel re-export. Its public part is what the models' API returns and what an editor asks any
language through:

- `LanguageModel`: what every model answers (`answer`, `references(of:)`, `complete`, `details`, `referenceCount`,
  `allFindings`, `place(of:)`, `location(of:)`), with a `project`. Not thread-safe: one serial queue per model.
- `ModelLanguage(name:extensions:manifests:make:)`: a language's file extensions, manifests and how to make its model
  for a folder (`make(root, trusted)`); `handles(_:)`, `isManifest(_:)` (a manifest named by a pattern, `*.csproj`). CodeKit's model tier and the `code-model` tool list
  `ModelLanguage.swift`, `ModelLanguage.go`, `ModelLanguage.typeScript`, `ModelLanguage.clang`, `ModelLanguage.python`,
  `ModelLanguage.rust`, `ModelLanguage.java`, `ModelLanguage.kotlin` and `ModelLanguage.cSharp`.
- `Project` (`root`, `units`, `projectUnits`, `loadedBytes`, `update(path:text:)`), `Unit` (one file: `path`,
  `source`, `tokens` without comments, `decls`, `imports`, `shape`), the declaration tables (`Decl`, `Param`, `Import`,
  `DeclRef`, `DeclKind` (`namespace` for TypeScript's namespaces and `declare module` blocks), `Access`, `Name`; an
  `Import`'s `member` is the declaration it takes, `import { a as b }`) and `Site` (a declaration, a local, a generic
  parameter or a module).
- `Answer`, `AnswerState`, `Finding`, `SymbolDetails`, `SymbolPart`, and completion's `ModelCompletionList`,
  `ModelCompletionEntry`, `ModelCompletionContext` and `ModelCompletionItemKind`.

```swift
import CodeModel
import CodeCSharpModel
import CodeClangModel
import CodeDartModel
import CodeGoModel
import CodeJavaModel
import CodeKotlinModel
import CodePHPModel
import CodePythonModel
import CodeRubyModel
import CodeRustModel
import CodeScalaModel
import CodeLuaModel
import CodeSwiftModel
import CodeTypeScriptModel

let languages: [ModelLanguage] = [.swift, .go, .typeScript, .clang, .python, .rust, .java, .kotlin, .cSharp, .dart, .php, .ruby, .scala, .lua]
func model(for file: String, root: String, trusted: Bool) -> (any LanguageModel)? {
  languages.first { $0.handles(file) }?.make(root, trusted)
}
```

A front end gives the core two objects: a `LanguageSyntax` (its lexer profile, a parser that fills a unit's tables and
returns its shape, the syntax that reads a file at a path (`syntax(forPath:)`, itself unless the project mixes
languages: Kotlin's reads `.java` files with Java's), how a condition of conditional compilation reads, which directives open, continue and close a
conditional block (`#if`/`#elseif` for Swift, `#if`/`#ifdef`/`#elif` for C) and, for C, a directive's line read again as
words; a parser can also mark ranges it leaves out that aren't between directives, `Unit.leftOutRanges` with a key for
their condition, Rust's `#[cfg]` items: a question inside one is read with every range of that key, a whole branch) and a `ProjectLayout` (its source files, a
file's module, where a module an import names is found, the modules every file sees). These, and the rest of what
front ends share (`Ty`, with `Ty.union` and `Ty.intersection` among the constructed types, `Module`, a unit's token
navigation (`Navigation.swift`: the token at an offset, the bracket a token is in, text between tokens, whether an
offset is in a comment or string, whether tokens start with a word list (`startsWith`), whether a punctuation token is made only of some characters (`punctuation(_:madeOf:)`: CodeScan lexes `>>` or `<?` as one token, so a type argument list's end is a token of `>`s), an answer summarizing sites), a project-relative path (`Project.rootRelative`), the member tables of nominal types with generics (`NominalTypes`: `MemberEntry`, type parameter maps, substitution, supertype walks and unification; Java's, Kotlin's and C#'s models conform), conditional branches, a zip reader for archives of sources
(`ZipArchive`: stored and deflated entries, zip64; Java's `src.zip`, `-sources.jar` and the Android SDK's sources), a layout-sensitive language's
logical lines and indented blocks (`LogicalLines`, Python's), completion's site (`Unit.completionSite(at:)`:
the anchor, the typed prefix, where the replacement starts, a `.` split from a number) and ranking with
`ModelCompletionHit`, `membersNamed`, `Unit.chain`, doc comments above a declaration), are `package` declarations: a
new language's model is a target in this package. Swift's front end is `SwiftSyntax` and `SwiftLayout` (a package's
manifest, sibling packages, the SDK's interfaces and Clang headers); Go's is in [CodeGoModel](CodeGoModel.md), TypeScript's in [CodeTypeScriptModel](CodeTypeScriptModel.md), C's, C++'s and
Objective-C's in [CodeClangModel](CodeClangModel.md), Python's in [CodePythonModel](CodePythonModel.md), Rust's in [CodeRustModel](CodeRustModel.md), Java's in [CodeJavaModel](CodeJavaModel.md), Kotlin's in [CodeKotlinModel](CodeKotlinModel.md), C#'s in [CodeCSharpModel](CodeCSharpModel.md), Dart's in [CodeDartModel](CodeDartModel.md), PHP's in [CodePHPModel](CodePHPModel.md), Ruby's in [CodeRubyModel](CodeRubyModel.md), Scala's in [CodeScalaModel](CodeScalaModel.md), Lua's in [CodeLuaModel](CodeLuaModel.md). Swift's Clang importer finds module maps and frameworks with
CodeClangModel's `ClangModuleMap`, so CodeSwiftModel depends on it and there is one header locator. The
resolver, member tables, completion contexts and the type of an expression stay in each front end: Swift's follow its
rules (conditional conformances, raw values, `@dynamicMemberLookup`, argument labels), Go's its own (method sets
through embedding, package-qualified names, build constraints), TypeScript's its own (declaration merging, exports
and module resolution, contextual types of literals, overloads).

## Testing

```bash
swift test --filter CodeSwiftModelTests
```

The tests write small projects to a temporary folder, with `@@` marking the positions they ask about, and run
without the SDK unless a test asks for it. `swift-model bench` and `query` compare a change against a real project.

## Related

- [CodeScan](CodeScan.md): the tokens and scanner the model reads, and the tier before it.
- [CodeGoModel](CodeGoModel.md): Go's model on the same core.
- [CodeKit](CodeKit.md): the definition tiers that ask the model, on its own queue.
- [CodeLSP](CodeLSP.md): SourceKit-LSP, the tier after it.
- [CodeAutocompletion](CodeAutocompletion.md): the completion list the model's items fill in Code.
