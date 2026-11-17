import Foundation

/// Finding a command on the PATH the way the system's shell does: ";" between folders and `.exe`, `.cmd` or `.bat`
/// after the name on Windows, ":" and the executable bit elsewhere. What CodeActions' `ShellEnvironment` and CodeLSP
/// share.
public enum ExecutableSearch {
  /// The PATH of an environment (Windows names it `Path`, in any case).
  public static func pathValue(in environment: [String: String]) -> String {
    #if os(Windows)
      return environment.first { $0.key.uppercased() == "PATH" }?.value ?? ""
    #else
      return environment["PATH"] ?? ""
    #endif
  }

  /// The folders a PATH value lists.
  public static func folders(inPath value: String) -> [String] {
    #if os(Windows)
      return value.split(separator: ";").map(String.init)
    #else
      return value.split(separator: ":").map(String.init)
    #endif
  }

  /// The full path of `tool` in the first of `folders` that has it, or nil. A path is taken as it is when it exists.
  public static func find(_ tool: String, in folders: [String]) -> String? {
    let fileManager = FileManager.default
    #if os(Windows)
      if tool.contains("\\") || tool.contains(":") { return fileManager.fileExists(atPath: tool) ? tool : nil }
      for directory in folders {
        for suffix in ["", ".exe", ".cmd", ".bat"] {
          let candidate = URL(fileURLWithPath: directory).appendingPathComponent(tool + suffix).path
          var isDirectory: ObjCBool = false
          if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue {
            return candidate
          }
        }
      }
      return nil
    #else
      if tool.hasPrefix("/") { return fileManager.isExecutableFile(atPath: tool) ? tool : nil }
      for directory in folders {
        let candidate = directory + "/" + tool
        if fileManager.isExecutableFile(atPath: candidate) { return candidate }
      }
      return nil
    #endif
  }

  /// The full path of `tool` on an environment's PATH, or nil.
  public static func find(_ tool: String, environment: [String: String]) -> String? {
    find(tool, in: folders(inPath: pathValue(in: environment)))
  }
}
