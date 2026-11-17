import Foundation

#if os(macOS)
  import CryptoKit
#endif

/// Where Xcode keeps a project's build products and package checkouts: its DerivedData folder (Settings › Locations),
/// and the folder in it it names after a workspace.
public enum XcodeDerivedData {
  /// Settings › Locations' custom DerivedData location (`IDECustomDerivedDataLocation`) as written: absolute, or
  /// relative to a workspace's folder. Nil when it's the default, and off macOS.
  public static var customLocation: String? {
    #if os(macOS)
      guard let custom = UserDefaults(suiteName: "com.apple.dt.Xcode")?.string(forKey: "IDECustomDerivedDataLocation"),
        !custom.isEmpty
      else { return nil }
      return custom
    #else
      return nil
    #endif
  }

  /// The DerivedData folder for a workspace in `folder` (an .xcodeproj's or .xcworkspace's folder, or a package's
  /// parent): the custom location (relative to `folder` when relative), else `~/Library/Developer/Xcode/DerivedData`.
  public static func root(
    nextTo folder: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory()), customLocation: String? = customLocation
  ) -> URL {
    if let custom = customLocation, !custom.isEmpty {
      let path = custom.hasPrefix("~") ? home.path + custom.dropFirst() : custom
      return path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path)
    }
    return home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
  }

  #if os(macOS)
    /// A workspace's folder in DerivedData: its name and a hash of its standardized path (`/private/tmp` is `/tmp`),
    /// as Xcode and xcodebuild name it.
    public static func folder(of workspace: URL, in root: URL) -> URL {
      let path = (workspace.path as NSString).standardizingPath
      let name = (path as NSString).lastPathComponent
      return root.appendingPathComponent("\((name as NSString).deletingPathExtension)-\(hash(path))")
    }

    /// Xcode's DerivedData hash: the path's MD5, each 64-bit half (big-endian) as 14 base-26 letters.
    public static func hash(_ path: String) -> String {
      let digest = Array(Insecure.MD5.hash(data: Data(path.utf8)))
      return [digest[0..<8], digest[8..<16]].map { half in
        var value = half.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        var letters = [Character](repeating: "a", count: 14)
        for index in (0..<14).reversed() {
          letters[index] = Character(UnicodeScalar(UInt8(97 + value % 26)))
          value /= 26
        }
        return String(letters)
      }.joined()
    }
  #endif
}
