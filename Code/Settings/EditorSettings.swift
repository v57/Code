import CodeKit
import SwiftUI

/// User-defaults keys for the settings, shared by the Settings window, the
/// editor, and the View menu.
enum EditorSettings {
  static let theme = "editor.theme"  // a theme or family ID ("xcode", "github", "xcode-dark", …)
  static let fontName = "editor.fontName"  // "" is the system monospaced font
  static let fontSize = "editor.fontSize"
  static let tabWidth = "editor.tabWidth"
  static let insertSpaces = "editor.insertSpaces"
  static let wrapLines = "editor.wrapLines"
  static let showLineNumbers = "editor.showLineNumbers"
  static let highlightCurrentLine = "editor.highlightCurrentLine"
  static let autoCloseDelimiters = "editor.autoCloseDelimiters"
  static let trimTrailingWhitespace = "editor.trimTrailingWhitespace"
  static let excludedNames = "files.excludedNames"
  static let showExtensions = "files.showExtensions"

  static let defaultFontSize = 13.0
  static let defaultExcludedNames = FileTree.defaultExcludedNames.sorted().joined(separator: ", ")

  /// "a, b,c" → ["a", "b", "c"].
  static func excludedNames(from text: String) -> Set<String> {
    Set(
      text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty })
  }

  /// The excluded names as currently stored.
  static var storedExcludedNames: Set<String> {
    excludedNames(from: UserDefaults.standard.string(forKey: excludedNames) ?? defaultExcludedNames)
  }
}

/// Reads the editor settings and builds an `EditorConfiguration`.
struct EditorConfigurationReader: DynamicProperty {
  @AppStorage(EditorSettings.theme) private var theme = "xcode"
  @AppStorage(EditorSettings.fontName) private var fontName = ""
  @AppStorage(EditorSettings.fontSize) private var fontSize = EditorSettings.defaultFontSize
  @AppStorage(EditorSettings.tabWidth) private var tabWidth = 4
  @AppStorage(EditorSettings.insertSpaces) private var insertSpaces = true
  @AppStorage(EditorSettings.wrapLines) private var wrapLines = true
  @AppStorage(EditorSettings.showLineNumbers) private var showLineNumbers = true
  @AppStorage(EditorSettings.highlightCurrentLine) private var highlightCurrentLine = true
  @AppStorage(EditorSettings.autoCloseDelimiters) private var autoCloseDelimiters = true
  @AppStorage(EditorSettings.trimTrailingWhitespace) private var trimTrailingWhitespace = true

  var configuration: EditorConfiguration {
    EditorConfiguration(
      themeID: theme, fontName: fontName.isEmpty ? nil : fontName,
      fontSize: CGFloat(fontSize), tabWidth: tabWidth, insertSpaces: insertSpaces,
      wrapLines: wrapLines, showLineNumbers: showLineNumbers,
      highlightCurrentLine: highlightCurrentLine, autoCloseDelimiters: autoCloseDelimiters,
      trimTrailingWhitespace: trimTrailingWhitespace)
  }
}
