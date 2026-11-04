import Foundation

/// A place in a text, in the editor's coordinates.
public struct TextPosition: Hashable, Sendable {
  public var line: Int
  public var character: Int

  public init(line: Int, character: Int) {
    self.line = line
    self.character = character
  }
}

public struct TextRange: Hashable, Sendable {
  public var start: TextPosition
  public var end: TextPosition

  public init(start: TextPosition, end: TextPosition) {
    self.start = start
    self.end = end
  }
}

public struct SourceLocation: Hashable, Sendable {
  public var path: String
  public var range: TextRange

  public init(path: String, range: TextRange) {
    self.path = path
    self.range = range
  }
}

/// Every file of a folder as what's kept after scanning it: its declarations and a small filter of its names.
///
/// Nothing else stays in memory. What a query needs beyond that comes from scanning the files that may hold the name,
/// which costs less than keeping positions: per Demos/ScanBench, 142 MB of source takes 5 MB of filters against 111 MB
/// of postings, and a query over all of it about 24 ms on one thread. Not thread-safe: one caller at a time, which
/// fans out to threads itself.
public final class WorkspaceIndex: @unchecked Sendable {
  public struct IndexedFile: Sendable {
    public var path: String
    public var profile: LexProfile
    public var size: Int
    public var modified: Int64
    public var symbols: FileSymbols
    public var filter: NameFilter
    /// The hash of each non-local symbol, in order of `symbols`.
    var hashes: [UInt32]
    /// Bumped when the file is scanned again, so its old table entries stop counting.
    var generation: UInt16
    var family: UInt8
  }

  /// A name's entries form a chain from `heads[hash & mask]`.
  struct Entry {
    var hash: UInt32
    var file: UInt32
    var symbol: UInt32
    var next: Int32
    var generation: UInt16
  }

  public private(set) var roots: [String]
  public private(set) var files: [IndexedFile?] = []
  private var fileIndexes: [String: Int] = [:]
  private var entries: [Entry] = []
  private var heads: [Int32] = []
  private var staleEntries = 0
  /// Open documents: the text the editor has, which wins over the disk.
  public private(set) var documents: [String: SourceFile] = [:]
  private var lastRefresh = Date.distantPast
  public var encoding = LineMap.Encoding.utf16

  public init(roots: [String]) {
    self.roots = roots
    heads = [Int32](repeating: -1, count: 1 << 12)
  }

  public var fileCount: Int { fileIndexes.count }
  public var symbolCount: Int { files.reduce(0) { $0 + ($1?.symbols.symbols.count ?? 0) } }
  /// What the index holds, in bytes.
  public var memoryUse: Int {
    var total = entries.capacity * MemoryLayout<Entry>.stride + heads.capacity * 4
    for file in files {
      guard let file else { continue }
      total += file.path.utf8.count + file.symbols.names.capacity + file.symbols.symbols.capacity * MemoryLayout<Symbol>.stride
      total += file.symbols.blocks.capacity * 8 + file.filter.words.capacity * 8 + file.hashes.capacity * 4 + 160
    }
    return total
  }

  // MARK: - Scanning

  /// Languages by file extension, looked up once per extension.
  private final class ExtensionTable: @unchecked Sendable {
    let lock = NSLock()
    var table: [String: LexProfile?] = [:]

    func profile(forFileNamed name: UnsafeBufferPointer<UInt8>) -> LexProfile? {
      var dot = name.count - 1
      while dot > 0, name[dot] != 0x2E, name.count - dot < 12 { dot -= 1 }
      let key: String
      if dot > 0, name[dot] == 0x2E {
        key = String(decoding: UnsafeBufferPointer(rebasing: name[(dot + 1)...]), as: UTF8.self).lowercased()
      } else {
        // Without an extension the whole name decides: Makefile, Dockerfile.
        key = "/" + String(decoding: name, as: UTF8.self).lowercased()
      }
      lock.lock()
      defer { lock.unlock() }
      if let known = table[key] { return known }
      let probe = key.hasPrefix("/") ? "/" + key.dropFirst() : "/a." + key
      var profile = LexProfile.profile(forPath: String(probe))
      if let found = profile, !found.isWorkspaceIndexed { profile = nil }
      table[key] = profile
      return profile
    }
  }

  private let extensions = ExtensionTable()

  /// Scans the roots again: new and changed files by their size and date, removed ones dropped. The first call reads
  /// everything; later ones cost a `stat` per file.
  @discardableResult public func refresh() -> Int {
    lastRefresh = Date()
    let known = fileIndexes
    let existing = files
    let threads = FileWalk.threadCount
    let workers = (0..<threads).map { _ in Worker() }
    let seenLock = NSLock()
    nonisolated(unsafe) var seen = Set<String>()
    seen.reserveCapacity(known.count)
    let table = extensions
    FileWalk.walk(
      roots: roots, threads: threads,
      wants: { table.profile(forFileNamed: $0) != nil },
      isUnchanged: { path, size, modified in
        seenLock.lock()
        seen.insert(path)
        seenLock.unlock()
        guard let index = known[path], let file = existing[index] else { return false }
        return file.size == size && file.modified == modified
      },
      visit: { path, text, count, modified, worker in
        let profile = (path as NSString).lastPathComponent.withCString { name in
          table.profile(forFileNamed: UnsafeBufferPointer(start: UnsafeRawPointer(name).assumingMemoryBound(to: UInt8.self), count: strlen(name)))
        }
        guard let profile else { return }
        workers[worker].scan(path: path, text: text, count: count, modified: modified, profile: profile)
      })
    var changes = 0
    for (path, index) in known where !seen.contains(path) {
      remove(index, path: path)
      changes += 1
    }
    for worker in workers {
      for file in worker.results {
        store(file)
        changes += 1
      }
      worker.free()
    }
    compactIfNeeded()
    return changes
  }

  /// `refresh()` at most this often, for clients that don't tell about changed files.
  public func refreshIfStale(olderThan seconds: TimeInterval = 2) {
    if Date().timeIntervalSince(lastRefresh) > seconds { refresh() }
  }

  private final class Worker: @unchecked Sendable {
    var results: [IndexedFile] = []
    private var tokens = UnsafeMutablePointer<Token>.allocate(capacity: 1 << 18)
    private var capacity = 1 << 18

    func free() { tokens.deallocate() }

    func scan(path: String, text: UnsafePointer<UInt8>, count: Int, modified: Int64, profile: LexProfile) {
      if count + 16 > capacity {
        tokens.deallocate()
        capacity = (count + 16) * 2
        tokens = .allocate(capacity: capacity)
      }
      let tokenCount = CodeScan.scan(text, count, profile: profile, into: tokens)
      let buffer = UnsafeBufferPointer(start: tokens, count: tokenCount)
      results.append(WorkspaceIndex.record(path: path, text: text, count: count, modified: modified, tokens: buffer, profile: profile))
    }
  }

  static func record(
    path: String, text: UnsafePointer<UInt8>, count: Int, modified: Int64, tokens: UnsafeBufferPointer<Token>,
    profile: LexProfile
  ) -> IndexedFile {
    var symbols = extractSymbols(text: text, length: count, tokens: tokens, profile: profile)
    // A file's problems and folds are for when it's open: they're scanned again then.
    symbols.problems = []
    symbols.blocks = []
    let hashes = symbols.symbols.map { symbol -> UInt32 in
      UInt32(truncatingIfNeeded: hashName(text + Int(symbol.offset), Int(symbol.nameLength)))
    }
    return IndexedFile(
      path: path, profile: profile, size: count, modified: modified, symbols: symbols,
      filter: NameFilter(text: text, tokens: tokens), hashes: hashes, generation: 0, family: profile.family)
  }

  private func store(_ incoming: IndexedFile) {
    var file = incoming
    let index: Int
    if let existing = fileIndexes[file.path] {
      index = existing
      file.generation = (files[index]?.generation ?? 0) &+ 1
      staleEntries += files[index]?.symbols.symbols.count ?? 0
      files[index] = file
    } else {
      index = files.count
      files.append(file)
      fileIndexes[file.path] = index
    }
    insertEntries(of: index)
  }

  private func insertEntries(of index: Int) {
    guard let file = files[index] else { return }
    if (entries.count + file.hashes.count) > heads.count * 2 { growHeads() }
    let mask = UInt32(heads.count - 1)
    entries.reserveCapacity(entries.count + file.hashes.count)
    for (symbol, hash) in file.hashes.enumerated() where !file.symbols.symbols[symbol].isLocal {
      let slot = Int(hash & mask)
      entries.append(Entry(hash: hash, file: UInt32(index), symbol: UInt32(symbol), next: heads[slot], generation: file.generation))
      heads[slot] = Int32(entries.count - 1)
    }
  }

  private func growHeads() {
    var size = heads.count
    while entries.count * 2 > size { size *= 2 }
    size *= 2
    heads = [Int32](repeating: -1, count: size)
    let mask = UInt32(size - 1)
    for index in entries.indices {
      let slot = Int(entries[index].hash & mask)
      entries[index].next = heads[slot]
      heads[slot] = Int32(index)
    }
  }

  private func remove(_ index: Int, path: String) {
    staleEntries += files[index]?.symbols.symbols.count ?? 0
    files[index] = nil
    fileIndexes[path] = nil
  }

  private func compactIfNeeded() {
    guard staleEntries > 1024, staleEntries * 2 > entries.count else { return }
    entries.removeAll(keepingCapacity: true)
    heads = [Int32](repeating: -1, count: heads.count)
    staleEntries = 0
    for index in files.indices { insertEntries(of: index) }
  }

  /// A file changed on disk or was saved: scans it now.
  public func fileChanged(path: String) {
    guard documents[path] == nil else { return }
    guard let bytes = FileWalk.read(path) else {
      if let index = fileIndexes[path] { remove(index, path: path) }
      return
    }
    guard let profile = LexProfile.profile(forPath: path), profile.isWorkspaceIndexed else { return }
    let source = SourceFile(bytes: bytes, profile: profile)
    index(source, path: path)
  }

  private func index(_ source: SourceFile, path: String) {
    let info = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
    let modified = Int64(((info[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
    let record = source.tokens.withUnsafeBufferPointer {
      Self.record(path: path, text: source.text, count: source.count, modified: modified, tokens: $0, profile: source.profile)
    }
    store(record)
  }

  // MARK: - Documents

  /// The editor opened a file or changed its text: `source` wins over the disk until it closes.
  public func setDocument(_ source: SourceFile, path: String) {
    _ = source.tokens
    _ = source.symbols
    documents[path] = source
    if source.profile.isWorkspaceIndexed { index(source, path: path) }
  }

  public func closeDocument(path: String) {
    documents[path] = nil
    fileChanged(path: path)
  }

  /// The text of a path: the editor's, or the disk's for a path the index knows or the caller names.
  public func source(path: String) -> SourceFile? {
    if let document = documents[path] { return document }
    if let cached = cache[path] { return cached }
    guard let bytes = FileWalk.read(path) else { return nil }
    let profile = (fileIndexes[path].flatMap { files[$0]?.profile }) ?? LexProfile.profile(forPath: path) ?? .plainText
    let source = SourceFile(bytes: bytes, profile: profile)
    if cache.count >= 32 { cache.removeAll(keepingCapacity: true) }
    cache[path] = source
    return source
  }

  /// A few files read recently: queries read the same declarations again.
  private var cache: [String: SourceFile] = [:]

  /// Forgets the recently read files, after something changed.
  public func clearCache() { cache.removeAll(keepingCapacity: true) }

  public func file(path: String) -> IndexedFile? { fileIndexes[path].flatMap { files[$0] } }

  /// Every non-local declaration with this name: the file index, the symbol index.
  func declarations(named bytes: UnsafeBufferPointer<UInt8>, hash: UInt64) -> [(file: Int, symbol: Int)] {
    var result: [(file: Int, symbol: Int)] = []
    let short = UInt32(truncatingIfNeeded: hash)
    var entry = heads[Int(short & UInt32(heads.count - 1))]
    while entry >= 0 {
      let item = entries[Int(entry)]
      if item.hash == short, let file = files[Int(item.file)], file.generation == item.generation {
        let symbol = file.symbols.symbols[Int(item.symbol)]
        if file.symbols.nameEquals(symbol, bytes) { result.append((Int(item.file), Int(item.symbol))) }
      }
      entry = item.next
    }
    return result
  }

  // MARK: - Positions

  public func location(path: String, source: SourceFile, start: Int, end: Int) -> SourceLocation {
    SourceLocation(path: path, range: range(in: source, start: start, end: end))
  }

  public func range(in source: SourceFile, start: Int, end: Int) -> TextRange {
    let a = source.lines.position(of: start, in: source.text, encoding: encoding)
    let b = source.lines.position(of: end, in: source.text, encoding: encoding)
    return TextRange(start: TextPosition(line: a.line, character: a.character), end: TextPosition(line: b.line, character: b.character))
  }
}

extension LexProfile {
  /// Whether a folder's scan keeps this language's files: code, not data whose keys would drown every name in it.
  public var isWorkspaceIndexed: Bool {
    guard case .code = rules.outline else { return false }
    if case .none = rules.blocks { return !rules.declarations.isEmpty }
    return true
  }

  /// Languages that can call each other: a name in one may be declared in another of them.
  public var family: UInt8 {
    switch spec.name {
    case "C", "C++", "Objective-C": return 1
    case "JavaScript", "TypeScript": return 2
    case "Swift": return 3
    case "Python": return 4
    case "Rust": return 5
    case "Go": return 6
    case "Java", "Kotlin", "Scala": return 7
    case "Shell", "Makefile", "Dockerfile": return 8
    case "Ruby": return 9
    case "PHP": return 10
    case "C#": return 11
    case "Dart": return 12
    case "Lua": return 13
    case "Haskell": return 14
    case "PowerShell": return 15
    default: return 100
    }
  }
}
