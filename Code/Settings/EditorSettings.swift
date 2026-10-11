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
  static let showsMinimap = "editor.showsMinimap"
  static let showsInlineIssues = "editor.showsInlineIssues"
  static let showsIssueMessages = "editor.showsIssueMessages"
  static let breakpointsEnabled = "debug.breakpointsEnabled"
  static let actionsEnabled = "actions.enabled"
  static let languageServersEnabled = "languages.enabled"
  static let disabledLanguageServers = "languages.disabled"  // comma-separated server IDs
  static let formatOnSave = "formatting.onSave"
  static let disabledFormatters = "formatting.disabled"  // comma-separated formatter IDs
  static let formatterRequiresConfig = "formatting.requiresConfig"  // JSON {id: Bool}
  static let formatterCommands = "formatting.commands"  // JSON {id: path}

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

extension EditorSettings {
  static func ids(from text: String) -> Set<String> {
    Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
  }

  static func idsText(_ ids: Set<String>) -> String { ids.sorted().joined(separator: ",") }

  static func dictionary<Value: Decodable>(from text: String) -> [String: Value] {
    (try? JSONDecoder().decode([String: Value].self, from: Data(text.utf8))) ?? [:]
  }

  static func dictionaryText<Value: Encodable>(_ dictionary: [String: Value]) -> String {
    (try? String(decoding: JSONEncoder().encode(dictionary), as: UTF8.self)) ?? "{}"
  }

  /// The services' settings as currently stored.
  static var storedServiceSettings: ServiceSettings {
    let defaults = UserDefaults.standard
    func bool(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
    var settings = ServiceSettings()
    settings.actionsEnabled = bool(actionsEnabled)
    settings.languageServersEnabled = bool(languageServersEnabled)
    settings.disabledLanguageServers = ids(from: defaults.string(forKey: disabledLanguageServers) ?? "")
    settings.formatOnSave = bool(formatOnSave)
    settings.disabledFormatters = ids(from: defaults.string(forKey: disabledFormatters) ?? "")
    settings.formatterRequiresConfig = dictionary(from: defaults.string(forKey: formatterRequiresConfig) ?? "")
    settings.formatterCommands = dictionary(from: defaults.string(forKey: formatterCommands) ?? "")
    settings.showsMinimap = bool(showsMinimap)
    settings.showsInlineIssues = bool(showsInlineIssues)
    settings.showsIssueMessages = bool(showsIssueMessages)
    settings.breakpointsEnabled = bool(breakpointsEnabled)
    return settings
  }
}

/// Reads the services' settings, so views update when they change.
struct ServiceSettingsReader: DynamicProperty {
  @AppStorage(EditorSettings.actionsEnabled) private var actionsEnabled = true
  @AppStorage(EditorSettings.languageServersEnabled) private var languageServersEnabled = true
  @AppStorage(EditorSettings.disabledLanguageServers) private var disabledLanguageServers = ""
  @AppStorage(EditorSettings.formatOnSave) private var formatOnSave = true
  @AppStorage(EditorSettings.disabledFormatters) private var disabledFormatters = ""
  @AppStorage(EditorSettings.formatterRequiresConfig) private var formatterRequiresConfig = "{}"
  @AppStorage(EditorSettings.formatterCommands) private var formatterCommands = "{}"
  @AppStorage(EditorSettings.showsMinimap) private var showsMinimap = true
  @AppStorage(EditorSettings.showsInlineIssues) private var showsInlineIssues = true
  @AppStorage(EditorSettings.showsIssueMessages) private var showsIssueMessages = true
  @AppStorage(EditorSettings.breakpointsEnabled) private var breakpointsEnabled = true

  var settings: ServiceSettings {
    var settings = ServiceSettings()
    settings.actionsEnabled = actionsEnabled
    settings.languageServersEnabled = languageServersEnabled
    settings.disabledLanguageServers = EditorSettings.ids(from: disabledLanguageServers)
    settings.formatOnSave = formatOnSave
    settings.disabledFormatters = EditorSettings.ids(from: disabledFormatters)
    settings.formatterRequiresConfig = EditorSettings.dictionary(from: formatterRequiresConfig)
    settings.formatterCommands = EditorSettings.dictionary(from: formatterCommands)
    settings.showsMinimap = showsMinimap
    settings.showsInlineIssues = showsInlineIssues
    settings.showsIssueMessages = showsIssueMessages
    settings.breakpointsEnabled = breakpointsEnabled
    return settings
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
