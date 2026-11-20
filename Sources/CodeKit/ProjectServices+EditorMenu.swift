#if os(macOS)
  import AppKit
  import CodeEditor
  import CodeLSP
  import CodeWorkspace
  import Observation

  /// The editor's own menu while it's up: what it shows and what its rows do. The app draws it with the kit's menu
  /// (`ProjectServices.editorMenu`), which takes the keys.
  @MainActor @Observable public final class EditorMenu: Identifiable {
    public let content: EditorMenuContent
    public let document: TextDocument.ID
    /// Where it opens (the pointer), in the editor view's space, from its top-left corner.
    public let point: CGPoint
    @ObservationIgnored var run: (EditorMenuContent.Action) -> Void = { _ in }

    init(content: EditorMenuContent, document: TextDocument.ID, point: CGPoint) {
      self.content = content
      self.document = document
      self.point = point
    }

    public func pick(_ row: EditorMenuContent.Row) {
      guard row.isEnabled else { return }
      run(row.action)
    }

    /// The menu as text, for Debug automation's dump.
    public var summary: String {
      var lines: [String] = []
      for part in content.parts {
        lines.append("[\(part.id)]" + (part.title.map { " \($0)" } ?? ""))
        for row in part.rows {
          lines.append("  \(row.isEnabled ? "" : "(off) ")\(row.title)\(row.hint.map { " [\($0)]" } ?? ""): \(row.preview)")
        }
      }
      return lines.joined(separator: "\n")
    }
  }

  /// Rename while it asks for the new name: the places are found as the name is typed.
  @MainActor @Observable public final class RenameRequest: Identifiable {
    /// The name as it is now.
    public let name: String
    public var newName: String
    /// The symbol on screen, in the editor view's space, from its top-left corner.
    public let anchor: CGRect
    public let document: TextDocument.ID
    /// The places found, and the files they're in; nil while they're looked for.
    public internal(set) var places: Int?
    public internal(set) var files = 0
    /// Why it can't be renamed, once known.
    public internal(set) var failure: String?
    public internal(set) var isRenaming = false
    @ObservationIgnored var sites: [RenameSite] = []
    /// The language server finds the places (the model couldn't): asked with the new name.
    @ObservationIgnored var asksServer = false
    @ObservationIgnored var position = LSPPosition(line: 0, character: 0)
    @ObservationIgnored var url: URL

    init(name: String, anchor: CGRect, document: TextDocument.ID, url: URL) {
      self.name = name
      newName = name
      self.anchor = anchor
      self.document = document
      self.url = url
    }

    /// What's wrong with the new name, if anything.
    public var problem: String? {
      if newName.isEmpty || newName == name { return nil }
      return Rename.isName(newName) ? nil : String(localized: "A name has letters, digits and _, and doesn’t start with a digit.")
    }

    public var canRename: Bool {
      places != nil && failure == nil && !isRenaming && !newName.isEmpty && newName != name && Rename.isName(newName)
    }

    /// The line under the field.
    public var status: String {
      if let failure { return failure }
      if let problem { return problem }
      guard let places else { return String(localized: "Finding the places that use \(name)…") }
      let placeText = String(localized: "\(places) places")
      let fileText = String(localized: "\(files) files")
      return asksServer
        ? String(localized: "\(placeText) in \(fileText), found by the language server.") : String(localized: "\(placeText) in \(fileText).")
    }
  }

  extension ProjectServices {
    // MARK: - The menu

    /// A right click in the editor (the text view has selected the word under the pointer, or put the caret there):
    /// the editor's own menu at `point` of the text view. `location`: the character under the pointer, if any.
    public func showEditorMenu(in document: TextDocument, at location: Int?, point: NSPoint) {
      guard let textView = document.textView else { return }
      editorMenuLookup?.cancel()
      hideSymbolMenu()
      let url = document.url
      let string = textView.string as NSString
      var context = EditorMenuContext()
      context.project = workspace.name
      context.fileName = url.lastPathComponent
      context.isEditable = textView.isEditable
      // A link takes the whole selection, unless the click was inside a selection of the person's own.
      var selection = textView.selectedRange()
      if let location, let link = EditorMenuContent.link(in: string, at: location),
        selection.length == 0 || NSIntersectionRange(selection, link.range).length == selection.length
      {
        context.link = link.url
        selection = link.range
        textView.setSelectedRange(selection)
      }
      context.selection = string.substring(with: selection)
      let first = textView.position(of: selection.location)
      // A selection ending at a line's start doesn't take that line.
      var last = textView.position(of: NSMaxRange(selection))
      if selection.length > 0, last.column == 0, last.line > first.line { last.line -= 1 }
      context.firstLine = first.line + 1
      context.lastLine = last.line + 1
      context.reference = EditorReference.text(file: url, root: workspace.root, firstLine: first.line + 1, lastLine: last.line + 1)
      let clicked = location.map { textView.position(of: $0).line } ?? first.line
      let all = annotations(for: url).sorted { ($0.line, $0.severity) < ($1.line, $1.severity) }
      let here = all.filter { $0.line == clicked }.sorted { $0.severity < $1.severity }
      context.issues = here.map(\.message)
      context.issueCount = all.count
      context.issueIndex = (here.first.flatMap { all.firstIndex(of: $0) } ?? 0) + 1
      context.clipboard = textView.isEditable ? NSPasteboard.general.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 } : nil
      if let spec = textView.spec { context.commentMarker = spec.lineComments.first ?? spec.blockComments.first?.open }
      context.breakpointsEnabled = textView.allowsBreakpoints && settings.breakpointsEnabled
      context.hasBreakpoint = textView.breakpoints.contains(first.line)
      context.quickHelpHint = languageServers.isOpen(url) ? nil : languageServerHint(for: url)

      let menuPoint = Self.editorPoint(point, in: textView)
      let show = { [weak self, weak document, weak textView] (context: EditorMenuContext) in
        guard let self, let document, let textView else { return }
        let menu = EditorMenu(content: EditorMenuContent.make(context), document: document.id, point: menuPoint)
        let line = first.line
        menu.run = { [weak self, weak document, weak textView] action in
          guard let self, let document, let textView else { return }
          self.perform(action, in: document, textView: textView, location: location ?? selection.location, line: line)
        }
        self.editorMenu = menu
      }
      // The symbol part: only for a word under the pointer that is all of the selection.
      guard let location, context.link == nil, let word = textView.identifierRange(at: location),
        selection.length == 0 || NSEqualRanges(selection, word)
      else { return show(context) }
      let position = textView.position(of: location)
      let text = textView.string
      let tiers = tiers
      let useModel = settings.usesModel(for: url)
      let useScanner = settings.usesScanner
      let root = workspace.root
      let serverRenames = languageServers.supportsRename(url)
      let name = string.substring(with: word)
      editorMenuLookup = Task { [weak self] in
        // The scanner and the model answer in milliseconds: the menu waits for them a moment rather than open
        // without its first part and change.
        enum Event: Sendable {
          case answer(SymbolAnswer?)
          case deadline
        }
        let answers = await withTaskGroup(of: Event.self) { group -> [SymbolAnswer] in
          var left = 0
          if useScanner {
            left += 1
            group.addTask { .answer(await tiers.scannerSymbols(url: url, text: text, line: position.line, column: position.column)) }
          }
          if useModel {
            left += 1
            group.addTask {
              .answer(await tiers.modelSymbols(url: url, text: text, line: position.line, column: position.column, countReferences: false).answer)
            }
          }
          group.addTask {
            try? await Task.sleep(for: .milliseconds(250))
            return .deadline
          }
          var found: [SymbolAnswer] = []
          for await event in group {
            guard case .answer(let answer) = event else { break }
            left -= 1
            if let answer, !answer.symbols.isEmpty { found.append(answer) }
            if left <= 0 { break }
          }
          group.cancelAll()
          return found
        }
        guard let self, !Task.isCancelled else { return }
        var context = context
        if let symbol = SymbolMenuContent.make(answers, pendingServer: nil, references: nil, file: url, root: root) {
          context.symbol = symbol
          let lead = SymbolMenuContent.merged(answers).first
          context.symbolTitle = lead.map { Self.shortName($0.description) }
          let place = lead?.description.symbol.place
          let inProject = place.map { $0.url.path.hasPrefix(root.standardizedFileURL.path + "/") } ?? false
          let modelIsSure = answers.contains { $0.tier == .model && $0.isSure } && !symbol.hasSeveralPlaces
          if !Rename.isName(name) {
            context.renameHint = String(localized: "\(name) isn’t a name Code can rename.")
          } else if modelIsSure, !inProject {
            context.renameHint = String(localized: "\(name) is declared outside \(self.workspace.name), where Code doesn’t change files.")
          } else if !modelIsSure, !serverRenames {
            context.renameHint = String(localized: "Code can’t tell every place that uses \(name), and no language server that renames is running.")
          }
        }
        show(context)
      }
    }

    /// `TripStore.save()`: the symbol with the type around it.
    static func shortName(_ description: SymbolDescription) -> String {
      guard let parent = description.parents.first, parent.kind != .module, !description.symbol.isValue else { return description.symbol.name }
      return parent.name + "." + description.symbol.name
    }

    /// The menu closed (a row was picked, Esc, a click outside).
    public func hideEditorMenu() {
      editorMenuLookup?.cancel()
      editorMenuLookup = nil
      editorMenu = nil
    }

    private func perform(_ action: EditorMenuContent.Action, in document: TextDocument, textView: CodeTextView, location: Int, line: Int) {
      switch action {
      case .symbol(.open(let place)): open(place.url, line: place.line + 1, column: place.column + 1, preview: true)
      case .symbol(.findReferences(let name)): findReferences?(name)
      case .symbol(.copy(let text)), .copyIssue(let text): Self.copy(text)
      case .copyReference(let text):
        Self.copy(text)
        showStatus(String(localized: "Copied \(text)"))
      case .symbol(.none): break
      case .showDefinitions:
        if let range = textView.identifierRange(at: location) {
          showSymbolMenu(in: document, at: location, range: range, fromClick: true)
        }
      case .quickHelp: showQuickHelp(in: document, at: location)
      case .rename: beginRename(in: document, at: location)
      case .showIssues: showIssues?()
      case .openLink(let url): NSWorkspace.shared.open(url)
      case .copyLink(let url): Self.copy(url.absoluteString)
      case .cut: textView.cut(nil)
      case .copy: textView.copy(nil)
      case .paste: textView.paste(nil)
      case .find(let text): findInProject?(text)
      case .comment: textView.toggleComment(nil)
      case .indent: textView.shiftRight(nil)
      case .outdent: textView.shiftLeft(nil)
      case .breakpoint: textView.toggleBreakpoint(atLine: line)
      }
    }

    /// Copy Reference (⌃⇧⌘C): the file and the selection's lines, as `EditorReference` writes them.
    public func copyReference(in document: TextDocument) {
      var first = 1
      var last = 1
      if let textView = document.textView {
        let selection = textView.selectedRange()
        let start = textView.position(of: selection.location)
        var end = textView.position(of: NSMaxRange(selection))
        if selection.length > 0, end.column == 0, end.line > start.line { end.line -= 1 }
        (first, last) = (start.line + 1, end.line + 1)
      }
      let text = EditorReference.text(file: document.url, root: workspace.root, firstLine: first, lastLine: last)
      Self.copy(text)
      showStatus(String(localized: "Copied \(text)"))
    }

    private static func copy(_ text: String) {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }

    /// A point of the text view in the editor view's space (the SwiftUI view's: from its top-left corner).
    static func editorPoint(_ point: NSPoint, in textView: NSView) -> CGPoint {
      guard let host = editorHost(of: textView) else { return point }
      let converted = host.convert(point, from: textView)
      return CGPoint(x: converted.x, y: host.isFlipped ? converted.y : host.bounds.height - converted.y)
    }

    static func editorRect(of range: NSRange, in textView: CodeTextView) -> CGRect {
      guard let host = editorHost(of: textView), let window = textView.window else { return .zero }
      let onScreen = textView.firstRect(forCharacterRange: range, actualRange: nil)
      let rect = host.convert(window.convertFromScreen(onScreen), from: nil)
      return CGRect(x: rect.minX, y: host.isFlipped ? rect.minY : host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func editorHost(of view: NSView) -> NSView? {
      var current = view.superview
      while let candidate = current {
        if candidate is CodeEditorHostView { return candidate }
        current = candidate.superview
      }
      return nil
    }

    // MARK: - Rename

    /// Rename… for the symbol at `location`: asks for the new name under it while the places are found, by the file's
    /// language model when it's sure of the symbol, else by its language server.
    public func beginRename(in document: TextDocument, at location: Int) {
      guard let textView = document.textView, let range = textView.identifierRange(at: location) else { return NSSound.beep() }
      let name = (textView.string as NSString).substring(with: range)
      guard Rename.isName(name) else { return showStatus(String(localized: "\(name) isn’t a name Code can rename.")) }
      let url = document.url
      let position = textView.position(of: range.location)
      let request = RenameRequest(name: name, anchor: Self.editorRect(of: range, in: textView), document: document.id, url: url)
      request.position = LSPPosition(line: position.line, character: position.column)
      renameRequest = request
      let text = textView.string
      let tiers = tiers
      let servers = languageServers
      let useModel = settings.usesModel(for: url)
      let serverRenames = languageServers.supportsRename(url)
      let lspPosition = request.position
      let projectName = workspace.name
      var openTexts: [String: String] = [:]
      for other in workspace.tabs where other.content == .text { openTexts[other.url.standardizedFileURL.path] = other.currentText }
      Task { [weak request] in
        let answer = useModel
          ? await tiers.modelRenameSites(url: url, text: text, line: position.line, column: position.column, name: name, openTexts: openTexts) : nil
        guard let request else { return }
        switch answer {
        case .sites(let sites)? where !sites.isEmpty:
          request.sites = sites
          request.files = Set(sites.map(\.url)).count
          request.places = sites.count
        case .outside?:
          request.failure = String(localized: "\(name) is declared outside \(projectName), where Code doesn’t change files.")
        default:
          guard serverRenames else {
            request.failure = String(localized: "Code can’t tell every place that uses \(name).")
            return
          }
          let locations = await servers.locations("textDocument/references", url: url, position: lspPosition)
          request.asksServer = true
          request.files = max(Set(locations.map(\.url)).count, 1)
          request.places = max(locations.count, 1)
        }
      }
    }

    public func cancelRename() { renameRequest = nil }

    /// Renames: open files are edited in their editor, as one undoable change each ("Rename"); the others are written
    /// on disk, in their own encoding, off the main thread. The status bar says how many places changed.
    public func commitRename(_ request: RenameRequest) {
      guard request.canRename else { return }
      let old = request.name
      let new = request.newName
      request.isRenaming = true
      let servers = languageServers
      Task {
        var sites = request.sites
        // A model's place counts only while it still reads the old name; a server's edits are its own.
        var check: String? = old
        if request.asksServer {
          let edits = await servers.rename(url: request.url, position: request.position, newName: new)
          sites = edits.filter { $0.range.start.line == $0.range.end.line }.map {
            RenameSite(
              url: $0.url, line: $0.range.start.line, column: $0.range.start.character,
              length: $0.range.end.character - $0.range.start.character, text: $0.newText)
          }
          check = nil
        }
        var places = 0
        var files = 0
        var closed: [URL: [RenameSite]] = [:]
        for (url, fileSites) in Dictionary(grouping: sites, by: \.url) {
          guard let document = workspace.document(for: url), document.content == .text else {
            closed[url] = fileSites
            continue
          }
          let (text, count) = Rename.replacing(fileSites, in: document.currentText, old: check, with: new)
          guard count > 0 else { continue }
          if let textView = document.textView {
            textView.applyEditedText(text, actionName: String(localized: "Rename"))
          } else {
            document.replaceText(text)
          }
          places += count
          files += 1
        }
        let closedFiles = closed
        let written = await Task.detached(priority: .userInitiated) {
          var places = 0
          var files = 0
          var failure: String?
          for (url, fileSites) in closedFiles {
            do {
              var count = 0
              let wrote = try ProjectReplace.rewrite(fileAt: url) { text in
                let result = Rename.replacing(fileSites, in: text, old: check, with: new)
                count = result.count
                return count > 0 ? result.text : nil
              }
              if wrote {
                places += count
                files += 1
              }
            } catch {
              failure = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
          }
          return (places, files, failure)
        }.value
        places += written.0
        files += written.1
        if renameRequest === request { renameRequest = nil }
        if let failure = written.2 {
          showStatus(String(localized: "Couldn’t rename in \(failure)"))
        } else if places == 0 {
          showStatus(String(localized: "Nothing was renamed: \(old) is no longer where it was found."))
        } else {
          showStatus(Rename.summary(old: old, new: new, places: places, files: files))
        }
      }
    }
  }
#endif
