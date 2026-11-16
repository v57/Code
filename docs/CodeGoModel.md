# CodeGoModel

## Purpose

CodeGoModel is a model of a Go project built from its source text, on [CodeModel](CodeSwiftModel.md#codemodel-the-core)
and [CodeScan](CodeScan.md)'s tokens, without the Go toolchain's type checker or gopls. It answers where a name is
defined (exact, a few candidates, or unknown), what can be completed at a position, where a definition is referenced
and what a symbol is (its declaration line, its doc comment, what holds it), in milliseconds. It reads the project's
modules, the standard library from `GOROOT/src` and other modules from the module cache, each package only when a
question reaches it.

It is not a type checker and it never downloads anything: a module missing from the module cache stays unknown. It is
the Go model in the middle of Code's three tiers (CodeKit's `CodeTiers`): CodeScan guesses first, the model answers for
`.go` files, and a language server (gopls, when installed) is asked only when the model isn't sure.

Names resolve the way `go/types` resolves them:

- **Packages and files** (`GoLayout`): a module per `go.mod` under the root (and the nearest above it), a package per
  directory with its import path, its external `_test` package apart. Files this Mac doesn't build (`//go:build`
  lines, `_windows.go`-style suffixes, the toolchain's tags such as `goexperiment.jsonv2`) are kept apart: the package
  doesn't see them, they see the package. Imports are found in the project's modules, a `replace` (a directory or
  another version), `vendor/`, the module cache (`GOMODCACHE`, `!`-escaped paths, the version the outermost `go.mod`
  requires) and `GOROOT/src`. `go env` is run once for GOROOT, GOMODCACHE, GOOS, GOARCH, CGO_ENABLED and GOVERSION,
  and `go list` for the toolchain's tags, with `GOTOOLCHAIN=local` and `GOPROXY=off`: nothing is ever downloaded.
- **Declarations** (`GoSyntax`): functions, methods (kept as an extension named after the receiver's type, so a type's
  method set is its extensions in the package), types with their fields, embedded fields (named after their type,
  also its inherited ranges), interface methods, anonymous structs and interfaces, constants with `iota` repeated,
  variables with which of several values they take (`a, b := f()`).
- **Bodies** (`GoBody`): locals with their scopes (`:=` redeclaring, `if`/`for`/`switch` headers, a type switch's
  binding per clause, `select` receives, labels, function literals), composite literals and their types, read once
  when a position inside asks.
- **Types** (`GoTypes`): the type of an expression (pointers, slices, arrays, maps, channels, functions, the builtin
  calls `make`, `new`, `append`, `len`…, conversions, type assertions, explicit instantiation `F[T]()` and a generic
  receiver's type arguments), so that `x.y` finds y among x's fields and methods, promoted ones too.
- The universe is `GOROOT/src/builtin/builtin.go`, where gopls places it.

## Platforms

<!-- platforms: macos ios=partial linux windows=partial -->

- **macOS, Linux**: everything, with `go` on the PATH (or in `/opt/homebrew/bin`, `/usr/local/go/bin`,
  `/usr/local/bin` or `/usr/bin`) for GOROOT and the module cache. Without it, the project's own packages only.
- **Windows**: builds and reads the project's own packages. The lookup for `go` splits the PATH at `:` and looks for a
  file named `go` in POSIX folders, so it doesn't find a Windows install, and there is no standard library or module
  cache.
- **iOS (iPadOS)**: builds; the project's own packages only (no `go` to run).
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeGoModel", package: "Code"),
```

CodeGoModel re-exports CodeModel. The target builds in Swift 5 language mode; the model isn't thread-safe. Give it its
own serial queue.

```swift
import CodeGoModel

let model = GoModel(root: "/path/to/module")
let file = "/path/to/module/server/server.go"
let answer = model.answer(path: file, line: 41, character: 12)  // from 0, UTF-16
for site in answer.sites {
  if let place = model.location(of: site) { print(place.path, place.line, place.name) }
}
model.project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 41, character: 12)
print(list.context, list.items.map(\.label))
```

## Main API

`GoModel` is a `LanguageModel` (CodeModel), so it is asked as Swift's model is.

### Loading a project

`GoModel(root:)` reads the Go project under a folder: its modules from their `go.mod` files. `project` is CodeModel's
`Project` (`update(path:text:)`, `units`, `projectUnits`, `loadedBytes`).

```swift
let model = GoModel(root: "/path/to/module")
let held = model.project.update(path: file, text: editedText)  // true: what other files see didn't change
print(model.project.projectUnits, model.project.loadedBytes)
```

### Definitions and references

```swift
let answer = model.answer(path: file, line: 41, character: 12)
for use in model.references(of: answer) { print(use.path, use.line) }
for site in answer.sites { if let place = model.place(of: site) { print(place.path, place.line) } }
```

- `answer(path:line:character:)`, `location(of:)`.
- `place(of:)`: a site as go/types' tools name it: a path relative to the root (`../x` for a sibling module),
  `goroot:<path under GOROOT/src>`, `mod:<path under the module cache>`, or `package:<import path>` for a package
  name.
- `references(of:)`: where an answer's definitions are used, a line each; `referenceCount(of:)`.

### Completion

`complete(path:line:character:limit:)` returns a `ModelCompletionList`: after `.`, a package's exported declarations
or a value's fields and methods (promoted ones after its own); in a composite literal, its struct's fields; elsewhere
the locals, type parameters, the package's declarations, imports, the universe and keywords, with function snippets.

```swift
let list = model.complete(path: file, line: 41, character: 12, limit: 40)
for item in list.items where !item.isDeprecated { print(item.label, item.detail) }
```

### Symbol details

`details(of:)` and `details(path:line:character:)` return `SymbolDetails` with the declaration's line, its doc comment
(`// Deprecated:` marks completion items) and its parents (the receiver's type, the package).

```swift
let (_, details) = model.details(path: file, line: 41, character: 12)
print(details.first?.declaration ?? "", details.first?.documentation ?? "")
```

`ModelLanguage.go`: the files (`.go`), manifests (`go.mod`, `go.work`) and how to make the model, for CodeKit and
`code-model`.

### The code-model tool

`code-model` measures it on a real project (`--language go`, or found from the files):

```bash
swift run code-model query --root ~/Projects/server --queries reference.json --out answers.json
swift run code-model complete --root ~/Projects/server --at server/server.go:41:12
swift run code-model bench --root ~/Projects/server --at server/server.go:41:12
```

It also has `check`, `files` and `complete-bench`.

## Numbers

Against go/types, from `../Demos/CodeModelBench/go/README.md` (which has the tools and how to run them). Held-out
modules, 300 sampled identifiers each: hub-net-node, hub-service-go and gobwas/ws 100% exact right, quic-go 95.8%
(every miss a package name of a module that isn't in the module cache, which go/types names anyway), none wrong;
references 99.9 to 100% recall and 98.9 to 100% precision. 20,000 identifiers of quic-go: 99.9% right once the missing
modules are left out. Release build: the first answer in 170 to 300 ms (the project and the standard library packages
it needs), then a median of 0.002 to 0.005 ms and a p95 of 0.014 to 0.025 ms; 156 MB peak for quic-go (1,366 files,
11.8 MB of source). Completion, the author's word deleted or its first two characters left: listed 96.3 to 100%, first
49 to 50.5%, in the top five 79.4 to 82.3%.

## Testing

```bash
swift test --filter CodeGoModelTests
```

The tests write small modules to a temporary folder with `@@` before the words they ask about; one reads the standard
library when `go` is installed.

## Related

- [CodeSwiftModel](CodeSwiftModel.md): Swift's model, and the [CodeModel core](CodeSwiftModel.md#codemodel-the-core)
  both are built on.
- [CodeScan](CodeScan.md): the tokens the model reads, and the tier before it.
- [CodeKit](CodeKit.md): the definition tiers that ask the model.
- [CodeLSP](CodeLSP.md): gopls, the tier after it.
