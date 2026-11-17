/// The core every language's model shares: what CodeLuaModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// Lua: `.lua` files, read again when a `.luarc.json`, `.luacheckrc`, rockspec or `stylua.toml` changes.
  public static let lua = ModelLanguage(
    name: "Lua", extensions: ["lua"], manifests: [".luarc.json", ".luarc.jsonc", ".luacheckrc", "*.rockspec", "stylua.toml", ".stylua.toml"]
  ) { root, _ in LuaModel(root: root) }
}
