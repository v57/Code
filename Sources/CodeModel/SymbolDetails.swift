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

extension SymbolPart.Kind {
  /// A declaration's kind as a part: a variable inside a type is a property.
  package init(_ decl: Decl, in unit: Unit) {
    switch decl.kind {
    case .structure: self = .structure
    case .classType: self = .classType
    case .actor: self = .actor
    case .enumeration: self = .enumeration
    case .protocolType: self = .protocolType
    case .extensionDecl: self = .extensionDecl
    case .function: self = .function
    case .initializer: self = .initializer
    case .deinitializer: self = .deinitializer
    case .subscriptDecl: self = .subscriptDecl
    case .variable: self = decl.parent >= 0 && unit.decls[Int(decl.parent)].kind.hasMembers ? .property : .variable
    case .enumCase: self = .enumCase
    case .typeAlias: self = .typeAlias
    case .associatedType: self = .associatedType
    case .macro: self = .macro
    case .namespace: self = .module
    }
  }
}

extension Project {
  /// The module a unit is in, as an import names it.
  package func moduleName(of unit: Unit) -> String { modules[unit.moduleName]?.publishedName ?? "" }

  /// Whether a unit is the SDK's (an interface, generated from headers, or a module read from the SDK).
  package func isSDK(_ unit: Unit) -> Bool {
    unit.isInterface || !unit.headerLines.isEmpty || modules[unit.moduleName]?.isSDK == true
  }

  /// A declaration as a part, at its name: `name` and `keyword` as the language writes them.
  package func part(_ ref: DeclRef, name: String, keyword: String) -> SymbolPart? {
    guard let at = location(of: .decl(ref)) else { return nil }
    let holder = units[Int(ref.unit)]
    return SymbolPart(
      kind: SymbolPart.Kind(holder.decls[Int(ref.decl)], in: holder), name: name, keyword: keyword, path: at.path, line: at.line,
      character: at.character, module: moduleName(of: holder), isSDK: isSDK(holder))
  }
}
