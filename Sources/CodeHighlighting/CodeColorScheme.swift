import Foundation

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// A code color scheme: one `UInt32` sRGB hex value (0xRRGGBB) per
/// Xcode-style syntax category. Platform-neutral — the platform layer
/// converts hex values to `NSColor`/`UIColor` as needed.
///
/// Defaults are GitHub's official Light / Dark code themes (primer
/// github-syntax-theme-generator, lib/themes/light.json and dark.json — the
/// classic editor palette that powers github.com code rendering).
public struct CodeColorScheme: Equatable, Sendable {
  public var plainText: UInt32
  public var comment: UInt32
  public var prose: UInt32
  public var keyword: UInt32
  public var string: UInt32
  public var number: UInt32
  public var link: UInt32
  public var preprocessor: UInt32
  public var typeDeclaration: UInt32
  public var memberDeclaration: UInt32
  public var projectType: UInt32
  public var projectMember: UInt32
  public var otherType: UInt32
  public var otherMember: UInt32
  public var attribute: UInt32

  public init(
    plainText: UInt32, comment: UInt32, prose: UInt32, keyword: UInt32, string: UInt32,
    number: UInt32, link: UInt32, preprocessor: UInt32, typeDeclaration: UInt32,
    memberDeclaration: UInt32, projectType: UInt32, projectMember: UInt32, otherType: UInt32,
    otherMember: UInt32, attribute: UInt32? = nil
  ) {
    self.plainText = plainText
    self.comment = comment
    self.prose = prose
    self.keyword = keyword
    self.string = string
    self.number = number
    self.link = link
    self.preprocessor = preprocessor
    self.typeDeclaration = typeDeclaration
    self.memberDeclaration = memberDeclaration
    self.projectType = projectType
    self.projectMember = projectMember
    self.otherType = otherType
    self.otherMember = otherMember
    // Schemes without an attribute color color attributes as preprocessor.
    self.attribute = attribute ?? preprocessor
  }

  public func color(for kind: SyntaxKind) -> UInt32 {
    switch kind {
    case .plainText: return plainText
    case .comment: return comment
    case .prose: return prose
    case .keyword: return keyword
    case .string: return string
    case .number: return number
    case .link: return link
    case .preprocessor: return preprocessor
    case .typeDeclaration: return typeDeclaration
    case .memberDeclaration: return memberDeclaration
    case .projectType: return projectType
    case .projectMember: return projectMember
    case .otherType: return otherType
    case .otherMember: return otherMember
    case .attribute: return attribute
    }
  }

  // MARK: - GitHub default schemes

  /// GitHub Light code theme (primer lib/themes/light.json).
  /// Plain #24292e · Comment #6a737d · Keyword #d73a49 · String #032f62 ·
  /// Constant (numbers) #005cc5 · Entity (types) #6f42c1 · Variable #e36209 ·
  /// Link #032f62 · Preprocessor (keyword) #d73a49.
  public static let githubLight = CodeColorScheme(
    plainText: 0x24292E, comment: 0x6A737D, prose: 0x24292E, keyword: 0xD73A49, string: 0x032F62,
    number: 0x005CC5, link: 0x032F62, preprocessor: 0xD73A49, typeDeclaration: 0x6F42C1,
    memberDeclaration: 0x6F42C1, projectType: 0x6F42C1, projectMember: 0xE36209,
    otherType: 0x6F42C1, otherMember: 0xE36209)

  /// GitHub Dark code theme (primer lib/themes/dark.json).
  /// Plain #f6f8fa · Comment #959da5 · Keyword #ea4a5a · String #79b8ff ·
  /// Constant (numbers) #c8e1ff · Entity (types) #b392f0 · Variable #fb8532 ·
  /// Link #79b8ff · Preprocessor (keyword) #ea4a5a.
  public static let githubDark = CodeColorScheme(
    plainText: 0xF6F8FA, comment: 0x959DA5, prose: 0xF6F8FA, keyword: 0xEA4A5A, string: 0x79B8FF,
    number: 0xC8E1FF, link: 0x79B8FF, preprocessor: 0xEA4A5A, typeDeclaration: 0xB392F0,
    memberDeclaration: 0xB392F0, projectType: 0xB392F0, projectMember: 0xFB8532,
    otherType: 0xB392F0, otherMember: 0xFB8532)

  /// Resolves the scheme from the caller-provided dark-mode state: dark →
  /// GitHub Dark, otherwise GitHub Light. Platform-neutral; each platform
  /// determines `isDark` from its own appearance/trait API.
  public static func systemAware(isDark: Bool) -> CodeColorScheme {
    isDark ? .githubDark : .githubLight
  }

  /// Resolves the scheme from the current platform's appearance: dark →
  /// GitHub Dark, otherwise GitHub Light. Resolved afresh on every parse, so
  /// an appearance switch re-applies the matching palette on the next restyle.
  /// Uses `NSAppearance.currentDrawing()` (not `NSApp.effectiveAppearance`)
  /// so the scheme can be resolved from a nonisolated context on macOS.
  public static var systemAware: CodeColorScheme {
    #if canImport(AppKit)
      let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      return systemAware(isDark: isDark)
    #elseif canImport(UIKit)
      let isDark = UITraitCollection.current.userInterfaceStyle == .dark
      return systemAware(isDark: isDark)
    #else
      return systemAware(isDark: false)
    #endif
  }
}
