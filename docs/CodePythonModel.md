# CodePythonModel

## Purpose

CodePythonModel is a model of a Python project built from its source text, on
[CodeModel](CodeSwiftModel.md#codemodel-the-core) and [CodeScan](CodeScan.md)'s tokens, without running Python, Jedi or
Pyright. It answers where a name is defined (exact, a few candidates, or unknown), what can be completed at a position
(members after `.`, module names after `import` and `from`, a module's names after `from m import`, else what's in
scope), where a definition is referenced and what a symbol is (its `def` or `class` line, its docstring, what holds it,
a value's type), in milliseconds. It reads `.py`, `.pyi` and `.pyw` files and the modules they import: the project's,
the standard library's and a virtual environment's, each only when a question reaches it.

It is not a type checker: it follows declared types and the types it can infer for sure, and gives candidates by name
(or nothing) otherwise, since an unknown answer is better than a wrong exact one. It never installs or downloads
anything. It is Python's model in the middle of Code's three tiers (CodeKit's `CodeTiers`): CodeScan guesses first,
the model answers for Python files, and a language server (Pyright, when installed) is asked only when the model
isn't sure.

Names resolve the way Python and Pyright resolve them:

- **Modules** (`PyLayout`): a module is a file, a package a folder with `__init__.py`, a namespace package a folder
  without one (used only when no root has a module of the name); a `.pyi` beside a `.py` is the same module and answers
  for it. Imports look, in order, at the modules built into the interpreter (`sys`, `builtins`, `posix`, the C
  extension modules: generated stubs), the project's roots (the folder, `src/`, every folder with a `pyproject.toml`,
  `setup.cfg` or `setup.py` and the package folders those name: hatch's `packages`, setuptools' `where` and
  `package_dir`, poetry's `from`), the importing file's folder, the standard library's sources and a virtual
  environment's `site-packages` (`.venv`, `venv` or `env` with a `pyvenv.cfg`), which is read, never installed into.
  Relative imports go up from the importing file's package. `from m import *` brings `__all__`'s names when the module
  has one, else its public ones.
- **Statements** (`PySyntax`, on CodeModel's `LogicalLines`): logical lines (a line break inside brackets or after a
  `\` continues the line) and blocks by indentation; a bracket left open while typing closes at the next line that
  starts a statement at or left of it, so one missing `)` doesn't swallow the file.
- **Scopes**: Python's rules: a function's names are its own when bound anywhere in it, `global` and `nonlocal` send
  them out, class bodies are not enclosing scopes for their methods, comprehensions and lambdas have their own scope,
  then the module's names, star imports and `builtins` (the universe). A name bound several times answers every binding
  in that scope, as Pyright lists a symbol's declarations.
- **Classes** (`PyTypes`): bases with the C3 method resolution order, `self.x = …` in methods as attributes,
  `@property`, `@staticmethod`, `@classmethod`, dataclass fields (and their keyword arguments), `super()` and `type[A]`
  (a class used as a value).
- **Types**: annotations (`list[int]`, `Optional`, `Union`, `X | None`, string annotations, `typing` aliases, generic
  classes and `TypeVar`s), return annotations, the inferred types of literals, constructors, `with … as`, `for` over a
  typed iterable, unpacking, and the common builtins (`enumerate`, `zip`, `sorted`, `next`, `min`, `max`, `list`,
  `dict` and `str` methods). A value whose type isn't known gives candidates by the attribute's name.
- **Places** (`place(of:)`): a path relative to the root, `stdlib:<path>` in the standard library, `site:<path>` in the
  virtual environment, `stub:<module>.pyi` for the generated stubs; a module at line 1.

## Platforms

<!-- platforms: macos ios=partial linux windows=partial -->

- **macOS**: everything, with the standard library of Xcode's Python 3.9 (`CODE_PYTHON_STDLIB` names another), else a
  Python.framework or Homebrew's.
- **Linux**: everything, with `/usr/lib/python3.x`.
- **Windows**: builds; the standard library only through `CODE_PYTHON_STDLIB`.
- **iOS (iPadOS)**: builds; the project's own files and the generated stubs.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodePythonModel", package: "Code"),
```

CodePythonModel re-exports CodeModel. The target builds in Swift 5 language mode; the model isn't thread-safe. Give it
its own serial queue.

```swift
import CodePythonModel

let model = PyModel(root: "/path/to/project")
let file = "/path/to/project/src/app/main.py"
let answer = model.answer(path: file, line: 41, character: 12)  // from 0, UTF-16
for site in answer.sites {
  if let place = model.place(of: site) { print(place.path, place.line) }
}
model.project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 41, character: 12, limit: 40)
print(list.context, list.items.map(\.label))
```

## Main API

`PyModel` is a `LanguageModel` (CodeModel), so it is asked as the other models are.

### Loading a project

`PyModel(root:)` reads the project's Python files under a folder, leaving out `node_modules`, `__pycache__`, `build`,
`dist`, `.tox`, `.git` and virtual environments. `project` is CodeModel's `Project` (`update(path:text:)`, `units`,
`projectUnits`, `loadedBytes`). The standard library's and the environment's modules are parsed when an import reaches
them.

### Definitions and references

- `answer(path:line:character:)`, `location(of:)`, `place(of:)`.
- `references(of:)`: where an answer's definitions are used, a line each, in the project: under its name, the names
  it's imported as (`from m import a as b`, `import posixpath as path`), and through other files' imports of an import
  that wasn't found.

### Completion

`complete(path:line:character:limit:)` returns a `ModelCompletionList`: after `.`, a module's names (with its star
imports') or a type's members along its MRO; after `import` and `from`, module names (a package's submodules after a
dot); after `from m import`, m's names; nothing in strings, comments or after `def`, `class`, `as`, `global` and
`nonlocal`; elsewhere the scope's names, enclosing functions', the module's, star imports', builtins and keywords.
`_private` names rank lower until `_` is typed, dunders lower still.

### Symbol details

`details(of:)` and `details(path:line:character:)` return `SymbolDetails`: the header on one line (`async def f(a:
int) -> str`, `class A(B)`, `x: int` from the annotation or the inferred type), the docstring's first paragraph (a
class without one, its `__init__`'s), its parents out to the dotted module name, and a value's type.

`ModelLanguage.python`: the extensions, the manifests (`pyproject.toml`, `setup.cfg`, `setup.py`) and how to make the
model, for CodeKit and `code-model`.

### Stubs

The modules Python has no source for (builtins, `sys`, `math`, `_io`, the other C extension modules the standard
library imports) come from `PyStubs.swift`: `.pyi` text introspected from Python 3.9 by
`../Demos/CodeModelBench/py/tools/gen_stubs.py`, with return types for common methods. The model writes them to
`$TMPDIR/code-python-stubs-39/` so an editor can open them; the same text is what the reference reads.

### The code-model tool

```bash
swift run code-model query --root ~/Projects/app --language python --queries reference.json --out answers.json
swift run code-model complete --root ~/Projects/app --language python --at src/app/main.py:41:12
```

## Numbers

Against `pyref.py` (Python 3.9's `ast` and `symtable`, names and certain attributes), from
`../Demos/CodeModelBench/py/README.md`. Held out, 300 identifiers each of hub-service-py, moq-py and canvas-trading:
100% right, all exact, none wrong or unknown; references 99.7 to 100% recall, 97.3 to 99.7% precision (the extras are
uses the reference can't place: keyword arguments, attributes of values). Every identifier of three tuning projects
(33,000) and of the 3.9 standard library (338,376): 100.0%. Attributes of values, which the reference leaves out,
checked by hand on 60 held-out ones: 41 exact and right, 7 candidates, 12 unknown, none wrong. Release build: the first
answer in 4 to 17 ms, then a median of 0.001 ms and a p95 under 0.05 ms per definition; 17 to 33 MB peak. Completion,
the author's word deleted or its first two characters left: listed 97.5 to 100%, first 48 to 55%, in the top five 64
to 75%, a median of 0.4 to 0.6 ms.

## Testing

```bash
swift test --filter CodePythonModelTests
```

The tests write small projects to a temporary folder with `@@` before the words they ask about.

## Related

- [CodeSwiftModel](CodeSwiftModel.md), [CodeGoModel](CodeGoModel.md), [CodeTypeScriptModel](CodeTypeScriptModel.md)
  and [CodeClangModel](CodeClangModel.md): the other models, and the [CodeModel core](CodeSwiftModel.md#codemodel-the-core)
  all are built on.
- [CodeScan](CodeScan.md): the tokens the model reads (f-strings with their code parts and format specs), and the tier
  before it.
- [CodeKit](CodeKit.md): the definition tiers that ask the model.
- [CodeLSP](CodeLSP.md): Pyright, the tier after it.
