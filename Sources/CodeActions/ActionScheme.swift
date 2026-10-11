import Foundation

/// What the toolbar can do with a scheme, as in Xcode's Product menu.
public enum ActionKind: String, CaseIterable, Codable, Sendable {
  case run
  case build
  case test
  case clean

  public var title: String {
    switch self {
    case .run: return "Run"
    case .build: return "Build"
    case .test: return "Test"
    case .clean: return "Clean"
    }
  }

  /// The activity view's verb while the action runs: "Building", "Running".
  public var progressTitle: String {
    switch self {
    case .run: return "Running"
    case .build: return "Building"
    case .test: return "Testing"
    case .clean: return "Cleaning"
    }
  }
}

/// The build system or language toolchain a scheme comes from.
public enum Toolchain: String, Codable, Sendable, CaseIterable {
  case xcode, swiftPM, cargo, go, gradle, android, maven, node, python, cmake, make, zig, dart
  case dotnet, elixir, ruby, php

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
  /// The built executable, relative to `directory`, for debugging with LLDB.
  public var executable: String?

  public init(
    name: String, toolchain: Toolchain, directory: URL, commands: [ActionKind: String],
    platforms: [Platform] = [.mac], xcodeContainer: String? = nil,
    androidApplicationID: String? = nil, androidModule: String? = nil, executable: String? = nil
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
  }

  public var id: String { directory.path + "#" + toolchain.rawValue + "#" + name }

  /// The project folder's name, which groups schemes in the picker.
  public var projectName: String { directory.lastPathComponent }

  public func supports(_ kind: ActionKind) -> Bool { commands[kind] != nil }
}
