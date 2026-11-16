/// The core every language's model shares: what CodeTypeScriptModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// TypeScript and JavaScript: `.ts`, `.tsx`, `.mts`, `.cts` (and `.d.ts`), `.js`, `.jsx`, `.mjs`, `.cjs`, read again
  /// when a `tsconfig.json`, `jsconfig.json` or `package.json` changes.
  public static let typeScript = ModelLanguage(
    name: "TypeScript", extensions: ["ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs"],
    manifests: ["tsconfig.json", "jsconfig.json", "package.json"]
  ) { root, _ in TSModel(root: root) }
}
