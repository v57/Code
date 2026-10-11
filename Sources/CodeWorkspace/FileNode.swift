import Foundation
import Observation

/// A file or folder in a project tree. Folder children load on demand (the
/// first time the folder is expanded) and reload when the folder changes on
/// disk.
@MainActor @Observable public final class FileNode: Identifiable, Hashable {
  public private(set) var url: URL
  public let isDirectory: Bool
  /// Sorted children: folders first, then files, each in Finder order.
  /// Nil until loaded; always nil for files.
  public internal(set) var children: [FileNode]?
  @ObservationIgnored public internal(set) weak var parent: FileNode?

  init(url: URL, isDirectory: Bool, parent: FileNode?) {
    self.url = url
    self.isDirectory = isDirectory
    self.parent = parent
  }

  public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
  public var name: String { url.lastPathComponent }

  /// Moves this node and its loaded descendants to `newURL` (after a rename).
  func relocate(to newURL: URL) {
    url = newURL
    for child in children ?? [] {
      child.relocate(to: newURL.appendingPathComponent(child.name, isDirectory: child.isDirectory))
    }
  }

  public nonisolated static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs === rhs }
  public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
