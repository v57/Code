import CodeKit
import ComponentKit
import SwiftUI

/// Find in Project (⇧⌘F, Xcode's Find navigator): the query, its options,
/// and the matches found so far, by file. In Replace mode (⌥⇧⌘F) the matches
/// can be replaced: one, a file's, or all of them.
@MainActor @Observable final class ProjectFind {
  var text = ""
  /// Replace mode: the navigator shows the replacement field and its buttons, and each match what it becomes.
  var isReplacing = false
  /// What matches become; for a regular expression a template (`$1`).
  var replacement = ""
  /// Replace All is asking before it replaces.
  var isConfirmingReplaceAll = false
  /// A replace is writing files.
  private(set) var isReplacingFiles = false
  /// What the last replace did ("Replaced 4 matches in 2 files"), or why it failed; cleared by the next search
  /// with another query.
  private(set) var replaceSummary: String?
  var mode = SearchQuery.Mode(rawValue: UserDefaults.standard.string(forKey: "find.mode") ?? "") ?? .containing {
    didSet { UserDefaults.standard.set(mode.rawValue, forKey: "find.mode") }
  }
  var isCaseSensitive = UserDefaults.standard.bool(forKey: "find.caseSensitive") {
    didSet { UserDefaults.standard.set(isCaseSensitive, forKey: "find.caseSensitive") }
  }
  private(set) var results: [FileSearchResult] = []
  /// The query of the results shown; nil before the first search.
  private(set) var searchedQuery: SearchQuery?
  private(set) var isSearching = false
  /// The search stopped at `ProjectSearch.matchLimit`.
  private(set) var isTruncated = false
  /// Files whose matches are folded away.
  var collapsed: Set<String> = []

  @ObservationIgnored private var task: Task<Void, Never>?

  var query: SearchQuery { SearchQuery(text, mode: mode, isCaseSensitive: isCaseSensitive) }
  var matchCount: Int { results.reduce(0) { $0 + $1.matches.count } }
  var isInvalidPattern: Bool { !text.isEmpty && query.expression == nil }

  /// Searches the project's visible files (what Open Quickly lists), with
  /// the open documents' unsaved edits, replacing a search still running.
  func search(in workspace: Workspace) {
    task?.cancel()
    let query = query
    guard query.expression != nil else {
      results = []
      searchedQuery = query.text.isEmpty ? nil : query
      isSearching = false
      return
    }
    if query != searchedQuery { replaceSummary = nil }
    var texts: [String: String] = [:]
    for document in workspace.tabs + workspace.detachedDocuments where document.content == .text {
      texts[workspace.tree.relativePath(of: document.url)] = document.currentText
    }
    let root = workspace.root
    let paths = workspace.index.paths
    results = []
    collapsed = []
    isTruncated = false
    searchedQuery = query
    isSearching = true
    let (batches, continuation) = AsyncStream.makeStream(of: [FileSearchResult].self)
    let search = Task.detached(priority: .userInitiated) {
      let truncated = ProjectSearch.search(query, root: root, paths: paths, texts: texts) {
        continuation.yield($0)
      }
      continuation.finish()
      return truncated
    }
    task = Task {
      await withTaskCancellationHandler {
        for await batch in batches { results += batch }
      } onCancel: {
        search.cancel()
      }
      guard !Task.isCancelled else { return }
      isTruncated = await search.value
      isSearching = false
    }
  }

  func clear() {
    task?.cancel()
    text = ""
    results = []
    searchedQuery = nil
    isSearching = false
    isTruncated = false
    replaceSummary = nil
  }

  // MARK: - Replace

  /// Replaces every match in the files listed, then searches again.
  func replaceAll(in workspace: Workspace) {
    replace(results.map { ($0.path, nil) }, in: workspace)
  }

  /// Replaces the selected match, or every match in the selected file, then searches again: the selection then
  /// holds the file's next match.
  func replace(_ selection: FindSelection, in workspace: Workspace) {
    guard let file = results.first(where: { $0.path == selection.path }) else { return }
    if let index = selection.match {
      guard file.matches.indices.contains(index) else { return }
      replace([(file.path, file.matches[index])], in: workspace)
    } else {
      replace([(file.path, nil)], in: workspace)
    }
  }

  /// Open files are edited in their editor, as one undoable change each ("Replace"); the others are written on
  /// disk, in their own encoding, off the main thread.
  private func replace(_ targets: [(path: String, match: SearchMatch?)], in workspace: Workspace) {
    guard !isReplacingFiles, let query = searchedQuery, query.expression != nil, !targets.isEmpty else { return }
    let replacement = replacement
    var count = 0
    var files = 0
    var closed: [(url: URL, match: SearchMatch?)] = []
    for target in targets {
      let url = workspace.root.appendingPathComponent(target.path)
      guard let document = workspace.document(for: url), document.content == .text else {
        closed.append((url, target.match))
        continue
      }
      let text = document.currentText
      var new: String?
      var replaced = 0
      if let match = target.match {
        new = ProjectReplace.replacing(
          line: match.line, column: match.column, in: text, query: query, with: replacement)
        replaced = new == nil ? 0 : 1
      } else {
        (new, replaced) = ProjectReplace.replacingAll(in: text, query: query, with: replacement)
      }
      guard let new, replaced > 0 else { continue }
      if let textView = document.textView {
        textView.applyEditedText(new, actionName: String(localized: "Replace"))
      } else {
        document.replaceText(new)
      }
      count += replaced
      files += 1
    }
    isReplacingFiles = true
    let closedFiles = closed
    Task {
      let written = await Task.detached(priority: .userInitiated) {
        var count = 0
        var files = 0
        var failures: [String] = []
        for target in closedFiles {
          do {
            let replaced =
              if let match = target.match {
                try ProjectReplace.replace(
                  line: match.line, column: match.column, inFileAt: target.url, query: query, with: replacement)
                  ? 1 : 0
              } else {
                try ProjectReplace.replaceAll(inFileAt: target.url, query: query, with: replacement)
              }
            count += replaced
            if replaced > 0 { files += 1 }
          } catch {
            failures.append("\(target.url.lastPathComponent): \(error.localizedDescription)")
          }
        }
        return (count, files, failures)
      }.value
      count += written.0
      files += written.1
      isReplacingFiles = false
      if let failure = written.2.first {
        replaceSummary = String(localized: "Couldn’t replace in \(failure)")
      } else {
        // The count keys Find's header uses, so each takes its language's plural forms.
        let matchText = String(localized: "\(count) matches")
        let fileText = String(localized: "\(files) files")
        replaceSummary = String(localized: "Replaced \(matchText) in \(fileText)")
      }
      search(in: workspace)
    }
  }
}

/// A row of the results: a file, or one of its matches.
nonisolated struct FindSelection: Hashable, Sendable {
  var path: String
  /// The match's index in the file's matches; nil for the file's row.
  var match: Int?
}

/// The Find navigator, in the sidebar while its search line has text: Find or Replace, then Xcode's options
/// (Containing, Matching Word, Regular Expression; Ignoring or Matching Case) as pop-ups, then the results by file in a
/// card whose header counts them. Selecting a match opens it in the editor with the match selected; ↑ and ↓ step
/// through them. In Replace mode a field takes what the matches become, each match shows it, Replace replaces the
/// selected match (or file's matches) and Replace All every match listed, after asking.
struct FindNavigatorView: View {
  @Binding var selection: FindSelection?
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace

  var body: some View {
    @Bindable var find = model.find
    // In lines that wrap before a picker that wouldn't fit the sidebar.
    KitFlowLayout(spacing: 6) { findOptions(find) }
      .frame(maxWidth: .infinity, alignment: .leading)
    if find.isReplacing { replaceControls(find) }
    KitSection("Results", meta: summary(find), systemImage: "magnifyingglass", status: status(find)) {
      let replacement = find.isReplacing ? find.replacement : nil
      ForEach(find.results) { file in
        FileResultRow(file: file, isExpanded: isExpanded(file.path))
        if !find.collapsed.contains(file.path) {
          ForEach(Array(file.matches.enumerated()), id: \.offset) { index, match in
            MatchRow(
              match: match, selection: FindSelection(path: file.path, match: index),
              replacement: replacement.map { replacement in
                find.searchedQuery.map { ProjectReplace.preview(of: match, query: $0, replacement: replacement) }
                  ?? replacement
              })
          }
        }
      }
    }
    .onChange(of: find.mode) { _, _ in searchAgain() }
    .onChange(of: find.isCaseSensitive) { _, _ in searchAgain() }
    .onChange(of: selection) { _, selection in
      if let selection { open(selection) }
    }
    .kitDialog(
      replaceAllTitle(find), isPresented: $find.isConfirmingReplaceAll,
      message: String(localized: "Files that aren’t open are changed on disk, where Undo can’t reach them."),
      systemImage: "arrow.left.arrow.right", confirm: String(localized: "Replace All")
    ) {
      find.replaceAll(in: workspace)
    }
  }

  /// Find or Replace; Containing, Matching Word or Regular Expression; Ignoring or Matching Case.
  @ViewBuilder private func findOptions(_ find: ProjectFind) -> some View {
    @Bindable var find = find
    KitPicker("Action", selection: $find.isReplacing, options: [("Find", false), ("Replace", true)])
    KitPicker(
      String(localized: "Find"), selection: $find.mode,
      options: [SearchQuery.Mode.containing, .matchingWord, .regularExpression].map { ($0.title, $0) })
    KitPicker("Case", selection: $find.isCaseSensitive, options: [("Ignoring Case", false), ("Matching Case", true)])
  }

  /// What the matches become, then Replace (the selected match or file) and Replace All.
  @ViewBuilder private func replaceControls(_ find: ProjectFind) -> some View {
    @Bindable var find = find
    let canReplace = !find.results.isEmpty && !find.isSearching && !find.isReplacingFiles
    TextField(
      find.mode == .regularExpression ? String(localized: "Replace with ($1 for a group)") : String(localized: "Replace with"),
      text: $find.replacement
    )
    .kitField(mono: true, content: .verbatim)
    .onSubmit { if canReplace { find.isConfirmingReplaceAll = true } }
    HStack(spacing: 6) {
      Button("Replace") {
        if let selection { find.replace(selection, in: workspace) }
      }
      .disabled(!canReplace || selection == nil)
      .kitHelp("Replace", meta: String(localized: "The selected match, or every match in the selected file"))
      Button("Replace All") { find.isConfirmingReplaceAll = true }
        .disabled(!canReplace)
      Spacer(minLength: 0)
    }
    .buttonStyle(.kit)
  }

  private func replaceAllTitle(_ find: ProjectFind) -> String {
    let matchText = String(localized: "\(find.matchCount) matches")
    let fileText = String(localized: "\(find.results.count) files")
    return String(localized: "Replace \(matchText) in \(fileText)?")
  }

  /// "13 matches · 3 files", or why there are none; after a replace, what it did.
  private func summary(_ find: ProjectFind) -> [String] {
    if find.text.isEmpty { return [String(localized: "Type in the search line below")] }
    if find.isReplacingFiles { return [String(localized: "Replacing…")] }
    if let replaced = find.replaceSummary, find.results.isEmpty, !find.isSearching { return [replaced] }
    if find.isInvalidPattern { return [String(localized: "Not a valid regular expression")] }
    if find.results.isEmpty {
      return [find.isSearching ? String(localized: "Searching…") : String(localized: "No results")]
    }
    let matches = find.matchCount
    let files = find.results.count
    let matchText = String(localized: "\(matches) matches")
    return [
      find.isTruncated ? String(localized: "\(matchText) (stopped)") : matchText,
      String(localized: "\(files) files"),
    ] + (find.replaceSummary.map { [$0] } ?? [])
  }

  private func status(_ find: ProjectFind) -> WorkStatus {
    if find.isSearching || find.isReplacingFiles { return .working }
    if find.isInvalidPattern { return .failed }
    return .idle
  }

  /// Options changed: search again for what is shown.
  private func searchAgain() {
    if model.find.searchedQuery != nil { model.find.search(in: workspace) }
  }

  private func isExpanded(_ path: String) -> Binding<Bool> {
    Binding(
      get: { !model.find.collapsed.contains(path) },
      set: { expanded in
        withKitAnimation {
          if expanded { model.find.collapsed.remove(path) } else { model.find.collapsed.insert(path) }
        }
      })
  }

  private func open(_ selection: FindSelection) {
    let url = workspace.root.appendingPathComponent(selection.path)
    guard let index = selection.match,
      let match = model.find.results.first(where: { $0.path == selection.path })?.matches[safe: index]
    else {
      workspace.open(url, preview: true)
      return
    }
    model.services.open(url, line: match.line, column: match.column + 1, length: match.length)
  }
}

extension SearchQuery.Mode {
  var title: String {
    switch self {
    case .containing: String(localized: "Containing")
    case .matchingWord: String(localized: "Matching Word")
    case .regularExpression: String(localized: "Regular Expression")
    }
  }
}

/// A file with matches: its icon and name, its folder, the number of matches.
private struct FileResultRow: View {
  let file: FileSearchResult
  @Binding var isExpanded: Bool
  @Environment(\.showsFileExtensions) private var showExtensions

  var body: some View {
    let url = URL(fileURLWithPath: file.path)
    SidebarRow(
      value: NavigatorItem.match(FindSelection(path: file.path, match: nil)),
      FileName.display(url, showExtensions: showExtensions), isExpanded: $isExpanded
    ) {
      FileIconView(for: url, size: 14)
    } trailing: {
      HStack(spacing: 6) {
        Text(file.folder).lineLimit(1).truncationMode(.head)
        Count(file.matches.count)
      }
    }
    .kitHelp(file.path)
  }
}

/// A match: its line in mono as the row's title, the match in bold on the highlight. In Replace mode the match is
/// struck through and what it becomes follows it, in bold on green.
private struct MatchRow: View {
  let match: SearchMatch
  let selection: FindSelection
  /// What the match becomes; nil outside Replace mode.
  var replacement: String?
  /// Only the appearance: the whole environment (`\.self`) changes with anything, which built every match again.
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    SidebarRow(value: NavigatorItem.match(selection), match.preview) { EmptyView() }
      .title(Text(attributed).font(KitFont.mono.font))
      .kitRowIndent(1)
      .kitHelp("Line \(match.line)", meta: match.preview)
  }

  private var attributed: AttributedString {
    var text = AttributedString(match.preview)
    guard let range = Range(match.range, in: text) else { return text }
    var environment = EnvironmentValues()
    environment.colorScheme = colorScheme
    text[range].font = KitFont.mono.font.bold()
    text[range].backgroundColor = Hue.yellow.soft(0.4).resolve(in: environment)
    if let replacement {
      text[range].strikethroughStyle = .single
      var new = AttributedString(replacement)
      new.font = KitFont.mono.font.bold()
      new.backgroundColor = Hue.green.soft(0.4).resolve(in: environment)
      text.insert(new, at: range.upperBound)
    }
    return text
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
