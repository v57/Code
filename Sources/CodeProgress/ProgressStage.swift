import Foundation

/// What bounds a stage's speed. Stages that share a resource slow down
/// together: a download that runs at half its usual speed predicts the same
/// for the next download in the run, not for an install that follows it.
public enum ProgressResource: String, Codable, Sendable, CaseIterable {
  /// Computing on this machine: compiling, unpacking, encoding.
  case cpu
  /// Reading and writing files: copying, installing, indexing.
  case disk
  /// Moving bytes over the network: downloads, uploads.
  case network
  /// Waiting for another machine's work: a language model's answer,
  /// notarization, a CI job.
  case remote
}

/// One stage of an operation ("Download", "Install", "Build").
public struct ProgressStage: Codable, Hashable, Sendable {
  /// How much a stage's duration changes from run to run.
  public enum Timing: String, Codable, Sendable {
    /// Takes about as long each time (a download of the same file, an
    /// install). How much faster or slower than usual it runs carries over
    /// to the run's other stages on the same resource, and it jumps to its
    /// end when it finishes.
    case `static`
    /// Takes as long as the work it finds (a compile with a build cache).
    /// Its speed says nothing about other stages, and when it ends early or
    /// late the rest of the run takes up the remaining progress smoothly
    /// instead of jumping.
    case dynamic
  }

  /// What the stage's history is kept under: a path, a command, or both
  /// ("xcodebuild build App.xcodeproj#App"). Stages with the same id share
  /// their history, in one run and across runs.
  public var id: String
  public var title: String
  public var resource: ProgressResource
  public var timing: Timing
  /// How much work the stage does, in its own unit (bytes to download,
  /// strings to translate), when known before it starts. The history learns
  /// how the duration follows it: a fixed cost plus a cost per unit.
  public var size: Double?

  public init(
    id: String, title: String? = nil, resource: ProgressResource = .cpu,
    timing: Timing = .static, size: Double? = nil
  ) {
    self.id = id
    self.title = title ?? id
    self.resource = resource
    self.timing = timing
    self.size = size
  }
}

/// How far an operation got, at one moment.
public struct ProgressSnapshot: Equatable, Sendable {
  /// From 0 to 1, never lower than an earlier snapshot of the same run; nil
  /// before anything is known (the first run of a one-stage operation that
  /// reports nothing).
  public var fraction: Double?
  /// The stage running now.
  public var stage: ProgressStage?
  /// The running stage's place among the stages expected.
  public var stageIndex: Int
  public var stageCount: Int
  /// How far the running stage got, when it reports it or its history
  /// gives an estimate.
  public var stageFraction: Double?
  /// Time left, when every stage left has an estimate.
  public var remaining: TimeInterval?

  public init(
    fraction: Double?, stage: ProgressStage?, stageIndex: Int, stageCount: Int,
    stageFraction: Double?, remaining: TimeInterval?
  ) {
    self.fraction = fraction
    self.stage = stage
    self.stageIndex = stageIndex
    self.stageCount = stageCount
    self.stageFraction = stageFraction
    self.remaining = remaining
  }
}

/// How a stage measured only by time moves: as fast as expected up to the
/// knee, then slower and slower toward the ceiling, which it never reaches,
/// so a stage that runs long keeps moving without running out of room.
public struct ProgressCurve: Equatable, Sendable {
  /// The fraction of the stage up to which progress follows time.
  public var knee: Double
  /// The fraction the stage approaches but never reaches.
  public var ceiling: Double
  /// How slowly it approaches: past the knee by this much of the expected
  /// time, it has covered half the way from the knee to the ceiling.
  public var patience: Double

  public init(knee: Double = 0.8, ceiling: Double = 0.95, patience: Double = 0.6) {
    self.knee = knee
    self.ceiling = ceiling
    self.patience = patience
  }

  /// With the defaults: 0.5 at half the expected time, 0.8 at 80%, 0.9 at
  /// twice the expected time.
  public func fraction(elapsed: TimeInterval, expected: TimeInterval) -> Double {
    guard expected > 0 else { return ceiling }
    let time = max(0, elapsed / expected)
    if time <= knee { return time }
    return ceiling - (ceiling - knee) * patience / (patience + time - knee)
  }
}
