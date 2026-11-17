# CodeShellModel

## Purpose

CodeShellModel is a model of shell scripts (sh, bash and zsh) and PowerShell scripts built from their source text, on
[CodeModel](CodeSwiftModel.md#codemodel-the-core) and [CodeScan](CodeScan.md)'s tokens. It doesn't run a shell, pwsh
or a language server. In milliseconds it answers:

- where a name is defined: exact, a few candidates, or unknown;
- what can be completed at a position;
- where a definition is referenced;
- what a symbol is.

It reads the scripts under a folder, the files they source outside it, and each language's builtins from a
hand-written stub. A shell runs a script's names as it reaches them, so much of what a script means is decided only
when it runs: the model answers what the text makes certain and gives candidates or nothing for the rest, since an
unknown answer is better than a wrong exact one. It never downloads or installs anything.

It is the scripts' model in the middle of Code's three tiers (CodeKit's `CodeTiers`):

1. CodeScan guesses first.
2. The model answers for shell and PowerShell files.
3. The language server is asked when the model isn't sure: bash-language-server for sh, bash and zsh when it's
   installed; CodeLSP's catalog has none for PowerShell (PowerShell Editor Services would be the one), so CodeScan's
   own server stands in.

**One library, two syntaxes.** Shell and PowerShell are both command languages: a line is a command and its
arguments, a command's name is a function, an alias or a builtin, found by name over the files a script sources, and a
function's variables are its own, its callers' or the script's. So there is one model, `ScriptModel`, over one set of
facts per file (`ScriptFile`: declarations, uses, sourced files, values), and two parsers that write them,
`ShellSyntax` and `PowerShellSyntax`, picked by `ScriptDialect`. Resolution, completion, details and references are
shared; what only PowerShell has (parameters at a call, classes and their members, modules and their exports) is an
extension of the same model (`ScriptPowerShell`, `ScriptPowerShellCompletion`). Two separate front ends would have
repeated the program, scoping and completion code, which is half of the library.

**Files** (`ScriptLayout`). Every file of the dialect under the root is its own module, named by its path; hidden
folders, `node_modules`, `Pods`, `DerivedData`, `Carthage` and `vendor` are left out.

- Shell: `.sh`, `.bash`, `.zsh`, `.ksh`, `.command`, the shells' startup files (`.bashrc`, `.bash_profile`, `.profile`,
  `.zshrc`, `.zshenv`, `.zprofile`, `.envrc`, `PKGBUILD`…), files without an extension whose `#!` line names a shell
  (`sh`, `bash`, `zsh`, `ksh`, `dash`, also through `env`), and zsh function files starting `#compdef` or `#autoload`.
- PowerShell: `.ps1` scripts, `.psm1` modules, `.psd1` manifests, and files without an extension whose `#!` line names
  `pwsh`.

A script's **program** is what it sources (and they source), plus, for a sourced file, what its sourcing scripts see.
That is where its names are looked up. A file outside the root is read when a script sources it.

**Shell** (`ShellSyntax`, on `ScriptTokens`: CodeScan's tokens read again as the shell's words, with expansions
inside `"…"` and here-documents as tokens of their own):

- **Functions**: `f() { … }`, `function f { … }`, `function f() …`; a command's name answers the program's functions
  of that name, then its aliases (`alias ll='ls -l'`), then the stub's builtins of the script's own shell (bash's
  `mapfile` isn't zsh's, zsh's `print` isn't bash's). An external program (`git`, `cc`) is unknown.
- **Variables, by dynamic scope**: in a function, its nearest `local`/`declare`/`typeset` declared before the use;
  else, when functions that call it declare that name local, candidates: those locals first, then the script's
  assignments, because the caller decides at run time; else every assignment in the script's program. Arrays
  (`a=(…)`, `a+=(…)`, `${a[@]}`, `${!a[@]}`), `read`, `mapfile`/`readarray`, `getopts`, `for`, `printf -v`,
  `${!name}`, arithmetic `(( n = … ))` and `for (( i = … ))`, and `IFS=` before a command declare variables too.
- **Sourcing**: `source` and `.` with a literal path, or one under `$(dirname "$0")`, `${BASH_SOURCE%/*}`,
  `${0:A:h}` (zsh) or a variable assigned one of those (`here=$(cd "$(dirname "$0")" && pwd)`); the path answers the
  file.
- **zsh's autoload**: the folders a script adds to `fpath` (`fpath=(… $fpath)`, `fpath+=…`) are searched for
  `autoload -Uz name`; the file is read as the function's body.
- A top-level `exit` or `exec` that opens a line ends the script: what follows is often embedded data.

**PowerShell** (`PowerShellSyntax`):

- **Functions and filters** with `param(…)` or parenthesized parameters; names are case-insensitive. A command's name
  answers the program's functions, then the functions the modules it imports export, then `Set-Alias`/`New-Alias`
  aliases, then the stub's cmdlets and aliases. `-Name` at a call answers the function's `$Name` in its `param()`,
  by the whole name or a prefix only one parameter has (`-Vers` for `-Version`); an advanced function
  (`[CmdletBinding()]` or a `[Parameter()]`) and a cmdlet also take the common parameters (`-Verbose`,
  `-ErrorAction`…). A prefix two parameters share is unknown, as PowerShell rejects it.
- **Scopes**: in a function, its parameters and its first assignment before the use; a variable it never assigns is
  its caller's, as in the shell (candidates when another function assigns the name, else the script's assignments).
  `$script:x` and `$global:x` are the script's; `$using:x` is the enclosing scope's; `$env:X` answers the program's
  `$env:X` assignments, else the stub's environment variables. A script's own `param()` is the script's.
- **Dot-sourcing and modules**: `. path`, `Import-Module path`, `Import-Module (Join-Path $PSScriptRoot …)` and
  `using module path`, with literal paths or ones under `$PSScriptRoot` (or a variable assigned from it, such as
  `$RootDir = Split-Path $PSScriptRoot -Parent`). A `.psm1` exports its `Export-ModuleMember -Function` names (with
  wildcards), or all its functions without one; a `.psd1` exports its `RootModule`'s and `NestedModules`' functions
  filtered by `FunctionsToExport`. A module's unexported function is unknown at a call outside it.
- **Classes and enums**: `[Name]` answers the program's or an imported module's class or enum; `$this.member` in a
  method and `[Name]::member` its members (its own, then its base class's), `[Name]::new` its constructors;
  `$x.member` when `$x`'s class is in the text: `[T]$x = …`, `$x = [T]::new(…)`, `New-Object T`, or a copy of
  another such variable.
- **Help**: a `<# .SYNOPSIS … #>` block first in a function's body or right above it is its documentation, its
  `.PARAMETER Name` the parameter's.
- **.NET types are unknown**: `[System.IO.Path]::Combine`, `$list.Add`, `$s.Length`. C#'s .NET stub
  ([CodeCSharpModel](CodeCSharpModel.md)) was not reused: a script's values are mostly untyped, so the stub would
  answer only typed variables and statics, and scripts use .NET far less than cmdlets; a member of a value whose type
  the model would have to guess must stay unknown anyway.

**Places** (`place(of:)`), as the bench's reference names them: a path relative to the root and a line, a whole file at
line 1. The stub's are `builtin:<name>` (shell) or `ps:<name>`, `ps:<Cmdlet>.<Parameter>`, `ps:env:<NAME>` and
`ps:CommonParameters.<Name>` (PowerShell), line 0.

**Unknown on purpose**: external programs and cmdlets outside the stub; a path built at run time (`source
"$dir/$name.sh"` with `name` computed, `Import-Module $name`); `eval` and `Invoke-Expression`; a variable only the
environment or a caller outside the project sets; modules from the PowerShell Gallery or `$env:PSModulePath`; .NET
members; a member of a value whose class the text doesn't give.

**The stubs** (marked as Code's stubs at the top): `ShellStd`, bash's and zsh's builtins and special variables with
one line of description each and which shell has them, generated by `../Demos/CodeModelBench/sh/tools/gen_std.py`
from `tools/std.sh`; `PowerShellStd`, 115 cmdlets with their parameters, the common parameters, 79 automatic,
preference and environment variables and the 70 aliases PowerShell 7 keeps on macOS and Linux, generated by
`ps1/tools/gen_std.py` from `tools/std.ps1`. Each is read as its own module and written to `$TMPDIR/code-script-std/`
when a file of it is opened.

**The lexer** (CodeScan's shell and PowerShell rules, `LanguageRules.codeEscape`): outside quotes a backslash (a
backtick in PowerShell) escapes the next character, so `\'` doesn't open a string; shell's `'…'` has no escapes and
`$'…'` is a string; PowerShell's `<# … #>` comments, `@"…"@` and `@'…'@` here-strings, the backtick escape in `"…"`
and `''` in `'…'`.

## Platforms

<!-- platforms: macos ios linux windows -->

- **macOS**, **Linux**, **Windows**: everything.
- **iOS (iPadOS)**: everything; the project's own files and the stubs.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeShellModel", package: "Code"),
```

CodeShellModel re-exports CodeModel. The target builds in Swift 5 language mode, and the model isn't thread-safe: give
it its own serial queue.

```swift
import CodeShellModel

let model = ScriptModel(root: "/path/to/project", dialect: .powerShell)  // or .shell
let file = "/path/to/project/build.ps1"
let answer = model.answer(path: file, line: 24, character: 6)  // from 0, UTF-16
for site in answer.sites {
  if let place = model.place(of: site) { print(place.path, place.line) }
}
model.project.update(path: file, text: editedText)  // the editor's text, after an edit
let list = model.complete(path: file, line: 24, character: 6, limit: 40)
print(list.context, list.items.map(\.label))
```

## Main API

`ScriptModel` is a `LanguageModel` (CodeModel), so it is asked as the other models are. One model reads one dialect:
a folder with both shell and PowerShell scripts gets two.

### Loading a project

`ScriptModel(root:dialect:)` lists the root's scripts; a file is parsed when a question needs it. `project` is
CodeModel's `Project`. After an edit, the answers built from the program are dropped and found again on the next
question.

### Definitions and references

- `answer(path:line:character:)`, `location(of:)` (the stub's file is written out first), `place(of:)`.
- `references(of:)`: where an answer's definitions are used in the project, one line each: every use that answers the
  same definitions (a local's in its file, a parameter's `-Name` at calls in other files too).

### Completion

`complete(path:line:character:limit:)` returns a `ModelCompletionList`:

- **Where a command goes** (a line's start, after `|`, `;`, `&&`, `then`, `do`, a `case` pattern's `)`, `$(`, a
  backtick in shell, `return`, `throw` and an assignment in PowerShell): the program's functions and aliases, a
  module's exported functions, the stub's builtins or cmdlets, and keywords.
- **After `$`, `${`, in `(( ))`**: the variables in scope: the function's locals and parameters first, then the
  script's, then the stub's.
- **PowerShell**: after `-` at a call, the command's parameters (and the common ones); after `value.`, the class's
  members; after `[Type]::`, its members and `new`; after `$env:`, environment variables; after `$script:`,
  `$global:`, `$using:`, `$local:` and `$private:`, variables.
- **Nothing** in arguments that aren't variables, in a name being declared or assigned, in comments and in quotes.

### Symbol details

`details(of:)` returns `SymbolDetails`: the declaration on its line (`deploy()`, `function Get-Tool`,
`[string]$Name`, `class Job : Task`), its description (the `#` comments right above it; for PowerShell, the help
block's synopsis or description, and a parameter's `.PARAMETER` text), its kind and its file.

### ModelLanguage.shell and ModelLanguage.powerShell

They hold, for CodeKit and `code-model`, the extensions, the startup file names and `#!` interpreters above, how to
make the model, and the manifests: none for shell (a script's files are found by what it sources), `*.psd1` for
PowerShell (a manifest change reads the project again).

### The code-model tool

```bash
swift run code-model query --root ~/Projects/scripts --language shell --queries reference.json --out answers.json
swift run code-model query --root ~/Projects/scripts --language powershell --queries reference.json --out answers.json
swift run code-model tokens --all --root ~/Projects/scripts --language powershell   # for ps1/tools/lexcheck.py
```

## Numbers

Measured in `../Demos/CodeModelBench/sh` and `ps1` (their READMEs have the details) against the bench's own
resolvers, `sh/tools/shref.py` and `ps1/tools/psref.py`, written apart from the model with their own lexers and
parsers: no shell has a "go to definition" of its own, and pwsh couldn't run here (the local Docker image failed with
a containerd I/O error). They name only what a script's text makes unambiguous; `bash -n` and `zsh -n` check that
every shell script parses.

| Corpus | Positions with a reference | Right | Wrong | References recall / precision |
|---|---|---|---|---|
| v57's shell scripts, tuned | 7,928 | 100% | 0 | 100% / 99.8% |
| moq-tools' scripts, held out (first run 97.4%) | 8,282 | 100% | 0 | 100% / 99.8% |
| Hub's scripts, held out (first run 99.9%, 6 wrong) | 6,468 | 100% | 0 | 100% / 99.5% |
| msquic's PowerShell, tuned | 8,633 | 100% | 0 | 99.1% / 99.1% |
| XDP for Windows' PowerShell, held out (first run 100%) | 5,085 | 100% | 0 | 99.5% / 98.3% |
| This Mac's PowerShell, held out (first run 100%) | 1,848 | 100% | 0 | 99.1% / 100% |

- **Fixtures** written for the bench (zsh autoload, sourcing, dynamic scope; modules, classes, scopes): 65
  hand-worked answers and 4 that must be unknown, all right.
- **Hand checks**: 88 exact answers where the references have none (50 shell, 38 PowerShell): all right after one fix.
- **Completion** (about 400 cases per corpus, the word deleted or two characters left): the word is listed in 100%
  of shell cases and 99.8 to 100% of PowerShell's (ignoring case, as PowerShell does); first 42 to 50%, top five 68 to
  76%; a median of 0.3 to 1.8 ms.
- **Speed and memory**: the first answer in 12 to 70 ms, then a median of 0.001 ms per answer. Every position with
  references peaks at 26 to 260 MB.
- **Crash runs**: random words of every corpus, macOS's shell scripts, zsh's 1,204 function files, Homebrew's
  PowerShell completion scripts and garbled copies of the corpora: no crash or hang.
- **Code lines** (scc): 4,894, of which 983 are the two stubs; shared 1,225 (`ScriptModel`, completion, details,
  facts, layout), shell 1,374 (`ShellSyntax`, `ScriptTokens`), PowerShell 1,312 (`PowerShellSyntax`,
  `ScriptPowerShell`, its completion).

## Testing

```bash
swift test --filter CodeShellModelTests
```

The tests write small projects to a temporary folder, with `^^` before the words they ask about: functions, dynamic
scope, sourcing, zsh's autoload, each shell's builtins, arrays, quoting and here-documents, a top-level `exec`;
PowerShell's parameters and scopes, modules and their exports, classes; completion in both. CodeScanTests cover the
lexer.

## Related

- The other models: [CodeSwiftModel](CodeSwiftModel.md), [CodeGoModel](CodeGoModel.md),
  [CodeTypeScriptModel](CodeTypeScriptModel.md), [CodeClangModel](CodeClangModel.md),
  [CodePythonModel](CodePythonModel.md), [CodeRustModel](CodeRustModel.md), [CodeJavaModel](CodeJavaModel.md),
  [CodeKotlinModel](CodeKotlinModel.md), [CodeCSharpModel](CodeCSharpModel.md), [CodeDartModel](CodeDartModel.md),
  [CodePHPModel](CodePHPModel.md), [CodeRubyModel](CodeRubyModel.md), [CodeScalaModel](CodeScalaModel.md),
  [CodeLuaModel](CodeLuaModel.md) and [CodeHaskellModel](CodeHaskellModel.md). The [CodeModel core](CodeSwiftModel.md#codemodel-the-core) is what they're all
  built on.
- [CodeScan](CodeScan.md): the tokens the model reads, and the tier before it.
- [CodeKit](CodeKit.md): the definition tiers that ask the model.
- [CodeLSP](CodeLSP.md): the language servers, the tier after it.
