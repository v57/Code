import CodeScan
import Foundation
import Testing

@testable import CodePretty

/// Formats `text` with the options it resolves to and checks the result: what's expected, the same tokens, and a
/// second pass that changes nothing.
private func expectFormats(_ text: String, _ language: String, to expected: String, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
  let profile = LexProfile.profile(forLanguage: language)!
  let source = SourceFile(text, profile: profile)
  let options = PrettyOptions.resolve(path: nil, source: source)
  let output = Pretty.format(source, options: options)
  #expect(!output.refused, "refused", sourceLocation: sourceLocation)
  let result = String(decoding: output.text, as: UTF8.self)
  #expect(result == expected, sourceLocation: sourceLocation)
  let formatted = SourceFile(bytes: output.text, profile: profile)
  #expect(Pretty.sameTokens(source, formatted), "tokens changed", sourceLocation: sourceLocation)
  #expect(Pretty.format(formatted, options: options).text == output.text, "a second pass changed it", sourceLocation: sourceLocation)
}

/// How much of the layout each language gets, and the rules that let the word-block languages have all of it.
@Suite struct LevelTests {
  @Test func phpIndentsInsideItsTagsAndLeavesMarkup() {
    expectFormats("<?php\nfunction a($b){\nif($b){\nreturn [1,2];\n}\n}\n", "PHP", to: "<?php\nfunction a($b) {\n  if ($b) {\n    return [1, 2];\n  }\n}\n")
    // With markup around it, the lines are the template's: spacing only, and the markup's bytes stay.
    let template = "<?php\nif($a){\necho 1;\n}\n?>\n<p>x</p>\n<?php foreach($b as $c): ?>\n  <li><?= $c ?></li>\n<?php endforeach; ?>\n"
    expectFormats(template, "PHP", to: "<?php\nif ($a) {\necho 1;\n}\n?>\n<p>x</p>\n<?php foreach ($b as $c): ?>\n  <li><?= $c ?></li>\n<?php endforeach; ?>\n")
    expectFormats("<html>\n<?php if ($a) { echo 1; } ?>\n</html>\n", "PHP", to: "<html>\n<?php if ($a) { echo 1; } ?>\n</html>\n")
    expectFormats("<?php declare(strict_types=1);\n", "PHP", to: "<?php declare(strict_types=1);\n")
  }

  @Test func scalaWithoutBracesKeepsItsIndentation() {
    let braceless = "object A:\n  def a(x: Int): Int =\n    val y = x\n    y\n"
    expectFormats(braceless, "Scala", to: braceless)
    expectFormats("object A {\ndef a = 1\n}\n", "Scala", to: "object A {\n  def a = 1\n}\n")
  }

  @Test func refusedFilesNowFormat() {
    // Python: an interpolated string's pieces keep their quotes when the file prefers the other ones.
    expectFormats("x = f'{a}-{b}'\ny = \"s\"\n", "Python", to: "x = f'{a}-{b}'\ny = \"s\"\n")
    // A brace-less `if` body is a statement of its own, not a continuation.
    expectFormats("void a() {\nif (b)\nc();\nd();\n}\n", "C", to: "void a() {\n  if (b)\n    c();\n  d();\n}\n")
    // An aligned argument's continuation keeps its offset from the alignment.
    let aligned = "int a() {\n  return f(b,\n           c +\n             d);\n}\n"
    expectFormats(aligned, "C", to: aligned)
  }

  @Test func dartKeepsTwoSpacesAndItsListBraces() {
    expectFormats("class A {\nA({this.a,\nthis.b});\nfinal int a;\n}\n", "Dart", to: "class A {\n  A({this.a,\n    this.b});\n  final int a;\n}\n")
  }
}
