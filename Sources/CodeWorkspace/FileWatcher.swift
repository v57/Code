import Foundation

#if os(macOS)
  import CoreServices
#elseif os(Windows)
  import WinSDK
#elseif os(Linux)
  import SwiftUIPortability
#endif

/// Watches a folder tree for changes with FSEvents (ReadDirectoryChangesW on
/// Windows, inotify on Linux) and reports them on the main queue, batched
/// (`latency`) so a `git checkout` arrives as a few callbacks rather than
/// thousands. Without `fileEvents`, a change is the folder whose items changed:
/// far fewer events in a busy tree. A no-op elsewhere.
public final class FileWatcher: @unchecked Sendable {
  /// One changed path. `structural` is true when an item was created, removed
  /// or renamed (the tree and Quick Open index need a re-read), false for a
  /// content change.
  public struct Change: Sendable {
    public let url: URL
    public let structural: Bool
    /// FSEvents dropped events under this path: re-read all of it.
    public let rescan: Bool
  }

  private let root: URL
  private let handler: @MainActor ([Change]) -> Void
  #if os(macOS)
    private var stream: FSEventStreamRef?
  #elseif os(Windows)
    private var reader: DirectoryReader?
  #elseif os(Linux)
    private var watcher: DirectoryWatcher?
  #endif

  public init(
    root: URL, latency: TimeInterval = 0.3, fileEvents: Bool = true,
    handler: @escaping @MainActor ([Change]) -> Void
  ) {
    self.root = root
    self.handler = handler
    #if os(macOS) || os(Windows) || os(Linux)
      start(latency: latency, fileEvents: fileEvents)
    #endif
  }

  deinit {
    #if os(macOS)
      if let stream {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
      }
    #elseif os(Windows)
      reader?.close()
    #elseif os(Linux)
      watcher?.stop()
    #endif
  }

  #if os(macOS)
    private func start(latency: TimeInterval, fileEvents: Bool) {
      var context = FSEventStreamContext(
        version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
        copyDescription: nil)
      let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        var changes: [Change] = []
        for i in 0..<min(count, paths.count) {
          let flag = Int(flags[i])
          let structural =
            flag
            & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
              | kFSEventStreamEventFlagItemRenamed) != 0
          let rescan =
            flag
            & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
          changes.append(
            Change(url: URL(fileURLWithPath: paths[i]), structural: structural, rescan: rescan))
        }
        MainActor.assumeIsolated { watcher.handler(changes) }
      }
      let flags = FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
          | (fileEvents ? kFSEventStreamCreateFlagFileEvents : 0))
      guard
        let stream = FSEventStreamCreate(
          nil, callback, &context, [root.path] as CFArray,
          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
      else { return }
      FSEventStreamSetDispatchQueue(stream, .main)
      FSEventStreamStart(stream)
      self.stream = stream
    }
  #elseif os(Windows)
    /// A thread reads the tree's changes (blocking) and hands them to the main queue after `latency`, gathered.
    private final class DirectoryReader: @unchecked Sendable {
      private let handle: HANDLE
      private let lock = NSLock()
      private var pending: [Change] = []
      private var flushScheduled = false
      private var closed = false

      init?(root: URL) {
        let opened = root.path.withCString(encodedAs: UTF16.self) {
          CreateFileW(
            $0, DWORD(FILE_LIST_DIRECTORY), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
            DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        guard let opened, opened != INVALID_HANDLE_VALUE else { return nil }
        handle = opened
      }

      func run(root: URL, latency: TimeInterval, fileEvents: Bool, deliver: @escaping @Sendable ([Change]) -> Void) {
        var filter = FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME
        if fileEvents { filter |= FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_SIZE }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
          var returned: DWORD = 0
          let ok = buffer.withUnsafeMutableBytes { raw in
            ReadDirectoryChangesW(handle, raw.baseAddress, DWORD(raw.count), true, DWORD(filter), &returned, nil, nil)
          }
          guard ok, !lock.withLock({ closed }) else { return }
          var changes: [Change] = []
          if returned == 0 {
            // The buffer overflowed: everything may have changed.
            changes.append(Change(url: root, structural: true, rescan: true))
          } else {
            buffer.withUnsafeBytes { raw in
              var offset = 0
              while true {
                let next = Int(raw.load(fromByteOffset: offset, as: DWORD.self))
                let action = Int32(raw.load(fromByteOffset: offset + 4, as: DWORD.self))
                let length = Int(raw.load(fromByteOffset: offset + 8, as: DWORD.self))
                let name = raw.baseAddress!.advanced(by: offset + 12).assumingMemoryBound(to: UInt16.self)
                let relative = String(decoding: UnsafeBufferPointer(start: name, count: length / 2), as: UTF16.self)
                var url = root.appendingPathComponent(relative.replacingOccurrences(of: "\\", with: "/"))
                // Without file events a change is its folder, as FSEvents reports it.
                if !fileEvents { url = url.deletingLastPathComponent() }
                let structural = action != FILE_ACTION_MODIFIED
                changes.append(Change(url: url, structural: structural, rescan: false))
                if next == 0 { break }
                offset += next
              }
            }
          }
          let flush: Bool = lock.withLock {
            pending += changes
            guard !flushScheduled else { return false }
            flushScheduled = true
            return true
          }
          if flush {
            DispatchQueue.global().asyncAfter(deadline: .now() + latency) { [self] in
              let batch: [Change] = lock.withLock {
                flushScheduled = false
                defer { pending = [] }
                return pending
              }
              if !batch.isEmpty { deliver(batch) }
            }
          }
        }
      }

      func close() {
        lock.withLock { closed = true }
        CancelIoEx(handle, nil)
        CloseHandle(handle)
      }
    }

    private func start(latency: TimeInterval, fileEvents: Bool) {
      guard let reader = DirectoryReader(root: root) else { return }
      self.reader = reader
      let root = self.root
      let handler = self.handler
      let thread = Thread {
        reader.run(root: root, latency: latency, fileEvents: fileEvents) { changes in
          DispatchQueue.main.async { MainActor.assumeIsolated { handler(changes) } }
        }
      }
      thread.name = "CodeWorkspace.FileWatcher"
      thread.start()
    }
  #elseif os(Linux)
    private func start(latency: TimeInterval, fileEvents: Bool) {
      let handler = self.handler
      watcher = DirectoryWatcher(paths: [root.path], fileEvents: fileEvents, latency: latency, queue: .main) { changes in
        let mapped = changes.map {
          Change(url: URL(fileURLWithPath: $0.path), structural: $0.structural, rescan: $0.rescan)
        }
        MainActor.assumeIsolated { handler(mapped) }
      }
    }
  #endif
}
