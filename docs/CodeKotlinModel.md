# CodeKotlinModel

## Purpose

CodeKotlinModel is a model of a Kotlin project built from its source text, on
[CodeModel](CodeSwiftModel.md#codemodel-the-core), [CodeScan](CodeScan.md)'s tokens and
[CodeJavaModel](CodeJavaModel.md)'s JVM layout, without running kotlinc, Gradle or a language server. It answers where
a name is defined (exact, a few candidates, or unknown), what can be completed at a position, where a definition is
referenced and what a symbol is, in milliseconds. It reads `.kt` files and, in a mixed project, `.java` files with
Java's parser into the same packages; the platform's and dependencies' Java sources as Java's model finds them; the
standard library from a generated stub.

It is not a compiler: it follows declared types and the types it can infer for sure, and gives candidates (or nothing)
otherwise, since an unknown answer is better than a wrong exact one. It never runs a build, downloads or installs
anything. It is Kotlin's model in the middle of Code's three tiers (CodeKit's `CodeTiers`): CodeScan guesses first,
the model answers for `.kt` files, and a language server (kotlin-language-server, when installed) is asked only when
the model isn't sure. Scripts (`.kts`, Gradle's build files) stay with the scanner.

Names resolve the way the Kotlin compiler resolves them:

- **Packages** (Java's `JavaLayout` and `JVMWorkspace`, with Kotlin's extensions): a file's package is its `package`
  line, whatever folder it's in, and a package is CodeModel's module. Builds, source roots, the platform and
  dependencies are found as [CodeJavaModel](CodeJavaModel.md) finds them (`settings.gradle(.kts)`'s `include` and
  `includeBuild`, `src/*/kotlin` and `src/*/java`, `local.properties`' Android SDK, a JDK's `src.zip`, `-sources.jar`s in
  `~/.gradle` and `~/.m2`, else Java's stub).
- **Imports**: explicit ones (`import a.b.C`, a top-level function or property, an extension), aliases
  (`import a.b.C as D`), star imports, the package's own declarations, then the default imports (`kotlin.*`,
  `kotlin.annotation`, `collections`, `comparisons`, `io`, `ranges`, `sequences`, `text`, `kotlin.jvm`, `java.lang.*`),
  in the compiler's order.
- **Scopes** (`KotlinBody`): locals (a `val` isn't seen in its own initializer), parameters, destructuring, `for`
  and `catch` variables, lambdas' parameters and their implicit `it`, `when (val x = …)`. Then the implicit receivers,
  innermost first: a lambda's receiver (`apply`, `with`, `buildString`, any `T.() -> R` parameter), `this` smart cast,
  the enclosing classes and their companions; each with its members, then the extensions it can see. Then top-level
  declarations.
- **Declarations** (`KotlinSyntax`): classes, interfaces, `object`s and companions, data, sealed, enum, value and
  annotation classes, primary-constructor properties, secondary constructors, top-level functions and properties,
  type aliases, local functions and classes. An extension (`fun A.f()`, `val A.p`) is CodeModel's `extensionDecl`, so
  the core's index of extensions by receiver name is Kotlin's too. Backtick names (`` `a test` ``) are one token
  (CodeScan's `backtickIdentifiers`).
- **Types** (`KotlinTypes`, `KotlinExpressions`): members through supertypes, generics substituted (variance read as
  the declared type), type parameters as their bounds; Java's classes as Kotlin sees them (`java.lang.String` is
  `kotlin.String`, `java.util.List` is `MutableList`, getters as properties, `length()` and `size()` as `length` and
  `size`, a Java interface's `toString()` as `Any`'s). Expressions: literals (a literal too big for an `Int` is a
  `Long`), `this`, calls, `?.` and `!!`, the elvis operator, `as` and `as?`, `is` and `!is`, `if` and `when` as
  values, operators through their functions (`plus`, `rangeTo`, `get`, `invoke`), `T::class`, function types as
  `FunctionN`, `by lazy` and other delegates through `getValue`, a data class's `copy`. Smart casts: `if (x is T)` in its
  branch (not the `else`), `if (x !is T) return` after it, `when (x) { is T -> … }`, `x is T && …`.
- **Calls**: a member wins over an extension; overloads are chosen by argument count and names (a trailing lambda goes
  to the last parameter), then by the argument types that are known, the most specific (when the arguments that make it
  fit are known), a literal's own type, then those that need no defaults; none that takes the arguments gives
  candidates. Generic functions' type parameters come from explicit type arguments, then the arguments, then lambdas'
  results; a lambda's parameters get the types of the function type it's passed to.
- **Places** (`place(of:)`): as the bench's compiler reference places them: a path relative to the root,
  `kotlin:<qualified name>` for the standard library, `jdk:` for the JDK and Android, `lib:` for other libraries (a
  function `Owner.name(<n>)`, an extension's owner its package and receiver's class, `kotlin.collections.Iterable.map(1)`,
  a constructor `<init>(<n>)`), `package:<name>`.

**Unknown on purpose**: a Java class's member found only as a Kotlin built-in's (`toString()` on a JDK class, `size` on
a JDK collection the stub doesn't declare it on), a value whose type comes from a library with no sources on disk
(Compose's `remember { … }`), an extension whose receiver can't be told. The by-name candidates for an unknown receiver
leave out other files' `private` members.

**The standard library**: `KotlinStd`, generated by `../Demos/CodeModelBench/kt/tools/stubgen.sh` from kotlin-stdlib
2.4.21's binary declarations (signatures only, no bodies or documentation; one file per package, `kotlin`,
`collections`, `text`, `io`, `ranges`, `sequences`, `jvm`, `math`, `time`, `coroutines` and the rest, plus
`Function0`…`Function22`), written to `$TMPDIR/code-kotlin-std/` when a file is opened. It's marked as generated at its
top. No standard library sources jar is on this Mac to read instead; kotlin-stdlib's `-sources.jar` is laid out by
source set (`commonMain`, `jvmMain`) with `expect`/`actual` declarations and has no built-ins (`Int`, `String`), so
reading it would need the stub's built-ins as well.

**Mixed projects**: `.java` files are parsed by Java's syntax (`KotlinSyntax.syntax(forPath:)`, CodeModel's hook) into
the same `Project`, so Kotlin sees Java's classes; a `JavaModel` on that project answers questions in `.java` files and
sees Kotlin's classes. CodeKit's tiers still send `.java` files to `ModelLanguage.java`'s own model, which doesn't read
`.kt` files.

## Platforms

<!-- platforms: macos ios=partial linux windows=partial -->

- **macOS**: everything, with a JDK's `src.zip` or the Android SDK's sources when on disk, else Java's stub.
- **Linux**: everything; JDKs in `/usr/lib/jvm`.
- **Windows**: builds; the platform from `JAVA_HOME` or `CODE_JAVA_SDK`.
- **iOS (iPadOS)**: builds; the project's own files and the stubs.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeKotlinModel", package: "Code"),
```

CodeKotlinModel re-exports CodeModel. The target builds in Swift 5 language mode; the model isn't thread-safe. Give it
its own serial queue.

```swift
import CodeKotlinModel

let model = KotlinModel(root: "/path/to/project")
let file = "/path/to/project/app/src/main/kotlin/com/example/Main.kt"
let answer = model.answer(path: file, line: 41, character: 12)  // from 0, UTF-16
for site in answer.sites {
  if let place = model.place(of: site) { print(place.path, place.line) }
}
model.project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 41, character: 12, limit: 40)
print(list.context, list.items.map(\.label))
```

## Main API

`KotlinModel` is a `LanguageModel` (CodeModel), so it is asked as the other models are.

### Loading a project

`KotlinModel(root:findsPlatform:)` reads the build's settings and the project's `.kt` and `.java` files;
`findsPlatform: false` skips looking for a JDK or Android SDK and reads Java's stub (the tests do).
`KotlinModel(project:)` takes a `Project` whose layout is a `JavaLayout`. `project` is CodeModel's `Project`.

### Definitions and references

- `answer(path:line:character:)`, `location(of:)` (a stub's or archive's file is written out first), `place(of:)`.
- `references(of:)`: where an answer's definitions are used, a line each, in the project (a Java method shown as a
  Kotlin property is found by both names).

### Completion

`complete(path:line:character:limit:)` returns a `ModelCompletionList`: after `.`, a value's members and the extensions
it can see, a class's companion members, nested classes and enum entries, a package's declarations and subpackages;
after `::`, members (and `class`); after `import`, the top-level packages; after `:`, `is` and `as`, types; after
`f(` or a `,` in its arguments, `f`'s parameter names (`name = `, only them before an `=`); nothing in strings,
comments or where a new name is declared; elsewhere locals, the implicit receivers' members and extensions, the
package's, imported and default declarations, types and keywords.

### Symbol details

`details(of:)` returns `SymbolDetails`: the declaration on one line (`inline fun <T> Iterable<T>.filter(predicate: (T)
-> Boolean): List<T>`, `data class Point`, `val name: String`), the KDoc above it, its parents (the classes
out to the package) and a value's type. Java's declarations get Java's details.

`ModelLanguage.kotlin`: the extension (`kt`), the manifests (`build.gradle`, `build.gradle.kts`, `settings.gradle`,
`settings.gradle.kts`, `pom.xml`, `local.properties`) and how to make the model, for CodeKit and `code-model`.

### The code-model tool

```bash
swift run code-model query --root ~/Projects/app --language kotlin --queries reference.json --out answers.json
swift run code-model complete --root ~/Projects/app --language kotlin --at app/src/main/kotlin/a/Main.kt:41:12
```

## Numbers

Against the Kotlin compiler's own resolution (kotlinc 2.4.21's K1 front end, `kt/tools/KotlinRef.kt`), from
`../Demos/CodeModelBench/kt/README.md`, with Java's and Kotlin's stubs (no JDK or Android sources on disk). Held out,
3,000 identifiers of vijo-android (an Android app in Compose): 95.9% right, 0.5% wrong (0.2% exact), 3.6% unknown.
Tuned on channel-kotlin, every identifier (11,657): 97.4% right, 0.2% wrong; its 7,809 project definitions 98.4%
exact. Every identifier of hub-service-kotlin, swiftui-android and moq-kt (looked at while tuning): 95.3%, 97.7% and
98.9% right, at most 0.3% wrong. What's unknown is mostly the JDK beyond Java's stub, Compose and AndroidX values and
packages the stubs lack. References: 96.6 to 99.0% recall, 94.9 to 99.4% precision. Release build: the first answer in
14 to 410 ms, then a median of 0.001 to 0.012 ms and a p95 of 0.02 to 0.15 ms per definition (channel-kotlin's 11,657
in 0.5 s); references 0.1 to 19 ms each on average (a name used thousands of times, Compose's `Text`, 0.4 s). Completion,
the author's word deleted or its first two characters left: listed 89.8% held out (92.3% tuned, 93.0% on the others),
first 46 to 50%, in the top five 66 to 70%, with two characters typed first 65 to 82%, a median of 0.6 to 1.1 ms.
3,000 random identifiers of each corpus, `.kts` files and keywords included: no crash or hang, at most 44 MB.

## Testing

```bash
swift test --filter CodeKotlinModelTests
```

The tests write small projects to a temporary folder with `@@` before the words they ask about (a mixed Kotlin and
Java one too), and read the stubs.

## Related

- [CodeJavaModel](CodeJavaModel.md): the layout, the platform and Java's half of a mixed project.
- [CodeSwiftModel](CodeSwiftModel.md), [CodeGoModel](CodeGoModel.md), [CodeTypeScriptModel](CodeTypeScriptModel.md),
  [CodeClangModel](CodeClangModel.md), [CodePythonModel](CodePythonModel.md) and [CodeRustModel](CodeRustModel.md): the
  other models, and the [CodeModel core](CodeSwiftModel.md#codemodel-the-core) all are built on.
- [CodeScan](CodeScan.md): the tokens the model reads, and the tier before it.
- [CodeKit](CodeKit.md): the definition tiers that ask the model.
- [CodeLSP](CodeLSP.md): kotlin-language-server, the tier after it.
