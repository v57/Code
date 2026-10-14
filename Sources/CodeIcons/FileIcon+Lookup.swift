import Foundation

/// Which icon a file gets: by its whole name first (`Package.swift`,
/// `Dockerfile`, `.gitignore`, `README.md`), then by its extension, then the
/// plain document.
extension FileIcon {
  static func resolve(_ name: String, isDirectory: Bool) -> String {
    let ext = (name as NSString).pathExtension
    if isDirectory {
      // Packages Finder shows as files.
      return directoryExtensions[ext] ?? "folder"
    }
    if let icon = fileNames[name] { return icon }
    let stem = (name as NSString).deletingPathExtension
    if ["readme", "license", "licence", "copying", "notice"].contains(stem) {
      return stem == "readme" ? "readme" : "license"
    }
    if name.hasPrefix(".env") { return "env" }
    if name.hasPrefix("dockerfile") || name.hasSuffix(".dockerfile") { return "docker" }
    if name.hasPrefix("docker-compose.") || name.hasPrefix("compose."),
      ["yml", "yaml"].contains(ext)
    {
      return "docker"
    }
    if name.hasPrefix(".eslintrc") || name.hasPrefix(".prettierrc") || name.hasPrefix(".babelrc") {
      return "config"
    }
    if name.hasPrefix("requirements") && ext == "txt" { return "package-python" }
    return extensions[ext] ?? "file"
  }

  static let directoryExtensions: [String: String] = [
    "xcodeproj": "xcode", "xcworkspace": "xcode", "playground": "xcode", "xcassets": "assets",
    "imageset": "image", "appiconset": "image", "colorset": "assets", "xcdatamodeld": "database",
    "rtfd": "text",
  ]

  static let fileNames: [String: String] = [
    // Package manifests and their locks
    "package.swift": "package-swift", "package.resolved": "lock", "package.json": "package-npm",
    "package-lock.json": "lock", "npm-shrinkwrap.json": "lock", "yarn.lock": "lock",
    "pnpm-lock.yaml": "lock", "pnpm-workspace.yaml": "package-npm", "bun.lockb": "lock",
    "bun.lock": "lock", ".npmrc": "config", ".nvmrc": "config", "cargo.toml": "package-cargo",
    "cargo.lock": "lock", "go.mod": "package-go", "go.sum": "lock", "go.work": "package-go",
    "go.work.sum": "lock", "gemfile": "package-ruby", "gemfile.lock": "lock", "rakefile": "ruby",
    "podfile": "package-cocoapods", "podfile.lock": "lock", "pubspec.yaml": "package-dart",
    "pubspec.lock": "lock", "pyproject.toml": "package-python", "pipfile": "package-python",
    "pipfile.lock": "lock", "setup.py": "package-python", "setup.cfg": "package-python",
    "poetry.lock": "lock", "uv.lock": "lock", "build.gradle": "package-gradle",
    "build.gradle.kts": "package-gradle", "settings.gradle": "package-gradle",
    "settings.gradle.kts": "package-gradle", "gradle.properties": "package-gradle",
    "gradlew": "package-gradle", "composer.json": "php", "composer.lock": "lock",
    "mix.exs": "elixir", "mix.lock": "lock", "flake.nix": "nix", "flake.lock": "lock",
    "build.zig": "zig", "build.zig.zon": "zig",
    // Build files
    "makefile": "make", "gnumakefile": "make", "justfile": "make", "cmakelists.txt": "cmake",
    "containerfile": "docker", ".dockerignore": "docker",
    // Git
    ".gitignore": "git", ".gitattributes": "git", ".gitmodules": "git", ".gitkeep": "git",
    ".gitconfig": "git", ".mailmap": "git", ".git-blame-ignore-revs": "git",
    // Settings
    ".editorconfig": "config", ".swiftlint.yml": "config", ".swift-format": "config",
    ".swift-version": "config", ".clang-format": "config", ".clang-tidy": "config",
    ".python-version": "config", ".ruby-version": "config", ".node-version": "config",
    ".tool-versions": "config", ".prettierignore": "config", ".eslintignore": "config",
    ".zshrc": "shell", ".zprofile": "shell", ".zshenv": "shell", ".bashrc": "shell",
    ".bash_profile": "shell", ".profile": "shell", "changelog.md": "markdown",
  ]

  static let extensions: [String: String] = {
    let groups: [String: [String]] = [
      // Languages
      "swift": ["swift", "swiftinterface"], "c": ["c"],
      "cpp": ["cc", "cpp", "cxx", "c++", "ixx", "cppm"],
      "header": ["h", "hh", "hpp", "hxx", "h++", "inl", "modulemap"], "objc": ["m", "mm"],
      "csharp": ["cs", "csx", "csproj", "sln"], "go": ["go"], "rust": ["rs"],
      "java": ["java", "class", "jar"], "kotlin": ["kt", "kts"], "dart": ["dart"],
      "scala": ["scala", "sc", "sbt"], "php": ["php", "phtml"], "javascript": ["js", "mjs", "cjs"],
      "typescript": ["ts", "mts", "cts"], "react": ["jsx"], "react-ts": ["tsx"],
      "python": ["py", "pyi", "pyw", "ipynb"], "ruby": ["rb", "rake", "gemspec", "erb"],
      "lua": ["lua", "luau"], "perl": ["pl", "pm"],
      "shell": ["sh", "bash", "zsh", "fish", "ksh", "command", "tool"],
      "powershell": ["ps1", "psm1", "psd1", "bat", "cmd"],
      "sql": ["sql", "psql", "mysql", "pgsql", "cql"], "html": ["html", "htm", "xhtml"],
      "css": ["css"], "sass": ["scss", "sass"], "less": ["less"], "vue": ["vue"],
      "svelte": ["svelte"], "elixir": ["ex", "exs", "heex", "leex"], "erlang": ["erl", "hrl"],
      "haskell": ["hs", "lhs"], "ocaml": ["ml", "mli"], "fsharp": ["fs", "fsi", "fsx"],
      "clojure": ["clj", "cljs", "cljc", "edn"], "elm": ["elm"], "zig": ["zig", "zon"],
      "r": ["r", "rmd"], "julia": ["jl"], "nim": ["nim", "nims", "nimble"],
      "groovy": ["groovy", "gradle"], "assembly": ["s", "asm"], "graphql": ["graphql", "gql"],
      "proto": ["proto"], "terraform": ["tf", "tfvars", "hcl"], "nix": ["nix"], "vim": ["vim"],
      "wasm": ["wasm", "wat"],
      // Data and documents
      "json": ["json", "jsonc", "json5", "jsonl", "geojson", "webmanifest"],
      "yaml": ["yml", "yaml"], "toml": ["toml"],
      "xml": ["xml", "xsd", "xsl", "xslt", "xcscheme", "xcsettings", "xcworkspacedata"],
      "plist": ["plist"], "config": ["ini", "cfg", "conf", "properties", "config"], "env": ["env"],
      "lock": ["lock", "resolved"], "csv": ["csv", "tsv"],
      "markdown": ["md", "markdown", "mdx", "mdown"], "text": ["txt", "rtf", "text"],
      "log": ["log"], "pdf": ["pdf"],
      "image": [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "ico", "icns",
        "avif",
      ], "svg": ["svg"], "font": ["ttf", "otf", "woff", "woff2"],
      "audio": ["mp3", "wav", "m4a", "aac", "flac", "aiff", "aif", "ogg", "caf"],
      "video": ["mp4", "mov", "m4v", "mkv", "webm", "avi"],
      "archive": ["zip", "gz", "tgz", "tar", "xz", "bz2", "7z", "rar", "zst", "dmg", "pkg", "xip"],
      "binary": ["o", "a", "so", "dylib", "dll", "exe", "bin", "dat"],
      "database": ["sqlite", "sqlite3", "db", "duckdb", "realm"],
      "certificate": [
        "pem", "crt", "cer", "der", "p12", "pfx", "mobileprovision", "provisionprofile",
      ],
      // Apple
      "xcode": ["pbxproj", "xctestplan", "xcfilelist"], "xcconfig": ["xcconfig"],
      "strings": ["strings", "stringsdict", "xcstrings", "po", "pot", "arb", "xliff", "xlf"],
      "entitlements": ["entitlements", "xcprivacy"], "interface": ["storyboard", "xib"],
    ]
    var map: [String: String] = [:]
    for (icon, extensions) in groups {
      for ext in extensions { map[ext] = icon }
    }
    return map
  }()
}
