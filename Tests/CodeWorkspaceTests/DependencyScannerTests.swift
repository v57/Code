import Foundation
import Testing

@testable import CodeWorkspace

/// A project folder and a home folder for package caches, removed when the
/// test ends.
private final class Fixture {
  let base: URL
  var root: URL { base.appendingPathComponent("Project") }
  var home: URL { base.appendingPathComponent("Home") }

  init() throws {
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent("DependencyScannerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  deinit { try? FileManager.default.removeItem(at: base) }

  /// Writes a file under the project (or, with "~/", the home folder).
  func file(_ path: String, _ contents: String = "") throws {
    let url =
      path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))) : base.appendingPathComponent(
        "Project/" + path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }

  func scan(_ environment: [String: String] = [:]) -> [PackageDependency] {
    DependencyScanner.scan(root, home: home, environment: environment)
  }
}

private func summary(_ dependencies: [PackageDependency]) -> [String] {
  dependencies.map { "\($0.name) \($0.detail)" }
}

@Suite struct DependencyScannerTests {
  @Test func swiftPackagesAsXcodeListsThem() throws {
    let fixture = try Fixture()
    try fixture.file(
      "Package.swift",
      #"let package = Package(name: "App", dependencies: [.package(path: "../Kit"), .package(url: "x", from: "1.0.0")])"#)
    try fixture.file("../Kit/Package.swift", #"let package = Package(\#n  name: "KitPackage")"#)
    try fixture.file(
      "App.xcodeproj/project.pbxproj",
      """
      A /* XCLocalSwiftPackageReference "." */ = {
        isa = XCLocalSwiftPackageReference;
        relativePath = .;
      };
      """)
    try fixture.file(
      "Package.resolved",
      #"{"pins": [{"identity": "swift-markdown", "location": "https://github.com/apple/swift-markdown.git", "state": {"version": "0.8.0"}}, {"identity": "dev", "location": "https://example.com/Dev", "state": {"branch": "main", "revision": "abcdef123"}}], "version": 3}"#
    )
    try fixture.file(".build/checkouts/swift-markdown/Package.swift")
    let found = fixture.scan()
    #expect(summary(found) == ["App local", "Dev main", "KitPackage local", "swift-markdown 0.8.0"])
    #expect(found.first { $0.name == "swift-markdown" }?.location?.lastPathComponent == "swift-markdown")
    #expect(found.first { $0.name == "Dev" }?.location == nil)
  }

  @Test func xcodeCheckoutsInDerivedData() throws {
    let fixture = try Fixture()
    try fixture.file("App.xcodeproj/project.pbxproj", "")
    try fixture.file(
      "App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
      #"{"object": {"pins": [{"package": "Alamofire", "repositoryURL": "https://github.com/Alamofire/Alamofire.git", "state": {"version": "5.9.0"}}]}, "version": 1}"#
    )
    let derived = "~/Library/Developer/Xcode/DerivedData/App-abc/"
    let plist = try PropertyListSerialization.data(
      fromPropertyList: ["WorkspacePath": fixture.root.appendingPathComponent("App.xcodeproj").path], format: .xml,
      options: 0)
    try fixture.file(derived + "info.plist", String(decoding: plist, as: UTF8.self))
    try fixture.file(derived + "SourcePackages/checkouts/Alamofire/Package.swift")
    let found = fixture.scan()
    #expect(summary(found) == ["Alamofire 5.9.0"])
    #expect(found[0].location?.path.contains("App-abc/SourcePackages/checkouts/Alamofire") == true)
  }

  @Test func nodeRustAndGo() throws {
    let fixture = try Fixture()
    try fixture.file(
      "package.json", #"{"dependencies": {"react": "^18.0.0", "shared": "file:../shared"}, "devDependencies": {"vite": "^5"}}"#)
    try fixture.file("node_modules/react/package.json", #"{"version": "18.3.1"}"#)
    try fixture.file("../shared/package.json", "{}")
    try fixture.file(
      "Cargo.toml",
      """
      [workspace]
      members = ["crates/*"]

      [workspace.dependencies]
      serde = { version = "1", features = ["derive"] }
      """)
    try fixture.file(
      "crates/core/Cargo.toml",
      """
      [dependencies]
      anyhow = "1.0"
      cli = { path = "../cli" }
      local-thing = { path = "../../vendor/local-thing" }

      [dev-dependencies.tempfile]
      version = "3"
      """)
    try fixture.file("crates/cli/Cargo.toml", "[package]\nname = \"cli\"\n")
    try fixture.file("vendor/local-thing/Cargo.toml")
    try fixture.file(
      "Cargo.lock",
      "[[package]]\nname = \"anyhow\"\nversion = \"1.0.86\"\n\n[[package]]\nname = \"serde\"\nversion = \"1.0.200\"\n")
    try fixture.file("~/.cargo/registry/src/index.crates.io-1/anyhow-1.0.86/Cargo.toml")
    try fixture.file(
      "go.mod",
      """
      module example.com/app

      require github.com/BurntSushi/toml v1.3.2
      require (
        golang.org/x/sys v0.22.0 // indirect
        example.com/lib v0.1.0
      )
      replace example.com/lib => ../lib
      """)
    try fixture.file("~/go/pkg/mod/github.com/!burnt!sushi/toml@v1.3.2/go.mod")
    try fixture.file("../lib/go.mod")
    let found = fixture.scan()
    #expect(
      summary(found) == [
        "anyhow 1.0.86", "example.com/lib local", "github.com/BurntSushi/toml v1.3.2", "local-thing local",
        "react 18.3.1", "serde 1.0.200", "shared local", "tempfile 3", "vite ^5",
      ])
    let located = Set(found.filter { $0.location != nil }.map(\.name))
    #expect(
      located == [
        "anyhow", "example.com/lib", "github.com/BurntSushi/toml", "local-thing", "react", "shared",
      ])
  }

  @Test func pythonRubyPhpDart() throws {
    let fixture = try Fixture()
    try fixture.file(
      "pyproject.toml",
      """
      [project]
      name = "app"
      dependencies = [
        "Requests>=2.31",
        "uvloop>=0.22; sys_platform != 'win32'",
      ]

      [project.optional-dependencies]
      dev = ["pytest>=8"]
      """)
    try fixture.file(".venv/lib/python3.12/site-packages/requests-2.32.3.dist-info/top_level.txt", "requests\n")
    try fixture.file(".venv/lib/python3.12/site-packages/requests/__init__.py")
    try fixture.file(
      "Gemfile.lock",
      """
      PATH
        remote: ../gems/tool
        specs:
          tool (0.1.0)

      GEM
        remote: https://rubygems.org/
        specs:
          oj (3.13.23)
          simplecov (0.22.0)
            docile (~> 1.1)

      DEPENDENCIES
        oj (= 3.13.23)
        simplecov (~> 0.22.0)
        tool!
      """)
    try fixture.file("vendor/bundle/ruby/3.3.0/gems/oj-3.13.23/README.md")
    try fixture.file(
      "composer.json", #"{"require": {"php": ">=8.2", "ext-json": "*", "guzzlehttp/guzzle": "^7.8"}}"#)
    try fixture.file("composer.lock", #"{"packages": [{"name": "guzzlehttp/guzzle", "version": "7.8.1"}]}"#)
    try fixture.file("vendor/guzzlehttp/guzzle/composer.json")
    try fixture.file(
      "pubspec.lock",
      """
      packages:
        http:
          dependency: "direct main"
          description:
            name: http
            url: "https://pub.dev"
          source: hosted
          version: "1.2.0"
        meta:
          dependency: transitive
          source: hosted
          version: "1.11.0"
        shared:
          dependency: "direct main"
          description:
            path: "../shared"
            relative: true
          source: path
          version: "0.0.1"
      sdks:
        dart: ">=3.0.0 <4.0.0"
      """)
    try fixture.file("~/.pub-cache/hosted/pub.dev/http-1.2.0/pubspec.yaml")
    let found = fixture.scan()
    #expect(
      summary(found) == [
        "guzzlehttp/guzzle 7.8.1", "http 1.2.0", "oj 3.13.23", "pytest ", "Requests 2.32.3", "shared local",
        "simplecov 0.22.0", "tool local", "uvloop ",
      ])
    let located = Set(found.filter { $0.location != nil }.map(\.name))
    #expect(located == ["guzzlehttp/guzzle", "http", "oj", "Requests"])
  }

  @Test func podsElixirDotnetJava() throws {
    let fixture = try Fixture()
    try fixture.file(
      "Podfile.lock",
      """
      PODS:
        - Alamofire (5.9.0)
        - Firebase/Core (10.0.0):
          - FirebaseCore
        - Local (0.1.0)

      DEPENDENCIES:
        - Alamofire (~> 5.9)
        - Firebase/Core
        - Local (from `../Local`)
      """)
    try fixture.file("Pods/Alamofire/README.md")
    try fixture.file(
      "mix.exs",
      """
      defmodule App.MixProject do
        defp deps do
          [
            {:jason, "~> 1.4"},
            {:tool, path: "../tool"}
          ]
        end
      end
      """)
    try fixture.file("mix.lock", #"%{"jason": {:hex, :jason, "1.4.4", "abc", [:mix], [], "hexpm", "def"}}"#)
    try fixture.file("deps/jason/mix.exs")
    try fixture.file(
      "App.csproj",
      """
      <Project>
        <ItemGroup>
          <PackageReference Include="Newtonsoft.Json" Version="13.0.3" />
          <PackageReference Include="Serilog"><Version>3.1.1</Version></PackageReference>
          <ProjectReference Include="..\\Lib\\Lib.csproj" />
        </ItemGroup>
      </Project>
      """)
    try fixture.file("~/.nuget/packages/newtonsoft.json/13.0.3/README.md")
    try fixture.file(
      "gradle/libs.versions.toml",
      """
      [versions]
      okhttp = "4.12.0"

      [libraries]
      okhttp = { module = "com.squareup.okhttp3:okhttp", version.ref = "okhttp" }
      """)
    try fixture.file("app/build.gradle.kts", #"dependencies { implementation("com.google.code.gson:gson:2.10.1") }"#)
    try fixture.file("~/.gradle/caches/modules-2/files-2.1/com.squareup.okhttp3/okhttp/4.12.0/abc/okhttp.jar")
    let found = fixture.scan()
    #expect(
      summary(found) == [
        "Alamofire 5.9.0", "Firebase 10.0.0", "gson 2.10.1", "jason 1.4.4", "Lib local", "Local local",
        "Newtonsoft.Json 13.0.3", "okhttp 4.12.0", "Serilog 3.1.1", "tool local",
      ])
    let located = Set(found.filter { $0.location != nil }.map(\.name))
    #expect(located == ["Alamofire", "jason", "Newtonsoft.Json", "okhttp"])
  }

  @Test func noManifestsNoDependencies() throws {
    let fixture = try Fixture()
    try fixture.file("README.md")
    #expect(fixture.scan().isEmpty)
    #expect(DependencyScanner.isManifest("Cargo.lock") && DependencyScanner.isManifest("App.csproj"))
    #expect(!DependencyScanner.isManifest("main.swift"))
  }
}
