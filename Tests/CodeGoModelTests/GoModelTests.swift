import CodeGoModel
import Foundation
import Testing

/// A Go module in a temporary folder, from file text with `@@` before the word a question is about.
private final class Module {
  let root: String
  let model: GoModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  init(_ files: [String: String]) throws {
    root = NSTemporaryDirectory() + "gomodel-" + UUID().uuidString + "/module"
    var all = files
    if all["go.mod"] == nil { all["go.mod"] = "module example.com/m\n\ngo 1.22\n" }
    for (name, text) in all {
      var body = ""
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var rest = String(line)
        while let mark = rest.range(of: "@@") {
          let character = rest.utf8.distance(from: rest.startIndex, to: mark.lowerBound)
          let word = String(rest[mark.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" })
          // The same word twice: the second is `word2`.
          var key = word
          var n = 2
          while marks[key] != nil {
            key = word + String(n)
            n += 1
          }
          marks[key] = (root + "/" + name, number, character)
          rest.removeSubrange(mark)
        }
        body += rest + "\n"
      }
      let url = URL(fileURLWithPath: root + "/" + name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try body.write(to: url, atomically: true, encoding: .utf8)
    }
    model = GoModel(root: root)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), paths relative to the module.
  func answer(_ key: String) -> (state: AnswerState, places: [String]) {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return (found.state, found.sites.compactMap { site in model.place(of: site).map { "\($0.path):\($0.line)" } })
  }

  func complete(_ key: String) -> [String] {
    let mark = marks[key]!
    return model.complete(path: mark.path, line: mark.line, character: mark.character, limit: 200).items.map(\.name)
  }
}

private let hasGo = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/go") || FileManager.default.isExecutableFile(atPath: "/usr/local/go/bin/go")

@Suite struct Definitions {
  @Test func methodsFieldsAndPromotion() throws {
    let m = try Module([
      "a.go": """
        package m

        type Base struct{ ID int }

        func (b *Base) Name() string { return "" }

        type Item struct {
        \tBase
        \tCount int
        }

        func use(i Item) {
        \t_ = i.@@Count
        \t_ = i.@@ID
        \t_ = i.@@Name()
        \t_ = i.@@Base.ID
        }
        """
    ])
    #expect(m.answer("Count").places == ["a.go:9"])
    #expect(m.answer("ID").places == ["a.go:3"])
    #expect(m.answer("Name").places == ["a.go:5"])
    #expect(m.answer("Base").places == ["a.go:8"])
  }

  @Test func localsAndScopes() throws {
    let m = try Module([
      "a.go": """
        package m

        func f(x int) int {
        \tif x := x + 1; x > 2 {
        \t\treturn @@x
        \t}
        \tfor k, v := range map[string]int{"a": 1} {
        \t\t_ = @@k
        \t\t_ = @@v
        \t}
        \tvar y interface{}
        \tswitch t := y.(type) {
        \tcase string:
        \t\t_ = @@t
        \t}
        \treturn @@x
        }
        """
    ])
    #expect(m.answer("x").places == ["a.go:4"])
    #expect(m.answer("k").places == ["a.go:7"])
    #expect(m.answer("v").places == ["a.go:7"])
    #expect(m.answer("t").places == ["a.go:12"])
    #expect(m.answer("x2").places == ["a.go:3"])
  }

  @Test func typesFromBuiltinsLiteralsAndGenerics() throws {
    let m = try Module([
      "a.go": """
        package m

        type P struct{ N int }

        func Make[T any]() (T, error) { var t T; return t, nil }

        func f() {
        \tps := make([]*P, 0, 4)
        \tps = append(ps, &P{})
        \t_ = ps[0].@@N
        \tfor _, p := range []*P{{N: 1}} {
        \t\t_ = p.@@N
        \t}
        \tq, _ := Make[P]()
        \t_ = q.@@N
        \tif c, ok := any(ps[0]).(interface{ Close() error }); ok {
        \t\t_ = c.@@Close()
        \t}
        }
        """
    ])
    #expect(m.answer("N").places == ["a.go:3"])
    #expect(m.answer("N2").places == ["a.go:3"])
    #expect(m.answer("N3").places == ["a.go:3"])
    #expect(m.answer("Close").places == ["a.go:16"])
  }

  @Test func packagesImportsAndBuildConstraints() throws {
    let m = try Module([
      "a.go": """
        package m

        import (
        \tu "example.com/m/util"
        )

        func f() { _ = u.@@Helper(); @@other() }
        """,
      "b.go": "package m\n\nfunc other() {}\n",
      "c_windows.go": "package m\n\nfunc other() {}\n",
      "d.go": "//go:build ignore\n\npackage m\n\nfunc other() {}\n",
      "util/util.go": "package util\n\n// Helper helps.\nfunc Helper() int { return 1 }\n",
    ])
    #expect(m.answer("Helper").places == ["util/util.go:4"])
    #expect(m.answer("other") == (.exact, ["b.go:3"]))
  }

  @Test func functionTypeParameterNamesDeclareThemselves() throws {
    let m = try Module([
      "a.go": "package m\n\ntype S struct {\n\tOn func(@@ipv4, ipv6 string)\n}\n"
    ])
    #expect(m.answer("ipv4").places == ["a.go:4"])
  }

  @Test func standardLibrary() throws {
    guard hasGo else { return }
    let m = try Module([
      "a.go": "package m\n\nimport \"strings\"\n\nvar s = strings.@@TrimSpace(\" a \")\nvar n = @@len(s)\n"
    ])
    let trim = m.answer("TrimSpace")
    #expect(trim.state == .exact)
    #expect(trim.places.first?.hasPrefix("goroot:strings/") == true)
    #expect(m.answer("len").places.first?.hasPrefix("goroot:builtin/builtin.go") == true)
  }
}

@Suite struct Services {
  @Test func memberCompletionListsFieldsAndMethods() throws {
    let m = try Module([
      "a.go": """
        package m

        type T struct{ Alpha, beta int }

        func (T) Gamma() {}

        func f(t T) {
        \tt.@@x
        }
        """
    ])
    let names = m.complete("x")
    #expect(names.contains("Alpha"))
    #expect(names.contains("beta"))
    #expect(names.contains("Gamma"))
    #expect(!names.contains("f"))
  }

  @Test func scopeCompletionHasLocalsFirst() throws {
    let m = try Module([
      "a.go": "package m\n\nfunc f() {\n\tcounter := 1\n\t_ = counter\n\t@@co\n}\n"
    ])
    let names = m.complete("co")
    #expect(names.first == "counter")
    #expect(names.contains("const") || names.contains("continue"))
  }

  @Test func referencesAndDetails() throws {
    let m = try Module([
      "a.go": "package m\n\n// Run runs.\nfunc @@Run() {}\n\nfunc a() { Run() }\n",
      "b.go": "package m\n\nfunc b() { Run(); Run() }\n",
    ])
    let mark = m.marks["Run"]!
    let answer = m.model.answer(path: mark.path, line: mark.line, character: mark.character)
    let lines = m.model.references(of: answer).map { "\(URL(fileURLWithPath: $0.path).lastPathComponent):\($0.line)" }
    // A line each.
    #expect(lines.sorted() == ["a.go:4", "a.go:6", "b.go:3"])
    let details = try #require(answer.sites.first.flatMap { m.model.details(of: $0) })
    #expect(details.declaration == "func Run()")
    #expect(details.documentation == "Run runs.")
  }
}
