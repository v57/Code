import SwiftUI

/// A file's icon: its SF Symbol, or its letters, in its color. It takes
/// `size` × 1.25 by `size`.
///
///     FileIconView(for: url, isDirectory: node.isDirectory)
///     FileIconView(.folder, size: 14)
public struct FileIconView: View {
  private let icon: FileIcon
  private let size: CGFloat
  @Environment(\.colorScheme) private var colorScheme

  public init(_ icon: FileIcon, size: CGFloat = 16) {
    self.icon = icon
    self.size = size
  }

  public init(for url: URL, isDirectory: Bool = false, size: CGFloat = 16) {
    self.init(FileIcon(for: url, isDirectory: isDirectory), size: size)
  }

  public var body: some View {
    Group {
      if let symbol = icon.symbol {
        // The scale is fixed: a sidebar's Label would draw symbols large.
        Image(systemName: symbol)
          .font(.system(size: size * 0.8))
          .imageScale(.medium)
      } else {
        let letters = icon.letters
        let scale = letters.count == 1 ? 0.9 : letters.count == 2 ? 0.72 : 0.64
        Text(letters)
          .font(.system(size: size * scale, weight: .heavy, design: .rounded))
          .fontWidth(letters.count >= 3 ? .condensed : .standard)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
      }
    }
    .foregroundStyle(tint)
    // A little wider than tall, so three letters fit at a readable size;
    // every icon takes the same width, so names stay aligned.
    .frame(width: size * 1.25, height: size)
    .accessibilityHidden(true)
  }

  private var tint: AnyShapeStyle {
    guard let color = icon.color else { return AnyShapeStyle(.secondary) }
    let rgb = FileIconColor.readable(color, onDark: colorScheme == .dark)
    return AnyShapeStyle(
      Color(
        .sRGB, red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255,
        blue: Double(rgb & 0xFF) / 255))
  }
}

/// Brand colors made readable on the sidebar: a light color (JavaScript's
/// yellow) darkened on a light background, a dark one (Lua's navy) lightened
/// on a dark background, by mixing with black or white.
enum FileIconColor {
  static func readable(_ rgb: UInt32, onDark: Bool) -> UInt32 {
    var color = rgb
    for _ in 0..<10 {
      let lum = luminance(color)
      if onDark ? lum >= 0.13 : lum <= 0.32 { break }
      color = mix(color, with: onDark ? 0xFFFFFF : 0x000000, amount: 0.12)
    }
    return color
  }

  /// WCAG relative luminance.
  static func luminance(_ rgb: UInt32) -> Double {
    func linear(_ channel: UInt32) -> Double {
      let c = Double(channel) / 255
      return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(rgb >> 16 & 0xFF) + 0.7152 * linear(rgb >> 8 & 0xFF) + 0.0722
      * linear(rgb & 0xFF)
  }

  private static func mix(_ a: UInt32, with b: UInt32, amount: Double) -> UInt32 {
    var out: UInt32 = 0
    for shift: UInt32 in [16, 8, 0] {
      let x = Double(a >> shift & 0xFF)
      let y = Double(b >> shift & 0xFF)
      out |= UInt32((x + (y - x) * amount).rounded()) << shift
    }
    return out
  }
}
