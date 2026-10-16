import CodeKit
import ComponentKit
import SwiftUI

/// Open Quickly (⇧⌘O, as in Xcode): fuzzy search over every file in the project, as the kit's palette. ↑/↓ move,
/// Return opens, Escape or a click elsewhere closes.
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
    PaletteOverlay {
      KitPalette(
        query: $model.quickOpenQuery, prompt: "Open Quickly", status: status(results), maxHeight: 360,
        dismiss: { model.isQuickOpenPresented = false }
      ) {
        PaletteGroup(
          "Files in \(workspace.name)", meta: meta(results, hiddenMatches: hiddenMatches),
          systemImage: "doc.text.magnifyingglass", hue: .teal
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
    let icon = FileIcon(fileName: name)
    return PaletteItem(
      name, id: path, systemImage: icon.kitSymbol, hue: icon.kitHue ?? .gray, detail: folder,
      note: result.isHidden ? "Hidden" : nil
    ) {
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

/// A palette floating at the top of the editor, closed by a click outside it.
struct PaletteOverlay<Content: View>: View {
  @Environment(WindowModel.self) private var model
  @ViewBuilder var content: Content

  var body: some View {
    ZStack(alignment: .top) {
      Color.black.opacity(0.001)
        .onTapGesture {
          model.isQuickOpenPresented = false
          model.isGoToLinePresented = false
        }
      content
        .frame(width: 560)
        .padding(.top, 8)
    }
  }
}
