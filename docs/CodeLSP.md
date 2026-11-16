# CodeLSP

## Purpose

CodeLSP is a Language Server Protocol client: JSON-RPC over a server's standard input and output, the catalog of
servers Code knows and how to install each from its official source, and a manager per workspace that starts the
right server for each opened file, keeps documents in sync and collects diagnostics.

It is not a language server and bundles none. Each server is a separate install the user starts (Homebrew, npm, gems,
.NET tools), or comes with Xcode or a language's SDK. The catalog's last entry is Code's own built-in server
(`code-lsp`, see [CodeScan](CodeScan.md#codeserver)), used for a language with no other server installed.

It has no UI and no editor glue: [CodeKit](CodeKit.md)'s `ProjectServices` feeds it a window's documents and turns its
answers into issues, jumps and completions. The user guide's [Languages and Formatting](Languages-and-Formatting.md)
shows the result.

## Platforms

<!-- platforms: macos ios=partial linux windows -->

- **macOS, Linux, Windows**: the client, its connection, the manager and completions build and run (`#if os(macOS) ||
  os(Windows) || os(Linux)`); part of Code's early Windows and Linux builds there.
- **iOS (iPadOS)**: only the catalog (`LanguageServerCatalog`, `LanguageServerConfiguration`, `ServerInstall`),
  `JSONValue` and `ToolUninstall` build; no server runs.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeLSP", package: "Code"),
```

```swift
import CodeActions  // ShellEnvironment: the login shell's PATH, where servers are installed
import CodeLSP
import Foundation

@MainActor
func definition(in folder: URL, file: URL) async throws -> [LSPLocation] {
  let servers = LanguageServerManager(workspace: folder, environment: ShellEnvironment.shared.variables)
  servers.didOpen(file, text: try String(contentsOf: file, encoding: .utf8))  // starts the file's server
  return await servers.locations(url: file, position: LSPPosition(line: 10, character: 4))
}
```

A server needs a moment to start and index; `states` says where each one is.

## Main API

### Managing a workspace's servers

`LanguageServerManager(workspace:environment:)` (`@MainActor`, `@Observable`) is one per workspace folder; the
environment defaults to the process's. A server runs per project root (the nearest or outermost folder with its
markers), so a folder of several projects gets one per project.

```swift
servers.disabledServerIDs = ["pyright"]  // stops it; .py files go to the next server that takes them
if case .failed(let reason)? = servers.states["gopls"] {
  print(reason, servers.log(for: "gopls"))
  servers.retry("gopls")
}
```

- State: `diagnostics` (by file), `states` (`ServerState` per server id: `notInstalled`, `starting`, `running`,
  `failed`), `activity` ("Indexing"), `log(for:)`, `retry(_:)`, `stopAll()`.
- Settings: `isEnabled`, `disabledServerIDs`, `isTrusted`, `configurations` (the catalog by default),
  `environment`, `setExtraWorkspaceFolders(_:forServer:)` (SourceKit-LSP takes a compilation database for Xcode
  targets this way), `configuration(for:)`, `executable(for:)`.
- `LanguageServerManager.builtInExecutable`: what runs the built-in server. Code sets it to its own binary, which
  serves with `--language-server`. Without it, the built-in server counts as not installed.

### Keeping documents in sync

```swift
servers.didOpen(file, text: text)
servers.didChange(file, changes: [LSPTextChange(range: range, text: "value")]) { editor.text }
servers.didSave(file, text: editor.text)
servers.didClose(file)
```

`didChange(_:changes:text:)` sends incremental `LSPTextChange`s, or the whole text (from the closure) to servers that
take only that (`wantsFullText(_:)`). Also `isOpen(_:)` and `filesChanged(_:forServer:)` for files changed on disk.

### Asking questions

```swift
let declarations = await servers.locations("textDocument/declaration", url: file, position: position)
let help = await servers.hover(url: file, position: position)
let list = await servers.completions(url: file, position: position, trigger: .character("."))
```

- `locations(_:url:position:)`: `textDocument/definition` by default, or another method.
- `hover(url:position:)`: the hover text.
- `completions(url:position:trigger:)` (an `LSPCompletionList` or nil), `resolve(_:url:)`, `supportsCompletion(_:)`,
  `completionTriggerCharacters(_:)`, `isBuiltIn(_:)` (the file's server is `code-lsp`).

### The catalog

```swift
let file = URL(fileURLWithPath: "/path/to/project/main.go")
if let server = LanguageServerCatalog.configuration(for: file) {
  print(server.name, server.languageID(for: file) ?? "", server.install.command ?? server.install.summary)
}
```

- `LanguageServerCatalog.all`: SourceKit-LSP, clangd, gopls, rust-analyzer, the TypeScript language server, Pyright,
  Kotlin, Eclipse JDT, Dart, ZLS, ElixirLS, Ruby LSP, Intelephense, csharp-ls, Lua, Bash and YAML servers, then
  `builtIn`. `configuration(for:in:)` (a file's server by extension), `root(for:configuration:workspace:)`,
  `initializationOptions(for:root:environment:)` (the TypeScript server gets a global TypeScript when the project has
  none).
- `LanguageServerConfiguration`: `id`, `name`, `languages`, `languageIDs` (extension to LSP language id), `command`,
  `arguments`, `rootMarkers`, `prefersOutermostRoot`, `install`, `initializationOptions`; `languageID(for:)`.
- `ServerInstall`: `.xcode`, `.brew`, `.npm`, `.gem`, `.dotnetTool`, `.sdk`, `.builtIn`, with the install `command`
  and a `summary`.
- `ToolUninstall.plan(tool:path:installCommand:home:which:)` returns a `ToolUninstallPlan` (`command(_:note:)` or
  `unknown(_:)`): how to remove an installed server or formatter, from where its binary really is. Nothing is ever
  deleted by path.

### Protocol types

- `LSPPosition` (line and UTF-16 character, from 0), `LSPRange`, `LSPLocation`, `LSPDiagnostic` (`range`, `severity`,
  `message`, `source`), `LSPTextChange`, `LSPCompletionItem`, `LSPCompletionList`, `LSPCompletionTrigger`
  (`invoked`, `character(_:)`, `incomplete`).
- `LanguageServer`: one running server for one project root (`configuration`, `root`, `status`, `activity`, `log`,
  `onDiagnostics`, `onStatusChange`), started by the manager.
- `LSPConnection(executable:arguments:directory:environment:)`: the JSON-RPC connection (`start()`,
  `request(_:_:timeout:)`, `notify(_:_:)`, `stop()`, `onNotification`, `onExit`, `onLog`); `JSONValue` for messages.

## Trust

In a folder that isn't trusted ([CodeFolders](CodeFolders.md)' `FolderTrust`), only the built-in server starts:
the others run what the repository names (SourceKit-LSP a `buildServer.json`, the TypeScript server the repository's
own `node_modules/typescript`, rust-analyzer build scripts and macros). Setting `isTrusted` to false stops the others.
A host that never turns trust on (`FolderTrust.use(_:)`) trusts every folder.

## Adding a server

Add a `LanguageServerConfiguration` to the private `installable` list in `Sources/CodeLSP/LanguageServerCatalog.swift`,
with its file extensions in `languageIDs`, its root markers and how to install it. Servers earlier in the list win
for the same extension; `builtIn` stays last. The built-in server takes every extension the installable servers list,
plus a few formats; a new language with no server needs its extensions there to reach it.

## Testing

```bash
swift test --filter CodeLSPTests
```

`LSPTests` check project roots, language ids and JSON, and talk to a real server (gopls: definitions, diagnostics,
completion) when it is installed. `LanguageServerManagerTests` check that an untrusted folder starts no external
server and that trust covers what is inside a folder; `ToolUninstallTests` check uninstall plans on fake install
folders.

## Related

- [CodeKit](CodeKit.md): `ProjectServices` connects the manager to the editor.
- [CodeScan](CodeScan.md#codeserver): CodeServer, the built-in server (`code-lsp`).
- [CodeFolders](CodeFolders.md): `FolderTrust`, which decides which servers may start.
- [CodeFormatting](CodeFormatting.md): formatters, which `ToolUninstall` also covers.
- [CodeActions](CodeActions.md): `ShellEnvironment`, the login shell's PATH the servers are found on, and
  `XcodeCompilationDatabase` for SourceKit-LSP.
