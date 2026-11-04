import CodeHighlighting
import Foundation
import Testing

@testable import CodeScan

private func profile(_ language: String) -> LexProfile { LexProfile.profile(forLanguage: language)! }

private func kinds(_ text: String, _ language: String) -> [(String, TokenKind)] {
  let source = SourceFile(text, profile: profile(language))
  return source.tokens.map { (source.string($0), $0.kind) }
}

private func names(_ text: String, _ language: String) -> [String] {
  let symbols = SourceFile(text, profile: profile(language)).symbols
  return symbols.symbols.filter { !$0.isLocal }.map { symbols.name($0) }
}

@Suite struct LexerTests {
  @Test func everyLanguageScansItsOwnWords() {
    for spec in LanguageCatalog.all {
      let words = spec.keywords.sorted().prefix(40).joined(separator: " ")
      let text = words + " identifier_1 12345 \"text\" ( [ { } ] ) // c\n# c\n/* c */ <!-- c --> -- c\n"
      let source = SourceFile(text, profile: LexProfile.profile(for: spec))
      var end = 0
      for token in source.tokens {
        #expect(token.start >= end, "\(spec.name)")
        #expect(token.end <= source.count, "\(spec.name)")
        end = token.end
      }
      #expect(!source.tokens.isEmpty, "\(spec.name)")
    }
  }

  /// The eight-byte identifier loop's edges: a stop in every position of a word, and in the next one.
  @Test func identifiersEndWhereTheyEnd() {
    for length in 1...40 {
      let word = String(repeating: "a", count: length)
      for stop in ["", " ", ".", "(", "-", "é"] {
        let tokens = kinds(word + stop, "Go")
        if stop == "é" {
          #expect(tokens.first?.0 == word + stop, "\(length)")
        } else {
          #expect(tokens.first?.0 == word, "\(length) \(stop)")
          #expect(tokens.first?.1 == .identifier)
        }
      }
    }
  }

  @Test func swiftInterpolationIsCode() {
    let tokens = kinds(#"let a = "x\(b + "y")z""#, "Swift")
    #expect(tokens.contains { $0.0 == "b" && $0.1 == .identifier })
    #expect(tokens.contains { $0.1 == .interpolationOpen })
    #expect(tokens.filter { $0.1 == .string }.count == 3)
  }

  @Test func interpolationsNestPastTheirRoom() {
    for (language, open, close) in [("swift", "\"\\(", ")\""), ("javascript", "`${", "}`"), ("typescript", "`${", "}`")] {
      for depth in [7, 8, 9, 400] {
        let text = String(repeating: open, count: depth) + "x" + String(repeating: close, count: depth) + "\n"
        let source = SourceFile(text, profile: profile(language))
        var end = 0
        for token in source.tokens {
          #expect(token.start >= end, "\(language) \(depth)")
          #expect(token.end <= source.count, "\(language) \(depth)")
          end = token.end
        }
      }
    }
  }

  @Test func rawAndMultilineStrings() {
    #expect(kinds(##"#"a"b"#"##, "Swift").map(\.1) == [.string])
    #expect(kinds("\"\"\"\na\n\"b\"\n\"\"\"", "Swift").map(\.1) == [.string])
    #expect(kinds(##"r#"a"b"#"##, "Rust").map(\.1) == [.string])
    #expect(kinds(#"R"x(a)")x""#, "C++").map(\.1) == [.string])
  }

  @Test func rustLifetimesAreNotCharacters() {
    let tokens = kinds("fn f<'a>(x: &'a str) -> char { 'b' }", "Rust")
    #expect(tokens.filter { $0.1 == .string }.map(\.0) == ["'b'"])
  }

  @Test func regexLiteralsAndDivision() {
    #expect(kinds("x = /a b/.test(y)", "JavaScript").contains { $0.0 == "/a b/" && $0.1 == .string })
    #expect(kinds("x = a / b / c", "JavaScript").filter { $0.1 == .string }.isEmpty)
  }

  @Test func hereDocuments() {
    let tokens = kinds("cat <<EOF\nnot code\nEOF\necho done\n", "Shell")
    #expect(tokens.contains { $0.0 == "echo" })
    #expect(!tokens.contains { $0.0 == "not" })
  }

  @Test func nestedComments() {
    #expect(kinds("/* a /* b */ c */ d", "Swift").map(\.0).last == "d")
  }

  @Test func aShebangIsAComment() {
    #expect(kinds("#!/usr/bin/env python\nx = 1", "Python").first?.1 == .comment)
    // Rust's inner attribute starts the same way.
    #expect(kinds("#![allow(x)]\nfn a() {}", "Rust").first?.1 != .comment)
  }
}

@Suite struct SymbolTests {
  @Test func swift() {
    let text = """
      struct Box<T> {
        var value: T
        func get(at index: Int) -> T { let local = value; return local }
        enum Kind { case a, b }
      }
      extension Box { func more() {} }
      """
    let all = names(text, "Swift")
    for name in ["Box", "value", "get", "Kind", "a", "b", "more"] { #expect(all.contains(name), "\(name)") }
    #expect(!all.contains("local"))
    let symbols = SourceFile(text, profile: profile("Swift")).symbols
    let get = symbols.symbols.first { symbols.name($0) == "get" }!
    #expect(symbols.name(symbols.symbols[Int(get.parent)]) == "Box")
    #expect(symbols.symbols.contains { symbols.name($0) == "index" && $0.isLocal })
  }

  @Test func eachFamily() {
    #expect(names("class A:\n  def b(self):\n    c = 1\n\ndef d(): pass\n", "Python").starts(with: ["A", "b"]))
    #expect(names("package p\nfunc (r R) M() {}\ntype T struct { F int }\n", "Go").contains("M"))
    #expect(names("int add(int a, int b) { return a + b; }\ntypedef struct S { int x; } S;\n#define MAX 3\n", "C").contains("add"))
    #expect(names("fn f() {}\nstruct S;\nimpl S { fn g(&self) {} }\n", "Rust").contains("g"))
    #expect(names("export class A { m() {} }\nconst f = (x) => x\nfunction g() {}\n", "TypeScript").contains("f"))
    #expect(names("{\"a\": {\"b\": 1}}", "JSON") == ["a", "b"])
    #expect(names("# One\ntext\n## Two\n```\n# not\n```\n", "Markdown") == ["One", "Two"])
    #expect(names("a:\n  b: 1\n", "YAML") == ["a", "b"])
    #expect(names("all: x\n\tcmd\n", "Makefile") == ["all"])
    #expect(names(".a { color: red }\n", "CSS").contains(".a"))
  }

  @Test func aByteOrderMarkIsntPartOfTheFirstWord() {
    #expect(names("\u{FEFF}struct Marked {}\n", "Swift") == ["Marked"])
    #expect(names("\u{FEFF}", "Swift").isEmpty)
    #expect(names("\u{FEFF}func F() {}\n", "Go") == ["F"])
  }

  @Test func cDeclarationsAreNotAssignments() {
    let text = """
      int f(struct S *s) {
        s->member = 1;
        a.b = 2;
        u32 x0, x1, *x2 = g(1, 2), x3[4];
        struct T *node = 0;
        h(x0, x1);
        return 0;
      }
      """
    let symbols = SourceFile(text, profile: profile("C")).symbols
    let all = symbols.symbols.map { symbols.name($0) }
    for name in ["f", "s", "x0", "x1", "x2", "x3", "node"] { #expect(all.contains(name), "\(name)") }
    for name in ["member", "b", "g", "h"] { #expect(!all.contains(name), "\(name)") }
    let nodes = symbols.symbols.filter { symbols.name($0) == "node" }
    #expect(nodes.count == 1)
    #expect(nodes.first?.isLocal == true)
  }

  @Test func unbalancedBracketsAreReported() {
    #expect(SourceFile("func a() { (1, 2 }", profile: profile("Swift")).symbols.problems.count >= 1)
    #expect(SourceFile("func a() { (1, 2) }", profile: profile("Swift")).symbols.problems.isEmpty)
  }

  @Test func theNameFilterHasNoFalseNegatives() {
    let text = (0..<500).map { "func name\($0)() {}" }.joined(separator: "\n")
    let source = SourceFile(text, profile: profile("Swift"))
    let filter = source.tokens.withUnsafeBufferPointer { NameFilter(text: source.text, tokens: $0) }
    for index in 0..<500 { #expect(filter.mayContain(hash: hashName("name\(index)"))) }
  }
}

@Suite struct LineMapTests {
  @Test func positionsInEveryEncoding() {
    let source = SourceFile("a\n😀b\r\né\n", profile: .plainText)
    let offset = source.string(from: 0, to: source.count).utf8.count - 3
    #expect(source.lines.position(of: offset, in: source.text, encoding: .utf16).line == 2)
    // After the emoji: two UTF-16 units, four bytes.
    #expect(source.lines.position(of: 6, in: source.text, encoding: .utf16) == (1, 2))
    #expect(source.lines.position(of: 6, in: source.text, encoding: .utf8) == (1, 4))
    #expect(source.lines.offset(line: 1, character: 2, in: source.text, encoding: .utf16) == 6)
    #expect(source.lines.offset(line: 1, character: 4, in: source.text, encoding: .utf8) == 6)
    // Past a line's end stops at its end.
    #expect(source.lines.offset(line: 0, character: 99, in: source.text, encoding: .utf16) == 1)
  }
}

@Suite struct WorkspaceTests {
  /// A folder of files, removed afterwards.
  private func withFolder(_ files: [String: String], _ body: (String) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("codescan-\(UUID().uuidString)").resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: folder) }
    for (name, text) in files {
      let url = folder.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
    }
    try body(folder.path)
  }

  private func offset(of word: String, in source: SourceFile) -> Int {
    source.string(from: 0, to: source.count).range(of: word).map { source.string(from: 0, to: source.count).utf8.distance(from: source.string(from: 0, to: source.count).startIndex, to: $0.lowerBound) }!
  }

  @Test func definitionAcrossFilesAndInScope() throws {
    try withFolder([
      "A.swift": "struct Thing { func run() {} }\n",
      "B.swift": "func use(run: Int) { let t = Thing(); t.run(); print(run) }\n",
      ".git/x.swift": "struct Thing {}\n",
      "node_modules/y.swift": "struct Thing {}\n",
    ]) { root in
      let index = WorkspaceIndex(roots: [root])
      index.refresh()
      #expect(index.fileCount == 2)
      let path = root + "/B.swift"
      let source = index.source(path: path)!
      let thing = index.resolve(path: path, source: source, offset: offset(of: "Thing", in: source))
      #expect(thing.first?.path == root + "/A.swift")
      #expect(thing.count == 1)
      // The receiver's declared type picks the method; a bare name is the parameter.
      let member = index.resolve(path: path, source: source, offset: offset(of: "run()", in: source))
      #expect(member.first?.path == root + "/A.swift")
      let parameter = index.resolve(path: path, source: source, offset: offset(of: "run)", in: source))
      #expect(parameter.first?.path == path)
    }
  }

  @Test func selfNamesTheType() throws {
    try withFolder(["A.swift": "struct Thing {\n  func a() { self.b() }\n  func b() {}\n}\n"]) { root in
      let index = WorkspaceIndex(roots: [root])
      index.refresh()
      let path = root + "/A.swift"
      let source = index.source(path: path)!
      #expect(index.resolve(path: path, source: source, offset: offset(of: "self", in: source)).first?.name == "Thing")
    }
  }

  @Test func referencesSkipStringsCommentsAndShadows() throws {
    try withFolder([
      "A.swift": "func target() {}\n// target\nlet s = \"target\"\ntarget()\nfunc other() { let target = 1; print(target) }\n",
      "B.swift": "func b() { target() }\n",
    ]) { root in
      let index = WorkspaceIndex(roots: [root])
      index.refresh()
      let path = root + "/A.swift"
      let source = index.source(path: path)!
      let found = index.references(path: path, source: source, offset: offset(of: "target", in: source), includeDeclaration: true)
      #expect(found.filter { $0.path == path }.map(\.range.start.line).sorted() == [0, 3])
      #expect(found.filter { $0.path == root + "/B.swift" }.count == 1)
    }
  }

  @Test func refreshSeesChangesAndOpenDocumentsWin() throws {
    try withFolder(["A.swift": "struct Old {}\n"]) { root in
      let index = WorkspaceIndex(roots: [root])
      index.refresh()
      #expect(index.workspaceSymbols(query: "Old", limit: 5).count == 1)
      let path = root + "/A.swift"
      // A different size, as the time can stay within one second's stamp.
      try "struct NewName {}\n".write(toFile: path, atomically: true, encoding: .utf8)
      index.refresh()
      #expect(index.workspaceSymbols(query: "Old", limit: 5).isEmpty)
      #expect(index.workspaceSymbols(query: "NewName", limit: 5).count == 1)

      index.setDocument(SourceFile("struct Unsaved {}\n", profile: profile("Swift")), path: path)
      #expect(index.workspaceSymbols(query: "Unsaved", limit: 5).count == 1)
      index.closeDocument(path: path)
      #expect(index.workspaceSymbols(query: "Unsaved", limit: 5).isEmpty)
      #expect(index.workspaceSymbols(query: "NewName", limit: 5).count == 1)

      try FileManager.default.removeItem(atPath: path)
      index.refresh()
      #expect(index.fileCount == 0)
    }
  }

  @Test func refreshLeavesOpenDocumentsAlone() throws {
    try withFolder(["A.swift": "struct Old {}\n", "B.swift": "struct Bee {}\n", "C.swift": "struct Sea {}\n"]) { root in
      let index = WorkspaceIndex(roots: [root])
      index.refresh()
      let swift = profile("Swift")
      func found(_ name: String) -> Bool { !index.workspaceSymbols(query: name, limit: 5).filter { $0.name == name }.isEmpty }
      let outside = "/not/in/the/folder/D.swift"
      // As long as the file, then not.
      index.setDocument(SourceFile("struct Bzz {}\n", profile: swift), path: root + "/B.swift")
      index.setDocument(SourceFile("struct Longer {}\n", profile: swift), path: root + "/A.swift")
      // Without a file in the folder: deleted from it, and never in it.
      index.setDocument(SourceFile("struct Sea {}\n", profile: swift), path: root + "/C.swift")
      try FileManager.default.removeItem(atPath: root + "/C.swift")
      index.setDocument(SourceFile("struct Elsewhere {}\n", profile: swift), path: outside)

      index.refresh()

      #expect(found("Bzz"))
      #expect(!found("Bee"))
      #expect(found("Longer"))
      #expect(!found("Old"))
      #expect(found("Sea"))
      #expect(found("Elsewhere"))
      #expect(index.fileCount == 4)

      // Closed, the disk counts again.
      for path in [root + "/A.swift", root + "/B.swift", root + "/C.swift", outside] { index.closeDocument(path: path) }
      index.refresh()
      #expect(found("Old"))
      #expect(found("Bee"))
      #expect(!found("Longer"))
      #expect(!found("Sea"))
      #expect(!found("Elsewhere"))
      #expect(index.fileCount == 2)
    }
  }

  @Test func gitignoreIsHonored() throws {
    try withFolder([
      ".gitignore": "gen/\n*.out.swift\n!keep.out.swift\n",
      "gen/a.swift": "struct A {}\n",
      "b.out.swift": "struct B {}\n",
      "keep.out.swift": "struct C {}\n",
      "d.swift": "struct D {}\n",
    ]) { root in
      let index = WorkspaceIndex(roots: [root])
      index.refresh()
      #expect(index.workspaceSymbols(query: "A", limit: 5).filter { $0.name == "A" }.isEmpty)
      #expect(index.workspaceSymbols(query: "B", limit: 5).filter { $0.name == "B" }.isEmpty)
      #expect(index.workspaceSymbols(query: "C", limit: 5).filter { $0.name == "C" }.count == 1)
      #expect(index.workspaceSymbols(query: "D", limit: 5).filter { $0.name == "D" }.count == 1)
    }
  }

  @Test func renameOnlyWhatItCanProve() throws {
    try withFolder([
      "A.swift": "func once() {}\nfunc twice() {}\nfunc f() { let local = 1; print(local); once(); twice() }\n",
      "B.swift": "struct S { func twice() {} }\n",
    ]) { root in
      let index = WorkspaceIndex(roots: [root])
      index.refresh()
      let path = root + "/A.swift"
      let source = index.source(path: path)!
      #expect(index.renameLocations(path: path, source: source, offset: offset(of: "local", in: source))?.count == 2)
      #expect(index.renameLocations(path: path, source: source, offset: offset(of: "once", in: source))?.count == 2)
      #expect(index.renameLocations(path: path, source: source, offset: offset(of: "twice", in: source)) == nil)
    }
  }

  @Test func completionsTakeThePrefixAndScope() throws {
    try withFolder(["A.swift": "struct Thing { func alpha() {} }\nfunc f(argument: Int) {\n  let t = Thing()\n  t.al\n  arg\n}\n"]) { root in
      let index = WorkspaceIndex(roots: [root])
      index.refresh()
      let path = root + "/A.swift"
      let source = index.source(path: path)!
      let afterMember = offset(of: "t.al", in: source) + 4
      #expect(index.completions(path: path, source: source, offset: afterMember, limit: 20).first?.label == "alpha")
      let afterBare = offset(of: "arg\n", in: source) + 3
      #expect(index.completions(path: path, source: source, offset: afterBare, limit: 20).first?.label == "argument")
    }
  }
}
