# CodeKit

## Purpose

CodeKit is the umbrella: one import for Code's libraries, plus the code that connects them into an editor for a
project window. It re-exports [CodeActions](CodeActions.md), [CodeAutocompletion](CodeAutocompletion.md),
[CodeEditor](CodeEditor.md), [CodeFolders](CodeFolders.md), [CodeFormatting](CodeFormatting.md),
[CodeHighlighting](CodeHighlighting.md), [CodeIcons](CodeIcons.md), [CodeLSP](CodeLSP.md),
[CodeMinimap](CodeMinimap.md), [CodeProgress](CodeProgress.md) and [CodeWorkspace](CodeWorkspace.md).

What it adds:

- `CodeEditorView`: the editor of a workspace document, with autosave, reload from disk, ⌘S trimming and formatting,
  the minimap, inline issues, breakpoints, completion and ⌘-click.
- `ProjectServices`: one project window's services: its schemes and actions, language servers, formatting, issues
  from builds and servers, breakpoints, jumping to definitions with Back and Forward, Quick Help, Open Quickly's
  symbols, and folder trust.
- `DebugSession`: Run under LLDB with the project's breakpoints.
- The definition tiers (`DefinitionTier`, `DefinitionChoices`): asking Code's scanner, a language's model (Swift's or
  Go's) and the language server together, and deciding when to jump and when to show a menu.

CodeKit is not a separate library of features: everything it shows comes from the libraries it re-exports.
[CodeScan](CodeScan.md), CodePretty, [CodeSwiftModel](CodeSwiftModel.md), [CodeGoModel](CodeGoModel.md),
[CodeTypeScriptModel](CodeTypeScriptModel.md), [CodeClangModel](CodeClangModel.md), [CodePythonModel](CodePythonModel.md), [CodeRustModel](CodeRustModel.md), [CodeJavaModel](CodeJavaModel.md), [CodeKotlinModel](CodeKotlinModel.md), [CodeCSharpModel](CodeCSharpModel.md), [CodeDartModel](CodeDartModel.md), [CodePHPModel](CodePHPModel.md), [CodeRubyModel](CodeRubyModel.md), [CodeScalaModel](CodeScalaModel.md) and [CodeLuaModel](CodeLuaModel.md) are used inside but not re-exported; [CodeActionsUI](CodeActionsUI.md) and CodeServer are separate products. It links all of
them, so take a single library when that is all you need.

## Platforms

<!-- platforms: macos ios=partial linux=partial windows=partial -->

- **macOS**: everything.
- **Windows, Linux**: `ProjectServices`, `DebugSession` (LLDB from the PATH) and a portable `CodeEditorView` (a SwiftUI
  text editor of the highlighted text, files up to 400 KB colored, CRLF kept) build and run; no minimap, no completion
  list and no symbol menu. Part of Code's early Windows and Linux builds.
- **iOS (iPadOS)**: the re-exports, `EditorFeatures`, the definition tier types and the symbol menu's content types; no
  `ProjectServices`, editor or debugger. Code's iPhone and iPad app uses CodeActions and CodeActionsUI directly.
- **Android**: not yet (the package has no Android setup).

## Getting started

```swift
// Package.swift (the manifest needs Swift tools 6.4)
dependencies: [
  .package(url: "https://github.com/v57/Code.git", branch: "main"),
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "CodeKit", package: "Code")]),
]
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

### Show a document

`CodeEditorView(document:revision:configuration:services:marks:features:unobscuredFrame:onSelectionChange:onOverlayGeometryChange:)`:
`configuration` is CodeEditor's `EditorConfiguration`; `marks` is any `Int` that changes when issues, breakpoints or
the debugger's line change; `features` (`EditorFeatures`: `showsMinimap`, `showsIssueMessages`, `breakpointsEnabled`,
`suggestsCompletions`); `onOverlayGeometryChange` reports where the minimap and the caret's line are
(`EditorOverlayGeometry`), for views floating over the editor (macOS only; not reported on Windows and Linux yet). The
same initializer exists on Windows and Linux.

```swift
CodeEditorView(
  document: document, revision: document.revision, configuration: EditorConfiguration(tabWidth: 4),
  services: services, marks: services.errorCount, features: EditorFeatures(showsMinimap: false),
  onSelectionChange: { selection in print("Line \(selection.line), column \(selection.column)") })
```

### Project services

`ProjectServices(workspace:settings:)` (`@MainActor`, `@Observable`) makes the window's `actions` (`ActionController`)
and `languageServers` (`LanguageServerManager`) and reads the login shell's environment (`isReady`). `CodeEditorView`
hooks each shown document's `preSave` to it, so ⌘S formats before writing.

`settings` (`ServiceSettings`) turns each service on or off: `actionsEnabled`, `languageServersEnabled`,
`disabledLanguageServers`, formatting (`formatOnSave`, `disabledFormatters`, `formatterRequiresConfig`,
`formatterCommands`, `usesBuiltInFormatter`), `showsMinimap`, `showsInlineIssues`, `showsIssueMessages`,
`breakpointsEnabled`, `suggestsCompletions`, and the tiers: `usesScanner`, `usesSwiftModel`, `usesLanguageModels`
(the other languages' models, Go's) and `serverDefinitions` (`off`, `whenUnsure`, `always`).

```swift
services.settings.serverDefinitions = .always
services.settings.usesSwiftModel = false  // frees the Swift model's memory
```

Tools: `installer` (`ToolInstaller`), `install(_:)` for a `LanguageServerConfiguration` or a
`FormatterConfiguration`; `formatting`; `statusMessage`, `showStatus(_:)`, `reopenShownDocuments()`, `shutDown()`.
For Xcode targets it writes the selected scheme's compiler arguments as a compilation database for SourceKit-LSP,
when the scheme or destination changes and after builds.

### Issues

`issues` (`ProjectIssue`: `url`, `line`, `column`, `severity`, `message`, `source` `.build` or `.languageServer`;
counted once when both report one), `errorCount`, `warningCount`, `annotations(for:)` (CodeEditor's
`LineAnnotation`s for a file), `open(_:)`.

```swift
for issue in services.issues where issue.severity == .error {
  print(issue.url?.lastPathComponent ?? "", issue.line ?? 0, issue.message)
}
```

### Navigation

`jumpToDefinition(in:at:)` (⌘-click), `showQuickHelp(in:at:)` (⌥-click),
`open(_:line:column:length:remember:preview:)`, `goBack()`, `goForward()`, `canGoBack`, `canGoForward`,
`clearHistory()`. `findReferences` is the app's Find in Project, called with a name. On macOS also
`showSymbolInfo(in:at:range:)` and `hideSymbolInfo(in:)` (⌘ held over a symbol), and `showSymbolMenu(in:at:range:fromClick:)`
with `symbolMenuPresenter`, which draws a `SymbolMenu` (its rows are `SymbolMenuContent`).

Open Quickly: `symbols(matching:limit:)` lists the project's declarations from Code's scanner, best first
(`ProjectSymbol`: `name`, `kind`, `containers`, `url`, `line`, `column`, `qualifiedName`); empty when `usesScanner` is
off.

```swift
let found = await services.symbols(matching: "Workspace.open")
if let first = found.first { services.open(first) }
services.open(url, line: 12, column: 5)
if services.canGoBack { services.goBack() }
```

### Breakpoints and debugging

`breakpoints` (lines from 0, by file), `breakpoints(for:)`, `setBreakpoints(_:for:)`, `removeAllBreakpoints()`,
`breakpointsActive`, `hasBreakpoints`; `executionLocation` and `debugger` while debugging.

`DebugSession` (`@MainActor`, `@Observable`): `state` (`starting`, `running`, `paused(reason:)`, `ended`), `frame`;
`continueRunning()`, `stepOver()`, `stepInto()`, `stepOut()`, `pause()`, `stop()`, `sendCommand(_:)` (an `(lldb)`
prompt). Run with breakpoints starts one through `ActionController.stepsOverride`; there is no public initializer.

```swift
services.setBreakpoints([9, 41], for: document.url)
if let debugger = services.debugger, case .paused = debugger.state {
  debugger.stepOver()
}
```

### Folder trust

`isTrusted`, `asksForTrust`, `trustFolder()`, `declineTrust()`. Until the folder is trusted, only Code's built-in
language server runs, formatters skip configurations that are code, and nothing reads the project through
`xcodebuild` or SwiftPM (see [CodeFolders](CodeFolders.md)).

```swift
if services.asksForTrust { services.trustFolder() }
```

### Definition tiers

`DefinitionTier` (`scanner`, `model`, `server`), `ServerDefinitions`, `DefinitionPlace` (`url`, `line` and `column`
from 0, `name`, `preview`), `DefinitionAnswer` (`tier`, `isSure`, `places`).

`DefinitionChoices(asking:decidingTier:)`: `ask(_:)`, `receive(_:from:selectionMoved:selected:)` and
`deadline(selectionMoved:selected:)` return a `Step` (`wait`, `jump`, `show`, `update`, `notFound`, `none`). A sure
answer with one place jumps; guesses, several places or a late answer show a menu, updated as slower tiers answer
without moving rows the user went past.

```swift
var choices = DefinitionChoices(asking: [.scanner, .model])
let place = DefinitionPlace(url: file, line: 41, column: 6, name: "open")
if case .jump(let target) = choices.receive(
  DefinitionAnswer(tier: .model, isSure: true, places: [place]), from: .model)
{
  services.open(target.url, line: target.line + 1, column: target.column + 1)
}
```

The scanner and the language models run in the app's process, each on its own serial queue; a language's model loads
when one of its files is first shown and frees its memory when its setting is off. The language server runs out of
process. The user guide's [Languages and Formatting](Languages-and-Formatting.md#jumping-and-completion) describes the
settings.

## Testing

```bash
swift test --filter CodeKitTests
swift test                          # every test target
swift build --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
```

`CodeKitTests` cover the definition choices, the symbol menu's content, the document editor and dragging the minimap;
the AppKit ones need a Mac. The last line checks that the libraries still build for iOS.

## Related

- [CodeWorkspace](CodeWorkspace.md): the `Workspace` and `TextDocument` a window shows.
- [CodeEditor](CodeEditor.md), [CodeMinimap](CodeMinimap.md), [CodeAutocompletion](CodeAutocompletion.md): the views
  `CodeEditorView` puts together.
- [CodeActions](CodeActions.md), [CodeLSP](CodeLSP.md), [CodeFormatting](CodeFormatting.md): what `ProjectServices`
  runs.
- [CodeScan](CodeScan.md), [CodeSwiftModel](CodeSwiftModel.md), [CodeGoModel](CodeGoModel.md),
  [CodeTypeScriptModel](CodeTypeScriptModel.md), [CodeClangModel](CodeClangModel.md), [CodePythonModel](CodePythonModel.md), [CodeRustModel](CodeRustModel.md),
  [CodeJavaModel](CodeJavaModel.md), [CodeKotlinModel](CodeKotlinModel.md), [CodeCSharpModel](CodeCSharpModel.md),
  [CodeDartModel](CodeDartModel.md), [CodePHPModel](CodePHPModel.md), [CodeRubyModel](CodeRubyModel.md),
  [CodeScalaModel](CodeScalaModel.md), [CodeLuaModel](CodeLuaModel.md): the fast tiers.
- [CodeFolders](CodeFolders.md): folder trust.
