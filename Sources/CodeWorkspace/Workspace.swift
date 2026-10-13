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
  /// The packages the project depends on, from its manifests and
  /// lockfiles (the navigator's Package Dependencies).
  public private(set) var dependencies: [PackageDependency] = []
  /// Called with documents whose tabs closed (language servers close them).
  @ObservationIgnored public var onCloseDocuments: (([TextDocument]) -> Void)?

  @ObservationIgnored private var watcher: FileWatcher?
  @ObservationIgnored private var indexRebuild: Task<Void, Never>?
  @ObservationIgnored private var dependencyScan: Task<Void, Never>?
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var isRestoring = false
  /// The root with symlinks resolved: FSEvents reports real paths
  /// ("/private/tmp/…" for "/tmp/…").
  @ObservationIgnored private let resolvedRootPath: String

  /// `hidesIgnoredFiles` is the app's setting, for projects that haven't
  /// chosen whether `.gitignore` hides files.
  public init(root: URL, hidesIgnoredFiles: Bool = true, defaults: UserDefaults = .standard) {
    let root = root.standardizedFileURL
    self.root = root
    self.defaults = defaults
    resolvedRootPath = FileTree.realPath(of: root)
    let visibility =
      defaults.data(forKey: Self.visibilityKey(root))
      .flatMap { try? JSONDecoder().decode(FileVisibility.self, from: $0) } ?? FileVisibility()
    tree = FileTree(root: root, visibility: visibility, hidesIgnoredFilesByDefault: hidesIgnoredFiles)
    index = FileIndex(root: root, rules: tree.rules)
    index.rebuild()
    watcher = FileWatcher(root: root) { [weak self] changes in self?.filesChanged(changes) }
    restoreSession()
    reloadDependencies()
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

  // MARK: - Hidden files

  /// The project's hidden-file choices, saved for the next time it opens.
  /// The navigator and Quick Open follow changes.
  public var visibility: FileVisibility {
    get { tree.visibility }
    set {
      guard newValue != tree.visibility else { return }
      let rulesChanged = !Self.sameRules(newValue, tree.visibility)
      tree.visibility = newValue
      saveVisibility()
      if rulesChanged { rulesDidChange() }
    }
  }

  /// The app's setting, for projects that haven't chosen whether
  /// `.gitignore` hides files.
  public var hidesIgnoredFilesByDefault: Bool {
    get { tree.hidesIgnoredFilesByDefault }
    set {
      guard newValue != tree.hidesIgnoredFilesByDefault else { return }
      tree.hidesIgnoredFilesByDefault = newValue
      if tree.visibility.hidesIgnoredFiles == nil { rulesDidChange() }
    }
  }

  /// Shows or hides a file or folder in this project.
  public func setVisible(_ url: URL, _ visible: Bool) {
    guard let node = tree.node(for: url) else { return }
    visibility = tree.visibility(setting: node, visible: visible)
  }

  /// Adds a file or folder to the project's `.gitignore` (made if missing)
  /// as a pattern anchored at the project ("/build/" for a folder) and
  /// applies it. A choice to show the item anyway is dropped, so it hides.
  @discardableResult
  public func addToGitIgnore(_ url: URL) -> Bool {
    guard let node = tree.node(for: url), node.url != root else { return false }
    let path = tree.relativePath(of: node.url)
    let pattern = "/" + Self.gitIgnoreEscaped(path) + (node.isDirectory ? "/" : "")
    let file = root.appendingPathComponent(".gitignore")
    var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    guard !text.split(whereSeparator: \.isNewline).contains(Substring(pattern)) else { return false }
    if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
    text += pattern + "\n"
    do {
      try text.write(to: file, atomically: true, encoding: .utf8)
    } catch {
      statusMessage = "Couldn’t write .gitignore: \(error.localizedDescription)"
      return false
    }
    if visibility.shownPaths.contains(path) {
      var visibility = visibility
      visibility.shownPaths.remove(path)
      self.visibility = visibility
    }
    // The watcher reports the change too, but the menu acts at once.
    tree.reload(directory: root)
    tree.reloadGitIgnore()
    rulesDidChange()
    return true
  }

  /// A path with the characters `.gitignore` treats specially escaped.
  static func gitIgnoreEscaped(_ path: String) -> String {
    var escaped = ""
    for character in path {
      if "*?[]\\!#".contains(character) { escaped.append("\\") }
      escaped.append(character)
    }
    // Trailing spaces are dropped unless escaped.
    while escaped.hasSuffix(" ") && !escaped.hasSuffix("\\ ") {
      escaped.removeLast()
      escaped += "\\ "
    }
    return escaped
  }

  /// Forgets the project's hidden and shown items.
  public func restoreDefaultVisibility() {
    var visibility = visibility
    visibility.hidesIgnoredFiles = nil
    visibility.hiddenPaths = []
    visibility.shownPaths = []
    self.visibility = visibility
  }

  private var visibilityKey: String { Self.visibilityKey(root) }
  private static func visibilityKey(_ root: URL) -> String { "CodeKit.visibility:" + root.path }

  private func saveVisibility() {
    if let data = try? JSONEncoder().encode(tree.visibility) { defaults.set(data, forKey: visibilityKey) }
  }

  /// Whether `a` and `b` hide the same files (the navigator toggle aside).
  private static func sameRules(_ a: FileVisibility, _ b: FileVisibility) -> Bool {
    var a = a
    a.showsHiddenFiles = b.showsHiddenFiles
    return a == b
  }

  private func rulesDidChange() {
    index.rules = tree.rules
    index.rebuild()
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
      let replaced = tabs[i]
      tabs[i] = document
      onCloseDocuments?([replaced])
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
    onCloseDocuments?([document])
    if previewTabID == document.id { previewTabID = nil }
    if selectedTabID == document.id {
      // Select the neighbor, as editors do: the tab to the right, else left.
      selectedTabID = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id
    }
    saveSession()
  }

  public func closeOthers(_ document: TextDocument) {
    for other in tabs where other.id != document.id { other.flush() }
    onCloseDocuments?(tabs.filter { $0.id != document.id })
    tabs = tabs.filter { $0.id == document.id }
    previewTabID = previewTabID == document.id ? previewTabID : nil
    selectedTabID = document.id
    saveSession()
  }

  public func closeAll() {
    flushAll()
    onCloseDocuments?(tabs)
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
      saveVisibility()
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
    var gitIgnoreChanged = false
    var manifestChanged = false
    for change in changes {
      let url = localURL(for: change.url)
      if change.rescan || DependencyScanner.isManifest(url.lastPathComponent) { manifestChanged = true }
      if url.lastPathComponent == ".gitignore" || url.path.hasSuffix("/.git/info/exclude") {
        gitIgnoreChanged = true
      }
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
    if gitIgnoreChanged { tree.reloadGitIgnore() }
    if structural || gitIgnoreChanged { scheduleIndexRebuild() }
    if manifestChanged { reloadDependencies(after: .seconds(1)) }
  }

  /// Finds the project's package dependencies again, off the main thread
  /// (after `delay`, so an install writing many manifests scans once).
  public func reloadDependencies(after delay: Duration = .zero) {
    dependencyScan?.cancel()
    let root = root
    dependencyScan = Task { [weak self] in
      if delay > .zero { try? await Task.sleep(for: delay) }
      guard !Task.isCancelled else { return }
      let found = await Task.detached(priority: .utility) { DependencyScanner.scan(root) }.value
      guard !Task.isCancelled, let self, found != self.dependencies else { return }
      self.dependencies = found
    }
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
