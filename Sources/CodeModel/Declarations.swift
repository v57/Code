import CodeScan
import Foundation

/// Layer 1: a file's declarations, read from its tokens by a language's parser. Types stay token ranges until someone
/// asks, and bodies stay a pair of tokens. Nothing here points at anything outside the file, so a file's declarations
/// never change once made.
public typealias Name = UInt64

@inlinable @inline(__always) package func name(_ text: String) -> Name { hashName(text) }

public enum DeclKind: UInt8 {
  case structure, classType, actor, enumeration, protocolType, extensionDecl
  case function, initializer, deinitializer, subscriptDecl, variable, enumCase, typeAlias, associatedType, macro
  /// A named scope of declarations that is no type: TypeScript's `namespace` and `declare module "x"`, C++'s
  /// `namespace`, Rust's `mod`.
  case namespace
  @inlinable package var isNominal: Bool { self == .structure || self == .classType || self == .actor || self == .enumeration || self == .protocolType }
  @inlinable package var isType: Bool { isNominal || self == .typeAlias || self == .associatedType }
  @inlinable package var isAccessorHolder: Bool { self == .variable || self == .subscriptDecl }
  @inlinable package var isCallable: Bool { self == .function || self == .initializer || self == .subscriptDecl || self == .macro }
  @inlinable package var hasMembers: Bool { isNominal || self == .extensionDecl || self == .namespace }
}

public enum Access: UInt8, Comparable {
  case isPrivate, filePrivate, inherited, package, isPublic
  public static func < (a: Access, b: Access) -> Bool { a.rawValue < b.rawValue }
}

public struct Decl {
  package var kind: DeclKind
  package var access: Access = .inherited
  package var isStatic = false
  package var isLocal = false
  /// `init?`.
  package var isFailable = false
  package var name: Name
  package var nameToken: Int32
  package var first: Int32
  package var end: Int32 = 0
  package var parent: Int32
  package var bodyOpen: Int32 = -1
  package var bodyClose: Int32 = -1
  /// The return type, a variable's type, what an alias names, or what an extension extends: tokens, not yet read.
  package var typeStart: Int32 = -1
  package var typeEnd: Int32 = -1
  package var initStart: Int32 = -1
  package var initEnd: Int32 = -1
  package var paramStart: Int32 = 0
  package var paramCount: Int32 = 0
  package var genericStart: Int32 = 0
  package var genericCount: Int32 = 0
  package var inheritStart: Int32 = 0
  package var inheritCount: Int32 = 0
  /// What follows `where`, up to the body: the requirements, not yet read.
  package var whereStart: Int32 = -1
  package var whereEnd: Int32 = -1
  /// Which of its initializer's values is this declaration's, from 1 (`a, b = f()`); 0 when the initializer is its own.
  package var valueIndex: Int32 = 0

  package init(kind: DeclKind, name: Name, nameToken: Int32, first: Int32, parent: Int32) {
    self.kind = kind
    self.name = name
    self.nameToken = nameToken
    self.first = first
    self.parent = parent
  }
}

public struct Param {
  package var label: Name
  package var local: Name
  package var nameToken: Int32
  package var typeStart: Int32
  package var typeEnd: Int32
  package var hasDefault: Bool
  package var variadic: Bool

  package init(label: Name, local: Name, nameToken: Int32, typeStart: Int32, typeEnd: Int32, hasDefault: Bool, variadic: Bool) {
    self.label = label
    self.local = local
    self.nameToken = nameToken
    self.typeStart = typeStart
    self.typeEnd = typeEnd
    self.hasDefault = hasDefault
    self.variadic = variadic
  }
}

package struct Generic {
  package var name: Name
  package var token: Int32

  package init(name: Name, token: Int32) {
    self.name = name
    self.token = token
  }
}

public struct Import {
  package var module: Name
  package var moduleName: String
  package var isExported: Bool
  package var isTestable: Bool
  /// The name the file gives the module (`import f "fmt"`, `import x as y`), 0 for its own; `aliasToken` is where.
  package var alias: Name = 0
  package var aliasToken: Int32 = -1
  /// Where the import's path or module name is written.
  package var token: Int32 = -1
  /// The declaration it takes from the module, 0 for the module itself: `import {a as b} from "m"` (with `alias` b),
  /// Python's `from m import a`, Rust's `use m::a`. `memberToken` is where it's written.
  package var member: Name = 0
  package var memberToken: Int32 = -1

  package init(module: Name, moduleName: String, isExported: Bool, isTestable: Bool) {
    self.module = module
    self.moduleName = moduleName
    self.isExported = isExported
    self.isTestable = isTestable
  }
}

/// A declaration: which file, which entry of its table.
public struct DeclRef: Hashable {
  @usableFromInline package var unit: Int32
  @usableFromInline package var decl: Int32

  package init(unit: Int32, decl: Int32) {
    self.unit = unit
    self.decl = decl
  }
}

/// What an answer names: a declaration, a local or generic parameter by its token, or a module.
public enum Site: Hashable {
  case decl(DeclRef)
  case local(unit: Int32, token: Int32)
  case generic(unit: Int32, token: Int32)
  case module(Name)
}
