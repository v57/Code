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

  var body: some View {
    Group {
      if let entries {
        ScrollView {
          KitSection(
            "Files", meta: [entries.count == 1 ? "1 item" : "\(entries.count) items", "over SFTP"],
            systemImage: "folder", hue: .blue
          ) {
            ForEach(entries, id: \.path) { entry in
              NavigationLink {
                if entry.isDirectory {
                  RemoteFolderView(session: session, path: entry.path, title: entry.name)
                } else {
                  RemoteFileView(session: session, entry: entry)
                }
              } label: {
                FileRow(entry: entry)
              }
              .buttonStyle(.plain)
            }
            if entries.isEmpty { Text("Empty.").kitFont(.caption).foregroundStyle(.kitSecondary).padding(10) }
          }
          .padding(.horizontal, KitMetrics.gutter + 4)
          .padding(.top, 4)
          .padding(.bottom, 24)
        }
      } else if let error {
        EmptyState(systemImage: "exclamationmark.triangle", title: "Couldn’t List \(title)", message: error, status: .failed(nil))
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

/// A file or folder in the card: its icon (CodeIcons), its name and a chevron, 44pt tall.
private struct FileRow: View {
  let entry: SFTPFileInfo

  var body: some View {
    HStack(spacing: 12) {
      FileIconView(FileIcon(fileName: entry.name, isDirectory: entry.isDirectory), size: 17)
        .foregroundStyle(entry.isDirectory ? AnyShapeStyle(Hue.blue.fill) : AnyShapeStyle(.kitSecondary))
      Text(entry.name)
        .kitFont(.body)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.kitTertiary)
    }
    .padding(.horizontal, 10)
    .frame(minHeight: 44)
    .contentShape(Rectangle())
  }
}

/// A file there, read-only, coloured by its language (CodeHighlighting), with no gutter.
struct RemoteFileView: View {
  let session: ProjectSession
  let entry: SFTPFileInfo
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.kitIdiom) private var idiom
  @State private var text: AttributedString?
  @State private var error: String?

  /// Bigger files aren't opened here.
  static let limit: UInt64 = 2 << 20

  var body: some View {
    Group {
      if let text {
        ScrollView([.vertical, .horizontal]) {
          Text(text)
            .font(.system(size: idiom == .phone ? 12 : 13, design: .monospaced))
            .lineSpacing(idiom == .phone ? 2 : 3)
            .textSelection(.enabled)
            .padding(.horizontal, idiom == .phone ? 14 : 16)
            .padding(.vertical, 12)
        }
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
        MetaLine((idiom == .phone ? [] : [folder]) + [session.source?.name ?? "", "read-only"])
      } accessory: {
        EmptyView()
      }
    }) {}
    .navigationBarBackButtonHidden(true)
    .task(id: colorScheme) {
      guard entry.size <= Self.limit else {
        error = "It’s \(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)): too big to show here."
        return
      }
      do {
        let data = try await session.fileClient().read(entry.path)
        guard let code = String(data: data, encoding: .utf8) else {
          error = "It isn’t text."
          return
        }
        text = Self.highlighted(code, name: entry.name, dark: colorScheme == .dark)
      } catch {
        self.error = ProjectSession.describe(error)
      }
    }
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

/// A file's icon on the title's tile: CodeIcons' glyph in its colour, on that colour's soft fill.
private struct FileTitleIcon: View {
  let name: String

  var body: some View {
    let icon = FileIcon(fileName: name)
    let hue: Hue = icon.symbol == "swift" ? .orange : .gray
    FileIconView(icon, size: 16)
      .frame(width: 32, height: 32)
      .background(hue.soft(0.16), in: RoundedRectangle(cornerRadius: KitMetrics.radius, style: .continuous))
  }
}

extension Color {
  /// 0xRRGGBB.
  init(rgb: UInt32) {
    self.init(
      red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
  }
}
