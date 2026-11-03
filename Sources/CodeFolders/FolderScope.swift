import Foundation

/// How deep Code may look into an opened folder on its own. The home folder and the folders above it hold Desktop,
/// Documents, Music and iCloud Drive: walking them asks for each of those permissions and reads the whole disk, so
/// everything that walks a project (schemes, the file index, dependencies, the project icon, language servers, the file
/// watcher) stays out. Their top level still lists, and folders the user opens in the navigator load as usual.
public enum FolderScope {
  /// Whether `folder` is the home folder or one above it, up to "/". Projects inside the home folder are not.
  public static func isBroad(_ folder: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> Bool {
    let folder = components(of: folder)
    let home = components(of: home)
    return folder.count <= home.count && Array(home.prefix(folder.count)) == folder
  }

  /// The path's components with symlinks resolved (`/tmp` is `/private/tmp`).
  private static func components(of url: URL) -> [String] {
    url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.filter { $0 != "/" }
  }
}
