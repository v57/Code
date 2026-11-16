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
public struct ModelLanguage {
  /// The language's name, as `LanguageSpec` has it: "Swift", "Go".
  public var name: String
  /// Lowercased file extensions without the dot.
  public var extensions: Set<String>
  /// File names whose change means reading the whole project again (`Package.swift`, `go.mod`).
  public var manifests: Set<String>
  /// The model of the project under `root`. `trusted`: the folder's own code may be run (a manifest evaluated).
  public var make: (_ root: String, _ trusted: Bool) -> any LanguageModel

  public init(name: String, extensions: Set<String>, manifests: Set<String>, make: @escaping (String, Bool) -> any LanguageModel) {
    self.name = name
    self.extensions = extensions
    self.manifests = manifests
    self.make = make
  }

  /// Whether a path is one of this language's files.
  public func handles(_ path: String) -> Bool {
    guard let dot = path.lastIndex(of: "."), !path[dot...].contains("/") else { return false }
    return extensions.contains(path[path.index(after: dot)...].lowercased())
  }
}
