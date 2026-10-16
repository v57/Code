import CodeKit
import ComponentKit
import Foundation

/// A file icon for the kit's views that take an SF Symbol and a hue (tabs, path bar crumbs, Open Quickly's tiles):
/// the icon's symbol, or a document where it draws letters, in the kit hue nearest its brand color.
extension FileIcon {
  var kitSymbol: String { symbol ?? (self == .folder ? "folder" : "doc.text") }

  var kitHue: Hue? {
    if self == .folder { return .blue }
    guard let color else { return nil }
    return Self.nearestHue(color)
  }

  /// The kit hue whose color is closest to `rgb` (in hue angle, gray for unsaturated colors).
  static func nearestHue(_ rgb: UInt32) -> Hue {
    let (h, s, v) = hsv(rgb)
    if s < 0.18 || v < 0.15 { return .gray }
    let hues: [(Hue, Double)] = [
      (.red, 355), (.orange, 20), (.yellow, 48), (.green, 130), (.teal, 193), (.blue, 211), (.indigo, 241),
      (.purple, 280), (.pink, 345),
    ]
    // Dark oranges and browns read as brown.
    if h > 20, h < 45, v < 0.55 { return .brown }
    return hues.min { angle($0.1, h) < angle($1.1, h) }!.0
  }

  private static func angle(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b).truncatingRemainder(dividingBy: 360)
    return min(d, 360 - d)
  }

  private static func hsv(_ rgb: UInt32) -> (Double, Double, Double) {
    let r = Double(rgb >> 16 & 0xFF) / 255
    let g = Double(rgb >> 8 & 0xFF) / 255
    let b = Double(rgb & 0xFF) / 255
    let maxC = max(r, g, b)
    let minC = min(r, g, b)
    let delta = maxC - minC
    var h = 0.0
    if delta > 0 {
      if maxC == r {
        h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
      } else if maxC == g {
        h = 60 * ((b - r) / delta + 2)
      } else {
        h = 60 * ((r - g) / delta + 4)
      }
    }
    if h < 0 { h += 360 }
    return (h, maxC == 0 ? 0 : delta / maxC, maxC)
  }
}
