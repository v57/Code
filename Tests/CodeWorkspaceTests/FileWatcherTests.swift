#if os(macOS) || os(Linux)
  import Foundation
  import Testing

  @testable import CodeWorkspace

  /// FileWatcher on the platform's file events (FSEvents, inotify): a new file in a new folder comes through as a
  /// structural change, an edit as a change of the file.
  @MainActor struct FileWatcherTests {
    final class Seen: @unchecked Sendable {
      var changes: [FileWatcher.Change] = []
    }

    func wait(until condition: () -> Bool) async {
      for _ in 0..<100 where !condition() { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    @Test func reportsNewFilesAndEdits() async throws {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("Watch-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let seen = Seen()
      let watcher = FileWatcher(root: root, latency: 0.05) { seen.changes += $0 }
      try await Task.sleep(nanoseconds: 300_000_000)

      let folder = root.appendingPathComponent("Sources")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try await Task.sleep(nanoseconds: 200_000_000)
      let file = folder.appendingPathComponent("A.swift")
      try "let a = 1\n".write(to: file, atomically: false, encoding: .utf8)
      await wait { seen.changes.contains { $0.url.resolvingSymlinksInPath().path == file.path && $0.structural } }
      #expect(seen.changes.contains { $0.url.resolvingSymlinksInPath().path == file.path && $0.structural })

      seen.changes = []
      let handle = try FileHandle(forWritingTo: file)
      handle.seekToEndOfFile()
      handle.write(Data("let b = 2\n".utf8))
      try handle.close()
      await wait { seen.changes.contains { $0.url.resolvingSymlinksInPath().path == file.path } }
      #expect(seen.changes.contains { $0.url.resolvingSymlinksInPath().path == file.path })
      _ = watcher
    }
  }
#endif
