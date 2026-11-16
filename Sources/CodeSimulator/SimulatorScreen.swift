import Foundation

#if os(macOS)
import CodeSimulatorPrivate
import CoreGraphics
import IOSurface
import ImageIO
import Observation
import UniformTypeIdentifiers

/// A booted iOS Simulator's screen and input, read from the simulator itself (Xcode's CoreSimulator and
/// SimulatorKit, loaded at run time): no Simulator window and no Screen Recording permission. The frameworks are
/// private, so every Xcode update can break this: `SimulatorScreen.availability` says whether they loaded, and
/// everything fails quietly into `state` when a call is missing.
///
/// ```swift
/// let screen = SimulatorScreen(udid: destination.id)
/// screen.start()                       // follows the device until `stop()`
/// SimulatorScreenView(screen: screen)  // the picture; clicks are touches, keys go to the device
/// ```
@MainActor @Observable public final class SimulatorScreen {
  public enum State: Equatable, Sendable {
    /// The frameworks or the device aren't there; the text says which.
    case unavailable(String)
    /// The device has no picture yet: "Shutdown", "Booting"…
    case waiting(String)
    case live
  }

  public enum Button: Sendable {
    case home, lock, side, siri
  }

  /// Whether this Mac's Xcode has the frameworks: nil when it does, else why not.
  public static let unavailableReason: String? = {
    guard let directory = developerDirectory() else { return "Xcode isn't installed, or xcode-select points nowhere." }
    do {
      try CSPSimulator.loadFrameworks(withDeveloperDirectory: directory)
      return nil
    } catch {
      return error.localizedDescription
    }
  }()

  public static var isAvailable: Bool { unavailableReason == nil }

  public let udid: String
  public private(set) var state: State
  public private(set) var name = ""
  /// The framebuffer's size in pixels, portrait as the device is built.
  public private(set) var pixelSize = CGSize.zero
  /// Pixels per point of the device's screen.
  public private(set) var pixelsPerPoint: CGFloat = 3
  /// The screen as shown (turned as the device is held), in the device's points: its real size on a display.
  public var pointSize: CGSize {
    let size = CGSize(width: pixelSize.width / pixelsPerPoint, height: pixelSize.height / pixelsPerPoint)
    return quarterTurns % 2 == 1 ? CGSize(width: size.height, height: size.width) : size
  }
  /// Quarter turns clockwise the picture is shown at: 0 portrait, 1 landscape right…
  public private(set) var quarterTurns = 0
  /// Frames drawn in the last second.
  public private(set) var framesPerSecond = 0

  @ObservationIgnored private var simulator: CSPSimulator?
  @ObservationIgnored private var poll: Task<Void, Never>?
  @ObservationIgnored private var frames = 0
  /// The view showing the surface: told when a frame lands or the surface is replaced.
  @ObservationIgnored var onFrame: (() -> Void)?
  @ObservationIgnored var onSurface: (() -> Void)?

  public init(udid: String) {
    self.udid = udid
    state = Self.unavailableReason.map { .unavailable($0) } ?? .waiting("")
  }

  /// The current framebuffer; nil until `state` is `.live`.
  public var surface: IOSurfaceRef? { simulator?.surface }

  /// Starts following the device: attaches when it has a picture, again after it reboots, until `stop()`.
  public func start() {
    guard poll == nil, Self.isAvailable else { return }
    poll = Task { [weak self] in
      while !Task.isCancelled {
        self?.tick()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  public func stop() {
    poll?.cancel()
    poll = nil
    simulator?.detach()
    simulator = nil
    if Self.isAvailable { state = .waiting("") }
  }

  private func tick() {
    if simulator == nil {
      do {
        let simulator = try CSPSimulator(udid: udid)
        simulator.frameHandler = { [weak self] in
          self?.frames += 1
          self?.onFrame?()
        }
        simulator.displayChangedHandler = { [weak self] in self?.displayChanged() }
        self.simulator = simulator
        name = simulator.name
        if simulator.screenScale >= 1 { pixelsPerPoint = simulator.screenScale }
      } catch {
        state = .unavailable(error.localizedDescription)
        return
      }
    }
    guard let simulator else { return }
    framesPerSecond = frames
    frames = 0
    guard simulator.isBooted else {
      if state == .live { simulator.detach() }
      state = .waiting(simulator.stateDescription)
      onSurface?()
      return
    }
    if simulator.attachDisplay() {
      if state != .live {
        state = .live
        displayChanged()
      }
    } else {
      state = .waiting(simulator.stateDescription)
    }
  }

  private func displayChanged() {
    guard let simulator else { return }
    if let surface {
      pixelSize = CGSize(width: IOSurfaceGetWidth(surface), height: IOSurfaceGetHeight(surface))
    }
    let turns = Int((simulator.displayAngle / (.pi / 2)).rounded())
    quarterTurns = ((turns % 4) + 4) % 4
    onSurface?()
  }

  // MARK: Input

  public enum TouchPhase: Sendable {
    case down, moved, up
  }

  /// A finger at `point`, 0…1 of the framebuffer from its top left; `second` adds another finger (a pinch).
  @discardableResult
  public func touch(_ phase: TouchPhase, at point: CGPoint, second: CGPoint? = nil) -> Bool {
    guard let simulator, state == .live else { return false }
    let phase: CSPTouchPhase =
      switch phase {
      case .down: .down
      case .moved: .moved
      case .up: .up
      }
    if var second {
      return simulator.sendTouch(phase, at: point, second: &second)
    }
    return simulator.sendTouch(phase, at: point, second: nil)
  }

  /// Presses and releases a hardware button.
  public func press(_ button: Button) {
    guard let simulator, state == .live else { return }
    let button: CSPButton =
      switch button {
      case .home: .home
      case .lock: .lock
      case .side: .side
      case .siri: .siri
      }
    simulator.send(button, down: true)
    Task { [weak simulator] in
      try? await Task.sleep(for: .milliseconds(60))
      simulator?.send(button, down: false)
    }
  }

  /// A key by its USB HID usage (keyboard page 7): 0x04 is A, 0x28 Return.
  public func key(usage: UInt32, down: Bool) {
    guard let simulator, state == .live else { return }
    simulator.sendKeyUsage(usage, down: down)
  }

  // MARK: Pictures

  /// The screen as it is now, upright, or nil without a picture.
  public func image() -> CGImage? {
    guard let surface else { return nil }
    IOSurfaceLock(surface, .readOnly, nil)
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    let width = IOSurfaceGetWidth(surface)
    let height = IOSurfaceGetHeight(surface)
    guard
      let context = CGContext(
        data: IOSurfaceGetBaseAddress(surface), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: IOSurfaceGetBytesPerRow(surface), space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
      let image = context.makeImage()
    else { return nil }
    guard quarterTurns != 0 else { return image }
    let turned = quarterTurns % 2 == 1
    guard
      let upright = CGContext(
        data: nil, width: turned ? height : width, height: turned ? width : height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return image }
    upright.translateBy(x: CGFloat(upright.width) / 2, y: CGFloat(upright.height) / 2)
    upright.rotate(by: -CGFloat(quarterTurns) * .pi / 2)
    upright.draw(image, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
    return upright.makeImage() ?? image
  }

  /// Writes the screen as a PNG.
  @discardableResult
  public func writePNG(to url: URL) -> Bool {
    guard let image = image(),
      let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
  }

  // MARK: Appearance

  /// Whether the device is in Dark Mode (`simctl ui appearance`); nil when it can't be asked.
  public nonisolated static func isDark(udid: String) async -> Bool? {
    guard let output = await simctl(["ui", udid, "appearance"]) else { return nil }
    return output.contains("dark")
  }

  /// Switches the device between Light and Dark Mode.
  public nonisolated static func setDark(_ isDark: Bool, udid: String) async {
    _ = await simctl(["ui", udid, "appearance", isDark ? "dark" : "light"])
  }

  private nonisolated static func simctl(_ arguments: [String]) async -> String? {
    await Task.detached {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
      process.arguments = ["simctl"] + arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      guard (try? process.run()) != nil else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }.value
  }

  /// The selected Xcode's Developer folder, as `xcode-select -p` answers, read from where xcode-select keeps it: no
  /// subprocess, since waiting for one on the main thread runs the run loop, and a view asking again from there
  /// would wait on this same first answer forever.
  private static func developerDirectory() -> String? {
    var candidates: [String] = []
    if let directory = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !directory.isEmpty {
      candidates.append(directory)
    }
    if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
      candidates.append(link)
    }
    candidates.append("/Applications/Xcode.app/Contents/Developer")
    // The command line tools alone have no simulators.
    return candidates.first {
      $0.hasSuffix("/Contents/Developer") && FileManager.default.fileExists(atPath: $0)
    }
  }
}
#else
/// Simulators exist only on a Mac with Xcode: elsewhere the preview comes from one through Remote.
public enum SimulatorScreen {
  public static let unavailableReason: String? = "Simulators run on a Mac with Xcode."
  public static var isAvailable: Bool { false }
}
#endif
