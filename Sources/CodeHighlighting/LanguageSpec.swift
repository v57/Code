import Foundation

/// One language configuration for the regex-based code scanner: comment and string
/// forms, keyword sets, declaration patterns, and preprocessor conventions.
public struct LanguageSpec: Sendable {
  /// Canonical display name, e.g. "Swift".
  public let name: String
  /// Fence info-string aliases, lowercased, e.g. ["swift"] or ["js", "javascript"].
  public let aliases: [String]

  /// Line comment markers, e.g. ["//"] for the C family, ["#"] for Python/Shell.
  public var lineComments: [String] = []
  /// Block comment pairs, e.g. [("/*", "*/")]. Checked BEFORE line comments so
  /// Lua's "--[[ ... ]]" wins over "--".
  public var blockComments: [(open: String, close: String)] = []
  /// Whether block comments nest (Swift: /* /* */ */). Non-nesting languages
  /// close at the first close marker.
  public var nestedBlockComments = false

  /// String literal forms (longest open is tried first at scan time).
  public var strings: [StringDelim] = []
  /// Character literal delimiter (C family "'"). Needs a close on the SAME line;
  /// a lone apostrophe (Rust lifetimes 'a) stays plain text.
  public var charLiteral: Character? = nil

  /// Reserved words. Case-sensitive unless `keywordsCaseInsensitive` (SQL).
  public var keywords: Set<String> = []
  /// Match keywords case-insensitively (SQL is conventionally uppercased).
  public var keywordsCaseInsensitive = false
  /// Declaration keywords and the kind their following name gets:
  /// "class" → .typeDeclaration, "func" → .memberDeclaration, ...
  public var declKeywords: [String: SyntaxKind] = [:]

  /// '#'-directives (`#include`, `#if`, `#region`). `hashDirectivesAnchored`
  /// requires the directive to start the line (C family); free-standing matches
  /// any `#word` (Swift's `#available`, `#selector`, `#if`).
  public var hashDirectives = false
  public var hashDirectivesAnchored = true
  /// '@'-words (`@available`, `@interface`, `@Override`) → preprocessor.
  public var atWords = false
  /// Rust attributes `#[...]` / `#![...]` → preprocessor.
  public var rustAttributes = false

  /// Capitalized identifiers are type references (Swift/Java/C#/Kotlin/...).
  public var capitalizedIsType = false
  /// `$name` / `${name}` are variables (Shell/PHP/Perl/Ruby/PowerShell).
  public var shellVars = false
  /// `.name` accesses are otherMembers. Off for C/C++ where header names
  /// (`#include <stdio.h>`) and struct fields would produce noise.
  public var memberAccess = true
  /// After a #include/#import directive, `<header.h>` contents are strings
  /// (GitHub colors header names as strings). C family only.
  public var headerStrings = false

  /// Identifier regex override, e.g. allowing "-" in CSS property names.
  /// Defaults to `[A-Za-z_$][A-Za-z0-9_$]*`.
  public var identifierPattern: String? = nil
  /// Line comment markers count only at the start of a line (after
  /// indentation): YAML/TOML/Makefile "#" may appear inside values.
  public var lineCommentsAtLineStartOnly = false
  /// Numeric literals are colored. Off for prose-like formats (HTML, Markdown)
  /// where digits are text.
  public var highlightsNumbers = true
  /// Rules tried once at the start of each line, first match wins: Markdown
  /// headings, YAML keys, Makefile targets, Dockerfile instructions.
  public var lineRules: [SyntaxRule] = []
  /// Rules tried at every position after strings and URLs and before
  /// numbers: HTML tags, CSS selectors, Markdown emphasis.
  public var inlineRules: [SyntaxRule] = []

  /// Memberwise initializer with the same parameter order and defaults as the
  /// implicit memberwise init.
  public init(
    name: String, aliases: [String], lineComments: [String] = [],
    blockComments: [(open: String, close: String)] = [], nestedBlockComments: Bool = false,
    strings: [StringDelim] = [], charLiteral: Character? = nil, keywords: Set<String> = [],
    keywordsCaseInsensitive: Bool = false, declKeywords: [String: SyntaxKind] = [:],
    hashDirectives: Bool = false, hashDirectivesAnchored: Bool = true, atWords: Bool = false,
    rustAttributes: Bool = false, capitalizedIsType: Bool = false, shellVars: Bool = false,
    memberAccess: Bool = true, headerStrings: Bool = false, identifierPattern: String? = nil,
    lineCommentsAtLineStartOnly: Bool = false, highlightsNumbers: Bool = true, lineRules: [SyntaxRule] = [],
    inlineRules: [SyntaxRule] = []
  ) {
    self.name = name
    self.aliases = aliases
    self.lineComments = lineComments
    self.blockComments = blockComments
    self.nestedBlockComments = nestedBlockComments
    self.strings = strings
    self.charLiteral = charLiteral
    self.keywords = keywords
    self.keywordsCaseInsensitive = keywordsCaseInsensitive
    self.declKeywords = declKeywords
    self.hashDirectives = hashDirectives
    self.hashDirectivesAnchored = hashDirectivesAnchored
    self.atWords = atWords
    self.rustAttributes = rustAttributes
    self.capitalizedIsType = capitalizedIsType
    self.shellVars = shellVars
    self.memberAccess = memberAccess
    self.headerStrings = headerStrings
    self.identifierPattern = identifierPattern
    self.lineCommentsAtLineStartOnly = lineCommentsAtLineStartOnly
    self.highlightsNumbers = highlightsNumbers
    self.lineRules = lineRules
    self.inlineRules = inlineRules
  }
}

/// A quoted string form. `open`/`close` are usually equal ("\""), but differ for
/// raw strings (Swift #"..."#, Rust r#"..."#, C# @"..."). `escape` is the
/// character that escapes the next character inside the string (nil = raw).
public struct StringDelim: Sendable {
  public let open: String
  public let close: String
  public let escape: Character?
  public let multiline: Bool  // may span lines (Swift """...""", JS `...`, Go `...`)

  public init(
    open: String, close: String? = nil, escape: Character? = "\\", multiline: Bool = false
  ) {
    self.open = open
    self.close = close ?? open
    self.escape = escape
    self.multiline = multiline
  }
}

/// A regex that colors what it matches. When the pattern has a capture group,
/// only group 1 is colored, but the scanner still skips the whole match (so
/// `^(\w+):` colors a YAML key without its colon).
public struct SyntaxRule: Sendable {
  public let pattern: String
  public let kind: SyntaxKind
  /// The rest of the line is not scanned after a match (Markdown headings).
  public let consumesLine: Bool

  public init(_ pattern: String, _ kind: SyntaxKind, consumesLine: Bool = false) {
    self.pattern = pattern
    self.kind = kind
    self.consumesLine = consumesLine
  }
}
