import CodeModel
import Foundation

/// Which C language a file is read as: it decides the predefined macros (`__cplusplus`, `__OBJC__`) and the words that
/// are keywords.
package struct CDialect: OptionSet, Hashable, Sendable {
  package let rawValue: UInt8
  package init(rawValue: UInt8) { self.rawValue = rawValue }
  package static let cpp = CDialect(rawValue: 1)
  package static let objc = CDialect(rawValue: 2)
  package static let c: CDialect = []

  /// By a source file's extension; nil for a header (`.h`), which the project decides.
  package static func of(path: String) -> CDialect? {
    guard let dot = path.lastIndex(of: ".") else { return nil }
    switch path[path.index(after: dot)...].lowercased() {
    case "c": return .c
    case "cc", "cpp", "cxx", "c++", "hpp", "hh", "hxx", "ipp", "tcc", "inl": return .cpp
    case "m": return .objc
    case "mm": return [.cpp, .objc]
    default: return nil
    }
  }

  /// clang's `-x` name.
  var clangName: String {
    switch (contains(.cpp), contains(.objc)) {
    case (true, true): return "objective-c++"
    case (true, false): return "c++"
    case (false, true): return "objective-c"
    default: return "c"
    }
  }
}

/// A macro's definition as `#if` reads it: an object-like macro's replacement text, or a function-like one.
package struct CMacro {
  package var value: String
  package var isFunction: Bool
}

/// The macros a project's `#if` lines see before a file's own: the compiler's predefined ones for this platform
/// (`clang -dM -E`, with the SDK's configuration headers: TargetConditionals, cdefs, Availability), the compile
/// commands' `-D`, and what the project's headers define. A header's own macros (its include guard) don't count for it.
package final class CMacroTable {
  package var macros: [Name: CMacro] = [:]
  /// Which file defined a macro: one never sees its own from here (include guards, defaults it sets).
  package var definedIn: [Name: String] = [:]

  init() {}

  private static let lock = NSLock()
  nonisolated(unsafe) private static var predefinedCache: [String: [Name: CMacro]] = [:]

  /// The compiler's own macros for a dialect, read once per process: `clang -dM -E` with the SDK's configuration
  /// headers, or a short list for this platform without a compiler.
  static func predefined(_ dialect: CDialect, sdk: String, std: String?) -> [Name: CMacro] {
    let key = dialect.clangName + "|" + sdk + "|" + (std ?? "")
    lock.lock()
    defer { lock.unlock() }
    if let known = predefinedCache[key] { return known }
    var table: [Name: CMacro] = [:]
    var text = ""
    #if os(macOS)
      var arguments = ["clang", "-x", dialect.clangName, "-dM", "-E"]
      if !sdk.isEmpty {
        arguments += ["-isysroot", sdk]
        for header in ["TargetConditionals.h", "sys/cdefs.h", "Availability.h", "AvailabilityMacros.h"] { arguments += ["-include", header] }
      }
      if dialect.contains(.objc) { arguments += ["-fobjc-arc", "-fmodules"] }
      if let std { arguments.append("-std=" + std) }
      arguments.append("/dev/null")
      text = ClangModuleMap.run("/usr/bin/xcrun", arguments)
    #elseif os(Linux)
      for compiler in ["/usr/bin/clang", "/usr/bin/cc", "/usr/bin/gcc"] where FileManager.default.isExecutableFile(atPath: compiler) {
        text = ClangModuleMap.run(compiler, ["-x", dialect.clangName, "-dM", "-E", "/dev/null"])
        if !text.isEmpty { break }
      }
    #endif
    if text.isEmpty { text = fallback(dialect) }
    for line in text.split(separator: "\n") {
      guard let (name, macro) = parseDefine(line.dropFirst(line.hasPrefix("#define ") ? 8 : 0)) else { continue }
      table[name] = macro
    }
    predefinedCache[key] = table
    return table
  }

  /// `NAME value` or `NAME(a, b) value`, after `#define`.
  static func parseDefine(_ text: Substring) -> (Name, CMacro)? {
    var rest = text.drop { $0 == " " || $0 == "\t" }
    let word = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
    guard !word.isEmpty else { return nil }
    rest = rest.dropFirst(word.count)
    let isFunction = rest.first == "("
    if isFunction, let close = rest.firstIndex(of: ")") { rest = rest[rest.index(after: close)...] }
    return (name(String(word)), CMacro(value: rest.trimmingCharacters(in: .whitespaces), isFunction: isFunction))
  }

  private static func fallback(_ dialect: CDialect) -> String {
    var lines = ["__STDC__ 1", "__STDC_VERSION__ 201710L", "__clang__ 1", "__GNUC__ 4", "__CHAR_BIT__ 8"]
    #if os(macOS) || os(iOS)
      lines += ["__APPLE__ 1", "__MACH__ 1", "__LP64__ 1", "TARGET_OS_MAC 1"]
      #if os(macOS)
        lines += ["TARGET_OS_OSX 1", "TARGET_OS_IPHONE 0", "TARGET_OS_IOS 0"]
      #else
        lines += ["TARGET_OS_OSX 0", "TARGET_OS_IPHONE 1", "TARGET_OS_IOS 1"]
      #endif
    #elseif os(Linux)
      lines += ["__linux__ 1", "__unix__ 1", "__LP64__ 1"]
    #elseif os(Windows)
      lines += ["_WIN32 1", "_WIN64 1"]
    #endif
    #if arch(arm64)
      lines += ["__aarch64__ 1", "__arm64__ 1"]
    #elseif arch(x86_64)
      lines += ["__x86_64__ 1"]
    #endif
    if dialect.contains(.cpp) { lines.append("__cplusplus 201703L") }
    if dialect.contains(.objc) { lines += ["__OBJC__ 1", "__OBJC2__ 1"] }
    return lines.map { "#define " + $0 }.joined(separator: "\n")
  }
}

/// One `#if` expression, evaluated: integers, `defined`, the `__has_…` checks, macros expanded. Nil when it can't be
/// told (an unknown function-like macro): such a branch is read.
struct CCondition {
  /// A macro's definition at this point, nil when it isn't one.
  let lookup: (Name) -> CMacro?
  /// Whether `<header>` or `"header"` would be found.
  let hasInclude: (String, Bool) -> Bool
  let dialect: CDialect

  private enum Piece: Equatable {
    case number(Int64)
    case word(String)
    case op(String)
    case header(String, angled: Bool)
  }

  /// Whether the branch is taken: what can't be told is.
  func evaluate(_ text: String) -> Bool {
    var pieces = lex(text)
    var expanding: Set<Name> = []
    pieces = expand(pieces, &expanding, depth: 0)
    var at = 0
    guard let value = ternary(pieces, &at), let known = value else { return true }
    return known != 0
  }

  private func lex(_ text: String) -> [Piece] {
    var pieces: [Piece] = []
    let bytes = Array(text.utf8)
    var i = 0
    while i < bytes.count {
      let c = bytes[i]
      if c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A || c == 0x5C { i += 1; continue }
      if c == 0x2F, i + 1 < bytes.count, bytes[i + 1] == 0x2F { break }
      if c == 0x2F, i + 1 < bytes.count, bytes[i + 1] == 0x2A {
        i += 2
        while i + 1 < bytes.count, !(bytes[i] == 0x2A && bytes[i + 1] == 0x2F) { i += 1 }
        i += 2
        continue
      }
      if isWordByte(c), !(c >= 0x30 && c <= 0x39) {
        var j = i + 1
        while j < bytes.count, isWordByte(bytes[j]) { j += 1 }
        let word = String(decoding: bytes[i..<j], as: UTF8.self)
        pieces.append(.word(word))
        i = j
        // `__has_include(<a/b.h>)`: the header's name is one piece.
        if word.hasPrefix("__has_include") {
          var k = i
          while k < bytes.count, bytes[k] == 0x20 { k += 1 }
          if k < bytes.count, bytes[k] == 0x28 {
            k += 1
            while k < bytes.count, bytes[k] == 0x20 { k += 1 }
            if k < bytes.count, bytes[k] == 0x3C || bytes[k] == 0x22 {
              let close: UInt8 = bytes[k] == 0x3C ? 0x3E : 0x22
              var e = k + 1
              while e < bytes.count, bytes[e] != close { e += 1 }
              pieces.append(.op("("))
              pieces.append(.header(String(decoding: bytes[(k + 1)..<min(e, bytes.count)], as: UTF8.self), angled: close == 0x3E))
              i = min(e + 1, bytes.count)
            }
          }
        }
        continue
      }
      if c >= 0x30, c <= 0x39 {
        var j = i
        while j < bytes.count, isWordByte(bytes[j]) || bytes[j] == 0x2E || bytes[j] == 0x27 { j += 1 }
        pieces.append(.number(Self.number(String(decoding: bytes[i..<j], as: UTF8.self))))
        i = j
        continue
      }
      if c == 0x27 {
        // A character: its first byte.
        var j = i + 1
        var value: Int64 = 0
        if j < bytes.count, bytes[j] == 0x5C, j + 1 < bytes.count {
          let e = bytes[j + 1]
          value = e == 0x6E ? 10 : e == 0x74 ? 9 : e == 0x30 ? 0 : Int64(e)
          j += 2
        } else if j < bytes.count {
          value = Int64(bytes[j])
          j += 1
        }
        while j < bytes.count, bytes[j] != 0x27 { j += 1 }
        pieces.append(.number(value))
        i = j + 1
        continue
      }
      if c == 0x22 {
        var j = i + 1
        while j < bytes.count, bytes[j] != 0x22 { j += bytes[j] == 0x5C ? 2 : 1 }
        pieces.append(.op("\"\""))
        i = j + 1
        continue
      }
      // Operators, longest first.
      let two = i + 1 < bytes.count ? String(decoding: bytes[i...(i + 1)], as: UTF8.self) : ""
      if ["&&", "||", "==", "!=", "<=", ">=", "<<", ">>"].contains(two) {
        pieces.append(.op(two))
        i += 2
      } else {
        pieces.append(.op(String(UnicodeScalar(c))))
        i += 1
      }
    }
    return pieces
  }

  private func isWordByte(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x24 }

  static func number(_ text: String) -> Int64 {
    var digits = text.lowercased().replacingOccurrences(of: "'", with: "")
    while let last = digits.last, last == "u" || last == "l" { digits.removeLast() }
    // Unsigned values past Int64.max (`0xFFFFFFFFFFFFFFFF`, `18446744073709551615UL`) keep their bits.
    func bits(_ text: Substring, _ radix: Int) -> Int64 { UInt64(text, radix: radix).map { Int64(bitPattern: $0) } ?? 0 }
    if digits.hasPrefix("0x") { return bits(digits.dropFirst(2), 16) }
    if digits.hasPrefix("0b") { return bits(digits.dropFirst(2), 2) }
    if digits.count > 1, digits.hasPrefix("0"), !digits.contains(".") { return bits(digits.dropFirst(), 8) }
    if let value = Int64(digits) { return value }
    if let value = UInt64(digits) { return Int64(bitPattern: value) }
    let double = Double(digits) ?? 0
    return double.isFinite && abs(double) < 9.2e18 ? Int64(double) : 0
  }

  /// Object-like macros replaced by their values, `defined` and the checks left for the parser.
  private func expand(_ pieces: [Piece], _ expanding: inout Set<Name>, depth: Int) -> [Piece] {
    var out: [Piece] = []
    var i = 0
    while i < pieces.count {
      let piece = pieces[i]
      guard case .word(let word) = piece else {
        out.append(piece)
        i += 1
        continue
      }
      if word == "defined" {
        // Kept as written: its operand isn't expanded.
        out.append(piece)
        if i + 1 < pieces.count, pieces[i + 1] == .op("(") {
          out.append(contentsOf: pieces[(i + 1)..<min(i + 4, pieces.count)])
          i += 4
        } else if i + 1 < pieces.count {
          out.append(pieces[i + 1])
          i += 2
        } else {
          i += 1
        }
        continue
      }
      let key = name(word)
      if depth < 16, !expanding.contains(key), let macro = lookup(key), !macro.isFunction, !Self.checks.contains(word) {
        expanding.insert(key)
        out.append(contentsOf: expand(lex(macro.value), &expanding, depth: depth + 1))
        expanding.remove(key)
      } else {
        out.append(piece)
      }
      i += 1
    }
    return out
  }

  /// `#ifndef __has_attribute`: the checks count as defined.
  static let checkNames = Set(checks.map { name($0) })

  private static let checks: Set<String> = [
    "__has_include", "__has_include_next", "__has_feature", "__has_extension", "__has_attribute", "__has_builtin", "__has_cpp_attribute",
    "__has_c_attribute", "__has_declspec_attribute", "__has_warning", "__building_module", "__is_target_os", "__is_target_arch",
    "__is_target_environment", "__is_target_vendor", "__has_embed",
  ]

  // MARK: Parsing, lowest precedence first

  private func ternary(_ p: [Piece], _ at: inout Int) -> Int64?? {
    guard let condition = binary(p, &at, 0) else { return nil }
    if at < p.count, p[at] == .op("?") {
      at += 1
      let yes = ternary(p, &at)
      if at < p.count, p[at] == .op(":") { at += 1 }
      let no = ternary(p, &at)
      guard let yes, let no else { return nil }
      guard let condition else { return yes == no ? yes : .some(nil) }
      return condition != 0 ? yes : no
    }
    return .some(condition)
  }

  private static let levels: [[String]] = [["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]]

  /// Nil: malformed. `.some(nil)`: unknown.
  private func binary(_ p: [Piece], _ at: inout Int, _ level: Int) -> Int64?? {
    if level == Self.levels.count { return unary(p, &at) }
    guard var left = binary(p, &at, level + 1) else { return nil }
    while at < p.count, case .op(let op) = p[at], Self.levels[level].contains(op) {
      at += 1
      guard let right = binary(p, &at, level + 1) else { return nil }
      switch (left, right) {
      case (.some(let a), .some(let b)): left = apply(op, a, b)
      case (.some(let a), nil) where op == "&&" && a == 0: left = 0
      case (.some(let a), nil) where op == "||" && a != 0: left = 1
      case (nil, .some(let b)) where op == "&&" && b == 0: left = 0
      case (nil, .some(let b)) where op == "||" && b != 0: left = 1
      default: left = nil
      }
    }
    return .some(left)
  }

  private func apply(_ op: String, _ a: Int64, _ b: Int64) -> Int64? {
    switch op {
    case "||": return a != 0 || b != 0 ? 1 : 0
    case "&&": return a != 0 && b != 0 ? 1 : 0
    case "|": return a | b
    case "^": return a ^ b
    case "&": return a & b
    case "==": return a == b ? 1 : 0
    case "!=": return a != b ? 1 : 0
    case "<": return a < b ? 1 : 0
    case ">": return a > b ? 1 : 0
    case "<=": return a <= b ? 1 : 0
    case ">=": return a >= b ? 1 : 0
    case "<<": return b >= 0 && b < 63 ? a << b : 0
    case ">>": return b >= 0 && b < 63 ? a >> b : 0
    case "+": return a &+ b
    case "-": return a &- b
    case "*": return a &* b
    case "/": return b == 0 ? nil : a / b
    case "%": return b == 0 ? nil : a % b
    default: return nil
    }
  }

  private func unary(_ p: [Piece], _ at: inout Int) -> Int64?? {
    guard at < p.count else { return nil }
    let piece = p[at]
    at += 1
    switch piece {
    case .number(let value): return .some(value)
    case .op("("):
      let inner = ternary(p, &at)
      if at < p.count, p[at] == .op(")") { at += 1 }
      return inner
    case .op("!"):
      guard let value = unary(p, &at) else { return nil }
      return .some(value.map { $0 == 0 ? 1 : 0 })
    case .op("-"):
      guard let value = unary(p, &at) else { return nil }
      return .some(value.map { 0 &- $0 })
    case .op("+"): return unary(p, &at)
    case .op("~"):
      guard let value = unary(p, &at) else { return nil }
      return .some(value.map { ~$0 })
    case .word("defined"):
      var parenthesized = false
      if at < p.count, p[at] == .op("(") {
        parenthesized = true
        at += 1
      }
      guard at < p.count, case .word(let word) = p[at] else { return nil }
      at += 1
      if parenthesized, at < p.count, p[at] == .op(")") { at += 1 }
      return .some(lookup(name(word)) != nil || Self.checks.contains(word) ? 1 : 0)
    case .word(let word):
      // A check or a function-like macro: its parenthesized argument.
      var argument = ""
      var header: (String, Bool)?
      var called = false
      if at < p.count, p[at] == .op("(") {
        called = true
        at += 1
        var depth = 1
        while at < p.count {
          if p[at] == .op("(") { depth += 1 }
          if p[at] == .op(")") {
            depth -= 1
            if depth == 0 { break }
          }
          switch p[at] {
          case .word(let text): argument += text
          case .header(let text, let angled): header = (text, angled)
          case .number(let value): argument += String(value)
          case .op(let text): argument += text
          }
          at += 1
        }
        at += 1
      }
      if let value = check(word, argument: argument, header: header) { return .some(value) }
      if called, lookup(name(word)) != nil || !Self.checks.contains(word) { return .some(nil) }
      // An identifier no macro names is 0.
      return .some(0)
    default:
      return nil
    }
  }

  /// The compiler's checks, as clang on this platform answers them.
  private func check(_ word: String, argument: String, header: (String, Bool)?) -> Int64? {
    switch word {
    case "__has_include", "__has_include_next":
      guard let header else { return 0 }
      return hasInclude(header.0, header.1) ? 1 : 0
    case "__has_feature", "__has_extension":
      if argument.hasPrefix("cxx_") { return dialect.contains(.cpp) ? 1 : 0 }
      if argument.hasPrefix("objc_") || argument == "modules" || argument == "blocks" {
        return dialect.contains(.objc) || argument == "blocks" ? 1 : 0
      }
      if argument.hasSuffix("_sanitizer") || argument.hasPrefix("ptrauth") || argument.hasPrefix("bounds_") || argument == "safe_stack"
        || argument == "coverage_sanitizer" || argument == "realtime_sanitizer" || argument == "typed_memory_operations"
      {
        return 0
      }
      return 1
    case "__has_attribute", "__has_builtin", "__has_warning": return 1
    case "__has_cpp_attribute": return dialect.contains(.cpp) ? 1 : 0
    case "__has_c_attribute": return dialect.contains(.cpp) ? 0 : 1
    case "__has_declspec_attribute", "__building_module", "__is_target_environment", "__has_embed": return 0
    case "__is_target_os":
      #if os(macOS)
        return argument == "macos" || argument == "macosx" || argument == "darwin" ? 1 : 0
      #elseif os(Linux)
        return argument == "linux" ? 1 : 0
      #else
        return 0
      #endif
    case "__is_target_arch":
      #if arch(arm64)
        return argument == "arm64" || argument == "aarch64" ? 1 : 0
      #else
        return argument == "x86_64" ? 1 : 0
      #endif
    case "__is_target_vendor": return argument == "apple" ? 1 : 0
    default: return nil
    }
  }
}
