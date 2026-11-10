import CodeKit
import ComponentKit
import SwiftUI

/// Open Quickly (⇧⌘O, as in Xcode): fuzzy search over every file and every declaration in the project, as the kit's
/// palette (over the editor with `kitPaletteOverlay`): each file's icon, its name over its folder with the matched
/// characters in bold; each symbol's kind, its name over its containers and file. A qualified query (`Some.value`)
/// finds members of matching containers and jumps straight to the declaration. ↑/↓ move, Return opens, Escape or a
/// click elsewhere closes.
struct QuickOpenView: View {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model

  private typealias Result = (path: String, match: FuzzyMatch.Result, isHidden: Bool)

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

  var body: some View {
    @Bindable var model = model
    let results = matches.results
    KitPalette(
      query: $model.quickOpenQuery, prompt: "Open Quickly", status: status(results), maxHeight: 360,
      dismiss: { model.isQuickOpenPresented = false }
    ) {
      if symbolsFirst(results) {
        symbolGroup
        fileGroup(results)
      } else {
        fileGroup(results)
        symbolGroup
      }
    }
    .onAppear {
      // Hidden files are indexed on first use, for the button and the hint.
      workspace.index.includesHiddenFiles = true
    }
    .task(
      id: SearchKey(
        query: model.quickOpenQuery, includesHidden: model.quickOpenIncludesHiddenFiles,
        revision: workspace.index.revision)
    ) {
      isSearching = true
      let found = await workspace.index.matches(
        model.quickOpenQuery, includingHidden: model.quickOpenIncludesHiddenFiles, limit: 60)
      guard !Task.isCancelled else { return }
      matches = found
      isSearching = false
    }
    .task(id: SearchKey(query: model.quickOpenQuery, includesHidden: false, revision: workspace.index.revision)) {
      isSearchingSymbols = true
      let found = await model.services.symbols(matching: model.quickOpenQuery, limit: 40)
      guard !Task.isCancelled else { return }
      symbols = found
      isSearchingSymbols = false
    }
  }

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
        item(result)
      }
    }
  }

  /// Declarations, shown once the query finds some.
  @ViewBuilder private var symbolGroup: some View {
    if !symbols.isEmpty, !model.quickOpenQuery.isEmpty {
      PaletteGroup(
        "Symbols", meta: [symbols.count == 1 ? String(localized: "1 match") : String(localized: "\(symbols.count) matches")],
        systemImage: "curlybraces", hue: .purple
      ) {
        ForEach(symbols) { symbol in
          item(symbol)
        }
      }
    }
  }

  /// Symbols lead for a qualified query (`Some.value`) or a declaration's exact name, unless a file is named by
  /// the query (`Foo.swift`, or `Foo` with `Foo.swift` in the project).
  private func symbolsFirst(_ results: [Result]) -> Bool {
    guard let symbol = symbols.first else { return false }
    let query = model.quickOpenQuery.filter { !$0.isWhitespace }.lowercased().replacingOccurrences(of: "::", with: ".")
    if let path = results.first?.path {
      let name = (path as NSString).lastPathComponent.filter { !$0.isWhitespace }.lowercased()
      if name == query || (name as NSString).deletingPathExtension == query { return false }
    }
    return query.contains(".") || symbol.name.lowercased() == query
  }

  private func item(_ symbol: ProjectSymbol) -> some View {
    let place = "\(symbol.url.lastPathComponent):\(symbol.line + 1)"
    let containers = symbol.containers.joined(separator: ".")
    // The containers' part of the query ("Some" in "Some.value") bolded in the subtitle.
    let query = model.quickOpenQuery.filter { !$0.isWhitespace }.replacingOccurrences(of: "::", with: ".")
    let containerQuery = query.contains(".") ? String(query[..<query.lastIndex(of: ".")!]) : ""
    let containerMatches = containerQuery.isEmpty ? [] : FuzzyMatch.match(containerQuery, in: containers)?.positions ?? []
    let look = Self.look(symbol.kind)
    return PaletteItem(
      symbol.name, id: "symbol:\(symbol.id)", systemImage: look.image, hue: look.hue,
      subtitle: containers.isEmpty ? place : "\(containers) · \(place)",
      matches: FuzzyMatch.match(symbol.nameQuery, in: symbol.name)?.positions ?? [],
      subtitleMatches: containerMatches,
      note: symbol.kind == .extension ? String(localized: "Extension") : nil
    ) {
      model.isQuickOpenPresented = false
      workspace.tree.reveal(symbol.url)
      model.services.open(symbol)
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

  private func item(_ result: Result) -> some View {
    let path = result.path
    let name = (path as NSString).lastPathComponent
    let folder = (path as NSString).deletingLastPathComponent
    // The matcher's UTF-16 offsets are into the whole path: split them between the name and its folder.
    let nameStart = path.utf16.count - name.utf16.count
    let positions = result.match.positions
    return PaletteItem(
      name, id: path, subtitle: folder.isEmpty ? nil : folder,
      matches: positions.filter { $0 >= nameStart }.map { $0 - nameStart },
      subtitleMatches: positions.filter { $0 < folder.utf16.count },
      note: result.isHidden ? String(localized: "Hidden") : nil
    ) {
      FileIconView(FileIcon(fileName: name), size: 16)
    } action: {
      open(path)
    }
  }

  private func status(_ results: [Result]) -> WorkStatus {
    if workspace.index.isIndexing || isSearching || isSearchingSymbols { return .working }
    if model.quickOpenQuery.isEmpty { return .idle }
    return results.isEmpty && symbols.isEmpty ? .failed : .done
  }

  /// "3 matches · 433 hidden files also match".
  private func meta(_ results: [Result], hiddenMatches: Int) -> [String] {
    var parts: [String] = []
    if workspace.index.isIndexing {
      parts.append(String(localized: "Indexing…"))
    } else if results.isEmpty {
      if !isSearching { parts.append(String(localized: "No matching files")) }
    } else if !model.quickOpenQuery.isEmpty {
      parts.append(results.count == 1 ? String(localized: "1 match") : String(localized: "\(results.count) matches"))
    }
    if hiddenMatches > 0 {
      parts.append(
        hiddenMatches == 1
          ? String(localized: "1 hidden file also matches")
          : String(localized: "\(hiddenMatches) hidden files also match"))
    }
    return parts
  }

  private func open(_ path: String) {
    let url = workspace.root.appendingPathComponent(path)
    model.isQuickOpenPresented = false
    workspace.tree.reveal(url)
    workspace.open(url)
  }
}
