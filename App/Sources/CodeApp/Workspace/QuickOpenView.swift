import CodeKit
import ComponentKit
import SwiftUI
import VaultKit
import VaultUI

/// Open Quickly (⌘O): fuzzy search over every file and every declaration in the project and over the projects'
/// names, as the kit's palette (over the editor with `kitPaletteOverlay`): each file's icon, its name over its folder
/// with the matched characters in bold; each symbol's kind, its name over its containers and file; each project's
/// icon and folder. A qualified query (`Some.value`) finds members of matching containers and jumps straight to the
/// declaration. Before anything is typed it lists the files opened lately, the projects opened lately and the last
/// search's results instead of every file. ↑/↓ move, Return opens, ⌘Return opens the second group's first item,
/// Escape or a click elsewhere closes.
struct QuickOpenView: View {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  @Environment(\.vault) private var vault
  /// The projects and groups removed from Code's lists (vault ids).
  @KitStorage(RemovedProjects.key) private var removed = KitIDSet()

  fileprivate typealias Result = (path: String, match: FuzzyMatch.Result, isHidden: Bool)

  /// The last search's matches: the index searches off the main thread, and the list keeps the previous matches
  /// until the next ones are in.
  @State private var matches = FileIndex.Matches()
  @State private var isSearching = false
  /// The last search's declarations (Code's scanner over the project), searched alongside the files.
  @State private var symbols: [ProjectSymbol] = []
  @State private var isSearchingSymbols = false

  /// What a search depends on: a new query, the hidden files switch or a rebuilt index searches again.
  private struct SearchKey: Equatable {
    var query: String
    var includesHidden: Bool
    var revision: Int
  }

  /// The palette's groups, in the order they show.
  private enum Section: Hashable {
    case recentFiles, recentProjects, lastSearch, files, symbols, projects
  }

  /// A project the palette lists: the vault's projects on this Mac and the folders opened lately.
  private struct Project: Identifiable {
    var name: String
    var folder: URL
    var icon: Data?
    var match: FuzzyMatch.Result?
    var id: String { folder.path }
  }

  private var query: String { model.quickOpenQuery }

  var body: some View {
    @Bindable var model = model
    let results = matches.results
    let projects = matchingProjects
    let sections = sections(results, projects: projects)
    let second = sections.lazy.compactMap { firstItem(of: $0, results: results, projects: projects) }.dropFirst().first
    KitPalette(
      query: $model.quickOpenQuery, prompt: "Open Quickly", status: status(results, projects: projects),
      hints: hints(second: second?.title), maxHeight: query.isEmpty ? 520 : 360,
      dismiss: { model.isQuickOpenPresented = false }
    ) {
      ForEach(sections, id: \.self) { section in
        group(section, results: results, projects: projects)
      }
    }
    .background {
      Button("Open Second") { second?.open() }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(second == nil)
        .hidden()
        .accessibilityHidden(true)
    }
    .onAppear {
      // Hidden files are indexed on first use, for the button and the hint.
      workspace.index.includesHiddenFiles = true
    }
    .onDisappear { remember(results) }
    .task(
      id: SearchKey(query: query, includesHidden: model.quickOpenIncludesHiddenFiles, revision: workspace.index.revision)
    ) {
      guard !query.isEmpty else {
        matches = FileIndex.Matches()
        return
      }
      isSearching = true
      let found = await workspace.index.matches(
        query, includingHidden: model.quickOpenIncludesHiddenFiles, limit: 60)
      guard !Task.isCancelled else { return }
      matches = found
      isSearching = false
    }
    .task(id: SearchKey(query: query, includesHidden: false, revision: workspace.index.revision)) {
      guard !query.isEmpty else {
        symbols = []
        return
      }
      isSearchingSymbols = true
      let found = await model.services.symbols(matching: query, limit: 40)
      guard !Task.isCancelled else { return }
      symbols = found
      isSearchingSymbols = false
    }
  }

  // MARK: - Sections

  /// Without a query: the files and projects opened lately and the last search. With one: files and symbols (the
  /// symbols first for a qualified query or an exact name), and the projects whose names match second.
  private func sections(_ results: [Result], projects: [Project]) -> [Section] {
    guard !query.isEmpty else {
      var sections: [Section] = []
      if !recentFiles.isEmpty { sections.append(.recentFiles) }
      if !projects.isEmpty { sections.append(.recentProjects) }
      if lastSearch != nil { sections.append(.lastSearch) }
      return sections
    }
    var sections: [Section] = symbolsFirst(results) ? [.symbols, .files] : [.files, .symbols]
    if !projects.isEmpty { sections.insert(.projects, at: 1) }
    return sections
  }

  @ViewBuilder private func group(_ section: Section, results: [Result], projects: [Project]) -> some View {
    switch section {
    case .recentFiles: recentFileGroup
    case .recentProjects: projectGroup(projects, title: String(localized: "Recent Projects"))
    case .lastSearch: lastSearchGroup
    case .files: fileGroup(results)
    case .symbols: symbolGroup
    case .projects: projectGroup(projects, title: String(localized: "Projects"))
    }
  }

  /// A section's first item (for ⌘Return): its title and how to open it.
  private func firstItem(
    of section: Section, results: [Result], projects: [Project]
  ) -> (title: String, open: () -> Void)? {
    switch section {
    case .recentFiles:
      return recentFiles.first.map { path in ((path as NSString).lastPathComponent, { open(path) }) }
    case .recentProjects, .projects:
      return projects.first.map { project in (project.name, { open(project) }) }
    case .lastSearch:
      guard let last = lastSearch else { return nil }
      if let path = last.files.first?.path { return ((path as NSString).lastPathComponent, { open(path) }) }
      return last.symbols.first.map { symbol in (symbol.name, { open(symbol) }) }
    case .files:
      return results.first.map { result in ((result.path as NSString).lastPathComponent, { open(result.path) }) }
    case .symbols:
      return symbols.first.map { symbol in (symbol.name, { open(symbol) }) }
    }
  }

  private func hints(second: String?) -> [PaletteHint] {
    guard let second else { return PaletteHint.standard }
    var hints = PaletteHint.standard
    hints.insert(PaletteHint(["⌘", "↩"], String(localized: "Open \(second)")), at: 2)
    return hints
  }

  // MARK: - Recent files, projects and the last search

  /// The files opened lately that are still there, but the one shown.
  private var recentFiles: [String] {
    let shown = workspace.selectedDocument.map { workspace.tree.relativePath(of: $0.url) }
    let fm = FileManager.default
    return workspace.recentFiles.filter {
      $0 != shown && fm.fileExists(atPath: workspace.root.appendingPathComponent($0).path)
    }
    .prefix(8).map { $0 }
  }

  private var recentFileGroup: some View {
    PaletteGroup("Recent Files", systemImage: "clock", hue: .teal) {
      ForEach(recentFiles, id: \.self) { path in
        fileItem(path, id: "recent:" + path, positions: [])
      }
    }
  }

  /// Without a query the projects opened lately; with one the vault's projects and the recents whose names match,
  /// best first. Never this window's project.
  private var matchingProjects: [Project] {
    let root = workspace.root.standardizedFileURL
    var vaultProjects: [URL: VaultProject] = [:]
    if let vault {
      for project in vault.codeProjectTree(removed: removed.ids).projects() {
        if let url = project.localURL?.standardizedFileURL { vaultProjects[url] = vaultProjects[url] ?? project }
      }
    }
    func project(_ folder: URL) -> Project {
      let record = vaultProjects[folder]
      return Project(name: record?.name ?? folder.lastPathComponent, folder: folder, icon: record?.icon)
    }
    let recents = AppState.shared.recents.existing.map(\.standardizedFileURL).filter { $0 != root }
    guard !query.isEmpty else { return recents.prefix(5).map(project) }
    var seen = Set<URL>()
    let folders = (recents + vaultProjects.keys.sorted { $0.path < $1.path }).filter { $0 != root && seen.insert($0).inserted }
    return folders.compactMap { folder in
      var entry = project(folder)
      guard let match = FuzzyMatch.match(query, in: entry.name) else { return nil }
      entry.match = match
      return entry
    }
    .sorted { ($0.match?.score ?? 0) > ($1.match?.score ?? 0) }
    .prefix(8).map { $0 }
  }

  private func projectGroup(_ projects: [Project], title: String) -> some View {
    PaletteGroup(title, systemImage: "square.stack.3d.up", hue: .orange) {
      Button {
        model.isQuickOpenPresented = false
        AppState.shared.chooseFolder()
      } label: {
        HStack(spacing: 5) {
          Text("Open Folder…")
          Keycaps("⇧⌘O")
        }
      }
      .buttonStyle(.kit)
      .controlSize(.small)
    } items: {
      ForEach(projects) { project in
        PaletteItem(
          project.name, id: "project:" + project.id, subtitle: project.folder.abbreviatedPath,
          matches: project.match?.positions ?? []
        ) {
          Avatar(name: project.name, imageData: project.icon, kind: .app, systemImage: "folder", size: 20)
        } action: {
          open(project)
        }
      }
    }
  }

  /// The last search in this project: its query and what it found, kept while the app runs.
  struct LastSearch {
    var query: String
    fileprivate var files: [Result]
    var symbols: [ProjectSymbol]
  }

  /// Each project's last search, by root path.
  private static var lastSearches: [String: LastSearch] = [:]

  private var lastSearch: LastSearch? { Self.lastSearches[workspace.root.path] }

  /// Keeps the search the palette closes on, when it found something.
  private func remember(_ results: [Result]) {
    guard !query.isEmpty, !results.isEmpty || !symbols.isEmpty else { return }
    Self.lastSearches[workspace.root.path] = LastSearch(
      query: query, files: Array(results.prefix(6)), symbols: Array(symbols.prefix(4)))
  }

  @ViewBuilder private var lastSearchGroup: some View {
    if let last = lastSearch {
      PaletteGroup("Last Search", meta: ["“\(last.query)”"], systemImage: "magnifyingglass", hue: .purple) {
        Button("Search Again") { model.quickOpenQuery = last.query }
          .buttonStyle(.kit)
          .controlSize(.small)
      } items: {
        ForEach(last.files, id: \.path) { result in
          fileItem(result, id: "last:" + result.path)
        }
        ForEach(last.symbols) { symbol in
          item(symbol, query: last.query, id: "last:symbol:\(symbol.id)")
        }
      }
    }
  }

  // MARK: - Files and symbols

  private func fileGroup(_ results: [Result]) -> some View {
    PaletteGroup(
      "Files in \(workspace.name)", meta: meta(results, hiddenMatches: matches.hiddenMatchCount),
      systemImage: "folder", hue: .teal
    ) {
      Button {
        model.quickOpenIncludesHiddenFiles.toggle()
      } label: {
        HStack(spacing: 5) {
          Text(model.quickOpenIncludesHiddenFiles ? "Leave out hidden" : "Include hidden")
          Keycaps("⇧⌘.")
        }
      }
      .buttonStyle(.kit)
      .controlSize(.small)
      .help(model.quickOpenIncludesHiddenFiles ? "Leave out hidden files (\(Keycaps.label("⇧⌘.")))" : "Include hidden files (\(Keycaps.label("⇧⌘.")))")
    } items: {
      ForEach(results, id: \.path) { result in
        fileItem(result, id: result.path)
      }
    }
  }

  /// Declarations, shown once the query finds some.
  @ViewBuilder private var symbolGroup: some View {
    if !symbols.isEmpty, !query.isEmpty {
      PaletteGroup(
        "Symbols", meta: [String(localized: "\(symbols.count) matches")],
        systemImage: "curlybraces", hue: .purple
      ) {
        ForEach(symbols) { symbol in
          item(symbol, query: query, id: "symbol:\(symbol.id)")
        }
      }
    }
  }

  /// Symbols lead for a qualified query (`Some.value`) or a declaration's exact name, unless a file is named by
  /// the query (`Foo.swift`, or `Foo` with `Foo.swift` in the project).
  private func symbolsFirst(_ results: [Result]) -> Bool {
    guard let symbol = symbols.first else { return false }
    let query = query.filter { !$0.isWhitespace }.lowercased().replacingOccurrences(of: "::", with: ".")
    if let path = results.first?.path {
      let name = (path as NSString).lastPathComponent.filter { !$0.isWhitespace }.lowercased()
      if name == query || (name as NSString).deletingPathExtension == query { return false }
    }
    return query.contains(".") || symbol.name.lowercased() == query
  }

  private func item(_ symbol: ProjectSymbol, query: String, id: String) -> some View {
    let place = "\(symbol.url.lastPathComponent):\(symbol.line + 1)"
    let containers = symbol.containers.joined(separator: ".")
    // The containers' part of the query ("Some" in "Some.value") bolded in the subtitle.
    let query = query.filter { !$0.isWhitespace }.replacingOccurrences(of: "::", with: ".")
    let containerQuery = query.contains(".") ? String(query[..<query.lastIndex(of: ".")!]) : ""
    let containerMatches = containerQuery.isEmpty ? [] : FuzzyMatch.match(containerQuery, in: containers)?.positions ?? []
    let look = Self.look(symbol.kind)
    return PaletteItem(
      symbol.name, id: id, systemImage: look.image, hue: look.hue,
      subtitle: containers.isEmpty ? place : "\(containers) · \(place)",
      matches: FuzzyMatch.match(symbol.nameQuery, in: symbol.name)?.positions ?? [],
      subtitleMatches: containerMatches,
      note: symbol.kind == .extension ? String(localized: "Extension") : nil
    ) {
      open(symbol)
    }
  }

  private static func look(_ kind: ProjectSymbol.Kind) -> (image: String, hue: Hue) {
    switch kind {
    case .type: ("t.square", .purple)
    case .protocol: ("p.square", .purple)
    case .extension: ("puzzlepiece.extension", .purple)
    case .function, .method: ("f.square", .blue)
    case .constructor: ("hammer", .blue)
    case .property, .variable: ("v.square", .teal)
    case .constant: ("c.square", .teal)
    case .enumCase: ("e.square", .orange)
    case .module: ("shippingbox", .brown)
    case .other: ("number.square", .gray)
    }
  }

  private func fileItem(_ result: Result, id: String) -> some View {
    fileItem(result.path, id: id, positions: result.match.positions, isHidden: result.isHidden)
  }

  /// A file by its path in the project; `positions` are the matcher's UTF-16 offsets into the whole path.
  private func fileItem(_ path: String, id: String, positions: [Int], isHidden: Bool = false) -> some View {
    let name = (path as NSString).lastPathComponent
    let folder = (path as NSString).deletingLastPathComponent
    // Split the offsets between the name and its folder.
    let nameStart = path.utf16.count - name.utf16.count
    return PaletteItem(
      name, id: id, subtitle: folder.isEmpty ? nil : folder,
      matches: positions.filter { $0 >= nameStart }.map { $0 - nameStart },
      subtitleMatches: positions.filter { $0 < folder.utf16.count },
      note: isHidden ? String(localized: "Hidden") : nil
    ) {
      FileIconView(FileIcon(fileName: name), size: 16)
    } action: {
      open(path)
    }
  }

  private func status(_ results: [Result], projects: [Project]) -> WorkStatus {
    if query.isEmpty { return .idle }
    if workspace.index.isIndexing || isSearching || isSearchingSymbols { return .working }
    return results.isEmpty && symbols.isEmpty && projects.isEmpty ? .failed : .done
  }

  /// "3 matches · 433 hidden files also match".
  private func meta(_ results: [Result], hiddenMatches: Int) -> [String] {
    var parts: [String] = []
    if workspace.index.isIndexing {
      parts.append(String(localized: "Indexing…"))
    } else if results.isEmpty {
      if !isSearching { parts.append(String(localized: "No matching files")) }
    } else {
      parts.append(String(localized: "\(results.count) matches"))
    }
    if hiddenMatches > 0 {
      parts.append(
        String(localized: "\(hiddenMatches) hidden files also match"))
    }
    return parts
  }

  // MARK: - Opening

  private func open(_ path: String) {
    let url = workspace.root.appendingPathComponent(path)
    model.isQuickOpenPresented = false
    workspace.tree.reveal(url)
    workspace.open(url)
  }

  private func open(_ symbol: ProjectSymbol) {
    model.isQuickOpenPresented = false
    workspace.tree.reveal(symbol.url)
    model.services.open(symbol)
  }

  /// Shows the project in this window, or brings forward the window it's open in.
  private func open(_ project: Project) {
    model.isQuickOpenPresented = false
    model.switchProject(project.folder)
  }
}
