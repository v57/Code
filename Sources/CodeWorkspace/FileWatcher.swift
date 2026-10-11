import Foundation

#if os(macOS)
  import CoreServices
#endif

/// Watches a folder tree for changes with FSEvents and reports them on the
/// main queue, batched (`latency`) so a `git checkout` arrives as a few
/// callbacks rather than thousands. A no-op where FSEvents does not exist.
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
  #endif

  public init(root: URL, latency: TimeInterval = 0.3, handler: @escaping @MainActor ([Change]) -> Void)
  {
    self.root = root
    self.handler = handler
    #if os(macOS)
      start(latency: latency)
    #endif
  }

  deinit {
    #if os(macOS)
      if let stream {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
      }
    #endif
  }

  #if os(macOS)
    private func start(latency: TimeInterval) {
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
        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
          | kFSEventStreamCreateFlagWatchRoot)
      guard
        let stream = FSEventStreamCreate(
          nil, callback, &context, [root.path] as CFArray,
          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
      else { return }
      FSEventStreamSetDispatchQueue(stream, .main)
      FSEventStreamStart(stream)
      self.stream = stream
    }
  #endif
}
