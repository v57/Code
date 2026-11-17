# CodeScalaModel

## Purpose

CodeScalaModel is a model of a Scala 2 or Scala 3 project built from its source text, on
[CodeModel](CodeSwiftModel.md#codemodel-the-core) and [CodeScan](CodeScan.md)'s tokens. It doesn't run scalac, sbt,
Mill, Bloop or a language server. In milliseconds it answers:

- where a name is defined: exact, a few candidates, or unknown;
- what can be completed at a position;
- where a definition is referenced;
- what a symbol is.

It reads the `.scala` and `.sc` files under a folder, the project's `.java` files with them, the source roots of the
build's other modules, the platform's and dependencies' sources when they're on disk, and Scala's standard library from
a hand-written stub.

It is not a compiler. It follows the types it can be sure of. Otherwise it gives candidates or nothing, since an unknown
answer is better than a wrong exact one. It never runs a build, and it never downloads or installs anything.

It is Scala's model in the middle of Code's three tiers (CodeKit's `CodeTiers`):

1. CodeScan guesses first.
2. The model answers for `.scala` and `.sc` files.
3. A language server would be asked only when the model isn't sure, but CodeLSP's catalog has none for Scala yet
   (Metals would be the one), so CodeScan's own server stands in.

Names resolve the way Scala's compiler binds them:

- **Files** ([CodeJavaModel](CodeJavaModel.md)'s `JavaLayout` and `JVMWorkspace`, shared with Java and Kotlin).
  - A file's package is its chained `package` clauses (`package a` then `package b` is `a.b`), read by Scala's own
    reader (`JavaLayout`'s `packageOfFile`). Files are grouped by package, not by folder.
  - The build's other modules, when the root is one of them: sbt's `build.sbt` projects (`project.in(file("a"))`,
    `(project in file("a"))`, `lazy val a = project`, a cross project's `shared`, `jvm`, `js` and `native` folders) and
    Mill's `build.sc`/`build.mill` modules (`object a extends ScalaModule`, nested ones as `a/b`), besides Gradle's and
    Maven's. Their source roots are `src/<set>/scala`, the cross-built `scala-2`, `scala-3` and `scala-2.13` folders,
    `src/<set>/java`, and Mill's `src` and `test/src`. scala-cli's projects are the files under the root.
    `target`, `out`, `.bsp`, `.metals`, `.bloop` and `.scala-build` are left out.
  - The platform is a JDK's `src.zip` when one is on disk, else Java's stub (`JavaStd`). Dependencies' `-sources.jar`s
    are read in place from Coursier's cache (`COURSIER_CACHE`, `~/Library/Caches/Coursier/v1`, `~/.cache/coursier/v1`),
    Ivy's (`~/.ivy2`), Gradle's and `~/.m2`. Nothing is fetched.
- **Declarations** (`ScalaSyntax`), braces and significant indentation alike, with `end` markers:
  - `class`, `case class`, `trait`, `object`, `case object`, `enum` and its `case`s, package objects;
  - `def` with several parameter lists, `using` and `implicit` lists, defaults and repeated parameters;
  - `val`, `var`, `lazy val`, `given` (named, anonymous, with a body), `type` and opaque types;
  - constructor parameters (a case class's and `val`/`var` ones are members);
  - Scala 3's `extension (x: T)` groups and Scala 2's `implicit class`es;
  - imports anywhere: selectors, renames (`a => b`), hiding (`a => _`), wildcards (`_` and `*`), `given` imports,
    `export`.
- **Locals**: `val`/`var`/`def`/`given` in blocks, lambdas' parameters (`x =>`, `(a, b) =>`, `{ case … }`, `_`), a
  `case` pattern's bindings (`Foo(a, b)`, `x @ …`, `e: T`), `val (a, b) =`, a `for`'s generators and its `x = …`
  definitions.
- **Simple names**, innermost first:
  1. locals and parameters;
  2. each enclosing template, with its members (its own, then its parents' from the rightmost) and the imports inside
     it;
  3. the file's top-level declarations and its imports (explicit before wildcards);
  4. the packages of its package clauses, innermost first, and their package objects;
  5. `scala.Predef`, `scala`, `java.lang`, then `scala`'s subpackages (`collection.mutable.ListBuffer` after
     `import scala.collection`).
- **A class and its companion** share a name: a type position means the class; `T.x` the object; `T(…)` the companion's
  `apply` by arity, or a case class's own constructor when its first list fits; `T[A]` alone the object; `case T(…)`
  `unapply` the same way; `end T` the class it closes.
- **Members** go through the receiver's static type and its parents, generics substituted, then the extension methods
  (Scala 3 extensions, Scala 2 implicit classes, the stub's `StringOps`, `RichInt`, `ArrowAssoc` and the others) seen
  there. `super.x` answers the parents' member.
- **Types** (`ScalaTypes`).
  - Declared types, with aliases followed and tuples as `TupleN`; `T | U`, function types (`T & U` and `T with U` as
    their first part).
  - Initializers, a function's `=` body, a block's last expression; `if`, `match` and `try` results are unknown.
  - Chains of calls with their overload chosen by arity, generics bound from arguments and from the receiver, an
    extension's own generics from what it extends; `new`, literals, `this`, infix operators, `apply`.
  - Lambdas' parameters from the function type the call expects (`xs.map(x => x.)`, `_.name`), for-comprehensions
    through `map`/`flatMap`/`foreach`, a pattern's bindings from the scrutinee or the extractor (`Status.Done(n)`).
  - Named arguments (`f(name = …)`, `copy(name = …)`).
  - A Java declaration's type is read from Java's model (`int` as `Int`, `java.util.List` as is).
- **Interpolated strings**: `$name` in `s"…"`, `f"…"`, `raw"…"` and any interpolator answers the name; `${…}` is code.
- **Places** (`place(of:)`), as the bench's reference names them: a path relative to the root and a line. The stub's,
  the platform's and anything outside the root are `sdk:<file>`, a package `package:<name>`.

**Unknown on purpose**: what only implicit or given resolution could tell (an implicit conversion's member, a
`summon[T]`'s or `using` argument's type when it isn't declared, a context function), macros and inline expansion,
structural and match types, type lambdas, a value whose type comes from a library with no sources on disk, and a
member on an unknown receiver.

**Scala's standard library**: `ScalaStd`, a hand-written stub (marked as Code's stub, not Scala's sources, at the top
of each file): 20 files and about 250 classes, traits and objects of `scala`, `scala.collection` (immutable and
mutable), `scala.util` (`Try`, `Either`, `Using`, `Random`, `Regex`), `scala.concurrent` (`Future`, `duration`),
`scala.math`, `scala.io.Source`, `scala.jdk.CollectionConverters`, `Predef` with its implicit classes, `Tuple1`…`Tuple22`
and `Function0`…`Function22`. Declarations only, with types, as the compiler sees them from outside. It is generated by
`../Demos/CodeModelBench/scala/tools/gen_std.py` from its own source text, and written to
`$TMPDIR/code-scala-std/` when a file of it is opened. `java.*` comes from Java's platform: a JDK's sources, else
`JavaStd`. A scala-library sources jar on disk would be better, but none is on this Mac.

**Mixed projects**: `.java` files are parsed by Java's syntax (`ScalaSyntax.syntax(forPath:)`, CodeModel's hook) into
the same `Project`, so Scala sees Java's classes; a `JavaModel` on that project answers questions in `.java` files.
CodeKit's tiers still send `.java` files to `ModelLanguage.java`'s own model, which doesn't read `.scala` files.

**The lexer** (CodeScan's Scala rules): operators with `:` in them (`+:`, `:+`, `<:`, `#::`) as one token and `.`
never part of one (`import a.*`); a name ending in `_` takes the operator after it (`unary_-`); backquoted names; nested
`/* */` comments; `${…}` interpolation.

## Platforms

<!-- platforms: macos ios=partial linux windows=partial -->

- **macOS**: everything, with a JDK's `src.zip` when on disk, else Java's stub.
- **Linux**: everything; JDKs in `/usr/lib/jvm`.
- **Windows**: builds; the platform from `JAVA_HOME` or `CODE_JAVA_SDK`.
- **iOS (iPadOS)**: builds; the project's own files and the stubs.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeScalaModel", package: "Code"),
```

CodeScalaModel re-exports CodeModel. The target builds in Swift 5 language mode, and the model isn't thread-safe: give
it its own serial queue.

```swift
import CodeScalaModel

let model = ScalaModel(root: "/path/to/project")
let file = "/path/to/project/core/src/main/scala/a/Main.scala"
let answer = model.answer(path: file, line: 41, character: 12)  // from 0, UTF-16
for site in answer.sites {
  if let place = model.place(of: site) { print(place.path, place.line) }
}
model.project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 41, character: 12, limit: 40)
print(list.context, list.items.map(\.label))
```

## Main API

`ScalaModel` is a `LanguageModel` (CodeModel), so it is asked as the other models are.

### Loading a project

`ScalaModel(root:findsPlatform:)` reads the build's files and the project's `.scala`, `.sc` and `.java` files;
`findsPlatform: false` skips looking for a JDK and reads Java's stub (the tests do). `ScalaModel(project:)` takes a
`Project` whose layout is a `JavaLayout`. `project` is CodeModel's `Project`.

### Definitions and references

- `answer(path:line:character:)`, `location(of:)` (the stub's or an archive's file is written out first), `place(of:)`.
- `references(of:)`: where an answer's definitions are used in the project, one line each: through import renames,
  `$name` in interpolated strings, and Java files that use a Scala declaration.

### Completion

`complete(path:line:character:limit:)` returns a `ModelCompletionList`:

- **After `.`**: a value's members and the extensions it can see; an object's members (an enum's companion also its
  cases); an enum's cases and its companion's members; a package's declarations, top-level extension methods and
  subpackages.
- **After `import`, and in an import's path or `{…}` selectors**: packages, a package's or object's members.
- **After `:`, `extends`, `with`, `new` and in `[…]`**: types.
- **After `f(` or a `,` in its arguments**: `f`'s parameter names (`name = `), a case class's for `copy(`.
- **After `$` in an interpolated string**: what's in scope.
- **After `def`, `val`, `var`, `class`, `trait`, `object`, `type`, `enum` and `given x:`**: nothing, since a new name
  goes there. Nothing in comments and other strings.
- **Elsewhere**: the locals in scope, the enclosing templates' members, the file's, imported, package and default
  declarations, and keywords.

### Symbol details

`details(of:)` returns `SymbolDetails`:

- the declaration on one line (`def second[A](xs: List[A]): A`, `case class Point(x: Int, y: Int)`,
  `val origin: Point`), an inferred type written in;
- the Scaladoc above it;
- its parents: the templates out to the package;
- a value's type, as Scala writes it (`(Int, String)`, `A => B`, `A | B`).

Java's declarations get Java's details.

### ModelLanguage.scala

`ModelLanguage.scala` holds, for CodeKit and `code-model`:

- the extensions: `scala`, `sc`;
- the manifests: `build.sbt`, `*.sbt`, `build.properties`, `build.sc`, `build.mill`, `.mill-version`, `project.scala`,
  and Gradle's and Maven's;
- how to make the model.

### The code-model tool

```bash
swift run code-model query --root ~/Projects/app --language scala --queries reference.json --out answers.json
swift run code-model complete --root ~/Projects/app --language scala --at core/src/main/scala/a/Main.scala:41:12
swift run code-model tokens --all --root ~/Projects/app --language scala   # CodeScan's names, for scala/tools/lexcheck.py
```

## Numbers

From `../Demos/CodeModelBench/scala` (2026-11-17, release build). No Scala toolchain, Metals, scalameta or Scala
source is on this Mac and nothing was downloaded, so **the corpora and the reference are the bench's own**: three
projects written for it (sbt with three modules and a Java file, sbt with a package object and cross-built folders,
Mill with a scala-cli script; Scala 2 and 3 syntax), and `scala/tools/scalaref.py`, a resolver written apart from the
model with its own lexer. It names only what Scala makes unambiguous from the source and leaves the rest out of the
score. A compiler's answers (scalac's SemanticDB, Metals) would be a better reference.

- **inventory** (tuned on, every identifier, 1,661 positions): of the 1,078 with a reference, 100% exactly right, none
  wrong; references 100% recall, 97.1% precision.
- **Held out**, scored once before looking:

  | Project | First run | After fixes | References recall / precision |
  |---|---|---|---|
  | ledger (938 with a reference) | 99.0% right, 9 wrong | 99.3%, 7 "wrong" | 99.2% / 97.1% |
  | planner (673 with a reference) | 99.4% right, 3 wrong, 1 unknown | 99.6%, 3 "wrong" | 99.3% / 95.7% |

  The ten left are the reference's: the last word of `package org.acme.ledger` is the package, where the reference
  names its package object, and `end Task` closes the class before it, where the reference names the companion object.
- **Hand checks**: 50 exact answers without a reference were checked by hand, and all were right.
- **Completion** (400 cases each, the word deleted or two characters left): listed 99.5 to 100%, first 55 to 62%, top
  five 80 to 84%, with two characters typed first 87 to 94%; a median of 0.4 to 0.9 ms.
- **Speed and memory**: the first answer in 27 to 60 ms, then a median of 0.004 ms per answer (p95 0.03 ms); a peak
  RSS of 26 to 32 MB with references.
- **Crash runs**: 3,000 random words of each corpus and of the stub, and 20,000 of 138 garbled copies of them: no
  crash or hang, at most 71 MB.

## Testing

```bash
swift test --filter CodeScalaModelTests
```

The tests write small projects to a temporary folder, with `@@` before the words they ask about, and read the stubs:
names, types, references, completion, details, and sbt and Mill layouts. CodeScanTests'
`scalaOperatorsBackquotesAndComments` covers the lexer.

## Related

- [CodeJavaModel](CodeJavaModel.md): the layout, the platform and Java's half of a mixed project.
- The other models: [CodeSwiftModel](CodeSwiftModel.md), [CodeGoModel](CodeGoModel.md),
  [CodeTypeScriptModel](CodeTypeScriptModel.md), [CodeClangModel](CodeClangModel.md),
  [CodePythonModel](CodePythonModel.md), [CodeRustModel](CodeRustModel.md), [CodeKotlinModel](CodeKotlinModel.md),
  [CodeCSharpModel](CodeCSharpModel.md), [CodeDartModel](CodeDartModel.md), [CodePHPModel](CodePHPModel.md) and
  [CodeRubyModel](CodeRubyModel.md). The [CodeModel core](CodeSwiftModel.md#codemodel-the-core) is what they're all
  built on.
- [CodeScan](CodeScan.md): the tokens the model reads, and the tier before it.
- [CodeKit](CodeKit.md): the definition tiers that ask the model.
- [CodeLSP](CodeLSP.md): the language servers, the tier after it (none for Scala yet).
