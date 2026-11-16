# CodeEditor

## Purpose

CodeEditor is Code's text editor view for the Mac: an `NSTextView` subclass (`CodeTextView`) with syntax colors,
line numbers, the current line, Xcode's edit assists (auto-closed brackets and quotes, indentation, block indent,
comment toggle, `<#placeholder#>` tokens, moving by names and subwords), inline issues, breakpoints and the debugger's
line. Text in, text out.

Colors are never written into the text storage: they are handed to the layout manager at draw time, so only visible
text is colored and undo never sees colors. Highlighting comes from [CodeHighlighting](CodeHighlighting.md)'s
incremental `SyntaxHighlighter`.

CodeEditor is not a document editor. It knows nothing about files, saving, language servers or completion. For an
editor of a workspace document with autosave, issues and language services, use [CodeKit](CodeKit.md)'s
`CodeEditorView`. The minimap and the completion list are separate libraries: [CodeMinimap](CodeMinimap.md) and
[CodeAutocompletion](CodeAutocompletion.md).

## Platforms

<!-- platforms: macos ios=partial linux=partial windows=partial -->

The views are AppKit (macOS 14 or later). On iOS (iPadOS), Linux and Windows only the platform-neutral types build
(`EditorConfiguration`, `EditorSelection`, `LineAnnotation`, `TextEdit`, `CodeTextEditing`, `EditorPlaceholder`).
Code's Windows and Linux builds edit with CodeKit's portable editor, a SwiftUI text editor of the highlighted text,
behind `CodeTextEditing`. Android: not yet (the package has no Android setup).

## Getting started

```swift
// Package.swift (the manifest needs Swift tools 6.4)
dependencies: [
  .package(url: "https://github.com/v57/Code.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [
    .product(name: "CodeEditor", package: "Code"),
    .product(name: "CodeHighlighting", package: "Code"),
  ]),
]
```

A SwiftUI editor over a string:

```swift
import CodeEditor
import CodeHighlighting
import SwiftUI

struct ScriptEditor: View {
  @State private var text = "print(\"Hello\")\n"

  var body: some View {
    CodeTextEditor(
      text: $text, language: CodeHighlighter.spec(forLanguage: "swift"),
      configuration: EditorConfiguration(tabWidth: 4, wrapLines: false))
  }
}
```

## Main API

### SwiftUI and AppKit views (macOS)

- `CodeTextEditor(text:language:configuration:onSelectionChange:)`: the SwiftUI view, bound to a `String`.
- `CodeEditorScrollView(text:language:highlightsSyntax:configuration:)`: the scroll view with the text view
  (`textView`) and its line numbers. Keep one per open file so a file brought back keeps its undo history, selection
  and scroll position.
- `CodeEditorHostView`: shows one editor at a time and moves focus along when tabs change (`show(_:)`,
  `show(_:focusing:)`, `current`); `unobscuredFrame` turns bars floating over the editor into `contentInsets`
  (`onContentInsetsChange`).

```swift
let editor = CodeEditorScrollView(
  text: source, language: Language.detect(url: fileURL), configuration: EditorConfiguration(fontSize: 14))
let host = CodeEditorHostView()
host.show(editor)
editor.textView.goTo(line: 12, column: 1)
```

### The text view (macOS)

`CodeTextView(text:spec:highlightsSyntax:configuration:)`:

- Content: `replaceAllText(_:)`, `setLanguage(_:highlightsSyntax:)`, `configuration`, `spec`, `tokens(ofLine:)`,
  `lineIndex`, `theme` (`onThemeChange`).
- Navigation: `goTo(line:column:length:)`, `currentSelection`, `position(of:)`, `location(line:column:)`,
  `rect(ofLine:)`, `caretLineTextRect()`, `identifierRange(at:)`.
- Edits from outside: `applyFormattedText(_:)` (one undoable "Format" edit that touches only what changed),
  `applyEditedText(_:actionName:)`, `trimTrailingWhitespace()` (edited lines only, as ⌘S does), and
  `insertCompletion(_:replacing:caret:additionalEdits:)` (one undoable change that selects the first placeholder).
- Actions for menus and key bindings: `shiftRight(_:)`, `shiftLeft(_:)`, `toggleComment(_:)`,
  `selectNextPlaceholder(_:)`, `selectPreviousPlaceholder(_:)`, `moveSubwordForward(_:)`, `moveSubwordBackward(_:)`
  and their `…AndModifySelection(_:)` forms.

```swift
let textView = editor.textView
textView.setLanguage(CodeHighlighter.spec(forLanguage: "python"), highlightsSyntax: true)
textView.applyFormattedText(formatted)  // undoable, keeps the caret where the text didn't change
```

### Issues, breakpoints and the debugger (macOS)

`annotations` (`[LineAnnotation]`), `showsAnnotationMessages`, `breakpoints` (lines from 0), `breakpointsActive`,
`allowsBreakpoints`, `toggleBreakpoint(atLine:)`, `onBreakpointsChange`, `executionLine`.

```swift
textView.annotations = [LineAnnotation(line: 4, column: 8, severity: .error, message: "Cannot find 'x' in scope")]
textView.breakpoints = [10, 22]
textView.onBreakpointsChange = { lines in print(lines.sorted()) }
```

### Hooks (macOS)

`onEdit`, `onTextChange` (a `TextEdit` in line and column terms, for language servers), `onSelectionChange`,
`onCommandClick` and `onOptionClick` (a character location; return true when handled), `onCommandHover` and
`onCommandHoverEnd` (with `pinCommandHover(range:keys:)`, `closeCommandHover()`, `commandHover(at:)` and
`isCommandHoverPinned` for a menu under the symbol), `onLayoutChange`, `onFocusLoss`, and for a completion list
`commandHandler`, `onTyping` and `onCompletionRequest`.

```swift
textView.onCommandClick = { location in
  print("jump from", textView.position(of: location))
  return true
}
```

### Platform-neutral types

- `EditorConfiguration(themeID:fontName:fontSize:tabWidth:insertSpaces:wrapLines:showLineNumbers:highlightCurrentLine:autoCloseDelimiters:trimTrailingWhitespace:)`:
  plain values, fit for `@AppStorage`; `fontSizes` is 8...36; `theme(isDark:)` resolves `themeID` with
  `EditorTheme.resolve`.
- `EditorSelection`: `line`, `column`, `length` and `lineCount`, lines and columns from 1.
- `LineAnnotation`: an issue on a line (from 0), with an optional `column` and a `Severity` (`error`, `warning`,
  `note`).
- `TextEdit`: a replaced range in lines and UTF-16 columns from 0, and the new text.
- `CodeTextEditing`: what project services need from any editor (`string`, `lineCount`, `currentSelection`,
  `caretLocation`, `selectionRange`, `isFocused`, `position(of:)`, `identifierRange(at:)`, `applyFormattedText(_:)`,
  `applyEditedText(_:actionName:)`, `goTo(line:column:length:)`, `toggleBreakpoint(atLine:)`,
  `showQuickHelp(_:at:)`). CodeKit makes `CodeTextView` adopt it, and its Windows and Linux editor adopts it too.
- `EditorPlaceholder`: the `open` (`<#`) and `close` (`#>`) markers, `ranges(in:range:)` and `scope(of:in:)` (the lines
  around a range, at most `maxLength` characters either side).

```swift
let text = "foo(<#x#>, <#y#>)" as NSString
let placeholders = EditorPlaceholder.ranges(in: text, range: NSRange(location: 0, length: text.length))  // 2
```

## Testing

```bash
swift test --filter CodeEditorTests
```

`EditAssistTests` drive a `CodeTextView` with typed text and check the edit assists; `EditorTests` cover colors from
the highlighter, indentation, comment toggling, the line index and CRLF files. They need AppKit, so run them on a Mac.
`PlaceholderScopeTests` check `EditorPlaceholder` and run everywhere.

See also the user guide's [Editing](Editing.md).

## Related

- [CodeHighlighting](CodeHighlighting.md): languages, tokens and themes.
- [CodeKit](CodeKit.md): `CodeEditorView`, the editor of a workspace document.
- [CodeAutocompletion](CodeAutocompletion.md): the completion list over a `CodeTextView`.
- [CodeMinimap](CodeMinimap.md): the minimap beside it.
- [CodeWorkspace](CodeWorkspace.md): the documents an editor shows.
