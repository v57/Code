# CodeSwiftModel

## Purpose

CodeSwiftModel is a model of a Swift project built from its source text and [CodeScan](CodeScan.md)'s tokens, without a
compiler or an index. It answers where a name is defined (exact, a few candidates, or unknown), what can be completed
at a position, and where a definition is referenced, in milliseconds. It reads the SDK's Swift interfaces and, when a
lookup needs them, Clang modules' headers.

It is not a compiler: it doesn't type-check, it says when it isn't sure, and its answers are only as good as what it
can read. It is the middle of the three tiers Code asks when jumping to a definition or completing
(CodeKit's `DefinitionTier`):

1. `scanner`: CodeScan, for every language. Tokens only, in microseconds, never sure.
2. `model`: this library, for Swift. Types read from source, in milliseconds, exact or candidates.
3. `server`: the language server (SourceKit-LSP), the compiler's answer, slowest. By default Code asks it only when the
   model isn't sure.

Inside, the model is built in layers, each only as far as a question needs (named so in the source):

- **Layer 1** (`Declarations.swift`): a file's declarations, read from its tokens. Types stay token ranges and bodies
  stay a pair of tokens until asked for. Nothing points outside the file.
- **Layer 2** (`Project.swift`): which files make which module, what each file can see, and everything else only when
  an import asks for it. Clang modules are read the way Swift sees them, as generated Swift declarations
  (`ClangImporter.swift`), only when a lookup misses.
- **Types** (`Types.swift`): read from their tokens when someone asks, then kept.
- **Layer 4** (`BodyScan.swift`): the names a body introduces and where each is visible, read once when a position
  inside it asks, and dropped with the file.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeSwiftModel", package: "Code"),
```

The target builds in Swift 5 language mode: the model's tables are plain classes used from one thread at a time.
Give it its own serial queue, as Code does, and never touch it from two threads.

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

- `Project(root:useSDK:useClang:runsManifest:)`: loads the project's Swift files. `useSDK` reads the SDK's Swift
  interfaces, `useClang` lets lookups read Clang headers, `runsManifest` lets it evaluate `Package.swift` for the
  targets (only in a folder the person trusts; without it, the targets are the usual folders). `update(path:text:)`
  takes a file's new text; `generatedInterface(of:)` shows a module as the model sees it; `projectUnits`,
  `loadedBytes`, `manifestMilliseconds`.
- `Model(project:)`:
  - `answer(path:line:character:)`: an `Answer` with `state` (`AnswerState`: `exact`, `candidates`, `unknown`),
    `sites` and `byNameOnly` (candidates only by name, as the receiver's type couldn't be told).
  - `location(of:)` (path, line, character, name and a preview line) and `place(of:)`.
  - `references(of:)`: where an answer's definitions are used.
  - `complete(path:line:character:limit:)`: a `SwiftCompletionList` with its `context` (`SwiftCompletionContext`:
    member, implicit member, scope, type, module name, attribute, directive, none), `state`, `prefix`,
    `replaceStart`, `items` (`SwiftCompletionEntry`: name, label, detail, module, kind, insert text, snippet,
    deprecated, needs unwrap) and `isIncomplete`. The names start with `Swift` so they don't clash with
    [CodeAutocompletion](CodeAutocompletion.md)'s.
  - `explain(path:line:character:)`: the chain at a position, step by step, for reading a miss.
  - `findings(path:)` and `allFindings()`: what can be said for sure is wrong (`Finding`): a member that a fully known
    type doesn't have, or can't show from where it's used.
- `Site` (a declaration, a local, a generic parameter or a module), `DeclRef`, `Unit` (one parsed file).

The `swift-model` tool measures the model on a real project:

```bash
swift run swift-model bench --root ~/Projects/MyApp --file Sources/App/Model.swift [--no-sdk]
swift run swift-model query --root ~/Projects/MyApp --queries reference.json --out answers.json
```

## Platform notes

- **macOS**: everything. The SDK's interfaces and Clang modules come from `xcrun --show-sdk-path`.
- **Linux, Windows**: the project's own files; the SDK lookup runs `/usr/bin/xcrun` and finds nothing there. Reading
  the manifest needs `swift` on the PATH.
- **iOS (iPadOS)**: builds; reads only the project's files (no SDK, no manifest).
- **Android**: not yet.

## Testing

```bash
swift test --filter CodeSwiftModelTests
```

The tests write small projects to a temporary folder, with `@@` marking the positions they ask about, and run
without the SDK unless a test asks for it. `swift-model bench` and `query` compare a change
against a real project.
