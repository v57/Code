import Foundation
import Testing

@testable import CodeWorkspace

@Suite struct ProjectReplaceTests {
  @Test func replacesEveryMatch() {
    let text = "count counter recount\ncount_x $1"
    #expect(ProjectReplace.replacingAll(in: text, query: SearchQuery("count"), with: "n") == ("n ner ren\nn_x $1", 4))
    #expect(
      ProjectReplace.replacingAll(in: text, query: SearchQuery("count", mode: .matchingWord), with: "total")
        == ("total counter recount\ncount_x $1", 1))
    // Outside regular expressions "$" and "\" are plain text, in the query and the replacement.
    #expect(ProjectReplace.replacingAll(in: text, query: SearchQuery("$1"), with: "\\$0").text.hasSuffix("count_x \\$0"))
    #expect(ProjectReplace.replacingAll(in: text, query: SearchQuery("none"), with: "x") == (text, 0))
  }

  @Test func regularExpressionsUseGroups() {
    let query = SearchQuery("(\\w+)\\.(\\w+)\\(", mode: .regularExpression)
    let result = ProjectReplace.replacingAll(in: "a.b(1) c.d(2)", query: query, with: "$2($1, ")
    #expect(result == ("b(a, 1) d(c, 2)", 2))
    // Empty matches are neither found nor replaced.
    #expect(ProjectReplace.replacingAll(in: "ab", query: SearchQuery("x*", mode: .regularExpression), with: "-") == ("ab", 0))
  }

  @Test func replacesOneMatchWhereItWasFound() throws {
    let text = "let a = 1\n  let b = a\r\nprint(a)"
    let match = ProjectSearch.search(text, expression: SearchQuery("a", mode: .matchingWord).expression!)[1]
    #expect(match.line == 2)
    let query = SearchQuery("a", mode: .matchingWord)
    #expect(
      ProjectReplace.replacing(line: match.line, column: match.column, in: text, query: query, with: "x")
        == "let a = 1\n  let b = x\r\nprint(a)")
    // The text there changed: nothing to replace.
    #expect(ProjectReplace.replacing(line: 2, column: match.column, in: "a\nlet b = c", query: query, with: "x") == nil)
    // \b sees the text before the match: "ba" isn't the word "a".
    #expect(ProjectReplace.replacing(line: 1, column: 1, in: "ba", query: query, with: "x") == nil)
    #expect(ProjectReplace.replacing(line: 9, column: 0, in: text, query: query, with: "x") == nil)
  }

  @Test func previewsFillInGroups() {
    let query = SearchQuery("(\\w+)=(\\w+)", mode: .regularExpression)
    let match = ProjectSearch.search("  x=1; y=2", expression: query.expression!)[1]
    #expect(ProjectReplace.preview(of: match, query: query, replacement: "$2=$1") == "2=y")
    #expect(ProjectReplace.preview(of: match, query: SearchQuery("y"), replacement: "$2") == "$2")
  }

  @Test func filesKeepTheirEncoding() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("replace-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let latin = folder.appendingPathComponent("latin.txt")
    try "café = café\n".data(using: .isoLatin1)!.write(to: latin)
    #expect(try ProjectReplace.replaceAll(inFileAt: latin, query: SearchQuery("café"), with: "thé") == 2)
    #expect(try Data(contentsOf: latin) == "thé = thé\n".data(using: .isoLatin1)!)
    #expect(try ProjectReplace.replace(line: 1, column: 6, inFileAt: latin, query: SearchQuery("thé"), with: "tea"))
    #expect(try String(contentsOf: latin, encoding: .isoLatin1) == "thé = tea\n")
    #expect(try !ProjectReplace.replace(line: 1, column: 0, inFileAt: latin, query: SearchQuery("tea"), with: "x"))
  }
}
