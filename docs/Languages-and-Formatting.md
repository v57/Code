# Languages and Formatting

Choose the language servers that give Code definitions, issues and completions, how Code answers jumps, and which
formatters run when you save. Everything here is in **Settings ▸ Languages** and **Settings ▸ Formatting** (open
settings with ⌘,).

## On the Mac

### Language servers

A language server gives Code a language's definitions, issues and completions. Code bundles none: you install each
one from its official source, and Code finds it on your PATH.

**Settings ▸ Languages ▸ Servers** lists every server Code knows, the installed ones first. Among them are
SourceKit-LSP (Swift, from Xcode), clangd, gopls, rust-analyzer, the TypeScript server, Pyright, Kotlin, Eclipse JDT
(Java), Dart, ZLS (Zig), ElixirLS, Ruby LSP, Intelephense (PHP), csharp-ls, Lua, Bash and YAML. Each row says which
languages it covers and where it's installed.

- **Install** runs the install command shown in the button's tooltip, for example a Homebrew, npm or gem command. It
  downloads the server from that source. A server that comes with Xcode or an SDK shows **Not installed** instead.
- **Uninstall** removes it, after asking.
- Each installed server has a switch, to turn it off without removing it.
- **Language servers** at the top turns them all on or off.

A server runs for each project in the folder, so a folder with several projects gets one per project.

#### Code's built-in server

Code has its own language server for every language it colors, listed as **Code’s scanner**. It runs inside Code
and contacts nothing. It's used for a language that has no other server installed, or when the others are off, and
it's the only server in a folder you haven't trusted (see [Privacy and Security](Privacy-and-Security.md#trusting-a-folder)).

#### Swift in Xcode projects

SourceKit-LSP doesn't read Xcode projects by itself. In a trusted folder, Code gives it the build settings of the
Xcode scheme you picked in the toolbar, so files in Xcode targets get definitions and issues. Other modules resolve
once the scheme has been built.

### Jumping and completion

When you jump to a definition or complete a name, Code asks up to three sources together. The fastest answer shows
first and the slower ones update it. Turn a source off in **Settings ▸ Languages ▸ Jumping and completion** to save
memory and power:

- **Code’s scanner**: guesses from the code's words, in every language. It uses about 8 MB.
- **Swift model**: reads Swift's types from the source and answers in milliseconds. It can use 150–200 MB for a large
  app.
- **Ask the language server**: **When Unsure** (the default) asks it for definitions only when the Swift model isn't
  sure, and always in other languages. **Always** lets its answer decide each jump. **Never** stops asking it for
  definitions; it still reports issues and completes.

### Formatting on save

When **Format when saving** is on in **Settings ▸ Formatting**, ⌘S formats the file before writing it. The change is
one step you can undo, and only what changed is touched. Saving on its own (autosave) never formats.

Code knows these formatters:

| Language | Formatter | Config files |
|---|---|---|
| Swift | swift-format | `.swift-format` |
| JavaScript, TypeScript, JSON, CSS, HTML, Markdown, YAML | Prettier | `.prettierrc` and the others Prettier reads |
| Go | gofmt | none |
| Rust | rustfmt | `rustfmt.toml` |
| Python | Ruff | `ruff.toml`, `pyproject.toml` |
| C, C++, Objective-C | ClangFormat | `.clang-format` |
| Zig | zig fmt | none |
| Elixir | mix format | `.formatter.exs` |
| Kotlin | ktlint | `.editorconfig` |
| Shell | shfmt | none |
| Java | google-java-format | none |
| C# | CSharpier | `.csharpierrc`, `.editorconfig` |
| Dart | dart format | `analysis_options.yaml` |
| PHP | Pint, PHP-CS-Fixer | `pint.json`; `.php-cs-fixer.php`, `.php-cs-fixer.dist.php` |
| Ruby | Standard Ruby, RuboCop | `.standard.yml`; `.rubocop.yml` |
| Scala | scalafmt | `.scalafmt.conf` |
| Lua | StyLua | `stylua.toml`, `.editorconfig` |
| Haskell | Fourmolu, Ormolu | `fourmolu.yaml`; `.ormolu` |
| PowerShell | Invoke-Formatter (PSScriptAnalyzer, run by `pwsh`) | `PSScriptAnalyzerSettings.psd1` |
| TOML | Taplo | `.taplo.toml`, `taplo.toml` |
| SQL | SQLFluff | `.sqlfluff`, which names your SQL dialect |

Each reads its own config file from the file's folder upward.

Where a language has two formatters, the project's config file picks one: the formatter whose config file is
nearest the file is used. A PHP project with `pint.json` gets Pint and one with `.php-cs-fixer.php` gets PHP-CS-Fixer.
A Ruby project with `.rubocop.yml` gets RuboCop, and otherwise Standard Ruby. A Haskell project with `fourmolu.yaml`
gets Fourmolu, and otherwise Ormolu. Pint, RuboCop and Fourmolu wait for their config file at first. If you turn one
of them off, the other formats that language.

Some formatters need a config file to run at all. scalafmt reads the version from `.scalafmt.conf`, and SQLFluff
needs the dialect from `.sqlfluff`. Invoke-Formatter also needs the PSScriptAnalyzer module, which its **Install**
adds after PowerShell.

For each formatter, under **Formatters**:

- **Install** runs its install command, and its switch turns it off.
- **Only with a config file** runs it only when the project has a config file for it. Its tooltip lists the file
  names.
- **Custom command** runs your own command instead, for example a local build of swift-format.

**Code’s formatter** formats files no formatter above applies to, in any language. It's off at first. If its result
would change the code's meaning, it leaves the file as it was.

<!-- only: windows -->
On Windows, the formatters listed under **Formatters** don't run yet.
<!-- /only -->

In a folder you haven't trusted, Code uses only formatters from your PATH, never one installed inside the project,
and skips a formatter whose config is code, such as a JavaScript Prettier config. PHP-CS-Fixer's config is PHP, and
RuboCop's and Standard Ruby's can load Ruby. scalafmt can download the version its config names, and SQLFluff can
run the project's templates and Python. Code doesn't use another formatter in their place. See
[Privacy and Security](Privacy-and-Security.md#trusting-a-folder).

## On iPhone and iPad

Code on iPhone and iPad runs no language servers or formatters: it shows files read-only, highlighted for their
language.
