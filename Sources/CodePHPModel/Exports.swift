/// The core every language's model shares: what CodePHPModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// PHP: `.php` and `.phtml` files, read again when Composer's manifest, its lock file or its generated autoloading
  /// (`vendor/composer/autoload_psr4.php`, `installed.json`) change.
  public static let php = ModelLanguage(
    name: "PHP", extensions: ["php", "phtml"], manifests: ["composer.json", "composer.lock", "autoload_psr4.php", "installed.json"]
  ) { root, _ in PHPModel(root: root) }
}
