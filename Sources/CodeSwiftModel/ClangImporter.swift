import Foundation

/// Clang modules, read the way Swift would see them: a module's headers and API notes become generated Swift
/// declarations, one per line, each remembering its header's line. Every other layer then treats them as an interface.
struct GeneratedModule {
  var text: String
  /// For each generated line, 1-based: which header and which line of it.
  var lines: [(header: Int32, line: Int32)]
  var headers: [String]
  var exports: [String]
}

// MARK: API notes

struct APINotes {
  struct Holder {
    var swiftName: String?
    var bridge: String?
    var methods: [String: String] = [:]
    var properties: [String: String] = [:]
  }
  var holders: [String: Holder] = [:]
  var globals: [String: String] = [:]
  var bridges: [String: String] = [:]

  /// Reads the YAML subset API notes use: sections by key, `- Name:` or `- Selector:` items, one level of nesting.
  mutating func read(_ text: String) {
    var section = ""
    var holder: String?
    var inner = ""
    var key: String?
    var itemIndent = -1
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let indent = raw.prefix { $0 == " " }.count
      var line = raw.dropFirst(indent)
      let startsItem = line.hasPrefix("- ")
      if startsItem { line = line.dropFirst(2) }
      guard let colon = line.firstIndex(of: ":") else { continue }
      let field = String(line[..<colon])
      var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("'") || value.hasPrefix("\"") { value = String(value.dropFirst().dropLast()) }
      if indent == 0, !startsItem, value.isEmpty {
        section = field
        holder = nil
        continue
      }
      // Names as they were for older Swift versions.
      if section == "SwiftVersions" { continue }
      if !startsItem, indent == itemIndent + 2, !value.isEmpty {
        inner = ""
        key = nil
      }
      if startsItem, indent == 0 || (holder == nil) {
        if field == "Name" {
          holder = value
          itemIndent = indent
          inner = ""
          key = nil
          if section == "Functions" || section == "Globals" || section == "Enumerators" || section == "Typedefs" || section == "Tags" {
            if holders[value] == nil { holders[value] = Holder() }
          }
        }
        continue
      }
      if !startsItem, indent == itemIndent + 2, value.isEmpty {
        inner = field
        key = nil
        continue
      }
      if startsItem, !inner.isEmpty {
        key = field == "Selector" || field == "Name" ? value : nil
        continue
      }
      guard let holder else { continue }
      if field == "SwiftName" {
        if inner == "Methods", let key {
          holders[holder, default: Holder()].methods[key] = value
        } else if inner == "Properties", let key {
          holders[holder, default: Holder()].properties[key] = value
        } else if inner.isEmpty {
          holders[holder, default: Holder()].swiftName = value
          if section == "Functions" || section == "Globals" || section == "Enumerators" { globals[holder] = value }
        }
      } else if field == "SwiftBridge", inner.isEmpty, !value.isEmpty {
        let name = value.split(separator: ".").last.map(String.init) ?? value
        bridges[holder] = name
      }
    }
  }
}

// MARK: Tokens

private enum CKind: UInt8 { case word, punct, string, number }

private struct CToken {
  var kind: CKind
  var start: Int32
  var length: Int32
  var line: Int32
}

private let swiftKeywords: Set<String> = [
  "default", "in", "for", "if", "else", "self", "Self", "class", "struct", "enum", "protocol", "func", "var", "let", "import", "init", "is", "as",
  "case", "switch", "where", "while", "do", "try", "catch", "throw", "throws", "return", "break", "continue", "repeat", "guard", "defer", "true", "false", "nil",
  "extension", "operator", "internal", "public", "private", "fileprivate", "static", "subscript", "typealias", "deinit", "super", "inout", "Any", "Type", "rethrows",
]

private func escaped(_ name: String) -> String { swiftKeywords.contains(name) ? "`" + name + "`" : name }

/// `removeItemAtURL` into its words: `remove`, `Item`, `At`, `URL`.
private func camelWords(_ text: String) -> [String] {
  var words: [String] = []
  var current = ""
  let chars = Array(text)
  for (index, c) in chars.enumerated() {
    if c.isUppercase, !current.isEmpty {
      let previousUpper = chars[index - 1].isUppercase
      let nextLower = index + 1 < chars.count && chars[index + 1].isLowercase
      if !previousUpper || nextLower {
        words.append(current)
        current = ""
      }
    }
    current.append(c)
  }
  if !current.isEmpty { words.append(current) }
  return words
}

private func lowerFirstWord(_ words: [String]) -> String {
  guard let first = words.first else { return "" }
  let lowered: String
  if first.count > 1, first.allSatisfy({ $0.isUppercase || $0.isNumber }) {
    lowered = first.lowercased()
  } else {
    lowered = first.prefix(1).lowercased() + first.dropFirst()
  }
  return lowered + words.dropFirst().joined()
}

private let prepositions: Set<String> = [
  "At", "By", "For", "From", "In", "Into", "Of", "On", "Onto", "To", "With", "Within", "Without", "Using", "During", "After", "Before", "Under", "Over", "Through",
  "As", "Like", "Upon", "Via", "Across", "Between", "Inside", "Outside", "Near", "Since", "Until", "Per", "Including", "Excluding", "Matching", "Containing",
]

private let falseOnMac: Set<String> = [
  "TARGET_OS_IPHONE", "TARGET_OS_IOS", "TARGET_OS_WATCH", "TARGET_OS_TV", "TARGET_OS_VISION", "TARGET_OS_MACCATALYST", "TARGET_OS_WIN32", "TARGET_OS_SIMULATOR", "__cplusplus",
]

private let sugarWords: Set<String> = [
  "const", "nullable", "nonnull", "__nullable", "__nonnull", "_Nullable", "_Nonnull", "_iio_Nullable", "_iio_Nonnull", "_Null_unspecified", "null_unspecified", "null_resettable", "__kindof", "struct", "enum", "union",
  "__unsafe_unretained", "__strong", "__weak", "__autoreleasing", "__covariant", "__contravariant", "volatile", "restrict", "__restrict", "_Noescape", "NS_NOESCAPE", "CF_NOESCAPE",
  "oneway", "in", "out", "inout", "bycopy", "byref", "signed", "register", "__block",
]

private func isSugarWord(_ word: String) -> Bool { sugarWords.contains(word) }

/// One header read into declaration lines.
private final class HeaderReader {
  let bytes: [UInt8]
  var tokens: [CToken] = []
  var includes: [String] = []
  let importer: ClangImporter
  var nonnull = false
  var out: [(text: String, line: Int32)] = []
  var deferred: [(type: String, name: String, line: Int32)] = []
  private var postponed: [(text: String, line: Int32)] = []
  /// Told to the importer once every reader is done: while they run, what they all read doesn't change.
  var foundClasses: [(String, String)] = []
  var foundProtocols: [(String, String)] = []
  var foundTyped: [String] = []
  /// Categories written with the C name, whose class another header may have renamed.
  var categories: [(line: Int, name: String)] = []

  init(bytes: [UInt8], importer: ClangImporter) {
    self.bytes = bytes
    self.importer = importer
    tokenize()
  }

  // MARK: Reading tokens

  private func tokenize() {
    tokens.reserveCapacity(bytes.count / 12)
    var i = 0
    var line: Int32 = 1
    let count = bytes.count
    var atLineStart = true
    var skipDepth = 0
    var nest: [Bool] = []
    bytes.withUnsafeBufferPointer { b in
      while i < count {
        let c = b[i]
        if c == 0x0A {
          line += 1
          i += 1
          atLineStart = true
          continue
        }
        if c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0C {
          i += 1
          continue
        }
        if c == 0x2F, i + 1 < count, b[i + 1] == 0x2F {
          while i < count, b[i] != 0x0A { i += 1 }
          continue
        }
        if c == 0x2F, i + 1 < count, b[i + 1] == 0x2A {
          i += 2
          while i + 1 < count, !(b[i] == 0x2A && b[i + 1] == 0x2F) {
            if b[i] == 0x0A { line += 1 }
            i += 1
          }
          i += 2
          continue
        }
        if c == 0x23, atLineStart {
          // A directive and its continuation lines.
          let start = i
          var end = i
          while end < count, b[end] != 0x0A {
            if b[end] == 0x5C, end + 1 < count, b[end + 1] == 0x0A {
              line += 1
              end += 2
              continue
            }
            if b[end] == 0x2F, end + 1 < count, b[end + 1] == 0x2A {
              end += 2
              while end + 1 < count, !(b[end] == 0x2A && b[end + 1] == 0x2F) {
                if b[end] == 0x0A { line += 1 }
                end += 1
              }
              end += 1
            }
            end += 1
          }
          let text = String(decoding: b[start..<min(end, count)], as: UTF8.self)
          directive(text, &skipDepth, &nest)
          i = end
          continue
        }
        atLineStart = false
        if skipDepth > 0 {
          // In a branch not taken: only strings and comments could fool the line walk, and lines are all it needs.
          while i < count, b[i] != 0x0A {
            if b[i] == 0x2F, i + 1 < count, b[i + 1] == 0x2A { break }
            i += 1
          }
          if i < count, b[i] != 0x0A { continue }
          continue
        }
        let isWordStart = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c >= 0x80
        if isWordStart {
          let start = i
          i += 1
          while i < count {
            let d = b[i]
            if (d >= 0x41 && d <= 0x5A) || (d >= 0x61 && d <= 0x7A) || d == 0x5F || (d >= 0x30 && d <= 0x39) || d >= 0x80 { i += 1 } else { break }
          }
          tokens.append(CToken(kind: .word, start: Int32(start), length: Int32(i - start), line: line))
          continue
        }
        if c >= 0x30, c <= 0x39 {
          let start = i
          i += 1
          while i < count {
            let d = b[i]
            if (d >= 0x41 && d <= 0x5A) || (d >= 0x61 && d <= 0x7A) || (d >= 0x30 && d <= 0x39) || d == 0x2E { i += 1 } else { break }
          }
          tokens.append(CToken(kind: .number, start: Int32(start), length: Int32(i - start), line: line))
          continue
        }
        if c == 0x22 || c == 0x27 {
          let start = i
          i += 1
          while i < count, b[i] != c, b[i] != 0x0A {
            if b[i] == 0x5C { i += 1 }
            i += 1
          }
          i += 1
          tokens.append(CToken(kind: .string, start: Int32(start), length: Int32(min(i, count) - start), line: line))
          continue
        }
        tokens.append(CToken(kind: .punct, start: Int32(i), length: 1, line: line))
        i += 1
      }
    }
  }

  private func directive(_ text: String, _ skipDepth: inout Int, _ nest: inout [Bool]) {
    let trimmed = text.dropFirst().drop { $0 == " " || $0 == "\t" }
    if trimmed.hasPrefix("import") || trimmed.hasPrefix("include") {
      if skipDepth == 0, let open = trimmed.firstIndex(of: "<"), let close = trimmed.firstIndex(of: ">"), open < close {
        includes.append(String(trimmed[trimmed.index(after: open)..<close]))
      }
    } else if trimmed.hasPrefix("ifdef") || trimmed.hasPrefix("ifndef") {
      let isNegated = trimmed.hasPrefix("ifndef")
      let macro = trimmed.dropFirst(isNegated ? 6 : 5).drop { $0 == " " || $0 == "\t" }.prefix { !$0.isWhitespace }
      if falseOnMac.contains(String(macro)) {
        nest.append(isNegated)
        if skipDepth > 0 || !isNegated { skipDepth += 1 }
      } else {
        // Anything else, such as an include guard: both sides are read.
        nest.append(false)
        if skipDepth > 0 { skipDepth += 1 }
      }
    } else if trimmed.hasPrefix("if") {
      let taken = condition(String(trimmed.dropFirst(2)))
      nest.append(taken)
      if skipDepth > 0 || !taken { skipDepth += 1 }
    } else if trimmed.hasPrefix("elif") {
      if let last = nest.last {
        if skipDepth <= 1 {
          if last {
            skipDepth = 1
          } else if condition(String(trimmed.dropFirst(4))) {
            skipDepth = 0
            nest[nest.count - 1] = true
          } else {
            skipDepth = 1
          }
        }
      }
    } else if trimmed.hasPrefix("else") {
      if let last = nest.last, skipDepth <= 1 {
        skipDepth = last ? 1 : 0
        nest[nest.count - 1] = true
      }
    } else if trimmed.hasPrefix("endif") {
      if !nest.isEmpty { nest.removeLast() }
      if skipDepth > 0 { skipDepth -= 1 }
    }
  }

  /// Conditions as they hold on a Mac: only what would drop a duplicate or wrong branch is told apart.
  private func condition(_ text: String) -> Bool {
    let compact = text.filter { !$0.isWhitespace }
    if compact == "0" { return false }
    for word in falseOnMac where compact == word || compact == "defined(" + word + ")" { return false }
    for word in falseOnMac where compact == "!" + word || compact == "!defined(" + word + ")" { return true }
    // C++ is never read: `__cplusplus >= 201103L`, `defined(__cplusplus) && X`.
    if compact.contains("__cplusplus"), !compact.contains("||"), !compact.contains("!defined(__cplusplus)"), !compact.contains("!__cplusplus") { return false }
    return true
  }

  // MARK: Helpers

  @inline(__always) private func word(_ i: Int) -> String {
    let t = tokens[i]
    return String(decoding: bytes[Int(t.start)..<Int(t.start + t.length)], as: UTF8.self)
  }

  @inline(__always) private func isByte(_ i: Int, _ byte: UInt8) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    let t = tokens[i]
    return t.length == 1 && bytes[Int(t.start)] == byte
  }

  private func isWord(_ i: Int) -> Bool { i >= 0 && i < tokens.count && tokens[i].kind == .word }

  private func isText(_ i: Int, _ text: StaticString) -> Bool {
    guard i >= 0, i < tokens.count else { return false }
    let t = tokens[i]
    guard Int(t.length) == text.utf8CodeUnitCount else { return false }
    return bytes.withUnsafeBufferPointer { memcmp($0.baseAddress! + Int(t.start), text.utf8Start, Int(t.length)) == 0 }
  }

  private func skipGroup(_ open: Int) -> Int {
    var depth = 0
    var i = open
    while i < tokens.count {
      if tokens[i].kind == .punct {
        let c = bytes[Int(tokens[i].start)]
        if c == 0x28 || c == 0x7B || c == 0x5B { depth += 1 }
        if c == 0x29 || c == 0x7D || c == 0x5D {
          depth -= 1
          if depth <= 0 { return i + 1 }
        }
      }
      i += 1
    }
    return i
  }

  /// A macro: `API_AVAILABLE(...)`, `NS_SWIFT_NAME(...)`, `FOUNDATION_EXPORT`; all capitals with an underscore, or `__x`.
  private func isMacroWord(_ i: Int) -> Bool {
    guard isWord(i) else { return false }
    let t = tokens[i]
    let start = Int(t.start)
    let length = Int(t.length)
    if length > 2, bytes[start] == 0x5F, bytes[start + 1] == 0x5F { return !isSugarWord(word(i)) }
    var hasUnderscore = false
    for k in 0..<length {
      let c = bytes[start + k]
      if c == 0x5F { hasUnderscore = true } else if c >= 0x61, c <= 0x7A { return false }
    }
    if hasUnderscore { return true }
    guard length > 5 else { return false }
    let text = word(i)
    return text.contains("DEPRECATED") || text.contains("UNAVAILABLE") || text.contains("EXTERN") || text.contains("INLINE") || text.contains("EXPORT")
  }

  private struct Trailing {
    var swiftName: String?
    var unavailable = false
    var typedEnum = false
    var refined = false
  }

  /// Steps over macros and reads the ones that matter.
  private func trailing(_ i: inout Int) -> Trailing {
    var result = Trailing()
    while i < tokens.count, isMacroWord(i) {
      let name = word(i)
      i += 1
      if name.hasSuffix("SWIFT_NAME") || name == "__swift_name" {
        if isByte(i, 0x28) {
          let close = skipGroup(i)
          var text = ""
          for k in (i + 1)..<max(i + 1, close - 1) { text += word(k) }
          result.swiftName = text
          i = close
          continue
        }
      }
      // `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` only rules out async callers.
      if (name.contains("SWIFT_UNAVAILABLE") && !name.hasSuffix("FROM_ASYNC")) || name == "NS_UNAVAILABLE" || name == "UNAVAILABLE_ATTRIBUTE" { result.unavailable = true }
      if name.hasSuffix("TYPED_ENUM") || name.hasSuffix("TYPED_EXTENSIBLE_ENUM") || name.hasSuffix("STRING_ENUM") || name.hasSuffix("EXTENSIBLE_STRING_ENUM") { result.typedEnum = true }
      if name == "NS_REFINED_FOR_SWIFT" || name == "CF_REFINED_FOR_SWIFT" { result.refined = true }
      if isByte(i, 0x28) { i = skipGroup(i) }
    }
    return result
  }

  // MARK: Types

  /// A C or Objective-C type, in Swift terms.
  private func swiftType(_ start: Int, _ end: Int, defaultNonnull: Bool? = nil) -> String {
    var i = start
    var stars = 0
    var nullable = false
    var explicitlyNonnull = false
    var base: String?
    var generics: [String] = []
    var protocols: [String] = []
    var unsignedSeen = false
    var longs = 0
    while i < end {
      let t = tokens[i]
      if t.kind == .word {
        let w = word(i)
        if w == "nullable" || w == "_Nullable" || w.hasSuffix("_Nullable") || w == "__nullable" || w == "_Null_unspecified" || w == "null_resettable" || w == "null_unspecified" {
          nullable = true
          i += 1
          continue
        }
        if w == "nonnull" || w == "_Nonnull" || w.hasSuffix("_Nonnull") || w == "__nonnull" {
          explicitlyNonnull = true
          i += 1
          continue
        }
        if isSugarWord(w) {
          i += 1
          continue
        }
        if isMacroWord(i) {
          i += 1
          if isByte(i, 0x28) { i = skipGroup(i) }
          continue
        }
        if w == "unsigned" {
          unsignedSeen = true
          i += 1
          continue
        }
        if w == "long" {
          longs += 1
          i += 1
          continue
        }
        if base == nil {
          base = w
        }
        i += 1
        if isByte(i, 0x3C) {
          // `<A, B *>` or `<P, Q>`.
          var depth = 0
          var j = i
          var from = i + 1
          var parts: [(Int, Int)] = []
          while j < end {
            if isByte(j, 0x3C) { depth += 1 }
            if isByte(j, 0x3E) {
              depth -= 1
              if depth == 0 {
                if from < j { parts.append((from, j)) }
                break
              }
            }
            if depth == 1, isByte(j, 0x2C) {
              parts.append((from, j))
              from = j + 1
            }
            if isByte(j, 0x28) {
              j = skipGroup(j)
              continue
            }
            j += 1
          }
          if base == "id" || base == "Class" {
            protocols = parts.map { $0.0 < $0.1 ? word($0.0) : "" }
          } else {
            generics = parts.map { swiftType($0.0, $0.1, defaultNonnull: true) }
          }
          i = j + 1
        }
        continue
      }
      if isByte(i, 0x2A) { stars += 1 }
      if isByte(i, 0x28) {
        i = skipGroup(i)
        continue
      }
      i += 1
    }
    // `unsigned` alone is an int; `long` and `long long` are 64 bits, which Swift spells Int and Int64.
    let longName = longs >= 2 ? (unsignedSeen ? "UInt64" : "Int64") : (unsignedSeen ? "UInt" : "Int")
    var name = base ?? (longs > 0 ? longName : unsignedSeen ? "UInt32" : "Any")
    if base == "double" { name = "Double" }
    if base == "int" { name = longs > 0 ? longName : unsignedSeen ? "UInt32" : "Int32" }
    if base == "short" { name = unsignedSeen ? "UInt16" : "Int16" }
    if base == "char", unsignedSeen { name = "UInt8" }
    let assumeNonnull = defaultNonnull ?? nonnull
    func wrap(_ text: String) -> String { !explicitlyNonnull && (nullable || !assumeNonnull) ? text + "?" : text }
    switch name {
    case "void":
      if stars == 0 { return "Void" }
      return wrap("UnsafeMutableRawPointer")
    case "id":
      if protocols.isEmpty { return wrap("Any") }
      return wrap("any " + protocols.map(importer.typeName).joined(separator: " & "))
    case "instancetype":
      return wrap("Self")
    case "Class":
      return wrap("AnyClass")
    case "SEL":
      return "Selector"
    case "BOOL", "bool", "_Bool":
      return stars > 0 ? "UnsafeMutablePointer<ObjCBool>?" : "Bool"
    case "NSInteger", "NSUInteger", "size_t", "ssize_t", "CFIndex":
      return stars > 0 ? "UnsafeMutablePointer<Int>?" : "Int"
    case "float":
      return "Float"
    case "char":
      return stars > 0 ? wrap("UnsafePointer<CChar>") : "CChar"
    case "NSString", "CFStringRef" where name == "NSString":
      if stars >= 2 { return "AutoreleasingUnsafeMutablePointer<String?>?" }
      return wrap("String")
    case "NSError":
      if stars >= 2 { return "NSErrorPointer" }
      return wrap("Error")
    case "NSArray":
      return wrap("[" + (generics.first ?? "Any") + "]")
    case "NSMutableArray":
      return wrap("NSMutableArray")
    case "NSSet":
      return wrap("Set<" + (generics.first ?? "AnyHashable") + ">")
    case "NSDictionary":
      if generics.count == 2 { return wrap("[" + generics[0] + ": " + generics[1] + "]") }
      return wrap("[AnyHashable: Any]")
    default:
      break
    }
    if let bridged = importer.bridge(name), stars <= 1 { return wrap(bridged) }
    var result = importer.typeName(name)
    if !generics.isEmpty { result += "<" + generics.joined(separator: ", ") + ">" }
    if stars == 0 { return result }
    if stars == 1, importer.isObjectType(name) || name.first?.isUppercase == true { return wrap(result) }
    return wrap("UnsafeMutablePointer<" + result + ">")
  }

  /// A block or function pointer in a parameter or property: `void (^name)(BOOL stop)`.
  private func blockType(_ start: Int, _ end: Int) -> (type: String, name: String?)? {
    var i = start
    var caret = -1
    while i < end {
      if isByte(i, 0x28), isByte(i + 1, 0x5E) || isByte(i + 1, 0x2A) {
        caret = i
        break
      }
      if isByte(i, 0x28), isMacroWord(i - 1) {
        i = skipGroup(i)
        continue
      }
      i += 1
    }
    guard caret >= 0 else { return nil }
    let inner = skipGroup(caret)
    var name: String?
    var nullable = false
    for k in (caret + 2)..<max(caret + 2, inner - 1) where isWord(k) {
      let w = word(k)
      if w == "_Nullable" || w.hasSuffix("_Nullable") || w == "nullable" || w == "__nullable" { nullable = true } else if !isSugarWord(w), !isMacroWord(k) { name = w }
    }
    var result = swiftType(start, caret, defaultNonnull: true)
    if result.hasSuffix("?") { result.removeLast() }
    var params: [String] = []
    if isByte(inner, 0x28) {
      let close = skipGroup(inner) - 1
      var from = inner + 1
      var j = from
      while j <= close {
        if j == close || isByte(j, 0x2C) {
          if from < j, !(j == from + 1 && isText(from, "void")) {
            params.append(cParameterType(from, j))
          }
          from = j + 1
        } else if isByte(j, 0x28) {
          j = skipGroup(j)
          continue
        }
        j += 1
      }
    }
    let text = "(" + params.joined(separator: ", ") + ") -> " + result
    return (nullable ? "(" + text + ")?" : text, name)
  }

  /// A C parameter's type, its name left out: the last plain word if there's another before it.
  private func cParameterType(_ start: Int, _ end: Int) -> String {
    if let block = blockType(start, end) { return block.type }
    var last = end - 1
    while last > start, !isWord(last) { last -= 1 }
    var words = 0
    for k in start..<end where isWord(k) && !isSugarWord(word(k)) && !isMacroWord(k) { words += 1 }
    if words >= 2, isWord(last), !isSugarWord(word(last)), !["int", "long", "char", "double", "float", "short"].contains(word(last)) {
      return swiftType(start, last)
    }
    return swiftType(start, end)
  }

  // MARK: Output

  private func emit(_ text: String, _ line: Int32) { out.append((text, line)) }

  // MARK: The file

  func read() {
    var i = 0
    while i < tokens.count {
      if isByte(i, 0x40) {
        i += 1
        if isText(i, "interface") {
          interface(&i)
        } else if isText(i, "protocol") {
          protocolDecl(&i)
        } else if isText(i, "class") {
          skipToSemicolon(&i)
        } else if isText(i, "implementation") {
          while i < tokens.count, !(isByte(i, 0x40) && isText(i + 1, "end")) { i += 1 }
          i += 2
        } else {
          i += 1
        }
        continue
      }
      guard isWord(i) else {
        i += 1
        continue
      }
      if isText(i, "NS_ASSUME_NONNULL_BEGIN") || isText(i, "CF_ASSUME_NONNULL_BEGIN") || isText(i, "NS_HEADER_AUDIT_BEGIN") || isText(i, "CF_IMPLICIT_BRIDGING_ENABLED") {
        nonnull = true
        i += 1
        if isByte(i, 0x28) { i = skipGroup(i) }
      } else if isText(i, "NS_ASSUME_NONNULL_END") || isText(i, "CF_ASSUME_NONNULL_END") || isText(i, "NS_HEADER_AUDIT_END") {
        nonnull = false
        i += 1
        if isByte(i, 0x28) { i = skipGroup(i) }
      } else if isText(i, "__BEGIN_DECLS") || isText(i, "__END_DECLS") || isText(i, "CF_EXTERN_C_BEGIN") || isText(i, "CF_EXTERN_C_END") || isText(i, "CF_IMPLICIT_BRIDGING_DISABLED") {
        i += 1
        if isByte(i, 0x28) { i = skipGroup(i) }
      } else if isText(i, "typedef") {
        typedefDecl(&i)
      } else if isText(i, "namespace") || isText(i, "template") || isText(i, "using") {
        // C++ that no condition kept out.
        skipToSemicolon(&i)
      } else if isText(i, "extern"), tokens[safe: i + 1]?.kind == .string {
        i += 2
        if isByte(i, 0x7B) { i += 1 }
      } else if isText(i, "struct") || isText(i, "union") || isText(i, "enum") {
        tagged(&i)
      } else {
        cDeclaration(&i)
      }
    }
  }

  private func skipToSemicolon(_ i: inout Int) {
    while i < tokens.count, !isByte(i, 0x3B) {
      if isByte(i, 0x28) || isByte(i, 0x7B) {
        i = skipGroup(i)
        continue
      }
      i += 1
    }
    i += 1
  }

  /// A name list in angle brackets, at `<`.
  private func nameList(_ i: inout Int) -> [String] {
    guard isByte(i, 0x3C) else { return [] }
    var names: [String] = []
    var depth = 0
    while i < tokens.count {
      if isByte(i, 0x3C) { depth += 1 }
      if isByte(i, 0x3E) {
        depth -= 1
        if depth == 0 {
          i += 1
          break
        }
      }
      if depth == 1, isWord(i), !isSugarWord(word(i)), !isMacroWord(i) {
        // A generic's bound after `:` isn't a name of its own.
        if !isByte(i - 1, 0x3A), !isByte(i - 1, 0x2A) { names.append(word(i)) }
      }
      i += 1
    }
    return names
  }

  private func interface(_ i: inout Int) {
    i += 1
    guard isWord(i) else { return }
    while isMacroWord(i) {
      _ = trailing(&i)
    }
    let line = tokens[i].line
    let objcName = word(i)
    i += 1
    let generics = nameList(&i)
    let holder = importer.notes[objcName]
    if isByte(i, 0x28) {
      // A category: members for a class that's already somewhere.
      i = skipGroup(i)
      if isByte(i, 0x3C) { _ = nameList(&i) }
      let swiftName = importer.classNames[objcName] ?? holder?.swiftName ?? objcName
      if swiftName == objcName { categories.append((out.count, objcName)) }
      emit("extension \(swiftName) {", line)
      body(&i, objcName: objcName, holder: holder, inProtocol: false)
      emit("}", line)
      flushPostponed()
      return
    }
    var parents: [String] = []
    if isByte(i, 0x3A) {
      i += 1
      if isWord(i) {
        parents.append(importer.typeName(word(i)))
        i += 1
        // `Parent<T>` is rare and `Parent <P>` common; only a second list makes the first generic.
        if isByte(i, 0x3C) {
          let first = nameList(&i)
          if !isByte(i, 0x3C) { parents.append(contentsOf: first.map(importer.protocolName)) }
        }
      }
    }
    if isByte(i, 0x3C) { parents.append(contentsOf: nameList(&i).map(importer.protocolName)) }
    if isByte(i, 0x7B) { i = skipGroup(i) }
    let macro = trailing(&i)
    let swiftName = holder?.swiftName ?? macro.swiftName ?? objcName
    foundClasses.append((objcName, swiftName))
    let generic = generics.isEmpty ? "" : "<" + generics.joined(separator: ", ") + ">"
    let inherits = parents.isEmpty ? "" : ": " + parents.joined(separator: ", ")
    let (open, close) = nesting(swiftName, line)
    emit("\(open)public class \(lastPart(swiftName))\(generic)\(inherits) {", line)
    body(&i, objcName: objcName, holder: holder, inProtocol: false)
    emit("}\(close)", line)
    flushPostponed()
    if swiftName != objcName { emit("public typealias \(objcName) = \(swiftName)", line) }
  }

  private func lastPart(_ name: String) -> String { name.split(separator: ".").last.map(String.init) ?? name }

  /// A dotted Swift name nests in its parent: `FileManager.ItemReplacementOptions`.
  private func nesting(_ name: String, _ line: Int32) -> (String, String) {
    let parts = name.split(separator: ".")
    guard parts.count > 1 else { return ("", "") }
    return ("extension " + parts.dropLast().joined(separator: ".") + " { ", " }")
  }

  private func protocolDecl(_ i: inout Int) {
    i += 1
    guard isWord(i) else { return }
    while isMacroWord(i) { _ = trailing(&i) }
    let line = tokens[i].line
    let objcName = word(i)
    i += 1
    if isByte(i, 0x3B) || isByte(i, 0x2C) {
      skipToSemicolon(&i)
      return
    }
    var parents: [String] = []
    if isByte(i, 0x3C) { parents = nameList(&i).map(importer.protocolName) }
    let macro = trailing(&i)
    let holder = importer.notes[objcName]
    let swiftName = importer.protocolName(holder?.swiftName ?? macro.swiftName ?? objcName)
    foundProtocols.append((objcName, swiftName))
    let inherits = parents.isEmpty ? "" : ": " + parents.joined(separator: ", ")
    let (open, close) = nesting(swiftName, line)
    emit("\(open)public protocol \(lastPart(swiftName))\(inherits) {", line)
    body(&i, objcName: objcName, holder: holder, inProtocol: true)
    emit("}\(close)", line)
    flushPostponed()
    if swiftName != objcName, importer.classNames[objcName] == nil { emit("public typealias \(objcName) = \(swiftName)", line) }
  }

  private func body(_ i: inout Int, objcName: String, holder: APINotes.Holder?, inProtocol: Bool) {
    let access = inProtocol ? "" : "public "
    while i < tokens.count {
      if isByte(i, 0x40) {
        if isText(i + 1, "end") {
          i += 2
          return
        }
        if isText(i + 1, "property") {
          i += 2
          property(&i, objcName: objcName, holder: holder, access: access)
          continue
        }
        i += 2
        continue
      }
      if isByte(i, 0x2D) || isByte(i, 0x2B) {
        method(&i, objcName: objcName, holder: holder, access: access)
        continue
      }
      if isText(i, "NS_ASSUME_NONNULL_BEGIN") { nonnull = true }
      if isText(i, "NS_ASSUME_NONNULL_END") { nonnull = false }
      // C between members belongs to the file, and goes out after the type: NSURL.h keeps its resource keys in there.
      if isWord(i), !isText(i, "NS_ASSUME_NONNULL_BEGIN"), !isText(i, "NS_ASSUME_NONNULL_END") {
        let count = out.count
        if isText(i, "typedef") { typedefDecl(&i) } else { cDeclaration(&i) }
        postponed.append(contentsOf: out[count...])
        out.removeSubrange(count...)
        continue
      }
      i += 1
    }
  }

  private func flushPostponed() {
    out.append(contentsOf: postponed)
    postponed.removeAll()
  }

  private func property(_ i: inout Int, objcName: String, holder: APINotes.Holder?, access: String) {
    let line = tokens[min(i, tokens.count - 1)].line
    var isClass = false
    var nullableAttribute = false
    var getter: String?
    if isByte(i, 0x28) {
      let close = skipGroup(i)
      var k = i + 1
      while k < close - 1 {
        if isText(k, "class") { isClass = true }
        if isText(k, "nullable") || isText(k, "null_resettable") { nullableAttribute = true }
        if isText(k, "getter"), isByte(k + 1, 0x3D) { getter = word(k + 2) }
        k += 1
      }
      i = close
    }
    let start = i
    while i < tokens.count, !isByte(i, 0x3B) {
      if isByte(i, 0x28) {
        i = skipGroup(i)
        continue
      }
      i += 1
    }
    let end = i
    i += 1
    // The name: the last word that's no macro, stepping back over macros and their arguments.
    var last = end - 1
    var macroName: String?
    var unavailable = false
    while last > start {
      if isByte(last, 0x29) {
        var depth = 0
        var k = last
        while k > start {
          if isByte(k, 0x29) { depth += 1 }
          if isByte(k, 0x28) {
            depth -= 1
            if depth == 0 { break }
          }
          k -= 1
        }
        guard isMacroWord(k - 1) else { break }
        var j = k - 1
        let macro = trailing(&j)
        if let name = macro.swiftName { macroName = name }
        if macro.unavailable { unavailable = true }
        last = k - 2
        continue
      }
      if isMacroWord(last) {
        if word(last) == "NS_UNAVAILABLE" { unavailable = true }
        last -= 1
        continue
      }
      break
    }
    guard !unavailable, last > start || isWord(last) else { return }
    var name: String
    var type: String
    if let block = blockType(start, last + 1), let blockName = block.name {
      name = blockName
      type = block.type
    } else {
      guard isWord(last) else { return }
      name = word(last)
      type = swiftType(start, last)
    }
    if nullableAttribute, !type.hasSuffix("?") { type += "?" }
    let staticWord = isClass ? "static " : ""
    if let noted = holder?.properties[name] ?? macroName {
      emit("\(access)\(staticWord)var \(escaped(noted)): \(type) { get }", line)
      return
    }
    var names = [getter ?? name]
    if getter != nil { names.append(name) }
    if isClass {
      // `defaultManager` on a file manager is `default`; `mainBundle` is `main`.
      let typeWords = camelWords(importer.classNames[objcName] ?? objcName)
      var words = camelWords(name)
      while words.count > 1, let lastWord = words.last, typeWords.contains(lastWord) { words.removeLast() }
      let shorter = lowerFirstWord(words)
      if shorter != name { names.append(shorter) }
    }
    // `stringByDeletingLastPathComponent` is `deletingLastPathComponent`, as for methods.
    let words = camelWords(name)
    if words.count > 2, words[1] == "By" { names.append(lowerFirstWord(Array(words.dropFirst(2)))) }
    // `CGContext` is `cgContext`, `URL` is `url`: Swift lowers what a name starts with.
    for entry in names {
      let swiftName = entry.first?.isUppercase == true ? lowerFirstWord(camelWords(entry)) : entry
      emit("\(access)\(staticWord)var \(escaped(swiftName)): \(type) { get }", line)
    }
  }

  private func method(_ i: inout Int, objcName: String, holder: APINotes.Holder?, access: String) {
    let isClass = isByte(i, 0x2B)
    let line = tokens[i].line
    i += 1
    var result = "Any"
    var resultWords: [String] = []
    if isByte(i, 0x28) {
      let close = skipGroup(i)
      if let block = blockType(i + 1, close - 1) {
        result = block.type
      } else {
        result = swiftType(i + 1, close - 1)
        for k in (i + 1)..<(close - 1) where isWord(k) { resultWords = camelWords(word(k)) }
      }
      i = close
    }
    var pieces: [String] = []
    var params: [(type: String, words: [String])] = []
    var selector = ""
    while i < tokens.count, isWord(i) || isByte(i, 0x3A) {
      if isMacroWord(i) { break }
      var piece = ""
      if isWord(i) {
        piece = word(i)
        i += 1
      }
      guard isByte(i, 0x3A) else {
        pieces.append(piece)
        selector += piece
        break
      }
      i += 1
      pieces.append(piece)
      selector += piece + ":"
      var type = "Any"
      var typeWords: [String] = []
      if isByte(i, 0x28) {
        let close = skipGroup(i)
        if let block = blockType(i + 1, close - 1) {
          type = block.type
        } else {
          type = swiftType(i + 1, close - 1)
          for k in (i + 1)..<(close - 1) where isWord(k) && !isSugarWord(word(k)) && !isMacroWord(k) {
            let written = word(k)
            let plain = written.hasPrefix("NS") || written.hasPrefix("CF") || written.hasPrefix("CG") ? String(written.dropFirst(2)) : written
            typeWords = written == "id" ? ["Object"] : camelWords(plain)
            break
          }
        }
        i = close
      }
      // Attributes on a parameter, then its name.
      while isMacroWord(i) { _ = trailing(&i) }
      if isWord(i) { i += 1 }
      params.append((type, typeWords))
    }
    if isByte(i, 0x2C) {
      // `, ...`: variadic.
      while i < tokens.count, !isByte(i, 0x3B) { i += 1 }
    }
    let macro = trailing(&i)
    if isByte(i, 0x7B) {
      i = skipGroup(i)
    } else {
      skipToSemicolon(&i)
    }
    guard !macro.unavailable else { return }
    let staticWord = isClass ? "static " : ""

    // `error:` at the end becomes `throws`.
    var throwing = false
    var effective = pieces
    var effectiveParams = params
    if let last = params.last, last.type.contains("NSErrorPointer") {
      throwing = true
      effective.removeLast()
      effectiveParams.removeLast()
      if result == "Bool" { result = "Void" }
      if result.hasSuffix("?") { result.removeLast() }
    }
    let effects = throwing ? " throws" : ""
    let returning = result == "Void" ? "" : " -> " + result

    if let noted = holder?.methods[selector] ?? macro.swiftName {
      emitNoted(noted, params: effectiveParams.map(\.type), staticWord: staticWord, access: access, effects: effects, returning: returning, line: line)
      return
    }
    for (base, labels) in importedNames(effective, effectiveParams, resultWords: resultWords, isClass: isClass, objcName: objcName) {
      emitCallable(base: base, labels: labels, types: effectiveParams.map(\.type), staticWord: base == "init" ? "" : staticWord, access: access, effects: effects, returning: returning, line: line)
    }
  }

  private func emitNoted(_ noted: String, params: [String], staticWord: String, access: String, effects: String, returning: String, line: Int32) {
    guard let open = noted.firstIndex(of: "(") else {
      emit("\(access)\(staticWord)var \(escaped(noted)): \(returning.replacingOccurrences(of: " -> ", with: "")) { get }", line)
      return
    }
    let base = String(noted[..<open])
    let labels = noted[noted.index(after: open)...].dropLast().split(separator: ":").map(String.init)
    let isInit = base == "init"
    emitCallable(base: base, labels: labels, types: params, staticWord: isInit ? "" : staticWord, access: access, effects: effects, returning: returning, line: line)
  }

  private func emitCallable(base: String, labels: [String], types: [String], staticWord: String, access: String, effects: String, returning: String, line: Int32) {
    var parts: [String] = []
    for (index, label) in labels.enumerated() {
      let type = index < types.count ? types[index] : "Any"
      parts.append("\(escaped(label)) p\(index): \(type)")
    }
    // `- (nullable instancetype)init…` can fail.
    let name = base == "init" ? (returning.hasSuffix("?") ? "init?" : "init") : "func " + escaped(base)
    emit("\(access)\(staticWord)\(name)(\(parts.joined(separator: ", ")))\(effects)\(base == "init" ? "" : returning)", line)
  }

  /// Swift's omit-needless-words rules, approximately: anything uncertain emits both forms, and labels choose at the call.
  private func importedNames(_ pieces: [String], _ params: [(type: String, words: [String])], resultWords: [String], isClass: Bool, objcName: String) -> [(String, [String])] {
    guard let first = pieces.first else { return [] }
    func dropType(_ words: [String], _ typeWords: [String]) -> [String] {
      var kept = words
      var tail = typeWords
      while kept.count > 1, let a = kept.last, let b = tail.last, a.lowercased() == b.lowercased() {
        kept.removeLast()
        tail.removeLast()
      }
      return kept
    }
    if params.isEmpty {
      if pieces.count > 1 { return [(lowerFirstWord(camelWords(first)), [])] }
      return [(first, [])]
    }
    let rest = Array(pieces.dropFirst())
    let restFull = rest.map { $0.isEmpty ? "_" : $0 }
    let restShort = zip(rest, params.dropFirst()).map { piece, param -> String in
      if piece.isEmpty { return "_" }
      return lowerFirstWord(dropType(camelWords(piece), param.words))
    }
    var results: [(String, [String])] = []
    func add(_ base: String, _ label: String) {
      guard !base.isEmpty else { return }
      for tail in [restFull, restShort] {
        let entry = (base, [label] + tail)
        if !results.contains(where: { $0.0 == entry.0 && $0.1 == entry.1 }) { results.append(entry) }
      }
    }
    let words = camelWords(first)
    let typeWords = params[0].words
    // `initWithURL:` is `init(url:)`; `+arrayWithObject:` is `init(object:)`.
    if words.first == "init", words.count > 1 {
      var after = Array(words.dropFirst())
      if after.first == "With" { after.removeFirst() }
      if after.isEmpty {
        results.append(("init", ["_"] + restFull))
      } else {
        add("init", lowerFirstWord(after))
        add("init", lowerFirstWord(dropType(after, typeWords)))
      }
      return results
    }
    if words == ["init"] {
      add("init", "_")
      return results
    }
    var splitAt = -1
    for index in stride(from: words.count - 1, to: 0, by: -1) where prepositions.contains(words[index]) {
      splitAt = index
      break
    }
    if splitAt > 0 {
      let baseWords = Array(words[..<splitAt])
      let labelWords = Array(words[splitAt...])
      // `colorWithAlphaComponent:` on a color is `withAlphaComponent(_:)`; `stringByAppendingString:` is `appending(_:)`.
      if baseWords.count == 1, let word = baseWords.first, resultWords.contains(where: { $0.lowercased() == word.lowercased() }) {
        var after = labelWords
        if after.first == "By" { after.removeFirst() }
        add(lowerFirstWord(dropType(after, typeWords)), "_")
        add(lowerFirstWord(after), "_")
      }
      let base = lowerFirstWord(baseWords)
      add(base, lowerFirstWord(dropType(labelWords, typeWords)))
      add(base, lowerFirstWord(labelWords))
    } else {
      add(lowerFirstWord(words), "_")
      add(lowerFirstWord(dropType(words, typeWords)), "_")
    }
    // A class factory that's an initializer in Swift.
    if isClass, splitAt > 0, resultWords.contains(where: { $0 == "instancetype" }) || resultWords.last == camelWords(objcName).last {
      var after = Array(words[splitAt...])
      if after.first == "With" { after.removeFirst() }
      if !after.isEmpty { add("init", lowerFirstWord(after)) }
    }
    return results
  }

  // MARK: C declarations

  private func typedefDecl(_ i: inout Int) {
    let line = tokens[i].line
    i += 1
    let start = i
    while isMacroWord(i), !isEnumMacro(i) {
      _ = trailing(&i)
    }
    if isEnumMacro(i) {
      enumMacro(&i, line: line)
      return
    }
    if isText(i, "enum") {
      i += 1
      var tag: String?
      if isWord(i), !isMacroWord(i) {
        tag = word(i)
        i += 1
      }
      if isByte(i, 0x3A) {
        while i < tokens.count, !isByte(i, 0x7B), !isByte(i, 0x3B) { i += 1 }
      }
      if isByte(i, 0x7B) {
        let open = i
        i = skipGroup(i)
        var name = tag
        let macro = trailing(&i)
        if isWord(i) {
          name = word(i)
          i += 1
        }
        _ = trailing(&i)
        skipToSemicolon(&i)
        if let name { emitEnum(name: name, swiftName: macro.swiftName, open: open, isOptions: false, line: line) }
        return
      }
    }
    // `typedef const struct CF_BRIDGED_TYPE(NSData) __CFData * CFDataRef;`
    if isText(i, "const"), isText(i + 1, "struct") { i += 1 }
    if isText(i, "struct") || isText(i, "union") {
      i += 1
      while isMacroWord(i) { _ = trailing(&i) }
      var tag: String?
      if isWord(i) {
        tag = word(i)
        i += 1
      }
      if isByte(i, 0x7B) {
        let open = i
        i = skipGroup(i)
        let before = trailing(&i)
        var name = tag
        if isWord(i) {
          name = word(i)
          i += 1
        }
        let after = trailing(&i)
        skipToSemicolon(&i)
        if let name { emitStruct(name: name, swiftName: before.swiftName ?? after.swiftName, open: open, line: line) }
        return
      }
      // `typedef struct __CFString * CFStringRef;`
      let stars = isByte(i, 0x2A)
      var j = i
      while j < tokens.count, !isByte(j, 0x3B) {
        if isByte(j, 0x28) {
          j = skipGroup(j)
          continue
        }
        j += 1
      }
      var nameIndex = j - 1
      while nameIndex > i, isMacroWord(nameIndex) || isByte(nameIndex, 0x29) {
        if isByte(nameIndex, 0x29) {
          var depth = 0
          while nameIndex > i {
            if isByte(nameIndex, 0x29) { depth += 1 }
            if isByte(nameIndex, 0x28) {
              depth -= 1
              if depth == 0 { break }
            }
            nameIndex -= 1
          }
          nameIndex -= 1
          continue
        }
        nameIndex -= 1
      }
      if isWord(nameIndex) {
        let name = word(nameIndex)
        if stars || name.hasSuffix("Ref") {
          let swift = name.hasSuffix("Ref") ? String(name.dropLast(3)) : name
          let noted = importer.notes[name]?.swiftName ?? swift
          emit("public class \(noted) {}", line)
          foundClasses.append((name, noted))
          if noted != name { emit("public typealias \(name) = \(noted)", line) }
        } else if tag == nil || tag != name {
          let swift = importer.notes[name]?.swiftName ?? name
          emit("public struct \(swift) {}", line)
          if swift != name { emit("public typealias \(name) = \(swift)", line) }
        }
      }
      i = j + 1
      return
    }
    // A block or function pointer type.
    var end = i
    while end < tokens.count, !isByte(end, 0x3B) {
      if isByte(end, 0x7B) { break }
      if isByte(end, 0x28) {
        end = skipGroup(end)
        continue
      }
      end += 1
    }
    if let block = blockType(start, end), let name = block.name {
      emit("public typealias \(importer.notes[name]?.swiftName ?? name) = \(block.type)", line)
      i = end + 1
      return
    }
    // `typedef A B;`, perhaps with macros after.
    var nameIndex = end - 1
    var hasTyped = false
    var noted: String?
    while nameIndex > start {
      if isByte(nameIndex, 0x29) {
        var depth = 0
        while nameIndex > start {
          if isByte(nameIndex, 0x29) { depth += 1 }
          if isByte(nameIndex, 0x28) {
            depth -= 1
            if depth == 0 { break }
          }
          nameIndex -= 1
        }
        var j = nameIndex - 1
        let macro = trailing(&j)
        if let name = macro.swiftName { noted = name }
        nameIndex -= 2
        continue
      }
      if isMacroWord(nameIndex) {
        var j = nameIndex
        if trailing(&j).typedEnum { hasTyped = true }
        nameIndex -= 1
        continue
      }
      break
    }
    guard isWord(nameIndex), nameIndex >= start else {
      i = end + 1
      return
    }
    let name = word(nameIndex)
    i = end + 1
    let swift = importer.notes[name]?.swiftName ?? noted ?? name
    if hasTyped {
      let raw = swiftType(start, nameIndex, defaultNonnull: true)
      let (open, close) = nesting(swift, line)
      emit("\(open)public struct \(lastPart(swift)): Hashable, RawRepresentable { public init(rawValue: \(raw)) {}; public var rawValue: \(raw) { get } }\(close)", line)
      if swift != name { emit("public typealias \(name) = \(swift)", line) }
      foundTyped.append(name)
      return
    }
    if ["CGFloat", "NSInteger", "NSUInteger", "BOOL", "CFIndex", "size_t", "ssize_t", "NSTimeInterval"].contains(name) { return }
    guard nameIndex > start else { return }
    let target = swiftType(start, nameIndex, defaultNonnull: true)
    if target != name { emit("public typealias \(name) = \(target)", line) }
  }

  private func isEnumMacro(_ i: Int) -> Bool {
    isText(i, "NS_ENUM") || isText(i, "NS_OPTIONS") || isText(i, "CF_ENUM") || isText(i, "CF_OPTIONS") || isText(i, "NS_CLOSED_ENUM") || isText(i, "CF_CLOSED_ENUM") || isText(i, "NS_ERROR_ENUM") || isText(i, "OS_ENUM")
  }

  private func enumMacro(_ i: inout Int, line: Int32) {
    let isOptions = isText(i, "NS_OPTIONS") || isText(i, "CF_OPTIONS")
    let isError = isText(i, "NS_ERROR_ENUM")
    i += 1
    guard isByte(i, 0x28) else { return }
    let close = skipGroup(i)
    // `(NSInteger, Name)`, or for errors `(Domain, Name)`.
    var name = ""
    var k = close - 2
    while k > i {
      if isWord(k) {
        name = word(k)
        break
      }
      k -= 1
    }
    _ = isError
    i = close
    var macro = trailing(&i)
    var open = -1
    if isByte(i, 0x7B) {
      open = i
      i = skipGroup(i)
    }
    let after = trailing(&i)
    if macro.swiftName == nil { macro.swiftName = after.swiftName }
    if isByte(i, 0x3B) { i += 1 }
    guard open >= 0, !name.isEmpty else { return }
    emitEnum(name: name, swiftName: macro.swiftName, open: open, isOptions: isOptions, line: line)
  }

  private func emitEnum(name: String, swiftName: String?, open: Int, isOptions: Bool, line: Int32) {
    let close = skipGroup(open) - 1
    var cases: [(name: String, noted: String?, line: Int32)] = []
    var i = open + 1
    while i < close {
      guard isWord(i), !isMacroWord(i) else {
        i += 1
        continue
      }
      let caseName = word(i)
      let caseLine = tokens[i].line
      i += 1
      var noted = importer.notes[caseName]?.swiftName
      let macro = trailing(&i)
      if let name = macro.swiftName { noted = name }
      while i < close, !isByte(i, 0x2C) {
        if isByte(i, 0x28) {
          i = skipGroup(i)
          continue
        }
        i += 1
      }
      i += 1
      if !macro.unavailable { cases.append((caseName, noted, caseLine)) }
    }
    let swift = importer.notes[name]?.swiftName ?? swiftName ?? name
    // Swift drops the words all cases share.
    let split = cases.map { camelWords($0.name) }
    var shared = 0
    if cases.count > 1, let first = split.first {
      outer: while shared < first.count - 1 {
        for words in split where shared >= words.count - 1 || words[shared] != first[shared] { break outer }
        shared += 1
      }
    } else if let first = split.first {
      let enumWords = camelWords(name)
      while shared < first.count - 1, shared < enumWords.count, first[shared] == enumWords[shared] { shared += 1 }
    }
    let (openText, closeText) = nesting(swift, line)
    if isOptions {
      emit("\(openText)public struct \(lastPart(swift)): OptionSet {", line)
    } else {
      emit("\(openText)public enum \(lastPart(swift)) {", line)
    }
    for (entry, words) in zip(cases, split) {
      let short = entry.noted ?? lowerFirstWord(Array(words.dropFirst(shared)))
      if short.isEmpty { continue }
      if isOptions {
        emit("public static var \(escaped(short)): \(lastPart(swift)) { get }", entry.line)
      } else {
        emit("case \(escaped(short))", entry.line)
      }
    }
    if isOptions { emit("public init(rawValue: Int) {}", line) }
    emit("}\(closeText)", line)
    if swift != name { emit("public typealias \(name) = \(swift)", line) }
  }

  private func emitStruct(name: String, swiftName: String?, open: Int, line: Int32) {
    let swift = importer.notes[name]?.swiftName ?? swiftName ?? name
    var fields: [(String, String, Int32)] = []
    let close = skipGroup(open) - 1
    var i = open + 1
    var from = i
    while i < close {
      if isByte(i, 0x7B) || isByte(i, 0x28) {
        i = skipGroup(i)
        continue
      }
      if isByte(i, 0x5B) {
        i = skipGroup(i)
        continue
      }
      if isByte(i, 0x3B) {
        if let block = blockType(from, i), let blockName = block.name {
          fields.append((blockName, block.type, tokens[from].line))
        } else {
          var last = i - 1
          if isByte(last, 0x5D) {
            while last > from, !isByte(last, 0x5B) { last -= 1 }
            last -= 1
          }
          while last > from, isMacroWord(last) { last -= 1 }
          if last > from, isWord(last), !isByte(from, 0x7B) {
            fields.append((word(last), swiftType(from, last), tokens[last].line))
          }
        }
        from = i + 1
      }
      i += 1
    }
    let (openText, closeText) = nesting(swift, line)
    emit("\(openText)public struct \(lastPart(swift)) {", line)
    for field in fields { emit("public var \(escaped(field.0)): \(field.1)", field.2) }
    let params = fields.map { "\(escaped($0.0)): \($0.1)" }.joined(separator: ", ")
    emit("public init() {}", line)
    if !fields.isEmpty { emit("public init(\(params)) {}", line) }
    emit("}\(closeText)", line)
    if swift != name { emit("public typealias \(name) = \(swift)", line) }
  }

  private func tagged(_ i: inout Int) {
    let isEnum = isText(i, "enum")
    let line = tokens[i].line
    i += 1
    while isMacroWord(i) { _ = trailing(&i) }
    var tag: String?
    if isWord(i) {
      tag = word(i)
      i += 1
    }
    if isByte(i, 0x7B) {
      let open = i
      i = skipGroup(i)
      let macro = trailing(&i)
      if isByte(i, 0x3B) { i += 1 }
      if let tag {
        if isEnum {
          emitEnum(name: tag, swiftName: macro.swiftName, open: open, isOptions: false, line: line)
        } else {
          emitStruct(name: tag, swiftName: macro.swiftName, open: open, line: line)
        }
      }
      return
    }
    skipToSemicolon(&i)
  }

  /// A function or a global at file scope.
  private func cDeclaration(_ i: inout Int) {
    // Macros ahead of something with its own shape: `NS_SWIFT_SENDABLE @interface`, `API_AVAILABLE(...) typedef`.
    if isMacroWord(i) {
      var next = i
      _ = trailing(&next)
      if isByte(next, 0x40) || isByte(next, 0x2D) || isByte(next, 0x2B) || isText(next, "typedef") || isText(next, "struct") || isText(next, "enum") || isText(next, "union") {
        i = next
        return
      }
    }
    let start = i
    var open = -1
    var j = i
    while j < tokens.count {
      if isByte(j, 0x3B) { break }
      if isByte(j, 0x7B) { break }
      if isByte(j, 0x28) {
        if isMacroWord(j - 1) {
          j = skipGroup(j)
          continue
        }
        if open < 0, !isByte(j + 1, 0x5E) { open = j }
        j = skipGroup(j)
        continue
      }
      j += 1
    }
    let end = j
    if isByte(j, 0x7B) {
      i = skipGroup(j)
      if isByte(i, 0x3B) { i += 1 }
    } else {
      i = j + 1
    }
    guard end > start, end - start < 300 else { return }
    let line = tokens[start].line
    if open > start, isWord(open - 1), !isMacroWord(open - 1) {
      let name = word(open - 1)
      let close = skipGroup(open) - 1
      var params: [String] = []
      var from = open + 1
      var k = from
      while k <= close {
        if k == close || isByte(k, 0x2C) {
          if from < k, !(k == from + 1 && isText(from, "void")), !isByte(from, 0x2E) { params.append(cParameterType(from, k)) }
          from = k + 1
        } else if isByte(k, 0x28) {
          k = skipGroup(k)
          continue
        }
        k += 1
      }
      var after = close + 1
      let macro = trailing(&after)
      guard !macro.unavailable else { return }
      var typeStart = start
      while typeStart < open - 1, isMacroWord(typeStart) || isText(typeStart, "extern") || isText(typeStart, "static") || isText(typeStart, "inline") || isText(typeStart, "__inline") {
        typeStart += 1
        if isByte(typeStart, 0x28) { typeStart = skipGroup(typeStart) }
      }
      guard typeStart < open - 1 else { return }
      let result = swiftType(typeStart, open - 1)
      emitFunction(name: name, noted: importer.notes[name]?.swiftName ?? importer.globals[name] ?? macro.swiftName, params: params, result: result, line: line)
      return
    }
    // A global: the last plain word before any macro is its name.
    var last = end - 1
    var noted: String?
    while last > start {
      if isByte(last, 0x29) {
        var depth = 0
        while last > start {
          if isByte(last, 0x29) { depth += 1 }
          if isByte(last, 0x28) {
            depth -= 1
            if depth == 0 { break }
          }
          last -= 1
        }
        var k = last - 1
        if let name = trailing(&k).swiftName { noted = name }
        last -= 2
        continue
      }
      if isMacroWord(last) {
        last -= 1
        continue
      }
      break
    }
    guard isWord(last), last > start else { return }
    let name = word(last)
    var typeStart = start
    while typeStart < last, isMacroWord(typeStart) || isText(typeStart, "extern") || isText(typeStart, "static") {
      typeStart += 1
      if isByte(typeStart, 0x28) { typeStart = skipGroup(typeStart) }
    }
    guard typeStart < last else { return }
    let type = swiftType(typeStart, last, defaultNonnull: true)
    emit("public var \(name): \(type) { get }", line)
    deferred.append((type: type, name: importer.globals[name] ?? noted ?? name, line: line))
  }

  private func emitFunction(name: String, noted: String?, params: [String], result: String, line: Int32) {
    let returning = result == "Void" ? "" : " -> " + result
    func parameters(_ labels: [String], skipping: Int = -1) -> String {
      var parts: [String] = []
      var index = 0
      for (position, type) in params.enumerated() {
        if position == skipping { continue }
        let label = index < labels.count ? labels[index] : "_"
        parts.append("\(escaped(label)) p\(position): \(type)")
        index += 1
      }
      return parts.joined(separator: ", ")
    }
    emit("public func \(name)(\(parameters([])))\(returning)", line)
    guard let noted else { return }
    // `getter:CGRect.width(self:)`, `CGRect.offsetBy(self:dx:dy:)`, `CGRect.init(x:y:width:height:)`, `Foo(a:)`.
    var text = noted
    var isGetter = false
    if text.hasPrefix("getter:") {
      isGetter = true
      text = String(text.dropFirst(7))
    } else if text.hasPrefix("setter:") {
      return
    }
    let parenIndex = text.firstIndex(of: "(")
    let head = parenIndex.map { String(text[..<$0]) } ?? text
    let labels = parenIndex.map { text[text.index(after: $0)...].dropLast().split(separator: ":").map(String.init) } ?? []
    let parts = head.split(separator: ".").map(String.init)
    guard parts.count >= 2 else {
      if parenIndex != nil { emit("public func \(escaped(head))(\(parameters(labels)))\(returning)", line) }
      return
    }
    let owner = parts.dropLast().joined(separator: ".")
    let member = parts.last!
    let selfSlot = labels.firstIndex(of: "self") ?? -1
    let kept = labels.filter { $0 != "self" }
    let staticWord = selfSlot < 0 ? "static " : ""
    if isGetter {
      emit("extension \(owner) { public \(staticWord)var \(escaped(member)): \(result) { get } }", line)
    } else if member == "init" {
      emit("extension \(owner) { public init(\(parameters(kept))) {} }", line)
    } else {
      emit("extension \(owner) { public \(staticWord)func \(escaped(member))(\(parameters(kept, skipping: selfSlot)))\(returning) }", line)
    }
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? { index >= 0 && index < count ? self[index] : nil }
}

// MARK: The importer

/// Finds a Clang module's headers and turns them into a generated interface.
final class ClangImporter {
  private let sdk: String
  private var frameworks: [String: String] = [:]
  /// `math.h` → `_DarwinFoundation1`, from the module maps in `usr/include`.
  private var headerModules: [String: String] = [:]
  private var moduleHeaders: [String: [String]] = [:]

  private var noteStore: [String: APINotes.Holder] = [:]
  private var globalStore: [String: String] = [:]
  private var bridgeStore: [String: String] = [
    "NSURL": "URL", "NSData": "Data", "NSDate": "Date", "NSUUID": "UUID", "NSLocale": "Locale", "NSCalendar": "Calendar", "NSTimeZone": "TimeZone",
    "NSCharacterSet": "CharacterSet", "NSIndexSet": "IndexSet", "NSIndexPath": "IndexPath", "NSURLComponents": "URLComponents", "NSURLRequest": "URLRequest",
    "NSNotification": "Notification", "NSAttributedString": "NSAttributedString",
  ]
  private var classStore: [String: String] = [:]
  private var protocolStore: [String: String] = [:]
  private var typedStore: Set<String> = []
  private var read: [String: [Data?]] = [:]

  init(sdk: String, frameworks: [String: String]) {
    self.sdk = sdk
    self.frameworks = frameworks
    readModuleMaps()
  }

  // Shared with the readers on other threads.
  var notes: NotesView { NotesView(importer: self) }
  struct NotesView {
    let importer: ClangImporter
    subscript(name: String) -> APINotes.Holder? {
      return importer.noteStore[name]
    }
  }
  var globals: GlobalsView { GlobalsView(importer: self) }
  struct GlobalsView {
    let importer: ClangImporter
    subscript(name: String) -> String? {
      return importer.globalStore[name]
    }
  }
  var classNames: ClassNames { ClassNames(importer: self) }
  struct ClassNames {
    let importer: ClangImporter
    subscript(name: String) -> String? {
      return importer.classStore[name] ?? importer.noteStore[name]?.swiftName
    }
  }

  func bridge(_ name: String) -> String? {
    return bridgeStore[name]
  }

  func isObjectType(_ name: String) -> Bool {
    return classStore[name] != nil || name.hasPrefix("NS")
  }

  /// The name a type goes by in generated text. Aliases cover renames, so the original works too.
  func typeName(_ name: String) -> String {
    return classStore[name] ?? noteStore[name]?.swiftName ?? name
  }

  func protocolName(_ name: String) -> String {
    if name == "NSObject" { return "NSObjectProtocol" }
    return protocolStore[name] ?? noteStore[name]?.swiftName ?? name
  }

  private func readModuleMaps() {
    let directory = sdk + "/usr/include"
    let manager = FileManager.default
    for entry in (try? manager.contentsOfDirectory(atPath: directory)) ?? [] where entry.hasSuffix(".modulemap") {
      guard let text = try? String(contentsOfFile: directory + "/" + entry, encoding: .utf8) else { continue }
      var current: String?
      for line in text.split(separator: "\n") {
        if !line.hasPrefix(" "), !line.hasPrefix("\t") {
          let parts = line.split(separator: " ")
          if parts.first == "module", parts.count > 1 {
            current = String(parts[1])
          } else if parts.first == "framework", parts.count > 2 {
            current = String(parts[2])
          }
          continue
        }
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("header \"") || trimmed.hasPrefix("textual header \"") || trimmed.hasPrefix("private header \"") else { continue }
        guard let current, let open = trimmed.firstIndex(of: "\""), let close = trimmed.lastIndex(of: "\""), open < close else { continue }
        let header = String(trimmed[trimmed.index(after: open)..<close])
        if headerModules[header] == nil { headerModules[header] = current }
        moduleHeaders[current, default: []].append(directory + "/" + header)
      }
    }
  }

  func hasModule(_ name: String) -> Bool { frameworks[name] != nil || moduleHeaders[name] != nil }

  func hasHeaders(_ name: String) -> Bool { !headers(of: name).isEmpty }

  private func headers(of name: String) -> [String] {
    if let framework = frameworks[name] {
      let directory = framework + "/Headers"
      let list = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
      return list.filter { $0.hasSuffix(".h") }.sorted().map { directory + "/" + $0 }
    }
    return Array(Set(moduleHeaders[name] ?? [])).sorted()
  }

  /// The module a `#import <...>` belongs to.
  private func moduleOf(include: String) -> String? {
    if let module = headerModules[include] { return module }
    if let slash = include.firstIndex(of: "/") {
      let first = String(include[..<slash])
      if frameworks[first] != nil { return first }
      if first == "objc" { return "ObjectiveC" }
      if first == "dispatch" { return "Dispatch" }
    }
    return nil
  }

  /// What a module exports, before its text exists: dependencies go first, as they rename what it mentions.
  /// Its headers are kept for `generate`, so they're read once.
  func exports(of name: String) -> [String] {
    let paths = headers(of: name)
    var contents = [Data?](repeating: nil, count: paths.count)
    contents.withUnsafeMutableBufferPointer { buffer in
      nonisolated(unsafe) let slots = buffer
      DispatchQueue.concurrentPerform(iterations: paths.count) { index in slots[index] = FileManager.default.contents(atPath: paths[index]) }
    }
    read[name] = contents
    var found: Set<String> = []
    for data in contents {
      guard let data else { continue }
      data.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        guard let base = bytes.baseAddress else { return }
        var i = 0
        while i < bytes.count {
          // A directive at the start of a line, the only part read.
          let rest = bytes.count - i
          var lineEnd = bytes.count
          if let newline = memchr(base + i, 0x0A, rest) { lineEnd = UnsafePointer(newline.assumingMemoryBound(to: UInt8.self)) - base }
          if rest > 8, bytes[i] == 0x23, bytes[i + 1] == 0x69, bytes[i + 2] == 0x6D || bytes[i + 2] == 0x6E {
            let text = String(decoding: bytes[i..<lineEnd], as: UTF8.self)
            if text.hasPrefix("#import") || text.hasPrefix("#include"), let open = text.firstIndex(of: "<"), let close = text.firstIndex(of: ">"), open < close {
              if let module = moduleOf(include: String(text[text.index(after: open)..<close])), module != name { found.insert(module) }
            }
          }
          i = lineEnd + 1
        }
      }
    }
    return found.sorted()
  }

  func generate(_ name: String) -> GeneratedModule? {
    guard hasModule(name) else { return nil }
    if let framework = frameworks[name] {
      let directory = framework + "/Headers"
      for entry in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] where entry.hasSuffix(".apinotes") {
        guard let text = try? String(contentsOfFile: directory + "/" + entry, encoding: .utf8) else { continue }
        var read = APINotes()
        read.read(text)
        noteStore.merge(read.holders) { old, new in
          var merged = old
          merged.swiftName = new.swiftName ?? old.swiftName
          merged.methods.merge(new.methods) { $1 }
          merged.properties.merge(new.properties) { $1 }
          return merged
        }
        globalStore.merge(read.globals) { $1 }
        bridgeStore.merge(read.bridges) { $1 }
        for (holder, entry) in read.holders {
          if let swift = entry.swiftName, !swift.contains("("), !swift.contains(":") { classStore[holder] = swift }
        }
      }
    }
    let paths = headers(of: name)
    guard !paths.isEmpty else { return nil }
    var readers = [HeaderReader?](repeating: nil, count: paths.count)
    let contents = read.removeValue(forKey: name)
    readers.withUnsafeMutableBufferPointer { buffer in
      nonisolated(unsafe) let slots = buffer
      DispatchQueue.concurrentPerform(iterations: paths.count) { index in
        guard let data = contents?[index] ?? FileManager.default.contents(atPath: paths[index]) else { return }
        let reader = HeaderReader(bytes: Array(data), importer: self)
        reader.read()
        slots[index] = reader
      }
    }
    for reader in readers {
      guard let reader else { continue }
      for (name, swift) in reader.foundClasses { classStore[name] = swift }
      for (name, swift) in reader.foundProtocols { protocolStore[name] = swift }
      typedStore.formUnion(reader.foundTyped)
    }
    for reader in readers {
      guard let reader else { continue }
      for category in reader.categories {
        if let swift = classStore[category.name], swift != category.name { reader.out[category.line].text = "extension \(swift) {" }
      }
    }
    var text = ""
    var lines: [(header: Int32, line: Int32)] = []
    var exported: Set<String> = []
    for reader in readers {
      for include in reader?.includes ?? [] {
        if let module = moduleOf(include: include), module != name { exported.insert(module) }
      }
    }
    for module in exported.sorted() {
      text += "@_exported import \(module)\n"
      lines.append((0, 1))
    }
    for (headerIndex, reader) in readers.enumerated() {
      guard let reader else { continue }
      for entry in reader.out {
        text += entry.text
        text += "\n"
        lines.append((Int32(headerIndex), entry.line))
      }
      // Constants of a typed-string type are its members too: `NSURLIsDirectoryKey` is `URLResourceKey.isDirectoryKey`.
      for constant in reader.deferred where isTypedName(constant.type) {
        let owner = constant.type
        // What gets dropped is what it shares with the C name: `NSURLIsDirectoryKey` of `NSURLResourceKey`.
        let ownerWords = camelWords(cTypedName(of: owner) ?? owner)
        var words = camelWords(constant.name)
        if constant.name.contains(".") {
          let parts = constant.name.split(separator: ".")
          text += "extension \(parts.dropLast().joined(separator: ".")) { public static var \(escaped(String(parts.last!))): \(owner) { get } }\n"
          lines.append((Int32(headerIndex), constant.line))
          continue
        }
        var index = 0
        while words.count > 1, index < ownerWords.count, words.first == ownerWords[index] {
          words.removeFirst()
          index += 1
        }
        let short = lowerFirstWord(words)
        text += "extension \(owner) { public static var \(escaped(short)): \(owner) { get } }\n"
        lines.append((Int32(headerIndex), constant.line))
      }
    }
    return GeneratedModule(text: text, lines: lines, headers: paths, exports: exported.sorted())
  }

  private func cTypedName(of type: String) -> String? {
    return typedStore.first { classStore[$0] == type || noteStore[$0]?.swiftName == type }
  }

  private func isTypedName(_ type: String) -> Bool {
    if typedStore.contains(type) { return true }
    return typedStore.contains(where: { classStore[$0] == type || noteStore[$0]?.swiftName == type })
  }
}
