import CodeKit
import ComponentKit
import SwiftUI

/// Every build, test and run of the window's project, floating on the editor as a circle: stacked down its trailing
/// edge 8pt before the minimap (before the scroller without one) and 8pt under the bars, newest at the bottom. The
/// pointer grows a circle leftwards into a capsule with its name, status and Stop; a click opens it further into a
/// card with its output, following as it runs (`ProcessCard`); a click outside or Esc closes it. A succeeded run
/// leaves after 3 s, a stopped one at once, a failed one stays until dismissed. Past five, the fifth circle counts the
/// rest and lists them in a menu. When the caret's line runs under the circles, they slide below it.
///
/// Put it over the editor: `safeTop` is where the bars over it end, in the global space.
struct ProcessStack: View {
  var geometry: EditorOverlayGeometry?
  var safeTop: CGFloat?
  @Environment(WindowModel.self) private var model
  @State private var hovered: ActionRun.ID?
  /// The run whose card is open.
  @State private var openID: ActionRun.ID?
  /// The circles' height at rest, for moving out of the caret line's way.
  @State private var restHeight: CGFloat = 0

  static let circle: CGFloat = 30
  static let spacing: CGFloat = 6
  static let gap: CGFloat = 8
  static let maxCircles = 5
  /// How long a run that succeeded stays.
  static let lingers: TimeInterval = 3

  var body: some View {
    let actions = model.services.actions
    let shown = actions.runs.filter(Self.isShown)
    let overflow = Self.overflow(of: shown)
    let circles = shown.filter { run in !overflow.contains { $0 === run } }
    GeometryReader { proxy in
      let trailing = (geometry?.trailingInset ?? 0) + Self.gap
      ZStack(alignment: .topTrailing) {
        if openID != nil {
          // A click outside the card closes it (and goes no further, as outside a kit popover).
          Color.clear
            .contentShape(Rectangle())
            .onTapGesture { close() }
        }
        VStack(alignment: .trailing, spacing: Self.spacing) {
          ForEach(circles) { run in
            ProcessItem(
              run: run, isHovered: hovered == run.id, isOpen: openID == run.id,
              hover: { inside in
                withKitAnimation(.kitFast) {
                  if inside {
                    hovered = run.id
                  } else if hovered == run.id {
                    hovered = nil
                  }
                }
              },
              open: { withKitAnimation { openID = run.id } },
              close: close)
            .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .trailing)))
          }
          if !overflow.isEmpty {
            OverflowCircle(runs: overflow)
              .transition(.opacity)
          }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
          if openID == nil, hovered == nil { restHeight = height }
        }
        .padding(.top, stackTop(in: proxy, trailing: trailing))
        .padding(.trailing, trailing)
      }
      .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
    }
    .animation(.kit, value: shown.map(\.id))
    .animation(.kit, value: geometry?.caretLine?.maxY)
    .task(id: shown.filter { $0.phase == .succeeded }.map(\.id)) { await dismissSucceeded() }
    .onChange(of: shown.map(\.id)) { _, ids in
      if let openID, !ids.contains(openID) { self.openID = nil }
    }
    .onChange(of: model.processStackDebug) { _, command in follow(command, circles: Array(circles)) }
  }

  /// Under the bars, or under the caret's line when its text runs under the circles at rest.
  private func stackTop(in proxy: GeometryProxy, trailing: CGFloat) -> CGFloat {
    let origin = proxy.frame(in: .global).minY
    let size = proxy.size
    let rest = max(0, (safeTop ?? origin) - origin) + Self.gap
    guard openID == nil, var line = geometry?.caretLine, restHeight > 0 else { return rest }
    let frame = proxy.frame(in: .global)
    line = line.offsetBy(dx: -frame.minX, dy: -origin)
    let circles = CGRect(
      x: size.width - trailing - Self.circle, y: rest, width: Self.circle, height: restHeight)
    let covered = line.maxX > circles.minX - 4 && line.maxY > circles.minY && line.minY < circles.maxY
    return covered ? line.maxY + Self.gap : rest
  }

  private func close() {
    guard openID != nil else { return }
    withKitAnimation { openID = nil }
    // The card took the keyboard: the editor has it back.
    model.workspace.selectedDocument?.focusEditor()
  }

  /// Takes the runs that succeeded off the stack `lingers` seconds after they did, unless the pointer is on one or
  /// its card is open.
  private func dismissSucceeded() async {
    let actions = model.services.actions
    while !Task.isCancelled {
      let done = actions.runs.filter { $0.phase == .succeeded && !$0.isDismissed }
      guard !done.isEmpty else { return }
      let now = Date()
      for run in done
      where now.timeIntervalSince(run.finished ?? now) >= Self.lingers && hovered != run.id && openID != run.id {
        withKitAnimation { actions.dismiss(run) }
      }
      try? await Task.sleep(for: .milliseconds(400))
    }
  }

  /// The runs the fifth circle lists when there are more than five: the oldest finished ones first, then the oldest
  /// still going, so what runs stays in sight.
  static func overflow(of shown: [ActionRun]) -> [ActionRun] {
    guard shown.count > maxCircles else { return [] }
    let hidden = shown.filter { !$0.isWorking } + shown.filter(\.isWorking)
    let ids = Set(hidden.prefix(shown.count - maxCircles + 1).map(\.id))
    return shown.filter { ids.contains($0.id) }
  }

  /// Still going, failed (until dismissed) or just succeeded; a stopped run leaves at once.
  static func isShown(_ run: ActionRun) -> Bool {
    guard !run.isDismissed else { return false }
    switch run.phase {
    case .waiting, .running, .failed, .succeeded: return true
    case .stopped: return false
    }
  }

  /// Debug builds' `stack:` commands (hover, open a circle by its place from the top).
  private func follow(_ command: ProcessStackDebug?, circles: [ActionRun]) {
    guard let command else { return }
    func run(_ index: Int) -> ActionRun.ID? { circles.indices.contains(index) ? circles[index].id : nil }
    withKitAnimation {
      switch command.action {
      case .hover(let index): hovered = run(index)
      case .open(let index): openID = run(index)
      case .off:
        hovered = nil
        openID = nil
      }
    }
  }
}

/// A Debug build's command for the stack (`DebugAutomation`'s `stack:`); `token` makes a repeat a change.
struct ProcessStackDebug: Equatable {
  enum Action: Equatable {
    case hover(Int)
    case open(Int)
    case off
  }

  var action: Action
  var token = UUID()
}

/// One run: a circle at rest, a capsule under the pointer, a card when clicked.
private struct ProcessItem: View {
  let run: ActionRun
  let isHovered: Bool
  let isOpen: Bool
  let hover: (Bool) -> Void
  let open: () -> Void
  let close: () -> Void
  @Environment(WindowModel.self) private var model

  var body: some View {
    Group {
      if isOpen {
        ProcessCard(run: run, close: close)
          .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .topTrailing)))
      } else {
        capsule
      }
    }
    .kitContextMenu { ProcessMenu(run: run) }
  }

  private var capsule: some View {
    let expanded = isHovered
    return HStack(spacing: 7) {
      ProcessIcon(run: run, size: 20)
      if expanded {
        Text(run.title)
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1)
          .transition(.opacity)
        TimelineView(.periodic(from: .now, by: 1)) { context in
          let status = ProcessText.status(of: run, at: context.date)
          if !status.isEmpty {
            Text(status)
              .font(.system(size: 12))
              .monospacedDigit()
              .foregroundStyle(ProcessText.statusStyle(of: run))
              .lineLimit(1)
          }
        }
        .transition(.opacity)
        MiniButton(run: run)
          .transition(.opacity)
      }
    }
    .padding(.leading, expanded ? 5 : 0)
    .padding(.trailing, expanded ? 6 : 0)
    .frame(minWidth: ProcessStack.circle, minHeight: ProcessStack.circle, maxHeight: ProcessStack.circle)
    .fixedSize()
    .background {
      Capsule(style: .continuous)
        .fill(.kitCard)
        .overlay(Capsule(style: .continuous).strokeBorder(.kitBorder, lineWidth: 0.5))
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(expanded ? 0.16 : 0.1), radius: expanded ? 6 : 2, y: expanded ? 3 : 1)
    }
    .contentShape(Capsule(style: .continuous))
    .onHover(perform: hover)
    .onTapGesture(perform: open)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(run.title)
    .accessibilityValue(ProcessText.status(of: run, at: Date()))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { open() }
  }
}

/// The capsule's Stop, or × on a failure (dismisses it).
private struct MiniButton: View {
  let run: ActionRun
  @Environment(WindowModel.self) private var model

  var body: some View {
    let actions = model.services.actions
    let working = run.isWorking
    Button {
      withKitAnimation { working ? actions.stop(run) : actions.dismiss(run) }
    } label: {
      Image(systemName: working ? "stop.fill" : "xmark")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(.kitSecondary)
        .frame(width: 18, height: 18)
        .background(.kitFill, in: Circle())
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .kitHelp(working ? "Stop" : "Dismiss")
  }
}

/// The run's kind in its live icon: the ring is its progress, the colour its state.
struct ProcessIcon: View {
  let run: ActionRun
  var size: CGFloat
  var shape: KitShape = .circle

  var body: some View {
    LiveIcon(systemImage: run.kind.symbolName, hue: ProcessText.hue(of: run.kind), status: status, size: size, shape: shape)
  }

  private var status: WorkStatus {
    switch run.phase {
    case .waiting, .stopped: return .paused()
    // An app has no end: no ring, the run's green.
    case .running where run.isRunningApp: return .idle
    case .running: return .working(progress: run.progress?.fraction)
    case .succeeded: return .done
    case .failed(let message): return .failed(message)
    }
  }
}

/// The circle that counts the runs past the fifth and lists them in a menu.
private struct OverflowCircle: View {
  let runs: [ActionRun]
  @Environment(WindowModel.self) private var model

  var body: some View {
    Text("+\(runs.count)")
      .font(.system(size: 11, weight: .semibold))
      .monospacedDigit()
      .frame(width: ProcessStack.circle, height: ProcessStack.circle)
      .background {
        Capsule(style: .continuous)
          .fill(.kitCard)
          .overlay(Capsule(style: .continuous).strokeBorder(.kitBorder, lineWidth: 0.5))
          .background(.ultraThinMaterial, in: Capsule(style: .continuous))
          .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
      }
      .contentShape(Circle())
      .kitMenu {
        ForEach(runs) { run in
          Button(run.title, systemImage: ProcessText.menuSymbol(of: run)) { model.showConsole(at: run) }
            .kitMenuHint(ProcessText.status(of: run, at: Date()))
            .kitMenuPreview("Opens the console at \(run.title)’s output.")
        }
      }
      .accessibilityLabel("\(runs.count) more")
  }
}

/// A circle's right-click menu: the run's actions, then the ones for all of them.
private struct ProcessMenu: View {
  let run: ActionRun
  @Environment(WindowModel.self) private var model

  var body: some View {
    let actions = model.services.actions
    let working = actions.runs.filter(\.isWorking)
    let finished = actions.runs.filter { !$0.isWorking && !$0.isDismissed }
    KitMenuPreview(ProcessText.summary(of: run))
    Button("Show Output", systemImage: "terminal") { model.showConsole(at: run) }
      .kitMenuPreview("Opens the console at \(run.title)’s output.")
    Button("Restart", systemImage: "arrow.clockwise") { actions.restart(run) }
      .kitMenuHint("⌘R")
      .kitMenuPreview(
        run.isWorking ? "Stops \(run.title) and starts it again." : "Runs \(run.title) again.")
    if run.isWorking {
      Button("Stop", systemImage: "stop.fill") { actions.stop(run) }
        .kitMenuHint("⌘.")
        .kitMenuPreview("Stops \(run.title).")
    } else {
      Button("Dismiss", systemImage: "xmark") { actions.dismiss(run) }
        .kitMenuPreview("Takes \(run.title) off the editor. The console keeps its output.")
    }
    Divider()
    Button("Stop All", systemImage: "stop.fill") { actions.stopAll() }
      .kitMenuHint(working.isEmpty ? nil : "\(working.count)")
      .kitMenuPreview(working.isEmpty ? nil : "Stops \(ProcessText.list(working.map(\.title))).")
      .disabled(working.isEmpty)
    Button("Hide Finished", systemImage: "xmark") { withKitAnimation { actions.hideFinished() } }
      .kitMenuPreview(
        finished.isEmpty ? nil : "Takes \(ProcessText.list(finished.map(\.title))) off the editor. The console keeps them.")
      .disabled(finished.isEmpty)
  }
}

/// What the stack says of a run.
enum ProcessText {
  /// The kind's colour: builds orange, tests the accent, runs green.
  static func hue(of kind: ActionKind) -> Hue {
    switch kind {
    case .run: return .green
    case .build: return .orange
    case .test: return .accent
    case .clean, .lint: return .gray
    case .install, .export, .upload: return .indigo
    }
  }

  /// The capsule's status: "Compiling 31/48", "31 / 48 tests", "4:12", "Done · 12 s", "2 failed".
  @MainActor static func status(of run: ActionRun, at now: Date) -> String {
    switch run.phase {
    case .waiting(let other): return "Waiting for \(other)"
    case .running:
      if run.isRunningApp { return clock(run.duration(at: now)) }
      if run.kind == .test, run.testsRun > 0 { return tests(of: run) }
      let message = run.progress?.message ?? run.stepTitle ?? ""
      return [message.isEmpty ? nil : message, run.place].compactMap { $0 }.joined(separator: " · ")
    case .succeeded: return "Done · \(seconds(run.duration(at: now)))"
    case .failed(let message): return message
    case .stopped: return "Stopped"
    }
  }

  @MainActor static func statusStyle(of run: ActionRun) -> AnyShapeStyle {
    switch run.phase {
    case .succeeded: return AnyShapeStyle(Hue.green.text)
    case .failed: return AnyShapeStyle(Hue.red.text)
    default: return AnyShapeStyle(.kitSecondary)
    }
  }

  /// "31 / 48 tests", or "31 tests" before a run of them finished.
  @MainActor static func tests(of run: ActionRun) -> String {
    if let expected = run.testsExpected, expected >= run.testsRun { return "\(run.testsRun) / \(expected) tests" }
    return run.testsRun == 1 ? "1 test" : "\(run.testsRun) tests"
  }

  /// The card's line under the name: where it runs, for how long, how far ("on studio-mac · 1:42 · 31 of 48"); a
  /// failure's says what failed ("Test · 2 failed").
  @MainActor static func meta(of run: ActionRun, at now: Date) -> String {
    if case .failed(let message) = run.phase {
      return [run.kind.title, message].joined(separator: " · ")
    }
    var parts: [String] = []
    if let place = run.place {
      parts.append("on \(place)")
    } else if let destination = run.destination, run.kind == .run || run.kind == .test {
      parts.append("on \(destination.name)")
    }
    parts.append(clock(run.duration(at: now)))
    switch run.phase {
    case .waiting(let other): parts.append("waiting for \(other)")
    case .running where run.kind == .test && run.testsRun > 0:
      parts.append(run.testsExpected.map { "\(run.testsRun) of \($0)" } ?? tests(of: run))
    case .running where !run.isRunningApp:
      if let message = run.progress?.message, !message.isEmpty { parts.append(message) }
    case .succeeded: parts.append(run.kind == .run ? "Finished" : "Succeeded")
    case .stopped: parts.append("Stopped")
    default: break
    }
    return parts.joined(separator: " · ")
  }

  /// The right-click menu's panel while no row is highlighted.
  @MainActor static func summary(of run: ActionRun) -> String {
    let status = status(of: run, at: Date())
    let place = run.place.map { " on \($0)" } ?? ""
    return status.isEmpty ? "\(run.title)\(place)." : "\(run.title)\(place): \(status)."
  }

  /// A row's icon in the overflow menu: the kind's, a failure's ×.
  @MainActor static func menuSymbol(of run: ActionRun) -> String {
    if case .failed = run.phase { return "xmark" }
    return run.kind.symbolName
  }

  /// "4:12", "1:02:09".
  static func clock(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
  }

  /// "12 s", "1:42".
  static func seconds(_ interval: TimeInterval) -> String {
    interval < 60 ? "\(max(0, Int(interval.rounded()))) s" : clock(interval)
  }

  /// "A", "A and B", "A, B and C".
  static func list(_ names: [String]) -> String {
    guard names.count > 1 else { return names.first ?? "" }
    return names.dropLast().joined(separator: ", ") + " and " + names.last!
  }
}
