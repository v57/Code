import Foundation
import Testing

@testable import CodeIcons

@Test func everyLookupHasAnIcon() {
  let names = Set(FileIcon.fileNames.values)
    .union(FileIcon.extensions.values)
    .union(FileIcon.directoryExtensions.values)
    .union(["folder", "file", "readme", "license", "env", "docker", "config", "package-python"])
  for name in names {
    #expect(FileIcon(named: name) != nil, "no icon named \(name)")
  }
}

@Test func lettersFitAndSymbolsExist() {
  for icon in FileIcon.all {
    #expect((1...3).contains(icon.letters.count), "\(icon.name): \(icon.letters)")
    if let symbol = FileIcon.catalog[icon.name]?.symbol {
      // Catches a misspelled symbol: this system has every symbol the catalog uses.
      #expect(icon.symbol == symbol, "\(icon.name): no SF Symbol \(symbol)")
    }
  }
}

@Test func colorsReadableInBothAppearances() {
  for icon in FileIcon.all {
    guard let color = icon.color else { continue }
    #expect(
      FileIconColor.luminance(FileIconColor.readable(color, onDark: false)) <= 0.32, "\(icon.name)")
    #expect(
      FileIconColor.luminance(FileIconColor.readable(color, onDark: true)) >= 0.13, "\(icon.name)")
  }
  // Colors that already read well stay as they are.
  #expect(FileIconColor.readable(0xF05138, onDark: false) == 0xF05138)
  #expect(FileIconColor.readable(0xF05138, onDark: true) == 0xF05138)
}

@Test func lookup() {
  let cases: [(String, Bool, String)] = [
    ("main.swift", false, "swift"), ("Package.swift", false, "package-swift"),
    ("package.json", false, "package-npm"), ("Cargo.lock", false, "lock"),
    ("Dockerfile", false, "docker"), ("Dockerfile.dev", false, "docker"),
    ("docker-compose.yml", false, "docker"), (".gitignore", false, "git"),
    ("README.md", false, "readme"), ("LICENSE", false, "license"), (".env.local", false, "env"),
    ("App.tsx", false, "react-ts"), ("Info.plist", false, "plist"),
    ("Localizable.xcstrings", false, "strings"), ("Assets.xcassets", true, "assets"),
    ("Code.xcodeproj", true, "xcode"), ("Sources", true, "folder"),
    ("notes.unknown", false, "file"), ("Makefile", false, "make"),
  ]
  for (name, isDirectory, icon) in cases {
    #expect(FileIcon(fileName: name, isDirectory: isDirectory).name == icon, "\(name)")
  }
}
