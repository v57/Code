import Foundation
import Testing

@testable import CodeKit

/// The symbol menu's words and rows, from the tiers' answers (the boards `code-05` and `code-06`).
@Suite struct SymbolMenuContentTests {
  let root = URL(fileURLWithPath: "/p")
  var store: URL { root.appendingPathComponent("Sources/Atlas/TripStore.swift") }
  var tripFile: URL { root.appendingPathComponent("Sources/Atlas/Trip.swift") }

  func place(_ url: URL, _ line: Int) -> DefinitionPlace { DefinitionPlace(url: url, line: line, column: 2, name: "") }

  var module: SymbolInfo {
    SymbolInfo(kind: .module, name: "Atlas", place: place(root.appendingPathComponent("Package.swift"), 11), module: "Atlas")
  }
  var tripStore: SymbolInfo { SymbolInfo(kind: .classType, name: "TripStore", keyword: "class", place: place(store, 5), module: "Atlas") }
  var trip: SymbolInfo { SymbolInfo(kind: .structure, name: "Trip", keyword: "struct", place: place(tripFile, 2), module: "Atlas") }

  @Test func aMethodJumpsInThisFileAndListsItsParents() throws {
    let save = SymbolDescription(
      symbol: SymbolInfo(kind: .function, name: "save()", keyword: "func", place: place(store, 30), module: "Atlas"),
      declaration: "private func save() throws", parents: [tripStore, module])
    let content = try #require(
      SymbolMenuContent.make(
        [SymbolAnswer(tier: .model, isSure: true, symbols: [save])], pendingServer: nil, references: 2, file: store,
        root: root))
    #expect(content.path.map(\.name) == ["Atlas", "TripStore", "save()"])
    #expect(content.rows.map(\.title) == ["Jump to Definition", "class TripStore", "Atlas", "Find References", "Copy Qualified Name"])
    #expect(content.rows.map(\.trail) == ["Line 31", "Line 6", "Package.swift:12", "2", nil])
    #expect(content.rows[1].section == "Inside")
    #expect(content.rows[3].separated)
    #expect(content.rows[0].preview == "Goes to line 31 in this file. A click on the symbol does the same.")
    #expect(content.rows[1].preview == "Goes to line 6, where class TripStore begins.")
    #expect(content.rows.allSatisfy { !$0.isGuess })
    #expect(content.footer == nil)
    #expect(content.rows.last?.action == .copy("Atlas.TripStore.save()"))
    #expect(content.rows[3].action == .findReferences("save"))
  }

  @Test func aLocalJumpsToItsType() throws {
    let local = SymbolDescription(
      symbol: SymbolInfo(kind: .local, name: "trip", keyword: "let", place: place(store, 17), module: "Atlas"),
      declaration: "let trip: Trip",
      parents: [SymbolInfo(kind: .function, name: "create(named:from:days:)", keyword: "func", place: place(store, 16)), tripStore, module],
      type: trip)
    let content = try #require(
      SymbolMenuContent.make(
        [SymbolAnswer(tier: .model, isSure: true, symbols: [local])], pendingServer: nil, references: nil, file: store,
        root: root))
    #expect(content.path.map(\.name) == ["TripStore", "create(named:from:days:)", "trip"])
    #expect(content.rows.map(\.title) == ["Jump to Definition", "Jump to Type: Trip", "func create(named:from:days:)", "class TripStore", "Find References"])
    #expect(content.rows[1].trail == "Trip.swift:3")
    #expect(content.rows[1].preview == "Opens Trip.swift at line 3, where struct Trip begins.")
    #expect(content.parents.first?.name == "create(named:from:days:)")
  }

  @Test func severalPlacesAreOneRowEachAndInsideFollowsTheHighlight() throws {
    let identifiable = SymbolInfo(kind: .protocolType, name: "Identifiable", keyword: "protocol", place: place(URL(fileURLWithPath: "/sdk/Swift.swiftinterface"), 900), module: "Swift", isSDK: true)
    let swift = SymbolInfo(kind: .module, name: "Swift", place: nil, module: "Swift", isSDK: true)
    let own = SymbolDescription(
      symbol: SymbolInfo(kind: .property, name: "id", keyword: "let", place: place(tripFile, 3), module: "Atlas"),
      declaration: "public let id: UUID", parents: [trip, module])
    let requirement = SymbolDescription(
      symbol: SymbolInfo(kind: .property, name: "id", keyword: "var", place: place(URL(fileURLWithPath: "/sdk/Swift.swiftinterface"), 901), module: "Swift", isSDK: true),
      parents: [identifiable, swift])
    let answers = [SymbolAnswer(tier: .model, isSure: false, symbols: [own, requirement])]
    let content = try #require(SymbolMenuContent.make(answers, pendingServer: nil, references: 9, file: store, root: root))
    #expect(content.hasSeveralPlaces)
    #expect(content.path.map(\.name) == ["Trip", "id"])
    #expect(content.summary == "2 places declare `id`: ⌘-click shows this menu instead of jumping.")
    #expect(content.rows.map(\.title) == ["Trip.id", "Identifiable.id", "struct Trip", "Find References"])
    #expect(content.rows.map(\.detail) == ["In struct Trip, Atlas", "A requirement of protocol Identifiable", nil, nil])
    #expect(content.rows.map(\.trail) == ["Trip.swift:4", "Swift", "Trip.swift:3", "9"])
    #expect(content.rows[0].section == "Definitions")
    #expect(content.rows[2].section == "Inside")
    #expect(content.rows[1].preview == "Opens Swift’s interface at var id.")
    let second = try #require(SymbolMenuContent.make(answers, pendingServer: nil, references: 9, file: store, root: root, highlighted: 1))
    #expect(second.rows.map(\.title) == ["Trip.id", "Identifiable.id", "protocol Identifiable", "Find References"])
  }

  @Test func overloadsAreToldApartByTheirDeclarations() throws {
    let atlas = [module]
    let answers = [
      SymbolAnswer(
        tier: .model, isSure: false,
        symbols: [
          SymbolDescription(
            symbol: SymbolInfo(kind: .function, name: "describe(_:)", keyword: "func", place: place(store, 20), module: "Atlas"),
            declaration: "public func describe(_ value: Int) -> String", parents: atlas),
          SymbolDescription(
            symbol: SymbolInfo(kind: .function, name: "describe(_:)", keyword: "func", place: place(store, 21), module: "Atlas"),
            declaration: "public func describe(_ value: String) -> String", parents: atlas),
        ])
    ]
    let content = try #require(SymbolMenuContent.make(answers, pendingServer: nil, references: nil, file: store, root: root))
    #expect(content.rows.prefix(2).map(\.detail) == ["public func describe(_ value: Int) -> String", "public func describe(_ value: String) -> String"])
  }

  @Test func theGuessShowsUntilTheServerAnswersInPlace() throws {
    let guess = SymbolDescription(
      symbol: SymbolInfo(kind: .initializer, name: "init(contentsOf:options:)", keyword: "init", place: place(URL(fileURLWithPath: "/sdk/Foundation.swiftinterface"), 40), module: "Foundation", isSDK: true),
      declaration: "init(contentsOf url: URL, options: Data.ReadingOptions = []) throws",
      parents: [
        SymbolInfo(kind: .structure, name: "Data", keyword: "struct", place: place(URL(fileURLWithPath: "/sdk/Foundation.swiftinterface"), 10), module: "Foundation", isSDK: true),
        SymbolInfo(kind: .module, name: "Foundation", place: nil, module: "Foundation", isSDK: true),
      ])
    let model = SymbolAnswer(tier: .model, isSure: false, symbols: [guess])
    let waiting = try #require(
      SymbolMenuContent.make([model], pendingServer: "sourcekit-lsp", references: nil, file: store, root: root))
    #expect(waiting.rows[0].isGuess)
    #expect(waiting.rows.map(\.trail).prefix(3) == ["Foundation", "Foundation", "SDK"])
    #expect(waiting.footer == "From the Swift model. sourcekit-lsp is still checking.")
    #expect(waiting.rows[2].action == .none)
    // The server says the same place: the rows stay, without GUESS.
    let server = SymbolAnswer(tier: .server, isSure: true, symbols: [SymbolDescription(symbol: SymbolInfo(kind: .other, name: "", place: guess.symbol.place))])
    let answered = try #require(
      SymbolMenuContent.make([model, server], pendingServer: nil, references: nil, file: store, root: root))
    #expect(answered.rows.map(\.id) == waiting.rows.map(\.id))
    #expect(answered.rows.allSatisfy { !$0.isGuess })
    #expect(answered.footer == nil)
    #expect(answered.declaration == guess.declaration)
    #expect(answered.path.map(\.name) == ["Foundation", "Data", "init(contentsOf:options:)"])
  }

  @Test func aCallOfATypeIsItsInitializer() throws {
    let interface = URL(fileURLWithPath: "/sdk/Foundation.swiftinterface")
    let data = SymbolInfo(kind: .structure, name: "Data", keyword: "struct", place: place(interface, 10), module: "Foundation", isSDK: true)
    let foundation = SymbolInfo(kind: .module, name: "Foundation", place: nil, module: "Foundation", isSDK: true)
    let answers = [
      SymbolAnswer(
        tier: .model, isSure: false,
        symbols: [
          SymbolDescription(
            symbol: SymbolInfo(kind: .initializer, name: "init(contentsOf:options:)", keyword: "init", place: place(interface, 40), module: "Foundation", isSDK: true),
            parents: [data, foundation]),
          SymbolDescription(symbol: data, parents: [foundation]),
        ])
    ]
    let content = try #require(SymbolMenuContent.make(answers, pendingServer: nil, references: nil, file: store, root: root))
    #expect(!content.hasSeveralPlaces)
    #expect(content.rows.first?.title == "Jump to Definition")
    #expect(content.rows.first?.preview == "Opens Foundation’s interface at init(contentsOf:options:).")
  }

  @Test func nothingToShowWithoutAPlace() {
    #expect(SymbolMenuContent.make([], pendingServer: "x", references: nil, file: store, root: root) == nil)
  }
}
