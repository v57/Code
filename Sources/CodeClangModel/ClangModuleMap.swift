import Foundation

/// Where an SDK's Clang modules and headers are: its frameworks, and the module maps of its `usr/include` (which
/// header is in which module). Read without a preprocessor or a compiler; CodeClangModel finds included headers with
/// it, and CodeSwiftModel's Clang importer the headers of a module Swift imports.
package final class ClangModuleMap {
  package let sdk: String
  /// Framework name → its folder (`Foundation` → `…/Foundation.framework`), nested and sub-frameworks too.
  package let frameworks: [String: String]
  /// `math.h` → `_DarwinFoundation1`, from the module maps in `usr/include`.
  package private(set) var headerModules: [String: String] = [:]
  package private(set) var moduleHeaders: [String: [String]] = [:]

  package init(sdk: String, frameworks: [String: String]) {
    self.sdk = sdk
    self.frameworks = frameworks
    readModuleMaps()
  }

  /// The SDK this Mac builds for (`xcrun --show-sdk-path`), "" where there's none.
  package static func sdkPath() -> String {
    #if os(macOS)
      return run("/usr/bin/xcrun", ["--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
    #else
      return ""
    #endif
  }

  /// Every framework under a folder, as `visit(name, path)` in the order a walk meets them: each before the
  /// frameworks nested in its `Frameworks` folder.
  package static func walkFrameworks(_ directory: String, _ visit: (_ name: String, _ path: String) -> Void) {
    let manager = FileManager.default
    for entry in (try? manager.contentsOfDirectory(atPath: directory)) ?? [] where entry.hasSuffix(".framework") {
      let framework = directory + "/" + entry
      visit(String(entry.dropLast(".framework".count)), framework)
      walkFrameworks(framework + "/Frameworks", visit)
    }
  }

  /// The SDK's frameworks, the developer folder's (XCTest, Testing) and the sub-frameworks, later ones winning.
  package static func frameworks(sdk: String) -> [String: String] {
    var found: [String: String] = [:]
    guard !sdk.isEmpty else { return found }
    walkFrameworks(sdk + "/System/Library/Frameworks") { found[$0] = $1 }
    let developer = URL(fileURLWithPath: sdk).deletingLastPathComponent().deletingLastPathComponent().path
    walkFrameworks(developer + "/Library/Frameworks") { found[$0] = $1 }
    walkFrameworks(sdk + "/System/Library/SubFrameworks") { found[$0] = $1 }
    return found
  }

  private func readModuleMaps() {
    let directory = sdk + "/usr/include"
    let manager = FileManager.default
    for entry in (try? manager.contentsOfDirectory(atPath: directory)) ?? [] where entry.hasSuffix(".modulemap") {
      guard let text = try? String(contentsOfFile: directory + "/" + entry, encoding: .utf8) else { continue }
      var current: String?
      for line in text.split(separator: "\n") {
        if !line.hasPrefix(" "), !line.hasPrefix("\t") {
          let parts = line.split(separator: " ")
          if parts.first == "module", parts.count > 1 {
            current = String(parts[1])
          } else if parts.first == "framework", parts.count > 2 {
            current = String(parts[2])
          }
          continue
        }
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.hasPrefix("header \"") || trimmed.hasPrefix("textual header \"") || trimmed.hasPrefix("private header \"") else { continue }
        guard let current, let open = trimmed.firstIndex(of: "\""), let close = trimmed.lastIndex(of: "\""), open < close else { continue }
        let header = String(trimmed[trimmed.index(after: open)..<close])
        if headerModules[header] == nil { headerModules[header] = current }
        moduleHeaders[current, default: []].append(directory + "/" + header)
      }
    }
  }

  package func hasModule(_ name: String) -> Bool { frameworks[name] != nil || moduleHeaders[name] != nil }

  /// A module's headers: a framework's `Headers` folder, or what the module maps list.
  package func headers(of name: String) -> [String] {
    if let framework = frameworks[name] {
      let directory = framework + "/Headers"
      let list = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
      return list.filter { $0.hasSuffix(".h") }.sorted().map { directory + "/" + $0 }
    }
    return Array(Set(moduleHeaders[name] ?? [])).sorted()
  }

  /// The module a `#import <...>` belongs to.
  package func module(ofInclude include: String) -> String? {
    if let module = headerModules[include] { return module }
    if let slash = include.firstIndex(of: "/") {
      let first = String(include[..<slash])
      if frameworks[first] != nil { return first }
      if first == "objc" { return "ObjectiveC" }
      if first == "dispatch" { return "Dispatch" }
    }
    return nil
  }

  /// `Foundation/NSString.h` → the framework's header, its `PrivateHeaders` second.
  package func frameworkHeader(_ include: String) -> String? {
    guard let slash = include.firstIndex(of: "/"), let framework = frameworks[String(include[..<slash])] else { return nil }
    let rest = include[include.index(after: slash)...]
    for folder in ["/Headers/", "/PrivateHeaders/"] {
      let path = framework + folder + rest
      if FileManager.default.fileExists(atPath: path) { return path }
    }
    return nil
  }

  /// A module's umbrella header for `@import Name;`: the framework's `Name.h`, else its module's first header.
  package func umbrellaHeader(of name: String) -> String? {
    if let framework = frameworks[name] {
      let path = framework + "/Headers/" + name + ".h"
      if FileManager.default.fileExists(atPath: path) { return path }
    }
    return headers(of: name).first
  }

  /// A tool's standard output, "" when it can't run.
  package static func run(_ tool: String, _ arguments: [String], input: String? = nil) -> String {
    #if os(macOS) || os(Linux) || os(Windows)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: tool)
      process.arguments = arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      if input != nil { process.standardInput = Pipe() } else { process.standardInput = FileHandle.nullDevice }
      guard (try? process.run()) != nil else { return "" }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return String(decoding: data, as: UTF8.self)
    #else
      return ""
    #endif
  }
}
