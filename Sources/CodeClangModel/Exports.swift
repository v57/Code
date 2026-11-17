/// The core every language's model shares: what CodeClangModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// C, C++ and Objective-C: `.c`, `.h`, `.cc`, `.cpp`, `.cxx`, `.hpp`, `.hh`, `.m`, `.mm`, read again when the
  /// project's `compile_commands.json` changes.
  public static let clang = ModelLanguage(
    name: "C", extensions: ["c", "h", "cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm"], manifests: ["compile_commands.json"]
  ) { root, _ in CModel(root: root) }
}
