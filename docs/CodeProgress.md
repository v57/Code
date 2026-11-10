# CodeProgress

## Purpose

CodeProgress estimates the progress of an operation made of stages: a build, a download and install, a batch of
translations. Each stage's share of the bar comes from how long it took before. While a stage runs, the bar moves
with what it reports (a fraction, or units counted against earlier runs), else with time along a curve that slows
toward a ceiling it never reaches. A stage running slower or faster than usual predicts the same for the run's later
stages on the same resource (CPU, disk, network, remote). The bar never moves back: when estimates change, the rest of
the run fills what is left from where the bar is.

It has no dependencies and no UI; you read snapshots and draw them. Code uses it for builds, and v57's Get and Dev for
downloads, installs, translation batches and server runs.

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

- `ProgressTracker(operation:stages:history:curve:now:)`: one run. Without `stages`, it expects the stages this
  operation ran last time. Stages not in the list can still start, and listed ones can be left out.
  - `begin(_:)` (a stage, finishing the running one), `begin(id:)` (a planned one).
  - `report(fraction:)`, `advance(units:)`, `update(units:of:)`: what the running stage did.
  - `finishStage()`, `complete()` (the plan for next time is the stages that ran), `cancel()` (the running stage
    isn't kept).
  - `snapshot()`: a `ProgressSnapshot` with `fraction` (never lower than before), `stage`, `stageIndex`, `stageCount`,
    `stageFraction` and `remaining`.
  - Safe from any thread.
- `ProgressStage(id:title:resource:timing:size:)`: stages with the same `id` share their history. `timing` is
  `.static` (takes about as long each time; its speed carries over to the run's other stages on its resource) or
  `.dynamic` (takes as long as the work it finds, such as a compile with a cache). `size` lets the history fit a fixed
  cost plus a cost per unit.
- `ProgressResource`: `cpu`, `disk`, `network`, `remote`.
- `ProgressHistory`: durations and plans, newer runs counting more. `ProgressHistory.standard` is a JSON file in the
  app's Application Support folder, saved shortly after changes; `ProgressHistory()` keeps it in memory.
  `duration(for:)`, `units(for:)`, `plan(for:)`, `record(_:for:)`, `recordPlan(_:for:date:)`, `removeAll()`, `save()`.
- `ProgressCurve(knee:ceiling:patience:)`: how a stage measured only by time moves.

## Platform notes

Plain Foundation: macOS, iOS (iPadOS), Linux and Windows. Android: not yet.

## Testing

```bash
swift test --filter CodeProgressTests
```

For your own tests, give the tracker an in-memory `ProgressHistory()` and a `now` closure you control, so time moves
only when the test says.
