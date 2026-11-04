import CodeLSP
import Foundation

/// A JSON reader over bytes, into CodeLSP's `JSONValue`: an open document's text is most of what arrives, and
/// `JSONSerialization` makes an object per string along the way. Answers the same or nil on what isn't JSON.
enum FastJSON {
  static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> JSONValue? {
    guard bytes.count > 0, let base = bytes.baseAddress else { return nil }
    var reader = Reader(t: base, n: bytes.count)
    return reader.value(depth: 0)
  }

  private struct Reader {
    let t: UnsafePointer<UInt8>
    let n: Int
    var i = 0

    mutating func skip() {
      while i < n, t[i] == 0x20 || t[i] == 0x0A || t[i] == 0x0D || t[i] == 0x09 { i += 1 }
    }

    mutating func value(depth: Int) -> JSONValue? {
      guard depth < 128 else { return nil }
      skip()
      guard i < n else { return nil }
      switch t[i] {
      case 0x7B:
        i += 1
        var object: [String: JSONValue] = [:]
        skip()
        if i < n, t[i] == 0x7D {
          i += 1
          return .object(object)
        }
        while i < n {
          skip()
          guard i < n, t[i] == 0x22, let key = string() else { return nil }
          skip()
          guard i < n, t[i] == 0x3A else { return nil }
          i += 1
          guard let item = value(depth: depth + 1) else { return nil }
          object[key] = item
          skip()
          guard i < n else { return nil }
          if t[i] == 0x2C {
            i += 1
            continue
          }
          if t[i] == 0x7D {
            i += 1
            return .object(object)
          }
          return nil
        }
        return nil
      case 0x5B:
        i += 1
        var array: [JSONValue] = []
        skip()
        if i < n, t[i] == 0x5D {
          i += 1
          return .array(array)
        }
        while i < n {
          guard let item = value(depth: depth + 1) else { return nil }
          array.append(item)
          skip()
          guard i < n else { return nil }
          if t[i] == 0x2C {
            i += 1
            continue
          }
          if t[i] == 0x5D {
            i += 1
            return .array(array)
          }
          return nil
        }
        return nil
      case 0x22:
        return string().map(JSONValue.string)
      case 0x74:
        guard n - i >= 4, memcmp(t + i, "true", 4) == 0 else { return nil }
        i += 4
        return .bool(true)
      case 0x66:
        guard n - i >= 5, memcmp(t + i, "false", 5) == 0 else { return nil }
        i += 5
        return .bool(false)
      case 0x6E:
        guard n - i >= 4, memcmp(t + i, "null", 4) == 0 else { return nil }
        i += 4
        return .null
      default:
        return number()
      }
    }

    mutating func number() -> JSONValue? {
      let start = i
      var isInteger = true
      var integer = 0
      var negative = false
      if i < n, t[i] == 0x2D {
        negative = true
        i += 1
      }
      while i < n {
        let c = t[i]
        if c >= 0x30, c <= 0x39 {
          if isInteger { integer = integer &* 10 &+ Int(c - 0x30) }
          // More digits than an integer is sure to hold.
          if i - start > 17 { isInteger = false }
        } else if c == 0x2E || c == 0x65 || c == 0x45 || c == 0x2B || c == 0x2D {
          isInteger = false
        } else {
          break
        }
        i += 1
      }
      guard i > start else { return nil }
      if isInteger { return .number(Double(negative ? -integer : integer)) }
      let text = String(decoding: UnsafeBufferPointer(start: t + start, count: i - start), as: UTF8.self)
      // `1e999` reads as infinity, which JSON can't say back.
      guard let value = Double(text), value.isFinite else { return nil }
      return .number(value)
    }

    mutating func string() -> String? {
      i += 1  // The quote.
      let start = i
      // Most strings hold no escapes: one copy, in one go.
      while i < n, t[i] != 0x22, t[i] != 0x5C { i += 1 }
      guard i < n else { return nil }
      if t[i] == 0x22 {
        let text = String(decoding: UnsafeBufferPointer(start: t + start, count: i - start), as: UTF8.self)
        i += 1
        return text
      }
      var bytes = [UInt8]()
      bytes.reserveCapacity((i - start) * 2)
      var runStart = start
      while i < n {
        let c = t[i]
        if c == 0x22 {
          bytes.append(contentsOf: UnsafeBufferPointer(start: t + runStart, count: i - runStart))
          i += 1
          return String(decoding: bytes, as: UTF8.self)
        }
        guard c == 0x5C else {
          i += 1
          continue
        }
        bytes.append(contentsOf: UnsafeBufferPointer(start: t + runStart, count: i - runStart))
        i += 1
        guard i < n else { return nil }
        switch t[i] {
        case 0x6E: bytes.append(0x0A)
        case 0x74: bytes.append(0x09)
        case 0x72: bytes.append(0x0D)
        case 0x62: bytes.append(0x08)
        case 0x66: bytes.append(0x0C)
        case 0x75:
          guard var scalar = hex4(at: i + 1) else { return nil }
          i += 4
          // A surrogate pair is one character.
          if scalar >= 0xD800, scalar < 0xDC00, i + 6 < n, t[i + 1] == 0x5C, t[i + 2] == 0x75, let low = hex4(at: i + 3), low >= 0xDC00, low < 0xE000 {
            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
            i += 6
          }
          let character = Unicode.Scalar(scalar) ?? "\u{FFFD}"
          bytes.append(contentsOf: Array(String(Character(character)).utf8))
        default: bytes.append(t[i])
        }
        i += 1
        runStart = i
      }
      return nil
    }

    func hex4(at start: Int) -> UInt32? {
      guard start + 4 <= n else { return nil }
      var value: UInt32 = 0
      for offset in 0..<4 {
        let c = t[start + offset]
        let digit: UInt32
        switch c {
        case 0x30...0x39: digit = UInt32(c - 0x30)
        case 0x41...0x46: digit = UInt32(c - 0x37)
        case 0x61...0x66: digit = UInt32(c - 0x57)
        default: return nil
        }
        value = value << 4 | digit
      }
      return value
    }
  }
}

/// Answers written straight to bytes: a reference list is thousands of small objects no one needs to build.
struct JSONWriter {
  var bytes = [UInt8]()

  init() { bytes.reserveCapacity(1 << 12) }

  mutating func raw(_ text: StaticString) {
    bytes.append(contentsOf: UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount))
  }

  mutating func raw(_ text: String) { bytes.append(contentsOf: text.utf8) }

  mutating func integer(_ value: Int) {
    if value >= 0, value < 10 {
      bytes.append(0x30 + UInt8(value))
      return
    }
    raw(String(value))
  }

  mutating func string(_ text: String) {
    var copy = text
    copy.withUTF8 { quoted($0) }
  }

  mutating func quoted(_ text: [UInt8]) { text.withUnsafeBufferPointer { quoted($0) } }

  mutating func quoted(_ text: UnsafeBufferPointer<UInt8>) {
    bytes.append(0x22)
    var runStart = 0
    for (index, c) in text.enumerated() where c < 0x20 || c == 0x22 || c == 0x5C {
      if index > runStart { bytes.append(contentsOf: UnsafeBufferPointer(rebasing: text[runStart..<index])) }
      runStart = index + 1
      switch c {
      case 0x22: raw("\\\"")
      case 0x5C: raw("\\\\")
      case 0x0A: raw("\\n")
      case 0x0D: raw("\\r")
      case 0x09: raw("\\t")
      default: raw("\\u00" + (c < 0x10 ? "0" : "") + String(c, radix: 16))
      }
    }
    if text.count > runStart { bytes.append(contentsOf: UnsafeBufferPointer(rebasing: text[runStart...])) }
    bytes.append(0x22)
  }

  /// A value from a request (its id).
  mutating func value(_ value: JSONValue) {
    switch value {
    case .null: raw("null")
    case .bool(let flag): raw(flag ? "true" : "false")
    case .number(let number):
      if number.rounded() == number, abs(number) < 1e15 {
        integer(Int(number))
      } else {
        raw(number.isFinite ? String(number) : "null")
      }
    case .string(let text): string(text)
    case .array(let items):
      raw("[")
      for (index, item) in items.enumerated() {
        if index > 0 { raw(",") }
        self.value(item)
      }
      raw("]")
    case .object(let object):
      raw("{")
      for (index, (key, item)) in object.enumerated() {
        if index > 0 { raw(",") }
        string(key)
        raw(":")
        self.value(item)
      }
      raw("}")
    }
  }
}
