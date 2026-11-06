import Foundation
import Testing

@testable import CodeKit

@Suite struct DefinitionChoicesTests {
  func place(_ file: String, _ line: Int) -> DefinitionPlace {
    DefinitionPlace(url: URL(fileURLWithPath: "/p/\(file)"), line: line, column: 0, name: "x")
  }

  func answer(_ tier: DefinitionTier, sure: Bool, _ places: DefinitionPlace...) -> DefinitionAnswer {
    DefinitionAnswer(tier: tier, isSure: sure, places: places)
  }

  @Test func anExactModelAnswerJumpsWithoutWaitingForTheScanner() {
    var choices = DefinitionChoices(asking: [.scanner, .model])
    #expect(choices.receive(answer(.model, sure: true, place("A.swift", 3)), from: .model) == .jump(place("A.swift", 3)))
    #expect(choices.isFinished)
    #expect(choices.receive(answer(.scanner, sure: false, place("B.swift", 1)), from: .scanner) == .none)
  }

  @Test func theScannerNeverJumpsOnItsOwnWhileABetterTierWasAsked() {
    var choices = DefinitionChoices(asking: [.scanner, .model])
    #expect(choices.receive(answer(.scanner, sure: false, place("A.swift", 3)), from: .scanner) == .wait)
    // The model answers nothing: the scanner's one place is offered, not jumped to.
    guard case .show(let rows, 0) = choices.receive(nil, from: .model) else {
      Issue.record("expected a menu")
      return
    }
    #expect(rows.map(\.place) == [place("A.swift", 3)])
  }

  @Test func theScannerAloneJumpsForALanguageWithNothingBetter() {
    var choices = DefinitionChoices(asking: [.scanner])
    #expect(choices.receive(answer(.scanner, sure: false, place("a.lua", 9)), from: .scanner) == .jump(place("a.lua", 9)))
  }

  @Test func guessesShowAfterTheWaitAndASureAnswerTakesTheTop() {
    var choices = DefinitionChoices(asking: [.scanner, .model])
    _ = choices.receive(answer(.scanner, sure: false, place("A.swift", 1), place("B.swift", 2)), from: .scanner)
    guard case .show(let shown, 0) = choices.deadline() else {
      Issue.record("expected a menu")
      return
    }
    #expect(shown.count == 2)
    // The model is sure of the second: it moves to the top, while nothing was selected by hand.
    guard case .update(let updated, 0) = choices.receive(answer(.model, sure: true, place("B.swift", 2)), from: .model)
    else {
      Issue.record("expected an update")
      return
    }
    #expect(updated.map(\.place) == [place("B.swift", 2), place("A.swift", 1)])
    #expect(updated[0].isSure && updated[0].tier == .model)
    #expect(choices.isFinished)
  }

  @Test func rowsTheUserMovedPastStayWhereTheyAre() {
    var choices = DefinitionChoices(asking: [.scanner, .model])
    _ = choices.receive(answer(.scanner, sure: false, place("A.swift", 1), place("B.swift", 2), place("C.swift", 3)), from: .scanner)
    _ = choices.deadline()
    // Selected the second row, then the model is sure of the third.
    guard
      case .update(let rows, 1) = choices.receive(
        answer(.model, sure: true, place("C.swift", 3)), from: .model, selectionMoved: true, selected: 1)
    else {
      Issue.record("expected an update")
      return
    }
    #expect(rows.map(\.place) == [place("A.swift", 1), place("B.swift", 2), place("C.swift", 3)])
    #expect(rows[2].isSure)
  }

  @Test func theServerIsAskedLaterAndDecidesWhenAsked() {
    // "When unsure": the model gave candidates, so the server is asked, and its one place jumps.
    var choices = DefinitionChoices(asking: [.model])
    choices.ask(.server)
    #expect(choices.receive(answer(.model, sure: false, place("A.swift", 1), place("B.swift", 2)), from: .model) == .wait)
    #expect(choices.receive(answer(.server, sure: true, place("B.swift", 2)), from: .server) == .jump(place("B.swift", 2)))

    // "Always": a sure model answer waits for the server, which has the last word.
    var always = DefinitionChoices(asking: [.model, .server], decidingTier: .server)
    #expect(always.receive(answer(.model, sure: true, place("A.swift", 1)), from: .model) == .wait)
    #expect(always.receive(answer(.server, sure: true, place("Z.swift", 7)), from: .server) == .jump(place("Z.swift", 7)))
  }

  @Test func nothingFromEveryTierIsNotFound() {
    var choices = DefinitionChoices(asking: [.scanner, .model])
    #expect(choices.receive(nil, from: .scanner) == .wait)
    #expect(choices.receive(answer(.model, sure: false), from: .model) == .notFound)
  }

  @Test func theSamePlaceFromTwoTiersIsOneRow() {
    let rows = DefinitionChoices.merge([
      answer(.scanner, sure: false, place("A.swift", 1), place("B.swift", 2)),
      answer(.model, sure: false, place("B.swift", 2)),
    ])
    #expect(rows.map(\.place) == [place("B.swift", 2), place("A.swift", 1)])
    #expect(rows[0].tier == .model)
  }
}

#if os(macOS)
  @Suite struct SymbolInfoTests {
    let root = URL(fileURLWithPath: "/p")

    func place(_ file: String, _ line: Int, _ preview: String) -> DefinitionPlace {
      DefinitionPlace(url: URL(fileURLWithPath: "/p/\(file)"), line: line, column: 0, name: "x", preview: preview)
    }

    @Test func aSurePlaceShowsItsDeclarationAndFile() {
      let answer = DefinitionAnswer(tier: .model, isSure: true, places: [place("Sources/A.swift", 9, "func flushAll()")])
      #expect(
        ProjectServices.symbolInfo(answer, hover: nil, root: root) == "```\nfunc flushAll()\n```\n`Sources/A.swift:10`")
    }

    @Test func guessesSaySoAndTheServerTextWinsWithThePlace() {
      let one = DefinitionAnswer(tier: .scanner, isSure: false, places: [place("A.swift", 0, "var a = 1")])
      #expect(ProjectServices.symbolInfo(one, hover: nil, root: root)?.hasSuffix("A guess from Code’s scanner.") == true)
      #expect(
        ProjectServices.symbolInfo(one, hover: "```swift\nvar a: Int\n```", root: root)
          == "```swift\nvar a: Int\n```\n\nDeclared in `A.swift:1`")
      #expect(ProjectServices.symbolInfo(nil, hover: "  ", root: root) == nil)
    }
  }
#endif
