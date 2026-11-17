# CodeJavaModel

## Purpose

CodeJavaModel is a model of a Java project built from its source text, on
[CodeModel](CodeSwiftModel.md#codemodel-the-core) and [CodeScan](CodeScan.md)'s tokens, without running javac, Gradle,
Maven or a language server. It answers where a name is defined (exact, a few candidates, or unknown), what can be
completed at a position (members after `.` and `::`, packages in imports, types where only a type goes, else what's in
scope), where a definition is referenced and what a symbol is (its declaration on one line, its Javadoc, the classes and
package it's in, a value's type), in milliseconds. It reads `.java` files: the project's, the build's other modules',
the platform's sources and dependencies' `-sources.jar`s, each package only when a name first reaches it.

It is not a compiler: it follows declared types and the types it can infer for sure, and gives candidates (or nothing)
otherwise, since an unknown answer is better than a wrong exact one. It never runs a build, downloads or installs
anything. It is Java's model in the middle of Code's three tiers (CodeKit's `CodeTiers`): CodeScan guesses first, the
model answers for Java files, and a language server (jdtls, when installed) is asked only when the model isn't sure.

Names resolve the way javac resolves them:

- **Packages** (`JavaLayout`, `JVMWorkspace`): a file's package is its `package` line, and a package is CodeModel's
  module. Every `.java` file under the root is the project's (`build`, `out`, `target`, `.gradle` and the other tools'
  folders left out); a package the project doesn't have is loaded when a name first needs it, from the build's other
  source roots, then the platform, then dependencies.
- **Builds**: the nearest `settings.gradle(.kts)` up to six folders above the root (`include(…)`, `includeBuild(…)`
  followed into other builds), else the outermost `pom.xml` with `<modules>`; each module's `src/*/java` and
  `src/*/kotlin`, Gradle's `srcDir`/`srcDirs` and Maven's `<sourceDirectory>`. A module outside the root is read as a
  source root of its own (`../core/src/main/java/…`).
- **The platform**: `CODE_JAVA_SDK` (a zip, a jar or a folder of sources), a JDK's `lib/src.zip` (`JAVA_HOME`,
  `/Library/Java/JavaVirtualMachines`, `~/Library/Java/JavaVirtualMachines`, `/usr/lib/jvm`) or the Android SDK's
  `platforms/android-<n>/android-stubs-src.jar` (from `local.properties`' `sdk.dir`, `ANDROID_HOME`,
  `ANDROID_SDK_ROOT`, `~/Library/Android/sdk`, …; `compileSdk`'s platform when it's installed, else the newest). An
  Android build (an Android Gradle plugin, an `android {` block, an `AndroidManifest.xml`) looks at the Android SDK
  first. Archives are read in place with CodeModel's `ZipArchive`; a file opened from one is written to
  `$TMPDIR/code-jvm-sources/`. With none on disk, `JavaStd` stands in: a hand-written stub of what code calls most in
  `java.lang`, `java.util` (with `function`, `stream`, `concurrent`), `java.io`, `java.nio`, `java.net` and `java.time`,
  written to `$TMPDIR/code-java-std/`.
- **Dependencies**: every `-sources.jar` in Gradle's cache (`GRADLE_USER_HOME` or `~/.gradle`), `~/.m2` and
  `CODE_JAVA_SOURCES`, for a package the platform doesn't have. A dependency with no sources on disk is left out.
- **Scopes** (`JavaModel`, `JavaBody`): locals (declarations, `var`, `for`, catch parameters, lambda parameters,
  `instanceof` and record patterns), unless a class declared nearer has a field of that name; fields and methods of the
  enclosing classes, inherited ones too, innermost class first; static imports. Types: type parameters, local
  classes, member types of the enclosing classes and their supertypes, the file's own, single-type imports, the
  package, on-demand imports, static on-demand imports' member types, `java.lang`. Then packages.
- **Types** (`JavaTypes`, `JavaExpressions`): classes, interfaces, enums, records (their components' accessors are the
  components), annotations, sealed types; members through `extends` and `implements` (the implicit `Object`,
  `Enum<E>` and `Record` too, an anonymous class's and an enum constant's body), generics substituted through
  supertypes, type parameters read as their bounds, wildcards as theirs. Expressions: literals, `this`, `super`,
  `new` (a diamond's arguments from the constructor's), casts, operators with numeric promotion and string `+`,
  conditionals, calls, array access, `.class`. A call's overload is chosen by its argument count, then by the argument
  types that are known (widening, boxing, varargs, the most specific), else given as candidates; no overload that
  takes that many arguments gives candidates. A generic method's type parameters come from its arguments (a lambda's
  result too). A lambda's parameters get the types of its functional interface's method: the interface of the
  parameter it's passed to, the variable it initializes, a cast or a `return`; a method reference is narrowed by that
  method's parameter count.
- **Places** (`place(of:)`): a path relative to the root (`../x` outside it), `jdk:<qualified name>` for the platform
  and `lib:<qualified name>` for a dependency (a method `java.util.List.of(2)`, a constructor `…String.<init>(1)`, a
  field `…Integer.MAX_VALUE`, line 1), `package:<name>` (line 0) for a package.

`JVMWorkspace`, `JVMSourceSet` and `JavaLayout` are the JVM's, not only Java's: [CodeKotlinModel](CodeKotlinModel.md)
takes them with its own extensions, syntax and standard library (`JavaLayout(root:findsPlatform:extensions:syntax:extraSets:)`,
a set held in memory written to its own `$TMPDIR` folder), as `package` declarations of this library, and asks a
`JavaModel` on the same `Project` about Java's declarations. [CodeScalaModel](CodeScalaModel.md) does the same and also
passes `packageOfFile` (Scala's chained `package` clauses). With `scala` among the extensions, `JVMWorkspace` also reads
sbt's and Mill's builds (`build.sbt` projects, `build.sc`/`build.mill` modules), `src/<set>/scala*` roots and Mill's
`src`, and Coursier's and Ivy's caches; a Java or Kotlin project never looks at them.

## Platforms

<!-- platforms: macos ios=partial linux windows=partial -->

- **macOS**: everything, with a JDK's `src.zip` or the Android SDK's sources found on disk, else the stub.
- **Linux**: everything; JDKs in `/usr/lib/jvm`.
- **Windows**: builds; the platform from `JAVA_HOME` or `CODE_JAVA_SDK`.
- **iOS (iPadOS)**: builds; the project's own files and the stub.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeJavaModel", package: "Code"),
```

CodeJavaModel re-exports CodeModel. The target builds in Swift 5 language mode; the model isn't thread-safe. Give it
its own serial queue.

```swift
import CodeJavaModel

let model = JavaModel(root: "/path/to/project")
let file = "/path/to/project/app/src/main/java/com/example/Main.java"
let answer = model.answer(path: file, line: 41, character: 12)  // from 0, UTF-16
for site in answer.sites {
  if let place = model.place(of: site) { print(place.path, place.line) }
}
model.project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 41, character: 12, limit: 40)
print(list.context, list.items.map(\.label))
```

## Main API

`JavaModel` is a `LanguageModel` (CodeModel), so it is asked as the other models are.

### Loading a project

`JavaModel(root:findsPlatform:)` reads the build's settings and the project's files; `findsPlatform: false` skips
looking for a JDK or Android SDK and reads the stub (the tests do). `project` is CodeModel's `Project`
(`update(path:text:)`, `units`, `projectUnits`, `loadedBytes`).

### Definitions and references

- `answer(path:line:character:)`, `location(of:)` (a platform or dependency file is written out of its archive first),
  `place(of:)`.
- `references(of:)`: where an answer's definitions are used, a line each, in the project.

### Completion

`complete(path:line:character:limit:)` returns a `ModelCompletionList`: after `.`, a value's fields and methods
(inherited ones too), a type's static members and member types (and `class`, `this`), a package's types and
subpackages; after `::`, methods (and `new`); after `import`, the top-level packages; after `new`, `extends`,
`implements`, `throws`, `instanceof` and in type arguments, types; nothing in strings, comments or where a new name is
declared; elsewhere locals, the enclosing classes' members, static imports, types and keywords.

### Symbol details

`details(of:)` and `details(path:line:character:)` return `SymbolDetails`: the declaration on one line without its
annotations (`public static <T> List<T> of(T... elements)`, `public final class String implements …`, `String name`),
the Javadoc's first paragraph, its parents (the classes out to the package) and a value's type.

`ModelLanguage.java`: the extension, the manifests (`build.gradle`, `build.gradle.kts`, `settings.gradle`,
`settings.gradle.kts`, `pom.xml`, `local.properties`) and how to make the model, for CodeKit and `code-model`.

### The code-model tool

```bash
swift run code-model query --root ~/Projects/app --language java --queries reference.json --out answers.json
swift run code-model complete --root ~/Projects/app --language java --at src/main/java/a/Main.java:41:12
```

## Numbers

Against javac 21's own resolution (`Trees.getElement` on every identifier, `java/tools/JavaRef.java`), from
`../Demos/CodeModelBench/java/README.md`, with Android 36's `android-stubs-src.jar` as the platform. Held out, 300
identifiers each: hub-service-java 91.7% right, jobok-android 96.3%, ed25519-jruby 99.7%, none wrong; what's unknown is
in jars with no sources on disk (dsl-json, slf4j, Android's support libraries) and their packages. Tuned on
channel-java: every identifier (12,951) 96.4% right, 0.1% wrong, all 8,752 in the project right. With the stub
instead of the SDK: channel-java 93.7%, held out 89.0%, 76.7% (an Android app) and 95.3%, 0.5 to 2% wrong (the stub
declares some overrides only on the interface). References: 99.4 to 99.8% recall, 99.3 to 100% precision. Release
build: the first answer in 6 to 170 ms, then a median of 0.002 to 0.014 ms and a p95 of 0.03 to 2.6 ms per definition
(channel-java's 12,951 in 477 ms); references 0.4 to 2.6 ms each; 40 to 165 MB peak. Completion, the author's word
deleted or its first two characters left: listed 89.0 to 99.8% held out (97.0% tuned), first 37 to 50%, in the top five
62 to 72%, a median of 0.4 to 0.6 ms. The Android SDK's 4,178 stub sources and the four corpora, 3,000 random
identifiers each: no crash or hang, at most 204 MB.

## Testing

```bash
swift test --filter CodeJavaModelTests
```

The tests write small projects to a temporary folder with `@@` before the words they ask about, and read the stub as
the platform.

## Related

- [CodeSwiftModel](CodeSwiftModel.md), [CodeGoModel](CodeGoModel.md), [CodeTypeScriptModel](CodeTypeScriptModel.md),
  [CodeClangModel](CodeClangModel.md), [CodePythonModel](CodePythonModel.md), [CodeRustModel](CodeRustModel.md) and
  [CodeKotlinModel](CodeKotlinModel.md): the other models, and the [CodeModel core](CodeSwiftModel.md#codemodel-the-core) all are built on.
- [CodeScan](CodeScan.md): the tokens the model reads, and the tier before it.
- [CodeKit](CodeKit.md): the definition tiers that ask the model.
- [CodeLSP](CodeLSP.md): jdtls, the tier after it.
