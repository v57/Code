# CodeMinimap

## Purpose

CodeMinimap draws Xcode's minimap: the file in miniature, each run of text as a rounded bar in its syntax color
instead of tiny text, the visible part framed, section titles from `MARK` comments, and marks for issues,
breakpoints, the debugger's line and search results. Click or drag to scroll.

It reads an editor through a small protocol, so it doesn't depend on [CodeEditor](CodeEditor.md). [CodeKit](CodeKit.md)
puts it beside Code's editor.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeMinimap", package: "Code"),
```

```swift
import AppKit
import CodeHighlighting
import CodeMinimap

@MainActor
func makeMinimap(for editor: some MinimapDataSource, text: NSString) -> MinimapView {
  let minimap = MinimapView(frame: NSRect(x: 0, y: 0, width: MinimapView.defaultWidth, height: 400))
  minimap.dataSource = editor
  minimap.theme = .xcodeLight
  minimap.sections = MinimapSections.find(in: text, lines: LineIndex(text))
  minimap.marks = [MinimapMark(line: 12, kind: .error)]
  return minimap
}
```

Call `invalidateContent()` after the text changes and `refresh()` after the editor scrolls.

## Main API

- `MinimapView`: `dataSource`, `theme` (an `EditorTheme`), `marks`, `sections`, `contentInsets`, `rowHeight`,
  `barHeight`, `columnWidth`, `MinimapView.defaultWidth`; `refresh()`, `invalidateContent()`.
- `MinimapDataSource`: `minimapLineCount`, `minimapRuns(ofLine:)`, `minimapVisibleLines`,
  `minimapScroll(toTopLine:)`.
- `MinimapRun`: a stretch of text on a line (column with tabs expanded, length, `SyntaxKind`).
- `MinimapMark`: a line and a kind (`error`, `warning`, `note`, `breakpoint`, `execution`, `highlight`).
- `MinimapSection` and `MinimapSections.find(in:lines:)`: `// MARK: - Title`, `# MARK: Title`,
  `#pragma mark - Title`, `// region Title`.

## Platform notes

- **macOS**: AppKit only.
- **iOS (iPadOS), Linux, Windows, Android**: the library builds empty.

## Testing

CodeMinimap has no test target of its own. Dragging the minimap is tested in CodeKit
(`swift test --filter MinimapDragTests`), on a Mac.
