import CodeKit
import SwiftUI

/// Open Quickly (⇧⌘O, as in Xcode): fuzzy search over every file in the project.
/// ↑/↓ move, Return opens, Escape or a click elsewhere closes.
struct QuickOpenView: View {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  @State private var query = ""
  @State private var selected = 0
  @FocusState private var isFocused: Bool

  private var results: [(path: String, match: FuzzyMatch.Result)] {
    workspace.index.search(query, limit: 60)
  }

  var body: some View {
    let results = results
    Palette {
      TextField("Search files by name", text: $query)
        .textFieldStyle(.plain)
        .font(.title3)
        .focused($isFocused)
        .padding(10)
        .onSubmit { open(results) }
        .onKeyPress(.downArrow) {
          selected = min(selected + 1, max(0, results.count - 1))
          return .handled
        }
        .onKeyPress(.upArrow) {
          selected = max(selected - 1, 0)
          return .handled
        }
        .onKeyPress(.escape) {
          model.isQuickOpenPresented = false
          return .handled
        }
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.element.path) { index, result in
              row(result.path, positions: result.match.positions, isSelected: index == selected)
                .id(index)
                .onTapGesture {
                  selected = index
                  open(results)
                }
            }
          }
          .padding(4)
        }
        .frame(maxHeight: 360)
        .onChange(of: selected) { _, index in proxy.scrollTo(index) }
      }
      if results.isEmpty {
        Text(workspace.index.isIndexing ? "Indexing…" : "No matching files")
          .foregroundStyle(.secondary)
          .padding(12)
      }
    }
    .onAppear { isFocused = true }
    .onChange(of: query) { _, _ in selected = 0 }
  }

  private func row(_ path: String, positions: [Int], isSelected: Bool) -> some View {
    let name = (path as NSString).lastPathComponent
    let folder = (path as NSString).deletingLastPathComponent
    let nameStart = (path as NSString).length - (name as NSString).length
    let url = workspace.root.appendingPathComponent(path)
    return HStack(spacing: 8) {
      Image(systemName: FileIcon.symbol(for: url, isDirectory: false))
        .foregroundStyle(FileIcon.tint(for: url, isDirectory: false))
        .frame(width: 16)
      Text(highlighted(name, positions: positions, offset: nameStart))
      Text(folder)
        .foregroundStyle(.secondary)
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.head)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(
      isSelected ? RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25)) : nil
    )
    .contentShape(Rectangle())
  }

  /// `text` with the matched characters (UTF-16 `positions` in the full path,
  /// `offset` where `text` starts) in bold.
  private func highlighted(_ text: String, positions: [Int], offset: Int) -> AttributedString {
    var result = AttributedString()
    let matched = Set(positions.map { $0 - offset })
    var utf16Offset = 0
    for character in text {
      var piece = AttributedString(String(character))
      if matched.contains(utf16Offset) {
        piece.font = .body.bold()
        piece.foregroundColor = .accentColor
      }
      result += piece
      utf16Offset += character.utf16.count
    }
    return result
  }

  private func open(_ results: [(path: String, match: FuzzyMatch.Result)]) {
    guard results.indices.contains(selected) else { return }
    let url = workspace.root.appendingPathComponent(results[selected].path)
    model.isQuickOpenPresented = false
    workspace.tree.reveal(url)
    workspace.open(url)
  }
}

/// A floating panel at the top of the editor, closed by a click outside it.
struct Palette<Content: View>: View {
  @Environment(WindowModel.self) private var model
  @ViewBuilder var content: Content

  var body: some View {
    ZStack(alignment: .top) {
      Color.black.opacity(0.001)
        .onTapGesture {
          model.isQuickOpenPresented = false
          model.isGoToLinePresented = false
        }
      VStack(alignment: .leading, spacing: 0) {
        content
      }
      .frame(width: 560)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
      .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }
  }
}
