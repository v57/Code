# CodeActionsUI

## Purpose

CodeActionsUI holds the views every app that runs [CodeActions](CodeActions.md) shows, drawn with v57's ComponentKit
([v57/Component](https://github.com/v57/Component)): the Notarization sheet Export needs, the build number sheet Upload
to App Store opens, an action's log cut into run blocks, and the cards of the run presets bar. v57's Code and Shell
both use it.

It holds no state and runs nothing itself: each view takes what it needs and hands the result back. The toolbar,
console and issue list are the app's own.

## Platforms

<!-- platforms: macos ios linux=partial windows=partial -->

- **macOS, iOS (iPadOS)**: supported; Code's Mac app and its iPhone and iPad app use it. The Notarization sheet is
  only useful on a Mac, where `notarytool` runs.
- **Linux, Windows**: Package.swift adds v57/SwiftUI's `SwiftUI` for it there, and it builds with the rest of the
  package. Off the Mac, CodeActions' `Notarization` reports that notarization needs a Mac, so the Notarization sheet
  has nothing to check.
- **Android**: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeActionsUI", package: "Code"),
```

It depends on CodeActions and ComponentKit. Present its sheets with ComponentKit's `kitSheet(item:)`; each closes
itself before calling back.

```swift
import CodeActions
import CodeActionsUI
import ComponentKit
import SwiftUI

struct UploadRequest: Identifiable {
  let scheme: ActionScheme
  var id: String { scheme.id }
}

struct ProjectView: View {
  let actions: ActionController
  @State private var upload: UploadRequest?

  var body: some View {
    RunBlocks {
      ForEach(ActionRuns.runs(from: actions)) { run in
        RunBlock(
          run.name, command: run.command, id: run.id, systemImage: run.systemImage, status: run.status,
          progress: run.progress, warnings: run.warnings, output: run.output)
      }
    }
    .kitSheet(item: $upload) { request in
      AppStoreUploadView(scheme: request.scheme) { buildNumber in
        actions.perform(.upload, environment: [AppStoreUpload.buildNumberVariable: buildNumber])
      }
    }
  }
}
```

## Main API

### Setting up notarization

`NotarizationSetupView(profile:exportsWhenDone:onDone:)` sets up what Export needs, a Developer ID Application
certificate and a `notarytool` keychain profile: an existing profile (checked with `notarytool`) or a new one from an
app-specific password or an App Store Connect API key. The credentials go straight to `notarytool`, which keeps them in
the keychain; the app gets back only the profile's name in `onDone`. A nil `profile` stands for
`Notarization.defaultProfile`. With `exportsWhenDone`, the primary button says Export instead of Done.

```swift
.kitSheet(item: $notarizationSetup) { request in
  NotarizationSetupView(profile: savedProfile, exportsWhenDone: request.exportsWhenDone) { profile in
    savedProfile = profile
    if request.exportsWhenDone { actions.perform(.export, environment: ["NOTARY_PROFILE": profile]) }
  }
}
```

### Asking for a build number

`AppStoreUploadView(scheme:onUpload:)` asks for the build number an upload carries, prefilled with the commit count of
the scheme's repository (the number Install stamps too), and checks it with `AppStoreUpload.isValidBuildNumber(_:)`.
The example under Getting started shows it.

### Showing a log as run blocks

`ActionRuns` turns an `ActionController`'s logs into `Run` values for ComponentKit's `RunBlocks` and `RunBlock`: a new
block at each command line, the last one carrying the run's state. A long block shows its last `ActionRuns.shownLines`
(400) lines.

```swift
let blocks = ActionRuns.runs(from: actions, filter: "error")  // only the output lines that contain it
let one = actions.current.map { ActionRuns.runs(of: $0) } ?? []
```

- `runs(from:filter:)`: every run the controller keeps, oldest first, after its notes.
- `runs(of:filter:)`: one `ActionRun`'s blocks.
- `status(of:)`: a run's `WorkStatus` for ComponentKit's live icons.
- `Run`: `id`, `name`, `command`, `systemImage`, `status`, `progress`, `warnings`, `output`, `runID` (the
  `ActionRun` it belongs to; nil for the notes).

### Run preset cards

`RunPresetCard(_:inVault:status:isAvailable:)` draws a `RunPreset` as a small card: the action's glyph, its name with
the usual part ("Run Git") in the label colour and the rest secondary, and the vault's glyph for a preset kept there.
Running, it takes the accent's tint; one that can't run now is dimmed. The caller adds the action, the tooltip and
the menu. `RunPresetMoreCard(count:)` is the bar's last card when the presets don't fit.

```swift
RunPresetCard(preset, inVault: true, status: actions.isRunning(tag: preset.name) ? .working(progress: nil) : .idle)
```

`RunPresetCard.symbol(_:)`, `split(_:)` and `vaultSymbol` give the same glyphs and name parts to other views.

## Testing

CodeActionsUI has no test target. The logic behind it is tested in CodeActions
(`swift test --filter NotarizationTests`, and `CodeActionsTests` for build numbers). Check the sheets in an app.

## Related

- [CodeActions](CodeActions.md): the `ActionController`, schemes and checks these views show.
- [ComponentKit: Containers](https://github.com/v57/Component/blob/main/docs/ComponentKit-Containers.md): `kitSheet`.
- [ComponentKit: Data views](https://github.com/v57/Component/blob/main/docs/ComponentKit-Data.md): `RunBlocks` and
  `RunBlock`.
- [ShellIntegrations](https://github.com/v57/Shell/blob/main/Docs/ShellIntegrations.md): Shell's smart actions, which
  show the Notarization sheet for Export.
