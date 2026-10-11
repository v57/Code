import Foundation

/// Colors and fonts for a whole editor: the syntax palette, the chrome around
/// the text (background, current line, gutter, selection), the font of each
/// syntax kind and the line spacing. Hex 0xRRGGBB values, platform-neutral
/// like `CodeColorScheme`.
public struct EditorTheme: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let isDark: Bool
  public let syntax: CodeColorScheme
  public let background: UInt32
  public let currentLine: UInt32
  public let gutterText: UInt32
  public let gutterCurrentText: UInt32
  public let selection: UInt32
  public let cursor: UInt32
  /// Font names by kind, as Xcode themes give them ("SFMono-Medium",
  /// "SFMono-Bold", "Helvetica"); the size comes from the editor settings.
  /// Empty: every kind uses the editor font.
  public let fonts: [SyntaxKind: String]
  /// Line height as a multiple of the font's natural line height.
  public let lineSpacing: Double

  public init(
    id: String, name: String, isDark: Bool, syntax: CodeColorScheme, background: UInt32,
    currentLine: UInt32, gutterText: UInt32, gutterCurrentText: UInt32, selection: UInt32,
    cursor: UInt32, fonts: [SyntaxKind: String] = [:], lineSpacing: Double = 1
  ) {
    self.id = id
    self.name = name
    self.isDark = isDark
    self.syntax = syntax
    self.background = background
    self.currentLine = currentLine
    self.gutterText = gutterText
    self.gutterCurrentText = gutterCurrentText
    self.selection = selection
    self.cursor = cursor
    self.fonts = fonts
    self.lineSpacing = lineSpacing
  }

  /// Xcode's "Default (Dark)" theme (Xcode 27 FontAndColorThemes/Default (Dark).xccolortheme):
  /// syntax colors (alpha composited over the background), fonts and line spacing. Doc
  /// comment prose follows what Xcode 27 draws rather than the file (Helvetica, comment
  /// gray): the system font, nearer the plain text color. Line spacing is measured from
  /// Xcode 27, which sets 13 pt SF Mono on 18 pt lines.
  public static let xcodeDark = EditorTheme(
    id: "xcode-dark", name: "Xcode Dark", isDark: true,
    syntax: CodeColorScheme(plainText: 0xDDDDDE, comment: 0x6C7986, prose: 0xBDBEC1, keyword: 0xFC5FA3, string: 0xFC6A5D, number: 0xD0BF69, link: 0x5482FF, preprocessor: 0xFD8F3F, typeDeclaration: 0x5DD8FF, memberDeclaration: 0x41A1C0, projectType: 0x9EF1DD, projectMember: 0x67B7A4, otherType: 0xD0A8FF, otherMember: 0xA167E6, attribute: 0xBF8555),
    background: 0x1F1F24, currentLine: 0x23252B,
    gutterText: 0x78797C, gutterCurrentText: 0xDDDDDE, selection: 0x515B70,
    cursor: 0xFFFFFF,
    fonts: [.plainText: "SFMono-Medium", .comment: "SFMono-Medium", .prose: ".AppleSystemUIFont", .keyword: "SFMono-Bold", .string: "SFMono-Medium", .number: "SFMono-Medium", .link: "SFMono-Medium", .preprocessor: "SFMono-Medium", .typeDeclaration: "SFMono-Medium", .memberDeclaration: "SFMono-Medium", .projectType: "SFMono-Medium", .projectMember: "SFMono-Medium", .otherType: "SFMono-Medium", .otherMember: "SFMono-Medium", .attribute: "SFMono-Medium"],
    lineSpacing: 1.163)

  /// Xcode's "Default (Light)" theme (Xcode 27 FontAndColorThemes/Default (Light).xccolortheme):
  /// syntax colors (alpha composited over the background), fonts and line spacing. Doc
  /// comment prose follows what Xcode 27 draws rather than the file (Helvetica, comment
  /// gray): the system font, nearer the plain text color. Line spacing is measured from
  /// Xcode 27, which sets 13 pt SF Mono on 18 pt lines.
  public static let xcodeLight = EditorTheme(
    id: "xcode-light", name: "Xcode Light", isDark: false,
    syntax: CodeColorScheme(plainText: 0x262626, comment: 0x5D6C79, prose: 0x4F4F52, keyword: 0x9B2393, string: 0xC41A16, number: 0x1C00CF, link: 0x0E0EFF, preprocessor: 0x643820, typeDeclaration: 0x0B4F79, memberDeclaration: 0x0F68A0, projectType: 0x1C464A, projectMember: 0x326D74, otherType: 0x3900A0, otherMember: 0x6C36A9, attribute: 0x815F03),
    background: 0xFFFFFF, currentLine: 0xE8F2FF,
    gutterText: 0x999999, gutterCurrentText: 0x262626, selection: 0xA4CDFF,
    cursor: 0x000000,
    fonts: [.plainText: "SFMono-Regular", .comment: "SFMono-Regular", .prose: ".AppleSystemUIFont", .keyword: "SFMono-Semibold", .string: "SFMono-Regular", .number: "SFMono-Regular", .link: "SFMono-Regular", .preprocessor: "SFMono-Regular", .typeDeclaration: "SFMono-Regular", .memberDeclaration: "SFMono-Regular", .projectType: "SFMono-Regular", .projectMember: "SFMono-Regular", .otherType: "SFMono-Regular", .otherMember: "SFMono-Regular", .attribute: "SFMono-Regular"],
    lineSpacing: 1.163)

  /// GitHub Light chrome (primer light: canvas, line highlight, gutter).
  public static let githubLight = EditorTheme(
    id: "github-light", name: "GitHub Light", isDark: false, syntax: .githubLight,
    background: 0xFFFFFF, currentLine: 0xF6F8FA, gutterText: 0x8C959F, gutterCurrentText: 0x24292E,
    selection: 0xC8E1FF, cursor: 0x24292E)

  /// GitHub Dark chrome (primer dark: canvas, line highlight, gutter).
  public static let githubDark = EditorTheme(
    id: "github-dark", name: "GitHub Dark", isDark: true, syntax: .githubDark,
    background: 0x24292E, currentLine: 0x2B3036, gutterText: 0x6A737D, gutterCurrentText: 0xE1E4E8,
    selection: 0x264F78, cursor: 0xC8E1FF)

  public static let all: [EditorTheme] = [xcodeLight, xcodeDark, githubLight, githubDark]

  /// Theme families that follow the system appearance, by ID: "xcode"
  /// (the default) and "github".
  public static let families: [(id: String, name: String)] = [("xcode", "Xcode"), ("github", "GitHub")]

  /// The theme for `id` — a family or a single theme — under the given
  /// appearance. Unknown IDs fall back to the Xcode family.
  public static func resolve(_ id: String?, isDark: Bool) -> EditorTheme {
    switch id {
    case "github": return isDark ? .githubDark : .githubLight
    case let id?: return all.first { $0.id == id } ?? systemAware(isDark: isDark)
    case nil: return systemAware(isDark: isDark)
    }
  }

  /// Xcode's default themes, following the appearance.
  public static func systemAware(isDark: Bool) -> EditorTheme {
    isDark ? .xcodeDark : .xcodeLight
  }
}
