import CodeKit
import ComponentKit
import SwiftUI

/// A process stack circle opened by a click: the run's live icon, name, where it runs and for how long, its progress,
/// the last lines of its output following as it runs (scroll back for more), and its actions: Open in Console,
/// Restart, Stop; a failure's offers Show Issues, Restart, Dismiss. Esc or its × closes it back to a circle.
struct ProcessCard: View {
  let run: ActionRun
  let close: () -> Void
  @Environment(WindowModel.self) private var model
  @FocusState private var isFocused: Bool

  static let width: CGFloat = 360
  /// Lines of output the card keeps: Open in Console has the rest.
  static let lines = 200

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if run.phase == .running, !run.isRunningApp, let fraction = run.progress?.fraction {
        KitProgressBar(value: fraction, hue: ProcessText.hue(of: run.kind))
      }
      ProcessOutput(run: run)
      actions
    }
    .padding(10)
    .frame(width: Self.width)
    .kitSurface(.floating, cornerRadius: 16)
    .focusable()
    .focusEffectDisabled()
    .focused($isFocused)
    .onKeyPress(.escape) {
      close()
      return .handled
    }
    .onExitCommand(perform: close)
    .onAppear { isFocused = true }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(run.title)
    .accessibilityAction(.escape, close)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 10) {
      ProcessIcon(run: run, size: 28, shape: .rounded)
      VStack(alignment: .leading, spacing: 1) {
        Text(run.title)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(ProcessText.meta(of: run, at: context.date))
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.kitSecondary)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.kitSecondary)
          .frame(width: 20, height: 20)
          .background(.kitFill, in: Circle())
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .kitHelp("Close", shortcut: "esc")
    }
  }

  @ViewBuilder private var actions: some View {
    let controller = model.services.actions
    HStack(spacing: 6) {
      if case .failed = run.phase, !run.issues.isEmpty {
        Button("Show Issues", systemImage: "exclamationmark.triangle") { model.isIssuesPresented = true }
      } else {
        Button("Open in Console", systemImage: "terminal") {
          close()
          model.showConsole(at: run)
        }
      }
      Button {
        close()
        controller.restart(run)
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .kitHelp("Restart", shortcut: "⌘R")
      .accessibilityLabel("Restart")
      Spacer(minLength: 0)
      if run.isWorking {
        Button("Stop", systemImage: "stop.fill") { controller.stop(run) }
      } else {
        Button("Dismiss", systemImage: "xmark") {
          close()
          withKitAnimation { controller.dismiss(run) }
        }
      }
    }
    .buttonStyle(.kit)
    .controlSize(.small)
  }
}

/// The card's output: the run's last lines in mono, errors and warnings marked, following the end as lines arrive.
private struct ProcessOutput: View {
  let run: ActionRun
  @State private var height: CGFloat = 0
  @Environment(\.self) private var environment

  static let maxHeight: CGFloat = 150

  var body: some View {
    let text = styled
    ScrollView {
      Text(text)
        .font(.system(size: 11, design: .monospaced))
        .lineSpacing(3)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }
    .kitFollowsEnd()
    .scrollIndicators(.automatic)
    .frame(height: min(Self.maxHeight, max(30, height)))
    .background(.kitFillSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .mask {
      // The oldest lines fade out under the top edge once there's more than fits.
      LinearGradient(
        stops: [.init(color: height > Self.maxHeight ? .clear : .black, location: 0), .init(color: .black, location: 0.16)],
        startPoint: .top, endPoint: .bottom)
    }
  }

  private var styled: AttributedString {
    _ = run.log.revision
    let entries = run.log.entries.suffix(ProcessCard.lines)
    if entries.isEmpty {
      var waiting = AttributedString(run.isWorking ? "Nothing yet." : "No output.")
      waiting.foregroundColor = KitColor.kitSecondary.resolve(in: environment)
      return waiting
    }
    let secondary = KitColor.kitSecondary.resolve(in: environment)
    let red = Hue.red.textColor(in: environment)
    let orange = Hue.orange.textColor(in: environment)
    let bold = Font.system(size: 11, weight: .semibold, design: .monospaced)
    var result = AttributedString()
    for (index, entry) in entries.enumerated() {
      if index > 0 { result += AttributedString("\n") }
      var line = AttributedString(entry.text)
      switch entry.kind {
      case .command, .status:
        line.foregroundColor = secondary
      case .failure:
        line.foregroundColor = red
        line.font = bold
      case .output:
        // "Trip.swift:42:9: warning:", "error: …": the marker in the hue, as the console's blocks do.
        for (marker, color) in [("error:", red), ("warning:", orange)] {
          if let range = entry.text.range(of: marker) {
            let end = entry.text.distance(from: entry.text.startIndex, to: range.upperBound)
            let start = line.index(line.startIndex, offsetByCharacters: 0)
            let stop = line.index(line.startIndex, offsetByCharacters: end)
            line[start..<stop].foregroundColor = color
            line[start..<stop].font = bold
            break
          }
        }
      }
      result += line
    }
    return result
  }
}
