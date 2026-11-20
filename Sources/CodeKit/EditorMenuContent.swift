import Foundation

// What the editor's own menu (a right click on its text; the canvas's `code-13` and `code-14` boards) shows, built
// from what is under the pointer: platform-neutral and without views, so the app draws it and the tests read it.
//
// Its parts always come in one order, and a part that doesn't apply is left out: what is under the pointer (an issue,
// a symbol, a link), the clipboard, Find, the lines, the breakpoint. Rows about the file stay in the tab's menu.

/// What a right click landed on, as the editor and the tiers know it.
public struct EditorMenuContext: Equatable, Sendable {
  /// The selection's text (a right click selects the word under the pointer); empty with only a caret.
  public var selection = ""
  /// The selected lines, or the caret's line twice (from 1).
  public var firstLine = 1
  public var lastLine = 1
  public var isEditable = true
  /// The project's name, for Find and Rename.
  public var project = ""
  /// The issues on the clicked line, worst first.
  public var issues: [String] = []
  /// How many issues the file has, and which of them the first one here is (from 1).
  public var issueCount = 0
  public var issueIndex = 0
  public var fileName = ""
  /// The symbol under the pointer, as the symbol menu describes it.
  public var symbol: SymbolMenuContent?
  /// Its qualified name (`TripStore.save()`), for the part's title.
  public var symbolTitle: String?
  /// A language server can answer Quick Help; else why not.
  public var quickHelpHint: String?
  /// Rename can find every place; else why not.
  public var renameHint: String?
  /// The link under the pointer.
  public var link: URL?
  /// What Paste would put here; nil with nothing to paste.
  public var clipboard: String?
  /// The file's comment marker (`//`), nil when its language has none.
  public var commentMarker: String?
  public var breakpointsEnabled = true
  public var hasBreakpoint = false
  /// Where the selection is, as other tools write it: `Sources/Atlas/TripStore.swift:20` (`EditorReference`).
  public var reference: String?

  public init() {}

  var hasSelection: Bool { !selection.isEmpty }
  var spansLines: Bool { lastLine > firstLine }
}

public struct EditorMenuContent: Equatable, Sendable {
  public enum Icon: String, Sendable {
    case jump, type, help, references, rename, copy, issues, link, cut, paste, reference, find, comment, indent, outdent, breakpoint
  }

  public enum Action: Hashable, Sendable {
    /// A row of the symbol menu: its place opens, its name is found or copied.
    case symbol(SymbolMenuContent.Action)
    /// Several places declare the symbol: the symbol menu lists them.
    case showDefinitions
    case quickHelp, rename
    case showIssues, copyIssue(String)
    case openLink(URL), copyLink(URL)
    case cut, copy, paste
    case copyReference(String)
    case find(String)
    case comment, indent, outdent, breakpoint
  }

  public struct Row: Identifiable, Equatable, Sendable {
    public var id: String
    public var icon: Icon
    public var title: String
    /// Its shortcut.
    public var hint: String?
    /// What picking it does, with the real names and line numbers; for a row that can't run, why.
    public var preview: String
    public var isEnabled = true
    public var action: Action
  }

  public struct Part: Identifiable, Equatable, Sendable {
    public var id: String
    /// What its rows act on (the issue, the symbol, the link); nil for the parts every menu has.
    public var title: String?
    public var rows: [Row]
  }

  public var parts: [Part]

  public var rows: [Row] { parts.flatMap(\.rows) }

  public static func make(_ context: EditorMenuContext) -> EditorMenuContent {
    var parts: [Part] = []
    let line = context.firstLine

    if let issue = context.issues.first {
      let where_ =
        context.issueCount > 1
        ? String(localized: "Opens Issues at this one, \(context.issueIndex) of \(context.issueCount) in \(context.fileName).")
        : String(localized: "Opens Issues at this one, the only one in \(context.fileName).")
      let all = context.issues.joined(separator: "\n")
      parts.append(
        Part(
          id: "issue", title: issue,
          rows: [
            Row(id: "issue.show", icon: .issues, title: String(localized: "Show in Issues"), hint: "⌥⌘5", preview: where_, action: .showIssues),
            Row(
              id: "issue.copy", icon: .copy, title: context.issues.count > 1 ? String(localized: "Copy \(context.issues.count) Issues") : String(localized: "Copy Issue"),
              preview: String(localized: "Copies “\(clipped(issue, 60))”."), action: .copyIssue(all)),
          ]))
    }

    if let symbol = context.symbol, !symbol.rows.isEmpty {
      let name = symbol.path.last?.name ?? context.selection
      var rows: [Row] = []
      if symbol.hasSeveralPlaces {
        let count = symbol.rows.filter { $0.definition != nil }.count
        rows.append(
          Row(
            id: "definition", icon: .jump, title: String(localized: "Jump to Definition…"), hint: "⌃⌘J",
            preview: String(localized: "\(count) places declare \(name): lists them under it to choose from."),
            action: .showDefinitions))
      } else if let row = symbol.rows.first(where: { $0.id == "definition" }) {
        // "A click on the symbol does the same" is the symbol menu's: here the click is ⌘-click.
        let sentence = row.preview.replacingOccurrences(of: " A click on the symbol does the same.", with: "")
        rows.append(
          Row(
            id: "definition", icon: .jump, title: row.title, hint: "⌃⌘J",
            preview: row.isEnabled ? sentence : String(localized: "\(name) is declared where Code can’t open it."),
            isEnabled: row.isEnabled, action: .symbol(row.action)))
      }
      if let row = symbol.rows.first(where: { $0.id == "type" }) {
        rows.append(
          Row(id: "type", icon: .type, title: row.title, preview: row.preview, isEnabled: row.isEnabled, action: .symbol(row.action)))
      }
      rows.append(
        Row(
          id: "help", icon: .help, title: String(localized: "Show Quick Help"), hint: "⌃⇧⌘/",
          preview: context.quickHelpHint ?? String(localized: "Shows what the language server says about \(name), under it."),
          isEnabled: context.quickHelpHint == nil, action: .quickHelp))
      if let row = symbol.rows.first(where: { $0.id == "references" }) {
        rows.append(Row(id: "references", icon: .references, title: row.title, preview: row.preview, action: .symbol(row.action)))
      }
      rows.append(
        Row(
          id: "rename", icon: .rename, title: String(localized: "Rename…"),
          preview: context.renameHint
            ?? String(localized: "Asks for a new name, then changes \(name) everywhere \(context.project) uses it."),
          isEnabled: context.renameHint == nil && context.isEditable, action: .rename))
      if let row = symbol.rows.first(where: { $0.id == "copy" }) {
        rows.append(Row(id: "name", icon: .copy, title: row.title, preview: row.preview, action: .symbol(row.action)))
      }
      parts.append(Part(id: "symbol", title: context.symbolTitle ?? name, rows: rows))
    }

    if let link = context.link {
      let shown = Self.shown(link)
      parts.append(
        Part(
          id: "link", title: shown,
          rows: [
            Row(id: "link.open", icon: .link, title: String(localized: "Open Link"), preview: String(localized: "Opens \(shown) in your browser."), action: .openLink(link)),
            Row(id: "link.copy", icon: .copy, title: String(localized: "Copy Link"), preview: String(localized: "Copies \(link.absoluteString)."), action: .copyLink(link)),
          ]))
    }

    // Cut and Copy stay in place, dimmed, with nothing selected: Paste is always the third row.
    let what =
      context.spansLines
      ? String(localized: "the \(context.lastLine - context.firstLine + 1) selected lines") : "“\(clipped(context.selection, 40))”"
    let nothing = String(localized: "Nothing is selected.")
    var paste = String(localized: "Nothing to paste.")
    if let clipboard = context.clipboard {
      let lines = clipboard.split(separator: "\n", omittingEmptySubsequences: false).count
      // Never the clipboard's own words: it may hold a password.
      let copied = lines > 1 ? String(localized: "the \(lines) copied lines") : String(localized: "what you copied")
      paste =
        context.hasSelection
        ? String(localized: "Puts \(copied) in place of \(what).") : String(localized: "Puts \(copied) here, at line \(line).")
    }
    var clipboardRows: [Row] = []
    if let reference = context.reference {
      clipboardRows.append(
        Row(
          id: "reference", icon: .reference, title: String(localized: "Copy Reference"), hint: "⌃⇧⌘C",
          preview: String(localized: "Copies \(reference), the file and line as compilers and terminals write them."),
          action: .copyReference(reference)))
    }
    parts.append(
      Part(
        id: "clipboard",
        rows: [
          Row(
            id: "cut", icon: .cut, title: String(localized: "Cut"), hint: "⌘X",
            preview: context.hasSelection ? String(localized: "Takes \(what) out and keeps it for Paste.") : nothing,
            isEnabled: context.hasSelection && context.isEditable, action: .cut),
          Row(
            id: "copy", icon: .copy, title: String(localized: "Copy"), hint: "⌘C",
            preview: context.hasSelection ? String(localized: "Copies \(what).") : nothing, isEnabled: context.hasSelection, action: .copy),
          Row(
            id: "paste", icon: .paste, title: String(localized: "Paste"), hint: "⌘V", preview: paste,
            isEnabled: context.clipboard != nil && context.isEditable, action: .paste),
        ] + clipboardRows))

    if context.hasSelection, !context.spansLines, !context.selection.contains("\n") {
      let text = context.selection
      parts.append(
        Part(
          id: "find",
          rows: [
            Row(
              id: "find", icon: .find, title: String(localized: "Find “\(clipped(text, 28))” in Project"), hint: "⇧⌘F",
              preview: String(localized: "Lists every place \(context.project) has “\(clipped(text, 40))”."), action: .find(text))
          ]))
    }

    var lines: [Row] = []
    if context.isEditable, let marker = context.commentMarker {
      if context.spansLines {
        let count = context.lastLine - context.firstLine + 1
        lines.append(
          Row(
            id: "comment", icon: .comment, title: String(localized: "Comment \(count) Lines"), hint: "⌘/",
            preview: String(localized: "Puts \(marker) before lines \(context.firstLine) to \(context.lastLine). Again takes it away."),
            action: .comment))
      } else {
        lines.append(
          Row(
            id: "comment", icon: .comment, title: String(localized: "Comment Line"), hint: "⌘/",
            preview: String(localized: "Puts \(marker) before line \(line). Again takes it away."), action: .comment))
      }
    }
    if context.isEditable, context.spansLines {
      lines.append(
        Row(
          id: "indent", icon: .indent, title: String(localized: "Indent"), hint: "⌘]",
          preview: String(localized: "Moves lines \(context.firstLine) to \(context.lastLine) one level in."), action: .indent))
      lines.append(
        Row(
          id: "outdent", icon: .outdent, title: String(localized: "Outdent"), hint: "⌘[",
          preview: String(localized: "Moves lines \(context.firstLine) to \(context.lastLine) one level out."), action: .outdent))
    }
    if context.breakpointsEnabled {
      lines.append(
        context.hasBreakpoint
          ? Row(
            id: "breakpoint", icon: .breakpoint, title: String(localized: "Remove Breakpoint from Line \(line)"), hint: "⌘\\",
            preview: String(localized: "A run no longer stops at line \(line)."), action: .breakpoint)
          : Row(
            id: "breakpoint", icon: .breakpoint, title: String(localized: "Add Breakpoint at Line \(line)"), hint: "⌘\\",
            preview: String(localized: "A run stops before line \(line), so you can look around."), action: .breakpoint))
    }
    if !lines.isEmpty { parts.append(Part(id: "lines", rows: lines)) }
    return EditorMenuContent(parts: parts)
  }

  /// `atlas.example/docs/trips`: a link without its scheme.
  static func shown(_ link: URL) -> String {
    let text = link.absoluteString
    guard let scheme = link.scheme, text.hasPrefix(scheme + "://") else { return text }
    return clipped(String(text.dropFirst(scheme.count + 3)), 48)
  }

  /// One line, cut to `limit` characters.
  static func clipped(_ text: String, _ limit: Int) -> String {
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.count > limit ? trimmed.prefix(limit - 1) + "…" : trimmed
  }

  /// The link at `location` of `text` (UTF-16), if any: `http`, `https` and `file` links, without the punctuation
  /// that ends a sentence around them.
  public static func link(in text: NSString, at location: Int) -> (url: URL, range: NSRange)? {
    guard location >= 0, location <= text.length else { return nil }
    let line = text.lineRange(for: NSRange(location: min(location, max(text.length - 1, 0)), length: 0))
    guard line.length < 4000, let expression = linkExpression else { return nil }
    for match in expression.matches(in: text as String, range: line) {
      var range = match.range
      // `(see https://x.dev/a).`: the bracket and the full stop aren't the link's.
      while range.length > 0, let last = Unicode.Scalar(text.character(at: NSMaxRange(range) - 1)), ".,;:!?)]}>'\"".unicodeScalars.contains(last) {
        if last == ")", text.substring(with: range).contains("(") { break }
        range.length -= 1
      }
      guard NSLocationInRange(location, range) || location == NSMaxRange(range), let url = URL(string: text.substring(with: range)), url.host != nil || url.isFileURL
      else { continue }
      return (url, range)
    }
    return nil
  }

  private static let linkExpression = try? NSRegularExpression(pattern: #"\b(?:https?|file)://[^\s<>"'`\\]+"#)
}

/// A place in a file as tools and people pass it around: the path from the project's folder, a colon and the line
/// (`Sources/Atlas/TripStore.swift:20`), several lines as `:18-21`. Compilers, grep and terminals read and write this
/// form, and editors open it. A file outside the project is written from the home folder (`~/…`).
public enum EditorReference {
  public static func text(file: URL, root: URL, firstLine: Int, lastLine: Int) -> String {
    let path = file.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    var shown = path
    if path.hasPrefix(rootPath + "/") {
      shown = String(path.dropFirst(rootPath.count + 1))
    } else {
      let home = NSHomeDirectory()
      if path.hasPrefix(home + "/") { shown = "~" + path.dropFirst(home.count) }
    }
    return lastLine > firstLine ? "\(shown):\(firstLine)-\(lastLine)" : "\(shown):\(firstLine)"
  }
}
