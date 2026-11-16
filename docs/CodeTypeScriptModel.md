# CodeTypeScriptModel

## Purpose

CodeTypeScriptModel is a model of a TypeScript or JavaScript project built from its source text, on
[CodeModel](CodeSwiftModel.md#codemodel-the-core) and [CodeScan](CodeScan.md)'s tokens, without TypeScript's compiler
or tsserver. It answers where a name is defined (exact, a few candidates, or unknown), what can be completed at a
position, where a definition is referenced and what a symbol is (its declaration line, its JSDoc, what holds it), in
milliseconds. It reads `.ts`, `.tsx`, `.mts`, `.cts`, `.d.ts`, `.js`, `.jsx`, `.mjs` and `.cjs` files, TypeScript's own
`lib.*.d.ts` files and the packages' types in the project's `node_modules`, each file only when a question reaches it.

It is not a type checker and it never downloads or installs anything: a package that isn't in `node_modules` stays
unknown. It is the TypeScript model in the middle of Code's three tiers (CodeKit's `CodeTiers`): CodeScan guesses
first, the model answers for TypeScript and JavaScript files, and a language server (typescript-language-server, when
installed) is asked only when the model isn't sure.

Names resolve the way TypeScript's language service resolves them:

- **Files and modules** (`TSLayout`): every file is its own module, named by its path; the global scope is the lib
  files (`compilerOptions.lib`, else the target's, and `/// <reference lib>`), the type roots (`@types/*`,
  `compilerOptions.types`), `declare global` blocks and the project's scripts (files without imports or exports).
  Imports resolve as `bundler`/`node` resolution does: relative files with their extensions (`./a.js` is `./a.ts`) and
  index files, `tsconfig.json`'s `paths` and `baseUrl` (with `extends`), packages in `node_modules` (`exports` with
  TypeScript's conditions, `types`, `typings`, `main`, a `.d.ts` beside a `.js`, `@types/`), a monorepo's own packages
  by their `package.json` names when they aren't linked, and ambient modules (`declare module "fs"`). The lib files
  are the project's `node_modules/typescript/lib`, else an installed TypeScript (Homebrew, npm, bun, VS Code's), or
  `CODE_TYPESCRIPT_LIB`.
- **Declarations** (`TSSyntax`): classes, interfaces, type aliases, enums, functions and their overloads, namespaces
  and `declare module` blocks (merged across files: an interface declared in several lib files is one symbol, and a
  module augmentation adds to the module it names), object types and literals, `export` in every form (`export { a as
  b }`, `export default`, `export =`, `export * as ns`, re-exports), `import x = A.B`, CommonJS (`require`,
  `module.exports`, `exports.a`) and, in JavaScript, `globalThis.name = value`.
- **Bodies** (`TSBody`): locals with their scopes (blocks, `for … of`, `catch`, destructuring), parameters, arrow
  functions and function expressions, `this` in classes, read once when a position inside asks.
- **Types** (`TSTypes`): the type of an expression (calls with their type arguments inferred from plain arguments,
  `new`, property access, element access, `await`, literals, `as` and `satisfies`, unions without `null` and
  `undefined`, intersections, utility types such as `Partial`, `Awaited`, `ReturnType` and `Record`), so that `x.y`
  finds y among x's members and its bases'. A literal's key is the property of the type it's written for (a typed
  variable, a parameter, a return type, an element), an overload is picked by its arguments, and a value whose type
  can't be told gives candidates by name, never a confident answer.

## Platforms

<!-- platforms: macos ios=partial linux windows=partial -->

- **macOS, Linux**: everything; the lib files from the project's `node_modules/typescript` or an installed TypeScript.
- **Windows**: builds and reads the project and its `node_modules`; an installed TypeScript is looked for only in POSIX
  folders, so without the project's own copy (or `CODE_TYPESCRIPT_LIB`) there are no lib files.
- **iOS (iPadOS)**: builds; the project and its `node_modules` only.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeTypeScriptModel", package: "Code"),
```

CodeTypeScriptModel re-exports CodeModel. The target builds in Swift 5 language mode; the model isn't thread-safe.
Give it its own serial queue.

```swift
import CodeTypeScriptModel

let model = TSModel(root: "/path/to/project")
let file = "/path/to/project/src/server.ts"
let answer = model.answer(path: file, line: 41, character: 12)  // from 0, UTF-16
for site in answer.sites {
  if let place = model.location(of: site) { print(place.path, place.line, place.name) }
}
model.project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 41, character: 12, limit: 40)
print(list.context, list.items.map(\.label))
```

## Main API

`TSModel` is a `LanguageModel` (CodeModel), so it is asked as Swift's and Go's models are.

### Loading a project

`TSModel(root:)` reads the project under a folder: `tsconfig.json` or `jsconfig.json` and its source files, leaving out
`node_modules` and build folders. `project` is CodeModel's `Project` (`update(path:text:)`, `units`, `projectUnits`,
`loadedBytes`).

### Definitions and references

```swift
let answer = model.answer(path: file, line: 41, character: 12)
for use in model.references(of: answer) { print(use.path, use.line) }
for site in answer.sites { if let place = model.place(of: site) { print(place.path, place.line) } }
```

- `answer(path:line:character:)`, `location(of:)`. A use of a namespace import (`import * as X from "m"`) answers
  the import, as TypeScript does; a module is placed at its first token.
- `place(of:)`: a site as TypeScript's language service names it: a path relative to the root (`node_modules/...` too,
  `../x` outside it), or `lib:<file>` for TypeScript's lib files.
- `references(of:)`: where an answer's definitions are used, a line each, through import aliases and export names.

### Completion

`complete(path:line:character:limit:)` returns a `ModelCompletionList`: after `.`, a value's members (its bases'
after its own) or a module's exports; in an object literal, the properties of the type it's written for; in `import {
… } from "m"`, what m exports; elsewhere the locals, type parameters, the file's declarations, imports, globals and
keywords. `@deprecated` marks items.

### Symbol details

`details(of:)` and `details(path:line:character:)` return `SymbolDetails` with the declaration's line (a variable's
inferred type when it has none written), its JSDoc's first paragraph and its parents (the class, interface or
namespace, the file).

`ModelLanguage.typeScript`: the files, the manifests (`tsconfig.json`, `jsconfig.json`, `package.json`) and how to
make the model, for CodeKit and `code-model`.

### The code-model tool

```bash
swift run code-model query --root ~/Projects/web --language typescript --queries reference.json --out answers.json
swift run code-model complete --root ~/Projects/web --language typescript --at src/server.ts:41:12
swift run code-model bench --root ~/Projects/web --language typescript --at src/server.ts:41:12
```

## Numbers

Against TypeScript 5.9.3's language service, from `../Demos/CodeModelBench/ts/README.md` (which has the tools and how
to run them). Held-out projects, 300 sampled identifiers each: right 95.1% (vijo-node, a Bun server with
`node_modules`), 95.3% (moq-js, a TypeScript 7 monorepo of 16 packages) and 97.2% (brainfly-node, JavaScript); wrong
3.9%, 3.2% and 0.4%; references 94.6 to 98.5% recall and 97.4 to 99.6% precision. All 48,070 identifiers of hub (a
Bun TypeScript project) with an answer: 98.2% right, 93.5% exact, 1.1% wrong. Release build: the first answer in 85 to
320 ms, then a median of 0.001 to 0.004 ms and a p95 of 0.006 to 0.05 ms per definition; 27 to 97 MB peak. Completion,
the author's word deleted or its first two characters left: listed 91.5 to 92.9%, first 46 to 49%, in the top five 74
to 75%.

## Testing

```bash
swift test --filter CodeTypeScriptModelTests
```

The tests write small projects to a temporary folder with `@@` before the words they ask about, and a small stand-in
for TypeScript's lib files, so they don't need TypeScript installed.

## Related

- [CodeSwiftModel](CodeSwiftModel.md) and [CodeGoModel](CodeGoModel.md): the other models, and the
  [CodeModel core](CodeSwiftModel.md#codemodel-the-core) all are built on.
- [CodeScan](CodeScan.md): the tokens the model reads, and the tier before it.
- [CodeKit](CodeKit.md): the definition tiers that ask the model.
- [CodeLSP](CodeLSP.md): the TypeScript language server, the tier after it.
