import CodeKit
import ComponentKit
import SwiftUI

extension Notification.Name {
  /// A language server or formatter was installed from Settings; the
  /// object is its ID.
  static let codeToolInstalled = Notification.Name("CodeToolInstalled")
}

/// Installs tools from Settings and finds which are installed, with the
/// login shell's PATH.
@MainActor @Observable final class ToolsModel {
  static let shared = ToolsModel()

  let installer = ToolInstaller()
  /// Tool commands found on the PATH, by command name.
  private(set) var paths: [String: String] = [:]
  private(set) var environment: [String: String]?
  private(set) var adb: String?

  func refresh() {
    Task {
      let environment = await Task.detached { ShellEnvironment.shared.variables }.value
      self.environment = environment
      let commands = LanguageServerCatalog.all.map(\.command) + FormatterCatalog.all.map(\.command)
      let found = await Task.detached {
        var found: [String: String] = [:]
        for command in Set(commands) {
          if let path = ShellEnvironment.shared.which(command) { found[command] = path }
        }
        return found
      }.value
      paths = found
      adb = await Task.detached { ShellEnvironment.shared.adb }.value
    }
  }

  func install(id: String, command: String) {
    guard let environment else { return }
    Task {
      let succeeded = await installer.install(id: id, command: command, environment: environment)
      refresh()
      if succeeded { NotificationCenter.default.post(name: .codeToolInstalled, object: id) }
    }
  }
}

struct LanguagesSettingsView: View {
  @AppStorage(EditorSettings.languageServersEnabled) private var enabled = true
  @AppStorage(EditorSettings.disabledLanguageServers) private var disabled = ""
  private let tools = ToolsModel.shared

  var body: some View {
    FormCard(
      footer:
        "Each language’s server is installed separately, from its official source. ⌘-click a symbol to jump to its definition; ⌥-click for Quick Help."
    ) {
      FormRow("Language servers", help: "For definitions and issues", systemImage: "curlybraces", hue: .purple) {
        Toggle("Use language servers for definitions and issues", isOn: $enabled).kitLabelsHidden()
      }
    }
    FormCard("Servers") {
      ForEach(LanguageServerCatalog.all) { server in
        ToolRow(
          name: server.name, detail: server.languages, source: server.install.summary,
          path: server.install == .xcode && tools.paths[server.command] == nil
            ? nil : tools.paths[server.command],
          isOn: Binding(
            get: { !EditorSettings.ids(from: disabled).contains(server.id) },
            set: { on in
              var ids = EditorSettings.ids(from: disabled)
              if on { ids.remove(server.id) } else { ids.insert(server.id) }
              disabled = EditorSettings.idsText(ids)
            }),
          installCommand: server.install.command, toolID: server.id, systemImage: "curlybraces", hue: .purple)
      }
    }
    .disabled(!enabled)
    .onAppear { tools.refresh() }
  }
}

struct FormattingSettingsView: View {
  @AppStorage(EditorSettings.formatOnSave) private var formatOnSave = true
  @AppStorage(EditorSettings.disabledFormatters) private var disabled = ""
  @AppStorage(EditorSettings.formatterRequiresConfig) private var requiresConfig = "{}"
  @AppStorage(EditorSettings.formatterCommands) private var commands = "{}"
  private let tools = ToolsModel.shared

  var body: some View {
    FormCard(
      footer:
        "The formatter runs before the file is written, so it is written once, formatted. Formatters read their own config files (.swift-format, .prettierrc, …) from the file’s folder upward."
    ) {
      FormRow("Format when saving", help: "Before the file is written (⌘S)", systemImage: "text.alignleft", hue: .orange) {
        Toggle("Format when saving (⌘S)", isOn: $formatOnSave).kitLabelsHidden()
      }
    }
    FormCard("Formatters") {
      ForEach(FormatterCatalog.all) { formatter in
        ToolRow(
          name: formatter.name, detail: formatter.languages,
          source: formatter.installCommand ?? "",
          path: customCommand(formatter.id) ?? tools.paths[formatter.command],
          isOn: Binding(
            get: { !EditorSettings.ids(from: disabled).contains(formatter.id) },
            set: { on in
              var ids = EditorSettings.ids(from: disabled)
              if on { ids.remove(formatter.id) } else { ids.insert(formatter.id) }
              disabled = EditorSettings.idsText(ids)
            }),
          installCommand: formatter.installCommand, toolID: formatter.id, systemImage: "text.alignleft",
          hue: .orange)
        HStack(spacing: 8) {
          if !formatter.configFiles.isEmpty {
            Toggle("Only with a config file", isOn: requiresConfigBinding(formatter))
              .toggleStyle(.kitCheckbox)
              .fixedSize()
              .help(formatter.configFiles.joined(separator: ", "))
          }
          Spacer(minLength: 0)
          TextField("Custom command", text: commandBinding(formatter.id))
            .kitField(mono: true)
            .frame(width: 220)
        }
        .controlSize(.small)
        .padding(.leading, 48)
        .padding(.trailing, 12)
        .padding(.bottom, 8)
      }
    }
    .disabled(!formatOnSave)
    .onAppear { tools.refresh() }
  }

  private func customCommand(_ id: String) -> String? {
    let value = (EditorSettings.dictionary(from: commands) as [String: String])[id]
    return value?.isEmpty == false ? value : nil
  }

  private func requiresConfigBinding(_ formatter: FormatterConfiguration) -> Binding<Bool> {
    Binding(
      get: {
        (EditorSettings.dictionary(from: requiresConfig) as [String: Bool])[formatter.id]
          ?? formatter.requiresConfigByDefault
      },
      set: { value in
        var dictionary: [String: Bool] = EditorSettings.dictionary(from: requiresConfig)
        dictionary[formatter.id] = value == formatter.requiresConfigByDefault ? nil : value
        requiresConfig = EditorSettings.dictionaryText(dictionary)
      })
  }

  private func commandBinding(_ id: String) -> Binding<String> {
    Binding(
      get: { (EditorSettings.dictionary(from: commands) as [String: String])[id] ?? "" },
      set: { value in
        var dictionary: [String: String] = EditorSettings.dictionary(from: commands)
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        dictionary[id] = trimmed.isEmpty ? nil : trimmed
        commands = EditorSettings.dictionaryText(dictionary)
      })
  }
}

struct RunSettingsView: View {
  @AppStorage(EditorSettings.actionsEnabled) private var actionsEnabled = true
  @AppStorage(EditorSettings.breakpointsEnabled) private var breakpointsEnabled = true
  private let tools = ToolsModel.shared

  var body: some View {
    FormCard(
      footer:
        "Schemes come from the projects in the folder: Xcode, Swift packages, Cargo, Go, Gradle and Android, Maven, Node and Bun, Python, CMake, Make, Zig, Dart, .NET, Elixir, Ruby and PHP."
    ) {
      FormRow("Run, Build and Test", help: "In the toolbar", systemImage: "play.fill", hue: .green) {
        Toggle("Show Run, Build and Test in the toolbar", isOn: $actionsEnabled).kitLabelsHidden()
      }
      FormRow(
        "Breakpoints", help: "Click a line number; Run debugs with LLDB", systemImage: "arrowtriangle.right.fill",
        hue: .blue
      ) {
        Toggle("Breakpoints", isOn: $breakpointsEnabled).kitLabelsHidden()
      }
    }
    FormCard {
      FormRow(
        "Android Debug Bridge", help: tools.adb ?? "Not found — brew install android-platform-tools",
        systemImage: "iphone", hue: tools.adb == nil ? .gray : .green)
    }
    .onAppear { tools.refresh() }
  }
}

/// A tool's row: what it is for, where it is installed (or Install while it isn't), and its switch.
private struct ToolRow: View {
  let name: String
  let detail: String
  let source: String
  let path: String?
  @Binding var isOn: Bool
  let installCommand: String?
  let toolID: String
  let systemImage: String
  let hue: Hue
  private var tools: ToolsModel { .shared }

  var body: some View {
    let running = tools.installer.running[toolID]
    FormRow(name, help: running ?? help, systemImage: systemImage, hue: path == nil ? .gray : hue) {
      HStack(spacing: 8) {
        if running != nil {
          LiveIcon(systemImage: "arrow.down", status: .working, size: 20)
        } else if path == nil, let installCommand {
          Button("Install") { tools.install(id: toolID, command: installCommand) }
            .buttonStyle(.kit)
            .help(installCommand)
        }
        Toggle(name, isOn: $isOn).kitLabelsHidden()
      }
    }
    .help(path ?? source)
  }

  /// "Swift, C · /usr/bin/sourcekit-lsp", or where it comes from while it isn't installed.
  private var help: String {
    if let path { return "\(detail) · \(path)" }
    return installCommand == nil && !source.isEmpty ? "\(detail) · \(source)" : "\(detail) · Not installed"
  }
}
