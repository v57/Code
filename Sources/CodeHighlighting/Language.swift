import Foundation

/// Picks the language of a file from its name, extension or shebang line.
public enum Language {
  /// Whole file names that decide the language on their own, lowercased.
  private static let byFileName: [String: String] = [
    "makefile": "makefile", "gnumakefile": "makefile", "dockerfile": "dockerfile",
    "containerfile": "dockerfile", "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby",
    "fastfile": "ruby", "appfile": "ruby", "brewfile": "ruby", "vagrantfile": "ruby",
    ".bashrc": "shell", ".bash_profile": "shell", ".zshrc": "shell", ".zprofile": "shell",
    ".zshenv": "shell", ".profile": "shell", ".envrc": "shell", "pkgbuild": "shell",
    "cmakelists.txt": "makefile", ".swift-format": "json", ".swiftlint.yml": "yaml",
    "package.resolved": "json", ".prettierrc": "json", ".eslintrc": "json", ".babelrc": "json",
    "cargo.lock": "toml", "pipfile": "toml",
  ]

  /// Extensions (lowercased, without the dot) that differ from a language alias.
  private static let byExtension: [String: String] = [
    "cjs": "js", "mts": "ts", "cts": "ts", "pyw": "py", "pyi": "py", "h": "c", "hh": "cpp",
    "cxx": "cpp", "c++": "cpp", "ipp": "cpp", "inl": "cpp", "gradle": "kotlin", "groovy": "java",
    "rake": "ruby", "gemspec": "ruby", "podspec": "ruby", "bash": "shell", "command": "shell",
    "psm1": "powershell", "psd1": "powershell", "lhs": "haskell", "cabal": "haskell",
    "entitlements": "xml", "xcprivacy": "xml", "xcscheme": "xml", "xcworkspacedata": "xml", "xcstrings": "json",
    "csproj": "xml", "resx": "xml", "xaml": "xml", "vue": "html",
    "svelte": "html", "astro": "html", "markdown": "md", "mdown": "md", "ddl": "sql", "cql": "cql", "redis": "redis",
    "dockerfile": "dockerfile", "mk": "makefile", "conf": "shell", "env": "shell",
  ]

  /// Interpreter names in a "#!" line.
  private static let byInterpreter: [String: String] = [
    "sh": "shell", "bash": "shell", "zsh": "shell", "ksh": "shell", "dash": "shell",
    "fish": "shell", "python": "python", "python3": "python", "python2": "python",
    "node": "javascript", "deno": "typescript", "bun": "javascript", "ruby": "ruby",
    "perl": "shell", "php": "php", "lua": "lua", "swift": "swift", "pwsh": "powershell",
    "make": "makefile",
  ]

  /// The language for `url`, or nil for plain text. `firstLine` (when known)
  /// lets a "#!" line decide for files without an extension.
  public static func detect(url: URL, firstLine: String? = nil) -> LanguageSpec? {
    let name = url.lastPathComponent.lowercased()
    if let alias = byFileName[name] { return CodeHighlighter.spec(forLanguage: alias) }
    if name.hasPrefix("dockerfile.") || name.hasSuffix(".dockerfile") {
      return CodeHighlighter.spec(forLanguage: "dockerfile")
    }
    let ext = url.pathExtension.lowercased()
    if !ext.isEmpty {
      if let alias = byExtension[ext] { return CodeHighlighter.spec(forLanguage: alias) }
      if let spec = CodeHighlighter.spec(forLanguage: ext) { return spec }
    }
    if let firstLine { return detect(shebang: firstLine) }
    return nil
  }

  /// The language named by a "#!" line: "#!/bin/zsh", "#!/usr/bin/env python3".
  public static func detect(shebang line: String) -> LanguageSpec? {
    guard line.hasPrefix("#!") else { return nil }
    let words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard var program = words.first.map({ String($0.split(separator: "/").last ?? $0) }) else {
      return nil
    }
    // "env" runs the next word that isn't an option ("env -S node --flag").
    if program == "env", let next = words.dropFirst().first(where: { !$0.hasPrefix("-") }) {
      program = String(next)
    }
    if let alias = byInterpreter[program] { return CodeHighlighter.spec(forLanguage: alias) }
    // Versioned names: "python3.12", "ruby2.7".
    let base = String(program.prefix(while: { $0.isLetter }))
    return byInterpreter[base].flatMap { CodeHighlighter.spec(forLanguage: $0) }
  }
}
