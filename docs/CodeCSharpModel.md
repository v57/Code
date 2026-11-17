# CodeCSharpModel

## Purpose

CodeCSharpModel is a model of a C# project built from its source text, on
[CodeModel](CodeSwiftModel.md#codemodel-the-core) and [CodeScan](CodeScan.md)'s tokens, without running the .NET SDK,
MSBuild, Roslyn or a language server. It answers where a name is defined (exact, a few candidates, or unknown), what
can be completed at a position, where a definition is referenced and what a symbol is, in milliseconds. It reads the
`.cs` files of every `.csproj` under a folder, and the .NET library from a generated stub.

It is not a compiler: it follows declared types and the types it can infer for sure, and gives candidates (or nothing)
otherwise, since an unknown answer is better than a wrong exact one. It never runs a build, restores NuGet packages,
downloads or installs anything. It is C#'s model in the middle of Code's three tiers (CodeKit's `CodeTiers`): CodeScan
guesses first, the model answers for `.cs` files, and a language server is asked only when the model isn't sure.

Names resolve the way Roslyn binds them:

- **Projects** (`CSharpLayout`): every `.cs` file under the root (bin, obj, node_modules, packages and hidden folders
  left out) belongs to the deepest folder with a `.csproj` above it, its `<Compile Include/Remove>` items followed;
  files under none form one loose project with implicit usings. A project is CodeModel's module, named as its
  `.csproj`, and sees the projects its `<ProjectReference>`s name, transitively, so a solution's projects link up
  without reading the `.sln` (a change to one, a `.csproj`, `Directory.Build.props` or `global.json` reloads the model).
  A project's properties come from its `Directory.Build.props` files, outermost first, then its own file, as a Debug
  build reads them (a condition naming Release isn't taken).
- **Namespaces and usings**: `namespace A.B { … }` and file-scoped `namespace A.B;`, whatever the folders. A name is
  looked up in locals and parameters, then each enclosing type (its type parameters, members, inherited ones too, and a
  primary constructor's parameters), innermost first; then each enclosing namespace from the innermost out, with that
  declaration's `using` directives (aliases, namespaces' types, `using static` members); last the file's usings, the
  project's `global using`s, the SDK's implicit usings (`ImplicitUsings`: `System`, `System.Collections.Generic`,
  `System.IO`, `System.Linq`, `System.Net.Http`, `System.Threading`, `System.Threading.Tasks`, and ASP.NET Core's for
  `Microsoft.NET.Sdk.Web`) and `<Using Include/Remove/Alias/Static>` items.
- **Declarations** (`CSharpSyntax`): classes, structs, records (`record`, `record struct`; positional parameters are
  properties), interfaces with default members, enums, delegates, nested types, partial types (every part is one type;
  a definition is its first part), primary constructors, methods, constructors, operators and conversions, properties,
  fields, constants, events, indexers, local functions, extension methods (`this T x`) and C# 14 extension blocks
  (`extension<T>(Receiver r) { … }`), top-level statements (one nameless function). `@name` is the word.
- **Conditional code**: `#if`, `#elif`, `#else` with the project's symbols, as the SDK defines them in Debug for its
  first target framework (`DEBUG`, `TRACE`, `NET`, `NET10_0`, `NET8_0_OR_GREATER`, `NETSTANDARD2_0`,
  `NETFRAMEWORK`, an OS from `net10.0-ios`) and `DefineConstants`; the branches not taken are the core's left-out
  ranges.
- **Scopes** (`CSharpBody`): parameters, locals (`var`, `using`, `const`, deconstructions), `for`, `foreach`, `using`
  and `fixed` headers, `catch` variables, lambdas' and anonymous methods' parameters, pattern variables (`is T x`,
  `case`, switch expression arms, property, positional and list patterns), `out var x`, and query range variables
  (`from`, `let`, `join`, `into`). A local can't hide an enclosing local, so the last one declared before a use and
  still in scope is the one meant.
- **Types** (`CSharpTypes`, `CSharpExpressions`): members through base classes and interfaces, generics substituted,
  type parameters as their constraints; the keyword types as their `System` structs. Expressions: literals, names,
  `this`/`base`, `new` (target-typed `new()` too, arrays, anonymous types' members), casts, `as`, `is`, `await`
  (`Task<T>`, `ValueTask<T>`, else `GetAwaiter().GetResult()`), operators on the keyword types and strings, `??`, `?:`,
  `switch` expressions, member access (`?.`, `!.` too), `Nullable<T>` and `T?`, indexers, tuples' element names, `var`
  from its initializer, `foreach` over arrays and `IEnumerable<T>`. Lambdas get their parameters'
  types from the delegate they're passed as (`Func`, `Action`, `Predicate`, `Expression<…>`, the project's delegates),
  so LINQ method chains are typed through `Enumerable`'s extension methods.
- **Calls**: overloads are chosen by argument count (optional parameters, `params`, named arguments), then by the
  argument types that are known, preferring the overloads every known argument fits without a user-defined conversion,
  then one whose parameters are exactly the arguments' types, then the better by conversion; an argument of unknown type
  where the overloads differ gives candidates. A number literal fits only numeric, `object` or interface parameters. A
  generic method's type parameters come from explicit type arguments, then the arguments. Extension methods (and
  extension blocks' members) come from the namespaces in scope when no instance member fits.
- **Places** (`place(of:)`): as the bench's Roslyn reference places them: a path relative to the root and a line,
  `net:<namespace>.<Type>` for the .NET library (a generic type with `` `n ``, a method `.Name(<n>)`, a constructor
  `..ctor(<n>)`, an indexer `.this[]`), `namespace:<name>` for a namespace.

**Unknown on purpose**: query syntax's results (`from … select …` is scoped, its range variables are found, but the
query's type is unknown, and so are members after it), `dynamic`, user-defined operators, collection expressions'
types, a delegate's `Invoke` (the stub has no members on delegates), tuple elements reached by name through a value
whose tuple type isn't written, and library types the stub lacks (anything from a NuGet package: no packages are read).

**The .NET library**: `CSharpStd`, generated by `../Demos/CodeModelBench/cs/tools/stubgen.sh` from the .NET 10 SDK's
reference assemblies (`Microsoft.NETCore.App.Ref` and `Microsoft.AspNetCore.App.Ref`, metadata only, in the local
`mcr.microsoft.com/dotnet/sdk` Docker image without network): signatures without bodies or documentation, 900 public
types in 47 namespaces (the ones the bench's projects use, `cs/tools/stub-types.txt`, and their bases), one file per
namespace, written to `$TMPDIR/code-csharp-std/` when a file is opened. It's marked as generated at its top. A namespace
of the stub is read when a name first needs it.

## Platforms

<!-- platforms: macos ios linux windows -->

- **macOS, Linux, Windows**: everything; the library is the built-in stub, so nothing has to be installed.
- **iOS (iPadOS)**: builds and answers; the project's own files and the stub.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeCSharpModel", package: "Code"),
```

CodeCSharpModel re-exports CodeModel. The target builds in Swift 5 language mode; the model isn't thread-safe. Give it
its own serial queue.

```swift
import CodeCSharpModel

let model = CSharpModel(root: "/path/to/solution")
let file = "/path/to/solution/src/App/Program.cs"
let answer = model.answer(path: file, line: 41, character: 12)  // from 0, UTF-16
for site in answer.sites {
  if let place = model.place(of: site) { print(place.path, place.line) }
}
model.project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 41, character: 12, limit: 40)
print(list.context, list.items.map(\.label))
```

## Main API

`CSharpModel` is a `LanguageModel` (CodeModel), so it is asked as the other models are.

### Loading a project

`CSharpModel(root:)` finds the `.csproj` projects under the root and reads their files; `CSharpModel(project:)` takes
a `Project` whose layout is a `CSharpLayout`. `project` is CodeModel's `Project`.

### Definitions and references

- `answer(path:line:character:)`, `location(of:)` (a stub's file is written out first), `place(of:)`.
- `references(of:)`: where an answer's definitions are used, a line each, in the project (a partial type's parts
  all count as it, an attribute class is also found without its `Attribute` suffix).

### Completion

`complete(path:line:character:limit:)` returns a `ModelCompletionList`: after `.`, a value's members and the extension
methods it can see, a type's static members and nested types, a namespace's types and namespaces; after `using` and
`namespace`, namespaces; types where only a type can go (after `new`, `:` in a type's head, `is`, `as`, a cast's
parenthesis, a parameter list's type); nothing in strings, comments or where a new name is declared; elsewhere locals,
the enclosing types' members, the namespaces' and usings' types, `using static` members and keywords. Methods come as
snippets with their parameters as placeholders; `[Obsolete]` members rank last.

### Symbol details

`details(of:)` returns `SymbolDetails`: the declaration on one line (`public static int Add(int a, int b)`,
`public sealed class ChannelServer<TState>`, `string? name`), the `<summary>` of its XML doc comment as text, its parents
(the types out to the namespace) and a value's type.

`ModelLanguage.cSharp`: the extension (`cs`), the manifests (`*.csproj`, `*.sln`, `*.slnx`, `Directory.Build.props`,
`global.json`; `ModelLanguage.isManifest(_:)` matches the patterns) and how to make the model, for CodeKit and
`code-model`.

### The code-model tool

```bash
swift run code-model query --root ~/Projects/app --language cs --queries reference.json --out answers.json
swift run code-model complete --root ~/Projects/app --language cs --at src/App/Program.cs:41:12
```

## Numbers

Against Roslyn's own binding (the .NET 10.0.401 SDK's `Microsoft.CodeAnalysis.CSharp` `SemanticModel`, run offline in
the local SDK Docker image by `../Demos/CodeModelBench/cs/tools/csref.sh`), from `../Demos/CodeModelBench/cs/README.md`.
Tuned on channel-cs (Hub's C# channel library: a solution of five projects linked by `ProjectReference`, ASP.NET Core,
QUIC), every identifier (12,624): 98.8% right, 0.2% wrong (no exact answer wrong; the wrong ones are candidate lists
without the right place), 1.1% unknown; its 8,668 project definitions 98.4% exact, the 3,510 in the .NET library 94.9%
exact. References: 98.0% recall, 99.9% precision. **No held-out score yet**: the Docker VM the reference runs in lost
its disk (I/O errors on the external volume it lives on) before a fresh sample was recorded, so these are tuning
numbers; a held-out run is `csref.sh` on one of the bench's other corpora, scored once. What's unknown is mostly library
types the stub doesn't have, delegates' `Invoke` and tuple elements by name.

Release build: the first answer in 90 ms (channel-cs) to 630 ms (9,400 files), then a median of 0.004 ms and a p95 of
0.02 ms per definition (channel-cs's 12,624 in 0.36 s); references 0.4 ms each on average. Completion on channel-cs, 400
cases (the author's word deleted, or its first two characters left): listed 91.0%, first 48.0%, top five 69.8%; with two
characters typed first 73 to 85%; a median of 0.8 ms. 3,000 random identifiers of each of six corpora and a decompiled
game (9,401 files, keywords included): no crash or hang, at most 300 MB.

## Testing

```bash
swift test --filter CodeCSharpModelTests
```

The tests write small projects (a `.csproj` and `.cs` files) to a temporary folder with `@@` before the words they ask
about, and read the stub.

## Related

- [CodeSwiftModel](CodeSwiftModel.md), [CodeGoModel](CodeGoModel.md), [CodeTypeScriptModel](CodeTypeScriptModel.md),
  [CodeClangModel](CodeClangModel.md), [CodePythonModel](CodePythonModel.md), [CodeRustModel](CodeRustModel.md),
  [CodeJavaModel](CodeJavaModel.md) and [CodeKotlinModel](CodeKotlinModel.md): the other models, and the
  [CodeModel core](CodeSwiftModel.md#codemodel-the-core) all are built on.
- [CodeScan](CodeScan.md): the tokens the model reads, and the tier before it.
- [CodeKit](CodeKit.md): the definition tiers that ask the model.
- [CodeLSP](CodeLSP.md): a C# language server, the tier after it.
