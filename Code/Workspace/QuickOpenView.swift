import CodeKit
import ComponentKit
import SwiftUI

/// Open Quickly (⇧⌘O, as in Xcode): fuzzy search over every file in the project, as the kit's palette (over the
/// editor with `kitPaletteOverlay`): each file's icon, its name over its folder with the matched characters in bold.
/// ↑/↓ move, Return opens, Escape or a click elsewhere closes.
struct QuickOpenView: View {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model

  private typealias Result = (path: String, match: FuzzyMatch.Result, isHidden: Bool)

  private var results: [Result] {
    workspace.index.search(
      model.quickOpenQuery, includingHidden: model.quickOpenIncludesHiddenFiles, limit: 60)
  }

  var body: some View {
    @Bindable var model = model
    let results = results
    let hiddenMatches =
      model.quickOpenIncludesHiddenFiles ? 0 : workspace.index.hiddenMatchCount(model.quickOpenQuery)
    KitPalette(
      query: $model.quickOpenQuery, prompt: "Open Quickly", status: status(results), maxHeight: 360,
      dismiss: { model.isQuickOpenPresented = false }
    ) {
      PaletteGroup(
        "Files in \(workspace.name)", meta: meta(results, hiddenMatches: hiddenMatches),
        systemImage: "folder", hue: .teal
      ) {
        Button {
          model.quickOpenIncludesHiddenFiles.toggle()
        } label: {
          HStack(spacing: 5) {
            Text(model.quickOpenIncludesHiddenFiles ? "Leave out hidden" : "Include hidden")
            Keycap("⇧⌘.")
          }
        }
        .buttonStyle(.kit)
        .controlSize(.small)
        .help(model.quickOpenIncludesHiddenFiles ? "Leave out hidden files (⇧⌘.)" : "Include hidden files (⇧⌘.)")
      } items: {
        ForEach(results, id: \.path) { result in
          item(result)
        }
      }
    }
    .onAppear {
      // Hidden files are indexed on first use, for the button and the hint.
      workspace.index.includesHiddenFiles = true
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
      note: result.isHidden ? "Hidden" : nil
    ) {
      FileIconView(FileIcon(fileName: name), size: 16)
    } action: {
      open(path)
    }
  }

  private func status(_ results: [Result]) -> WorkStatus {
    if workspace.index.isIndexing { return .working }
    if model.quickOpenQuery.isEmpty { return .idle }
    return results.isEmpty ? .failed : .done
  }

  /// "3 matches · 433 hidden files also match".
  private func meta(_ results: [Result], hiddenMatches: Int) -> [String] {
    var parts: [String] = []
    if workspace.index.isIndexing {
      parts.append("Indexing…")
    } else if results.isEmpty {
      parts.append("No matching files")
    } else if !model.quickOpenQuery.isEmpty {
      parts.append(results.count == 1 ? "1 match" : "\(results.count) matches")
    }
    if hiddenMatches > 0 {
      parts.append(hiddenMatches == 1 ? "1 hidden file also matches" : "\(hiddenMatches) hidden files also match")
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
