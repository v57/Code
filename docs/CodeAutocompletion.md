# CodeAutocompletion

## Purpose

CodeAutocompletion is Xcode's completion list over a [CodeEditor](CodeEditor.md) text view: it opens while typing an
identifier or after a trigger character, filters with fuzzy matching (typed letters in bold), shows kind badges,
types and documentation, and inserts the chosen item, with snippet tab stops as Xcode placeholders (`<#name#>`).

Completions come from a `CompletionProvider`: a language server, the file's own words and the language's keywords,
or anything you write. The provider is asked without blocking typing; an answer is filtered with what was typed
since, and an incomplete list is asked for again as the word grows.

CodeAutocompletion is not a source of completions. It has no language knowledge of its own beyond
`WordCompletionProvider`. [CodeKit](CodeKit.md)'s provider combines Code's scanner, the language models (Swift's and
Go's) and the language server.

## Platforms

<!-- platforms: macos ios=partial linux=partial windows=partial -->

The list window and `CompletionController` are AppKit, macOS only. On iOS (iPadOS), Linux and Windows the model types
build (items, providers, matching, snippets, the word provider), with no list UI. Android: not yet (the package has no
Android setup).

## Getting started

```swift
// Package.swift (the manifest needs Swift tools 6.4)
dependencies: [
  .package(url: "https://github.com/v57/Code.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "CodeAutocompletion", package: "Code")]),
]
```

```swift
import CodeAutocompletion
import CodeEditor

@MainActor
func attachCompletion(to editor: CodeEditorScrollView) -> CompletionController {
  // Keep the controller alive as long as the editor.
  CompletionController(textView: editor.textView, provider: WordCompletionProvider())
}
```

## Main API

### Write a provider

- `CompletionProvider` (`@MainActor`, a class): `completions(for:)`, optionally `completions(for:update:)` (a quick
  list first, a better one replacing it), `triggerCharacters` (default `["."]`) and `resolve(_:)` (fill in
  documentation and edits; default nil).
- `CompletionContext`: the `text`, caret `location`, `wordRange`, `word`, `trigger` (`.invoked`, `.typing`,
  `.character(_:)`, `.incomplete`) and `language`.
- `CompletionList(items:isIncomplete:)`.
- `CompletionItem(label:labelDetail:detail:documentation:kind:filterText:sortText:insertText:isSnippet:range:additionalEdits:isDeprecated:isPreselected:needsResolve:payload:)`:
  everything but `label` is optional. `kind` is a `CompletionKind` (the Language Server Protocol's kinds, same raw
  values); `additionalEdits` are `CompletionEdit`s (such as an import a server adds); `expansion` is the text with
  snippet tab stops as placeholders.

```swift
@MainActor final class ColorNames: CompletionProvider {
  func completions(for context: CompletionContext) async -> CompletionList? {
    CompletionList(items: ["red", "green", "blue"].map { CompletionItem(label: $0, kind: .value) })
  }
}
```

### Show the list (macOS)

`CompletionController(textView:provider:)` attaches through the text view's hooks (`commandHandler` takes ↑ ↓ Return
Tab Esc while the list shows, `onTyping`, `onCompletionRequest` for Esc and ⌃Space). `provider`, `show(trigger:)`,
`toggle()`, `dismiss()`, `isShowing`, `shownItems`, `suggestsWhileTyping` (off: only Esc and ⌃Space open it),
`onAccept`.

The same window also shows a menu of choices (Code's list of definition places): `showChoices(_:at:selecting:onPick:)`,
`updateChoices(_:selecting:)` (updated in place without moving rows the user went past), `isShowingChoices`,
`choicesSelectionMoved`, `selectedChoice`.

```swift
controller.provider = ColorNames()
controller.suggestsWhileTyping = false
let places = ["Workspace.swift:12", "TextDocument.swift:40"].map { CompletionItem(label: $0) }
controller.showChoices(places, at: caret) { index in print("picked", index) }
```

### Matching, snippets and words

- `CompletionMatcher.match(_:in:)` (a `Match` with `score` and matched `positions`) and `rank(_:query:)`: fuzzy
  scoring; ranked best match first, then the provider's sort text, then shorter labels.
- `Snippet.expand(_:)`: LSP snippet syntax to an `Expansion` (`text` with placeholders, and a `caret`).
- `WordCompletionProvider`: the file's words and the language's keywords (`minimumWordLength`, 3; `scanLimit`, one
  million characters); `WordCompletionProvider.items(in:around:excluding:language:minimumLength:limit:)` for the same
  list without a controller.
- `Identifier`: identifier characters (`contains(_:)`, `isDigit(_:)`) and `range(endingAt:in:)`.

```swift
let match = CompletionMatcher.match("tv", in: "tableView")  // positions [0, 5]: the humps t and V
let snippet = Snippet.expand("print(${1:value})")          // text "print(<#value#>)"
```

## Testing

```bash
swift test --filter CodeAutocompletionTests
```

The tests cover matching and ranking, snippets, the word provider, and the controller and placeholders against a
`CodeTextView` (on a Mac). A test provider is a small class that adopts `CompletionProvider`, as above.

See also the user guide's [Editing](Editing.md#completion).

## Related

- [CodeEditor](CodeEditor.md): the `CodeTextView` the list attaches to.
- [CodeHighlighting](CodeHighlighting.md): a context's `language` (its keywords feed the word provider).
- [CodeKit](CodeKit.md): the provider Code uses, from its tiers and the language server.
- [CodeLSP](CodeLSP.md): language servers' completions.
