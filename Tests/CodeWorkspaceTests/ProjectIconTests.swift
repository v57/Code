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
}
