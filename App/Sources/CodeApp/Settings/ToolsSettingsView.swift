import CodeKit
import ComponentKit
import SwiftUI

extension Notification.Name {
  /// A language server or formatter was installed or uninstalled from
  /// Settings; the object is its ID.
  static let codeToolInstalled = Notification.Name("CodeToolInstalled")
}

/// Installs tools from Settings and finds which are installed, with the
/// login shell's PATH.
@MainActor @Observable final class ToolsModel {
  static let shared = ToolsModel()

  let installer = ToolInstaller()
  /// Tool commands found on the PATH, by command name.
  private(set) var paths: [String: String] = [:]
  /// Whether `paths` is known yet, so a row doesn't offer Install for a tool that is only still being looked for.
  private(set) var hasFoundTools = false
  private(set) var environment: [String: String]?
  private(set) var adb: String?
  /// Tools being uninstalled, by ID (their progress is in `installer`, which runs both).
  private(set) var uninstalling: Set<String> = []
  /// The last line of a failed uninstall, by tool ID.
  private(set) var uninstallFailures: [String: String] = [:]

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
      hasFoundTools = true
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

  /// How the copy of `command` on the PATH would be uninstalled.
  func uninstallPlan(command: String, installCommand: String?) -> ToolUninstallPlan? {
    guard let path = paths[command] else { return nil }
    return ToolUninstall.plan(tool: command, path: path, installCommand: installCommand) {
      ShellEnvironment.shared.which($0)
    }
  }

  func uninstall(id: String, command: String) {
    guard let environment else { return }
    uninstalling.insert(id)
    uninstallFailures[id] = nil
    Task {
      let succeeded = await installer.install(id: id, command: command, environment: environment)
      uninstalling.remove(id)
      if succeeded {
        NotificationCenter.default.post(name: .codeToolInstalled, object: id)
      } else {
        let lines = installer.logs[id]?.split(whereSeparator: \.isNewline) ?? []
        uninstallFailures[id] = lines.last.map(String.init) ?? String(localized: "Uninstalling failed.")
      }
      refresh()
    }
  }
}

struct LanguagesSettingsView: View {
  @AppStorage(EditorSettings.languageServersEnabled) private var enabled = true
  @AppStorage(EditorSettings.disabledLanguageServers) private var disabled = ""
  @AppStorage(EditorSettings.usesScanner) private var usesScanner = true
  @AppStorage(EditorSettings.usesSwiftModel) private var usesSwiftModel = true
  @AppStorage(EditorSettings.serverDefinitions) private var serverDefinitions = ServerDefinitions.whenUnsure.rawValue
  private let tools = ToolsModel.shared
  private let editor = EditorConfigurationReader()

  var body: some View {
    FormCard(
      footer:
        "Each language’s server is installed separately, from its official source. ⌘-click a symbol to jump to its definition; ⌥-click for Quick Help."
    ) {
      FormRow("Language servers", help: "For definitions and issues", systemImage: "curlybraces", hue: .purple) {
        Toggle("Use language servers for definitions and issues", isOn: $enabled).kitLabelsHidden()
      }
      .preview(height: EditorPreview.height(lines: 3, configuration: editor.configuration)) {
        EditorPreview(
          text: PreviewSample.issues, configuration: editor.configuration,
          annotations: enabled ? PreviewSample.issueAnnotations : [])
      }
    }
    FormCard(
      "Jumping and completion",
      footer:
        "The fastest answer shows first and the slower ones update it. A menu lists the places when the answer isn’t sure, or there are several; what you already moved past stays where it is. Turn a tier off to save memory and power."
    ) {
      FormRow("Code’s scanner", help: "Guesses from the code’s words, in every language, while the others work. About 8 MB", systemImage: "bolt", hue: .yellow) {
        Toggle("Use Code’s scanner", isOn: $usesScanner).kitLabelsHidden()
      }
      FormRow("Swift model", help: "Swift’s types read from the source, answering in milliseconds. 150–200 MB for a large app", systemImage: "swift", hue: .orange) {
        Toggle("Use the Swift model", isOn: $usesSwiftModel).kitLabelsHidden()
      }
      FormRow(String(localized: "Ask the language server"), help: serverHelp, systemImage: "curlybraces", hue: .purple) {
        KitPicker(
          "Ask the language server", selection: $serverDefinitions,
          options: [
            ("When Unsure", ServerDefinitions.whenUnsure.rawValue), ("Always", ServerDefinitions.always.rawValue),
            ("Never", ServerDefinitions.off.rawValue),
          ])
      }
      .disabled(!enabled)
    }
    FormCard("Servers") {
      ForEach(LanguageServerCatalog.all.installedFirst { tools.paths[$0.command] != nil }) { server in
        ToolRow(
          name: server.name, detail: server.languages, source: server.install.summary,
          path: server.install == .builtIn ? LanguageServerManager.builtInExecutable : tools.paths[server.command],
          isOn: Binding(
            get: { !EditorSettings.ids(from: disabled).contains(server.id) },
            set: { on in
              var ids = EditorSettings.ids(from: disabled)
              if on { ids.remove(server.id) } else { ids.insert(server.id) }
              disabled = EditorSettings.idsText(ids)
            }),
          installCommand: server.install.command, toolID: server.id, command: server.command,
          systemImage: "curlybraces", hue: .purple)
      }
    }
    .disabled(!enabled)
    .onAppear { tools.refresh() }
  }

  private var serverHelp: String {
    switch ServerDefinitions(rawValue: serverDefinitions) ?? .whenUnsure {
    case .whenUnsure:
      return String(localized: "For definitions only when the Swift model isn’t sure, and always in other languages")
    case .always: return String(localized: "Its answer decides each jump; the faster ones show while it works")
    case .off: return String(localized: "Never for definitions; it still reports issues and completes")
    }
  }
}

struct FormattingSettingsView: View {
  @AppStorage(EditorSettings.formatOnSave) private var formatOnSave = true
  @AppStorage(EditorSettings.usesBuiltInFormatter) private var usesBuiltInFormatter = false
  @AppStorage(EditorSettings.disabledFormatters) private var disabled = ""
  @AppStorage(EditorSettings.formatterRequiresConfig) private var requiresConfig = "{}"
  @AppStorage(EditorSettings.formatterCommands) private var commands = "{}"
  private let tools = ToolsModel.shared
  private let editor = EditorConfigurationReader()

  var body: some View {
    FormCard(
      footer:
        "The formatter runs before the file is written, so it is written once, formatted. Formatters read their own config files (.swift-format, .prettierrc, …) from the file’s folder upward."
    ) {
      FormRow("Format when saving", help: "Before the file is written (⌘S)", systemImage: "text.alignleft", hue: .orange) {
        Toggle("Format when saving (⌘S)", isOn: $formatOnSave).kitLabelsHidden()
      }
      .preview(height: EditorPreview.height(lines: 2, configuration: editor.configuration)) {
        EditorPreview(text: PreviewSample.formatting(isOn: formatOnSave), configuration: editor.configuration)
      }
      FormRow("Code’s formatter", help: "For files no formatter below applies to, in any language", systemImage: "wand.and.stars", hue: .orange) {
        Toggle("Use Code’s formatter for other files", isOn: $usesBuiltInFormatter).kitLabelsHidden()
      }
      .disabled(!formatOnSave)
    }
    FormCard("Formatters") {
      ForEach(FormatterCatalog.all.installedFirst { path(of: $0) != nil }) { formatter in
        ToolRow(
          name: formatter.name, detail: formatter.languages,
          source: formatter.installCommand ?? "",
          path: path(of: formatter),
          isOn: Binding(
            get: { !EditorSettings.ids(from: disabled).contains(formatter.id) },
            set: { on in
              var ids = EditorSettings.ids(from: disabled)
              if on { ids.remove(formatter.id) } else { ids.insert(formatter.id) }
              disabled = EditorSettings.idsText(ids)
            }),
          installCommand: formatter.installCommand, toolID: formatter.id, command: formatter.command,
          systemImage: "text.alignleft", hue: .orange
        ) {
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
      }
    }
    .disabled(!formatOnSave)
    .onAppear { tools.refresh() }
  }

  private func path(of formatter: FormatterConfiguration) -> String? {
    customCommand(formatter.id) ?? tools.paths[formatter.command]
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
  private let editor = EditorConfigurationReader()

  var body: some View {
    FormCard(
      footer:
        "Schemes come from the projects in the folder: Xcode, Swift packages, Cargo, Go, Gradle and Android, Maven, Node and Bun, Python, CMake, Make, Zig, Dart, .NET, Elixir, Ruby and PHP."
    ) {
      FormRow("Run, Build and Test", help: "In the toolbar", systemImage: "play.fill", hue: .green) {
        Toggle("Show Run, Build and Test in the toolbar", isOn: $actionsEnabled).kitLabelsHidden()
      }
      .preview(height: 36) { ToolbarPreview(showsActions: actionsEnabled) }
      FormRow(
        "Breakpoints", help: "Click a line number; Run debugs with LLDB", systemImage: "arrowtriangle.right.fill",
        hue: .blue
      ) {
        Toggle("Breakpoints", isOn: $breakpointsEnabled).kitLabelsHidden()
      }
      .preview(height: EditorPreview.height(lines: 3, configuration: editor.configuration)) {
        EditorPreview(
          text: PreviewSample.currentLine, configuration: editor.configuration, breakpoints: breakpointsEnabled ? [1] : [])
      }
    }
    FormCard {
      FormRow(
        String(localized: "Android Debug Bridge"),
        help: tools.adb ?? String(localized: "Not found — brew install android-platform-tools"),
        systemImage: "iphone", hue: tools.adb == nil ? .gray : .green)
    }
    .onAppear { tools.refresh() }
  }
}

extension Array {
  /// The installed tools, then the others, each group in the catalog's order.
  fileprivate func installedFirst(_ isInstalled: (Element) -> Bool) -> [Element] {
    filter(isInstalled) + filter { !isInstalled($0) }
  }
}

/// A tool's row: what it is for and where it is installed, with Uninstall, its switch and `controls`, a line of small
/// controls under it (a formatter's config-file check and custom command); only Install while it isn't installed.
private struct ToolRow<Controls: View>: View {
  let name: String
  let detail: String
  let source: String
  let path: String?
  @Binding var isOn: Bool
  let installCommand: String?
  let toolID: String
  /// The command on the PATH: what Uninstall removes, which isn't a formatter's custom command.
  let command: String
  let systemImage: String
  let hue: Hue
  @ViewBuilder var controls: Controls
  private var tools: ToolsModel { .shared }
  @State private var uninstallPlan: ToolUninstallPlan?
  @State private var isConfirmingUninstall = false

  var body: some View {
    Group {
      if Controls.self == EmptyView.self || path == nil {
        row
      } else {
        row.detail { controls }
      }
    }
    .help(path ?? source)
    .kitDialog(
      uninstallTitle, isPresented: $isConfirmingUninstall, message: uninstallMessage, systemImage: "trash",
      hue: uninstallCommand == nil ? .gray : .red, confirm: uninstallCommand == nil ? String(localized: "OK") : String(localized: "Uninstall"),
      role: uninstallCommand == nil ? nil : .destructive
    ) {
      if let uninstallCommand { KitCodeBlock(uninstallCommand) }
    } action: {
      if let uninstallCommand { tools.uninstall(id: toolID, command: uninstallCommand) }
    }
  }

  private var uninstallCommand: String? {
    if case .command(let command, _) = uninstallPlan { command } else { nil }
  }

  private var uninstallTitle: String {
    uninstallCommand == nil ? String(localized: "Can’t Uninstall \(name)") : String(localized: "Uninstall \(name)?")
  }

  private var uninstallMessage: String? {
    switch uninstallPlan {
    case .command(_, let note): note ?? String(localized: "Code will run this command.")
    case .unknown(let reason): reason
    case nil: nil
    }
  }

  private var row: FormRow<some View, EmptyView> {
    let running = tools.installer.running[toolID]
    return FormRow(
      name, help: running ?? help, systemImage: systemImage, hue: path == nil ? .gray : hue,
      error: running == nil ? tools.uninstallFailures[toolID] : nil
    ) {
      if running != nil {
        LiveIcon(systemImage: tools.uninstalling.contains(toolID) ? "trash" : "arrow.down", status: .working, size: 20)
      } else if path != nil {
        HStack(spacing: 8) {
          if tools.paths[command] != nil {
            Button("Uninstall") {
              uninstallPlan = tools.uninstallPlan(command: command, installCommand: installCommand)
              isConfirmingUninstall = uninstallPlan != nil
            }
            .buttonStyle(.kit)
          }
          Toggle(name, isOn: $isOn).kitLabelsHidden()
        }
      } else if !tools.hasFoundTools {
        LiveIcon(systemImage: "magnifyingglass", status: .working, size: 20)
      } else if let installCommand {
        Button("Install") { tools.install(id: toolID, command: installCommand) }
          .buttonStyle(.kit)
          .help(installCommand)
      } else {
        // Comes with Xcode or an SDK: nothing to install from here, and nothing to switch.
        Chip("Not installed", style: .quiet)
      }
    }
  }

  /// "Swift, C · /usr/bin/sourcekit-lsp", or where it comes from while it isn't installed.
  private var help: String {
    if let path { return "\(detail) · \(path)" }
    return installCommand == nil && !source.isEmpty ? "\(detail) · \(source)" : String(localized: "\(detail) · Not installed")
  }
}

extension ToolRow where Controls == EmptyView {
  init(
    name: String, detail: String, source: String, path: String?, isOn: Binding<Bool>, installCommand: String?,
    toolID: String, command: String, systemImage: String, hue: Hue
  ) {
    self.init(
      name: name, detail: detail, source: source, path: path, isOn: isOn, installCommand: installCommand,
      toolID: toolID, command: command, systemImage: systemImage, hue: hue
    ) { EmptyView() }
  }
}
