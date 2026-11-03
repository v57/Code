import Foundation
import Testing

@testable import CodeLSP

@Suite final class ToolUninstallTests {
  private let root: String

  init() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    root = url.resolvingSymlinksInPath().path
  }

  deinit {
    try? FileManager.default.removeItem(atPath: root)
  }

  /// A file under the test's folder, executable.
  private func file(_ path: String, _ content: String = "") throws {
    let url = URL(fileURLWithPath: root + "/" + path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  private func link(_ path: String, to destination: String) throws {
    let url = URL(fileURLWithPath: root + "/" + path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: root + "/" + destination)
  }

  private func expectEqual<Value: Equatable>(
    _ value: Value, _ expected: Value, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(value == expected, sourceLocation: sourceLocation)
  }

  private func plan(_ tool: String, _ path: String, path found: [String: String] = [:]) -> ToolUninstallPlan {
    ToolUninstall.plan(
      tool: tool, path: root + "/" + path, home: root + "/home", which: { [root] in found[$0].map { root + "/" + $0 } })
  }

  @Test func homebrewFormulaFollowsTheLink() throws {
    try file("brew/Cellar/shfmt/3.8/bin/shfmt")
    try file("brew/bin/brew")
    try link("brew/bin/shfmt", to: "brew/Cellar/shfmt/3.8/bin/shfmt")
    expectEqual(
      plan("shfmt", "brew/bin/shfmt", path: ["brew": "brew/bin/brew"]), .command("brew uninstall shfmt", note: nil))
  }

  @Test func homebrewFormulaOfAnotherNameSaysWhatElseGoes() throws {
    try file("brew/Cellar/go/1.2/libexec/bin/gofmt")
    try file("brew/bin/brew")
    try link("brew/bin/gofmt", to: "brew/Cellar/go/1.2/libexec/bin/gofmt")
    expectEqual(
      plan("gofmt", "brew/bin/gofmt", path: ["brew": "brew/bin/brew"]),
      .command("brew uninstall go", note: "gofmt comes with go: this removes all of go."))
  }

  @Test func anotherHomebrewOnThePathUsesTheToolsOwn() throws {
    try file("intel/Cellar/ruff/1/bin/ruff")
    try file("intel/bin/brew")
    try file("arm/bin/brew")
    try link("intel/bin/ruff", to: "intel/Cellar/ruff/1/bin/ruff")
    expectEqual(
      plan("ruff", "intel/bin/ruff", path: ["brew": "arm/bin/brew"]),
      .command("\(root)/intel/bin/brew uninstall ruff", note: nil))
  }

  @Test func homebrewWithoutBrewIsUnknown() throws {
    try file("brew/Cellar/ruff/1/bin/ruff")
    guard case .unknown = plan("ruff", "brew/Cellar/ruff/1/bin/ruff") else { Issue.record("guessed a command"); return }
  }

  @Test func aCaskUsesCask() throws {
    try file("brew/Caskroom/zed/1/zed")
    try file("brew/bin/brew")
    expectEqual(
      plan("zed", "brew/Caskroom/zed/1/zed", path: ["brew": "brew/bin/brew"]),
      .command("brew uninstall --cask zed", note: nil))
  }

  @Test func npmGlobalPackage() throws {
    try file("node/lib/node_modules/intelephense/lib/intelephense.js")
    try file("node/bin/npm")
    try link("node/bin/intelephense", to: "node/lib/node_modules/intelephense/lib/intelephense.js")
    expectEqual(
      plan("intelephense", "node/bin/intelephense", path: ["npm": "node/bin/npm"]),
      .command("npm uninstall -g intelephense", note: nil))
  }

  @Test func npmScopedPackage() throws {
    try file("node/lib/node_modules/@acme/server/cli.js")
    try file("node/bin/npm")
    try link("node/bin/server", to: "node/lib/node_modules/@acme/server/cli.js")
    expectEqual(
      plan("server", "node/bin/server", path: ["npm": "node/bin/npm"]),
      .command("npm uninstall -g @acme/server", note: nil))
  }

  @Test func homebrewWinsOverItsOwnNodeModules() throws {
    try file("brew/Cellar/pyright/1/libexec/lib/node_modules/pyright/langserver.js")
    try file("brew/bin/brew")
    try link("brew/bin/pyright-langserver", to: "brew/Cellar/pyright/1/libexec/lib/node_modules/pyright/langserver.js")
    guard case .command(let command, _) = plan("pyright-langserver", "brew/bin/pyright-langserver", path: ["brew": "brew/bin/brew"])
    else { Issue.record("no command"); return }
    expectEqual(command, "brew uninstall pyright")
  }

  @Test func rustupProxy() throws {
    try file("home/.cargo/bin/rustup")
    try link("home/.cargo/bin/rustfmt", to: "home/.cargo/bin/rustup")
    expectEqual(
      plan("rustfmt", "home/.cargo/bin/rustfmt"),
      .command("rustup component remove rustfmt", note: "This removes it from rustup’s default toolchain."))
  }

  @Test func cargoCrateFromItsRecord() throws {
    try file("home/.cargo/bin/rg")
    try file(
      "home/.cargo/.crates2.json", #"{"installs":{"ripgrep 14.0.0 (registry+https://x)":{"bins":["rg"]}}}"#)
    expectEqual(plan("rg", "home/.cargo/bin/rg"), .command("cargo uninstall ripgrep", note: nil))
    try file("home/.cargo/bin/other")
    guard case .unknown = plan("other", "home/.cargo/bin/other") else { Issue.record("guessed a crate"); return }
  }

  @Test func dotnetTool() throws {
    try file("home/.dotnet/tools/csharp-ls")
    try file("home/.dotnet/tools/.store/csharp-ls/1/x")
    expectEqual(
      plan("csharp-ls", "home/.dotnet/tools/csharp-ls"), .command("dotnet tool uninstall --global csharp-ls", note: nil))
    try file("home/.dotnet/tools/other")
    guard case .unknown = plan("other", "home/.dotnet/tools/other") else { Issue.record("guessed a tool"); return }
  }

  @Test func uvAndPipx() throws {
    try file("home/.local/share/uv/tools/ruff/bin/ruff")
    try link("home/.local/bin/ruff", to: "home/.local/share/uv/tools/ruff/bin/ruff")
    expectEqual(
      plan("ruff", "home/.local/bin/ruff", path: ["uv": "bin/uv"]), .command("uv tool uninstall ruff", note: nil))
    try file("home/.local/pipx/venvs/black/bin/black")
    try link("home/.local/bin/black", to: "home/.local/pipx/venvs/black/bin/black")
    expectEqual(
      plan("black", "home/.local/bin/black", path: ["pipx": "bin/pipx"]), .command("pipx uninstall black", note: nil))
  }

  @Test func gemFromItsStub() throws {
    try file("ruby/bin/ruby")
    try file("ruby/bin/gem")
    try file(
      "ruby/bin/ruby-lsp",
      "#!\(root)/ruby/bin/ruby\n# This file was generated by RubyGems.\nload Gem.activate_bin_path('ruby-lsp', 'ruby-lsp', version)\n"
    )
    expectEqual(
      plan("ruby-lsp", "ruby/bin/ruby-lsp", path: ["gem": "ruby/bin/gem"]),
      .command("gem uninstall --all --executables --abort-on-dependent ruby-lsp", note: nil))
  }

  @Test func pipScriptFromItsRecord() throws {
    try file("py/bin/python3")
    try file("py/bin/ruff", "#!\(root)/py/bin/python3\nimport sys\n")
    try file("py/lib/python3.12/site-packages/ruff-0.3.0.dist-info/RECORD", "../../../bin/ruff,sha256=x,1\n")
    expectEqual(plan("ruff", "py/bin/ruff"), .command("\(root)/py/bin/python3 -m pip uninstall -y ruff", note: nil))
    try file("py/bin/other", "#!\(root)/py/bin/python3\n")
    guard case .unknown = plan("other", "py/bin/other") else { Issue.record("guessed a package"); return }
  }

  @Test func goInstallIsNeverDeletedByPath() throws {
    try file("home/go/bin/gopls")
    guard case .unknown(let reason) = plan("gopls", "home/go/bin/gopls") else { Issue.record("guessed a command"); return }
    #expect(reason.contains("go install"))
  }

  @Test func aPlainFileIsUnknownAndSaysSo() throws {
    try file("somewhere/tool")
    let plan = ToolUninstall.plan(
      tool: "tool", path: root + "/somewhere/tool", installCommand: "brew install tool", home: root + "/home",
      which: { _ in nil })
    guard case .unknown(let reason) = plan else { Issue.record("guessed a command"); return }
    #expect(reason.contains("brew install tool"))
  }

  @Test func appleToolsAreNotUninstallable() {
    guard case .unknown(let reason) = ToolUninstall.plan(tool: "sourcekit-lsp", path: "/usr/bin/sourcekit-lsp", which: { _ in nil })
    else { Issue.record("guessed a command"); return }
    #expect(reason.contains("Xcode"))
  }

  @Test func quotingKeepsAnOddNameOneWord() {
    expectEqual(ToolUninstall.quoted("plain-name_1.2@x"), "plain-name_1.2@x")
    expectEqual(ToolUninstall.quoted("a b;rm"), "'a b;rm'")
    expectEqual(ToolUninstall.quoted("it's"), "'it'\\''s'")
  }
}
