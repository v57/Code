/// The core every language's model shares: what CodeRubyModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// Ruby: `.rb`, `.rake`, `.gemspec`, `.ru` files and `Rakefile`, `Gemfile` (named files are matched by the layout),
  /// read again when the Gemfile, its lock or a gemspec change.
  public static let ruby = ModelLanguage(
    name: "Ruby", extensions: ["rb", "rake", "gemspec", "ru"], manifests: ["Gemfile", "Gemfile.lock", "*.gemspec", ".ruby-version"]
  ) { root, _ in RubyModel(root: root) }
}
