import Foundation

/// What a Windows machine's sshd runs commands in: its default shell is cmd or PowerShell, neither of which knows
/// `sh`. Everything sent there is a PowerShell script, carried as base64 in a `powershell -Command` that both shells
/// pass along unchanged, so no quoting reaches the shell sshd starts. The scheme's commands themselves run in cmd, as
/// on Code's own Windows port (`SubprocessCapture.shellPath`), translated from the POSIX shell commands the detectors
/// write here (`cmdLine(fromPOSIX:)`).
enum WindowsShell {
  /// A command that starts with this is a PowerShell script for the machine, run as it is (the probe, a desktop job);
  /// any other is a shell command for `cmdLine(fromPOSIX:)`.
  static let powerShellPrefix = "#powershell\n"

  /// The script as a PowerShell script for `SSHExecutor`.
  static func script(_ powerShell: String) -> String { powerShellPrefix + powerShell }

  /// The line sshd gets: PowerShell decoding and running `script` (UTF-8, base64), its exit status the command's.
  static func invocation(_ script: String) -> String {
    let encoded = Data(script.utf8).base64EncodedString()
    return
      "powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"iex ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(encoded)')))\""
  }

  /// What every script starts with: UTF-8 output, no progress bars (they'd draw over the log), errors that stop it.
  static let preamble = """
    $ProgressPreference = 'SilentlyContinue'
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
    """

  /// Runs a cmd command line in `directory`: the line goes in through an environment variable, which cmd expands
  /// before it parses operators, so neither PowerShell's argument quoting nor sshd's shell touch it.
  ///
  /// Commands go to Windows without a terminal (`ssh -T`: its sshd sends nothing back from a command on one), and
  /// there a command outlives the connection. So a watcher waits for the connection's `sshd-session` (this script's
  /// nearest sshd ancestor), which ends when the connection closes (Stop, a dropped link), and then ends the
  /// command's process tree. (Standard input can't tell: Code's `ssh` reads /dev/null, so it ends at once.)
  static func runScript(cmdLine: String, directory: String) -> String {
    """
    \(preamble)
    Set-Location -LiteralPath \(quote(directory)) -ErrorAction Stop
    $env:CODE_CMD = \(quote(cmdLine))
    $p = Start-Process cmd.exe -ArgumentList '/d /s /c %CODE_CMD%' -WorkingDirectory (Get-Location).Path -NoNewWindow -PassThru
    $null = $p.Handle
    $watcher = [PowerShell]::Create().AddScript({
      param($child, $self)
      $session = $null; $current = $self
      for ($i = 0; $i -lt 5 -and -not $session -and $current; $i++) {
        $process = Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction SilentlyContinue
        if (-not $process) { break }
        if ($process.ProcessId -ne $self -and $process.Name -like 'sshd*') { $session = $process.ProcessId }
        $current = $process.ParentProcessId
      }
      if (-not $session) { return }
      while (Get-Process -Id $session -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 500 }
      taskkill.exe /T /F /PID $child 2>&1 | Out-Null
    }).AddArgument($p.Id).AddArgument($PID)
    $null = $watcher.BeginInvoke()
    $p.WaitForExit()
    exit $p.ExitCode
    """
  }

  /// A PowerShell string literal that's taken as it is.
  static func quote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
  }

  // MARK: - POSIX to cmd

  /// A POSIX shell command (what the detectors write on a Mac or Linux) as a cmd command line: words requoted with
  /// cmd's double quotes, `;` as `&`, `/dev/null` as `NUL`, `$NAME` as `%NAME%`, `cd` changing drives too, a program
  /// path with `\`, and `NAME=value command` as `set`. `rewrite` changes each word first (paths into the project here
  /// become the folder there). From a Windows client the commands are cmd's already and only words are rewritten.
  static func cmdLine(fromPOSIX command: String, rewrite: (String) -> String = { $0 }) -> String {
    var output: [String] = []
    var atCommandStart = true
    var afterRedirect = false
    for token in tokenize(command) {
      switch token {
      case .operator(let op):
        switch op {
        case ";": output.append("&")
        case "&&", "||", "|", "&", "(", ")": output.append(op)
        default:
          // Redirections: what follows is a file.
          output.append(op)
          afterRedirect = !op.hasSuffix("&1") && !op.hasSuffix("&2")
          continue
        }
        atCommandStart = op != ")"
        afterRedirect = false
      case .word(let word, let quoted):
        var text = rewrite(word)
        if afterRedirect {
          if text == "/dev/null" { text = "NUL" }
          output.append(cmdQuote(text, expand: false))
          afterRedirect = false
          continue
        }
        if atCommandStart, !quoted, let equals = text.firstIndex(of: "="), text[..<equals].allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber }), equals != text.startIndex {
          // NAME=value before a command.
          output.append("set \"\(text)\" &&")
          continue
        }
        if atCommandStart {
          atCommandStart = false
          if text == "cd" {
            output.append("cd /d")
            continue
          }
          if text.contains("/") { text = text.replacingOccurrences(of: "/", with: "\\") }
        }
        output.append(cmdQuote(text, expand: !quoted))
      }
    }
    return output.joined(separator: " ")
  }

  /// A word for cmd: plain ones as they are, others in double quotes (a `"` inside as `\"`, the C runtime's rule,
  /// with the backslashes before it doubled). With `expand`, `$NAME` and `${NAME}` become `%NAME%`.
  static func cmdQuote(_ word: String, expand: Bool) -> String {
    var text = word
    if expand { text = expandVariables(text) }
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=@+,\\%"))
    if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
    var result = "\""
    var backslashes = 0
    for character in text {
      if character == "\\" {
        backslashes += 1
        continue
      }
      if character == "\"" {
        result += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
      } else {
        result += String(repeating: "\\", count: backslashes) + String(character)
      }
      backslashes = 0
    }
    result += String(repeating: "\\", count: backslashes * 2) + "\""
    return result
  }

  private static func expandVariables(_ text: String) -> String {
    guard text.contains("$") else { return text }
    var result = ""
    var index = text.startIndex
    func isName(_ c: Character) -> Bool { c == "_" || (c.isASCII && (c.isLetter || c.isNumber)) }
    while index < text.endIndex {
      let character = text[index]
      let next = text.index(after: index)
      if character == "$", next < text.endIndex {
        if text[next] == "{", let close = text[next...].firstIndex(of: "}") {
          let name = text[text.index(after: next)..<close]
          if !name.isEmpty, name.allSatisfy(isName) {
            result += "%\(name)%"
            index = text.index(after: close)
            continue
          }
        } else if isName(text[next]), !text[next].isNumber {
          var end = next
          while end < text.endIndex, isName(text[end]) { end = text.index(after: end) }
          let name = text[next..<end]
          result += name == "HOME" ? "%USERPROFILE%" : "%\(name)%"
          index = end
          continue
        }
      }
      result.append(character)
      index = next
    }
    return result
  }

  enum Token: Equatable {
    /// A word with its quotes removed; `quoted` when any of it was in single quotes (nothing in it expands).
    case word(String, quoted: Bool)
    case `operator`(String)
  }

  /// POSIX words and operators: quotes and backslashes as `sh` reads them, without expanding anything.
  static func tokenize(_ command: String) -> [Token] {
    var tokens: [Token] = []
    var word = ""
    var inWord = false
    var singleQuoted = false
    let characters = Array(command)
    var index = 0
    func endWord() {
      if inWord { tokens.append(.word(word, quoted: singleQuoted)) }
      word = ""
      inWord = false
      singleQuoted = false
    }
    while index < characters.count {
      let character = characters[index]
      switch character {
      case " ", "\t", "\n":
        endWord()
        index += 1
      case "'":
        inWord = true
        singleQuoted = true
        index += 1
        while index < characters.count, characters[index] != "'" {
          word.append(characters[index])
          index += 1
        }
        index += 1
      case "\"":
        inWord = true
        index += 1
        while index < characters.count, characters[index] != "\"" {
          if characters[index] == "\\", index + 1 < characters.count, "\"\\$`".contains(characters[index + 1]) {
            index += 1
          }
          word.append(characters[index])
          index += 1
        }
        index += 1
      case "\\":
        inWord = true
        if index + 1 < characters.count { word.append(characters[index + 1]) }
        index += 2
      case ";", "&", "|", "(", ")", ">", "<":
        // A digit right before a redirection is its file descriptor ("2>").
        var descriptor = ""
        if (character == ">" || character == "<"), inWord, !singleQuoted, word.count == 1, word.first!.isNumber {
          descriptor = word
          word = ""
          inWord = false
        }
        endWord()
        var op = String(character)
        let next = index + 1 < characters.count ? characters[index + 1] : nil
        if (character == "&" || character == "|" || character == ">"), next == character {
          op.append(character)
          index += 1
        }
        if character == ">", index + 2 < characters.count, characters[index + 1] == "&", characters[index + 2].isNumber {
          op += "&" + String(characters[index + 2])
          index += 2
        }
        tokens.append(.operator(descriptor + op))
        index += 1
      default:
        inWord = true
        word.append(character)
        index += 1
      }
    }
    endWord()
    return tokens
  }
}
