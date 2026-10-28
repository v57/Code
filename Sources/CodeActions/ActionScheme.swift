import Foundation

/// What the toolbar can do with a scheme, as in Xcode's Product menu, plus
/// a linter and the ways an Xcode app is distributed.
public enum ActionKind: String, CaseIterable, Codable, Sendable {
  case run
  case build
  case test
  case clean
  case lint
  /// Archives the Mac app, stamped with the commit count as its build number, and copies it into ~/Applications
  /// when it is already there, else into /Applications: exported with Developer ID when the keychain has that
  /// identity, so other Macs open it. In `ActionPlanner`'s steps it quits the running copy first and opens it again
  /// afterwards (`AppInstall`).
  case install
  /// Archives the Mac app, exports it with Developer ID, notarizes and staples
  /// it, and zips it in .build/<scheme>/Export (needs `Notarization`).
  case export
  /// Archives the app and uploads it to App Store Connect.
  case upload

  public var title: String {
    switch self {
    case .run: return "Run"
    case .build: return "Build"
    case .test: return "Test"
    case .clean: return "Clean"
    case .lint: return "Lint"
    case .install: return "Install"
    case .export: return "Export"
    case .upload: return "Upload to App Store"
    }
  }

  /// The activity view's verb while the action runs: "Building", "Running".
  public var progressTitle: String {
    switch self {
    case .run: return "Running"
    case .build: return "Building"
    case .test: return "Testing"
    case .clean: return "Cleaning"
    case .lint: return "Linting"
    case .install: return "Installing"
    case .export: return "Exporting"
    case .upload: return "Uploading"
    }
  }

  /// Install, Export and Upload: one-shot actions that ship the app.
  public var isDistribution: Bool { [.install, .export, .upload].contains(self) }

  /// Export notarizes with the notarytool keychain profile in
  /// `NOTARY_PROFILE` ("notary" when unset); see `Notarization`.
  public var needsNotarization: Bool { self == .export }
}

/// The build system or language toolchain a scheme comes from.
public enum Toolchain: String, Codable, Sendable, CaseIterable {
  case xcode, swiftPM, cargo, go, gradle, android, maven, node, python, cmake, make, zig, dart
  case dotnet, elixir, ruby, php, docker

  public var displayName: String {
    switch self {
    case .xcode: return "Xcode"
    case .swiftPM: return "Swift Package"
    case .cargo: return "Cargo"
    case .go: return "Go"
    case .gradle: return "Gradle"
    case .android: return "Android"
    case .maven: return "Maven"
    case .node: return "Node"
    case .python: return "Python"
    case .cmake: return "CMake"
    case .make: return "Make"
    case .zig: return "Zig"
    case .dart: return "Dart"
    case .dotnet: return ".NET"
    case .elixir: return "Elixir"
    case .ruby: return "Ruby"
    case .php: return "PHP"
    case .docker: return "Docker Compose"
    }
  }

  /// An SF Symbol for menus and the scheme picker.
  public var symbolName: String {
    switch self {
    case .xcode: return "hammer"
    case .swiftPM: return "swift"
    case .android: return "apps.iphone"
    case .node: return "curlybraces"
    case .python: return "chevron.left.forwardslash.chevron.right"
    case .make, .cmake: return "wrench.and.screwdriver"
    case .docker: return "cube.box"
    default: return "shippingbox"
    }
  }
}

/// Where a scheme's product can run.
public enum Platform: String, Codable, Sendable, Hashable, CaseIterable {
  /// This Mac (also every command-line tool and server).
  case mac
  case iOS
  case android
}

/// One thing the toolbar can build and run, like an Xcode scheme: an Xcode
/// scheme, a package's executable, a Go command, an Android app. The shell
/// commands run in `directory`.
public struct ActionScheme: Identifiable, Hashable, Codable, Sendable {
  public var name: String
  public var toolchain: Toolchain
  /// The project folder the commands run in.
  public var directory: URL
  /// Shell commands for the actions this scheme supports.
  public var commands: [ActionKind: String]
  /// Where the product runs; the destination menu offers these.
  public var platforms: [Platform]
  /// The `.xcodeproj` / `.xcworkspace` file name, for Xcode schemes.
  public var xcodeContainer: String?
  /// The Android application ID and its Gradle module, for Android apps.
  public var androidApplicationID: String?
  public var androidModule: String?
  /// The built executable, relative to `directory` (absolute once `inBuildFolders()` moved it), for debugging with LLDB.
  public var executable: String?
  /// Xcode's derived data folder (`-derivedDataPath`), set by `inBuildFolders()`; nil builds into DerivedData.
  public var derivedDataPath: String?

  public init(
    name: String, toolchain: Toolchain, directory: URL, commands: [ActionKind: String],
    platforms: [Platform] = [.mac], xcodeContainer: String? = nil,
    androidApplicationID: String? = nil, androidModule: String? = nil, executable: String? = nil,
    derivedDataPath: String? = nil
  ) {
    self.name = name
    self.toolchain = toolchain
    self.directory = directory
    self.commands = commands
    self.platforms = platforms
    self.xcodeContainer = xcodeContainer
    self.androidApplicationID = androidApplicationID
    self.androidModule = androidModule
    self.executable = executable
    self.derivedDataPath = derivedDataPath
  }

  /// `executable`'s full path.
  public var executableURL: URL? {
    executable.map { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : directory.appendingPathComponent($0) }
  }

  /// `xcodebuild`'s arguments for the container and scheme, with the derived data folder when there is one.
  public var xcodeArguments: String {
    let container = xcodeContainer ?? ""
    let flag = container.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
    let derivedData = derivedDataPath.map { "-derivedDataPath \(shellQuote($0)) " } ?? ""
    return "\(derivedData)\(flag) \(shellQuote(container)) -scheme \(shellQuote(name))"
  }

  public var id: String { directory.path + "#" + toolchain.rawValue + "#" + name }

  /// The project folder's name, which groups schemes in the picker.
  public var projectName: String { directory.lastPathComponent }

  public func supports(_ kind: ActionKind) -> Bool { commands[kind] != nil }

  /// The action as one shell command run in `directory`, for a terminal
  /// that runs commands instead of `ActionPlanner`'s steps (Shell). Run
  /// builds an Xcode app or tool for this Mac and runs its product (found
  /// with -showBuildSettings) in the foreground, and installs and launches an
  /// Android app on the connected device; the other actions are the scheme's
  /// commands.
  public func terminalCommand(for kind: ActionKind) -> String? {
    guard kind == .run else { return commands[kind] }
    switch toolchain {
    case .xcode:
      guard supports(.run), platforms.contains(.mac), xcodeContainer != nil else { return nil }
      let arguments = "\(xcodeArguments) -destination 'platform=macOS'"
      let products =
        derivedDataPath.map { shellQuote($0 + "/Build/Products/Debug") }
        ?? "\"$(xcodebuild \(arguments) -showBuildSettings 2>/dev/null | sed -n 's/^ *BUILT_PRODUCTS_DIR = //p' | head -1)\""
      return
        "xcodebuild \(arguments) build && products=\(products) && app=\"$products\"/\(shellQuote(name + ".app")); [ -d \"$app\" ] || app=$(ls -d \"$products\"/*.app 2>/dev/null | head -1)"
        + "; if [ -n \"$app\" ]; then \"$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \"$app/Contents/Info.plist\")\"; else \"$products\"/\(shellQuote(name)); fi"
    case .android:
      guard let install = commands[.run] else { return nil }
      guard let applicationID = androidApplicationID else { return install }
      return install
        + " && adb shell monkey -p \(shellQuote(applicationID)) -c android.intent.category.LAUNCHER 1 >/dev/null"
    default:
      return commands[.run]
    }
  }
}
