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
  /// `console:on|off`, `issues`, `back`, `quickhelp`, `type:<text>` (as if
  /// typed: completions open), `complete` (Esc), `key:up|down|return|tab|esc`,
  /// `hidden:on|off` (Show Hidden Files), `choose:on|off` (Choose Visible
  /// Files), `setvisible:<relative path>:on|off`, `quickopen:<query>|off`,
  /// `quickopenhidden:on|off`, `scroll:<lines>` (a scroll-wheel event over
  /// the editor; negative scrolls down), `find:<query>` (Find in Project),
  /// `findmode:containing|matchingWord|regularExpression`, `findcase:on|off`,
  /// `findopen:<file index>:<match index>` (opens a result),
  /// `dependency:<folder path>` (expands it under Package Dependencies),
  /// `select:<path>` (selects a navigator row, as a click does),
  /// `folder:<relative path>:on|off` (expands or collapses a tree folder),
  /// `focus` (the editor takes the keyboard), `menu:project|scheme|destination|off` (opens a kit menu),
  /// `navigator:on|off`, `size:<width>x<height>` (the window's content size).
  ///
  /// Launched with `-DebugAutomationName <name>`, the app listens for that
  /// name instead, so other Debug instances ignore the commands.
  @MainActor enum DebugAutomation {
    private static var observer: NSObjectProtocol?

    static func start() {
      guard observer == nil else { return }
      observer = DistributedNotificationCenter.default().addObserver(
        forName: Notification.Name(UserDefaults.standard.string(forKey: "DebugAutomationName") ?? "dev.v57.code.debug"),
        object: nil, queue: .main
      ) { note in
        guard let command = note.object as? String else { return }
        MainActor.assumeIsolated { run(command) }
      }
    }

    static func run(_ command: String) {
      if command.hasPrefix("window:") {
        let name = String(command.dropFirst("window:".count))
        AppState.shared.debugModel =
          AppState.shared.debugModels.compactMap(\.model).first { $0.workspace.name == name }
        return
      }
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
      case "back": services.goBack()
      case "forward": services.goForward()
      case "tab":
        if let tab = model.workspace.tabs.first(where: { $0.name == argument }) {
          model.workspace.selectedTabID = tab.id
        }
      case "notarization": model.notarizationSetup = NotarizationSetupRequest()
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
      case "type":
        // Typed one character at a time, as from the keyboard.
        if let textView = document?.textView {
          for character in argument {
            textView.insertText(String(character), replacementRange: textView.selectedRange())
            textView.onTyping?(String(character))
          }
        }
      case "complete": document?.textView?.complete(nil)
      case "focus":
        // The editor takes the keyboard, as after opening a file.
        if let textView = document?.textView { textView.window?.makeFirstResponder(textView) }
      case "scroll":
        // A line-based wheel event, as from a mouse, sent through the scroll view.
        if let scrollView = document?.textView?.enclosingScrollView, let lines = Int32(argument),
          let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0),
          let event = NSEvent(cgEvent: cgEvent)
        {
          scrollView.scrollWheel(with: event)
        }
      case "key":
        let selectors: [String: Selector] = [
          "up": #selector(NSResponder.moveUp(_:)), "down": #selector(NSResponder.moveDown(_:)),
          "return": #selector(NSResponder.insertNewline(_:)), "tab": #selector(NSResponder.insertTab(_:)),
          "backtab": #selector(NSResponder.insertBacktab(_:)), "esc": #selector(NSResponder.cancelOperation(_:)),
        ]
        if let selector = selectors[argument] { document?.textView?.doCommand(by: selector) }
      case "save": document?.save()
      case "insert": document?.textView?.insertText(argument, replacementRange: document!.textView!.selectedRange())
      case "console": model.isConsoleVisible = argument != "off"
      case "settings":
        if !argument.isEmpty { UserDefaults.standard.set(argument, forKey: "settings.tab") }
        AppState.shared.debugOpenSettings?()
      case "issues": model.isIssuesPresented.toggle()
      case "menu": model.openMenu = ChromeMenu(rawValue: argument)
      case "navigator": model.isNavigatorVisible = argument != "off"
      case "size":
        // size:<width>x<height>, the window's content size.
        let sides = argument.split(separator: "x").compactMap { Double($0) }
        if sides.count == 2, let window = NSApp.windows.first(where: { $0.title == model.workspace.name }) {
          window.setContentSize(NSSize(width: sides[0], height: sides[1]))
        }
      case "hidden":
        // The navigator's Show Hidden Files: hidden:on|off.
        model.workspace.visibility.showsHiddenFiles = argument != "off"
      case "choose":
        // Choose Visible Files: choose:on|off.
        model.isChoosingVisibleFiles = argument != "off"
      case "setvisible":
        // setvisible:<relative path>:on|off.
        if let colon = argument.lastIndex(of: ":") {
          let url = model.workspace.root.appendingPathComponent(String(argument[..<colon]))
          model.workspace.tree.reveal(url)
          model.workspace.setVisible(url, argument[argument.index(after: colon)...] != "off")
        }
      case "quickopen":
        // Opens Open Quickly with a query; quickopen:off closes it.
        model.isQuickOpenPresented = argument != "off"
        if argument != "off" { model.quickOpenQuery = argument }
      case "quickopenhidden": model.quickOpenIncludesHiddenFiles = argument != "off"
      case "find":
        model.findInProject()
        model.find.text = argument
        model.find.search(in: model.workspace)
      case "findmode":
        if let mode = SearchQuery.Mode(rawValue: argument) { model.find.mode = mode }
      case "findcase": model.find.isCaseSensitive = argument != "off"
      case "findopen":
        let parts = argument.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2, model.find.results.indices.contains(parts[0]) {
          let file = model.find.results[parts[0]]
          if file.matches.indices.contains(parts[1]) {
            let match = file.matches[parts[1]]
            services.open(
              model.workspace.root.appendingPathComponent(file.path), line: match.line,
              column: match.column + 1, length: match.length)
          }
        }
      case "dependency":
        model.expandedDependencyFolders.insert(URL(fileURLWithPath: argument))
      case "select": model.sidebarSelection = URL(fileURLWithPath: argument)
      case "folder":
        if let colon = argument.lastIndex(of: ":"),
          let node = model.workspace.tree.node(
            for: model.workspace.root.appendingPathComponent(String(argument[..<colon])))
        {
          model.workspace.tree.setExpanded(node, argument[argument.index(after: colon)...] != "off")
        }
      case "newwindow":
        // Open in New Window: the selected document, or newwindow:<path>.
        if !argument.isEmpty {
          model.openInNewWindow(URL(fileURLWithPath: argument))
        } else if let document {
          model.openInNewWindow(document)
        }
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
          "progress: \(actions.progress.map { "\($0.fraction.map { String(format: "%.2f", $0) } ?? "-") \($0.remaining.map { String(format: "%.0fs left", $0) } ?? "") \($0.message)" } ?? "-")",
          "issues: \(services.issues.count) (errors \(services.errorCount), warnings \(services.warningCount))",
          "servers: \(services.languageServers.states)",
          "document: \(document?.url.path ?? "-") line \(document?.textView?.currentSelection.line ?? 0)",
          "annotations: \(document.map { services.annotations(for: $0.url).map { "\($0.line + 1): \($0.message)" } } ?? [])",
          "breakpoints: \(services.breakpoints)",
          "execution: \(String(describing: services.executionLocation))",
          "debugger: \(String(describing: services.debugger?.state))",
          "status: \(services.statusMessage ?? "-")",
          "completions: \(document?.completion?.shownItems.prefix(15).map(\.label).joined(separator: ", ") ?? "-")",
          "selection: \(document?.textView.map { NSStringFromRange($0.selectedRange()) } ?? "-")",
          "line text: \(document?.textView.map { view in let text = view.string as NSString; return text.substring(with: text.lineRange(for: view.selectedRange())) } ?? "-")",
        ]
        lines += services.issues.prefix(20).map { "  issue: \($0.url?.lastPathComponent ?? "-"):\($0.line ?? 0) \($0.message)" }
        if let textView = document?.textView {
          var view: NSView? = textView
          while let current = view {
            lines.append("  view \(type(of: current)) frame \(current.frame) hidden \(current.isHidden) alpha \(current.alphaValue)")
            view = current.superview
          }
          lines.append("  text length \(textView.string.count) visible \(textView.visibleRect) clip \(textView.enclosingScrollView?.contentView.bounds ?? .zero) container \(textView.textContainer?.size ?? .zero) inset \(textView.textContainerInset) origin \(textView.textContainerOrigin)")
        }
        lines.append("tabs: \(model.workspace.tabs.map(\.name))")
        lines.append("history: back \(services.canGoBack) forward \(services.canGoForward)")
        lines.append(
          "detached: "
            + model.workspace.detachedDocuments.map { document in
              let window = document.textView?.window
              return "\(document.name) window \(window?.title ?? "-") level \(window?.level.rawValue ?? -1)"
            }.joined(separator: ", "))
        lines.append(
          "dependencies: "
            + model.workspace.dependencies.map { "\($0.name) \($0.detail) \($0.location?.path ?? "-")" }
            .joined(separator: ", "))
        let find = model.find
        lines.append(
          "find: \(find.text) searching \(find.isSearching) \(find.matchCount) in \(find.results.count) files: "
            + find.results.prefix(8).map { "\($0.path)×\($0.matches.count)" }.joined(separator: ", "))
        let index = model.workspace.index
        lines.append("index: \(index.paths.count) visible, \(index.hiddenPaths.count) hidden")
        lines.append(
          "quick open: "
            + index.search(model.quickOpenQuery, includingHidden: model.quickOpenIncludesHiddenFiles, limit: 10)
            .map { $0.path + ($0.isHidden ? " (hidden)" : "") }.joined(separator: ", "))
        lines.append("log tail:")
        lines += actions.log.entries.suffix(15).map { "  " + $0.text }
        try? lines.joined(separator: "\n").write(
          toFile: argument.isEmpty ? "/tmp/code-debug-state.txt" : argument, atomically: true, encoding: .utf8)
      default: break
      }
    }

    /// The document's editor is in a window.
    static func isShown(_ document: TextDocument) -> Bool { document.textView?.window != nil }

    private static func split(_ command: String) -> (String, String) {
      guard let colon = command.firstIndex(of: ":") else { return (command, "") }
      return (String(command[..<colon]), String(command[command.index(after: colon)...]))
    }
  }
#endif
