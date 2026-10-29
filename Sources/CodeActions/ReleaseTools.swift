import Foundation

/// The tools Mac release archives link with (`Release/`): `xcodebuild-release` runs xcodebuild with Swift LTO,
/// `ld-archive-prelink` as the linker (unused package code goes, LLVM's machine outliner runs, and Swift code only
/// Swift's own metadata records kept goes) and `actool-icon-slim` for the icon (its flattened fallbacks as HEVC):
/// apps 35–50% smaller. This is the one copy: Install and Export here, Dev's release.sh (`RELEASE_TOOLS`) and the
/// apps' release scripts (from the `../Code` checkout) all archive through it.
public enum ReleaseTools {
  /// The folder of the tools, inside CodeActions' resources.
  public static var folder: URL? { Bundle.module.url(forResource: "Release", withExtension: nil) }

  /// `xcodebuild-release` in `folder`.
  public static var xcodebuild: URL? { folder?.appendingPathComponent("xcodebuild-release") }

  /// `command`, an `xcodebuild …` command line for a Mac archive, run through `xcodebuild-release`; where the tools
  /// aren't (a command made on another machine), xcodebuild as given.
  static func linked(_ command: String) -> String {
    guard let tool = xcodebuild.map({ shellQuote($0.path) }), command.hasPrefix("xcodebuild ") else { return command }
    let arguments = command.dropFirst("xcodebuild ".count)
    return "if [ -x \(tool) ]; then \(tool) \(arguments); else xcodebuild \(arguments); fi"
  }
}
