import CodeScan
import Foundation

/// What a language's front end gives the core about its files: how they're lexed and read into declarations, and
/// what its conditional compilation keeps.
package protocol LanguageSyntax: AnyObject {
  var profile: LexProfile { get }
  /// Reads a file's declarations into its tables (`decls`, `params`, `generics`, `ranges`, `imports`) and returns its
  /// shape: a hash of everything other files can see, which holds across an edit to a body.
  func parse(_ unit: Unit) -> UInt64
  /// A condition of conditional compilation from token `i`, with `i` moved past it: whether its branch is taken.
  func evaluateCondition(_ unit: Unit, _ i: inout Int) -> Bool
  /// Whether a parameter's name can follow an argument label (`label name`): that word is the same parameter's.
  var parametersHaveLabels: Bool { get }
}

/// What a language's front end gives the core about a project: which files make which module, and where a module an
/// import names is found.
package protocol ProjectLayout: AnyObject {
  var syntax: any LanguageSyntax { get }
  /// The source files under a directory, sorted.
  func sourceFiles(in directory: String) -> [String]
  /// The module of a file in the project, by its path relative to the root.
  func moduleName(ofRelative path: String) -> String
  /// Loads a module that isn't the project's: next to it, or in the SDK. Registers it with `Project.register`.
  func loadModule(_ moduleName: Name, display: String, into project: Project) -> Module?
  /// The modules every file sees without an import, in the order names resolve.
  var implicitModules: [String] { get }
  /// How a place in an SDK module's interface is named: `sdk:<module><extension>`.
  var interfaceExtension: String { get }
}

/// What a front end keeps for a body once asked for, dropped with the file.
package protocol BodyFacts: AnyObject {
  /// Types read in the body: stale once any declaration changed.
  func dropTypes()
}
