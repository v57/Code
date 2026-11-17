# CodeClangModel

## Purpose

CodeClangModel is a model of a C, C++ or Objective-C project built from its source text, on
[CodeModel](CodeSwiftModel.md#codemodel-the-core) and [CodeScan](CodeScan.md)'s tokens, without clang or clangd. It
answers where a name is defined (exact, a few candidates, or unknown), what can be completed at a position (members
after `.`, `->` and `::`, an Objective-C receiver's methods, else what's in scope), where a definition is referenced and
what a symbol is (its declaration line, its doc comment, what holds it), in milliseconds. It reads `.c`, `.h`, `.cc`,
`.cpp`, `.cxx`, `.hpp`, `.hh`, `.hxx`, `.m` and `.mm` files, and the headers they include: the project's, clang's own,
the SDK's and its frameworks', each only when a question reaches it.

It is not a compiler: it never expands a macro into code, and it never downloads or installs anything. It is the C
family's model in the middle of Code's three tiers (CodeKit's `CodeTiers`): CodeScan guesses first, the model answers
for C, C++ and Objective-C files (`.h` is one language for it: each header is read in the dialect of a file that
includes it), and a language server (clangd) is asked only when the model isn't sure.

Names resolve the way clangd resolves them:

- **Files** (`CLayout`): every file is its own module, and each `#include` or `#import` is an import the file
  re-exports, so a file sees what its includes' closure declares, in include order. Includes are found as clang finds
  them: the including file's folder for `"…"`, the folders of the project's `compile_commands.json` (`-iquote`,
  `-I`, `-isystem`, `-F`; its `-D`, `-U` and `-std` too, merged for the whole project rather than per file), then
  libc++ for C++, clang's own headers, the SDK's `usr/include` and its frameworks (`<Foundation/Foundation.h>`,
  umbrella frameworks inside others). A file's dialect comes from its extension; without `compile_commands.json` the
  defaults apply.
- **The preprocessor** (`CPreprocessor`, `CSyntax`): the compiler's predefined macros for this Mac, `#define` and
  `#undef` in order (a header's macros are seen by the files after it), and `#if`, `#ifdef`, `#elif` with integers,
  `defined`, `__has_include` and the other `__has_…` checks. Code a condition leaves out has no declarations, as in
  clangd: a word there answers the nearest same word in the code around it, else what an index search by name finds
  when that's one or two. A macro's use goes to its `#define`, a word in a macro's body to the nearest same word in
  code, and include guards are recognised.
- **Declarations** (`CParser`): functions and their prototypes, variables, typedefs (a C `typedef struct x y` declares
  the tag too), structs, unions, enums, bit-fields, function pointers and their parameters, K&R definitions, C++
  namespaces (libc++'s `_LIBCPP_BEGIN_NAMESPACE_STD`), classes with bases and access, templates, constructors and
  destructors in and out of line, operators, `using` and aliases, `extern "C"`, Objective-C `@interface`,
  `@implementation`, categories, protocols, properties and methods by selector. Export and availability macros
  (`API_AVAILABLE(…)`, `CMARK_GFM_EXPORT`) are stepped over, and a macro that writes a function's head
  (`static ALLOC_FUNC(name) { … }`) names the function by its argument.
- **Bodies** (`CBody`): locals with their scopes, labels, parameters, read once when a position inside asks.
- **Types** (`CTypes`): the type of an expression (calls, members, pointers and arrays, casts, `self` and `super`,
  messages, typedefs through forward-declared tags) so that `x.y` and `p->y` find y in x's type and its bases, and
  `[receiver selector]` finds the method on the receiver's class, its categories and protocols. C++ overloads,
  templates and argument-dependent lookup are answered as far as the declarations tell, with candidates otherwise.
- **Which declaration** (`CModel`): the definition (an `@implementation` for an Objective-C method), else the first
  declaration the file reads; from a definition, its first declaration (clangd's toggle). A `static` function is its
  own file's.

## Platforms

<!-- platforms: macos ios=partial linux=partial windows=partial -->

- **macOS**: everything, with the selected Xcode's SDK, libc++ and clang headers.
- **Linux, Windows**: builds and reads the project and the include folders of `compile_commands.json`; no SDK or
  clang headers are looked for.
- **iOS (iPadOS)**: builds; the project's own files only.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeClangModel", package: "Code"),
```

CodeClangModel re-exports CodeModel. The target builds in Swift 5 language mode; the model isn't thread-safe. Give it
its own serial queue.

```swift
import CodeClangModel

let model = CModel(root: "/path/to/project")
let file = "/path/to/project/src/list.c"
let answer = model.answer(path: file, line: 41, character: 12)  // from 0, UTF-16
for site in answer.sites {
  if let place = model.location(of: site) { print(place.path, place.line, place.name) }
}
model.project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 41, character: 12, limit: 40)
print(list.context, list.items.map(\.label))
```

## Main API

`CModel` is a `LanguageModel` (CodeModel), so it is asked as Swift's, Go's and TypeScript's models are.

### Loading a project

`CModel(root:)` reads the project under a folder and its `compile_commands.json` when there is one, leaving out build
folders. `project` is CodeModel's `Project` (`update(path:text:)`, `units`, `projectUnits`, `loadedBytes`).

### Definitions and references

- `answer(path:line:character:)`, `location(of:)`.
- `place(of:)`: a site as clangd names it: a path relative to the root, `sdk:<path in the SDK>`, `clang:<path in
  clang's headers>`, else the real path of its folder (a framework's `Headers` link resolved, `/opt/homebrew/opt/x`
  as its Cellar folder).
- `references(of:)`: where an answer's definitions are used, a line each.

### Completion

`complete(path:line:character:limit:)` returns a `ModelCompletionList`: after `.` and `->`, the members of the value's
type and its bases; after `A::`, a namespace's or class's members; in `[receiver |`, its methods (class methods after
a class's name) and properties, every known selector when the receiver's type isn't known; in `#if` lines, macros;
elsewhere the locals, parameters, the class's members (in an out-of-line method too), the enclosing namespaces' and
`using namespace`s' names, the file's and its includes' declarations, macros and keywords. Objective-C methods insert
their selector with placeholders.

### Symbol details

`details(of:)` and `details(path:line:character:)` return `SymbolDetails`: the declaration on one line, its doc
comment (`///`, `/** */`, else the comment above), its parents (class, namespace, Objective-C container, file) and a
variable's type.

`ModelLanguage.clang`: the extensions, the manifest (`compile_commands.json`) and how to make the model, for CodeKit
and `code-model`.

### Shared with Swift

`ClangModuleMap` (module maps and framework folders, walked the way clang walks them) is the one header-locating code
both models use: CodeSwiftModel's Clang importer reads it to find what a Swift `import` of a C module brings, so Swift
depends on this library rather than keeping a second reader.

### The code-model tool

```bash
swift run code-model query --root ~/Projects/lib --language c --queries reference.json --out answers.json
swift run code-model complete --root ~/Projects/lib --language c --at src/list.c:41:12
swift run code-model decls --root ~/Projects/lib --language c --at src/list.c
```

## Numbers

Against clangd 21 (Apple), from `../Demos/CodeModelBench/c/README.md` (tools and how to run them). Held-out projects,
400 sampled identifiers each, of those clangd answers: right 99.0% (gumbo, C), 96.7% (double-conversion, C++), 89.2%
(Objective-C), 91.7% (libssh2, C), 96.4% (scrypt, C, drawn last and scored once); wrong 0.0 to 3.9%; references 89.7
to 98.4% recall and 93.4 to 99.9% precision. Every identifier of cmark: 99.9% right. Release build: the first answer
in 0.3 to 1.3 s (Foundation's headers are the slow part), then a median of 0.005 to 0.11 ms per definition; 35 to 290
MB peak. Completion, the author's word deleted or its first two characters left: listed 81 to 96%, first 32 to 43%,
in the top five 53 to 70%.

## Testing

```bash
swift test --filter CodeClangModelTests
```

The tests write small projects to a temporary folder with `@@` before the words they ask about.

## Related

- [CodeSwiftModel](CodeSwiftModel.md), [CodeGoModel](CodeGoModel.md) and [CodeTypeScriptModel](CodeTypeScriptModel.md):
  the other models, and the [CodeModel core](CodeSwiftModel.md#codemodel-the-core) all are built on.
- [CodeScan](CodeScan.md): the tokens the model reads, and the tier before it.
- [CodeKit](CodeKit.md): the definition tiers that ask the model.
- [CodeLSP](CodeLSP.md): clangd, the tier after it.
