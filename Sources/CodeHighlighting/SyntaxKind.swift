import Foundation

/// Xcode-style semantic syntax categories — mirrors Xcode's SourceCode theme keys:
/// Plain Text, Comments, Prose, Keywords, Strings, Numbers, Links, Preprocessors,
/// Attributes, Type Declarations, Member Declarations, Project Types, Project Members,
/// Other Types, Other Members.
///
/// The lexers emit these kinds; `CodeColorScheme` maps each kind to a color.
public enum SyntaxKind: Equatable, Sendable {
  /// Plain code text (untokenized characters and ordinary identifiers).
  case plainText
  /// Line and block comments (`//`, `/* */`, `#` where it is a comment, `--`).
  case comment
  /// Doc-comment prose (the text inside `///` / `/** */`) — Xcode's "Prose".
  case prose
  /// Language keywords (if, for, class, func, let, return, ...).
  case keyword
  /// String and character literals.
  case string
  /// Numeric literals (integers, floats, hex, binary, octal, exponents).
  case number
  /// URLs (in comments and plain text).
  case link
  /// Preprocessor directives (`#include`, `#if`, C# region directives).
  case preprocessor
  /// Attributes and annotations (`@MainActor`, `@Override`, Rust `#[derive]`),
  /// Xcode's "Attributes".
  case attribute
  /// Type names in declarations (`class Foo`, `struct Bar`, `interface Baz`).
  case typeDeclaration
  /// Function/method names in declarations (`func foo`, `def bar`, `fn baz`).
  case memberDeclaration
  /// Types defined by the project (reserved: requires project knowledge; lexers
  /// emit `otherType` — Xcode distinguishes these from framework "other" types).
  case projectType
  /// Members defined by the project (reserved: requires project knowledge; lexers
  /// emit `otherMember`).
  case projectMember
  /// Type references: capitalized identifiers in type-convention languages.
  case otherType
  /// Member accesses (`obj.prop`, `self.value`) and, in scripting languages,
  /// variables (`$var`, `$env:NAME`).
  case otherMember
}
