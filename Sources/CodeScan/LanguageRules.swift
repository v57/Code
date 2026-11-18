import CodeHighlighting

/// What a language needs beyond `LanguageSpec` (its comments, strings and keywords, which CodeHighlighting owns): how
/// blocks and declarations look and how it may be laid out. Plain data, so a language is a table row and every
/// language runs the same code; a language without a row gets `LanguageRules()`, which still scans and answers.
public struct LanguageRules: Sendable {
  /// How the code marks a block.
  public enum Blocks: Sendable {
    case braces
    /// By indentation, or by words like `end` whose pairs can't be told from tokens: scopes end at the indentation.
    case indentation
    /// A format or markup without code blocks.
    case none
  }

  /// How a parameter list names its parameters.
  public enum Parameters: Sendable {
    case none
    /// The identifier before `:`, or the segment's first one: `x: Int`, `a, b int`, `x`.
    case nameFirst
    /// The segment's last identifier before `=`: `int x`, `const Foo &x`.
    case nameLast
  }

  /// How a file's outline is found.
  public enum Outline: Sendable {
    case code
    case jsonKeys, yamlKeys, tomlKeys, markdownHeadings, makeTargets, cssSelectors, dockerStages
  }

  /// How much of a language's layout the formatter may decide.
  public enum Layout: Sendable {
    /// Newlines and indentation are free inside blocks: re-indents, spaces and wraps.
    case full
    /// Indentation carries meaning (or block words can't be told from tokens): spaces within a line only.
    case spacing
    /// Whitespace may be content: trailing spaces and blank lines only.
    case lines
  }

  public struct Interpolation: Sendable {
    /// The bytes that start code inside a string (`\(`, `${`, `#{`, `{`), the byte that ends it.
    public var open: String
    public var close: UInt8
    /// `{{` is a literal brace, not code (Python's f-strings, C#'s `$"..."`).
    public var doubledIsLiteral = false
    /// For strings opened by these markers only; empty means every string but the raw ones.
    public var strings: Set<String> = []
    /// Raw ones among `strings` (Python's `rf"…"`): the escape byte keeps a quote in, but code still opens after it.
    public var rawStrings: Set<String> = []
    /// A `:` outside brackets in the code starts a format spec, text up to the close (Python's `{x:#x}`).
    public var formatSpec = false
  }

  public var blocks = Blocks.braces
  public var outline = Outline.code
  public var layout = Layout.lines
  public var parameters = Parameters.none
  /// Declaration words that aren't in the spec's `declKeywords`, or more exact than its kinds.
  public var declarations: [String: SymbolKind] = [:]
  /// `Type name(...)` and `Type name = ...` declare without a keyword (C, Java, C#).
  public var typedDeclarations = false
  /// `name(...) {` inside a type body is a method and `name: Type` a field (JavaScript, TypeScript).
  public var bareMembers = false
  /// `name = value` at the start of a line declares `name` (Python, Ruby, Lua, Shell, Makefile).
  public var assignmentDeclares = false
  /// `name :: Type` at column 0 declares `name` (Haskell).
  public var signatureDeclares = false
  /// `name() {` declares a function (Shell).
  public var bareFunctions = false
  /// `{ a, b in` (Swift) or `{ a, b ->` (Kotlin) names a closure's parameters.
  public var closureHead: String?
  /// `(a, b) =>` and `a =>` name a closure's parameters.
  public var arrowParameters = false
  public var interpolations: [Interpolation] = []
  /// Extra string openers with their close: f-strings, `$"..."`.
  public var extraStrings: [StringDelim] = []
  /// `/.../` after an operator is a regex (JavaScript, TypeScript, Ruby).
  public var regexLiterals = false
  /// `<<WORD` starts a here-document (Shell, Ruby, PHP).
  public var hereDocuments = false
  /// A here-document's closing word may be indented and followed by any byte that can't continue it (PHP 7.3's
  /// `EOT;`, `EOT,`, `EOT)`).
  public var hereDocumentsCloseLoosely = false
  /// Code sits between `<?php` (or `<?=`) and `?>`, which a `//` or `#` comment doesn't hide; the text around it is
  /// markup, one string token (PHP).
  public var inlineMarkup = false
  /// `#[…]` is an attribute, not a `#` comment (PHP 8).
  public var hashBracketAttributes = false
  /// `` `a name` `` is one identifier (Kotlin's test names and keywords used as names).
  public var backtickIdentifiers = false
  /// `:` is an operator byte like `+` or `<`: `+:`, `:+`, `<:` and `#::` are one token each, and a lone `:` stays
  /// one; `.` is never part of an operator (`import a.*`, `xs.+:(x)`) (Scala).
  public var colonJoinsOperators = false
  /// A `#` comment needs a space before it (`$#` and `${#a}` aren't comments).
  public var commentsNeedWordStart = false
  /// Strings may run over lines whatever their quote (Shell, Ruby, PHP).
  public var multilineStrings = false
  /// `#"..."#` (Swift), `r#"..."#` (Rust), `R"x(...)x"` (C++).
  public var swiftRawStrings = false
  public var rustRawStrings = false
  public var cppRawStrings = false
  /// `$` ends an identifier, so `$name` and `name` are one name (Shell, Makefile, PHP, Ruby).
  public var dollarIsPunctuation = false
  /// This byte escapes the next one in code too, as a string of the two (Shell's `\'`, PowerShell's `` `" ``); a line
  /// break after it stays a line break. 0 for none.
  public var codeEscape: UInt8 = 0
  /// Identifier bytes besides letters, digits and `_` (`-` in CSS).
  public var extraIdentifierBytes = ""
  /// Bytes that may end an identifier, once, when no `=` follows (Ruby's `empty?` and `save!`; `a!=b` is `a != b`).
  public var identifierSuffixes = ""
  /// `@name`, `@@name`, `$name` and `$!`-style globals are one identifier, the sign included (Ruby).
  public var sigilNames = false
  /// `:name` (also `:name?`, `:name=`, `:@name`) is a symbol, one string token, where a value starts: not right after a
  /// name (`a:b` is a label and a name), and `::` stays a separator (Ruby).
  public var colonSymbols = false
  /// A keyword written as a label (`end:`), after `.` or `&.` (`x.class`) or after `def` is a name (Ruby).
  public var keywordsAsNames = false
  /// `%w[a b]`, `%i(a)`, `%q{…}`, `%r{…}i`, `%(…)`: one string token where a value starts (Ruby).
  public var percentLiterals = false
  /// A here-document's `<<WORD` can't follow a value directly (`a<<b` shifts) or `class` (`class <<self`) (Ruby).
  public var hereDocumentsAfterOperators = false
  /// `=begin` … `=end` at a line's start are a comment, and `__END__` alone on a line ends the code (Ruby).
  public var embeddedDocuments = false
  /// `[[…]]` and `[==[…]==]` are strings, `--[[…]]` and `--[==[…]==]` comments, closed only by a bracket of the same
  /// level (Lua).
  public var longBrackets = false
  /// The language's operators: a run of operator bytes is split into the longest of these from its start (Lua's `=#`
  /// is `=` and `#`, `..#` is `..` and `#`). Empty: a run is one token.
  public var operators: [String] = []
  /// A string's escape that skips the whitespace after it, line breaks too (Lua's `\z`); 0 for none.
  public var whitespaceEscape: UInt8 = 0
  /// `1.` is a number, the dot its own when no digit, name or dot follows (Lua's `{ 1., 2 }`).
  public var trailingDotNumbers = false
  /// Every run of the symbol bytes `!#$%&*+./<=>?@\^|-~:` is one operator, `:`, `.` and `-` included (`<-`, `.:`,
  /// `|->`); a run of two or more dashes alone starts a line comment, and `--` inside a longer run doesn't (`-->`,
  /// `|--`); a run right after a capitalized word splits off its first `.` (`Map.!` is `Map`, `.`, `!`) (Haskell).
  public var symbolOperators = false
  /// `.`, `?.` and these reach into a value.
  public var memberOperators: Set<String> = []
  /// The language's trailing comma where a list breaks: required (Go) or welcome.
  public var trailingCommas = TrailingCommas.never
  /// `case` lines up with its `switch` instead of one level in (Swift, Go).
  public var caseAlignsWithSwitch = false
  /// A newline can end a statement, so continuation lines indent only after an operator.
  public var newlineEndsStatements = false
  /// A space between a type-like word and `{` would change meaning or the language's style (Go's `Foo{}`).
  public var bracesFollowTightly = false
  /// `x: y` has no space before the colon (Swift, TypeScript, Kotlin, Rust, JSON, Python).
  public var colonHugsLeft = false
  /// `-> ` spaced: an arrow between types, not C's member access.
  public var arrowIsSpaced = false
  /// Prefers these quotes for strings when no escaping changes (Prettier's normalization).
  public var prefersDoubleQuotes = false
  /// `if (x)`. Off where projects differ and no tool of the language settles it: `if(x)` stays.
  public var spacesAfterControlWords = true
  /// A list broken over lines ends in a comma in a call too, not only in a literal. Swift's takes one only since 6.1.
  public var callsTakeTrailingCommas = true
  /// `{ a }` has spaces inside on one line, where the language's own tool writes it so.
  public var spacesInsideBraces = false
  /// Operators keep the spaces they have: gofmt's own spacing depends on precedence.
  public var preservesOperatorSpacing = false
  /// Bracket mismatches are reported. Off where tokens can't see through the language.
  public var reportsBrackets = true
  /// `~r/…/i`, `~s(…)`, `~w[…]a`, `~S"""…"""`, `~HTML"…"`: one string token, its delimiters not nesting, `\` skipping
  /// the next byte and a `#{…}` in a lowercase one skipped whole (Elixir).
  public var tildeSigils = false
  /// `?a`, `?\n`, `?"`: a character, one string token, wherever `?` doesn't end a name (Elixir).
  public var questionCharacters = false
  /// A name's `?` or `!` is its own before `=` too: `a?=b` is `a?`, `=` and `b`, and `a!=b` is `a!`, `=` and `b`
  /// (Elixir; Ruby reads `a!=b` as `a != b`).
  public var suffixesBeforeEquals = false
  /// `:"…"` and `:'…'` are symbols too, one string token with any `#{…}` in it, and `:a=` is `:a` and `=`, not a
  /// setter's name (Elixir's atoms).
  public var quotedSymbols = false
  /// A string opened by three quotes ends only at a line whose text starts with them (Elixir's heredocs).
  public var heredocsCloseAtLineStart = false
  /// `const Name = struct {`: a constant whose value starts with one of these words (after `extern` or `packed`)
  /// declares a type of this kind, and its braces are its body (Zig).
  public var typeValues: [String: SymbolKind] = [:]
  /// A `{}` holds a comma list or statements, never `case` labels: a `switch`'s prongs are its content, and a comma in
  /// braces ends an element. A one-element list keeps the spaces inside its braces as written: zig fmt writes `.{x}`
  /// and `error{A}`, but `.{ .x = 1 }` and `.{ a, b }` (Zig).
  public var bracesHoldLists = false
  /// Words that open and close blocks as brackets do (`then` … `fi`, `do` … `end`): `.full` indents by them.
  public var blockWords: [String: BlockWord] = [:]
  /// Block words count only where a command starts: `echo done` is an argument (Shell).
  public var blockWordsAtCommandStart = false
  /// A line starts a command: `/usr/bin/make`, `& $tool`, `. $file`; only `|` (and a shell's `&&`) at its start goes on.
  public var linesStartCommands = false
  /// Goto labels and `public:` sit a level out from what they label (clang-format's defaults).
  public var outdentsLabels = false
  /// `namespace a {` and `extern "C" {` don't indent their content, unless the file does.
  public var flatNamespaces = false
  /// Where the language's tools differ (C's `case` under `switch` or in from it), the file's own choice wins.
  public var followsFileStyle = false
  /// A line too long for the print width may break after a bracket. Off where a line break ends a command.
  public var wrapsLists = true
  /// Braces are optional and indentation can make blocks instead (Scala 3): a file that uses it keeps its indentation.
  public var optionalBraces = false
  /// Spaces separate words, as on a shell's command line (`a=b` isn't `a = b`): a gap stays a gap, runs of spaces
  /// becoming one, and none is made but where these say. Nil: spacing is the formatter's.
  public var wordGaps: WordGaps?
  /// Words after which the next token's column opens a block of the layout rule (Haskell's `do`, `where`, `let`,
  /// `of`, `\case`): the gaps before it on its line stay as written.
  public var layoutWords: Set<String> = []

  /// Where a word-separated language may still gain a space.
  public struct WordGaps: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// `a,b` → `a, b`.
    public static let afterCommas = WordGaps(rawValue: 1)
    /// `a==b` → `a == b`, for the operators that can't be anything else.
    public static let aroundOperators = WordGaps(rawValue: 2)
    /// `){` → `) {`.
    public static let beforeBraces = WordGaps(rawValue: 4)
    /// `if(` → `if (`.
    public static let afterControlWords = WordGaps(rawValue: 8)
  }

  /// What a block word does.
  public enum BlockWord: Sendable {
    case open
    /// Opens where a statement starts: `x = if a` does, `y if a` (a modifier) doesn't (Ruby).
    case openAtStatementStart
    /// `while`, `until`, `for`: opens where a statement starts, and its own `do` on its line opens nothing more (Ruby).
    case loopHead
    /// `do`: opens, unless a loop head on its line already did.
    case loopBody
    case close
    /// Ends a block and starts the next where it starts a line (`else`, `when`, `rescue`); elsewhere it's left alone.
    case middle
    /// A shell `case`: `in` opens its patterns, each `a)` a body that `;;` ends, `esac` all of it.
    case caseHead, caseIn, caseEnd
  }

  public enum TrailingCommas: Sendable { case never, allowed, required }

  public init() {}

  init(_ configure: (inout LanguageRules) -> Void) { configure(&self) }

  /// The rules for a language of the catalog, by its name.
  public static func rules(for name: String) -> LanguageRules { table[name] ?? LanguageRules() }

  private static let controlInC: [String: SymbolKind] = [
    "class": .class, "struct": .struct, "enum": .enum, "union": .struct, "interface": .interface,
    "namespace": .module, "typedef": .typeAlias,
  ]

  private static let table: [String: LanguageRules] = [
    "Swift": LanguageRules {
      $0.layout = .full
      $0.parameters = .nameFirst
      $0.declarations = [
        "class": .class, "struct": .struct, "enum": .enum, "protocol": .interface, "actor": .class,
        "extension": .extension, "typealias": .typeAlias, "func": .function, "init": .constructor,
        "subscript": .function, "let": .constant, "var": .variable, "case": .enumMember, "macro": .function,
        "associatedtype": .typeAlias,
      ]
      $0.closureHead = "in"
      $0.interpolations = [Interpolation(open: "\\(", close: 0x29)]
      $0.swiftRawStrings = true
      $0.regexLiterals = true
      $0.callsTakeTrailingCommas = false
      $0.spacesInsideBraces = true
      $0.trailingCommas = .allowed
      $0.caseAlignsWithSwitch = true
      $0.newlineEndsStatements = true
      $0.colonHugsLeft = true
      $0.arrowIsSpaced = true
    },
    "JavaScript": script(typed: false),
    "TypeScript": script(typed: true),
    "Python": LanguageRules {
      $0.blocks = .indentation
      $0.layout = .spacing
      $0.parameters = .nameFirst
      $0.assignmentDeclares = true
      $0.declarations = ["class": .class, "def": .function]
      $0.extraStrings = fStrings(["f", "F", "rf", "fr"])
      $0.interpolations = [
        Interpolation(
          open: "{", close: 0x7D, doubledIsLiteral: true, strings: Set(fStrings(["f", "F", "rf", "fr"]).map(\.open)),
          rawStrings: Set(fStrings(["rf", "fr"]).map(\.open)), formatSpec: true)
      ]
      $0.trailingCommas = .allowed
      $0.colonHugsLeft = true
      $0.prefersDoubleQuotes = true
      $0.arrowIsSpaced = true
    },
    "Java": LanguageRules {
      $0.layout = .full
      $0.parameters = .nameLast
      $0.typedDeclarations = true
      $0.declarations = ["class": .class, "interface": .interface, "enum": .enum, "record": .struct]
      $0.extraStrings = [StringDelim(open: "\"\"\"", multiline: true)]
      $0.arrowIsSpaced = true
    },
    "C#": LanguageRules {
      $0.layout = .full
      $0.parameters = .nameLast
      $0.typedDeclarations = true
      $0.arrowParameters = true
      $0.declarations = [
        "class": .class, "interface": .interface, "struct": .struct, "enum": .enum, "record": .struct,
        "namespace": .module, "var": .variable,
      ]
      $0.extraStrings = [
        StringDelim(open: "\"\"\"", escape: nil, multiline: true), StringDelim(open: "$\"", close: "\""),
        StringDelim(open: "$@\"", close: "\"", escape: "\"", multiline: true),
      ]
      $0.interpolations = [Interpolation(open: "{", close: 0x7D, doubledIsLiteral: true, strings: ["$\""])]
    },
    "C++": cFamily(raw: true),
    "C": cFamily(raw: false),
    "Objective-C": LanguageRules {
      var base = cFamily(raw: false)
      base.declarations["@interface"] = .class
      base.declarations["@implementation"] = .class
      base.declarations["@protocol"] = .interface
      $0 = base
    },
    "PHP": LanguageRules {
      $0.layout = .lines  // HTML can sit between its code.
      $0.parameters = .nameLast
      $0.declarations = [
        "class": .class, "interface": .interface, "trait": .interface, "enum": .enum, "function": .function,
        "namespace": .module, "const": .constant,
      ]
      $0.hereDocuments = true
      $0.hereDocumentsCloseLoosely = true
      $0.inlineMarkup = true
      $0.hashBracketAttributes = true
      $0.multilineStrings = true
      $0.dollarIsPunctuation = true
      $0.assignmentDeclares = true
      $0.interpolations = [Interpolation(open: "{$", close: 0x7D, strings: ["\""])]
      $0.trailingCommas = .allowed
    },
    "Shell": LanguageRules {
      $0.codeEscape = 0x5C
      $0.blocks = .indentation
      $0.bareFunctions = true
      $0.assignmentDeclares = true
      $0.declarations = ["function": .function]
      $0.hereDocuments = true
      $0.commentsNeedWordStart = true
      $0.multilineStrings = true
      $0.dollarIsPunctuation = true
      $0.interpolations = [
        Interpolation(open: "$(", close: 0x29, strings: ["\""]), Interpolation(open: "${", close: 0x7D, strings: ["\""]),
      ]
      $0.reportsBrackets = false  // `case x)` closes what never opened.
    },
    "Ruby": LanguageRules {
      $0.blocks = .indentation
      $0.layout = .lines  // `%w(a,b)` and friends: a comma isn't always one.
      $0.parameters = .nameFirst
      $0.assignmentDeclares = true
      $0.declarations = ["class": .class, "module": .module, "def": .function]
      $0.hereDocuments = true
      $0.multilineStrings = true
      $0.regexLiterals = true
      $0.hereDocumentsAfterOperators = true
      $0.dollarIsPunctuation = true
      $0.identifierSuffixes = "!?"
      $0.sigilNames = true
      $0.colonSymbols = true
      $0.keywordsAsNames = true
      $0.percentLiterals = true
      $0.embeddedDocuments = true
      // `` `ls #{dir}` ``: a command's text.
      $0.extraStrings = [StringDelim(open: "`", multiline: true)]
      $0.interpolations = [Interpolation(open: "#{", close: 0x7D, strings: ["\"", "`"])]
      $0.memberOperators = ["::"]
    },
    "Rust": LanguageRules {
      $0.layout = .full
      $0.parameters = .nameFirst
      $0.declarations = [
        "fn": .function, "struct": .struct, "enum": .enum, "trait": .interface, "impl": .extension, "type": .typeAlias,
        "mod": .module, "let": .variable, "const": .constant, "static": .variable, "union": .struct,
        "macro_rules": .function,
      ]
      $0.rustRawStrings = true
      $0.multilineStrings = true
      $0.spacesInsideBraces = true
      $0.trailingCommas = .allowed
      $0.colonHugsLeft = true
      $0.arrowIsSpaced = true
      $0.memberOperators = ["::"]
    },
    "Go": LanguageRules {
      $0.layout = .full
      $0.parameters = .nameFirst
      $0.declarations = [
        "func": .function, "type": .typeAlias, "var": .variable, "const": .constant, "package": .module,
      ]
      $0.trailingCommas = .required
      $0.caseAlignsWithSwitch = true
      $0.newlineEndsStatements = true
      $0.bracesFollowTightly = true
      $0.colonHugsLeft = true
      $0.preservesOperatorSpacing = true
    },
    "Kotlin": LanguageRules {
      $0.layout = .full
      $0.parameters = .nameFirst
      $0.declarations = [
        "class": .class, "interface": .interface, "enum": .enum, "object": .class, "typealias": .typeAlias,
        "fun": .function, "val": .constant, "var": .variable, "package": .module,
      ]
      $0.closureHead = "->"
      $0.spacesInsideBraces = true
      $0.interpolations = [Interpolation(open: "${", close: 0x7D)]
      $0.trailingCommas = .allowed
      $0.newlineEndsStatements = true
      $0.colonHugsLeft = true
      $0.arrowIsSpaced = true
      $0.backtickIdentifiers = true
    },
    "Dart": LanguageRules {
      $0.layout = .full
      $0.parameters = .nameLast
      $0.typedDeclarations = true
      $0.arrowParameters = true
      $0.declarations = [
        "class": .class, "mixin": .class, "enum": .enum, "extension": .extension, "typedef": .typeAlias,
        "var": .variable, "final": .constant, "const": .constant,
      ]
      $0.interpolations = [Interpolation(open: "${", close: 0x7D)]
      $0.trailingCommas = .allowed
      $0.arrowIsSpaced = true
    },
    "Scala": LanguageRules {
      $0.layout = .full
      $0.parameters = .nameFirst
      $0.arrowParameters = true
      $0.declarations = [
        "class": .class, "trait": .interface, "object": .class, "enum": .enum, "type": .typeAlias, "def": .function,
        "val": .constant, "var": .variable, "package": .module,
      ]
      $0.interpolations = [Interpolation(open: "${", close: 0x7D)]
      $0.newlineEndsStatements = true
      $0.colonHugsLeft = true
      $0.backtickIdentifiers = true
      $0.colonJoinsOperators = true
      $0.optionalBraces = true
    },
    "PowerShell": LanguageRules {
      $0.codeEscape = 0x60
      $0.layout = .lines
      $0.parameters = .nameLast
      $0.assignmentDeclares = true
      $0.declarations = ["function": .function, "class": .class, "enum": .enum]
      $0.dollarIsPunctuation = true
      $0.multilineStrings = true
      $0.extraIdentifierBytes = "-"
      $0.interpolations = [Interpolation(open: "$(", close: 0x29, strings: ["\"", "@\""])]
      $0.newlineEndsStatements = true
      $0.reportsBrackets = false
    },
    "Lua": LanguageRules {
      $0.blocks = .indentation
      $0.layout = .spacing
      $0.parameters = .nameFirst
      $0.assignmentDeclares = true
      $0.declarations = ["function": .function, "local": .variable]
      $0.longBrackets = true
      $0.whitespaceEscape = 0x7A
      $0.trailingDotNumbers = true
      $0.operators = [
        "...", "..", "==", "~=", "<=", ">=", "<<", ">>", "//", "::", "+", "-", "*", "/", "%", "^", "#", "&", "~", "|", "<", ">",
        "=", ":", ".",
      ]
    },
    "Haskell": LanguageRules {
      $0.blocks = .indentation
      $0.signatureDeclares = true
      $0.symbolOperators = true
      $0.dollarIsPunctuation = true
      // `foldl'`, `x'`: a prime continues a name; `'a'` where no name runs into it is a character.
      $0.extraIdentifierBytes = "'"
      $0.declarations = [
        "data": .struct, "newtype": .struct, "type": .typeAlias, "class": .interface, "instance": .extension,
        "module": .module,
      ]
      $0.reportsBrackets = false
    },
    "Zig": LanguageRules {
      // `zig fmt` is canonical and whitespace is never content outside a `\\` line, which is one token to its line's
      // end: the formatter may lay it all out.
      $0.layout = .full
      $0.parameters = .nameFirst
      $0.declarations = ["fn": .function, "const": .constant, "var": .variable]
      $0.typeValues = ["struct": .struct, "enum": .enum, "union": .struct, "opaque": .struct, "error": .enum]
      // `x: u32,` in a struct's body is a field.
      $0.bareMembers = true
      $0.trailingCommas = .allowed
      $0.colonHugsLeft = true
      $0.spacesInsideBraces = true
      $0.bracesHoldLists = true
      // `Point{ .x = 1 }` and `[_]u8{ 1, 2 }` are literals, `fn f() void {` a body: tokens can't tell them apart.
      $0.bracesFollowTightly = true
    },
    "Elixir": LanguageRules {
      $0.blocks = .indentation
      // Spaces within a line only: newlines end expressions, and `do … end` blocks can't be told from `do:` by tokens
      // alone for a re-indent. Where a space is meaning (`f (x)`, `f -1`, `%Point{`, `if(a, b)`), it stays as written.
      $0.layout = .spacing
      $0.parameters = .nameFirst
      $0.assignmentDeclares = true
      $0.declarations = [
        "defmodule": .module, "def": .function, "defp": .function, "defmacro": .function, "defmacrop": .function,
        "defguard": .function, "defguardp": .function, "defdelegate": .function, "defprotocol": .interface,
        "defimpl": .extension, "defstruct": .struct, "defexception": .struct, "@type": .typeAlias, "@typep": .typeAlias,
        "@opaque": .typeAlias, "@callback": .function, "@macrocallback": .function,
      ]
      $0.multilineStrings = true
      $0.identifierSuffixes = "!?"
      $0.colonSymbols = true
      $0.quotedSymbols = true
      $0.heredocsCloseAtLineStart = true
      $0.keywordsAsNames = true
      $0.tildeSigils = true
      $0.questionCharacters = true
      $0.suffixesBeforeEquals = true
      $0.interpolations = [Interpolation(open: "#{", close: 0x7D)]
      $0.bracesFollowTightly = true
      $0.spacesAfterControlWords = false
    },
    "JSON": LanguageRules {
      $0.layout = .full
      $0.outline = .jsonKeys
      $0.colonHugsLeft = true
      $0.spacesInsideBraces = true
    },
    "YAML": LanguageRules {
      $0.blocks = .indentation
      $0.outline = .yamlKeys
      $0.commentsNeedWordStart = true
      $0.reportsBrackets = false
    },
    "TOML": LanguageRules {
      $0.blocks = .none
      $0.outline = .tomlKeys
      $0.commentsNeedWordStart = true
      $0.extraIdentifierBytes = "-"
    },
    "HTML": LanguageRules {
      $0.blocks = .none
      $0.extraIdentifierBytes = "-"
      $0.reportsBrackets = false
    },
    "CSS": LanguageRules {
      $0.layout = .full
      $0.outline = .cssSelectors
      $0.extraIdentifierBytes = "-"
      $0.commentsNeedWordStart = true  // url(http://…).
      $0.spacesInsideBraces = true
    },
    "SQL": LanguageRules {
      $0.blocks = .none
      $0.declarations = ["table": .struct, "view": .struct, "function": .function, "procedure": .function, "index": .field]
    },
    "CQL": LanguageRules {
      $0.blocks = .none
      $0.declarations = ["table": .struct, "keyspace": .module, "type": .typeAlias]
    },
    "Redis": LanguageRules {
      $0.blocks = .none
      $0.reportsBrackets = false
    },
    "Markdown": LanguageRules {
      $0.blocks = .none
      $0.outline = .markdownHeadings
      $0.reportsBrackets = false
    },
    "Makefile": LanguageRules {
      $0.blocks = .none
      $0.outline = .makeTargets
      $0.dollarIsPunctuation = true
      $0.commentsNeedWordStart = true
      $0.extraIdentifierBytes = "-"
      $0.reportsBrackets = false
    },
    "Dockerfile": LanguageRules {
      $0.blocks = .none
      $0.outline = .dockerStages
      $0.dollarIsPunctuation = true
      $0.commentsNeedWordStart = true
      $0.reportsBrackets = false
    },
  ]

  private static func script(typed: Bool) -> LanguageRules {
    LanguageRules {
      $0.layout = .full
      $0.parameters = .nameFirst
      $0.bareMembers = true
      $0.arrowParameters = true
      $0.declarations = [
        "class": .class, "function": .function, "const": .constant, "let": .variable, "var": .variable,
      ]
      if typed {
        $0.declarations["interface"] = .interface
        $0.declarations["enum"] = .enum
        $0.declarations["type"] = .typeAlias
        $0.declarations["namespace"] = .module
        $0.declarations["module"] = .module
      }
      $0.interpolations = [Interpolation(open: "${", close: 0x7D, strings: ["`"])]
      $0.regexLiterals = true
      $0.newlineEndsStatements = true
      $0.spacesInsideBraces = true
      $0.trailingCommas = .allowed
      $0.colonHugsLeft = true
      $0.prefersDoubleQuotes = true
      $0.arrowIsSpaced = true
    }
  }

  private static func cFamily(raw: Bool) -> LanguageRules {
    LanguageRules {
      $0.layout = .full
      $0.parameters = .nameLast
      $0.typedDeclarations = true
      $0.declarations = controlInC
      $0.cppRawStrings = raw
      $0.memberOperators = ["->", "::"]
      $0.spacesAfterControlWords = false
      $0.outdentsLabels = true
      $0.flatNamespaces = true
      $0.followsFileStyle = true
    }
  }

  private static func fStrings(_ prefixes: [String]) -> [StringDelim] {
    prefixes.flatMap { prefix -> [StringDelim] in
      [
        StringDelim(open: prefix + "\"\"\"", close: "\"\"\"", multiline: true),
        StringDelim(open: prefix + "'''", close: "'''", multiline: true),
        StringDelim(open: prefix + "\"", close: "\""),
        StringDelim(open: prefix + "'", close: "'"),
      ]
    }
  }
}

/// The kinds a declaration can have; raw values are LSP's `SymbolKind`.
public enum SymbolKind: UInt8, Sendable {
  case module = 2
  case namespace = 3
  case `class` = 5
  case method = 6
  case property = 7
  case field = 8
  case constructor = 9
  case `enum` = 10
  case interface = 11
  case function = 12
  case variable = 13
  case constant = 14
  case key = 20
  case enumMember = 22
  case `struct` = 23
  case typeAlias = 26
  /// Adds to a type declared elsewhere (`extension Foo`, `impl Foo`): LSP's Namespace on the wire.
  case `extension` = 200

  public var isType: Bool {
    switch self {
    case .class, .enum, .interface, .struct, .typeAlias, .extension, .module, .namespace: return true
    default: return false
    }
  }

  public var isCallable: Bool {
    switch self {
    case .method, .constructor, .function: return true
    default: return false
    }
  }

  public var isValue: Bool {
    switch self {
    case .property, .field, .variable, .constant, .enumMember, .key: return true
    default: return false
    }
  }

  /// The number LSP knows it by.
  public var wire: UInt8 { self == .extension ? 3 : rawValue }
}
