/// The core every language's model shares: what CodeGoModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// Go: `.go` files, read again when a `go.mod` or `go.work` changes.
  public static let go = ModelLanguage(name: "Go", extensions: ["go"], manifests: ["go.mod", "go.work"]) { root, _ in GoModel(root: root) }
}
