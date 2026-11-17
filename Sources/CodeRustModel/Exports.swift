/// The core every language's model shares: what CodeRustModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// Rust: `.rs` files, read again when a `Cargo.toml` or `Cargo.lock` changes (they name the crates, their
  /// dependencies and features).
  public static let rust = ModelLanguage(name: "Rust", extensions: ["rs"], manifests: ["Cargo.toml", "Cargo.lock"]) { root, _ in RustModel(root: root) }
}
