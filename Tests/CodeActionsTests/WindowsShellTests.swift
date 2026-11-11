import Foundation
import Testing

@testable import CodeActions

/// Build From a Windows machine: commands go there as PowerShell running cmd, translated from the POSIX commands the
/// detectors write; the probe answers in PowerShell; a WinUI app builds only there.
@Suite struct WindowsShellTests {
  @Test func posixCommandsBecomeCmdLines() {
    func cmd(_ posix: String) -> String { WindowsShell.cmdLine(fromPOSIX: posix) }
    #expect(cmd("swift build --product 'My App'") == "swift build --product \"My App\"")
    #expect(cmd("swift run Code") == "swift run Code")
    #expect(
      cmd("cmake -S . -B build && cmake --build build --target app && ./build/app")
        == "cmake -S . -B build && cmake --build build --target app && .\\build\\app")
    #expect(cmd("FOO=bar make run") == "set \"FOO=bar\" && make run")
    #expect(cmd("echo $HOME ${PATH} >/dev/null 2>&1") == "echo %USERPROFILE% %PATH% > NUL 2>&1")
    #expect(cmd("echo '$HOME'") == "echo \"$HOME\"")
    #expect(cmd("a; b || c | d") == "a & b || c | d")
    #expect(cmd("cd sub && swift build") == "cd /d sub && swift build")
    #expect(cmd(#"printf '%s' "a\"b" 'it'\''s'"#) == #"printf %s "a\"b" "it's""#)
    #expect(cmd("go run ./cmd/'my tool'") == "go run \"./cmd/my tool\"")
    #expect(WindowsShell.cmdQuote(#"C:\a b\"#, expand: false) == #""C:\a b\\""#)
  }

  @Test func pathsIntoTheProjectBecomeTheFolderThere() throws {
    let executor = SSHExecutor(
      target: .init(id: "pc", name: "PC", host: "h", directory: #"C:\dev\My App"#),
      localRoot: URL(fileURLWithPath: "/Users/me/App"), system: BuildCapabilities.windows)
    #expect(
      executor.windowsCommandLine("swift build --scratch-path /Users/me/App/.build/x -Xswiftc -g")
        == #"swift build --scratch-path "C:\dev\My App\.build\x" -Xswiftc -g"#)
    #expect(executor.windowsCommandLine("ls /Users/me/Apple") == "ls /Users/me/Apple")
    #expect(executor.remotePath("/Users/me/App/Sources/Tool") == #"C:\dev\My App\Sources\Tool"#)

    // What sshd gets: PowerShell decoding the script, which enters the folder and hands the line to cmd.
    let sent = executor.remoteCommand("swift build", directory: URL(fileURLWithPath: "/Users/me/App"))
    #expect(sent.hasPrefix("powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"iex "))
    let encoded = sent.split(separator: "'")[1]
    let script = String(decoding: Data(base64Encoded: String(encoded))!, as: UTF8.self)
    #expect(script.contains(#"Set-Location -LiteralPath 'C:\dev\My App' -ErrorAction Stop"#))
    #expect(script.contains("$env:CODE_CMD = 'swift build'"))
    #expect(script.contains("Start-Process cmd.exe -ArgumentList '/d /s /c %CODE_CMD%'"))
    // No terminal on Windows: its sshd sends nothing back from one.
    #expect(try executor.sshArguments("x").contains("-T"))

    // A PowerShell script goes as it is.
    let probe = executor.windowsScript(MachineProbe.windowsScript(find: nil), directory: URL(fileURLWithPath: "/Users/me/App"))
    #expect(probe.contains("CODE-PROBE "))
    #expect(!probe.contains("CODE_CMD"))
  }

  @Test func theWindowsProbeAnswersLikeTheOthers() {
    let answer = MachineProbe.parse([
      "CODE-PROBE system Windows\r", "CODE-PROBE tool swift\r", #"CODE-PROBE folder C:\dev\Code"#,
    ])
    #expect(answer.capabilities.system == BuildCapabilities.windows)
    #expect(answer.capabilities.toolchains == [.swiftPM])
    #expect(answer.folder == #"C:\dev\Code"#)
    let script = MachineProbe.windowsScript(find: ("Co'de", "Developer/v57/Co'de", "v57/Co'de"))
    #expect(script.hasPrefix(WindowsShell.powerShellPrefix))
    #expect(script.contains(#"("$HOME" + '\Developer\v57\Co''de')"#))
    #expect(script.contains(#"("$env:SystemDrive" + '\dev\*\Co''de')"#))
    #expect(script.contains("$origin = 'v57/Co''de'"))
  }

  @Test func aWinUIAppBuildsOnlyOnWindows() {
    let manifest = """
      #if os(Windows)
      package.products.append(.library(name: "CodeWinUI", type: .dynamic, targets: ["Code"]))
      #elseif os(Linux)
      package.products.append(.executable(name: "Code", targets: ["Code"]))
      #endif
      """
    #expect(SwiftPackageDetector.winUIApps(in: manifest) == ["CodeWinUI"])
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winui-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try? manifest.write(to: folder.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    let all = ProjectScanner.schemes(in: ProjectFolder(listing: folder), anySystem: true)
    #expect(all.map(\.name) == ["Code", "CodeWinUI"])
    let winUI = all[1]
    // This Mac's own list (Shell's smart actions) leaves it out; Build From a Windows machine offers it.
    #expect(ProjectScanner.schemes(in: ProjectFolder(listing: folder)).map(\.name) == ["Code"])
    #expect(!BuildCapabilities.local.canBuild(winUI))
    #expect(BuildCapabilities(system: BuildCapabilities.windows, toolchains: [.swiftPM]).canBuild(winUI))
    #expect(!BuildCapabilities(system: "Linux", toolchains: [.swiftPM]).canBuild(winUI))

    // Run stages it with SwiftUI's build-app.ps1, then runs its host until the app quits.
    let line = WindowsShell.cmdLine(fromPOSIX: winUI.commands[.run]!)
    #expect(line.hasPrefix("powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"$s = @("))
    #expect(line.contains("-PackagePath $PWD.Path -Product"))
    #expect(line.hasSuffix(#"-Product 'CodeWinUI' } catch { Write-Host ('error: ' + $_); exit 1 }; exit 0" && .build\winui\CodeWinUI\SwiftUIHost.exe"#))
  }

  @Test func runOnLinuxGetsTheDesktopSession() {
    let script = DesktopRun.linuxSessionScript("swift run GalleryGtk")
    #expect(script.hasPrefix("{\n"))
    #expect(script.contains("systemctl --user show-environment"))
    #expect(script.hasSuffix("swift run GalleryGtk\n}"))
  }
}
