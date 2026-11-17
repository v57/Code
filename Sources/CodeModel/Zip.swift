import Foundation

/// A zip archive read in place (a JDK's `src.zip`, a `-sources.jar`, the Android SDK's `android-stubs-src.jar`): its
/// entries' names from the central directory, and an entry's bytes when asked, stored or deflated. Read-only, no
/// dependencies, the same on every platform.
package final class ZipArchive {
  package struct Entry {
    package var method: UInt16
    package var compressedSize: Int
    package var size: Int
    package var headerOffset: Int
  }

  package let path: String
  /// Entries by name, as written (`java/util/List.java`).
  package private(set) var entries: [String: Entry] = [:]
  private let data: Data

  package init?(path: String) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
    self.path = path
    self.data = data
    guard readDirectory() else { return nil }
  }

  private func readDirectory() -> Bool {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
      let bytes = raw.bindMemory(to: UInt8.self)
      let count = bytes.count
      func u16(_ at: Int) -> Int { at + 2 <= count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : 0 }
      func u32(_ at: Int) -> Int { at + 4 <= count ? u16(at) | u16(at + 2) << 16 : 0 }
      func u64(_ at: Int) -> Int { at + 8 <= count ? u32(at) | u32(at + 4) << 32 : 0 }
      // The end of central directory record: 22 bytes and a comment of up to 64 KB, read from the end.
      var end = -1
      var at = count - 22
      while at >= max(0, count - 22 - 65_535) {
        if u32(at) == 0x0605_4B50 {
          end = at
          break
        }
        at -= 1
      }
      guard end >= 0 else { return false }
      var total = u16(end + 10)
      var offset = u32(end + 16)
      // Zip64: the locator just before it points at the bigger record.
      if offset == 0xFFFF_FFFF || total == 0xFFFF, end >= 20, u32(end - 20) == 0x0706_4B50 {
        let record = u64(end - 12)
        if u32(record) == 0x0606_4B50 {
          total = u64(record + 32)
          offset = u64(record + 48)
        }
      }
      var position = offset
      entries.reserveCapacity(total)
      for _ in 0..<total {
        guard u32(position) == 0x0201_4B50 else { break }
        let method = UInt16(u16(position + 10))
        var compressed = u32(position + 20)
        var size = u32(position + 24)
        let nameLength = u16(position + 28)
        let extraLength = u16(position + 30)
        let commentLength = u16(position + 32)
        var header = u32(position + 42)
        let nameStart = position + 46
        guard nameStart + nameLength <= count else { break }
        let name = String(decoding: UnsafeBufferPointer(rebasing: bytes[nameStart..<(nameStart + nameLength)]), as: UTF8.self)
        // Zip64 sizes and offset in the extra field, in that order, for those set to all ones.
        var extra = nameStart + nameLength
        let extraEnd = extra + extraLength
        while extra + 4 <= extraEnd {
          let id = u16(extra)
          let length = u16(extra + 2)
          if id == 1 {
            var field = extra + 4
            if size == 0xFFFF_FFFF { size = u64(field); field += 8 }
            if compressed == 0xFFFF_FFFF { compressed = u64(field); field += 8 }
            if header == 0xFFFF_FFFF { header = u64(field) }
          }
          extra += 4 + length
        }
        if !name.hasSuffix("/") { entries[name] = Entry(method: method, compressedSize: compressed, size: size, headerOffset: header) }
        position = extraEnd + commentLength
      }
      return true
    }
  }

  /// An entry's bytes, nil when it's missing or written in a way this doesn't read (only stored and deflated are).
  package func contents(_ name: String) -> [UInt8]? {
    guard let entry = entries[name] else { return nil }
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [UInt8]? in
      let bytes = raw.bindMemory(to: UInt8.self)
      let at = entry.headerOffset
      guard at + 30 <= bytes.count, bytes[at] == 0x50, bytes[at + 1] == 0x4B, bytes[at + 2] == 3, bytes[at + 3] == 4 else { return nil }
      let start = at + 30 + (Int(bytes[at + 26]) | Int(bytes[at + 27]) << 8) + (Int(bytes[at + 28]) | Int(bytes[at + 29]) << 8)
      guard start + entry.compressedSize <= bytes.count else { return nil }
      let input = UnsafeBufferPointer(rebasing: bytes[start..<(start + entry.compressedSize)])
      switch entry.method {
      case 0: return Array(input)
      case 8: return Inflater.inflate(input, expected: entry.size)
      default: return nil
      }
    }
  }
}

/// RFC 1951's deflate, decoded: stored, fixed and dynamic Huffman blocks. Huffman codes are read a bit at a time
/// through canonical counts (as zlib's `puff` does): small and plain, fast enough for source files.
enum Inflater {
  private struct Huffman {
    var counts = [Int](repeating: 0, count: 16)
    var symbols: [Int]

    init(lengths: ArraySlice<Int>) {
      symbols = [Int](repeating: 0, count: lengths.count)
      for length in lengths { counts[length] += 1 }
      var offsets = [Int](repeating: 0, count: 16)
      for bits in 1..<15 { offsets[bits + 1] = offsets[bits] + counts[bits] }
      for (symbol, length) in zip(0..., lengths) where length != 0 {
        symbols[offsets[length]] = symbol
        offsets[length] += 1
      }
    }
  }

  private struct Reader {
    let input: UnsafeBufferPointer<UInt8>
    var position = 0
    var buffer = 0
    var count = 0
    var failed = false

    init(_ input: UnsafeBufferPointer<UInt8>) { self.input = input }

    mutating func bits(_ need: Int) -> Int {
      while count < need {
        guard position < input.count else {
          failed = true
          return 0
        }
        buffer |= Int(input[position]) << count
        position += 1
        count += 8
      }
      let value = buffer & ((1 << need) - 1)
      buffer >>= need
      count -= need
      return value
    }

    mutating func decode(_ code: Huffman) -> Int {
      var value = 0
      var first = 0
      var index = 0
      for length in 1..<16 {
        value |= bits(1)
        let count = code.counts[length]
        if value - count < first { return failed ? -1 : code.symbols[index + (value - first)] }
        index += count
        first += count
        first <<= 1
        value <<= 1
      }
      return -1
    }
  }

  private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
  private static let distanceBase = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
  ]
  private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
  private static let fixed: (Huffman, Huffman) = {
    var lengths = [Int](repeating: 8, count: 288)
    for i in 144..<256 { lengths[i] = 9 }
    for i in 256..<280 { lengths[i] = 7 }
    return (Huffman(lengths: lengths[...]), Huffman(lengths: [Int](repeating: 5, count: 30)[...]))
  }()

  static func inflate(_ input: UnsafeBufferPointer<UInt8>, expected: Int) -> [UInt8]? {
    var out: [UInt8] = []
    out.reserveCapacity(expected)
    var reader = Reader(input)
    var last = 0
    repeat {
      last = reader.bits(1)
      let type = reader.bits(2)
      switch type {
      case 0:
        reader.buffer = 0
        reader.count = 0
        let at = reader.position
        guard at + 4 <= input.count else { return nil }
        let length = Int(input[at]) | Int(input[at + 1]) << 8
        guard at + 4 + length <= input.count else { return nil }
        out.append(contentsOf: UnsafeBufferPointer(rebasing: input[(at + 4)..<(at + 4 + length)]))
        reader.position = at + 4 + length
      case 1:
        guard codes(&reader, &out, fixed.0, fixed.1) else { return nil }
      case 2:
        let literals = reader.bits(5) + 257
        let distances = reader.bits(5) + 1
        let lengthCodes = reader.bits(4) + 4
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var lengths = [Int](repeating: 0, count: 320)
        for i in 0..<lengthCodes { lengths[order[i]] = reader.bits(3) }
        let lengthCode = Huffman(lengths: lengths[0..<19])
        var i = 0
        while i < literals + distances {
          let symbol = reader.decode(lengthCode)
          if symbol < 0 { return nil }
          if symbol < 16 {
            lengths[i] = symbol
            i += 1
            continue
          }
          var repeated = 0
          var times = 0
          if symbol == 16 {
            guard i > 0 else { return nil }
            repeated = lengths[i - 1]
            times = 3 + reader.bits(2)
          } else if symbol == 17 {
            times = 3 + reader.bits(3)
          } else {
            times = 11 + reader.bits(7)
          }
          guard i + times <= literals + distances else { return nil }
          for _ in 0..<times {
            lengths[i] = repeated
            i += 1
          }
        }
        let literal = Huffman(lengths: lengths[0..<literals])
        let distance = Huffman(lengths: lengths[literals..<(literals + distances)])
        guard codes(&reader, &out, literal, distance) else { return nil }
      default:
        return nil
      }
      if reader.failed { return nil }
    } while last == 0
    return out
  }

  private static func codes(_ reader: inout Reader, _ out: inout [UInt8], _ literal: Huffman, _ distance: Huffman) -> Bool {
    while true {
      let symbol = reader.decode(literal)
      if symbol < 0 || reader.failed { return false }
      if symbol < 256 {
        out.append(UInt8(symbol))
        continue
      }
      if symbol == 256 { return true }
      let index = symbol - 257
      guard index < 29 else { return false }
      let length = lengthBase[index] + reader.bits(lengthExtra[index])
      let code = reader.decode(distance)
      guard code >= 0, code < 30 else { return false }
      let back = distanceBase[code] + reader.bits(distanceExtra[code])
      guard back <= out.count else { return false }
      let from = out.count - back
      for k in 0..<length { out.append(out[from + k]) }
    }
  }
}
