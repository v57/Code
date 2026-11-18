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

  @Test func shellIndentsByItsWords() {
    let text = """
      if [ -n "$a" ]; then
      echo a
      elif true; then
          echo b
      else
      for i in 1 2; do
      echo $i
      done
      fi
      case $x in
        a|b) echo ab;;
      (c)
        echo c
        ;;
      esac

      """
    expectFormats(text, "Shell", to: """
      if [ -n "$a" ]; then
        echo a
      elif true; then
        echo b
      else
        for i in 1 2; do
          echo $i
        done
      fi
      case $x in
        a|b) echo ab;;
        (c)
          echo c
          ;;
      esac

      """)
    // `echo done` is an argument, not the loop's end.
    expectFormats("for a in b; do\necho done\ndone\n", "Shell", to: "for a in b; do\n  echo done\ndone\n")
  }

  @Test func shellLinesAreCommands() {
    // `&` ends a command, `X=` assigns nothing, `/usr/bin/x` and `"$x"` start one; `||`, `|` and `$(` go on.
    let text = "run &\npid=$!\nEMPTY=\nnext=1\n/usr/bin/make all\n\"$x\" >out\nok ||\n{ echo no; }\nv=$(ls |\n  wc -l)\n"
    expectFormats(text, "Shell", to: "run &\npid=$!\nEMPTY=\nnext=1\n/usr/bin/make all\n\"$x\" >out\nok ||\n  { echo no; }\nv=$(ls |\n  wc -l)\n")
    // A here-document's body stays, and the command after it starts a line.
    expectFormats("f() {\ncat <<EOF\n  body\nEOF\n  echo after\n}\n", "Shell", to: "f() {\n  cat <<EOF\n  body\nEOF\n  echo after\n}\n")
    // Spaces separate words: none is added or removed but one where several were.
    expectFormats("a=b  c  -x=1 d,e\n", "Shell", to: "a=b c -x=1 d,e\n")
  }

  @Test func rubyIndentsByItsWords() {
    let text = "class A\ndef a=(v)\n@a=v\nend\ndef b = 1\ndef c(x)\nreturn 1 if x\n[1,2].each do |i|\nputs i\nend\nend\nend\n"
    expectFormats(text, "Ruby", to: """
      class A
        def a=(v)
          @a = v
        end
        def b = 1
        def c(x)
          return 1 if x
          [1, 2].each do |i|
            puts i
          end
        end
      end

      """)
    // A quoted here-document word runs to its quote, and the body runs to it.
    let heredoc = "A.class_eval <<-'end;', __FILE__\n  def x\n  end\nend;\nputs 1\n"
    expectFormats(heredoc, "Ruby", to: heredoc)
  }

  @Test func powerShellIndentsBracesAndKeepsCommandsWords() {
    let text = "function A {\nparam($x)\nif($x){\n& $tool -p:x=1 a,b\n. $common\n}\n}\n"
    expectFormats(text, "PowerShell", to: "function A {\n  param($x)\n  if ($x) {\n    & $tool -p:x=1 a, b\n    . $common\n  }\n}\n")
  }

  @Test func haskellKeepsItsLayout() {
    expectFormats("main = do\n    let xs = [1,2]\n    print   xs\n", "Haskell", to: "main = do\n    let xs = [1, 2]\n    print xs\n")
    // After `where` the next word's column is the block's: the gap before it stays.
    expectFormats("f = g\n  where  g  = 1\n         h = 2\n", "Haskell", to: "f = g\n  where  g = 1\n         h = 2\n")
  }

  @Test func luaIndentsByWordsAndKeepsItsTables() {
    let text = "local function a(x)\nif x then\nreturn {1,2}\nelse\nreturn nil\nend\nend\n"
    expectFormats(text, "Lua", to: "local function a(x)\n  if x then\n    return {1, 2}\n  else\n    return nil\n  end\nend\n")
    // A table under its call, and a long string under its key, stay where they're written; `={` gets both spaces.
    let tables = "data:extend(\n{\n  {type=\"a\"},\n})\nsim =\n{\n  init =\n  [[\n    go()\n  ]]\n}\nt={x=1}\n"
    expectFormats(tables, "Lua", to: "data:extend(\n{\n  {type = \"a\"},\n})\nsim =\n{\n  init =\n  [[\n    go()\n  ]]\n}\nt = {x = 1}\n")
    // Without its spaces `t[ [[key]] ]` would be another long string.
    expectFormats("local f = t[ [[key]] ]\n", "Lua", to: "local f = t[ [[key]] ]\n")
    // Four spaces under `function`, with no braces to say so.
    let four = "function a()\n    if b then\n        c()\n    end\nend\n"
    expectFormats(four, "Lua", to: four)
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
