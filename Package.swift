// swift-tools-version: 6.4

import PackageDescription

let swiftSettings: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency")]

/// Another v57 repository: GitHub's main branch, or the checkout next to this one with `V57_LOCAL=1`.
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../\(name)")
}

/// CodeKit is split into libraries a project can take one at a time:
///
/// - CodeHighlighting: languages, the incremental syntax highlighter, themes
///   (platform-neutral, no dependencies; what Git's diffs and Md's fenced code need).
/// - CodeWorkspace: project folders — file tree, watching, Quick Open index,
///   text documents with autosave, tabs and sessions (platform-neutral).
/// - CodeEditor: the AppKit code editor view (text in, text out).
/// - CodeActions: Xcode-style schemes found in a project folder (Xcode,
///   SwiftPM, Cargo, Go, Gradle/Android, Node, Python, …), run destinations
///   (Mac, simulators, devices, Android), and running build/run/test with
///   progress and the build log's issues (macOS), or on another machine
///   over SSH (SSHKit's in-process client on iPhone and iPad).
/// - CodeProgress: progress of operations made of stages (builds, downloads
///   and installs, batches), estimated from how long each stage took before,
///   by the resource it waits on and the size of its work (platform-neutral).
/// - CodeLSP: language server client (JSON-RPC over stdio) and the servers
///   for each language, installed from their official sources (macOS).
/// - CodeMinimap: Xcode's minimap, drawn as shapes, with marks (AppKit).
/// - CodeFormatting: formatters run before an explicit save (swift-format,
///   prettier, gofmt, …) (macOS).
/// - CodeAutocompletion: Xcode's completion list over the editor, fed by a
///   provider (a language server, or the file's words and the language's
///   keywords), fuzzy matching, snippets as placeholders (AppKit).
/// - CodeIcons: file icons for languages, data and project files: an SF
///   Symbol, else one to three letters in the language's color (SwiftUI,
///   platform-neutral).
/// - CodeKit: all of the above, plus what connects them (an editor for a
///   workspace's documents with language services, issues and breakpoints).
///
/// The apps are the package in App/ (App/Package.swift), so the libraries carry none of their dependencies.
let package = Package(
  name: "Code",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(name: "CodeKit", targets: ["CodeKit"]),
    .library(name: "CodeHighlighting", targets: ["CodeHighlighting"]),
    .library(name: "CodeWorkspace", targets: ["CodeWorkspace"]),
    .library(name: "CodeEditor", targets: ["CodeEditor"]),
    .library(name: "CodeActions", targets: ["CodeActions"]),
    .library(name: "CodeLSP", targets: ["CodeLSP"]),
    .library(name: "CodeMinimap", targets: ["CodeMinimap"]),
    .library(name: "CodeFormatting", targets: ["CodeFormatting"]),
    .library(name: "CodeAutocompletion", targets: ["CodeAutocompletion"]),
    .library(name: "CodeIcons", targets: ["CodeIcons"]),
    .library(name: "CodeProgress", targets: ["CodeProgress"]),
  ],
  // SSHKit: remote actions over SSH, in-process (../SSH).
  dependencies: [v57("SSH")],
  targets: [
    .target(name: "CodeHighlighting", swiftSettings: swiftSettings),
    .target(name: "CodeWorkspace", dependencies: ["CodeHighlighting"], swiftSettings: swiftSettings),
    .target(name: "CodeEditor", dependencies: ["CodeHighlighting"], swiftSettings: swiftSettings),
    .target(name: "CodeProgress", swiftSettings: swiftSettings),
    .target(
      name: "CodeActions", dependencies: ["CodeProgress", .product(name: "SSHKit", package: "SSH")],
      // Release/: the linker and asset catalog compiler Install archives Mac apps with (copies of Dev's).
      resources: [.copy("Release")], swiftSettings: swiftSettings),
    .target(name: "CodeLSP", swiftSettings: swiftSettings),
    .target(name: "CodeMinimap", dependencies: ["CodeHighlighting"], swiftSettings: swiftSettings),
    .target(name: "CodeFormatting", swiftSettings: swiftSettings),
    .target(name: "CodeIcons", swiftSettings: swiftSettings),
    .target(
      name: "CodeAutocompletion", dependencies: ["CodeHighlighting", "CodeEditor"],
      swiftSettings: swiftSettings),
    .target(
      name: "CodeKit",
      dependencies: [
        "CodeHighlighting", "CodeWorkspace", "CodeEditor", "CodeActions", "CodeLSP", "CodeMinimap",
        "CodeFormatting", "CodeAutocompletion", "CodeIcons", "CodeProgress",
      ],
      swiftSettings: swiftSettings),

    .testTarget(
      name: "CodeHighlightingTests", dependencies: ["CodeHighlighting"],
      swiftSettings: swiftSettings),
    .testTarget(
      name: "CodeWorkspaceTests", dependencies: ["CodeWorkspace"], swiftSettings: swiftSettings),
    .testTarget(name: "CodeEditorTests", dependencies: ["CodeEditor"], swiftSettings: swiftSettings),
    .testTarget(name: "CodeKitTests", dependencies: ["CodeKit"], swiftSettings: swiftSettings),
    .testTarget(
      name: "CodeActionsTests", dependencies: ["CodeActions"], swiftSettings: swiftSettings),
    .testTarget(name: "CodeLSPTests", dependencies: ["CodeLSP"], swiftSettings: swiftSettings),
    .testTarget(
      name: "CodeAutocompletionTests", dependencies: ["CodeAutocompletion"],
      swiftSettings: swiftSettings),
    .testTarget(name: "CodeIconsTests", dependencies: ["CodeIcons"], swiftSettings: swiftSettings),
    .testTarget(
      name: "CodeProgressTests", dependencies: ["CodeProgress"], swiftSettings: swiftSettings),
    .testTarget(
      name: "CodeFormattingTests", dependencies: ["CodeFormatting"], swiftSettings: swiftSettings),
  ])

#if os(Windows) || os(Linux)
// Off Apple platforms SwiftUI, CryptoKit and os are v57/SwiftUI's, and SwiftUIPortability adds the Foundation APIs
// swift-corelibs-foundation lacks.
package.dependencies += [v57("SwiftUI")]
for target in package.targets where target.type == .regular {
  target.dependencies += [
    .product(name: "SwiftUIPortability", package: "SwiftUI"), .product(name: "os", package: "SwiftUI"),
    .product(name: "CryptoKit", package: "SwiftUI"),
  ]
  if ["CodeIcons", "CodeKit"].contains(target.name) {
    target.dependencies += [.product(name: "SwiftUI", package: "SwiftUI")]
  }
}
#endif
