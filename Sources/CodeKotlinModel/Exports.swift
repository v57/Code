/// The core every language's model shares: what CodeKotlinModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// Kotlin: `.kt` files (and the project's `.java` files with them), read again when a Gradle or Maven build file
  /// changes. Scripts (`.kts`) stay with the scanner.
  public static let kotlin = ModelLanguage(
    name: "Kotlin", extensions: ["kt"],
    manifests: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "pom.xml", "local.properties"]
  ) { root, _ in KotlinModel(root: root) }
}
