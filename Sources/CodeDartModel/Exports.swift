/// The core every language's model shares: what CodeDartModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// Dart: `.dart` files, read again when a package's pubspec, its lock file, the resolved package configuration or
  /// the analysis options change.
  public static let dart = ModelLanguage(
    name: "Dart", extensions: ["dart"], manifests: ["pubspec.yaml", "pubspec.lock", "package_config.json", "analysis_options.yaml"]
  ) { root, _ in DartModel(root: root) }
}
