import CodeHighlighting
import Foundation
import Observation

/// An open project folder: its file tree, Quick Open index, open tabs, and the
/// file watcher that keeps them current.
///
/// Tabs follow VS Code and Zed: a single click opens a *preview* tab that the
/// next single click replaces; editing it, double-clicking the file, or
/// double-clicking the tab keeps it. Documents autosave, so closing a tab never
/// asks anything.
@MainActor @Observable public final class Workspace {
  public let root: URL
  public let tree: FileTree
  public let index: FileIndex
  public private(set) var tabs: [TextDocument] = []
  public var selectedTabID: TextDocument.ID? {
    didSet {
      guard selectedTabID != oldValue else { return }
      // Leaving a tab saves it, as switching documents does in Markdown.
      tabs.first { $0.id == oldValue }?.flush()
      saveSession()
    }
  }
  /// The tab a single click replaces; nil when every tab is kept.
  public private(set) var previewTabID: TextDocument.ID?
  /// A transient message for the status bar (a failed file operation).
  public var statusMessage: String?

  @ObservationIgnored private var watcher: FileWatcher?
  @ObservationIgnored private var indexRebuild: Task<Void, Never>?
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var isRestoring = false
  /// The root with symlinks resolved: FSEvents reports real paths
  /// ("/private/tmp/…" for "/tmp/…").
  @ObservationIgnored private let resolvedRootPath: String

  public init(
    root: URL, excludedNames: Set<String> = FileTree.defaultExcludedNames,
    defaults: UserDefaults = .standard
  ) {
    let root = root.standardizedFileURL
    self.root = root
    self.defaults = defaults
    resolvedRootPath = FileTree.realPath(of: root)
    tree = FileTree(root: root, excludedNames: excludedNames)
    index = FileIndex(root: root, excludedNames: excludedNames)
    index.rebuild()
    watcher = FileWatcher(root: root) { [weak self] changes in self?.filesChanged(changes) }
    restoreSession()
  }

  public var name: String { root.lastPathComponent }

  public var selectedDocument: TextDocument? {
    tabs.first { $0.id == selectedTabID }
  }

  public func document(for url: URL) -> TextDocument? {
    let url = url.standardizedFileURL
    return tabs.first { $0.url == url }
  }

  public func isPreview(_ document: TextDocument) -> Bool { document.id == previewTabID }

  /// The excluded names for the tree and Quick Open.
  public var excludedNames: Set<String> {
    get { tree.excludedNames }
    set {
      tree.excludedNames = newValue
      index.rebuild(excludedNames: newValue)
    }
  }

  // MARK: - Tabs

  /// Opens `url` in a tab and selects it. With `preview`, the tab replaces the
  /// current preview tab instead of adding one.
  @discardableResult
  public func open(_ url: URL, preview: Bool = false) -> TextDocument {
    let url = url.standardizedFileURL
    if let existing = document(for: url) {
      if !preview { keep(existing) }
      selectedTabID = existing.id
      return existing
    }
    let document = TextDocument(url: url)
    document.onEdit = { [weak self, weak document] in
      if let self, let document { self.keep(document) }
    }
    if preview, let previewID = previewTabID, let i = tabs.firstIndex(where: { $0.id == previewID })
    {
      tabs[i].flush()
      tabs[i] = document
    } else if let selected = selectedTabID, let i = tabs.firstIndex(where: { $0.id == selected }) {
      tabs.insert(document, at: i + 1)
    } else {
      tabs.append(document)
    }
    previewTabID = preview ? document.id : (previewTabID == document.id ? nil : previewTabID)
    selectedTabID = document.id
    Task { await document.load() }
    saveSession()
    return document
  }

  /// Turns a preview tab into a kept one.
  public func keep(_ document: TextDocument) {
    if previewTabID == document.id { previewTabID = nil }
  }

  public func close(_ document: TextDocument) {
    guard let i = tabs.firstIndex(where: { $0.id == document.id }) else { return }
    document.flush()
    tabs.remove(at: i)
    if previewTabID == document.id { previewTabID = nil }
    if selectedTabID == document.id {
      // Select the neighbor, as editors do: the tab to the right, else left.
      selectedTabID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id
    }
    saveSession()
  }

  public func closeOthers(_ document: TextDocument) {
    for other in tabs where other.id != document.id { other.flush() }
    tabs = tabs.filter { $0.id == document.id }
    previewTabID = previewTabID == document.id ? previewTabID : nil
    selectedTabID = document.id
    saveSession()
  }

  public func closeAll() {
    flushAll()
    tabs = []
    previewTabID = nil
    selectedTabID = nil
    saveSession()
  }

  /// Moves a tab to `index` (tab bar drag and drop).
  public func move(_ document: TextDocument, to index: Int) {
    guard let from = tabs.firstIndex(where: { $0.id == document.id }) else { return }
    let tab = tabs.remove(at: from)
    tabs.insert(tab, at: max(0, min(index, tabs.count)))
    saveSession()
  }

  public func selectNextTab(offset: Int) {
    guard !tabs.isEmpty else { return }
    let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
    selectedTabID = tabs[(current + offset + tabs.count) % tabs.count].id
  }

  /// Saves every document with pending edits.
  public func flushAll() {
    for document in tabs { document.flush() }
  }

  /// Save All (⌥⌘S): an explicit save of every open document.
  public func saveAll() {
    for document in tabs { document.save() }
  }

  // MARK: - File operations

  /// Creates a file and opens it.
  @discardableResult
  public func createFile(named name: String, in directory: URL) -> URL? {
    perform {
      let url = try tree.createFile(named: name, in: directory)
      tree.reveal(url)
      open(url)
      return url
    }
  }

  @discardableResult
  public func createFolder(named name: String, in directory: URL) -> URL? {
    perform {
      let url = try tree.createFolder(named: name, in: directory)
      tree.reveal(url)
      return url
    }
  }

  /// Renames a file or folder, moving any open documents inside it along.
  @discardableResult
  public func rename(_ url: URL, to name: String) -> URL? {
    perform {
      for document in tabs where Self.contains(url, document.url) { document.flush() }
      let newURL = try tree.rename(url, to: name)
      let oldPath = url.standardizedFileURL.path
      for document in tabs where Self.contains(url, document.url) {
        let suffix = document.url.path.dropFirst(oldPath.count)
        document.move(to: URL(fileURLWithPath: newURL.path + suffix))
      }
      saveSession()
      return newURL
    }
  }

  /// Moves a file or folder to the Trash and closes its documents.
  public func trash(_ url: URL) {
    _ = perform {
      for document in tabs where Self.contains(url, document.url) { document.flush() }
      try tree.trash(url)
      for document in tabs where Self.contains(url, document.url) { close(document) }
      return url
    }
  }

  private func perform(_ operation: () throws -> URL) -> URL? {
    do {
      statusMessage = nil
      return try operation()
    } catch {
      statusMessage = error.localizedDescription
      return nil
    }
  }

  /// Whether `item` is `container` or inside it.
  private static func contains(_ container: URL, _ item: URL) -> Bool {
    let c = container.standardizedFileURL.path
    let i = item.standardizedFileURL.path
    return i == c || i.hasPrefix(c + "/")
  }

  // MARK: - File system changes

  private func filesChanged(_ changes: [FileWatcher.Change]) {
    var directories: Set<URL> = []
    var structural = false
    for change in changes {
      let url = localURL(for: change.url)
      if change.rescan {
        tree.reloadAll()
        structural = true
        continue
      }
      directories.insert(url.deletingLastPathComponent())
      if change.structural {
        structural = true
        directories.insert(url)
      }
      if let document = document(for: url) {
        Task { await document.reloadFromDisk() }
      }
    }
    for directory in directories { tree.reload(directory: directory) }
    if structural { scheduleIndexRebuild() }
  }

  /// Maps a real path from FSEvents back under `root` as the user opened it.
  private func localURL(for url: URL) -> URL {
    let path = url.path
    guard resolvedRootPath != root.path, path.hasPrefix(resolvedRootPath) else {
      return url.standardizedFileURL
    }
    return URL(fileURLWithPath: root.path + path.dropFirst(resolvedRootPath.count))
      .standardizedFileURL
  }

  private func scheduleIndexRebuild() {
    indexRebuild?.cancel()
    indexRebuild = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      self?.index.rebuild()
    }
  }

  // MARK: - Session

  /// Open tabs, the selected tab and expanded folders, restored when the
  /// project opens again. Paths are relative to the root.
  struct Session: Codable {
    var tabs: [String]
    var selected: String?
    var expanded: [String]
  }

  private var sessionKey: String { "CodeKit.session:" + root.path }

  /// Stores the open tabs and expanded folders for the next time this
  /// project opens. Called after tab changes; the app also calls it before
  /// closing the window to keep the latest expansion state.
  public func saveSession() {
    guard !isRestoring else { return }
    let session = Session(
      tabs: tabs.filter { $0.id != previewTabID }.map { tree.relativePath(of: $0.url) },
      selected: selectedDocument.map { tree.relativePath(of: $0.url) },
      expanded: tree.expanded.map { tree.relativePath(of: $0) }.sorted())
    if let data = try? JSONEncoder().encode(session) { defaults.set(data, forKey: sessionKey) }
  }

  private func restoreSession() {
    guard let data = defaults.data(forKey: sessionKey),
      let session = try? JSONDecoder().decode(Session.self, from: data)
    else { return }
    isRestoring = true
    defer { isRestoring = false }
    let fm = FileManager.default
    for path in session.expanded {
      let url = root.appendingPathComponent(path)
      if fm.fileExists(atPath: url.path) { tree.expand(url) }
    }
    for path in session.tabs {
      let url = root.appendingPathComponent(path)
      if fm.fileExists(atPath: url.path) { open(url) }
    }
    if let selected = session.selected, let document = document(for: root.appendingPathComponent(selected)) {
      selectedTabID = document.id
    }
  }
}
