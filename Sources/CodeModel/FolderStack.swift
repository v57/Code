import Foundation

/// The folders a depth-first walk has yet to list. It follows folder links, as the layouts always have, except a link
/// back to a folder the walk is inside of (or to a folder above one), which would list the same files forever.
///
/// Each folder carries its real path, worked out as the walk goes down (only a link costs a lookup), and the real
/// paths of the folders where the walk went through a link: a link whose target is one of those, or above one, loops.
public struct FolderStack {
  private struct Entry {
    var path: String
    var real: String
    /// The real paths of the folders above it from which the walk followed a link.
    var crossings: [String]
  }

  private var entries: [Entry] = []
  private var current: Entry?

  public init(_ start: String) {
    entries = [Entry(path: start, real: Self.realPath(start), crossings: [])]
  }

  /// The next folder to list; the folders pushed after it are its own.
  public mutating func pop() -> String? {
    current = entries.popLast()
    return current?.path
  }

  /// Adds `path`, a folder inside the one `pop()` returned last, unless it's a link that loops. Returns whether it was added.
  @discardableResult public mutating func push(_ path: String) -> Bool {
    guard let parent = current else {
      entries.append(Entry(path: path, real: Self.realPath(path), crossings: []))
      return true
    }
    let name = path.hasPrefix(parent.path + "/") ? String(path.dropFirst(parent.path.count + 1)) : (path as NSString).lastPathComponent
    guard Self.isLink(path) else {
      entries.append(Entry(path: path, real: parent.real + "/" + name, crossings: parent.crossings))
      return true
    }
    let target = Self.realPath(path)
    for folder in parent.crossings + [parent.real] where Self.contains(target, folder) { return false }
    entries.append(Entry(path: path, real: target, crossings: parent.crossings + [parent.real]))
    return true
  }

  /// Whether `folder` is `ancestor` or inside it.
  private static func contains(_ ancestor: String, _ folder: String) -> Bool {
    folder == ancestor || ancestor == "/" || folder.hasPrefix(ancestor + "/")
  }

  static func isLink(_ path: String) -> Bool {
    #if os(Windows)
      return (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    #else
      var info = stat()
      return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    #endif
  }

  static func realPath(_ path: String) -> String {
    #if os(Windows)
      return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    #else
      guard let resolved = realpath(path, nil) else { return path }
      defer { free(resolved) }
      return String(cString: resolved)
    #endif
  }
}
