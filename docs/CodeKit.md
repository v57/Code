# CodeKit

## Purpose

CodeKit is the umbrella: one import for Code's libraries, plus the code that connects them into an editor for a
project window. It re-exports [CodeActions](CodeActions.md), [CodeAutocompletion](CodeAutocompletion.md),
[CodeEditor](CodeEditor.md), [CodeFolders](CodeFolders.md), [CodeFormatting](CodeFormatting.md),
[CodeHighlighting](CodeHighlighting.md), [CodeIcons](CodeIcons.md), [CodeLSP](CodeLSP.md),
[CodeMinimap](CodeMinimap.md), [CodeProgress](CodeProgress.md) and [CodeWorkspace](CodeWorkspace.md).
[CodeScan](CodeScan.md), CodePretty and [CodeSwiftModel](CodeSwiftModel.md) are used inside but not re-exported;
[CodeActionsUI](CodeActionsUI.md) and CodeServer are separate products.

What it adds:

- `CodeEditorView`: the editor of a workspace document, with autosave, reload from disk, ⌘S trimming and formatting,
  the minimap, inline issues, breakpoints, completion and ⌘-click.
- `ProjectServices`: one project window's services: its schemes and actions, language servers, formatting, issues
  from builds and servers, breakpoints, jumping to definitions with Back and Forward, Quick Help, and folder trust.
- `DebugSession`: Run under LLDB with the project's breakpoints.
- The definition tiers (`DefinitionTier`, `DefinitionChoices`): asking Code's scanner, the Swift model and the language
  server together, and deciding when to jump and when to show a menu.

Take a single library when that is all you need: CodeKit links all of them.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeKit", package: "Code"),
```

Inside the v57 folder, build against the sibling checkouts with `Code-Local.xcworkspace` (or `<App>-Local.xcworkspace`
in another app), and run SwiftPM with `V57_LOCAL=1`.

```swift
import CodeKit
import SwiftUI

@MainActor @Observable
final class ProjectWindow {
  let workspace: Workspace
  let services: ProjectServices

  init(folder: URL) {
    workspace = Workspace(root: folder)
    services = ProjectServices(workspace: workspace)
  }
}

struct EditorPane: View {
  let window: ProjectWindow

  var body: some View {
    if let document = window.workspace.selectedDocument {
      CodeEditorView(document: document, revision: document.revision, services: window.services)
    } else {
      Text("No file open")
    }
  }
}
```

Pass `document.revision`, so the editor takes text replaced from outside (a reload from disk). Call
`services.shutDown()` when the window closes.

## Main API

Editor

- `CodeEditorView(document:revision:configuration:services:marks:features:unobscuredFrame:onSelectionChange:)`:
  `configuration` is CodeEditor's `EditorConfiguration`; `marks` is any value that changes when issues, breakpoints or
  the debugger's line change; `features` (`EditorFeatures`: minimap, issue messages, breakpoints, completion while
  typing). The same initializer exists on Windows and Linux.

ProjectServices (`@MainActor`, `@Observable`)

- `ProjectServices(workspace:settings:)`: makes the window's `actions` (`ActionController`) and `languageServers`
  (`LanguageServerManager`) and reads the login shell's environment (`isReady`). `CodeEditorView` hooks each shown
  document's `preSave` to it, so ⌘S formats before writing.
- `settings` (`ServiceSettings`): actions, language servers (all or each), formatting (on save, each formatter, "only
  with a config file", custom commands, the built-in formatter), minimap, inline issues, breakpoints, completion
  while typing, and the tiers: `usesScanner`, `usesSwiftModel`, `serverDefinitions` (`off`, `whenUnsure`, `always`).
- Issues: `issues` (`ProjectIssue`, from the build or a language server, counted once when both report one),
  `errorCount`, `warningCount`, `annotations(for:)`, `open(_:)`.
- Navigation: `jumpToDefinition(in:at:)`, `showQuickHelp(in:at:)`, `open(_:line:column:length:remember:)`,
  `goBack()`, `goForward()`, `canGoBack`, `canGoForward`, `clearHistory()`.
- Breakpoints: `breakpoints`, `breakpoints(for:)`, `setBreakpoints(_:for:)`, `removeAllBreakpoints()`,
  `breakpointsActive`, `hasBreakpoints`; `executionLocation` and `debugger` while debugging.
- Trust: `isTrusted`, `asksForTrust`, `trustFolder()`, `declineTrust()`. Until the folder is trusted, only Code's
  built-in language server runs, formatters skip configurations that are code, and nothing reads the project through
  `xcodebuild` or SwiftPM (see [CodeFolders](CodeFolders.md)).
- Tools: `installer` (`ToolInstaller`), `install(_:)` for a language server or a formatter; `statusMessage`,
  `showStatus(_:)`, `shutDown()`.
- For Xcode targets it writes the selected scheme's compiler arguments as a compilation database for SourceKit-LSP,
  when the scheme or destination changes and after builds.

DebugSession (`@MainActor`, `@Observable`)

- `state` (`starting`, `running`, `paused(reason:)`, `ended`), `frame`; `continueRunning()`, `stepOver()`,
  `stepInto()`, `stepOut()`, `pause()`, `stop()`, `sendCommand(_:)` (an `(lldb)` prompt). Run with breakpoints starts
  one through `ActionController.stepsOverride`.

Definition tiers

- `DefinitionTier` (`scanner`, `model`, `server`), `ServerDefinitions`, `DefinitionPlace`, `DefinitionAnswer`.
- `DefinitionChoices(asking:decidingTier:)`: `receive(_:from:selectionMoved:selected:)` and `deadline(...)` return a
  `Step` (`wait`, `jump`, `show`, `update`, `notFound`, `none`). A sure answer with one place jumps; guesses, several
  places or a late answer show a menu, updated as slower tiers answer without moving rows the user went past.

The scanner and the Swift model run in the app's process, each on its own serial queue. The model loads when a Swift
file is first shown and frees its memory when `usesSwiftModel` is off; the language server runs out of process. The
user guide's [Languages and Formatting](Languages-and-Formatting.md#jumping-and-completion) describes the settings.

## Platform notes

- **macOS**: everything.
- **Windows, Linux**: `ProjectServices`, `DebugSession` (LLDB from the PATH) and a portable `CodeEditorView` (a SwiftUI
  text editor of the highlighted text, files up to 400 KB colored, CRLF kept) build and run; no minimap and no
  completion list. Part of Code's early Windows and Linux builds.
- **iOS (iPadOS)**: the re-exports, `EditorFeatures` and the definition tier types; no `ProjectServices`, editor or
  debugger. Code's iPhone and iPad app uses CodeActions and CodeActionsUI directly.
- **Android**: not yet.

## Testing

```bash
swift test --filter CodeKitTests
swift test                          # every test target
swift build --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
```

`CodeKitTests` cover the definition choices, the document editor and dragging the minimap; the AppKit ones need a Mac.
The last line checks that the libraries still build for iOS.
