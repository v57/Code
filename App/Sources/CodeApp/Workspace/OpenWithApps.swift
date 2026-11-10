import CodeKit
import ComponentKit
import Foundation
import SwiftUI

/// The apps a menu's Open With row offers (`KitOpenWithRow`), in the order the menus board draws them: Xcode, Git,
/// the file manager, Terminal. Code leaves itself out; an app that isn't installed drops out of the row.
enum OpenWithApps {
  static let xcode = "com.apple.dt.Xcode"
  static let git = "dev.v57.git"

  /// A project's folder: Xcode (on its workspace or project when it has one), Git, the file manager, Terminal.
  /// `container` is the one the window builds from; without it, the folder's default.
  @MainActor static func project(
    _ folder: URL, container: ProjectContainer? = nil, xcode: Bool = true, git: Bool = true
  ) -> [KitOpenApp?] {
    let name = folder.lastPathComponent
    return [
      xcode
        ? .app(Self.xcode, name: "Xcode", opening: [xcodeTarget(folder, container: container)], preview: "Opens \(name) in Xcode.")
        : nil,
      git ? .app(Self.git, name: "Git", opening: [folder], preview: "Opens \(name) in Git.") : nil,
      .fileManager(revealing: [folder], preview: "Shows the \(name) folder in \(KitDesktop.fileManagerName)."),
      .terminal(at: folder, preview: "Opens Terminal in the \(name) folder."),
    ]
  }

  /// A file or folder in a project: Xcode (with the project, so the file opens in it), the file manager, and with
  /// `defaultApp` the app the system opens the file with.
  @MainActor static func item(
    _ url: URL, project: URL?, container: ProjectContainer? = nil, defaultApp: Bool
  ) -> [KitOpenApp?] {
    let name = url.lastPathComponent
    let opening = project.map { [xcodeTarget($0, container: container), url] } ?? [url]
    return [
      .app(Self.xcode, name: "Xcode", opening: opening, preview: "Opens \(name) in Xcode."),
      .fileManager(revealing: [url], preview: "Shows \(name) in its folder in \(KitDesktop.fileManagerName)."),
      defaultApp
        ? .defaultApp(
          opening: url,
          preview: "Opens \(name) in \(KitDesktop.defaultApp(for: url)?.name ?? String(localized: "the app the system opens it with")).")
        : nil,
    ]
  }

  /// What Xcode opens for a project: the workspace or project it builds from, else the folder's own (a workspace
  /// before a project), else the folder.
  private static func xcodeTarget(_ folder: URL, container: ProjectContainer?) -> URL {
    if let container, container.kind != .package, container.directory.standardizedFileURL == folder.standardizedFileURL {
      return folder.appendingPathComponent(container.fileName)
    }
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    guard let found = ProjectContainer.list(entries: entries, in: folder).first(where: { $0.kind != .package }) else {
      return folder
    }
    return folder.appendingPathComponent(found.fileName)
  }
}
