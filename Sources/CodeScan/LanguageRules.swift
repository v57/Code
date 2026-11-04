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
  /// Identifier bytes besides letters, digits and `_` (`-` in CSS, `!` and `?` in Ruby).
  public var extraIdentifierBytes = ""
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
          open: "{", close: 0x7D, doubledIsLiteral: true, strings: Set(fStrings(["f", "F", "rf", "fr"]).map(\.open)))
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
      $0.multilineStrings = true
      $0.dollarIsPunctuation = true
      $0.assignmentDeclares = true
      $0.interpolations = [Interpolation(open: "{$", close: 0x7D, strings: ["\""])]
      $0.trailingCommas = .allowed
    },
    "Shell": LanguageRules {
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
      $0.dollarIsPunctuation = true
      $0.extraIdentifierBytes = "!?"
      $0.interpolations = [Interpolation(open: "#{", close: 0x7D, strings: ["\""])]
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
    },
    "PowerShell": LanguageRules {
      $0.layout = .lines
      $0.parameters = .nameLast
      $0.assignmentDeclares = true
      $0.declarations = ["function": .function, "class": .class, "enum": .enum]
      $0.dollarIsPunctuation = true
      $0.multilineStrings = true
      $0.extraIdentifierBytes = "-"
      $0.interpolations = [Interpolation(open: "$(", close: 0x29, strings: ["\""])]
      $0.newlineEndsStatements = true
      $0.reportsBrackets = false
    },
    "Lua": LanguageRules {
      $0.blocks = .indentation
      $0.layout = .spacing
      $0.parameters = .nameFirst
      $0.assignmentDeclares = true
      $0.declarations = ["function": .function, "local": .variable]
    },
    "Haskell": LanguageRules {
      $0.blocks = .indentation
      $0.signatureDeclares = true
      $0.declarations = [
        "data": .struct, "newtype": .struct, "type": .typeAlias, "class": .interface, "instance": .extension,
        "module": .module,
      ]
      $0.reportsBrackets = false
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
