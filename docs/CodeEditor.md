# CodeEditor

## Purpose

CodeEditor is Code's text editor view for the Mac: an `NSTextView` subclass (`CodeTextView`) with syntax colors,
line numbers, the current line, Xcode's edit assists (auto-closed brackets and quotes, indentation, block indent,
comment toggle, `<#placeholder#>` tokens), inline issues, breakpoints and the debugger's line. Text in, text out.

Colors are never written into the text storage: they are handed to the layout manager at draw time, so only visible
text is colored and undo never sees colors. Highlighting comes from [CodeHighlighting](CodeHighlighting.md)'s
incremental `SyntaxHighlighter`.

It knows nothing about files, saving, language servers or completion. For an editor of a workspace document with
autosave, issues and language services, use [CodeKit](CodeKit.md)'s `CodeEditorView`. The minimap and the completion
list are separate libraries: [CodeMinimap](CodeMinimap.md) and [CodeAutocompletion](CodeAutocompletion.md).

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeEditor", package: "Code"),
.product(name: "CodeHighlighting", package: "Code"),
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

In AppKit, make a `CodeEditorScrollView(text:language:highlightsSyntax:configuration:)` and read or drive its
`textView`.

## Main API

Views (macOS)

- `CodeTextEditor(text:language:configuration:onSelectionChange:)`: the SwiftUI view, bound to a `String`.
- `CodeEditorScrollView`: the scroll view with the text view and its line numbers. Keep one per open file so a file
  brought back keeps its undo history, selection and scroll position.
- `CodeEditorHostView`: shows one editor at a time and moves focus along when tabs change (`show(_:)`).
- `CodeTextView`: the text view.
  - Content: `replaceAllText(_:)`, `setLanguage(_:highlightsSyntax:)`, `configuration`, `tokens(ofLine:)`,
    `lineIndex`, `theme`.
  - Navigation: `goTo(line:column:length:)`, `currentSelection`, `position(of:)`, `location(line:column:)`,
    `rect(ofLine:)`, `identifierRange(at:)`.
  - Marks: `annotations` (`[LineAnnotation]`), `breakpoints`, `breakpointsActive`, `allowsBreakpoints`,
    `toggleBreakpoint(atLine:)`, `executionLine`, `showsAnnotationMessages`.
  - Edits from outside: `applyFormattedText(_:)` (one undoable "Format" edit that touches only what changed).
  - Hooks: `onEdit`, `onTextChange` (a `TextEdit` in line and column terms, for language servers),
    `onSelectionChange`, `onCommandClick`, `onOptionClick`, `onCommandHover`, `onCommandHoverEnd`, `onLayoutChange`,
    `onBreakpointsChange`, `onFocusLoss`, and for a completion list `commandHandler`, `onTyping` and
    `onCompletionRequest`.

Platform-neutral types

- `EditorConfiguration`: theme id, font name and size (`fontSizes` is 8...36), tab width, spaces or tabs, line
  wrapping, line numbers, current line, auto-closed delimiters, trimming trailing whitespace on ⌘S;
  `theme(isDark:)`. Plain values, fit for `@AppStorage`.
- `EditorSelection`: line, column, length and line count, from 1.
- `LineAnnotation`: an issue on a line (from 0), with `Severity` (`error`, `warning`, `note`).
- `TextEdit`: a replaced range in lines and columns.
- `CodeTextEditing`: what project services need from any editor (text, caret, positions, `applyFormattedText`,
  `goTo`, `toggleBreakpoint`, `showQuickHelp`). `CodeTextView` adopts it; CodeKit's Windows and Linux editor does too.
- `EditorPlaceholder`: the `<#` and `#>` markers and `ranges(in:range:)`.

## Platform notes

- **macOS**: the views (AppKit, macOS 14 or later).
- **iOS (iPadOS), Linux, Windows**: only the platform-neutral types build. Code's Windows and Linux builds edit with
  CodeKit's portable editor, a SwiftUI text editor of the highlighted text, behind `CodeTextEditing`.
- **Android**: not yet.

## Testing

```bash
swift test --filter CodeEditorTests
```

`EditAssistTests` drive a `CodeTextView` with typed text and check the edit assists; `EditorTests` cover colors from
the highlighter, indentation, comment toggling, the line index and CRLF files. They need AppKit, so run them on a Mac.

See also the user guide's [Editing](Editing.md).
