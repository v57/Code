import Foundation
import Testing

@testable import CodeHighlighting

// MARK: - Code syntax highlighting (CodeHighlighter / CodeScanner / LanguageCatalog)

/// Kind of the innermost token covering `offset` in `code` (overlapping tokens
/// exist: a URL inside a comment is a link token inside the comment token).
private func kindAt(_ code: String, _ language: String, _ offset: Int) -> SyntaxKind? {
  CodeHighlighter.tokens(in: code, language: language).last { NSLocationInRange(offset, $0.range) }?
    .kind
}

@Suite struct CodeHighlightingTests {
  // MARK: - Language resolution from fence info strings

  @Test func languageAliasResolution() {
    #expect(CodeHighlighter.spec(forLanguage: "py")?.name == "Python")
    #expect(CodeHighlighter.spec(forLanguage: "c++")?.name == "C++")
    #expect(CodeHighlighter.spec(forLanguage: "objective-c")?.name == "Objective-C")
    #expect(CodeHighlighter.spec(forLanguage: "TypeScript")?.name == "TypeScript")
    #expect(CodeHighlighter.spec(forLanguage: "swift linenums")?.name == "Swift")
    #expect(CodeHighlighter.spec(forLanguage: "language-python")?.name == "Python")
    #expect(CodeHighlighter.spec(forLanguage: "klingon") == nil)
    #expect(CodeHighlighter.all.count == 29)
    #expect(Set(CodeHighlighter.all.map(\.name)).count == CodeHighlighter.all.count)
    let names = Set(CodeHighlighter.all.map { $0.name })
    #expect(
      [
        "JavaScript", "TypeScript", "Python", "Java", "C#", "C++", "PHP", "Shell", "C", "Ruby",
        "Rust", "Go", "Kotlin", "Dart", "Swift", "Objective-C", "Scala", "PowerShell", "Lua",
        "Haskell",
      ].allSatisfy { names.contains($0) })
    #expect(CodeHighlighter.spec(forLanguage: "plaintext") == nil)
  }

  // MARK: - Swift lexing: keywords, declarations, types, strings, comments, links

  @Test func swiftLexing() {
    let sw =
      "func greet(name: String) -> String {\n    let msg = \"Hello, \\(name)!\"   // hi https://example.com\n    return msg\n}\n"
    let swNs = sw as NSString
    #expect(kindAt(sw, "swift", swNs.range(of: "func").location) == .keyword)
    #expect(kindAt("func", "swift", 0) == .keyword)
    #expect(kindAt(sw, "swift", swNs.range(of: "greet").location) == .memberDeclaration)
    #expect(kindAt(sw, "swift", swNs.range(of: "String").location) == .otherType)
    #expect(kindAt(sw, "swift", swNs.range(of: "Hello").location) == .string)
    #expect(kindAt(sw, "swift", swNs.range(of: "hi").location) == .comment)
    #expect(kindAt(sw, "swift", swNs.range(of: "https://").location) == .link)
    #expect(
      kindAt(sw, "swift", swNs.range(of: "let").location) == .keyword
        && kindAt(sw, "swift", swNs.range(of: "return").location) == .keyword)

    let nums = "let n = 42, f = 3.14, h = 0xFF, b = 0b1010"
    #expect(kindAt(nums, "swift", (nums as NSString).range(of: "42").location) == .number)
    #expect(kindAt(nums, "swift", (nums as NSString).range(of: "3.14").location) == .number)
    #expect(kindAt(nums, "swift", (nums as NSString).range(of: "0xFF").location) == .number)
    #expect(kindAt(nums, "swift", (nums as NSString).range(of: "0b1010").location) == .number)
  }

  // MARK: - Doc comments: /// markers are comments, prose is prose

  @Test func swiftDocComments() {
    let doc = "/// Docs for foo\nfunc foo() {}"
    #expect(kindAt(doc, "swift", (doc as NSString).range(of: "///").location) == .comment)
    #expect(kindAt(doc, "swift", (doc as NSString).range(of: "Docs").location) == .prose)
    #expect(kindAt("/** Block docs */\nlet x = 1", "swift", 4) == .prose)
    #expect(kindAt("/**/", "swift", 0) == .comment)
  }

  // MARK: - Cross-line constructs

  @Test func swiftCrossLineConstructs() {
    let multi = "\"\"\"\nline one\ntwo\n\"\"\"\nlet end = true"
    #expect(
      kindAt(multi, "swift", (multi as NSString).range(of: "line one").location) == .string
        && kindAt(multi, "swift", (multi as NSString).range(of: "two").location) == .string)
    #expect(kindAt(multi, "swift", (multi as NSString).range(of: "let end").location) == .keyword)

    let nested = "let a = 1 /* outer /* inner */ still */ let b = 2"
    #expect(
      kindAt(nested, "swift", (nested as NSString).range(of: "still").location) == .comment
        && kindAt(nested, "swift", (nested as NSString).range(of: "let b").location) == .keyword)

    let unterminated = "let s = \"unterminated\nlet t = 1"
    #expect(
      kindAt(unterminated, "swift", (unterminated as NSString).range(of: "let t").location)
        == .keyword)

    let raw = "let r = #\"raw \\\"quoted\\\" text\"#\nlet next = 5"
    #expect(
      kindAt(raw, "swift", (raw as NSString).range(of: "quoted").location) == .string
        && kindAt(raw, "swift", (raw as NSString).range(of: "let next").location) == .keyword)
  }

  // MARK: - UTF-16 safety: emoji inside strings and comments

  @Test func swiftEmojiUtf16() {
    let emoji = "let s = \"🎉\" // 😀 comment\nlet n = 7"
    #expect(kindAt(emoji, "swift", (emoji as NSString).range(of: "🎉").location) == .string)
    #expect(kindAt(emoji, "swift", (emoji as NSString).range(of: "😀").location) == .comment)
  }

  // MARK: - Other languages: comments, strings, preprocessors, attributes, vars

  @Test func otherLanguages() {
    let cCode = "#include <stdio.h>\n#define MAX 10\nint main(void) { return 0; }"
    let cNs = cCode as NSString
    #expect(kindAt(cCode, "c", cNs.range(of: "#include").location) == .preprocessor)
    #expect(kindAt(cCode, "c", cNs.range(of: "#define").location) == .preprocessor)
    #expect(kindAt(cCode, "c", cNs.range(of: "stdio").location) == .string)
    #expect(kindAt(cCode, "c", cNs.range(of: "stdio.h").location + 5) == .string)

    let py = "# comment\ndef f(x):\n    return x * 2\n"
    #expect(kindAt(py, "python", (py as NSString).range(of: "comment").location) == .comment)
    #expect(kindAt(py, "python", (py as NSString).range(of: "def").location) == .keyword)
    #expect(kindAt(py, "python", (py as NSString).range(of: "f(x)").location) == .memberDeclaration)
    #expect(kindAt(py, "python", (py as NSString).range(of: "2").location) == .number)

    let rust = "#[derive(Debug)]\nstruct Point { x: i32 }\nfn main() {}"
    #expect(
      kindAt(rust, "rust", (rust as NSString).range(of: "#[derive").location) == .attribute)
    #expect(
      kindAt(rust, "rust", (rust as NSString).range(of: "Point").location) == .typeDeclaration)
    #expect(
      kindAt(rust, "rust", (rust as NSString).range(of: "main").location) == .memberDeclaration)
    #expect(kindAt("fn f<'a>(x: &'a str) -> &'a str { x }", "rust", 8) == nil)

    let sh = "for f in *.md; do echo $f; done"
    #expect(kindAt(sh, "bash", (sh as NSString).range(of: "for").location) == .keyword)
    #expect(kindAt(sh, "bash", (sh as NSString).range(of: "$f").location) == .otherMember)

    let lua = "local function greet(name)\n    print(name)\nend"
    #expect(kindAt(lua, "lua", (lua as NSString).range(of: "greet").location) == .memberDeclaration)
    #expect(kindAt(lua, "lua", (lua as NSString).range(of: "local").location) == .keyword)
  }

  // MARK: - GitHub schemes: struct colors per Xcode category, dark vs light distinct

  @Test func githubSchemes() {
    #expect(CodeColorScheme.githubLight.plainText == 0x24292E)
    #expect(CodeColorScheme.githubDark.comment == 0x959DA5)
    #expect(
      CodeColorScheme.githubDark.keyword != CodeColorScheme.githubLight.keyword
        && CodeColorScheme.githubDark.plainText != CodeColorScheme.githubLight.plainText)
    #expect(
      CodeColorScheme.githubDark.color(for: .keyword) == CodeColorScheme.githubDark.keyword
        && CodeColorScheme.githubLight.color(for: .comment) == CodeColorScheme.githubLight.comment)
  }
}
