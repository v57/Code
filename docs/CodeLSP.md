# CodeLSP

## Purpose

CodeLSP is a Language Server Protocol client: JSON-RPC over a server's standard input and output, the catalog of
servers Code knows and how to install each from its official source, and a manager per workspace that starts the
right server for each opened file, keeps documents in sync and collects diagnostics.

Servers are never bundled. Each is a separate install the user starts (Homebrew, npm, gems, .NET tools), or comes with
Xcode or a language's SDK. The catalog's last entry is Code's own built-in server (`code-lsp`, see
[CodeScan](CodeScan.md#codeserver)), used for a language with no other server installed.

It has no UI and no editor glue: [CodeKit](CodeKit.md)'s `ProjectServices` feeds it a window's documents and turns its
answers into issues, jumps and completions. The user guide's [Languages and Formatting](Languages-and-Formatting.md)
shows the result.

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

Manager (`@MainActor`, `@Observable`)

- `LanguageServerManager(workspace:environment:)`: one per workspace folder. A server runs per project root (the
  nearest or outermost folder with its markers), so a folder of several projects gets one per project.
- Documents: `didOpen(_:text:)`, `didChange(_:changes:text:)` (incremental `LSPTextChange`s, or the whole text for
  servers that take only that: `wantsFullText(_:)`), `didSave(_:text:)`, `didClose(_:)`, `isOpen(_:)`,
  `filesChanged(_:forServer:)`.
- Questions: `locations(_:url:position:)` (`textDocument/definition` by default, or another method),
  `hover(url:position:)`, `completions(url:position:trigger:)`, `resolve(_:url:)`, `supportsCompletion(_:)`,
  `completionTriggerCharacters(_:)`.
- State: `diagnostics` (by file), `states` (`ServerState` per server id: `notInstalled`, `starting`, `running`,
  `failed`), `activity` ("Indexing"), `log(for:)`, `retry(_:)`, `stopAll()`.
- Settings: `isEnabled`, `disabledServerIDs`, `isTrusted`, `setExtraWorkspaceFolders(_:forServer:)` (SourceKit-LSP
  takes a compilation database for Xcode targets this way), `configuration(for:)`, `executable(for:)`.
- `LanguageServerManager.builtInExecutable`: what runs the built-in server. Code sets it to its own binary, which
  serves with `--language-server`. Without it, the built-in server counts as not installed.

Catalog

- `LanguageServerCatalog.all`: SourceKit-LSP, clangd, gopls, rust-analyzer, the TypeScript language server, Pyright,
  Kotlin, Eclipse JDT, Dart, ZLS, ElixirLS, Ruby LSP, Intelephense, csharp-ls, Lua, Bash and YAML servers, then
  `builtIn`. `configuration(for:in:)` (a file's server by extension), `root(for:configuration:workspace:)`,
  `initializationOptions(...)`.
- `LanguageServerConfiguration`: `id`, `name`, `languages`, `languageIDs` (extension to LSP language id), `command`,
  `arguments`, `rootMarkers`, `prefersOutermostRoot`, `install`, `initializationOptions`; `languageID(for:)`.
- `ServerInstall`: `.xcode`, `.brew`, `.npm`, `.gem`, `.dotnetTool`, `.sdk`, `.builtIn`, with the install `command`
  and a `summary`.
- `ToolUninstall.plan(...)` and `ToolUninstallPlan`: how to remove an installed server or formatter.

Protocol types

- `LSPPosition` (line and UTF-16 character, from 0), `LSPRange`, `LSPLocation`, `LSPDiagnostic`, `LSPTextChange`,
  `LSPCompletionItem`, `LSPCompletionList`, `LSPCompletionTrigger`.
- `LanguageServer`: one running server (`status`, `log`, `onDiagnostics`), started by the manager.
- `LSPConnection`: the JSON-RPC connection; `JSONValue` for messages.

## Trust

In a folder that isn't trusted ([CodeFolders](CodeFolders.md)' `FolderTrust`), only the built-in server starts:
the others run what the repository names (SourceKit-LSP a `buildServer.json`, the TypeScript server the repository's
own `node_modules/typescript`, rust-analyzer build scripts and macros). Setting `isTrusted` to false stops the others.
A host that never turns trust on trusts every folder.

## Adding a server

Add a `LanguageServerConfiguration` to the private `installable` list in `Sources/CodeLSP/LanguageServerCatalog.swift`,
with its file extensions in `languageIDs`, its root markers and how to install it. Servers earlier in the list win
for the same extension; `builtIn` stays last. The built-in server takes every extension the installable servers list,
plus a few formats; a new language with no server needs its extensions there to reach it.

## Platform notes

- **macOS**: supported.
- **Linux, Windows**: the client, its connection and completions build and run there; part of Code's early builds.
- **iOS (iPadOS)**: only the catalog and `JSONValue` build; no server runs.
- **Android**: not yet.

## Testing

```bash
swift test --filter CodeLSPTests
```

`LSPTests` check project roots, language ids and JSON, and talk to a real server (gopls: definitions, diagnostics,
completion) when it is installed. `LanguageServerManagerTests` check that an untrusted folder starts no external
server and that trust covers what is inside a folder; `ToolUninstallTests` check uninstall plans on fake install
folders.
