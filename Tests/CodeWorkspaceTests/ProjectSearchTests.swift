import Foundation
import Testing

@testable import CodeWorkspace

@Suite struct ProjectSearchTests {
  func matches(_ text: String, _ query: SearchQuery) -> [SearchMatch] {
    ProjectSearch.search(text, expression: query.expression!)
  }

  func highlighted(_ match: SearchMatch) -> String { String(match.preview[match.range]) }

  @Test func linesColumnsAndPreviews() {
    let found = matches("let a = 1\n    let b = a\r\nprint(A)", SearchQuery("a"))
    #expect(found.map(\.line) == [1, 2, 3])
    #expect(found.map(\.column) == [4, 12, 6])
    // Leading whitespace and the \r of CRLF are left out of the preview.
    #expect(found[1].preview == "let b = a")
    #expect(found.map(highlighted) == ["a", "a", "A"])
  }

  @Test func modes() {
    let text = "count counter recount count_x x+=1"
    #expect(matches(text, SearchQuery("count")).count == 4)
    #expect(matches(text, SearchQuery("count", mode: .matchingWord)).map(\.column) == [0])
    #expect(matches(text, SearchQuery("+=", mode: .matchingWord)).count == 1)
    #expect(matches(text, SearchQuery("Count", isCaseSensitive: true)).isEmpty)
    #expect(matches(text, SearchQuery("(re)?count\\b", mode: .regularExpression)).map(\.column) == [0, 14])
    #expect(SearchQuery("(", mode: .regularExpression).expression == nil)
    #expect(SearchQuery("(").expression != nil)
  }

  @Test func longLinesAreCutAroundTheMatch() {
    let line = String(repeating: "x", count: 400) + "needle" + String(repeating: "y", count: 400)
    let match = matches(line, SearchQuery("needle"))[0]
    #expect(match.column == 400 && match.length == 6)
    #expect(match.preview.hasPrefix("…") && match.preview.hasSuffix("…"))
    #expect(highlighted(match) == "needle")
    #expect(match.preview.count < 200)
  }

  @Test func searchesFilesAndOpenTexts() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ProjectSearchTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "needle\nhay".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try Data([0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0x00]).write(to: root.appendingPathComponent("b.bin"))
    try "hay".write(to: root.appendingPathComponent("c.swift"), atomically: true, encoding: .utf8)
    var results: [FileSearchResult] = []
    ProjectSearch.search(
      SearchQuery("needle"), root: root, paths: ["a.txt", "b.bin", "c.swift", "missing"],
      texts: ["c.swift": "hay\nneedle needle"]
    ) { results += $0 }
    // The binary file is skipped; the open document's unsaved text wins.
    #expect(results.map(\.path) == ["a.txt", "c.swift"])
    #expect(results[1].matches.map(\.line) == [2, 2])
  }
}
