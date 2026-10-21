import CodeHighlighting
import SSHKit
import SwiftUI

/// A folder of the project on the device it was read from, listed over SFTP.
struct RemoteFolderView: View {
  let session: ProjectSession
  let path: String
  let title: String
  @State private var entries: [SFTPFileInfo]?
  @State private var error: String?

  var body: some View {
    Group {
      if let entries {
        List(entries, id: \.path) { entry in
          if entry.isDirectory {
            NavigationLink {
              RemoteFolderView(session: session, path: entry.path, title: entry.name)
            } label: {
              Label(entry.name, systemImage: "folder")
            }
          } else {
            NavigationLink {
              RemoteFileView(session: session, entry: entry)
            } label: {
              Label(entry.name, systemImage: "doc.text")
            }
          }
        }
        .listStyle(.plain)
      } else if let error {
        ContentUnavailableView("Couldn’t List \(title)", systemImage: "exclamationmark.triangle", description: Text(error))
      } else {
        ProgressView()
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
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
}

/// A file there, read-only, colored by its language (CodeHighlighting).
struct RemoteFileView: View {
  let session: ProjectSession
  let entry: SFTPFileInfo
  @Environment(\.colorScheme) private var colorScheme
  @State private var text: AttributedString?
  @State private var error: String?

  /// Bigger files aren't opened here.
  static let limit: UInt64 = 2 << 20

  var body: some View {
    Group {
      if let text {
        ScrollView([.vertical, .horizontal]) {
          Text(text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding()
        }
      } else if let error {
        ContentUnavailableView("Couldn’t Open \(entry.name)", systemImage: "doc", description: Text(error))
      } else {
        ProgressView()
      }
    }
    .navigationTitle(entry.name)
    .navigationBarTitleDisplayMode(.inline)
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

extension Color {
  /// 0xRRGGBB.
  init(rgb: UInt32) {
    self.init(
      red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
  }
}
