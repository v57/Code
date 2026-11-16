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

CodeFolders is not a sandbox: it decides nothing on its own and blocks nothing itself. The other libraries ask it
before they run a folder's code. It doesn't store anything either: the host gives trust a store. It has no
dependencies and no UI.

## Platforms

<!-- platforms: macos ios linux windows -->

Plain Foundation, the same on every platform it builds for. Android: not yet (the package has no Android setup).

## Getting started

```swift
// Package.swift (the manifest needs Swift tools 6.4)
dependencies: [
  .package(url: "https://github.com/v57/Code.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "CodeFolders", package: "Code")]),
]
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
```

`loadTrustedPaths` and `saveTrustedPaths` stand for your own storage.

## Main API

### Folder trust

- `FolderTrust.use(_:)`: turns trust on in this process with a `Store` (`load`, `save`; `Store.memory()` for tests).
  A host that never calls it trusts every folder: v57's Shell and Dev do this, as their folders are the person's own.
- `FolderTrust.isTrusted(_:)`: the folder or a folder above it was trusted, or trust isn't in use. Links are resolved
  first, so a link to a folder isn't a way around it.
- `FolderTrust.trust(_:)`, `distrust(_:)` (also for folders inside it that were trusted on their own),
  `trustedFolders` (sorted paths, for settings), `isInUse`.

```swift
FolderTrust.use(.memory())
FolderTrust.trust(URL(fileURLWithPath: "/work/app"))
FolderTrust.isTrusted(URL(fileURLWithPath: "/work/app/Sources"))  // true: inside a trusted folder
FolderTrust.distrust(URL(fileURLWithPath: "/work/app"))
```

What follows from an untrusted folder, in the other libraries: only Code's built-in language server starts; formatters
come from the PATH and skip configurations that are code; nothing runs `xcodebuild -list`,
`-showBuildSettingsForIndex` or `swift package dump-package`. The user guide's
[Privacy and Security](Privacy-and-Security.md#trusting-a-folder) describes it as Code's users see it.

### Folder scope

`FolderScope.isBroad(_:home:)`: the folder is the home folder or one above it, up to `/`, with links resolved. Projects
inside the home folder are not broad. Their top level still lists; only walking the whole tree is skipped.

```swift
FolderScope.isBroad(FileManager.default.homeDirectoryForCurrentUser)  // true
```

### Project containers

`ProjectContainer(directory:fileName:)`: `directory`, `fileName`, `id`, `kind` (`.workspace`, `.project`, `.package`,
each with a `title` and `symbolName`), `name` (the file's name without its extension; a package goes by its folder).
`list(entries:in:)` returns the containers among a folder's entries, workspaces first, then projects, then the package;
`effective(picked:in:)` is the picked one while the folder still has it, else the first. `isContainer(_:)` and
`packageManifest` (`"Package.swift"`).

```swift
let containers = ProjectContainer.list(entries: ["App.xcodeproj", "Package.swift", "README.md"], in: folder)
let used = ProjectContainer.effective(picked: nil, in: containers)  // App.xcodeproj
```

## Testing

CodeFolders has no test target of its own. Folder trust is tested through the language servers
(`swift test --filter LanguageServerManagerTests`), and containers through CodeActions (`swift test --filter
BuildSourceTests`). Use `FolderTrust.Store.memory()` in your own tests. Trust is process-wide and `use(_:)` can't be
undone, so run tests that install a store apart from those that expect every folder to be trusted.

## Related

- [CodeActions](CodeActions.md): finds schemes in the picked container, and reads Xcode projects and packages only in
  a trusted folder.
- [CodeFormatting](CodeFormatting.md): skips configurations that are code in an untrusted folder.
- [CodeLSP](CodeLSP.md): starts only the built-in server in an untrusted folder.
- [CodeWorkspace](CodeWorkspace.md): its index, watcher, dependencies and icon search stay out of broad folders.
- [CodeKit](CodeKit.md): `ProjectServices` asks the person to trust a folder.
