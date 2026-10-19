import Foundation

/// The progress of one run of an operation made of stages: a build, a
/// download and install, a batch of translations.
///
/// Each stage's share of the bar comes from how long it took before (its
/// `ProgressHistory`). While a stage runs, the bar moves with what it reports
/// (a fraction, or units counted against the units of its last runs), else
/// with time along a `ProgressCurve`. A static stage that runs slower or
/// faster than usual predicts the same for the run's later stages on its
/// resource; any stage repeated in a run predicts its later repetitions.
///
/// The bar never moves back. When the estimates of the stages left change
/// (a dynamic stage ends early or late, a stage nobody expected starts), the
/// rest of the run fills what is left of the bar from where it is.
///
/// Snapshots move with time, so read one on a timer while the run lasts.
/// Every method is safe from any thread.
public final class ProgressTracker: @unchecked Sendable {
  public let operation: String
  public let history: ProgressHistory
  public let curve: ProgressCurve

  struct Entry {
    enum State: Equatable {
      case pending
      case running(start: Date)
      case done
      case skipped
    }

    var stage: ProgressStage
    var state: State = .pending
    /// From the history, before this run's factors.
    var base: TimeInterval?
    /// Units counted so far, and the total when reported.
    var units: Double = 0
    var unitTotal: Double?
    var reported: Double?
  }

  /// Where the bar was when the estimates last changed, and the first stage
  /// sharing what is left of it.
  struct Anchor {
    var value: Double
    var index: Int
  }

  private let lock = NSLock()
  private let now: @Sendable () -> Date
  private var entries: [Entry] = []
  private var running: Int?
  private var anchor = Anchor(value: 0, index: 0)
  private var shown: Double?
  private var isOver = false
  /// Actual over expected durations finished in this run, with the expected
  /// durations as weights: per stage id, and per resource (static only).
  private var stageRatios: [String: [(ratio: Double, weight: Double)]] = [:]
  private var resourceRatios: [ProgressResource: [(ratio: Double, weight: Double)]] = [:]

  /// `stages` are the ones expected, in order; with none, the stages this
  /// operation ran last time. Stages can still start that aren't in the
  /// list, and stages in it can be left out.
  public init(
    operation: String, stages: [ProgressStage] = [], history: ProgressHistory = .standard,
    curve: ProgressCurve = ProgressCurve(), now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.operation = operation
    self.history = history
    self.curve = curve
    self.now = now
    let planned = stages.isEmpty ? (history.plan(for: operation) ?? []) : stages
    entries = planned.map { Entry(stage: $0, base: history.duration(for: $0)) }
  }

  // MARK: - Reporting

  /// Starts a stage, finishing the one running. When the stage is expected
  /// later, the stages before it are left out.
  public func begin(_ stage: ProgressStage) {
    lock.withLock {
      let date = now()
      if running != nil { finishRunning(at: date) }
      // Where the bar is before the stages change.
      let value = max(shown ?? 0, currentValue(at: date) ?? 0)
      let next = entries.firstIndex { $0.state == .pending } ?? entries.count
      if let index = entries[next...].firstIndex(where: { $0.stage.id == stage.id }) {
        var changed = false
        for skipped in next..<index {
          entries[skipped].state = .skipped
          changed = true
        }
        if entries[index].stage != stage {
          entries[index].stage = stage
          entries[index].base = history.duration(for: stage)
          changed = true
        }
        entries[index].state = .running(start: date)
        running = index
        if changed { anchor = Anchor(value: value, index: index) }
      } else {
        var entry = Entry(stage: stage, base: history.duration(for: stage))
        entry.state = .running(start: date)
        entries.insert(entry, at: next)
        running = next
        anchor = Anchor(value: value, index: next)
      }
    }
  }

  /// Starts the stage with this id, as planned.
  public func begin(id: String) {
    let stage = lock.withLock {
      entries.first { $0.stage.id == id && $0.state == .pending }?.stage
    }
    begin(stage ?? ProgressStage(id: id))
  }

  /// The running stage's own fraction (a download's bytes, "[12/40]").
  public func report(fraction: Double) {
    lock.withLock {
      guard let running else { return }
      entries[running].reported = min(1, max(0, fraction))
    }
  }

  /// Counts units the running stage finished (tasks, tests, files). Its
  /// last runs' counts stand in for a total.
  public func advance(units: Double = 1) {
    lock.withLock {
      guard let running else { return }
      entries[running].units += units
    }
  }

  /// Sets how many units the running stage finished, of a total when the
  /// tool gives one. A dynamic stage's total can't fall below what its
  /// earlier runs counted, as tools that plan while they work ("[1/1]
  /// Planning", then "[2/59]") start with small totals.
  public func update(units: Double, of total: Double? = nil) {
    lock.withLock {
      guard let running else { return }
      entries[running].units = units
      if let total { entries[running].unitTotal = total }
    }
  }

  /// Finishes the running stage and keeps its duration.
  public func finishStage() {
    lock.withLock {
      guard running != nil else { return }
      finishRunning(at: now())
    }
  }

  /// Finishes the run: the running stage counts, the stages that didn't run
  /// are left out, and the history keeps the stages that ran as the plan
  /// for next time.
  public func complete() {
    lock.withLock {
      guard !isOver else { return }
      if running != nil { finishRunning(at: now()) }
      for index in entries.indices where entries[index].state == .pending {
        entries[index].state = .skipped
      }
      isOver = true
      shown = 1
      let ran = entries.filter { $0.state == .done }.map(\.stage)
      if !ran.isEmpty { history.recordPlan(ran, for: operation) }
    }
  }

  /// Ends the run without keeping the running stage (it failed or was
  /// stopped); the stages finished before it are kept.
  public func cancel() {
    lock.withLock {
      if let running { entries[running].state = .skipped }
      running = nil
      isOver = true
    }
  }

  // MARK: - Reading

  public func snapshot() -> ProgressSnapshot {
    lock.withLock {
      let date = now()
      let value = isOver ? shown : currentValue(at: date)
      if let value { shown = max(shown ?? 0, value) }
      let stageFraction = running.flatMap { fraction(of: $0, at: date) }
      let active = entries.filter { $0.state != .skipped }
      return ProgressSnapshot(
        fraction: shown,
        stage: running.map { entries[$0].stage },
        stageIndex: running.map { index in
          entries[..<index].filter { $0.state != .skipped }.count
        } ?? active.filter { $0.state == .done }.count,
        stageCount: active.count,
        stageFraction: stageFraction,
        remaining: isOver ? 0 : remaining(at: date))
    }
  }

  // MARK: - Estimating

  /// The expected duration of a stage in this run: its history, scaled by
  /// how this run's earlier stages of the same id or resource went.
  private func expected(_ index: Int) -> TimeInterval? {
    let entry = entries[index]
    guard let base = entry.base else { return nil }
    let ratios = stageRatios[entry.stage.id] ?? resourceRatios[entry.stage.resource] ?? []
    return base * Self.mean(ratios)
  }

  /// Weighted geometric mean, 1 for none.
  static func mean(_ ratios: [(ratio: Double, weight: Double)]) -> Double {
    let total = ratios.map(\.weight).reduce(0, +)
    guard total > 0 else { return 1 }
    return exp(ratios.map { log(max($0.ratio, 1e-3)) * $0.weight }.reduce(0, +) / total)
  }

  /// How far the stage got: what it reports, its units against a total,
  /// else its time against its estimate along the curve.
  private func fraction(of index: Int, at date: Date) -> Double? {
    let entry = entries[index]
    switch entry.state {
    case .done: return 1
    case .pending, .skipped: return 0
    case .running(let start):
      if let reported = entry.reported { return reported }
      let counted = history.units(for: entry.stage)
      let total =
        entry.unitTotal.map { entry.stage.timing == .dynamic ? max($0, counted ?? 0) : $0 } ?? counted
      if entry.units > 0, let total, total > 0 {
        return min(0.99, entry.units / total)
      }
      guard let expected = expected(index) else { return nil }
      return curve.fraction(elapsed: date.timeIntervalSince(start), expected: expected)
    }
  }

  /// Each stage's share of what is left of the bar since the anchor:
  /// expected durations, the mean of the known ones for stages never run,
  /// equal shares when none is known.
  private func spans() -> [Int: Double] {
    let indices = entries.indices.filter { $0 >= anchor.index && entries[$0].state != .skipped }
    let known = indices.compactMap { expected($0) }
    let fill = known.isEmpty ? 1 : known.reduce(0, +) / Double(known.count)
    var spans: [Int: Double] = [:]
    for index in indices {
      spans[index] = max(known.isEmpty ? 1 : (expected(index) ?? fill), 1e-6)
    }
    return spans
  }

  private func currentValue(at date: Date) -> Double? {
    let spans = spans()
    let total = spans.values.reduce(0, +)
    guard total > 0 else { return shown }
    var done = 0.0
    var known = anchor.value > 0
    for (index, span) in spans {
      switch entries[index].state {
      case .done:
        done += span
        known = true
      case .running:
        guard let fraction = fraction(of: index, at: date) else { continue }
        known = true
        done += span * fraction
      default: break
      }
    }
    guard known else { return shown }
    return anchor.value + (1 - anchor.value) * min(1, done / total)
  }

  private func remaining(at date: Date) -> TimeInterval? {
    var left = 0.0
    for index in entries.indices {
      switch entries[index].state {
      case .pending:
        guard let expected = expected(index) else { return nil }
        left += expected
      case .running(let start):
        let elapsed = date.timeIntervalSince(start)
        if let fraction = fraction(of: index, at: date), fraction > 0.05,
          entries[index].reported != nil || entries[index].units > 0
        {
          left += elapsed * (1 - fraction) / fraction
        } else if let expected = expected(index) {
          left += max(expected - elapsed, expected * 0.05)
        } else {
          return nil
        }
      default: break
      }
    }
    return left
  }

  // MARK: - Changes

  /// Finishes the running stage: keeps its duration, learns from it, and
  /// moves the anchor past it. A static stage jumps to its end; a dynamic
  /// one with an estimate stays where it is, and the stages left fill the
  /// rest of the bar.
  private func finishRunning(at date: Date) {
    guard let index = running, case .running(let start) = entries[index].state else { return }
    let entry = entries[index]
    let duration = date.timeIntervalSince(start)
    let value: Double?
    if entry.stage.timing == .static || fraction(of: index, at: date) == nil {
      entries[index].state = .done
      value = currentValue(at: date)
    } else {
      value = currentValue(at: date)
      entries[index].state = .done
    }
    if let value { shown = max(shown ?? 0, value) }
    running = nil

    history.record(
      ProgressHistory.Sample(
        duration: duration, size: entry.stage.size, units: entry.units > 0 ? entry.units : nil,
        date: date),
      for: entry.stage.id)
    if let base = entry.base, base > 0 {
      let ratio = (ratio: duration / base, weight: base)
      stageRatios[entry.stage.id, default: []].append(ratio)
      if entry.stage.timing == .static { resourceRatios[entry.stage.resource, default: []].append(ratio) }
    }
    // The stages left share what is left of the bar, from where it is.
    anchor = Anchor(value: shown ?? 0, index: index + 1)
  }
}
