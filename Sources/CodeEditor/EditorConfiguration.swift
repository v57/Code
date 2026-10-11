import CodeHighlighting
import Foundation

/// How the editor looks and behaves. Plain values, so an app can store them
/// with `@AppStorage` and build one per view update.
public struct EditorConfiguration: Equatable, Sendable {
  /// A theme ID from `EditorTheme.all`, a family from `EditorTheme.families`,
  /// or nil for the Xcode family (following the system appearance).
  public var themeID: String?
  /// A font family/PostScript name; nil uses the theme's fonts (SF Mono in
  /// the weights the theme gives each kind).
  public var fontName: String?
  public var fontSize: CGFloat
  public var tabWidth: Int
  /// Tab inserts spaces up to the next tab stop.
  public var insertSpaces: Bool
  public var wrapLines: Bool
  public var showLineNumbers: Bool
  public var highlightCurrentLine: Bool
  /// Typing ( [ or a quote inserts its closer (Xcode's type-over completions).
  public var autoCloseDelimiters: Bool
  /// ⌘S trims trailing whitespace from edited lines.
  public var trimTrailingWhitespace: Bool

  public init(
    themeID: String? = nil, fontName: String? = nil, fontSize: CGFloat = 13, tabWidth: Int = 4,
    insertSpaces: Bool = true, wrapLines: Bool = true, showLineNumbers: Bool = true,
    highlightCurrentLine: Bool = true, autoCloseDelimiters: Bool = true,
    trimTrailingWhitespace: Bool = true
  ) {
    self.themeID = themeID
    self.fontName = fontName
    self.fontSize = fontSize
    self.tabWidth = tabWidth
    self.insertSpaces = insertSpaces
    self.wrapLines = wrapLines
    self.showLineNumbers = showLineNumbers
    self.highlightCurrentLine = highlightCurrentLine
    self.autoCloseDelimiters = autoCloseDelimiters
    self.trimTrailingWhitespace = trimTrailingWhitespace
  }

  public static let fontSizes: ClosedRange<CGFloat> = 8...36

  /// The theme to use under the given appearance.
  public func theme(isDark: Bool) -> EditorTheme {
    EditorTheme.resolve(themeID, isDark: isDark)
  }
}

/// Where the caret is, for a status bar. Lines and columns count from 1;
/// the column counts UTF-16 units, as the editor's text does.
public struct EditorSelection: Equatable, Sendable {
  public var line: Int
  public var column: Int
  /// Selected characters (0 for a caret).
  public var length: Int
  /// Lines the selection touches (1 for a caret).
  public var lineCount: Int

  public init(line: Int = 1, column: Int = 1, length: Int = 0, lineCount: Int = 1) {
    self.line = line
    self.column = column
    self.length = length
    self.lineCount = lineCount
  }
}
