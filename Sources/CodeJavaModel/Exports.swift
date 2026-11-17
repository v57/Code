/// The core every language's model shares: what CodeJavaModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// Java: `.java` files, read again when a Gradle or Maven build file changes.
  public static let java = ModelLanguage(
    name: "Java", extensions: ["java"],
    manifests: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "pom.xml", "local.properties"]
  ) { root, _ in JavaModel(root: root) }
}
