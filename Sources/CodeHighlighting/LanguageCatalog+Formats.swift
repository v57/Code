import Foundation

/// Data, markup, style and build formats. Their coloring is regex-level and
/// approximate (HTML attributes are found by shape, CSS properties only at a
/// line start, Markdown emphasis without nesting), which reads well for
/// typical files.
extension LanguageCatalog {
  static let formats: [LanguageSpec] = [
    json, yaml, toml, html, css, sql, markdown, makefile, dockerfile,
  ]

  // MARK: - JSON

  /// JSON with comments allowed (JSONC: tsconfig.json, VS Code settings).
  static let json = LanguageSpec(
    name: "JSON", aliases: ["json", "jsonc", "json5", "geojson", "webmanifest"],
    lineComments: ["//"], blockComments: [("/*", "*/")], strings: [StringDelim(open: "\"")],
    keywords: ["true", "false", "null"], memberAccess: false,
    lineRules: [SyntaxRule(#"^\s*("(?:[^"\\]|\\.)*")\s*:"#, .otherMember)])

  // MARK: - YAML

  static let yaml = LanguageSpec(
    name: "YAML", aliases: ["yaml", "yml"], lineComments: ["#"],
    strings: [StringDelim(open: "\""), StringDelim(open: "'", escape: nil)],
    keywords: ["true", "false", "null", "yes", "no", "on", "off", "True", "False", "Null", "~"],
    memberAccess: false,
    lineRules: [
      SyntaxRule(#"^(---|\.\.\.)\s*$"#, .preprocessor, consumesLine: true),
      SyntaxRule(#"^\s*(?:-\s+)?([^\s#'"\-\[\]{}][^:#]*?|"[^"]*"|'[^']*')\s*:(?=\s|$)"#, .otherMember),
    ],
    inlineRules: [SyntaxRule(#"[&*!][A-Za-z0-9_\-!]+"#, .preprocessor)])

  // MARK: - TOML

  static let toml = LanguageSpec(
    name: "TOML", aliases: ["toml"], lineComments: ["#"],
    strings: [
      StringDelim(open: "\"\"\"", multiline: true),
      StringDelim(open: "'''", escape: nil, multiline: true), StringDelim(open: "\""),
      StringDelim(open: "'", escape: nil),
    ], keywords: ["true", "false", "inf", "nan"], memberAccess: false,
    lineRules: [
      SyntaxRule(#"^\s*(\[\[?[^\]]*\]\]?)"#, .typeDeclaration),
      SyntaxRule(#"^\s*([A-Za-z0-9_\-."]+)\s*="#, .otherMember),
    ])

  // MARK: - HTML / XML

  static let html = LanguageSpec(
    name: "HTML", aliases: ["html", "htm", "xhtml", "xml", "svg", "plist", "xib", "storyboard"],
    blockComments: [("<!--", "-->")], memberAccess: false, highlightsNumbers: false,
    inlineRules: [
      SyntaxRule(#"<![A-Za-z][^>]*>|<\?[^?]*\?>"#, .preprocessor),
      SyntaxRule(#"</?([A-Za-z][A-Za-z0-9:_\-.]*)"#, .keyword),
      SyntaxRule(#"\s([A-Za-z_:@][A-Za-z0-9_:.\-]*)(?=\s*=)"#, .otherMember),
      SyntaxRule(#"=\s*("[^"]*"|'[^']*')"#, .string),
      SyntaxRule(#"&[A-Za-z0-9#]+;"#, .number),
    ])

  // MARK: - CSS / SCSS / Less

  static let css = LanguageSpec(
    name: "CSS", aliases: ["css", "scss", "sass", "less"], lineComments: ["//"],
    blockComments: [("/*", "*/")], strings: [StringDelim(open: "\""), StringDelim(open: "'")],
    atWords: true, memberAccess: false, identifierPattern: #"-?[A-Za-z_][A-Za-z0-9_\-]*"#,
    lineRules: [SyntaxRule(#"^\s*(-{0,2}[A-Za-z][A-Za-z0-9\-]*)\s*:(?![^;{]*\{)"#, .otherMember)],
    inlineRules: [
      SyntaxRule(#"#[0-9a-fA-F]{3,8}\b"#, .number),
      SyntaxRule(#"[.#]-?[A-Za-z_][A-Za-z0-9_\-]*"#, .typeDeclaration),
      SyntaxRule(#"::?[A-Za-z][A-Za-z\-]*"#, .keyword),
      SyntaxRule(#"!important"#, .keyword),
      SyntaxRule(#"\$[A-Za-z_][A-Za-z0-9_\-]*"#, .otherMember),
    ])

  // MARK: - SQL

  static let sql = LanguageSpec(
    name: "SQL", aliases: ["sql", "mysql", "postgresql", "psql", "sqlite", "plsql"],
    lineComments: ["--"], blockComments: [("/*", "*/")],
    strings: [StringDelim(open: "'", escape: nil), StringDelim(open: "\"", escape: nil)],
    keywords: [
      "ADD", "ALL", "ALTER", "AND", "ANY", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASE", "CAST",
      "CHECK", "COLUMN", "COMMIT", "CONSTRAINT", "CREATE", "CROSS", "DATABASE", "DEFAULT",
      "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "EXISTS", "FALSE", "FOREIGN", "FROM",
      "FULL", "GROUP", "HAVING", "IF", "IN", "INDEX", "INNER", "INSERT", "INTO", "IS", "JOIN",
      "KEY", "LEFT", "LIKE", "LIMIT", "NOT", "NULL", "OFFSET", "ON", "OR", "ORDER", "OUTER",
      "PRIMARY", "REFERENCES", "RETURNING", "RIGHT", "ROLLBACK", "SELECT", "SET", "TABLE", "THEN",
      "TRANSACTION", "TRIGGER", "TRUE", "UNION", "UNIQUE", "UPDATE", "USING", "VALUES", "VIEW",
      "WHEN", "WHERE", "WITH", "INTEGER", "INT", "TEXT", "VARCHAR", "CHAR", "BOOLEAN", "REAL",
      "FLOAT", "DOUBLE", "DATE", "TIMESTAMP", "BLOB", "SERIAL", "AUTOINCREMENT", "REPLACE",
    ], keywordsCaseInsensitive: true)

  // MARK: - Markdown

  /// Fenced code blocks color as strings (the "```" delimiter is a multiline
  /// string), so a block's content never mixes with Markdown coloring.
  static let markdown = LanguageSpec(
    name: "Markdown", aliases: ["markdown", "md", "mdx", "mkd"], blockComments: [("<!--", "-->")],
    strings: [
      StringDelim(open: "```", escape: nil, multiline: true),
      StringDelim(open: "~~~", escape: nil, multiline: true), StringDelim(open: "`", escape: nil),
    ], memberAccess: false, highlightsNumbers: false,
    lineRules: [
      SyntaxRule(#"^(#{1,6}\s.*)$"#, .keyword, consumesLine: true),
      SyntaxRule(#"^\s{0,3}(>.*)$"#, .comment, consumesLine: true),
      SyntaxRule(#"^\s*([-*+]|\d+[.)])\s"#, .keyword),
      SyntaxRule(#"^\s{0,3}((?:[-*_]\s*){3,})$"#, .preprocessor, consumesLine: true),
    ],
    inlineRules: [
      SyntaxRule(#"!?\[[^\]]*\]\([^)]*\)"#, .link),
      SyntaxRule(#"\*\*[^*]+\*\*|__[^_]+__"#, .typeDeclaration),
      SyntaxRule(#"\*[^*\s][^*]*\*|(?<![A-Za-z0-9])_[^_\s][^_]*_(?![A-Za-z0-9])"#, .otherType),
    ])

  // MARK: - Makefile

  static let makefile = LanguageSpec(
    name: "Makefile", aliases: ["makefile", "make", "mk", "gnumakefile"], lineComments: ["#"],
    strings: [StringDelim(open: "\""), StringDelim(open: "'", escape: nil)],
    keywords: [
      "ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "-include", "define",
      "endef", "export", "unexport", "override", "private", "vpath",
    ], shellVars: true, memberAccess: false,
    lineRules: [
      SyntaxRule(#"^\s*([A-Za-z_][A-Za-z0-9_.]*)\s*(?::{1,2}|\+|\?|!)?="#, .otherMember),
      SyntaxRule(#"^([^\s:#=][^:#=]*?)\s*::?(?!=)"#, .memberDeclaration),
    ],
    inlineRules: [SyntaxRule(#"\$[({][^)}]*[)}]|\$[@<^+?*%]"#, .otherMember)])

  // MARK: - Dockerfile

  static let dockerfile = LanguageSpec(
    name: "Dockerfile", aliases: ["dockerfile", "docker", "containerfile"], lineComments: ["#"],
    strings: [StringDelim(open: "\""), StringDelim(open: "'", escape: nil)],
    keywords: [
      "FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER",
      "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL", "AS", "MAINTAINER",
    ], keywordsCaseInsensitive: true, shellVars: true, memberAccess: false,
    lineCommentsAtLineStartOnly: true)
}
