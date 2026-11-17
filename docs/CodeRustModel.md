# CodeRustModel

## Purpose

CodeRustModel is a model of a Rust project built from its source text, on
[CodeModel](CodeSwiftModel.md#codemodel-the-core) and [CodeScan](CodeScan.md)'s tokens, without running cargo, rustc or
rust-analyzer. It answers where a name is defined (exact, a few candidates, or unknown), what can be completed at a
position (members after `.` and `::`, a `use` group's names, else what's in scope), where a definition is referenced and
what a symbol is (its declaration on one line, its doc comment, what holds it, a value's type), in milliseconds. It reads
`.rs` files and the crates they use: the workspace's, its dependencies' from Cargo's registry and git checkouts, and a
stub of the standard library, each only when a question reaches it.

It is not a type checker: it follows declared types and the types it can infer for sure (no trait solving beyond
impls, derives, bounds and blanket impls; macros are not expanded but for a few kinds), and gives candidates by name (or
nothing) otherwise, since an unknown answer is better than a wrong exact one. It never runs cargo, fetches or builds
anything. It is Rust's model in the middle of Code's three tiers (CodeKit's `CodeTiers`): CodeScan guesses first, the
model answers for Rust files, and a language server (rust-analyzer, when installed) is asked only when the model isn't
sure.

Names resolve the way rustc resolves them:

- **Crates** (`RustLayout`): every `Cargo.toml` under the root and the workspace above it (members, `exclude`,
  `[workspace.dependencies]` and `workspace = true`), each package's library, binaries, tests, examples and benches as
  crates (`src/lib.rs`, `src/main.rs`, `src/bin/`, `[[bin]]`, `tests/`…). Dependencies are `path`, `git` (the checkout
  in `~/.cargo/git/checkouts`) or the registry (`~/.cargo/registry/src`, the version `Cargo.lock` names, else the newest
  installed that meets the requirement), renamed with `package = "…"`, dev-dependencies for the project's own crates,
  `[target.'cfg(…)'.dependencies]` as this machine's build would. Features are unified as Cargo does (defaults,
  `dep:x`, `x/feature`, optional dependencies). `CARGO_HOME` names another Cargo folder. Nothing is downloaded: a
  dependency that isn't installed is left out.
- **Modules**: the module tree from each crate's root (`mod x;` → `x.rs` or `x/mod.rs`, `#[path]`, inline `mod x { }`),
  `use` trees with `self`, `super`, `crate`, `as` and globs, `pub use` re-exports, `extern crate`, `#[macro_export]`
  macros at the crate's root, and `macro_rules!` with one rule defined in the same file read where it's used.
- **Conditional compilation** (`RustSyntax`): `#[cfg]`, `#[cfg_attr]`, `cfg_if!` and tokio's `cfg_*!` macros as this
  machine's build sees them (its OS, family, arch, the crate's features, `test` in tests and `#[cfg(test)]` modules).
  An item left out isn't read, but a question inside one reads it, with every item of the same conditions (CodeModel's
  focus), so code for another platform or feature still answers.
- **Scopes**: locals (`let` patterns, parameters, closures, `for`, `if let`, `while let`, `match` arms, shadowing), type
  parameters, items in function bodies, the module's items, its `use`s and globs, the crates it can name, the prelude
  and the primitive types, in Rust's three namespaces (types, values, macros).
- **Types** (`RustTypes`, `RustExpressions`): declared types, `let` initializers, calls and paths (`Arc::clone(&x)`),
  generic arguments and return types (a closure's result feeds `map`'s), `?`, `.await`, `match` and `if` results,
  type aliases, associated types (`Iterator::Item`, `Deref::Target`), autoderef through references, `Box`, `Rc`, `Arc`
  and any `Deref`. A method is found in inherent impls, then traits: impls, derives, bounds and blanket impls whose
  bounds hold (`impl<T: Display> ToString for T`). Of traits' methods of one name, the ones whose trait is in scope
  (declared, imported, through a glob or the prelude); a trait out of scope still answers when no other does.
- **The standard library** (`RustStd`): no rust-src is installed here, so std, core and alloc are one hand-written stub
  of the items code uses most (chosen by how often four corpora's code names them), with signatures and no bodies,
  written to `$TMPDIR/code-rust-std/std.rs` so ⌘-click can open it.
- **Places** (`place(of:)`): a path relative to the root, `registry:<name>-<version>/<path>` in the registry,
  `git:<repo>/<path>` in a git checkout, `std:<item>` in the stub (`std:Option`, `std:Iterator::map`,
  `std:io::stdout`); a module's place is its `mod` line, or its file at line 1.

## Platforms

<!-- platforms: macos ios=partial linux windows=partial -->

- **macOS**: everything, with the registry and checkouts of `~/.cargo` (or `CARGO_HOME`).
- **Linux**: everything; `cfg` is read as Linux's (`target_os = "linux"`, `target_env = "gnu"`).
- **Windows**: builds; `cfg` is read as Windows', the Cargo folder from `CARGO_HOME`.
- **iOS (iPadOS)**: builds; the project's own files and the standard library's stub.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeRustModel", package: "Code"),
```

CodeRustModel re-exports CodeModel. The target builds in Swift 5 language mode; the model isn't thread-safe. Give it
its own serial queue.

```swift
import CodeRustModel

let model = RustModel(root: "/path/to/workspace")
let file = "/path/to/workspace/crates/app/src/main.rs"
let answer = model.answer(path: file, line: 41, character: 12)  // from 0, UTF-16
for site in answer.sites {
  if let place = model.place(of: site) { print(place.path, place.line) }
}
model.project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 41, character: 12, limit: 40)
print(list.context, list.items.map(\.label))
```

## Main API

`RustModel` is a `LanguageModel` (CodeModel), so it is asked as the other models are.

### Loading a project

`RustModel(root:)` reads the workspace's manifests and its crates' module trees, leaving out `target`, `.git` and
`node_modules`. `project` is CodeModel's `Project` (`update(path:text:)`, `units`, `projectUnits`, `loadedBytes`). A
dependency's files are parsed when a path first names its crate.

### Definitions and references

- `answer(path:line:character:)`, `location(of:)` (a `mod x;` opens its file), `place(of:)`.
- `references(of:)`: where an answer's definitions are used, a line each, in the project: under its name and the names
  it's imported as.

### Completion

`complete(path:line:character:limit:)` returns a `ModelCompletionList`: after `.`, the receiver's fields and methods
through autoderef (traits' too); after `::`, a module's or crate's items (with its `#[macro_export]` macros), an enum's
variants, a type's associated functions (its impls', derived and implemented traits'); in a `use` group, the names of
the path before the brace; after `if let` and `while let`, a pattern's names; nothing in strings, comments or after
`fn`, `struct`, `let` and the other keywords that name something new; elsewhere the locals in reach, the scopes' items
and imports, the crates, the prelude and keywords.

### Symbol details

`details(of:)` and `details(path:line:character:)` return `SymbolDetails`: the declaration on one line (`pub fn new(x:
u8) -> Self`, `struct Point`, `let p: &Point`), the doc comment's first paragraph, its parents (an impl's type, a trait,
the modules out to the crate) and a value's type.

`ModelLanguage.rust`: the extension, the manifests (`Cargo.toml`, `Cargo.lock`) and how to make the model, for CodeKit
and `code-model`.

### The code-model tool

```bash
swift run code-model query --root ~/Projects/app --language rust --queries reference.json --out answers.json
swift run code-model complete --root ~/Projects/app --language rust --at src/main.rs:41:12
```

## Numbers

Against rustdoc's own links to definitions (rustc's name resolution, `rsref.py`), from
`../Demos/CodeModelBench/rs/README.md`. Held out, 300 identifiers each: hub-service-rs 98.0% right (1.3% wrong, 0.7%
unknown), channel-rs 94.3% (2.3% wrong, 3.3% unknown), tokio 94.7% (1.7% wrong, 3.7% unknown); some of the wrong ones
are the reference's (channel-rs recorded as hub-service-rs's dependency, with another serde_json). Tuned on session:
every identifier (3,596) 99.7% right. References: 96.4 to 99.3% recall; every reference the model gives on a line where
rustdoc linked the name is right (99.5 to 100%), and rustdoc leaves many uses unlinked, so plain precision reads 78 to
92%. Release build: the first answer in 38 to 104 ms (loading the workspace, its dependencies' manifests and the stub), then
a median of 0.004 to 0.014 ms and a p95 of 0.06 to 0.95 ms per definition (session's 3,596 in 157 ms); references 0.7 to
4 ms each; 34 to 116 MB peak. Completion, the author's word deleted or its first two characters left: listed 93.8 to 97.3% held out
(100% tuned), first 44 to 47%, in the top five 65 to 68%, a median of 0.5 to 1.4 ms. Fifteen registry crates (tokio, syn, serde, regex, hashbrown,
nix, libc…), 3,000 random identifiers each: no crash or hang, at most 250 MB.

## Testing

```bash
swift test --filter CodeRustModelTests
```

The tests write small Cargo projects to a temporary folder with `@@` before the words they ask about.

## Related

- [CodeSwiftModel](CodeSwiftModel.md), [CodeGoModel](CodeGoModel.md), [CodeTypeScriptModel](CodeTypeScriptModel.md),
  [CodeClangModel](CodeClangModel.md), [CodePythonModel](CodePythonModel.md) and [CodeJavaModel](CodeJavaModel.md): the
  other models, and the
  [CodeModel core](CodeSwiftModel.md#codemodel-the-core) all are built on.
- [CodeScan](CodeScan.md): the tokens the model reads, and the tier before it.
- [CodeKit](CodeKit.md): the definition tiers that ask the model.
- [CodeLSP](CodeLSP.md): rust-analyzer, the tier after it.
