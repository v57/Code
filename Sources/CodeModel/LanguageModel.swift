import Foundation

/// What every language's model answers, so that an editor (CodeKit's model tier, `code-model`) asks any of them the
/// same way. Not thread-safe: one serial queue per model.
public protocol LanguageModel: AnyObject {
  var project: Project { get }
  /// Where the name at a position is defined. Line and character from 0, the character in UTF-16 units.
  func answer(path: String, line: Int, character: Int) -> Answer
  /// Where an answer's definitions are used, 1-based lines, paths relative to the root.
  func references(of answer: Answer) -> [(path: String, line: Int)]
  /// What could be typed at a position.
  func complete(path: String, line: Int, character: Int, limit: Int) -> ModelCompletionList
  /// The details of every site the answer at a position names.
  func details(path: String, line: Int, character: Int) -> (answer: Answer, details: [SymbolDetails])
  func details(of site: Site) -> SymbolDetails?
  /// How many places use what an answer names, nil when the answer is a guess.
  func referenceCount(of answer: Answer) -> Int?
  /// What it can be sure is wrong, over the project's files.
  func allFindings() -> [Finding]
  /// A site's place as a reference recorded by the language's own tools names it, 1-based (`code-model query`).
  func place(of site: Site) -> (path: String, line: Int)?
  /// Where a site is, for an editor to open: the core's `Project.location(of:)` unless the language opens something
  /// else (Rust's `mod x;` opens its file).
  func location(of site: Site) -> (path: String, line: Int, character: Int, name: String, preview: String)?
}

extension LanguageModel {
  /// Where a site is, for an editor to open (see `Project.location(of:)`).
  public func location(of site: Site) -> (path: String, line: Int, character: Int, name: String, preview: String)? {
    project.location(of: site)
  }

  public func referenceCount(of answer: Answer) -> Int? {
    guard answer.state != .unknown, !answer.byNameOnly else { return nil }
    let found = references(of: answer)
    return found.isEmpty ? nil : found.count
  }

  public func details(path: String, line: Int, character: Int) -> (answer: Answer, details: [SymbolDetails]) {
    let found = answer(path: path, line: line, character: character)
    guard found.state != .unknown else { return (found, []) }
    return (found, found.sites.prefix(30).compactMap(details(of:)))
  }

  public func allFindings() -> [Finding] { [] }

  public func place(of site: Site) -> (path: String, line: Int)? { project.place(of: site) }
}

/// A language with a model: its files, and how to make its model for a folder. Each front end has one
/// (`ModelLanguage.swift`, `ModelLanguage.go`); CodeKit and `code-model` list them.
public struct ModelLanguage: Sendable {
  /// The language's name, as `LanguageSpec` has it: "Swift", "Go".
  public var name: String
  /// Lowercased file extensions without the dot.
  public var extensions: Set<String>
  /// File names whose change means reading the whole project again (`Package.swift`, `go.mod`).
  public var manifests: Set<String>
  /// The model of the project under `root`. `trusted`: the folder's own code may be run (a manifest evaluated).
  public var make: @Sendable (_ root: String, _ trusted: Bool) -> any LanguageModel
  /// Whole file names that are the language's whatever their extension (`.zshrc`, `Rakefile`).
  public var fileNames: Set<String>
  /// Programs a `#!` line names for the language's files without an extension (`bash`, `pwsh`).
  public var interpreters: Set<String>

  public init(
    name: String, extensions: Set<String>, manifests: Set<String>, fileNames: Set<String> = [], interpreters: Set<String> = [],
    make: @escaping @Sendable (String, Bool) -> any LanguageModel
  ) {
    self.name = name
    self.extensions = extensions
    self.manifests = manifests
    self.fileNames = fileNames
    self.interpreters = interpreters
    self.make = make
  }

  /// Whether a file name (or a path's last part) is one of `manifests`; `*.csproj` matches by extension.
  public func isManifest(_ path: String) -> Bool {
    let file = path.split(separator: "/").last.map(String.init) ?? path
    if manifests.contains(file) { return true }
    guard let dot = file.lastIndex(of: ".") else { return false }
    return manifests.contains("*" + file[dot...])
  }

  /// Whether a path is one of this language's files: by its extension, its whole name, or, without an extension, the
  /// program its `#!` line names (read from disk).
  public func handles(_ path: String) -> Bool {
    let file = path.split(separator: "/").last.map(String.init) ?? path
    if let dot = file.lastIndex(of: "."), extensions.contains(file[file.index(after: dot)...].lowercased()) { return true }
    if !fileNames.isEmpty, fileNames.contains(file) { return true }
    guard !interpreters.isEmpty, !file.contains("."), let program = Self.interpreter(ofFile: path) else { return false }
    return interpreters.contains(program)
  }

  /// The program a file's `#!` line runs (`/usr/bin/env -S bash -e` names `bash`), versions dropped (`python3.12` is
  /// `python`), nil without one.
  public static func interpreter(ofFile path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let head = try? handle.read(upToCount: 256) else { return nil }
    return interpreter(ofFirstLine: String(decoding: head.prefix { $0 != 10 }, as: UTF8.self))
  }

  public static func interpreter(ofFirstLine line: String) -> String? {
    // zsh's function files: `#compdef` (a completion function), `#autoload`.
    if line.hasPrefix("#compdef") || line.hasPrefix("#autoload") { return "zsh" }
    guard line.hasPrefix("#!") else { return nil }
    let words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
    guard var program = words.first.map({ String($0.split(separator: "/").last ?? $0) }) else { return nil }
    if program == "env", let next = words.dropFirst().first(where: { !$0.hasPrefix("-") }) { program = String(next) }
    let base = program.prefix { $0.isLetter || $0 == "-" || $0 == "_" }
    return base.isEmpty ? nil : String(base)
  }
}
