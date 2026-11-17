import CodeFolders
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
    let queue = FolderQueue(roots.map { ($0, IgnoreRules.outer(of: $0)) })
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
            if skipped.contains(text) || rules.ignores(folder: folder, name: name, isDirectory: true) { return }
            more.append((folder + "/" + text, rules))
            return
          }
          guard wants(name), !rules.ignores(folder: folder, name: name, isDirectory: false) else { return }
          let path = folder + "/" + String(decoding: name, as: UTF8.self)
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

/// What the `.gitignore` files say about a walk's entries: those above its root up to the repository's (and
/// `.git/info/exclude`), then those on the way down. Matched by CodeFolders' `GitIgnore.Rule`, the matcher Quick Open's
/// file list uses (git's wildmatch: `*`, `?`, `**`, classes, escapes), with git's precedence: the deepest file first,
/// in it the last line that matches; `!` brings back what a shallower line ignored.
final class IgnoreRules: @unchecked Sendable {
  static let empty = IgnoreRules(sets: [])

  struct RuleSet {
    /// The folder whose entries' paths the rules see below it (an outer set's: the walk's root).
    var base: String
    /// Put before that path: from the `.gitignore`'s folder to `base` ("Code/" one folder up), "" for one inside.
    var prefix: String
    var rules: [GitIgnore.Rule]
  }

  /// Shallowest first.
  let sets: [RuleSet]

  init(sets: [RuleSet]) { self.sets = sets }

  /// The rules from above a walk's root.
  static func outer(of root: String) -> IgnoreRules {
    let sets = GitIgnore.outerRules(of: URL(fileURLWithPath: root)).map { RuleSet(base: root, prefix: $0.prefix, rules: $0.rules) }
    return sets.isEmpty ? empty : IgnoreRules(sets: sets)
  }

  func adding(folder: String) -> IgnoreRules {
    guard let bytes = FileManager.default.contents(atPath: folder + "/.gitignore") else { return self }
    let rules = GitIgnore.rules(in: String(decoding: bytes, as: UTF8.self))
    if rules.isEmpty { return self }
    return IgnoreRules(sets: sets + [RuleSet(base: folder, prefix: "", rules: rules)])
  }

  func ignores(folder: String, name: UnsafeBufferPointer<UInt8>, isDirectory: Bool) -> Bool {
    for set in sets.reversed() {
      var relative: [UInt8]?
      for rule in set.rules.reversed() where isDirectory || !rule.isDirectoryOnly {
        let matched: Bool
        if rule.isAnchored {
          if relative == nil { relative = Self.path(below: set, folder: folder, name: name) }
          matched = relative!.withUnsafeBufferPointer { rule.matches($0) }
        } else {
          matched = rule.matches(name)
        }
        if matched { return !rule.isNegated }
      }
    }
    return false
  }

  /// An entry's path as a set's rules see it: the prefix, then the path below the set's base.
  private static func path(below set: RuleSet, folder: String, name: UnsafeBufferPointer<UInt8>) -> [UInt8] {
    var path = Array(set.prefix.utf8)
    if folder.utf8.count > set.base.utf8.count {
      path += folder.utf8.dropFirst(set.base.utf8.count + 1)
      path.append(0x2F)
    }
    path += name
    return path
  }
}
