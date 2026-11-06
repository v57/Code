#if os(macOS) || os(Windows) || os(Linux)
  import CodeFolders
  import CodeScan
  import CodeSwiftModel
  import Foundation

  /// The two fast tiers of one workspace, in this process: Code's scanner for every language, and the Swift model for
  /// Swift. Each works on its own serial queue, built on first use, and answers with the editor's current text.
  final class CodeTiers: @unchecked Sendable {
    let root: URL
    private let scanner: ScannerTier
    private var swift: SwiftModelTier?
    private let lock = NSLock()

    init(root: URL) {
      self.root = root.standardizedFileURL
      scanner = ScannerTier(root: self.root)
    }

    /// The Swift model, made (and its project loaded, in the background) on first use.
    private var swiftModel: SwiftModelTier {
      lock.lock()
      defer { lock.unlock() }
      if let swift { return swift }
      let made = SwiftModelTier(root: root)
      swift = made
      return made
    }

    /// Starts loading the Swift model, so that the first question doesn't wait for all of it.
    func prepareSwiftModel() { _ = swiftModel }

    /// Drops the Swift model and its memory (turned off in settings).
    func dropSwiftModel() {
      lock.lock()
      swift = nil
      lock.unlock()
    }

    var hasSwiftModel: Bool {
      lock.lock()
      defer { lock.unlock() }
      return swift != nil
    }

    /// Files changed on disk: the Swift model reads them again, or the whole project when files came or went or a
    /// manifest changed. The scanner checks its files itself when asked.
    func filesChanged(_ urls: [URL], structural: Bool) {
      lock.lock()
      let swift = swift
      lock.unlock()
      guard let swift else { return }
      let paths = urls.map(\.standardizedFileURL.path)
      let reload = paths.contains { $0.hasSuffix("/Package.swift") } || (structural && paths.contains { $0.hasSuffix(".swift") })
      swift.filesChanged(paths.filter { $0.hasSuffix(".swift") }, reload: reload)
    }

    func scannerDefinitions(url: URL, text: String, line: Int, column: Int) async -> DefinitionAnswer? {
      await scanner.definitions(path: url.standardizedFileURL.path, text: text, line: line, column: column)
    }

    func modelDefinitions(url: URL, text: String, line: Int, column: Int) async -> DefinitionAnswer? {
      await swiftModel.definitions(path: url.standardizedFileURL.path, text: text, line: line, column: column)
    }

    func modelCompletions(url: URL, text: String, line: Int, column: Int) async -> SwiftCompletionList? {
      await swiftModel.completions(path: url.standardizedFileURL.path, text: text, line: line, column: column)
    }

    func scannerCompletions(url: URL, text: String, line: Int, column: Int) async -> [WorkspaceIndex.Completion] {
      await scanner.completions(path: url.standardizedFileURL.path, text: text, line: line, column: column)
    }

    /// Whether a file is one the Swift model reads.
    static func isSwift(_ url: URL) -> Bool { url.pathExtension.lowercased() == "swift" }
  }

  /// The line's text at `line` (from 0), trimmed, for the definitions menu.
  func previewLine(_ bytes: UnsafeBufferPointer<UInt8>, lineStart: Int) -> String {
    var end = lineStart
    while end < bytes.count, bytes[end] != 10 { end += 1 }
    let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[lineStart..<end]), as: UTF8.self)
    return String(text.trimmingCharacters(in: .whitespaces).prefix(160))
  }

  /// Code's scanner over the workspace: lexical, with no types, every language. About 8 MB for a few hundred files.
  private final class ScannerTier: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodeKit.scanner", qos: .userInitiated)
    private let index: WorkspaceIndex
    private var indexed = false

    init(root: URL) {
      index = WorkspaceIndex(roots: FolderScope.isBroad(root) ? [] : [root.path])
    }

    /// The file as the editor has it, and its offset at a position.
    private func prepare(path: String, text: String, line: Int, column: Int) -> (SourceFile, Int)? {
      if !indexed {
        index.refresh()
        indexed = true
      } else {
        index.refreshIfStale()
      }
      guard let profile = LexProfile.profile(forPath: path) else { return nil }
      let source: SourceFile
      if let current = index.source(path: path), current.bytes.elementsEqual(text.utf8) {
        source = current
      } else {
        source = SourceFile(text, profile: profile)
        index.setDocument(source, path: path)
      }
      index.clearCache()
      return (source, source.lines.offset(line: line, character: column, in: source.text))
    }

    func definitions(path: String, text: String, line: Int, column: Int) async -> DefinitionAnswer? {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          guard let (source, offset) = prepare(path: path, text: text, line: line, column: column) else {
            return continuation.resume(returning: nil)
          }
          var places: [DefinitionPlace] = []
          for answer in index.resolve(path: path, source: source, offset: offset).prefix(30) {
            guard let target = answer.path == path ? source : index.source(path: answer.path) else { continue }
            let start = Int(answer.symbol.offset)
            let range = index.range(in: target, start: start, end: start + Int(answer.symbol.nameLength))
            let lineStart = target.lines.offset(line: range.start.line, character: 0, in: target.text)
            places.append(
              DefinitionPlace(
                url: URL(fileURLWithPath: answer.path), line: range.start.line, column: range.start.character,
                name: answer.name, preview: previewLine(target.bytes, lineStart: lineStart)))
          }
          continuation.resume(returning: DefinitionAnswer(tier: .scanner, isSure: false, places: places))
        }
      }
    }

    func completions(path: String, text: String, line: Int, column: Int) async -> [WorkspaceIndex.Completion] {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          guard let (source, offset) = prepare(path: path, text: text, line: line, column: column) else {
            return continuation.resume(returning: [])
          }
          continuation.resume(returning: index.completions(path: path, source: source, offset: offset))
        }
      }
    }
  }

  /// The Swift model of the workspace (CodeSwiftModel): declarations from every Swift file, the SDK's interfaces and
  /// headers read when a question needs them. 150 to 200 MB for a large app; the first question waits for the project
  /// to load (under a second).
  private final class SwiftModelTier: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CodeKit.swiftModel", qos: .userInitiated)
    private var model: Model?
    /// The text each file was last given as, by path, so that an unchanged file isn't read again.
    private var given: [String: Int] = [:]

    private let root: String
    private let isBroad: Bool

    init(root: URL) {
      self.root = root.path
      isBroad = FolderScope.isBroad(root)
      queue.async { [self] in load() }
    }

    private func load() {
      guard !isBroad else { return }
      model = Model(project: Project(root: root))
      given = [:]
    }

    /// A reload is waiting: changes come in bursts (a checkout, a build).
    private var reloadPending = false

    func filesChanged(_ paths: [String], reload: Bool) {
      if reload {
        queue.async { [self] in
          guard !reloadPending else { return }
          reloadPending = true
          queue.asyncAfter(deadline: .now() + 1) { [self] in
            reloadPending = false
            load()
          }
        }
        return
      }
      queue.async { [self] in
        guard let model else { return }
        for path in paths {
          guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
          var hasher = Hasher()
          hasher.combine(text)
          let hash = hasher.finalize()
          guard given[path] != hash else { continue }
          given[path] = hash
          model.project.update(path: path, text: text)
        }
      }
    }

    /// The model, with `path` as the editor has it.
    private func prepare(path: String, text: String) -> Model? {
      guard let model else { return nil }
      var hasher = Hasher()
      hasher.combine(text)
      let hash = hasher.finalize()
      if given[path] != hash {
        given[path] = hash
        model.project.update(path: path, text: text)
      }
      return model
    }

    func definitions(path: String, text: String, line: Int, column: Int) async -> DefinitionAnswer? {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          guard let model = prepare(path: path, text: text) else { return continuation.resume(returning: nil) }
          let answer = model.answer(path: path, line: line, character: column)
          guard answer.state != .unknown else { return continuation.resume(returning: nil) }
          var places: [DefinitionPlace] = []
          for site in answer.sites.prefix(30) {
            guard let found = model.location(of: site) else { continue }
            places.append(
              DefinitionPlace(
                url: URL(fileURLWithPath: found.path), line: found.line, column: found.character, name: found.name,
                preview: found.preview))
          }
          // An answer found by name only is a guess, like the scanner's.
          let sure = answer.state == .exact && !answer.byNameOnly
          continuation.resume(returning: DefinitionAnswer(tier: .model, isSure: sure, places: places))
        }
      }
    }

    func completions(path: String, text: String, line: Int, column: Int) async -> SwiftCompletionList? {
      await withCheckedContinuation { continuation in
        queue.async { [self] in
          guard let model = prepare(path: path, text: text) else { return continuation.resume(returning: nil) }
          continuation.resume(returning: model.complete(path: path, line: line, character: column, limit: 300))
        }
      }
    }
  }
#endif
