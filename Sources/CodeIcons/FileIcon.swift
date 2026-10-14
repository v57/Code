import Foundation

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

/// A file's icon: an SF Symbol where one fits (a gear for settings, a lock for
/// lockfiles, the Swift bird), otherwise one to three letters ("PY", "C++"),
/// in the language's color. Where the symbol is missing (an older system, or
/// a platform without SF Symbols) the letters stand in for it.
public struct FileIcon: Hashable, Sendable, Identifiable {
  public let name: String
  public var id: String { name }

  /// The icon with this name ("swift", "folder", "package-npm"), or nil when
  /// there's none.
  public init?(named name: String) {
    guard Self.catalog[name] != nil else { return nil }
    self.name = name
  }

  private init(known name: String) { self.name = name }

  public init(for url: URL, isDirectory: Bool = false) {
    self.init(fileName: url.lastPathComponent, isDirectory: isDirectory)
  }

  public init(fileName: String, isDirectory: Bool = false) {
    self.init(known: Self.resolve(fileName.lowercased(), isDirectory: isDirectory))
  }

  public static let folder = FileIcon(known: "folder")
  public static let file = FileIcon(known: "file")

  /// Every icon, by name.
  public static var all: [FileIcon] { catalog.keys.sorted().map(FileIcon.init(known:)) }

  private var look: Look { Self.catalog[name] ?? Self.catalog["file"]! }

  /// The SF Symbol to draw, or nil to draw `letters`: the icon has none, or
  /// this system lacks it.
  public var symbol: String? {
    guard let symbol = look.symbol, Self.availableSymbols.contains(symbol) else { return nil }
    return symbol
  }

  /// One to three letters, drawn when there's no symbol.
  public var letters: String { look.letters }

  /// 0xRRGGBB, or nil for the secondary label color. Brand colors as they
  /// are: `FileIconView` adjusts them for contrast in light and dark.
  public var color: UInt32? { look.color }

  // MARK: - Icons

  struct Look: Sendable {
    let symbol: String?
    let letters: String
    let color: UInt32?

    static func symbol(_ symbol: String, _ letters: String, _ color: UInt32? = nil) -> Look {
      Look(symbol: symbol, letters: letters, color: color)
    }

    static func letters(_ letters: String, _ color: UInt32? = nil) -> Look {
      Look(symbol: nil, letters: letters, color: color)
    }
  }

  static let catalog: [String: Look] = [
    // Languages
    "swift": .symbol("swift", "SW", 0xF05138), "c": .letters("C", 0x5C6BC0),
    "cpp": .letters("C++", 0x00599C), "header": .letters("H", 0x8E6CC0),
    "objc": .letters("OC", 0x3D7FD9), "csharp": .letters("C#", 0x68217A),
    "go": .letters("GO", 0x00ADD8), "rust": .letters("RS", 0xCE5A2B),
    "java": .symbol("cup.and.saucer.fill", "JV", 0xE76F00), "kotlin": .letters("KT", 0x7F52FF),
    "dart": .letters("DT", 0x0175C2), "scala": .letters("SC", 0xDC322F),
    "php": .letters("PHP", 0x777BB4), "javascript": .letters("JS", 0xF7DF1E),
    "typescript": .letters("TS", 0x3178C6), "react": .symbol("atom", "JSX", 0x149ECA),
    "react-ts": .symbol("atom", "TSX", 0x3178C6), "python": .letters("PY", 0x3776AB),
    "ruby": .letters("RB", 0xCC342D), "lua": .letters("LUA", 0x000080),
    "perl": .letters("PL", 0x39457E), "shell": .symbol("terminal", "SH"),
    "powershell": .symbol("terminal", "PS", 0x2B5797),
    "sql": .symbol("cylinder.split.1x2", "SQL", 0xE38C00),
    "html": .symbol("chevron.left.forwardslash.chevron.right", "HTM", 0xE34F26),
    "css": .letters("CSS", 0x663399), "sass": .letters("S", 0xCD6799),
    "less": .letters("L", 0x1D365D), "vue": .letters("V", 0x41B883),
    "svelte": .letters("S", 0xFF3E00), "elixir": .letters("EX", 0x6E4A7E),
    "erlang": .letters("ER", 0xA90533), "haskell": .letters("λ", 0x5E5086),
    "ocaml": .letters("ML", 0xEC6813), "fsharp": .letters("F#", 0x378BBA),
    "clojure": .letters("CLJ", 0x5881D8), "elm": .letters("ELM", 0x1293D8),
    "zig": .letters("Z", 0xF7A41D), "r": .letters("R", 0x276DC3), "julia": .letters("JL", 0x9558B2),
    "nim": .letters("NIM", 0xC9A227), "groovy": .letters("GR", 0x4298B8),
    "assembly": .letters("ASM", 0x6E4C13), "graphql": .letters("GQL", 0xE10098),
    "proto": .letters("PB", 0x4A7EBB), "terraform": .letters("TF", 0x7B42BC),
    "nix": .letters("NIX", 0x5277C3), "vim": .letters("VIM", 0x019733),
    "wasm": .letters("WA", 0x654FF0),
    // Data and documents
    "json": .symbol("curlybraces", "{}", 0xCB9B12), "yaml": .letters("YML", 0xCB171E),
    "toml": .letters("TML", 0x9C4221),
    "xml": .symbol("chevron.left.forwardslash.chevron.right", "XML", 0x0060AC),
    "plist": .symbol("list.bullet.rectangle", "PL"), "config": .symbol("gearshape", "CFG"),
    "env": .symbol("key", "ENV", 0xD69E2E), "lock": .symbol("lock", "LCK"),
    "csv": .symbol("tablecells", "CSV", 0x217346), "markdown": .letters("MD", 0x0B7EC8),
    "text": .symbol("doc.plaintext", "TXT"), "log": .symbol("text.alignleft", "LOG"),
    "pdf": .letters("PDF", 0xE5252A), "image": .symbol("photo", "IMG", 0x2BA84A),
    "svg": .letters("SVG", 0xFFB13B), "font": .symbol("textformat", "FNT", 0xA0522D),
    "audio": .symbol("waveform", "AUD", 0xE91E63), "video": .symbol("film", "VID", 0x7C3AED),
    "archive": .symbol("doc.zipper", "ZIP", 0xA16207), "binary": .letters("BIN"),
    "database": .symbol("cylinder", "DB", 0x0F80CC),
    "certificate": .symbol("checkmark.seal", "CRT", 0xB7791F),
    // Apple
    "xcode": .symbol("hammer.fill", "XC", 0x147EFB),
    "assets": .symbol("photo.on.rectangle.angled", "AST", 0x147EFB),
    "xcconfig": .symbol("gearshape", "CFG", 0x147EFB), "strings": .symbol("globe", "STR", 0x0EA5E9),
    "entitlements": .symbol("checkmark.shield", "ENT"),
    "interface": .symbol("macwindow", "IB", 0x147EFB),
    // Project files
    "package-swift": .symbol("shippingbox.fill", "PKG", 0xF05138),
    "package-npm": .symbol("shippingbox.fill", "NPM", 0xCB3837),
    "package-cargo": .symbol("shippingbox.fill", "PKG", 0xCE5A2B),
    "package-go": .symbol("shippingbox.fill", "MOD", 0x00ADD8),
    "package-ruby": .symbol("shippingbox.fill", "GEM", 0xCC342D),
    "package-dart": .symbol("shippingbox.fill", "PUB", 0x0175C2),
    "package-python": .symbol("shippingbox.fill", "PKG", 0x3776AB),
    "package-gradle": .symbol("shippingbox.fill", "GR", 0x02303A),
    "package-cocoapods": .symbol("shippingbox.fill", "POD", 0xEE3322),
    "docker": .symbol("cube.fill", "DK", 0x2496ED), "make": .symbol("hammer", "MK"),
    "cmake": .symbol("hammer", "CM", 0x064F8C),
    "git": .symbol("arrow.triangle.branch", "GIT", 0xF05033),
    "readme": .symbol("book.closed", "RD", 0x0EA5E9), "license": .symbol("scroll", "LIC", 0xB7791F),
    "folder": .symbol("folder.fill", "DIR", 0x5C8CD1), "file": .symbol("doc", "DOC"),
  ]

  /// The catalog's symbols this system has, looked up once.
  static let availableSymbols: Set<String> = Set(catalog.values.compactMap(\.symbol)).filter {
    #if canImport(AppKit)
      NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
    #elseif canImport(UIKit)
      UIImage(systemName: $0) != nil
    #else
      false
    #endif
  }
}
