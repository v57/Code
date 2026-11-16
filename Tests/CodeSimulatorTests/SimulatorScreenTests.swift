import Foundation
import Testing

@testable import CodeSimulator

#if os(macOS)
@Suite(.serialized) struct SimulatorScreenTests {
  @Test func pointsTurnWithTheDevice() {
    // Portrait: the picture is the framebuffer.
    #expect(SimulatorNSView.framebufferPoint(x: 0.25, y: 0.1, quarterTurns: 0) == CGPoint(x: 0.25, y: 0.1))
    // Upside down: both axes flip.
    #expect(SimulatorNSView.framebufferPoint(x: 0.25, y: 0.1, quarterTurns: 2) == CGPoint(x: 0.75, y: 0.9))
    // A quarter turn swaps the axes, and the centre stays the centre whichever way.
    #expect(SimulatorNSView.framebufferPoint(x: 0.25, y: 0.1, quarterTurns: 1) == CGPoint(x: 0.9, y: 0.25))
    #expect(SimulatorNSView.framebufferPoint(x: 0.25, y: 0.1, quarterTurns: 3) == CGPoint(x: 0.1, y: 0.75))
    for turns in -4...8 {
      #expect(SimulatorNSView.framebufferPoint(x: 0.5, y: 0.5, quarterTurns: turns) == CGPoint(x: 0.5, y: 0.5))
    }
  }

  @Test func keysMapToHIDUsages() {
    #expect(HIDUsage.usage(forKeyCode: 0) == 0x04)  // A
    #expect(HIDUsage.usage(forKeyCode: 36) == 0x28)  // Return
    #expect(HIDUsage.usage(forKeyCode: 51) == 0x2a)  // Delete
    #expect(HIDUsage.usage(forKeyCode: 200) == nil)
  }

  /// With a booted simulator's identifier in CODE_SIMULATOR_TEST: its picture arrives and a PNG can be written.
  @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["CODE_SIMULATOR_TEST"] != nil))
  func readsABootedSimulator() async throws {
    let udid = try #require(ProcessInfo.processInfo.environment["CODE_SIMULATOR_TEST"])
    #expect(SimulatorScreen.unavailableReason == nil)
    let screen = SimulatorScreen(udid: udid)
    screen.start()
    defer { screen.stop() }
    for _ in 0..<50 where screen.state != .live { try await Task.sleep(for: .milliseconds(100)) }
    #expect(screen.state == .live)
    #expect(screen.pixelSize.width > 100)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("code-simulator-test.png")
    #expect(screen.writePNG(to: url))
    try? FileManager.default.removeItem(at: url)
  }

  /// The same simulator takes input: Home leaves Settings, and a touch on a row of Settings opens it.
  @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["CODE_SIMULATOR_TEST"] != nil))
  func sendsButtonsAndTouches() async throws {
    let udid = try #require(ProcessInfo.processInfo.environment["CODE_SIMULATOR_TEST"])
    let screen = SimulatorScreen(udid: udid)
    screen.start()
    defer { screen.stop() }
    for _ in 0..<50 where screen.state != .live { try await Task.sleep(for: .milliseconds(100)) }
    try #require(screen.state == .live)

    func pixels() -> Data? { screen.image()?.dataProvider?.data as Data? }
    /// Waits until the picture has stopped changing for three seconds (an app takes a while to draw on a busy Mac).
    func settled() async throws -> Data {
      var last = try #require(pixels())
      var still = 0
      for _ in 0..<60 where still < 3 {
        try await Task.sleep(for: .seconds(1))
        let now = try #require(pixels())
        still = now == last ? still + 1 : 0
        last = now
      }
      return last
    }
    /// Waits for the picture to become something else than `old`.
    func changed(from old: Data) async throws -> Bool {
      for _ in 0..<100 {
        try await Task.sleep(for: .milliseconds(200))
        if try #require(pixels()) != old { return true }
      }
      return false
    }
    func launchSettings() async throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      process.arguments = ["simctl", "launch", "--terminate-running-process", udid, "com.apple.Preferences"]
      process.standardOutput = FileHandle.nullDevice
      try process.run()
      process.waitUntilExit()
      // Its first frame is empty; the list comes later.
      try await Task.sleep(for: .seconds(4))
    }

    try await launchSettings()
    let settings = try await settled()
    screen.press(.home)
    #expect(try await changed(from: settings), "Home left Settings")

    try await launchSettings()
    let before = try await settled()
    // A row of the list, whichever page Settings came back to.
    #expect(screen.touch(.down, at: CGPoint(x: 0.5, y: 0.45)))
    try await Task.sleep(for: .milliseconds(150))
    #expect(screen.touch(.up, at: CGPoint(x: 0.5, y: 0.45)))
    #expect(try await changed(from: before), "the touch opened a row")
    if let directory = ProcessInfo.processInfo.environment["CODE_SIMULATOR_TEST_SHOTS"] {
      _ = try await settled()
      screen.writePNG(to: URL(fileURLWithPath: directory).appendingPathComponent("after-touch.png"))
    }
  }
}
#endif
