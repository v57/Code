import CodeKit
import ComponentKit
import SwiftUI

/// Find in Project (⇧⌘F, Xcode's Find navigator): the query, its options,
/// and the matches found so far, by file.
@MainActor @Observable final class ProjectFind {
  var text = ""
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
    var texts: [String: String] = [:]
    for document in workspace.tabs where document.content == .text {
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
  }
}

/// A row of the results: a file, or one of its matches.
nonisolated struct FindSelection: Hashable, Sendable {
  var path: String
  /// The match's index in the file's matches; nil for the file's row.
  var match: Int?
}

/// The Find navigator, in the sidebar while its search line has text: Xcode's options (Containing, Matching Word,
/// Regular Expression; Ignoring or Matching Case) as two pop-ups, then the results by file in a card whose header
/// counts them. Selecting a match opens it in the editor with the match selected; ↑ and ↓ step through them.
struct FindNavigatorView: View {
  @Binding var selection: FindSelection?
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace

  var body: some View {
    @Bindable var find = model.find
    HStack(spacing: 6) {
      FindOptionMenu(
        title: find.mode.title, selection: $find.mode,
        options: [SearchQuery.Mode.containing, .matchingWord, .regularExpression].map { ($0.title, $0) })
      FindOptionMenu(
        title: find.isCaseSensitive ? "Matching Case" : "Ignoring Case", selection: $find.isCaseSensitive,
        options: [("Ignoring Case", false), ("Matching Case", true)])
    }
    KitSection("Results", meta: summary(find), systemImage: "magnifyingglass", status: status(find)) {
      ForEach(find.results) { file in
        FileResultRow(file: file, isExpanded: isExpanded(file.path))
        if !find.collapsed.contains(file.path) {
          ForEach(Array(file.matches.enumerated()), id: \.offset) { index, match in
            MatchRow(match: match, selection: FindSelection(path: file.path, match: index))
          }
        }
      }
    }
    .onChange(of: find.mode) { _, _ in searchAgain() }
    .onChange(of: find.isCaseSensitive) { _, _ in searchAgain() }
    .onChange(of: selection) { _, selection in
      if let selection { open(selection) }
    }
  }

  /// "13 matches · 3 files", or why there are none.
  private func summary(_ find: ProjectFind) -> [String] {
    if find.text.isEmpty { return ["Type in the search line below"] }
    if find.isInvalidPattern { return ["Not a valid regular expression"] }
    if find.results.isEmpty { return [find.isSearching ? "Searching…" : "No results"] }
    let matches = find.matchCount
    let files = find.results.count
    return [
      "\(matches) match\(matches == 1 ? "" : "es")" + (find.isTruncated ? " (stopped)" : ""),
      "\(files) file\(files == 1 ? "" : "s")",
    ]
  }

  private func status(_ find: ProjectFind) -> WorkStatus {
    if find.isSearching { return .working }
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
    case .containing: "Containing"
    case .matchingWord: "Matching Word"
    case .regularExpression: "Regular Expression"
    }
  }
}

/// One of Find's options as a raised pop-up that fills its half of the line.
private struct FindOptionMenu<Value: Hashable>: View {
  let title: String
  @Binding var selection: Value
  let options: [(String, Value)]

  var body: some View {
    Menu {
      Picker(title, selection: $selection) {
        ForEach(options, id: \.1) { Text($0.0).tag($0.1) }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      HStack(spacing: 4) {
        Text(title).lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.kitSecondary)
      }
      .kitFont(.callout)
      .foregroundStyle(.kitLabel)
      .padding(.leading, 9)
      .padding(.trailing, 6)
      .frame(height: 26)
      .kitSurface(.raised, cornerRadius: KitMetrics.radiusSmall)
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .frame(maxWidth: .infinity)
    .accessibilityValue(title)
  }
}

/// A file with matches: its icon and name, its folder, the number of matches.
private struct FileResultRow: View {
  let file: FileSearchResult
  @Binding var isExpanded: Bool
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  var body: some View {
    let url = URL(fileURLWithPath: file.path)
    SidebarRow(
      value: NavigatorItem.match(FindSelection(path: file.path, match: nil)),
      FileName.display(url, showExtensions: showExtensions)
    ) {
      HStack(spacing: 2) {
        Disclosure(isDirectory: true, isExpanded: $isExpanded)
        FileIconView(for: url, size: 14)
      }
    } trailing: {
      HStack(spacing: 6) {
        Text(file.folder).lineLimit(1).truncationMode(.head)
        Count(file.matches.count)
      }
    }
    .help(file.path)
  }
}

/// A match: its line in mono, the match in bold on the highlight.
private struct MatchRow: View {
  let match: SearchMatch
  let selection: FindSelection
  @Environment(\.self) private var environment

  var body: some View {
    SidebarRow(value: NavigatorItem.match(selection), "") {
      Text(attributed)
        .font(.system(size: 11.5, design: .monospaced))
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .layoutPriority(1)
    }
    .kitRowIndent(1)
    .help("Line \(match.line)")
  }

  private var attributed: AttributedString {
    var text = AttributedString(match.preview)
    if let range = Range(match.range, in: text) {
      text[range].font = .system(size: 11.5, weight: .bold, design: .monospaced)
      text[range].backgroundColor = Hue.yellow.soft(0.4).resolve(in: environment)
    }
    return text
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
