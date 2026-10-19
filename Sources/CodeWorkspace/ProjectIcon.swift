import Foundation

#if canImport(ImageIO) && canImport(CoreGraphics)
  import CoreGraphics
  import ImageIO
  import UniformTypeIdentifiers
#endif

/// A project's icon, found in its folder: an Xcode asset catalog's app icon, else an Android launcher icon, else an
/// `icon.png`-like file near the top. Apps keep a small thumbnail of it (the vault's project icon).
public enum ProjectIcon {
  /// The image file that is the icon of the project in `root`, or nil. Walks at most `maxDepth` folders down,
  /// skipping hidden folders, dependencies and build output, and gives up after `maxEntries` entries.
  public static func find(in root: URL, maxDepth: Int = 6, maxEntries: Int = 20_000) -> URL? {
    let fileManager = FileManager.default
    guard
      let walker = fileManager.enumerator(
        at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else { return nil }
    var best: (rank: Int, depth: Int, url: URL)?
    var visited = 0
    for case let url as URL in walker {
      visited += 1
      if visited > maxEntries { break }
      let name = url.lastPathComponent
      let depth = walker.level
      let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      if isDirectory {
        if skippedFolders.contains(name) || skippedExtensions.contains(url.pathExtension) || depth >= maxDepth {
          walker.skipDescendants()
        }
        if url.pathExtension == "appiconset" {
          walker.skipDescendants()
          let rank = name == "AppIcon.appiconset" ? 0 : 1
          if let file = largestImage(inIconSet: url), isBetter(rank, depth, than: best) {
            best = (rank, depth, file)
          }
        }
        continue
      }
      let rank: Int
      if name == "ic_launcher.png", url.deletingLastPathComponent().lastPathComponent.hasPrefix("mipmap-") {
        rank = 2 + mipmapOrder(url.deletingLastPathComponent().lastPathComponent)
      } else if depth <= 2, iconNames.contains(name.lowercased()) {
        rank = 10
      } else {
        continue
      }
      if isBetter(rank, depth, than: best) { best = (rank, depth, url) }
    }
    return best?.url
  }

  /// A square PNG of `pixels` × `pixels` made from an image file, with the transparent margin a macOS icon draws
  /// around its shape trimmed off. nil when the file isn't an image (or on platforms without ImageIO).
  public static func thumbnail(of file: URL, pixels: Int = 64) -> Data? {
    #if canImport(ImageIO) && canImport(CoreGraphics)
      guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else { return nil }
      let shape = opaqueBounds(of: image).flatMap { image.cropping(to: $0) } ?? image
      guard
        let context = CGContext(
          data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      context.interpolationQuality = .high
      let scale = CGFloat(pixels) / CGFloat(max(shape.width, shape.height))
      let size = CGSize(width: CGFloat(shape.width) * scale, height: CGFloat(shape.height) * scale)
      context.draw(
        shape,
        in: CGRect(
          x: (CGFloat(pixels) - size.width) / 2, y: (CGFloat(pixels) - size.height) / 2, width: size.width,
          height: size.height))
      guard let thumbnail = context.makeImage() else { return nil }
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(destination, thumbnail, nil)
      return CGImageDestinationFinalize(destination) ? data as Data : nil
    #else
      return nil
    #endif
  }

  // MARK: - Finding

  /// Dependencies, build output, and other apps' code (examples, ports, test fixtures), whose icons aren't the
  /// project's.
  static let skippedFolders: Set<String> = [
    "build", "Build", "DerivedData", "node_modules", "Pods", "Carthage", "vendor", "venv", "dist", "target",
    "site-packages", "__pycache__", "Examples", "Example", "Samples", "Demos", "Ports", "Tests", "Fixtures",
    "ThirdParty", "third_party", "External",
  ]
  static let skippedExtensions: Set<String> = ["xcodeproj", "xcworkspace", "app", "framework", "bundle", "icon"]
  static let iconNames: Set<String> = [
    "icon.png", "appicon.png", "app-icon.png", "app_icon.png", "logo.png", "apple-touch-icon.png", "favicon.png",
  ]

  /// Lower ranks win, then shallower files.
  static func isBetter(_ rank: Int, _ depth: Int, than best: (rank: Int, depth: Int, url: URL)?) -> Bool {
    guard let best else { return true }
    return (rank, depth) < (best.rank, best.depth)
  }

  /// Android's densities, largest first.
  static func mipmapOrder(_ folder: String) -> Int {
    ["mipmap-xxxhdpi", "mipmap-xxhdpi", "mipmap-xhdpi", "mipmap-hdpi", "mipmap-mdpi"].firstIndex(of: folder) ?? 5
  }

  /// The biggest picture an `.appiconset` lists (its size times its scale), an iOS one over a macOS one of the same
  /// size (no margin to trim); without a usable `Contents.json`, its largest PNG file.
  static func largestImage(inIconSet set: URL) -> URL? {
    struct Contents: Decodable {
      struct Image: Decodable {
        var filename: String?
        var size: String?
        var scale: String?
        var idiom: String?
      }
      var images: [Image]
    }
    let fileManager = FileManager.default
    if let data = try? Data(contentsOf: set.appendingPathComponent("Contents.json")),
      let contents = try? JSONDecoder().decode(Contents.self, from: data)
    {
      let listed = contents.images.compactMap { image -> (pixels: Double, isMac: Bool, url: URL)? in
        guard let filename = image.filename else { return nil }
        let url = set.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let side = image.size.flatMap { Double($0.split(separator: "x").first ?? "") } ?? 0
        let scale = image.scale.flatMap { Double($0.dropLast()) } ?? 1
        return (side * scale, image.idiom == "mac", url)
      }
      if let best = listed.max(by: { ($0.pixels, $0.isMac ? 0 : 1) < ($1.pixels, $1.isMac ? 0 : 1) }) {
        return best.url
      }
    }
    let pngs = ((try? fileManager.contentsOfDirectory(atPath: set.path)) ?? [])
      .filter { $0.lowercased().hasSuffix(".png") }
      .map { set.appendingPathComponent($0) }
    return pngs.max { size(of: $0) < size(of: $1) }
  }

  static func size(of url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
  }

  // MARK: - Trimming

  #if canImport(ImageIO) && canImport(CoreGraphics)
    /// The part of `image` that isn't (almost) transparent, nil when that is all of it or none of it.
    static func opaqueBounds(of image: CGImage) -> CGRect? {
      let width = image.width
      let height = image.height
      guard width > 0, height > 0,
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
      else { return nil }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
      var minX = width
      var minY = height
      var maxX = -1
      var maxY = -1
      for y in 0..<height {
        let row = pixels + y * context.bytesPerRow
        for x in 0..<width where row[x] > 8 {
          minX = min(minX, x)
          maxX = max(maxX, x)
          minY = min(minY, y)
          maxY = max(maxY, y)
        }
      }
      guard maxX >= minX, maxY >= minY else { return nil }
      // The bitmap's first row is the image's top, as `cropping(to:)` counts.
      let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
      return bounds.size == CGSize(width: width, height: height) ? nil : bounds
    }
  #endif
}
