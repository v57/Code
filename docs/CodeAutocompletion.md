# CodeAutocompletion

## Purpose

CodeAutocompletion is Xcode's completion list over a [CodeEditor](CodeEditor.md) text view: it opens while typing an
identifier or after a trigger character, filters with fuzzy matching (typed letters in bold), shows kind badges,
types and documentation, and inserts the chosen item, with snippet tab stops as Xcode placeholders (`<#name#>`).

Completions come from a `CompletionProvider`: a language server, the file's own words and the language's keywords,
or anything you write. The provider is asked without blocking typing; an answer is filtered with what was typed
since, and an incomplete list is asked for again as the word grows.

It has no language knowledge of its own beyond `WordCompletionProvider`. [CodeKit](CodeKit.md)'s provider combines
Code's scanner, the Swift model and the language server.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeAutocompletion", package: "Code"),
```

```swift
import CodeAutocompletion
import CodeEditor
import CodeHighlighting

@MainActor final class ColorNames: CompletionProvider {
  func completions(for context: CompletionContext) async -> CompletionList? {
    CompletionList(items: ["red", "green", "blue"].map { CompletionItem(label: $0, kind: .value) })
  }
}

@MainActor
func attachCompletion(to editor: CodeEditorScrollView) -> CompletionController {
  // Keep the controller alive as long as the editor.
  CompletionController(textView: editor.textView, provider: WordCompletionProvider())
}
```

Swap providers with `controller.provider = ColorNames()`.

## Main API

Model (platform-neutral)

- `CompletionProvider` (`@MainActor`): `completions(for:)`, optionally `completions(for:update:)` (a quick list first,
  a better one replacing it), `triggerCharacters` (default `["."]`) and `resolve(_:)` (fill in documentation and edits).
- `CompletionContext`: the text, caret `location`, `wordRange`, `word`, `trigger` and `language`.
- `CompletionList`: `items` and `isIncomplete`.
- `CompletionItem`: `label`, `labelDetail`, `detail`, `documentation`, `kind` (`CompletionKind`, the Language Server
  Protocol's kinds), `filterText`, `sortText`, `insertText`, `isSnippet`, `range`, `additionalEdits`
  (`CompletionEdit`, such as an import a server adds), `isDeprecated`, `isPreselected`, `needsResolve`, `payload`,
  and `expansion`.
- `CompletionMatcher.match(_:in:)` and `rank(_:query:)`: fuzzy scoring with matched positions.
- `Snippet.expand(_:)`: LSP snippet syntax to text with placeholders and a caret.
- `WordCompletionProvider`: the file's words (`minimumWordLength`, `scanLimit`) and the language's keywords.
- `Identifier`: identifier characters and `range(endingAt:in:)`.

List (macOS)

- `CompletionController(textView:provider:)`: attaches through the text view's hooks (`commandHandler` takes ↑ ↓
  Return Tab Esc while the list shows, `onTyping`, `onCompletionRequest` for Esc and ⌃Space).
  `show(trigger:)`, `toggle()`, `dismiss()`, `isShowing`, `shownItems`, `suggestsWhileTyping`, `onAccept`.
- `showChoices(...)`, `updateChoices(_:selecting:)`: the same window as a menu of choices (Code's list of definition
  places), updated in place without moving rows the user went past.

## Platform notes

- **macOS**: the list window and controller (AppKit).
- **iOS (iPadOS), Linux, Windows**: the model types build; there is no list UI.
- **Android**: not yet.

## Testing

```bash
swift test --filter CodeAutocompletionTests
```

The tests cover matching and ranking, snippets, the word provider, and the controller and placeholders against a
`CodeTextView` (on a Mac). A test provider is a small class that adopts `CompletionProvider`, as above.

See also the user guide's [Editing](Editing.md#completion).
