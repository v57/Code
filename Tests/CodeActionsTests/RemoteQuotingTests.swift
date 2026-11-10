import Foundation
import Testing

@testable import CodeActions

#if os(macOS)
  /// Security audit L9 and L14: what goes to another machine's shell is quoted for POSIX shells whatever this computer
  /// runs, a folder there with quotes or `$` stays one word, and the automatic `git status` runs no repository command.
  @Suite struct RemoteQuotingTests {
    @Test func posixQuotingKeepsEverythingLiteral() throws {
      for text in ["plain/path", "a b", "it's", "$(touch x)", "`id`", "a\"b", "", "\\n"] {
        let output = try run("printf '%s' \(posixShellQuote(text))")
        #expect(output == text)
      }
    }

    @Test func aFolderThereWithQuotesStaysOneWord() throws {
      let base = FileManager.default.temporaryDirectory.appendingPathComponent("Remote-\(UUID().uuidString)")
      let there = base.appendingPathComponent("it's a \"$(touch pwned)\" dir")
      try FileManager.default.createDirectory(at: there.appendingPathComponent("App"), withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: base) }
      let executor = SSHExecutor(
        target: .init(id: "studio", name: "Mac Studio", host: "h", directory: there.path),
        localRoot: URL(fileURLWithPath: "/Users/other/Atlas"))
      let command = #"printf '%s\n' '/Users/other/Atlas/a b' /Users/other/Atlas/c "/Users/other/Atlas/d" "$PWD""#
      let script = executor.remoteScript(command, directory: URL(fileURLWithPath: "/Users/other/Atlas/App"))
      let output = try run(script)
      #expect(output == [there.path + "/a b", there.path + "/c", there.path + "/d", there.path + "/App"]
        .joined(separator: "\n"))
      #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("pwned").path))
      #expect(!FileManager.default.fileExists(atPath: there.appendingPathComponent("App/pwned").path))
      // The whole command for `ssh`, as the login shell there gets it.
      #expect(executor.remoteCommand("true", directory: URL(fileURLWithPath: "/Users/other/Atlas")).hasPrefix(
        "exec \"$SHELL\" -lc 'CODE_ROOT="))
    }

    @Test func automaticGitStatusRunsNoFSMonitor() throws {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FSMonitor-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let marker = folder.appendingPathComponent("ran")
      let hook = folder.appendingPathComponent("monitor.sh")
      try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: hook)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
      _ = try run("cd '\(folder.path)' && git init -q && echo a > a && git add a && git -c user.name=t -c user.email=t@t commit -qm a && git config core.fsmonitor '\(hook.path)'")
      try "b\n".write(to: folder.appendingPathComponent("a"), atomically: true, encoding: .utf8)
      #expect(SourceFingerprint.folder(folder).isDirty)
      #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    private func run(_ script: String) throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = ["-c", script]
      let pipe = Pipe()
      process.standardOutput = pipe
      try process.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      var text = String(decoding: data, as: UTF8.self)
      if text.hasSuffix("\n") { text.removeLast() }
      return text
    }
  }
#endif
