import Foundation

/// Run on another machine, in the desktop session of the user logged in there, so an app's windows open on its screen
/// and Stop ends it: on Linux the command gets the session's display and bus (`linuxSessionScript`), on Windows it
/// starts as a scheduled task in the interactive session (`WindowsDesktopJob`). Elsewhere (a Mac, a container,
/// a system not probed yet) it runs over the connection as any command does.
enum DesktopRun {
  static func step(_ command: String) -> ActionStep {
    ActionStep("Run") { context in
      guard let machine = context.executor as? SSHExecutor else {
        try await context.run(command, title: "Run")
        return
      }
      if machine.isWindows {
        let job = WindowsDesktopJob(
          command: command, cmdLine: machine.windowsCommandLine(command),
          directory: machine.remotePath(context.directory.path))
        try await job.run("Run", context: context)
      } else if machine.system == "Linux" {
        try await context.run(linuxSessionScript(command), title: "Run", shown: command)
      } else {
        try await context.run(command, title: "Run")
      }
    }
  }

  /// The command with the display, D-Bus and runtime folder of the user's graphical session, from systemd's user
  /// manager (where GNOME, KDE and the others put them), else the usual sockets. An SSH session has none of them, so
  /// a GTK app would fail to open a display. Stop still ends it: the app is the SSH session's.
  static func linuxSessionScript(_ command: String) -> String {
    """
    {
    eval "$(systemctl --user show-environment 2>/dev/null | grep -E '^(DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR|XDG_SESSION_TYPE|XDG_CURRENT_DESKTOP)=' | sed 's/^/export /')"
    if [ -z "$WAYLAND_DISPLAY$DISPLAY" ]; then
      r="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
      if [ -S "$r/wayland-0" ]; then export XDG_RUNTIME_DIR="$r" WAYLAND_DISPLAY=wayland-0
      elif [ -S /tmp/.X11-unix/X0 ]; then export DISPLAY=:0
      else echo "warning: Nobody is logged in on this machine’s screen: the app has no display to open windows on."
      fi
    fi
    \(command)
    }
    """
  }
}

/// A command run in the interactive session of the user logged in on a Windows machine: a scheduled task for that
/// user with the Interactive logon type, which Windows starts on their desktop (an SSH session's own window station
/// shows nothing). The task runs PowerShell, hidden, which runs the command in cmd writing to a log in
/// `%LOCALAPPDATA%\dev.v57.code\runs\<id>`; the SSH command follows the log as `DesktopJob` does on a Mac. Stop ends
/// the task's process tree. With nobody logged in, the command runs over the connection instead.
struct WindowsDesktopJob: FollowedJob {
  var id: String
  /// The command as the log shows it.
  var command: String
  /// The command for cmd there.
  var cmdLine: String
  /// The folder it runs in there.
  var directory: String

  init(id: String = String(UUID().uuidString.lowercased().prefix(12)), command: String, cmdLine: String, directory: String) {
    self.id = id
    self.command = command
    self.cmdLine = cmdLine
    self.directory = directory
  }

  var machine: String { "the PC" }
  var taskName: String { "Run \(id)" }
  static let taskPath = "\\dev.v57.code\\"

  /// `$J`, the job's folder, and `$name`/`$path`, its task.
  private var locals: String {
    let q = WindowsShell.quote
    return """
      $runs = Join-Path $env:LOCALAPPDATA 'dev.v57.code\\runs'
      $J = Join-Path $runs \(q(id))
      $name = \(q(taskName)); $path = \(q(Self.taskPath))
      """
  }

  /// The batch file the task's PowerShell runs: the command (from `CODE_CMD`, so cmd parses it as one line) with its
  /// output in the log, then its exit status, written whole.
  var batch: String {
    [
      "@chcp 65001 >NUL",
      "@(%CODE_CMD%) >> \"%~dp0log\" 2>&1",
      "@>\"%~dp0status.part\" echo %ERRORLEVEL%",
      "@move /y \"%~dp0status.part\" \"%~dp0status\" >NUL",
    ].joined(separator: "\r\n") + "\r\n"
  }

  /// What the task runs: notes its process id (Stop ends its tree), enters the folder and runs the batch file.
  var taskScript: String {
    let q = WindowsShell.quote
    return """
      Set-Content -LiteralPath (Join-Path $PSScriptRoot 'pid') -Value $PID
      $env:CODE_CMD = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'command'))
      try { Set-Location -LiteralPath \(q(directory)) -ErrorAction Stop } catch {
        Add-Content -LiteralPath (Join-Path $PSScriptRoot 'log') -Value "error: $_"
        Set-Content -LiteralPath (Join-Path $PSScriptRoot 'status') -Value 1; exit 1
      }
      & cmd.exe /d /c (Join-Path $PSScriptRoot 'job.cmd')
      """
  }

  var startScript: String {
    let q = WindowsShell.quote
    return WindowsShell.script(
      """
      \(locals)
      $me = [Environment]::UserName
      $desktop = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Where-Object {
        (Invoke-CimMethod -InputObject $_ -MethodName GetOwner -ErrorAction SilentlyContinue).User -eq $me })
      if ($desktop.Count -eq 0) { \(q(DesktopJob.plainMarker)); exit 0 }
      New-Item -ItemType Directory -Force -Path $runs | Out-Null
      Get-ChildItem -LiteralPath $runs -Directory | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
      New-Item -ItemType Directory -Force -Path $J | Out-Null
      $utf8 = New-Object Text.UTF8Encoding $false
      [IO.File]::WriteAllText("$J\\log", '', $utf8)
      [IO.File]::WriteAllText("$J\\command", \(q(cmdLine)), $utf8)
      [IO.File]::WriteAllText("$J\\job.cmd", \(q(batch)), $utf8)
      [IO.File]::WriteAllText("$J\\job.ps1", \(q(taskScript)), $utf8)
      try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + "$J\\job.ps1" + '"')
        $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan) -MultipleInstances Parallel
        Register-ScheduledTask -TaskName $name -TaskPath $path -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $name -TaskPath $path -ErrorAction Stop
      } catch {
        "error: Couldn’t start it in this PC’s desktop session: $_"; \(q(DesktopJob.exitMarker + "1")); exit 1
      }
      for ($i = 0; $i -lt 240 -and -not (Test-Path -LiteralPath "$J\\pid"); $i++) { Start-Sleep -Milliseconds 250 }
      if (-not (Test-Path -LiteralPath "$J\\pid")) {
        $result = (Get-ScheduledTaskInfo -TaskName $name -TaskPath $path -ErrorAction SilentlyContinue).LastTaskResult
        Unregister-ScheduledTask -TaskName $name -TaskPath $path -Confirm:$false -ErrorAction SilentlyContinue
        "error: This PC’s desktop session didn’t start it (task result $result)."; \(q(DesktopJob.exitMarker + "1")); exit 1
      }
      \(followBody(from: 1))
      """)
  }

  func followScript(from line: Int) -> String {
    WindowsShell.script(
      """
      \(locals)
      \(followBody(from: line))
      """)
  }

  /// Copies the log's bytes from line `line` on as they come, then the exit marker once the task has finished: a
  /// task that ended without writing its status (killed) failed. The finished task is removed.
  private func followBody(from line: Int) -> String {
    let q = WindowsShell.quote
    return """
      if (-not (Test-Path -LiteralPath "$J\\log")) { 'error: This PC has no log of the run any more.'; \(q(DesktopJob.exitMarker + "1")); exit 1 }
      $skip = \(max(0, line - 1)); $seen = 0; $lastByte = 10; $last = $false; $tick = 0
      $fs = [IO.File]::Open("$J\\log", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
      $out = [Console]::OpenStandardOutput()
      $buffer = New-Object byte[] 65536
      while ($true) {
        $count = $fs.Read($buffer, 0, $buffer.Length)
        if ($count -gt 0) {
          $start = 0
          while ($seen -lt $skip -and $start -lt $count) { if ($buffer[$start] -eq 10) { $seen++ }; $start++ }
          if ($start -lt $count) { $out.Write($buffer, $start, $count - $start); $out.Flush(); $lastByte = $buffer[$count - 1] }
          continue
        }
        if ($last) { break }
        if (Test-Path -LiteralPath "$J\\status") { $last = $true; continue }
        $tick++
        if ($tick % 8 -eq 0) {
          $task = Get-ScheduledTask -TaskName $name -TaskPath $path -ErrorAction SilentlyContinue
          if (-not $task -or $task.State -ne 'Running') {
            Start-Sleep -Seconds 2
            if (-not (Test-Path -LiteralPath "$J\\status")) { Set-Content -LiteralPath "$J\\status" -Value 1 }
            continue
          }
        }
        Start-Sleep -Milliseconds 250
      }
      $fs.Close()
      Unregister-ScheduledTask -TaskName $name -TaskPath $path -Confirm:$false -ErrorAction SilentlyContinue
      $status = (Get-Content -LiteralPath "$J\\status" -Raw).Trim()
      $end = $(if ($lastByte -ne 10) { "`n" } else { '' }) + \(q(DesktopJob.exitMarker)) + $status + "`n"
      $bytes = [Text.Encoding]::UTF8.GetBytes($end); $out.Write($bytes, 0, $bytes.Length); $out.Flush()
      """
  }

  var stopScript: String {
    WindowsShell.script(
      """
      \(locals)
      if (Test-Path -LiteralPath "$J\\pid") { taskkill.exe /T /F /PID ((Get-Content -LiteralPath "$J\\pid" -Raw).Trim()) 2>&1 | Out-Null }
      Stop-ScheduledTask -TaskName $name -TaskPath $path -ErrorAction SilentlyContinue
      Unregister-ScheduledTask -TaskName $name -TaskPath $path -Confirm:$false -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $J) { Set-Content -LiteralPath "$J\\status" -Value 130 }
      """)
  }
}
