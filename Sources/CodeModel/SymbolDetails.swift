import Foundation

/// What a symbol is, for a menu about it (Code's ⌘-hover): its kind and name, where it's declared, its declaration and
/// summary, what it's inside (out to its module) and, for a value, its type.

/// A symbol, or one of the declarations around it.
public struct SymbolPart: Hashable {
  public enum Kind: String {
    case module, structure, classType, actor, enumeration, protocolType, extensionDecl
    case function, initializer, deinitializer, subscriptDecl, property, variable, local, parameter, enumCase
    case typeAlias, associatedType, macro, generic
  }

  public var kind: Kind
  /// What it's called where it's used: `Trip`, `init(name:start:days:)`, `save()`, `trip`.
  public var name: String
  /// The word that declares it: `struct`, `func`, `let`; empty for a module or a parameter.
  public var keyword: String
  /// The file it's declared in (a `.swiftinterface` or a header for the SDK's), nil for a module without a manifest.
  public var path: String?
  /// From 0; the character in UTF-16 units.
  public var line: Int
  public var character: Int
  /// The module it's in, as written in an import.
  public var module: String
  /// Declared in the SDK, not the project.
  public var isSDK: Bool

  package init(kind: Kind, name: String, keyword: String, path: String?, line: Int, character: Int, module: String, isSDK: Bool) {
    self.kind = kind
    self.name = name
    self.keyword = keyword
    self.path = path
    self.line = line
    self.character = character
    self.module = module
    self.isSDK = isSDK
  }
}

public struct SymbolDetails: Hashable {
  public var symbol: SymbolPart
  /// Its declaration as one line, without attributes or body: `private func save() throws`, `let trip: Trip`.
  public var declaration: String
  /// The first paragraph of its doc comment.
  public var documentation: String?
  /// What it's inside, nearest first, ending with its module.
  public var parents: [SymbolPart]
  /// A value's type, when that's a declared type.
  public var type: SymbolPart?

  package init(symbol: SymbolPart, declaration: String, documentation: String?, parents: [SymbolPart], type: SymbolPart?) {
    self.symbol = symbol
    self.declaration = declaration
    self.documentation = documentation
    self.parents = parents
    self.type = type
  }
}
