# CodeDartModel

## Purpose

CodeDartModel is a model of a Dart project built from its source text, on
[CodeModel](CodeSwiftModel.md#codemodel-the-core) and [CodeScan](CodeScan.md)'s tokens, without running the Dart SDK,
the analyzer, `dart pub` or a language server. It answers where a name is defined (exact, a few candidates, or
unknown), what can be completed at a position, where a definition is referenced and what a symbol is, in milliseconds.
It reads the `.dart` files under a folder, the packages they import from the pub cache already on disk, and the `dart:`
libraries from an SDK on disk or a hand-written stub.

It is not a compiler: it follows declared types and the types it can infer for sure, and gives candidates (or nothing)
otherwise, since an unknown answer is better than a wrong exact one. It never runs `dart pub get`, downloads or installs
anything. It is Dart's model in the middle of Code's three tiers (CodeKit's `CodeTiers`): CodeScan guesses first, the
model answers for `.dart` files, and a language server is asked only when the model isn't sure.

Names resolve the way the analyzer binds them:

- **Libraries** (`DartLayout`): every `.dart` file under the root (`build`, `.dart_tool`, hidden folders and the
  platform folders of a Flutter app left out) is a library, or a part of the library that names it (`part` and
  `part of`, by URI or by library name), which is one CodeModel module with it, named by the library's path. Private
  names (`_x`) are seen only in their own library and its parts.
- **Imports and exports**: `import` with `as`, `show`, `hide` and `deferred`; `export` with `show` and `hide` (a
  library's namespace is its public declarations plus what it exports, transitively); `dart:core` is imported unless a
  file imports it itself. A name is looked up in the body's locals, the enclosing types' members (their type
  parameters too), the library's own declarations, then its imports (a project's or package's name wins over a `dart:`
  one of the same name), then prefixes, then inherited members through `this`.
- **Packages**: `package:` URIs resolve through the package a file is in (the deepest folder with a `pubspec.yaml`):
  its `.dart_tool/package_config.json` (paths written for another machine's pub cache are looked for in this one's),
  else `pubspec.lock` with the pub cache (`PUB_CACHE`, `~/.pub-cache`, Windows' `%LOCALAPPDATA%\Pub\Cache`; hosted
  packages at their locked version, path packages where the lock says), then the packages under the root by name. A
  package that isn't on disk stays unknown. A package's files are read in place.
- **Declarations** (`DartSyntax`): classes with their modifiers (`abstract`, `base`, `final`, `interface`, `sealed`,
  `mixin class`), mixins with `on`, enums with members and constructors, extensions (named or not) and extension
  types, typedefs (both forms), constructors (the unnamed one is `new`, named ones, `factory`, `const`, redirecting and
  initializer lists), `this.x` and `super.x` parameters, getters and setters (a setter is named `x=`), operators,
  fields, top-level functions and variables, generics with bounds, metadata skipped.
- **Scopes** (`DartBody`): parameters, locals (`var`, `final`, typed, `late`), local functions, `for` and `for-in`
  (`await for` too), `catch (e, s)`, closures' parameters, pattern variables (declarations, `if (… case …)`, switch
  statement cases and switch expression arms, with `when` guards). `_` is a wildcard and answers nothing.
- **Types** (`DartTypes`, `DartExpressions`): members through superclasses, mixins and interfaces, generics
  substituted, type parameters as their bounds; extensions' members on the types they apply to, with their own type
  parameters bound. Expressions: literals (collections with their type arguments, records), names, `this`/`super`,
  calls (a class called is its unnamed constructor; generic functions' type arguments from explicit ones, then the
  arguments, closures' results too), `await` (`Future`, `FutureOr`), cascades (`..`, `?..`), `?.`, `!`, `??`, `?:`,
  `as`, `is`, operators on numbers, strings and the user's `operator` declarations, indexes, `switch` expressions,
  `var`/`final` from their initializer, `for-in` over `Iterable` and `Stream`. Promotion: `x is T` in an `if`, a `&&`, a
  `?:`, after `if (x is! T) return;` and `x is! T || …`, and `case T()` patterns.
- **Places** (`place(of:)`): as the bench's analyzer reference places them: a path relative to the root and a line; a
  package's file outside the root as `package:<name>/<path>`; a `dart:` declaration as
  `dart:<library>/<Owner>.<member>` (`Owner.new` for an unnamed constructor, `operator ==`, `name=` for a setter, a
  parameter as `Owner.member.parameter`).

**Unknown on purpose**: `dynamic` receivers, names from packages not on disk (Flutter's when no Flutter SDK is
installed), record fields (`$1`, named fields), the language's `values`/`index` of enums where the stub doesn't
declare them, and declarations the stub lacks.

**The `dart:` libraries**: from a Dart SDK on disk (`CODE_DART_SDK`, `DART_SDK`, a Flutter SDK's `bin/cache/dart-sdk`
from `FLUTTER_ROOT`, FVM or the usual folders, Homebrew's, `/usr/lib/dart`), each library with its parts; `dart:ui`
from a Flutter SDK's `sky_engine`. Without one, `DartStd`: a hand-written stub of `dart:core`, `async`, `convert`, `io`,
`typed_data`, `math`, `developer`, `isolate`, `collection` and `ffi` (signatures only, marked as Code's stub at its
top), written to `$TMPDIR/code-dart-std/` when a file is opened.

## Platforms

<!-- platforms: macos ios linux windows -->

- **macOS, Linux, Windows**: everything; packages from the pub cache, the `dart:` libraries from an SDK or the stub.
- **iOS (iPadOS)**: builds and answers; the project's own files and the stub.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeDartModel", package: "Code"),
```

CodeDartModel re-exports CodeModel. The target builds in Swift 5 language mode; the model isn't thread-safe. Give it
its own serial queue.

```swift
import CodeDartModel

let model = DartModel(root: "/path/to/app")
let file = "/path/to/app/lib/main.dart"
let answer = model.answer(path: file, line: 41, character: 12)  // from 0, UTF-16
for site in answer.sites {
  if let place = model.place(of: site) { print(place.path, place.line) }
}
model.project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 41, character: 12, limit: 40)
print(list.context, list.items.map(\.label))
```

## Main API

`DartModel` is a `LanguageModel` (CodeModel), so it is asked as the other models are.

### Loading a project

`DartModel(root:)` finds the packages under the root and reads their files; `DartModel(project:)` takes a `Project`
whose layout is a `DartLayout`. `project` is CodeModel's `Project`.

### Definitions and references

- `answer(path:line:character:)`, `location(of:)` (a stub's file is written out first), `place(of:)`.
- `references(of:)`: where an answer's definitions are used, a line each, in the project (a class's constructors
  count as it; a named parameter is also found as the named arguments that pass it).

### Completion

`complete(path:line:character:limit:)` returns a `ModelCompletionList`: after `.`, a value's members and the extension
members that apply, a type's static members and constructors, an enum's values, a prefix's names; in a call's
parentheses its named parameters first; nothing in strings, comments or where a new name is declared; elsewhere locals,
the enclosing types' members, the library's and its imports' names, prefixes and keywords. Functions come as snippets
with their parameters as placeholders; `@Deprecated` members rank last.

### Symbol details

`details(of:)` returns `SymbolDetails`: the declaration on one line (`Future<String> read(String path, {bool cached =
true}) async`, `class Channel<State>`, `final int count`, an inferred variable with its type), the `///` doc comment as
text, its parents (the types out to the library, as its path or `package:` or `dart:` URI) and a value's type.

`ModelLanguage.dart`: the extension (`dart`), the manifests (`pubspec.yaml`, `pubspec.lock`, `package_config.json`,
`analysis_options.yaml`) and how to make the model, for CodeKit and `code-model`.

### The code-model tool

```bash
swift run code-model query --root ~/Projects/app --language dart --queries reference.json --out answers.json
swift run code-model complete --root ~/Projects/app --language dart --at lib/main.dart:41:12
```

## Numbers

From `../Demos/CodeModelBench/dart` (2026-11-17, release build). **Not scored against a reference yet**: the analysis
server in the local `dart:3.13.5` Docker image is the reference (`dart/tools/dartref.py`), and the Docker VM didn't run
containers that day, so these are answer states and hand checks, not accuracy.

- channel-dart (tuned on), every identifier (16,664): 88.0% exact, no candidates, 12.0% unknown, mostly words that
  name nothing (`await`, `late`, `required`, `Function`, `_`) and `package:test`'s names, not on this Mac.
- hub-service-dart 85.4% exact, moq 83.5%, moq_ffi (a 12,000-line generated FFI file) 91.3%; a Flutter app without the
  Flutter SDK 53.9%.
- About 130 sampled exact answers across four corpora checked by hand: all right.
- A median of 0.002 ms per answer, the first in 11–98 ms; channel-dart's 16,664 in 0.2 s with a peak RSS of 63 MB.
- 3,000 random words of each corpus: no crash, no hang.

## Testing

```bash
swift test --filter CodeDartModelTests
```

The tests write small projects (a `pubspec.yaml`, `.dart` files, a `package_config.json` with a package beside the
project) to a temporary folder with `@@` before the words they ask about, and read the stub.

## Related

- [CodeSwiftModel](CodeSwiftModel.md), [CodeGoModel](CodeGoModel.md), [CodeTypeScriptModel](CodeTypeScriptModel.md),
  [CodeClangModel](CodeClangModel.md), [CodePythonModel](CodePythonModel.md), [CodeRustModel](CodeRustModel.md),
  [CodeJavaModel](CodeJavaModel.md), [CodeKotlinModel](CodeKotlinModel.md) and [CodeCSharpModel](CodeCSharpModel.md):
  the other models, and the [CodeModel core](CodeSwiftModel.md#codemodel-the-core) all are built on.
- [CodeScan](CodeScan.md): the tokens the model reads, and the tier before it.
- [CodeKit](CodeKit.md): the definition tiers that ask the model.
- [CodeLSP](CodeLSP.md): Dart's language server (`dart language-server`), the tier after it.
