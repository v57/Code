# CodeFolders

## Purpose

CodeFolders holds three small things that [CodeActions](CodeActions.md), [CodeWorkspace](CodeWorkspace.md),
[CodeLSP](CodeLSP.md) and [CodeKit](CodeKit.md) share about a folder:

- **Folder trust** (`FolderTrust`): whether a folder's own code may run. A cloned repository can name tools that run
  when it is opened: a `buildServer.json` that SourceKit-LSP runs, a `node_modules/.bin/prettier`, a `Package.swift`
  that `dump-package` evaluates, package URLs that `xcodebuild` resolves. Until the folder is trusted, the libraries
  run none of it.
- **Folder scope** (`FolderScope`): the home folder and the folders above it are never walked.
- **Project containers** (`ProjectContainer`): a folder's Xcode workspaces, projects and Swift package, one of which
  its schemes and dependencies come from.

It has no dependencies and no UI. It does not store anything itself: the host gives trust a store.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeFolders", package: "Code"),
```

```swift
import CodeFolders
import Foundation

// A host that asks before running a folder's code installs a store once, at launch.
// Keep it somewhere the folder's own scripts can't write, such as the keychain.
FolderTrust.use(FolderTrust.Store(load: { loadTrustedPaths() }, save: { saveTrustedPaths($0) }))

let folder = URL(fileURLWithPath: "/path/to/project")
if !FolderTrust.isTrusted(folder) {
  // Ask the person; on yes:
  FolderTrust.trust(folder)
}

let containers = ProjectContainer.list(entries: ["App.xcodeproj", "Package.swift"], in: folder)
let used = ProjectContainer.effective(picked: nil, in: containers)  // the Xcode project, listed first
```

`loadTrustedPaths` and `saveTrustedPaths` stand for your own storage.

## Main API

- `FolderTrust.use(_:)`: turns trust on in this process with a `Store` (`load`, `save`; `Store.memory()` for tests).
  A host that never calls it trusts every folder: v57's Shell and Dev do this, as their folders are the person's own.
- `FolderTrust.isTrusted(_:)`: the folder or a folder above it was trusted, or trust isn't in use. Links are resolved
  first, so a link to a folder isn't a way around it.
- `FolderTrust.trust(_:)`, `distrust(_:)` (also for folders inside it), `trustedFolders`, `isInUse`.
- `FolderScope.isBroad(_:home:)`: the folder is the home folder or above it.
- `ProjectContainer`: `directory`, `fileName`, `kind` (`.workspace`, `.project`, `.package`, each with a `title` and
  `symbolName`), `name`; `list(entries:in:)` (workspaces, then projects, then the package), `effective(picked:in:)`,
  `isContainer(_:)`, `packageManifest`.

What follows from an untrusted folder, in the other libraries: only Code's built-in language server starts; formatters
come from the PATH and skip configurations that are code; nothing runs `xcodebuild -list`,
`-showBuildSettingsForIndex` or `swift package dump-package`. The user guide's
[Privacy and Security](Privacy-and-Security.md#trusting-a-folder) describes it as Code's users see it.

## Platform notes

Plain Foundation: macOS, iOS (iPadOS), Linux and Windows. Android: not yet.

## Testing

CodeFolders has no test target of its own. Folder trust is tested through the language servers
(`swift test --filter LanguageServerManagerTests`), and containers through CodeActions (`swift test --filter
CodeActionsTests`). Use `FolderTrust.Store.memory()` in your own tests. Trust is process-wide and `use(_:)` can't be
undone, so run tests that install a store apart from those that expect every folder to be trusted.
