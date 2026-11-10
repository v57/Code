#if os(macOS) || os(Windows) || os(Linux)
  import CodeScan
  import Foundation

  /// A declaration Open Quickly lists: found by Code's scanner over the project, every language.
  public struct ProjectSymbol: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
      case type, `protocol`, `extension`, function, method, constructor, property, variable, constant, enumCase
      case module, other

      init(_ kind: SymbolKind) {
        switch kind {
        case .class, .struct, .enum, .typeAlias: self = .type
        case .interface: self = .protocol
        case .extension: self = .extension
        case .function: self = .function
        case .method: self = .method
        case .constructor: self = .constructor
        case .property, .field, .key: self = .property
        case .variable: self = .variable
        case .constant: self = .constant
        case .enumMember: self = .enumCase
        case .module, .namespace: self = .module
        }
      }
    }

    public var name: String
    public var kind: Kind
    /// The declarations it's inside, outermost first.
    public var containers: [String]
    public var url: URL
    /// From 0.
    public var line: Int
    /// From 0, in UTF-16 units.
    public var column: Int
    /// The part of the query matched against the name (after the last `.`), for highlighting it.
    public var nameQuery: String

    public var id: String { "\(url.path):\(line):\(column)" }

    /// `Outer.Inner.name`.
    public var qualifiedName: String { (containers + [name]).joined(separator: ".") }
  }

  extension ProjectServices {
    /// Declarations in the project whose name fuzzily matches `query`, best first. A qualified query (`Some.value`,
    /// `A.B.c`, `Some::value`) matches the containers too, innermost first, and `Some.` lists Some's members.
    /// Empty when the scanner is off in Settings.
    public func symbols(matching query: String, limit: Int = 60) async -> [ProjectSymbol] {
      guard settings.usesScanner else { return [] }
      return await tiers.scannerSymbols(matching: query, limit: limit)
    }

    /// Opens a symbol's file at its name, remembered for Go Back.
    public func open(_ symbol: ProjectSymbol) {
      open(symbol.url, line: symbol.line + 1, column: symbol.column + 1, length: symbol.name.utf16.count)
    }
  }
#endif
