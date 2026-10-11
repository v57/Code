import Foundation
import Testing

@testable import CodeHighlighting

/// The kind of the last token covering the first occurrence of `needle`.
private func kind(of needle: String, in code: String, _ language: String) -> SyntaxKind? {
  let at = (code as NSString).range(of: needle).location
  return CodeHighlighter.tokens(in: code, language: language).last {
    NSLocationInRange(at, $0.range)
  }?.kind
}

@Suite struct FormatsTests {
  @Test func json() {
    let code = "{\n  \"name\": \"Code\",\n  \"count\": 3, \"ok\": true\n}"
    #expect(kind(of: "\"name\"", in: code, "json") == .otherMember)
    #expect(kind(of: "\"Code\"", in: code, "json") == .string)
    #expect(kind(of: "3", in: code, "json") == .number)
    #expect(kind(of: "true", in: code, "json") == .keyword)
  }

  @Test func yaml() {
    let code = "---\nname: Code # comment\nlist:\n  - key: \"value\"\n"
    #expect(kind(of: "---", in: code, "yaml") == .preprocessor)
    #expect(kind(of: "name", in: code, "yaml") == .otherMember)
    #expect(kind(of: "# comment", in: code, "yaml") == .comment)
    #expect(kind(of: "key", in: code, "yaml") == .otherMember)
    #expect(kind(of: "\"value\"", in: code, "yaml") == .string)
  }

  @Test func toml() {
    let code = "[package]\nname = \"code\"\n"
    #expect(kind(of: "[package]", in: code, "toml") == .typeDeclaration)
    #expect(kind(of: "name", in: code, "toml") == .otherMember)
  }

  @Test func html() {
    let code = "<!DOCTYPE html>\n<a href=\"x.html\">Don't 2</a> &amp; <!-- c -->"
    #expect(kind(of: "<!DOCTYPE", in: code, "html") == .preprocessor)
    #expect(kind(of: "a href", in: code, "html") == .keyword)
    #expect(kind(of: "href", in: code, "html") == .otherMember)
    #expect(kind(of: "\"x.html\"", in: code, "html") == .string)
    #expect(kind(of: "Don't", in: code, "html") == nil)
    #expect(kind(of: "2", in: code, "html") == nil)
    #expect(kind(of: "&amp;", in: code, "html") == .number)
    #expect(kind(of: "c -->", in: code, "html") == .comment)
  }

  @Test func css() {
    let code = ".card:hover {\n  color: #fff !important;\n}\n@media screen {}"
    #expect(kind(of: ".card", in: code, "css") == .typeDeclaration)
    #expect(kind(of: ":hover", in: code, "css") == .keyword)
    #expect(kind(of: "color", in: code, "css") == .otherMember)
    #expect(kind(of: "#fff", in: code, "css") == .number)
    #expect(kind(of: "@media", in: code, "css") == .attribute)
  }

  @Test func sqlIsCaseInsensitive() {
    #expect(kind(of: "select", in: "select * from t", "sql") == .keyword)
    #expect(kind(of: "FROM", in: "SELECT * FROM t", "sql") == .keyword)
  }

  @Test func markdown() {
    let code = "# Title 2\n\n- item **bold** and `code`\n\n```swift\nlet x = 1\n```\n> quote"
    #expect(kind(of: "Title", in: code, "md") == .keyword)
    #expect(kind(of: "-", in: code, "md") == .keyword)
    #expect(kind(of: "**bold**", in: code, "md") == .typeDeclaration)
    #expect(kind(of: "`code`", in: code, "md") == .string)
    #expect(kind(of: "let x", in: code, "md") == .string)
    #expect(kind(of: "quote", in: code, "md") == .comment)
  }

  @Test func makefileAndDockerfile() {
    let make = "CC := clang\nbuild: main.o\n\t$(CC) -o $@ main.o\n"
    #expect(kind(of: "CC", in: make, "makefile") == .otherMember)
    #expect(kind(of: "build", in: make, "makefile") == .memberDeclaration)
    #expect(kind(of: "$(CC)", in: make, "makefile") == .otherMember)
    let docker = "# base\nFROM swift:6 AS build\nRUN echo \"#not a comment\"\n"
    #expect(kind(of: "# base", in: docker, "dockerfile") == .comment)
    #expect(kind(of: "FROM", in: docker, "dockerfile") == .keyword)
    #expect(kind(of: "#not", in: docker, "dockerfile") == .string)
  }

  @Test func languageDetection() {
    func name(_ path: String, _ firstLine: String? = nil) -> String? {
      Language.detect(url: URL(fileURLWithPath: path), firstLine: firstLine)?.name
    }
    #expect(name("/p/App.swift") == "Swift")
    #expect(name("/p/index.tsx") == "TypeScript")
    #expect(name("/p/main.h") == "C")
    #expect(name("/p/Makefile") == "Makefile")
    #expect(name("/p/Dockerfile.dev") == "Dockerfile")
    #expect(name("/p/.zshrc") == "Shell")
    #expect(name("/p/Package.resolved") == "JSON")
    #expect(name("/p/config.yml") == "YAML")
    #expect(name("/p/README.md") == "Markdown")
    #expect(name("/p/Info.plist") == "HTML")
    #expect(name("/p/run", "#!/usr/bin/env python3") == "Python")
    #expect(name("/p/run", "#!/bin/zsh -e") == "Shell")
    #expect(name("/p/notes.txt") == nil)
  }
}
