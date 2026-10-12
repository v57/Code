import CodeHighlighting
import Foundation
import Testing

@testable import CodeAutocompletion
@testable import CodeEditor

@Suite struct MatcherTests {
  @Test func prefixBeatsWordStartsBeatsScattered() throws {
    let prefix = try #require(CompletionMatcher.match("tab", in: "tableView"))
    let humps = try #require(CompletionMatcher.match("tv", in: "tableView"))
    #expect(prefix.positions == [0, 1, 2])
    #expect(humps.positions == [0, 5])
    let ranked = CompletionMatcher.rank(
      ["notable", "tableView", "takeAllBytes", "table"].map { CompletionItem(label: $0) }
    ) { _ in "tab" }
    #expect(ranked.map(\.index) == [3, 1, 2, 0])
  }

  @Test func caseInsensitiveButExactCaseFirst() {
    let items = ["Count", "count"].map { CompletionItem(label: $0) }
    let ranked = CompletionMatcher.rank(items) { _ in "cou" }
    #expect(ranked.map(\.index) == [1, 0])
  }

  @Test func oneCharacterMatchesOnlyAtWordStarts() {
    #expect(CompletionMatcher.match("v", in: "tableView") != nil)
    #expect(CompletionMatcher.match("b", in: "tableView") == nil)
    #expect(CompletionMatcher.match("bv", in: "tableView") != nil)
    #expect(CompletionMatcher.match("xyz", in: "tableView") == nil)
    #expect(CompletionMatcher.match("s", in: "URLSession")?.positions == [3])
  }

  @Test func emptyQueryKeepsTheProvidersOrder() {
    let items = [
      CompletionItem(label: "b", sortText: "2"), CompletionItem(label: "a", sortText: "3"),
      CompletionItem(label: "c", sortText: "1"),
    ]
    #expect(CompletionMatcher.rank(items) { _ in "" }.map(\.index) == [2, 0, 1])
  }
}

@Suite struct SnippetTests {
  @Test func tabStopsBecomePlaceholders() {
    let expansion = Snippet.expand("foo(${1:x: Int}, ${2:y})$0")
    #expect(expansion.text == "foo(<#x: Int#>, <#y#>)")
    #expect(expansion.caret == nil)
  }

  @Test func emptyTabStopsPlaceTheCaret() {
    #expect(Snippet.expand("foo($1)$0") == Snippet.Expansion(text: "foo()", caret: 4))
    #expect(Snippet.expand("bar()$0") == Snippet.Expansion(text: "bar()", caret: 5))
    #expect(Snippet.expand("plain") == Snippet.Expansion(text: "plain", caret: nil))
  }

  @Test func nestedChoicesVariablesAndEscapes() {
    #expect(Snippet.expand("${1:outer ${2:inner}}").text == "<#outer inner#>")
    #expect(Snippet.expand("${1|one,two|}").text == "<#one#>")
    #expect(Snippet.expand("${TM_SELECTED_TEXT:default} $HOME").text == "default ")
    #expect(Snippet.expand("cost \\$5 \\}").text == "cost $5 }")
    #expect(Snippet.expand("if ${1:cond} {\n\t$0\n}").text == "if <#cond#> {\n\t\n}")
  }

  @Test func placeholdersAreFoundOnOneLine() {
    let text = "f(<#a#>, <#b#>) <# not\n closed #> <##>" as NSString
    let ranges = EditorPlaceholder.ranges(
      in: text, range: NSRange(location: 0, length: text.length))
    #expect(ranges.map { text.substring(with: $0) } == ["<#a#>", "<#b#>"])
  }
}

@MainActor @Suite struct WordProviderTests {
  @Test func wordsOfTheFileAndKeywords() async throws {
    let text = "let total = 1\nlet totalCount = total + 2\ntot" as NSString
    let caret = text.length
    let context = CompletionContext(
      text: text, location: caret, wordRange: NSRange(location: caret - 3, length: 3),
      trigger: .typing, language: CodeHighlighter.spec(forLanguage: "swift"))
    let list = try #require(await WordCompletionProvider().completions(for: context))
    let labels = Set(list.items.map(\.label))
    #expect(labels.contains("total"))
    #expect(labels.contains("totalCount"))
    #expect(!labels.contains("tot"))
    #expect(list.items.contains { $0.label == "let" && $0.kind == .keyword })
    #expect(!list.items.contains { $0.label == "let" && $0.kind == .text })
  }
}

#if canImport(AppKit)
  import AppKit

  /// Answers with fixed items, after a turn (like a server).
  @MainActor private final class FixedProvider: CompletionProvider {
    var items: [CompletionItem]
    var requests: [CompletionContext.Trigger] = []

    init(_ items: [CompletionItem]) { self.items = items }

    var triggerCharacters: Set<String> { ["."] }

    func completions(for context: CompletionContext) async -> CompletionList? {
      requests.append(context.trigger)
      await Task.yield()
      return CompletionList(items: items)
    }
  }

  @MainActor @Suite struct ControllerTests {
    private func makeEditor(_ text: String) -> (CodeTextView, NSWindow) {
      let scroll = CodeEditorScrollView(
        text: text, language: CodeHighlighter.spec(forLanguage: "swift"))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = scroll
      window.makeFirstResponder(scroll.textView)
      let textView = scroll.textView
      textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
      return (textView, window)
    }

    /// Types like the keyboard: the text, then the editor's typing callback.
    private func type(_ text: String, in textView: CodeTextView) {
      for character in text {
        textView.insertText(String(character), replacementRange: textView.selectedRange())
        textView.onTyping?(String(character))
      }
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() } }

    @Test func typingFiltersAndReturnInsertsWithPlaceholders() async {
      let (textView, window) = makeEditor("let x = ")
      defer { window.close() }
      let provider = FixedProvider([
        CompletionItem(
          label: "max(_:_:)", kind: .function, filterText: "max", insertText: "max(${1:a}, ${2:b})",
          isSnippet: true),
        CompletionItem(
          label: "min(_:_:)", kind: .function, filterText: "min", insertText: "min(${1:a}, ${2:b})",
          isSnippet: true), CompletionItem(label: "map", kind: .method),
      ])
      let controller = CompletionController(textView: textView, provider: provider)
      type("m", in: textView)
      await settle()
      #expect(provider.requests == [.typing])
      #expect(controller.shownItems.count == 3)
      type("a", in: textView)
      #expect(controller.shownItems.map(\.label) == ["map", "max(_:_:)"])
      // Down to "max", Return.
      textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
      textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
      #expect(textView.string == "let x = max(<#a#>, <#b#>)")
      #expect(!controller.isShowing)
      // The first placeholder is selected; Tab goes to the next.
      #expect(textView.selectedRange() == NSRange(location: 12, length: 5))
      textView.insertTab(nil)
      #expect(textView.selectedRange() == NSRange(location: 19, length: 5))
      // Typing replaces it.
      textView.insertText("2", replacementRange: textView.selectedRange())
      #expect(textView.string == "let x = max(<#a#>, 2)")
      textView.undoManager?.undo()
    }

    @Test func escapeClosesAndTriggerCharacterOpens() async {
      let (textView, window) = makeEditor("value")
      defer { window.close() }
      let provider = FixedProvider([CompletionItem(label: "count", kind: .property)])
      let controller = CompletionController(textView: textView, provider: provider)
      type(".", in: textView)
      await settle()
      #expect(provider.requests == [.character(".")])
      #expect(controller.shownItems.map(\.label) == ["count"])
      textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
      #expect(!controller.isShowing)
      // Esc again asks for completions.
      textView.complete(nil)
      await settle()
      #expect(controller.isShowing)
      // A non-identifier character closes the list.
      type("(", in: textView)
      #expect(!controller.isShowing)
    }

    @Test func noListWhileTypingInComments() async {
      let (textView, window) = makeEditor("// ")
      defer { window.close() }
      let provider = FixedProvider([CompletionItem(label: "count")])
      let controller = CompletionController(textView: textView, provider: provider)
      type("c", in: textView)
      await settle()
      #expect(provider.requests.isEmpty)
      #expect(!controller.isShowing)
    }

    @Test func replacesTheItemsRangeWithWhatWasTypedSince() async {
      let (textView, window) = makeEditor("obj.")
      defer { window.close() }
      // A server's range: from after the "." to the caret when asked.
      let provider = FixedProvider([
        CompletionItem(
          label: "description", kind: .property, range: NSRange(location: 4, length: 0))
      ])
      let controller = CompletionController(textView: textView, provider: provider)
      controller.show(trigger: .character("."))
      await settle()
      type("des", in: textView)
      #expect(controller.shownItems.count == 1)
      textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
      #expect(textView.string == "obj.description")
    }
  }

  @MainActor @Suite struct PlaceholderTests {
    private func editor(_ text: String) -> CodeTextView {
      let view = CodeTextView(
        text: text, spec: CodeHighlighter.spec(forLanguage: "swift"), highlightsSyntax: true,
        configuration: EditorConfiguration(tabWidth: 4))
      view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
      return view
    }

    @Test func caretInsideSelectsThePlaceholder() {
      let view = editor("f(<#value#>)")
      view.setSelectedRange(NSRange(location: 5, length: 0))
      #expect(view.selectedRange() == NSRange(location: 2, length: 9))
      // At its start the caret stays.
      view.setSelectedRange(NSRange(location: 2, length: 0))
      #expect(view.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func backspaceAfterDeletesIt() {
      let view = editor("f(<#value#>)")
      view.setSelectedRange(NSRange(location: 11, length: 0))
      view.deleteBackward(nil)
      #expect(view.string == "f()")
    }

    @Test func multilineCompletionsTakeTheLinesIndentation() {
      let view = editor("    if")
      view.insertCompletion(
        "if <#condition#> {\n\t\n}", replacing: NSRange(location: 4, length: 2), caret: nil)
      #expect(view.string == "    if <#condition#> {\n        \n    }")
      #expect(view.selectedRange() == NSRange(location: 7, length: 13))
    }

    @Test func additionalEditsGoInTheSameUndo() {
      let view = editor("\nlet d = Da")
      view.insertCompletion(
        "Date", replacing: NSRange(location: 9, length: 2), caret: nil,
        additionalEdits: [(NSRange(location: 0, length: 0), "import Foundation\n")])
      #expect(view.string == "import Foundation\n\nlet d = Date")
      #expect(view.selectedRange().location == (view.string as NSString).length)
    }
  }
#endif
