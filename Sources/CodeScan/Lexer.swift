import CodeHighlighting
import Foundation

public enum TokenKind: UInt8, Sendable {
  case identifier = 1
  case keyword
  /// A keyword that declares something (`func`, `class`, `let`).
  case declarationKeyword
  case number
  case string
  case comment
  case docComment
  case open
  case close
  /// Code inside a string starts or ends: `\(` and its `)`.
  case interpolationOpen
  case interpolationClose
  case punctuation
  /// `#if`, or a whole C preprocessor line.
  case directive
  /// `@Published`, `#[derive(Debug)]`.
  case attribute
}

/// One token: 8 bytes, its bytes in the source.
public struct Token: Sendable, Equatable {
  public var offset: UInt32
  var bits: UInt32

  @inline(__always) init(_ kind: TokenKind, _ start: Int, _ end: Int) {
    offset = UInt32(truncatingIfNeeded: start)
    bits = UInt32(truncatingIfNeeded: end &- start) << 8 | UInt32(kind.rawValue)
  }

  @inline(__always) public var kind: TokenKind { TokenKind(rawValue: UInt8(truncatingIfNeeded: bits))! }
  @inline(__always) public var length: Int { Int(bits >> 8) }
  @inline(__always) public var start: Int { Int(offset) }
  @inline(__always) public var end: Int { Int(offset) &+ Int(bits >> 8) }
}

/// Byte classes the scan loop dispatches on.
enum ByteClass {
  static let space: UInt8 = 0, newline: UInt8 = 1, ident: UInt8 = 2, digit: UInt8 = 3, opener: UInt8 = 4
  static let open: UInt8 = 5, close: UInt8 = 6, punct: UInt8 = 7, single: UInt8 = 8, colon: UInt8 = 9
}

/// A language's rules compiled to tables: everything the scan looks at per byte, so no language is in its code.
public final class LexProfile: @unchecked Sendable {
  public let spec: LanguageSpec
  public let rules: LanguageRules

  struct Opener {
    enum Kind { case lineComment, blockComment, string, swiftRaw, rustRaw, cppRaw }
    var kind: Kind
    var open: [UInt8]
    var close: [UInt8] = []
    var escape: UInt8 = 0
    var multiline = false
    var nested = false
    var interpolation: Int = -1
  }

  struct CompiledInterpolation {
    var open: [UInt8]
    var close: UInt8
    var doubledIsLiteral: Bool
  }

  let cls: UnsafeMutablePointer<UInt8>
  /// What `cls` would say for a byte when none of its openers match.
  let fallback: UnsafeMutablePointer<UInt8>
  let ident: UnsafeMutablePointer<UInt8>
  let openers: [[Opener]]
  let interpolations: [CompiledInterpolation]
  let charLiteral: Bool
  let anchoredDirectives: Bool
  let freeDirectives: Bool
  let atWords: Bool
  let rustAttributes: Bool
  let commentsNeedWordStart: Bool
  let hereDocuments: Bool
  let regexLiterals: Bool

  // Keywords: open addressing over the word's first 16 bytes, its length and whether it declares.
  private let keywordWords: UnsafeMutablePointer<UInt64>
  private let keywordMask: Int
  let maxKeyword: Int
  private let caseInsensitive: Bool
  /// Declaration words, for the symbol pass.
  public let declarationKinds: [String: SymbolKind]

  private init(spec: LanguageSpec) {
    self.spec = spec
    rules = LanguageRules.rules(for: spec.name)
    let rules = self.rules

    cls = .allocate(capacity: 256)
    fallback = .allocate(capacity: 256)
    ident = .allocate(capacity: 256)
    for byte in 0..<256 {
      let c = UInt8(byte)
      var kind = ByteClass.punct
      var isIdent: UInt8 = 0
      switch c {
      case 0x41...0x5A, 0x61...0x7A, 0x5F, 0x80...0xFF:
        kind = ByteClass.ident
        isIdent = 1
      case 0x30...0x39:
        kind = ByteClass.digit
        isIdent = 1
      case 0x20, 0x09, 0x0D, 0x0C: kind = ByteClass.space
      case 0x0A: kind = ByteClass.newline
      case 0x28, 0x5B, 0x7B: kind = ByteClass.open
      case 0x29, 0x5D, 0x7D: kind = ByteClass.close
      case 0x2C, 0x3B: kind = ByteClass.single
      case 0x3A: kind = ByteClass.colon
      case 0x24:
        if !rules.dollarIsPunctuation {
          kind = ByteClass.ident
          isIdent = 1
        }
      default: break
      }
      cls[byte] = kind
      ident[byte] = isIdent
    }
    for byte in rules.extraIdentifierBytes.utf8 { ident[Int(byte)] = 1 }
    fallback.update(from: cls, count: 256)

    // Openers: comments, then strings, longest first per first byte.
    let compiled = rules.interpolations.map {
      CompiledInterpolation(open: Array($0.open.utf8), close: $0.close, doubledIsLiteral: $0.doubledIsLiteral)
    }
    interpolations = compiled
    var table = [[Opener]](repeating: [], count: 256)
    func add(_ opener: Opener) { table[Int(opener.open[0])].append(opener) }
    for marker in spec.lineComments { add(Opener(kind: .lineComment, open: Array(marker.utf8))) }
    for block in spec.blockComments {
      add(
        Opener(
          kind: .blockComment, open: Array(block.open.utf8), close: Array(block.close.utf8),
          nested: spec.nestedBlockComments))
    }
    for delim in spec.strings + rules.extraStrings {
      let escaped = delim.escape.flatMap { $0.asciiValue } ?? 0
      if rules.swiftRawStrings, delim.open.hasPrefix("#") { continue }
      if rules.rustRawStrings, delim.open.hasPrefix("r") { continue }
      var interpolation = -1
      for (index, rule) in rules.interpolations.enumerated() where escaped != 0 || rule.open.utf8.first != 0x5C {
        if rule.strings.isEmpty ? escaped != 0 : rule.strings.contains(delim.open) {
          interpolation = index
          break
        }
      }
      add(
        Opener(
          kind: .string, open: Array(delim.open.utf8), close: Array(delim.close.utf8), escape: escaped,
          multiline: delim.multiline || rules.multilineStrings, interpolation: interpolation))
    }
    if rules.swiftRawStrings { add(Opener(kind: .swiftRaw, open: [0x23])) }
    if rules.rustRawStrings {
      add(Opener(kind: .rustRaw, open: [0x72]))
      add(Opener(kind: .rustRaw, open: [0x62]))
    }
    if rules.cppRawStrings {
      for prefix in ["R\"", "u8R\"", "uR\"", "UR\"", "LR\""] { add(Opener(kind: .cppRaw, open: Array(prefix.utf8))) }
    }
    for byte in 0..<256 where !table[byte].isEmpty {
      table[byte].sort { $0.open.count > $1.open.count }
      cls[byte] = ByteClass.opener
    }
    charLiteral = spec.charLiteral != nil
    if charLiteral { cls[0x27] = ByteClass.opener }
    anchoredDirectives = spec.hashDirectives && spec.hashDirectivesAnchored
    freeDirectives = spec.hashDirectives && !spec.hashDirectivesAnchored
    rustAttributes = spec.rustAttributes
    atWords = spec.atWords
    if anchoredDirectives || freeDirectives || rustAttributes { cls[0x23] = ByteClass.opener }
    if atWords { cls[0x40] = ByteClass.opener }
    regexLiterals = rules.regexLiterals
    if regexLiterals { cls[0x2F] = ByteClass.opener }
    hereDocuments = rules.hereDocuments
    if hereDocuments { cls[0x3C] = ByteClass.opener }
    commentsNeedWordStart = rules.commentsNeedWordStart || spec.lineCommentsAtLineStartOnly
    openers = table

    // Keywords: the spec's, and every declaration word of the rules. Kinds come from the rules, else the spec's.
    var kinds = rules.declarations
    for (word, kind) in spec.declKeywords where kinds[word] == nil {
      kinds[word] = kind == .typeDeclaration ? .class : .function
    }
    declarationKinds = kinds
    caseInsensitive = spec.keywordsCaseInsensitive
    var words = spec.keywords.filter { $0.utf8.count <= 16 && $0.utf8.allSatisfy { $0 != 0x2D && $0 != 0x7E } }
    words.formUnion(kinds.keys.filter { !$0.hasPrefix("@") })
    var capacity = 64
    while capacity < words.count * 4 { capacity *= 2 }
    keywordMask = capacity - 1
    let keywordTable = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity * 2)
    keywordTable.initialize(repeating: 0, count: capacity * 2)
    keywordWords = keywordTable
    var longest = 0
    let mask = keywordMask
    for word in words {
      var bytes = Array(word.utf8) + [UInt8](repeating: 0, count: 16)
      let length = word.utf8.count
      longest = max(longest, length)
      let declaring = kinds[word] != nil || kinds[word.lowercased()] != nil
      bytes.withUnsafeMutableBytes { buffer in
        let (first, second) = Self.key(
          UnsafePointer(buffer.bindMemory(to: UInt8.self).baseAddress!), length, spec.keywordsCaseInsensitive)
        var slot = Self.slot(first, second) & mask
        while keywordTable[slot &* 2] != 0 { slot = (slot &+ 1) & mask }
        keywordTable[slot &* 2] = first
        // The length and whether it declares share the second word's top byte: identifiers here have at most 16 bytes.
        keywordTable[slot &* 2 &+ 1] = second ^ (UInt64(length) << 56) ^ (declaring ? 1 << 55 : 0)
      }
    }
    maxKeyword = longest
  }

  @inline(__always) private static func key(_ t: UnsafePointer<UInt8>, _ length: Int, _ folding: Bool) -> (UInt64, UInt64) {
    let raw = UnsafeRawPointer(t)
    var first = raw.loadUnaligned(as: UInt64.self)
    var second = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
    if length < 8 {
      first &= (1 << UInt64(length &* 8)) &- 1
      second = 0
    } else if length == 8 {
      second = 0
    } else if length < 16 {
      second &= (1 << UInt64((length &- 8) &* 8)) &- 1
    }
    if folding {
      first &= 0xDFDF_DFDF_DFDF_DFDF
      second &= 0xDFDF_DFDF_DFDF_DFDF
    }
    return (first, second)
  }

  @inline(__always) private static func slot(_ first: UInt64, _ second: UInt64) -> Int {
    Int(truncatingIfNeeded: ((first ^ (second &* 0x9E37_79B9_7F4A_7C15)) &* 0xFF51_AFD7_ED55_8CCD) >> 40)
  }

  /// 0: not a keyword; 1: a keyword; 2: a declaring keyword.
  @inline(__always) func keywordClass(_ t: UnsafePointer<UInt8>, _ length: Int) -> Int {
    let (first, second) = Self.key(t, length, caseInsensitive)
    var slot = Self.slot(first, second) & keywordMask
    while true {
      let stored = keywordWords[slot &* 2]
      if stored == 0 { return 0 }
      if stored == first {
        let other = keywordWords[slot &* 2 &+ 1]
        let plain = second ^ (UInt64(length) << 56)
        if other == plain { return 1 }
        if other == plain ^ (1 << 55) { return 2 }
      }
      slot = (slot &+ 1) & keywordMask
    }
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var cache: [String: LexProfile] = [:]

  /// The profile for a language, built once.
  public static func profile(for spec: LanguageSpec) -> LexProfile {
    lock.lock()
    defer { lock.unlock() }
    if let profile = cache[spec.name] { return profile }
    let profile = LexProfile(spec: spec)
    cache[spec.name] = profile
    return profile
  }

  /// A language by its alias ("swift", "ts"); nil when the catalog has none.
  public static func profile(forLanguage alias: String) -> LexProfile? {
    CodeHighlighter.spec(forLanguage: alias).map(profile(for:))
  }

  /// The plain-text profile: words, numbers and brackets, without strings or comments.
  public static let plainText = profile(for: LanguageSpec(name: "Plain Text", aliases: []))
}

/// How many padding bytes must follow every text given to the scanner, readable and zero: its loops read words
/// and stop at the zero instead of checking the end each time.
public let scanPadding = 32

/// Whether the text starts with UTF-8's byte order mark, as files written on Windows often do.
@inline(__always) public func hasByteOrderMark(_ t: UnsafePointer<UInt8>, _ n: Int) -> Bool {
  n >= 3 && t[0] == 0xEF && t[1] == 0xBB && t[2] == 0xBF
}

/// Scans `text`. `out` has room for `length + 8` tokens, and the text is followed by `scanPadding` zero bytes.
/// Tolerant: unterminated strings end at their line, and comments at the end.
public func scan(
  _ t: UnsafePointer<UInt8>, _ n: Int, profile: LexProfile, into out: UnsafeMutablePointer<Token>
) -> Int {
  var i = 0
  var count = 0
  let cls = profile.cls
  let ident = profile.ident
  let fallback = profile.fallback
  let raw = UnsafeRawPointer(t)
  var frames = InterpolationFrames()
  var hereDocument = HereDocument()

  // A byte order mark says how the text is written, and would join the first word as high bytes do.
  if hasByteOrderMark(t, n) {
    i = 3
  } else if n > 2, t[0] == 0x23, t[1] == 0x21, t[2] != 0x5B {
    // A shebang is no code, in any language.
    i = lineEnd(t, n, 0)
    out[0] = Token(.comment, 0, i)
    count = 1
  }

  @inline(__always) func identifierEnd(_ start: Int) -> Int {
    var j = start &+ 1
    while true {
      let word = raw.loadUnaligned(fromByteOffset: j, as: UInt64.self)
      let stop = nonIdentifierMask(word)
      if stop == 0 {
        j &+= 8
        continue
      }
      j &+= stop.trailingZeroBitCount >> 3
      // $ and the extras are in the table, not the fast mask.
      if ident[Int(t[j])] == 0 { return j }
      j &+= 1
    }
  }

  while i < n {
    let c = t[i]
    var kind = cls[Int(c)]
    if kind == ByteClass.opener {
      if let (end, added) = opener(t, n, i, profile, out, count, &frames, &hereDocument) {
        count = added
        i = end
        continue
      }
      kind = fallback[Int(c)]
    }
    switch kind {
    case ByteClass.space:
      i &+= 1
    case ByteClass.newline:
      i &+= 1
      if hereDocument.pending {
        let end = hereDocument.bodyEnd(t, n, from: i)
        if end > i {
          out[count] = Token(.string, i, end)
          count &+= 1
          i = end
        }
        hereDocument.pending = false
      }
    case ByteClass.ident:
      let j = identifierEnd(i)
      let length = j &- i
      var tokenKind = TokenKind.identifier
      if length <= profile.maxKeyword {
        switch profile.keywordClass(t + i, length) {
        case 1: tokenKind = .keyword
        case 2: tokenKind = .declarationKeyword
        default: break
        }
      }
      out[count] = Token(tokenKind, i, j)
      count &+= 1
      i = j
    case ByteClass.digit:
      var j = i &+ 1
      while true {
        let b = t[j]
        if ident[Int(b)] != 0 {
          j &+= 1
        } else if b == 0x2E, t[j &+ 1] >= 0x30, t[j &+ 1] <= 0x39 {
          j &+= 2
        } else if b == 0x2B || b == 0x2D, t[j &- 1] | 0x20 == 0x65, t[i &+ 1] | 0x20 != 0x78 {
          j &+= 1
        } else {
          break
        }
      }
      out[count] = Token(.number, i, j)
      count &+= 1
      i = j
    case ByteClass.open:
      frames.opened()
      out[count] = Token(.open, i, i &+ 1)
      count &+= 1
      i &+= 1
    case ByteClass.close:
      if frames.closes(c) {
        out[count] = Token(.interpolationClose, i, i &+ 1)
        count &+= 1
        i &+= 1
        let frame = frames.pop()
        (i, count) = continueString(t, n, i, profile, frame.opener, frame.firstByte, out, count, &frames)
      } else {
        out[count] = Token(.close, i, i &+ 1)
        count &+= 1
        i &+= 1
      }
    case ByteClass.single:
      out[count] = Token(.punctuation, i, i &+ 1)
      count &+= 1
      i &+= 1
    case ByteClass.colon:
      let j = t[i &+ 1] == 0x3A ? i &+ 2 : i &+ 1
      out[count] = Token(.punctuation, i, j)
      count &+= 1
      i = j
    default:
      // A run of operator bytes is one token, up to anything that may start something else.
      var j = i &+ 1
      while j < n, cls[Int(t[j])] == ByteClass.punct { j &+= 1 }
      out[count] = Token(.punctuation, i, j)
      count &+= 1
      i = j
    }
  }
  return count
}

/// High bit set in each byte that isn't [A-Za-z0-9_] or at least 0x80.
@inline(__always) private func nonIdentifierMask(_ w: UInt64) -> UInt64 {
  let high = w & 0x8080_8080_8080_8080
  let low = w & 0x7F7F_7F7F_7F7F_7F7F
  let lower = low | 0x2020_2020_2020_2020
  let isAlpha = (lower &+ 0x1F1F_1F1F_1F1F_1F1F) & ~(lower &+ 0x0505_0505_0505_0505)
  let isDigit = (low &+ 0x5050_5050_5050_5050) & ~(low &+ 0x4646_4646_4646_4646)
  let isUnderscore = ~((low ^ 0x5F5F_5F5F_5F5F_5F5F) &+ 0x7F7F_7F7F_7F7F_7F7F)
  return ~(high | isAlpha | isDigit | isUnderscore) & 0x8080_8080_8080_8080
}

/// Strings that are waiting for code inside them to finish: fixed room, as nesting past it isn't real code.
private struct InterpolationFrames {
  struct Frame {
    var depth: Int32
    var closer: UInt8
    var opener: UInt16
    var firstByte: UInt8
  }
  var count = 0
  var frames: (Frame, Frame, Frame, Frame, Frame, Frame, Frame, Frame) = {
    let empty = Frame(depth: 0, closer: 0, opener: 0, firstByte: 0)
    return (empty, empty, empty, empty, empty, empty, empty, empty)
  }()

  @inline(__always) private mutating func with<R>(_ index: Int, _ body: (inout Frame) -> R) -> R {
    withUnsafeMutablePointer(to: &frames) { tuple in
      tuple.withMemoryRebound(to: Frame.self, capacity: 8) { body(&$0[index]) }
    }
  }

  @inline(__always) mutating func opened() {
    if count > 0 { with(count &- 1) { $0.depth &+= 1 } }
  }

  @inline(__always) mutating func closes(_ byte: UInt8) -> Bool {
    guard count > 0 else { return false }
    return with(count &- 1) { frame in
      if frame.depth == 0 { return frame.closer == byte }
      frame.depth &-= 1
      return false
    }
  }

  mutating func pop() -> Frame {
    count &-= 1
    return with(count) { $0 }
  }

  mutating func push(_ frame: Frame) -> Bool {
    guard count < 8 else { return false }
    with(count) { $0 = frame }
    count &+= 1
    return true
  }
}

private struct HereDocument {
  var pending = false
  var start = 0
  var length = 0
  var indented = false

  /// The offset after the line that ends the document (or the file's end).
  func bodyEnd(_ t: UnsafePointer<UInt8>, _ n: Int, from body: Int) -> Int {
    var line = body
    while line < n {
      var first = line
      if indented { while t[first] == 0x20 || t[first] == 0x09 { first &+= 1 } }
      if memcmp(t + first, t + start, length) == 0 {
        let after = t[first &+ length]
        if after == 0x0A || after == 0x0D || after == 0 || after == 0x3B { return first &+ length }
      }
      guard let found = memchr(t + line, 0x0A, n &- line) else { return n }
      line = UnsafePointer(found.assumingMemoryBound(to: UInt8.self)) - t &+ 1
    }
    return n
  }
}

@inline(__always) private func matches(_ t: UnsafePointer<UInt8>, _ i: Int, _ bytes: [UInt8]) -> Bool {
  bytes.withUnsafeBufferPointer { memcmp(t + i, $0.baseAddress!, $0.count) == 0 }
}

/// Tries what can start at `i` for a byte with openers: a comment, string, directive, attribute, regex or here-document.
/// Returns the offset after it and the new token count, or nil to scan the byte as usual.
private func opener(
  _ t: UnsafePointer<UInt8>, _ n: Int, _ i: Int, _ profile: LexProfile, _ out: UnsafeMutablePointer<Token>, _ count: Int,
  _ frames: inout InterpolationFrames, _ hereDocument: inout HereDocument
) -> (Int, Int)? {
  let c = t[i]
  let list = profile.openers[Int(c)]
  if !list.isEmpty {
    for (index, entry) in list.enumerated() where matches(t, i, entry.open) {
      // A name can run into a marker: `bar"` is a name and a quote, `r` in `for` no raw string.
      if entry.open.count > 1 || entry.kind == .rustRaw, profile.ident[Int(c)] != 0, i > 0,
        profile.ident[Int(t[i &- 1])] != 0
      {
        continue
      }
      switch entry.kind {
      case .lineComment:
        if profile.commentsNeedWordStart, i > 0, t[i &- 1] != 0x20, t[i &- 1] != 0x09, t[i &- 1] != 0x0A,
          t[i &- 1] != 0x0D
        {
          continue
        }
        let end = lineEnd(t, n, i)
        let width = entry.open.count
        // `///`, `//!`: documentation. `////...` rules aren't.
        let third = t[i &+ width]
        let isDoc =
          entry.open == [0x2F, 0x2F] && (third == 0x21 || (third == 0x2F && t[i &+ width &+ 1] != 0x2F))
        out[count] = Token(isDoc ? .docComment : .comment, i, end)
        return (end, count &+ 1)
      case .blockComment:
        let end = blockEnd(t, n, i &+ entry.open.count, entry.open, entry.close, entry.nested)
        let isDoc =
          entry.open == [0x2F, 0x2A] && t[i &+ 2] == 0x2A && t[i &+ 3] != 0x2F && t[i &+ 3] != 0x2A
        out[count] = Token(isDoc ? .docComment : .comment, i, end)
        return (end, count &+ 1)
      case .string:
        let (end, added) = continueString(
          t, n, i &+ entry.open.count, profile, UInt16(index), c, out, count, &frames, start: i)
        return (end, added)
      case .swiftRaw:
        var q = i
        while t[q] == 0x23 { q &+= 1 }
        guard t[q] == 0x22 else { continue }
        let hashes = q &- i
        let triple = t[q &+ 1] == 0x22 && t[q &+ 2] == 0x22
        let end = rawEnd(t, n, triple ? q &+ 3 : q &+ 1, quotes: triple ? 3 : 1, hashes: hashes, multiline: triple)
        out[count] = Token(.string, i, end)
        return (end, count &+ 1)
      case .rustRaw:
        var q = i
        if c == 0x62 {  // b"..", br"..", br#".."#
          if t[i &+ 1] == 0x22 { continue }
          guard t[i &+ 1] == 0x72 else { continue }
          q &+= 1
        }
        q &+= 1
        var hashes = 0
        while t[q] == 0x23 {
          q &+= 1
          hashes &+= 1
        }
        guard t[q] == 0x22 else { continue }
        let end = rawEnd(t, n, q &+ 1, quotes: 1, hashes: hashes, multiline: true)
        out[count] = Token(.string, i, end)
        return (end, count &+ 1)
      case .cppRaw:
        var open = i &+ entry.open.count
        let delimiter = open
        while t[open] != 0x28 && t[open] != 0x0A && open < n { open &+= 1 }
        guard t[open] == 0x28 else { continue }
        let close = [0x29] + Array(UnsafeBufferPointer(start: t + delimiter, count: open &- delimiter)) + [0x22]
        var j = open &+ 1
        while j < n, !matches(t, j, close) { j &+= 1 }
        let end = min(n, j &+ close.count)
        out[count] = Token(.string, i, end)
        return (end, count &+ 1)
      }
    }
  }
  switch c {
  case 0x27 where profile.charLiteral:
    // 'x', '\n', '\''; not 'a in Rust or Scala: a lifetime or symbol stays plain.
    let next = t[i &+ 1]
    if next == 0x5C {
      var j = i &+ 2
      j &+= 1
      while j < n, t[j] != 0x27, t[j] != 0x0A { j &+= 1 }
      let end = t[j] == 0x27 ? j &+ 1 : j
      out[count] = Token(.string, i, end)
      return (end, count &+ 1)
    }
    var width = 1
    if next >= 0xF0 { width = 4 } else if next >= 0xE0 { width = 3 } else if next >= 0xC0 { width = 2 }
    if t[i &+ 1 &+ width] == 0x27, next != 0x27 {
      out[count] = Token(.string, i, i &+ 2 &+ width)
      return (i &+ 2 &+ width, count &+ 1)
    }
    return nil
  case 0x23:
    if profile.rustAttributes, t[i &+ 1] == 0x5B || (t[i &+ 1] == 0x21 && t[i &+ 2] == 0x5B) {
      var j = i &+ (t[i &+ 1] == 0x5B ? 1 : 2)
      var depth = 0
      while j < n {
        if t[j] == 0x5B { depth &+= 1 } else if t[j] == 0x5D {
          depth &-= 1
          if depth == 0 {
            j &+= 1
            break
          }
        }
        j &+= 1
      }
      out[count] = Token(.attribute, i, j)
      return (j, count &+ 1)
    }
    if profile.anchoredDirectives {
      var back = i
      while back > 0, t[back &- 1] == 0x20 || t[back &- 1] == 0x09 { back &-= 1 }
      guard back == 0 || t[back &- 1] == 0x0A else { return nil }
      var end = lineEnd(t, n, i)
      while end > i, end < n, t[end &- 1] == 0x5C || (t[end &- 1] == 0x0D && t[end &- 2] == 0x5C) {
        end = lineEnd(t, n, end &+ 1)
      }
      out[count] = Token(.directive, i, end)
      return (end, count &+ 1)
    }
    if profile.freeDirectives, profile.ident[Int(t[i &+ 1])] != 0 {
      var j = i &+ 2
      while profile.ident[Int(t[j])] != 0 { j &+= 1 }
      out[count] = Token(.directive, i, j)
      return (j, count &+ 1)
    }
    return nil
  case 0x40:
    guard profile.atWords, profile.ident[Int(t[i &+ 1])] != 0 else { return nil }
    var j = i &+ 2
    while profile.ident[Int(t[j])] != 0 { j &+= 1 }
    out[count] = Token(.attribute, i, j)
    return (j, count &+ 1)
  case 0x2F where profile.regexLiterals:
    guard regexMayStart(t, i, count > 0 ? out[count &- 1] : nil) else { return nil }
    var j = i &+ 1
    var inClass = false
    while j < n {
      let b = t[j]
      if b == 0x0A { return nil }
      if b == 0x5C {
        j &+= 2
        continue
      }
      if b == 0x5B { inClass = true } else if b == 0x5D { inClass = false } else if b == 0x2F && !inClass { break }
      j &+= 1
    }
    guard j < n else { return nil }
    j &+= 1
    while profile.ident[Int(t[j])] != 0 { j &+= 1 }
    out[count] = Token(.string, i, j)
    return (j, count &+ 1)
  case 0x3C where profile.hereDocuments:
    guard t[i &+ 1] == 0x3C else { return nil }
    if i > 0, t[i &- 1] >= 0x30, t[i &- 1] <= 0x39 { return nil }
    var j = i &+ 2
    if t[j] == 0x3C { j &+= 1 }
    let indented = t[j] == 0x2D || t[j] == 0x7E
    if indented { j &+= 1 }
    let quote = t[j] == 0x22 || t[j] == 0x27 ? t[j] : 0
    if quote != 0 { j &+= 1 }
    let wordStart = j
    guard profile.ident[Int(t[j])] != 0, t[j] > 0x39 else { return nil }
    while profile.ident[Int(t[j])] != 0 { j &+= 1 }
    hereDocument = HereDocument(pending: true, start: wordStart, length: j &- wordStart, indented: indented)
    if quote != 0, t[j] == quote { j &+= 1 }
    out[count] = Token(.punctuation, i, j)
    return (j, count &+ 1)
  default:
    return nil
  }
}

/// Whether a `/` here starts a regex: not after a value or `<` (a closing tag).
private func regexMayStart(_ t: UnsafePointer<UInt8>, _ i: Int, _ previous: Token?) -> Bool {
  // `a / b`: a regex doesn't start with a space.
  if t[i &+ 1] == 0x20 || t[i &+ 1] == 0x3D { return false }
  guard let previous else { return true }
  switch previous.kind {
  case .identifier, .number, .string, .close, .interpolationClose: return false
  case .keyword, .declarationKeyword:
    // `this / 2`, but `return /x/`.
    return !(previous.length == 4 && memcmp(t + previous.start, "this", 4) == 0)
  case .punctuation:
    return t[previous.end &- 1] != 0x3C && !(previous.length == 1 && t[previous.start] == 0x2E)
  default: return true
  }
}

@inline(__always) private func lineEnd(_ t: UnsafePointer<UInt8>, _ n: Int, _ i: Int) -> Int {
  guard n > i, let found = memchr(t + i, 0x0A, n &- i) else { return n }
  var end = UnsafePointer(found.assumingMemoryBound(to: UInt8.self)) - t
  if end > i, t[end &- 1] == 0x0D { end &-= 1 }
  return end
}

private func blockEnd(
  _ t: UnsafePointer<UInt8>, _ n: Int, _ start: Int, _ open: [UInt8], _ close: [UInt8], _ nested: Bool
) -> Int {
  var i = start
  var depth = 1
  let first = close[0]
  if !nested {
    while i < n {
      guard let found = memchr(t + i, Int32(first), n &- i) else { return n }
      i = UnsafePointer(found.assumingMemoryBound(to: UInt8.self)) - t
      if matches(t, i, close) { return min(n, i &+ close.count) }
      i &+= 1
    }
    return n
  }
  let opening = open[0]
  while i < n {
    let c = t[i]
    if c == first, matches(t, i, close) {
      i &+= close.count
      depth &-= 1
      if depth == 0 { return min(n, i) }
      continue
    }
    if c == opening, matches(t, i, open) {
      depth &+= 1
      i &+= open.count
      continue
    }
    i &+= 1
  }
  return n
}

private func rawEnd(_ t: UnsafePointer<UInt8>, _ n: Int, _ start: Int, quotes: Int, hashes: Int, multiline: Bool) -> Int {
  var i = start
  while i < n {
    let c = t[i]
    if c == 0x0A, !multiline { return i }
    if c == 0x22 {
      var q = 0
      while q < quotes, t[i &+ q] == 0x22 { q &+= 1 }
      if q == quotes {
        var h = 0
        while h < hashes, t[i &+ q &+ h] == 0x23 { h &+= 1 }
        if h == hashes { return min(n, i &+ q &+ h) }
      }
    }
    i &+= 1
  }
  return n
}

/// Scans a string's text from `i`: ends at its close, its line for a single-line string, or code inside it, which the
/// caller's loop then scans. `first` and `index` name the opener, to come back when the code ends.
private func continueString(
  _ t: UnsafePointer<UInt8>, _ n: Int, _ from: Int, _ profile: LexProfile, _ index: UInt16, _ first: UInt8,
  _ out: UnsafeMutablePointer<Token>, _ count: Int, _ frames: inout InterpolationFrames, start: Int? = nil
) -> (Int, Int) {
  let entry = profile.openers[Int(first)][Int(index)]
  let begin = start ?? from
  let close = entry.close
  let closeByte = close[0]
  let escape = entry.escape
  let code = entry.interpolation >= 0 ? profile.interpolations[entry.interpolation] : nil
  let codeByte = code?.open[0] ?? 0
  var i = from
  var count = count
  // A `$(` or `${` starts with a byte that isn't the escape; `\(` with the one that is.
  while i < n {
    let c = t[i]
    if c == codeByte, let code, matches(t, i, code.open) {
      if code.doubledIsLiteral, t[i &+ code.open.count] == codeByte {
        i &+= code.open.count &+ 1
        continue
      }
      if frames.push(.init(depth: 0, closer: code.close, opener: index, firstByte: first)) {
        if i > begin {
          out[count] = Token(.string, begin, i)
          count &+= 1
        }
        out[count] = Token(.interpolationOpen, i, i &+ code.open.count)
        return (i &+ code.open.count, count &+ 1)
      }
    }
    if c == escape, escape != 0 {
      i &+= 2
      continue
    }
    if c == closeByte, matches(t, i, close) {
      let end = i &+ close.count
      out[count] = Token(.string, begin, end)
      return (end, count &+ 1)
    }
    if c == 0x0A, !entry.multiline {
      var end = i
      if end > begin, t[end &- 1] == 0x0D { end &-= 1 }
      if end > begin {
        out[count] = Token(.string, begin, end)
        count &+= 1
      }
      return (end, count)
    }
    i &+= 1
  }
  let end = min(i, n)
  if end > begin {
    out[count] = Token(.string, begin, end)
    count &+= 1
  }
  return (end, count)
}
