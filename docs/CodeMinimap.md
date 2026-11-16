# CodeMinimap

## Purpose

CodeMinimap draws Xcode's minimap: the file in miniature, each run of text as a rounded bar in its syntax color
instead of tiny text, the visible part framed, section titles from `MARK` comments, and marks for issues,
breakpoints, the debugger's line and search results. Click or drag to scroll.

CodeMinimap is not tied to an editor: it reads one through a small protocol, `MinimapDataSource`, so it doesn't depend
on [CodeEditor](CodeEditor.md). It doesn't highlight either: the data source hands it runs that already have a
`SyntaxKind`. [CodeKit](CodeKit.md) puts it beside Code's editor.

## Platforms

<!-- platforms: macos -->

The minimap is AppKit, macOS only. On iOS (iPadOS), Linux and Windows the library builds with only `MinimapLayout`,
whose `columnWidth` is 0 there, so views laid out beside an editor need no `#if`. Android: not yet (the package has no
Android setup).

## Getting started

```swift
// Package.swift (the manifest needs Swift tools 6.4)
dependencies: [
  .package(url: "https://github.com/v57/Code.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "CodeMinimap", package: "Code")]),
]
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

### The view

`MinimapView` (an `NSView`): `dataSource`, `theme` (an `EditorTheme`), `marks`, `sections`, `contentInsets`,
`rowHeight` (3), `barHeight` (2), `columnWidth` (1.25), `MinimapView.defaultWidth` (120); `refresh()` after scrolling,
`invalidateContent()` after the text or colors change. `MinimapLayout.columnWidth` is the room it takes, on every
platform.

```swift
minimap.theme = .xcodeDark
minimap.rowHeight = 4
minimap.invalidateContent()
```

### The data source

`MinimapDataSource` (`@MainActor`): `minimapLineCount`, `minimapRuns(ofLine:)`, `minimapVisibleLines` (a
`ClosedRange<Double>`, fractional at the edges), `minimapScroll(toTopLine:)`. A `MinimapRun` is a stretch of text on a
line: `column` (with tabs expanded), `length` and `kind` (`SyntaxKind`).

```swift
@MainActor final class Lines: MinimapDataSource {
  var lines: [String] = []
  var top = 0.0
  var minimapLineCount: Int { lines.count }
  func minimapRuns(ofLine line: Int) -> [MinimapRun] {
    [MinimapRun(column: 0, length: lines[line].count, kind: .plainText)]
  }
  var minimapVisibleLines: ClosedRange<Double> { top...(top + 40) }
  func minimapScroll(toTopLine line: Double) { top = line }
}
```

### Marks and sections

- `MinimapMark(line:kind:)`: kinds `error`, `warning`, `note`, `breakpoint`, `execution`, `highlight`.
- `MinimapSection(line:title:hasSeparator:)` and `MinimapSections.find(in:lines:)`: `// MARK: - Title`,
  `# MARK: Title`, `#pragma mark - Title`, `// region Title` (a `-` draws a separator above the title).

```swift
minimap.marks = searchLines.map { MinimapMark(line: $0, kind: .highlight) } + [MinimapMark(line: 30, kind: .breakpoint)]
```

## Testing

CodeMinimap has no test target of its own. Dragging the minimap is tested in CodeKit
(`swift test --filter MinimapDragTests`), on a Mac.

## Related

- [CodeHighlighting](CodeHighlighting.md): `SyntaxKind`, `EditorTheme` and `LineIndex`.
- [CodeEditor](CodeEditor.md): the editor it usually sits beside.
- [CodeKit](CodeKit.md): `CodeEditorView` shows it, with the project's issues and breakpoints as marks.
