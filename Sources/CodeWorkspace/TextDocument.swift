import CodeHighlighting
import Foundation
import Observation

/// One open text file: its content, language and encoding, and the autosave
/// that writes edits back.
///
/// The editor owns the live text while the file is open. It calls
/// `markEdited()` on each change and supplies the current text through
/// `textProvider`, so a keystroke never copies the whole file. The text is only
/// copied out when a save actually runs: about a second after typing pauses
/// (`saveDelay`), and right away on `flush()`, which the app calls when
/// switching tabs, closing, deactivating and quitting.
@MainActor @Observable public final class TextDocument: Identifiable {
  public enum Content: Equatable, Sendable {
    case loading
    case text
    /// The file has NUL bytes: it is not shown as text.
    case binary
    /// Over `TextDocument.maximumSize`; the size in bytes.
    case tooLarge(Int)
    case unreadable(String)
  }

  public enum SaveState: Equatable, Sendable {
    case saved
    case unsaved
    case failed(String)
  }

  /// Files above this size are not opened.
  public nonisolated static let maximumSize = 20 * 1024 * 1024
  /// Files above this size open without syntax highlighting.
  public nonisolated static let highlightingLimit = 2 * 1024 * 1024

  public let id = UUID()
  public private(set) var url: URL
  public private(set) var content: Content = .loading
  public private(set) var language: LanguageSpec?
  public private(set) var encoding: String.Encoding = .utf8
  public private(set) var saveState: SaveState = .saved
  /// False for large files, where highlighting would make typing lag.
  public private(set) var highlightsSyntax = true
  /// The file no longer exists on disk (deleted or moved by another app).
  /// The next save writes it again.
  public private(set) var isMissing = false
  /// Changes when the text is replaced from outside the editor (load, reload
  /// from disk), telling the editor to take the new `text`.
  public private(set) var revision = 0

  /// The text as last loaded or saved. While the editor is attached, its own
  /// text is newer; read `currentText` for that.
  @ObservationIgnored public private(set) var text = ""
  /// The editor's live text; set by the editor while it shows this document.
  @ObservationIgnored public var textProvider: (@MainActor () -> String)?
  /// Called on the first edit after loading (the workspace pins preview tabs).
  @ObservationIgnored public var onEdit: (@MainActor () -> Void)?
  @ObservationIgnored public var saveDelay: Duration = .seconds(1)
  /// The platform editor's state for this document. The AppKit editor keeps
  /// its text view here, so switching tabs keeps undo history, scroll
  /// position and selection; it goes away with the document.
  @ObservationIgnored public var editorState: AnyObject?
  /// Runs before an explicit save (`save()`), not before autosaves: the
  /// editor tidies the text (trims trailing whitespace) and returns whether
  /// it changed anything.
  @ObservationIgnored public var willSave: (@MainActor () -> Bool)?
  /// Runs before an explicit save, before `willSave`, and may take a while:
  /// formatting on save. It changes the editor's text (an undoable edit), so
  /// the file is written once, already formatted.
  @ObservationIgnored public var preSave: (@MainActor () async -> Void)?
  /// Called after each successful write, with the text written.
  @ObservationIgnored public var didSave: (@MainActor (String) -> Void)?
  /// Where to put the caret once the editor shows the text (line and
  /// column from 1, and how many characters to select): a jump to a
  /// definition or a search result in a file not shown yet.
  @ObservationIgnored public var pendingSelection: (line: Int, column: Int, length: Int)?
  /// An explicit save is running its `preSave`.
  public private(set) var isSaving = false

  @ObservationIgnored private var hasPendingEdits = false
  @ObservationIgnored private var saveTask: Task<Void, Never>?

  public init(url: URL) {
    self.url = url
    language = Language.detect(url: url)
  }

  public var name: String { url.lastPathComponent }

  /// The newest text: the editor's when attached, else the loaded text.
  public var currentText: String { textProvider?() ?? text }

  // MARK: - Loading

  /// Reads the file. Safe to call again (reload); a reload never discards
  /// edits that have not been saved yet.
  public func load() async {
    let url = url
    let result = await Task.detached(priority: .userInitiated) { Self.read(url) }.value
    apply(result, keepingPendingEdits: true)
  }

  /// Re-reads the file after another app changed it. Skipped while edits are
  /// waiting to be saved: they are written next and win.
  public func reloadFromDisk() async {
    guard content != .loading else { return }
    let url = url
    let result = await Task.detached(priority: .utility) { Self.read(url) }.value
    if case .missing = result {
      isMissing = true
      return
    }
    isMissing = false
    if case .text(let newText, _) = result, newText == currentText { return }
    apply(result, keepingPendingEdits: true)
  }

  private func apply(_ result: ReadResult, keepingPendingEdits: Bool) {
    if keepingPendingEdits && hasPendingEdits { return }
    switch result {
    case .text(let text, let encoding):
      self.text = text
      self.encoding = encoding
      highlightsSyntax = text.utf16.count <= Self.highlightingLimit
      if language == nil, let firstLine = text.split(separator: "\n", maxSplits: 1).first {
        language = Language.detect(url: url, firstLine: String(firstLine))
      }
      content = .text
      isMissing = false
      revision += 1
    case .binary:
      content = .binary
    case .tooLarge(let size):
      content = .tooLarge(size)
    case .missing:
      isMissing = true
      if content == .loading { content = .unreadable("The file doesn’t exist.") }
    case .failed(let message):
      content = .unreadable(message)
    }
  }

  enum ReadResult: Sendable {
    case text(String, String.Encoding)
    case binary
    case tooLarge(Int)
    case missing
    case failed(String)
  }

  /// Reads and decodes `url`: UTF-8 first, then UTF-16 by byte-order mark,
  /// then Foundation's encoding detection, then Latin-1 (which decodes
  /// anything).
  nonisolated static func read(_ url: URL) -> ReadResult {
    let size: Int
    do {
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
      if values.isDirectory == true { return .failed("This is a folder.") }
      size = values.fileSize ?? 0
    } catch {
      return FileManager.default.fileExists(atPath: url.path) ? .failed(error.localizedDescription) : .missing
    }
    if size > maximumSize { return .tooLarge(size) }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      return FileManager.default.fileExists(atPath: url.path) ? .failed(error.localizedDescription) : .missing
    }
    return decode(data)
  }

  nonisolated static func decode(_ data: Data) -> ReadResult {
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
      if let text = String(data: data, encoding: .utf16) { return .text(text, .utf16) }
    }
    if data.prefix(8192).contains(0) { return .binary }
    if let text = String(data: data, encoding: .utf8) { return .text(text, .utf8) }
    var converted: NSString?
    var lossy = ObjCBool(false)
    let detected = NSString.stringEncoding(
      for: data, encodingOptions: [.allowLossyKey: false], convertedString: &converted,
      usedLossyConversion: &lossy)
    if detected != 0, let converted {
      return .text(converted as String, String.Encoding(rawValue: detected))
    }
    return .text(String(decoding: data, as: UTF8.self), .utf8)
  }

  // MARK: - Editing and saving

  /// Records an edit made in the editor and schedules a save.
  public func markEdited() {
    guard content == .text else { return }
    if !hasPendingEdits { onEdit?() }
    hasPendingEdits = true
    if saveState != .unsaved { saveState = .unsaved }
    saveTask?.cancel()
    // An explicit save is about to write; no autosave in between.
    if isSaving { return }
    saveTask = Task { [weak self, saveDelay] in
      try? await Task.sleep(for: saveDelay)
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }

  /// Replaces the whole text from outside the editor (the editor picks it up
  /// through `revision`) and saves it.
  public func replaceText(_ newText: String) {
    text = newText
    revision += 1
    textProvider = nil
    markEdited()
  }

  /// An explicit save (⌘S): lets the editor tidy the text, then writes
  /// whatever is pending.
  public func save() {
    guard content == .text, !isSaving else { return }
    guard let preSave else {
      finishSave()
      return
    }
    // No autosave while formatting: the save below writes once.
    saveTask?.cancel()
    saveTask = nil
    isSaving = true
    Task {
      await preSave()
      isSaving = false
      finishSave()
    }
  }

  private func finishSave() {
    if willSave?() == true { hasPendingEdits = true }
    flush()
  }

  /// Writes pending edits now.
  public func flush() {
    saveTask?.cancel()
    saveTask = nil
    guard hasPendingEdits else { return }
    let newText = currentText
    do {
      encoding = try Self.write(newText, to: url, encoding: encoding)
      text = newText
      hasPendingEdits = false
      isMissing = false
      saveState = .saved
      didSave?(newText)
    } catch {
      saveState = .failed(error.localizedDescription)
    }
  }

  /// Points the document at its new location after a rename or move.
  public func move(to newURL: URL) {
    url = newURL
    if let detected = Language.detect(url: newURL) { language = detected }
  }

  /// Writes `text` atomically through a file coordinator in `encoding`, or in
  /// UTF-8 when the text no longer fits that encoding (an emoji typed into a
  /// Latin-1 file). Returns the encoding used.
  nonisolated static func write(_ text: String, to url: URL, encoding: String.Encoding) throws
    -> String.Encoding
  {
    var used = encoding
    let data: Data
    if let encoded = text.data(using: encoding) {
      data = encoded
    } else {
      data = Data(text.utf8)
      used = .utf8
    }
    var coordinationError: NSError?
    var writeError: Error?
    NSFileCoordinator().coordinate(
      writingItemAt: url, options: .forReplacing, error: &coordinationError
    ) { target in
      do {
        try data.write(to: target, options: .atomic)
      } catch {
        writeError = error
      }
    }
    if let error = coordinationError ?? writeError { throw error }
    return used
  }
}

extension String.Encoding {
  /// A short name for the status bar: "UTF-8", "UTF-16", "Western (Windows Latin 1)".
  public var displayName: String {
    switch self {
    case .utf8: return "UTF-8"
    case .utf16, .utf16LittleEndian, .utf16BigEndian: return "UTF-16"
    case .ascii: return "ASCII"
    default:
      return String.localizedName(of: self)
    }
  }
}
