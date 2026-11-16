# CodeProgress

## Purpose

CodeProgress estimates the progress of an operation made of stages: a build, a download and install, a batch of
translations. Each stage's share of the bar comes from how long it took before. While a stage runs, the bar moves
with what it reports (a fraction, or units counted against earlier runs), else with time along a curve that slows
toward a ceiling it never reaches. A stage running slower or faster than usual predicts the same for the run's later
stages on the same resource (CPU, disk, network, remote). The bar never moves back: when estimates change, the rest of
the run fills what is left from where the bar is.

It doesn't measure anything itself and has no UI: the caller says when stages start and how far they got, and reads
snapshots to draw. It has no dependencies. Code uses it for builds, and v57's Get and Dev for downloads, translation
batches and server runs.

## Platforms

<!-- platforms: macos ios linux windows -->

Plain Foundation, with no platform code: the same on macOS, iOS (iPadOS), Linux and Windows. `ProgressHistory.standard`
keeps its file in the user's Application Support folder as Foundation finds it on each system. Android: not yet.

## Getting started

```swift
.package(url: "https://github.com/v57/Code.git", branch: "main"),
// in the target:
.product(name: "CodeProgress", package: "Code"),
```

```swift
import CodeProgress

let tracker = ProgressTracker(
  operation: "install MyApp",
  stages: [
    ProgressStage(id: "download MyApp.zip", title: "Download", resource: .network, size: 48_000_000),
    ProgressStage(id: "unpack MyApp.zip", title: "Unpack", resource: .disk),
  ])

tracker.begin(id: "download MyApp.zip")
tracker.report(fraction: 0.5)  // half the bytes are in
let snapshot = tracker.snapshot()  // read on a timer: it moves with time
print(snapshot.fraction ?? 0, snapshot.stage?.title ?? "", snapshot.remaining ?? 0)

tracker.begin(id: "unpack MyApp.zip")
tracker.complete()  // keeps the durations for next time
```

The first run has no history: `fraction` may be nil until a stage reports one. Later runs estimate from the history.

## Main API

### Tracking a run

`ProgressTracker(operation:stages:history:curve:now:)` is one run. Without `stages`, it expects the stages this
operation ran last time. Stages not in the list can still start, and listed ones can be left out. Every method is
safe from any thread.

```swift
let build = ProgressTracker(operation: "build MyApp")  // the stages of the last build
build.begin(ProgressStage(id: "swift build MyApp", title: "Compile", timing: .dynamic))
build.update(units: 12, of: 40)  // 12 of 40 files compiled
build.finishStage()
build.cancel()  // stopped: the running stage isn't kept
```

- `begin(_:)` (a stage, finishing the running one), `begin(id:)` (a planned one).
- `report(fraction:)`, `advance(units:)`, `update(units:of:)`: what the running stage did.
- `finishStage()`, `complete()` (the plan for next time is the stages that ran), `cancel()` (the running stage isn't
  kept).
- `snapshot()`: a `ProgressSnapshot` with `fraction` (never lower than before), `stage`, `stageIndex`, `stageCount`,
  `stageFraction` and `remaining`.
- `operation`, `history`, `curve`.

### Describing stages

`ProgressStage(id:title:resource:timing:size:)`: stages with the same `id` share their history, in one run and across
runs; `title` defaults to the id.

```swift
let translate = ProgressStage(id: "translate de", title: "German", resource: .remote, timing: .static, size: 1_200)
```

- `timing` (`ProgressStage.Timing`) is `.static` (takes about as long each time; its speed carries over to the run's
  other stages on its resource) or `.dynamic` (takes as long as the work it finds, such as a compile with a cache).
- `size` lets the history fit a fixed cost plus a cost per unit.
- `ProgressResource`: `cpu`, `disk`, `network`, `remote`.

### Keeping history

`ProgressHistory` keeps durations and plans, newer runs counting more. `ProgressHistory.standard` is a JSON file in
the app's Application Support folder, saved a second after changes; `ProgressHistory(fileURL:)` reads and writes
another file, and `ProgressHistory()` keeps it in memory.

```swift
let history = ProgressHistory(fileURL: nil)  // in memory, for a test
let tracker = ProgressTracker(operation: "sync", history: history)
```

- `duration(for:)`, `units(for:)`, `plan(for:)`, `record(_:for:)` (a `Sample`), `recordPlan(_:for:date:)`,
  `removeAll()`, `save()`, `fileURL`.
- `ProgressHistory.samplesKept` (12 per stage) and `entriesKept` (400 stages and operations, the ones used longest ago dropped first).

### Shaping time-only progress

`ProgressCurve(knee:ceiling:patience:)` is how a stage measured only by time moves (defaults 0.8, 0.95 and 0.6);
`fraction(elapsed:expected:)` gives its value.

```swift
let curve = ProgressCurve(ceiling: 0.9)
let tracker = ProgressTracker(operation: "notarize", curve: curve)
```

## Testing

```bash
swift test --filter CodeProgressTests
```

For your own tests, give the tracker an in-memory `ProgressHistory()` and a `now` closure you control, so time moves
only when the test says.

## Related

- [CodeActions](CodeActions.md): every action's steps are stages (`ActionStep`'s `resource` and `timing`), and
  `ActionController.progressHistory` keeps their history.
