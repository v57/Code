import Foundation
import Observation

/// Recently opened project folders, newest first, kept in user defaults.
@MainActor @Observable final class RecentProjects {
  private static let key = "recentProjects"
  static let limit = 20

  private(set) var folders: [URL]

  init() {
    let paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    folders = paths.map { URL(fileURLWithPath: $0) }
  }

  /// Folders that still exist.
  var existing: [URL] {
    folders.filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  func add(_ folder: URL) {
    let folder = folder.standardizedFileURL
    folders.removeAll { $0 == folder }
    folders.insert(folder, at: 0)
    folders = Array(folders.prefix(Self.limit))
    save()
  }

  func remove(_ folder: URL) {
    folders.removeAll { $0 == folder }
    save()
  }

  func clear() {
    folders = []
    save()
  }

  private func save() {
    UserDefaults.standard.set(folders.map(\.path), forKey: Self.key)
  }
}

extension URL {
  /// The path with the home folder abbreviated to "~".
  var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
