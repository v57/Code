import CodeKit
import ComponentKit
import SwiftUI
import VaultUI

/// Settings as the kit's settings window: the panes in its sidebar, each a column of form cards.
struct SettingsView: View {
  /// The tab shown, kept for the next time Settings opens.
  @AppStorage("settings.tab") private var tab = "editor"

  var body: some View {
    KitSettings(selection: $tab, window: .hiddenTitleBar) {
      SettingsPane("Editor", systemImage: "character.cursor.ibeam", hue: .blue, id: "editor") {
        EditorSettingsView()
      }
      SettingsPane("Files", systemImage: "folder", hue: .teal, id: "files") { FilesSettingsView() }
      SettingsPane("Languages", systemImage: "curlybraces", hue: .purple, id: "languages") {
        LanguagesSettingsView()
      }
      SettingsPane("Formatting", systemImage: "text.alignleft", hue: .orange, id: "formatting") {
        FormattingSettingsView()
      }
      SettingsPane("Run", systemImage: "play.fill", hue: .green, id: "run") { RunSettingsView() }
      SettingsPane("Privacy", systemImage: "hand.raised", hue: .blue, id: "privacy") { VaultICloudCard() }
      SettingsPane("Accounts", systemImage: "person.2", hue: .indigo, section: "v57", id: "accounts") {
        VaultAccountsSettings()
      }
      #if os(macOS)
        // Your devices, and your iPhone and iPad sign in to this Mac over SSH: which of them can, and the other keys.
        SettingsPane("Remote", systemImage: "network", hue: .teal, section: "v57", id: "remote") { VaultRemoteSettings() }
      #else
        SettingsPane("Devices", systemImage: "laptopcomputer", hue: .blue, section: "v57", id: "devices") { VaultDevicesSettings() }
      #endif
    }
    .toggleStyle(.kitSwitch)
    .frame(width: 680, height: 560)
  }
}

private struct EditorSettingsView: View {
  @AppStorage(EditorSettings.theme) private var theme = "xcode"
  @AppStorage(EditorSettings.fontName) private var fontName = ""
  @AppStorage(EditorSettings.fontSize) private var fontSize = EditorSettings.defaultFontSize
  @AppStorage(EditorSettings.tabWidth) private var tabWidth = 2
  @AppStorage(EditorSettings.insertSpaces) private var insertSpaces = true
  @AppStorage(EditorSettings.wrapLines) private var wrapLines = true
  @AppStorage(EditorSettings.showLineNumbers) private var showLineNumbers = true
  @AppStorage(EditorSettings.highlightCurrentLine) private var highlightCurrentLine = true
  @AppStorage(EditorSettings.autoCloseDelimiters) private var autoCloseDelimiters = true
  @AppStorage(EditorSettings.trimTrailingWhitespace) private var trimTrailingWhitespace = true
  @AppStorage(EditorSettings.showsMinimap) private var showsMinimap = true
  @AppStorage(EditorSettings.showsInlineIssues) private var showsInlineIssues = true
  @AppStorage(EditorSettings.showsIssueMessages) private var showsIssueMessages = true
  @AppStorage(EditorSettings.suggestsCompletions) private var suggestsCompletions = true

  /// Installed fixed-pitch font families.
  private let monospacedFamilies = KitFont.monospacedFamilies()
  private let editor = EditorConfigurationReader()
  private var configuration: EditorConfiguration { editor.configuration }

  private func height(lines: Int) -> CGFloat { EditorPreview.height(lines: lines, configuration: configuration) }

  var body: some View {
    FormCard("Appearance") {
      FormRow("Theme", help: "Matching the system follows light and dark", systemImage: "paintpalette", hue: .purple) {
        KitPicker(
          "Theme", selection: $theme,
          options: EditorTheme.families.map { ("\($0.name) (Match System)", $0.id) }
            + EditorTheme.all.map { ($0.name, $0.id) })
      }
      .preview(height: height(lines: 4)) {
        EditorPreview(text: PreviewSample.code, configuration: configuration, currentLine: 1)
      }
      FormRow("Font", help: "Installed fixed-pitch fonts", systemImage: "textformat", hue: .blue) {
        KitPicker(
          "Font", selection: $fontName, options: [("Theme Font (SF Mono)", "")] + monospacedFamilies.map { ($0, $0) })
      }
      .preview(height: height(lines: 1)) { EditorPreview(text: PreviewSample.oneLine, configuration: configuration) }
      FormRow("Font size", help: "\(Keycaps.label("⌘+")) and \(Keycaps.label("⌘−")) change it too", systemImage: "textformat.size", hue: .blue) {
        KitStepper(
          "Font size", value: $fontSize,
          in: Double(EditorConfiguration.fontSizes.lowerBound)...Double(EditorConfiguration.fontSizes.upperBound),
          unit: "pt")
      }
      .preview(height: height(lines: 1)) { EditorPreview(text: PreviewSample.oneLine, configuration: configuration) }
    }
    FormCard("Editing") {
      FormRow("Tab width", systemImage: "arrow.right.to.line", hue: .gray) {
        KitPicker("Tab width", selection: $tabWidth, options: [2, 3, 4, 8].map { ("\($0) spaces", $0) })
      }
      .preview(height: height(lines: 3)) { EditorPreview(text: PreviewSample.indented, configuration: configuration) }
      FormRow("Insert spaces when pressing Tab", systemImage: "keyboard", hue: .gray) {
        Toggle("Insert spaces when pressing Tab", isOn: $insertSpaces).kitLabelsHidden()
      }
      .preview(height: height(lines: 2)) {
        EditorPreview(
          text: PreviewSample.tabKey(insertSpaces: insertSpaces, tabWidth: tabWidth), configuration: configuration)
      }
      FormRow("Close brackets and quotes", help: "As you type the opening one", systemImage: "curlybraces", hue: .gray) {
        Toggle("Automatically close brackets and quotes", isOn: $autoCloseDelimiters).kitLabelsHidden()
      }
      .preview(height: height(lines: 2)) {
        EditorPreview(text: PreviewSample.closing(isOn: autoCloseDelimiters), configuration: configuration)
      }
      FormRow("Trim trailing whitespace", help: "When saving", systemImage: "scissors", hue: .gray) {
        Toggle("Trim trailing whitespace when saving", isOn: $trimTrailingWhitespace).kitLabelsHidden()
      }
      .preview(height: height(lines: 2)) {
        EditorPreview(text: PreviewSample.trimming(isOn: trimTrailingWhitespace), configuration: configuration)
      }
      FormRow("Suggest completions", help: "While typing", systemImage: "text.badge.plus", hue: .gray) {
        Toggle("Suggest completions while typing", isOn: $suggestsCompletions).kitLabelsHidden()
      }
      .preview(height: 96) { CompletionPreview(isOn: suggestsCompletions, configuration: configuration) }
    }
    FormCard("Display") {
      FormRow("Wrap lines", systemImage: "arrow.turn.down.left", hue: .indigo) {
        Toggle("Wrap lines", isOn: $wrapLines).kitLabelsHidden()
      }
      .preview(height: height(lines: 4)) { EditorPreview(text: PreviewSample.longLine, configuration: configuration) }
      FormRow("Line numbers", systemImage: "list.number", hue: .indigo) {
        Toggle("Show line numbers", isOn: $showLineNumbers).kitLabelsHidden()
      }
      .preview(height: height(lines: 3)) { EditorPreview(text: PreviewSample.currentLine, configuration: configuration) }
      FormRow("Highlight current line", systemImage: "highlighter", hue: .indigo) {
        Toggle("Highlight current line", isOn: $highlightCurrentLine).kitLabelsHidden()
      }
      .preview(height: height(lines: 3)) {
        EditorPreview(text: PreviewSample.currentLine, configuration: configuration, currentLine: 1)
      }
      FormRow("Minimap", systemImage: "sidebar.right", hue: .indigo) {
        Toggle("Show minimap", isOn: $showsMinimap).kitLabelsHidden()
      }
      .preview(height: 96) {
        EditorPreview(text: PreviewSample.file, configuration: configuration, showsMinimap: showsMinimap)
      }
    }
    FormCard("Issues") {
      FormRow("Show issues in the editor", systemImage: "exclamationmark.triangle", hue: .orange) {
        Toggle("Show issues in the editor", isOn: $showsInlineIssues).kitLabelsHidden()
      }
      .preview(height: height(lines: 3)) {
        EditorPreview(
          text: PreviewSample.issues, configuration: configuration,
          annotations: showsInlineIssues ? PreviewSample.issueAnnotations : [], showsMessages: false)
      }
      FormRow("Show issue messages", help: "At the end of their lines", systemImage: "text.bubble", hue: .orange) {
        Toggle("Show issue messages at the end of lines", isOn: $showsIssueMessages).kitLabelsHidden()
      }
      .preview(height: height(lines: 3)) {
        EditorPreview(
          text: PreviewSample.issues, configuration: configuration,
          annotations: showsInlineIssues ? PreviewSample.issueAnnotations : [], showsMessages: showsIssueMessages)
      }
      .disabled(!showsInlineIssues)
    }
  }
}

private struct FilesSettingsView: View {
  @AppStorage(EditorSettings.hidesIgnoredFiles) private var hidesIgnoredFiles = true
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  var body: some View {
    FormCard {
      FormRow("Show file extensions", help: "In the navigator, tabs and path bar", systemImage: "doc.text", hue: .teal) {
        Toggle("Show file extensions", isOn: $showExtensions).kitLabelsHidden()
      }
      .preview(height: 36) {
        FilesPreview(
          files: [("Trip.swift", false), ("README.md", false), ("Package.swift", false)], showsExtensions: showExtensions)
      }
    }
    FormCard(
      footer:
        "For projects that haven’t chosen. Choose a project’s visible files from its navigator (View › Hidden Files › Edit Hidden Files); \(Keycaps.label("⇧⌘.")) shows hidden files."
    ) {
      FormRow("Hide files listed in .gitignore", systemImage: "eye.slash", hue: .gray) {
        Toggle("Hide files listed in .gitignore", isOn: $hidesIgnoredFiles).kitLabelsHidden()
      }
      .preview(height: 36) {
        FilesPreview(
          files: [("Sources", true), ("Package.swift", false)] + (hidesIgnoredFiles ? [] : [(".build", true), (".DS_Store", false)]))
      }
    }
  }
}
