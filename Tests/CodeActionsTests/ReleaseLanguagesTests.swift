import CryptoKit
import Foundation
import Testing

@testable import CodeActions

#if os(macOS)
  /// `Release/release-languages`: a release takes v57/Localizations at the commit release.env pins, never a branch or
  /// a checkout's working tree, and a manifest can't name paths outside the app's `.lproj` folders
  /// (Ideas/Security/supply-chain.md M5).
  @Suite(.serialized) struct ReleaseLanguagesTests {
    /// A v57/Localizations repository and an unsigned app, in a temporary folder.
    final class Fixture {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReleaseLanguages-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
      var localizations: URL { root.appendingPathComponent("Localizations") }
      var app: URL { root.appendingPathComponent("App.app") }
      var resources: URL { app.appendingPathComponent("Contents/Resources") }

      init() throws {
        try FileManager.default.createDirectory(at: localizations, withIntermediateDirectories: true)
        try git("init", "-q")
        try write(resources.appendingPathComponent("en.lproj/Localizable.strings"), "\"Open\" = \"Open\";\n")
        let info: [String: Any] = ["CFBundleDevelopmentRegion": "en", "CFBundleIdentifier": "dev.v57.test"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
          .write(to: app.appendingPathComponent("Contents/Info.plist"))
      }

      deinit { try? FileManager.default.removeItem(at: root) }

      func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
      }

      /// `App/<language>.lproj/<name>` in the repository's working tree.
      func translation(_ language: String, _ text: String, name: String = "Localizable.strings") throws {
        try write(localizations.appendingPathComponent("App/\(language).lproj/\(name)"), text)
      }

      /// manifest.json for `entries` (language → name → the file's path in the repository).
      func manifest(_ entries: [String: [String: String]]) throws {
        var languages: [String: [String: [String: Any]]] = [:]
        for (language, files) in entries {
          for (name, path) in files {
            let data = try Data(contentsOf: localizations.appendingPathComponent(path))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            languages[language, default: [:]][name] = ["bytes": data.count, "sha256": hash]
          }
        }
        let manifest: [String: Any] = ["version": 1, "sources": ["App": languages]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: localizations.appendingPathComponent("manifest.json"))
      }

      /// Commits everything and answers the commit.
      func commit(_ message: String) throws -> String {
        try git("add", "-A")
        try git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", message)
        return try git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
      }

      @discardableResult
      func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", localizations.path] + arguments
        process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
      }

      /// Runs release-languages on the app with the sources "App" and German bundled; its exit status and log.
      func run(ref: String?) throws -> (status: Int32, log: String) {
        let tool = try #require(ReleaseTools.folder).appendingPathComponent("release-languages")
        let process = Process()
        process.executableURL = tool
        process.arguments = ["--sources", "App", "--bundled", "de", "--project-dir", root.path, app.path]
        var environment = ["PATH": "/usr/bin:/bin", "V57_LOCALIZATIONS_URL": localizations.path]
        environment["V57_LOCALIZATIONS_REF"] = ref
        process.environment = environment
        let log = Pipe()
        process.standardError = log
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = log.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
      }

      var info: [String: Any] {
        get throws {
          let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
          return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
        }
      }

      func bundled(_ language: String) throws -> [String: String] {
        let data = try Data(contentsOf: resources.appendingPathComponent("\(language).lproj/Localizable.strings"))
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] ?? [:]
      }
    }

    @Test func aReleaseTakesThePinnedCommitOnly() throws {
      let fixture = try Fixture()
      try fixture.translation("de", "\"Open\" = \"Öffnen\";\n")
      try fixture.translation("nl", "\"Open\" = \"Openen\";\n")
      let files = ["Localizable.strings": "App/de.lproj/Localizable.strings"]
      try fixture.manifest(["de": files, "nl": ["Localizable.strings": "App/nl.lproj/Localizable.strings"]])
      let pinned = try fixture.commit("Translations")
      let manifest = try Data(contentsOf: fixture.localizations.appendingPathComponent("manifest.json"))
      // A later commit and an uncommitted change are not what the release pinned.
      try fixture.translation("de", "\"Open\" = \"Später\";\n")
      try fixture.manifest(["de": files])
      _ = try fixture.commit("Later")
      try fixture.translation("de", "\"Open\" = \"Uncommitted\";\n")

      let result = try fixture.run(ref: pinned)
      #expect(result.status == 0, "\(result.log)")
      #expect(result.log.contains("at \(pinned)"))
      #expect(try fixture.bundled("de")["Open"] == "Öffnen")
      // The app downloads its other languages from the same commit and checks the manifest it finds there.
      let info = try fixture.info
      #expect(info["V57LocalizationsCommit"] as? String == pinned)
      let hash = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
      #expect(info["V57LocalizationsManifest"] as? String == hash)
      #expect((info["V57Languages"] as? [String: Int])?.keys.sorted() == ["nl"])
    }

    @Test func aReleaseWithSourcesNeedsACommit() throws {
      let fixture = try Fixture()
      try fixture.translation("de", "\"Open\" = \"Öffnen\";\n")
      try fixture.manifest(["de": ["Localizable.strings": "App/de.lproj/Localizable.strings"]])
      _ = try fixture.commit("Translations")
      for ref in [nil, "main", "HEAD", "1b125e0"] {
        let result = try fixture.run(ref: ref)
        #expect(result.status != 0, "\(ref ?? "no ref") was taken")
        #expect(result.log.contains("LOCALIZATIONS_REF"))
      }
      #expect(!FileManager.default.fileExists(atPath: fixture.resources.appendingPathComponent("de.lproj").path))
    }

    @Test func aManifestCantNamePathsOutsideTheLanguageFolders() throws {
      let fixture = try Fixture()
      try fixture.translation("de", "\"Open\" = \"Öffnen\";\n")
      // A file the manifest describes correctly, under a name that climbs out of de.lproj, and a language that does.
      try fixture.write(fixture.localizations.appendingPathComponent("App/x.strings"), "\"Open\" = \"Pwned\";\n")
      try fixture.write(fixture.localizations.appendingPathComponent("App/../evil.lproj/Localizable.strings"), "\"Open\" = \"Pwned\";\n")
      for entries in [
        ["de": ["Localizable.strings": "App/de.lproj/Localizable.strings", "../x.strings": "App/x.strings"]],
        ["de": ["Localizable.strings": "App/de.lproj/Localizable.strings"],
         "../../evil": ["Localizable.strings": "evil.lproj/Localizable.strings"]],
        ["de": ["Info.plist": "App/de.lproj/Localizable.strings"]],
      ] {
        try fixture.manifest(entries)
        let result = try fixture.run(ref: try fixture.commit("Manifest"))
        #expect(result.status != 0, "\(entries) was taken")
        #expect(result.log.contains("manifest.json"))
      }
      let written = try FileManager.default.subpathsOfDirectory(atPath: fixture.app.path)
      #expect(written.sorted() == ["Contents", "Contents/Info.plist", "Contents/Resources", "Contents/Resources/en.lproj",
        "Contents/Resources/en.lproj/Localizable.strings"])
      #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("evil.lproj").path))
    }
  }
#endif
