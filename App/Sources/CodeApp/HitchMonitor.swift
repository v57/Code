#if DEBUG && os(macOS)
  import AppKit
  import CodeKit

  /// Counts main-thread stalls in Debug builds, for finding hitches without Instruments: every stretch the main run
  /// loop spends awake (from waking to going back to sleep, the frame's commit included) longer than a 120 Hz frame is
  /// recorded with the step the shell named last.
  ///
  /// Driven by a distributed notification named after DebugAutomation's with `.perf` appended
  /// (`dev.v57.code.debug.perf`): `reset`, `mark:<step>`, `threshold:<ms>`, `report:<path>` (JSON),
  /// `scrollrun:<points per frame>:<frames>` (one pixel wheel event over the editor per display frame, as a trackpad
  /// scrolls).
  @MainActor final class HitchMonitor: NSObject {
    static let shared = HitchMonitor()

    struct Stall: Codable {
      var mark: String
      var at: Double
      var ms: Double
    }

    private var stalls: [Stall] = []
    private var iterations = 0
    private var awakeSince: Double?
    private var mark = ""
    private var startedAt = CACurrentMediaTime()
    private var threshold = 1000.0 / 120 + 0.5
    private var observers: [CFRunLoopObserver] = []
    private var listener: NSObjectProtocol?
    private var displayLink: CADisplayLink?
    private var scrollStep: Int32 = 0
    private var scrollFramesLeft = 0

    static func start() {
      shared.install()
    }

    private func install() {
      guard observers.isEmpty else { return }
      let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) {
        _, _ in
        MainActor.assumeIsolated { HitchMonitor.shared.awakeSince = CACurrentMediaTime() }
      }
      // Last of the observers before sleeping, so the frame's Core Animation commit counts.
      let sleep = CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, Int.max
      ) { _, _ in
        MainActor.assumeIsolated { HitchMonitor.shared.wentToSleep() }
      }
      for observer in [wake, sleep].compactMap({ $0 }) {
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        observers.append(observer)
      }
      let name = (UserDefaults.standard.string(forKey: "DebugAutomationName") ?? "dev.v57.code.debug") + ".perf"
      listener = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name(name), object: nil, queue: .main
      ) { note in
        guard let command = note.object as? String else { return }
        MainActor.assumeIsolated { HitchMonitor.shared.run(command) }
      }
    }

    private func wentToSleep() {
      guard let since = awakeSince else { return }
      awakeSince = nil
      iterations += 1
      let now = CACurrentMediaTime()
      let ms = (now - since) * 1000
      if ms > threshold {
        stalls.append(Stall(mark: mark, at: ((since - startedAt) * 1000).rounded(), ms: (ms * 10).rounded() / 10))
      }
    }

    private func run(_ command: String) {
      let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
      let argument = parts.count > 1 ? parts[1] : ""
      switch parts.first {
      case "reset":
        stalls = []
        iterations = 0
        startedAt = CACurrentMediaTime()
        mark = ""
      case "mark": mark = argument
      case "threshold": threshold = Double(argument) ?? threshold
      case "report": report(to: argument.isEmpty ? "/tmp/code-hitches.json" : argument)
      case "scrollrun":
        let values = argument.split(separator: ":").compactMap { Int($0) }
        guard values.count == 2 else { return }
        scroll(step: Int32(values[0]), frames: values[1])
      default: break
      }
    }

    private func report(to path: String) {
      struct Report: Codable {
        var iterations: Int
        var thresholdMs: Double
        var stalls: [Stall]
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted]
      let data = try? encoder.encode(Report(iterations: iterations, thresholdMs: threshold, stalls: stalls))
      try? data?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Scrolling

    private var scrollView: NSScrollView? {
      AppState.shared.debugModel?.workspace.selectedDocument?.textView?.enclosingScrollView
    }

    private func scroll(step: Int32, frames: Int) {
      displayLink?.invalidate()
      guard let scrollView else { return }
      scrollStep = step
      scrollFramesLeft = frames
      let link = scrollView.displayLink(target: self, selector: #selector(tick(_:)))
      link.add(to: .main, forMode: .common)
      displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
      guard scrollFramesLeft > 0, let scrollView,
        let cgEvent = CGEvent(
          scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: scrollStep, wheel2: 0, wheel3: 0),
        let event = NSEvent(cgEvent: cgEvent)
      else {
        link.invalidate()
        displayLink = nil
        return
      }
      scrollFramesLeft -= 1
      scrollView.scrollWheel(with: event)
    }
  }
#endif
