import CodeProgress
import Foundation
import Testing

@testable import CodeActions

/// Several actions of one project at once (`ActionController.runs`, the editor's process stack).
@MainActor @Suite struct ConcurrentRunsTests {
  private let root: URL
  private let controller: ActionController

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("runs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    controller = ActionController(root: root)
    controller.progressHistory = ProgressHistory(fileURL: root.appendingPathComponent("history.json"))
  }

  private func scheme(_ name: String, _ commands: [ActionKind: String]) -> ActionScheme {
    ActionScheme(name: name, toolchain: .make, directory: root, commands: commands)
  }

  private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<400 where !condition() {
      try? await Task.sleep(for: .milliseconds(25))
    }
  }

  @Test func aRunKeepsGoingWhileATestRuns() async {
    let app = scheme("App", [.run: "sleep 30", .test: "echo ok"])
    controller.perform(.run, scheme: app, destination: nil)
    await waitUntil { controller.runs.first?.isRunningApp == true }
    controller.perform(.test, scheme: app, destination: nil)
    await waitUntil { controller.runs.last?.phase == .succeeded }
    #expect(controller.runs.map(\.kind) == [.run, .test])
    #expect(controller.runs[0].phase == .running)
    #expect(controller.runs[1].phase == .succeeded)
    #expect(controller.isRunning)
    controller.stopAll()
    await waitUntil { controller.runs[0].phase == .stopped }
    #expect(controller.runs[0].phase == .stopped)
    #expect(!controller.isRunning)
  }

  @Test func aBuildOfTheSameProjectWaitsForTheOneBuildingIt() async {
    let app = scheme("App", [.test: "sleep 1", .build: "echo built"])
    controller.perform(.test, scheme: app, destination: nil)
    await waitUntil { controller.runs.first?.stepTitle == "Test" }
    controller.perform(.build, scheme: app, destination: nil)
    await waitUntil { controller.runs.last?.phase == .waiting("Test App") }
    #expect(controller.runs[1].phase == .waiting("Test App"))
    await waitUntil { controller.runs.last?.phase == .succeeded }
    #expect(controller.runs.map(\.phase) == [.succeeded, .succeeded])
    #expect(controller.runs[0].finished! <= controller.runs[1].finished!)
  }

  @Test func performingTheSameActionAgainReplacesIt() async {
    let app = scheme("App", [.run: "sleep 30", .build: "false"])
    controller.perform(.build, scheme: app, destination: nil)
    await waitUntil { controller.runs.first?.phase == .failed("Exit code 1") }
    controller.perform(.run, scheme: app, destination: nil)
    await waitUntil { controller.runs.last?.isRunningApp == true }
    controller.perform(.run, scheme: app, destination: nil)
    await waitUntil { controller.runs.count == 3 && controller.runs[2].isRunningApp }
    #expect(controller.runs[1].phase == .stopped)
    #expect(controller.runs[2].phase == .running)
    // A failure stays on the editor until another run of the same action comes.
    #expect(!controller.runs[0].isDismissed)
    controller.perform(.build, scheme: app, destination: nil)
    #expect(controller.runs[0].isDismissed)
    controller.stopAll()
    await waitUntil { !controller.isRunning }
  }
}
