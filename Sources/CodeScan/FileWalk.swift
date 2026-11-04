import Foundation

/// Walks a folder and reads its source files on a few threads, handing each file's padded bytes to a closure.
///
/// Measured in Demos/ScanBench: 6 threads is where it stops getting faster (130 ms for 142 MB; one thread 486 ms),
/// plain `read` beats `mmap` (a file ending on a page boundary has nothing readable after it for the scanner's padding,
/// so `mmap` needs a copy anyway), and `readdir` with a path buffer beats `FileManager` by 40%.
public enum FileWalk {
  public static let defaultSkippedFolders: Set<String> = [
    ".build", ".git", ".hg", ".svn", "node_modules", "target", "DerivedData", ".swiftpm", "dist", "vendor", "Pods",
    "__pycache__", ".venv", "venv", ".gradle", ".idea", ".next", ".nuxt", "Carthage", "bower_components", ".cache",
    ".dart_tool", "xcuserdata", ".terraform", ".tox", ".mypy_cache", ".pytest_cache",
  ]

  /// Files bigger than this are generated data, not code to read.
  public static let largestFile = 8 << 20

  public static var threadCount: Int { max(1, min(6, ProcessInfo.processInfo.activeProcessorCount)) }

  /// What a thread gets for a file. The buffer is reused for the next file, so copy what's kept; it's padded.
  public typealias Visit = @Sendable (_ path: String, _ text: UnsafePointer<UInt8>, _ count: Int, _ modified: Int64, _ worker: Int) -> Void

  /// Calls `visit` for each file `wants` accepts, and `visitUnchanged` on those it says didn't change, on several threads.
  public static func walk(
    roots: [String], threads: Int = threadCount, skipped: Set<String> = defaultSkippedFolders,
    wants: @Sendable @escaping (_ name: UnsafeBufferPointer<UInt8>) -> Bool,
    isUnchanged: @Sendable @escaping (_ path: String, _ size: Int, _ modified: Int64) -> Bool = { _, _, _ in false },
    visit: @escaping Visit
  ) {
    let queue = FolderQueue(roots.map { ($0, IgnoreRules.empty) })
    DispatchQueue.concurrentPerform(iterations: threads) { worker in
      var reader = FileReader()
      defer { reader.free() }
      while let (folder, inherited) = queue.take() {
        var more: [(String, IgnoreRules)] = []
        let rules = inherited.adding(folder: folder)
        list(folder) { name, isDirectory in
          if name.first == 0x2E, !isDirectory || !name.elementsEqual(".github".utf8) { return }
          if isDirectory {
            let text = String(decoding: name, as: UTF8.self)
            if skipped.contains(text) || rules.ignores(folder: folder, name: text, isDirectory: true) { return }
            more.append((folder + "/" + text, rules))
            return
          }
          guard wants(name) else { return }
          let text = String(decoding: name, as: UTF8.self)
          if rules.ignores(folder: folder, name: text, isDirectory: false) { return }
          let path = folder + "/" + text
          reader.read(path, isUnchanged: isUnchanged) { bytes, count, modified in
            visit(path, bytes, count, modified, worker)
          }
        }
        queue.finish(adding: more)
      }
    }
  }

  /// Calls `body` for each entry of a folder.
  static func list(_ folder: String, _ body: (UnsafeBufferPointer<UInt8>, Bool) -> Void) {
    #if os(Windows)
      for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: folder + "/" + name, isDirectory: &isDirectory)
        name.utf8CString.withUnsafeBufferPointer { buffer in
          buffer.withMemoryRebound(to: UInt8.self) { bytes in
            body(UnsafeBufferPointer(rebasing: bytes[0..<(bytes.count - 1)]), isDirectory.boolValue)
          }
        }
      }
    #else
      guard let dir = opendir(folder) else { return }
      defer { closedir(dir) }
      while let entry = readdir(dir) {
        let type = entry.pointee.d_type
        var isDirectory = type == DT_DIR
        var isFile = type == DT_REG
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
          pointer.withMemoryRebound(to: UInt8.self, capacity: 256) { name in
            let length = strlen(UnsafeRawPointer(name).assumingMemoryBound(to: CChar.self))
            if type == DT_UNKNOWN || type == DT_LNK {
              // Some file systems don't say, and a link may be to either: ask, without following a folder link.
              var info = stat()
              let path = folder + "/" + String(decoding: UnsafeBufferPointer(start: name, count: length), as: UTF8.self)
              if type == DT_UNKNOWN, lstat(path, &info) == 0 {
                isDirectory = info.st_mode & S_IFMT == S_IFDIR
                isFile = info.st_mode & S_IFMT == S_IFREG
              } else if type == DT_LNK, stat(path, &info) == 0 {
                isFile = info.st_mode & S_IFMT == S_IFREG
              }
            }
            if isDirectory || isFile { body(UnsafeBufferPointer(start: name, count: length), isDirectory) }
          }
        }
      }
    #endif
  }

  /// Reads one file into padded memory, or nil when it isn't there, is too big or holds a NUL early on (binary).
  public static func read(_ path: String) -> [UInt8]? {
    var reader = FileReader()
    defer { reader.free() }
    var result: [UInt8]?
    reader.read(path, isUnchanged: { _, _, _ in false }) { bytes, count, _ in
      result = Array(UnsafeBufferPointer(start: bytes, count: count))
    }
    return result
  }
}

/// A thread's reusable buffer for reading files.
struct FileReader {
  private var buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
  private var capacity = 1 << 20

  func free() { buffer.deallocate() }

  mutating func read(
    _ path: String, isUnchanged: (String, Int, Int64) -> Bool, _ body: (UnsafePointer<UInt8>, Int, Int64) -> Void
  ) {
    #if os(Windows)
      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
      let modified = Int64(((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
      let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
      if isUnchanged(path, size, modified) { return }
      guard size <= FileWalk.largestFile, let data = FileManager.default.contents(atPath: path) else { return }
      guard data.count + scanPadding <= capacity || grow(data.count + scanPadding) else { return }
      data.copyBytes(to: buffer, count: data.count)
      let count = data.count
    #else
      let fd = open(path, O_RDONLY)
      guard fd >= 0 else { return }
      defer { close(fd) }
      var info = stat()
      guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return }
      let size = Int(info.st_size)
      #if canImport(Darwin)
        let modified = Int64(info.st_mtimespec.tv_sec) * 1000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000
      #else
        let modified = Int64(info.st_mtim.tv_sec) * 1000 + Int64(info.st_mtim.tv_nsec) / 1_000_000
      #endif
      if isUnchanged(path, size, modified) { return }
      guard size <= FileWalk.largestFile else { return }
      guard size + scanPadding <= capacity || grow(size + scanPadding) else { return }
      var count = 0
      while count < size {
        #if canImport(Darwin)
          let done = Darwin.read(fd, buffer + count, size - count)
        #else
          let done = Glibc.read(fd, buffer + count, size - count)
        #endif
        if done <= 0 { break }
        count += done
      }
    #endif
    guard count > 0 else {
      // An empty file still counts: it replaces what the index knew.
      buffer.initialize(repeating: 0, count: scanPadding)
      body(buffer, 0, modified)
      return
    }
    // Binary files have a NUL early on: git's own test.
    if memchr(buffer, 0, min(count, 8000)) != nil { return }
    (buffer + count).initialize(repeating: 0, count: scanPadding)
    body(buffer, count, modified)
  }

  private mutating func grow(_ needed: Int) -> Bool {
    buffer.deallocate()
    capacity = needed * 2
    buffer = .allocate(capacity: capacity)
    return true
  }
}

/// Folders handed out to threads; each thread lists one and reads its files.
private final class FolderQueue: @unchecked Sendable {
  private let ready = NSCondition()
  private var folders: [(String, IgnoreRules)]
  private var active = 0

  init(_ roots: [(String, IgnoreRules)]) { folders = roots }

  func take() -> (String, IgnoreRules)? {
    ready.lock()
    defer { ready.unlock() }
    while true {
      if let folder = folders.popLast() {
        active += 1
        return folder
      }
      if active == 0 {
        ready.broadcast()
        return nil
      }
      ready.wait()
    }
  }

  func finish(adding more: [(String, IgnoreRules)]) {
    ready.lock()
    folders += more
    active -= 1
    ready.broadcast()
    ready.unlock()
  }
}

/// What the `.gitignore` files on the way down say. A subset of git's rules that covers what's found in practice:
/// names, `*.ext` and other single-`*` globs, `dir/`, `/anchored` and `a/b`; `!name` re-includes that exact pattern.
final class IgnoreRules: @unchecked Sendable {
  static let empty = IgnoreRules(patterns: [])

  struct Pattern {
    var base: String
    var text: String
    var directoryOnly: Bool
    /// Compared to the path below `base`, not any name.
    var anchored: Bool
    /// `!pattern`: brings back what an earlier line ignored.
    var negated = false
  }

  let patterns: [Pattern]

  init(patterns: [Pattern]) { self.patterns = patterns }

  func adding(folder: String) -> IgnoreRules {
    guard let bytes = FileManager.default.contents(atPath: folder + "/.gitignore") else { return self }
    var patterns = self.patterns
    for line in String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isNewline) {
      var text = String(line).trimmingCharacters(in: .whitespaces)
      if text.isEmpty || text.hasPrefix("#") { continue }
      let negated = text.hasPrefix("!")
      if negated { text.removeFirst() }
      let directoryOnly = text.hasSuffix("/")
      if directoryOnly { text.removeLast() }
      let anchored = text.contains("/")
      if text.hasPrefix("/") { text.removeFirst() }
      if text.hasPrefix("**/") { text.removeFirst(3) }
      patterns.append(Pattern(base: folder, text: text, directoryOnly: directoryOnly, anchored: anchored && !text.hasPrefix("*"), negated: negated))
    }
    return IgnoreRules(patterns: patterns)
  }

  func ignores(folder: String, name: String, isDirectory: Bool) -> Bool {
    // The last line that matches decides.
    for pattern in patterns.reversed() where isDirectory || !pattern.directoryOnly {
      if pattern.anchored {
        let relative = String((folder + "/" + name).dropFirst(pattern.base.count + 1))
        if Self.glob(pattern.text, relative) { return !pattern.negated }
      } else if Self.glob(pattern.text, name) {
        return !pattern.negated
      }
    }
    return false
  }

  /// `*` matches anything but `/`, `?` one character.
  static func glob(_ pattern: String, _ text: String) -> Bool {
    if !pattern.contains("*"), !pattern.contains("?") { return pattern == text }
    let p = Array(pattern.utf8)
    let s = Array(text.utf8)
    var pi = 0
    var si = 0
    var star = -1
    var mark = 0
    while si < s.count {
      if pi < p.count, p[pi] == 0x3F || p[pi] == s[si], p[pi] != 0x2A {
        pi += 1
        si += 1
      } else if pi < p.count, p[pi] == 0x2A {
        star = pi
        mark = si
        pi += 1
      } else if star >= 0, s[mark] != 0x2F {
        pi = star + 1
        mark += 1
        si = mark
      } else {
        return false
      }
    }
    while pi < p.count, p[pi] == 0x2A { pi += 1 }
    return pi == p.count
  }
}
