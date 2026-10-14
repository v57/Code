import Foundation

/// Names of files as the navigator, tabs and path bar show them.
enum FileName {
  /// The name as Xcode shows it with file extensions hidden: "AppState" for
  /// "AppState.swift", "Assets" for "Assets.xcassets". Dotfiles and names
  /// without an extension stay whole.
  static func display(_ url: URL, showExtensions: Bool) -> String {
    let name = url.lastPathComponent
    guard !showExtensions, !name.hasPrefix("."), !url.pathExtension.isEmpty else { return name }
    return url.deletingPathExtension().lastPathComponent
  }
}
