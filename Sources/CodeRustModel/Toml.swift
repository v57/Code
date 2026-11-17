import Foundation

/// Enough TOML for `Cargo.toml` and `Cargo.lock`: tables, arrays of tables, dotted and quoted keys, strings (basic,
/// literal, multi-line), numbers and booleans as strings, arrays and inline tables. A value is a `String`, `[Any]` or
/// `[String: Any]`; what it can't read it skips.
struct Toml {
  private let bytes: [UInt8]
  private var at = 0

  static func read(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    var reader = Toml(bytes: Array(data))
    return reader.document()
  }

  init(bytes: [UInt8]) { self.bytes = bytes }

  private var current: UInt8 { at < bytes.count ? bytes[at] : 0 }

  private mutating func skipSpace(newlines: Bool) {
    while at < bytes.count {
      let byte = bytes[at]
      if byte == 0x20 || byte == 0x09 || byte == 0x0D || (newlines && byte == 0x0A) {
        at += 1
      } else if byte == 0x23 {
        while at < bytes.count, bytes[at] != 0x0A { at += 1 }
      } else {
        break
      }
    }
  }

  private mutating func skipLine() {
    while at < bytes.count, bytes[at] != 0x0A { at += 1 }
  }

  mutating func document() -> [String: Any] {
    var root: [String: Any] = [:]
    var path: [String] = []
    var isArray = false
    while true {
      skipSpace(newlines: true)
      guard at < bytes.count else { break }
      if current == 0x5B {
        at += 1
        isArray = current == 0x5B
        if isArray { at += 1 }
        path = keyPath(until: 0x5D)
        at += isArray ? 2 : 1
        if isArray {
          Toml.appendTable(&root, path)
        } else {
          Toml.ensureTable(&root, path)
        }
        skipLine()
        continue
      }
      let key = keyPath(until: 0x3D)
      guard current == 0x3D, !key.isEmpty else {
        skipLine()
        continue
      }
      at += 1
      skipSpace(newlines: false)
      let value = self.value()
      Toml.set(&root, path, isArray: isArray, key: key, value: value)
      skipLine()
    }
    return root
  }

  /// `a.b."c.d"` up to a stop byte.
  private mutating func keyPath(until stop: UInt8) -> [String] {
    var parts: [String] = []
    while at < bytes.count {
      skipSpace(newlines: false)
      if current == stop || current == 0x0A { break }
      if current == 0x22 || current == 0x27 {
        parts.append(string())
      } else {
        let start = at
        while at < bytes.count, current != 0x2E, current != stop, current != 0x20, current != 0x09, current != 0x0A { at += 1 }
        parts.append(String(decoding: bytes[start..<at], as: UTF8.self))
      }
      skipSpace(newlines: false)
      if current == 0x2E { at += 1 }
    }
    return parts
  }

  private mutating func string() -> String {
    let quote = current
    if at + 2 < bytes.count, bytes[at + 1] == quote, bytes[at + 2] == quote {
      at += 3
      if current == 0x0A { at += 1 }
      let start = at
      while at + 2 < bytes.count, !(bytes[at] == quote && bytes[at + 1] == quote && bytes[at + 2] == quote) { at += 1 }
      let text = String(decoding: bytes[start..<min(at, bytes.count)], as: UTF8.self)
      at += 3
      return text
    }
    at += 1
    var result: [UInt8] = []
    while at < bytes.count, current != quote, current != 0x0A {
      if quote == 0x22, current == 0x5C, at + 1 < bytes.count {
        at += 1
        switch current {
        case 0x6E: result.append(0x0A)
        case 0x74: result.append(0x09)
        default: result.append(current)
        }
        at += 1
        continue
      }
      result.append(current)
      at += 1
    }
    if current == quote { at += 1 }
    return String(decoding: result, as: UTF8.self)
  }

  private mutating func value() -> Any {
    switch current {
    case 0x22, 0x27:
      return string()
    case 0x5B:
      at += 1
      var list: [Any] = []
      while at < bytes.count {
        skipSpace(newlines: true)
        if current == 0x5D {
          at += 1
          break
        }
        if current == 0x2C {
          at += 1
          continue
        }
        let before = at
        list.append(value())
        if at == before { at += 1 }
      }
      return list
    case 0x7B:
      at += 1
      var table: [String: Any] = [:]
      while at < bytes.count {
        skipSpace(newlines: true)
        if current == 0x7D {
          at += 1
          break
        }
        if current == 0x2C {
          at += 1
          continue
        }
        let key = keyPath(until: 0x3D)
        guard current == 0x3D else {
          at += 1
          continue
        }
        at += 1
        skipSpace(newlines: false)
        let item = value()
        Toml.set(&table, [], isArray: false, key: key, value: item)
      }
      return table
    default:
      let start = at
      while at < bytes.count, current != 0x2C, current != 0x5D, current != 0x7D, current != 0x0A, current != 0x23 { at += 1 }
      return String(decoding: bytes[start..<at], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
  }

  private static func ensureTable(_ table: inout [String: Any], _ path: [String]) {
    guard let first = path.first else { return }
    if var list = table[first] as? [Any], var last = list.last as? [String: Any] {
      ensureTable(&last, Array(path.dropFirst()))
      list[list.count - 1] = last
      table[first] = list
      return
    }
    var inner = table[first] as? [String: Any] ?? [:]
    ensureTable(&inner, Array(path.dropFirst()))
    table[first] = inner
  }

  private static func appendTable(_ table: inout [String: Any], _ path: [String]) {
    guard let first = path.first else { return }
    if path.count == 1 {
      var list = table[first] as? [Any] ?? []
      list.append([String: Any]())
      table[first] = list
      return
    }
    var inner = table[first] as? [String: Any] ?? [:]
    appendTable(&inner, Array(path.dropFirst()))
    table[first] = inner
  }

  private static func set(_ table: inout [String: Any], _ path: [String], isArray: Bool, key: [String], value: Any) {
    if let first = path.first {
      if var list = table[first] as? [Any], var last = list.last as? [String: Any] {
        set(&last, Array(path.dropFirst()), isArray: isArray, key: key, value: value)
        list[list.count - 1] = last
        table[first] = list
      } else {
        var inner = table[first] as? [String: Any] ?? [:]
        set(&inner, Array(path.dropFirst()), isArray: isArray, key: key, value: value)
        table[first] = inner
      }
      return
    }
    guard let head = key.first else { return }
    if key.count == 1 {
      table[head] = value
      return
    }
    var inner = table[head] as? [String: Any] ?? [:]
    set(&inner, [], isArray: false, key: Array(key.dropFirst()), value: value)
    table[head] = inner
  }
}
