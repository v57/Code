import AppKit
import CodeKit
import SwiftUI

/// Xcode's debug area under the editor: the debug bar while debugging, and
/// the output of the last action (build log, program output, LLDB).
struct ConsoleView: View {
  @Environment(WindowModel.self) private var model
  @State private var command = ""
  @State private var filter = ""

  var body: some View {
    let services = model.services
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        if let debugger = services.debugger {
          DebugBar(debugger: debugger)
          Divider().frame(height: 14)
        }
        if let scheme = services.actions.selectedScheme {
          Text(scheme.name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        Spacer()
        TextField("Filter", text: $filter)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .frame(width: 160)
        Button {
          services.actions.log.clear()
        } label: {
          Image(systemName: "trash")
        }
        .help("Clear Console")
        Button {
          model.isConsoleVisible = false
        } label: {
          Image(systemName: "rectangle.bottomthird.inset.filled")
        }
        .help("Hide Debug Area (⇧⌘Y)")
      }
      .buttonStyle(.borderless)
      .padding(.horizontal, 10)
      .frame(height: 28)
      .background(.bar)
      Divider()
      LogTextView(log: services.actions.log, filter: filter)
      if let debugger = services.debugger {
        Divider()
        HStack(spacing: 6) {
          Text("(lldb)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
          TextField("", text: $command)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .onSubmit {
              guard !command.isEmpty else { return }
              debugger.sendCommand(command)
              command = ""
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
      }
    }
  }
}

/// Continue/Pause, Step Over, Step Into, Step Out, and the stopped frame.
private struct DebugBar: View {
  let debugger: DebugSession

  var body: some View {
    let isPaused: Bool = {
      if case .paused = debugger.state { return true }
      return false
    }()
    HStack(spacing: 8) {
      Button {
        isPaused ? debugger.continueRunning() : debugger.pause()
      } label: {
        Image(systemName: isPaused ? "play.fill" : "pause.fill")
      }
      .help(isPaused ? "Continue (⌃⌘Y)" : "Pause (⌃⌘Y)")
      Button(action: debugger.stepOver) { Image(systemName: "arrow.turn.down.right") }
        .help("Step Over (F6)")
        .disabled(!isPaused)
      Button(action: debugger.stepInto) { Image(systemName: "arrow.down.to.line") }
        .help("Step Into (F7)")
        .disabled(!isPaused)
      Button(action: debugger.stepOut) { Image(systemName: "arrow.up.to.line") }
        .help("Step Out (F8)")
        .disabled(!isPaused)
      if let frame = debugger.frame {
        Text(frame)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}

/// The log in a read-only text view, appended as lines arrive and kept
/// scrolled to the end while it is at the end.
private struct LogTextView: NSViewRepresentable {
  let log: ActionLog
  let filter: String

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSTextView.scrollableTextView()
    let textView = scrollView.documentView as! NSTextView
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.usesFindBar = true
    textView.textContainerInset = NSSize(width: 6, height: 6)
    textView.font = Coordinator.font
    textView.backgroundColor = .textBackgroundColor
    context.coordinator.textView = textView
    context.coordinator.attach(log)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    _ = log.revision
    context.coordinator.attach(log)
    if context.coordinator.filter != filter {
      context.coordinator.filter = filter
      context.coordinator.reload()
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  @MainActor final class Coordinator {
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    weak var textView: NSTextView?
    weak var log: ActionLog?
    var filter = ""

    func attach(_ log: ActionLog) {
      guard self.log !== log else { return }
      self.log = log
      log.onAppend = { [weak self] entries in self?.append(entries) }
      log.onClear = { [weak self] in self?.reload() }
      reload()
    }

    func reload() {
      guard let storage = textView?.textStorage else { return }
      storage.setAttributedString(NSAttributedString())
      append(log?.entries ?? [])
    }

    private func append(_ entries: [ActionLog.Entry]) {
      guard let textView, let storage = textView.textStorage else { return }
      let visible = textView.enclosingScrollView?.contentView.bounds ?? .zero
      let atEnd = visible.maxY >= textView.bounds.height - 30
      let text = NSMutableAttributedString()
      for entry in entries where filter.isEmpty || entry.text.localizedCaseInsensitiveContains(filter) {
        text.append(NSAttributedString(string: entry.text + "\n", attributes: Self.attributes(for: entry)))
      }
      storage.append(text)
      // Keep the text view's length bounded like the log.
      if storage.length > 4_000_000 {
        storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 3_000_000))
      }
      if atEnd { textView.scrollToEndOfDocument(nil) }
    }

    static func attributes(for entry: ActionLog.Entry) -> [NSAttributedString.Key: Any] {
      var color = NSColor.labelColor
      var font = Self.font
      switch entry.kind {
      case .command:
        color = .secondaryLabelColor
      case .status:
        color = .secondaryLabelColor
        font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
      case .failure:
        color = .systemRed
        font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
      case .output:
        if entry.text.contains("error:") || entry.text.contains(" error ") || entry.text.hasPrefix("error") {
          color = .systemRed
        } else if entry.text.contains("warning:") {
          color = .systemOrange
        }
      }
      return [.font: font, .foregroundColor: color]
    }
  }
}
