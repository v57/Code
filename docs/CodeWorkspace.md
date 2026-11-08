# CodeWorkspace

## Purpose

CodeWorkspace is the model of an open project folder: its file tree with lazy folders and live updates, hidden files
(`.gitignore` and the user's own choices), the Quick Open index, Find in Project, the package dependencies read from
manifests and lockfiles, text documents that autosave, tabs with a preview tab, a saved session, and the project's
icon.

It has no UI and no editor: an editor attaches to a `TextDocument` and supplies its live text (Code's is
[CodeEditor](CodeEditor.md), joined to documents by [CodeKit](CodeKit.md)'s `CodeEditorView`). It resolves no
packages and runs no tools; dependencies are read from files only.

v57's Code, Dev and Git use `ProjectIcon` to find a project's app icon for the shared vault.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeWorkspace", package: "Code"),
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

Workspace (`@MainActor`, `@Observable`)

- `Workspace(root:hidesIgnoredFiles:defaults:)`: opens a folder, builds its index, starts the file watcher, restores
  the session (tabs, expanded folders) and reads its dependencies. Choices are kept in `UserDefaults` per folder.
- `tree` (`FileTree`), `index` (`FileIndex`), `tabs`, `selectedTabID`, `selectedDocument`, `previewTabID`,
  `dependencies`, `statusMessage`.
- Tabs: `open(_:preview:)`, `keep(_:)`, `close(_:)`, `closeOthers(_:)`, `closeAll()`, `move(_:to:)`,
  `selectNextTab(offset:)`, `detach(_:)` and `reattach(_:)` (a document in its own window), `document(for:)`.
- Saving: `flushAll()`, `saveAll()`, `saveSession()`.
- Files: `createFile(named:in:)`, `createFolder(named:in:)`, `rename(_:to:)`, `trash(_:)` (to the Trash; a failure
  goes to `statusMessage`).
- Hidden files: `visibility`, `setVisible(_:_:)`, `addToGitIgnore(_:)`, `restoreDefaultVisibility()`.
- Callbacks: `onCloseDocuments`, `onOpenDetached`, `onSelectionChange`, `onFilesChange`.

TextDocument (`@MainActor`, `@Observable`)

- `TextDocument(url:)`, `load()`, `reloadFromDisk()`, `content` (`.loading`, `.text`, `.binary`, `.tooLarge`,
  `.unreadable`), `language`, `encoding`, `saveState`, `revision`, `isMissing`, `highlightsSyntax`.
- Editing: the editor sets `textProvider` and calls `markEdited()`; `currentText` reads the live text, `text` the last
  loaded or saved one. `replaceText(_:)` replaces it from outside the editor.
- Saving: autosave after `saveDelay` (one second) without formatting; `flush()` writes now; `save()` is an explicit
  save that runs `preSave` first (where formatting goes). `willSave`, `didSave`, `onEdit`.
- Files over `maximumSize` (20 MB) don't open; over `highlightingLimit` (2 MB) they open without highlighting.
  Writes are coordinated and atomic, in the file's own encoding.

Files

- `FileTree`: `root` (`FileNode`), `expanded`, `loadChildren(of:)`, `setExpanded(_:_:)`, `reveal(_:)`, `node(for:)`,
  `reload(directory:)`, `relativePath(of:)`, and the file operations the workspace wraps.
- `FileNode`: `url`, `name`, `isDirectory`, `children`, `hiddenReason`, `isHidden`.
- `FileVisibility` and `HiddenReason`: hidden by `.gitignore`, by name (`.git`, `.svn`, `.hg`, `.DS_Store`) or by the
  user; `showsHiddenFiles`.
- `GitIgnore`: `.gitignore` rules (the folder's, those above it up to the repository root, `.git/info/exclude`).
- `FileWatcher(root:latency:fileEvents:handler:)`: batched change events (`Change`: `url`, `structural`, `rescan`) on
  the main queue.

Finding

- `FileIndex`: every file's relative path, built off the main thread (stops at `FileIndex.limit`, 100,000 files);
  `search(_:includingHidden:limit:)`, `matches(_:includingHidden:limit:)` (async), `includesHiddenFiles`.
- `FuzzyMatch.match(_:in:)`: the scoring Quick Open uses.
- `ProjectSearch.search(_:root:paths:texts:progress:)`: Find in Project over the given paths, with unsaved texts of open
  documents, results in batches (`FileSearchResult`, `SearchMatch`); `SearchQuery` with `.containing`,
  `.matchingWord` or `.regularExpression` and case sensitivity.

Dependencies and icon

- `DependencyScanner.scan(_:container:home:environment:)`: `PackageDependency` values (name, version or local,
  `Ecosystem`, location on disk) from Swift packages, npm/Yarn/pnpm, Cargo, Go, Python, RubyGems, Composer, pub,
  CocoaPods, Hex, NuGet and Gradle/Maven. `DependencyScanner.isManifest(_:)` says which file changes matter.
- `ProjectIcon.find(in:maxDepth:maxEntries:)`: the project's app icon file (an Icon Composer icon, an asset catalog's
  app icon, an Android launcher icon or an `icon.png`-like file); `ProjectIcon.thumbnail(of:pixels:)` makes a square
  PNG of it.

The home folder and the folders above it are never walked (`FolderScope` in [CodeFolders](CodeFolders.md)): the index,
watcher, dependency scan and icon search do nothing there.

## Platform notes

- **macOS**: everything; the watcher uses FSEvents.
- **iOS (iPadOS)**: builds; `FileWatcher` is a no-op, so changes on disk aren't seen. Code's iPhone and iPad app reads
  remote projects over SFTP and doesn't use a `Workspace`.
- **Windows**: builds and watches with `ReadDirectoryChangesW` (renames and adds are structural, overflows rescan);
  uses Windows' 8-bit encoding where Foundation can't detect one. Part of Code's early Windows build.
- **Linux**: watches with inotify; part of Code's early Linux build.
- `ProjectIcon.thumbnail` needs ImageIO and returns nil on Linux and Windows.
- **Android**: not yet.

## Testing

```bash
swift test --filter CodeWorkspaceTests
```

The tests cover the dependency scanner, the file watcher, the project icon, Find in Project and the workspace's tabs
and hidden files, on temporary folders. There are no fakes; a `Workspace` over a temporary folder with its own
`UserDefaults(suiteName:)` keeps tests apart.

See also the user guide's [Projects and Files](Projects-and-Files.md).
