// swift-tools-version: 6.4

import PackageDescription

/// Another v57 repository: GitHub's main branch, or the checkout next to this repository with `V57_LOCAL=1` (in
/// Xcode, open Code-Local.xcworkspace instead).
func v57(_ name: String) -> Package.Dependency {
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/\(name).git", branch: "main") : .package(path: "../../\(name)")
}

/// This repository's kits, the package at "..": SwiftPM names a path dependency after its folder, which is Code in
/// the main checkout and the worktree's own name in a worktree.
let kits = String(Context.packageDirectory.split(whereSeparator: { $0 == "/" || $0 == "\\" }).dropLast().last ?? "Code")

/// The apps, a package of their own so the kits (the package one folder up, which other repositories depend on)
/// carry none of the apps' dependencies:
///
/// - CodeApp: the Mac app, all of it but its entry point (Sources/Code/CodeMain.swift). Code.xcodeproj builds that
///   file into Code.app with Resources (the icon, assets, Info.plist and entitlements); on Linux and Windows the Code
///   target below does.
/// - CodeMobileApp: the iPhone and iPad app (remote actions), all of it but its entry point
///   (Sources/CodeMobile/CodeMobileMain.swift, the Xcode project's Code iOS target).
let appSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6), .defaultIsolation(MainActor.self), .enableUpcomingFeature("ApproachableConcurrency"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "CodeApp", platforms: [.macOS(.v14), .iOS(.v17)],
  products: [
    .library(name: "CodeApp", targets: ["CodeApp"]),
    .library(name: "CodeMobileApp", targets: ["CodeMobileApp"]),
  ],
  dependencies: [
    // This repository's kits.
    .package(path: ".."),
    // The shared design, the user's vault (projects, devices, accounts), in-app updates and SSH.
    v57("Component"), v57("Vault"), v57("UpdateKit"), v57("SSH"),
  ],
  targets: [
    .target(
      name: "CodeApp",
      dependencies: [
        .product(name: "CodeKit", package: kits), .product(name: "CodeActionsUI", package: kits),
        .product(name: "ComponentKit", package: "Component"), .product(name: "VaultKit", package: "Vault"),
        .product(name: "VaultUI", package: "Vault"), .product(name: "UpdateKit", package: "UpdateKit"),
      ],
      swiftSettings: appSettings),
    .target(
      name: "CodeMobileApp",
      dependencies: [
        .product(name: "CodeActions", package: kits), .product(name: "CodeActionsUI", package: kits),
        .product(name: "CodeHighlighting", package: kits),
        .product(name: "CodeIcons", package: kits), .product(name: "ComponentKit", package: "Component"),
        .product(name: "VaultKit", package: "Vault"), .product(name: "VaultUI", package: "Vault"),
        .product(name: "SSHKit", package: "SSH"),
      ],
      swiftSettings: appSettings),
  ])

// Dev's screenshot scenes (`.dev/screenshots.json`).
package.dependencies += [v57("Dev")]
for target in package.targets where target.name == "CodeApp" {
  target.dependencies += [.product(name: "DevScreenshots", package: "Dev")]
}

#if os(Windows) || os(Linux)
// Off Apple platforms SwiftUI is v57/SwiftUI's, and SwiftUIPortability adds the Foundation APIs
// swift-corelibs-foundation lacks. Only here: on Apple platforms the apps use Apple's SwiftUI, and v57/SwiftUI (with
// its swift-syntax) stays out of the package graph Xcode resolves.
package.dependencies += [v57("SwiftUI")]
// On Apple platforms `import Foundation` brings Combine (ObservableObject, @Published), URLSession and the file APIs
// SwiftUIPortability adds along: every file gets them here too.
let offAppleSettings =
  appSettings + [
    .unsafeFlags(
      ["Combine", "FoundationNetworking", "SwiftUIPortability"].flatMap {
        ["-Xfrontend", "-import-module", "-Xfrontend", $0]
      })
  ]
for target in package.targets where target.name == "CodeApp" {
  target.dependencies += [
    .product(name: "SwiftUI", package: "SwiftUI"), .product(name: "SwiftUIPortability", package: "SwiftUI"),
  ]
  target.swiftSettings = offAppleSettings
}
// The entry point, Sources/Code/CodeMain.swift, which the Xcode project builds on Apple platforms.
#if os(Windows)
// The app: a DLL the SwiftUI WinUI host loads (SwiftUI's Windows/scripts/build-app.ps1 -PackagePath <this folder>
// -Product CodeWinUI).
package.targets.append(
  .target(
    name: "Code", dependencies: ["CodeApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: offAppleSettings))
package.products.append(.library(name: "CodeWinUI", type: .dynamic, targets: ["Code"]))
#elseif os(Linux)
// The app on SwiftUI's GTK backend (in App/: V57_LOCAL=1 swift build --product Code; SwiftUI's Linux/scripts/build-app
// stages it).
package.targets.append(
  .executableTarget(
    name: "Code", dependencies: ["CodeApp", .product(name: "SwiftUI", package: "SwiftUI")],
    swiftSettings: offAppleSettings))
package.products.append(.executable(name: "Code", targets: ["Code"]))
#endif
#endif
