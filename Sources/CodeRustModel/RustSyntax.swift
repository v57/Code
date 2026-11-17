import CodeModel
import CodeScan
import Foundation

/// What `#[cfg(…)]` holds on this Mac, as Cargo builds a crate for it: the target's names and values, the crate's
/// features, and `test` inside test code (a `#[cfg(test)]` module, a file under `tests/`).
final class RustConfig: @unchecked Sendable {
  /// Features on per crate folder (a package's, or a dependency's in the registry), longest folder first.
  private(set) var features: [(directory: String, features: Set<String>)] = []
  /// Folders whose files are test targets (`tests/`): `test` holds everywhere in them.
  private(set) var testFolders: [String] = []
  private let lock = NSLock()

  func setFeatures(_ list: Set<String>, for directory: String) {
    lock.lock()
    defer { lock.unlock() }
    features.removeAll { $0.directory == directory }
    features.append((directory, list))
    features.sort { $0.directory.count > $1.directory.count }
  }

  func addTestFolder(_ directory: String) {
    lock.lock()
    defer { lock.unlock() }
    if !testFolders.contains(directory) { testFolders.append(directory) }
  }

  func features(forPath path: String) -> Set<String> {
    lock.lock()
    defer { lock.unlock() }
    for entry in features where path.hasPrefix(entry.directory + "/") { return entry.features }
    return []
  }

  func isTestFile(_ path: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return testFolders.contains { path.hasPrefix($0 + "/") }
  }

  #if arch(x86_64)
    static let arch = "x86_64"
  #else
    static let arch = "aarch64"
  #endif
  #if os(macOS)
    static let os = "macos", family = "unix", vendor = "apple", env = ""
  #elseif os(Linux)
    static let os = "linux", family = "unix", vendor = "unknown", env = "gnu"
  #elseif os(Windows)
    static let os = "windows", family = "windows", vendor = "pc", env = "msvc"
  #else
    static let os = "ios", family = "unix", vendor = "apple", env = ""
  #endif

  /// `name = "value"` on this target.
  static func holds(_ name: String, _ value: String?, features: Set<String>, test: Bool) -> Bool {
    guard let value else {
      switch name {
      case "unix": return family == "unix"
      case "windows": return family == "windows"
      case "test": return test
      case "debug_assertions": return true
      default: return false
      }
    }
    switch name {
    case "feature": return features.contains(value)
    case "target_os": return value == os
    case "target_family": return value == family
    case "target_arch": return value == arch
    case "target_vendor": return value == vendor
    case "target_env": return value == env
    case "target_pointer_width": return value == "64"
    case "target_endian": return value == "little"
    case "target_has_atomic": return value != "128"
    case "panic": return value == "unwind"
    case "target_feature":
      return arch == "aarch64" ? ["neon", "aes", "crc", "sha2", "lse", "fp16", "rcpc", "dotprod", "rdm", "v8.1a", "v8.2a", "v8.3a"].contains(value)
        : ["sse", "sse2", "sse3", "ssse3", "sse4.1", "sse4.2", "fxsr", "cmpxchg16b"].contains(value)
    default: return false
    }
  }
}

/// Rust's reading of a file into the core's tables (`RustParser`), with the tokens it reads: operator runs split into
/// Rust's tokens (`>>` is two `>` so that generics close, `'a` is one token), attributes as tokens (`#`, `[`, words),
/// `t.0.1`'s float split into fields.
final class RustSyntax: LanguageSyntax {
  let profile = LexProfile.profile(forLanguage: "rust")!
  let parametersHaveLabels = false
  let config: RustConfig

  init(config: RustConfig) { self.config = config }

  func parse(_ unit: Unit) -> UInt64 {
    var parser = RustParser(unit: unit, config: config)
    parser.parseFile()
    return parser.shape
  }

  func evaluateCondition(_ unit: Unit, _ i: inout Int) -> Bool {
    i += 1
    return true
  }

  /// Rust has no conditional directives: `#[cfg]` is read per item by the parser.
  func conditional(_ unit: Unit, _ i: Int) -> ConditionalDirective { .none }

  func codeTokens(_ source: SourceFile) -> [Token] {
    let text = source.text
    var kept = [Token]()
    kept.reserveCapacity(source.tokens.count + source.tokens.count / 4)
    let all = source.tokens
    var index = 0
    while index < all.count {
      let token = all[index]
      index += 1
      switch token.kind {
      case .comment, .docComment:
        continue
      case .attribute:
        attributeTokens(text, token.start, token.end, into: &kept)
      case .punctuation:
        splitOperators(text, token.start, token.end, into: &kept)
        // `'a`, `'static`, `'outer`: one token with what follows the quote.
        if text[token.end - 1] == 0x27, index < all.count, all[index].start == token.end,
          all[index].kind == .identifier || all[index].kind == .keyword || all[index].kind == .declarationKeyword
        {
          kept.removeLast()
          kept.append(Token(kind: .string, start: token.end - 1, end: all[index].end))
          index += 1
        }
      case .number:
        // `t.0.1`: the number `0.1` after a `.` is two fields.
        if let previous = kept.last, previous.kind == .punctuation, previous.length == 1, text[previous.start] == 0x2E,
          let dot = (token.start..<token.end).first(where: { text[$0] == 0x2E })
        {
          kept.append(Token(kind: .number, start: token.start, end: dot))
          kept.append(Token(kind: .punctuation, start: dot, end: dot + 1))
          kept.append(Token(kind: .number, start: dot + 1, end: token.end))
        } else {
          kept.append(token)
        }
      case .identifier:
        // `r#type`: a raw identifier is one name.
        if token.length == 1, text[token.start] == 0x72, index + 1 < all.count, all[index].length == 1, text[all[index].start] == 0x23,
          all[index].start == token.end, all[index + 1].start == token.end + 1, all[index + 1].kind == .identifier || all[index + 1].kind == .keyword
        {
          kept.append(Token(kind: .identifier, start: token.start, end: all[index + 1].end))
          index += 2
        } else {
          kept.append(token)
        }
      default:
        kept.append(token)
      }
    }
    return kept
  }

  private static let operators: [[UInt8]] = [
    "<<=", ">>=", "...", "..=", "::", "->", "=>", "==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "%=", "^=", "&=", "|=", "..",
  ].map { Array($0.utf8) }

  /// A run of operator bytes as Rust's tokens; `<<` and `>>` stay two, as generics read them.
  private func splitOperators(_ text: UnsafePointer<UInt8>, _ start: Int, _ end: Int, into kept: inout [Token]) {
    var i = start
    while i < end {
      var length = 1
      for op in RustSyntax.operators where op.count <= end - i {
        var matches = true
        for (k, byte) in op.enumerated() where text[i + k] != byte {
          matches = false
          break
        }
        if matches {
          length = op.count
          break
        }
      }
      // `&&x` is two references in a type or pattern, but `a && b` reads the same either way: kept as one.
      kept.append(Token(kind: .punctuation, start: i, end: i + length))
      i += length
    }
  }

  private static let attributeKeywords: Set<String> = ["crate", "self", "super", "Self", "in", "pub", "true", "false", "unsafe"]

  /// `#[derive(Debug)]` as `#`, `[`, `derive`, `(`, `Debug`, `)`, `]`.
  private func attributeTokens(_ text: UnsafePointer<UInt8>, _ start: Int, _ end: Int, into kept: inout [Token]) {
    var i = start
    while i < end {
      let byte = text[i]
      if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
        i += 1
      } else if byte == 0x5F || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A) || byte >= 0x80 {
        var j = i + 1
        while j < end, text[j] == 0x5F || (text[j] | 0x20 >= 0x61 && text[j] | 0x20 <= 0x7A) || (text[j] >= 0x30 && text[j] <= 0x39) || text[j] >= 0x80 { j += 1 }
        // `r"…"`, `r#"…"#`: a raw string.
        if j == i + 1, byte == 0x72, j < end, text[j] == 0x22 || text[j] == 0x23 {
          var hashes = 0
          var k = j
          while k < end, text[k] == 0x23 {
            hashes += 1
            k += 1
          }
          if k < end, text[k] == 0x22 {
            k += 1
            while k < end {
              if text[k] == 0x22 {
                var h = 0
                while h < hashes, k + 1 + h < end, text[k + 1 + h] == 0x23 { h += 1 }
                if h == hashes {
                  k += 1 + hashes
                  break
                }
              }
              k += 1
            }
            kept.append(Token(kind: .string, start: i, end: min(k, end)))
            i = min(k, end)
            continue
          }
        }
        let word = String(decoding: UnsafeBufferPointer(start: text + i, count: j - i), as: UTF8.self)
        kept.append(Token(kind: RustSyntax.attributeKeywords.contains(word) ? .keyword : .identifier, start: i, end: j))
        i = j
      } else if byte >= 0x30 && byte <= 0x39 {
        var j = i + 1
        while j < end, text[j] == 0x5F || text[j] == 0x2E || (text[j] | 0x20 >= 0x61 && text[j] | 0x20 <= 0x7A) || (text[j] >= 0x30 && text[j] <= 0x39) { j += 1 }
        kept.append(Token(kind: .number, start: i, end: j))
        i = j
      } else if byte == 0x22 {
        var j = i + 1
        while j < end, text[j] != 0x22 { j += text[j] == 0x5C ? 2 : 1 }
        j = min(j + 1, end)
        kept.append(Token(kind: .string, start: i, end: j))
        i = j
      } else if byte == 0x28 || byte == 0x5B || byte == 0x7B {
        kept.append(Token(kind: .open, start: i, end: i + 1))
        i += 1
      } else if byte == 0x29 || byte == 0x5D || byte == 0x7D {
        kept.append(Token(kind: .close, start: i, end: i + 1))
        i += 1
      } else if byte == 0x3A, i + 1 < end, text[i + 1] == 0x3A {
        kept.append(Token(kind: .punctuation, start: i, end: i + 2))
        i += 2
      } else {
        kept.append(Token(kind: .punctuation, start: i, end: i + 1))
        i += 1
      }
    }
  }
}

/// Words the front end compares often.
enum RustWord {
  static let selfValue = name("self"), selfType = name("Self"), crate = name("crate"), superWord = name("super")
  static let underscore = name("_"), glob = name("*"), blanket = name("<blanket>"), slice = name("slice"), array = name("array")
  static let tuple = name("tuple"), pointer = name("pointer"), function = name("fn"), str = name("str"), never = name("!")
  static let std = name("std"), core = name("core"), alloc = name("alloc"), prelude = name("prelude")
  static let some = name("Some"), none = name("None"), ok = name("Ok"), err = name("Err")
  static let option = name("Option"), result = name("Result"), string = name("String"), vec = name("Vec"), box = name("Box")
  static let deref = name("Deref"), target = name("Target"), iterator = name("Iterator"), intoIterator = name("IntoIterator")
  static let item = name("Item"), intoIter = name("IntoIter"), output = name("Output"), future = name("Future"), intoFuture = name("IntoFuture")
  static let fnTrait = name("Fn"), fnMut = name("FnMut"), fnOnce = name("FnOnce"), index = name("Index"), sized = name("Sized")
  static let bool = name("bool"), char = name("char"), usize = name("usize"), i32 = name("i32"), f64 = name("f64"), u8 = name("u8")
  static let range = name("Range"), rangeInclusive = name("RangeInclusive"), unit = name("()")
}

/// The type constructors Rust builds without a declaration.
enum RustTy {
  /// `&T` and `&mut T`.
  static let reference = hashName("&ref"), mutReference = hashName("&mut")
  /// `*const T`, `*mut T`.
  static let raw = hashName("*raw")
}
