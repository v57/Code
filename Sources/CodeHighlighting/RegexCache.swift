import Foundation

/// Compiled regular expressions shared by every scanner, keyed by pattern.
/// NSRegularExpression is immutable and thread-safe, so one instance serves
/// all threads.
enum RegexCache {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var byPattern: [String: NSRegularExpression] = [:]

  /// The compiled pattern, or nil when it does not compile.
  static func regex(_ pattern: String) -> NSRegularExpression? {
    lock.lock()
    defer { lock.unlock() }
    if let cached = byPattern[pattern] { return cached }
    guard let made = try? NSRegularExpression(pattern: pattern) else { return nil }
    byPattern[pattern] = made
    return made
  }
}
