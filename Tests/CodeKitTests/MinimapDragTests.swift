#if canImport(AppKit)
  import AppKit
  import Testing

  @testable import CodeKit

  @MainActor @Suite struct MinimapDragTests {
    /// Dragging the minimap's frame down a long file only ever scrolls the editor down: the editor's visible line
    /// count wavered as it scrolled, which the drag multiplied into jumps back and forth near the end.
    @Test func draggingDownNeverScrollsBack() async throws {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeKitMinimap-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let url = folder.appendingPathComponent("long.swift")
      let lines = (0..<1000).map { "let value\($0) = \"\(String(repeating: "x", count: $0 % 60))\"" }
      try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

      let document = TextDocument(url: url)
      await document.load()
      let editor = DocumentEditor.editor(for: document, configuration: EditorConfiguration())
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered,
        defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      editor.container.frame = window.contentView!.bounds
      window.contentView!.addSubview(editor.container)
      editor.container.layoutSubtreeIfNeeded()
      let textView = editor.scrollView.textView
      textView.layoutManager!.ensureLayout(for: textView.textContainer!)

      let minimap = editor.container.minimap
      #expect(minimap.bounds.height > 0)
      let clipView = editor.scrollView.contentView
      func event(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(
          with: type, location: minimap.convert(NSPoint(x: 40, y: y), to: nil), modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
      }
      // Grab the frame at the top, then drag to the bottom a point at a time.
      minimap.mouseDown(with: event(.leftMouseDown, y: 4))
      var last = clipView.bounds.minY
      var backwards: [CGFloat] = []
      var y: CGFloat = 4
      while y < minimap.bounds.height {
        y += 1
        minimap.mouseDragged(with: event(.leftMouseDragged, y: y))
        let top = clipView.bounds.minY
        if top < last - 0.5 { backwards.append(last - top) }
        last = top
      }
      minimap.mouseUp(with: event(.leftMouseUp, y: y))
      #expect(backwards.isEmpty, "scrolled back by \(backwards)")
      // It reached the end of the file (the editor scrolls on past its last line; the drag stops there).
      #expect(try #require(minimap.dataSource).minimapVisibleLines.upperBound >= 999.5)
    }

    /// With a bar floating over the editor's top (the tab strip), an editor at its top shows line 0 in the minimap's
    /// frame: the frame started a bar's height of lines down, as the text view's visibleRect already left the inset out.
    @Test func frameStartsAtTheTopUnderABar() async throws {
      let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodeKitMinimap-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let url = folder.appendingPathComponent("long.swift")
      try (0..<300).map { "let value\($0) = \($0)" }.joined(separator: "\n").write(
        to: url, atomically: true, encoding: .utf8)

      let document = TextDocument(url: url)
      await document.load()
      let editor = DocumentEditor.editor(for: document, configuration: EditorConfiguration())
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered,
        defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      editor.container.frame = window.contentView!.bounds
      window.contentView!.addSubview(editor.container)
      editor.container.layoutSubtreeIfNeeded()
      let textView = editor.scrollView.textView
      textView.layoutManager!.ensureLayout(for: textView.textContainer!)
      editor.container.contentInsets = NSEdgeInsets(top: 60, left: 0, bottom: 30, right: 0)

      let source = try #require(editor.container.minimap.dataSource)
      let clipView = editor.scrollView.contentView
      // At the top: line 0 (below the text container's inset) starts at the bar's bottom.
      let top = clipView.bounds.minY
      #expect(top + 60 == textView.textContainerOrigin.y)
      #expect(source.minimapVisibleLines.lowerBound == 0)
      // Scrolling to line 0 from the minimap comes back to the same place.
      source.minimapScroll(toTopLine: 20)
      #expect(source.minimapVisibleLines.lowerBound > 19)
      source.minimapScroll(toTopLine: 0)
      #expect(clipView.bounds.minY == top)
      #expect(source.minimapVisibleLines.lowerBound == 0)
    }
  }
#endif
