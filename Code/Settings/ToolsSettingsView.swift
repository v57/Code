import CodeKit
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
    VStack(alignment: .leading, spacing: 12) {
      Toggle("Use language servers for definitions and issues", isOn: $enabled)
      Text("Each language’s server is installed separately, from its official source. ⌘-click a symbol to jump to its definition; ⌥-click for Quick Help.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      List {
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
            installCommand: server.install.command, toolID: server.id)
        }
      }
      .disabled(!enabled)
      .frame(height: 340)
    }
    .padding(20)
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
    VStack(alignment: .leading, spacing: 12) {
      Toggle("Format when saving (⌘S)", isOn: $formatOnSave)
      Text("The formatter runs before the file is written, so it is written once, formatted. Formatters read their own config files (.swift-format, .prettierrc, …) from the file’s folder upward.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      List {
        ForEach(FormatterCatalog.all) { formatter in
          VStack(alignment: .leading, spacing: 4) {
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
              installCommand: formatter.installCommand, toolID: formatter.id)
            HStack {
              if !formatter.configFiles.isEmpty {
                Toggle("Only with a config file", isOn: requiresConfigBinding(formatter))
                  .controlSize(.small)
                  .help(formatter.configFiles.joined(separator: ", "))
              }
              Spacer()
              TextField("Custom command", text: commandBinding(formatter.id))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 200)
            }
            .padding(.leading, 22)
          }
        }
      }
      .disabled(!formatOnSave)
      .frame(height: 340)
    }
    .padding(20)
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
    Form {
      Toggle("Show Run, Build and Test in the toolbar", isOn: $actionsEnabled)
      Text("Schemes come from the projects in the folder: Xcode, Swift packages, Cargo, Go, Gradle and Android, Maven, Node and Bun, Python, CMake, Make, Zig, Dart, .NET, Elixir, Ruby and PHP.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Divider()
      Toggle("Breakpoints (click a line number; Run debugs with LLDB)", isOn: $breakpointsEnabled)
      Divider()
      LabeledContent("Android Debug Bridge:") {
        Text(tools.adb ?? "Not found — brew install android-platform-tools")
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
    .padding(20)
    .onAppear { tools.refresh() }
  }
}

/// A tool's row: its switch, what it is for, where it is installed, and
/// Install while it isn't.
private struct ToolRow: View {
  let name: String
  let detail: String
  let source: String
  let path: String?
  @Binding var isOn: Bool
  let installCommand: String?
  let toolID: String
  private var tools: ToolsModel { .shared }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Toggle(isOn: $isOn) {
        VStack(alignment: .leading, spacing: 2) {
          Text(name).fontWeight(.medium)
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      if let running = tools.installer.running[toolID] {
        ProgressView().controlSize(.small)
        Text(running).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 160)
      } else if let path {
        Text(path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.head)
          .frame(maxWidth: 200, alignment: .trailing)
          .help(path)
      } else if let installCommand {
        Button("Install") { tools.install(id: toolID, command: installCommand) }
          .controlSize(.small)
          .help(installCommand)
      } else {
        Text(source).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }
}
