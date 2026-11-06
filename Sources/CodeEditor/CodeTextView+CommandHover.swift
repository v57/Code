#if canImport(AppKit)
  import AppKit

  /// ⌘ held over a symbol: it's underlined as a link (a click jumps to its definition), and after a moment
  /// `onCommandHover` is asked to show what it is. Moving off it, letting go of ⌘, typing, clicking or scrolling ends
  /// the hover (`onCommandHoverEnd`).
  extension CodeTextView {
    /// How long the pointer rests on a symbol before its information is asked for.
    static let commandHoverDelay: Duration = .milliseconds(350)

    /// The state of a ⌘-hover: the symbol under the pointer and the pending ask.
    final class CommandHover {
      var range: NSRange?
      var task: Task<Void, Never>?
      var area: NSTrackingArea?
      /// The ask went out: its end must be said.
      var asked = false
    }

    public override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let area = commandHover.area { removeTrackingArea(area) }
      let area = NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
      addTrackingArea(area)
      commandHover.area = area
    }

    public override func mouseMoved(with event: NSEvent) {
      super.mouseMoved(with: event)
      updateCommandHover(at: convert(event.locationInWindow, from: nil), flags: event.modifierFlags)
    }

    public override func flagsChanged(with event: NSEvent) {
      super.flagsChanged(with: event)
      guard let window else { return }
      let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
      updateCommandHover(at: visibleRect.contains(point) ? point : nil, flags: event.modifierFlags)
    }

    public override func mouseExited(with event: NSEvent) {
      super.mouseExited(with: event)
      endCommandHover()
    }

    public override func scrollWheel(with event: NSEvent) {
      endCommandHover()
      super.scrollWheel(with: event)
    }

    /// Follows the pointer while ⌘ alone is held.
    func updateCommandHover(at point: NSPoint?, flags: NSEvent.ModifierFlags) {
      guard onCommandHover != nil, flags.intersection(.deviceIndependentFlagsMask) == .command, let point,
        let location = characterUnderPoint(point), let range = identifierRange(at: location),
        !isInsideNumber(range)
      else { return endCommandHover() }
      NSCursor.pointingHand.set()
      guard range != commandHover.range else { return }
      endCommandHover()
      commandHover.range = range
      // The layout manager's delegate draws the underline (`shouldUseTemporaryAttributes`).
      layoutManager?.invalidateDisplay(forCharacterRange: range)
      commandHover.task = Task { @MainActor [weak self] in
        try? await Task.sleep(for: Self.commandHoverDelay)
        guard let self, !Task.isCancelled, self.commandHover.range == range else { return }
        self.commandHover.asked = true
        self.onCommandHover?(range.location, range)
      }
    }

    /// Takes the underline away and closes what the hover showed.
    func endCommandHover() {
      commandHover.task?.cancel()
      commandHover.task = nil
      if let range = commandHover.range {
        commandHover.range = nil
        let length = (string as NSString).length
        let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
        if clamped.length > 0 { layoutManager?.invalidateDisplay(forCharacterRange: clamped) }
        NSCursor.iBeam.set()
      }
      if commandHover.asked {
        commandHover.asked = false
        onCommandHoverEnd?()
      }
    }

    /// Hovers the character at `location` with ⌘ held, as the pointer would; `nil` ends the hover (Debug automation).
    public func commandHover(at location: Int?) {
      guard let location, let layoutManager, let textContainer, location < (string as NSString).length else {
        return endCommandHover()
      }
      let glyph = layoutManager.glyphIndexForCharacter(at: location)
      let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
      let point = NSPoint(x: rect.midX + textContainerOrigin.x, y: rect.midY + textContainerOrigin.y)
      updateCommandHover(at: point, flags: .command)
    }

    /// The character drawn under `point`, not the nearest insertion point: past a line's end there is none.
    func characterUnderPoint(_ point: NSPoint) -> Int? {
      guard let layoutManager, let textContainer else { return nil }
      let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
      var fraction: CGFloat = 0
      let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
      guard glyph < layoutManager.numberOfGlyphs else { return nil }
      let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
      guard rect.contains(inContainer) else { return nil }
      return layoutManager.characterIndexForGlyph(at: glyph)
    }

    /// `1_000`, `0x1F`: digits aren't symbols.
    private func isInsideNumber(_ range: NSRange) -> Bool {
      guard let text = textStorage?.mutableString, range.location < text.length else { return true }
      let first = text.character(at: range.location)
      return first >= 0x30 && first <= 0x39
    }
  }
#endif
