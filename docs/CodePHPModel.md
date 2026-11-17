# CodePHPModel

## Purpose

CodePHPModel is a model of a PHP project built from its source text, on
[CodeModel](CodeSwiftModel.md#codemodel-the-core) and [CodeScan](CodeScan.md)'s tokens, without running PHP, Composer
or a language server. It answers where a name is defined (exact, a few candidates, or unknown), what can be completed
at a position, where a definition is referenced and what a symbol is, in milliseconds. It reads the `.php` and `.phtml`
files under a folder, the Composer packages its names reach in `vendor/`, and PHP's own functions and classes from a
hand-written stub.

It is not an interpreter: it follows declared types, PHPDoc and the types it can infer for sure, and gives candidates
(or nothing) otherwise, since an unknown answer is better than a wrong exact one. It never runs `composer install`,
downloads or installs anything. It is PHP's model in the middle of Code's three tiers (CodeKit's `CodeTiers`): CodeScan
guesses first, the model answers for `.php` and `.phtml` files, and a language server is asked only when the model
isn't sure.

Names resolve the way PHP binds them:

- **Files** (`PHPLayout`): every `.php` and `.phtml` file under the root (`vendor`, `node_modules` and hidden folders
  left out) is read, each its own module. Classes, functions and constants are found by their fully qualified name
  across them, so it doesn't matter which file declares a name. Inline markup, `<?php`, `<?=` and `?>` are CodeScan's.
- **Namespaces and imports**: `namespace A;` and `namespace A { }`, `use A\B`, `use A\B as C`, group uses
  (`use A\{B, C}`), `use function` and `use const`. A class name goes through the imports, then the namespace. A
  function or a constant goes through `use function`/`use const`, then the namespace, then the global one, as PHP falls
  back.
- **Composer** (`PHPLayout`): every `composer.json` under the root (or the nearest above it) with its vendor folder.
  When Composer has run, its generated `vendor/composer/autoload_psr4.php`, `autoload_namespaces.php`,
  `autoload_classmap.php` and `autoload_files.php`; else `composer.json`'s and `vendor/composer/installed.json`'s
  `autoload` sections (PSR-4 longest prefix first, PSR-0, classmap folders, `files`). A class that isn't in the project
  is looked up there and its file read in place when a name reaches it. `include`/`require` with a literal path
  (`__DIR__ . '/x.php'` too) answers that file.
- **Declarations** (`PHPSyntax`): classes (`abstract`, `final`, `readonly`), interfaces, traits, enums (backed or not)
  with cases, constants, properties (typed, promoted constructor parameters, `readonly`), methods, functions, `define()`d
  constants, attributes skipped, anonymous classes (`new class(…) extends … { }`) as local classes.
- **Variables** (`PHPBody`): a variable's definition is its first binding in its function: a parameter, `$x =` and
  compound assignments, `$x[…] =`, `foreach (… as $k => $v)` (by reference too), `catch`, `global`, `static`, `[…] =`
  and `list(…) =`. A closure has its own scope with its `use` captures (a capture answers the outer variable); an arrow
  function sees its parent's. `$this` is the class around (an anonymous one too). Superglobals (`$_SERVER`,
  `$GLOBALS`, …) are the stub's.
- **Members** (`PHPTypes`): `->`, `?->` and `::`, through the class, its traits (with `insteadof` and `as`), its parents
  and its interfaces; `self`, `static` and `parent`. A member that isn't declared on a class with `__get`, `__set`,
  `__call` or `__callStatic` is unknown, never another class's.
- **Types**: native types (unions, intersections, nullable, `self`/`static`), PHPDoc's `@var`, `@param`, `@return`,
  `@property` and `@method` (the `psalm-` and `phpstan-` forms preferred), `T[]`, `array<K, V>`, `list<T>`,
  `iterable<T>` and generic arguments for `foreach`; a value from `new`, `clone`, a call's result with `static` and
  `$this` as the receiver, `??`, an inline `/** @var T $x */`. Narrowing: `instanceof` in an `if` and its `&&` terms,
  after `if (!$x instanceof T) return;` (or throw, continue, break), `assert($x instanceof T)`.
- **Places** (`place(of:)`): as the bench's reference places them: a path relative to the root and a line; a
  vendor's file as `vendor/…`; the stub's declarations as `php:<Name>` or `php:<Class>::<member>`, a superglobal as
  `php:$<name>`, on line 1.

**Unknown on purpose**: dynamic names (`$obj->$name`, `$$x`, `new $class`), magic members on classes with `__get` and
`__call`, `mixed` and untyped values, array shapes' keys, extensions' functions and classes the stub lacks (FFI,
OpenSwoole, pcntl, posix, …), packages that aren't in `vendor/`, and the words of a `namespace` line.

**PHP's own declarations**: `PHPStd`, a hand-written stub (signatures only, marked as Code's stub at its top) of the
superglobals, the core interfaces and classes (`Throwable` and the exceptions, `Closure`, `Generator`, `Fiber`,
`WeakMap`, `Stringable`, `ArrayAccess`, attributes, `PhpToken`), the SPL, dates, PDO, Reflection, about 400 functions
and the common constants, written to `$TMPDIR/code-php-std/php.php` when a file is opened.

## Platforms

<!-- platforms: macos ios linux windows -->

- **macOS, Linux, Windows, iOS (iPadOS)**: everything; the stub is the same everywhere and Composer's files are read
  in place.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodePHPModel", package: "Code"),
```

CodePHPModel re-exports CodeModel. The target builds in Swift 5 language mode; the model isn't thread-safe. Give it
its own serial queue.

```swift
import CodePHPModel

let model = PHPModel(root: "/path/to/app")
let file = "/path/to/app/src/Server.php"
let answer = model.answer(path: file, line: 41, character: 12)  // from 0, UTF-16
for site in answer.sites {
  if let place = model.place(of: site) { print(place.path, place.line) }
}
model.project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 41, character: 12, limit: 40)
print(list.context, list.items.map(\.label))
```

## Main API

`PHPModel` is a `LanguageModel` (CodeModel), so it is asked as the other models are.

### Loading a project

`PHPModel(root:)` reads the files under the root and Composer's autoloading; vendor files are read when a name reaches
them. `project` is CodeModel's `Project`.

### Definitions and references

- `answer(path:line:character:)`, `location(of:)` (the stub is written out first; an included file opens at its
  start), `place(of:)`.
- `references(of:)`: where an answer's definitions are used, a line each, in the project.

### Completion

`complete(path:line:character:limit:)` returns a `ModelCompletionList`: after `->` and `?->`, a value's instance
members; after `::`, a class's constants, cases and static members (every method after `self`, `static` and `parent`)
and `class`; after `$`, the variables in scope, `$this` and the superglobals; after `new`, `instanceof`, `extends` and
`implements`, classes; nothing in strings, comments or where a new name is declared; elsewhere the namespace's and the
global functions, classes and constants and the keywords. Functions and methods come as snippets with their parameters
as placeholders; deprecated ones (`@deprecated`) rank last. Private and protected members are listed wherever the
type is known (visibility isn't checked yet).

### Symbol details

`details(of:)` returns `SymbolDetails`: the declaration on one line (`public function find(int $id): ?User`,
`final class Server`, `private readonly Logger $logger`, a variable with its type), the docblock as text, its parents
(the class and the namespace or file) and a value's type.

`ModelLanguage.php`: the extensions (`php`, `phtml`), the manifests (`composer.json`, `composer.lock`,
`autoload_psr4.php`, `installed.json`) and how to make the model, for CodeKit and `code-model`.

### The code-model tool

```bash
swift run code-model query --root ~/Projects/app --language php --queries reference.json --out answers.json
swift run code-model complete --root ~/Projects/app --language php --at src/Server.php:41:12
```

## Numbers

From `../Demos/CodeModelBench/php` (2026-11-17, release build). No PHP is installed here, so the reference is
`php/tools/phpref.py`, a resolver written for the bench apart from the model (it shares only a Python lexer): it names
only what PHP makes unambiguous (variables' bindings, classes through imports and Composer, functions, constants,
`$this`/`self`/`static`/`parent` members, members of parameters and properties declared with one class) and leaves the
rest out of the score.

- channel-php (tuned on), every identifier (12,614): of the 9,822 with a reference, 100.0% exact right, none wrong;
  references at 99.9% recall and 99.1% precision. Of all 12,614, 91.6% exact, 79 candidates, 7.7% unknown, mostly
  extensions' APIs the stub lacks and namespace names.
- Held out, scored once: hub-service-php 100% of 3,531 exact right, none wrong; nikic/php-parser 99.9% (26,349 of
  26,373), none wrong, 21 unknown and 3 candidates (right first), from docblock words (`Scalar`, `Double`) taken for
  types, fixed since.
- About 80 exact answers without a reference checked by hand: all right.
- A median of 0.001–0.002 ms per answer, the first in 40–160 ms; channel-php's 12,614 in 0.2 s with a peak RSS of
  54 MB; a generated 10,000-line file's 21,502 identifiers in 0.24 s.
- 3,000 random words of each of 27 vendor packages: no crash, no hang, the slowest 28 ms.

## Testing

```bash
swift test --filter CodePHPModelTests
```

The tests write small projects (`.php` files, a `composer.json` and a vendor package) to a temporary folder with `@@`
before the words they ask about, and read the stub.

## Related

- [CodeSwiftModel](CodeSwiftModel.md), [CodeGoModel](CodeGoModel.md), [CodeTypeScriptModel](CodeTypeScriptModel.md),
  [CodeClangModel](CodeClangModel.md), [CodePythonModel](CodePythonModel.md), [CodeRustModel](CodeRustModel.md),
  [CodeJavaModel](CodeJavaModel.md), [CodeKotlinModel](CodeKotlinModel.md), [CodeCSharpModel](CodeCSharpModel.md) and
  [CodeDartModel](CodeDartModel.md): the other models, and the [CodeModel core](CodeSwiftModel.md#codemodel-the-core)
  all are built on.
- [CodeScan](CodeScan.md): the tokens the model reads, and the tier before it.
- [CodeKit](CodeKit.md): the definition tiers that ask the model.
- [CodeLSP](CodeLSP.md): PHP's language server (Intelephense), the tier after it.
