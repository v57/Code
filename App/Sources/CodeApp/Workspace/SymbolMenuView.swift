// The symbol menu is CodeKit's on macOS only (`SymbolMenu`).
#if os(macOS)
import CodeKit
import ComponentKit
import SwiftUI

/// The symbol menu (the canvas's `code-05` and `code-06` boards): where the symbol lives as a path whose parts jump,
/// its declaration in the editor's colors and its summary; then the rows (Jump to Definition, Jump to Type, the
/// parents it's Inside, Find References, Copy Qualified Name), and a panel saying what the highlighted row does. Drawn
/// as the kit's menus are (`KitMenu`'s metrics), in its own panel (`SymbolMenuPanel`), since the editor keeps the keys.
struct SymbolMenuView: View {
  let menu: SymbolMenu
  /// Its size changed (answers came in): the panel follows.
  var onSize: (CGSize) -> Void = { _ in }

  static let width: CGFloat = 400
  private let rowHeight: CGFloat = 28
  private let padding: CGFloat = 6

  var body: some View {
    let content = menu.content
    VStack(alignment: .leading, spacing: 1) {
      head(content)
      separator
      ForEach(content.rows) { row in
        if row.separated { separator }
        if let section = row.section {
          Text(section)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.kitSecondary)
            .padding(EdgeInsets(top: 4, leading: 8, bottom: 1, trailing: 8))
        }
        SymbolMenuRow(row: row, isHighlighted: row.id == menu.highlighted) { inside in
          // The highlight stays when the pointer leaves: its sentence below still says what ↩ does.
          if inside { menu.highlighted = row.id }
        } pick: {
          menu.pick(row, newTab: KitDesktop.modifierKeys.contains(.option))
        }
      }
      if let footer = content.footer {
        HStack(spacing: 6) {
          ProgressView().controlSize(.mini).frame(width: 12, height: 12)
          Text(footer)
        }
        .font(.system(size: 11))
        .foregroundStyle(.kitSecondary)
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 2, trailing: 8))
      } else {
        previewPanel(content).padding(.top, 5)
      }
    }
    .padding(padding)
    .frame(width: Self.width, alignment: .leading)
    .kitSurface(.floating, cornerRadius: 14)
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(content.path.last.map { "Symbol \($0.name)" } ?? "Symbol")
  }

  // MARK: Head

  private func head(_ content: SymbolMenuContent) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      crumbs(content.path)
      if let declaration = content.declaration, !declaration.isEmpty {
        Text(highlighted(declaration))
          .font(.system(size: 12, design: .monospaced))
          .lineSpacing(3)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(EdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9))
          .background(.kitFillSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      if let summary = content.summary {
        Text(Self.markdown(summary))
          .font(.system(size: 12))
          .lineSpacing(2)
          .foregroundStyle(.kitLabel)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
      }
    }
    .padding(EdgeInsets(top: 2, leading: 2, bottom: 6, trailing: 2))
  }

  private func crumbs(_ path: [SymbolInfo]) -> some View {
    HStack(spacing: 1) {
      ForEach(Array(path.enumerated()), id: \.offset) { index, part in
        if index > 0 {
          Image(systemName: "chevron.right")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.kitTertiary)
            .frame(width: 10)
        }
        SymbolCrumb(part: part, isLast: index == path.count - 1) { menu.open(part) }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Where it is declared")
  }

  // MARK: Preview

  /// The highlighted row's sentence; the tallest one's space is kept, so the rows never move.
  private func previewPanel(_ content: SymbolMenuContent) -> some View {
    let active = content.rows.first { $0.id == menu.highlighted }
    return ZStack(alignment: .topLeading) {
      ForEach(content.rows) { row in sentence(row.preview).hidden() }
      if let active { sentence(active.preview) }
    }
    .padding(EdgeInsets(top: 8, leading: 10, bottom: 9, trailing: 10))
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      active == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(.kitFillSoft),
      in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  private func sentence(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 12))
      .lineSpacing(2)
      .foregroundStyle(.kitLabel)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var separator: some View {
    Rectangle().fill(.kitSeparator).frame(height: 1).padding(.vertical, 4).padding(.horizontal, 6)
  }

  // MARK: Text

  /// The declaration in the editor's theme colors.
  private func highlighted(_ code: String) -> AttributedString {
    var text = AttributedString(code)
    let syntax = menu.theme.syntax
    text.foregroundColor = Self.color(syntax.plainText)
    let utf16 = code.utf16
    for token in CodeHighlighter.tokens(in: code, language: menu.language) {
      guard token.range.location >= 0, token.range.location + token.range.length <= utf16.count,
        let start = utf16.index(utf16.startIndex, offsetBy: token.range.location, limitedBy: utf16.endIndex),
        let end = utf16.index(start, offsetBy: token.range.length, limitedBy: utf16.endIndex),
        let lower = AttributedString.Index(start, within: text), let upper = AttributedString.Index(end, within: text)
      else { continue }
      text[lower..<upper].foregroundColor = Self.color(syntax.color(for: token.kind))
    }
    return text
  }

  static func color(_ hex: UInt32) -> Color {
    Color(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
  }

  /// Inline code in a doc summary in the code font.
  static func markdown(_ text: String) -> AttributedString {
    var result = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
    for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
      result[run.range].font = .system(size: 11, design: .monospaced)
    }
    return result
  }
}

/// One row: its icon (a kind's tile, or a symbol), title, a second line, GUESS while unconfirmed, and its trail.
private struct SymbolMenuRow: View {
  let row: SymbolMenuContent.Row
  let isHighlighted: Bool
  let hover: (Bool) -> Void
  let pick: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      icon.frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 6) {
          Text(row.title).lineLimit(1).truncationMode(.middle)
          if row.isGuess {
            Text("GUESS")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.kitSecondary)
              .padding(.horizontal, 5)
              .frame(height: 16)
              .background(.kitFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
          }
        }
        if let detail = row.detail {
          Text(detail)
            .font(.system(size: 11))
            .foregroundStyle(.kitSecondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if let trail = row.trail {
        Text(trail)
          .font(.system(size: 12))
          .monospacedDigit()
          .foregroundStyle(.kitSecondary)
          .lineLimit(1)
          .fixedSize()
      }
    }
    .font(.system(size: 13))
    .foregroundStyle(row.isEnabled ? AnyShapeStyle(.kitLabel) : AnyShapeStyle(.kitTertiary))
    .padding(.horizontal, 8)
    .padding(.vertical, row.detail == nil ? 0 : 4)
    .frame(minHeight: row.detail == nil ? 28 : 40)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(isHighlighted ? AnyShapeStyle(Hue.accent.soft(0.14)) : AnyShapeStyle(.clear))
    }
    .contentShape(Rectangle())
    .onHover(perform: hover)
    .onTapGesture { if row.isEnabled { pick() } }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { if row.isEnabled { pick() } }
  }

  @ViewBuilder private var icon: some View {
    switch row.icon {
    case .jump: Image(systemName: "arrow.right").font(.system(size: 12)).foregroundStyle(.kitSecondary)
    case .references: Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.kitSecondary)
    case .copy: Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundStyle(.kitSecondary)
    case .kind(let kind): SymbolKindTile(kind: kind, size: 18)
    }
  }
}

/// A part of the path: its kind's tile and name; a click jumps there.
private struct SymbolCrumb: View {
  let part: SymbolInfo
  let isLast: Bool
  let open: () -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 5) {
      SymbolKindTile(kind: part.kind, size: 16)
      Text(part.name)
        .font(.system(size: 12, weight: isLast ? .semibold : .regular))
        .foregroundStyle(isLast || isHovered ? AnyShapeStyle(.kitLabel) : AnyShapeStyle(.kitSecondary))
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(EdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 6))
    .frame(height: 24)
    .background(
      isHovered && part.place != nil ? AnyShapeStyle(.kitField) : AnyShapeStyle(.clear),
      in: RoundedRectangle(cornerRadius: 7, style: .continuous)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture { if part.place != nil { open() } }
    .help(part.place == nil ? part.title : "Jump to \(part.title)")
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
  }
}

/// A symbol kind's letter tile (S, C purple types, P indigo protocols, M blue functions, P teal properties, L gray
/// locals), a package for a module: the completion list's kinds.
struct SymbolKindTile: View {
  let kind: SymbolInfo.Kind
  var size: CGFloat = 18

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size >= 18 ? 5 : 4, style: .continuous).fill(hue.soft(0.16))
      if kind == .module {
        Image(systemName: "shippingbox").font(.system(size: size * 0.58, weight: .semibold))
      } else {
        Text(letter).font(.system(size: size >= 18 ? 10 : 9, weight: .bold))
      }
    }
    .foregroundStyle(hue.text)
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  private var hue: Hue {
    switch kind {
    case .structure, .classType, .actor, .enumeration, .extensionDecl, .typeAlias, .generic: .purple
    case .protocolType: .indigo
    case .function, .method, .initializer, .subscriptDecl, .macro: .blue
    case .property, .variable, .enumCase: .teal
    case .local, .parameter, .other: .gray
    case .module: .orange
    }
  }

  private var letter: String {
    switch kind {
    case .structure: "S"
    case .classType: "C"
    case .actor: "A"
    case .enumeration: "E"
    case .extensionDecl: "X"
    case .typeAlias, .generic: "T"
    case .protocolType: "P"
    case .function, .method, .initializer, .subscriptDecl: "M"
    case .macro: "#"
    case .property, .variable: "P"
    case .enumCase: "E"
    case .local, .parameter: "L"
    case .other, .module: "?"
    }
  }
}
#endif
