import Foundation

/// A JSON value, for the protocol's loosely typed messages.
public enum JSONValue: Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
  ExpressibleByNilLiteral
{
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, new in new }))
  }
  public init(nilLiteral: ()) { self = .null }

  public subscript(key: String) -> JSONValue {
    if case .object(let object) = self { return object[key] ?? .null }
    return .null
  }

  public subscript(index: Int) -> JSONValue {
    if case .array(let array) = self, array.indices.contains(index) { return array[index] }
    return .null
  }

  public var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var int: Int? {
    if case .number(let value) = self { return Int(value) }
    return nil
  }

  public var bool: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var array: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var object: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var isNull: Bool { self == .null }

  // MARK: - Serialization

  public init(any: Any) {
    switch any {
    case let value as NSNumber:
      // Booleans come back from JSONSerialization as NSNumber too.
      if CFGetTypeID(value) == CFBooleanGetTypeID() {
        self = .bool(value.boolValue)
      } else {
        self = .number(value.doubleValue)
      }
    case let value as String: self = .string(value)
    case let value as [Any]: self = .array(value.map(JSONValue.init(any:)))
    case let value as [String: Any]: self = .object(value.mapValues(JSONValue.init(any:)))
    default: self = .null
    }
  }

  public var any: Any {
    switch self {
    case .null: return NSNull()
    case .bool(let value): return value
    case .number(let value):
      return value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value as Any
    case .string(let value): return value
    case .array(let value): return value.map(\.any)
    case .object(let value): return value.mapValues(\.any)
    }
  }

  public static func decode(_ data: Data) throws -> JSONValue {
    JSONValue(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
  }

  public func encoded() throws -> Data {
    try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .withoutEscapingSlashes])
  }
}
