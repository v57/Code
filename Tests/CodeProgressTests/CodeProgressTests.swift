import Foundation
import Testing

@testable import CodeProgress

final class Clock: @unchecked Sendable {
  var date = Date(timeIntervalSinceReferenceDate: 0)
  func advance(_ seconds: TimeInterval) { date += seconds }
}

func tracker(
  _ stages: [ProgressStage], _ history: ProgressHistory, _ clock: Clock, operation: String = "op"
) -> ProgressTracker {
  ProgressTracker(operation: operation, stages: stages, history: history) { clock.date }
}

func near(_ value: Double?, _ expected: Double, _ tolerance: Double = 0.001) -> Bool {
  guard let value else { return false }
  return abs(value - expected) < tolerance
}

@Suite struct ProgressTrackerTests {
  let download = ProgressStage(id: "download", resource: .network)
  let install = ProgressStage(id: "install", resource: .disk)

  @Test func installation() {
    let history = ProgressHistory()
    let clock = Clock()

    // First run: nothing to estimate from, so only finished stages count.
    let first = tracker([download, install], history, clock)
    first.begin(download)
    #expect(first.snapshot().fraction == nil)
    clock.advance(10)
    first.begin(install)
    #expect(first.snapshot().fraction == 0.5)
    clock.advance(20)
    #expect(first.snapshot().fraction == 0.5)
    first.complete()
    #expect(first.snapshot().fraction == 1)

    // Second run: the download is a third of the run, the install two.
    let second = tracker([download, install], history, clock)
    second.begin(download)
    clock.advance(8)
    #expect(near(second.snapshot().fraction, 0.8 / 3))
    #expect(near(second.snapshot().remaining, 22))
    // The download takes twice as long: it slows down toward its end.
    clock.advance(12)
    #expect(near(second.snapshot().fraction, 0.9 / 3))
    second.begin(install)
    #expect(near(second.snapshot().fraction, 1.0 / 3))
    // The slow network says nothing about the disk: still 20 s.
    #expect(near(second.snapshot().remaining, 20))
    clock.advance(10)
    #expect(near(second.snapshot().fraction, 2.0 / 3))
    second.complete()
  }

  @Test func slowStageSlowsTheSameResource() {
    let history = ProgressHistory()
    let extras = ProgressStage(id: "extras", resource: .network)
    for (stage, seconds) in [(download, 10.0), (extras, 10), (install, 20)] {
      history.record(.init(duration: seconds), for: stage.id)
    }
    let clock = Clock()
    let run = tracker([download, extras, install], history, clock)
    run.begin(download)
    clock.advance(20)
    run.begin(extras)
    // The download ended a quarter in (10 of 40 s): the next download is
    // expected to take 20 s too, the install still 20.
    #expect(near(run.snapshot().fraction, 0.25))
    #expect(near(run.snapshot().remaining, 40))
    clock.advance(10)
    #expect(near(run.snapshot().fraction, 0.25 + 0.75 * 0.25))
  }

  @Test func dynamicStageEndingEarlyDoesNotJump() {
    let history = ProgressHistory()
    let compile = ProgressStage(id: "compile", timing: .dynamic)
    let package = ProgressStage(id: "package", resource: .disk)
    history.record(.init(duration: 90), for: compile.id)
    history.record(.init(duration: 10), for: package.id)
    let clock = Clock()
    let run = tracker([compile, package], history, clock)
    run.begin(compile)
    clock.advance(45)
    #expect(near(run.snapshot().fraction, 0.45))
    // The build cache made it quick: the bar stays and the package stage
    // takes the rest.
    run.begin(package)
    #expect(near(run.snapshot().fraction, 0.45))
    clock.advance(5)
    #expect(near(run.snapshot().fraction, 0.45 + 0.55 * 0.5))
  }

  @Test func repeatedStagesLearnFromEachOther() {
    let history = ProgressHistory()
    let batch = ProgressStage(id: "batch", resource: .remote, timing: .dynamic)
    history.record(.init(duration: 10), for: batch.id)
    let clock = Clock()
    let run = tracker([batch, batch, batch], history, clock)
    run.begin(batch)
    clock.advance(20)
    run.begin(batch)
    // The first batch took twice as long: so should the others.
    #expect(near(run.snapshot().remaining, 40))
  }

  @Test func countsUnitsAgainstEarlierRuns() {
    let history = ProgressHistory()
    let build = ProgressStage(id: "build", timing: .dynamic)
    history.record(.init(duration: 60, units: 300), for: build.id)
    history.record(.init(duration: 5, units: 10), for: build.id)
    // An incremental build doesn't shrink what a full one counts.
    #expect(history.units(for: build) == 300)
    let clock = Clock()
    let run = tracker([build], history, clock)
    run.begin(build)
    run.advance(units: 150)
    #expect(run.snapshot().stageFraction == 0.5)
    run.report(fraction: 0.75)
    #expect(run.snapshot().fraction == 0.75)
  }

  @Test func growingTotalsDontOutrunEarlierRuns() {
    let history = ProgressHistory()
    let build = ProgressStage(id: "build", timing: .dynamic)
    history.record(.init(duration: 10, units: 60), for: build.id)
    let clock = Clock()
    let run = tracker([build], history, clock)
    run.begin(build)
    // "[1/1] Planning build": not done, as the last build counted 60.
    run.update(units: 1, of: 1)
    #expect(near(run.snapshot().stageFraction, 1.0 / 60))
    run.update(units: 30, of: 60)
    #expect(run.snapshot().stageFraction == 0.5)
  }

  @Test func neverMovesBack() {
    let history = ProgressHistory()
    let clock = Clock()
    history.record(.init(duration: 10), for: download.id)
    let run = tracker([download], history, clock)
    run.begin(download)
    clock.advance(9)
    let before = run.snapshot().fraction ?? 0
    // A long stage nobody expected starts.
    let surprise = ProgressStage(id: "surprise")
    history.record(.init(duration: 1000), for: surprise.id)
    run.begin(surprise)
    #expect((run.snapshot().fraction ?? 0) >= before)
    clock.advance(500)
    #expect((run.snapshot().fraction ?? 0) > before)
  }

  @Test func remembersThePlan() {
    let history = ProgressHistory()
    let clock = Clock()
    let first = tracker([], history, clock, operation: "test")
    first.begin(ProgressStage(id: "build", timing: .dynamic))
    clock.advance(30)
    first.begin(ProgressStage(id: "tests"))
    clock.advance(10)
    first.complete()

    // Next time the tests are expected before they start.
    let second = tracker([], history, clock, operation: "test")
    second.begin(id: "build")
    #expect(second.snapshot().stageCount == 2)
    clock.advance(15)
    #expect(near(second.snapshot().fraction, 15.0 / 40))
  }
}

@Suite struct ProgressHistoryTests {
  @Test func durationFollowsSize() {
    let history = ProgressHistory()
    let translate = ProgressStage(id: "translate", resource: .remote, size: 10)
    history.record(.init(duration: 6, size: 10), for: translate.id)
    // One size: the duration is taken to follow it.
    #expect(near(history.duration(for: ProgressStage(id: "translate", size: 20)), 12))
    // Two: a fixed cost (5 s) plus 0.1 s a string.
    history.record(.init(duration: 105, size: 1000), for: translate.id)
    #expect(near(history.duration(for: ProgressStage(id: "translate", size: 100)), 15))
    #expect(near(history.duration(for: translate), 6))
  }

  @Test func newerRunsCountMore() {
    let history = ProgressHistory()
    history.record(.init(duration: 10), for: "a")
    history.record(.init(duration: 20), for: "a")
    // Weights 0.6 and 1.
    #expect(near(history.duration(for: ProgressStage(id: "a")), (6 + 20) / 1.6))
  }

  @Test func curve() {
    let curve = ProgressCurve()
    #expect(curve.fraction(elapsed: 5, expected: 10) == 0.5)
    #expect(near(curve.fraction(elapsed: 8, expected: 10), 0.8))
    #expect(near(curve.fraction(elapsed: 20, expected: 10), 0.9))
    #expect(curve.fraction(elapsed: 1e6, expected: 10) < 0.95)
  }

  @Test func savesToAFile() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("CodeProgress-\(UUID().uuidString)").appendingPathComponent("history.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let history = ProgressHistory(fileURL: url)
    history.record(.init(duration: 3, units: 7), for: "a")
    history.recordPlan([ProgressStage(id: "a", resource: .disk)], for: "op")
    history.save()
    let read = ProgressHistory(fileURL: url)
    #expect(read.duration(for: ProgressStage(id: "a")) == 3)
    #expect(read.units(for: ProgressStage(id: "a")) == 7)
    #expect(read.plan(for: "op")?.first?.resource == .disk)
  }
}
