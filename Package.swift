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
/// - CodeKit: all of the above, plus what connects them (an editor for a
///   workspace's documents). Future libraries (language servers, navigation,
///   linting) join the same way.
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
  ],
  targets: [
    .target(name: "CodeHighlighting", swiftSettings: swiftSettings),
    .target(name: "CodeWorkspace", dependencies: ["CodeHighlighting"], swiftSettings: swiftSettings),
    .target(name: "CodeEditor", dependencies: ["CodeHighlighting"], swiftSettings: swiftSettings),
    .target(
      name: "CodeKit", dependencies: ["CodeHighlighting", "CodeWorkspace", "CodeEditor"],
      swiftSettings: swiftSettings),

    .testTarget(
      name: "CodeHighlightingTests", dependencies: ["CodeHighlighting"],
      swiftSettings: swiftSettings),
    .testTarget(
      name: "CodeWorkspaceTests", dependencies: ["CodeWorkspace"], swiftSettings: swiftSettings),
    .testTarget(name: "CodeEditorTests", dependencies: ["CodeEditor"], swiftSettings: swiftSettings),
    .testTarget(name: "CodeKitTests", dependencies: ["CodeKit"], swiftSettings: swiftSettings),
  ])
