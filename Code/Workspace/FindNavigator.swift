import CodeKit
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
  /// Bumped to put the caret in the search field.
  private(set) var focusRequest = 0

  @ObservationIgnored private var task: Task<Void, Never>?

  var query: SearchQuery { SearchQuery(text, mode: mode, isCaseSensitive: isCaseSensitive) }
  var matchCount: Int { results.reduce(0) { $0 + $1.matches.count } }
  var isInvalidPattern: Bool { !text.isEmpty && query.expression == nil }

  func focus() { focusRequest += 1 }

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
struct FindSelection: Hashable {
  var path: String
  /// The match's index in the file's matches; nil for the file's row.
  var match: Int?
}

/// The Find navigator: a search field with Xcode's options (Containing,
/// Matching Word, Regular Expression; Ignoring or Matching Case) and the
/// results by file. Selecting a match opens it in the editor with the match
/// selected; ↑ and ↓ step through them.
struct FindNavigatorView: View {
  @Environment(WindowModel.self) private var model
  @Environment(Workspace.self) private var workspace
  @FocusState private var isFieldFocused: Bool
  @State private var selection: FindSelection?

  var body: some View {
    @Bindable var find = model.find
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 4) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("Find in Project", text: $find.text)
            .textFieldStyle(.plain)
            .focused($isFieldFocused)
            .onSubmit { find.search(in: workspace) }
          if !find.text.isEmpty {
            Button {
              find.clear()
              isFieldFocused = true
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear")
          }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(find.isInvalidPattern ? Color.red.opacity(0.7) : .clear))
        HStack(spacing: 6) {
          Picker("Match", selection: $find.mode) {
            Text("Containing").tag(SearchQuery.Mode.containing)
            Text("Matching Word").tag(SearchQuery.Mode.matchingWord)
            Text("Regular Expression").tag(SearchQuery.Mode.regularExpression)
          }
          .labelsHidden()
          .fixedSize()
          Spacer(minLength: 0)
          Picker("Case", selection: $find.isCaseSensitive) {
            Text("Ignoring Case").tag(false)
            Text("Matching Case").tag(true)
          }
          .labelsHidden()
          .fixedSize()
        }
        .controlSize(.small)
        .menuStyle(.borderlessButton)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      Divider()
      results
    }
    .onChange(of: find.mode) { _, _ in searchAgain() }
    .onChange(of: find.isCaseSensitive) { _, _ in searchAgain() }
    .onChange(of: find.focusRequest, initial: true) { _, _ in
      DispatchQueue.main.async { isFieldFocused = true }
    }
    .onChange(of: selection) { _, selection in
      if let selection { open(selection) }
    }
  }

  /// Options changed: search again for what is shown.
  private func searchAgain() {
    if model.find.searchedQuery != nil { model.find.search(in: workspace) }
  }

  @ViewBuilder private var results: some View {
    let find = model.find
    if find.results.isEmpty {
      VStack {
        Spacer()
        Group {
          if find.isInvalidPattern {
            Text("Not a valid regular expression")
          } else if find.isSearching {
            ProgressView().controlSize(.small)
          } else if find.searchedQuery != nil {
            Text("No Results")
          }
        }
        .foregroundStyle(.secondary)
        Spacer()
      }
      .frame(maxWidth: .infinity)
    } else {
      List(selection: $selection) {
        ForEach(find.results) { file in
          DisclosureGroup(isExpanded: isExpanded(file.path)) {
            ForEach(Array(file.matches.enumerated()), id: \.offset) { index, match in
              MatchRow(match: match)
                .tag(FindSelection(path: file.path, match: index))
            }
          } label: {
            FileRow(file: file)
              .tag(FindSelection(path: file.path, match: nil))
          }
        }
      }
      .listStyle(.sidebar)
      .environment(\.sidebarRowSize, .small)
    }
  }

  private func isExpanded(_ path: String) -> Binding<Bool> {
    Binding(
      get: { !model.find.collapsed.contains(path) },
      set: { expanded in
        if expanded { model.find.collapsed.remove(path) } else { model.find.collapsed.insert(path) }
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

/// The footer of the Find navigator: how many matches in how many files.
struct FindSummary: View {
  @Environment(WindowModel.self) private var model

  var body: some View {
    let find = model.find
    HStack(spacing: 6) {
      if find.isSearching && !find.results.isEmpty { ProgressView().controlSize(.mini) }
      Text(summary(find))
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
  }

  private func summary(_ find: ProjectFind) -> String {
    guard find.searchedQuery != nil, !find.results.isEmpty else { return "" }
    let matches = find.matchCount
    let files = find.results.count
    let text = "\(matches) result\(matches == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")"
    return find.isTruncated ? text + " (stopped)" : text
  }
}

private struct FileRow: View {
  let file: FileSearchResult
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  var body: some View {
    let url = URL(fileURLWithPath: file.path)
    HStack(spacing: 6) {
      FileIconView(for: url)
      Text(FileName.display(url, showExtensions: showExtensions))
        .fontWeight(.medium)
        .lineLimit(1)
      Text(file.folder)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.head)
      Spacer(minLength: 0)
      Text("\(file.matches.count)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .help(file.path)
  }
}

private struct MatchRow: View {
  let match: SearchMatch

  var body: some View {
    Text(attributed)
      .font(.system(size: 11.5, design: .monospaced))
      .lineLimit(2)
      .help("Line \(match.line)")
  }

  /// The line with the match in bold on a highlight, as in Xcode.
  private var attributed: AttributedString {
    var text = AttributedString(match.preview)
    if let range = Range(match.range, in: text) {
      text[range].font = .system(size: 11.5, weight: .bold, design: .monospaced)
      text[range].backgroundColor = Color.yellow.opacity(0.35)
    }
    return text
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
