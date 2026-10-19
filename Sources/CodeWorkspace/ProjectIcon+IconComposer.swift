import Foundation

#if canImport(ImageIO) && canImport(CoreGraphics)
  import CoreGraphics
  import ImageIO

  /// A flat picture of an Icon Composer bundle (`AppIcon.icon`: `icon.json` and its `Assets`): the background fill
  /// on a 1024-point square, then each group's layers, placed by their positions and tinted by their fills. Glass,
  /// shadows, blur and blend modes are left out.
  extension ProjectIcon {
    /// The canvas of an Icon Composer icon, in points.
    static let iconCanvas: CGFloat = 1024

    /// Whether `file` is the `icon.json` of an Icon Composer bundle, which `find` returns for one (the vault hashes
    /// a file, not a folder).
    static func isIconComposerFile(_ file: URL) -> Bool {
      file.lastPathComponent == "icon.json"
        && file.deletingLastPathComponent().pathExtension == "icon"
    }

    /// The icon `icon.json` describes, drawn `side` pixels square; nil when it isn't one.
    static func renderIconComposer(_ file: URL, side: Int) -> CGImage? {
      guard let data = try? Data(contentsOf: file),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let context = CGContext(
          data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      let assets = file.deletingLastPathComponent().appendingPathComponent("Assets")
      context.interpolationQuality = .high
      // Points from the top left, as Icon Composer places layers.
      let scale = CGFloat(side) / iconCanvas
      context.translateBy(x: 0, y: CGFloat(side))
      context.scaleBy(x: scale, y: -scale)
      let canvas = CGRect(x: 0, y: 0, width: iconCanvas, height: iconCanvas)
      let background = IconFill(json, key: "fill") ?? .system(dark: false)
      background.paint(canvas, in: context)

      var images: [String: IconLayerImage] = [:]
      // The first group and layer are in front.
      for group in (json["groups"] as? [[String: Any]] ?? []).reversed()
      where group["hidden"] as? Bool != true {
        let (groupScale, groupOffset) = position(group)
        context.saveGState()
        context.setAlpha(number(group["opacity"]) ?? 1)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        for layer in (group["layers"] as? [[String: Any]] ?? []).reversed()
        where layer["hidden"] as? Bool != true {
          guard let name = layer["image-name"] as? String else { continue }
          if images[name] == nil {
            images[name] = IconLayerImage(assets.appendingPathComponent(name))
          }
          guard let image = images[name] else { continue }
          let (layerScale, layerOffset) = position(layer)
          let size = CGSize(
            width: image.size.width * groupScale * layerScale,
            height: image.size.height * groupScale * layerScale)
          let center = CGPoint(
            x: iconCanvas / 2 + groupOffset.x + layerOffset.x * groupScale,
            y: iconCanvas / 2 + groupOffset.y + layerOffset.y * groupScale)
          let frame = CGRect(
            x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width,
            height: size.height)
          context.saveGState()
          context.setAlpha(number(layer["opacity"]) ?? 1)
          context.beginTransparencyLayer(auxiliaryInfo: nil)
          image.draw(in: frame, context: context)
          if let fill = IconFill(layer, key: "fill") {
            // The fill takes the image's shape.
            context.setBlendMode(.sourceIn)
            fill.paint(frame, in: context)
          }
          context.endTransparencyLayer()
          context.restoreGState()
        }
        context.endTransparencyLayer()
        context.restoreGState()
      }
      return context.makeImage()
    }

    /// A `position`'s scale and translation, in points.
    static func position(_ object: [String: Any]) -> (scale: CGFloat, offset: CGPoint) {
      let position = object["position"] as? [String: Any]
      let translation = (position?["translation-in-points"] as? [Any])?.compactMap(number) ?? []
      return (
        number(position?["scale"]) ?? 1,
        translation.count == 2 ? CGPoint(x: translation[0], y: translation[1]) : .zero
      )
    }

    static func number(_ value: Any?) -> CGFloat? {
      (value as? NSNumber).map { CGFloat($0.doubleValue) }
    }
  }

  /// A layer's picture: a bitmap (its pixels are points) or an SVG.
  enum IconLayerImage {
    case bitmap(CGImage)
    case svg(SVGImage)

    init?(_ url: URL) {
      if url.pathExtension.lowercased() == "svg" {
        guard let svg = SVGImage(contentsOf: url) else { return nil }
        self = .svg(svg)
      } else {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        self = .bitmap(image)
      }
    }

    var size: CGSize {
      switch self {
      case .bitmap(let image): CGSize(width: image.width, height: image.height)
      case .svg(let svg): svg.size
      }
    }

    /// Draws it into `frame` of a context whose y axis points down.
    func draw(in frame: CGRect, context: CGContext) {
      context.saveGState()
      switch self {
      case .bitmap(let image):
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: frame.size))
      case .svg(let svg): svg.draw(in: frame, context: context)
      }
      context.restoreGState()
    }
  }

  /// An Icon Composer fill: a colour, the gradient it makes of one, or the system's light or dark background.
  enum IconFill {
    case solid(CGColor)
    case gradient(CGColor, CGColor, start: CGPoint, end: CGPoint)
    case system(dark: Bool)

    /// The fill under `key` of `object`, or of its `<key>-specializations` (the default or light appearance's; with
    /// only dark and tinted ones, the light appearance has none).
    init?(_ object: [String: Any], key: String) {
      var value = object[key]
      if value == nil, let specializations = object[key + "-specializations"] as? [[String: Any]] {
        let chosen =
          specializations.first { $0["appearance"] == nil }
          ?? specializations.first { $0["appearance"] as? String == "light" }
        value = chosen?["value"]
      }
      if let name = value as? String {
        guard name.hasPrefix("system-") else { return nil }
        self = .system(dark: name == "system-dark")
      } else if let fill = value as? [String: Any] {
        if let color = (fill["solid"] as? String).flatMap(Self.color) {
          self = .solid(color)
        } else if let color = (fill["automatic-gradient"] as? String).flatMap(Self.color) {
          self = .gradient(
            Self.lighter(color), color, start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 1))
        } else if let colors = (fill["linear-gradient"] as? [String])?.compactMap(Self.color),
          colors.count >= 2
        {
          let orientation = fill["orientation"] as? [String: Any]
          func point(_ key: String, _ fallback: CGPoint) -> CGPoint {
            guard let point = orientation?[key] as? [String: Any],
              let x = ProjectIcon.number(point["x"]), let y = ProjectIcon.number(point["y"])
            else { return fallback }
            return CGPoint(x: x, y: y)
          }
          self = .gradient(
            colors[0], colors[colors.count - 1], start: point("start", CGPoint(x: 0.5, y: 0)),
            end: point("stop", CGPoint(x: 0.5, y: 1)))
        } else {
          return nil
        }
      } else {
        return nil
      }
    }

    /// Fills `rect`; a gradient runs between points given as fractions of it.
    func paint(_ rect: CGRect, in context: CGContext) {
      switch self {
      case .solid(let color):
        context.setFillColor(color)
        context.fill(rect)
      case .gradient(let first, let last, let start, let end):
        Self.draw(first, last, from: start, to: end, in: rect, context: context)
      case .system(let dark):
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let top = CGColor(
          colorSpace: sRGB, components: dark ? [0.24, 0.24, 0.26, 1] : [1, 1, 1, 1])!
        let bottom = CGColor(
          colorSpace: sRGB, components: dark ? [0.07, 0.07, 0.08, 1] : [0.87, 0.87, 0.89, 1])!
        Self.draw(
          top, bottom, from: CGPoint(x: 0.5, y: 0), to: CGPoint(x: 0.5, y: 1), in: rect,
          context: context)
      }
    }

    static func draw(
      _ first: CGColor, _ last: CGColor, from start: CGPoint, to end: CGPoint, in rect: CGRect,
      context: CGContext
    ) {
      guard
        let gradient = CGGradient(
          colorsSpace: CGColorSpace(name: CGColorSpace.extendedSRGB),
          colors: [first, last] as CFArray, locations: [0, 1])
      else { return }
      context.saveGState()
      context.clip(to: rect)
      context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX + start.x * rect.width, y: rect.minY + start.y * rect.height),
        end: CGPoint(x: rect.minX + end.x * rect.width, y: rect.minY + end.y * rect.height),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
      context.restoreGState()
    }

    /// A colour as Icon Composer writes it: `srgb:r,g,b,a`, `extended-srgb:…`, `display-p3:…`, `gray:w,a` or
    /// `extended-gray:w,a`.
    static func color(_ text: String) -> CGColor? {
      let parts = text.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { return nil }
      let components = parts[1].split(separator: ",").compactMap {
        Double($0.trimmingCharacters(in: .whitespaces))
      }.map { CGFloat($0) }
      let space: CFString
      switch parts[0] {
      case "srgb": space = CGColorSpace.sRGB
      case "extended-srgb": space = CGColorSpace.extendedSRGB
      case "display-p3": space = CGColorSpace.displayP3
      case "gray": space = CGColorSpace.genericGrayGamma2_2
      case "extended-gray": space = CGColorSpace.extendedGray
      default: return nil
      }
      guard let colorSpace = CGColorSpace(name: space),
        components.count == colorSpace.numberOfComponents + 1
      else { return nil }
      return CGColor(colorSpace: colorSpace, components: components)
    }

    /// The top of an automatic gradient: `color` a little toward white.
    static func lighter(_ color: CGColor) -> CGColor {
      guard let space = color.colorSpace, let components = color.components, !components.isEmpty
      else { return color }
      var lighter = components
      for index in 0..<(components.count - 1) { lighter[index] += (1 - lighter[index]) * 0.25 }
      return CGColor(colorSpace: space, components: lighter) ?? color
    }
  }
#endif
