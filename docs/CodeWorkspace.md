# CodeWorkspace

## Purpose

CodeWorkspace is the model of an open project folder: its file tree with lazy folders and live updates, hidden files
(`.gitignore` and the user's own choices), the Quick Open index, Find in Project and Replace, the package dependencies
read from manifests and lockfiles, text documents that autosave, tabs with a preview tab, a saved session, and the
project's icon.

CodeWorkspace is not an editor. It has no UI: an editor attaches to a `TextDocument` and supplies its live text (Code's
is [CodeEditor](CodeEditor.md), joined to documents by [CodeKit](CodeKit.md)'s `CodeEditorView`). It resolves no
packages and runs no tools; dependencies are read from files only.

v57's Code, Dev and Git use `ProjectIcon` to find a project's app icon for the shared vault.

## Platforms

<!-- platforms: macos ios=partial linux windows -->

- **macOS**: everything; the watcher uses FSEvents.
- **iOS (iPadOS)**: builds, but `FileWatcher` is a no-op, so changes on disk aren't seen. Code's iPhone and iPad app
  reads remote projects over SFTP and doesn't use a `Workspace`.
- **Windows**: watches with `ReadDirectoryChangesW` (a buffer overflow reports a rescan of the whole folder); a file
  whose encoding Foundation can't detect is read as Windows-1252. Part of Code's early Windows build.
- **Linux**: watches with inotify; part of Code's early Linux build.
- `ProjectIcon.thumbnail` needs ImageIO and returns nil on Linux and Windows.
- **Android**: not yet (the package has no Android setup).

## Getting started

```swift
// Package.swift (the manifest needs Swift tools 6.4)
dependencies: [
  .package(url: "https://github.com/v57/Code.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "CodeWorkspace", package: "Code")]),
]
```

CodeWorkspace depends on [CodeHighlighting](CodeHighlighting.md) (a document's language) and
[CodeFolders](CodeFolders.md). Inside the v57 folder, build against the checkout with `<App>-Local.xcworkspace`, or
`V57_LOCAL=1` for SwiftPM.

```swift
import CodeWorkspace
import Foundation

@MainActor
func editReadme(in folder: URL) async {
  let workspace = Workspace(root: folder)
  let document = workspace.open(folder.appendingPathComponent("README.md"))
  await document.load()  // open(_:) starts loading too; load() is safe to call again
  guard document.content == .text else { return }
  document.replaceText(document.text + "\nOne more line.\n")  // saves after `saveDelay`
  document.flush()  // or write it now

  for result in workspace.index.search("readme") { print(result.path) }
}
```

## Main API

### Open a folder

`Workspace(root:hidesIgnoredFiles:defaults:)` (`@MainActor`, `@Observable`) opens a folder, builds its index, starts
the file watcher, restores the session (tabs, expanded folders) and reads its dependencies. Choices are kept in
`UserDefaults` per folder. It has `root`, `name`, `tree` (`FileTree`), `index` (`FileIndex`), `dependencies`,
`recentFiles`, `statusMessage`, and callbacks `onCloseDocuments`, `onOpenDetached`, `onSelectionChange` and
`onFilesChange`.

```swift
let workspace = Workspace(root: folder, defaults: UserDefaults(suiteName: "test")!)
workspace.onFilesChange = { urls, structural in print(urls.count, structural) }
```

### Tabs and documents

`tabs`, `selectedTabID`, `selectedDocument`, `previewTabID`, `isPreview(_:)`, `detachedDocuments`; `open(_:preview:)`,
`keep(_:)` (a preview tab stays), `close(_:)`, `closeOthers(_:)`, `closeAll()`, `move(_:to:)`, `selectNextTab(offset:)`,
`detach(_:)` and `reattach(_:)` (a document in its own window), `document(for:)`. `flushAll()`, `saveAll()` and
`saveSession()` write the documents and the session.

`TextDocument(url:)` (`@MainActor`, `@Observable`): `load()`, `reloadFromDisk()`, `content` (`.loading`, `.text`,
`.binary`, `.tooLarge(_:)`, `.unreadable(_:)`), `name`, `language`, `encoding` (`displayName` for a status bar),
`saveState` (`.saved`, `.unsaved`, `.failed(_:)`), `revision`, `isMissing`, `highlightsSyntax`, `move(to:)`.

- Editing: the editor sets `textProvider` (and keeps its own state in `editorState`) and calls `markEdited()`;
  `currentText` reads the live text, `text` the last loaded or saved one. `replaceText(_:)` replaces it from outside the
  editor. `pendingSelection` is where to put the caret once the editor shows the text.
- Saving: autosave after `saveDelay` (one second) without formatting; `flush()` writes now; `save()` is an explicit
  save that runs `preSave` first (where formatting goes; `isSaving` meanwhile), then `willSave`. `didSave` and
  `onEdit` report back.
- Files over `maximumSize` (20 MB) don't open; over `highlightingLimit` (2 MB) they open without highlighting.
  Writes are coordinated and atomic, in the file's own encoding.

```swift
let document = workspace.open(url, preview: true)
document.preSave = { /* format the editor's text; the save writes once, after it */ }
document.save()
```

### Files and hidden files

- `Workspace`: `createFile(named:in:)`, `createFolder(named:in:)`, `rename(_:to:)` (each returns the new URL or nil),
  `trash(_:)` (to the Trash; a failure goes to `statusMessage`).
- Hidden files: `visibility` (`FileVisibility`), `hidesIgnoredFilesByDefault`, `setVisible(_:_:)`,
  `addToGitIgnore(_:)`, `restoreDefaultVisibility()`.
- `FileTree`: `root` (`FileNode`), `expanded`, `loadChildren(of:)`, `setExpanded(_:_:)`, `expand(_:)`, `reveal(_:)`,
  `node(for:)`, `reload(directory:)`, `reloadAll()`, `relativePath(of:)`, and the file operations the workspace wraps
  (these throw a `FileTree.OperationError`).
- `FileNode`: `url`, `name`, `isDirectory`, `children`, `parent`, `hiddenReason`, `isHidden`.
- `FileVisibility` (`hidesIgnoredFiles`, `hiddenPaths`, `shownPaths`, `showsHiddenFiles`) and `HiddenReason`: hidden
  by name (`.name`: `.git`, `.svn`, `.hg`, `.DS_Store`), by the user (`.user`) or by a `.gitignore` line
  (`.gitIgnore(_:)`).
- `GitIgnore`: `.gitignore` rules (the folder's, those above it up to the repository root, `.git/info/exclude`);
  `rule(ignoring:isDirectory:)`.
- `FileWatcher(root:latency:fileEvents:handler:)`: batched change events (`Change`: `url`, `structural`, `rescan`) on
  the main actor.

```swift
if let readme = workspace.tree.reveal(folder.appendingPathComponent("docs/README.md")) {
  workspace.setVisible(readme.url, false)
}
```

### Quick Open and Find in Project

- `FileIndex`: every file's relative path, built off the main thread (stops at `FileIndex.limit`, 100,000 files,
  `isTruncated`); `search(_:includingHidden:limit:)`, `matches(_:includingHidden:limit:)` (async),
  `hiddenMatchCount(_:)`, `includesHiddenFiles`, `rebuild()`.
- `FuzzyMatch.match(_:in:)`: the scoring Quick Open uses (`score`, matched `positions`).
- `ProjectSearch.search(_:root:paths:texts:progress:)`: Find in Project over the given paths, with unsaved texts of
  open documents, results in batches (`FileSearchResult`, `SearchMatch`); stops at `matchLimit` (10,000) and skips
  files over `maximumFileSize` (8 MB). `SearchQuery(_:mode:isCaseSensitive:)` with `.containing`, `.matchingWord` or
  `.regularExpression`.
- `ProjectReplace`: `replacingAll(in:query:with:)`, `replacing(...)` one match, `replaceAll(inFileAt:query:with:)`,
  `replace(...)` in a file, and `preview(of:query:replacement:)`.

```swift
let query = SearchQuery("TODO", mode: .matchingWord)
ProjectSearch.search(query, root: workspace.root, paths: workspace.index.paths) { batch in
  for file in batch { print(file.path, file.matches.count) }
}
```

### Dependencies and the project icon

- `DependencyScanner.scan(_:container:home:environment:)`: `PackageDependency` values (`name`, `version`, `isLocal`,
  `ecosystem`, `location` on disk, `source`) from Swift packages, npm/Yarn/pnpm, Cargo, Go, Python, RubyGems,
  Composer, pub, CocoaPods, Hex, NuGet and Gradle/Maven. `DependencyScanner.isManifest(_:)` says which file changes
  matter. On a `Workspace`, `dependencyContainer` (the `ProjectContainer.fileName` the project builds from) picks the
  Swift packages, and `reloadDependencies(after:)` scans again.
- `ProjectIcon.find(in:maxDepth:maxEntries:)`: the project's app icon file (an Icon Composer icon, an asset catalog's
  app icon, an Android launcher icon or an `icon.png`-like file); `ProjectIcon.thumbnail(of:pixels:)` makes a square
  PNG of it.

```swift
let packages = DependencyScanner.scan(folder)
if let icon = ProjectIcon.find(in: folder), let png = ProjectIcon.thumbnail(of: icon, pixels: 64) {
  print(packages.count, png.count)
}
```

The home folder and the folders above it are never walked (`FolderScope` in [CodeFolders](CodeFolders.md)): the index,
watcher, dependency scan and icon search do nothing there.

## Testing

```bash
swift test --filter CodeWorkspaceTests
```

The tests cover the dependency scanner, the file watcher, the project icon, Find in Project and Replace, and the
workspace's tabs and hidden files, on temporary folders. There are no fakes; a `Workspace` over a temporary folder
with its own `UserDefaults(suiteName:)` keeps tests apart.

See also the user guide's [Projects and Files](Projects-and-Files.md).

## Related

- [CodeHighlighting](CodeHighlighting.md): a document's `language`.
- [CodeFolders](CodeFolders.md): `FolderScope` and the `ProjectContainer` dependencies follow.
- [CodeKit](CodeKit.md): `CodeEditorView` shows a `TextDocument`, `ProjectServices` runs a `Workspace`'s services.
- [CodeIcons](CodeIcons.md): icons for the file tree.
- [VaultKit](https://github.com/v57/Vault/blob/main/docs/VaultKit.md): keeps the project icons apps find with `ProjectIcon`.
