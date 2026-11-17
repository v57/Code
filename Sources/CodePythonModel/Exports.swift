/// The core every language's model shares: what CodePythonModel's API returns (answers, sites, details, completions).
@_exported import CodeModel

/// The core's, not Foundation's.
typealias Unit = CodeModel.Unit

extension ModelLanguage {
  /// Python: `.py`, `.pyi` (stubs) and `.pyw`, read again when a `pyproject.toml`, `setup.cfg` or `setup.py` changes
  /// (they name the import roots).
  public static let python = ModelLanguage(
    name: "Python", extensions: ["py", "pyi", "pyw"], manifests: ["pyproject.toml", "setup.cfg", "setup.py"]
  ) { root, _ in PyModel(root: root) }
}
