#if DEBUG
  import AppKit
  import CodeKit

  /// Drives a window from the command line in Debug builds, for testing
  /// without clicking:
  ///
  ///     swift -e 'import Foundation; DistributedNotificationCenter.default()
  ///       .postNotificationName(.init("dev.v57.code.debug"), object: "open:/path/File.swift:12")'
  ///
  /// Commands: `open:<path>[:line]`, `perform:run|build|test|clean`, `stop`,
  /// `scheme:<name>`, `destination:<name or id>`, `definition` (at the
  /// caret), `breakpoint` (toggle at the caret), `save`, `insert:<text>`,
  /// `console:on|off`, `issues`, `back`, `quickhelp`.
  @MainActor enum DebugAutomation {
    private static var observer: NSObjectProtocol?

    static func start() {
      guard observer == nil else { return }
      observer = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name("dev.v57.code.debug"), object: nil, queue: .main
      ) { note in
        guard let command = note.object as? String else { return }
        MainActor.assumeIsolated { run(command) }
      }
    }

    private static func run(_ command: String) {
      guard let model = AppState.shared.debugModel else { return }
      let services = model.services
      let (name, argument) = split(command)
      let document = model.workspace.selectedDocument
      switch name {
      case "open":
        var path = argument
        var line = 1
        if let colon = argument.lastIndex(of: ":"), let number = Int(argument[argument.index(after: colon)...]) {
          path = String(argument[..<colon])
          line = number
        }
        services.open(URL(fileURLWithPath: path), line: line)
      case "perform":
        if let kind = ActionKind(rawValue: argument) { model.perform(kind) }
      case "stop": services.actions.stop()
      case "scheme":
        if let scheme = services.actions.schemes.first(where: { $0.name == argument }) {
          services.actions.selectedSchemeID = scheme.id
        }
      case "destination":
        if let destination = services.actions.destinations.first(where: {
          $0.name == argument || $0.id == argument
        }) {
          services.actions.selectedDestinationID = destination.id
        }
      case "definition":
        if let document, let textView = document.textView {
          services.jumpToDefinition(in: document, at: textView.selectedRange().location)
        }
      case "quickhelp":
        if let document, let textView = document.textView {
          services.showQuickHelp(in: document, at: textView.selectedRange().location)
        }
      case "breakpoint":
        if let textView = document?.textView {
          textView.toggleBreakpoint(atLine: textView.currentSelection.line - 1)
        }
      case "column":
        // Moves the caret to a column of its line (from 1).
        if let textView = document?.textView, let column = Int(argument) {
          textView.goTo(line: textView.currentSelection.line, column: column)
        }
      case "save": document?.save()
      case "insert": document?.textView?.insertText(argument, replacementRange: document!.textView!.selectedRange())
      case "console": model.isConsoleVisible = argument != "off"
      case "issues": model.isIssuesPresented.toggle()
      case "back": services.goBack()
      case "continue": services.debugger?.continueRunning()
      case "step": services.debugger?.stepOver()
      case "dump":
        // Writes the window's state for checking from the shell.
        let actions = services.actions
        var lines = [
          "schemes: " + actions.schemes.map { "\($0.name)[\($0.toolchain.rawValue)]" }.joined(separator: ", "),
          "scheme: \(actions.selectedScheme?.name ?? "-")",
          "destinations: " + actions.destinations.map { "\($0.name)[\($0.kind.rawValue)]" }.joined(separator: ", "),
          "destination: \(actions.selectedDestination?.name ?? "-")",
          "state: \(actions.state)",
          "issues: \(services.issues.count) (errors \(services.errorCount), warnings \(services.warningCount))",
          "servers: \(services.languageServers.states)",
          "document: \(document?.url.path ?? "-") line \(document?.textView?.currentSelection.line ?? 0)",
          "annotations: \(document.map { services.annotations(for: $0.url).map { "\($0.line + 1): \($0.message)" } } ?? [])",
          "breakpoints: \(services.breakpoints)",
          "execution: \(String(describing: services.executionLocation))",
          "debugger: \(String(describing: services.debugger?.state))",
          "status: \(services.statusMessage ?? "-")",
        ]
        lines += services.issues.prefix(20).map { "  issue: \($0.url?.lastPathComponent ?? "-"):\($0.line ?? 0) \($0.message)" }
        if let textView = document?.textView {
          var view: NSView? = textView
          while let current = view {
            lines.append("  view \(type(of: current)) frame \(current.frame) hidden \(current.isHidden) alpha \(current.alphaValue)")
            view = current.superview
          }
          lines.append("  text length \(textView.string.count) visible \(textView.visibleRect)")
        }
        lines.append("tabs: \(model.workspace.tabs.map(\.name))")
        lines.append("log tail:")
        lines += actions.log.entries.suffix(15).map { "  " + $0.text }
        try? lines.joined(separator: "\n").write(
          toFile: argument.isEmpty ? "/tmp/code-debug-state.txt" : argument, atomically: true, encoding: .utf8)
      default: break
      }
    }

    private static func split(_ command: String) -> (String, String) {
      guard let colon = command.firstIndex(of: ":") else { return (command, "") }
      return (String(command[..<colon]), String(command[command.index(after: colon)...]))
    }
  }
#endif
