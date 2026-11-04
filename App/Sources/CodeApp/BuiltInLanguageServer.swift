import CodeKit
import CodeServer
import Foundation

extension CodeApp {
  /// Code's binary is also its built-in language server, so it needs no second executable to bundle or find: with this
  /// flag it serves on standard input and output, before anything of the app starts, and never returns.
  public static func runLanguageServerIfAsked() {
    if CommandLine.arguments.dropFirst().first == "--language-server" {
      LanguageServerLoop.runOnStandardStreams()
    }
    LanguageServerManager.builtInExecutable = Bundle.main.executablePath
  }
}
