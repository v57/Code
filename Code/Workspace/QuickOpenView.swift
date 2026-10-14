import CodeKit
import SwiftUI

/// Open Quickly (⇧⌘O, as in Xcode): fuzzy search over every file in the project.
/// ↑/↓ move, Return opens, Escape or a click elsewhere closes.
struct QuickOpenView: View {
  @Environment(Workspace.self) private var workspace
  @Environment(WindowModel.self) private var model
  @State private var selected = 0
  @FocusState private var isFocused: Bool

  private typealias Result = (path: String, match: FuzzyMatch.Result, isHidden: Bool)

  private var results: [Result] {
    workspace.index.search(
      model.quickOpenQuery, includingHidden: model.quickOpenIncludesHiddenFiles, limit: 60)
  }

  var body: some View {
    @Bindable var model = model
    let results = results
    Palette {
      HStack(spacing: 8) {
        TextField("Search files by name", text: $model.quickOpenQuery)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($isFocused)
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
        HiddenFilesButton(isOn: $model.quickOpenIncludesHiddenFiles)
      }
      .padding(10)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.element.path) { index, result in
              row(result, isSelected: index == selected)
                .onTapGesture {
                  selected = index
                  open(results)
                }
            }
          }
          .padding(4)
        }
        .frame(maxHeight: 360)
        .onChange(of: selected) { _, index in
          if results.indices.contains(index) { proxy.scrollTo(results[index].path) }
        }
      }
      if results.isEmpty {
        Text(workspace.index.isIndexing ? "Indexing…" : "No matching files")
          .foregroundStyle(.secondary)
          .padding(12)
      }
      let hiddenMatches =
        model.quickOpenIncludesHiddenFiles ? 0 : workspace.index.hiddenMatchCount(model.quickOpenQuery)
      if hiddenMatches > 0 {
        Divider()
        HStack {
          Text(hiddenMatches == 1 ? "1 hidden file also matches" : "\(hiddenMatches) hidden files also match")
            .foregroundStyle(.secondary)
          Spacer()
          Button("Include ⇧⌘.") { model.quickOpenIncludesHiddenFiles = true }
            .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
    }
    .onAppear {
      isFocused = true
      // Hidden files are indexed on first use, for the button and the hint.
      workspace.index.includesHiddenFiles = true
    }
    .onChange(of: model.quickOpenQuery) { _, _ in selected = 0 }
    .onChange(of: model.quickOpenIncludesHiddenFiles) { _, _ in selected = 0 }
  }

  private func row(_ result: Result, isSelected: Bool) -> some View {
    let path = result.path
    let name = (path as NSString).lastPathComponent
    let folder = (path as NSString).deletingLastPathComponent
    let nameStart = (path as NSString).length - (name as NSString).length
    let url = workspace.root.appendingPathComponent(path)
    return HStack(spacing: 8) {
      FileIconView(for: url)
        .opacity(result.isHidden ? 0.45 : 1)
      Text(highlighted(name, positions: result.match.positions, offset: nameStart))
      Text(folder)
        .foregroundStyle(.secondary)
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.head)
      Spacer(minLength: 0)
      if result.isHidden {
        Label("Hidden", systemImage: "eye.slash")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
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

  private func open(_ results: [Result]) {
    guard results.indices.contains(selected) else { return }
    let url = workspace.root.appendingPathComponent(results[selected].path)
    model.isQuickOpenPresented = false
    workspace.tree.reveal(url)
    workspace.open(url)
  }
}

/// Open Quickly's Hidden Files button: a capsule, tinted while on.
private struct HiddenFilesButton: View {
  @Binding var isOn: Bool

  var body: some View {
    Button {
      isOn.toggle()
    } label: {
      Label("Hidden Files", systemImage: "eye")
        .font(.callout.weight(.medium))
        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.15) : .clear))
        .overlay(Capsule().strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.35)))
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help(isOn ? "Leave out hidden files (⇧⌘.)" : "Include hidden files (⇧⌘.)")
    .accessibilityValue(isOn ? "On" : "Off")
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
