// Project icons are drawn with ImageIO (Apple platforms).
#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import CodeWorkspace

struct ProjectIconTests {
  /// A fresh folder holding the given files (a trailing `/` makes a folder).
  func folder(_ files: [String: Data] = [:], folders: [String] = []) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectIcon-\(UUID().uuidString)")
    for path in folders {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    for (path, data) in files {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
    }
    return root
  }

  /// A PNG of `side` pixels: an opaque square of `inner` pixels in the middle, transparent around it.
  func png(side: Int, inner: Int) throws -> Data {
    let context = try #require(
      CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    let margin = (side - inner) / 2
    context.fill(CGRect(x: margin, y: margin, width: inner, height: inner))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }

  func contents(_ images: [(file: String, size: String, scale: String, idiom: String)]) -> Data {
    let list = images.map {
      ["filename": $0.file, "size": $0.size, "scale": $0.scale, "idiom": $0.idiom]
    }
    return try! JSONSerialization.data(withJSONObject: ["images": list])
  }

  @Test func picksTheLargestImageOfTheAppIconSet() throws {
    let set = "App/Assets.xcassets/AppIcon.appiconset/"
    let root = try folder([
      set + "Contents.json": contents([
        ("16.png", "16x16", "1x", "mac"), ("mac1024.png", "512x512", "2x", "mac"),
        ("ios.png", "1024x1024", "1x", "universal"),
      ]),
      set + "16.png": Data([1]), set + "mac1024.png": Data([1]), set + "ios.png": Data([1]),
      "icon.png": Data([1]),
    ])
    #expect(ProjectIcon.find(in: root)?.lastPathComponent == "ios.png")
  }

  @Test func prefersAppIconSetsThenAndroidThenNamedFiles() throws {
    let android = try folder([
      "app/src/main/res/mipmap-hdpi/ic_launcher.png": Data([1]),
      "app/src/main/res/mipmap-xxxhdpi/ic_launcher.png": Data([1]),
      "logo.png": Data([1]),
    ])
    #expect(ProjectIcon.find(in: android)?.path.hasSuffix("mipmap-xxxhdpi/ic_launcher.png") == true)
    let web = try folder(["public/favicon.png": Data([1]), "docs/deep/er/icon.png": Data([1])])
    #expect(ProjectIcon.find(in: web)?.lastPathComponent == "favicon.png")
    let none = try folder([
      "node_modules/x/Assets.xcassets/AppIcon.appiconset/a.png": Data([1]),
      "Ports/App/Assets.xcassets/AppIcon.appiconset/a.png": Data([1]),
    ])
    #expect(ProjectIcon.find(in: none) == nil)
  }

  @Test func thumbnailsTrimTheTransparentMargin() throws {
    let root = try folder(["icon.png": try png(side: 100, inner: 50)])
    let data = try #require(ProjectIcon.thumbnail(of: root.appendingPathComponent("icon.png"), pixels: 16))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 16 && image.height == 16)
    // The square fills the thumbnail: its corner is opaque.
    #expect(ProjectIcon.opaqueBounds(of: image) == nil)
    #expect(ProjectIcon.thumbnail(of: root.appendingPathComponent("missing.png")) == nil)
  }

  // MARK: - Icon Composer

  /// An Icon Composer bundle's files, under `path`.
  func iconBundle(_ path: String, json: String, assets: [String: Data]) -> [String: Data] {
    var files = [path + "/icon.json": Data(json.utf8)]
    for (name, data) in assets { files[path + "/Assets/" + name] = data }
    return files
  }

  /// The colour of the pixel at `x`, `y` (from the top left) of a PNG, in sRGB bytes.
  func pixel(_ data: Data, _ x: Int, _ y: Int) throws -> [UInt8] {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = try #require(
      CGContext(
        data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(
      image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return bytes
  }

  func isClose(_ pixel: [UInt8], _ expected: [UInt8]) -> Bool {
    zip(pixel, expected).allSatisfy { abs(Int($0) - Int($1)) <= 8 }
  }

  @Test func findsIconComposerIconsLikeAppIconSets() throws {
    let json = #"{"groups":[]}"#
    let only = try folder(
      iconBundle("App/Resources/AppIcon.icon", json: json, assets: [:]).merging([
        "app/src/main/res/mipmap-xxxhdpi/ic_launcher.png": Data([1])
      ]) { $1 })
    #expect(ProjectIcon.find(in: only)?.path.hasSuffix("AppIcon.icon/icon.json") == true)
    let both = try folder(
      iconBundle("App/AppIcon.icon", json: json, assets: [:]).merging([
        "App/Assets.xcassets/AppIcon.appiconset/a.png": Data([1])
      ]) { $1 })
    #expect(ProjectIcon.find(in: both)?.path.hasSuffix("AppIcon.icon/icon.json") == true)
    // A fixture app's set deeper down isn't the project's icon.
    let fixture = try folder(
      iconBundle("App/AppIcon.icon", json: json, assets: [:]).merging([
        "Tools/screenshots/DemoApp/Assets.xcassets/AppIcon.appiconset/a.png": Data([1])
      ]) { $1 })
    #expect(ProjectIcon.find(in: fixture)?.path.hasSuffix("App/AppIcon.icon/icon.json") == true)
    // A bundle without its description isn't an icon.
    let empty = try folder(folders: ["App/AppIcon.icon/Assets"])
    #expect(ProjectIcon.find(in: empty) == nil)
  }

  @Test func drawsTheBackgroundAndTintedLayers() throws {
    // A blue background; a 512-point square (of a 1024-pixel PNG at half scale) moved right, tinted green; a
    // hidden layer that would cover everything.
    let json = """
      {"fill":{"solid":"srgb:0,0,1,1"},"groups":[
        {"layers":[
          {"image-name":"square.png","fill":{"solid":"srgb:0,1,0,1"},
           "position":{"scale":0.5,"translation-in-points":[256,0]}},
          {"image-name":"square.png","hidden":true,"position":{"scale":2}}
        ],"position":{"scale":1,"translation-in-points":[0,0]}}]}
      """
    let root = try folder(
      iconBundle(
        "AppIcon.icon", json: json, assets: ["square.png": try png(side: 1024, inner: 1024)]))
    let file = try #require(ProjectIcon.find(in: root))
    let data = try #require(ProjectIcon.thumbnail(of: file, pixels: 16))
    #expect(isClose(try pixel(data, 2, 8), [0, 0, 255, 255]))
    #expect(isClose(try pixel(data, 13, 8), [0, 255, 0, 255]))
  }

  @Test func drawsSVGLayersAndSystemFills() throws {
    // A dark background; a white circle drawn with two arcs, filling the middle half.
    let svg = """
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
      <path d="M0 5a5 5 0 1 0 10 0a5 5 0 10-10 0" transform="translate(0)"/></svg>
      """
    let json = """
      {"fill":"system-dark","groups":[{"layers":[{"image-name":"dot.svg",
        "fill-specializations":[{"appearance":"dark","value":{"solid":"srgb:1,0,0,1"}},
                                {"value":{"automatic-gradient":"extended-gray:1.00000,1.00000"}}],
        "position":{"scale":51.2}}]}]}
      """
    let root = try folder(
      iconBundle("AppIcon.icon", json: json, assets: ["dot.svg": Data(svg.utf8)]))
    let data = try #require(
      ProjectIcon.thumbnail(of: root.appendingPathComponent("AppIcon.icon/icon.json"), pixels: 16))
    #expect(isClose(try pixel(data, 8, 8), [255, 255, 255, 255]))
    let corner = try pixel(data, 0, 15)
    #expect(corner[0] < 40 && corner[3] == 255)
  }

  @Test func readsSVGPathsAndSizes() throws {
    #expect(SVGImage.numbers("1.5-2.5.5e1,3") == [1.5, -2.5, 5, 3])
    let circle = SVGImage.path("M0 5a5 5 0 1 0 10 0a5 5 0 10-10 0z").boundingBoxOfPath
    #expect(abs(circle.minY) < 0.01 && abs(circle.maxY - 10) < 0.01 && abs(circle.maxX - 10) < 0.01)
    let square = SVGImage.path("m1 1h4v4H1zM10 10l2 2s1 1 2 2q1 1 2 2t2 2").boundingBoxOfPath
    #expect(square.minX == 1 && square.maxX == 18 && square.maxY == 18)
    // Without a size, an SVG is as big as what it draws.
    let unsized = try #require(
      SVGImage(
        data: Data(
          """
          <svg><g transform="scale(2)"><rect x="1" y="2" width="3" height="4"/></g>
          <defs><rect width="99" height="99"/></defs></svg>
          """.utf8)))
    #expect(unsized.size == CGSize(width: 6, height: 8))
    let sized = try #require(
      SVGImage(
        data: Data(
          #"<svg viewBox="0 0 20 10"><circle cx="5" cy="5" r="5" fill="none"/><circle cx="5" cy="5" r="5"/></svg>"#
            .utf8)))
    #expect(sized.size == CGSize(width: 20, height: 10) && sized.shapes.count == 1)
    #expect(SVGImage(data: Data("<svg></svg>".utf8)) == nil)
  }

  @Test func readsIconComposerColors() throws {
    let p3 = try #require(IconFill.color("display-p3:0.95884,0.89502,0.29815,1.00000"))
    #expect(p3.numberOfComponents == 4 && p3.colorSpace?.name == CGColorSpace.displayP3)
    #expect(IconFill.color("extended-gray:1.00000,1.00000")?.numberOfComponents == 2)
    #expect(IconFill.color("srgb:1,0") == nil && IconFill.color("lab:1,2,3,1") == nil)
  }
}
#endif
