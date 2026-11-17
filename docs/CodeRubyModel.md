# CodeRubyModel

## Purpose

CodeRubyModel is a model of a Ruby project built from its source text, on
[CodeModel](CodeSwiftModel.md#codemodel-the-core) and [CodeScan](CodeScan.md)'s tokens. It doesn't run Ruby, Bundler or
a language server. In milliseconds it answers:

- where a name is defined: exact, a few candidates, or unknown;
- what can be completed at a position;
- where a definition is referenced;
- what a symbol is.

It reads the `.rb`, `.rake`, `.gemspec` and `.ru` files under a folder (plus `Rakefile` and `Gemfile`), the files a
`require` reaches in the gems and the standard library, and Ruby's core classes from a stub generated from rbs.

It is not an interpreter. It follows the types it can be sure of, and YARD and Sorbet's types. Otherwise it gives
candidates or nothing, since an unknown answer is better than a wrong exact one. It never runs `bundle install`, and it
never downloads or installs anything.

It is Ruby's model in the middle of Code's three tiers (CodeKit's `CodeTiers`):

1. CodeScan guesses first.
2. The model answers for `.rb`, `.rake`, `.gemspec` and `.ru` files.
3. A language server (Ruby LSP) is asked only when the model isn't sure.

Names resolve the way Ruby binds them:

- **Files** (`RubyLayout`).
  - Every Ruby file under the root is read, each its own module. `vendor`, `node_modules`, `tmp`, `log`, `coverage`
    and hidden folders are left out.
  - Constants are global in Ruby, so a class reopened in ten files is one class.
  - `require` and `require_relative` follow Ruby's load path as a run would see it:
    1. The project's `lib`, `test` and `spec` folders, and the folders a file adds to `$LOAD_PATH`.
    2. The gems `Gemfile.lock` names, at their locked versions, found where Bundler installs them: `.bundle/config`'s
       `BUNDLE_PATH`, `vendor/bundle`, `GEM_HOME`, the user's and the system's gem folders. They are read in place.
    3. The newest Ruby's standard library on disk. `CODE_RUBY_STDLIB` overrides it.
  - A `require` answers the file it loads.
- **Declarations** (`RubySyntax`).
  - `class`, `module`, `class << self`, `def` and `def self.x`.
  - Endless defs (`def x = …`) and operator methods.
  - Constants.
  - `attr_reader`, `attr_writer` and `attr_accessor`.
  - `alias` and `alias_method`.
  - `define_method(:name)` with a literal name.
  - `Struct.new(:a, :b)` and `Data.define` members; `Class.new(Base)` and `Module.new` blocks.
  - `private`, `protected` and `module_function`, alone or around a `def`.
- **Locals** (`RubyBody`).
  - A local is defined where it is first bound in its scope (a method, class, module or file).
  - A block sees its parents' locals; its parameters (`|a, (b, c), *d, e: 1, &f|`) are its own.
  - Bindings include multiple assignment, `rescue => e`, `for x in` and `||=`.
  - A bare name is a local only after its binding.
  - `name "arg"`, with a space and an argument on the same line, is a command call even when a local of that name is in
    scope.
- **Constants**:
  1. Lexically: the classes and modules around the name, innermost first.
  2. The innermost one's ancestors.
  3. The top level.

  `A::B` is looked up in `A` and its ancestors. A class's own name and superclass are read outside it.
- **Methods** (`RubyTypes`).
  - A method is looked up through a value's ancestors, as Ruby orders them: prepends, the class, includes (latest
    first), then the superclass's.
  - A class's singleton side holds its `def self.x` and `class << self` methods, its extends and its superclass's
    singleton side, then `Class` and `Module`.
  - `super` answers the next ancestor's method.
- **Types**.
  - Literals, `Foo.new` (→ `initialize`), constants, `self` and a method's last expression.
  - `||=`.
  - YARD's `@return`, `@param`, `@yieldparam`, `@yieldsplat` and `@!generics`; Sorbet's `sig { params(…).returns(…) }`.
  - Block parameters from the receiver's `@yieldparam`, so `words.each { |w| w. }` knows `w`.
  - A value whose type can't be told answers by name, as candidates.
- **Instance, class and global variables**.
  - `@x` is defined at its first assignment in the class, else in an ancestor. The class itself keeps its own
    class-level ones apart.
  - `@@x` is shared down the hierarchy.
  - `$x` belongs to the whole program.
- **Places** (`place(of:)`), as the bench's reference names them: a path relative to the root (`../…` outside it) and a
  line. The stub's declarations are `ruby:core.rb` and a line.

**Unknown on purpose:**

- `method_missing` and `respond_to_missing?`;
- `send`/`public_send` with a computed name, and `define_method` with a computed name;
- blocks evaluated elsewhere (`instance_eval`, `class_eval`, DSLs such as RSpec's `describe`);
- values with no type: a method's untyped parameter, and a Hash or Array literal's elements;
- C extensions;
- names interpolated inside heredocs, regexes and `%` literals, which CodeScan doesn't lex as code.

**Ruby's core classes**: `RubyStd`, a stub of 326 classes and modules (marked as Code's generated stub at its top). It
is generated by `../Demos/CodeModelBench/rb/tools/gen_stub.rb` from the rbs gem 3.4.0's core signatures:

- each class's superclass, includes, constants, attributes and methods;
- parameters as the first overload names them;
- types as YARD tags;
- `private` sections;
- each one's first sentence of documentation.

It is written to `$TMPDIR/code-ruby-std/core.rb` when a file of it is opened.

**The lexer** (CodeScan's Ruby rules) handles:

- `%w[]`, `%i[]` and `%q()` literals;
- heredocs after operators (`x = <<~EOS`, `foo(<<-A, <<-B)`);
- `?c` character literals;
- regexes after a space or `=`;
- symbols of operators (`:<=>`, `:[]=`);
- keywords after `.`, `&.` and `::` taken as method names;
- `@x`, `@@x` and `$x` as one name;
- `=begin`/`=end` comments;
- backtick commands with `#{}`.

Checked against Ripper over Ruby 2.6's standard library, it misses 0.7% of names and finds 0.01% that aren't.

## Platforms

<!-- platforms: macos ios linux windows -->

- **macOS, Linux, Windows, iOS (iPadOS)**: everything works. The stub is the same everywhere. Gems and the standard
  library are read where they're installed, and there are none on iOS.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeRubyModel", package: "Code"),
```

CodeRubyModel re-exports CodeModel. The target builds in Swift 5 language mode, and the model isn't thread-safe: give
it its own serial queue.

```swift
import CodeRubyModel

let model = RubyModel(root: "/path/to/app")
let file = "/path/to/app/lib/app/server.rb"
let answer = model.answer(path: file, line: 41, character: 12)  // from 0, UTF-16
for site in answer.sites {
  if let place = model.place(of: site) { print(place.path, place.line) }
}
model.project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 41, character: 12, limit: 40)
print(list.context, list.items.map(\.label))
```

## Main API

`RubyModel` is a `LanguageModel` (CodeModel), so it is asked as the other models are.

### Loading a project

`RubyModel(root:)` reads the files under the root. Required files outside it are read when a name reaches them. `project`
is CodeModel's `Project`.

### Definitions and references

- `answer(path:line:character:)`, `location(of:)` and `place(of:)`. `location(of:)` writes the stub out first; a required
  file opens at its start.
- `references(of:)`: where an answer's definitions are used in the project, one line each.

### Completion

`complete(path:line:character:limit:)` returns a `ModelCompletionList`:

- **After `.` and `&.`**: a value's methods along its ancestors. Private methods appear only after `self.`, and an
  unknown receiver gives no list.
- **After `::`**: a class's or module's constants and its singleton methods.
- **After `@`, `@@` and `$`**: the variables of that kind in scope.
- **After `def`, `class`, `module` and `alias`**: nothing, since a new name goes there.
- **Elsewhere**: the locals in scope, self's methods, the constants of the lexical scopes and the top level, and the
  keywords.

Object's, Kernel's and Module's methods rank after the class's own. Methods come as snippets with their parameters
as placeholders, required keywords as `name: ${n:name}`. Writers (`x=`), operators, `initialize` and `method_missing`
aren't offered.

### Symbol details

`details(of:)` returns `SymbolDetails`:

- the declaration's line (`def find(id, scope: nil)`, `class User < Record`, `attr_reader :name`), or a variable with
  its type;
- the comment above it up to a blank line or a YARD tag;
- its parents: the classes and modules, and the file;
- a value's type, written as RBS writes it (`Array[Integer]`, `singleton(User)`, `String | Symbol`, `Integer?`).

### ModelLanguage.ruby

`ModelLanguage.ruby` holds, for CodeKit and `code-model`:

- the extensions: `rb`, `rake`, `gemspec`, `ru`;
- the manifests: `Gemfile`, `Gemfile.lock`, `*.gemspec`, `.ruby-version`;
- how to make the model.

`Rakefile` and `Gemfile` are read as part of a project. CodeKit doesn't send them to the model on their own, because
they have no extension.

### The code-model tool

```bash
swift run code-model query --root ~/Projects/app --language ruby --queries reference.json --out answers.json
swift run code-model complete --root ~/Projects/app --language ruby --at lib/app/server.rb:41:12
swift run code-model tokens --all --root ~/Projects/app --language ruby   # CodeScan's names, for rb/tools/lexcheck.rb
```

## Numbers

From `../Demos/CodeModelBench/rb` (2026-11-17, release build). The reference is `rb/tools/rbref.rb`, a resolver
written for the bench and kept apart from the model. It reads Ripper's parse tree in Ruby 3.3 (the local hub-toolchains
Docker image, no network). It names only what Ruby makes unambiguous and leaves the rest out of the score.

- **channel-rb** (tuned on, every identifier, 11,250 positions): of the 6,961 with a reference, 100.0% were exactly
  right and none wrong. References came out at 100% recall and 98.5% precision.
- **Held out**, scored before looking:

  | Project | First run | After fixes | References recall / precision |
  |---|---|---|---|
  | hub-service-rb (3,034 with a reference) | 95.7% right, 2 wrong | 100% | 100% / 97.8% |
  | rake 12.3.3 (3,199 with a reference) | 99.4% right, 7 wrong | 99.6%, 0 wrong, 0.4% unknown (interpolation in regexes and heredocs) | 99.7% / 98.2% |

  The fixes were in the lexer (`<<`), block parameters, command calls and endless defs.
- **Hand checks**: 50 exact answers without a reference were checked by hand, and all were right.
- **Speed and memory**: a median of 0.001 ms per answer (p95 0.005 ms). channel-rb's 11,250 positions with references
  took 2.0 s at a peak RSS of 126 MB.
- **Crash runs**: 100,000 random words of Ruby 2.6's standard library took 1.8 s at 244 MB. Six gems got 3,000 words
  each. Nothing crashed or hung.

## Testing

```bash
swift test --filter CodeRubyModelTests
```

The tests write small projects to a temporary folder, with `^^` before the words they ask about, and read the stub.
CodeScanTests' `rubySigilsSymbolsLiteralsAndOperators` covers the lexer.

## Related

- The other models: [CodeSwiftModel](CodeSwiftModel.md), [CodeGoModel](CodeGoModel.md),
  [CodeTypeScriptModel](CodeTypeScriptModel.md), [CodeClangModel](CodeClangModel.md),
  [CodePythonModel](CodePythonModel.md), [CodeRustModel](CodeRustModel.md), [CodeJavaModel](CodeJavaModel.md),
  [CodeKotlinModel](CodeKotlinModel.md), [CodeCSharpModel](CodeCSharpModel.md), [CodeDartModel](CodeDartModel.md) and
  [CodePHPModel](CodePHPModel.md). The [CodeModel core](CodeSwiftModel.md#codemodel-the-core) is what they're all
  built on.
- [CodeScan](CodeScan.md): the tokens the model reads, and the tier before it.
- [CodeKit](CodeKit.md): the definition tiers that ask the model.
- [CodeLSP](CodeLSP.md): Ruby's language server (Ruby LSP), the tier after it.
