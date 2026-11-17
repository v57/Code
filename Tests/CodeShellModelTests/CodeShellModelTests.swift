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

@Suite struct PowerShellDefinitions {
  @Test func functionsParametersAndScopes() throws {
    let s = try Scripts(
      [
        "helpers.ps1": "<#\n.SYNOPSIS\nFormats a name.\n.PARAMETER Value\nThe name.\n#>\nfunction Format-Name { param($Value) \"[$Value]\" }\n",
        "main.ps1": """
          param([string]$Config = "Debug")
          . "$PSScriptRoot/^^helpers.ps1"
          $script:Count = 0
          function Invoke-Step {
              [CmdletBinding()]
              param($Name)
              $script:^^Count++
              $label = "$^^Name/$^^Config"
              Invoke-Command -ScriptBlock { Write-Output $using:^^label }
              ^^Show-Label
          }
          function Show-Label { Write-Output $^^label }
          ^^Invoke-Step -^^N one -^^Verbose
          $env:BUILD_MODE = 'ci'
          ^^Write-Output $env:^^BUILD_MODE $^^Count $^^Unset
          ^^Format-Name -^^Value x
          ^^gci | ^^Get-Thing
          """,
      ], dialect: .powerShell)
    #expect(s.exact("helpers") == "helpers.ps1:1")
    #expect(s.exact("Count") == "main.ps1:3")
    #expect(s.exact("Count2") == "main.ps1:3")
    #expect(s.exact("Name") == "main.ps1:6")
    #expect(s.exact("Config") == "main.ps1:1")
    #expect(s.exact("label") == "main.ps1:8")
    #expect(s.exact("Show-Label") == "main.ps1:12")
    // Show-Label's $label: Invoke-Step's local when it calls, else nothing in the script: a candidate, never exact.
    #expect(s.answer("label2").state != .exact)
    #expect(s.exact("Invoke-Step") == "main.ps1:4")
    // A unique prefix of a parameter, and a common parameter of an advanced function.
    #expect(s.exact("N") == "main.ps1:6")
    #expect(s.exact("Verbose") == "ps:CommonParameters.Verbose")
    #expect(s.exact("BUILD_MODE") == "main.ps1:14")
    #expect(s.answer("Unset").state == .unknown)
    #expect(s.exact("Format-Name") == "helpers.ps1:7")
    #expect(s.exact("Value") == "helpers.ps1:7")
    // Cmdlets and their aliases from the marked stub.
    #expect(s.exact("Write-Output") == "ps:Write-Output")
    #expect(s.exact("gci") == "ps:gci")
    #expect(s.answer("Get-Thing").state == .unknown)
    #expect(s.details("Format-Name")?.documentation == "Formats a name.")
    #expect(s.details("Value")?.documentation == "The name.")
  }

  @Test func modulesAndTheirExports() throws {
    let s = try Scripts(
      [
        "Tools/Tools.psd1": "@{\n    RootModule = 'Tools.psm1'\n    NestedModules = @('Extra.psm1')\n    FunctionsToExport = @('Get-Tool', 'Get-Extra')\n}\n",
        "Tools/Tools.psm1": "function Get-Tool {\n    param([string]$Name, [int]$Version)\n}\nfunction Hidden-Helper { }\n",
        "Tools/Extra.psm1": "function Get-Extra { }\n",
        "lib/Log.psm1": "function Write-Note { param([string]$Text) }\nfunction Write-Hidden { }\nExport-ModuleMember -Function Write-N*\n",
        "build.ps1": """
          Import-Module (Join-Path $PSScriptRoot 'Tools/^^Tools.psd1') -Force
          Import-Module "$PSScriptRoot/lib/Log.psm1"
          ^^Write-Note "start"
          ^^Get-Tool -^^Name hammer -^^Vers 2
          ^^Hidden-Helper
          ^^Write-Hidden "x"
          ^^Get-Extra
          """,
      ], dialect: .powerShell)
    #expect(s.exact("Tools") == "Tools/Tools.psd1:1")
    #expect(s.exact("Write-Note") == "lib/Log.psm1:1")
    #expect(s.exact("Get-Tool") == "Tools/Tools.psm1:1")
    #expect(s.exact("Name") == "Tools/Tools.psm1:2")
    #expect(s.exact("Vers") == "Tools/Tools.psm1:2")
    #expect(s.exact("Get-Extra") == "Tools/Extra.psm1:1")
    // Not exported: unknown, not the module's function.
    #expect(s.answer("Hidden-Helper").state == .unknown)
    #expect(s.answer("Write-Hidden").state == .unknown)
  }

  @Test func classesMembersAndStatics() throws {
    let s = try Scripts(
      [
        "Base.ps1": "class Task {\n    [string]$Name\n    [void] Run() { Write-Host $this.Name }\n}\n",
        "app.ps1": """
          . $PSScriptRoot\\Base.ps1
          enum Level { Low; High = 5 }
          class Job : ^^Task {
              [Level]$Level = [^^Level]::^^Low
              static [int]$Made = 0
              Job([string]$name) { $this.^^Name = $name; [Job]::^^Made++ }
              [string] Describe() { return "$($this.^^Level)" }
          }
          [Job]$job = [Job]::^^new("a")
          $job.^^Run()
          $other = New-Object Job -ArgumentList "b"
          $other.^^Describe()
          $copy = $job
          $copy.^^Level
          $unknown.^^Run()
          [System.IO.Path]::^^GetFileName("x")
          """,
      ], dialect: .powerShell)
    #expect(s.exact("Task") == "Base.ps1:1")
    #expect(s.exact("Level") == "app.ps1:2")
    #expect(s.exact("Low") == "app.ps1:2")
    #expect(s.exact("Name") == "Base.ps1:2")
    #expect(s.exact("Made") == "app.ps1:5")
    #expect(s.exact("Level2") == "app.ps1:4")
    #expect(s.exact("new") == "app.ps1:6")
    #expect(s.exact("Run") == "Base.ps1:3")
    #expect(s.exact("Describe") == "app.ps1:7")
    #expect(s.exact("Level3") == "app.ps1:4")
    // No type known, and .NET types aren't modelled: unknown rather than a guess.
    #expect(s.answer("Run2").state == .unknown)
    #expect(s.answer("GetFileName").state == .unknown)
  }
}

@Suite struct PowerShellCompletion {
  @Test func parametersMembersAndEnvironment() throws {
    let s = try Scripts(
      [
        "c.ps1": """
          class Box {
              [int]$Width
              [int] Area() { return 1 }
              static [Box] Make() { return [Box]::new() }
          }
          function Get-Tool { [CmdletBinding()] param([string]$Name, [int]$Version) }
          $env:BUILD_MODE = 'ci'
          $box = [Box]::new()
          Get-Tool -^^
          $box.^^W
          [Box]::^^M
          $env:^^BU
          $script:^^bo
          ^^Get-T
          """
      ], dialect: .powerShell)
    let parameters = s.complete("")
    #expect(parameters.prefix(2).sorted() == ["Name", "Version"])
    #expect(parameters.contains("Verbose"))
    #expect(s.complete("W", typed: 1) == ["Width"])
    #expect(s.complete("M", typed: 1).contains("Make"))
    #expect(s.complete("BU", typed: 2).first == "BUILD_MODE")
    #expect(s.complete("bo", typed: 2).first == "box")
    #expect(s.complete("Get-T", typed: 5).first == "Get-Tool")
  }
}
