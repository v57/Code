import CodeKit
import Foundation
import Observation
import VaultKit

/// A window's run presets: those kept on this Mac in the project's `.dev/actions.json` (read again when the file
/// changes, by hand too) and those kept in the vault for the project (`VaultProjectPreset`), in one order the bar shows
/// and ⌘1…⌘9 follow.
@MainActor @Observable final class RunPresets {
  /// Where a preset is kept.
  enum Place: Hashable {
    /// The preset's index in the file.
    case file(Int)
    case vault(VaultProjectPreset)
  }

  struct Item: Identifiable, Hashable {
    var preset: RunPreset
    var place: Place
    /// "file:<name>" or "vault:<record id>": stable while it's renamed in place, for the bar's order and the running
    /// action's tag.
    var id: String

    var isInVault: Bool { if case .vault = place { true } else { false } }
  }

  let root: URL
  private let actions: ActionController
  /// The window's account's vault, set by the bar (its view has it).
  var vault: Vault? {
    didSet { if vault !== oldValue { refresh() } }
  }
  private(set) var filePresets: [RunPreset] = []
  /// Why `.dev/actions.json` couldn't be read; its presets stay as last read meanwhile.
  private(set) var fileError: String?
  /// The bar's order, by item id, as last dragged (unknown ones go after, the file's then the vault's).
  private var order: [String] {
    didSet { UserDefaults.standard.set(order, forKey: orderKey) }
  }
  @ObservationIgnored private let orderKey: String

  init(root: URL, actions: ActionController) {
    self.root = root
    self.actions = actions
    orderKey = "presets.order:" + root.path
    order = UserDefaults.standard.stringArray(forKey: "presets.order:" + root.path) ?? []
    reloadFile()
  }

  var fileURL: URL { RunPresetFile.url(in: root) }

  /// The vault's project for this folder, when it is one.
  var vaultProject: VaultProject? { vault?.project(atPath: root.path) }

  /// Every preset in the bar's order.
  var items: [Item] {
    var all = filePresets.enumerated().map { Item(preset: $1, place: .file($0), id: "file:" + $1.name) }
    // The same name twice in the file: the later one keeps its place by its index.
    var seen: Set<String> = []
    for index in all.indices where !seen.insert(all[index].id).inserted { all[index].id += "#\(index)" }
    if let project = vaultProject, let vault {
      all += vault.presets(of: project.id).compactMap { record in
        guard let action = ActionKind(rawValue: record.action) else { return nil }
        let preset = RunPreset(
          name: record.name, action: action, from: record.from, project: record.project, scheme: record.scheme,
          target: record.target)
        return Item(preset: preset, place: .vault(record), id: "vault:" + record.id)
      }
    }
    let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    return all.enumerated()
      .sorted { (rank[$0.element.id] ?? order.count + $0.offset) < (rank[$1.element.id] ?? order.count + $1.offset) }
      .map(\.element)
  }

  // MARK: - Reading

  /// Reads `.dev/actions.json` again.
  func reloadFile() {
    do {
      let presets = try RunPresetFile.read(in: root)
      if presets != filePresets { filePresets = presets }
      fileError = nil
    } catch RunPresetFile.ReadError.newerVersion(let version) {
      fileError = "\(RunPresetFile.fileName) is version \(version), from a newer Code."
    } catch {
      fileError = "\(RunPresetFile.fileName) isn’t valid JSON: \(error.localizedDescription)"
    }
    refresh()
  }

  /// The project's files changed: reads the file again when it was among them (or its folder came or went).
  func filesChanged(_ urls: [URL]) {
    let file = fileURL.standardizedFileURL.path
    let folder = fileURL.deletingLastPathComponent().standardizedFileURL.path
    if urls.contains(where: { [file, folder].contains($0.standardizedFileURL.path) }) { reloadFile() }
  }

  /// Lists the devices the presets name, so the bar can tell which are gone.
  func refresh() {
    actions.refreshPresetDestinations(for: items.map(\.preset))
  }

  // MARK: - Changing

  /// Adds a preset at the end of the bar, in the file or the vault.
  func add(_ preset: RunPreset, inVault: Bool) {
    if inVault {
      saveToVault(preset, replacing: nil)
    } else {
      writeFile(filePresets + [preset])
    }
  }

  /// Replaces an item's preset in place (Edit…, Rename), keeping it where it is kept, or moving it when `inVault`
  /// says another place.
  func update(_ item: Item, with preset: RunPreset, inVault: Bool? = nil) {
    let toVault = inVault ?? item.isInVault
    // The bar's order as it is now, so the item keeps its place under its new id.
    if !order.contains(item.id) { order = items.map(\.id) }
    switch (item.place, toVault) {
    case (.file, false):
      guard let index = fileIndex(of: item) else { return }
      var presets = filePresets
      presets[index] = preset
      // Its order follows the new name.
      replaceInOrder(item.id, with: "file:" + preset.name)
      writeFile(presets)
    case (.vault(let record), true):
      saveToVault(preset, replacing: record)
    case (.file, true):
      guard let index = fileIndex(of: item) else { return }
      let id = saveToVault(preset, replacing: nil)
      replaceInOrder(item.id, with: id.map { "vault:" + $0 })
      var presets = filePresets
      presets.remove(at: index)
      writeFile(presets)
    case (.vault(let record), false):
      replaceInOrder(item.id, with: "file:" + preset.name)
      writeFile(filePresets + [preset])
      vault?.delete(record)
    }
  }

  /// Keep in Vault: moves a preset from the file to the vault, or back.
  func toggleVault(_ item: Item) {
    update(item, with: item.preset, inVault: !item.isInVault)
  }

  func remove(_ item: Item) {
    switch item.place {
    case .file:
      guard let index = fileIndex(of: item) else { return }
      var presets = filePresets
      presets.remove(at: index)
      writeFile(presets)
    case .vault(let record):
      vault?.delete(record)
    }
    order.removeAll { $0 == item.id }
    refresh()
  }

  /// A drag on the bar: `item` goes before `target` (at the end without one). The file and the vault keep the new
  /// order among their own presets too.
  func move(_ item: Item, before target: Item?) {
    var ids = items.map(\.id)
    guard let from = ids.firstIndex(of: item.id), item.id != target?.id else { return }
    ids.remove(at: from)
    let to = target.flatMap { ids.firstIndex(of: $0.id) } ?? ids.count
    ids.insert(item.id, at: to)
    order = ids
    let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let ordered = ids.compactMap { byID[$0] }
    let file = ordered.filter { !$0.isInVault }.map(\.preset)
    if file != filePresets { writeFile(file) }
    if let vault {
      for (index, item) in ordered.filter(\.isInVault).enumerated() {
        if case .vault(var record) = item.place, record.order != index {
          record.order = index
          vault.save(record)
        }
      }
    }
  }

  private func fileIndex(of item: Item) -> Int? {
    guard case .file(let index) = item.place, filePresets.indices.contains(index) else { return nil }
    return index
  }

  private func replaceInOrder(_ id: String, with new: String?) {
    guard let index = order.firstIndex(of: id) else { return }
    if let new { order[index] = new } else { order.remove(at: index) }
  }

  private func writeFile(_ presets: [RunPreset]) {
    do {
      try RunPresetFile.write(presets, in: root)
      filePresets = presets
      fileError = nil
    } catch {
      fileError = "Couldn’t write \(RunPresetFile.displayPath(in: root)): \(error.localizedDescription)"
    }
    refresh()
  }

  /// Saves a preset in the vault under this folder's project, adding the folder to the vault's projects first when it
  /// isn't one. Returns the record's id.
  @discardableResult
  private func saveToVault(_ preset: RunPreset, replacing record: VaultProjectPreset?) -> String? {
    guard let vault else { return nil }
    if vaultProject == nil {
      let root = root
      vault.perform { try $0.addProject(path: root.path, remoteURL: Self.originURL(of: root)) }
    }
    guard let project = vaultProject else { return nil }
    let order = record?.order ?? ((vault.presets(of: project.id).map(\.order).max() ?? -1) + 1)
    let saved = VaultProjectPreset(
      id: record?.id ?? UUID().uuidString, projectID: project.id, name: preset.name, action: preset.action.rawValue,
      from: preset.from, project: preset.project, scheme: preset.scheme, target: preset.target, order: order)
    vault.save(saved)
    refresh()
    return saved.id
  }

  /// The `origin` remote in the folder's `.git/config`, so the vault's project is the repository's on every device.
  nonisolated static func originURL(of root: URL) -> String? {
    guard let config = try? String(contentsOf: root.appendingPathComponent(".git/config"), encoding: .utf8) else {
      return nil
    }
    var inOrigin = false
    for line in config.split(separator: "\n") {
      let text = line.trimmingCharacters(in: .whitespaces)
      if text.hasPrefix("[") {
        inOrigin = text == "[remote \"origin\"]"
      } else if inOrigin, text.hasPrefix("url") {
        let parts = text.split(separator: "=", maxSplits: 1)
        if parts.count == 2 { return parts[1].trimmingCharacters(in: .whitespaces) }
      }
    }
    return nil
  }

  // MARK: - Running

  /// Runs a preset with its own choices; the toolbar stays as it is.
  func run(_ item: Item) {
    actions.perform(preset: item.preset, tag: item.id)
  }

  func isRunning(_ item: Item) -> Bool {
    actions.isRunning(tag: item.id)
  }

  func state(of item: Item) -> RunPresetState {
    actions.state(of: item.preset)
  }

  /// Where it's kept, for its tooltip and menu.
  func placeDescription(_ item: Item) -> String {
    item.isInVault ? "In the Vault." : "In \(RunPresetFile.folder)/\(RunPresetFile.fileName)."
  }
}
