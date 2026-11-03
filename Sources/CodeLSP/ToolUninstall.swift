import Foundation

/// What uninstalling a tool would do.
public enum ToolUninstallPlan: Equatable, Sendable {
  /// `command` removes it. `note` says what else goes when the tool is part of something bigger ("gofmt comes with
  /// go…").
  case command(String, note: String?)
  /// Why Code can't tell how it was installed, or can't remove it. Nothing is ever deleted by path.
  case unknown(String)
}

/// Finds the command that uninstalls a tool from where its binary really is (following its symlinks), not from how
/// Code would install it: the catalog's `brew install rust` says nothing about a `rustfmt` that came from rustup.
public enum ToolUninstall {
  /// - Parameters:
  ///   - tool: the command's name ("gofmt").
  ///   - path: where the PATH finds it.
  ///   - installCommand: how Code would install it, to say why a copy elsewhere isn't recognized.
  ///   - which: looks a command up on the PATH.
  public static func plan(
    tool: String, path: String, installCommand: String? = nil, home: String = NSHomeDirectory(),
    which: @escaping (String) -> String?
  ) -> ToolUninstallPlan {
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let home = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
    let finder = Finder(tool: tool, path: path, resolved: resolved, home: home, which: which)
    let finders: [KeyPath<Finder, ToolUninstallPlan?>] = [
      \.rustup, \.homebrew, \.pythonTool, \.node, \.cargo, \.dotnet, \.gem, \.pip, \.system, \.goInstall,
    ]
    if let plan = finders.lazy.compactMap({ finder[keyPath: $0] }).first { return plan }
    let expected = installCommand.map { " It isn’t where “\($0)” puts it." } ?? ""
    return .unknown("Code can’t tell how \(path) was installed, so it won’t remove it.\(expected)")
  }

  /// Quotes a word for the shell when it needs it.
  static func quoted(_ word: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
    if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
    return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private struct Finder {
    let tool: String
    let path: String
    let resolved: String
    let home: String
    let which: (String) -> String?

    /// The part of `resolved` right after `marker` ("/Cellar/"), and the part before it.
    private func component(after marker: String) -> (before: String, name: String)? {
      guard let range = resolved.range(of: marker) else { return nil }
      let name = resolved[range.upperBound...].prefix { $0 != "/" }
      return name.isEmpty ? nil : (String(resolved[..<range.lowerBound]), String(name))
    }

    /// `name`, when the PATH's is the one next to the tool; its full path when another one comes first on the PATH.
    /// nil when there is none there: it might manage another install.
    private func runner(_ name: String, at sibling: String) -> String? {
      guard FileManager.default.isExecutableFile(atPath: sibling) else { return nil }
      let onPath = which(name).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
      let expected = URL(fileURLWithPath: sibling).resolvingSymlinksInPath().path
      return onPath == expected ? name : quoted(sibling)
    }

    /// The first lines of the binary, when it's a script (a gem's or pip's stub).
    private var script: String? {
      guard let handle = FileHandle(forReadingAtPath: resolved), let data = try? handle.read(upToCount: 4096) else {
        return nil
      }
      return String(data: data, encoding: .utf8)
    }

    /// The interpreter in a script's `#!` line, when it's a path (not `/usr/bin/env ruby`).
    private var shebang: String? {
      guard let first = script?.split(separator: "\n").first, first.hasPrefix("#!/") else { return nil }
      let words = first.dropFirst(2).split(separator: " ")
      return words.count == 1 ? String(words[0]) : nil
    }

    /// `~/.cargo/bin/rustfmt` is a link to rustup, which runs the toolchain's copy.
    var rustup: ToolUninstallPlan? {
      let name = URL(fileURLWithPath: resolved).lastPathComponent
      guard name == "rustup" || name == "rustup-init", tool != "rustup" else { return nil }
      let components = ["rustfmt": "rustfmt", "cargo-fmt": "rustfmt", "rust-analyzer": "rust-analyzer", "clippy-driver": "clippy"]
      guard let component = components[tool] else {
        return .unknown("\(tool) comes with rustup’s toolchain: Code can’t tell which component it’s from.")
      }
      return .command(
        "rustup component remove \(component)", note: "This removes it from rustup’s default toolchain.")
    }

    var homebrew: ToolUninstallPlan? {
      let found = component(after: "/Cellar/").map { (prefix: $0.before, name: $0.name, flag: "") }
        ?? component(after: "/Caskroom/").map { (prefix: $0.before, name: $0.name, flag: "--cask ") }
      guard let found else { return nil }
      guard let brew = runner("brew", at: found.prefix + "/bin/brew") else {
        return .unknown("\(found.name) came from Homebrew in \(found.prefix), which has no brew command any more.")
      }
      let note = found.name == tool ? nil : "\(tool) comes with \(found.name): this removes all of \(found.name)."
      return .command("\(brew) uninstall \(found.flag)\(quoted(found.name))", note: note)
    }

    /// uv's and pipx's tools each have their own environment.
    var pythonTool: ToolUninstallPlan? {
      if let found = component(after: "/uv/tools/"), which("uv") != nil {
        return .command("uv tool uninstall \(quoted(found.name))", note: nil)
      }
      if let found = component(after: "/pipx/venvs/"), which("pipx") != nil {
        return .command("pipx uninstall \(quoted(found.name))", note: nil)
      }
      return nil
    }

    var node: ToolUninstallPlan? {
      /// A package in `node_modules`, with its scope.
      func package(_ marker: String) -> (before: String, name: String)? {
        guard var found = component(after: marker) else { return nil }
        if found.name.hasPrefix("@"),
          let scoped = component(after: marker + found.name + "/")
        {
          found.name += "/" + scoped.name
        }
        return found
      }
      if let found = package("/.bun/install/global/node_modules/") {
        return which("bun") == nil ? nil : .command("bun remove -g \(quoted(found.name))", note: nil)
      }
      guard let found = package("/lib/node_modules/") else { return nil }
      guard let npm = runner("npm", at: found.before + "/bin/npm") else {
        return .unknown("\(found.name) is an npm package in \(found.before), which has no npm command.")
      }
      return .command("\(npm) uninstall -g \(quoted(found.name))", note: nil)
    }

    /// `cargo install`'s record of which crate made which binary.
    var cargo: ToolUninstallPlan? {
      let bin = home + "/.cargo/bin/"
      guard resolved.hasPrefix(bin) else { return nil }
      let record = home + "/.cargo/.crates2.json"
      guard let data = FileManager.default.contents(atPath: record),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let installs = object["installs"] as? [String: [String: Any]],
        let key = installs.first(where: { ($0.value["bins"] as? [String])?.contains(tool) == true })?.key,
        let crate = key.split(separator: " ").first
      else {
        return .unknown("\(path) isn’t in cargo’s list of installed crates, so Code won’t remove it.")
      }
      return .command("cargo uninstall \(quoted(String(crate)))", note: nil)
    }

    var dotnet: ToolUninstallPlan? {
      let tools = home + "/.dotnet/tools/"
      guard resolved.hasPrefix(tools) else { return nil }
      guard FileManager.default.fileExists(atPath: tools + ".store/" + tool.lowercased()) else {
        return .unknown("Code can’t tell which .NET tool \(path) comes from.")
      }
      return .command("dotnet tool uninstall --global \(quoted(tool))", note: nil)
    }

    /// RubyGems' stub names its gem: `Gem.activate_bin_path('ruby-lsp', 'ruby-lsp', version)`. The gem command is the
    /// one beside the stub's Ruby. `--abort-on-dependent` so that it refuses instead of asking, as nothing can answer.
    var gem: ToolUninstallPlan? {
      guard let script, let call = script.range(of: "Gem.activate_bin_path('") else { return nil }
      let name = script[call.upperBound...].prefix { $0 != "'" }
      let ruby = shebang.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().deletingLastPathComponent().path }
      guard !name.isEmpty, let ruby, let gem = runner("gem", at: ruby + "/gem") else {
        return .unknown("\(path) is a Ruby gem’s command, but Code can’t tell which Ruby’s.")
      }
      return .command("\(gem) uninstall --all --executables --abort-on-dependent \(quoted(String(name)))", note: nil)
    }

    /// pip's script: the package that lists it in its `RECORD`, in the `site-packages` of the same install.
    var pip: ToolUninstallPlan? {
      guard let python = shebang, URL(fileURLWithPath: python).lastPathComponent.hasPrefix("python") else { return nil }
      let fm = FileManager.default
      let prefix = URL(fileURLWithPath: resolved).deletingLastPathComponent().deletingLastPathComponent().path
      let lib = prefix + "/lib"
      let folders = ((try? fm.contentsOfDirectory(atPath: lib)) ?? []).filter { $0.hasPrefix("python") }
      for folder in folders {
        let packages = "\(lib)/\(folder)/site-packages"
        for info in (try? fm.contentsOfDirectory(atPath: packages)) ?? [] where info.hasSuffix(".dist-info") {
          guard let record = fm.contents(atPath: "\(packages)/\(info)/RECORD") else { continue }
          let lines = String(decoding: record, as: UTF8.self).split(separator: "\n")
          if lines.contains(where: { $0.contains("/bin/\(tool),") }), let name = info.split(separator: "-").first {
            return .command("\(quoted(python)) -m pip uninstall -y \(quoted(String(name)))", note: nil)
          }
        }
      }
      return .unknown("\(path) is a Python script, but Code can’t tell which package it comes from.")
    }

    var system: ToolUninstallPlan? {
      let places = ["/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/Library/Developer/CommandLineTools/"]
      let comesWithXcode = resolved.hasPrefix("/Applications/Xcode") || places.contains { resolved.hasPrefix($0) }
      guard comesWithXcode else { return nil }
      return .unknown("\(tool) comes with Xcode or macOS, so it can’t be uninstalled on its own.")
    }

    var goInstall: ToolUninstallPlan? {
      guard resolved.hasPrefix(home + "/go/bin/") else { return nil }
      return .unknown("\(path) came from “go install”, which has no uninstall command. Delete the file yourself if you don’t want it.")
    }
  }
}
