import CodeApp
import SwiftUI

/// The Mac app's entry point, and the app's on Linux and Windows: the app itself is the CodeApp library
/// (App/Sources/CodeApp).
@main enum CodeMain {
  static func main() { CodeApp.main() }
}
