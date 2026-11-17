/// The core every language's model shares: what CodeScalaModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// Scala 2 and 3: `.scala` and `.sc` files (and the project's `.java` files with them), read again when an sbt, Mill,
  /// scala-cli, Gradle or Maven build file changes.
  public static let scala = ModelLanguage(
    name: "Scala", extensions: ["scala", "sc"],
    manifests: [
      "build.sbt", "*.sbt", "build.properties", "build.sc", "build.mill", ".mill-version", "project.scala", "build.gradle", "build.gradle.kts",
      "settings.gradle", "settings.gradle.kts", "pom.xml",
    ]
  ) { root, _ in ScalaModel(root: root) }
}
