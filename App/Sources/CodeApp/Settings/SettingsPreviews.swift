import CodeKit
import ComponentKit
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif

/// A few lines of code for a setting's preview, in the real editor with the current settings: the same text view,
/// highlighter, gutter and minimap as a project's window, read-only. Issues and breakpoints are made up for it.
struct EditorPreview: View {
  var text: String
  var configuration: EditorConfiguration
  /// The line with the caret (from 0): it gets the current-line bar, when that is on. Off for every other preview,
  /// where a bar on the first line would only be noise.
  var currentLine: Int?
  var annotations: [LineAnnotation] = []
  var showsMessages = true
  var breakpoints: Set<Int> = []
  var showsMinimap = false

  /// Tall enough for `lines` lines at the current font size, with a limit for the biggest sizes.
  static func height(lines: Int, configuration: EditorConfiguration) -> CGFloat {
    min(CGFloat(lines) * configuration.fontSize * 1.5 + 14, 140)
  }

  var body: some View {
    #if canImport(AppKit)
      EditorPreviewRepresentable(preview: self)
    #else
      Text(text)
        .font(.system(size: configuration.fontSize, design: .monospaced))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(6)
    #endif
  }
}

#if canImport(AppKit)
  private struct EditorPreviewRepresentable: NSViewRepresentable {
    let preview: EditorPreview

    func makeNSView(context: Context) -> EditorPreviewView {
      EditorPreviewView(text: preview.text)
    }

    func updateNSView(_ view: EditorPreviewView, context: Context) {
      view.update(preview)
    }
  }

  /// The scroll view and the minimap beside it, as a project's editor lays them out.
  @MainActor private final class EditorPreviewView: NSView, MinimapDataSource {
    private let scrollView: CodeEditorScrollView
    private let minimap = MinimapView()
    private var textView: CodeTextView { scrollView.textView }

    init(text: String) {
      scrollView = CodeEditorScrollView(text: text, language: CodeHighlighter.spec(forLanguage: "swift"))
      super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 72))
      clipsToBounds = true
      addSubview(scrollView)
      addSubview(minimap)
      // Not selectable either: no I-beam over it, and it never takes focus from the form.
      textView.isEditable = false
      textView.isSelectable = false
      minimap.dataSource = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ preview: EditorPreview) {
      var configuration = preview.configuration
      if preview.currentLine == nil { configuration.highlightCurrentLine = false }
      // Breakpoints are drawn in the gutter.
      if !preview.breakpoints.isEmpty { configuration.showLineNumbers = true }
      textView.configuration = configuration
      if textView.string != preview.text {
        textView.isEditable = true
        textView.replaceAllText(preview.text)
        textView.isEditable = false
      }
      textView.annotations = preview.annotations
      textView.showsAnnotationMessages = preview.showsMessages
      textView.breakpoints = preview.breakpoints
      if let line = preview.currentLine { textView.goTo(line: line + 1) }
      // A preview doesn't scroll, so nothing shows that it could (setting the wrapping brings a scroller back).
      scrollView.hasVerticalScroller = false
      scrollView.hasHorizontalScroller = false
      minimap.isHidden = !preview.showsMinimap
      minimap.theme = textView.theme
      minimap.refresh()
      needsLayout = true
    }

    override func layout() {
      super.layout()
      let width = minimap.isHidden ? 0 : min(MinimapView.defaultWidth, bounds.width / 3)
      scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width - width, height: bounds.height)
      minimap.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    }

    // MARK: Minimap

    var minimapLineCount: Int { textView.lineIndex.count }

    /// Each word as a bar in its syntax color.
    func minimapRuns(ofLine line: Int) -> [MinimapRun] {
      let text = textView.string as NSString
      let range = textView.lineIndex.range(ofLine: line)
      let tokens = textView.tokens(ofLine: line)
      var runs: [MinimapRun] = []
      for offset in 0..<range.length {
        let character = text.character(at: range.location + offset)
        guard character != 0x20, character != 0x0A else { continue }
        let location = range.location + offset
        let kind = tokens.first { NSLocationInRange(location, $0.range) }?.kind ?? .plainText
        if let last = runs.last, last.column + last.length == offset, last.kind == kind {
          runs[runs.count - 1].length += 1
        } else {
          runs.append(MinimapRun(column: offset, length: 1, kind: kind))
        }
      }
      return runs
    }

    /// The lines that fit, from the top: the preview doesn't scroll.
    var minimapVisibleLines: ClosedRange<Double> {
      let lineHeight = textView.configuration.fontSize * 1.5
      return 0...min(Double(bounds.height / lineHeight), Double(minimapLineCount))
    }

    func minimapScroll(toTopLine line: Double) {}
  }
#endif

/// A row of files with their real icons, as the navigator shows them.
struct FilesPreview: View {
  var files: [(name: String, isDirectory: Bool)]
  var showsExtensions = true

  var body: some View {
    HStack(spacing: 16) {
      ForEach(files, id: \.name) { file in
        let url = URL(fileURLWithPath: "/" + file.name)
        HStack(spacing: 5) {
          FileIconView(for: url, isDirectory: file.isDirectory, size: 14)
          Text(FileName.display(url, showExtensions: showsExtensions)).kitFont(.callout).lineLimit(1)
        }
        .fixedSize()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
  }
}

/// The toolbar's actions, or only the project's name when they're off.
struct ToolbarPreview: View {
  var showsActions: Bool

  var body: some View {
    HStack(spacing: 12) {
      if showsActions {
        Image(systemName: "play.fill").foregroundStyle(Hue.green.text)
        Image(systemName: "stop.fill").foregroundStyle(.kitTertiary)
      }
      Text("Atlas").kitFont(.callout)
      if showsActions {
        Label("Atlas", systemImage: "swift").kitFont(.caption)
        Label("My Mac", systemImage: "laptopcomputer").kitFont(.caption)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
  }
}

/// The completion list under a word being typed: a drawing, as the real list is a panel of its own (a window can't
/// be placed in a form).
struct CompletionPreview: View {
  var isOn: Bool
  var configuration: EditorConfiguration

  var body: some View {
    let column = configuration.fontSize * 0.62 * 19 + 44
    EditorPreview(text: "let title = trip.na", configuration: configuration)
      .overlay(alignment: .topLeading) {
        if isOn {
          VStack(alignment: .leading, spacing: 1) {
            ForEach(["name", "nameTag", "navigationTitle"], id: \.self) { name in
              Text(name)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 6)
                .frame(width: 140, alignment: .leading)
            }
          }
          .padding(.vertical, 3)
          .kitSurface(.card, cornerRadius: 6)
          .offset(x: column, y: configuration.fontSize * 1.5 + 3)
        }
      }
  }
}

/// What a setting's preview shows, in Swift. The ones about typing or saving are a before and after in comments, as
/// the whitespace they're about doesn't show by itself: `·` for a space, `→` for a tab.
enum PreviewSample {
  static let code = """
    struct Trip {
      let stops: Int  // How far it goes
      var title: String { "\\(stops) stops" }
    }
    """

  static let oneLine = "let trip = Trip(stops: 3)"

  static let indented = """
    func start() {
    \tfor stop in stops {
    \t\tvisit(stop)
    """

  static let longLine = """
    // One long line
    let summary = trips.filter { $0.stops > 3 }.map(\\.title).joined(separator: ", ")
    """

  static let currentLine = """
    let trip = Trip(stops: 3)
    trip.start()
    print(trip.title)
    """

  /// Long enough to see the shape of a file in the minimap.
  static let file = (0..<8).map { index in
    """
    // MARK: Part \(index)
    struct Part\(index): View {
      var count = \(index)
      var body: some View {
        Text("Part \\(count)").padding()
      }
    }

    """
  }.joined(separator: "\n")

  static let issues = """
    let total = stops.count
    print(totl)
    var unused = 3
    """

  static let issueAnnotations = [
    LineAnnotation(line: 1, severity: .error, message: "Cannot find 'totl' in scope"),
    LineAnnotation(line: 2, severity: .warning, message: "Variable 'unused' was never used"),
  ]

  static func tabKey(insertSpaces: Bool, tabWidth: Int) -> String {
    let indent = insertSpaces ? String(repeating: "·", count: tabWidth) : "→" + String(repeating: " ", count: max(tabWidth - 1, 0))
    return """
      // Tab inserts \(insertSpaces ? "\(tabWidth) spaces" : "a tab")
      \(indent)visit(stop)
      """
  }

  static func closing(isOn: Bool) -> String {
    """
    // Typing ( gives
    print(\(isOn ? ")" : "")
    """
  }

  static func trimming(isOn: Bool) -> String {
    """
    // Saved: end spaces \(isOn ? "go" : "stay")
    let name = "Atlas"\(isOn ? "" : "····")
    """
  }

  static func formatting(isOn: Bool) -> String {
    """
    // Typed: let  stops=[1,2 ,3]
    \(isOn ? "let stops = [1, 2, 3]" : "let  stops=[1,2 ,3]")
    """
  }
}
