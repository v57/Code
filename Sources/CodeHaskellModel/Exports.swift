/// The core every language's model shares: what CodeHaskellModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// Haskell: `.hs` and `.hs-boot` files, read again when a `.cabal`, `cabal.project`, `stack.yaml`, hpack's
  /// `package.yaml` or `hie.yaml` changes.
  public static let haskell = ModelLanguage(
    name: "Haskell", extensions: ["hs", "hs-boot"],
    manifests: ["*.cabal", "cabal.project", "cabal.project.local", "stack.yaml", "package.yaml", "hie.yaml"]
  ) { root, _ in HaskellModel(root: root) }
}
