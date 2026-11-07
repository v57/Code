import AppKit
import CodeKit
import SwiftUI

/// The symbol menu's window: a borderless panel under the symbol (above it when there's no room), which never takes
/// focus, so the editor keeps the keys and hands the menu the ones it wants. It stays while the pointer goes to it,
/// also once ⌘ is let go, and closes on a click anywhere but the menu and the symbol, a scroll outside it, the pointer
/// going well away, and the window losing focus, moving or closing. Typing and Esc close it in the editor.
@MainActor final class SymbolMenuPanel {
  /// Draws the window's symbol menus; their Find References is Find in Project for the name as a whole word.
  static func install(on model: WindowModel) {
    let panel = SymbolMenuPanel()
    model.services.symbolMenuPresenter = { menu, textView, anchor in
      if let menu, let textView { panel.show(menu, from: textView, anchor: anchor) } else { panel.hide() }
    }
    model.services.findReferences = { [weak model] name in
      guard let model else { return }
      model.findInProject()
      model.find.mode = .matchingWord
      model.find.text = name
      model.find.search(in: model.workspace)
    }
  }

  private var panel: NSPanel?
  private var host: NSHostingView<AnyView>?
  private weak var menu: SymbolMenu?
  /// The symbol's first line on screen.
  private var anchor: NSRect = .zero
  private var monitors: [Any] = []
  private var observers: [NSObjectProtocol] = []
  private var awayTimer: Timer?
  /// The pointer came near the menu or the symbol (a menu opened from the keys or a click elsewhere waits for it).
  private var pointerWasNear = false

  /// How far the pointer may go from the menu and the symbol before the menu closes.
  private let awayDistance: CGFloat = 100
  private let gap: CGFloat = 4

  func show(_ menu: SymbolMenu, from textView: NSView, anchor: NSRect) {
    guard let window = textView.window else { return }
    hide()
    self.menu = menu
    self.anchor = anchor
    let view = SymbolMenuView(menu: menu) { [weak self] size in self?.place(size) }
    let root = AnyView(view.environment(\.colorScheme, window.effectiveAppearance.isDark ? .dark : .light))
    let host = NSHostingView(rootView: root)
    host.sizingOptions = []
    let panel = SymbolMenuWindow(
      contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .popUpMenu
    panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace]
    panel.isReleasedWhenClosed = false
    // It closes itself when the app loses focus; a capture of a background window keeps it.
    panel.hidesOnDeactivate = false
    panel.acceptsMouseMovedEvents = true
    panel.appearance = window.effectiveAppearance
    panel.contentView = host
    self.panel = panel
    self.host = host
    place(host.fittingSize)
    panel.orderFront(nil)
    watch(window, clip: textView.enclosingScrollView?.contentView)
  }

  func hide() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors = []
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    awayTimer?.invalidate()
    awayTimer = nil
    pointerWasNear = false
    panel?.orderOut(nil)
    panel = nil
    host = nil
    menu = nil
  }

  /// Under the symbol from 12pt before it (the rows' text lines up with it), above when there's no room below, inside
  /// the screen. The menu grows and shrinks as answers come, keeping its top edge (its bottom edge above the symbol).
  private func place(_ size: CGSize) {
    guard let panel, size.width > 0, size.height > 0 else { return }
    let screen = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame ?? .zero
    var x = anchor.minX - 12
    x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
    var y = anchor.minY - gap - size.height
    if y < screen.minY + 8 { y = anchor.maxY + gap }
    panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
  }

  private func close() {
    menu?.close()
    hide()
  }

  private func watch(_ window: NSWindow, clip: NSClipView?) {
    let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    let local = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
      let location = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
      MainActor.assumeIsolated {
        guard let self, let panel = self.panel else { return }
        // On the menu it goes on; on the symbol the editor jumps (it's a link).
        if panel.frame.contains(location) || self.anchor.insetBy(dx: -1, dy: -1).contains(location) { return }
        self.close()
      }
      return event
    }
    let scrolls = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self, let panel = self.panel, event.window !== panel else { return }
        self.close()
      }
      return event
    }
    let otherApps = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
      MainActor.assumeIsolated { self?.close() }
    }
    monitors = [local, scrolls, otherApps].compactMap { $0 }
    awayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkAway() }
    }
    let center = NotificationCenter.default
    var names: [(Notification.Name, AnyObject?)] = [
      (NSWindow.didMoveNotification, window), (NSWindow.didResizeNotification, window),
      (NSWindow.willCloseNotification, window),
    ]
    // Focus leaving closes it, when it had focus (a capture of a background window keeps it).
    if NSApp.isActive { names.append((NSApplication.didResignActiveNotification, nil)) }
    if window.isKeyWindow { names.append((NSWindow.didResignKeyNotification, window)) }
    // The editor scrolled (also momentum, or a scroll the events above don't see): the symbol moved away. Its bounds
    // also change in place as the editor lays out; only a move of the origin counts.
    if let clip {
      let origin = clip.bounds.origin
      clip.postsBoundsChangedNotifications = true
      observers.append(
        center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) {
          [weak self, weak clip] _ in
          MainActor.assumeIsolated {
            guard let clip, hypot(clip.bounds.origin.x - origin.x, clip.bounds.origin.y - origin.y) > 0.5 else { return }
            self?.close()
          }
        })
    }
    for (name, object) in names {
      observers.append(
        center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated { self?.close() }
        })
    }
  }

  /// The pointer went well away from the menu and the symbol, after being near them.
  private func checkAway() {
    guard let panel else { return }
    let point = NSEvent.mouseLocation
    let distance = [panel.frame, anchor].map { rect in
      hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
    }.min() ?? 0
    if distance <= awayDistance {
      pointerWasNear = true
    } else if pointerWasNear {
      close()
    }
  }
}

private final class SymbolMenuWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

extension NSAppearance {
  fileprivate var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
