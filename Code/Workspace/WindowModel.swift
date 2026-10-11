import CodeKit
import SwiftUI

/// The state of one project window around its workspace: overlays, prompts,
/// the sidebar selection and the caret position for the status bar.
@MainActor @Observable final class WindowModel {
  enum Prompt: Identifiable {
    case newFile(in: URL)
    case newFolder(in: URL)
    case rename(URL)

    var id: String {
      switch self {
      case .newFile(let url): return "file:" + url.path
      case .newFolder(let url): return "folder:" + url.path
      case .rename(let url): return "rename:" + url.path
      }
    }
  }

  let workspace: Workspace
  var isQuickOpenPresented = false
  var isGoToLinePresented = false
  var prompt: Prompt?
  /// The text field of the current prompt.
  var promptText = ""
  var trashCandidate: URL?
  var sidebarSelection: URL?
  /// The navigator (sidebar) column, toggled with ⌘0.
  var isNavigatorVisible = true
  var selection = EditorSelection()

  init(workspace: Workspace) {
    self.workspace = workspace
  }

  /// The folder new items go into: the selected folder, the selected file's
  /// folder, or the project root.
  var targetFolder: URL {
    guard let selected = sidebarSelection ?? workspace.selectedDocument?.url else {
      return workspace.root
    }
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory)
    return isDirectory.boolValue ? selected : selected.deletingLastPathComponent()
  }

  func ask(_ prompt: Prompt) {
    switch prompt {
    case .rename(let url): promptText = url.lastPathComponent
    default: promptText = ""
    }
    self.prompt = prompt
  }

  /// Runs the current prompt with `promptText`.
  func commitPrompt() {
    guard let prompt else { return }
    self.prompt = nil
    let name = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    switch prompt {
    case .newFile(let folder):
      if let url = workspace.createFile(named: name, in: folder) { sidebarSelection = url }
    case .newFolder(let folder):
      if let url = workspace.createFolder(named: name, in: folder) { sidebarSelection = url }
    case .rename(let url):
      if let newURL = workspace.rename(url, to: name), sidebarSelection == url {
        sidebarSelection = newURL
      }
    }
  }

  func confirmTrash() {
    guard let url = trashCandidate else { return }
    trashCandidate = nil
    workspace.trash(url)
    if sidebarSelection == url { sidebarSelection = nil }
  }
}

extension FocusedValues {
  @Entry var windowModel: WindowModel?
}
