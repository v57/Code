// swift-tools-version: 6.4

import PackageDescription

let swiftSettings: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency")]

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
///   progress and the build log's issues (macOS).
/// - CodeLSP: language server client (JSON-RPC over stdio) and the servers
///   for each language, installed from their official sources (macOS).
/// - CodeMinimap: Xcode's minimap, drawn as shapes, with marks (AppKit).
/// - CodeFormatting: formatters run before an explicit save (swift-format,
///   prettier, gofmt, …) (macOS).
/// - CodeAutocompletion: Xcode's completion list over the editor, fed by a
///   provider (a language server, or the file's words and the language's
///   keywords), fuzzy matching, snippets as placeholders (AppKit).
/// - CodeKit: all of the above, plus what connects them (an editor for a
///   workspace's documents with language services, issues and breakpoints).
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
  ],
  targets: [
    .target(name: "CodeHighlighting", swiftSettings: swiftSettings),
    .target(name: "CodeWorkspace", dependencies: ["CodeHighlighting"], swiftSettings: swiftSettings),
    .target(name: "CodeEditor", dependencies: ["CodeHighlighting"], swiftSettings: swiftSettings),
    .target(name: "CodeActions", swiftSettings: swiftSettings),
    .target(name: "CodeLSP", swiftSettings: swiftSettings),
    .target(name: "CodeMinimap", dependencies: ["CodeHighlighting"], swiftSettings: swiftSettings),
    .target(name: "CodeFormatting", swiftSettings: swiftSettings),
    .target(
      name: "CodeAutocompletion", dependencies: ["CodeHighlighting", "CodeEditor"],
      swiftSettings: swiftSettings),
    .target(
      name: "CodeKit",
      dependencies: [
        "CodeHighlighting", "CodeWorkspace", "CodeEditor", "CodeActions", "CodeLSP", "CodeMinimap",
        "CodeFormatting", "CodeAutocompletion",
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
    .testTarget(
      name: "CodeFormattingTests", dependencies: ["CodeFormatting"], swiftSettings: swiftSettings),
  ])
