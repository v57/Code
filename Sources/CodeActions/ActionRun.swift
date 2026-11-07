import CodeProgress
import Foundation
import Observation

/// One build, test, run (or other action) of a project, from its start to its end: what the editor's process stack
/// shows as a circle and the console as its blocks. Several run at once; `ActionController.runs` keeps them, newest last.
@MainActor @Observable public final class ActionRun: Identifiable {
  public enum Phase: Equatable, Sendable {
    /// Waiting for another run to finish building the same project (that run's title, "Build Trips").
    case waiting(String)
    case running
    case succeeded
    /// Why, in few words ("2 errors", "Exit code 1").
    case failed(String)
    case stopped
  }

  public nonisolated let id = UUID()
  public let kind: ActionKind
  public let scheme: ActionScheme
  public let destination: RunDestination?
  /// Where it runs when not on this computer ("studio-mac", "Colima"); nil here.
  public let place: String?
  public let started = Date()
  public internal(set) var phase: Phase
  public internal(set) var finished: Date?
  public internal(set) var progress: ActionProgress?
  /// The step running now ("Build", "Install", "Run").
  public internal(set) var stepTitle: String?
  /// Issues from its log.
  public internal(set) var issues: [BuildIssue] = []
  /// Tests run so far.
  public internal(set) var testsRun = 0
  /// How many tests the last finished run of the same tests ran; nil before one finished.
  public let testsExpected: Int?
  public let log = ActionLog()
  /// Taken off the editor's stack (dismissed, Hide Finished, or gone by itself); the console still shows it.
  public var isDismissed = false

  @ObservationIgnored let environment: [String: String]
  @ObservationIgnored let source: BuildSource
  @ObservationIgnored var operation = ""
  @ObservationIgnored var context: ActionContext?
  @ObservationIgnored var task: Task<Void, Never>?
  @ObservationIgnored var tracker: ProgressTracker?
  /// What the log said last, under the tracker's fraction.
  @ObservationIgnored var progressMessage = ""
  @ObservationIgnored var progressTimer: Task<Void, Never>?
  /// It may still write the project's build folder: runs of the same project started after it wait (`ActionController`).
  @ObservationIgnored var isBuilding = true

  init(
    kind: ActionKind, scheme: ActionScheme, destination: RunDestination?, source: BuildSource,
    environment: [String: String], testsExpected: Int?
  ) {
    self.kind = kind
    self.scheme = scheme
    self.destination = destination
    self.source = source
    self.environment = environment
    self.testsExpected = testsExpected
    place = source.isLocal ? (destination?.kind == .remote ? destination?.name : nil) : source.name
    phase = .running
  }

  /// "Build Trips", "Test Atlas".
  public var title: String { "\(kind.title) \(scheme.name)" }

  /// Waiting or running.
  public var isWorking: Bool {
    switch phase {
    case .waiting, .running: return true
    default: return false
    }
  }

  /// A Run past its build: the app runs as long as it likes, with no progress to show.
  public var isRunningApp: Bool { kind == .run && stepTitle == "Run" && phase == .running }

  public var errorCount: Int { issues.filter { $0.severity == .error }.count }
  public var warningCount: Int { issues.filter { $0.severity == .warning }.count }

  /// How long it ran, or has been running at `now`.
  public func duration(at now: Date = Date()) -> TimeInterval {
    (finished ?? now).timeIntervalSince(started)
  }
}
