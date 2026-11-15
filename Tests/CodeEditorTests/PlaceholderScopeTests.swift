import Foundation
import Testing

@testable import CodeEditor

@Suite struct PlaceholderScopeTests {
  @Test func scopeIsTheLineOnShortLines() {
    let text = "let a = 1\nfoo(<#x#>, <#y#>)\nlet b = 2" as NSString
    let caret = text.range(of: "<#y").location
    let scope = EditorPlaceholder.scope(of: NSRange(location: caret, length: 0), in: text)
    #expect(text.substring(with: scope) == "foo(<#x#>, <#y#>)\n")
    #expect(EditorPlaceholder.ranges(in: text, range: scope).count == 2)
  }

  @Test func scopeStaysNearTheRangeOnAMinifiedLine() {
    let filler = String(repeating: "a=1;", count: 1_250_000)  // a 5 MB line
    let text = (filler + "f(<#x#>)" + filler) as NSString
    let at = (filler as NSString).length + 3
    let clock = ContinuousClock()
    var scope = NSRange()
    var found: [NSRange] = []
    let elapsed = clock.measure {
      for _ in 0..<1000 {
        scope = EditorPlaceholder.scope(of: NSRange(location: at, length: 1), in: text)
        found = EditorPlaceholder.ranges(in: text, range: scope)
      }
    }
    #expect(scope.length <= 2 * EditorPlaceholder.maxLength + 1)
    #expect(found == [NSRange(location: at - 1, length: 5)])
    // Each lookup was a 5 MB scan before: about 1000 × 10 ms.
    #expect(elapsed < .milliseconds(500))
  }
}
