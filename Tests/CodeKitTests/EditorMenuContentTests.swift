import Foundation
import Testing

@testable import CodeKit

/// The editor menu's parts and words (the boards `code-13` and `code-14`), and Rename's edits.
@Suite struct EditorMenuContentTests {
  let root = URL(fileURLWithPath: "/p")
  var store: URL { root.appendingPathComponent("Sources/Atlas/TripStore.swift") }

  var save: SymbolMenuContent {
    let place = DefinitionPlace(url: store, line: 30, column: 15, name: "save")
    let tripStore = SymbolInfo(kind: .classType, name: "TripStore", keyword: "class", place: DefinitionPlace(url: store, line: 5, column: 19, name: ""), module: "Atlas")
    let symbol = SymbolDescription(
      symbol: SymbolInfo(kind: .function, name: "save()", keyword: "func", place: place, module: "Atlas"),
      declaration: "private func save() throws", parents: [tripStore])
    return SymbolMenuContent.make(
      [SymbolAnswer(tier: .model, isSure: true, symbols: [symbol])], pendingServer: nil, references: nil, file: store, root: root)!
  }

  func context(_ change: (inout EditorMenuContext) -> Void) -> EditorMenuContext {
    var context = EditorMenuContext()
    context.project = "Atlas"
    context.fileName = "TripStore.swift"
    context.commentMarker = "//"
    change(&context)
    return context
  }

  @Test func aSymbolComesFirstThenTheRowsEveryMenuHas() {
    let content = EditorMenuContent.make(
      context {
        $0.selection = "save"
        $0.firstLine = 20
        $0.lastLine = 20
        $0.symbol = save
        $0.symbolTitle = "TripStore.save()"
        $0.clipboard = "x"
      })
    #expect(content.parts.map(\.id) == ["symbol", "clipboard", "find", "lines"])
    #expect(content.parts[0].title == "TripStore.save()")
    #expect(content.parts[0].rows.map(\.title) == ["Jump to Definition", "Show Quick Help", "Find References", "Rename…", "Copy Qualified Name"])
    #expect(content.parts[0].rows[0].preview == "Goes to line 31 in this file.")
    #expect(content.parts[0].rows[0].hint == "⌃⌘J")
    #expect(content.parts[0].rows[3].preview == "Asks for a new name, then changes save() everywhere Atlas uses it.")
    #expect(content.parts[2].rows.map(\.title) == ["Find “save” in Project"])
    #expect(content.parts[3].rows.map(\.title) == ["Comment Line", "Add Breakpoint at Line 20"])
    #expect(content.rows.filter { !$0.isEnabled }.isEmpty)
  }

  @Test func renameSaysWhyItCant() {
    let content = EditorMenuContent.make(
      context {
        $0.selection = "save"
        $0.symbol = save
        $0.renameHint = "Code can’t tell every place that uses save."
        $0.quickHelpHint = "sourcekit-lsp is starting…"
      })
    let rows = content.parts[0].rows
    #expect(rows.first { $0.id == "rename" }?.isEnabled == false)
    #expect(rows.first { $0.id == "rename" }?.preview == "Code can’t tell every place that uses save.")
    #expect(rows.first { $0.id == "help" }?.isEnabled == false)
  }

  @Test func severalLinesStartAtTheClipboardAndGetIndent() {
    let content = EditorMenuContent.make(
      context {
        $0.selection = "let a\nlet b\nlet c\nlet d"
        $0.firstLine = 18
        $0.lastLine = 21
        $0.clipboard = "x"
      })
    #expect(content.parts.map(\.id) == ["clipboard", "lines"])
    #expect(content.parts[1].rows.map(\.title) == ["Comment 4 Lines", "Indent", "Outdent", "Add Breakpoint at Line 18"])
    #expect(content.parts[1].rows[0].preview == "Puts // before lines 18 to 21. Again takes it away.")
    #expect(content.parts[0].rows[0].preview == "Takes the 4 selected lines out and keeps it for Paste.")
  }

  @Test func emptySpaceKeepsCutAndCopyInPlaceDimmed() {
    let content = EditorMenuContent.make(
      context {
        $0.firstLine = 23
        $0.lastLine = 23
        $0.clipboard = "a\nb\nc\nd"
        $0.hasBreakpoint = true
      })
    #expect(content.parts.map(\.id) == ["clipboard", "lines"])
    #expect(content.parts[0].rows.map(\.isEnabled) == [false, false, true])
    #expect(content.parts[0].rows[2].preview == "Puts the 4 copied lines here, at line 23.")
    #expect(content.parts[1].rows.map(\.title) == ["Comment Line", "Remove Breakpoint from Line 23"])
  }

  @Test func anIssueThenALink() {
    let link = URL(string: "https://atlas.example/docs/trips")!
    let content = EditorMenuContent.make(
      context {
        $0.selection = link.absoluteString
        $0.issues = ["Call can throw but is not marked with ‘try’"]
        $0.issueCount = 2
        $0.issueIndex = 1
        $0.link = link
        $0.breakpointsEnabled = false
      })
    #expect(content.parts.map(\.id) == ["issue", "link", "clipboard", "find", "lines"])
    #expect(content.parts[0].title == "Call can throw but is not marked with ‘try’")
    #expect(content.parts[0].rows[0].preview == "Opens Issues at this one, 1 of 2 in TripStore.swift.")
    #expect(content.parts[1].title == "atlas.example/docs/trips")
    #expect(content.parts[1].rows[0].preview == "Opens atlas.example/docs/trips in your browser.")
    #expect(content.parts[4].rows.map(\.id) == ["comment"])
  }

  @Test func copyReferenceIsThePathFromTheProjectAndTheLines() {
    #expect(EditorReference.text(file: store, root: root, firstLine: 20, lastLine: 20) == "Sources/Atlas/TripStore.swift:20")
    #expect(EditorReference.text(file: store, root: root, firstLine: 18, lastLine: 21) == "Sources/Atlas/TripStore.swift:18-21")
    #expect(EditorReference.text(file: URL(fileURLWithPath: "/etc/hosts"), root: root, firstLine: 3, lastLine: 3) == "/etc/hosts:3")
    let content = EditorMenuContent.make(context { $0.reference = "Sources/Atlas/TripStore.swift:20" })
    #expect(content.parts[0].rows.map(\.id) == ["cut", "copy", "paste", "reference"])
    #expect(content.parts[0].rows[3].action == .copyReference("Sources/Atlas/TripStore.swift:20"))
  }

  @Test func aLinkIsFoundWithoutTheSentenceAroundIt() {
    let text = "/// The format (see https://atlas.example/docs/trips). More at http://x.dev/a_(b)!" as NSString
    let first = EditorMenuContent.link(in: text, at: text.range(of: "atlas").location)
    #expect(first?.url.absoluteString == "https://atlas.example/docs/trips")
    #expect(first.map { text.substring(with: $0.range) } == "https://atlas.example/docs/trips")
    #expect(EditorMenuContent.link(in: text, at: text.range(of: "x.dev").location)?.url.absoluteString == "http://x.dev/a_(b)")
    #expect(EditorMenuContent.link(in: text, at: 6) == nil)
  }

  @Test func renameChangesOnlyThePlacesThatStillReadTheName() {
    let url = store
    let text = "func save() {}\n  try save(); saved()\nlet x = save\n"
    let sites = [
      RenameSite(url: url, line: 0, column: 5, length: 4), RenameSite(url: url, line: 1, column: 6, length: 4),
      RenameSite(url: url, line: 2, column: 8, length: 4),
      // The file changed since: this place reads something else.
      RenameSite(url: url, line: 1, column: 13, length: 4),
      RenameSite(url: url, line: 9, column: 0, length: 4),
    ]
    let result = Rename.replacing(sites, in: text, old: "save", with: "store")
    #expect(result.count == 3)
    #expect(result.text == "func store() {}\n  try store(); saved()\nlet x = store\n")
    #expect(Rename.columns(of: "save", in: "  try save(); saved() _save save" as NSString) == [6, 28])
    #expect(["store2", "_x", "2x", "a b", ""].map(Rename.isName) == [true, true, false, false, false])
  }
}
