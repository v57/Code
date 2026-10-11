import SwiftUI

/// SF Symbols, tints and display names for files in the sidebar, tabs and
/// path bar, styled after Xcode's navigator.
enum FileIcon {
  /// The name as Xcode shows it with file extensions hidden: "AppState" for
  /// "AppState.swift", "Assets" for "Assets.xcassets". Dotfiles and names
  /// without an extension stay whole.
  static func displayName(_ url: URL, showExtensions: Bool) -> String {
    let name = url.lastPathComponent
    guard !showExtensions, !name.hasPrefix("."), !url.pathExtension.isEmpty else { return name }
    return url.deletingPathExtension().lastPathComponent
  }

  static func symbol(for url: URL, isDirectory: Bool) -> String {
    switch url.pathExtension.lowercased() {
    case "xcassets": return "photo.on.rectangle.angled"
    case "xcodeproj", "xcworkspace": return "hammer.fill"
    default: break
    }
    if isDirectory { return "folder.fill" }
    switch url.pathExtension.lowercased() {
    case "swift": return "swift"
    case "json", "jsonc", "js", "mjs", "cjs", "ts", "tsx", "jsx", "java", "kt", "c", "cc", "cpp",
      "h", "hpp", "m", "mm", "cs", "go", "rs", "dart", "scala", "php", "css", "scss":
      return "curlybraces"
    case "md", "markdown", "txt", "rtf": return "doc.plaintext"
    case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "ico", "icns", "svg":
      return "photo"
    case "pdf": return "doc.richtext"
    case "sh", "zsh", "bash", "fish", "command": return "terminal"
    case "yml", "yaml", "toml", "plist", "xml", "entitlements", "xcconfig": return "gearshape"
    case "html", "htm": return "chevron.left.forwardslash.chevron.right"
    case "zip", "gz", "tar", "xz", "7z": return "doc.zipper"
    case "py", "rb", "lua", "pl": return "chevron.left.forwardslash.chevron.right"
    default:
      let name = url.lastPathComponent.lowercased()
      if name.hasPrefix(".git") || name == "license" { return "doc.badge.gearshape" }
      if ["makefile", "dockerfile", "package.swift", "gemfile", "podfile"].contains(name) {
        return "hammer"
      }
      return "doc"
    }
  }

  static func tint(for url: URL, isDirectory: Bool) -> Color {
    switch url.pathExtension.lowercased() {
    case "xcassets", "xcodeproj", "xcworkspace": return .blue
    default: break
    }
    // Xcode's folders are a muted blue.
    if isDirectory { return Color(red: 0.36, green: 0.55, blue: 0.82) }
    switch url.pathExtension.lowercased() {
    case "swift": return .orange
    case "js", "mjs", "cjs", "jsx": return .yellow
    case "ts", "tsx", "go", "dart": return .cyan
    case "json", "jsonc", "yml", "yaml", "toml": return .purple
    case "md", "markdown": return .blue
    case "rs", "html", "htm": return .red
    case "py": return .teal
    case "rb": return .pink
    case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg": return .green
    default: return .secondary
    }
  }
}
