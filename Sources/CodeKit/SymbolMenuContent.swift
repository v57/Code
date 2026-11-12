import Foundation

// What the symbol menu (⌘ held over a symbol, or a ⌘-click with several places) says, built from the tiers' answers:
// platform-neutral and without views, so the app draws it and the tests read it.

/// A symbol, or a declaration around it (its type, its module).
public struct SymbolInfo: Hashable, Sendable {
  public enum Kind: String, Sendable {
    case module, structure, classType, actor, enumeration, protocolType, extensionDecl
    case function, method, initializer, subscriptDecl, property, variable, local, parameter, enumCase
    case typeAlias, macro, generic, other
  }

  public var kind: Kind
  /// What it's called where it's used: `Trip`, `init(name:start:days:)`, `trip`.
  public var name: String
  /// The word that declares it (`struct`, `func`, `let`); empty for a module.
  public var keyword: String
  /// Where its name is; nil for what can't be opened (a module without a manifest).
  public var place: DefinitionPlace?
  /// The module it's in.
  public var module: String
  /// Declared in the SDK.
  public var isSDK: Bool

  public init(
    kind: Kind, name: String, keyword: String = "", place: DefinitionPlace?, module: String = "", isSDK: Bool = false
  ) {
    self.kind = kind
    self.name = name
    self.keyword = keyword
    self.place = place
    self.module = module
    self.isSDK = isSDK
  }

  /// `struct Trip`, `func create(named:from:days:)`; a module by its name.
  /// `struct Trip`, `func save()`; `init(name:)` says its keyword already.
  public var title: String {
    keyword.isEmpty || kind == .module || name.hasPrefix(keyword + "(") || name == keyword ? name : keyword + " " + name
  }

  public var isType: Bool {
    switch kind {
    case .structure, .classType, .actor, .enumeration, .protocolType, .extensionDecl, .typeAlias, .generic: return true
    default: return false
    }
  }

  public var isValue: Bool { kind == .local || kind == .parameter }
}

/// One place a symbol is declared, with what the menu shows about it.
public struct SymbolDescription: Hashable, Sendable {
  public var symbol: SymbolInfo
  /// On one line, without attributes or body.
  public var declaration: String?
  /// The doc comment's first paragraph, Markdown.
  public var documentation: String?
  /// What it's inside, nearest first, ending with its module when known.
  public var parents: [SymbolInfo]
  /// A value's type, when that's a declared type.
  public var type: SymbolInfo?

  public init(
    symbol: SymbolInfo, declaration: String? = nil, documentation: String? = nil, parents: [SymbolInfo] = [],
    type: SymbolInfo? = nil
  ) {
    self.symbol = symbol
    self.declaration = declaration
    self.documentation = documentation
    self.parents = parents
    self.type = type
  }

  /// `Atlas.Trip.init(name:start:days:)`.
  public var qualifiedName: String {
    (parents.reversed().map(\.name) + [symbol.name]).filter { !$0.isEmpty }.joined(separator: ".")
  }
}

/// One tier's answer about a symbol.
public struct SymbolAnswer: Sendable, Equatable {
  public var tier: DefinitionTier
  /// The Swift model's exact answer, or the language server's.
  public var isSure: Bool
  public var symbols: [SymbolDescription]

  public init(tier: DefinitionTier, isSure: Bool, symbols: [SymbolDescription]) {
    self.tier = tier
    self.isSure = isSure
    self.symbols = symbols
  }
}

/// What the menu shows.
public struct SymbolMenuContent: Equatable, Sendable {
  public enum Icon: Hashable, Sendable {
    case jump, references, copy
    case kind(SymbolInfo.Kind)
  }

  public enum Action: Hashable, Sendable {
    case open(DefinitionPlace)
    case findReferences(String)
    case copy(String)
    /// Nothing to do (a module in the SDK).
    case none
  }

  public struct Row: Identifiable, Equatable, Sendable {
    /// Stays the same as answers replace each other, so a row keeps its place and its highlight.
    public var id: String
    /// A header above it (`Inside`, `Definitions`).
    public var section: String?
    /// A line above it (or above its header).
    public var separated = false
    public var icon: Icon
    public var title: String
    /// A second line (several definitions: where each is).
    public var detail: String?
    /// At its end: `Trip.swift:14`, `Line 31`, a count.
    public var trail: String?
    /// A guess the language server is still checking, or that only a guessing tier gave.
    public var isGuess = false
    /// What picking it does, for the panel at the menu's end.
    public var preview: String
    public var action: Action
    /// Which definition it is (several places): the menu's Inside follows the highlighted one.
    public var definition: Int?

    public var isEnabled: Bool { action != .none }
  }

  /// Where it lives: the module, types and functions around it, then the symbol (three at most).
  public var path: [SymbolInfo]
  public var declaration: String?
  /// Its summary; with several places, says so.
  public var summary: String?
  public var rows: [Row]
  /// Who answered while the language server is still checking.
  public var footer: String?
  /// Several places declare it.
  public var hasSeveralPlaces: Bool
  /// The parents ⌘↑ goes to, nearest first.
  public var parents: [SymbolInfo]

  /// The menu for the tiers' answers so far; nil while none has a place.
  ///
  /// - `pendingServer`: the language server's name while it is still checking.
  /// - `references`: how many places use the symbol, when known.
  /// - `highlighted`: the definition row highlighted (several places): Inside follows it.
  public static func make(
    _ answers: [SymbolAnswer], pendingServer: String?, references: Int?, file: URL, root: URL,
    highlighted: Int? = nil
  ) -> SymbolMenuContent? {
    let rows = merged(answers)
    guard let first = rows.first else { return nil }
    let file = file.standardizedFileURL
    let root = root.standardizedFileURL
    var built: [Row] = []
    let several = rows.count > 1
    let lead = first.description
    func trail(_ info: SymbolInfo) -> String? { Self.trail(info, file: file, root: root) }

    if several {
      let titles = rows.map { Self.ownerName($0.description) }
      for (index, row) in rows.enumerated() {
        let symbol = row.description.symbol
        // Overloads share a title: their declarations tell them apart.
        let isOverload = titles.filter { $0 == titles[index] }.count > 1
        let detail = isOverload ? row.description.declaration ?? Self.detail(row.description) : Self.detail(row.description)
        built.append(
          Row(
            id: "place.\(index)", section: index == 0 ? "Definitions" : nil, icon: .kind(symbol.kind),
            title: titles[index], detail: detail, trail: trail(symbol),
            isGuess: !row.isSure, preview: Self.openSentence(symbol, file: file, root: root, own: true),
            action: symbol.place.map(Action.open) ?? .none, definition: index))
      }
    } else {
      let symbol = lead.symbol
      var preview = Self.openSentence(symbol, file: file, root: root, own: true)
      if first.isSure { preview += " A click on the symbol does the same." }
      built.append(
        Row(
          id: "definition", icon: .jump, title: "Jump to Definition", trail: trail(symbol), isGuess: !first.isSure,
          preview: preview, action: symbol.place.map(Action.open) ?? .none))
      if let type = lead.type {
        built.append(
          Row(
            id: "type", icon: .kind(type.kind), title: "Jump to Type: " + type.name, trail: trail(type),
            preview: Self.openSentence(type, file: file, root: root, own: false),
            action: type.place.map(Action.open) ?? .none))
      }
    }

    // Inside: the highlighted definition's parents, the ones the path shows.
    let focus = several ? rows[min(max(highlighted ?? 0, 0), rows.count - 1)] : first
    let shownParents = Array(focus.description.parents.prefix(several ? 1 : 2))
    for (index, parent) in shownParents.enumerated() {
      built.append(
        Row(
          id: "parent.\(index)", section: index == 0 ? "Inside" : nil, separated: index == 0 && several,
          icon: .kind(parent.kind), title: parent.title, trail: trail(parent),
          preview: Self.openSentence(parent, file: file, root: root, own: false),
          action: parent.place.map(Action.open) ?? .none))
    }

    let name = lead.symbol.name
    let bare = Self.bareName(name)
    let count = references.map { "\($0)" }
    built.append(
      Row(
        id: "references", separated: true, icon: .references, title: "Find References", trail: count,
        preview: references.map { String(localized: "Lists the \($0) places that use \(name) in Find in Project.") }
          ?? String(localized: "Lists the places that use \(name) in Find in Project."),
        action: .findReferences(bare)))
    if !several, !lead.symbol.isValue {
      let qualified = lead.qualifiedName
      built.append(
        Row(id: "copy", icon: .copy, title: "Copy Qualified Name", preview: "Copies \(qualified).", action: .copy(qualified)))
    }

    let path = Array((lead.parents.reversed() + [lead.symbol]).suffix(several ? 2 : 3))
    var summary = lead.documentation
    if several {
      summary = String(localized: "\(rows.count) places declare `\(bare)`: ⌘-click shows this menu instead of jumping.")
    }
    var footer: String?
    if let pendingServer, !first.isSure || rows.contains(where: { !$0.isSure }) {
      footer = "From \(Self.tierName(first.tier)). \(pendingServer) is still checking."
    }
    return SymbolMenuContent(
      path: path, declaration: lead.declaration, summary: summary, rows: built, footer: footer,
      hasSeveralPlaces: several, parents: focus.description.parents)
  }

  /// One definition from every answer: a sure answer's first, then the better tier's; one row per place.
  struct Merged: Equatable {
    var description: SymbolDescription
    var tier: DefinitionTier
    var isSure: Bool
  }

  static func merged(_ answers: [SymbolAnswer]) -> [Merged] {
    let ordered = answers.filter { !$0.symbols.isEmpty }.sorted { ($0.isSure ? 1 : 0, $0.tier) > ($1.isSure ? 1 : 0, $1.tier) }
    guard let best = ordered.first else { return [] }
    // The best answer decides how many places there are; worse tiers only fill in what it doesn't say.
    var result: [Merged] = []
    var seen = Set<String>()
    for symbol in best.symbols {
      let key = symbol.symbol.place?.key ?? symbol.symbol.name
      guard seen.insert(key).inserted else { continue }
      var filled = symbol
      for other in ordered.dropFirst() {
        guard let same = other.symbols.first(where: { $0.symbol.place?.key == symbol.symbol.place?.key }) else { continue }
        if filled.declaration == nil { filled.declaration = same.declaration }
        if filled.documentation == nil { filled.documentation = same.documentation }
        if filled.parents.isEmpty { filled.parents = same.parents }
        if filled.type == nil { filled.type = same.type }
        // A place with nothing said about it (a language server's): the other tier's symbol, at this place.
        if filled.symbol.kind == .other || filled.symbol.name.isEmpty {
          var symbol = same.symbol
          symbol.place = filled.symbol.place ?? symbol.place
          filled.symbol = symbol
        }
      }
      result.append(Merged(description: filled, tier: best.tier, isSure: best.isSure))
    }
    // `Data(…)` names the type and its initializer: the initializer is the place.
    let initializedTypes = Set(
      result.compactMap { $0.description.symbol.kind == .initializer ? $0.description.parents.first?.place?.key : nil })
    if !initializedTypes.isEmpty {
      result.removeAll { $0.description.symbol.isType && $0.description.symbol.place.map { initializedTypes.contains($0.key) } == true }
    }
    return result
  }

  // MARK: Words

  static func tierName(_ tier: DefinitionTier) -> String {
    switch tier {
    case .scanner: return "Code’s scanner"
    case .model: return "the Swift model"
    case .server: return "the language server"
    }
  }

  /// `Line 31` in this file, `Trip.swift:3` in another, the module for the SDK's; a module: its manifest's line or
  /// `SDK`.
  static func trail(_ info: SymbolInfo, file: URL, root: URL) -> String? {
    if info.kind == .module {
      if info.isSDK { return "SDK" }
      guard let place = info.place else { return nil }
      return "\(place.url.lastPathComponent):\(place.line + 1)"
    }
    if info.isSDK { return info.module.isEmpty ? "SDK" : info.module }
    guard let place = info.place else { return nil }
    if place.url == file { return "Line \(place.line + 1)" }
    return "\(place.url.lastPathComponent):\(place.line + 1)"
  }

  /// What opening it does.
  static func openSentence(_ info: SymbolInfo, file: URL, root: URL, own: Bool) -> String {
    guard let place = info.place else {
      return info.kind == .module ? "\(info.name) comes with the SDK." : "Its place isn’t known."
    }
    let line = place.line + 1
    if info.kind == .module {
      return "Opens \(place.url.lastPathComponent) at line \(line), where target \(info.name) is declared."
    }
    if info.isSDK {
      let module = info.module.isEmpty ? "the SDK" : info.module + "’s"
      return "Opens \(module) interface at \(info.title)."
    }
    if place.url == file {
      return own ? "Goes to line \(line) in this file." : "Goes to line \(line), where \(info.title) begins."
    }
    return own
      ? "Opens \(place.url.lastPathComponent) at line \(line)."
      : "Opens \(place.url.lastPathComponent) at line \(line), where \(info.title) begins."
  }

  /// `Trip.id`, `Identifiable.id`: a member by its type.
  static func ownerName(_ description: SymbolDescription) -> String {
    guard let owner = description.parents.first, owner.kind != .module else { return description.symbol.name }
    return owner.name + "." + description.symbol.name
  }

  /// `In struct Trip, Atlas`, `A requirement of protocol Identifiable`.
  static func detail(_ description: SymbolDescription) -> String? {
    guard let owner = description.parents.first else { return nil }
    if owner.kind == .protocolType { return "A requirement of protocol \(owner.name)" }
    if owner.kind == .module { return "In \(owner.name)" }
    let module = description.parents.last.flatMap { $0.kind == .module && $0 != owner ? $0.name : nil }
    return "In \(owner.title)" + (module.map { ", " + $0 } ?? "")
  }

  /// `save()` → `save`, `init(name:)` → `init`.
  static func bareName(_ name: String) -> String {
    String(name.prefix { $0 != "(" })
  }
}
