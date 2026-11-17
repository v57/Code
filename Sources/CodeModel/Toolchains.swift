import Foundation

/// What the layouts share about the toolchains installed on this machine.
public enum Toolchains {
  /// Folder names of installed versions, newest first: `3.13` before `3.9`, `jdk-21.jdk` before `jdk1.8.0_292.jdk`,
  /// `ruby-3.10.0` before `ruby-3.3.0`. Each name's version is its first run of digits and dots, compared part by part
  /// as numbers; names without one come last. Equal versions keep a string order, descending, as before.
  public static func newestFirst<S: Sequence>(_ names: S) -> [String] where S.Element == String {
    names.map { (name: $0, version: version(of: $0)) }
      .sorted { a, b in
        switch (a.version, b.version) {
        case (nil, nil): return a.name > b.name
        case (nil, _): return false
        case (_, nil): return true
        case (let x?, let y?):
          for k in 0..<max(x.count, y.count) {
            let p = k < x.count ? x[k] : -1
            let q = k < y.count ? y[k] : -1
            if p != q { return p > q }
          }
          return a.name > b.name
        }
      }
      .map(\.name)
  }

  /// Paths with versions in them, newest first: compared as text, descending, but each run of digits as a number,
  /// so `…/guava/33.0.0/…` comes before `…/guava/9.0/…` (Gradle's and Maven's caches).
  public static func newestPathsFirst<S: Sequence>(_ paths: S) -> [String] where S.Element == String {
    paths.sorted { naturalOrder($0, $1) > 0 }
  }

  /// -1, 0 or 1: text order, with runs of digits compared as numbers.
  static func naturalOrder(_ a: String, _ b: String) -> Int {
    let x = Array(a.utf8)
    let y = Array(b.utf8)
    func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    var i = 0
    var j = 0
    while i < x.count, j < y.count {
      if isDigit(x[i]), isDigit(y[j]) {
        var i2 = i
        var j2 = j
        while i2 < x.count, isDigit(x[i2]) { i2 += 1 }
        while j2 < y.count, isDigit(y[j2]) { j2 += 1 }
        // Leading zeros don't count; then the longer run is bigger, else the first different digit decides.
        var p = i
        var q = j
        while p < i2 - 1, x[p] == 0x30 { p += 1 }
        while q < j2 - 1, y[q] == 0x30 { q += 1 }
        if i2 - p != j2 - q { return i2 - p < j2 - q ? -1 : 1 }
        while p < i2 {
          if x[p] != y[q] { return x[p] < y[q] ? -1 : 1 }
          p += 1
          q += 1
        }
        i = i2
        j = j2
      } else {
        if x[i] != y[j] { return x[i] < y[j] ? -1 : 1 }
        i += 1
        j += 1
      }
    }
    if x.count - i != y.count - j { return x.count - i < y.count - j ? -1 : 1 }
    return a < b ? -1 : a > b ? 1 : 0
  }

  /// The numbers of a name's first version-like run (`python3.13` → 3, 13; `jdk1.8.0_292` → 1, 8, 0).
  static func version(of name: String) -> [Int]? {
    var parts: [Int] = []
    var current: Int?
    for byte in name.utf8 {
      if byte >= 0x30, byte <= 0x39 {
        let digit = Int(byte - 0x30)
        current = (current ?? 0) &* 10 &+ digit
      } else if byte == 0x2E, let value = current {
        parts.append(value)
        current = nil
      } else if current != nil || !parts.isEmpty {
        break
      }
    }
    if let current { parts.append(current) }
    return parts.isEmpty ? nil : parts
  }
}
