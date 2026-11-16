# CodeGoModel

## Purpose

CodeGoModel is a model of a Go project built from its source text, on [CodeModel](CodeSwiftModel.md#codemodel-the-core)
and [CodeScan](CodeScan.md)'s tokens, without the Go toolchain's type checker or gopls. It answers where a name is
defined (exact, a few candidates, or unknown), what can be completed at a position, where a definition is referenced
and what a symbol is (its declaration line, its doc comment, what holds it), in milliseconds. It reads the project's
modules, the standard library from `GOROOT/src` and other modules from the module cache, each package only when a
question reaches it.

It is the Go model in the middle of Code's three tiers (CodeKit's `CodeTiers`): CodeScan guesses first, the model
answers for `.go` files, and a language server (gopls, when installed) is asked only when the model isn't sure.

Names resolve the way `go/types` resolves them:

- **Packages and files** (`GoLayout`): a module per `go.mod` under the root (and the one above it), a package per
  directory with its import path, its external `_test` package apart. Files this Mac doesn't build (`//go:build`
  lines, `_windows.go`-style suffixes, the toolchain's tags such as `goexperiment.jsonv2`) are kept apart: the package
  doesn't see them, they see the package. Imports are found in the project's modules, a `replace` (a directory or
  another version), `vendor/`, the module cache (`GOMODCACHE`, `!`-escaped paths, the version the outermost `go.mod`
  requires) and `GOROOT/src`. `go env` is run once for GOROOT, GOMODCACHE, GOOS and GOARCH, with `GOTOOLCHAIN=local`
  and `GOPROXY=off`: nothing is ever downloaded.
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

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeGoModel", package: "Code"),
```

The target builds in Swift 5 language mode; the model isn't thread-safe. Give it its own serial queue.

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

`GoModel` is a `LanguageModel` (CodeModel), so it is asked as Swift's model is:

- `GoModel(root:)`: the project under a folder. `project` is CodeModel's `Project` (`update(path:text:)`,
  `projectUnits`, `loadedBytes`).
- `answer(path:line:character:)`, `location(of:)`, `place(of:)` (a site as go/types' tools name it: a path under the
  root, `goroot:<path>`, `mod:<path>@<version>/…`, or `package:<import path>` for a package name).
- `references(of:)`: where an answer's definitions are used, a line each.
- `complete(path:line:character:limit:)`: after `.`, a package's exported declarations or a value's fields and
  methods (promoted ones after its own); in a composite literal, its struct's fields; elsewhere the locals, type
  parameters, the package's declarations, imports, the universe and keywords, with function snippets.
- `details(of:)`, `details(path:line:character:)`: `SymbolDetails` with the declaration's line, its doc comment
  (`// Deprecated:` marks completion items) and its parents (the receiver's type, the package).
- `ModelLanguage.go`: the files (`.go`), manifests (`go.mod`, `go.work`) and how to make the model, for CodeKit and
  `code-model`.

`code-model` measures it on a real project (`--language go`, or found from the files):

```bash
swift run code-model query --root ~/Projects/server --queries reference.json --out answers.json
swift run code-model complete --root ~/Projects/server --at server/server.go:41:12
swift run code-model bench --root ~/Projects/server --at server/server.go:41:12
```

## Numbers

Against go/types (`../Demos/CodeModelBench/go/README.md` has the tools and how to run them). Held-out modules, 300
sampled identifiers each: hub-net-node, hub-service-go and gobwas/ws 100% exact right, quic-go 95.8% (every miss a
package name of a module that isn't in the module cache, which go/types names anyway), none wrong; references 99.9 to
100% recall and 98.9 to 100% precision. 20,000 identifiers of quic-go: 99.9% right once the missing modules are left
out. Release: the first answer in 170 to 300 ms (the project and the standard library packages it needs), then a median
of 0.004 ms and a p95 of 0.014 ms; 156 MB peak for quic-go (1,366 files, 11.8 MB of source). Completion, the author's
word deleted or its first two characters left: listed 96 to 100%, first 49 to 51%, in the top five 79 to 82%.

## Platform notes

- **macOS, Linux, Windows**: everything, with `go` on the PATH (or in `/opt/homebrew/bin`, `/usr/local/go/bin`) for
  GOROOT and the module cache. Without it, the project's own packages only.
- **iOS (iPadOS)**: builds; the project's own packages only (no `go` to run).
- **Android**: not yet.

## Testing

```bash
swift test --filter CodeGoModelTests
```

The tests write small modules to a temporary folder with `@@` before the words they ask about; one reads the standard
library when `go` is installed.
