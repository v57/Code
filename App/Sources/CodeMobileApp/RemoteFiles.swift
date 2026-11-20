import CodeActions
import CodeHighlighting
import CodeIcons
import ComponentKit
import SSHKit
import SwiftUI

/// A folder of the project on the device it was read from, listed over SFTP (folders first, hidden files left out)
/// in one card under the kit's bar.
struct RemoteFolderView: View {
  let session: ProjectSession
  let path: String
  let title: String
  /// The project's own folder: the bar says where it is ("studio-mac · ~/Developer/Atlas").
  var isRoot = false
  @State private var entries: [SFTPFileInfo]?
  @State private var error: String?
  /// The file or folder a row pushed.
  @State private var pushed: SFTPFileInfo?

  var body: some View {
    Group {
      if let entries, entries.isEmpty {
        EmptyState(systemImage: "folder", title: "Empty Folder", message: "\(title) has nothing to show here.")
      } else if let entries {
        ScrollView {
          KitSection(
            "Files", meta: [
              String(localized: "\(entries.count) items"),
              String(localized: "over SFTP"),
            ],
            systemImage: "folder", hue: .blue
          ) {
            ForEach(entries, id: \.path) { entry in
              fileRow(entry)
            }
          }
          .padding(.horizontal, KitMetrics.gutter + 4)
          .padding(.top, 4)
          .padding(.bottom, 24)
        }
      } else if let error {
        EmptyState(systemImage: "exclamationmark.triangle", title: String(localized: "Couldn’t List \(title)"), message: error, status: .failed(nil))
      } else {
        EmptyState(systemImage: "folder", title: "Listing \(title)", status: .working)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.kitWindow)
    .kitPane(.content)
    .kitToolbar(title, title: {
      KitTitle(title, meta: meta, systemImage: "folder", hue: .blue)
    }) {}
    .navigationBarBackButtonHidden(true)
    .navigationDestination(item: $pushed) { entry in
      if entry.isDirectory {
        RemoteFolderView(session: session, path: entry.path, title: entry.name)
      } else {
        RemoteFileView(session: session, entry: entry)
      }
    }
    .task {
      do {
        let listed = try await session.fileClient().list(path)
        // Folders first, then by name as Finder sorts.
        entries = listed.filter { !$0.name.hasPrefix(".") }.sorted {
          $0.isDirectory != $1.isDirectory
            ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
      } catch {
        self.error = ProjectSession.describe(error)
      }
    }
  }

  /// A file or folder in the card: the kit's row with its icon (CodeIcons) and name; a tap pushes it.
  private func fileRow(_ entry: SFTPFileInfo) -> some View {
    SidebarRow(entry.name) {
      FileIconView(FileIcon(fileName: entry.name, isDirectory: entry.isDirectory), size: 17)
        .foregroundStyle(entry.isDirectory ? AnyShapeStyle(Hue.blue.fill) : AnyShapeStyle(.kitSecondary))
    }
    .pushes()
    .action { pushed = entry }
  }

  private var meta: [String] {
    let device = session.source?.name ?? ""
    return [device, isRoot ? RemoteFolderView.abbreviated(path) : session.relativePath(of: path)]
  }

  /// `/Users/aiko/Developer/Atlas` as `~/Developer/Atlas`.
  static func abbreviated(_ path: String) -> String {
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count > 2, parts[0] == "Users" || parts[0] == "home" else { return path }
    return "~/" + parts.dropFirst(2).joined(separator: "/")
  }
}

/// A file there, read-only, coloured by its language (CodeHighlighting), with no gutter. Opened for an issue, it
/// shows the issue over the text and scrolls to its line, marked in the issue's colour.
struct RemoteFileView: View {
  let session: ProjectSession
  let entry: SFTPFileInfo
  var issue: BuildIssue?
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.kitIdiom) private var idiom
  @State private var text: AttributedString?
  /// A file that isn't text: the kit's preview (a picture, a PDF, or its kind and size).
  @State private var data: Data?
  @State private var error: String?

  /// Bigger files aren't opened here.
  static let limit: UInt64 = 2 << 20

  var body: some View {
    Group {
      if let text, let issue, let line = issue.line {
        VStack(spacing: 8) {
          issueBanner(issue)
          lines(of: text, marking: line, hue: issue.severity == .error ? .red : .orange)
        }
      } else if let text {
        ScrollView([.vertical, .horizontal]) {
          Text(text)
            .kitFont(.code)
            .lineSpacing(idiom == .phone ? 2 : 3)
            .textSelection(.enabled)
            .padding(.horizontal, idiom == .phone ? 14 : 16)
            .padding(.vertical, 12)
        }
        // The text stops at the bar, as in an editor: dense lines scrolling on under the bar's fade read through the
        // file's name and meta there.
        .clipped()
      } else if let data {
        KitFilePreview(name: entry.name, data: data)
      } else if let error {
        EmptyState(systemImage: "doc", title: "Couldn’t Open \(entry.name)", message: error, status: .failed(nil))
      } else {
        EmptyState(systemImage: "doc.text", title: "Reading \(entry.name)", status: .working)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.kitWindow)
    .kitPane(.content)
    .kitToolbar(entry.name, title: {
      RichHeader(Text(entry.name), size: .title) {
        FileTitleIcon(name: entry.name)
      } meta: {
        MetaLine((idiom == .phone ? [] : [folder]) + [session.source?.name ?? "", String(localized: "read-only")])
      } accessory: {
        EmptyView()
      }
    }) {}
    .navigationBarBackButtonHidden(true)
    .task(id: colorScheme) {
      guard entry.size <= Self.limit else {
        error = String(
          localized: "It’s \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)): too big to show here.")
        return
      }
      do {
        let data = try await session.fileClient().read(entry.path)
        guard let code = String(data: data, encoding: .utf8) else {
          self.data = data
          return
        }
        text = Self.highlighted(code, name: entry.name, dark: colorScheme == .dark)
      } catch {
        self.error = ProjectSession.describe(error)
      }
    }
  }

  /// The issue the file was opened for, over its text.
  private func issueBanner(_ issue: BuildIssue) -> some View {
    let isError = issue.severity == .error
    return Banner(
      issue.message, message: issue.line.map { String(localized: "Line \($0)") },
      systemImage: isError ? "xmark.octagon" : "exclamationmark.triangle", hue: isError ? .red : .orange
    ) {}
    .padding(.horizontal, KitMetrics.gutter + 4)
    .padding(.top, 4)
  }

  /// The text a line at a time, scrolled to `marked` (from 1), which has the issue's colour behind it.
  private func lines(of text: AttributedString, marking marked: Int, hue: Hue) -> some View {
    let lines = Self.split(text)
    // The marked line's colour spans the screen, or the longest line when that's wider.
    return GeometryReader { geometry in
      ScrollViewReader { proxy in
        ScrollView([.vertical, .horizontal]) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
              Text(lines[index])
                .kitFont(.code)
                .padding(.horizontal, idiom == .phone ? 14 : 16)
                .padding(.vertical, idiom == .phone ? 1 : 1.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(index + 1 == marked ? AnyShapeStyle(hue.fill.opacity(0.18)) : AnyShapeStyle(.clear))
                .id(index + 1)
            }
          }
          .frame(minWidth: geometry.size.width, alignment: .leading)
          .textSelection(.enabled)
          .padding(.vertical, 12)
        }
        .clipped()
        .onAppear { proxy.scrollTo(marked, anchor: UnitPoint(x: 0, y: 0.3)) }
      }
    }
  }

  /// A highlighted text's lines, without their line breaks (an empty line stays one line).
  static func split(_ text: AttributedString) -> [AttributedString] {
    var lines: [AttributedString] = []
    var start = text.startIndex
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(afterCharacter: index)
      if text.characters[index] == "\n" {
        lines.append(AttributedString(text[start..<index]))
        start = next
      }
      index = next
    }
    lines.append(AttributedString(text[start..<text.endIndex]))
    return lines
  }

  /// The file's folder in the project ("Sources/Atlas").
  private var folder: String {
    session.relativePath(of: (entry.path as NSString).deletingLastPathComponent)
  }

  static func highlighted(_ code: String, name: String, dark: Bool) -> AttributedString {
    let firstLine = code.prefix { $0 != "\n" }
    let spec = Language.detect(url: URL(fileURLWithPath: name), firstLine: String(firstLine))
    var text = AttributedString(code)
    guard let spec else { return text }
    let scheme = CodeColorScheme.systemAware(isDark: dark)
    let utf16 = code.utf16
    for token in CodeHighlighter.tokens(in: code, language: spec.name) {
      guard
        let start = utf16.index(utf16.startIndex, offsetBy: token.range.location, limitedBy: utf16.endIndex),
        let end = utf16.index(start, offsetBy: token.range.length, limitedBy: utf16.endIndex),
        let lower = AttributedString.Index(start, within: text), let upper = AttributedString.Index(end, within: text)
      else { continue }
      text[lower..<upper].foregroundColor = Color(rgb: scheme.color(for: token.kind))
    }
    return text
  }
}

/// A file's icon on the title's tile: CodeIcons' glyph in its colour, on the kit's soft tile.
private struct FileTitleIcon: View {
  let name: String

  var body: some View {
    let icon = FileIcon(fileName: name)
    Tile(hue: icon.symbol == "swift" ? .orange : .gray, size: 32) { FileIconView(icon, size: 16) }
  }
}
