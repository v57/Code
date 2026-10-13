import AppKit
import CodeKit
import SwiftUI

struct SettingsView: View {
  /// The tab shown, kept for the next time Settings opens.
  @AppStorage("settings.tab") private var tab = "editor"

  var body: some View {
    TabView(selection: $tab) {
      EditorSettingsView()
        .tabItem { Label("Editor", systemImage: "character.cursor.ibeam") }
        .tag("editor")
      FilesSettingsView()
        .tabItem { Label("Files", systemImage: "folder") }
        .tag("files")
      LanguagesSettingsView()
        .tabItem { Label("Languages", systemImage: "curlybraces") }
        .tag("languages")
      FormattingSettingsView()
        .tabItem { Label("Formatting", systemImage: "text.alignleft") }
        .tag("formatting")
      RunSettingsView()
        .tabItem { Label("Run", systemImage: "play") }
        .tag("run")
    }
    .frame(width: 560)
  }
}

private struct EditorSettingsView: View {
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
  @AppStorage(EditorSettings.showsMinimap) private var showsMinimap = true
  @AppStorage(EditorSettings.showsInlineIssues) private var showsInlineIssues = true
  @AppStorage(EditorSettings.showsIssueMessages) private var showsIssueMessages = true
  @AppStorage(EditorSettings.suggestsCompletions) private var suggestsCompletions = true

  /// Installed fixed-pitch font families.
  private let monospacedFamilies: [String] = {
    let manager = NSFontManager.shared
    return manager.availableFontFamilies.filter { family in
      guard let members = manager.availableMembers(ofFontFamily: family),
        let name = members.first?.first as? String,
        let font = NSFont(name: name, size: 12)
      else { return false }
      return font.isFixedPitch
    }
  }()

  var body: some View {
    Form {
      Picker("Theme:", selection: $theme) {
        ForEach(EditorTheme.families, id: \.id) { family in
          Text("\(family.name) (Match System)").tag(family.id)
        }
        Divider()
        ForEach(EditorTheme.all) { theme in
          Text(theme.name).tag(theme.id)
        }
      }
      Picker("Font:", selection: $fontName) {
        Text("Theme Font (SF Mono)").tag("")
        Divider()
        ForEach(monospacedFamilies, id: \.self) { family in
          Text(family).tag(family)
        }
      }
      Stepper(value: $fontSize, in: Double(EditorConfiguration.fontSizes.lowerBound)...Double(EditorConfiguration.fontSizes.upperBound)) {
        Text("Font size: \(Int(fontSize)) pt")
      }
      Picker("Tab width:", selection: $tabWidth) {
        ForEach([2, 3, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
      }
      Toggle("Insert spaces when pressing Tab", isOn: $insertSpaces)
      Toggle("Automatically close brackets and quotes", isOn: $autoCloseDelimiters)
      Toggle("Trim trailing whitespace when saving", isOn: $trimTrailingWhitespace)
      Toggle("Suggest completions while typing", isOn: $suggestsCompletions)
      Divider()
      Toggle("Wrap lines", isOn: $wrapLines)
      Toggle("Show line numbers", isOn: $showLineNumbers)
      Toggle("Highlight current line", isOn: $highlightCurrentLine)
      Toggle("Show minimap", isOn: $showsMinimap)
      Divider()
      Toggle("Show issues in the editor", isOn: $showsInlineIssues)
      Toggle("Show issue messages at the end of lines", isOn: $showsIssueMessages)
        .disabled(!showsInlineIssues)
    }
    .padding(20)
  }
}

private struct FilesSettingsView: View {
  @AppStorage(EditorSettings.hidesIgnoredFiles) private var hidesIgnoredFiles = true
  @AppStorage(EditorSettings.showExtensions) private var showExtensions = false

  var body: some View {
    Form {
      Toggle("Show file extensions", isOn: $showExtensions)
      Divider()
      Toggle("Hide files listed in .gitignore", isOn: $hidesIgnoredFiles)
      Text("For projects that haven’t chosen. Choose a project’s visible files from its navigator (View › Choose Visible Files); ⇧⌘. shows hidden files.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(20)
  }
}
