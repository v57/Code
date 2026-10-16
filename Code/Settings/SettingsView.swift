import AppKit
import CodeKit
import ComponentKit
import SwiftUI

/// Settings as the kit's settings window: the panes in its sidebar, each a column of form cards.
struct SettingsView: View {
  /// The tab shown, kept for the next time Settings opens.
  @AppStorage("settings.tab") private var tab = "editor"

  var body: some View {
    KitSettings(selection: $tab) {
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
    }
    .toggleStyle(.kitSwitch)
    .frame(width: 680, height: 560)
    // The kit lays the sidebar out under the window's buttons: run it up into the title bar.
    .frame(height: 560 - 32, alignment: .bottom)
    .modifier(SettingsWindowTitle())
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
    FormCard("Appearance") {
      FormRow("Theme", help: "Matching the system follows light and dark", systemImage: "paintpalette", hue: .purple) {
        Picker("Theme", selection: $theme) {
          ForEach(EditorTheme.families, id: \.id) { family in
            Text("\(family.name) (Match System)").tag(family.id)
          }
          Divider()
          ForEach(EditorTheme.all) { theme in
            Text(theme.name).tag(theme.id)
          }
        }
        .labelsHidden()
        .fixedSize()
      }
      FormRow("Font", help: "Installed fixed-pitch fonts", systemImage: "textformat", hue: .blue) {
        Picker("Font", selection: $fontName) {
          Text("Theme Font (SF Mono)").tag("")
          Divider()
          ForEach(monospacedFamilies, id: \.self) { family in
            Text(family).tag(family)
          }
        }
        .labelsHidden()
        .fixedSize()
      }
      FormRow("Font size", help: "⌘+ and ⌘− change it too", systemImage: "textformat.size", hue: .blue) {
        KitStepper(
          "Font size", value: $fontSize,
          in: Double(EditorConfiguration.fontSizes.lowerBound)...Double(EditorConfiguration.fontSizes.upperBound),
          unit: "pt")
      }
    }
    FormCard("Editing") {
      FormRow("Tab width", systemImage: "arrow.right.to.line", hue: .gray) {
        Picker("Tab width", selection: $tabWidth) {
          ForEach([2, 3, 4, 8], id: \.self) { Text("\($0) spaces").tag($0) }
        }
        .labelsHidden()
        .fixedSize()
      }
      FormRow("Insert spaces when pressing Tab", systemImage: "keyboard", hue: .gray) {
        Toggle(isOn: $insertSpaces) {}.accessibilityLabel("Insert spaces when pressing Tab")
      }
      FormRow("Close brackets and quotes", help: "As you type the opening one", systemImage: "curlybraces", hue: .gray) {
        Toggle(isOn: $autoCloseDelimiters) {}.accessibilityLabel("Automatically close brackets and quotes")
      }
      FormRow("Trim trailing whitespace", help: "When saving", systemImage: "scissors", hue: .gray) {
        Toggle(isOn: $trimTrailingWhitespace) {}.accessibilityLabel("Trim trailing whitespace when saving")
      }
      FormRow("Suggest completions", help: "While typing", systemImage: "text.badge.plus", hue: .gray) {
        Toggle(isOn: $suggestsCompletions) {}.accessibilityLabel("Suggest completions while typing")
      }
    }
    FormCard("Display") {
      FormRow("Wrap lines", systemImage: "arrow.turn.down.left", hue: .indigo) {
        Toggle(isOn: $wrapLines) {}.accessibilityLabel("Wrap lines")
      }
      FormRow("Line numbers", systemImage: "list.number", hue: .indigo) {
        Toggle(isOn: $showLineNumbers) {}.accessibilityLabel("Show line numbers")
      }
      FormRow("Highlight current line", systemImage: "highlighter", hue: .indigo) {
        Toggle(isOn: $highlightCurrentLine) {}.accessibilityLabel("Highlight current line")
      }
      FormRow("Minimap", systemImage: "sidebar.right", hue: .indigo) {
        Toggle(isOn: $showsMinimap) {}.accessibilityLabel("Show minimap")
      }
    }
    FormCard("Issues") {
      FormRow("Show issues in the editor", systemImage: "exclamationmark.triangle", hue: .orange) {
        Toggle(isOn: $showsInlineIssues) {}.accessibilityLabel("Show issues in the editor")
      }
      FormRow("Show issue messages", help: "At the end of their lines", systemImage: "text.bubble", hue: .orange) {
        Toggle(isOn: $showsIssueMessages) {}.accessibilityLabel("Show issue messages at the end of lines")
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
        Toggle(isOn: $showExtensions) {}.accessibilityLabel("Show file extensions")
      }
    }
    FormCard(
      footer:
        "For projects that haven’t chosen. Choose a project’s visible files from its navigator (View › Hidden Files › Edit Hidden Files); ⇧⌘. shows hidden files."
    ) {
      FormRow("Hide files listed in .gitignore", systemImage: "eye.slash", hue: .gray) {
        Toggle(isOn: $hidesIgnoredFiles) {}.accessibilityLabel("Hide files listed in .gitignore")
      }
    }
  }
}

/// No system title: the kit's settings window titles its panes.
private struct SettingsWindowTitle: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    } else {
      content
    }
  }
}
