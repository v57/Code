import CodeHighlighting
import CodeScan
import Foundation
import Testing

@testable import CodePretty

private func pretty(_ text: String, _ language: String, _ configure: (inout PrettyOptions) -> Void = { _ in }) -> String {
  var options = PrettyOptions()
  configure(&options)
  return Pretty.format(text, language: language, options: options)!
}

@Suite struct PrettyTests {
  @Test func indentationFollowsBrackets() {
    #expect(
      pretty("func a() {\nif b {\nc()\n}\n}\n", "Swift") == """
        func a() {
          if b {
            c()
          }
        }

        """)
  }

  @Test func spacingAroundOperatorsCommasAndBraces() {
    #expect(pretty("let a=1 ;f(a ,b)\n", "Swift").hasPrefix("let a = 1; f(a, b)"))
    #expect(pretty("if(a==b){c()}\n", "JavaScript") == "if (a == b) { c() }\n")
    #expect(pretty("x = a==b\n", "Python") == "x = a == b\n")
  }

  @Test func whatCanMeanTwoThingsStaysAsItIs() {
    for text in ["let a: [Int] = [-1, +2]\n", "let b = x as? Y ?? z\n", "func f<T: U>(a: T?) -> T! { a! }\n", "let c = reduce(0, +)\n", "x[1...2]\n", "@attr(x) func y() {}\n"] {
      #expect(pretty(text, "Swift") == text)
    }
    #expect(pretty("int *p = &q; T&& r = s;\n", "C") == "int *p = &q; T&& r = s;\n")
    #expect(pretty("f(a=1, b=2)\n", "Python") == "f(a=1, b=2)\n")
    #expect(pretty("a:hover { b: c; }\n", "CSS") == "a:hover { b: c; }\n")
  }

  @Test func stringsAndCommentsAreNotCode() {
    let swift = "let s = \"a  =b\"  // keep   this\n"
    #expect(pretty(swift, "Swift") == swift)
    let block = "func a() {\n/*\n   x\n     y\n*/\n}\n"
    #expect(pretty(block, "Swift") == "func a() {\n  /*\n     x\n       y\n  */\n}\n")
  }

  @Test func chainsAndContinuations() {
    #expect(pretty("let a = b\n.c()\n.d()\n", "Swift") == "let a = b\n  .c()\n  .d()\n")
    #expect(pretty("let a =\nb\nlet c = 1\n", "Swift") == "let a =\n  b\nlet c = 1\n")
    let swiftFormat = "View {\n}\n.frame()\n.padding()\n"
    #expect(pretty(swiftFormat, "Swift") == swiftFormat)
    let indented = "View {\n}\n  .frame()\n  .padding()\n"
    #expect(pretty(indented, "Swift") == indented)
  }

  @Test func switchFollowsTheLanguage() {
    #expect(pretty("switch a {\ncase 1:\nb()\ndefault:\nc()\n}\n", "Swift") == "switch a {\ncase 1:\n  b()\ndefault:\n  c()\n}\n")
    #expect(pretty("switch (a) {\ncase 1:\nb();\n}\n", "JavaScript") == "switch (a) {\n  case 1:\n    b();\n}\n")
  }

  @Test func alignedArgumentsStayAligned() {
    let text = "foo(a,\n    b);\n"
    #expect(pretty(text, "C") == text)
    #expect(pretty("  foo(a,\n      b);\n", "C") == text)
  }

  @Test func theAuthorsPreprocessorLinesStay() {
    let c = "void a() {\n#if X\n  b();\n#endif\n}\n"
    #expect(pretty(c, "C") == c)
    let swiftIndented = "#if os(macOS)\n  let a = 1\n#endif\nlet b = 2\n"
    #expect(pretty(swiftIndented, "Swift") == swiftIndented)
    let swiftFlat = "#if os(macOS)\nlet a = 1\n#endif\n"
    #expect(pretty(swiftFlat, "Swift") == swiftFlat)
  }

  @Test func blankLinesAndLineEnds() {
    #expect(pretty("a()\n\n\n\nb()   \n\n", "Swift") == "a()\n\nb()\n")
    #expect(pretty("func a() {\n\n  b()\n\n}\n", "Swift") == "func a() {\n  b()\n}\n")
    #expect(pretty("a()\r\nb()\r\n", "Swift") == "a()\r\nb()\r\n")
    #expect(pretty("", "Swift") == "")
  }

  @Test func wrapsOnlyWhenAWidthIsSet() {
    let long = "call(argumentNumberOne, argumentNumberTwo, argumentNumberThree)\n"
    #expect(pretty(long, "Swift") == long)
    #expect(
      pretty(long, "Swift") { $0.printWidth = 40 } == """
        call(
          argumentNumberOne,
          argumentNumberTwo,
          argumentNumberThree
        )

        """)
    #expect(pretty("let x = [aaaaaaaaaaaaaaa, bbbbbbbbbbbbbbb]\n", "Swift") { $0.printWidth = 20 } == "let x = [\n  aaaaaaaaaaaaaaa,\n  bbbbbbbbbbbbbbb,\n]\n")
    #expect(pretty("call(aaaaaaaaaaaaaaa, bbbbbbbbbbbbbbb)\n", "Rust") { $0.printWidth = 20 } == "call(\n    aaaaaaaaaaaaaaa,\n    bbbbbbbbbbbbbbb,\n)\n".replacingOccurrences(of: "    ", with: "  "))
  }

  @Test func quotesFollowTheFile() {
    #expect(pretty("a = 'x'\nb = \"y\"\nc = \"z\"\n", "Python") == "a = \"x\"\nb = \"y\"\nc = \"z\"\n")
    #expect(pretty("a = 'it\"s'\nb = \"y\"\nc = \"z\"\n", "Python") == "a = 'it\"s'\nb = \"y\"\nc = \"z\"\n")
    #expect(pretty("a = 'x'\n", "JavaScript") == "a = 'x'\n")
  }

  @Test func indentationBlocksKeepTheirs() {
    let python = "def a():\n      if b:\n            c( d )\n"
    #expect(pretty(python, "Python") == "def a():\n      if b:\n            c(d)\n")
  }

  @Test func contentFormatsOnlyLoseWhatsInvisible() {
    #expect(pretty("a  \nb\n\n\n", "YAML") == "a\nb\n")
    #expect(pretty("hard  \nbreak\n", "Markdown") == "hard  \nbreak\n")
    #expect(pretty("<a>  </a>  \n", "HTML") == "<a>  </a>\n")
  }

  @Test func tokensAreCheckedAndEveryLanguageIsStable() {
    for spec in LanguageCatalog.all {
      let text = spec.keywords.sorted().prefix(30).joined(separator: "  ") + "\n  a  =  b ( c ,d )\n\n\n{ e }  \n"
      let profile = LexProfile.profile(for: spec)
      let source = SourceFile(text, profile: profile)
      let output = Pretty.format(source, options: PrettyOptions())
      guard !output.refused else { continue }
      let result = SourceFile(bytes: output.text, profile: profile)
      #expect(Pretty.sameTokens(source, result), "\(spec.name)")
      let again = Pretty.format(result, options: PrettyOptions())
      #expect(again.text == output.text, "\(spec.name)")
    }
  }

  @Test func aChangedTokenIsCaught() {
    let profile = LexProfile.profile(forLanguage: "Swift")!
    let a = SourceFile("let a = 1", profile: profile)
    #expect(!Pretty.sameTokens(a, SourceFile("let a = 2", profile: profile)))
    #expect(!Pretty.sameTokens(a, SourceFile("let a =", profile: profile)))
    #expect(Pretty.sameTokens(a, SourceFile("let   a=1\n", profile: profile)))
    #expect(Pretty.sameTokens(SourceFile("[a]", profile: profile), SourceFile("[a,]", profile: profile)))
    #expect(!Pretty.sameTokens(SourceFile("f(a)b", profile: profile), SourceFile("f(a),b", profile: profile)))
  }

  @Test func editsRebuildTheResult() {
    let old = (0..<60).map { "line \($0)" }
    var new = old
    new[3] = "changed"
    new.remove(at: 20)
    new.insert("added", at: 40)
    new[59 - 1] = "last"
    let before = Array((old.joined(separator: "\n") + "\n").utf8)
    let after = Array((new.joined(separator: "\n") + "\n").utf8)
    let edits = before.withUnsafeBufferPointer { a in after.withUnsafeBufferPointer { b in Pretty.edits(from: a, to: b) } }
    #expect(edits.count == 4)
    var lines = old.map { Array(($0 + "\n").utf8) }
    for edit in edits.reversed() {
      let replacement = edit.text.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast().map { Array($0) + [0x0A] }
      lines.replaceSubrange(edit.startLine..<edit.endLine, with: replacement)
    }
    #expect(lines.flatMap { $0 } == after)
    let same = before.withUnsafeBufferPointer { a in Pretty.edits(from: a, to: a) }
    #expect(same.isEmpty)
  }

  @Test func optionsComeFromTheProjectThenTheText() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pretty-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("a/.git"), withIntermediateDirectories: true)
    let profile = LexProfile.profile(forLanguage: "Swift")!
    let plain = SourceFile("func a() {\n    b()\n}\n", profile: profile)
    #expect(PrettyOptions.resolve(path: nil, source: plain).indentWidth == 4)
    #expect(PrettyOptions.resolve(path: nil, source: plain).printWidth == 0)
    let tabbed = SourceFile("func a() {\n\tb()\n}\n", profile: profile)
    #expect(PrettyOptions.resolve(path: nil, source: tabbed).useTabs)

    try "[*.swift]\nindent_size = 3\nmax_line_length = 77\n".write(to: folder.appendingPathComponent("a/.editorconfig"), atomically: true, encoding: .utf8)
    let path = folder.appendingPathComponent("a/b.swift").path
    #expect(PrettyOptions.resolve(path: path, source: plain).indentWidth == 3)
    #expect(PrettyOptions.resolve(path: path, source: plain).printWidth == 77)
    // Above the repository's root doesn't count.
    try "[*]\nindent_size = 7\n".write(to: folder.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
    #expect(PrettyOptions.resolve(path: path, source: plain).indentWidth == 3)
  }
}
