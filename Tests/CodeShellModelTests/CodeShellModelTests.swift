import CodeModel
import CodeShellModel
import Foundation
import Testing

/// A folder of scripts in a temporary folder, from file text with `^^` before the word a question is about.
final class Scripts {
  let root: String
  let model: ScriptModel
  var marks: [String: (path: String, line: Int, character: Int)] = [:]

  init(_ files: [String: String], dialect: ScriptDialect = .shell) throws {
    let base = NSTemporaryDirectory() + "scriptmodel-" + UUID().uuidString
    root = base + "/project"
    for (name, text) in files.sorted(by: { $0.key < $1.key }) {
      var body = ""
      for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        var rest = String(line)
        while let mark = rest.range(of: "^^") {
          let character = rest.utf16.distance(from: rest.startIndex, to: mark.lowerBound)
          let word = String(rest[mark.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
          var key = word
          var n = 2
          while marks[key] != nil {
            key = word + String(n)
            n += 1
          }
          marks[key] = (root + "/" + name, number, character)
          rest.removeSubrange(mark)
        }
        body += rest + "\n"
      }
      let url = URL(fileURLWithPath: root + "/" + name)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try body.write(to: url, atomically: true, encoding: .utf8)
    }
    model = ScriptModel(root: root, dialect: dialect)
  }

  deinit { try? FileManager.default.removeItem(atPath: URL(fileURLWithPath: root).deletingLastPathComponent().path) }

  /// The answer's definitions as `path:line` (1-based), `builtin:<name>`/`ps:<name>` for the stub's.
  func answer(_ key: String) -> (state: AnswerState, places: [String]) {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return (found.state, found.sites.compactMap { site in model.place(of: site).map { $0.line == 0 ? $0.path : "\($0.path):\($0.line)" } })
  }

  func exact(_ key: String) -> String? {
    let found = answer(key)
    return found.state == .exact && found.places.count == 1 ? found.places[0] : nil
  }

  func all(_ key: String) -> [String]? {
    let found = answer(key)
    return found.state == .exact ? found.places.sorted() : nil
  }

  func references(_ key: String) -> [String] {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    return model.references(of: found).map { "\($0.path):\($0.line)" }.sorted()
  }

  func complete(_ key: String, typed: Int = 0) -> [String] {
    let mark = marks[key]!
    return model.complete(path: mark.path, line: mark.line, character: mark.character + typed, limit: 400).items.map(\.name)
  }

  func details(_ key: String) -> SymbolDetails? {
    let mark = marks[key]!
    let found = model.answer(path: mark.path, line: mark.line, character: mark.character)
    guard let site = found.sites.first else { return nil }
    return model.details(of: site)
  }
}

@Suite struct ShellDefinitions {
  @Test func functionsAndTheirCalls() throws {
    let s = try Scripts([
      "build.sh": """
        #!/bin/bash
        compile() { echo "compiling $1"; }
        function package {
          ^^compile "$@"
        }
        ^^package app
        ^^cc -o x x.c
        """
    ])
    #expect(s.exact("compile") == "build.sh:2")
    #expect(s.exact("package") == "build.sh:3")
    #expect(s.answer("cc").state == .unknown)
    #expect(s.references("compile") == ["build.sh:2", "build.sh:4"])
  }

  @Test func variablesFollowDynamicScope() throws {
    let s = try Scripts([
      "scope.sh": """
        #!/bin/bash
        count=0
        inner() { echo "$^^count $^^mode"; }
        outer() { local count=5; inner; echo "$^^count"; local count=6; echo $^^count; }
        mode=y
        (( ^^count = count + 1 ))
        """
    ])
    // inner's count: outer's local when outer calls it, else the script's.
    let dynamic = s.answer("count")
    #expect(dynamic.state == .candidates)
    #expect(dynamic.places.first == "scope.sh:4")
    #expect(Set(dynamic.places) == ["scope.sh:4", "scope.sh:2", "scope.sh:6"])
    #expect(s.exact("mode") == "scope.sh:5")
    // The nearest local declared before the use.
    #expect(s.exact("count2") == "scope.sh:4")
    #expect(s.exact("count3") == "scope.sh:4")
    #expect(s.all("count4") == ["scope.sh:2", "scope.sh:6"])
  }

  @Test func sourcedFilesAndTheirNames() throws {
    let s = try Scripts([
      "bin/run.sh": """
        #!/bin/bash
        source "$(dirname "$0")/../lib/^^common.sh"
        . "${BASH_SOURCE%/*}/^^util.sh"
        ^^log_info "in $^^LIB_DIR"
        ^^ll
        """,
      "bin/util.sh": "here=$(cd \"$(dirname \"$0\")\" && pwd)\nsource \"$here/../lib/common.sh\"\n",
      "lib/common.sh": "LIB_DIR=${BASH_SOURCE%/*}\nalias ll='ls -l'\n# Writes to stderr.\nlog_info() { printf '%s\\n' \"$*\" >&2; }\n",
    ])
    #expect(s.exact("common") == "lib/common.sh:1")
    #expect(s.exact("util") == "bin/util.sh:1")
    #expect(s.exact("log_info") == "lib/common.sh:4")
    #expect(s.exact("LIB_DIR") == "lib/common.sh:1")
    #expect(s.exact("ll") == "lib/common.sh:2")
    #expect(s.details("log_info")?.documentation == "Writes to stderr.")
    #expect(s.details("log_info")?.declaration == "log_info()")
  }

  @Test func zshAutoloadsFromFpath() throws {
    let s = try Scripts([
      ".zshrc": """
        fpath=(${0:A:h}/functions $fpath)
        autoload -Uz greet
        NAME=you
        ^^greet world
        """,
      "functions/greet": "print -r -- \"hello $1, $^^NAME\"\n",
    ])
    #expect(s.exact("greet") == "functions/greet:1")
    #expect(s.exact("NAME") == ".zshrc:3")
  }

  @Test func builtinsAreEachShellsOwn() throws {
    let s = try Scripts([
      "a.sh": "#!/bin/bash\n^^echo hi\n^^mapfile -t lines < f\n^^print hi\necho $^^HOME $^^BASH_SOURCE\n",
      "b.zsh": "^^print hi\n^^log\necho $^^ZSH_VERSION\n",
    ])
    #expect(s.exact("echo") == "builtin:echo")
    #expect(s.exact("mapfile") == "builtin:mapfile")
    // zsh's `print` isn't bash's: an external program there.
    #expect(s.answer("print").state == .unknown)
    #expect(s.exact("print2") == "builtin:print")
    #expect(s.exact("log") == "builtin:log")
    #expect(s.exact("HOME") == "builtin:HOME")
    #expect(s.exact("BASH_SOURCE") == "builtin:BASH_SOURCE")
    #expect(s.exact("ZSH_VERSION") == "builtin:ZSH_VERSION")
    #expect(s.details("echo")?.declaration == "builtin echo")
    #expect(s.details("echo")?.symbol.isSDK == true)
  }

  @Test func arraysReadAndGetopts() throws {
    let s = try Scripts([
      "args.sh": """
        #!/bin/bash
        files=(a b)
        files+=(c)
        while getopts d:o: opt; do
          case $^^opt in
            d) dir=$OPTARG ;;
            o) echo "${^^files[@]}" "${#^^files[@]}" ;;
          esac
        done
        while IFS= read -r -d '' ^^line; do echo "$^^line" "$^^dir"; done
        """
    ])
    #expect(s.exact("opt") == "args.sh:4")
    #expect(s.all("files") == ["args.sh:2", "args.sh:3"])
    #expect(s.all("files2") == ["args.sh:2", "args.sh:3"])
    #expect(s.exact("line2") == "args.sh:10")
    #expect(s.exact("dir") == "args.sh:6")
  }

  @Test func quotingAndHereDocuments() throws {
    let s = try Scripts([
      "q.sh": """
        #!/bin/bash
        name=x
        say() { :; }
        echo 'not $name' "${name//\\"/\\'}" \\'^^say
        cat <<EOF
        $^^name and $(^^say)
        EOF
        cat <<'EOF'
        $name
        EOF
        ^^say done
        """
    ])
    #expect(s.answer("say").state == .unknown)
    #expect(s.exact("name") == "q.sh:2")
    #expect(s.exact("say2") == "q.sh:3")
    #expect(s.exact("say3") == "q.sh:3")
  }

  @Test func stopsAtATopLevelExec() throws {
    let s = try Scripts([
      "wrap.sh": "#!/bin/sh\n^^helper\nexec python3 - \"$@\" <<'X'\nX\nexit 0\nhelper() { :; }\n"
    ])
    // What follows is data: its `helper` isn't the script's.
    #expect(s.answer("helper").state == .unknown)
  }
}

@Suite struct ShellCompletion {
  @Test func variablesAfterADollar() throws {
    let s = try Scripts([
      "c.sh": """
        #!/bin/bash
        GLOBAL=1
        f() {
          local mine=2
          echo $(( ^^ + 1 ))
          echo "$^^m ${^^G"
        }
        """
    ])
    #expect(s.complete("m", typed: 1).contains("mine"))
    #expect(s.complete("G", typed: 1).first == "GLOBAL")
    #expect(s.complete("").contains("mine"))
  }

  @Test func commandsWhereACommandGoes() throws {
    let s = try Scripts([
      "c.sh": """
        #!/bin/bash
        deploy() { :; }
        alias dl='ls'
        ^^de
        X=1 ^^de2
        if true; then ^^de3; fi
        case $1 in a) ^^de4 ;; esac
        echo ^^de5 # ^^de6
        y=$(git ^^de7)
        """
    ])
    for key in ["de", "de2", "de3", "de4"] {
      #expect(s.complete(key, typed: 2).first == "deploy", "\(key)")
    }
    #expect(s.complete("de", typed: 1).contains("dl"))
    #expect(s.complete("de", typed: 2).contains("declare"))
    #expect(s.complete("de5", typed: 2).isEmpty)
    #expect(s.complete("de6", typed: 2).isEmpty)
    #expect(s.complete("de7", typed: 2).isEmpty)
  }
}
