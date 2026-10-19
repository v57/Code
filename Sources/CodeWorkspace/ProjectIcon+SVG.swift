import Foundation

#if canImport(CoreGraphics)
  import CoreGraphics

  /// The filled shapes of a simple SVG, as Icon Composer layers and SF Symbol exports are: paths, rectangles,
  /// circles, ellipses and polygons with their fills, opacities and transforms, nested in groups. Strokes,
  /// gradients, masks, text and references are left out.
  struct SVGImage {
    struct Shape {
      var path: CGPath
      var color: CGColor
      var evenOdd: Bool
    }

    /// The part of the SVG's coordinates it shows, and its size in points.
    var viewBox: CGRect
    var size: CGSize
    var shapes: [Shape]

    init?(contentsOf url: URL) {
      guard let data = try? Data(contentsOf: url) else { return nil }
      self.init(data: data)
    }

    init?(data: Data) {
      let reader = SVGReader()
      let parser = XMLParser(data: data)
      parser.delegate = reader
      guard parser.parse(), let root = reader.root, !reader.shapes.isEmpty else { return nil }
      shapes = reader.shapes
      let width = root["width"].flatMap(Self.length)
      let height = root["height"].flatMap(Self.length)
      let box = root["viewBox"].map(Self.numbers) ?? []
      if box.count == 4, box[2] > 0, box[3] > 0 {
        viewBox = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
      } else if let width, let height {
        viewBox = CGRect(x: 0, y: 0, width: width, height: height)
      } else {
        // No size: as big as what it draws.
        viewBox = shapes.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
      }
      guard !viewBox.isNull, viewBox.width > 0, viewBox.height > 0 else { return nil }
      size = CGSize(width: width ?? viewBox.width, height: height ?? viewBox.height)
    }

    /// Draws the shapes so the view box fills `frame` (of a context whose y axis points down).
    func draw(in frame: CGRect, context: CGContext) {
      context.translateBy(x: frame.minX, y: frame.minY)
      context.scaleBy(x: frame.width / viewBox.width, y: frame.height / viewBox.height)
      context.translateBy(x: -viewBox.minX, y: -viewBox.minY)
      for shape in shapes {
        context.addPath(shape.path)
        context.setFillColor(shape.color)
        context.fillPath(using: shape.evenOdd ? .evenOdd : .winding)
      }
    }

    // MARK: - Values

    static func length(_ text: String) -> CGFloat? {
      let number = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(
        of: "px", with: "")
      return Double(number).map { CGFloat($0) }
    }

    /// The numbers in a list such as `0 0 24 24`, `1,2` or `3-4`.
    static func numbers(_ text: String) -> [CGFloat] {
      var scanner = PathScanner(text)
      var numbers: [CGFloat] = []
      while let number = scanner.number() { numbers.append(number) }
      return numbers
    }

    /// `#rgb`, `#rrggbb`, `rgb(r, g, b)`, `black` or `white`; nil for `none`. Anything else (a named colour, a
    /// gradient) is black, which a tinted layer doesn't show anyway.
    static func color(_ text: String) -> CGColor?? {
      let text = text.trimmingCharacters(in: .whitespaces).lowercased()
      let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
      func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor? {
        CGColor(colorSpace: sRGB, components: [r, g, b, 1])
      }
      if text == "none" || text == "transparent" { return .some(nil) }
      if text == "white" { return rgb(1, 1, 1) }
      if text.hasPrefix("#") {
        var hex = String(text.dropFirst())
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        if hex.count == 6, let value = UInt32(hex, radix: 16) {
          return rgb(
            CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255,
            CGFloat(value & 0xFF) / 255)
        }
      }
      if text.hasPrefix("rgb(") {
        let values = numbers(String(text.dropFirst(4).dropLast()))
        if values.count >= 3 { return rgb(values[0] / 255, values[1] / 255, values[2] / 255) }
      }
      return rgb(0, 0, 0)
    }

    /// An SVG `transform` list, applied right to left.
    static func transform(_ text: String) -> CGAffineTransform {
      var result = CGAffineTransform.identity
      for item in text.split(separator: ")") {
        let parts = item.split(separator: "(", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let name = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n"))
        let values = numbers(String(parts[1]))
        let transform: CGAffineTransform
        switch (name, values.count) {
        case ("matrix", 6):
          transform = CGAffineTransform(
            a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
        case ("translate", 1...):
          transform = CGAffineTransform(
            translationX: values[0], y: values.count > 1 ? values[1] : 0)
        case ("scale", 1...):
          transform = CGAffineTransform(
            scaleX: values[0], y: values.count > 1 ? values[1] : values[0])
        case ("rotate", 1...):
          let rotation = CGAffineTransform(rotationAngle: values[0] * .pi / 180)
          if values.count == 3 {
            transform = CGAffineTransform(translationX: -values[1], y: -values[2]).concatenating(
              rotation
            ).concatenating(CGAffineTransform(translationX: values[1], y: values[2]))
          } else {
            transform = rotation
          }
        default: continue
        }
        result = transform.concatenating(result)
      }
      return result
    }

    // MARK: - Path data

    /// The path an SVG `d` attribute describes; what follows a malformed command is left out.
    static func path(_ data: String) -> CGPath {
      let path = CGMutablePath()
      var scanner = PathScanner(data)
      var command: Character = "M"
      var current = CGPoint.zero
      var start = CGPoint.zero
      var lastControl: CGPoint?
      var lastCommand: Character = " "
      while true {
        if let next = scanner.command() { command = next } else if scanner.isAtEnd { break }
        let relative = command.isLowercase
        let origin = relative ? current : .zero
        func point() -> CGPoint? {
          guard let x = scanner.number(), let y = scanner.number() else { return nil }
          return CGPoint(x: origin.x + x, y: origin.y + y)
        }
        var control: CGPoint?
        switch command.uppercased().first! {
        case "M":
          guard let to = point() else { return path }
          path.move(to: to)
          current = to
          start = to
          // More pairs after a move are lines.
          command = relative ? "l" : "L"
        case "L":
          guard let to = point() else { return path }
          path.addLine(to: to)
          current = to
        case "H":
          guard let x = scanner.number() else { return path }
          current = CGPoint(x: relative ? current.x + x : x, y: current.y)
          path.addLine(to: current)
        case "V":
          guard let y = scanner.number() else { return path }
          current = CGPoint(x: current.x, y: relative ? current.y + y : y)
          path.addLine(to: current)
        case "C":
          guard let first = point(), let second = point(), let to = point() else { return path }
          path.addCurve(to: to, control1: first, control2: second)
          control = second
          current = to
        case "S":
          let first = "CS".contains(lastCommand) ? reflect(lastControl, around: current) : current
          guard let second = point(), let to = point() else { return path }
          path.addCurve(to: to, control1: first, control2: second)
          control = second
          current = to
        case "Q":
          guard let first = point(), let to = point() else { return path }
          path.addQuadCurve(to: to, control: first)
          control = first
          current = to
        case "T":
          let first = "QT".contains(lastCommand) ? reflect(lastControl, around: current) : current
          guard let to = point() else { return path }
          path.addQuadCurve(to: to, control: first)
          control = first
          current = to
        case "A":
          guard let rx = scanner.number(), let ry = scanner.number(), let angle = scanner.number(),
            let large = scanner.flag(), let sweep = scanner.flag(), let to = point()
          else { return path }
          addArc(
            to: path, from: current, to: to, radii: CGSize(width: rx, height: ry), angle: angle,
            large: large, sweep: sweep)
          current = to
        case "Z":
          path.closeSubpath()
          current = start
          // A command must follow.
          guard let next = scanner.command() else { return path }
          command = next
          lastCommand = "Z"
          continue
        default: return path
        }
        lastControl = control
        lastCommand = Character(command.uppercased())
      }
      return path
    }

    static func reflect(_ point: CGPoint?, around center: CGPoint) -> CGPoint {
      guard let point else { return center }
      return CGPoint(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }

    /// An elliptical arc from `start` to `end` (SVG's endpoint form, turned into its centre form).
    static func addArc(
      to path: CGMutablePath, from start: CGPoint, to end: CGPoint, radii: CGSize, angle: CGFloat,
      large: Bool, sweep: Bool
    ) {
      var rx = abs(radii.width)
      var ry = abs(radii.height)
      guard start != end else { return }
      guard rx > 0, ry > 0 else {
        path.addLine(to: end)
        return
      }
      let phi = angle * .pi / 180
      let cosPhi = cos(phi)
      let sinPhi = sin(phi)
      let dx = (start.x - end.x) / 2
      let dy = (start.y - end.y) / 2
      let x1 = cosPhi * dx + sinPhi * dy
      let y1 = -sinPhi * dx + cosPhi * dy
      let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
      if lambda > 1 {
        rx *= lambda.squareRoot()
        ry *= lambda.squareRoot()
      }
      let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
      let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
      let coefficient = (large == sweep ? -1 : 1) * max(0, numerator / denominator).squareRoot()
      let cx1 = coefficient * rx * y1 / ry
      let cy1 = -coefficient * ry * x1 / rx
      let center = CGPoint(
        x: cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2,
        y: sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2)
      let startAngle = atan2((y1 - cy1) / ry, (x1 - cx1) / rx)
      var delta = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - startAngle
      if sweep, delta < 0 { delta += 2 * .pi }
      if !sweep, delta > 0 { delta -= 2 * .pi }
      let transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: phi)
        .scaledBy(x: rx, y: ry)
      path.addArc(
        center: .zero, radius: 1, startAngle: startAngle, endAngle: startAngle + delta,
        clockwise: delta < 0, transform: transform)
    }
  }

  /// Reads SVG path data: commands, numbers (`1.5-2`, `.5.5`, `1e-3`) and arc flags (`1 0`, `10`).
  struct PathScanner {
    let characters: [Character]
    var index = 0

    init(_ text: String) { characters = Array(text) }

    var isAtEnd: Bool {
      mutating get {
        skipSeparators()
        return index >= characters.count
      }
    }

    mutating func skipSeparators() {
      while index < characters.count, characters[index].isWhitespace || characters[index] == "," {
        index += 1
      }
    }

    mutating func command() -> Character? {
      skipSeparators()
      guard index < characters.count, characters[index].isLetter, characters[index] != "e",
        characters[index] != "E"
      else { return nil }
      defer { index += 1 }
      return characters[index]
    }

    mutating func flag() -> Bool? {
      skipSeparators()
      guard index < characters.count, characters[index] == "0" || characters[index] == "1" else {
        return nil
      }
      defer { index += 1 }
      return characters[index] == "1"
    }

    mutating func number() -> CGFloat? {
      skipSeparators()
      let begin = index
      if index < characters.count, characters[index] == "-" || characters[index] == "+" {
        index += 1
      }
      var sawDot = false
      var sawDigit = false
      while index < characters.count {
        let character = characters[index]
        if character.isASCII, character.isNumber {
          sawDigit = true
        } else if character == ".", !sawDot {
          sawDot = true
        } else {
          break
        }
        index += 1
      }
      if sawDigit, index < characters.count, characters[index] == "e" || characters[index] == "E" {
        var end = index + 1
        if end < characters.count, characters[end] == "-" || characters[end] == "+" { end += 1 }
        if end < characters.count, characters[end].isASCII, characters[end].isNumber {
          index = end
          while index < characters.count, characters[index].isASCII, characters[index].isNumber {
            index += 1
          }
        }
      }
      guard sawDigit, let value = Double(String(characters[begin..<index])) else {
        index = begin
        return nil
      }
      return CGFloat(value)
    }
  }

  /// Collects an SVG's filled shapes, with the fill, opacity and transform each inherits from its groups.
  final class SVGReader: NSObject, XMLParserDelegate {
    struct Style {
      var color: CGColor? = CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0, 0, 0, 1])
      var opacity: CGFloat = 1
      var fillOpacity: CGFloat = 1
      var evenOdd = false
      var transform = CGAffineTransform.identity
    }

    var root: [String: String]?
    var shapes: [SVGImage.Shape] = []
    var styles = [Style()]
    /// How deep inside `defs`, `clipPath`, `mask` and the like, whose shapes aren't drawn.
    var hiddenDepth = 0

    static let hiddenElements: Set<String> = [
      "defs", "clipPath", "mask", "symbol", "pattern", "linearGradient", "radialGradient", "filter",
      "marker", "title", "desc", "metadata", "style",
    ]

    func parser(
      _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
      qualifiedName: String?, attributes: [String: String] = [:]
    ) {
      if hiddenDepth > 0 || Self.hiddenElements.contains(element) {
        hiddenDepth += 1
        return
      }
      if element == "svg", root == nil { root = attributes }
      let style = self.style(attributes, inheriting: styles.last ?? Style())
      styles.append(style)
      guard let path = shape(element, attributes), let color = style.color else { return }
      let alpha = style.opacity * style.fillOpacity
      var transform = style.transform
      guard alpha > 0, let transformed = path.copy(using: &transform) else { return }
      shapes.append(
        .init(
          path: transformed, color: color.copy(alpha: color.alpha * alpha) ?? color,
          evenOdd: style.evenOdd))
    }

    func parser(
      _ parser: XMLParser, didEndElement element: String, namespaceURI: String?,
      qualifiedName: String?
    ) {
      if hiddenDepth > 0 {
        hiddenDepth -= 1
        return
      }
      styles.removeLast()
    }

    func style(_ attributes: [String: String], inheriting parent: Style) -> Style {
      var properties = attributes
      for declaration in (attributes["style"] ?? "").split(separator: ";") {
        let parts = declaration.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
          properties[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(
            in: .whitespaces)
        }
      }
      var style = parent
      // Opacity isn't inherited, it multiplies.
      if let fill = properties["fill"], let color = SVGImage.color(fill) { style.color = color }
      if let opacity = properties["opacity"].flatMap(SVGImage.length) { style.opacity *= opacity }
      if let opacity = properties["fill-opacity"].flatMap(SVGImage.length) {
        style.fillOpacity = opacity
      }
      if let rule = properties["fill-rule"] { style.evenOdd = rule == "evenodd" }
      if let transform = attributes["transform"] {
        style.transform = SVGImage.transform(transform).concatenating(parent.transform)
      }
      return style
    }

    func shape(_ element: String, _ attributes: [String: String]) -> CGPath? {
      func value(_ name: String) -> CGFloat { attributes[name].flatMap(SVGImage.length) ?? 0 }
      switch element {
      case "path": return attributes["d"].map(SVGImage.path)
      case "rect":
        let rect = CGRect(
          x: value("x"), y: value("y"), width: value("width"), height: value("height"))
        guard rect.width > 0, rect.height > 0 else { return nil }
        var rx = attributes["rx"] == nil ? value("ry") : value("rx")
        var ry = attributes["ry"] == nil ? rx : value("ry")
        rx = min(rx, rect.width / 2)
        ry = min(ry, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: rx, cornerHeight: ry, transform: nil)
      case "circle":
        let r = value("r")
        guard r > 0 else { return nil }
        return CGPath(
          ellipseIn: CGRect(x: value("cx") - r, y: value("cy") - r, width: 2 * r, height: 2 * r),
          transform: nil)
      case "ellipse":
        let rx = value("rx")
        let ry = value("ry")
        guard rx > 0, ry > 0 else { return nil }
        return CGPath(
          ellipseIn: CGRect(
            x: value("cx") - rx, y: value("cy") - ry, width: 2 * rx, height: 2 * ry), transform: nil
        )
      case "polygon", "polyline":
        let numbers = SVGImage.numbers(attributes["points"] ?? "")
        guard numbers.count >= 4 else { return nil }
        let path = CGMutablePath()
        path.addLines(
          between: stride(from: 0, to: numbers.count - 1, by: 2).map {
            CGPoint(x: numbers[$0], y: numbers[$0 + 1])
          })
        path.closeSubpath()
        return path
      default: return nil
      }
    }
  }
#endif
