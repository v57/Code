# CodeIcons

## Purpose

CodeIcons gives every file an icon by its name or extension: an SF Symbol where one fits (the Swift bird, a gear for
settings, a lock for lockfiles, a box for package manifests in the ecosystem's color), otherwise one to three letters
("PY", "C++") in the language's color. Letters also stand in where the symbol is missing, on older systems or
platforms without SF Symbols, so every icon has both. Brand colors are kept and adjusted for contrast when drawn.

CodeIcons is not a language detector: it goes by the file's name (the whole name first, then the extension) and never
reads the file. For a file's language, see [CodeHighlighting](CodeHighlighting.md). It is a small SwiftUI library with
no other dependencies.

## Platforms

<!-- platforms: macos ios linux windows -->

On macOS and iOS (iPadOS) an icon draws its SF Symbol when the system has it, else its letters. On Linux and Windows
it builds on v57/SwiftUI and always draws the letters (`symbol` is nil there). Android: not yet (the package has no
Android setup).

## Getting started

```swift
// Package.swift (the manifest needs Swift tools 6.4)
dependencies: [
  .package(url: "https://github.com/v57/Code.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "CodeIcons", package: "Code")]),
]
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

### Draw an icon

`FileIconView(_:size:)` and `FileIconView(for:isDirectory:size:)` (`size` defaults to 16): the icon, `size` × 1.25
wide by `size` tall, so names beside it stay aligned. A color too light or too dark for the appearance is mixed toward
black or white until it reads.

```swift
FileIconView(.folder, size: 14)
FileIconView(for: URL(fileURLWithPath: "Package.swift"))
```

### Look an icon up

- `FileIcon(for:isDirectory:)` and `FileIcon(fileName:isDirectory:)`: the icon for a file (the plain document when
  nothing matches); `FileIcon(named:)` (nil for an unknown name, such as `"swift"`, `"folder"`, `"package-npm"`).
- `FileIcon.folder`, `FileIcon.file`, `FileIcon.all` (every icon, by name).
- `name` (also `id`), `symbol` (an SF Symbol name, nil when the icon has none or this system lacks it), `letters`,
  `color` (`0xRRGGBB`, nil for the secondary label color).

```swift
let icon = FileIcon(fileName: "main.py")
print(icon.name, icon.letters, icon.symbol ?? "letters only")
```

A new icon is an entry in `FileIcon.catalog` (`FileIcon.swift`) and the names or extensions that use it in
`FileIcon+Lookup.swift`.

## Testing

```bash
swift test --filter CodeIconsTests
```

The tests check that every lookup has an icon, that letters fit and symbols exist, the lookup itself, and that colors
read in both appearances.

## Related

- [CodeHighlighting](CodeHighlighting.md): the languages these icons stand for.
- [CodeWorkspace](CodeWorkspace.md): the file tree they're drawn in.
- [CodeKit](CodeKit.md): re-exports it.
