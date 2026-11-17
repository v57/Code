import Foundation

/// Zig and Elixir: languages Code formats with their own tools (`zig fmt`, `mix format`) and now colors, scans and
/// indexes too.
extension LanguageCatalog {
  // MARK: - Zig

  /// Zig 0.14. `\\` starts a multiline string's line, which runs to the line's end; `@import` and the other builtins
  /// are `@` words; `const Point = struct {` names a type with no keyword before its name, so a rule colors it.
  static let zig = LanguageSpec(
    name: "Zig", aliases: ["zig", "zon"], lineComments: ["//"],
    strings: [StringDelim(open: "\\\\", close: "\n", escape: nil), StringDelim(open: "\"")], charLiteral: "'",
    keywords: [
      "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await", "break", "callconv",
      "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export", "extern", "fn",
      "for", "if", "inline", "linksection", "noalias", "noinline", "nosuspend", "opaque", "or", "orelse", "packed",
      "pub", "resume", "return", "struct", "suspend", "switch", "test", "threadlocal", "try", "union", "unreachable",
      "usingnamespace", "var", "volatile", "while", "true", "false", "null", "undefined",
    ],
    declKeywords: ["fn": .memberDeclaration], atWords: true, capitalizedIsType: true,
    inlineRules: [
      SyntaxRule(
        #"[A-Za-z_][A-Za-z0-9_]*(?=\s*=\s*(?:(?:extern|packed)\s+)?(?:struct|enum|union|opaque)\b|\s*=\s*error\s*\{)"#,
        .typeDeclaration)
    ])

  // MARK: - Elixir

  /// Elixir 1.17. Every string interpolates `#{…}`, may span lines and has a heredoc form (`"""`, `'''`); sigils
  /// (`~r/…/i`, `~s(…)`, `~w[…]a`, `~S"""…"""`), `?a` characters and atoms (`:ok`, `:"a b"`, `key:`) are colored by
  /// rules; `@doc` and the other module attributes are `@` words. A name may end in `?` or `!`.
  static let elixir = LanguageSpec(
    name: "Elixir", aliases: ["elixir", "ex", "exs", "iex"], lineComments: ["#"],
    strings: [
      StringDelim(open: "\"\"\"", multiline: true), StringDelim(open: "'''", multiline: true),
      StringDelim(open: "\"", multiline: true), StringDelim(open: "'", multiline: true),
    ],
    keywords: [
      "true", "false", "nil", "when", "and", "or", "not", "in", "fn", "do", "end", "catch", "rescue", "after", "else",
      "case", "cond", "if", "unless", "with", "for", "receive", "try", "raise", "reraise", "throw", "quote", "unquote",
      "unquote_splicing", "import", "require", "alias", "use", "defmodule", "def", "defp", "defmacro", "defmacrop",
      "defguard", "defguardp", "defdelegate", "defprotocol", "defimpl", "defstruct", "defexception", "defoverridable",
      "__MODULE__", "__DIR__", "__ENV__", "__CALLER__", "__STACKTRACE__",
    ],
    declKeywords: [
      "defmodule": .typeDeclaration, "defprotocol": .typeDeclaration, "defimpl": .typeDeclaration,
      "def": .memberDeclaration, "defp": .memberDeclaration, "defmacro": .memberDeclaration,
      "defmacrop": .memberDeclaration, "defguard": .memberDeclaration, "defguardp": .memberDeclaration,
      "defdelegate": .memberDeclaration,
    ], atWords: true, capitalizedIsType: true, identifierPattern: "[A-Za-z_][A-Za-z0-9_]*[?!]?",
    inlineRules: [
      // A heredoc sigil's letters; its quotes are the string's.
      SyntaxRule(#"~(?:[a-z]|[A-Z][A-Z0-9]*)(?="""|''')"#, .string),
      SyntaxRule(
        #"~(?:[a-z]|[A-Z][A-Z0-9]*)(?:\((?:[^)\\]|\\.)*\)|\[(?:[^\]\\]|\\.)*\]|\{(?:[^}\\]|\\.)*\}|<(?:[^>\\]|\\.)*>|/(?:[^/\\]|\\.)*/|\|(?:[^|\\]|\\.)*\||"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')[A-Za-z0-9]*"#,
        .string),
      SyntaxRule(#"\?(?:\\.|[^\s\\])"#, .string),
      SyntaxRule(#":(?:[A-Za-z_][A-Za-z0-9_@]*[?!]?|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')"#, .string),
      // `key: value`: the key is an atom.
      SyntaxRule(#"[A-Za-z_][A-Za-z0-9_]*[?!]?:(?=\s)"#, .string),
    ])
}
