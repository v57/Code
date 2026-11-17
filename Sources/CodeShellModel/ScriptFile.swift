import CodeModel
import CodeScan
import Foundation

/// What a name token is, as the parser read it. Both dialects' parsers write these; the model resolves them.
enum ScriptUse {
  /// A command's name (`build`, `Get-Foo`): a function, alias or builtin, by name. The enclosing function's
  /// declaration, -1 at the top level. `functionsOnly`: `unset -f f`, `autoload f`, PowerShell's `Function:f`.
  case command(function: Int32, functionsOnly: Bool)
  /// A variable's use (`$x`, `${x}`, a name in arithmetic, `read x`'s `x` when it isn't a definition): the enclosing
  /// function's declaration, -1 at the top level.
  case variable(function: Int32)
  /// PowerShell's `$script:x`, `$global:x`: the script's variables only. `$env:X`: the environment's.
  case scriptVariable
  case environment
  /// A sourced file's path (`source ./x.sh`, `. "$PSScriptRoot/x.ps1"`, `Import-Module ./M.psm1`): `ScriptFile.sources`.
  case path(Int32)
  /// `$this` in a class's method or property: the class's declaration.
  case this(class: Int32)
  /// A command's parameter at a call (`Get-Foo -Name x`): the command's name token.
  case parameter(command: Int32)
  /// `value.name` (PowerShell): the receiver's expression in `ScriptFile.exprs`.
  case member(receiver: Int32)
  /// `[Type]::name`: the type's name token (its last).
  case staticMember(type: Int32)
  /// A type's name in `[Type]`, `class A : B`, `New-Object Type`: the first token of its dotted name.
  case type(first: Int32)
}

/// A file a script reads with its code: `source`, `.`, PowerShell's dot-sourcing and `Import-Module`, zsh's `fpath`.
struct ScriptSource {
  /// `source`: read into the script (its functions and variables are the script's); `module`: imported, its exported
  /// functions only; `functionFolder`: zsh's `fpath`; `run`: a script run as a command (`& ./x.ps1`), only a path.
  enum Kind: UInt8 { case source, module, functionFolder, run }
  var kind: Kind
  /// The path's first and last token (a word can be several).
  var first: Int32
  var last: Int32
  /// The path as written with its expansions read: `\u{1}` for the script's own folder, `\u{2}` for the home folder,
  /// `\u{3}NAME\u{3}` for a variable's value; nil when it can't be told.
  var pattern: String?
  /// The enclosing function's declaration, -1 at the top level.
  var function: Int32
}

/// An expression whose type PowerShell's model may follow: a variable, a member, a call, a type's static member.
enum ScriptExpr {
  /// `$x`: the name token.
  case variable(Int32)
  /// `$this`: the class's declaration.
  case this(Int32)
  /// `base.name` or `base.name(…)`: the base expression and the name's token.
  case member(Int32, Int32)
  /// `[T]::name` or `[T]::name(…)`: the type's name tokens and the member's name token.
  case staticMember(Int32, Int32, Int32)
  /// `[T]` alone (a cast), `[T]::new(…)`, `New-Object T`: the type's name tokens.
  case type(Int32, Int32)
  /// `(…)` around an expression, `$(…)`.
  case paren(Int32)
  case other
}

/// A file as its parser read it: every name's meaning, the files it reads, and what each function calls (for
/// dynamic scope). Kept in `Unit.scans`.
final class ScriptFile: BodyFacts {
  static let key = Int32.min + 2
  var uses: [Int32: ScriptUse] = [:]
  var sources: [ScriptSource] = []
  /// Declarations that are a function's parameters (PowerShell's `param()` and `function f($a)`).
  var parameters: Set<Int32> = []
  /// Each function's (by its declaration) command names, as hashes: who calls whom, for dynamic scope.
  var calls: [Int32: Set<Name>] = [:]
  /// Each variable declaration's value tokens (after `=`), or -1.
  var values: [Int32: (start: Int32, end: Int32)] = [:]
  /// A shell file read as zsh (`.zsh`, a zsh startup file, `#!…zsh`).
  var isZsh = false
  /// A file that is one function's body (zsh's autoloaded functions): the function is the file's name.
  var isFunctionFile = false
  /// PowerShell's expressions, by index; `endsAt` the outermost one ending at a token.
  var exprs: [ScriptExpr] = []
  var endsAt: [Int32: Int32] = [:]
  /// Variables' declared types (`[int]$x`, a parameter's `[string]`): the declaration and the type's first and last
  /// name token.
  var declaredTypes: [Int32: (Int32, Int32)] = [:]
  /// PowerShell's `Export-ModuleMember -Function a, b` (names lowercased, hashed); nil when the module exports all.
  var exportedFunctions: Set<Name>?
  /// `Export-ModuleMember -Function Get-*`: wildcard patterns, lowercased.
  var exportPatterns: [String] = []
  /// A class's base and interfaces: their name tokens (first, last).
  var bases: [Int32: [(Int32, Int32)]] = [:]
  /// A module manifest's (`.psd1`) `RootModule`/`NestedModules` and `FunctionsToExport`.
  var manifestModules: [String] = []
  var manifestFunctions: Set<Name>?

  func dropTypes() {}

  @inline(__always) func expr(_ index: Int32) -> ScriptExpr { exprs[Int(index)] }
}

extension Unit {
  /// A token's name as a dialect compares names: PowerShell's ignore case.
  @inline(__always) func key(_ i: Int, _ dialect: ScriptDialect) -> Name {
    dialect == .shell ? hash(i) : lowerHash(i)
  }

  func lowerHash(_ i: Int) -> Name {
    let token = tokens[i]
    var bytes = [UInt8](repeating: 0, count: token.length)
    for k in 0..<token.length {
      let b = source.text[token.start + k]
      bytes[k] = b >= 0x41 && b <= 0x5A ? b | 0x20 : b
    }
    return bytes.withUnsafeBufferPointer { hashName($0.baseAddress!, $0.count) }
  }
}

/// A name lowercased and hashed, as PowerShell's declarations are named.
func lowerName(_ text: String) -> Name { name(text.lowercased()) }
