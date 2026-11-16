#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI

/// The simulator's picture, live: the framebuffer shown by Core Animation as it is drawn, turned as the device is
/// held. A click is a touch and a drag a swipe; ⌥ adds a second finger mirrored through the centre (a pinch); while
/// the view has focus, keys go to the device. It fills what it is given: size it to `screen.pixelSize`'s proportions.
public struct SimulatorScreenView: NSViewRepresentable {
  var screen: SimulatorScreen

  public init(screen: SimulatorScreen) {
    self.screen = screen
  }

  public func makeNSView(context: Context) -> SimulatorNSView {
    let view = SimulatorNSView()
    view.attach(screen)
    return view
  }

  public func updateNSView(_ view: SimulatorNSView, context: Context) {
    if view.screen !== screen { view.attach(screen) }
    // Read here so a turn or a new surface updates the view.
    _ = screen.quarterTurns
    _ = screen.pixelSize
    view.surfaceChanged()
  }

  public static func dismantleNSView(_ view: SimulatorNSView, coordinator: ()) {
    view.detach()
  }
}

public final class SimulatorNSView: NSView {
  fileprivate(set) weak var screen: SimulatorScreen?
  private let picture = CALayer()
  private var isTouching = false

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = .black
    picture.contentsGravity = .resize
    picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
    layer?.addSublayer(picture)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func attach(_ screen: SimulatorScreen) {
    detach()
    self.screen = screen
    screen.onFrame = { [weak self] in self?.frameDrawn() }
    screen.onSurface = { [weak self] in self?.surfaceChanged() }
    surfaceChanged()
  }

  func detach() {
    screen?.onFrame = nil
    screen?.onSurface = nil
    screen = nil
    picture.contents = nil
  }

  func surfaceChanged() {
    picture.contents = screen?.surface
    needsLayout = true
  }

  private func frameDrawn() {
    // The surface is the same object with new pixels: tell Core Animation to look again.
    let selector = Selector(("setContentsChanged"))
    if picture.responds(to: selector) {
      picture.perform(selector)
    } else {
      let contents = picture.contents
      picture.contents = nil
      picture.contents = contents
    }
  }

  override public func layout() {
    super.layout()
    let turns = screen?.quarterTurns ?? 0
    let turned = turns % 2 == 1
    // The surface is portrait; turned a quarter, it is laid out sideways and rotated into the bounds.
    picture.bounds = CGRect(
      x: 0, y: 0, width: turned ? bounds.height : bounds.width, height: turned ? bounds.width : bounds.height)
    picture.position = CGPoint(x: bounds.midX, y: bounds.midY)
    picture.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
  }

  // MARK: Touches

  /// The point as 0…1 of the framebuffer from its top left, whatever way the device is turned.
  func framebufferPoint(_ event: NSEvent) -> CGPoint {
    let point = convert(event.locationInWindow, from: nil)
    guard bounds.width > 0, bounds.height > 0 else { return .zero }
    let x = min(max(point.x / bounds.width, 0), 1)
    let y = min(max(1 - point.y / bounds.height, 0), 1)
    return Self.framebufferPoint(x: x, y: y, quarterTurns: screen?.quarterTurns ?? 0)
  }

  /// Turns a point of the picture as shown into the portrait framebuffer's.
  static func framebufferPoint(x: CGFloat, y: CGFloat, quarterTurns: Int) -> CGPoint {
    switch ((quarterTurns % 4) + 4) % 4 {
    case 1: CGPoint(x: 1 - y, y: x)
    case 2: CGPoint(x: 1 - x, y: 1 - y)
    case 3: CGPoint(x: y, y: 1 - x)
    default: CGPoint(x: x, y: y)
    }
  }

  private func send(_ phase: SimulatorScreen.TouchPhase, _ event: NSEvent) {
    let point = framebufferPoint(event)
    let second = event.modifierFlags.contains(.option) ? CGPoint(x: 1 - point.x, y: 1 - point.y) : nil
    screen?.touch(phase, at: point, second: second)
  }

  override public var acceptsFirstResponder: Bool { true }
  override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override public func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    isTouching = true
    send(.down, event)
  }

  override public func mouseDragged(with event: NSEvent) {
    if isTouching { send(.moved, event) }
  }

  override public func mouseUp(with event: NSEvent) {
    guard isTouching else { return }
    isTouching = false
    send(.up, event)
  }

  // MARK: Keys

  override public func keyDown(with event: NSEvent) {
    guard !event.modifierFlags.contains(.command), let usage = HIDUsage.usage(forKeyCode: event.keyCode) else {
      return super.keyDown(with: event)
    }
    screen?.key(usage: usage, down: true)
  }

  override public func keyUp(with event: NSEvent) {
    guard let usage = HIDUsage.usage(forKeyCode: event.keyCode) else { return super.keyUp(with: event) }
    screen?.key(usage: usage, down: false)
  }

  override public func flagsChanged(with event: NSEvent) {
    guard let usage = HIDUsage.usage(forKeyCode: event.keyCode), let flag = HIDUsage.modifier(forKeyCode: event.keyCode)
    else { return super.flagsChanged(with: event) }
    // ⌘ and ⌥ stay the Mac's: ⌘ for the app's shortcuts, ⌥ for the second finger.
    guard flag == .shift || flag == .control else { return }
    screen?.key(usage: usage, down: event.modifierFlags.contains(flag))
  }
}

/// macOS virtual key codes as USB HID keyboard usages.
enum HIDUsage {
  static func usage(forKeyCode code: UInt16) -> UInt32? { table[code] }

  static func modifier(forKeyCode code: UInt16) -> NSEvent.ModifierFlags? {
    switch code {
    case 56, 60: .shift
    case 59, 62: .control
    case 58, 61: .option
    case 55, 54: .command
    default: nil
    }
  }

  private static let table: [UInt16: UInt32] = [
    0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0a, 4: 0x0b, 34: 0x0c, 38: 0x0d, 40: 0x0e, 37: 0x0f,
    46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13, 12: 0x14, 15: 0x15, 1: 0x16, 17: 0x17, 32: 0x18, 9: 0x19, 13: 0x1a,
    7: 0x1b, 16: 0x1c, 6: 0x1d,
    18: 0x1e, 19: 0x1f, 20: 0x20, 21: 0x21, 23: 0x22, 22: 0x23, 26: 0x24, 28: 0x25, 25: 0x26, 29: 0x27,
    36: 0x28, 53: 0x29, 51: 0x2a, 48: 0x2b, 49: 0x2c, 27: 0x2d, 24: 0x2e, 33: 0x2f, 30: 0x30, 42: 0x31, 41: 0x33,
    39: 0x34, 50: 0x35, 43: 0x36, 47: 0x37, 44: 0x38,
    124: 0x4f, 123: 0x50, 125: 0x51, 126: 0x52, 117: 0x4c, 115: 0x4a, 119: 0x4d, 116: 0x4b, 121: 0x4e,
    56: 0xe1, 60: 0xe5, 59: 0xe0, 62: 0xe4, 58: 0xe2, 61: 0xe6, 55: 0xe3, 54: 0xe7,
  ]
}
#endif
