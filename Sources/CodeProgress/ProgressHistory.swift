import Foundation

/// How long stages took before, how many units they counted, and which
/// stages each operation ran, kept in a JSON file (or only in memory).
/// Trackers read their estimates from it and add to it as stages finish.
public final class ProgressHistory: @unchecked Sendable {
  /// One finished stage.
  public struct Sample: Codable, Equatable, Sendable {
    public var duration: TimeInterval
    public var size: Double?
    /// Units the stage counted (tasks, tests), when it counted any.
    public var units: Double?
    public var date: Date

    public init(duration: TimeInterval, size: Double? = nil, units: Double? = nil, date: Date = Date()) {
      self.duration = duration
      self.size = size
      self.units = units
      self.date = date
    }
  }

  struct Record: Codable {
    var samples: [Sample] = []
    var lastUsed: Date
  }

  struct Contents: Codable {
    var stages: [String: Record] = [:]
    /// The stages each operation ran last time, in order.
    var plans: [String: [ProgressStage]] = [:]
    var planDates: [String: Date] = [:]
  }

  /// Samples kept per stage, newest last.
  public static let samplesKept = 12
  /// Stages and operations kept; the ones used longest ago go first.
  public static let entriesKept = 400
  /// How much less each older sample counts than the next newer one.
  static let ageWeight = 0.6

  /// Kept in Application Support, in a folder named after the app.
  public static let standard: ProgressHistory = {
    let folder = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return ProgressHistory(
      fileURL: support.appendingPathComponent(folder).appendingPathComponent("ProgressHistory.json"))
  }()

  public let fileURL: URL?
  private let lock = NSLock()
  private var contents = Contents()
  private var isSaveScheduled = false
  private let queue = DispatchQueue(label: "CodeProgress.history", qos: .utility)

  /// Reads the file when there is one; nil keeps the history in memory.
  public init(fileURL: URL? = nil) {
    self.fileURL = fileURL
    if let fileURL, let data = try? Data(contentsOf: fileURL),
      let contents = try? JSONDecoder().decode(Contents.self, from: data)
    {
      self.contents = contents
    }
  }

  // MARK: - Estimates

  /// How long the stage should take, from its earlier runs: the newer ones
  /// count more, and with sizes, a fixed cost plus a cost per unit fitted to
  /// them. Nil when it never ran.
  public func duration(for stage: ProgressStage) -> TimeInterval? {
    let samples = lock.withLock { contents.stages[stage.id]?.samples } ?? []
    guard !samples.isEmpty else { return nil }
    let weights = Self.weights(samples.count)
    if let size = stage.size, size > 0 {
      let sized = zip(samples, weights).compactMap { sample, weight in
        sample.size.flatMap { $0 > 0 ? (size: $0, duration: sample.duration, weight: weight) : nil }
      }
      if !sized.isEmpty {
        return max(0.01, Self.fit(sized).estimate(size))
      }
    }
    let total = weights.reduce(0, +)
    return zip(samples, weights).map { $0.duration * $1 }.reduce(0, +) / total
  }

  /// How many units the stage should count: for a dynamic stage the most of
  /// its recent runs (an incremental build runs only some of its tasks, a
  /// full one all of them), else the last run's.
  public func units(for stage: ProgressStage) -> Double? {
    let counts = (lock.withLock { contents.stages[stage.id]?.samples } ?? []).compactMap(\.units)
    return stage.timing == .dynamic ? counts.max() : counts.last
  }

  /// The stages the operation ran last time.
  public func plan(for operation: String) -> [ProgressStage]? {
    lock.withLock { contents.plans[operation] }
  }

  // MARK: - Recording

  public func record(_ sample: Sample, for stageID: String) {
    lock.withLock {
      var record = contents.stages[stageID] ?? Record(lastUsed: sample.date)
      record.samples.append(sample)
      if record.samples.count > Self.samplesKept {
        record.samples.removeFirst(record.samples.count - Self.samplesKept)
      }
      record.lastUsed = sample.date
      contents.stages[stageID] = record
      prune()
    }
    scheduleSave()
  }

  public func recordPlan(_ stages: [ProgressStage], for operation: String, date: Date = Date()) {
    lock.withLock {
      contents.plans[operation] = stages
      contents.planDates[operation] = date
      prune()
    }
    scheduleSave()
  }

  /// Forgets everything.
  public func removeAll() {
    lock.withLock { contents = Contents() }
    scheduleSave()
  }

  private func prune() {
    if contents.stages.count > Self.entriesKept {
      let old = contents.stages.sorted { $0.value.lastUsed < $1.value.lastUsed }
        .prefix(contents.stages.count - Self.entriesKept)
      for (id, _) in old { contents.stages[id] = nil }
    }
    if contents.plans.count > Self.entriesKept {
      let old = contents.planDates.sorted { $0.value < $1.value }
        .prefix(contents.plans.count - Self.entriesKept)
      for (id, _) in old {
        contents.plans[id] = nil
        contents.planDates[id] = nil
      }
    }
  }

  /// Writes the file a moment later, once for a burst of changes.
  private func scheduleSave() {
    guard fileURL != nil else { return }
    let schedule = lock.withLock {
      defer { isSaveScheduled = true }
      return !isSaveScheduled
    }
    guard schedule else { return }
    queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.save() }
  }

  /// Writes the file now.
  public func save() {
    guard let fileURL else { return }
    let data = lock.withLock {
      isSaveScheduled = false
      return try? JSONEncoder().encode(contents)
    }
    guard let data else { return }
    try? FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: fileURL, options: .atomic)
  }

  // MARK: - Fitting

  /// Weights for samples oldest first: the newest counts 1.
  static func weights(_ count: Int) -> [Double] {
    (0..<count).map { pow(ageWeight, Double(count - 1 - $0)) }
  }

  /// Duration as a fixed cost plus a cost per unit of size.
  struct Fit: Equatable {
    var fixed: TimeInterval
    var perUnit: TimeInterval
    func estimate(_ size: Double) -> TimeInterval { fixed + perUnit * size }
  }

  /// Weighted least squares over the samples' sizes. With one size (or a
  /// fit that makes no sense) the duration is taken to follow the size.
  static func fit(_ samples: [(size: Double, duration: TimeInterval, weight: Double)]) -> Fit {
    let total = samples.map(\.weight).reduce(0, +)
    let meanSize = samples.map { $0.size * $0.weight }.reduce(0, +) / total
    let meanDuration = samples.map { $0.duration * $0.weight }.reduce(0, +) / total
    let variance = samples.map { $0.weight * pow($0.size - meanSize, 2) }.reduce(0, +)
    let proportional = Fit(
      fixed: 0,
      perUnit: samples.map { $0.weight * $0.duration * $0.size }.reduce(0, +)
        / samples.map { $0.weight * $0.size * $0.size }.reduce(0, +))
    guard variance > meanSize * meanSize * 1e-6 else { return proportional }
    let covariance = samples.map { $0.weight * ($0.size - meanSize) * ($0.duration - meanDuration) }
      .reduce(0, +)
    let perUnit = covariance / variance
    let fixed = meanDuration - perUnit * meanSize
    guard perUnit >= 0, fixed >= 0 else { return proportional }
    return Fit(fixed: fixed, perUnit: perUnit)
  }
}
