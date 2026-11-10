# CodeActionsUI

## Purpose

CodeActionsUI holds the views every app that runs [CodeActions](CodeActions.md) shows, drawn with v57's ComponentKit
([v57/Component](https://github.com/v57/Component)): the Notarization sheet Export needs, the build number sheet Upload
to App Store opens, and an action's log cut into run blocks. v57's Code and Shell both use it.

It holds no state and runs nothing itself: each view takes what it needs and hands the result back. The toolbar,
console and issue list are the app's own.

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

- `NotarizationSetupView(profile:exportsWhenDone:onDone:)`: sets up what Export needs, a Developer ID Application
  certificate and a `notarytool` keychain profile: an existing profile (checked with `notarytool`) or a new one from an
  app-specific password or an App Store Connect API key. The credentials go straight to `notarytool`, which keeps them
  in the keychain; the app gets back only the profile's name in `onDone`. With `exportsWhenDone`, the primary button
  says Export.
- `AppStoreUploadView(scheme:onUpload:)`: asks for the build number an upload carries, prefilled with the commit count
  of the scheme's repository (the number Install stamps too), and checks it with `AppStoreUpload.isValidBuildNumber`.
- `ActionRuns.runs(from:filter:)`: an `ActionController`'s log as `Run` values for ComponentKit's `RunBlock`: a new
  block at each command line, the last one carrying the action's state. A long block shows its last
  `ActionRuns.shownLines` (400) lines.

## Platform notes

- **macOS, iOS (iPadOS)**: supported; Code's Mac app and its iPhone and iPad app use it. The Notarization sheet is
  only useful on a Mac, where `notarytool` runs.
- **Linux, Windows**: Package.swift adds v57/SwiftUI for it there, so it is meant to build; not tested on its own.
- **Android**: not yet.

## Testing

CodeActionsUI has no test target. The logic behind it is tested in CodeActions
(`swift test --filter NotarizationTests`, and `CodeActionsTests` for build numbers). Check the sheets in an app.
