import Foundation

/// The 20 most-used languages, in GitHub Octoverse 2024 ranking order
/// (JavaScript, TypeScript, Python, Java, C#, C++, PHP, Shell, C, Ruby, Rust,
/// Go, Kotlin, Dart, Swift, Objective-C, Scala, PowerShell, Lua, Haskell),
/// followed by the data, markup and build formats a project folder also holds
/// (LanguageCatalog+Formats.swift).
public enum LanguageCatalog {
  public static let all: [LanguageSpec] = [
    javascript, typescript, python, java, csharp, cpp, php, shell, c, ruby, rust, go, kotlin, dart,
    swift, objectiveC, scala, powershell, lua, haskell,
  ] + formats

  // MARK: - JavaScript

  static let javascript = LanguageSpec(
    name: "JavaScript", aliases: ["javascript", "js", "jsx", "mjs", "node", "ecmascript"],
    lineComments: ["//"], blockComments: [("/*", "*/")],
    strings: [
      StringDelim(open: "`", multiline: true), StringDelim(open: "\""), StringDelim(open: "'"),
    ],
    keywords: [
      "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do",
      "else", "export", "extends", "false", "finally", "for", "function", "if", "import", "in",
      "instanceof", "new", "null", "return", "super", "switch", "this", "throw", "true", "try",
      "typeof", "var", "void", "while", "with", "yield", "async", "await", "let", "static", "get",
      "set", "of", "from", "undefined",
    ], declKeywords: ["class": .typeDeclaration, "function": .memberDeclaration])

  // MARK: - TypeScript

  static let typescript = LanguageSpec(
    name: "TypeScript", aliases: ["typescript", "ts", "tsx"], lineComments: ["//"],
    blockComments: [("/*", "*/")],
    strings: [
      StringDelim(open: "`", multiline: true), StringDelim(open: "\""), StringDelim(open: "'"),
    ],
    keywords: [
      "break", "case", "catch", "class", "const", "continue", "debugger", "declare", "default",
      "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "function",
      "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let", "module",
      "namespace", "new", "null", "private", "protected", "public", "readonly", "return", "static",
      "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var",
      "void", "while", "with", "yield", "async", "await", "abstract", "as", "unknown", "never",
      "any", "boolean", "number", "string", "symbol", "object", "infer", "is", "satisfies", "get",
      "set", "of", "from",
    ],
    declKeywords: [
      "class": .typeDeclaration, "interface": .typeDeclaration, "enum": .typeDeclaration,
      "type": .typeDeclaration, "function": .memberDeclaration,
    ], capitalizedIsType: true)

  // MARK: - Python

  static let python = LanguageSpec(
    name: "Python", aliases: ["python", "py", "python3", "py3", "python2"], lineComments: ["#"],
    strings: [
      StringDelim(open: "\"\"\"", multiline: true), StringDelim(open: "'''", multiline: true),
      StringDelim(open: "\""), StringDelim(open: "'"),
    ],
    keywords: [
      "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
      "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is",
      "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while",
      "with", "yield",
    ], declKeywords: ["class": .typeDeclaration, "def": .memberDeclaration])

  // MARK: - Java

  static let java = LanguageSpec(
    name: "Java", aliases: ["java"], lineComments: ["//"], blockComments: [("/*", "*/")],
    strings: [StringDelim(open: "\"")], charLiteral: "'",
    keywords: [
      "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const",
      "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float",
      "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long",
      "native", "new", "package", "private", "protected", "public", "return", "short", "static",
      "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "try",
      "void", "volatile", "while", "true", "false", "null", "record", "var", "yield", "sealed",
      "permits", "non-sealed", "default",
    ],
    declKeywords: [
      "class": .typeDeclaration, "interface": .typeDeclaration, "enum": .typeDeclaration,
      "record": .typeDeclaration,
    ], atWords: true, capitalizedIsType: true)

  // MARK: - C#

  static let csharp = LanguageSpec(
    name: "C#", aliases: ["csharp", "c#", "cs"], lineComments: ["//"],
    blockComments: [("/*", "*/")],
    strings: [StringDelim(open: "@\"", close: "\"", escape: "\""), StringDelim(open: "\"")],
    charLiteral: "'",
    keywords: [
      "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char", "checked",
      "class", "const", "continue", "decimal", "default", "delegate", "do", "double", "else",
      "enum", "event", "explicit", "extern", "false", "finally", "fixed", "float", "for", "foreach",
      "goto", "if", "implicit", "in", "int", "interface", "internal", "is", "lock", "long",
      "namespace", "new", "null", "object", "operator", "out", "override", "params", "private",
      "protected", "public", "readonly", "ref", "return", "sbyte", "sealed", "short", "sizeof",
      "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true", "try",
      "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort", "using", "virtual", "void",
      "volatile", "while", "async", "await", "var", "dynamic", "get", "set", "value", "nameof",
      "record", "required", "init", "file",
    ],
    declKeywords: [
      "class": .typeDeclaration, "interface": .typeDeclaration, "struct": .typeDeclaration,
      "enum": .typeDeclaration, "record": .typeDeclaration,
    ], hashDirectives: true, hashDirectivesAnchored: true, capitalizedIsType: true)

  // MARK: - C++

  static let cpp = LanguageSpec(
    name: "C++", aliases: ["cpp", "c++", "cc", "hpp", "hxx", "cxx", "cplusplus"],
    lineComments: ["//"], blockComments: [("/*", "*/")], strings: [StringDelim(open: "\"")],
    charLiteral: "'",
    keywords: [
      "alignas", "alignof", "and", "and_eq", "asm", "auto", "bitand", "bitor", "bool", "break",
      "case", "catch", "char", "char16_t", "char32_t", "class", "compl", "concept", "const",
      "constexpr", "const_cast", "continue", "decltype", "default", "delete", "do", "double",
      "dynamic_cast", "else", "enum", "explicit", "export", "extern", "false", "float", "for",
      "friend", "goto", "if", "inline", "int", "long", "mutable", "namespace", "new", "noexcept",
      "not", "not_eq", "nullptr", "operator", "or", "or_eq", "private", "protected", "public",
      "register", "reinterpret_cast", "requires", "return", "short", "signed", "sizeof", "static",
      "static_assert", "static_cast", "struct", "switch", "template", "this", "thread_local",
      "throw", "true", "try", "typedef", "typeid", "typename", "union", "unsigned", "using",
      "virtual", "void", "volatile", "wchar_t", "while", "xor", "xor_eq", "final", "override",
      "NULL",
    ],
    declKeywords: [
      "class": .typeDeclaration, "struct": .typeDeclaration, "enum": .typeDeclaration,
      "union": .typeDeclaration, "typename": .typeDeclaration, "concept": .typeDeclaration,
    ], hashDirectives: true, hashDirectivesAnchored: true, memberAccess: false, headerStrings: true)

  // MARK: - PHP

  static let php = LanguageSpec(
    name: "PHP", aliases: ["php"], lineComments: ["//", "#"], blockComments: [("/*", "*/")],
    strings: [StringDelim(open: "\""), StringDelim(open: "'")],
    keywords: [
      "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone",
      "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty",
      "enddeclare", "endfor", "endforeach", "endif", "endswitch", "endwhile", "enum", "exit", "die",
      "extends", "final", "finally", "fn", "for", "foreach", "function", "global", "goto", "if",
      "implements", "include", "include_once", "instanceof", "insteadof", "interface", "isset",
      "list", "match", "namespace", "new", "or", "print", "private", "protected", "public",
      "readonly", "require", "require_once", "return", "static", "switch", "throw", "trait", "try",
      "unset", "use", "var", "while", "xor", "yield", "true", "false", "null",
    ],
    declKeywords: [
      "class": .typeDeclaration, "interface": .typeDeclaration, "trait": .typeDeclaration,
      "enum": .typeDeclaration, "function": .memberDeclaration,
    ], shellVars: true)

  // MARK: - Shell (Bash/Zsh)

  static let shell = LanguageSpec(
    name: "Shell", aliases: ["sh", "shell", "bash", "zsh", "ksh", "fish"], lineComments: ["#"],
    strings: [StringDelim(open: "\""), StringDelim(open: "'")],
    keywords: [
      "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac",
      "in", "function", "select", "time", "coproc", "return", "break", "continue", "local",
      "declare", "export", "readonly", "set", "unset", "shift", "trap", "exit", "echo", "printf",
      "true", "false",
    ], declKeywords: ["function": .memberDeclaration], shellVars: true)

  // MARK: - C

  static let c = LanguageSpec(
    name: "C", aliases: ["c", "h"], lineComments: ["//"], blockComments: [("/*", "*/")],
    strings: [StringDelim(open: "\"")], charLiteral: "'",
    keywords: [
      "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else",
      "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register",
      "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef",
      "union", "unsigned", "void", "volatile", "while", "_Bool", "_Complex", "_Imaginary", "true",
      "false", "NULL",
    ],
    declKeywords: [
      "struct": .typeDeclaration, "enum": .typeDeclaration, "union": .typeDeclaration,
      "typedef": .typeDeclaration,
    ], hashDirectives: true, hashDirectivesAnchored: true, memberAccess: false, headerStrings: true)

  // MARK: - Ruby

  static let ruby = LanguageSpec(
    name: "Ruby", aliases: ["ruby", "rb", "gemfile"], lineComments: ["#"],
    strings: [StringDelim(open: "\""), StringDelim(open: "'")],
    keywords: [
      "BEGIN", "END", "__FILE__", "__LINE__", "alias", "and", "begin", "break", "case", "class",
      "def", "defined?", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in",
      "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super",
      "then", "true", "undef", "unless", "until", "when", "while", "yield",
    ],
    declKeywords: [
      "class": .typeDeclaration, "module": .typeDeclaration, "def": .memberDeclaration,
    ], shellVars: true)

  // MARK: - Rust

  static let rust = LanguageSpec(
    name: "Rust", aliases: ["rust", "rs"], lineComments: ["//"], blockComments: [("/*", "*/")],
    nestedBlockComments: true,
    strings: [StringDelim(open: "r#\"", close: "\"#", escape: nil), StringDelim(open: "\"")],
    charLiteral: "'",
    keywords: [
      "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
      "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move",
      "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true",
      "type", "unsafe", "use", "where", "while", "abstract", "become", "box", "do", "final",
      "macro", "override", "priv", "typeof", "unsized", "virtual", "yield", "try",
    ],
    declKeywords: [
      "fn": .memberDeclaration, "struct": .typeDeclaration, "enum": .typeDeclaration,
      "trait": .typeDeclaration, "impl": .typeDeclaration, "type": .typeDeclaration,
      "mod": .typeDeclaration,
    ], rustAttributes: true, capitalizedIsType: true)

  // MARK: - Go

  static let go = LanguageSpec(
    name: "Go", aliases: ["go", "golang"], lineComments: ["//"], blockComments: [("/*", "*/")],
    strings: [StringDelim(open: "`", escape: nil, multiline: true), StringDelim(open: "\"")],
    charLiteral: "'",
    keywords: [
      "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
      "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return",
      "select", "struct", "switch", "type", "var", "true", "false", "nil", "iota",
    ],
    declKeywords: [
      "func": .memberDeclaration, "type": .typeDeclaration, "struct": .typeDeclaration,
      "interface": .typeDeclaration,
    ], capitalizedIsType: true)

  // MARK: - Kotlin

  static let kotlin = LanguageSpec(
    name: "Kotlin", aliases: ["kotlin", "kt", "kts"], lineComments: ["//"],
    blockComments: [("/*", "*/")],
    strings: [StringDelim(open: "\"\"\"", multiline: true), StringDelim(open: "\"")],
    keywords: [
      "as", "break", "class", "companion", "const", "constructor", "continue", "crossinline",
      "data", "do", "else", "enum", "expect", "external", "false", "final", "finally", "for", "fun",
      "if", "import", "in", "infix", "init", "inline", "interface", "internal", "is", "lateinit",
      "noinline", "null", "object", "open", "operator", "out", "override", "package", "private",
      "protected", "public", "reified", "return", "sealed", "set", "super", "suspend", "tailrec",
      "this", "throw", "true", "try", "typealias", "typeof", "val", "var", "vararg", "when",
      "where", "while", "by", "catch", "dynamic", "get", "value",
    ],
    declKeywords: [
      "class": .typeDeclaration, "interface": .typeDeclaration, "enum": .typeDeclaration,
      "object": .typeDeclaration, "typealias": .typeDeclaration, "fun": .memberDeclaration,
    ], atWords: true, capitalizedIsType: true)

  // MARK: - Dart

  static let dart = LanguageSpec(
    name: "Dart", aliases: ["dart"], lineComments: ["//"], blockComments: [("/*", "*/")],
    strings: [
      StringDelim(open: "\"\"\"", multiline: true), StringDelim(open: "'''", multiline: true),
      StringDelim(open: "\""), StringDelim(open: "'"),
    ],
    keywords: [
      "abstract", "as", "assert", "async", "await", "break", "case", "catch", "class", "const",
      "continue", "covariant", "default", "deferred", "do", "dynamic", "else", "enum", "export",
      "extends", "extension", "external", "factory", "false", "final", "finally", "for", "Function",
      "get", "hide", "if", "implements", "import", "in", "interface", "is", "late", "library",
      "mixin", "new", "null", "on", "operator", "part", "required", "rethrow", "return", "set",
      "show", "static", "super", "switch", "sync", "this", "throw", "true", "try", "typedef", "var",
      "void", "while", "with", "yield",
    ],
    declKeywords: [
      "class": .typeDeclaration, "mixin": .typeDeclaration, "enum": .typeDeclaration,
      "extension": .typeDeclaration, "typedef": .typeDeclaration,
    ], capitalizedIsType: true)

  // MARK: - Swift

  static let swift = LanguageSpec(
    name: "Swift", aliases: ["swift"], lineComments: ["//"], blockComments: [("/*", "*/")],
    nestedBlockComments: true,
    strings: [
      StringDelim(open: "\"\"\"", multiline: true),
      StringDelim(open: "#\"", close: "\"#", escape: nil), StringDelim(open: "\""),
    ],
    keywords: [
      "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import",
      "init", "inout", "internal", "let", "open", "operator", "private", "precedencegroup",
      "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var",
      "actor", "async", "await", "borrowing", "consuming", "convenience", "distributed", "dynamic",
      "didSet", "get", "indirect", "infix", "isolated", "lazy", "mutating", "nonisolated",
      "override", "postfix", "prefix", "required", "set", "some", "unsafe", "weak", "willSet",
      "where", "throws", "try", "catch", "as", "is", "do", "else", "for", "guard", "if", "in",
      "repeat", "return", "switch", "while", "break", "case", "continue", "default", "defer",
      "fallthrough", "true", "false", "nil", "self", "Self", "Any", "any", "final", "package",
      "macro", "sending", "consume", "copy", "discard", "each",
    ],
    declKeywords: [
      "class": .typeDeclaration, "struct": .typeDeclaration, "enum": .typeDeclaration,
      "protocol": .typeDeclaration, "actor": .typeDeclaration, "extension": .typeDeclaration,
      "typealias": .typeDeclaration, "func": .memberDeclaration, "init": .memberDeclaration,
      "subscript": .memberDeclaration,
    ], hashDirectives: true, hashDirectivesAnchored: false, atWords: true, capitalizedIsType: true)

  // MARK: - Objective-C

  static let objectiveC = LanguageSpec(
    name: "Objective-C", aliases: ["objectivec", "objective-c", "objc", "obj-c", "m", "mm"],
    lineComments: ["//"], blockComments: [("/*", "*/")],
    strings: [StringDelim(open: "@\"", close: "\""), StringDelim(open: "\"")], charLiteral: "'",
    keywords: [
      "BOOL", "break", "case", "char", "Class", "const", "continue", "default", "do", "double",
      "else", "enum", "extern", "float", "for", "goto", "id", "if", "in", "instancetype", "int",
      "long", "nil", "Nil", "NO", "NULL", "return", "SEL", "self", "short", "signed", "sizeof",
      "static", "struct", "super", "switch", "typedef", "union", "unsigned", "void", "volatile",
      "while", "YES", "true", "false", "nonnull", "nullable", "null_resettable", "null_unspecified",
    ], declKeywords: ["protocol": .typeDeclaration], hashDirectives: true,
    hashDirectivesAnchored: true, atWords: true, capitalizedIsType: true, headerStrings: true)

  // MARK: - Scala

  static let scala = LanguageSpec(
    name: "Scala", aliases: ["scala", "sc"], lineComments: ["//"], blockComments: [("/*", "*/")],
    strings: [StringDelim(open: "\"\"\"", multiline: true), StringDelim(open: "\"")],
    charLiteral: "'",
    keywords: [
      "abstract", "case", "catch", "class", "def", "do", "else", "enum", "export", "extends",
      "false", "final", "finally", "for", "forSome", "given", "if", "implicit", "import", "lazy",
      "match", "new", "null", "object", "opaque", "override", "package", "private", "protected",
      "return", "sealed", "super", "this", "throw", "trait", "true", "try", "type", "using", "val",
      "var", "while", "with", "yield",
    ],
    declKeywords: [
      "class": .typeDeclaration, "trait": .typeDeclaration, "object": .typeDeclaration,
      "enum": .typeDeclaration, "type": .typeDeclaration, "def": .memberDeclaration,
    ], capitalizedIsType: true)

  // MARK: - PowerShell

  static let powershell = LanguageSpec(
    name: "PowerShell", aliases: ["powershell", "ps1", "posh", "pwsh"], lineComments: ["#"],
    strings: [StringDelim(open: "\""), StringDelim(open: "'")],
    keywords: [
      "begin", "break", "catch", "class", "continue", "data", "define", "do", "dynamicparam",
      "else", "elseif", "end", "enum", "exit", "filter", "finally", "for", "foreach", "from",
      "function", "if", "in", "param", "process", "return", "static", "switch", "throw", "trap",
      "try", "until", "using", "var", "while", "workflow", "parallel", "sequence", "clean",
      "hidden", "not", "and", "or", "xor", "eq", "ne", "lt", "le", "gt", "ge", "true", "false",
      "null",
    ],
    declKeywords: [
      "function": .memberDeclaration, "class": .typeDeclaration, "enum": .typeDeclaration,
    ], shellVars: true)

  // MARK: - Lua

  static let lua = LanguageSpec(
    name: "Lua", aliases: ["lua"], lineComments: ["--"], blockComments: [("--[[", "]]")],
    strings: [StringDelim(open: "\""), StringDelim(open: "'")],
    keywords: [
      "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
      "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
    ], declKeywords: ["function": .memberDeclaration])

  // MARK: - Haskell

  static let haskell = LanguageSpec(
    name: "Haskell", aliases: ["haskell", "hs"], lineComments: ["--"],
    blockComments: [("{-", "-}")], strings: [StringDelim(open: "\"")], charLiteral: "'",
    keywords: [
      "as", "case", "class", "data", "default", "deriving", "do", "else", "foreign", "forall",
      "hiding", "if", "import", "in", "infix", "infixl", "infixr", "instance", "let", "mdo",
      "module", "newtype", "of", "otherwise", "pattern", "qualified", "role", "stock", "then",
      "type", "where", "anyclass", "family", "static", "via",
    ],
    declKeywords: [
      "data": .typeDeclaration, "newtype": .typeDeclaration, "type": .typeDeclaration,
      "class": .typeDeclaration, "instance": .typeDeclaration,
    ], capitalizedIsType: true)
}
