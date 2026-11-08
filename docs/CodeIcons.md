# CodeIcons

## Purpose

CodeIcons gives every file an icon by its name or extension: an SF Symbol where one fits (the Swift bird, a gear for
settings, a lock for lockfiles, a box for package manifests in the ecosystem's color), otherwise one to three letters
("PY", "C++") in the language's color. Letters also stand in where the symbol is missing, on older systems or
platforms without SF Symbols, so every icon has both. Brand colors are kept and adjusted for contrast when drawn.

It is a small SwiftUI library with no other dependencies. It draws icons only; it doesn't detect languages (see
[CodeHighlighting](CodeHighlighting.md)).

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeIcons", package: "Code"),
```

```swift
import CodeIcons
import SwiftUI

struct FileRow: View {
  let url: URL
  let isDirectory: Bool

  var body: some View {
    Label {
      Text(url.lastPathComponent)
    } icon: {
      FileIconView(for: url, isDirectory: isDirectory, size: 14)
    }
  }
}
```

## Main API

- `FileIconView(_:size:)` and `FileIconView(for:isDirectory:size:)`: the icon, `size` × 1.25 wide by `size` tall.
- `FileIcon(for:isDirectory:)`, `FileIcon(fileName:isDirectory:)`, `FileIcon(named:)` (nil for an unknown name),
  `FileIcon.folder`, `FileIcon.file`, `FileIcon.all`.
- `FileIcon.name`, `symbol` (an SF Symbol name, when there is one), `letters`, `color` (`0xRRGGBB`, when it has one).

A new icon is an entry in `FileIcon.catalog` (`FileIcon.swift`) and the names or extensions that use it in
`FileIcon+Lookup.swift`.

## Platform notes

- **macOS, iOS (iPadOS)**: supported.
- **Linux, Windows**: builds on v57/SwiftUI; letters stand in for SF Symbols there.
- **Android**: not yet.

## Testing

```bash
swift test --filter CodeIconsTests
```
