import Foundation

/// What a folder's schemes and dependencies come from: one of its Xcode workspaces or projects, or its Swift package.
/// A folder can have several (`Markdown-Local.xcworkspace`, `Markdown.xcodeproj` and `Package.swift`), and each lists
/// its own schemes and resolves its own packages, so one is picked per folder.
public struct ProjectContainer: Identifiable, Hashable, Codable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case workspace, project, package

    public var title: String {
      switch self {
      case .workspace: return "Workspace"
      case .project: return "Project"
      case .package: return "Package"
      }
    }

    public var symbolName: String {
      switch self {
      case .workspace: return "square.stack.3d.up"
      case .project: return "hammer"
      case .package: return "shippingbox"
      }
    }
  }

  /// The manifest that makes a folder a Swift package.
  public static let packageManifest = "Package.swift"

  /// The folder it is in.
  public var directory: URL
  /// Its name in `directory`: "App.xcworkspace", "App.xcodeproj" or "Package.swift".
  public var fileName: String

  public init(directory: URL, fileName: String) {
    self.directory = directory
    self.fileName = fileName
  }

  public var id: String { directory.path + "/" + fileName }

  public var kind: Kind {
    if fileName.hasSuffix(".xcworkspace") { return .workspace }
    return fileName.hasSuffix(".xcodeproj") ? .project : .package
  }

  /// What it is called in a menu: the file's name without its extension; a package goes by its folder.
  public var name: String {
    kind == .package ? directory.lastPathComponent : (fileName as NSString).deletingPathExtension
  }

  /// Whether a folder entry of this name is a container.
  public static func isContainer(_ name: String) -> Bool {
    name.hasSuffix(".xcworkspace") || name.hasSuffix(".xcodeproj") || name == packageManifest
  }

  /// The containers among a folder's entries, the one that wins by default first: workspaces, as a workspace contains
  /// its projects, then projects, then the package, each by name.
  public static func list(entries: [String], in directory: URL) -> [ProjectContainer] {
    let names = entries.filter(isContainer).sorted()
    let ordered =
      names.filter { $0.hasSuffix(".xcworkspace") } + names.filter { $0.hasSuffix(".xcodeproj") }
      + names.filter { $0 == packageManifest }
    return ordered.map { ProjectContainer(directory: directory, fileName: $0) }
  }

  /// The container a folder uses: `picked` while the folder still has it, else the first.
  public static func effective(picked: String?, in containers: [ProjectContainer]) -> ProjectContainer? {
    containers.first { $0.fileName == picked } ?? containers.first
  }
}
