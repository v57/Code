# Code user guide

Code is a folder-based code editor for the Mac. You open a folder, browse it in the sidebar, edit files in tabs, and
run, build, test and debug it from an Xcode-style toolbar, in any of the languages it knows. On iPhone and iPad, Code
has no editor: it runs Build, Test and Clean on your own Macs over SSH and shows you the log, the issues and the files.

## Platforms

- **Mac** (macOS 14 or later, Apple silicon): the full editor, with language servers, formatting, Run, Build, Test,
  debugging with LLDB, and Install, Export and Upload for Xcode apps.
- **iPhone and iPad** (iOS 17 or later): lists the projects on your other devices and runs Build, Test and Clean there.
  You can read the project's files, but not edit them.
- **Linux and Windows**: Code builds there from the same sources, but these builds are early and not released yet.
  This guide describes the Mac, iPhone and iPad apps.

## Pages

- [Getting Started](Getting-Started.md): open your first folder on the Mac, or your first project on iPhone and iPad.
- [Projects and Files](Projects-and-Files.md): the welcome window, the sidebar, hidden files, package dependencies,
  tabs and windows.
- [Editing](Editing.md): the editor, completion, finding, jumping to definitions, Quick Help and the minimap.
- [Languages and Formatting](Languages-and-Formatting.md): language servers, Code's own scanner and Swift model, and
  formatting on save.
- [Run, Build and Test](Run-Build-and-Test.md): schemes, run destinations, the console, issues, breakpoints, and
  Install, Export and Upload.
- [iPhone and iPad](iPhone-and-iPad.md): build and test on your Mac from your iPhone or iPad.
- [Settings](Settings.md): every pane in Code's settings.
- [Privacy and Security](Privacy-and-Security.md): trusting a folder, Restricted Mode, sign-in to your Macs, and what
  Code sends over the network.
- [Keyboard Shortcuts](Keyboard-Shortcuts.md): the Mac app's shortcuts.

## Works with other v57 apps

- **[Vault](https://github.com/v57/Vault/blob/main/docs/README.md)** keeps your projects, devices and SSH hosts. A
  folder you open in Code becomes a project there, so Git, Markdown, Dev and Code on your other devices can show it.
  Code's iPhone and iPad app reaches your Macs through the hosts and device keys in the vault.
- **[Shell](https://github.com/v57/Shell/blob/main/Docs/README.md)**'s smart actions are Code's schemes: the projects
  Code detects are the ones Shell offers to run in a terminal.
- **[Git](https://github.com/v57/Git/blob/main/docs/README.md)**: open a project in Git from the project's menu in
  Code's sidebar, and see the same project list in both apps.
- **Dev** lists the same Xcode projects, with the app icons Code finds for them.
- **[Hub](https://github.com/v57/hub-app/blob/main/docs/README.md)**: a Mac joined to your Hub can be reached from
  your iPhone or iPad through it.
- Code's highlighter also colors code in Git's diffs, Markdown's code blocks and Database's query editors.

## Network

Code contacts no server on its own. Opening a folder you haven't trusted contacts nothing. Trusting a folder lets its
own tools run, and those may fetch packages. iCloud syncs your vault's projects and hosts when it's on. The details
are in [Privacy and Security](Privacy-and-Security.md).

## For developers

Code is built from the libraries in this repository's Swift package, which other apps can use one at a time. Add
the package with `.package(url: "https://github.com/v57/Code.git", branch: "main")` (Swift tools 6.4) and depend on the
products you need. Each page below covers a library's purpose, a small example, its main API, platform notes and
tests.

| Library | Purpose | Platforms | Import |
|---|---|---|---|
| [CodeKit](CodeKit.md) | Most libraries below in one import, plus what connects them: `CodeEditorView`, `ProjectServices`, `DebugSession`, the definition tiers | macOS; Windows, Linux (early); iOS: re-exports only | `import CodeKit` |
| [CodeHighlighting](CodeHighlighting.md) | Languages, file language detection, the incremental highlighter, bracket matching, color schemes and themes; no dependencies | macOS, iOS, Linux, Windows | `import CodeHighlighting` |
| [CodeWorkspace](CodeWorkspace.md) | A project folder: file tree, hidden files, watching, Quick Open index, Find in Project, package dependencies, autosaving documents, tabs, the project's icon | macOS, iOS (no watching), Linux, Windows | `import CodeWorkspace` |
| [CodeFolders](CodeFolders.md) | Folder trust, folder scope, a folder's Xcode workspaces, projects and package; no dependencies | macOS, iOS, Linux, Windows | `import CodeFolders` |
| [CodeEditor](CodeEditor.md) | The AppKit code editor (`CodeTextView`, `CodeEditorScrollView`, SwiftUI `CodeTextEditor`) and neutral editor types | macOS; types everywhere | `import CodeEditor` |
| [CodeMinimap](CodeMinimap.md) | Xcode's minimap with sections and marks | macOS | `import CodeMinimap` |
| [CodeAutocompletion](CodeAutocompletion.md) | The completion list, the provider protocol, fuzzy matching, snippets as placeholders | macOS (list); model everywhere | `import CodeAutocompletion` |
| [CodeActions](CodeActions.md) | Schemes found in a folder, run destinations, running actions with progress and issues, here, over SSH or in a container; the release tools | macOS; iOS (over SSH only); Windows, Linux (early) | `import CodeActions` |
| [CodeActionsUI](CodeActionsUI.md) | CodeActions' sheets and run blocks on ComponentKit | macOS, iOS | `import CodeActionsUI` |
| [CodeProgress](CodeProgress.md) | Progress of staged operations, estimated from their history; no dependencies | macOS, iOS, Linux, Windows | `import CodeProgress` |
| [CodeLSP](CodeLSP.md) | Language server client, the server catalog and a manager per workspace | macOS, Windows, Linux | `import CodeLSP` |
| [CodeFormatting](CodeFormatting.md) | External formatters run before an explicit save | macOS, Linux | `import CodeFormatting` |
| [CodeIcons](CodeIcons.md) | File icons: an SF Symbol, else colored letters | macOS, iOS, Linux, Windows | `import CodeIcons` |
| [CodeScan](CodeScan.md) | A scanner for every language, declarations and a workspace index without a compiler | macOS, iOS, Linux, Windows | `import CodeScan` |
| [CodePretty](CodeScan.md#codepretty) | A formatter for every language that refuses any change to tokens | macOS, iOS, Linux, Windows | `import CodePretty` |
| [CodeServer](CodeScan.md#codeserver) | A language server for every language (`code-lsp`) | macOS, Windows, Linux | `import CodeServer` |
| [CodeSwiftModel](CodeSwiftModel.md) | A Swift code model from source: definitions, completions, references | macOS; Linux, Windows, iOS without the SDK | `import CodeSwiftModel` |

The package also builds three tools: `code-lsp` (CodeServer's server on standard input and output), `code-pretty`
(CodePretty over files and folders) and `swift-model` (measures CodeSwiftModel on a project). Android is not supported
yet by any library.

Run every test with `swift test` at the repository root.
