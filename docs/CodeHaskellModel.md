# CodeHaskellModel

## Purpose

CodeHaskellModel is a model of a Haskell project built from its source text, on
[CodeModel](CodeSwiftModel.md#codemodel-the-core) and [CodeScan](CodeScan.md)'s tokens. It doesn't run GHC, cabal,
stack or a language server. In milliseconds it answers:

- where a name is defined: exact, a few candidates, or unknown;
- what can be completed at a position;
- where a definition is referenced;
- what a symbol is.

It reads the `.hs` and `.hs-boot` files under a folder, and the modules they import but don't have (base's Prelude,
Data.List, Control.Monad …, containers' Data.Map, text's Data.Text, mtl's State and Reader) from a hand-written stub.

It doesn't infer types. Haskell's names don't need them: GHC's renamer finds what every name means before type
checking, from scopes, imports and export lists alone, and the model does the same. What would need types (which
instance a method call picks, a record field reached with `x.f` when two records have one) it gives as candidates or
leaves unknown, since an unknown answer is better than a wrong exact one. It never downloads or installs anything.

It is Haskell's model in the middle of Code's three tiers (CodeKit's `CodeTiers`):

1. CodeScan guesses first.
2. The model answers for `.hs` and `.hs-boot` files.
3. A language server would be asked only when the model isn't sure, but CodeLSP's catalog has none for Haskell yet
   (haskell-language-server would be the one), so CodeScan's own server stands in.

Names resolve the way GHC's renamer binds them:

- **Files** (`HaskellLayout`). Every `.hs` and `.hs-boot` file under the root (hidden folders, `dist-newstyle`, `dist`
  and `node_modules` left out) is read, and a file is found by the module its `module` line names (`Main` without
  one). When two files declare a module, the `.hs` comes before its `.hs-boot`, then the importing file's own package.
  Packages are the folders with a `.cabal` file or hpack's `package.yaml`; their `default-extensions` count for every
  file under them, with each file's `{-# LANGUAGE … #-}` pragmas.
- **Layout** (`HaskellBlocks`). The layout rule (Haskell 2010's §10.3) turns the tokens into a stream with virtual
  braces and semicolons. Its parse-error(t) rule is taken as the cases that need it in practice: `in` closes a `let`
  block, a closing bracket the blocks opened inside it, a comma the blocks opened at its bracket level (not inside a
  guard), `then`, `else` and `of` the blocks opened since their `if` or `case`, and a `where` lined up with a `do` or
  `case` block's items ends that block. C preprocessor lines are left out, so both branches of an `#if` are read.
- **Syntax** (`HaskellParser`). The whole module is read: header and export list, imports, and every declaration —
  signatures and equations (a function's clauses one definition, infix definitions like ``x `op` y`` and `a <+> b`),
  pattern bindings, `data` and `newtype` with constructors (infix ones, records, GADT syntax), type synonyms, type and
  data families, classes (methods, defaults, associated types, functional dependencies), instances, pattern synonyms,
  `foreign import`, fixity declarations, standalone deriving, Template Haskell's top-level splices as expressions. It
  steps over what it can't read, so code being typed keeps its names.
- **Locals**, scoped as Haskell scopes them: an equation's argument patterns and its `where` bindings over its guards
  and right-hand sides; `where` and `let` groups recursive; `do` binds from the next statement, `let` statements to the
  block's end; `case` and `\case` alternatives, lambdas, pattern guards left to right, list comprehensions' qualifiers
  before the expression written ahead of them; as-patterns, view patterns, bang and lazy patterns.
- **Type variables**: bound at their first occurrence in a signature, by an explicit `forall`, or by the head of a
  `data`, `class` or `instance` declaration (a class's methods see its variables); a signature's `forall` also reaches
  its function's equations (ScopedTypeVariables).
- **Free names**: values and types in their own namespaces. An unqualified name is the module's own top level
  (constructors, fields and methods included), else what its unqualified imports bring in: the imported modules'
  export lists (`T(..)`, `T(a, b)`, `module X` re-exports; none exports everything), import lists, `hiding` (hiding
  `C` hides a type and a constructor of that name), plus the implicit Prelude unless Prelude is imported or
  `NoImplicitPrelude` is on. One declaration is exact, several are candidates, none is unknown. `Q.x` looks in the
  imports named `Q` (by `as`, else by module).
- **Classes**: a method used anywhere, and an instance's equation for it, answers the method's signature in its class.
  Which instance runs is a matter of types, so it isn't answered.
- **Records**: a field's name in `C { f = e }`, `r { f = e }` and record patterns answers the field. RecordWildCards'
  `C{..}` binds the constructor's fields, so a name it binds answers the field; NamedFieldPuns' `C {f}` binds a local.
  With OverloadedRecordDot, `x.f` and `(.f)` answer the one field of that name in scope, else the fields of that name
  as candidates (the record's type isn't inferred).
- **Modules**: a module's name in `module`, `import`, `as` and a qualifier answers the module's file (its `module`
  line).
- **Places** (`place(of:)`), as the bench's reference names them: a path relative to the root and a line; the stub's
  are `std:<Module>` and the line in Code's stub of that module.

**Unknown or left out on purpose**: types and what needs them (an instance's method for a given call, `x.f`'s record
when several have the field), quasi-quotes' contents, Template Haskell's generated names (`makeLenses`), names from a
module neither the project nor the stub has, literate Haskell (`.lhs`), the C preprocessor's conditions (both branches
are read), and packages' sources on disk: there are none on this Mac (no `~/.ghcup`, `~/.stack` or `~/.cabal`), and
`~/.cabal/packages` keeps them as tarballs, which the core doesn't read.

**The stub**: `HaskellStd`, one hand-written module per file (marked as Code's stub at the top of each) of base's
Prelude, Data.List, Data.Maybe, Data.Either, Data.Char, Data.Function, Data.Ord, Data.Foldable, Data.Traversable,
Data.IORef, Data.Kind, Data.Word, Data.Int, Data.Bits, Data.Functor, Data.Functor.Identity, Control.Monad,
Control.Applicative, Control.Exception, Control.Concurrent(.MVar), Control.Monad.IO.Class, System.IO, System.Exit,
System.Environment, Text.Printf, Text.Read and Debug.Trace, containers' Data.Map(.Strict), Data.Set and Data.IntMap,
text's Data.Text(.IO), transformers' Control.Monad.Trans.Class and mtl's Control.Monad.State and Control.Monad.Reader:
export lists, data types, classes and signatures, no bodies. It is generated by
`../Demos/CodeModelBench/hs/tools/gen_std.py` from `tools/std/*.hs`; a module is read only when an import names it
and no project file declares it, and written to `$TMPDIR/code-haskell-std/` then.

**The lexer** (CodeScan's Haskell rules): every run of symbol bytes is one operator (`<-`, `.:`, `|->`), a run of
dashes alone starts a comment but `-->` and `|--` are operators, `Map.!` is `Map`, `.` and `!`, a prime continues a
name (`foldl'`) while `'a'` stays a character, and `{- -}` comments nest.

## Platforms

<!-- platforms: macos ios linux windows -->

- **macOS**, **Linux**, **Windows**: everything.
- **iOS (iPadOS)**: everything; the project's own files and the stub.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeHaskellModel", package: "Code"),
```

CodeHaskellModel re-exports CodeModel. The target builds in Swift 5 language mode, and the model isn't thread-safe:
give it its own serial queue.

```swift
import CodeHaskellModel

let model = HaskellModel(root: "/path/to/project")
let file = "/path/to/project/src/Parser.hs"
let answer = model.answer(path: file, line: 24, character: 6)  // from 0, UTF-16
for site in answer.sites {
  if let place = model.place(of: site) { print(place.path, place.line) }
}
model.project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 24, character: 6, limit: 40)
print(list.context, list.items.map(\.label))
```

## Main API

`HaskellModel` is a `LanguageModel` (CodeModel), so it is asked as the other models are.

### Loading a project

`HaskellModel(root:)` reads the root's packages (`*.cabal`, `package.yaml`) and parses its `.hs` and `.hs-boot`
files. `HaskellModel(project:)` takes a `Project` whose layout is a `HaskellLayout`. The tables of modules, exports and
imports are built when a question needs them and dropped when a file's shape (its module name, exports, imports or
declarations) changes; an edit inside a body keeps them.

### Definitions and references

- `answer(path:line:character:)`, `location(of:)` (the stub's file is written out first), `place(of:)`.
- `references(of:)`: where an answer's definitions are used in the project, one line each, operators included
  (CodeModel's `Project.references(named:in:landingOn:operators:answer:)`).

### Completion

`complete(path:line:character:limit:)` returns a `ModelCompletionList`:

- **After `Q.`**: what the imports named `Q` bring in.
- **After `x.`** with OverloadedRecordDot: the fields in scope.
- **After `import`** (and `qualified`): the modules, the project's and the stub's, the rest of a dotted name.
- **Elsewhere**: the locals in scope (type variables too), the module's own top level, what its imports bring in
  unqualified, the Prelude's, and keywords. An operator is inserted in parentheses. Nothing in comments and strings.

### Symbol details

`details(of:)` returns `SymbolDetails`:

- the declaration: `name :: type` from its signature (a field's, a method's, a GADT constructor's), a constructor with
  its fields' types, else its line; a local with its signature when it has one;
- the Haddock comment above it (`-- |` and the lines after it, or `{-| … -}`);
- what it's inside (its data type or class) and its module.

### ModelLanguage.haskell

`ModelLanguage.haskell` holds, for CodeKit and `code-model`:

- the extensions: `hs`, `hs-boot`;
- the manifests: `*.cabal`, `cabal.project`, `cabal.project.local`, `stack.yaml`, `package.yaml`, `hie.yaml`;
- how to make the model.

### The code-model tool

```bash
swift run code-model query --root ~/Projects/app --language haskell --queries reference.json --out answers.json
swift run code-model complete --root ~/Projects/app --language haskell --at src/Parser.hs:24:6
swift run code-model tokens --all --root ~/Projects/app --language haskell   # CodeScan's names, for hs/tools/lexcheck.py
```

## Numbers

Measured on 2026-11-17 with `code-model` against `../Demos/CodeModelBench/hs` (its README has the details). There is
no Haskell toolchain or project on this Mac and nothing was downloaded, so the projects are three written for the
bench and the reference is the bench's own resolver (`hs/tools/hsref.py`, written apart from the model), which names
only what Haskell makes unambiguous from the source:

| Project | Positions | Exactly right | Wrong | References recall / precision |
|---|---|---|---|---|
| taskboard (tuned on) | 2,754 | 100% | 0 | 100% / 100% |
| minilang (held out) | 3,562 | 100% | 0 | 100% / 100% |
| inventory (held out) | 1,463 | 100% | 0 | 100% / 100% |

The held-out projects were right on the first run. Completion (400 cases each) lists the word 99.0–99.5% of the time,
first 39.5–45.2%, in the top 5 62.0–68.8%, in a median of 0.4–0.6 ms with the edit. The first answer takes 10–25 ms,
then 0.001 ms (p95 under 0.01 ms), in 21–38 MB. 20,000 random positions over each project, the stub and 150 garbled
files made no crash or hang.

## Testing

```bash
swift test --filter CodeHaskellModelTests
```
