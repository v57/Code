import CodeHighlighting
import Foundation

/// A text in memory, padded for the scanner, with its tokens, line starts and symbols made on demand.
public final class SourceFile: @unchecked Sendable {
  public let profile: LexProfile
  /// The bytes, followed by `scanPadding` zeros.
  private let storage: UnsafeMutablePointer<UInt8>
  public let count: Int
  public private(set) lazy var tokens: [Token] = makeTokens()
  public private(set) lazy var lines: LineMap = LineMap(text, count)
  public private(set) lazy var symbols: FileSymbols = makeSymbols()

  public var text: UnsafePointer<UInt8> { UnsafePointer(storage) }
  public var bytes: UnsafeBufferPointer<UInt8> { UnsafeBufferPointer(start: storage, count: count) }

  public init(bytes: some Collection<UInt8>, profile: LexProfile) {
    self.profile = profile
    count = bytes.count
    storage = .allocate(capacity: count + scanPadding)
    _ = UnsafeMutableBufferPointer(start: storage, count: count).initialize(from: bytes)
    (storage + count).initialize(repeating: 0, count: scanPadding)
  }

  public convenience init(_ text: String, profile: LexProfile) { self.init(bytes: Array(text.utf8), profile: profile) }

  deinit { storage.deallocate() }

  private func makeTokens() -> [Token] {
    [Token](unsafeUninitializedCapacity: count + 8) { buffer, initialized in
      initialized = scan(text, count, profile: profile, into: buffer.baseAddress!)
    }
  }

  private func makeSymbols() -> FileSymbols {
    tokens.withUnsafeBufferPointer { extractSymbols(text: text, length: count, tokens: $0, profile: profile) }
  }

  public func string(_ token: Token) -> String {
    String(decoding: UnsafeBufferPointer(start: text + token.start, count: token.length), as: UTF8.self)
  }

  public func string(from start: Int, to end: Int) -> String {
    String(decoding: UnsafeBufferPointer(start: text + start, count: max(0, min(end, count) - start)), as: UTF8.self)
  }

  /// The index of the token at or containing `offset`, else the one that follows it.
  public func tokenIndex(at offset: Int) -> Int {
    var low = 0
    var high = tokens.count
    while low < high {
      let middle = (low + high) / 2
      if tokens[middle].end <= offset { low = middle + 1 } else { high = middle }
    }
    return low
  }

  /// The name token under `offset`, also when the cursor sits right after it.
  public func nameToken(at offset: Int) -> Int? {
    let index = tokenIndex(at: offset)
    func isName(_ i: Int) -> Bool {
      guard i >= 0, i < tokens.count else { return false }
      switch tokens[i].kind {
      case .identifier, .keyword, .declarationKeyword: return tokens[i].start <= offset && offset <= tokens[i].end
      case .attribute: return tokens[i].start <= offset && offset <= tokens[i].end
      default: return false
      }
    }
    if isName(index) { return index }
    if isName(index - 1) { return index - 1 }
    return nil
  }
}

/// Offsets to LSP's line and character, in UTF-16 or UTF-8 code units.
public struct LineMap: Sendable {
  public enum Encoding: Sendable { case utf16, utf8 }

  /// The offset each line starts at.
  public private(set) var starts: [UInt32]
  let count: Int

  public init(_ t: UnsafePointer<UInt8>, _ n: Int) {
    var starts = [UInt32]()
    starts.reserveCapacity(n / 32 + 2)
    starts.append(0)
    var i = 0
    while i < n, let found = memchr(t + i, 0x0A, n - i) {
      i = UnsafePointer(found.assumingMemoryBound(to: UInt8.self)) - t + 1
      starts.append(UInt32(i))
    }
    self.starts = starts
    count = n
  }

  public func line(of offset: Int) -> Int {
    var low = 0
    var high = starts.count
    while low + 1 < high {
      let middle = (low + high) / 2
      if Int(starts[middle]) <= offset { low = middle } else { high = middle }
    }
    return low
  }

  public func position(of offset: Int, in t: UnsafePointer<UInt8>, encoding: Encoding = .utf16) -> (line: Int, character: Int) {
    let line = line(of: offset)
    let start = Int(starts[line])
    guard encoding == .utf16 else { return (line, offset - start) }
    var character = 0
    var i = start
    while i < offset {
      let c = t[i]
      if c < 0x80 || c >= 0xC0 { character &+= c >= 0xF0 ? 2 : 1 }
      i &+= 1
    }
    return (line, character)
  }

  public func offset(line: Int, character: Int, in t: UnsafePointer<UInt8>, encoding: Encoding = .utf16) -> Int {
    guard line < starts.count else { return count }
    guard line >= 0 else { return 0 }
    let start = Int(starts[line])
    var end = line + 1 < starts.count ? Int(starts[line + 1]) : count
    // The line's terminator isn't a place inside it.
    if end > start, t[end - 1] == 0x0A { end -= 1 }
    if end > start, t[end - 1] == 0x0D { end -= 1 }
    guard encoding == .utf16 else { return min(end, start + character) }
    var units = 0
    var i = start
    while i < end, units < character {
      let c = t[i]
      if c < 0x80 {
        units &+= 1
        i &+= 1
      } else if c >= 0xF0 {
        units &+= 2
        i &+= 4
      } else if c >= 0xE0 {
        units &+= 1
        i &+= 3
      } else if c >= 0xC0 {
        units &+= 1
        i &+= 2
      } else {
        i &+= 1
      }
    }
    return min(i, end)
  }
}

extension LexProfile {
  /// The language for a file: by name and extension through `Language.detect`, and its first line otherwise.
  public static func profile(forPath path: String, firstLine: String? = nil) -> LexProfile? {
    Language.detect(url: URL(fileURLWithPath: path), firstLine: firstLine).map(profile(for:))
  }
}
